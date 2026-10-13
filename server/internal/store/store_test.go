package store

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func openTemp(t *testing.T) *Store {
	t.Helper()
	s, err := Open(context.Background(), filepath.Join(t.TempDir(), "pt.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func openMigrated(t *testing.T) *Store {
	t.Helper()
	s := openTemp(t)
	if err := s.Migrate(context.Background()); err != nil {
		t.Fatalf("Migrate: %v", err)
	}
	return s
}

func TestOpenMigrateQuickCheck(t *testing.T) {
	ctx := context.Background()
	s := openTemp(t)
	p, err := s.PendingMigrations(ctx)
	if err != nil || !p {
		t.Fatalf("pending before = %v, %v; want true", p, err)
	}
	if err := s.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	p, err = s.PendingMigrations(ctx)
	if err != nil || p {
		t.Fatalf("pending after = %v, %v; want false", p, err)
	}
	if err := s.QuickCheck(ctx); err != nil {
		t.Fatal(err)
	}
	var mode string
	if err := s.W.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("journal_mode = %q, %v", mode, err)
	}
}

func TestReaderIsReadOnly(t *testing.T) {
	s := openMigrated(t)
	_, err := s.R.ExecContext(context.Background(), "INSERT INTO server_state(key,value) VALUES('a','b')")
	if err == nil {
		t.Fatal("insert via reader succeeded")
	}
}

func TestWithTxRollback(t *testing.T) {
	ctx := context.Background()
	s := openMigrated(t)
	boom := errors.New("boom")
	err := s.WithTx(ctx, func(tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, "INSERT INTO server_state(key,value) VALUES('a','b')"); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("err = %v", err)
	}
	var n int
	if err := s.R.QueryRowContext(ctx, "SELECT count(*) FROM server_state").Scan(&n); err != nil || n != 0 {
		t.Fatalf("count = %d, %v", n, err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, "INSERT INTO server_state(key,value) VALUES('a','b')")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.R.QueryRowContext(ctx, "SELECT count(*) FROM server_state").Scan(&n); err != nil || n != 1 {
		t.Fatalf("count = %d, %v", n, err)
	}
}

func TestWithTxRollbackOnPanic(t *testing.T) {
	ctx := context.Background()
	s := openMigrated(t)
	func() {
		defer func() { _ = recover() }()
		_ = s.WithTx(ctx, func(tx *sql.Tx) error {
			_, _ = tx.ExecContext(ctx, "INSERT INTO server_state(key,value) VALUES('a','b')")
			panic("x")
		})
	}()
	var n int
	if err := s.R.QueryRowContext(ctx, "SELECT count(*) FROM server_state").Scan(&n); err != nil || n != 0 {
		t.Fatalf("count = %d, %v", n, err)
	}
}

func TestBackupTo(t *testing.T) {
	ctx := context.Background()
	s := openMigrated(t)
	dst := filepath.Join(t.TempDir(), "backup.db")
	if err := s.BackupTo(ctx, dst); err != nil {
		t.Fatal(err)
	}
	b, err := Open(ctx, dst)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	var n int
	if err := b.R.QueryRowContext(ctx, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('assets','users','change_log')").Scan(&n); err != nil || n != 3 {
		t.Fatalf("tables = %d, %v", n, err)
	}
	if err := s.BackupTo(ctx, dst); err == nil {
		t.Fatal("backup over existing file should fail")
	}
}

func seedUserDevice(t *testing.T, s *Store) {
	t.Helper()
	ctx := context.Background()
	stmts := []string{
		"INSERT INTO users(id,username,slug,display_name,role,password_hash,created_at) VALUES('u1','alice','alice','Alice','admin','x','2026-01-01T00:00:00.000Z')",
		"INSERT INTO devices(id,user_id,name,platform,app_version,created_at,last_seen_at) VALUES('d1','u1','phone','android','1','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z')",
	}
	for _, q := range stmts {
		if _, err := s.W.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
}

func TestPartialUniqueUploadSessions(t *testing.T) {
	ctx := context.Background()
	s := openMigrated(t)
	seedUserDevice(t, s)
	ins := func(id, state string) error {
		_, err := s.W.ExecContext(ctx, `INSERT INTO upload_sessions
(id,owner_id,device_id,sha256,length,"offset",state,meta_json,staging_path,dest_path,created_at,updated_at,expires_at)
VALUES(?,'u1','d1','abc',10,0,?,'{}','s','d','t','t','t')`, id, state)
		return err
	}
	if err := ins("a", "receiving"); err != nil {
		t.Fatal(err)
	}
	err := ins("b", "receiving")
	if err == nil || !strings.Contains(err.Error(), "UNIQUE") {
		t.Fatalf("want unique error, got %v", err)
	}
	if err := ins("c", "done"); err != nil {
		t.Fatalf("done row: %v", err)
	}
	if err := ins("d", "finalizing"); err == nil {
		t.Fatal("finalizing should conflict with receiving")
	}
}

func TestForeignKeysOn(t *testing.T) {
	ctx := context.Background()
	s := openMigrated(t)
	var fk int
	if err := s.W.QueryRowContext(ctx, "PRAGMA foreign_keys").Scan(&fk); err != nil || fk != 1 {
		t.Fatalf("fk = %d, %v", fk, err)
	}
	_, err := s.W.ExecContext(ctx, "INSERT INTO devices(id,user_id,name,platform,app_version,created_at,last_seen_at) VALUES('d','nouser','n','p','v','t','t')")
	if err == nil {
		t.Fatal("expected FK violation")
	}
}
