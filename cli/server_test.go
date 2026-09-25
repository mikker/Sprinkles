package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func newTestServer(t *testing.T, files map[string]string) (*httptest.Server, string) {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ts := httptest.NewServer((&Server{dir: dir}).Handler())
	t.Cleanup(ts.Close)
	return ts, dir
}

func get(t *testing.T, url string) (int, http.Header, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, string(body)
}

func TestDomains(t *testing.T) {
	ts, _ := newTestServer(t, map[string]string{
		"global.js":       "",
		"global.css":      "",
		"example.com.js":  "",
		"example.com.css": "",
		"a.test.css":      "",
		"notes.txt":       "",
	})

	status, header, body := get(t, ts.URL+"/v3/domains.json")
	if status != 200 || header.Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("status=%d headers=%v", status, header)
	}
	var domains []string
	json.Unmarshal([]byte(body), &domains)
	if strings.Join(domains, ",") != "a.test,example.com" {
		t.Fatalf("got %v", domains)
	}
}

func TestScripts(t *testing.T) {
	ts, _ := newTestServer(t, map[string]string{
		"global.js":       "console.log('global');",
		"example.com.js":  "console.log('example');",
		"example.com.css": "p::before { content: \"\\201C\"; } /* `${x}` */",
	})

	_, header, body := get(t, ts.URL+"/v3/s/example.com.js")
	if header.Get("Content-Type") != "text/javascript; charset=utf-8" {
		t.Fatalf("content-type %q", header.Get("Content-Type"))
	}
	if !strings.HasPrefix(body, "console.log('example');;function _SprinklesInjectStyles_") {
		t.Fatalf("unexpected body: %s", body)
	}
	if strings.Contains(body, "global") {
		t.Fatal("v3 scripts should not include global")
	}

	// The injected CSS must evaluate back to the original, if node is around
	if node, err := exec.LookPath("node"); err == nil {
		script := "var document={createElement:()=>({dataset:{}}),body:{appendChild:e=>{globalThis.out=e.innerHTML}}};" +
			"console.groupCollapsed=console.log=console.groupEnd=()=>{};var window={};" +
			body + ";process.stdout.write(globalThis.out)"
		out, err := exec.Command(node, "-e", script).CombinedOutput()
		if err != nil {
			t.Fatalf("node: %v\n%s", err, out)
		}
		if want := "p::before { content: \"\\201C\"; } /* `${x}` */"; string(out) != want {
			t.Fatalf("css roundtrip: got %q want %q", out, want)
		}
	}

	_, _, legacy := get(t, ts.URL+"/s/example.com.js")
	if !strings.HasPrefix(legacy, "console.log('global');console.log('example');") {
		t.Fatalf("legacy should prepend global: %s", legacy)
	}

	_, _, missing := get(t, ts.URL+"/v3/s/nothing.here.js")
	if missing != "" {
		t.Fatalf("expected empty body, got %q", missing)
	}
}

func TestScriptsRejectsTraversal(t *testing.T) {
	ts, _ := newTestServer(t, nil)
	status, _, _ := get(t, ts.URL+"/v3/s/..%2F..%2Fsecret.js")
	if status != http.StatusUnprocessableEntity {
		t.Fatalf("got status %d", status)
	}
}

func TestChecksumChanges(t *testing.T) {
	ts, dir := newTestServer(t, map[string]string{"global.js": "a"})

	checksum := func() float64 {
		_, _, body := get(t, ts.URL+"/v3/checksum.json")
		var v map[string]float64
		json.Unmarshal([]byte(body), &v)
		return v["checksum"]
	}

	first := checksum()
	if first != checksum() {
		t.Fatal("checksum not stable")
	}
	os.WriteFile(filepath.Join(dir, "example.com.css"), nil, 0o644)
	second := checksum()
	if second == first {
		t.Fatal("checksum should change when a file is added")
	}
	os.WriteFile(filepath.Join(dir, "global.js"), []byte("b"), 0o644)
	if checksum() == second {
		t.Fatal("checksum should change when a file changes")
	}
}

func TestVersionAndStatic(t *testing.T) {
	ts, _ := newTestServer(t, nil)

	_, _, body := get(t, ts.URL+"/version.json")
	var v struct {
		Version string
		Build   int
	}
	json.Unmarshal([]byte(body), &v)
	// The extensions require build >= 105
	if v.Version != version || v.Build < 105 {
		t.Fatalf("got %+v", v)
	}

	status, _, index := get(t, ts.URL+"/")
	if status != 200 || !strings.Contains(index, "Sprinkles is ready to serve") {
		t.Fatalf("index: %d", status)
	}
	if status, _, _ := get(t, ts.URL+"/logo.png"); status != 200 {
		t.Fatalf("logo: %d", status)
	}
}

func TestCertsVerifyForLocalhost(t *testing.T) {
	certs := Certs{dir: t.TempDir()}
	created, err := certs.Ensure()
	if err != nil || !created {
		t.Fatalf("created=%v err=%v", created, err)
	}
	if created, _ := certs.Ensure(); created {
		t.Fatal("CA should be reused")
	}

	tlsConfig, err := certs.TLSConfig()
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewUnstartedServer((&Server{dir: t.TempDir()}).Handler())
	ts.TLS = tlsConfig
	ts.StartTLS()
	defer ts.Close()

	ca, _ := certs.CACert()
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}

	url := strings.Replace(ts.URL, "127.0.0.1", "localhost", 1) + "/version.json"
	resp, err := client.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
}
