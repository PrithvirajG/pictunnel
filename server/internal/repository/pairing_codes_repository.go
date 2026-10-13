package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// PairingCode is a row of the pairing_codes table.
type PairingCode struct {
	CodeHash      string
	UserID        string
	CreatedAt     time.Time
	ExpiresAt     time.Time
	RedeemedAt    *time.Time
	InvalidatedAt *time.Time
}

// PairingCodesRepository accesses the pairing_codes table.
type PairingCodesRepository struct{}

// Insert stores a pairing code.
func (PairingCodesRepository) Insert(ctx context.Context, db queries.DBTX, c PairingCode) error {
	return mapErr(queries.New(db).InsertPairingCode(ctx, queries.InsertPairingCodeParams{
		CodeHash: c.CodeHash, UserID: c.UserID, CreatedAt: formatTime(c.CreatedAt), ExpiresAt: formatTime(c.ExpiresAt),
		RedeemedAt: formatTimePtr(c.RedeemedAt), InvalidatedAt: formatTimePtr(c.InvalidatedAt),
	}))
}

// Get returns the code or ErrNotFound.
func (PairingCodesRepository) Get(ctx context.Context, db queries.DBTX, hash string) (PairingCode, error) {
	r, err := queries.New(db).GetPairingCode(ctx, hash)
	if err != nil {
		return PairingCode{}, mapErr(err)
	}
	ts, err := parseTimes(r.CreatedAt, r.ExpiresAt)
	if err != nil {
		return PairingCode{}, err
	}
	red, err := parseTimePtr(r.RedeemedAt)
	if err != nil {
		return PairingCode{}, err
	}
	inv, err := parseTimePtr(r.InvalidatedAt)
	if err != nil {
		return PairingCode{}, err
	}
	return PairingCode{CodeHash: r.CodeHash, UserID: r.UserID, CreatedAt: ts[0], ExpiresAt: ts[1], RedeemedAt: red, InvalidatedAt: inv}, nil
}

// MarkRedeemed redeems the code. It reports false when the code is missing,
// already redeemed, invalidated or expired (expires_at < at).
func (PairingCodesRepository) MarkRedeemed(ctx context.Context, db queries.DBTX, hash string, at time.Time) (bool, error) {
	s := formatTime(at)
	n, err := queries.New(db).MarkPairingCodeRedeemed(ctx, queries.MarkPairingCodeRedeemedParams{At: &s, CodeHash: hash})
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// InvalidateOutstanding invalidates every unredeemed, unexpired code and
// returns how many were invalidated.
func (PairingCodesRepository) InvalidateOutstanding(ctx context.Context, db queries.DBTX, now time.Time) (int64, error) {
	s := formatTime(now)
	return queries.New(db).InvalidateOutstandingPairingCodes(ctx, &s)
}

// DeleteExpired removes codes that expired before now and returns the count.
func (PairingCodesRepository) DeleteExpired(ctx context.Context, db queries.DBTX, now time.Time) (int64, error) {
	return queries.New(db).DeleteExpiredPairingCodes(ctx, formatTime(now))
}
