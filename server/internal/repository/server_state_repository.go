package repository

import (
	"context"
	"database/sql"
	"errors"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// ServerStateRepository accesses the server_state key/value table.
type ServerStateRepository struct{}

// Get returns the value for key and whether it exists.
func (ServerStateRepository) Get(ctx context.Context, db queries.DBTX, key string) (string, bool, error) {
	v, err := queries.New(db).GetServerState(ctx, key)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

// Set upserts key to value.
func (ServerStateRepository) Set(ctx context.Context, db queries.DBTX, key, value string) error {
	return queries.New(db).UpsertServerState(ctx, queries.UpsertServerStateParams{Key: key, Value: value})
}
