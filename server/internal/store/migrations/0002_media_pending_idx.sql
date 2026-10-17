-- +goose Up
-- Boot re-enqueues media jobs for assets whose derived data is incomplete.
CREATE INDEX assets_media_pending_idx ON assets(id)
    WHERE thumbnails_ready = 0 OR (kind = 'video' AND (playable IS NULL OR playable = 0));

-- +goose Down
-- Migrations are append-only.
