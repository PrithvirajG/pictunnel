// Package store owns the SQLite connection pools, migrations and transactions.
package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite" // pure-Go SQLite driver ("sqlite")
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// Store holds a single-connection writer pool and a read-only reader pool.
type Store struct {
	W    *sql.DB
	R    *sql.DB
	path string
}

func dsn(path string, pragmas []string, extra ...string) string {
	q := url.Values{}
	for _, p := range pragmas {
		q.Add("_pragma", p)
	}
	for i := 0; i+1 < len(extra); i += 2 {
		q.Set(extra[i], extra[i+1])
	}
	return "file:" + url.PathEscape(path) + "?" + q.Encode()
}

// Open opens the writer and reader pools for the database at path.
func Open(ctx context.Context, path string) (*Store, error) {
	w, err := sql.Open("sqlite", dsn(path, []string{
		"foreign_keys(1)", "journal_mode(WAL)", "synchronous(FULL)", "busy_timeout(5000)",
	}, "_txlock", "immediate"))
	if err != nil {
		return nil, fmt.Errorf("store: open writer: %w", err)
	}
	w.SetMaxOpenConns(1)
	if err := w.PingContext(ctx); err != nil {
		_ = w.Close()
		return nil, fmt.Errorf("store: ping writer: %w", err)
	}
	r, err := sql.Open("sqlite", dsn(path, []string{
		"foreign_keys(1)", "busy_timeout(5000)", "query_only(1)",
	}))
	if err != nil {
		_ = w.Close()
		return nil, fmt.Errorf("store: open reader: %w", err)
	}
	r.SetMaxOpenConns(4)
	if err := r.PingContext(ctx); err != nil {
		_ = w.Close()
		_ = r.Close()
		return nil, fmt.Errorf("store: ping reader: %w", err)
	}
	return &Store{W: w, R: r, path: path}, nil
}

// Close closes both pools.
func (s *Store) Close() error {
	return errors.Join(s.R.Close(), s.W.Close())
}

// QuickCheck runs PRAGMA quick_check and fails unless it returns "ok".
func (s *Store) QuickCheck(ctx context.Context) error {
	var res string
	if err := s.W.QueryRowContext(ctx, "PRAGMA quick_check").Scan(&res); err != nil {
		return fmt.Errorf("store: quick_check: %w", err)
	}
	if res != "ok" {
		return fmt.Errorf("store: quick_check failed: %s", res)
	}
	return nil
}

func (s *Store) provider() (*goose.Provider, error) {
	sub, err := fs.Sub(migrationsFS, "migrations")
	if err != nil {
		return nil, err
	}
	return goose.NewProvider(goose.DialectSQLite3, s.W, sub)
}

// PendingMigrations reports whether unapplied migrations exist.
func (s *Store) PendingMigrations(ctx context.Context) (bool, error) {
	p, err := s.provider()
	if err != nil {
		return false, err
	}
	return p.HasPending(ctx)
}

// Migrate applies all pending migrations.
func (s *Store) Migrate(ctx context.Context) error {
	p, err := s.provider()
	if err != nil {
		return err
	}
	if _, err := p.Up(ctx); err != nil {
		return fmt.Errorf("store: migrate: %w", err)
	}
	return nil
}

// BackupTo writes a consistent copy of the database with VACUUM INTO.
// dst must not exist.
func (s *Store) BackupTo(ctx context.Context, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return fmt.Errorf("store: backup destination %q already exists", dst)
	}
	if _, err := s.W.ExecContext(ctx, "VACUUM INTO ?", dst); err != nil {
		return fmt.Errorf("store: backup: %w", err)
	}
	return nil
}

// WithTx runs fn in an immediate write transaction on W. It rolls back on
// error or panic and commits otherwise.
func (s *Store) WithTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := s.W.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("store: begin: %w", err)
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback()
			panic(p)
		}
	}()
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("store: commit: %w", err)
	}
	return nil
}
