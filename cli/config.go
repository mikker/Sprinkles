package main

import (
	"encoding/json"
	"os"
	"strconv"
)

const defaultPort = 3133

// Config is stored in $XDG_CONFIG_HOME/sprinkles/config.json.
type Config struct {
	Directory string `json:"directory,omitempty"`
	Port      int    `json:"port,omitempty"`
}

// loadConfig reads the config file, then applies SPRINKLES_DIR and
// SPRINKLES_PORT overrides and defaults.
func loadConfig() (Config, error) {
	cfg, err := readConfigFile()
	if err != nil {
		return cfg, err
	}

	if dir := os.Getenv("SPRINKLES_DIR"); dir != "" {
		cfg.Directory = dir
	}
	if port, err := strconv.Atoi(os.Getenv("SPRINKLES_PORT")); err == nil {
		cfg.Port = port
	}

	if cfg.Directory == "" {
		cfg.Directory = defaultScriptsDir()
	}
	if cfg.Port == 0 {
		cfg.Port = defaultPort
	}
	cfg.Directory = expandHome(cfg.Directory)

	return cfg, nil
}

// readConfigFile reads the config file as-is, without env overrides or defaults.
func readConfigFile() (Config, error) {
	var cfg Config
	data, err := os.ReadFile(configPath())
	if os.IsNotExist(err) {
		return cfg, nil
	} else if err != nil {
		return cfg, err
	}
	return cfg, json.Unmarshal(data, &cfg)
}

// saveDirectory stores dir in the config file, keeping its other settings.
func saveDirectory(dir string) error {
	cfg, err := readConfigFile()
	if err != nil {
		return err
	}
	cfg.Directory = dir
	return saveConfig(cfg)
}

func saveConfig(cfg Config) error {
	if err := os.MkdirAll(configDir(), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(configPath(), append(data, '\n'), 0o644)
}
