package main

import (
	"bytes"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const nssNickname = "Sprinkles Local CA"

var errNoCertutil = errors.New("certutil not found; install nss (Arch: `pacman -S nss`, Debian/Ubuntu: `apt install libnss3-tools`)")

// nssDatabases finds the NSS certificate databases used by Chromium-based
// browsers and Firefox-based browsers (including Flatpak and Snap installs).
func nssDatabases(create bool) []string {
	home := homeDir()

	chromium := filepath.Join(home, ".pki", "nssdb")
	if create && !exists(filepath.Join(chromium, "cert9.db")) {
		if err := os.MkdirAll(chromium, 0o700); err == nil {
			exec.Command("certutil", "-d", "sql:"+chromium, "-N", "--empty-password").Run()
		}
	}

	patterns := []string{
		filepath.Join(home, ".pki", "nssdb"),
		filepath.Join(home, ".var", "app", "*", ".pki", "nssdb"),
		filepath.Join(home, ".mozilla", "firefox", "*"),
		filepath.Join(home, ".config", "mozilla", "firefox", "*"),
		filepath.Join(home, ".var", "app", "*", ".mozilla", "firefox", "*"),
		filepath.Join(home, "snap", "firefox", "common", ".mozilla", "firefox", "*"),
		filepath.Join(home, ".librewolf", "*"),
		filepath.Join(home, ".zen", "*"),
		filepath.Join(home, ".floorp", "*"),
		filepath.Join(home, ".waterfox", "*"),
	}

	var dbs []string
	for _, pattern := range patterns {
		matches, _ := filepath.Glob(pattern)
		for _, dir := range matches {
			if exists(filepath.Join(dir, "cert9.db")) {
				dbs = append(dbs, dir)
			}
		}
	}
	return dbs
}

type trustResult struct {
	DB  string
	Err error
}

// trustBrowsers adds the CA to every browser certificate database.
func trustBrowsers(certs Certs) ([]trustResult, error) {
	if !certs.HasCA() {
		return nil, fmt.Errorf("no CA found in %s", tildify(certs.dir))
	}
	if _, err := exec.LookPath("certutil"); err != nil {
		return nil, errNoCertutil
	}

	var results []trustResult
	for _, db := range nssDatabases(true) {
		removeFromNSS(db)
		out, err := exec.Command("certutil", "-d", "sql:"+db, "-A", "-t", "C,,", "-n", nssNickname, "-i", certs.CAPath()).CombinedOutput()
		if err != nil {
			err = errors.New(strings.TrimSpace(string(out)))
		}
		results = append(results, trustResult{db, err})
	}
	return results, nil
}

// untrustBrowsers removes the CA from browser certificate databases, returning
// the ones it was removed from.
func untrustBrowsers() ([]string, error) {
	if _, err := exec.LookPath("certutil"); err != nil {
		return nil, errNoCertutil
	}

	var removed []string
	for _, db := range nssDatabases(false) {
		if removeFromNSS(db) {
			removed = append(removed, db)
		}
	}
	return removed, nil
}

// trustedIn counts the browser databases that trust our current CA.
func trustedIn(certs Certs) (trusted, total int) {
	ca, err := certs.CACert()
	if err != nil {
		return 0, 0
	}
	if _, err := exec.LookPath("certutil"); err != nil {
		return 0, 0
	}

	for _, db := range nssDatabases(false) {
		total++
		out, err := exec.Command("certutil", "-d", "sql:"+db, "-L", "-n", nssNickname, "-a").Output()
		if err != nil {
			continue
		}
		for block, rest := pem.Decode(out); block != nil; block, rest = pem.Decode(rest) {
			if bytes.Equal(block.Bytes, ca.Raw) {
				trusted++
				break
			}
		}
	}
	return trusted, total
}

func removeFromNSS(db string) bool {
	removed := false
	// Delete every cert with our nickname, in case of duplicates
	for range 10 {
		if exec.Command("certutil", "-d", "sql:"+db, "-D", "-n", nssNickname).Run() != nil {
			break
		}
		removed = true
	}
	return removed
}

// systemTrustCmd returns a sudo command that adds (or removes) the CA in the
// OS trust store.
func systemTrustCmd(certs Certs, add bool) (*exec.Cmd, error) {
	if _, err := exec.LookPath("trust"); err == nil {
		action := "--store"
		if !add {
			action = "--remove"
		}
		return exec.Command("sudo", "trust", "anchor", action, certs.CAPath()), nil
	}

	if _, err := exec.LookPath("update-ca-certificates"); err == nil {
		const dest = "/usr/local/share/ca-certificates/sprinkles.crt"
		script := fmt.Sprintf("cp %q %s && update-ca-certificates", certs.CAPath(), dest)
		if !add {
			script = fmt.Sprintf("rm -f %s && update-ca-certificates --fresh", dest)
		}
		return exec.Command("sudo", "sh", "-c", script), nil
	}

	return nil, fmt.Errorf("don't know how to update the system trust store here; add %s manually", certs.CAPath())
}
