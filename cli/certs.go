package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Certs is a local root CA plus a localhost certificate signed by it.
// Trusting the CA in the browser lets extensions reach https://localhost:3133.
type Certs struct {
	dir string
}

func (c Certs) CAPath() string                     { return filepath.Join(c.dir, "ca.pem") }
func (c Certs) CAKeyPath() string                  { return filepath.Join(c.dir, "ca-key.pem") }
func (c Certs) CertPath() string                   { return filepath.Join(c.dir, "cert.pem") }
func (c Certs) KeyPath() string                    { return filepath.Join(c.dir, "key.pem") }
func (c Certs) HasCA() bool                        { return exists(c.CAPath()) && exists(c.CAKeyPath()) }
func (c Certs) CACert() (*x509.Certificate, error) { return readCert(c.CAPath()) }

// Ensure creates the CA if missing and (re)issues the localhost certificate
// when it's missing or about to expire. Returns true if a new CA was created.
func (c Certs) Ensure() (bool, error) {
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		return false, err
	}

	created := false
	if !c.HasCA() {
		if err := c.generateCA(); err != nil {
			return false, fmt.Errorf("generating CA: %w", err)
		}
		created = true
	}

	leaf, err := readCert(c.CertPath())
	if created || err != nil || !exists(c.KeyPath()) || time.Until(leaf.NotAfter) < 30*24*time.Hour {
		if err := c.generateLeaf(); err != nil {
			return created, fmt.Errorf("generating certificate: %w", err)
		}
	}

	return created, nil
}

func (c Certs) TLSConfig() (*tls.Config, error) {
	pair, err := tls.LoadX509KeyPair(c.CertPath(), c.KeyPath())
	if err != nil {
		return nil, err
	}
	return &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}, nil
}

func (c Certs) generateCA() error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	hostname, _ := os.Hostname()
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: randomSerial(),
		Subject: pkix.Name{
			CommonName:         "Sprinkles Local CA",
			Organization:       []string{"Sprinkles"},
			OrganizationalUnit: []string{os.Getenv("USER") + "@" + hostname},
		},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLenZero:        true,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return err
	}
	if err := writeKey(c.CAKeyPath(), key); err != nil {
		return err
	}
	return writePEM(c.CAPath(), "CERTIFICATE", der, 0o644)
}

func (c Certs) generateLeaf() error {
	ca, err := c.CACert()
	if err != nil {
		return err
	}
	caKey, err := readKey(c.CAKeyPath())
	if err != nil {
		return err
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: randomSerial(),
		Subject:      pkix.Name{CommonName: "localhost", Organization: []string{"Sprinkles"}},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.AddDate(0, 0, 825),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
	if err != nil {
		return err
	}
	if err := writeKey(c.KeyPath(), key); err != nil {
		return err
	}
	return writePEM(c.CertPath(), "CERTIFICATE", der, 0o644)
}

func randomSerial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	return n
}

func writeKey(path string, key *ecdsa.PrivateKey) error {
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	return writePEM(path, "PRIVATE KEY", der, 0o600)
}

func writePEM(path, typ string, der []byte, perm os.FileMode) error {
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}), perm)
}

func readPEM(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("no PEM data in " + path)
	}
	return block.Bytes, nil
}

func readCert(path string) (*x509.Certificate, error) {
	der, err := readPEM(path)
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

func readKey(path string) (any, error) {
	der, err := readPEM(path)
	if err != nil {
		return nil, err
	}
	return x509.ParsePKCS8PrivateKey(der)
}
