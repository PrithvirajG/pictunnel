package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// RefreshToken is a row of the refresh_tokens table.
type RefreshToken struct {
	Hash      string
	DeviceID  string
	FamilyID  string
	State     string // active | rotated | revoked
	IssuedAt  time.Time
	RotatedAt *time.Time
	ExpiresAt time.Time
}

// RefreshTokensRepository accesses the refresh_tokens table.
type RefreshTokensRepository struct{}

// Insert stores a refresh token.
func (RefreshTokensRepository) Insert(ctx context.Context, db queries.DBTX, t RefreshToken) error {
	return mapErr(queries.New(db).InsertRefreshToken(ctx, queries.InsertRefreshTokenParams{
		TokenHash: t.Hash, DeviceID: t.DeviceID, FamilyID: t.FamilyID, State: t.State,
		IssuedAt: formatTime(t.IssuedAt), RotatedAt: formatTimePtr(t.RotatedAt), ExpiresAt: formatTime(t.ExpiresAt),
	}))
}

// Get returns the token or ErrNotFound.
func (RefreshTokensRepository) Get(ctx context.Context, db queries.DBTX, hash string) (RefreshToken, error) {
	r, err := queries.New(db).GetRefreshToken(ctx, hash)
	if err != nil {
		return RefreshToken{}, mapErr(err)
	}
	ts, err := parseTimes(r.IssuedAt, r.ExpiresAt)
	if err != nil {
		return RefreshToken{}, err
	}
	rot, err := parseTimePtr(r.RotatedAt)
	if err != nil {
		return RefreshToken{}, err
	}
	return RefreshToken{
		Hash: r.TokenHash, DeviceID: r.DeviceID, FamilyID: r.FamilyID, State: r.State,
		IssuedAt: ts[0], RotatedAt: rot, ExpiresAt: ts[1],
	}, nil
}

// MarkRotated moves an active token to rotated. It reports false when the
// token was not active (already rotated, revoked or missing), so it is
// single-shot.
func (RefreshTokensRepository) MarkRotated(ctx context.Context, db queries.DBTX, hash string, at time.Time) (bool, error) {
	s := formatTime(at)
	n, err := queries.New(db).MarkRefreshTokenRotated(ctx, queries.MarkRefreshTokenRotatedParams{RotatedAt: &s, TokenHash: hash})
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// RevokeFamily revokes every token in the family.
func (RefreshTokensRepository) RevokeFamily(ctx context.Context, db queries.DBTX, familyID string) error {
	return queries.New(db).RevokeRefreshTokenFamily(ctx, familyID)
}

// RevokeByDevice revokes every token of the device.
func (RefreshTokensRepository) RevokeByDevice(ctx context.Context, db queries.DBTX, deviceID string) error {
	return queries.New(db).RevokeRefreshTokensByDevice(ctx, deviceID)
}

// DeleteExpired removes tokens that expired before now and returns the count.
func (RefreshTokensRepository) DeleteExpired(ctx context.Context, db queries.DBTX, now time.Time) (int64, error) {
	return queries.New(db).DeleteExpiredRefreshTokens(ctx, formatTime(now))
}
