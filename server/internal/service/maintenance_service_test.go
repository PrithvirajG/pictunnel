package service

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

func TestBackupKeepsSeven(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	e.seed(t, e.alice, "x")
	dir := filepath.Join(e.dataDir, "backups")
	// An unrelated file in the backups dir is never pruned.
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	var want []string
	for day := 0; day < 9; day++ {
		if err := e.maint.BackupDatabase(ctx); err != nil {
			t.Fatalf("day %d: %v", day, err)
		}
		// A second run on the same day is a no-op.
		if err := e.maint.BackupDatabase(ctx); err != nil {
			t.Fatalf("day %d rerun: %v", day, err)
		}
		want = append(want, "pictunnel-"+e.clk.Now().Format("20060102")+".db")
		e.clk.Advance(24 * time.Hour)
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, d := range ents {
		got = append(got, d.Name())
	}
	sort.Strings(got)
	wantNames := append(append([]string{}, want[2:]...), "notes.txt")
	sort.Strings(wantNames)
	if fmt.Sprint(got) != fmt.Sprint(wantNames) {
		t.Fatalf("backups %v, want %v", got, wantNames)
	}
	// Each backup is a usable SQLite database.
	b, err := os.ReadFile(filepath.Join(dir, want[8]))
	if err != nil || len(b) < 16 || string(b[:15]) != "SQLite format 3" {
		t.Fatalf("backup is not a database: %v", err)
	}
}

func TestCompactChangeLogFloor(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	floor := func() (int64, bool) {
		v, ok, err := repository.ServerStateRepository{}.Get(ctx, e.st.R, "change_log_floor")
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			return 0, false
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			t.Fatal(err)
		}
		return n, true
	}
	a := e.seed(t, e.alice, "a")
	e.clk.Advance(10 * 24 * time.Hour)
	b := e.seed(t, e.alice, "b")
	if err := e.maint.CompactChangeLog(ctx); err != nil {
		t.Fatal(err)
	}
	if _, ok := floor(); ok {
		t.Fatal("floor set although nothing was compacted")
	}
	e.clk.Advance(85 * 24 * time.Hour) // a is 95 days old, b 85
	if err := e.maint.CompactChangeLog(ctx); err != nil {
		t.Fatal(err)
	}
	if f, ok := floor(); !ok || f != a.UpdatedSeq {
		t.Fatalf("floor %d %v, want %d", f, ok, a.UpdatedSeq)
	}
	_, _, _, err := e.feed.Changes(ctx, e.alice, EncodeCursor(a.UpdatedSeq), 0)
	wantCode(t, err, "cursor_expired") // cursor ≤ floor
	var rows []string
	r, err := e.st.R.QueryContext(ctx, `SELECT asset_id FROM change_log`)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	for r.Next() {
		var id string
		if err := r.Scan(&id); err != nil {
			t.Fatal(err)
		}
		rows = append(rows, id)
	}
	if len(rows) != 1 || rows[0] != b.ID {
		t.Fatalf("rows after compaction: %v, want only %s", rows, b.ID)
	}
	// Head is above the floor, so no head advance happened.
	if h, _ := (repository.ChangeLogRepository{}).Head(ctx, e.st.R); h != b.UpdatedSeq {
		t.Fatalf("head %d, want %d", h, b.UpdatedSeq)
	}
}

func TestExpireTokens(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	at := repository.AccessTokensRepository{}
	if err := at.Insert(ctx, e.st.W, "old", e.alice.DeviceID, t0.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := at.Insert(ctx, e.st.W, "new", e.alice.DeviceID, t0.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	rt := repository.RefreshTokensRepository{}
	for _, tok := range []struct {
		h   string
		exp time.Time
	}{{"rold", t0.Add(-time.Hour)}, {"rnew", t0.Add(time.Hour)}} {
		if err := rt.Insert(ctx, e.st.W, repository.RefreshToken{Hash: tok.h, DeviceID: e.alice.DeviceID, FamilyID: "f",
			State: "active", IssuedAt: t0.Add(-2 * time.Hour), ExpiresAt: tok.exp}); err != nil {
			t.Fatal(err)
		}
	}
	ws := repository.WebSessionsRepository{}
	if err := ws.Insert(ctx, e.st.W, repository.WebSession{TokenHash: "wold", DeviceID: e.alice.DeviceID, CSRFHash: "c",
		ExpiresAt: t0.Add(-time.Second), LastUsedAt: t0.Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	pc := repository.PairingCodesRepository{}
	if err := pc.Insert(ctx, e.st.W, repository.PairingCode{CodeHash: "pold", UserID: e.alice.UserID,
		CreatedAt: t0.Add(-time.Hour), ExpiresAt: t0.Add(-time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if err := e.maint.ExpireTokens(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := at.Get(ctx, e.st.R, "old"); err != repository.ErrNotFound {
		t.Fatalf("expired access token kept: %v", err)
	}
	if _, err := at.Get(ctx, e.st.R, "new"); err != nil {
		t.Fatalf("live access token removed: %v", err)
	}
	if _, err := rt.Get(ctx, e.st.R, "rold"); err != repository.ErrNotFound {
		t.Fatalf("expired refresh token kept: %v", err)
	}
	if _, err := rt.Get(ctx, e.st.R, "rnew"); err != nil {
		t.Fatalf("live refresh token removed: %v", err)
	}
	if _, err := ws.Get(ctx, e.st.R, "wold"); err != repository.ErrNotFound {
		t.Fatalf("expired web session kept: %v", err)
	}
	if _, err := pc.Get(ctx, e.st.R, "pold"); err != repository.ErrNotFound {
		t.Fatalf("expired pairing code kept: %v", err)
	}
}
