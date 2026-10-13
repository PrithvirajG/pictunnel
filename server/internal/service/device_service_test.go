package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

func TestDeviceListAndRename(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, d, tp := e.setupAlice(t)
	p := e.principal(t, tp.AccessToken)
	list, err := e.devices.List(ctx, p)
	if err != nil || len(list) != 1 || list[0].ID != d.ID {
		t.Fatalf("List = %+v, %v", list, err)
	}
	got, err := e.devices.Rename(ctx, p, d.ID, "  Alice's Pixel ")
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "Alice's Pixel" || got.ID != d.ID {
		t.Fatalf("renamed = %+v", got)
	}
	for _, bad := range []string{"", "   ", strings.Repeat("n", 101)} {
		_, err = e.devices.Rename(ctx, p, d.ID, bad)
		wantCode(t, err, "invalid_request")
	}
	_, err = e.devices.Rename(ctx, p, "no-such-device", "x")
	wantCode(t, err, "not_found")
}

func TestDeviceRenameOtherUserNotFound(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, aliceDev, _ := e.setupAlice(t)
	if _, err := e.users.Create(ctx, "bob", testPassword, "Bob", "user"); err != nil {
		t.Fatal(err)
	}
	_, _, btp, err := e.auth.Login(ctx, "bob", testPassword, pixel)
	if err != nil {
		t.Fatal(err)
	}
	bob := e.principal(t, btp.AccessToken)
	_, err = e.devices.Rename(ctx, bob, aliceDev.ID, "pwned")
	wantCode(t, err, "not_found")
	err = e.devices.Revoke(ctx, bob, aliceDev.ID)
	wantCode(t, err, "not_found")
	dev, _ := repository.DevicesRepository{}.Get(ctx, e.st.R, aliceDev.ID)
	if dev.Name != "Pixel 9" || dev.RevokedAt != nil {
		t.Fatalf("alice's device changed: %+v", dev)
	}
	list, err := e.devices.List(ctx, bob)
	if err != nil || len(list) != 1 || list[0].UserID != bob.UserID {
		t.Fatalf("bob's List = %+v, %v", list, err)
	}
}

func TestDeviceRevoke(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, tp := e.setupAlice(t)
	_, d2, tp2, err := e.auth.Login(ctx, "alice", testPassword, DeviceInfo{Name: "iPhone", Platform: "ios", AppVersion: "0.1.0"})
	if err != nil {
		t.Fatal(err)
	}
	p := e.principal(t, tp.AccessToken)
	if err := e.devices.Revoke(ctx, p, d2.ID); err != nil {
		t.Fatal(err)
	}
	_, err = e.auth.AuthenticateBearer(ctx, tp2.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.Refresh(ctx, tp2.RefreshToken)
	wantCode(t, err, "unauthorized")
	// Idempotent; the revoked device stays revoked at its first time.
	e.clk.Advance(time.Minute)
	if err := e.devices.Revoke(ctx, p, d2.ID); err != nil {
		t.Fatalf("second revoke: %v", err)
	}
	dev, _ := repository.DevicesRepository{}.Get(ctx, e.st.R, d2.ID)
	if dev.RevokedAt == nil || !dev.RevokedAt.Equal(t0) {
		t.Fatalf("revoked_at = %v", dev.RevokedAt)
	}
	list, _ := e.devices.List(ctx, p)
	if len(list) != 1 {
		t.Fatalf("List after revoke = %+v", list)
	}
	// Renaming a revoked device is not found.
	_, err = e.devices.Rename(ctx, p, d2.ID, "x")
	wantCode(t, err, "not_found")
	e.principal(t, tp.AccessToken)
}

func TestTouchLastSeenCoalesced(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, d, _ := e.setupAlice(t)
	get := func() time.Time {
		dev, err := repository.DevicesRepository{}.Get(ctx, e.st.R, d.ID)
		if err != nil {
			t.Fatal(err)
		}
		return dev.LastSeenAt
	}
	e.clk.Advance(5 * time.Second)
	if err := e.devices.TouchLastSeen(ctx, d.ID); err != nil {
		t.Fatal(err)
	}
	if got := get(); !got.Equal(t0.Add(5 * time.Second)) {
		t.Fatalf("first touch: %v", got)
	}
	e.clk.Advance(30 * time.Second)
	if err := e.devices.TouchLastSeen(ctx, d.ID); err != nil {
		t.Fatal(err)
	}
	if got := get(); !got.Equal(t0.Add(5 * time.Second)) {
		t.Fatalf("touch within a minute wrote: %v", got)
	}
	e.clk.Advance(30 * time.Second)
	if err := e.devices.TouchLastSeen(ctx, d.ID); err != nil {
		t.Fatal(err)
	}
	if got := get(); !got.Equal(t0.Add(65 * time.Second)) {
		t.Fatalf("touch after a minute: %v", got)
	}
	if err := e.devices.TouchLastSeen(ctx, "missing"); err != nil {
		t.Fatalf("touch of a missing device: %v", err)
	}
}
