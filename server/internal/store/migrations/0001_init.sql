-- +goose Up
CREATE TABLE server_state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL COLLATE NOCASE,
    slug          TEXT NOT NULL,
    display_name  TEXT NOT NULL,
    role          TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    quota_bytes   INTEGER,
    created_at    TEXT NOT NULL,
    disabled_at   TEXT
);
CREATE UNIQUE INDEX users_username_uq ON users(username COLLATE NOCASE);
CREATE UNIQUE INDEX users_slug_uq ON users(slug);

CREATE TABLE devices (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id),
    name         TEXT NOT NULL,
    platform     TEXT NOT NULL,
    app_version  TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    revoked_at   TEXT
);
CREATE INDEX devices_user_id_idx ON devices(user_id);

CREATE TABLE access_tokens (
    token_hash TEXT PRIMARY KEY,
    device_id  TEXT NOT NULL REFERENCES devices(id),
    expires_at TEXT NOT NULL
);
CREATE INDEX access_tokens_device_id_idx ON access_tokens(device_id);
CREATE INDEX access_tokens_expires_at_idx ON access_tokens(expires_at);

CREATE TABLE refresh_tokens (
    token_hash TEXT PRIMARY KEY,
    device_id  TEXT NOT NULL REFERENCES devices(id),
    family_id  TEXT NOT NULL,
    state      TEXT NOT NULL CHECK (state IN ('active', 'rotated', 'revoked')),
    issued_at  TEXT NOT NULL,
    rotated_at TEXT,
    expires_at TEXT NOT NULL
);
CREATE INDEX refresh_tokens_family_id_idx ON refresh_tokens(family_id);

CREATE TABLE web_sessions (
    token_hash   TEXT PRIMARY KEY,
    device_id    TEXT NOT NULL REFERENCES devices(id),
    csrf_hash    TEXT NOT NULL,
    expires_at   TEXT NOT NULL,
    last_used_at TEXT NOT NULL
);

CREATE TABLE pairing_codes (
    code_hash      TEXT PRIMARY KEY,
    user_id        TEXT NOT NULL REFERENCES users(id),
    created_at     TEXT NOT NULL,
    expires_at     TEXT NOT NULL,
    redeemed_at    TEXT,
    invalidated_at TEXT
);

CREATE TABLE assets (
    id                      TEXT PRIMARY KEY,
    owner_id                TEXT NOT NULL REFERENCES users(id),
    sha256                  TEXT NOT NULL,
    size_bytes              INTEGER NOT NULL,
    mime                    TEXT NOT NULL,
    kind                    TEXT NOT NULL,
    filename                TEXT NOT NULL,
    original_path           TEXT NOT NULL,
    taken_at                TEXT,
    taken_at_offset_minutes INTEGER,
    taken_at_source         TEXT NOT NULL,
    width                   INTEGER,
    height                  INTEGER,
    duration_ms             INTEGER,
    lat                     REAL,
    lon                     REAL,
    state                   TEXT NOT NULL DEFAULT 'active',
    trashed_at              TEXT,
    stack_key               TEXT,
    stack_id                TEXT,
    thumbnails_ready        INTEGER NOT NULL DEFAULT 0,
    video_codec             TEXT,
    audio_codec             TEXT,
    container               TEXT,
    playable                INTEGER,
    created_at              TEXT NOT NULL,
    updated_seq             INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX assets_owner_sha256_uq ON assets(owner_id, sha256);
CREATE INDEX assets_owner_state_trashed_idx ON assets(owner_id, state, trashed_at);
CREATE INDEX assets_owner_id_idx ON assets(owner_id, id);

CREATE TABLE live_videos (
    asset_id      TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    owner_id      TEXT NOT NULL REFERENCES users(id),
    sha256        TEXT NOT NULL,
    size_bytes    INTEGER NOT NULL,
    mime          TEXT NOT NULL,
    filename      TEXT NOT NULL,
    original_path TEXT NOT NULL,
    created_at    TEXT NOT NULL
);

CREATE TABLE library_paths (
    path_key  TEXT PRIMARY KEY,
    path      TEXT NOT NULL,
    user_id   TEXT NOT NULL REFERENCES users(id),
    upload_id TEXT,
    asset_id  TEXT
);

CREATE TABLE asset_sources (
    device_id  TEXT NOT NULL REFERENCES devices(id),
    local_id   TEXT NOT NULL,
    asset_id   TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    PRIMARY KEY (device_id, local_id)
);
CREATE INDEX asset_sources_asset_id_idx ON asset_sources(asset_id);

CREATE TABLE upload_sessions (
    id            TEXT PRIMARY KEY,
    owner_id      TEXT NOT NULL REFERENCES users(id),
    device_id     TEXT NOT NULL REFERENCES devices(id),
    sha256        TEXT NOT NULL,
    length        INTEGER NOT NULL,
    "offset"      INTEGER NOT NULL DEFAULT 0,
    state         TEXT NOT NULL,
    pair_role     TEXT,
    pair_sha256   TEXT,
    meta_json     TEXT NOT NULL,
    staging_path  TEXT NOT NULL,
    dest_path     TEXT NOT NULL,
    asset_id      TEXT,
    asset_created INTEGER NOT NULL DEFAULT 0,
    failure_code  TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    expires_at    TEXT NOT NULL
);
CREATE UNIQUE INDEX upload_sessions_active_uq ON upload_sessions(owner_id, sha256)
    WHERE state IN ('receiving', 'finalizing');
CREATE INDEX upload_sessions_state_expires_idx ON upload_sessions(state, expires_at);

CREATE TABLE tombstones (
    owner_id   TEXT NOT NULL REFERENCES users(id),
    sha256     TEXT NOT NULL,
    filename   TEXT NOT NULL,
    deleted_at TEXT NOT NULL,
    PRIMARY KEY (owner_id, sha256)
);

CREATE TABLE change_log (
    seq        INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id   TEXT NOT NULL REFERENCES users(id),
    kind       TEXT NOT NULL,
    asset_id   TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX change_log_owner_seq_idx ON change_log(owner_id, seq);
CREATE INDEX change_log_asset_id_idx ON change_log(asset_id);

CREATE TABLE jobs (
    id           TEXT PRIMARY KEY,
    kind         TEXT NOT NULL,
    dedupe_key   TEXT NOT NULL,
    payload      TEXT NOT NULL,
    state        TEXT NOT NULL CHECK (state IN ('pending', 'running', 'done', 'dead')),
    attempts     INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL,
    run_after    TEXT NOT NULL,
    lease_until  TEXT,
    last_error   TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
CREATE UNIQUE INDEX jobs_active_uq ON jobs(kind, dedupe_key)
    WHERE state IN ('pending', 'running');
CREATE INDEX jobs_state_run_after_idx ON jobs(state, run_after);

CREATE TABLE audit_log (
    id          TEXT PRIMARY KEY,
    at          TEXT NOT NULL,
    user_id     TEXT,
    device_id   TEXT,
    event       TEXT NOT NULL,
    detail_json TEXT NOT NULL
);

-- +goose Down
-- Migrations are append-only; the initial schema is never rolled back.
SELECT 1;
