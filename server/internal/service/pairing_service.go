package service

import (
	"context"
	"crypto/rand"
	"database/sql"
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
// values in preference order (LAN first, then remote).
type PairingServiceDeps struct {
	Store        *store.Store
	PairingCodes repository.PairingCodesRepository
	Devices      repository.DevicesRepository
	Users        repository.UsersRepository
	Auth         *AuthService
	Clock        clock.Clock
	ServerID     string
	Fingerprint  string
	Endpoints    func() []string
}

// PairingService creates and redeems pairing codes (S§4.3, P§6.3).
type PairingService struct {
	d PairingServiceDeps

	mu       sync.Mutex
	failures int // server-wide failed redemptions since the last invalidation
}

// NewPairingService returns a PairingService.
func NewPairingService(d PairingServiceDeps) *PairingService { return &PairingService{d: d} }

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
func (s *PairingService) Create(ctx context.Context, p Principal) (code, qrURI string, expiresAt time.Time, err error) {
	now := msNow(s.d.Clock.Now())
	expiresAt = now.Add(pairingCodeTTL)
	for attempt := 0; ; attempt++ {
		code = newPairingCode()
		err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
			return s.d.PairingCodes.Insert(ctx, tx, repository.PairingCode{
				CodeHash: hashToken(code), UserID: p.UserID, CreatedAt: now, ExpiresAt: expiresAt,
			})
		})
		if err == nil {
			break
		}
		if !errors.Is(err, repository.ErrUniqueViolation) || attempt >= 2 {
			return "", "", time.Time{}, err
		}
	}
	return code, s.qrURI(code), expiresAt, nil
}

// qrURI builds pictunnel://pair?v=1&sid=…&code=…&fp=…&u=…&u=… (P§6.3) with
// each endpoint URL-encoded, in order, duplicates removed.
func (s *PairingService) qrURI(code string) string {
	var b strings.Builder
	b.WriteString("pictunnel://pair?v=1&sid=")
	b.WriteString(url.QueryEscape(s.d.ServerID))
	b.WriteString("&code=")
	b.WriteString(url.QueryEscape(code))
	b.WriteString("&fp=")
	b.WriteString(url.QueryEscape(s.d.Fingerprint))
	if s.d.Endpoints != nil {
		seen := map[string]bool{}
		for _, e := range s.d.Endpoints() {
			if e == "" || seen[e] {
				continue
			}
			seen[e] = true
			b.WriteString("&u=")
			b.WriteString(url.QueryEscape(e))
		}
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
		return repository.User{}, repository.Device{}, TokenPair{}, s.fail(ctx)
	}
	var u repository.User
	var d repository.Device
	var tp TokenPair
	failed := false
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		now := msNow(s.d.Clock.Now())
		h := hashToken(canon)
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
			CreatedAt: now, LastSeenAt: now,
		}
		if err := s.d.Devices.Insert(ctx, tx, d); err != nil {
			return err
		}
		tp, err = s.d.Auth.IssueForDevice(ctx, tx, d.ID)
		return err
	})
	if failed {
		return repository.User{}, repository.Device{}, TokenPair{}, s.fail(ctx)
	}
	if err != nil {
		return repository.User{}, repository.Device{}, TokenPair{}, err
	}
	return u, d, tp, nil
}

// fail records a failed redemption and returns the error for the caller.
// At pairingMaxFailures it invalidates every outstanding code and resets
// the counter; if that write fails the counter stays at the limit so the
// next failure retries it.
func (s *PairingService) fail(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failures++
	if s.failures >= pairingMaxFailures {
		if _, err := s.d.PairingCodes.InvalidateOutstanding(ctx, s.d.Store.W, msNow(s.d.Clock.Now())); err != nil {
			return err
		}
		s.failures = 0
	}
	return apperr.PairingCodeInvalid()
}
