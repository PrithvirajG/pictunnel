package service

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"golang.org/x/text/unicode/norm"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// AuthServiceDeps are the AuthService dependencies. Secret is the 32-byte
// server secret k of ADR 0012 (<data>/secret.key).
type AuthServiceDeps struct {
	Store         *store.Store
	Users         repository.UsersRepository
	Devices       repository.DevicesRepository
	AccessTokens  repository.AccessTokensRepository
	RefreshTokens repository.RefreshTokensRepository
	WebSessions   repository.WebSessionsRepository
	Audit         repository.AuditLogRepository
	Clock         clock.Clock
	Secret        []byte
}

// AuthService handles login, token issue and rotation, and authentication
// of bearer tokens and session cookies (S§4.2).
type AuthService struct {
	d      AuthServiceDeps
	secret []byte

	dummyOnce sync.Once
	dummyHash string
}

// SecretLen is the required length of the server secret k (ADR 0012).
const SecretLen = 32

func checkSecret(secret []byte) error {
	if len(secret) != SecretLen {
		return fmt.Errorf("service: server secret must be %d bytes, got %d", SecretLen, len(secret))
	}
	return nil
}

// NewAuthService returns an AuthService. The secret must be exactly 32
// bytes; it is copied.
func NewAuthService(d AuthServiceDeps) (*AuthService, error) {
	if err := checkSecret(d.Secret); err != nil {
		return nil, err
	}
	d.Secret = bytes.Clone(d.Secret)
	return &AuthService{d: d, secret: d.Secret}, nil
}

// webDeviceName names the device a cookie login creates.
const webDeviceName = "Web browser"

// sessionTouchInterval bounds how often a cookie session's sliding expiry is
// written.
const sessionTouchInterval = time.Hour

func (s *AuthService) now() time.Time { return msNow(s.d.Clock.Now()) }

// checkPassword returns the active user with this username and password, or
// Unauthorized. Unknown users still pay for one hash to blunt timing probes.
func (s *AuthService) checkPassword(ctx context.Context, username, password string) (repository.User, error) {
	u, err := s.d.Users.GetByUsername(ctx, s.d.Store.R, norm.NFC.String(username))
	if errors.Is(err, repository.ErrNotFound) {
		s.dummyOnce.Do(func() { s.dummyHash, _ = hashPassword("pictunnel-dummy-password") })
		verifyPassword(s.dummyHash, password)
		return repository.User{}, apperr.Unauthorized()
	}
	if err != nil {
		return repository.User{}, err
	}
	if !verifyPassword(u.PasswordHash, password) || u.DisabledAt != nil {
		return repository.User{}, apperr.Unauthorized()
	}
	return u, nil
}

func (s *AuthService) insertDevice(ctx context.Context, db queries.DBTX, userID string, dev DeviceInfo, now time.Time) (repository.Device, error) {
	d := repository.Device{
		ID: ids.New(), UserID: userID, Name: dev.Name, Platform: dev.Platform, AppVersion: dev.AppVersion,
		CreatedAt: now,
	}
	return d, s.d.Devices.Insert(ctx, db, d)
}

// Login verifies the password and registers a new device with a token pair.
func (s *AuthService) Login(ctx context.Context, username, password string, dev DeviceInfo) (repository.User, repository.Device, TokenPair, error) {
	dev, err := dev.validate()
	if err != nil {
		return repository.User{}, repository.Device{}, TokenPair{}, err
	}
	u, err := s.checkPassword(ctx, username, password)
	if err != nil {
		return repository.User{}, repository.Device{}, TokenPair{}, err
	}
	var d repository.Device
	var tp TokenPair
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		now := s.now()
		var err error
		if d, err = s.insertDevice(ctx, tx, u.ID, dev, now); err != nil {
			return err
		}
		if tp, err = s.IssueForDevice(ctx, tx, d.ID); err != nil {
			return err
		}
		return s.d.Audit.Append(ctx, tx, auditEvent(now, u.ID, d.ID, "auth.login", map[string]any{"mode": "tokens"}))
	})
	if err != nil {
		return repository.User{}, repository.Device{}, TokenPair{}, err
	}
	return u, d, tp, nil
}

// LoginCookie verifies the password and creates a web device and session.
// The session and CSRF tokens are returned once; only hashes are stored.
func (s *AuthService) LoginCookie(ctx context.Context, username, password string) (user repository.User, device repository.Device, sessionToken, csrfToken string, expires time.Time, err error) {
	u, err := s.checkPassword(ctx, username, password)
	if err != nil {
		return repository.User{}, repository.Device{}, "", "", time.Time{}, err
	}
	sess, csrf := newToken(prefixWebSession), randomB64(32)
	var d repository.Device
	var exp time.Time
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		now := s.now()
		exp = now.Add(WebSessionTTL)
		var err error
		if d, err = s.insertDevice(ctx, tx, u.ID, DeviceInfo{Name: webDeviceName, Platform: "web"}, now); err != nil {
			return err
		}
		if err := s.d.WebSessions.Insert(ctx, tx, repository.WebSession{
			TokenHash: hashToken(sess), DeviceID: d.ID, CSRFHash: hashToken(csrf), ExpiresAt: exp, LastUsedAt: now,
		}); err != nil {
			return err
		}
		return s.d.Audit.Append(ctx, tx, auditEvent(now, u.ID, d.ID, "auth.login", map[string]any{"mode": "cookie"}))
	})
	if err != nil {
		return repository.User{}, repository.Device{}, "", "", time.Time{}, err
	}
	return u, d, sess, csrf, exp, nil
}

// IssueForDevice stores a fresh random token pair in a new refresh family.
func (s *AuthService) IssueForDevice(ctx context.Context, db queries.DBTX, deviceID string) (TokenPair, error) {
	now := s.now()
	tp := TokenPair{
		AccessToken: newToken(prefixAccess), AccessExpiresAt: now.Add(AccessTTL),
		RefreshToken: newToken(prefixRefresh), RefreshExpiresAt: now.Add(RefreshTTL),
	}
	if err := s.d.AccessTokens.Insert(ctx, db, hashToken(tp.AccessToken), deviceID, tp.AccessExpiresAt); err != nil {
		return TokenPair{}, err
	}
	if err := s.d.RefreshTokens.Insert(ctx, db, repository.RefreshToken{
		Hash: hashToken(tp.RefreshToken), DeviceID: deviceID, FamilyID: ids.New(), State: "active",
		IssuedAt: now, ExpiresAt: tp.RefreshExpiresAt,
	}); err != nil {
		return TokenPair{}, err
	}
	return tp, nil
}

// activeDevice loads the device and its user, returning Unauthorized when
// either is missing, the device is revoked or the user is disabled.
func (s *AuthService) activeDevice(ctx context.Context, db queries.DBTX, deviceID string) (repository.User, repository.Device, error) {
	d, err := s.d.Devices.Get(ctx, db, deviceID)
	if errors.Is(err, repository.ErrNotFound) {
		return repository.User{}, repository.Device{}, apperr.Unauthorized()
	}
	if err != nil {
		return repository.User{}, repository.Device{}, err
	}
	if d.RevokedAt != nil {
		return repository.User{}, repository.Device{}, apperr.Unauthorized()
	}
	u, err := s.d.Users.GetByID(ctx, db, d.UserID)
	if errors.Is(err, repository.ErrNotFound) {
		return repository.User{}, repository.Device{}, apperr.Unauthorized()
	}
	if err != nil {
		return repository.User{}, repository.Device{}, err
	}
	if u.DisabledAt != nil {
		return repository.User{}, repository.Device{}, apperr.Unauthorized()
	}
	return u, d, nil
}

// Refresh rotates a refresh token (S§4.2, ADR 0012). The successor pair is
// derived from the presented token, so a replay within RefreshGrace of the
// rotation returns the identical pair, even across restarts. A replay after
// the grace window revokes the family and the device and returns
// refresh_token_reused. Unknown, garbled, revoked or expired tokens return
// unauthorized.
func (s *AuthService) Refresh(ctx context.Context, refreshToken string) (TokenPair, error) {
	if !strings.HasPrefix(refreshToken, prefixRefresh) || len(refreshToken) == len(prefixRefresh) {
		return TokenPair{}, apperr.Unauthorized()
	}
	var tp TokenPair
	reused := false
	err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		now := s.now()
		rt, err := s.d.RefreshTokens.Get(ctx, tx, hashToken(refreshToken))
		if errors.Is(err, repository.ErrNotFound) {
			return apperr.Unauthorized()
		}
		if err != nil {
			return err
		}
		if rt.State == "revoked" {
			return apperr.Unauthorized()
		}
		u, d, err := s.activeDevice(ctx, tx, rt.DeviceID)
		if err != nil {
			return err
		}
		at2, rt2 := deriveSuccessors(s.secret, refreshToken)
		switch rt.State {
		case "active":
			if now.After(rt.ExpiresAt) {
				return apperr.Unauthorized()
			}
			if ok, err := s.d.RefreshTokens.MarkRotated(ctx, tx, rt.Hash, now); err != nil {
				return err
			} else if !ok {
				return apperr.Unauthorized()
			}
			tp = TokenPair{
				AccessToken: at2, AccessExpiresAt: now.Add(AccessTTL),
				RefreshToken: rt2, RefreshExpiresAt: now.Add(RefreshTTL),
			}
			if err := s.d.AccessTokens.Insert(ctx, tx, hashToken(at2), d.ID, tp.AccessExpiresAt); err != nil {
				return err
			}
			return s.d.RefreshTokens.Insert(ctx, tx, repository.RefreshToken{
				Hash: hashToken(rt2), DeviceID: d.ID, FamilyID: rt.FamilyID, State: "active",
				IssuedAt: now, ExpiresAt: tp.RefreshExpiresAt,
			})
		case "rotated":
			if rt.RotatedAt != nil && now.Sub(*rt.RotatedAt) <= RefreshGrace {
				return s.replaySuccessors(ctx, tx, at2, rt2, &tp)
			}
			reused = true
			if err := s.d.RefreshTokens.RevokeFamily(ctx, tx, rt.FamilyID); err != nil {
				return err
			}
			if err := s.d.Audit.Append(ctx, tx, auditEvent(now, u.ID, d.ID, "auth.refresh_reused",
				map[string]any{"family_id": rt.FamilyID})); err != nil {
				return err
			}
			return s.revokeDevice(ctx, tx, d, now)
		default:
			return apperr.Unauthorized()
		}
	})
	if err != nil {
		return TokenPair{}, err
	}
	if reused {
		return TokenPair{}, apperr.RefreshTokenReused()
	}
	return tp, nil
}

// replaySuccessors returns the already-stored successor pair with its stored
// expiries. A missing successor (for example, a different server secret)
// or a revoked one is unauthorized.
func (s *AuthService) replaySuccessors(ctx context.Context, db queries.DBTX, at2, rt2 string, tp *TokenPair) error {
	a, err := s.d.AccessTokens.Get(ctx, db, hashToken(at2))
	if errors.Is(err, repository.ErrNotFound) {
		return apperr.Unauthorized()
	}
	if err != nil {
		return err
	}
	r, err := s.d.RefreshTokens.Get(ctx, db, hashToken(rt2))
	if errors.Is(err, repository.ErrNotFound) {
		return apperr.Unauthorized()
	}
	if err != nil {
		return err
	}
	if r.State == "revoked" {
		return apperr.Unauthorized()
	}
	*tp = TokenPair{AccessToken: at2, AccessExpiresAt: a.ExpiresAt, RefreshToken: rt2, RefreshExpiresAt: r.ExpiresAt}
	return nil
}

func principalOf(u repository.User, d repository.Device, via string) Principal {
	return Principal{
		UserID: u.ID, Username: u.Username, Slug: u.Slug, Role: u.Role,
		DeviceID: d.ID, Platform: d.Platform, Via: via,
	}
}

// AuthenticateBearer resolves an access token. It only reads: revoked
// devices, disabled users and unknown tokens are unauthorized; an expired
// token is token_expired. Updating last_seen_at is the caller's job
// (DeviceService.TouchLastSeen).
func (s *AuthService) AuthenticateBearer(ctx context.Context, token string) (Principal, error) {
	if !strings.HasPrefix(token, prefixAccess) || len(token) == len(prefixAccess) {
		return Principal{}, apperr.Unauthorized()
	}
	at, err := s.d.AccessTokens.Get(ctx, s.d.Store.R, hashToken(token))
	if errors.Is(err, repository.ErrNotFound) {
		return Principal{}, apperr.Unauthorized()
	}
	if err != nil {
		return Principal{}, err
	}
	u, d, err := s.activeDevice(ctx, s.d.Store.R, at.DeviceID)
	if err != nil {
		return Principal{}, err
	}
	if s.now().After(at.ExpiresAt) {
		return Principal{}, apperr.TokenExpired()
	}
	return principalOf(u, d, ViaBearer), nil
}

// AuthenticateCookie resolves a pt_session cookie value. Unknown, expired or
// revoked sessions are unauthorized. Use slides the expiry to 30 days,
// written at most once per sessionTouchInterval.
func (s *AuthService) AuthenticateCookie(ctx context.Context, token string) (Principal, error) {
	if !strings.HasPrefix(token, prefixWebSession) || len(token) == len(prefixWebSession) {
		return Principal{}, apperr.Unauthorized()
	}
	h := hashToken(token)
	ws, err := s.d.WebSessions.Get(ctx, s.d.Store.R, h)
	if errors.Is(err, repository.ErrNotFound) {
		return Principal{}, apperr.Unauthorized()
	}
	if err != nil {
		return Principal{}, err
	}
	now := s.now()
	if now.After(ws.ExpiresAt) {
		return Principal{}, apperr.Unauthorized()
	}
	u, d, err := s.activeDevice(ctx, s.d.Store.R, ws.DeviceID)
	if err != nil {
		return Principal{}, err
	}
	if now.Sub(ws.LastUsedAt) >= sessionTouchInterval {
		err := s.d.WebSessions.Touch(ctx, s.d.Store.W, h, now, now.Add(WebSessionTTL))
		if errors.Is(err, repository.ErrNotFound) {
			return Principal{}, apperr.Unauthorized() // logged out concurrently
		}
		if err != nil {
			return Principal{}, err
		}
	}
	p := principalOf(u, d, ViaCookie)
	p.SessionHash = h
	return p, nil
}

// CheckCSRF reports whether csrf matches the cookie session's CSRF token,
// compared in constant time. Bearer principals need no CSRF token; any
// other principal (including the zero value) fails closed.
func (s *AuthService) CheckCSRF(ctx context.Context, p Principal, csrf string) bool {
	switch p.Via {
	case ViaBearer:
		return true
	case ViaCookie:
	default:
		return false
	}
	if csrf == "" || p.SessionHash == "" {
		return false
	}
	ws, err := s.d.WebSessions.Get(ctx, s.d.Store.R, p.SessionHash)
	if err != nil {
		return false
	}
	return equalHashes(hashToken(csrf), ws.CSRFHash)
}

// Logout revokes the caller's device: its refresh family or web session and
// its access tokens. Signing in again registers a new device.
func (s *AuthService) Logout(ctx context.Context, p Principal) error {
	return s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		if err := s.d.Audit.Append(ctx, tx, auditEvent(s.now(), p.UserID, p.DeviceID, "auth.logout", map[string]any{"via": p.Via})); err != nil {
			return err
		}
		return s.RevokeDevice(ctx, tx, p.DeviceID)
	})
}

// RevokeDevice marks the device revoked (keeping the first revocation time),
// deletes its access tokens and web sessions and revokes its refresh tokens.
// It is idempotent; an unknown device is not_found.
func (s *AuthService) RevokeDevice(ctx context.Context, db queries.DBTX, deviceID string) error {
	d, err := s.d.Devices.Get(ctx, db, deviceID)
	if errors.Is(err, repository.ErrNotFound) {
		return apperr.NotFound()
	}
	if err != nil {
		return err
	}
	return s.revokeDevice(ctx, db, d, s.now())
}

func (s *AuthService) revokeDevice(ctx context.Context, db queries.DBTX, d repository.Device, now time.Time) error {
	if d.RevokedAt == nil {
		if err := s.d.Devices.Revoke(ctx, db, d.ID, now); err != nil {
			return err
		}
		if err := s.d.Audit.Append(ctx, db, auditEvent(now, d.UserID, d.ID, "device.revoked", nil)); err != nil {
			return err
		}
	}
	if err := s.d.AccessTokens.DeleteByDevice(ctx, db, d.ID); err != nil {
		return err
	}
	if err := s.d.RefreshTokens.RevokeByDevice(ctx, db, d.ID); err != nil {
		return err
	}
	return s.d.WebSessions.DeleteByDevice(ctx, db, d.ID)
}
