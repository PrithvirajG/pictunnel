// Package config loads and validates server configuration.
//
// Precedence (highest first): command-line flags, environment variables
// PICTUNNEL_<SECTION>_<KEY>, <data_dir>/config.toml, defaults.
package config

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// Config is the full server configuration.
type Config struct {
	DataDir    string `toml:"data_dir"`
	LibraryDir string `toml:"library_dir"`
	Server     struct {
		Name       string   `toml:"name"`
		HTTPSAddr  string   `toml:"https_addr"`
		LocalAddr  string   `toml:"local_addr"`
		PublicURLs []string `toml:"public_urls"`
	} `toml:"server"`
	TLS struct {
		Mode     string `toml:"mode"` // self-signed|files|off
		CertFile string `toml:"cert_file"`
		KeyFile  string `toml:"key_file"`
	} `toml:"tls"`
	Discovery struct {
		MDNS bool `toml:"mdns"`
	} `toml:"discovery"`
	Upload struct {
		MaxFileBytes          int64 `toml:"max_file_bytes"`
		RecommendedChunkBytes int64 `toml:"recommended_chunk_bytes"`
	} `toml:"upload"`
	Storage struct {
		ReserveBytes int64 `toml:"reserve_bytes"`
	} `toml:"storage"`
	Trash struct {
		RetentionDays int `toml:"retention_days"`
	} `toml:"trash"`
	Clients struct {
		MinVersion map[string]string `toml:"min_version"` // android, ios, web
	} `toml:"clients"`
	RateLimit struct {
		Enabled bool `toml:"enabled"`
	} `toml:"rate_limit"`
	Media struct {
		FFmpegPath  string `toml:"ffmpeg_path"`
		FFprobePath string `toml:"ffprobe_path"`
		Workers     int    `toml:"workers"`
	} `toml:"media"`
	Jobs struct {
		Workers int `toml:"workers"`
	} `toml:"jobs"`
	Log struct {
		Level  string `toml:"level"`
		Format string `toml:"format"`
	} `toml:"log"`
}

// defaultDataDir picks the OS-specific application data directory.
func defaultDataDir() string {
	if _, err := os.Stat("/.dockerenv"); err == nil {
		return "/data"
	}
	switch runtime.GOOS {
	case "windows":
		pd := os.Getenv("ProgramData")
		if pd == "" {
			pd = `C:\ProgramData`
		}
		return filepath.Join(pd, "PicTunnel")
	case "darwin":
		home, err := os.UserHomeDir()
		if err != nil {
			home = "."
		}
		return filepath.Join(home, "Library", "Application Support", "PicTunnel")
	default:
		return "/var/lib/pictunnel"
	}
}

func stdoutIsTTY() bool {
	fi, err := os.Stdout.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// Default returns the configuration used when nothing is set.
func Default() Config {
	var c Config
	c.DataDir = defaultDataDir()
	c.LibraryDir = filepath.Join(c.DataDir, "library")
	c.Server.Name, _ = os.Hostname()
	c.Server.HTTPSAddr = ":8443"
	c.Server.LocalAddr = "127.0.0.1:8080"
	c.Server.PublicURLs = []string{}
	c.TLS.Mode = "self-signed"
	c.Discovery.MDNS = true
	c.Upload.MaxFileBytes = 53687091200 // 50 GiB
	c.Upload.RecommendedChunkBytes = 8 << 20
	c.Storage.ReserveBytes = 1 << 30
	c.Trash.RetentionDays = 30
	c.Clients.MinVersion = map[string]string{"android": "0.1.0", "ios": "0.1.0", "web": "0.1.0"}
	c.RateLimit.Enabled = true
	c.Media.Workers = max(1, runtime.NumCPU()/2)
	c.Jobs.Workers = 2
	c.Log.Level = "info"
	c.Log.Format = "json"
	if stdoutIsTTY() {
		c.Log.Format = "text"
	}
	return c
}

// field binds a dotted config key to a setter parsing its string form.
type field struct {
	key string
	set func(string) error
}

func strF(key string, p *string) field {
	return field{key, func(s string) error { *p = s; return nil }}
}

func i64F(key string, p *int64) field {
	return field{key, func(s string) error {
		v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
		*p = v
		return nil
	}}
}

func intF(key string, p *int) field {
	return field{key, func(s string) error {
		v, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
		*p = v
		return nil
	}}
}

func boolF(key string, p *bool) field {
	return field{key, func(s string) error {
		v, err := strconv.ParseBool(strings.TrimSpace(s))
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
		*p = v
		return nil
	}}
}

func listF(key string, p *[]string) field {
	return field{key, func(s string) error {
		out := []string{}
		for _, part := range strings.Split(s, ",") {
			if part = strings.TrimSpace(part); part != "" {
				out = append(out, part)
			}
		}
		*p = out
		return nil
	}}
}

func mapEntryF(key string, m map[string]string, name string) field {
	return field{key, func(s string) error { m[name] = s; return nil }}
}

func (c *Config) fields() []field {
	if c.Clients.MinVersion == nil {
		c.Clients.MinVersion = map[string]string{}
	}
	return []field{
		strF("data_dir", &c.DataDir),
		strF("library_dir", &c.LibraryDir),
		strF("server.name", &c.Server.Name),
		strF("server.https_addr", &c.Server.HTTPSAddr),
		strF("server.local_addr", &c.Server.LocalAddr),
		listF("server.public_urls", &c.Server.PublicURLs),
		strF("tls.mode", &c.TLS.Mode),
		strF("tls.cert_file", &c.TLS.CertFile),
		strF("tls.key_file", &c.TLS.KeyFile),
		boolF("discovery.mdns", &c.Discovery.MDNS),
		i64F("upload.max_file_bytes", &c.Upload.MaxFileBytes),
		i64F("upload.recommended_chunk_bytes", &c.Upload.RecommendedChunkBytes),
		i64F("storage.reserve_bytes", &c.Storage.ReserveBytes),
		intF("trash.retention_days", &c.Trash.RetentionDays),
		mapEntryF("clients.min_version.android", c.Clients.MinVersion, "android"),
		mapEntryF("clients.min_version.ios", c.Clients.MinVersion, "ios"),
		mapEntryF("clients.min_version.web", c.Clients.MinVersion, "web"),
		boolF("rate_limit.enabled", &c.RateLimit.Enabled),
		strF("media.ffmpeg_path", &c.Media.FFmpegPath),
		strF("media.ffprobe_path", &c.Media.FFprobePath),
		intF("media.workers", &c.Media.Workers),
		intF("jobs.workers", &c.Jobs.Workers),
		strF("log.level", &c.Log.Level),
		strF("log.format", &c.Log.Format),
	}
}

func flagName(key string) string { return strings.ReplaceAll(key, "_", "-") }

func envName(key string) string {
	return "PICTUNNEL_" + strings.ToUpper(strings.NewReplacer(".", "_").Replace(key))
}

// Load builds the configuration from args (flags, without the program or
// subcommand name), env (KEY=VALUE entries), <data_dir>/config.toml and defaults.
func Load(args []string, env []string) (Config, error) {
	cfg := Default()
	libraryExplicit := false

	// Flags.
	fs := flag.NewFlagSet("pictunnel", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	flagVals := map[string]*string{}
	for _, f := range cfg.fields() {
		v := new(string)
		flagVals[f.key] = v
		fs.StringVar(v, flagName(f.key), "", "")
	}
	if err := fs.Parse(args); err != nil {
		return Config{}, fmt.Errorf("config: %w", err)
	}
	flagSet := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { flagSet[f.Name] = true })

	envMap := map[string]string{}
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok {
			envMap[k] = v
		}
	}

	// Resolve data_dir first: it locates config.toml.
	dataDir := cfg.DataDir
	if v, ok := envMap[envName("data_dir")]; ok && v != "" {
		dataDir = v
	}
	if flagSet[flagName("data_dir")] {
		dataDir = *flagVals["data_dir"]
	}

	// config.toml (optional).
	b, err := os.ReadFile(filepath.Join(dataDir, "config.toml"))
	switch {
	case err == nil:
		dec := toml.NewDecoder(bytes.NewReader(b))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&cfg); err != nil {
			return Config{}, fmt.Errorf("config: parse config.toml: %w", err)
		}
		if cfg.LibraryDir != filepath.Join(defaultDataDir(), "library") {
			libraryExplicit = true
		}
	case errors.Is(err, os.ErrNotExist):
	default:
		return Config{}, fmt.Errorf("config: read config.toml: %w", err)
	}
	cfg.DataDir = dataDir

	// Env, then flags.
	for _, f := range cfg.fields() {
		if v, ok := envMap[envName(f.key)]; ok {
			if err := f.set(v); err != nil {
				return Config{}, fmt.Errorf("config: env %s: %w", envName(f.key), err)
			}
			if f.key == "library_dir" {
				libraryExplicit = true
			}
		}
	}
	for _, f := range cfg.fields() {
		if flagSet[flagName(f.key)] {
			if err := f.set(*flagVals[f.key]); err != nil {
				return Config{}, fmt.Errorf("config: flag --%s: %w", flagName(f.key), err)
			}
			if f.key == "library_dir" {
				libraryExplicit = true
			}
		}
	}
	cfg.DataDir = dataDir
	if !libraryExplicit || cfg.LibraryDir == "" {
		cfg.LibraryDir = filepath.Join(cfg.DataDir, "library")
	}

	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Validate checks the configuration for unusable values.
func (c Config) Validate() error {
	var errs []error
	bad := func(format string, a ...any) { errs = append(errs, fmt.Errorf("config: "+format, a...)) }
	switch c.TLS.Mode {
	case "self-signed", "off":
	case "files":
		if c.TLS.CertFile == "" || c.TLS.KeyFile == "" {
			bad("tls.mode=files requires tls.cert_file and tls.key_file")
		}
	default:
		bad("tls.mode %q must be self-signed, files or off", c.TLS.Mode)
	}
	if c.Upload.MaxFileBytes <= 0 {
		bad("upload.max_file_bytes must be > 0")
	}
	if c.Upload.RecommendedChunkBytes <= 0 {
		bad("upload.recommended_chunk_bytes must be > 0")
	}
	if c.Storage.ReserveBytes < 0 {
		bad("storage.reserve_bytes must be >= 0")
	}
	if c.Trash.RetentionDays < 1 {
		bad("trash.retention_days must be >= 1")
	}
	if c.Media.Workers < 1 {
		bad("media.workers must be >= 1")
	}
	if c.Jobs.Workers < 1 {
		bad("jobs.workers must be >= 1")
	}
	switch c.Log.Level {
	case "debug", "info", "warn", "error":
	default:
		bad("log.level %q must be debug, info, warn or error", c.Log.Level)
	}
	switch c.Log.Format {
	case "json", "text":
	default:
		bad("log.format %q must be json or text", c.Log.Format)
	}
	if c.DataDir == "" {
		bad("data_dir must not be empty")
	}
	for _, p := range []string{"android", "ios", "web"} {
		if c.Clients.MinVersion[p] == "" {
			bad("clients.min_version.%s must not be empty", p)
		}
	}
	return errors.Join(errs...)
}
