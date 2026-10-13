package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// WebSession is a row of the web_sessions table.
type WebSession struct {
	TokenHash  string
	DeviceID   string
	CSRFHash   string
	ExpiresAt  time.Time
	LastUsedAt time.Time
}

// WebSessionsRepository accesses the web_sessions table.
type WebSessionsRepository struct{}

// Insert stores a web session.
func (WebSessionsRepository) Insert(ctx context.Context, db queries.DBTX, w WebSession) error {
	return mapErr(queries.New(db).InsertWebSession(ctx, queries.InsertWebSessionParams{
		TokenHash: w.TokenHash, DeviceID: w.DeviceID, CsrfHash: w.CSRFHash,
		ExpiresAt: formatTime(w.ExpiresAt), LastUsedAt: formatTime(w.LastUsedAt),
	}))
}

// Get returns the session or ErrNotFound.
func (WebSessionsRepository) Get(ctx context.Context, db queries.DBTX, hash string) (WebSession, error) {
	r, err := queries.New(db).GetWebSession(ctx, hash)
	if err != nil {
		return WebSession{}, mapErr(err)
	}
	ts, err := parseTimes(r.ExpiresAt, r.LastUsedAt)
	if err != nil {
		return WebSession{}, err
	}
	return WebSession{TokenHash: r.TokenHash, DeviceID: r.DeviceID, CSRFHash: r.CsrfHash, ExpiresAt: ts[0], LastUsedAt: ts[1]}, nil
}

// Touch records use and slides the expiry.
func (WebSessionsRepository) Touch(ctx context.Context, db queries.DBTX, hash string, lastUsed, expires time.Time) error {
	return requireRow(queries.New(db).TouchWebSession(ctx, queries.TouchWebSessionParams{
		LastUsedAt: formatTime(lastUsed), ExpiresAt: formatTime(expires), TokenHash: hash,
	}))
}

// DeleteByDevice removes every session of the device.
func (WebSessionsRepository) DeleteByDevice(ctx context.Context, db queries.DBTX, deviceID string) error {
	return queries.New(db).DeleteWebSessionsByDevice(ctx, deviceID)
}

// DeleteExpired removes sessions that expired before now and returns the count.
func (WebSessionsRepository) DeleteExpired(ctx context.Context, db queries.DBTX, now time.Time) (int64, error) {
	return queries.New(db).DeleteExpiredWebSessions(ctx, formatTime(now))
}
