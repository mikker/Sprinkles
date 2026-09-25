package main

import (
	"os"
	"path/filepath"
	"strings"
)

// Where Sprinkles keeps its files, following the XDG base directory spec.

func homeDir() string {
	home, _ := os.UserHomeDir()
	return home
}

// xdgDir returns $env/sprinkles, or ~/fallback/sprinkles when env is unset.
func xdgDir(env, fallback string) string {
	if dir := os.Getenv(env); dir != "" {
		return filepath.Join(dir, "sprinkles")
	}
	return filepath.Join(homeDir(), fallback, "sprinkles")
}

func configDir() string { return xdgDir("XDG_CONFIG_HOME", ".config") }
func dataDir() string   { return xdgDir("XDG_DATA_HOME", ".local/share") }
func stateDir() string  { return xdgDir("XDG_STATE_HOME", ".local/state") }

func configPath() string        { return filepath.Join(configDir(), "config.json") }
func defaultCerts() Certs       { return Certs{dir: filepath.Join(dataDir(), "certs")} }
func defaultScriptsDir() string { return filepath.Join(homeDir(), ".sprinkles") }

// daemonLogPath is where a daemon started without systemd writes its output.
func daemonLogPath() string { return filepath.Join(stateDir(), "sprinkles.log") }

func socketPath() string {
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, "sprinkles.sock")
	}
	return filepath.Join(dataDir(), "sprinkles.sock")
}

func servicePath() string {
	return filepath.Join(filepath.Dir(configDir()), "systemd", "user", serviceName)
}

func binPath() string { return filepath.Join(homeDir(), ".local", "bin", "sprinkles") }

func expandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		return filepath.Join(homeDir(), path[1:])
	}
	return path
}

// tildify shortens paths under the home directory for display.
func tildify(path string) string {
	home := homeDir()
	if home != "" && (path == home || strings.HasPrefix(path, home+"/")) {
		return "~" + path[len(home):]
	}
	return path
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
