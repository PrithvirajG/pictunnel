package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestAuditLogAppendList(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	r := repository.AuditLogRepository{}

	base := time.Date(2026, 5, 1, 0, 0, 0, 250_000_000, time.UTC)
	uid := "someone"
	for i, id := range []string{"e1", "e2", "e3"} {
		ev := repository.AuditEvent{ID: id, At: base.Add(time.Duration(i) * time.Second), Event: "login", DetailJSON: "{}"}
		if i == 0 {
			ev.UserID = &uid
		}
		if err := r.Append(ctx, s.W, ev); err != nil {
			t.Fatal(err)
		}
	}
	list, err := r.List(ctx, s.R, 2)
	if err != nil || len(list) != 2 || list[0].ID != "e3" || list[1].ID != "e2" {
		t.Fatalf("%+v %v", list, err)
	}
	all, _ := r.List(ctx, s.R, 10)
	if all[2].UserID == nil || *all[2].UserID != uid || !all[2].At.Equal(base) || all[0].UserID != nil {
		t.Fatalf("%+v", all)
	}
}
