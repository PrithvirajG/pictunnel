// Package repository holds one stateless repository per table. Methods take
// the caller's queries.DBTX so the caller chooses the reader pool or a write
// transaction.
package repository

import "time"

const timeLayout = "2006-01-02T15:04:05.000Z"

func formatTime(t time.Time) string { return t.UTC().Format(timeLayout) }

func formatTimePtr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := formatTime(*t)
	return &s
}

func parseTime(s string) (time.Time, error) {
	t, err := time.Parse(timeLayout, s)
	if err != nil {
		return time.Time{}, err
	}
	return t.UTC(), nil
}

func parseTimePtr(s *string) (*time.Time, error) {
	if s == nil {
		return nil, nil
	}
	t, err := parseTime(*s)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// parseTimes parses several non-null timestamps, returning the first error.
func parseTimes(ss ...string) ([]time.Time, error) {
	out := make([]time.Time, len(ss))
	for i, s := range ss {
		t, err := parseTime(s)
		if err != nil {
			return nil, err
		}
		out[i] = t
	}
	return out, nil
}

func boolInt(b bool) int64 {
	if b {
		return 1
	}
	return 0
}
