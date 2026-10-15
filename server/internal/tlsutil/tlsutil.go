// Package tlsutil creates and loads the server's TLS material: a local CA and
// a leaf whose key (and therefore SPKI pin) is stable across renewals (S§5.1).
// It imports no domain package.
package tlsutil

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	caLifetime    = 10 * 365 * 24 * time.Hour
	leafLifetime  = 825 * 24 * time.Hour
	renewWindow   = 30 * 24 * time.Hour
	backdate      = time.Hour
	caNameFormat  = "PicTunnel Local CA %s"
	leafCommonFmt = "PicTunnel Server %s"
)

// Material is a ready-to-serve certificate plus its pin.
type Material struct {
	Cert  tls.Certificate
	Leaf  *x509.Certificate
	CAPEM []byte
	// SPKIFingerprint is the unpadded base64url SHA-256 of the leaf's SPKI.
	SPKIFingerprint string
	// CARegenerated is true when an existing CA (cert or key file present)
	// was unusable or expiring and has been replaced. Clients that installed
	// the old CA must re-trust; the leaf pin is unchanged.
	CARegenerated bool
}

// SPKIFingerprint returns the unpadded base64url SHA-256 of cert's SubjectPublicKeyInfo.
func SPKIFingerprint(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// LoadFiles loads a user-supplied certificate and key.
func LoadFiles(certFile, keyFile string) (*Material, error) {
	pair, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, err
	}
	pair.Leaf = leaf
	return &Material{Cert: pair, Leaf: leaf, SPKIFingerprint: SPKIFingerprint(leaf)}, nil
}

// LocalIPs returns the addresses of up, non-loopback interfaces.
func LocalIPs() ([]net.IP, error) {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var out []net.IP
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && !n.IP.IsLoopback() {
				out = append(out, n.IP)
			}
		}
	}
	return out, nil
}

// EnsureSelfSigned makes sure dir holds ca.{crt,key} and server.{crt,key}.
// The leaf is regenerated (with the SAME key) when it expires within 30 days,
// when it does not cover every host/IP, or when it no longer verifies against
// the CA. Nothing is written when everything is already valid.
func EnsureSelfSigned(dir, serverID string, hosts []string, ips []net.IP, now time.Time) (*Material, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	short := serverID
	if len(short) > 8 {
		short = short[:8]
	}
	dns, ipList := wantedSANs(hosts, ips)

	caCert, caKey, caPEM, caNew, err := ensureCA(dir, short, now)
	if err != nil {
		return nil, err
	}
	leafKey, err := ensureLeafKey(dir)
	if err != nil {
		return nil, err
	}

	crtPath := filepath.Join(dir, "server.crt")
	leaf := loadCert(crtPath)
	if leaf == nil || !leafOK(leaf, leafKey, caCert, dns, ipList, now) {
		der, err := signLeaf(short, dns, ipList, leafKey, caCert, caKey, now)
		if err != nil {
			return nil, err
		}
		if err := writeAtomic(crtPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
			return nil, err
		}
		if leaf, err = x509.ParseCertificate(der); err != nil {
			return nil, err
		}
	}
	return &Material{
		Cert: tls.Certificate{Certificate: [][]byte{leaf.Raw}, PrivateKey: leafKey, Leaf: leaf},
		Leaf: leaf, CAPEM: caPEM, SPKIFingerprint: SPKIFingerprint(leaf), CARegenerated: caNew,
	}, nil
}

func wantedSANs(hosts []string, ips []net.IP) ([]string, []net.IP) {
	seenD := map[string]bool{}
	var dns []string
	for _, h := range append([]string{"localhost"}, hosts...) {
		if h != "" && !seenD[h] {
			seenD[h] = true
			dns = append(dns, h)
		}
	}
	seenI := map[string]bool{}
	var out []net.IP
	for _, i := range append(append([]net.IP{}, ips...), net.ParseIP("127.0.0.1"), net.IPv6loopback) {
		if i != nil && !seenI[i.String()] {
			seenI[i.String()] = true
			out = append(out, i)
		}
	}
	return dns, out
}

func leafOK(leaf *x509.Certificate, key *ecdsa.PrivateKey, ca *x509.Certificate, dns []string, ips []net.IP, now time.Time) bool {
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || !pub.Equal(&key.PublicKey) {
		return false
	}
	if leaf.CheckSignatureFrom(ca) != nil {
		return false
	}
	if now.Add(renewWindow).After(leaf.NotAfter) || now.Before(leaf.NotBefore) {
		return false
	}
	have := map[string]bool{}
	for _, d := range leaf.DNSNames {
		have[d] = true
	}
	for _, d := range dns {
		if !have[d] {
			return false
		}
	}
	for _, want := range ips {
		found := false
		for _, i := range leaf.IPAddresses {
			if i.Equal(want) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func signLeaf(short string, dns []string, ips []net.IP, key *ecdsa.PrivateKey, ca *x509.Certificate, caKey *ecdsa.PrivateKey, now time.Time) ([]byte, error) {
	serial, err := newSerial()
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: fmt.Sprintf(leafCommonFmt, short)},
		NotBefore:             now.Add(-backdate),
		NotAfter:              now.Add(leafLifetime),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              dns,
		IPAddresses:           ips,
	}
	return x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
}

// ensureCA loads the CA or creates a new one. replaced reports that a CA
// file existed but was replaced.
func ensureCA(dir, short string, now time.Time) (cert *x509.Certificate, key *ecdsa.PrivateKey, pemOut []byte, replaced bool, err error) {
	crtPath, keyPath := filepath.Join(dir, "ca.crt"), filepath.Join(dir, "ca.key")
	cert, key = loadCert(crtPath), loadKey(keyPath)
	if cert != nil && key != nil && cert.NotAfter.After(now.Add(renewWindow)) {
		if pub, ok := cert.PublicKey.(*ecdsa.PublicKey); ok && pub.Equal(&key.PublicKey) {
			b, err := os.ReadFile(crtPath)
			if err != nil {
				return nil, nil, nil, false, err
			}
			return cert, key, b, false, nil
		}
	}
	replaced = fileExists(crtPath) || fileExists(keyPath)
	key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, nil, false, err
	}
	serial, err := newSerial()
	if err != nil {
		return nil, nil, nil, false, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: fmt.Sprintf(caNameFormat, short)},
		NotBefore:             now.Add(-backdate),
		NotAfter:              now.Add(caLifetime),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, nil, false, err
	}
	cert, err = x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, nil, false, err
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	// Key first: a crash between the writes leaves a key without a cert, which is regenerated.
	if err := writeKey(keyPath, key); err != nil {
		return nil, nil, nil, false, err
	}
	if err := writeAtomic(crtPath, pemBytes, 0o644); err != nil {
		return nil, nil, nil, false, err
	}
	return cert, key, pemBytes, replaced, nil
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func ensureLeafKey(dir string) (*ecdsa.PrivateKey, error) {
	path := filepath.Join(dir, "server.key")
	if k := loadKey(path); k != nil {
		return k, nil
	}
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return k, writeKey(path, k)
}

func writeKey(path string, k *ecdsa.PrivateKey) error {
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		return err
	}
	return writeAtomic(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
}

func loadCert(path string) *x509.Certificate {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil
	}
	c, err := x509.ParseCertificate(blk.Bytes)
	if err != nil {
		return nil
	}
	return c
}

func loadKey(path string) *ecdsa.PrivateKey {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil
	}
	ek, _ := k.(*ecdsa.PrivateKey)
	return ek
}

func newSerial() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
}

// writeAtomic writes data to a temp file in the same directory, then renames it.
func writeAtomic(path string, data []byte, perm os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	fail := func(err error) error {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Chmod(perm); err != nil {
		return fail(err)
	}
	if _, err := f.Write(data); err != nil {
		return fail(err)
	}
	if err := f.Sync(); err != nil {
		return fail(err)
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
