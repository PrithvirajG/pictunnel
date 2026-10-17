package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// AccessToken is a row of the access_tokens table.
type AccessToken struct {
	TokenHash string
	DeviceID  string
	ExpiresAt time.Time
}

// AccessTokensRepository accesses the access_tokens table.
type AccessTokensRepository struct{}

// Insert stores a hashed access token.
func (AccessTokensRepository) Insert(ctx context.Context, db queries.DBTX, hash, deviceID string, expiresAt time.Time) error {
	return mapErr(queries.New(db).InsertAccessToken(ctx, queries.InsertAccessTokenParams{
		TokenHash: hash, DeviceID: deviceID, ExpiresAt: formatTime(expiresAt),
	}))
}

// Get returns the token or ErrNotFound.
func (AccessTokensRepository) Get(ctx context.Context, db queries.DBTX, hash string) (AccessToken, error) {
	r, err := queries.New(db).GetAccessToken(ctx, hash)
	if err != nil {
		return AccessToken{}, mapErr(err)
	}
	exp, err := parseTime(r.ExpiresAt)
	if err != nil {
		return AccessToken{}, err
	}
	return AccessToken{TokenHash: r.TokenHash, DeviceID: r.DeviceID, ExpiresAt: exp}, nil
}

// DeleteByDevice removes every access token of the device.
func (AccessTokensRepository) DeleteByDevice(ctx context.Context, db queries.DBTX, deviceID string) error {
	return queries.New(db).DeleteAccessTokensByDevice(ctx, deviceID)
}

// DeleteExpired removes tokens that expired before now and returns the count.
func (AccessTokensRepository) DeleteExpired(ctx context.Context, db queries.DBTX, now time.Time) (int64, error) {
	return queries.New(db).DeleteExpiredAccessTokens(ctx, formatTime(now))
}
