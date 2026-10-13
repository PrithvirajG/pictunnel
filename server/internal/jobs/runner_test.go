package jobs_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

var t0 = time.Date(2026, 3, 4, 5, 6, 7, 0, time.UTC)

type env struct {
	r   *jobs.Runner
	s   *store.Store
	clk *clocktest.Fake
	rep repository.JobsRepository
}

func newEnv(t *testing.T) *env {
	t.Helper()
	s := repotest.NewStore(t)
	clk := clocktest.NewFake(t0)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &env{r: jobs.New(s, repository.JobsRepository{}, clk, log), s: s, clk: clk}
}

func (e *env) enqueue(t *testing.T, kind, key string) {
	t.Helper()
	if err := e.r.Enqueue(context.Background(), e.s.W, kind, key, []byte(`{"x":1}`), time.Time{}); err != nil {
		t.Fatal(err)
	}
}

func (e *env) counts(t *testing.T) map[string]int64 {
	t.Helper()
	cs, err := e.rep.Counts(context.Background(), e.s.R)
	if err != nil {
		t.Fatal(err)
	}
	m := map[string]int64{}
	for _, c := range cs {
		m[c.Kind+"/"+c.State] = c.N
	}
	return m
}

func TestHandlerErrorSchedulesBackoffRetry(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	var calls atomic.Int32
	e.r.Register("k", func(context.Context, []byte) error { calls.Add(1); return errors.New("boom") }, 3)
	e.enqueue(t, "k", "a")

	if err := e.r.RunNow(ctx, "k"); err == nil {
		t.Fatal("RunNow must surface the handler error")
	}
	if calls.Load() != 1 {
		t.Fatalf("calls = %d", calls.Load())
	}
	pend, err := e.rep.ListPending(ctx, e.s.R, "k")
	if err != nil || len(pend) != 1 || pend[0].State != "pending" {
		t.Fatalf("pending: %+v %v", pend, err)
	}
	j := pend[0]
	if !j.RunAfter.After(t0) || j.RunAfter.After(t0.Add(30*time.Second)) {
		t.Fatalf("run_after %v not in (now, now+30s]", j.RunAfter)
	}
	if j.LastError == nil || *j.LastError != "boom" {
		t.Fatalf("last_error: %v", j.LastError)
	}
	// Not due yet: RunNow must not run it.
	_ = e.r.RunNow(ctx, "k")
	if calls.Load() != 1 {
		t.Fatalf("ran before run_after: %d", calls.Load())
	}
}

func TestDeadAfterMaxAttempts(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	var calls atomic.Int32
	e.r.Register("k", func(context.Context, []byte) error { calls.Add(1); return errors.New("boom") }, 3)
	e.enqueue(t, "k", "a")
	for i := 0; i < 5; i++ {
		_ = e.r.RunNow(ctx, "k")
		e.clk.Advance(2 * time.Hour)
	}
	if calls.Load() != 3 {
		t.Fatalf("calls = %d, want 3", calls.Load())
	}
	if c := e.counts(t); c["k/dead"] != 1 || c["k/pending"] != 0 {
		t.Fatalf("counts: %v", c)
	}
}

func TestPermanentErrorIsDeadImmediately(t *testing.T) {
	e := newEnv(t)
	var calls atomic.Int32
	e.r.Register("k", func(context.Context, []byte) error {
		calls.Add(1)
		return &jobs.Permanent{Err: errors.New("bad payload")}
	}, 0)
	e.enqueue(t, "k", "a")
	_ = e.r.RunNow(context.Background(), "k")
	if c := e.counts(t); c["k/dead"] != 1 || calls.Load() != 1 {
		t.Fatalf("counts %v calls %d", c, calls.Load())
	}
}

func TestRunNowRunsPeriodicHandlerOnce(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	var calls atomic.Int32
	var gotNil atomic.Bool
	e.r.Register("p", func(_ context.Context, payload []byte) error {
		calls.Add(1)
		gotNil.Store(payload == nil)
		return nil
	}, 0)
	// Start with no pools so nothing runs the scheduled job; stop the
	// scheduler before RunNow so the direct-run path is exercised.
	e.r.Start(ctx, nil, []jobs.Periodic{{Kind: "p", Every: time.Hour}})
	e.r.Stop()
	// Drop whatever the scheduler enqueued so only the direct path remains.
	if _, err := e.s.W.ExecContext(ctx, "DELETE FROM jobs"); err != nil {
		t.Fatal(err)
	}
	if err := e.r.RunNow(ctx, "p"); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || !gotNil.Load() {
		t.Fatalf("calls %d nilPayload %v", calls.Load(), gotNil.Load())
	}
}

func TestEnqueueDedupe(t *testing.T) {
	e := newEnv(t)
	e.r.Register("k", func(context.Context, []byte) error { return nil }, 0)
	e.enqueue(t, "k", "same")
	e.enqueue(t, "k", "same")
	e.enqueue(t, "k", "other")
	pend, _ := e.rep.ListPending(context.Background(), e.s.R, "k")
	if len(pend) != 2 {
		t.Fatalf("pending = %d, want 2", len(pend))
	}
	if pend[0].MaxAttempts != jobs.DefaultMaxAttempts {
		t.Fatalf("max_attempts = %d", pend[0].MaxAttempts)
	}
}

func waitFor(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(10 * time.Second):
		t.Fatalf("timeout waiting for %s", what)
	}
}

func TestStopWaitsForRunningHandler(t *testing.T) {
	e := newEnv(t)
	started, release := make(chan struct{}), make(chan struct{})
	e.r.Register("k", func(context.Context, []byte) error {
		close(started)
		<-release
		return nil
	}, 0)
	e.r.Start(context.Background(), []jobs.Pool{{Name: "p", Workers: 1, Kinds: []string{"k"}}}, nil)
	e.enqueue(t, "k", "a")
	waitFor(t, started, "handler start")

	stopped := make(chan struct{})
	go func() { e.r.Stop(); close(stopped) }()
	select {
	case <-stopped:
		t.Fatal("Stop returned while handler still running")
	case <-time.After(150 * time.Millisecond):
	}
	close(release)
	waitFor(t, stopped, "Stop")
	if c := e.counts(t); c["k/done"] != 1 {
		t.Fatalf("job not completed before Stop returned: %v", c)
	}
}

func TestPoolsOnlyRunTheirKinds(t *testing.T) {
	e := newEnv(t)
	doneA, doneB := make(chan struct{}), make(chan struct{})
	var cRuns atomic.Int32
	e.r.Register("a", func(context.Context, []byte) error { close(doneA); return nil }, 0)
	e.r.Register("b", func(context.Context, []byte) error { close(doneB); return nil }, 0)
	e.r.Register("c", func(context.Context, []byte) error { cRuns.Add(1); return nil }, 0)
	e.r.Start(context.Background(), []jobs.Pool{
		{Name: "pa", Workers: 1, Kinds: []string{"a"}},
		{Name: "pb", Workers: 1, Kinds: []string{"b"}},
	}, nil)
	defer e.r.Stop()
	e.enqueue(t, "c", "x")
	e.enqueue(t, "a", "x")
	e.enqueue(t, "b", "x")
	waitFor(t, doneA, "a")
	waitFor(t, doneB, "b")
	time.Sleep(200 * time.Millisecond)
	if cRuns.Load() != 0 {
		t.Fatal("kind outside every pool was run")
	}
	if c := e.counts(t); c["c/pending"] != 1 {
		t.Fatalf("counts: %v", c)
	}
}

func TestCrashLoopingJobIsDeadLetteredWithoutRunning(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	var calls atomic.Int32
	e.r.Register("k", func(context.Context, []byte) error { calls.Add(1); return nil }, 2)
	e.enqueue(t, "k", "a")
	// Simulate a worker that crashes after every lease: lease, let it expire.
	for i := 0; i < 3; i++ {
		now := e.clk.Now()
		j, err := e.rep.LeaseNext(ctx, e.s.W, []string{"k"}, now, now.Add(time.Minute))
		if err != nil || j == nil || j.Attempts != i+1 {
			t.Fatalf("lease %d: %+v %v", i, j, err)
		}
		e.clk.Advance(2 * time.Minute)
	}
	if err := e.r.RunNow(ctx, "k"); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 0 {
		t.Fatal("handler ran for a job past max_attempts")
	}
	if c := e.counts(t); c["k/dead"] != 1 || c["k/running"] != 0 {
		t.Fatalf("counts: %v", c)
	}
}

func TestBackoffBounds(t *testing.T) {
	for attempts, ceil := range map[int]time.Duration{1: 30 * time.Second, 2: time.Minute, 3: 2 * time.Minute, 8: time.Hour, 50: time.Hour} {
		for i := 0; i < 200; i++ {
			if d := jobs.Backoff(attempts); d <= 0 || d > ceil {
				t.Fatalf("Backoff(%d) = %v, want (0, %v]", attempts, d, ceil)
			}
		}
	}
}

func TestShutdownInterruptedJobIsReleasedWithoutPenalty(t *testing.T) {
	e := newEnv(t)
	started := make(chan struct{})
	e.r.Register("k", func(ctx context.Context, _ []byte) error {
		close(started)
		<-ctx.Done()
		return ctx.Err()
	}, 3)
	e.r.Start(context.Background(), []jobs.Pool{{Name: "p", Workers: 1, Kinds: []string{"k"}}}, nil)
	e.enqueue(t, "k", "a")
	waitFor(t, started, "handler start")
	e.r.StopWithTimeout(50 * time.Millisecond)

	pend, err := e.rep.ListPending(context.Background(), e.s.R, "k")
	if err != nil || len(pend) != 1 {
		t.Fatalf("pending: %+v %v", pend, err)
	}
	j := pend[0]
	if j.State != "pending" || j.Attempts != 0 || j.LeaseUntil != nil || j.LastError != nil {
		t.Fatalf("job not cleanly released: %+v", j)
	}
	if j.RunAfter.After(e.clk.Now()) {
		t.Fatalf("released job must be runnable now: %v", j.RunAfter)
	}
}
