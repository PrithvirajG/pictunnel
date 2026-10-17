package service

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

const (
	// maxRelPathBytes bounds the library-relative path (S§6.3).
	maxRelPathBytes = 240
	// maxExtBytes: a longer "extension" is treated as part of the stem.
	maxExtBytes = 16
	// maxCollisionProbes bounds the ~N search.
	maxCollisionProbes = 10000
)

// LibraryServiceDeps are the LibraryService dependencies. FS is used to skip
// names already present on disk that no reservation covers.
type LibraryServiceDeps struct {
	LibraryPaths repository.LibraryPathsRepository
	FS           storage.FS
	Clock        clock.Clock
	LibraryDir   string
}

// LibraryService assigns and reserves library paths (S§6.3, P§7.5).
type LibraryService struct{ d LibraryServiceDeps }

// NewLibraryService returns a LibraryService.
func NewLibraryService(d LibraryServiceDeps) *LibraryService { return &LibraryService{d: d} }

// AssignInput describes the file to place. Date picks <YYYY>/<MM> (its own
// wall clock; zero means the server clock). SiblingOf, the rel path of a
// Live Photo's primary, places the file next to it with the primary's stem.
type AssignInput struct {
	UserID   string
	UserSlug string
	Filename string
	Date     time.Time
	UploadID string
	// SiblingOf is the rel path of the primary for a live video.
	SiblingOf string
}

// Assign computes the library-relative path ("alice/2024/05/IMG.JPG",
// slash-separated) and reserves it in library_paths inside tx. A name whose
// case-folded NFC key is reserved, or which already exists on disk, gets
// "~2", "~3", … before the extension.
func (s *LibraryService) Assign(ctx context.Context, tx queries.DBTX, in AssignInput) (string, error) {
	name := storage.SanitizeFilename(in.Filename)
	stem, ext := splitExt(name)
	var dir string
	if in.SiblingOf != "" {
		dir = path.Dir(in.SiblingOf)
		stem, _ = splitExt(path.Base(in.SiblingOf))
	} else {
		d := in.Date
		if d.IsZero() {
			d = s.d.Clock.Now()
		}
		dir = fmt.Sprintf("%s/%04d/%02d", in.UserSlug, d.Year(), int(d.Month()))
	}
	var upload *string
	if in.UploadID != "" {
		upload = &in.UploadID
	}
	for n := 1; n <= maxCollisionProbes; n++ {
		suffix := ext
		if n > 1 {
			suffix = "~" + strconv.Itoa(n) + ext
		}
		rel := storage.FitPath(dir, stem, suffix, maxRelPathBytes)
		if hasPtpartSuffix(rel) {
			// Truncation can cut a long stem right after ".ptpart"; the next
			// probe appends "~N", so it cannot end that way again.
			continue
		}
		key := storage.PathKey(rel)
		taken, err := s.d.LibraryPaths.Exists(ctx, tx, key)
		if err != nil {
			return "", err
		}
		if taken {
			continue
		}
		if taken, err = s.onDisk(rel); err != nil {
			return "", err
		} else if taken {
			continue
		}
		err = s.d.LibraryPaths.Reserve(ctx, tx, repository.LibraryPath{
			PathKey: key, Path: rel, UserID: in.UserID, UploadID: upload,
		})
		if errors.Is(err, repository.ErrUniqueViolation) {
			continue
		}
		if err != nil {
			return "", err
		}
		return rel, nil
	}
	return "", fmt.Errorf("library: no free name for %q in %q", name, dir)
}

// hasPtpartSuffix reports whether p ends in the in-flight copy extension
// (ASCII case-insensitively, as case-insensitive filesystems compare it).
func hasPtpartSuffix(p string) bool {
	n := len(p) - len(storage.PtpartSuffix)
	return n >= 0 && strings.EqualFold(p[n:], storage.PtpartSuffix)
}

func splitExt(name string) (string, string) {
	stem, ext := storage.SplitExt(name)
	if len(ext) > maxExtBytes {
		return name, ""
	}
	return stem, ext
}

func (s *LibraryService) onDisk(rel string) (bool, error) {
	if s.d.FS == nil || s.d.LibraryDir == "" {
		return false, nil
	}
	// Defence in depth: copies live in the library temp dir, but a name whose
	// <name>.ptpart exists on disk is still treated as taken.
	abs := filepath.Join(s.d.LibraryDir, filepath.FromSlash(rel))
	for _, p := range []string{abs, abs + storage.PtpartSuffix} {
		_, err := s.d.FS.Stat(p)
		if err == nil {
			return true, nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return false, fmt.Errorf("library: stat %s: %w", p, err)
		}
	}
	return false, nil
}
