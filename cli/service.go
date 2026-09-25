package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The systemd user service that starts Sprinkles on login.
const serviceName = "sprinkles.service"

type serviceStatus struct {
	Installed bool
	Active    bool
	MainPID   int
}

func getServiceStatus() serviceStatus {
	status := serviceStatus{Installed: exists(servicePath())}
	if !status.Installed {
		return status
	}
	out, _ := exec.Command("systemctl", "--user", "show", serviceName, "-p", "ActiveState", "-p", "MainPID").Output()
	for _, line := range strings.Split(string(out), "\n") {
		key, value, _ := strings.Cut(line, "=")
		switch key {
		case "ActiveState":
			status.Active = value == "active"
		case "MainPID":
			status.MainPID, _ = strconv.Atoi(value)
		}
	}
	return status
}

// install copies this binary to ~/.local/bin and sets it up as a systemd user
// service that starts on login, replacing any daemon started another way.
// Returns notes worth showing the user.
func install() ([]string, error) {
	var notes []string

	exe, err := installBinary()
	if err != nil {
		return nil, err
	}
	notes = append(notes, "Installed "+tildify(exe))
	if !inPath(filepath.Dir(exe)) {
		notes = append(notes, tildify(filepath.Dir(exe))+" is not in your PATH")
	}

	unit := fmt.Sprintf(`[Unit]
Description=Sprinkles – serve your CSS and JavaScript to the browser extension

[Service]
ExecStart=%q serve
Restart=on-failure

[Install]
WantedBy=default.target
`, exe)

	if err := os.MkdirAll(filepath.Dir(servicePath()), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(servicePath(), []byte(unit), 0o644); err != nil {
		return nil, err
	}
	if err := systemctl("daemon-reload"); err != nil {
		return nil, err
	}
	if err := systemctl("enable", serviceName); err != nil {
		return nil, err
	}

	// Hand over from a daemon that isn't the service
	if st, err := getDaemonStatus(); err == nil && !isServiceDaemon(st) {
		if err := stopDaemon(); err != nil {
			return nil, err
		}
	}
	if err := systemctl("restart", serviceName); err != nil {
		return nil, err
	}
	if err := waitForDaemon(true, 5*time.Second); err != nil {
		return nil, fmt.Errorf("the service didn't start; see `journalctl --user -u sprinkles`")
	}

	notes = append(notes, "Installed the systemd service. Sprinkles now starts on login")
	return notes, nil
}

// installBinary copies the running executable to ~/.local/bin/sprinkles
// unless it's already running from there.
func installBinary() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if exe, err = filepath.EvalSymlinks(exe); err != nil {
		return "", err
	}
	if strings.Contains(exe, "go-build") {
		return "", fmt.Errorf("refusing to install a temporary `go run` binary; build sprinkles first")
	}

	dest := binPath()
	if exe == dest {
		return dest, nil
	}

	src, err := os.Open(exe)
	if err != nil {
		return "", err
	}
	defer src.Close()
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", err
	}

	// Write then rename, so a running copy of the old binary isn't disturbed
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".sprinkles-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, src); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Chmod(tmp.Name(), 0o755); err != nil {
		return "", err
	}
	return dest, os.Rename(tmp.Name(), dest)
}

// uninstall removes the systemd service, stopping the server it runs.
// The binary is left in place.
func uninstall() error {
	if !exists(servicePath()) {
		return nil
	}
	systemctl("disable", "--now", serviceName)
	if err := os.Remove(servicePath()); err != nil {
		return err
	}
	return systemctl("daemon-reload")
}

func systemctl(args ...string) error {
	out, err := exec.Command("systemctl", append([]string{"--user"}, args...)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %s: %s", strings.Join(args, " "), strings.TrimSpace(string(out)))
	}
	return nil
}

func inPath(dir string) bool {
	for _, p := range filepath.SplitList(os.Getenv("PATH")) {
		if p == dir {
			return true
		}
	}
	return false
}
