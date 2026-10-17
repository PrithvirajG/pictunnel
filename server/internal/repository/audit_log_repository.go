package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// AuditEvent is a row of the audit_log table.
type AuditEvent struct {
	ID         string
	At         time.Time
	UserID     *string
	DeviceID   *string
	Event      string
	DetailJSON string
}

// AuditLogRepository accesses the audit_log table.
type AuditLogRepository struct{}

// Append stores an audit event.
func (AuditLogRepository) Append(ctx context.Context, db queries.DBTX, e AuditEvent) error {
	return mapErr(queries.New(db).AppendAuditEvent(ctx, queries.AppendAuditEventParams{
		ID: e.ID, At: formatTime(e.At), UserID: e.UserID, DeviceID: e.DeviceID, Event: e.Event, DetailJson: e.DetailJSON,
	}))
}

// List returns the newest events first, up to limit.
func (AuditLogRepository) List(ctx context.Context, db queries.DBTX, limit int) ([]AuditEvent, error) {
	rows, err := queries.New(db).ListAuditEvents(ctx, int64(limit))
	if err != nil {
		return nil, err
	}
	out := make([]AuditEvent, 0, len(rows))
	for _, r := range rows {
		at, err := parseTime(r.At)
		if err != nil {
			return nil, err
		}
		out = append(out, AuditEvent{ID: r.ID, At: at, UserID: r.UserID, DeviceID: r.DeviceID, Event: r.Event, DetailJSON: r.DetailJson})
	}
	return out, nil
}
