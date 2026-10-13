package repository_test

import (
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

// ts is a fixed UTC instant with millisecond precision.
var ts = time.Date(2026, 6, 1, 10, 0, 0, 456_000_000, time.UTC)

func newAsset(id, owner, sha string) repository.Asset {
	return repository.Asset{
		ID: id, OwnerID: owner, SHA256: sha, SizeBytes: 100, Mime: "image/jpeg", Kind: "photo",
		Filename: id + ".jpg", OriginalPath: "2026/06/" + id + ".jpg", TakenAtSource: "exif",
		State: "active", CreatedAt: ts,
	}
}
