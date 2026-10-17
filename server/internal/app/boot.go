package app

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
	"github.com/PrithvirajG/pictunnel/server/internal/tlsutil"
)

const (
	lockFileName   = "pictunnel.lock"
	dbFileName     = "pictunnel.db"
	secretFileName = "secret.key"
	secretLen      = 32
	serverIDKey    = "server_id"
)

// acquireLock takes the exclusive data-dir lock (S§10.1 step 2).
func acquireLock(dataDir string) (*os.File, error) {
	p := filepath.Join(dataDir, lockFileName)
	f, err := os.OpenFile(p, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock file %s: %w", p, err)
	}
	if err := tryLock(f); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("another pictunnel instance is using data dir %s (lock %s is held): %w", dataDir, p, err)
	}
	_ = f.Truncate(0)
	_, _ = f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0)
	return f, nil
}

// openStore opens the database, runs quick_check and migrates, backing up
// an existing database first when migrations are pending (S§10.1 steps 3–4).
func openStore(ctx context.Context, dataDir string, now time.Time) (*store.Store, error) {
	path := filepath.Join(dataDir, dbFileName)
	_, statErr := os.Stat(path)
	existed := statErr == nil
	damaged := func(err error) error {
		return fmt.Errorf("%w\nThe database %s is damaged. Stop here and restore it: copy the newest file from %s over it (keep the damaged one aside), then start again", err, path, filepath.Join(dataDir, "backups"))
	}
	st, err := store.Open(ctx, path)
	if err != nil {
		if existed {
			return nil, damaged(err)
		}
		return nil, err
	}
	if err := st.QuickCheck(ctx); err != nil {
		_ = st.Close()
		return nil, damaged(err)
	}
	pending, err := st.PendingMigrations(ctx)
	if err != nil {
		_ = st.Close()
		return nil, err
	}
	if pending {
		if existed {
			dir := filepath.Join(dataDir, "backups")
			if err := os.MkdirAll(dir, 0o700); err != nil {
				_ = st.Close()
				return nil, err
			}
			dst := filepath.Join(dir, "pre-migrate-"+now.UTC().Format("20060102T150405Z")+".db")
			if err := st.BackupTo(ctx, dst); err != nil {
				_ = st.Close()
				return nil, fmt.Errorf("backup before migration: %w", err)
			}
		}
		if err := st.Migrate(ctx); err != nil {
			_ = st.Close()
			return nil, err
		}
	}
	return st, nil
}

// loadSecret reads <data>/secret.key or creates it once: 32 random bytes,
// mode 0600.
func loadSecret(dataDir string) ([]byte, error) {
	p := filepath.Join(dataDir, secretFileName)
	b, err := os.ReadFile(p)
	if err == nil {
		if len(b) != secretLen {
			return nil, fmt.Errorf("%s is %d bytes, want %d; restore it from a backup (deleting it logs every device out)", p, len(b), secretLen)
		}
		return b, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	b = make([]byte, secretLen)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return nil, err
	}
	tmp := p + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, err
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return nil, err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return nil, err
	}
	if err := f.Close(); err != nil {
		return nil, err
	}
	if err := os.Rename(tmp, p); err != nil {
		return nil, err
	}
	return b, nil
}

// loadServerID reads server_state.server_id or generates it once.
func loadServerID(ctx context.Context, st *store.Store) (string, error) {
	var id string
	err := st.WithTx(ctx, func(tx *sql.Tx) error {
		ss := repository.ServerStateRepository{}
		v, ok, err := ss.Get(ctx, tx, serverIDKey)
		if err != nil {
			return err
		}
		if ok && v != "" {
			id = v
			return nil
		}
		id = ids.New()
		return ss.Set(ctx, tx, serverIDKey, id)
	})
	return id, err
}

// FilterIPs drops loopback, IPv6 link-local and IPv4 link-local
// (169.254/16) addresses: they are useless in a certificate SAN or a
// pairing endpoint for another device.
func FilterIPs(ips []net.IP) []net.IP {
	var out []net.IP
	for _, ip := range ips {
		if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast() {
			continue
		}
		out = append(out, ip)
	}
	return out
}

// localIPs returns the filtered interface addresses (none on error).
func localIPs() []net.IP {
	ips, err := tlsutil.LocalIPs()
	if err != nil {
		return nil
	}
	return FilterIPs(ips)
}

// PairingEndpoints builds the qr_uri endpoints (S§4.3): LAN entries
// https://<ip>:<port> first (only when the server terminates TLS itself),
// then the configured public URLs; empty values and duplicates are
// dropped. It is never empty: https://localhost:<port> is the fallback.
func PairingEndpoints(ips []net.IP, port int, publicURLs []string, tlsOn bool) []string {
	var out []string
	seen := map[string]bool{}
	add := func(u string) {
		u = strings.TrimSpace(u)
		if u != "" && !seen[u] {
			seen[u] = true
			out = append(out, u)
		}
	}
	if tlsOn {
		for _, ip := range ips {
			add("https://" + net.JoinHostPort(ip.String(), strconv.Itoa(port)))
		}
	}
	for _, u := range publicURLs {
		add(strings.TrimRight(strings.TrimSpace(u), "/"))
	}
	if len(out) == 0 {
		out = append(out, "https://"+net.JoinHostPort("localhost", strconv.Itoa(port)))
	}
	return out
}

// addrPort returns the port of a listen address like ":8443" (8443 when
// it cannot be parsed or is 0).
func addrPort(addr string) int {
	_, p, err := net.SplitHostPort(addr)
	if err != nil {
		return 8443
	}
	n, err := strconv.Atoi(p)
	if err != nil || n <= 0 {
		return 8443
	}
	return n
}

// tlsHosts are the DNS SANs of the self-signed leaf.
func tlsHosts() []string {
	hosts := []string{"localhost"}
	if h, err := os.Hostname(); err == nil && h != "" {
		h = strings.ToLower(strings.TrimSuffix(h, "."))
		hosts = append(hosts, h)
		if !strings.HasSuffix(h, ".local") {
			hosts = append(hosts, h+".local")
		}
	}
	return hosts
}

// reenqueueMedia re-enqueues (deduped) the media jobs of assets whose
// derived data is incomplete: generate_thumbnails when thumbnails are not
// ready, extract_metadata for a video whose playability is unknown, and
// transcode_video for a non-playable video without web.mp4. It recovers
// jobs that went dead, e.g. while ffmpeg was missing.
func (a *App) reenqueueMedia(ctx context.Context) error {
	pending, err := repository.AssetsRepository{}.ListMediaPending(ctx, a.st.R)
	if err != nil {
		return err
	}
	n := 0
	for _, m := range pending {
		payload, _ := json.Marshal(map[string]string{"asset_id": m.ID})
		var kinds []string
		if !m.ThumbnailsReady {
			kinds = append(kinds, service.JobGenerateThumbnails)
		}
		if m.Kind == "video" {
			switch {
			case m.Playable == nil:
				kinds = append(kinds, service.JobExtractMetadata)
			case !*m.Playable:
				web := filepath.Join(a.cfg.DataDir, "derived", m.ID[0:2], m.ID[2:4], m.ID, "web.mp4")
				if _, err := os.Stat(web); err != nil {
					kinds = append(kinds, service.JobTranscodeVideo)
				}
			}
		}
		for _, k := range kinds {
			if err := a.runner.Enqueue(ctx, a.st.W, k, m.ID, payload, time.Time{}); err != nil {
				return err
			}
			n++
		}
	}
	if n > 0 {
		a.log.Info("boot: re-enqueued media jobs", "jobs", n)
	}
	return nil
}
