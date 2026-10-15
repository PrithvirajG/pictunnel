// Command pictunnel is the PicTunnel server.
//
//	pictunnel serve [flags]               run the server
//	pictunnel version                     print the version
//	pictunnel reset-password <user> [flags]  set a new random password (offline)
//
// Flags are the config keys (S§10.2), e.g. --data-dir, --server.https-addr,
// --discovery.mdns=false; env PICTUNNEL_<SECTION>_<KEY> and
// <data_dir>/config.toml work too.
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
)

// version is set at build time with -ldflags "-X main.version=<version>".
var version = "dev"

const usage = `usage:
  pictunnel serve [flags]
  pictunnel version
  pictunnel reset-password <user> [flags]
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Args[1:], os.Environ(), os.Stdout, os.Stderr))
}

func run(ctx context.Context, args, env []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		_, _ = fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "version", "--version":
		_, _ = fmt.Fprintf(stdout, "pictunnel %s\n", version)
		return 0
	case "serve":
		return serve(ctx, args[1:], env, stdout, stderr)
	case "reset-password":
		if len(args) < 2 || strings.HasPrefix(args[1], "-") {
			_, _ = fmt.Fprint(stderr, usage)
			return 2
		}
		return resetPassword(ctx, args[1], args[2:], env, stdout, stderr)
	default:
		_, _ = fmt.Fprint(stderr, usage)
		return 2
	}
}

func newLogger(cfg config.Config, w io.Writer) *slog.Logger {
	var lvl slog.Level
	_ = lvl.UnmarshalText([]byte(cfg.Log.Level))
	ho := &slog.HandlerOptions{Level: lvl}
	if cfg.Log.Format == "text" {
		return slog.New(slog.NewTextHandler(w, ho))
	}
	return slog.New(slog.NewJSONHandler(w, ho))
}

func serve(ctx context.Context, args, env []string, stdout, stderr io.Writer) int {
	cfg, err := config.Load(args, env)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel: %v\n", err)
		return 2
	}
	log := newLogger(cfg, stderr)
	var a *app.App
	a, err = app.New(ctx, app.Options{
		Config: cfg, Log: log, Version: version,
		Listening: func(httpsAddr, localAddr string) {
			scheme := "https"
			if cfg.TLS.Mode == "off" {
				scheme = "http"
			}
			local := "local listener off"
			if localAddr != "" {
				local = "local http://" + localAddr
			}
			_, _ = fmt.Fprintf(stdout, "PicTunnel %s listening on %s://%s (%s)\n", version, scheme, httpsAddr, local)
			if tok := a.SetupToken(); tok != "" {
				if localAddr != "" {
					_, _ = fmt.Fprintf(stdout, "First-run setup: open http://%s on this machine to create the admin account.\n", localAddr)
				}
				_, _ = fmt.Fprintf(stdout, "From another machine, send the header PicTunnel-Setup-Token: %s\n"+
					"(the token changes on every start until setup is done)\n", tok)
			}
		},
	})
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel: %v\n", err)
		return 1
	}
	defer func() { _ = a.Close() }()
	if fp := a.Fingerprint(); fp != "" {
		_, _ = fmt.Fprintf(stdout, "Server %s, certificate pin %s\n", a.ServerID(), fp)
	}
	if err := a.Run(ctx); err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel: %v\n", err)
		return 1
	}
	return 0
}

// resetPassword runs offline against the database: it takes the data-dir
// lock (so it refuses while the server runs), sets a new random password,
// revokes the user's devices and prints the password.
func resetPassword(ctx context.Context, user string, args, env []string, stdout, stderr io.Writer) int {
	cfg, err := config.Load(args, env)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel: %v\n", err)
		return 2
	}
	pw, err := app.ResetPassword(ctx, cfg, user)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel: reset password for %q: %v\n", user, err)
		return 1
	}
	_, _ = fmt.Fprintf(stdout, "New password for %s: %s\nAll of %s's devices were signed out.\n", user, pw, user)
	return 0
}
