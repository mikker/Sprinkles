package main

import (
	"crypto/rand"
	"embed"
	"encoding/json"
	"hash/fnv"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

//go:embed static
var staticFiles embed.FS

// Server serves the scripts in dir using the same HTTP API as the macOS app.
type Server struct {
	dir string
	// Log receives a line per request when set
	Log func(string)
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// v3 manifest
	mux.HandleFunc("GET /v3/domains.json", s.handleList)
	mux.HandleFunc("GET /v3/checksum.json", s.handleChecksum)
	mux.HandleFunc("GET /v3/s/", s.handleScripts)
	// v2 manifest/legacy
	mux.HandleFunc("GET /s/", s.handleScriptsLegacy)
	// meta
	mux.HandleFunc("GET /version.json", s.handleVersion)

	static, _ := fs.Sub(staticFiles, "static")
	mux.Handle("GET /", http.FileServerFS(static))

	return s.logRequests(mux)
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.domains())
}

// domains lists the domains that have a .js or .css file, excluding global.
func (s *Server) domains() []string {
	seen := map[string]bool{}
	for _, name := range s.scriptFiles() {
		if strings.HasPrefix(name, "global") {
			continue
		}
		seen[strings.TrimSuffix(strings.TrimSuffix(name, ".js"), ".css")] = true
	}

	domains := make([]string, 0, len(seen))
	for domain := range seen {
		domains = append(domains, domain)
	}
	sort.Strings(domains)
	return domains
}

func (s *Server) handleChecksum(w http.ResponseWriter, r *http.Request) {
	var checksum uint64
	for _, name := range s.scriptFiles() {
		data, err := os.ReadFile(filepath.Join(s.dir, name))
		if err != nil {
			continue
		}
		h := fnv.New64a()
		h.Write([]byte(name))
		h.Write([]byte{0})
		h.Write(data)
		checksum ^= h.Sum64()
	}

	// Keep within JavaScript's safe integer range
	writeJSON(w, map[string]uint64{"checksum": checksum & (1<<53 - 1)})
}

func (s *Server) handleScripts(w http.ResponseWriter, r *http.Request) {
	domain, ok := parseDomain(r.URL.Path)
	if !ok {
		writeJS(w, http.StatusUnprocessableEntity, "console.log('Failed parsing domain')")
		return
	}

	writeJS(w, http.StatusOK, s.compileSet(domain))
}

func (s *Server) handleScriptsLegacy(w http.ResponseWriter, r *http.Request) {
	domain, ok := parseDomain(r.URL.Path)
	if !ok {
		writeJS(w, http.StatusUnprocessableEntity, "console.log('Failed parsing domain')")
		return
	}

	writeJS(w, http.StatusOK, s.compileSet("global")+s.compileSet(domain))
}

func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"version": version, "build": buildNumber()})
}

// scriptFiles lists the .js and .css files in the scripts directory.
func (s *Server) scriptFiles() []string {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil
	}

	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if entry.Type().IsDir() {
			continue
		}
		if strings.HasSuffix(name, ".js") || strings.HasSuffix(name, ".css") {
			names = append(names, name)
		}
	}
	return names
}

func (s *Server) compileSet(base string) string {
	javascript := s.tryReading(base + ".js")
	if css := s.tryReading(base + ".css"); css != "" {
		javascript += injectStyleElement(base, css)
	}
	return javascript
}

func (s *Server) tryReading(name string) string {
	data, err := os.ReadFile(filepath.Join(s.dir, name))
	if err != nil {
		if !os.IsNotExist(err) && s.Log != nil {
			s.Log(err.Error())
		}
		return ""
	}
	return string(data)
}

// parseDomain extracts "example.com" from paths like "/s/example.com.js".
func parseDomain(path string) (string, bool) {
	i := strings.Index(path, "/s/")
	if i < 0 || !strings.HasSuffix(path, ".js") {
		return "", false
	}
	domain := strings.TrimSuffix(path[i+3:], ".js")
	if domain == "" || strings.ContainsAny(domain, `/\`) || strings.HasPrefix(domain, ".") {
		return "", false
	}
	return domain, true
}

func injectStyleElement(label, css string) string {
	fnName := "_SprinklesInjectStyles_" + randomChars(8)
	css = escapeTemplateLiteral(css)

	return ";function " + fnName + `() {
  console.groupCollapsed("Injecting Sprinkles styles (` + label + `)");
  console.log(` + "`" + css + "`" + `);
  console.groupEnd();

  var d = document;
  var e = d.createElement('style');
  e.dataset.sprinklesInjected = 1;

  var content = ` + "`" + css + "`" + `;
  if (window.trustedTypes && trustedTypes.createPolicy) {
    const escapeHTMLPolicy = trustedTypes.createPolicy("myEscapePolicy", {
      createHTML: (content) => content.replace(/\</g, "&lt;"),
    });

    content = escapeHTMLPolicy.createHTML(content);
  }

  e.innerHTML = content;
  d.body.appendChild(e);
};
` + fnName + "();"
}

// escapeTemplateLiteral makes css safe to embed in a JS `template literal`,
// so backslashes (eg. `content: "\201C"`), backticks and ${ survive as-is.
func escapeTemplateLiteral(s string) string {
	return strings.NewReplacer(`\`, `\\`, "`", "\\`", "${", "\\${").Replace(s)
}

func randomChars(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	rand.Read(b)
	for i := range b {
		b[i] = chars[int(b[i])%len(chars)]
	}
	return string(b)
}

func writeJS(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.WriteHeader(status)
	w.Write([]byte(body))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.Log != nil {
			s.Log(r.Method + " " + r.URL.Path)
		}
		next.ServeHTTP(w, r)
	})
}
