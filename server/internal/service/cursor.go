package service

import (
	"context"
	"encoding/base64"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// Change-log kinds (P§7.6) and the server_state key holding the compaction
// floor (S§7).
const (
	changeAssetRemoved = "asset.removed"
	changeLogFloorKey  = "change_log_floor"
)

// Paging limits (P§7.2, P§7.6, OpenAPI Limit).
const (
	maxPageLimit          = 1000
	defaultSnapshotLimit  = 1000
	defaultChangesLimit   = 500
	defaultTombstoneLimit = 200
	maxBulkIDs            = 1000
)

// EncodeCursor renders a change-log seq as a feed cursor: "c_" followed by
// 16 lowercase hex digits.
func EncodeCursor(seq int64) string { return fmt.Sprintf("c_%016x", seq) }

// DecodeCursor parses a feed cursor. Anything not produced by EncodeCursor
// for a non-negative seq is an error.
func DecodeCursor(s string) (int64, error) {
	if len(s) != 18 || !strings.HasPrefix(s, "c_") {
		return 0, fmt.Errorf("cursor: malformed %q", s)
	}
	for _, c := range s[2:] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return 0, fmt.Errorf("cursor: malformed %q", s)
		}
	}
	v, err := strconv.ParseUint(s[2:], 16, 64)
	if err != nil || v > math.MaxInt64 {
		return 0, fmt.Errorf("cursor: out of range %q", s)
	}
	return int64(v), nil
}

// pageLimit applies a default to limit <= 0 and rejects limits above 1000.
func pageLimit(limit, def int) (int, error) {
	switch {
	case limit < 0 || limit > maxPageLimit:
		return 0, apperr.InvalidRequest("limit must be between 1 and 1000")
	case limit == 0:
		return def, nil
	}
	return limit, nil
}

// encodeToken wraps opaque "a|b" paging state in URL-safe base64.
func encodeToken(parts ...string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strings.Join(parts, "|")))
}

// decodeToken reverses encodeToken, requiring exactly n non-empty parts.
func decodeToken(tok string, n int) ([]string, bool) {
	b, err := base64.RawURLEncoding.DecodeString(tok)
	if err != nil {
		return nil, false
	}
	parts := strings.Split(string(b), "|")
	if len(parts) != n {
		return nil, false
	}
	for _, p := range parts {
		if p == "" {
			return nil, false
		}
	}
	return parts, true
}

// appendAssetChange appends a change for the asset and deletes the asset's
// earlier rows (one row per asset, S§3). It does not stamp updated_seq.
func appendAssetChange(ctx context.Context, tx queries.DBTX, cl repository.ChangeLogRepository,
	ownerID, kind, assetID string, now time.Time) (int64, error) {
	seq, err := cl.Append(ctx, tx, ownerID, kind, assetID, now)
	if err != nil {
		return 0, err
	}
	if _, err := cl.DeleteForAsset(ctx, tx, assetID, seq); err != nil {
		return 0, err
	}
	return seq, nil
}

// appendAssetUpsert appends asset.upsert, compacts the asset's earlier rows
// and stamps assets.updated_seq, all on tx.
func appendAssetUpsert(ctx context.Context, tx queries.DBTX, cl repository.ChangeLogRepository, assets repository.AssetsRepository,
	ownerID, assetID string, now time.Time) (int64, error) {
	seq, err := appendAssetChange(ctx, tx, cl, ownerID, changeAssetUpsert, assetID, now)
	if err != nil {
		return 0, err
	}
	return seq, assets.SetUpdatedSeq(ctx, tx, assetID, seq)
}
