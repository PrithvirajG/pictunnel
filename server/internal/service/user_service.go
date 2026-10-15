package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// UserServiceDeps are the UserService dependencies.
type UserServiceDeps struct {
	Store       *store.Store
	Users       repository.UsersRepository
	ServerState repository.ServerStateRepository
	Devices     repository.DevicesRepository
	Audit       repository.AuditLogRepository
	Auth        *AuthService
	Clock       clock.Clock
}

// UserService manages accounts and first-run setup (S§4.1).
type UserService struct{ d UserServiceDeps }

// NewUserService returns a UserService.
func NewUserService(d UserServiceDeps) *UserService { return &UserService{d: d} }

// setupTokenKey is the server_state row holding the setup token hash.
const setupTokenKey = "setup_token_hash"

const (
	minPasswordLen    = 10
	maxPasswordLen    = 256 // OpenAPI SetupRequest.password maxLength
	maxDisplayNameLen = 100
)

var usernameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{2,31}$`)

// normalizeUsername NFC-normalizes and validates a username.
func normalizeUsername(username string) (string, error) {
	u := norm.NFC.String(username)
	if !usernameRe.MatchString(u) {
		return "", apperr.InvalidRequest("username must match ^[a-z0-9][a-z0-9._-]{2,31}$")
	}
	return u, nil
}

func validatePassword(pw string) error {
	n := utf8.RuneCountInString(pw)
	if n < minPasswordLen {
		return apperr.InvalidRequest("password must be at least 10 characters")
	}
	if n > maxPasswordLen {
		return apperr.InvalidRequest("password must be at most 256 characters")
	}
	return nil
}

// newUser validates the inputs and builds a user row with a hashed password.
func (s *UserService) newUser(username, password, displayName, role string) (repository.User, error) {
	u, err := normalizeUsername(username)
	if err != nil {
		return repository.User{}, err
	}
	if err := validatePassword(password); err != nil {
		return repository.User{}, err
	}
	if role != RoleAdmin && role != RoleUser {
		return repository.User{}, apperr.InvalidRequest("role must be admin or user")
	}
	dn := strings.TrimSpace(norm.NFC.String(displayName))
	if dn == "" {
		dn = u
	}
	if utf8.RuneCountInString(dn) > maxDisplayNameLen {
		return repository.User{}, apperr.InvalidRequest("display name must be at most 100 characters")
	}
	hash, err := hashPassword(password)
	if err != nil {
		return repository.User{}, err
	}
	return repository.User{
		ID: ids.New(), Username: u, Slug: strings.ToLower(u), DisplayName: dn, Role: role,
		PasswordHash: hash, CreatedAt: msNow(s.d.Clock.Now()),
	}, nil
}

// Setup creates the first admin. It fails with setup_already_done once any
// user exists (checked inside the write transaction).
func (s *UserService) Setup(ctx context.Context, username, password, displayName string) (repository.User, error) {
	u, err := s.newUser(username, password, displayName, RoleAdmin)
	if err != nil {
		return repository.User{}, err
	}
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		n, err := s.d.Users.Count(ctx, tx)
		if err != nil {
			return err
		}
		if n > 0 {
			return apperr.SetupAlreadyDone()
		}
		if err := s.d.Users.Insert(ctx, tx, u); err != nil {
			return err
		}
		return s.d.Audit.Append(ctx, tx, auditEvent(u.CreatedAt, u.ID, "", "user.setup", nil))
	})
	if err != nil {
		return repository.User{}, err
	}
	return u, nil
}

// Create adds a user with role admin or user. A taken username returns
// invalid_request.
func (s *UserService) Create(ctx context.Context, username, password, displayName, role string) (repository.User, error) {
	u, err := s.newUser(username, password, displayName, role)
	if err != nil {
		return repository.User{}, err
	}
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		if err := s.d.Users.Insert(ctx, tx, u); err != nil {
			if errors.Is(err, repository.ErrUniqueViolation) {
				return apperr.InvalidRequest("username is already taken")
			}
			return err
		}
		return s.d.Audit.Append(ctx, tx, auditEvent(u.CreatedAt, u.ID, "", "user.created", map[string]any{"role": role}))
	})
	if err != nil {
		return repository.User{}, err
	}
	return u, nil
}

// ResetPassword replaces the user's password with a random one and returns
// it. In the same transaction every device of the user is revoked, which
// ends all of their token families and web sessions.
func (s *UserService) ResetPassword(ctx context.Context, username string) (string, error) {
	pw := randomB64(15) // 20 characters, 120 bits
	hash, err := hashPassword(pw)
	if err != nil {
		return "", err
	}
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		u, err := s.d.Users.GetByUsername(ctx, tx, norm.NFC.String(username))
		if errors.Is(err, repository.ErrNotFound) {
			return apperr.NotFound()
		}
		if err != nil {
			return err
		}
		if err := s.d.Users.SetPasswordHash(ctx, tx, u.ID, hash); err != nil {
			return err
		}
		devs, err := s.d.Devices.ListByUser(ctx, tx, u.ID)
		if err != nil {
			return err
		}
		for _, d := range devs {
			if err := s.d.Auth.RevokeDevice(ctx, tx, d.ID); err != nil {
				return err
			}
		}
		return s.d.Audit.Append(ctx, tx, auditEvent(msNow(s.d.Clock.Now()), u.ID, "", "user.password_reset", map[string]any{"devices_revoked": len(devs)}))
	})
	if err != nil {
		return "", err
	}
	return pw, nil
}

// EnsureSetupToken generates a fresh setup hijack-guard token (S§4.1)
// while no user exists, replacing any earlier one, so every boot before
// setup prints a working token. Once a user exists it does nothing and
// returns created=false. Only the hash is stored.
func (s *UserService) EnsureSetupToken(ctx context.Context) (token string, created bool, err error) {
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		n, err := s.d.Users.Count(ctx, tx)
		if err != nil {
			return err
		}
		if n > 0 {
			return nil
		}
		tok := randomB64(24)
		if err := s.d.ServerState.Set(ctx, tx, setupTokenKey, hashToken(tok)); err != nil {
			return err
		}
		token, created = tok, true
		return nil
	})
	if err != nil {
		return "", false, err
	}
	return token, created, nil
}

// CheckSetupToken reports whether token matches the stored setup token hash.
func (s *UserService) CheckSetupToken(ctx context.Context, token string) bool {
	if token == "" {
		return false
	}
	h, ok, err := s.d.ServerState.Get(ctx, s.d.Store.R, setupTokenKey)
	if err != nil || !ok || h == "" {
		return false
	}
	return equalHashes(hashToken(token), h)
}

// auditEvent builds an audit row; empty ids are stored as NULL.
func auditEvent(at time.Time, userID, deviceID, event string, detail map[string]any) repository.AuditEvent {
	ev := repository.AuditEvent{ID: ids.New(), At: at, Event: event, DetailJSON: "{}"}
	if userID != "" {
		ev.UserID = &userID
	}
	if deviceID != "" {
		ev.DeviceID = &deviceID
	}
	if detail != nil {
		b, err := json.Marshal(detail)
		if err != nil {
			panic(fmt.Sprintf("audit detail: %v", err)) // detail maps are built from plain values
		}
		ev.DetailJSON = string(b)
	}
	return ev
}
