package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// enableTLSReload rewires the TLS configs that pgx built during ParseConfig so
// that the database certificates are reloaded from disk per handshake instead of
// being read once and cached for the process lifetime.
//
// pgx's configTLS reads sslrootcert/sslcert/sslkey a single time and bakes the
// results into a static *tls.Config (RootCAs and Certificates) that every pooled
// connection reuses. In a cert-manager / CloudNativePG-style deployment the
// files on disk rotate on their own schedule, so without this the API keeps
// presenting an expired client certificate — and trusting a retired CA — until
// the process restarts.
//
// crypto/tls exposes per-handshake hooks for exactly this:
//   - GetClientCertificate replaces the static client certificate (Go ignores
//     tls.Config.Certificates for client auth once it is set), covering client
//     cert/key rotation for mutual TLS.
//   - There is no GetRootCAs callback, so CA rotation is handled by taking over
//     verification: InsecureSkipVerify is set and VerifyConnection re-reads the
//     CA bundle from disk each handshake. The hostname is verified only when pgx
//     would have (verify-full), mirroring its verify-ca/verify-full distinction.
//
// Both reloaders cache by file mtime so the steady state is a couple of stat
// calls per handshake, not a re-read. Files protected by a password
// (PGSSLPASSWORD/sslpassword) are left on pgx's static path because
// tls.LoadX509KeyPair cannot decrypt them; a warning is logged so the operator
// knows a restart is required to pick up a renewed encrypted key.
func enableTLSReload(cfg *pgconn.Config, databaseURL string) {
	rootcert, cert, key := resolveTLSPaths(databaseURL)

	var clientReload *clientCertReloader
	if cert != "" && key != "" {
		if os.Getenv("PGSSLPASSWORD") != "" || connStringParams(databaseURL)["sslpassword"] != "" {
			slog.Warn("client certificate key is password-protected; automatic reload on rotation is disabled (restart to pick up a renewed client certificate)")
		} else {
			clientReload = &clientCertReloader{certPath: cert, keyPath: key}
		}
	}

	caPath := ""
	// "system" means the OS trust store, which has no single file to reload.
	if rootcert != "" && rootcert != "system" {
		caPath = rootcert
	}

	if clientReload == nil && caPath == "" {
		return
	}

	for _, tc := range allTLSConfigs(cfg) {
		if tc == nil {
			continue
		}

		if clientReload != nil {
			tc.GetClientCertificate = clientReload.getClientCertificate
		}

		// Only take over verification when pgx actually configured a CA to verify
		// against (verify-ca, verify-full, or require-with-rootcert). For
		// require/allow/prefer without a CA there is nothing to reload.
		if caPath != "" && tc.RootCAs != nil {
			// pgx leaves InsecureSkipVerify=false for verify-full (Go verifies the
			// hostname against RootCAs) and =true for verify-ca/require (chain only,
			// no hostname). Preserve that: verify the hostname only when pgx would.
			r := &caCertReloader{caPath: caPath}
			if !tc.InsecureSkipVerify {
				r.serverName = tc.ServerName
			}

			tc.InsecureSkipVerify = true   // we verify the chain ourselves below
			tc.VerifyPeerCertificate = nil // drop pgx's static-pool verifier
			tc.RootCAs = nil               // no longer consulted; avoid confusion
			tc.VerifyConnection = r.verifyConnection
			// ServerName is deliberately left intact so SNI still advertises the
			// right host even though hostname verification now lives in r.
		}
	}

	slog.Info("enabled TLS certificate hot-reload",
		"client_cert", clientReload != nil, "ca", caPath != "")
}

// allTLSConfigs returns the primary TLS config and every fallback's TLS config
// (sslmode=prefer/allow produce fallbacks) so reload hooks cover all of them.
func allTLSConfigs(cfg *pgconn.Config) []*tls.Config {
	configs := []*tls.Config{cfg.TLSConfig}
	for _, fb := range cfg.Fallbacks {
		configs = append(configs, fb.TLSConfig)
	}
	return configs
}

// clientCertReloader serves the mutual-TLS client certificate, reloading the
// cert/key pair from disk whenever either file's mtime changes.
type clientCertReloader struct {
	certPath, keyPath string

	mu      sync.Mutex
	cached  *tls.Certificate
	certMod time.Time
	keyMod  time.Time
}

func (r *clientCertReloader) getClientCertificate(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	certStat, err := os.Stat(r.certPath)
	if err != nil {
		return nil, fmt.Errorf("stat client cert %q: %w", r.certPath, err)
	}
	keyStat, err := os.Stat(r.keyPath)
	if err != nil {
		return nil, fmt.Errorf("stat client key %q: %w", r.keyPath, err)
	}

	if r.cached != nil && certStat.ModTime().Equal(r.certMod) && keyStat.ModTime().Equal(r.keyMod) {
		return r.cached, nil
	}

	pair, err := tls.LoadX509KeyPair(r.certPath, r.keyPath)
	if err != nil {
		return nil, fmt.Errorf("load client cert/key: %w", err)
	}

	r.cached = &pair
	r.certMod = certStat.ModTime()
	r.keyMod = keyStat.ModTime()
	slog.Info("loaded client certificate from disk", "cert", r.certPath)
	return r.cached, nil
}

// caCertReloader verifies the server's certificate chain against a CA bundle
// reloaded from disk whenever the file's mtime changes. A non-empty serverName
// additionally enforces hostname verification (verify-full); empty skips it
// (verify-ca).
type caCertReloader struct {
	caPath     string
	serverName string

	mu     sync.Mutex
	cached *x509.CertPool
	mod    time.Time
}

func (r *caCertReloader) pool() (*x509.CertPool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	stat, err := os.Stat(r.caPath)
	if err != nil {
		return nil, fmt.Errorf("stat CA %q: %w", r.caPath, err)
	}
	if r.cached != nil && stat.ModTime().Equal(r.mod) {
		return r.cached, nil
	}

	pemBytes, err := os.ReadFile(r.caPath)
	if err != nil {
		return nil, fmt.Errorf("read CA %q: %w", r.caPath, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pemBytes) {
		return nil, fmt.Errorf("no certificates found in CA file %q", r.caPath)
	}

	r.cached = pool
	r.mod = stat.ModTime()
	slog.Info("loaded CA certificate from disk", "ca", r.caPath)
	return pool, nil
}

func (r *caCertReloader) verifyConnection(cs tls.ConnectionState) error {
	pool, err := r.pool()
	if err != nil {
		return err
	}
	if len(cs.PeerCertificates) == 0 {
		return errors.New("server presented no certificates")
	}

	opts := x509.VerifyOptions{
		Roots:         pool,
		Intermediates: x509.NewCertPool(),
		DNSName:       r.serverName, // empty => hostname check skipped (verify-ca)
	}
	// Skip the leaf (index 0); the rest are intermediates.
	for _, cert := range cs.PeerCertificates[1:] {
		opts.Intermediates.AddCert(cert)
	}
	_, err = cs.PeerCertificates[0].Verify(opts)
	return err
}

// resolveTLSPaths re-derives the sslrootcert/sslcert/sslkey file paths pgx used,
// following the same precedence libpq does: the ~/.postgresql defaults (only when
// the files exist) are overridden by the PGSSL* environment variables, which are
// in turn overridden by connection-string parameters. pgx discards these paths
// after building its tls.Config, so the reloaders have to recover them here.
func resolveTLSPaths(databaseURL string) (rootcert, cert, key string) {
	if home, err := os.UserHomeDir(); err == nil {
		defaultCert := filepath.Join(home, ".postgresql", "postgresql.crt")
		defaultKey := filepath.Join(home, ".postgresql", "postgresql.key")
		if fileExists(defaultCert) && fileExists(defaultKey) {
			cert, key = defaultCert, defaultKey
		}
		if defaultRoot := filepath.Join(home, ".postgresql", "root.crt"); fileExists(defaultRoot) {
			rootcert = defaultRoot
		}
	}

	if v := os.Getenv("PGSSLROOTCERT"); v != "" {
		rootcert = v
	}
	if v := os.Getenv("PGSSLCERT"); v != "" {
		cert = v
	}
	if v := os.Getenv("PGSSLKEY"); v != "" {
		key = v
	}

	params := connStringParams(databaseURL)
	if v := params["sslrootcert"]; v != "" {
		rootcert = v
	}
	if v := params["sslcert"]; v != "" {
		cert = v
	}
	if v := params["sslkey"]; v != "" {
		key = v
	}

	return rootcert, cert, key
}

// fileExists reports whether path names an existing file (mirrors the os.Stat
// guard pgx uses for its ~/.postgresql defaults).
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// connStringParams extracts the parameters from a libpq connection string,
// supporting both the URL form (postgres://host/db?sslrootcert=...) and the DSN
// keyword/value form (host=... sslrootcert=...). The DSN parser does not handle
// values quoted across spaces; certificate paths in this deployment do not
// contain spaces.
func connStringParams(s string) map[string]string {
	params := map[string]string{}
	s = strings.TrimSpace(s)
	if s == "" {
		return params
	}

	if strings.HasPrefix(s, "postgres://") || strings.HasPrefix(s, "postgresql://") {
		if u, err := url.Parse(s); err == nil {
			for k, vs := range u.Query() {
				if len(vs) > 0 {
					params[k] = vs[len(vs)-1]
				}
			}
		}
		return params
	}

	for _, field := range strings.Fields(s) {
		if k, v, ok := strings.Cut(field, "="); ok {
			params[k] = v
		}
	}
	return params
}
