package main

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func TestDaemonLifecycle(t *testing.T) {
	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("XDG_DATA_HOME", filepath.Join(root, "data"))
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(root, "run"))
	t.Setenv("SPRINKLES_DIR", "")
	t.Setenv("SPRINKLES_PORT", "")

	port := freePort(t)
	first, second := filepath.Join(root, "first"), filepath.Join(root, "second")
	if err := saveConfig(Config{Directory: first, Port: port}); err != nil {
		t.Fatal(err)
	}

	d := &Daemon{host: "127.0.0.1", plain: true}
	done := make(chan error, 1)
	go func() { done <- d.Run() }()

	if err := waitForDaemon(true, 3*time.Second); err != nil {
		t.Fatal(err)
	}
	st, err := getDaemonStatus()
	if err != nil || st.Directory != first || st.Port != port || st.PID != os.Getpid() {
		t.Fatalf("status %+v, %v", st, err)
	}

	// A second daemon refuses to start
	if err := (&Daemon{host: "127.0.0.1", plain: true}).Run(); err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("expected already running error, got %v", err)
	}

	// Requests show up in the log stream
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	lines := make(chan string, 100)
	go streamLogs(ctx, func() {}, func(line string) { lines <- line })
	time.Sleep(100 * time.Millisecond)

	resp, err := http.Get("http://127.0.0.1:" + strconv.Itoa(port) + "/v3/domains.json")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	waitForLine(t, lines, "GET /v3/domains.json")

	// Reload picks up a new directory
	if err := saveDirectory(second); err != nil {
		t.Fatal(err)
	}
	if err := reloadDaemon(); err != nil {
		t.Fatal(err)
	}
	if st, _ := getDaemonStatus(); st == nil || st.Directory != second {
		t.Fatalf("after reload: %+v", st)
	}
	if !exists(filepath.Join(second, "global.js")) {
		t.Fatal("reload should prepare the new directory")
	}

	// A bad directory is rejected and the server keeps serving the old one
	os.WriteFile(filepath.Join(root, "file"), nil, 0o644)
	saveDirectory(filepath.Join(root, "file"))
	if err := reloadDaemon(); err == nil {
		t.Fatal("expected reload error")
	}
	if st, _ := getDaemonStatus(); st == nil || st.Directory != second {
		t.Fatalf("after failed reload: %+v", st)
	}

	if err := stopDaemon(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("daemon didn't stop")
	}
}

func waitForLine(t *testing.T, lines <-chan string, want string) {
	t.Helper()
	timeout := time.After(2 * time.Second)
	for {
		select {
		case line := <-lines:
			if strings.Contains(line, want) {
				return
			}
		case <-timeout:
			t.Fatalf("no log line containing %q", want)
		}
	}
}
