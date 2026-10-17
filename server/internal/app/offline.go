package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// ResetPassword is the offline `pictunnel reset-password` (S§10.2). It does
// a light boot only: the data-dir lock (so it refuses while the server
// runs), open + quick_check + backup/migrate, and secret.key. It does not
// touch TLS, recovery, media jobs or the setup token. It returns the new
// random password; the user's devices are signed out.
func ResetPassword(ctx context.Context, cfg config.Config, username string) (string, error) {
	if _, err := os.Stat(filepath.Join(cfg.DataDir, dbFileName)); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("no database in data dir %s (wrong --data-dir?)", cfg.DataDir)
		}
		return "", err
	}
	lock, err := acquireLock(cfg.DataDir)
	if err != nil {
		return "", err
	}
	defer lock.Close()
	clk := clock.Real{}
	st, err := openStore(ctx, cfg.DataDir, clk.Now())
	if err != nil {
		return "", err
	}
	defer st.Close()
	secret, err := loadSecret(cfg.DataDir)
	if err != nil {
		return "", err
	}
	auth, err := service.NewAuthService(service.AuthServiceDeps{
		Store: st, Users: repository.UsersRepository{}, Devices: repository.DevicesRepository{},
		AccessTokens: repository.AccessTokensRepository{}, RefreshTokens: repository.RefreshTokensRepository{},
		WebSessions: repository.WebSessionsRepository{}, Audit: repository.AuditLogRepository{},
		Clock: clk, Secret: secret,
	})
	if err != nil {
		return "", err
	}
	users := service.NewUserService(service.UserServiceDeps{
		Store: st, Users: repository.UsersRepository{}, ServerState: repository.ServerStateRepository{},
		Devices: repository.DevicesRepository{}, Audit: repository.AuditLogRepository{}, Auth: auth, Clock: clk,
	})
	return users.ResetPassword(ctx, username)
}
