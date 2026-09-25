package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("205"))
	labelStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Width(10)
	dimStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	okStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	warnStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	errStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	keyStyle   = lipgloss.NewStyle().Bold(true)
)

type (
	tickMsg   struct{}
	statusMsg struct {
		daemon   *daemonStatus
		managed  bool // daemon is the systemd service
		service  serviceStatus
		external bool
		cfg      Config
		domains  []string
	}
	trustStatusMsg struct{ trusted, total int }
	logMsg         string
	logResetMsg    struct{}
	// actionMsg reports the outcome of a key command. after runs regardless of
	// the outcome; check m.flashErr for success.
	actionMsg struct {
		text  string
		err   error
		after func(*model) tea.Cmd
	}
)

// model is the dashboard. It controls the daemon over its control socket;
// the server keeps running after the dashboard quits.
type model struct {
	cfg   Config
	certs Certs

	daemon   *daemonStatus
	managed  bool
	service  serviceStatus
	external bool
	domains  []string
	checked  bool

	trusted, trustTotal int
	trustChecked        bool

	logs  []string
	logCh chan tea.Msg

	flash    string
	flashErr bool
	busy     bool

	editingDir bool
	input      textinput.Model

	width, height int
}

func runTUI() error {
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("reading %s: %w", configPath(), err)
	}

	m := &model{cfg: cfg, certs: defaultCerts(), logCh: make(chan tea.Msg, 100)}
	m.input = textinput.New()
	m.input.Prompt = "Scripts directory: "

	if created, err := m.certs.Ensure(); err != nil {
		m.setFlash("", err)
	} else if created {
		m.setFlash("Created a new certificate authority. Press t to trust it in your browsers.", nil)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go m.followLogs(ctx)

	_, err = tea.NewProgram(m).Run()
	return err
}

// followLogs streams the daemon's log, reconnecting whenever it restarts.
func (m *model) followLogs(ctx context.Context) {
	for ctx.Err() == nil {
		streamLogs(ctx,
			func() { m.logCh <- logResetMsg{} },
			func(line string) { m.logCh <- logMsg(line) })
		select {
		case <-ctx.Done():
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func (m *model) Init() tea.Cmd {
	// Start the server if nothing is serving yet
	start := func() tea.Msg {
		if _, err := getDaemonStatus(); err == nil || probe(m.cfg.Port) {
			return nil
		}
		return actionMsg{err: startDaemon()}
	}
	return tea.Batch(start, m.waitForLog(), m.refreshStatus(), m.refreshTrust(), tick())
}

func tick() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m *model) waitForLog() tea.Cmd {
	return func() tea.Msg { return <-m.logCh }
}

func (m *model) refreshStatus() tea.Cmd {
	return func() tea.Msg {
		msg := statusMsg{service: getServiceStatus()}
		msg.cfg, _ = loadConfig()
		if st, err := getDaemonStatus(); err == nil {
			msg.daemon = st
			msg.managed = st.runsAs(msg.service)
			msg.cfg.Directory, msg.cfg.Port = st.Directory, st.Port
		} else {
			msg.external = probe(msg.cfg.Port)
		}
		msg.domains = (&Server{dir: msg.cfg.Directory}).domains()
		return msg
	}
}

func (m *model) refreshTrust() tea.Cmd {
	certs := m.certs
	return func() tea.Msg {
		trusted, total := trustedIn(certs)
		return trustStatusMsg{trusted, total}
	}
}

// action runs fn in the background and reports its outcome.
func (m *model) action(text string, fn func() error, after func(*model) tea.Cmd) tea.Cmd {
	m.busy = true
	return func() tea.Msg { return actionMsg{text: text, err: fn(), after: after} }
}

func (m *model) setFlash(text string, err error) {
	m.flash, m.flashErr = text, err != nil
	if err != nil {
		m.flash = err.Error()
	}
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.input.SetWidth(msg.Width - len(m.input.Prompt) - 4)

	case tickMsg:
		return m, tea.Batch(m.refreshStatus(), tick())

	case statusMsg:
		m.daemon, m.managed, m.service, m.external = msg.daemon, msg.managed, msg.service, msg.external
		m.cfg, m.domains, m.checked = msg.cfg, msg.domains, true

	case trustStatusMsg:
		m.trusted, m.trustTotal, m.trustChecked = msg.trusted, msg.total, true

	case logResetMsg:
		m.logs = nil
		return m, m.waitForLog()

	case logMsg:
		m.logs = append(m.logs, string(msg))
		if len(m.logs) > maxLogLines {
			m.logs = m.logs[len(m.logs)-maxLogLines:]
		}
		return m, m.waitForLog()

	case actionMsg:
		m.busy = false
		m.setFlash(msg.text, msg.err)
		var cmd tea.Cmd
		if msg.after != nil {
			cmd = msg.after(m)
		}
		return m, tea.Batch(cmd, m.refreshStatus())

	case tea.KeyPressMsg:
		if m.editingDir {
			return m.updateDirInput(msg)
		}
		return m.handleKey(msg)
	}

	return m, nil
}

func (m *model) updateDirInput(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.editingDir = false
		return m, nil
	case "enter":
		m.editingDir = false
		dir, err := filepath.Abs(expandHome(strings.TrimSpace(m.input.Value())))
		if err != nil {
			m.setFlash("", err)
			return m, nil
		}
		written, err := prepareScriptsDir(dir)
		if err != nil {
			m.setFlash("", err)
			return m, nil
		}
		if err := saveDirectory(dir); err != nil {
			m.setFlash("", err)
			return m, nil
		}
		text := "Using " + tildify(dir)
		if len(written) > 0 {
			text += " (added example global.css and global.js)"
		}
		return m, m.applyConfig(text)
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

// applyConfig makes the server pick up the saved config, starting it if it
// isn't running.
func (m *model) applyConfig(text string) tea.Cmd {
	return m.action(text, func() error {
		if _, err := getDaemonStatus(); err != nil {
			return startDaemon()
		}
		return reloadDaemon()
	}, nil)
}

func (m *model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if m.busy && msg.String() != "q" && msg.String() != "ctrl+c" {
		return m, nil
	}

	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit

	case "s":
		switch {
		case m.daemon != nil:
			return m, m.action("Stopped", stopDaemon, nil)
		case m.external:
			m.setFlash(fmt.Sprintf("Another process is serving port %d", m.cfg.Port), nil)
		default:
			return m, m.action("Started", startDaemon, nil)
		}

	case "r":
		return m, m.action("Restarted", restartDaemon, nil)

	case "o":
		if err := openPath(m.cfg.Directory); err != nil {
			m.setFlash("", err)
		} else {
			m.setFlash("Opened "+tildify(m.cfg.Directory), nil)
		}

	case "e":
		return m, m.editConfig()

	case "d":
		m.editingDir = true
		m.input.SetValue(tildify(m.cfg.Directory))
		m.input.CursorEnd()
		return m, m.input.Focus()

	case "l":
		// Show where the log lives for daemons started outside the dashboard
		if m.managed {
			m.setFlash("Logs: journalctl --user -u sprinkles -f", nil)
		} else {
			m.setFlash("Logs: "+tildify(daemonLogPath()), nil)
		}

	case "t":
		certs := m.certs
		var text string
		return m, m.action("", func() error {
			results, err := trustBrowsers(certs)
			if err != nil {
				return err
			}
			if len(results) == 0 {
				return fmt.Errorf("no browser profiles found; start your browser once and try again")
			}
			ok := 0
			for _, r := range results {
				if r.Err == nil {
					ok++
				}
			}
			text = fmt.Sprintf("Trusted in %d of %d browser profiles. Restart your browser.", ok, len(results))
			return nil
		}, func(m *model) tea.Cmd {
			if !m.flashErr {
				m.setFlash(text, nil)
			}
			return m.refreshTrust()
		})

	case "u":
		var text string
		return m, m.action("", func() error {
			removed, err := untrustBrowsers()
			text = fmt.Sprintf("Removed from %d browser profiles", len(removed))
			return err
		}, func(m *model) tea.Cmd {
			if !m.flashErr {
				m.setFlash(text, nil)
			}
			return m.refreshTrust()
		})

	case "T":
		cmd, err := systemTrustCmd(m.certs, true)
		if err != nil {
			m.setFlash("", err)
			return m, nil
		}
		return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
			return actionMsg{text: "Added the CA to the system trust store", err: err}
		})

	case "i":
		var notes []string
		return m, m.action("", func() (err error) {
			notes, err = install()
			return err
		}, func(m *model) tea.Cmd {
			if !m.flashErr {
				m.setFlash(strings.Join(notes, ". ")+".", nil)
			}
			return nil
		})

	case "x":
		if !m.service.Installed {
			return m, nil
		}
		// Keep serving in the background until the next login
		return m, m.action("Removed the systemd service", func() error {
			if err := uninstall(); err != nil {
				return err
			}
			return startDaemon()
		}, nil)
	}

	return m, nil
}

func (m *model) editConfig() tea.Cmd {
	if !exists(configPath()) {
		if err := saveConfig(Config{Directory: m.cfg.Directory, Port: defaultPort}); err != nil {
			m.setFlash("", err)
			return nil
		}
	}

	editor := strings.Fields(firstNonEmpty(os.Getenv("VISUAL"), os.Getenv("EDITOR"), "vi"))
	cmd := exec.Command(editor[0], append(editor[1:], configPath())...)

	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		if err != nil {
			return actionMsg{err: err}
		}
		return actionMsg{after: func(m *model) tea.Cmd { return m.applyConfig("Config saved") }}
	})
}

func (m *model) View() tea.View {
	var b strings.Builder

	b.WriteString(titleStyle.Render("Sprinkles") + dimStyle.Render(" "+version) + "\n\n")

	row := func(label, value string) {
		b.WriteString("  " + labelStyle.Render(label) + value + "\n")
	}

	row("Server", m.serverStatus())

	scripts := tildify(m.cfg.Directory)
	if n := len(m.domains); n > 0 {
		scripts += dimStyle.Render(fmt.Sprintf(" · %d domain%s", n, plural(n)))
	}
	row("Scripts", scripts)
	row("Config", tildify(configPath()))
	row("CA", m.caStatus())
	row("Service", m.serviceStatus())
	b.WriteString("\n")

	switch {
	case m.editingDir:
		b.WriteString("  " + m.input.View() + "\n")
		b.WriteString("  " + dimStyle.Render("enter save · esc cancel") + "\n")
	case m.busy:
		b.WriteString("  " + dimStyle.Render("Working…") + "\n")
	case m.flash != "" && m.flashErr:
		b.WriteString(errStyle.Render(m.wrap("✗ "+m.flash)) + "\n")
	case m.flash != "":
		b.WriteString(m.wrap(okStyle.Render("✓ ")+m.flash) + "\n")
	default:
		b.WriteString("\n")
	}
	b.WriteString("\n")

	help := m.help()
	logHeight := 8
	if m.height > 0 {
		used := strings.Count(b.String(), "\n") + strings.Count(help, "\n") + 3
		logHeight = max(m.height-used, 1)
	}

	b.WriteString("  " + dimStyle.Render("Log") + "\n")
	logs := m.logs[max(len(m.logs)-logHeight, 0):]
	for _, line := range logs {
		if strings.Contains(line, "TLS handshake error") &&
			(strings.Contains(line, "unknown certificate") || strings.Contains(line, "bad certificate")) {
			line += " (press t to trust the CA, then restart the browser)"
		}
		if m.width > 4 && len(line) > m.width-4 {
			line = line[:m.width-5] + "…"
		}
		b.WriteString("  " + line + "\n")
	}
	if len(logs) == 0 {
		b.WriteString("  " + dimStyle.Render("Nothing yet") + "\n")
	}
	b.WriteString(strings.Repeat("\n", max(logHeight-max(len(logs), 1), 0)))

	b.WriteString("\n" + help)

	v := tea.NewView(b.String())
	v.AltScreen = true
	v.WindowTitle = "Sprinkles"
	return v
}

func (m *model) serverStatus() string {
	switch {
	case m.daemon != nil:
		url := fmt.Sprintf("%s://localhost:%d", m.daemon.Scheme, m.daemon.Port)
		return okStyle.Render("● ") + "Serving " + url + dimStyle.Render(" · "+m.daemon.describe(m.service))
	case m.external:
		return warnStyle.Render("● ") + fmt.Sprintf("Another program is serving port %d", m.cfg.Port)
	case m.busy || !m.checked:
		return dimStyle.Render("○ …")
	case m.flashErr:
		return errStyle.Render("○ Not running") + dimStyle.Render(" (d change dir · e edit config · s retry)")
	}
	return dimStyle.Render("○ Stopped")
}

func (m *model) caStatus() string {
	ca, err := m.certs.CACert()
	if err != nil {
		return errStyle.Render("missing")
	}
	expires := dimStyle.Render(" · expires " + ca.NotAfter.Format(time.DateOnly))

	switch {
	case !m.trustChecked:
		return dimStyle.Render("checking…")
	case m.trustTotal == 0:
		return warnStyle.Render("no browser profiles found (is certutil installed?)") + expires
	case m.trusted == m.trustTotal:
		return okStyle.Render(fmt.Sprintf("trusted in all %d browser profiles", m.trustTotal)) + expires
	case m.trusted == 0:
		return errStyle.Render("not trusted by your browsers") + dimStyle.Render(" (press t)") + expires
	}
	return warnStyle.Render(fmt.Sprintf("trusted in %d of %d browser profiles", m.trusted, m.trustTotal)) +
		dimStyle.Render(" (press t)") + expires
}

func (m *model) serviceStatus() string {
	switch {
	case m.service.Active:
		return okStyle.Render("enabled") + dimStyle.Render(" · starts on login")
	case m.service.Installed:
		return warnStyle.Render("installed, not running")
	}
	return dimStyle.Render("not installed (press i to start on login)")
}

func (m *model) help() string {
	start := "start"
	if m.daemon != nil {
		start = "stop"
	}
	service := "install service"
	if m.service.Installed {
		service = "reinstall service"
	}

	items := [][2]string{
		{"s", start}, {"r", "restart"}, {"o", "open scripts"}, {"d", "change dir"}, {"e", "edit config"},
		{"l", "log file"}, {"t", "trust in browsers"}, {"T", "trust system-wide"}, {"u", "untrust"},
		{"i", service},
	}
	if m.service.Installed {
		items = append(items, [2]string{"x", "remove service"})
	}
	items = append(items, [2]string{"q", "quit (server keeps running)"})

	// Wrap to the terminal width
	width := m.width - 4
	if width <= 0 {
		width = 80
	}
	var lines []string
	var line string
	for _, item := range items {
		entry := keyStyle.Render(item[0]) + " " + dimStyle.Render(item[1])
		plain := item[0] + " " + item[1]
		if line != "" && lipgloss.Width(line)+3+len(plain) > width {
			lines = append(lines, line)
			line = ""
		}
		if line != "" {
			line += dimStyle.Render(" · ")
		}
		line += entry
	}
	lines = append(lines, line)
	return "  " + strings.Join(lines, "\n  ")
}

// wrap indents text by two spaces and wraps it to the terminal width.
func (m *model) wrap(text string) string {
	width := m.width - 4
	if width <= 0 {
		width = 80
	}
	lines := strings.Split(lipgloss.Wrap(text, width, " "), "\n")
	return "  " + strings.Join(lines, "\n  ")
}

func openPath(path string) error {
	cmd := exec.Command("xdg-open", path)
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
