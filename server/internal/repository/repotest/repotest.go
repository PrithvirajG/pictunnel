// Package repotest provides helpers for repository tests.
package repotest

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// NewStore opens a migrated store in a temp dir, closed on cleanup.
func NewStore(t *testing.T) *store.Store {
	t.Helper()
	ctx := context.Background()
	s, err := store.Open(ctx, filepath.Join(t.TempDir(), "pt.db"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Migrate(ctx); err != nil {
		t.Fatalf("store.Migrate: %v", err)
	}
	return s
}

// SeedUser inserts a minimal user row (for foreign keys) and returns its id.
func SeedUser(t *testing.T, s *store.Store, id string) string {
	t.Helper()
	_, err := s.W.ExecContext(context.Background(),
		`INSERT INTO users (id, username, slug, display_name, role, password_hash, created_at)
		 VALUES (?, ?, ?, ?, 'member', 'h', '2026-01-01T00:00:00.000Z')`, id, "u-"+id, "s-"+id, "User "+id)
	if err != nil {
		t.Fatalf("SeedUser: %v", err)
	}
	return id
}

// SeedDevice inserts a minimal device row for the user and returns its id.
func SeedDevice(t *testing.T, s *store.Store, userID, id string) string {
	t.Helper()
	_, err := s.W.ExecContext(context.Background(),
		`INSERT INTO devices (id, user_id, name, platform, app_version, created_at, last_seen_at)
		 VALUES (?, ?, 'd', 'ios', '1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')`, id, userID)
	if err != nil {
		t.Fatalf("SeedDevice: %v", err)
	}
	return id
}
