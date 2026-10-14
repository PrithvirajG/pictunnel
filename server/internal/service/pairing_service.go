package service

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// PairingServiceDeps are the PairingService dependencies. Fingerprint is the
// leaf certificate's SPKI SHA-256 in base64url; Endpoints returns the QR `u`
// values in preference order (LAN first, then remote). Secret is the 32-byte
// server secret; codes are stored as HMAC-SHA256(Secret, canonical code).
type PairingServiceDeps struct {
	Store        *store.Store
	PairingCodes repository.PairingCodesRepository
	Devices      repository.DevicesRepository
	Users        repository.UsersRepository
	Audit        repository.AuditLogRepository
	Auth         *AuthService
	Clock        clock.Clock
	ServerID     string
	Fingerprint  string
	Endpoints    func() []string
	Secret       []byte
}

// PairingService creates and redeems pairing codes (S§4.3, P§6.3).
type PairingService struct {
	d PairingServiceDeps

	mu       sync.Mutex
	failures int // server-wide failed redemptions since the last invalidation
}

// NewPairingService returns a PairingService. The secret must be exactly
// 32 bytes; it is copied.
func NewPairingService(d PairingServiceDeps) (*PairingService, error) {
	if err := checkSecret(d.Secret); err != nil {
		return nil, err
	}
	d.Secret = bytes.Clone(d.Secret)
	return &PairingService{d: d}, nil
}

// codeHash is the stored form of a canonical pairing code:
// hex HMAC-SHA256(server secret, code).
func (s *PairingService) codeHash(code string) string {
	m := hmac.New(sha256.New, s.d.Secret)
	m.Write([]byte(code))
	return hex.EncodeToString(m.Sum(nil))
}

const (
	pairingCodeTTL     = 10 * time.Minute
	pairingMaxFailures = 5
	crockford          = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	pairingCodeLen     = 10
)

// newPairingCode returns 10 Crockford base32 characters from crypto/rand,
// formatted XXXX-XXXX-XX.
func newPairingCode() string {
	b := make([]byte, pairingCodeLen)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = crockford[b[i]&31] // 256 is a multiple of 32: uniform
	}
	return formatPairingCode(string(b))
}

func formatPairingCode(c string) string { return c[:4] + "-" + c[4:8] + "-" + c[8:] }

// normalizePairingCode accepts a typed code: case-insensitive, with or
// without dashes and spaces, and with Crockford aliases (I, L → 1; O → 0).
func normalizePairingCode(in string) (string, bool) {
	var b strings.Builder
	for _, r := range strings.ToUpper(in) {
		switch r {
		case '-', ' ', '\t':
			continue
		case 'I', 'L':
			r = '1'
		case 'O':
			r = '0'
		}
		if r > 127 || !strings.ContainsRune(crockford, r) {
			return "", false
		}
		b.WriteRune(r)
	}
	if b.Len() != pairingCodeLen {
		return "", false
	}
	return formatPairingCode(b.String()), true
}

// Create issues a single-use pairing code for the caller with its QR URI.
// With no endpoint to put in the QR URI it fails with internal before
// storing a code.
func (s *PairingService) Create(ctx context.Context, p Principal) (code, qrURI string, expiresAt time.Time, err error) {
	eps := s.endpoints()
	if len(eps) == 0 {
		return "", "", time.Time{}, apperr.Internal()
	}
	now := msNow(s.d.Clock.Now())
	expiresAt = now.Add(pairingCodeTTL)
	for attempt := 0; ; attempt++ {
		code = newPairingCode()
		err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
			return s.d.PairingCodes.Insert(ctx, tx, repository.PairingCode{
				CodeHash: s.codeHash(code), UserID: p.UserID, CreatedAt: now, ExpiresAt: expiresAt,
			})
		})
		if err == nil {
			break
		}
		if !errors.Is(err, repository.ErrUniqueViolation) || attempt >= 2 {
			return "", "", time.Time{}, err
		}
	}
	return code, s.qrURI(code, eps), expiresAt, nil
}

// endpoints returns the configured endpoints, empty ones and duplicates
// removed, in order.
func (s *PairingService) endpoints() []string {
	if s.d.Endpoints == nil {
		return nil
	}
	var out []string
	seen := map[string]bool{}
	for _, e := range s.d.Endpoints() {
		if e != "" && !seen[e] {
			seen[e] = true
			out = append(out, e)
		}
	}
	return out
}

// qrURI builds pictunnel://pair?v=1&sid=…&code=…&fp=…&u=…&u=… (P§6.3) with
// each endpoint URL-encoded and repeated in order.
func (s *PairingService) qrURI(code string, endpoints []string) string {
	var b strings.Builder
	b.WriteString("pictunnel://pair?v=1&sid=")
	b.WriteString(url.QueryEscape(s.d.ServerID))
	b.WriteString("&code=")
	b.WriteString(url.QueryEscape(code))
	b.WriteString("&fp=")
	b.WriteString(url.QueryEscape(s.d.Fingerprint))
	for _, e := range endpoints {
		b.WriteString("&u=")
		b.WriteString(url.QueryEscape(e))
	}
	return b.String()
}

// Redeem consumes a pairing code, registering the device for the code's
// owner and issuing tokens. An unknown, used, expired or invalidated code is
// pairing_code_invalid and counts toward the server-wide failure limit:
// after 5 failures every outstanding code is invalidated.
func (s *PairingService) Redeem(ctx context.Context, code string, dev DeviceInfo) (repository.User, repository.Device, TokenPair, error) {
	dev, err := dev.validate()
	if err != nil {
		return repository.User{}, repository.Device{}, TokenPair{}, err
	}
	canon, ok := normalizePairingCode(code)
	if !ok {
		return repository.User{}, repository.Device{}, TokenPair{}, s.fail(ctx, "malformed")
	}
	var u repository.User
	var d repository.Device
	var tp TokenPair
	failed := false
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		now := msNow(s.d.Clock.Now())
		h := s.codeHash(canon)
		redeemed, err := s.d.PairingCodes.MarkRedeemed(ctx, tx, h, now)
		if err != nil {
			return err
		}
		if !redeemed {
			failed = true
			return apperr.PairingCodeInvalid()
		}
		pc, err := s.d.PairingCodes.Get(ctx, tx, h)
		if err != nil {
			return err
		}
		if u, err = s.d.Users.GetByID(ctx, tx, pc.UserID); err != nil {
			return err
		}
		if u.DisabledAt != nil {
			return apperr.PairingCodeInvalid()
		}
		d = repository.Device{
			ID: ids.New(), UserID: u.ID, Name: dev.Name, Platform: dev.Platform, AppVersion: dev.AppVersion,
			CreatedAt: now,
		}
		if err := s.d.Devices.Insert(ctx, tx, d); err != nil {
			return err
		}
		if tp, err = s.d.Auth.IssueForDevice(ctx, tx, d.ID); err != nil {
			return err
		}
		return s.d.Audit.Append(ctx, tx, auditEvent(now, u.ID, d.ID, "pairing.redeemed", nil))
	})
	if failed {
		return repository.User{}, repository.Device{}, TokenPair{}, s.fail(ctx, "invalid")
	}
	if err != nil {
		return repository.User{}, repository.Device{}, TokenPair{}, err
	}
	return u, d, tp, nil
}

// fail records a failed redemption (reason "malformed" or "invalid") with an
// audit event that never includes the code, and returns the error for the
// caller. At pairingMaxFailures it invalidates every outstanding code and
// resets the counter; if that write fails the counter stays at the limit so
// the next failure retries it.
func (s *PairingService) fail(ctx context.Context, reason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := msNow(s.d.Clock.Now())
	s.failures++
	var invalidated int64
	if s.failures >= pairingMaxFailures {
		n, err := s.d.PairingCodes.InvalidateOutstanding(ctx, s.d.Store.W, now)
		if err != nil {
			return err
		}
		invalidated = n
		s.failures = 0
	}
	if err := s.d.Audit.Append(ctx, s.d.Store.W, auditEvent(now, "", "", "pairing.failed",
		map[string]any{"reason": reason, "invalidated": invalidated})); err != nil {
		return err
	}
	return apperr.PairingCodeInvalid()
}
