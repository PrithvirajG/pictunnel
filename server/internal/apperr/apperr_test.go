package apperr_test

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
)

func TestCatalogueComplete(t *testing.T) {
	b, err := os.ReadFile("../../../api/protocol/sync-protocol.md")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`(?m)^\| \x60([a-z_]+)\x60 \| (\d{3})`)
	doc := map[string]int{}
	for _, m := range re.FindAllStringSubmatch(string(b), -1) {
		n, _ := strconv.Atoi(m[2])
		doc[m[1]] = n
	}
	if len(doc) != 24 {
		t.Fatalf("parsed %d codes from doc, want 24", len(doc))
	}
	for k, v := range doc {
		if got, ok := apperr.Catalogue[k]; !ok || got != v {
			t.Errorf("catalogue[%s]=%d,%v want %d", k, got, ok, v)
		}
	}
	for k := range apperr.Catalogue {
		if _, ok := doc[k]; !ok {
			t.Errorf("catalogue has extra code %s", k)
		}
	}
}

func TestConstructorsMatchCatalogue(t *testing.T) {
	all := []*apperr.Error{
		apperr.InvalidRequest("x"), apperr.CursorRequired(), apperr.PairingCodeInvalid(),
		apperr.Unauthorized(), apperr.TokenExpired(), apperr.RefreshTokenReused(), apperr.Forbidden("x"),
		apperr.NotFound(), apperr.NotReady(), apperr.OffsetMismatch(5), apperr.LengthMismatch(),
		apperr.Tombstoned(time.Now()), apperr.PairPrimaryMissing(), apperr.SetupAlreadyDone(),
		apperr.CursorExpired(), apperr.FileTooLarge(1), apperr.QuotaExceeded(), apperr.UploadLocked(),
		apperr.ClientTooOld("1.0.0"), apperr.RateLimited(3 * time.Second), apperr.ChecksumMismatch(),
		apperr.Internal(), apperr.ServerUnavailable(2 * time.Second), apperr.InsufficientStorage(),
	}
	seen := map[string]bool{}
	for _, e := range all {
		seen[e.Code] = true
		if e.Status != apperr.Catalogue[e.Code] {
			t.Errorf("%s status %d != %d", e.Code, e.Status, apperr.Catalogue[e.Code])
		}
		if e.Title == "" {
			t.Errorf("%s has no title", e.Code)
		}
	}
	if len(seen) != len(apperr.Catalogue) {
		t.Errorf("constructors cover %d codes, catalogue has %d", len(seen), len(apperr.Catalogue))
	}
	tp := apperr.TusPrecondition()
	if tp.Status != 412 || tp.Code != "invalid_request" || tp.Headers.Get("Tus-Version") != "1.0.0" {
		t.Errorf("tus precondition: %+v", tp)
	}
	if rn := apperr.RangeNotSatisfiable(); rn.Status != 416 || rn.Code != "invalid_request" {
		t.Errorf("range not satisfiable: %+v", rn)
	}
}

func TestHeadersAndAs(t *testing.T) {
	if h := apperr.OffsetMismatch(42).Headers.Get("Upload-Offset"); h != "42" {
		t.Errorf("Upload-Offset = %q", h)
	}
	if h := apperr.RateLimited(1500 * time.Millisecond).Headers.Get("Retry-After"); h != "2" {
		t.Errorf("Retry-After = %q", h)
	}
	if h := apperr.ServerUnavailable(5 * time.Second).Headers.Get("Retry-After"); h != "5" {
		t.Errorf("Retry-After = %q", h)
	}
	e := apperr.FileTooLarge(99)
	if e.Extra["max_file_bytes"] != int64(99) {
		t.Errorf("extra = %v", e.Extra)
	}
	w := fmt.Errorf("wrap: %w", apperr.NotFound())
	got, ok := apperr.As(w)
	if !ok || got.Code != "not_found" {
		t.Errorf("As failed")
	}
	if _, ok := apperr.As(fmt.Errorf("plain")); ok {
		t.Error("As matched plain error")
	}
	if apperr.NotFound().Error() == "" {
		t.Error("empty Error()")
	}
}
