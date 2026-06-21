package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// ca bundles a self-signed certificate authority used to sign leaf certs in the
// tests below.
type ca struct {
	cert    *x509.Certificate
	key     *ecdsa.PrivateKey
	certPEM []byte
}

func newCA(t *testing.T, commonName string) *ca {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: commonName},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create CA cert: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse CA cert: %v", err)
	}
	return &ca{
		cert:    cert,
		key:     key,
		certPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
	}
}

// signLeaf issues a leaf certificate signed by the CA. dnsName, when set, becomes
// the certificate's SAN (used for server certs that must match a hostname).
func (c *ca) signLeaf(t *testing.T, commonName, dnsName string, isServer bool) (tls.Certificate, []byte, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: commonName},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	if isServer {
		tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	} else {
		tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	}
	if dnsName != "" {
		tmpl.DNSNames = []string{dnsName}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.cert, &key.PublicKey, c.key)
	if err != nil {
		t.Fatalf("create leaf cert: %v", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal leaf key: %v", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatalf("build key pair: %v", err)
	}
	return pair, certPEM, keyPEM
}

// writeFile writes b to path with a mtime bumped past any previous version, so
// the reloaders' mtime cache always sees a rotation as a change even when the
// test runs within a single filesystem-timestamp tick.
func writeFile(t *testing.T, path string, b []byte) {
	t.Helper()
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	future := time.Now().Add(10 * time.Second)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatalf("chtimes %s: %v", path, err)
	}
}

// startTLSServer accepts connections and performs the server side of the
// handshake with the given config, reporting each server-side handshake result
// on a channel. It returns the listener address and a dial helper that reports
// the effective handshake error (nil on success).
//
// Both sides' errors are combined because the failure surfaces on different ends
// depending on what is being rejected: a bad server cert fails the client's
// handshake, while a bad client cert (under TLS 1.3) is verified only after the
// client considers the handshake complete, so it surfaces server-side.
func startTLSServer(t *testing.T, serverCfg *tls.Config) (string, func(clientCfg *tls.Config) error) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	serverErr := make(chan error, 16)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				tconn := tls.Server(conn, serverCfg)
				serverErr <- tconn.Handshake()
				tconn.Close()
			}()
		}
	}()

	dial := func(clientCfg *tls.Config) error {
		raw, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			return err
		}
		defer raw.Close()
		conn := tls.Client(raw, clientCfg)
		defer conn.Close()
		clientErr := conn.Handshake()

		select {
		case sErr := <-serverErr:
			if clientErr != nil {
				return clientErr
			}
			return sErr
		case <-time.After(5 * time.Second):
			t.Fatal("timed out waiting for server handshake result")
			return nil
		}
	}
	return ln.Addr().String(), dial
}

// pgxLikeClientConfig builds the TLS config the way pgx's configTLS would for
// verify-full with mutual TLS: RootCAs loaded from the CA file, ServerName set
// for hostname verification, and the client certificate loaded once. The test
// then runs enableTLSReload over it and asserts rotations are picked up.
func pgxLikeClientConfig(t *testing.T, caPEM, clientCertPEM, clientKeyPEM []byte, serverName string) *tls.Config {
	t.Helper()
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		t.Fatal("append CA")
	}
	cert, err := tls.X509KeyPair(clientCertPEM, clientKeyPEM)
	if err != nil {
		t.Fatalf("client key pair: %v", err)
	}
	return &tls.Config{
		RootCAs:      pool,
		ServerName:   serverName,
		Certificates: []tls.Certificate{cert},
	}
}

func TestEnableTLSReload_CARotation(t *testing.T) {
	dir := t.TempDir()
	caPath := filepath.Join(dir, "ca.crt")
	clientCertPath := filepath.Join(dir, "client.crt")
	clientKeyPath := filepath.Join(dir, "client.key")

	// The server's identity is signed by caB; the client initially trusts only
	// caA. After rotating ca.crt to caB the handshake must verify.
	caA := newCA(t, "ca-A")
	caB := newCA(t, "ca-B")
	serverCert, _, _ := caB.signLeaf(t, "pg-server", "localhost", true)

	// Client cert is not under test here; sign it with caB and trust it on the
	// server so client auth never gets in the way.
	clientPair, clientCertPEM, clientKeyPEM := caB.signLeaf(t, "stats-api", "", false)
	_ = clientPair
	clientCAPool := x509.NewCertPool()
	clientCAPool.AppendCertsFromPEM(caB.certPEM)

	writeFile(t, caPath, caA.certPEM) // start trusting the wrong CA
	writeFile(t, clientCertPath, clientCertPEM)
	writeFile(t, clientKeyPath, clientKeyPEM)

	t.Setenv("PGSSLROOTCERT", caPath)
	t.Setenv("PGSSLCERT", clientCertPath)
	t.Setenv("PGSSLKEY", clientKeyPath)

	serverCfg := &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    clientCAPool,
	}
	addr, dial := startTLSServer(t, serverCfg)
	_ = addr

	// Build a pgx-style config (trusting caA) and install the reloaders.
	clientCfg := pgxLikeClientConfig(t, caA.certPEM, clientCertPEM, clientKeyPEM, "localhost")
	cfg := &pgconn.Config{TLSConfig: clientCfg}
	enableTLSReload(cfg, "")

	if clientCfg.VerifyConnection == nil || clientCfg.GetClientCertificate == nil {
		t.Fatal("expected reload hooks to be installed")
	}
	if !clientCfg.InsecureSkipVerify || clientCfg.RootCAs != nil {
		t.Fatal("expected verification to be taken over by the reloader")
	}

	// With ca.crt still caA, verifying a caB-signed server must fail.
	if err := dial(clientCfg); err == nil {
		t.Fatal("expected handshake to fail while trusting the old CA")
	}

	// Rotate the CA file to caB; a fresh handshake must now succeed without
	// rebuilding the config.
	writeFile(t, caPath, caB.certPEM)
	if err := dial(clientCfg); err != nil {
		t.Fatalf("expected handshake to succeed after CA rotation, got %v", err)
	}
}

func TestEnableTLSReload_ClientCertRotation(t *testing.T) {
	dir := t.TempDir()
	caPath := filepath.Join(dir, "ca.crt")
	clientCertPath := filepath.Join(dir, "client.crt")
	clientKeyPath := filepath.Join(dir, "client.key")

	// Server identity and trust are static. The client cert starts signed by the
	// wrong CA (caOther) and is rotated to one the server trusts (caClient).
	caServer := newCA(t, "server-ca")
	caClient := newCA(t, "client-ca")
	caOther := newCA(t, "other-ca")

	serverCert, _, _ := caServer.signLeaf(t, "pg-server", "localhost", true)
	_, oldCertPEM, oldKeyPEM := caOther.signLeaf(t, "stats-api", "", false)
	_, newCertPEM, newKeyPEM := caClient.signLeaf(t, "stats-api", "", false)

	clientCAPool := x509.NewCertPool()
	clientCAPool.AppendCertsFromPEM(caClient.certPEM)

	writeFile(t, caPath, caServer.certPEM)
	writeFile(t, clientCertPath, oldCertPEM) // start with the untrusted client cert
	writeFile(t, clientKeyPath, oldKeyPEM)

	t.Setenv("PGSSLROOTCERT", caPath)
	t.Setenv("PGSSLCERT", clientCertPath)
	t.Setenv("PGSSLKEY", clientKeyPath)

	serverCfg := &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    clientCAPool,
	}
	_, dial := startTLSServer(t, serverCfg)

	clientCfg := pgxLikeClientConfig(t, caServer.certPEM, oldCertPEM, oldKeyPEM, "localhost")
	cfg := &pgconn.Config{TLSConfig: clientCfg}
	enableTLSReload(cfg, "")

	// The server rejects the caOther-signed client cert.
	if err := dial(clientCfg); err == nil {
		t.Fatal("expected handshake to fail with the untrusted client cert")
	}

	// Rotate the client cert/key to the caClient-signed pair; a fresh handshake
	// must now be accepted.
	writeFile(t, clientCertPath, newCertPEM)
	writeFile(t, clientKeyPath, newKeyPEM)
	if err := dial(clientCfg); err != nil {
		t.Fatalf("expected handshake to succeed after client cert rotation, got %v", err)
	}
}

func TestResolveTLSPaths_Precedence(t *testing.T) {
	t.Setenv("PGSSLROOTCERT", "/env/ca.crt")
	t.Setenv("PGSSLCERT", "/env/client.crt")
	t.Setenv("PGSSLKEY", "/env/client.key")

	// Connection-string parameters override the environment.
	root, cert, key := resolveTLSPaths("postgres://u@h:5432/db?sslrootcert=/url/ca.crt&sslcert=/url/c.crt")
	if root != "/url/ca.crt" || cert != "/url/c.crt" {
		t.Fatalf("connstring should override env: got root=%q cert=%q", root, cert)
	}
	if key != "/env/client.key" {
		t.Fatalf("env should remain for params the URL omits: got key=%q", key)
	}

	// With no connection string, the environment wins.
	root, cert, key = resolveTLSPaths("")
	if root != "/env/ca.crt" || cert != "/env/client.crt" || key != "/env/client.key" {
		t.Fatalf("env fallback wrong: root=%q cert=%q key=%q", root, cert, key)
	}
}
