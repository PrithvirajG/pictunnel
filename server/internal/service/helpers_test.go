package service

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

func TestMain(m *testing.M) {
	// Production argon2id parameters cost 64 MiB and ~100 ms per hash; the
	// suite hashes dozens of passwords, so it uses cheap parameters. The
	// production values are asserted in TestPasswordDefaultParams.
	argonParams = argon2Params{memory: 64, time: 1, threads: 1, keyLen: 32}
	os.Exit(m.Run())
}

var t0 = time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

const testPassword = "correct horse battery"

var testSecret = []byte("0123456789abcdef0123456789abcdef")

type env struct {
	st      *store.Store
	clk     *clocktest.Fake
	users   *UserService
	auth    *AuthService
	devices *DeviceService
	pairing *PairingService
}

func newEnv(t *testing.T) *env {
	t.Helper()
	st := repotest.NewStore(t)
	return newEnvOn(t, st, clocktest.NewFake(t0))
}

// newEnvOn builds fresh service instances over an existing store and clock,
// which simulates a server restart.
func newEnvOn(t *testing.T, st *store.Store, clk *clocktest.Fake) *env {
	t.Helper()
	e := &env{st: st, clk: clk}
	var err error
	e.auth, err = NewAuthService(AuthServiceDeps{
		Store: st, Users: repository.UsersRepository{}, Devices: repository.DevicesRepository{},
		AccessTokens: repository.AccessTokensRepository{}, RefreshTokens: repository.RefreshTokensRepository{},
		WebSessions: repository.WebSessionsRepository{}, Audit: repository.AuditLogRepository{},
		Clock: clk, Secret: testSecret,
	})
	if err != nil {
		t.Fatal(err)
	}
	e.users = NewUserService(UserServiceDeps{
		Store: st, Users: repository.UsersRepository{}, ServerState: repository.ServerStateRepository{},
		Devices: repository.DevicesRepository{}, Audit: repository.AuditLogRepository{}, Auth: e.auth, Clock: clk,
	})
	e.devices = NewDeviceService(DeviceServiceDeps{
		Store: st, Devices: repository.DevicesRepository{}, Auth: e.auth, Clock: clk,
	})
	e.pairing, err = NewPairingService(PairingServiceDeps{
		Store: st, PairingCodes: repository.PairingCodesRepository{}, Devices: repository.DevicesRepository{},
		Users: repository.UsersRepository{}, Audit: repository.AuditLogRepository{}, Auth: e.auth, Clock: clk,
		Secret:      testSecret,
		ServerID:    "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f",
		Fingerprint: "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc",
		Endpoints: func() []string {
			return []string{"https://192.168.1.20:8443", "https://photos.example.com", "https://192.168.1.20:8443"}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return e
}

var pixel = DeviceInfo{Name: "Pixel 9", Platform: "android", AppVersion: "0.1.0"}

// setupAlice creates the admin "alice" and logs in a device with tokens.
func (e *env) setupAlice(t *testing.T) (repository.User, repository.Device, TokenPair) {
	t.Helper()
	if _, err := e.users.Setup(context.Background(), "alice", testPassword, "Alice"); err != nil {
		t.Fatalf("Setup: %v", err)
	}
	u, d, tp, err := e.auth.Login(context.Background(), "alice", testPassword, pixel)
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	return u, d, tp
}

func (e *env) principal(t *testing.T, access string) Principal {
	t.Helper()
	p, err := e.auth.AuthenticateBearer(context.Background(), access)
	if err != nil {
		t.Fatalf("AuthenticateBearer: %v", err)
	}
	return p
}

func wantCode(t *testing.T, err error, code string) {
	t.Helper()
	ae, ok := apperr.As(err)
	if !ok {
		t.Fatalf("err = %v, want apperr %q", err, code)
	}
	if ae.Code != code {
		t.Fatalf("code = %q (%v), want %q", ae.Code, err, code)
	}
}
