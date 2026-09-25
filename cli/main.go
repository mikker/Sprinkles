// Command sprinkles is a Linux/CLI version of the Sprinkles macOS app. It serves
// your per-domain CSS and JavaScript over https://localhost:3133 for the
// Sprinkles browser extensions.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"time"
)

// Overridden at build time with -ldflags "-X main.version=... -X main.build=..."
var (
	version = "1.2.1"
	build   = "131"
)

func buildNumber() int {
	n, _ := strconv.Atoi(build)
	return n
}

const usage = `Usage: sprinkles [command] [flags]

Run without a command in a terminal for the interactive dashboard. The server
runs in the background and keeps running when the dashboard quits.

Commands:
  install             Install to ~/.local/bin and start on login (systemd user service)
  uninstall           Remove the systemd service
  start               Start the server in the background
  stop                Stop the background server
  restart             Restart the background server
  logs                Follow the server log
  status              Show server, configuration and certificate info
  setup [dir]         Choose scripts directory, create certificates, trust CA
  trust [--system]    Trust the Sprinkles CA in browsers (and system with --system)
  untrust [--system]  Remove the Sprinkles CA from browsers (and system)
  serve [flags]       Run the server in the foreground
  version             Print version

Serve flags:
  --dir DIR           Scripts directory (default from config, or ~/.sprinkles)
  --port PORT         Port (default 3133)
  --host HOST         Listen address (default localhost)
  --http              Serve plain HTTP instead of HTTPS
  -v, --verbose       Log requests

Config: %s
Env:    SPRINKLES_DIR, SPRINKLES_PORT
`

func main() {
	log.SetFlags(log.Ltime)

	flag.Usage = func() { fmt.Fprintf(os.Stderr, usage, tildify(configPath())) }

	args := os.Args[1:]
	cmd := ""
	if len(args) > 0 && args[0] != "" && args[0][0] != '-' {
		cmd, args = args[0], args[1:]
	}

	var err error
	switch cmd {
	case "":
		if len(args) == 0 && isTerminal(os.Stdin) && isTerminal(os.Stdout) {
			err = runTUI()
		} else {
			err = runServe(args)
		}
	case "serve":
		err = runServe(args)
	case "start":
		if err = startDaemon(); err == nil {
			err = printDaemonStatus()
		}
	case "stop":
		err = stopDaemon()
	case "restart":
		if err = restartDaemon(); err == nil {
			err = printDaemonStatus()
		}
	case "logs":
		err = runLogs()
	case "install":
		err = runInstall()
	case "uninstall":
		if err = uninstall(); err == nil {
			fmt.Println("Removed the systemd service")
		}
	case "setup", "init":
		err = runSetup(args)
	case "trust":
		err = runTrust(args, true)
	case "untrust":
		err = runTrust(args, false)
	case "status":
		err = runStatus()
	case "version":
		fmt.Printf("sprinkles %s (%s)\n", version, build)
	case "help", "-h", "--help":
		flag.Usage()
	default:
		flag.Usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

func runServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	fs.Usage = flag.Usage
	d := &Daemon{}
	fs.StringVar(&d.dirOverride, "dir", "", "")
	fs.IntVar(&d.portOverride, "port", 0, "")
	fs.StringVar(&d.host, "host", "localhost", "")
	fs.BoolVar(&d.plain, "http", false, "")
	fs.BoolVar(&d.verbose, "verbose", false, "")
	fs.BoolVar(&d.verbose, "v", false, "")
	fs.Parse(args)

	return d.Run()
}

func runLogs() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	err := streamLogs(ctx, func() {}, func(line string) { fmt.Println(line) })
	if ctx.Err() != nil {
		return nil
	}
	if _, statusErr := getDaemonStatus(); statusErr != nil {
		return errNotRunning
	}
	return err
}

func runInstall() error {
	notes, err := install()
	for _, note := range notes {
		fmt.Println(note)
	}
	if err != nil {
		return err
	}
	fmt.Println("Logs: journalctl --user -u sprinkles -f")
	return nil
}

func printDaemonStatus() error {
	st, err := getDaemonStatus()
	if err != nil {
		return errNotRunning
	}
	fmt.Printf("Serving %s on %s://localhost:%d (%s)\n", tildify(st.Directory), st.Scheme, st.Port, st.describe(getServiceStatus()))
	return nil
}

func runSetup(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	if len(args) > 0 {
		cfg.Directory = expandHome(args[0])
	}
	if cfg.Directory, err = filepath.Abs(cfg.Directory); err != nil {
		return err
	}

	written, err := prepareScriptsDir(cfg.Directory)
	if err != nil {
		return err
	}
	for _, path := range written {
		fmt.Printf("Writing default %s\n", path)
	}
	if err := saveDirectory(cfg.Directory); err != nil {
		return err
	}
	fmt.Printf("Scripts directory: %s\nSaved config to %s\n\n", cfg.Directory, configPath())
	if err := reloadDaemon(); err != nil {
		return err
	}

	certs := defaultCerts()
	if _, err := certs.Ensure(); err != nil {
		return err
	}
	fmt.Printf("Certificates in %s\n\nTrusting CA in browsers:\n", certs.dir)

	return printTrust(certs)
}

func runTrust(args []string, add bool) error {
	fs := flag.NewFlagSet("trust", flag.ExitOnError)
	fs.Usage = flag.Usage
	system := fs.Bool("system", false, "")
	fs.Parse(args)

	certs := defaultCerts()

	if !add {
		removed, err := untrustBrowsers()
		if err != nil {
			fmt.Println(err)
		}
		for _, db := range removed {
			fmt.Printf("✓ removed from %s\n", db)
		}
	} else {
		if _, err := certs.Ensure(); err != nil {
			return err
		}
		if err := printTrust(certs); err != nil {
			fmt.Println(err)
		}
	}

	if *system && certs.HasCA() {
		cmd, err := systemTrustCmd(certs, add)
		if err != nil {
			return err
		}
		fmt.Printf("Updating the system trust store (%s)\n", cmd.String())
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	}
	return nil
}

func printTrust(certs Certs) error {
	results, err := trustBrowsers(certs)
	if err != nil {
		return err
	}
	if len(results) == 0 {
		fmt.Println("No browser certificate databases found. Start your browser once and try again.")
		return nil
	}
	for _, r := range results {
		if r.Err != nil {
			fmt.Printf("✗ %s: %v\n", r.DB, r.Err)
		} else {
			fmt.Printf("✓ %s\n", r.DB)
		}
	}
	fmt.Println("\nRestart your browser for the change to take effect.")
	return nil
}

func runStatus() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	certs := defaultCerts()
	service := getServiceStatus()

	fmt.Printf("Version:    %s (%s)\n", version, build)
	fmt.Printf("Config:     %s\n", configPath())
	fmt.Printf("Directory:  %s\n", cfg.Directory)
	fmt.Printf("Port:       %d\n", cfg.Port)
	if st, err := getDaemonStatus(); err == nil {
		fmt.Printf("Server:     serving %s on %s://localhost:%d (%s)\n", tildify(st.Directory), st.Scheme, st.Port, st.describe(service))
	} else if probe(cfg.Port) {
		fmt.Printf("Server:     another program is serving port %d\n", cfg.Port)
	} else {
		fmt.Println("Server:     stopped")
	}
	fmt.Printf("Service:    installed=%v active=%v\n", service.Installed, service.Active)
	fmt.Printf("Certs:      %s\n", certs.dir)

	if ca, err := certs.CACert(); err == nil {
		trusted, total := trustedIn(certs)
		fmt.Printf("CA expires: %s (trusted in %d of %d browser profiles)\n", ca.NotAfter.Format(time.DateOnly), trusted, total)
	} else {
		fmt.Println("CA:         missing (run `sprinkles setup`)")
	}
	if leaf, err := readCert(certs.CertPath()); err == nil {
		fmt.Printf("Cert expires: %s\n", leaf.NotAfter.Format(time.DateOnly))
	}
	return nil
}
