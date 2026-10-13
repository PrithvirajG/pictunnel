package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/config"
)

func writeTOML(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.toml"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestConfigDefaults(t *testing.T) {
	d := config.Default()
	if d.Upload.MaxFileBytes != 53687091200 || d.Upload.RecommendedChunkBytes != 8388608 ||
		d.Storage.ReserveBytes != 1<<30 || d.Trash.RetentionDays != 30 ||
		d.Server.HTTPSAddr != ":8443" || d.Server.LocalAddr != "127.0.0.1:8080" ||
		d.TLS.Mode != "self-signed" || !d.Discovery.MDNS || !d.RateLimit.Enabled ||
		d.Jobs.Workers != 2 || d.Media.Workers < 1 || d.Log.Level != "info" ||
		d.Clients.MinVersion["ios"] != "0.1.0" || d.Clients.MinVersion["android"] != "0.1.0" || d.Clients.MinVersion["web"] != "0.1.0" {
		t.Fatalf("bad defaults: %+v", d)
	}
}

func TestConfigPrecedence(t *testing.T) {
	dir := writeTOML(t, "[trash]\nretention_days = 10\n[server]\nname = \"fromfile\"\n")
	env := []string{"PICTUNNEL_DATA_DIR=" + dir}
	c, err := config.Load(nil, env)
	if err != nil || c.Trash.RetentionDays != 10 || c.Server.Name != "fromfile" {
		t.Fatalf("toml: %v %+v", err, c.Trash)
	}
	env = append(env, "PICTUNNEL_TRASH_RETENTION_DAYS=20")
	c, err = config.Load(nil, env)
	if err != nil || c.Trash.RetentionDays != 20 {
		t.Fatalf("env: %v %d", err, c.Trash.RetentionDays)
	}
	c, err = config.Load([]string{"--trash.retention-days=30"}, env)
	if err != nil || c.Trash.RetentionDays != 30 {
		t.Fatalf("flag: %v %d", err, c.Trash.RetentionDays)
	}
	c, err = config.Load([]string{"--data-dir=" + dir, "--clients.min-version.ios=1.2.3", "--server.https-addr=:1"}, nil)
	if err != nil || c.Clients.MinVersion["ios"] != "1.2.3" || c.Clients.MinVersion["web"] != "0.1.0" || c.Server.HTTPSAddr != ":1" || c.Trash.RetentionDays != 10 {
		t.Fatalf("flag2: %v %+v", err, c)
	}
	if c.LibraryDir != filepath.Join(dir, "library") {
		t.Fatalf("library dir = %q", c.LibraryDir)
	}
}

func TestConfigValidation(t *testing.T) {
	dir := t.TempDir()
	base := []string{"--data-dir=" + dir}
	for name, extra := range map[string][]string{
		"tls mode":   {"--tls.mode=bogus"},
		"max bytes":  {"--upload.max-file-bytes=0"},
		"files mode": {"--tls.mode=files"},
		"retention":  {"--trash.retention-days=0"},
		"unknown":    {"--nope=1"},
	} {
		if _, err := config.Load(append(append([]string{}, base...), extra...), nil); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
	if _, err := config.Load(base, nil); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
}
