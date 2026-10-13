// Package jobs implements the durable, table-backed job runner and scheduler.
package jobs

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

const (
	// DefaultMaxAttempts applies to kinds enqueued without a registered handler.
	DefaultMaxAttempts = 8

	leaseDuration     = 5 * time.Minute
	heartbeatInterval = time.Minute
	pollInterval      = time.Second
	backoffBase       = 30 * time.Second
	backoffCap        = time.Hour
	// DefaultStopGrace is how long Stop lets in-flight handlers finish before
	// cancelling their context.
	DefaultStopGrace = 30 * time.Second
)

var errLeaseLost = errors.New("jobs: lease lost")

// Handler processes one job payload. A nil payload means a periodic run.
type Handler func(ctx context.Context, payload []byte) error

// Permanent wraps an error that must not be retried: the job goes straight to dead.
type Permanent struct{ Err error }

func (p *Permanent) Error() string {
	if p.Err == nil {
		return "permanent failure"
	}
	return "permanent failure: " + p.Err.Error()
}

func (p *Permanent) Unwrap() error { return p.Err }

// Pool is a named set of workers serving a list of job kinds.
type Pool struct {
	Name    string
	Workers int
	Kinds   []string
}

// Periodic asks the scheduler to enqueue Kind once per Every period.
type Periodic struct {
	Kind  string
	Every time.Duration
}

type registration struct {
	h           Handler
	maxAttempts int
}

// Runner leases jobs from the jobs table and runs their handlers.
type Runner struct {
	st   *store.Store
	repo repository.JobsRepository
	clk  clock.Clock
	log  *slog.Logger

	mu             sync.Mutex
	handlers       map[string]registration
	periodic       map[string]time.Duration
	wake           chan struct{} // closed and replaced to broadcast "new work"
	stopLoop       context.CancelFunc
	cancelHandlers context.CancelFunc // cancels the context handlers run under

	wg sync.WaitGroup
}

// New returns a Runner. Register handlers before Start.
func New(st *store.Store, repo repository.JobsRepository, clk clock.Clock, log *slog.Logger) *Runner {
	if log == nil {
		log = slog.Default()
	}
	return &Runner{
		st: st, repo: repo, clk: clk, log: log,
		handlers: map[string]registration{},
		periodic: map[string]time.Duration{},
		wake:     make(chan struct{}),
	}
}

// Register installs the handler for kind. maxAttempts <= 0 selects the default (8).
func (r *Runner) Register(kind string, h Handler, maxAttempts int) {
	if maxAttempts <= 0 {
		maxAttempts = DefaultMaxAttempts
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.handlers[kind] = registration{h: h, maxAttempts: maxAttempts}
}

func (r *Runner) lookup(kind string) (registration, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	reg, ok := r.handlers[kind]
	return reg, ok
}

// Enqueue inserts a pending job on db (a write transaction or the writer
// pool) unless a pending or running job with the same kind and dedupeKey
// exists. A zero runAfter means now. Workers are woken after the insert; if db
// is a transaction that has not committed yet the 1 s poll still picks it up.
func (r *Runner) Enqueue(ctx context.Context, db queries.DBTX, kind, dedupeKey string, payload []byte, runAfter time.Time) error {
	now := r.clk.Now()
	if runAfter.IsZero() {
		runAfter = now
	}
	maxAttempts := DefaultMaxAttempts
	if reg, ok := r.lookup(kind); ok {
		maxAttempts = reg.maxAttempts
	}
	_, err := r.repo.Enqueue(ctx, db, repository.Job{
		ID: ids.New(), Kind: kind, DedupeKey: dedupeKey, Payload: string(payload),
		MaxAttempts: maxAttempts, RunAfter: runAfter, CreatedAt: now,
	})
	if err != nil {
		return fmt.Errorf("jobs: enqueue %s: %w", kind, err)
	}
	r.notify()
	return nil
}

func (r *Runner) notify() {
	r.mu.Lock()
	defer r.mu.Unlock()
	close(r.wake)
	r.wake = make(chan struct{})
}

func (r *Runner) wakeCh() <-chan struct{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.wake
}

// Start launches the worker pools and the scheduler. Workers poll every 1 s
// and wake early on Enqueue. ctx is passed to handlers; Stop only ends polling.
func (r *Runner) Start(ctx context.Context, pools []Pool, periodic []Periodic) {
	loopCtx, cancel := context.WithCancel(ctx)
	handlerCtx, cancelHandlers := context.WithCancel(ctx)
	r.mu.Lock()
	r.stopLoop = cancel
	r.cancelHandlers = cancelHandlers
	for _, p := range periodic {
		r.periodic[p.Kind] = p.Every
	}
	r.mu.Unlock()

	for _, p := range pools {
		kinds := append([]string(nil), p.Kinds...)
		for i := 0; i < p.Workers; i++ {
			r.wg.Add(1)
			go r.worker(loopCtx, handlerCtx, p.Name, kinds)
		}
	}
	for _, p := range periodic {
		if p.Every <= 0 {
			continue
		}
		r.wg.Add(1)
		go r.schedule(loopCtx, p)
	}
}

// Stop ends polling and waits up to DefaultStopGrace for in-flight handlers,
// then cancels their context and waits for them to return. Jobs interrupted
// that way are released back to pending without an attempt penalty.
func (r *Runner) Stop() { r.StopWithTimeout(DefaultStopGrace) }

// StopWithTimeout is Stop with an explicit grace period.
func (r *Runner) StopWithTimeout(grace time.Duration) {
	r.mu.Lock()
	cancel, cancelH := r.stopLoop, r.cancelHandlers
	r.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	done := make(chan struct{})
	go func() { r.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(grace):
		if cancelH != nil {
			cancelH()
		}
		<-done
	}
	if cancelH != nil {
		cancelH()
	}
}

func (r *Runner) worker(loopCtx, handlerCtx context.Context, pool string, kinds []string) {
	defer r.wg.Done()
	for loopCtx.Err() == nil {
		wake := r.wakeCh()
		job, err := r.lease(loopCtx, kinds)
		if err != nil {
			if loopCtx.Err() == nil {
				r.log.Error("jobs: lease failed", "pool", pool, "err", err)
			}
		} else if job != nil {
			_ = r.process(handlerCtx, job)
			continue
		}
		select {
		case <-loopCtx.Done():
			return
		case <-wake:
		case <-time.After(pollInterval):
		}
	}
}

// lease claims the next runnable job among the registered kinds.
func (r *Runner) lease(ctx context.Context, kinds []string) (*repository.Job, error) {
	var live []string
	for _, k := range kinds {
		if _, ok := r.lookup(k); ok {
			live = append(live, k)
		}
	}
	var job *repository.Job
	err := r.st.WithTx(ctx, func(tx *sql.Tx) error {
		now := r.clk.Now()
		j, err := r.repo.LeaseNext(ctx, tx, live, now, now.Add(leaseDuration))
		job = j
		return err
	})
	return job, err
}

// process runs one leased job and records its outcome. It returns the
// handler's error (nil on success or when the job was dead-lettered unrun).
func (r *Runner) process(ctx context.Context, job *repository.Job) error {
	// Outcome writes must land even if ctx is cancelled mid-handler.
	wctx := context.WithoutCancel(ctx)
	reg, ok := r.lookup(job.Kind)
	if !ok {
		r.finishDead(wctx, job, "no handler registered")
		return nil
	}
	// LeaseNext re-leases expired running jobs and increments attempts each
	// time, so a job that crashes its worker every time ends up here.
	if job.Attempts > job.MaxAttempts {
		r.log.Warn("jobs: dead-lettering job that exhausted its lease attempts", "kind", job.Kind, "id", job.ID, "attempts", job.Attempts)
		r.finishDead(wctx, job, fmt.Sprintf("exceeded max attempts (%d) without completing", job.MaxAttempts))
		return nil
	}

	// jctx is cancelled on shutdown (via ctx) or when the heartbeat finds the
	// lease was taken over.
	jctx, jcancel := context.WithCancelCause(ctx)
	defer jcancel(nil)
	hbCtx, stopHB := context.WithCancel(jctx)
	hbDone := make(chan struct{})
	go func() {
		defer close(hbDone)
		t := time.NewTicker(heartbeatInterval)
		defer t.Stop()
		for {
			select {
			case <-hbCtx.Done():
				return
			case <-t.C:
				now := r.clk.Now()
				err := r.st.WithTx(wctx, func(tx *sql.Tx) error {
					return r.repo.ExtendLease(wctx, tx, job.ID, job.Attempts, now.Add(leaseDuration), now)
				})
				if errors.Is(err, repository.ErrNotFound) {
					jcancel(errLeaseLost)
					return
				}
				if err != nil {
					r.log.Warn("jobs: heartbeat failed", "kind", job.Kind, "id", job.ID, "err", err)
				}
			}
		}
	}()
	herr := runHandler(jctx, reg.h, payloadBytes(job.Payload))
	stopHB()
	<-hbDone

	if errors.Is(context.Cause(jctx), errLeaseLost) {
		r.log.Warn("jobs: lease lost during handler, outcome discarded", "kind", job.Kind, "id", job.ID)
		return nil
	}
	if herr != nil && ctx.Err() != nil {
		// Interrupted by shutdown: hand the job back, no attempt penalty.
		now := r.clk.Now()
		r.record(job, "release", r.st.WithTx(wctx, func(tx *sql.Tx) error {
			return r.repo.Release(wctx, tx, job.ID, job.Attempts, now, now)
		}))
		return herr
	}
	if herr == nil {
		r.record(job, "complete", r.st.WithTx(wctx, func(tx *sql.Tx) error {
			return r.repo.Complete(wctx, tx, job.ID, job.Attempts, r.clk.Now())
		}))
		return nil
	}
	var perm *Permanent
	if errors.As(herr, &perm) || job.Attempts >= job.MaxAttempts {
		r.finishDead(wctx, job, herr.Error())
		return herr
	}
	now := r.clk.Now()
	runAfter := now.Add(Backoff(job.Attempts))
	r.record(job, "fail", r.st.WithTx(wctx, func(tx *sql.Tx) error {
		return r.repo.Fail(wctx, tx, job.ID, job.Attempts, herr.Error(), runAfter, now)
	}))
	r.log.Warn("jobs: handler failed, will retry", "kind", job.Kind, "id", job.ID, "attempt", job.Attempts, "retry_at", runAfter, "err", herr)
	return herr
}

func (r *Runner) finishDead(ctx context.Context, job *repository.Job, msg string) {
	r.record(job, "dead", r.st.WithTx(ctx, func(tx *sql.Tx) error {
		return r.repo.Dead(ctx, tx, job.ID, job.Attempts, msg, r.clk.Now())
	}))
	r.log.Error("jobs: job is dead", "kind", job.Kind, "id", job.ID, "attempts", job.Attempts, "reason", msg)
}

// record logs a failed outcome write. ErrNotFound means the lease was lost to
// a re-lease, which the guarded UPDATEs reject on purpose.
func (r *Runner) record(job *repository.Job, what string, err error) {
	if err == nil {
		return
	}
	if errors.Is(err, repository.ErrNotFound) {
		r.log.Warn("jobs: lease lost before outcome was recorded", "kind", job.Kind, "id", job.ID, "outcome", what)
		return
	}
	r.log.Error("jobs: recording outcome failed", "kind", job.Kind, "id", job.ID, "outcome", what, "err", err)
}

func runHandler(ctx context.Context, h Handler, payload []byte) (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("handler panic: %v", p)
		}
	}()
	return h(ctx, payload)
}

func payloadBytes(s string) []byte {
	if s == "" {
		return nil
	}
	return []byte(s)
}

// Backoff returns the full-jitter retry delay after the given attempt number:
// a uniform value in (0, min(1h, 30s*2^(attempts-1))].
func Backoff(attempts int) time.Duration {
	ceiling := backoffCap
	if attempts < 1 {
		attempts = 1
	}
	if attempts-1 < 7 { // 30s<<7 already exceeds the 1h cap
		if d := backoffBase << (attempts - 1); d < ceiling {
			ceiling = d
		}
	}
	return time.Duration(rand.Int64N(int64(ceiling))) + 1
}

// RunNow synchronously runs every runnable pending job of kind. If kind is
// periodic and no pending job ran, it runs the handler once with a nil
// payload. It returns the joined handler errors.
func (r *Runner) RunNow(ctx context.Context, kind string) error {
	reg, ok := r.lookup(kind)
	if !ok {
		return fmt.Errorf("jobs: no handler registered for %q", kind)
	}
	var errs []error
	ran := false
	for ctx.Err() == nil {
		job, err := r.lease(ctx, []string{kind})
		if err != nil {
			return errors.Join(append(errs, err)...)
		}
		if job == nil {
			break
		}
		ran = true
		if err := r.process(ctx, job); err != nil {
			errs = append(errs, err)
		}
	}
	r.mu.Lock()
	_, isPeriodic := r.periodic[kind]
	r.mu.Unlock()
	if isPeriodic && !ran {
		if err := runHandler(ctx, reg.h, nil); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
