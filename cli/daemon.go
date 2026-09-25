package main

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Daemon runs the Sprinkles server plus a control socket that the dashboard
// and CLI commands use to query status, stream logs, reload config and stop.
type Daemon struct {
	host    string
	plain   bool
	verbose bool
	// Overrides from command line flags, kept across reloads
	dirOverride  string
	portOverride int

	mu      sync.Mutex
	cfg     Config
	runner  *Runner
	started time.Time

	logs *logBuffer
	errs chan error
	quit chan struct{}
}

type daemonStatus struct {
	PID       int       `json:"pid"`
	Version   string    `json:"version"`
	Build     int       `json:"build"`
	Directory string    `json:"directory"`
	Port      int       `json:"port"`
	Scheme    string    `json:"scheme"`
	Started   time.Time `json:"started"`
}

func (d *Daemon) Run() error {
	if st, err := getDaemonStatus(); err == nil {
		return fmt.Errorf("sprinkles is already running (pid %d)", st.PID)
	}

	d.logs = newLogBuffer()
	d.errs = make(chan error, 1)
	d.quit = make(chan struct{})
	d.started = time.Now()

	cfg, err := d.config()
	if err != nil {
		return err
	}
	if err := d.start(cfg); err != nil {
		return err
	}

	control, err := d.listenControl()
	if err != nil {
		d.runner.Stop()
		return err
	}
	defer control.Close()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)

	select {
	case err = <-d.errs:
	case <-signals:
	case <-d.quit:
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	d.runner.Stop()
	return err
}

// config loads the config file and env, then applies flag overrides.
func (d *Daemon) config() (Config, error) {
	cfg, err := loadConfig()
	if err != nil {
		return cfg, fmt.Errorf("reading %s: %w", configPath(), err)
	}
	if d.dirOverride != "" {
		cfg.Directory = expandHome(d.dirOverride)
	}
	if d.portOverride != 0 {
		cfg.Port = d.portOverride
	}
	cfg.Directory, err = filepath.Abs(cfg.Directory)
	return cfg, err
}

// start serves cfg. Callers other than Run must hold d.mu.
func (d *Daemon) start(cfg Config) error {
	written, err := prepareScriptsDir(cfg.Directory)
	if err != nil {
		return err
	}
	for _, path := range written {
		d.logError("Wrote default " + path)
	}

	var tlsConfig *tls.Config
	if !d.plain {
		certs := defaultCerts()
		created, err := certs.Ensure()
		if err != nil {
			return err
		}
		if created {
			d.logError("Created a new Sprinkles CA. Run `sprinkles trust` so browsers accept it.")
		}
		if tlsConfig, err = certs.TLSConfig(); err != nil {
			return err
		}
	}

	runner, err := startServer(cfg.Directory, d.host, cfg.Port, tlsConfig, d.logRequest, d.logError)
	if err != nil {
		return err
	}
	go func() {
		if err := <-runner.Done(); err != nil {
			select {
			case d.errs <- err:
			default:
			}
		}
	}()

	d.runner, d.cfg = runner, cfg
	d.logError(fmt.Sprintf("Serving %s on %s://%s:%d", tildify(cfg.Directory), d.scheme(), d.host, cfg.Port))
	return nil
}

// reload re-reads the config and restarts the server if it changed.
func (d *Daemon) reload() error {
	cfg, err := d.config()
	if err != nil {
		return err
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	if cfg == d.cfg {
		return nil
	}

	// Validate before stopping the working server
	if _, err := prepareScriptsDir(cfg.Directory); err != nil {
		return err
	}

	old := d.cfg
	d.runner.Stop()
	if err := d.start(cfg); err != nil {
		d.logError("Reload failed: " + err.Error())
		if restoreErr := d.start(old); restoreErr != nil {
			return errors.Join(err, restoreErr)
		}
		return err
	}
	return nil
}

func (d *Daemon) scheme() string {
	if d.plain {
		return "http"
	}
	return "https"
}

func (d *Daemon) status() daemonStatus {
	d.mu.Lock()
	defer d.mu.Unlock()
	return daemonStatus{
		PID:       os.Getpid(),
		Version:   version,
		Build:     buildNumber(),
		Directory: d.cfg.Directory,
		Port:      d.cfg.Port,
		Scheme:    d.scheme(),
		Started:   d.started,
	}
}

func (d *Daemon) logRequest(line string) {
	d.logs.add(line)
	if d.verbose {
		log.Print(line)
	}
}

func (d *Daemon) logError(line string) {
	if strings.Contains(line, "error reading preface") {
		return // clients closing connections early, eg. status probes
	}
	d.logs.add(line)
	log.Print(line)
}

func (d *Daemon) listenControl() (*http.Server, error) {
	path := socketPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	os.Remove(path) // stale socket from a crashed daemon; Run checked none is alive

	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	os.Chmod(path, 0o600)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(d.status())
	})
	mux.HandleFunc("GET /logs", d.handleLogs)
	mux.HandleFunc("POST /reload", func(w http.ResponseWriter, r *http.Request) {
		if err := d.reload(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})
	mux.HandleFunc("POST /stop", func(w http.ResponseWriter, r *http.Request) {
		d.logError("Stopping")
		close(d.quit)
	})

	srv := &http.Server{Handler: mux}
	go srv.Serve(l)
	return srv, nil
}

// handleLogs streams recent log lines, then new ones as they happen.
func (d *Daemon) handleLogs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	backlog, lines, cancel := d.logs.subscribe()
	defer cancel()

	flusher := http.NewResponseController(w)
	for _, line := range backlog {
		fmt.Fprintln(w, line)
	}
	flusher.Flush()

	for {
		select {
		case line := <-lines:
			fmt.Fprintln(w, line)
			flusher.Flush()
		case <-r.Context().Done():
			return
		case <-d.quit:
			return
		}
	}
}

const maxLogLines = 200

type logBuffer struct {
	mu    sync.Mutex
	lines []string
	subs  map[chan string]struct{}
}

func newLogBuffer() *logBuffer {
	return &logBuffer{subs: map[chan string]struct{}{}}
}

func (b *logBuffer) add(line string) {
	line = time.Now().Format("15:04:05") + " " + line

	b.mu.Lock()
	defer b.mu.Unlock()
	b.lines = append(b.lines, line)
	if len(b.lines) > maxLogLines {
		b.lines = b.lines[len(b.lines)-maxLogLines:]
	}
	for ch := range b.subs {
		select {
		case ch <- line:
		default: // slow reader; drop rather than block requests
		}
	}
}

func (b *logBuffer) subscribe() ([]string, <-chan string, func()) {
	b.mu.Lock()
	defer b.mu.Unlock()
	ch := make(chan string, 100)
	b.subs[ch] = struct{}{}
	backlog := append([]string(nil), b.lines...)
	return backlog, ch, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		delete(b.subs, ch)
	}
}
