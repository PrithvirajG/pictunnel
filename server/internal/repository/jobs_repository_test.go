package repository_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func newJob(id, kind, key string) repository.Job {
	return repository.Job{ID: id, Kind: kind, DedupeKey: key, Payload: "{}", MaxAttempts: 5, RunAfter: ts, CreatedAt: ts}
}

func TestJobsEnqueueDedupeAndReenqueue(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	r := repository.JobsRepository{}

	ins, err := r.Enqueue(ctx, s.W, newJob("j1", "thumb", "a1"))
	if err != nil || !ins {
		t.Fatalf("first enqueue: %v %v", ins, err)
	}
	ins, err = r.Enqueue(ctx, s.W, newJob("j2", "thumb", "a1"))
	if err != nil || ins {
		t.Fatalf("duplicate while pending must not insert: %v %v", ins, err)
	}
	if ins, _ := r.Enqueue(ctx, s.W, newJob("j3", "extract", "a1")); !ins {
		t.Fatal("different kind with same key must insert")
	}
	pend, err := r.ListPending(ctx, s.R, "thumb")
	if err != nil || len(pend) != 1 || pend[0].ID != "j1" || pend[0].State != "pending" {
		t.Fatalf("ListPending: %+v %v", pend, err)
	}

	j, err := r.LeaseNext(ctx, s.W, []string{"thumb"}, ts, ts.Add(time.Minute))
	if err != nil || j == nil || j.ID != "j1" {
		t.Fatalf("lease: %+v %v", j, err)
	}
	if ins, _ := r.Enqueue(ctx, s.W, newJob("j4", "thumb", "a1")); ins {
		t.Fatal("duplicate while running must not insert")
	}
	if err := r.Complete(ctx, s.W, "j1", ts); err != nil {
		t.Fatal(err)
	}
	if ins, _ := r.Enqueue(ctx, s.W, newJob("j5", "thumb", "a1")); !ins {
		t.Fatal("re-enqueue after Complete must be allowed")
	}
}

func TestJobsLeaseFailDeadCounts(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	r := repository.JobsRepository{}

	future := newJob("jf", "thumb", "future")
	future.RunAfter = ts.Add(time.Hour)
	for _, j := range []repository.Job{newJob("j1", "thumb", "a"), newJob("j2", "thumb", "b"), future} {
		if _, err := r.Enqueue(ctx, s.W, j); err != nil {
			t.Fatal(err)
		}
	}
	if j, err := r.LeaseNext(ctx, s.W, []string{"other"}, ts, ts.Add(time.Minute)); err != nil || j != nil {
		t.Fatalf("kind filter: %+v %v", j, err)
	}
	if j, err := r.LeaseNext(ctx, s.W, nil, ts, ts.Add(time.Minute)); err != nil || j != nil {
		t.Fatalf("no kinds: %+v %v", j, err)
	}
	j, err := r.LeaseNext(ctx, s.W, []string{"thumb"}, ts, ts.Add(time.Minute))
	if err != nil || j == nil || j.ID != "j1" || j.State != "running" || j.Attempts != 1 || j.LeaseUntil == nil || !j.LeaseUntil.Equal(ts.Add(time.Minute)) {
		t.Fatalf("lease 1: %+v %v", j, err)
	}
	j2, _ := r.LeaseNext(ctx, s.W, []string{"thumb"}, ts, ts.Add(time.Minute))
	if j2 == nil || j2.ID != "j2" {
		t.Fatalf("lease 2: %+v", j2)
	}
	if j3, _ := r.LeaseNext(ctx, s.W, []string{"thumb"}, ts, ts.Add(time.Minute)); j3 != nil {
		t.Fatalf("future job must not lease: %+v", j3)
	}

	if err := r.ExtendLease(ctx, s.W, "j1", ts.Add(5*time.Minute), ts); err != nil {
		t.Fatal(err)
	}
	// j2's lease expires; it is re-leased once the lease passes. j1 was extended.
	re, err := r.LeaseNext(ctx, s.W, []string{"thumb"}, ts.Add(2*time.Minute), ts.Add(time.Hour))
	if err != nil || re == nil || re.ID != "j2" || re.Attempts != 2 {
		t.Fatalf("expired lease reclaim: %+v %v", re, err)
	}

	later := ts.Add(10 * time.Minute)
	if err := r.Fail(ctx, s.W, "j1", "boom", later, ts.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if got, _ := r.LeaseNext(ctx, s.W, []string{"thumb"}, ts.Add(5*time.Minute), ts.Add(6*time.Minute)); got != nil {
		t.Fatalf("failed job waits for run_after: %+v", got)
	}
	got, _ := r.LeaseNext(ctx, s.W, []string{"thumb"}, later, later.Add(time.Minute))
	if got == nil || got.ID != "j1" || got.LastError == nil || *got.LastError != "boom" || got.Attempts != 2 {
		t.Fatalf("retry: %+v", got)
	}
	if err := r.Dead(ctx, s.W, "j2", "gave up", ts); err != nil {
		t.Fatal(err)
	}
	counts, err := r.Counts(ctx, s.R)
	if err != nil {
		t.Fatal(err)
	}
	m := map[string]int64{}
	for _, c := range counts {
		m[c.Kind+"/"+c.State] = c.N
	}
	if m["thumb/running"] != 1 || m["thumb/dead"] != 1 || m["thumb/pending"] != 1 {
		t.Fatalf("Counts: %+v", counts)
	}
}

func TestJobsLeaseNextConcurrentNoDuplicates(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	r := repository.JobsRepository{}

	const jobs = 40
	for i := 0; i < jobs; i++ {
		id := string(rune('A'+i/26)) + string(rune('a'+i%26))
		if _, err := r.Enqueue(ctx, s.W, newJob(id, "thumb", id)); err != nil {
			t.Fatal(err)
		}
	}
	var (
		mu   sync.Mutex
		seen = map[string]int{}
		wg   sync.WaitGroup
	)
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				j, err := r.LeaseNext(ctx, s.W, []string{"thumb"}, ts, ts.Add(time.Hour))
				if err != nil {
					t.Error(err)
					return
				}
				if j == nil {
					return
				}
				mu.Lock()
				seen[j.ID]++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if len(seen) != jobs {
		t.Fatalf("leased %d distinct jobs, want %d", len(seen), jobs)
	}
	for id, n := range seen {
		if n != 1 {
			t.Fatalf("job %s leased %d times", id, n)
		}
	}
}
