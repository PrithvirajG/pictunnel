package httpapi

import (
	"context"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
)

// ListDevices lists the caller's active devices.
func (s *server) ListDevices(ctx context.Context, _ gen.ListDevicesRequestObject) (gen.ListDevicesResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	ds, err := s.d.Devices.List(ctx, p)
	if err != nil {
		return nil, err
	}
	var m mapper
	out := gen.ListDevices200JSONResponse{Devices: make([]gen.Device, 0, len(ds))}
	for _, d := range ds {
		out.Devices = append(out.Devices, m.device(d))
	}
	return out, m.err
}

// UpdateDevice renames one of the caller's devices.
func (s *server) UpdateDevice(ctx context.Context, req gen.UpdateDeviceRequestObject) (gen.UpdateDeviceResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	d, err := s.d.Devices.Rename(ctx, p, req.DeviceId.String(), req.Body.Name)
	if err != nil {
		return nil, err
	}
	var m mapper
	out := gen.UpdateDevice200JSONResponse(m.device(d))
	return out, m.err
}

// RevokeDevice revokes one of the caller's devices (idempotent).
func (s *server) RevokeDevice(ctx context.Context, req gen.RevokeDeviceRequestObject) (gen.RevokeDeviceResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	if err := s.d.Devices.Revoke(ctx, p, req.DeviceId.String()); err != nil {
		return nil, err
	}
	return gen.RevokeDevice204Response{}, nil
}
