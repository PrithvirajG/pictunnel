package service

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// DeviceServiceDeps are the DeviceService dependencies.
type DeviceServiceDeps struct {
	Store   *store.Store
	Devices repository.DevicesRepository
	Auth    *AuthService
	Clock   clock.Clock
}

// DeviceService lists, renames and revokes the caller's devices.
type DeviceService struct {
	d DeviceServiceDeps

	mu       sync.Mutex
	lastSeen map[string]time.Time // device id → last written last_seen_at
}

// NewDeviceService returns a DeviceService.
func NewDeviceService(d DeviceServiceDeps) *DeviceService {
	return &DeviceService{d: d, lastSeen: map[string]time.Time{}}
}

// lastSeenInterval is the minimum spacing of last_seen_at writes per device.
const lastSeenInterval = time.Minute

// List returns the caller's non-revoked devices.
func (s *DeviceService) List(ctx context.Context, p Principal) ([]repository.Device, error) {
	return s.d.Devices.ListByUser(ctx, s.d.Store.R, p.UserID)
}

// ownedDevice returns the caller's non-revoked device, or not_found.
func (s *DeviceService) ownedDevice(ctx context.Context, tx *sql.Tx, p Principal, id string) (repository.Device, error) {
	d, err := s.d.Devices.Get(ctx, tx, id)
	if errors.Is(err, repository.ErrNotFound) || (err == nil && d.UserID != p.UserID) {
		return repository.Device{}, apperr.NotFound()
	}
	return d, err
}

// Rename sets the name of one of the caller's active devices. Another
// user's, a revoked or an unknown device is not_found.
func (s *DeviceService) Rename(ctx context.Context, p Principal, id, name string) (repository.Device, error) {
	n, err := cleanDeviceName(name)
	if err != nil {
		return repository.Device{}, err
	}
	var d repository.Device
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		var err error
		if d, err = s.ownedDevice(ctx, tx, p, id); err != nil {
			return err
		}
		if d.RevokedAt != nil {
			return apperr.NotFound()
		}
		if err := s.d.Devices.Rename(ctx, tx, id, n); err != nil {
			return err
		}
		d.Name = n
		return nil
	})
	if err != nil {
		return repository.Device{}, err
	}
	return d, nil
}

// Revoke revokes one of the caller's devices; it is idempotent. Another
// user's or an unknown device is not_found.
func (s *DeviceService) Revoke(ctx context.Context, p Principal, id string) error {
	return s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		if _, err := s.ownedDevice(ctx, tx, p, id); err != nil {
			return err
		}
		return s.d.Auth.RevokeDevice(ctx, tx, id)
	})
}

// TouchLastSeen records device activity, writing last_seen_at at most once
// per minute per device (tracked in memory). An unknown device is ignored.
func (s *DeviceService) TouchLastSeen(ctx context.Context, deviceID string) error {
	now := msNow(s.d.Clock.Now())
	s.mu.Lock()
	if last, ok := s.lastSeen[deviceID]; ok && now.Sub(last) < lastSeenInterval {
		s.mu.Unlock()
		return nil
	}
	prev, hadPrev := s.lastSeen[deviceID]
	s.lastSeen[deviceID] = now
	s.mu.Unlock()

	err := s.d.Devices.TouchLastSeen(ctx, s.d.Store.W, deviceID, now)
	if errors.Is(err, repository.ErrNotFound) {
		s.forget(deviceID, now, prev, hadPrev)
		return nil
	}
	if err != nil {
		s.forget(deviceID, now, prev, hadPrev)
		return err
	}
	return nil
}

// forget undoes a reservation made by TouchLastSeen whose write failed,
// unless a later call has replaced it.
func (s *DeviceService) forget(deviceID string, reserved, prev time.Time, hadPrev bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cur, ok := s.lastSeen[deviceID]; ok && cur.Equal(reserved) {
		if hadPrev {
			s.lastSeen[deviceID] = prev
		} else {
			delete(s.lastSeen, deviceID)
		}
	}
}
