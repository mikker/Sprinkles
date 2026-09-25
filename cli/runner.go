package main

import (
	"context"
	"crypto/tls"
	"errors"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Runner is a running Sprinkles HTTP(S) server.
type Runner struct {
	srv  *http.Server
	done chan error
}

// startServer serves dir on host:port, over HTTPS when tlsConfig is set.
// requestLog receives a line per request (optional); errorLog receives server
// errors such as TLS handshake failures.
func startServer(dir, host string, port int, tlsConfig *tls.Config, requestLog, errorLog func(string)) (*Runner, error) {
	listeners, err := listen(host, port)
	if err != nil {
		return nil, err
	}

	srv := &http.Server{
		Handler:           (&Server{dir: dir, Log: requestLog}).Handler(),
		TLSConfig:         tlsConfig,
		ReadHeaderTimeout: 10 * time.Second,
		ErrorLog:          log.New(logWriter(errorLog), "", 0),
	}

	r := &Runner{srv: srv, done: make(chan error, len(listeners))}
	for _, l := range listeners {
		go func() {
			var err error
			if tlsConfig != nil {
				err = srv.ServeTLS(l, "", "")
			} else {
				err = srv.Serve(l)
			}
			if errors.Is(err, http.ErrServerClosed) {
				err = nil
			}
			r.done <- err
		}()
	}
	return r, nil
}

// Done receives an error if the server stops unexpectedly.
func (r *Runner) Done() <-chan error { return r.done }

func (r *Runner) Stop() error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return r.srv.Shutdown(ctx)
}

// listen binds both IPv4 and IPv6 loopback for "localhost", since browsers
// may resolve localhost to either.
func listen(host string, port int) ([]net.Listener, error) {
	hosts := []string{host}
	if host == "localhost" {
		hosts = []string{"127.0.0.1", "::1"}
	}

	var listeners []net.Listener
	var errs []error
	for _, h := range hosts {
		l, err := net.Listen("tcp", net.JoinHostPort(h, strconv.Itoa(port)))
		if err != nil {
			errs = append(errs, err)
			continue
		}
		listeners = append(listeners, l)
	}
	if len(listeners) == 0 {
		return nil, errors.Join(errs...)
	}
	return listeners, nil
}

// probe reports whether something answers like Sprinkles on the port.
func probe(port int) bool {
	client := &http.Client{
		Timeout:   500 * time.Millisecond,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
	}
	for _, scheme := range []string{"https", "http"} {
		resp, err := client.Get(scheme + "://localhost:" + strconv.Itoa(port) + "/version.json")
		if err == nil {
			resp.Body.Close()
			return resp.StatusCode == http.StatusOK
		}
	}
	return false
}

// logWriter adapts a line logger to http.Server's ErrorLog.
type logWriter func(string)

func (f logWriter) Write(p []byte) (int, error) {
	if f != nil {
		f(strings.TrimSpace(string(p)))
	}
	return len(p), nil
}
