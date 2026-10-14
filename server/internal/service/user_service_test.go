package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

func TestSetupTwice(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	u, err := e.users.Setup(ctx, "alice", testPassword, "Alice")
	if err != nil {
		t.Fatal(err)
	}
	if u.Role != "admin" || u.Slug != "alice" || u.DisplayName != "Alice" || u.ID == "" {
		t.Fatalf("user = %+v", u)
	}
	if !strings.HasPrefix(u.PasswordHash, "$argon2id$") {
		t.Fatalf("password hash %q", u.PasswordHash)
	}
	_, err = e.users.Setup(ctx, "bob", testPassword, "Bob")
	wantCode(t, err, "setup_already_done")
}

func TestSetupValidation(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	for _, c := range []struct{ name, user, pw string }{
		{"short password", "alice", "123456789"},
		{"too short username", "a", testPassword},
		{"two chars a1", "a1", testPassword},
		{"two chars ab", "ab", testPassword},
		{"uppercase", "Alice", testPassword},
		{"leading dot", ".alice", testPassword},
		{"space", "al ice", testPassword},
		{"too long", strings.Repeat("a", 33), testPassword},
		{"empty", "", testPassword},
		{"password too long", "alice", strings.Repeat("p", 257)},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, err := e.users.Setup(ctx, c.user, c.pw, "")
			wantCode(t, err, "invalid_request")
		})
	}
	// Boundary cases that are valid.
	u, err := e.users.Setup(ctx, "ab1", "0123456789", "")
	if err != nil {
		t.Fatal(err)
	}
	if u.DisplayName != "ab1" {
		t.Fatalf("display name defaults to username, got %q", u.DisplayName)
	}
}

func TestCreateUser(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	e.setupAlice(t)
	u, err := e.users.Create(ctx, "bob.smith", testPassword, "Bob", "user")
	if err != nil {
		t.Fatal(err)
	}
	if u.Role != "user" || u.Slug != "bob.smith" {
		t.Fatalf("user = %+v", u)
	}
	_, err = e.users.Create(ctx, "bob.smith", testPassword, "Bob", "user")
	wantCode(t, err, "invalid_request")
	_, err = e.users.Create(ctx, "carol", testPassword, "Carol", "root")
	wantCode(t, err, "invalid_request")
	if _, _, _, err := e.auth.Login(ctx, "bob.smith", testPassword, pixel); err != nil {
		t.Fatalf("login as created user: %v", err)
	}
}

func TestResetPassword(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	e.setupAlice(t)
	pw, err := e.users.ResetPassword(ctx, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if len(pw) < 10 {
		t.Fatalf("new password %q too short", pw)
	}
	_, _, _, err = e.auth.Login(ctx, "alice", testPassword, pixel)
	wantCode(t, err, "unauthorized")
	if _, _, _, err := e.auth.Login(ctx, "alice", pw, pixel); err != nil {
		t.Fatalf("login with reset password: %v", err)
	}
	_, err = e.users.ResetPassword(ctx, "nobody")
	wantCode(t, err, "not_found")
}

func TestSetupToken(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	tok, created, err := e.users.EnsureSetupToken(ctx)
	if err != nil || !created || tok == "" {
		t.Fatalf("EnsureSetupToken = %q, %v, %v", tok, created, err)
	}
	tok2, created2, err := e.users.EnsureSetupToken(ctx)
	if err != nil || created2 || tok2 != "" {
		t.Fatalf("second EnsureSetupToken = %q, %v, %v; want no new token", tok2, created2, err)
	}
	if !e.users.CheckSetupToken(ctx, tok) {
		t.Fatal("correct setup token rejected")
	}
	for _, bad := range []string{"", tok + "x", strings.ToUpper(tok)} {
		if bad != tok && e.users.CheckSetupToken(ctx, bad) {
			t.Fatalf("wrong setup token %q accepted", bad)
		}
	}
	// Nothing stored → nothing matches.
	e2 := newEnv(t)
	if e2.users.CheckSetupToken(ctx, "") || e2.users.CheckSetupToken(ctx, tok) {
		t.Fatal("token accepted with none stored")
	}
}

func TestEnsureSetupTokenSkippedAfterSetup(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	e.setupAlice(t)
	tok, created, err := e.users.EnsureSetupToken(ctx)
	if err != nil || created || tok != "" {
		t.Fatalf("EnsureSetupToken after setup = %q, %v, %v", tok, created, err)
	}
}

func TestResetPasswordRevokesDevices(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, d, tp := e.setupAlice(t)
	_, _, sess, csrf, _, err := e.auth.LoginCookie(ctx, "alice", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	cp, err := e.auth.AuthenticateCookie(ctx, sess)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.users.ResetPassword(ctx, "alice"); err != nil {
		t.Fatal(err)
	}
	_, err = e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.Refresh(ctx, tp.RefreshToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.AuthenticateCookie(ctx, sess)
	wantCode(t, err, "unauthorized")
	if e.auth.CheckCSRF(ctx, cp, csrf) {
		t.Fatal("CSRF accepted after the session was revoked")
	}
	if _, err := (repository.WebSessionsRepository{}).Get(ctx, e.st.R, hashToken(sess)); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("web session row still present: %v", err)
	}
	dev, err := repository.DevicesRepository{}.Get(ctx, e.st.R, d.ID)
	if err != nil || dev.RevokedAt == nil {
		t.Fatalf("device not revoked: %+v, %v", dev, err)
	}
}
