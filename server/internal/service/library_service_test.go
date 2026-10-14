package service

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/PrithvirajG/pictunnel/server/internal/storage"
)

var may2024 = time.Date(2024, 5, 6, 10, 0, 0, 0, time.UTC)

func (e *fenv) assign(t *testing.T, in AssignInput) string {
	t.Helper()
	if in.UserID == "" {
		in.UserID, in.UserSlug = e.owner, "alice"
	}
	var rel string
	err := e.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		rel, err = e.lib.Assign(context.Background(), tx, in)
		return err
	})
	if err != nil {
		t.Fatalf("Assign(%+v): %v", in, err)
	}
	return rel
}

func TestAssignCollisionCaseNFC(t *testing.T) {
	e := newFenv(t)
	if got := e.assign(t, AssignInput{Filename: "Photo 🙂.JPG", Date: may2024, UploadID: "u1"}); got != "alice/2024/05/Photo 🙂.JPG" {
		t.Fatalf("first = %q", got)
	}
	if got := e.assign(t, AssignInput{Filename: "photo 🙂.jpg", Date: may2024, UploadID: "u2"}); got != "alice/2024/05/photo 🙂~2.jpg" {
		t.Fatalf("second = %q", got)
	}
	if got := e.assign(t, AssignInput{Filename: "PHOTO 🙂.jpg", Date: may2024, UploadID: "u3"}); got != "alice/2024/05/PHOTO 🙂~3.jpg" {
		t.Fatalf("third = %q", got)
	}
	// NFD and NFC spellings collide and the stored name is NFC.
	if got := e.assign(t, AssignInput{Filename: "Café.jpg", Date: may2024, UploadID: "u4"}); got != "alice/2024/05/Café.jpg" {
		t.Fatalf("nfc = %q", got)
	}
	if got := e.assign(t, AssignInput{Filename: "Café.jpg", Date: may2024, UploadID: "u5"}); got != "alice/2024/05/Café~2.jpg" {
		t.Fatalf("nfd = %q", got)
	}
	// Reservations carry the upload id and the case-folded key.
	var found bool
	for _, r := range e.reservations(t) {
		if r.Path == "alice/2024/05/photo 🙂~2.jpg" {
			found = r.PathKey == storage.PathKey(r.Path) && r.UploadID != nil && *r.UploadID == "u2" && r.UserID == e.owner
		}
	}
	if !found {
		t.Fatalf("reservation for ~2 missing or wrong: %+v", e.reservations(t))
	}
}

func TestAssignSanitizesAndFits(t *testing.T) {
	e := newFenv(t)
	if got := e.assign(t, AssignInput{Filename: `a/b:c*?"<>|.jpg`, Date: may2024, UploadID: "u1"}); got != "alice/2024/05/a_b_c______.jpg" {
		t.Fatalf("sanitized = %q", got)
	}
	if got := e.assign(t, AssignInput{Filename: "con.txt", Date: may2024, UploadID: "u2"}); got != "alice/2024/05/_con.txt" {
		t.Fatalf("reserved = %q", got)
	}
	long := strings.Repeat("é", 300) + ".HEIC"
	got := e.assign(t, AssignInput{Filename: long, Date: may2024, UploadID: "u3"})
	if len(got) >= 240 || !strings.HasSuffix(got, ".HEIC") || !utf8.ValidString(got) || !strings.HasPrefix(got, "alice/2024/05/éé") {
		t.Fatalf("long = %q (%d bytes)", got, len(got))
	}
	got2 := e.assign(t, AssignInput{Filename: long, Date: may2024, UploadID: "u4"})
	if len(got2) >= 240 || !strings.HasSuffix(got2, "~2.HEIC") {
		t.Fatalf("long collision = %q (%d bytes)", got2, len(got2))
	}
	// A file already on disk that no reservation covers is never overwritten.
	p := e.libPath("alice/2024/05/manual.jpg")
	writeAt(t, p, []byte("mine"))
	if got := e.assign(t, AssignInput{Filename: "manual.jpg", Date: may2024, UploadID: "u5"}); got != "alice/2024/05/manual~2.jpg" {
		t.Fatalf("on-disk collision = %q", got)
	}
	// Zero date falls back to the clock.
	if got := e.assign(t, AssignInput{Filename: "x.jpg", UploadID: "u6"}); got != "alice/2026/10/x.jpg" {
		t.Fatalf("zero date = %q", got)
	}
}

func TestAssignSibling(t *testing.T) {
	e := newFenv(t)
	if got := e.assign(t, AssignInput{Filename: "IMG_1.MOV", SiblingOf: "alice/2023/01/IMG_1.HEIC", Date: may2024, UploadID: "u1"}); got != "alice/2023/01/IMG_1.MOV" {
		t.Fatalf("sibling = %q", got)
	}
	if got := e.assign(t, AssignInput{Filename: "whatever.mov", SiblingOf: "alice/2023/01/IMG_9~2.HEIC", UploadID: "u2"}); got != "alice/2023/01/IMG_9~2.mov" {
		t.Fatalf("sibling stem = %q", got)
	}
	if got := e.assign(t, AssignInput{Filename: "IMG_1.mov", SiblingOf: "alice/2023/01/IMG_1.HEIC", UploadID: "u3"}); got != "alice/2023/01/IMG_1~2.mov" {
		t.Fatalf("sibling collision = %q", got)
	}
}
