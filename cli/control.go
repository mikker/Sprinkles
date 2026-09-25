package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// Client side of the daemon's control socket, plus starting and stopping the
// daemon.

var errNotRunning = errors.New("sprinkles isn't running")

var controlTransport = &http.Transport{
	// A fresh connection per request, so status always reflects the daemon
	// currently listening
	DisableKeepAlives: true,
	DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", socketPath())
	},
}

var controlClient = &http.Client{Transport: controlTransport, Timeout: 5 * time.Second}

func getDaemonStatus() (*daemonStatus, error) {
	resp, err := controlClient.Get("http://sprinkles/status")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var st daemonStatus
	return &st, json.NewDecoder(resp.Body).Decode(&st)
}

func controlPost(path string) error {
	resp, err := controlClient.Post("http://sprinkles"+path, "", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return errors.New(strings.TrimSpace(string(body)))
	}
	return nil
}

// reloadDaemon makes a running daemon pick up config changes.
func reloadDaemon() error {
	if _, err := getDaemonStatus(); err != nil {
		return nil // not running; it'll read the config when it starts
	}
	return controlPost("/reload")
}

// streamLogs calls onConnect, then fn for each log line until the daemon
// goes away or ctx is done.
func streamLogs(ctx context.Context, onConnect func(), fn func(string)) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://sprinkles/logs", nil)
	resp, err := (&http.Client{Transport: controlTransport}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	onConnect()
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		fn(scanner.Text())
	}
	return scanner.Err()
}

// isServiceDaemon reports whether the running daemon is the systemd service.
func isServiceDaemon(st *daemonStatus) bool {
	return st.runsAs(getServiceStatus())
}

func (st *daemonStatus) runsAs(service serviceStatus) bool {
	return st != nil && service.MainPID == st.PID
}

// describe says how the daemon runs, eg. for status output.
func (st *daemonStatus) describe(service serviceStatus) string {
	if st.runsAs(service) {
		return "systemd service"
	}
	return fmt.Sprintf("background process %d", st.PID)
}

// startDaemon starts the server in the background: through systemd when the
// service is installed, otherwise as a detached process.
func startDaemon() error {
	if _, err := getDaemonStatus(); err == nil {
		return nil
	}

	if getServiceStatus().Installed {
		if err := systemctl("start", serviceName); err != nil {
			return err
		}
		if err := waitForDaemon(true, 5*time.Second); err != nil {
			return fmt.Errorf("the service didn't start; see `journalctl --user -u sprinkles`")
		}
		return nil
	}

	return spawnDaemon()
}

func spawnDaemon() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(stateDir(), 0o755); err != nil {
		return err
	}
	logFile, err := os.Create(daemonLogPath())
	if err != nil {
		return err
	}
	defer logFile.Close()

	cmd := exec.Command(exe, "serve")
	cmd.Stdout, cmd.Stderr = logFile, logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // survive the terminal closing
	if err := cmd.Start(); err != nil {
		return err
	}

	exited := make(chan struct{})
	go func() { cmd.Wait(); close(exited) }()

	deadline := time.After(5 * time.Second)
	for {
		if _, err := getDaemonStatus(); err == nil {
			return nil
		}
		select {
		case <-exited:
			return fmt.Errorf("server exited: %s", lastLine(daemonLogPath()))
		case <-deadline:
			return fmt.Errorf("server didn't start; see %s", tildify(daemonLogPath()))
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// stopDaemon stops the running daemon, whichever way it was started.
func stopDaemon() error {
	st, err := getDaemonStatus()
	if err != nil {
		return nil
	}
	if isServiceDaemon(st) {
		return systemctl("stop", serviceName)
	}
	if err := controlPost("/stop"); err != nil {
		return err
	}
	return waitForDaemon(false, 5*time.Second)
}

func restartDaemon() error {
	st, err := getDaemonStatus()
	if err == nil && isServiceDaemon(st) {
		if err := systemctl("restart", serviceName); err != nil {
			return err
		}
		return waitForDaemon(true, 5*time.Second)
	}
	if err := stopDaemon(); err != nil {
		return err
	}
	return startDaemon()
}

func waitForDaemon(up bool, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		_, err := getDaemonStatus()
		if (err == nil) == up {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	if up {
		return errors.New("timed out waiting for the server to start")
	}
	return errors.New("timed out waiting for the server to stop")
}

func lastLine(path string) string {
	data, _ := os.ReadFile(path)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	return lines[len(lines)-1]
}
