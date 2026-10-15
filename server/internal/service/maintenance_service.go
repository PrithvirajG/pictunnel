package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

const (
	// changeLogRetention is the feed retention (P§7.6).
	changeLogRetention = 90 * 24 * time.Hour
	backupDirName      = "backups"
	backupsKept        = 7
)

var backupName = regexp.MustCompile(`^pictunnel-[0-9]{8}\.db$`)

// MaintenanceServiceDeps are the MaintenanceService dependencies.
type MaintenanceServiceDeps struct {
	Store         *store.Store
	ChangeLog     repository.ChangeLogRepository
	ServerState   repository.ServerStateRepository
	AccessTokens  repository.AccessTokensRepository
	RefreshTokens repository.RefreshTokensRepository
	WebSessions   repository.WebSessionsRepository
	PairingCodes  repository.PairingCodesRepository
	FS            storage.FS
	Clock         clock.Clock
	// DataDir holds <data>/backups.
	DataDir string
	Log     *slog.Logger
}

// MaintenanceService holds the periodic housekeeping job bodies (S§9):
// compact_change_log, expire_tokens and backup_database.
type MaintenanceService struct {
	d   MaintenanceServiceDeps
	log *slog.Logger
}

// NewMaintenanceService returns a MaintenanceService.
func NewMaintenanceService(d MaintenanceServiceDeps) *MaintenanceService {
	log := d.Log
	if log == nil {
		log = slog.Default()
	}
	return &MaintenanceService{d: d, log: log}
}

// CompactChangeLog deletes change-log rows older than 90 days and raises
// change_log_floor to the highest deleted seq (never lowering it). When the
// head equals the floor it advances the head by one, so a snapshot taken
// now gets a cursor above the floor instead of an already expired one.
func (s *MaintenanceService) CompactChangeLog(ctx context.Context) error {
	cutoff := s.d.Clock.Now().Add(-changeLogRetention)
	err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		maxDel, _, err := s.d.ChangeLog.DeleteBefore(ctx, tx, cutoff)
		if err != nil || maxDel == 0 {
			return err
		}
		floor := maxDel
		if v, ok, err := s.d.ServerState.Get(ctx, tx, changeLogFloorKey); err != nil {
			return err
		} else if ok {
			cur, err := strconv.ParseInt(v, 10, 64)
			if err != nil {
				return fmt.Errorf("bad %s %q: %w", changeLogFloorKey, v, err)
			}
			floor = max(floor, cur)
		}
		if err := s.d.ServerState.Set(ctx, tx, changeLogFloorKey, strconv.FormatInt(floor, 10)); err != nil {
			return err
		}
		head, err := s.d.ChangeLog.Head(ctx, tx)
		if err != nil {
			return err
		}
		if head <= floor {
			return s.d.ChangeLog.AdvanceHead(ctx, tx, floor+1)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("compact_change_log: %w", err)
	}
	return nil
}

// ExpireTokens deletes expired access tokens, refresh tokens, web sessions
// and pairing codes.
func (s *MaintenanceService) ExpireTokens(ctx context.Context) error {
	now := s.d.Clock.Now()
	err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		for _, del := range []func() (int64, error){
			func() (int64, error) { return s.d.AccessTokens.DeleteExpired(ctx, tx, now) },
			func() (int64, error) { return s.d.RefreshTokens.DeleteExpired(ctx, tx, now) },
			func() (int64, error) { return s.d.WebSessions.DeleteExpired(ctx, tx, now) },
			func() (int64, error) { return s.d.PairingCodes.DeleteExpired(ctx, tx, now) },
		} {
			if _, err := del(); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("expire_tokens: %w", err)
	}
	return nil
}

// BackupDatabase writes <data>/backups/pictunnel-YYYYMMDD.db (UTC date) with
// VACUUM INTO, via a temp name renamed into place, and keeps the newest 7.
// A backup that already exists for today is kept as is.
func (s *MaintenanceService) BackupDatabase(ctx context.Context) error {
	dir := filepath.Join(s.d.DataDir, backupDirName)
	if err := s.d.FS.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("backup_database: %w", err)
	}
	dst := filepath.Join(dir, "pictunnel-"+s.d.Clock.Now().Format("20060102")+".db")
	_, err := s.d.FS.Stat(dst)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		tmp := dst + ".tmp"
		if err := s.d.FS.Remove(tmp); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("backup_database: %w", err)
		}
		if err := s.d.Store.BackupTo(ctx, tmp); err != nil {
			return fmt.Errorf("backup_database: %w", err)
		}
		if err := s.d.FS.Rename(tmp, dst); err != nil {
			return fmt.Errorf("backup_database: %w", err)
		}
		if err := s.d.FS.SyncDir(dir); err != nil {
			s.log.Warn("backup_database: sync dir", "err", err)
		}
	case err != nil:
		return fmt.Errorf("backup_database: %w", err)
	}
	return s.pruneBackups(dir)
}

func (s *MaintenanceService) pruneBackups(dir string) error {
	ents, err := s.d.FS.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("backup_database: %w", err)
	}
	var names []string
	for _, e := range ents {
		if e.Type().IsRegular() && backupName.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names))) // newest date first
	for _, n := range names[min(len(names), backupsKept):] {
		if err := s.d.FS.Remove(filepath.Join(dir, n)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("backup_database: prune %s: %w", n, err)
		}
	}
	return nil
}
