package ids_test

import (
	"sort"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/ids"
)

func TestIDsAreV7Sortable(t *testing.T) {
	const n = 1000
	got := make([]string, n)
	for i := range got {
		got[i] = ids.New()
		if got[i][14] != '7' {
			t.Fatalf("id %q is not v7", got[i])
		}
		if i%100 == 99 {
			time.Sleep(2 * time.Millisecond)
		}
	}
	sorted := append([]string(nil), got...)
	sort.Strings(sorted)
	for i := range got {
		if got[i] != sorted[i] {
			t.Fatalf("order differs at %d", i)
		}
	}
}
