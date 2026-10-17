package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// Device is a row of the devices table.
type Device struct {
	ID         string
	UserID     string
	Name       string
	Platform   string
	AppVersion string
	CreatedAt  time.Time
	LastSeenAt *time.Time // nil until the first authenticated request
	RevokedAt  *time.Time
}

// DevicesRepository accesses the devices table.
type DevicesRepository struct{}

func deviceFromRow(r queries.Device) (Device, error) {
	created, err := parseTime(r.CreatedAt)
	if err != nil {
		return Device{}, err
	}
	seen, err := parseTimePtr(r.LastSeenAt)
	if err != nil {
		return Device{}, err
	}
	rev, err := parseTimePtr(r.RevokedAt)
	if err != nil {
		return Device{}, err
	}
	return Device{
		ID: r.ID, UserID: r.UserID, Name: r.Name, Platform: r.Platform, AppVersion: r.AppVersion,
		CreatedAt: created, LastSeenAt: seen, RevokedAt: rev,
	}, nil
}

// Insert adds a device.
func (DevicesRepository) Insert(ctx context.Context, db queries.DBTX, d Device) error {
	return mapErr(queries.New(db).InsertDevice(ctx, queries.InsertDeviceParams{
		ID: d.ID, UserID: d.UserID, Name: d.Name, Platform: d.Platform, AppVersion: d.AppVersion,
		CreatedAt: formatTime(d.CreatedAt), LastSeenAt: formatTimePtr(d.LastSeenAt), RevokedAt: formatTimePtr(d.RevokedAt),
	}))
}

// Get returns the device (revoked or not) or ErrNotFound.
func (DevicesRepository) Get(ctx context.Context, db queries.DBTX, id string) (Device, error) {
	r, err := queries.New(db).GetDevice(ctx, id)
	if err != nil {
		return Device{}, mapErr(err)
	}
	return deviceFromRow(r)
}

// ListByUser returns the user's non-revoked devices.
func (DevicesRepository) ListByUser(ctx context.Context, db queries.DBTX, userID string) ([]Device, error) {
	rows, err := queries.New(db).ListDevicesByUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]Device, 0, len(rows))
	for _, r := range rows {
		d, err := deviceFromRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, nil
}

// Rename sets the device name.
func (DevicesRepository) Rename(ctx context.Context, db queries.DBTX, id, name string) error {
	return requireRow(queries.New(db).RenameDevice(ctx, queries.RenameDeviceParams{Name: name, ID: id}))
}

// Revoke marks the device revoked at the given time.
func (DevicesRepository) Revoke(ctx context.Context, db queries.DBTX, id string, at time.Time) error {
	s := formatTime(at)
	return requireRow(queries.New(db).RevokeDevice(ctx, queries.RevokeDeviceParams{RevokedAt: &s, ID: id}))
}

// TouchLastSeen updates last_seen_at.
func (DevicesRepository) TouchLastSeen(ctx context.Context, db queries.DBTX, id string, at time.Time) error {
	return requireRow(queries.New(db).TouchDeviceLastSeen(ctx, queries.TouchDeviceLastSeenParams{LastSeenAt: formatTimePtr(&at), ID: id}))
}
