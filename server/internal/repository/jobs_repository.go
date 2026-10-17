package repository

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// Job is a row of the jobs table.
type Job struct {
	ID          string
	Kind        string
	DedupeKey   string
	Payload     string
	State       string // pending | running | done | dead
	Attempts    int
	MaxAttempts int
	RunAfter    time.Time
	LeaseUntil  *time.Time
	LastError   *string
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// JobCount is the number of jobs of one kind in one state.
type JobCount struct {
	Kind  string
	State string
	N     int64
}

// JobsRepository accesses the jobs table.
type JobsRepository struct{}

func jobFromRow(r queries.Job) (Job, error) {
	ts, err := parseTimes(r.RunAfter, r.CreatedAt, r.UpdatedAt)
	if err != nil {
		return Job{}, err
	}
	lease, err := parseTimePtr(r.LeaseUntil)
	if err != nil {
		return Job{}, err
	}
	return Job{
		ID: r.ID, Kind: r.Kind, DedupeKey: r.DedupeKey, Payload: r.Payload, State: r.State,
		Attempts: int(r.Attempts), MaxAttempts: int(r.MaxAttempts), RunAfter: ts[0], LeaseUntil: lease,
		LastError: r.LastError, CreatedAt: ts[1], UpdatedAt: ts[2],
	}, nil
}

// Enqueue inserts a pending job unless a pending or running job with the same
// (kind, dedupe_key) exists. It reports whether a row was inserted. Only ID,
// Kind, DedupeKey, Payload, MaxAttempts, RunAfter and CreatedAt are used.
func (JobsRepository) Enqueue(ctx context.Context, db queries.DBTX, j Job) (bool, error) {
	n, err := queries.New(db).EnqueueJob(ctx, queries.EnqueueJobParams{
		ID: j.ID, Kind: j.Kind, DedupeKey: j.DedupeKey, Payload: j.Payload, MaxAttempts: int64(j.MaxAttempts),
		RunAfter: formatTime(j.RunAfter), CreatedAt: formatTime(j.CreatedAt), UpdatedAt: formatTime(j.CreatedAt),
	})
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// LeaseNext atomically claims the next runnable job of one of kinds and marks
// it running until leaseUntil, incrementing attempts. Runnable means pending
// with run_after <= now, or running with an expired lease. It returns nil
// when nothing is runnable. The claim is a single UPDATE ... RETURNING, so
// concurrent callers never receive the same job.
func (JobsRepository) LeaseNext(ctx context.Context, db queries.DBTX, kinds []string, now, leaseUntil time.Time) (*Job, error) {
	if len(kinds) == 0 {
		return nil, nil
	}
	lu := formatTime(leaseUntil)
	r, err := queries.New(db).LeaseNextJob(ctx, queries.LeaseNextJobParams{LeaseUntil: &lu, Now: formatTime(now), Kinds: kinds})
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	j, err := jobFromRow(r)
	if err != nil {
		return nil, err
	}
	return &j, nil
}

// ExtendLease pushes a running job's lease out to leaseUntil. attempts
// identifies the lease as for Complete; ErrNotFound means the lease was lost.
func (JobsRepository) ExtendLease(ctx context.Context, db queries.DBTX, id string, attempts int, leaseUntil, now time.Time) error {
	lu := formatTime(leaseUntil)
	return requireRow(queries.New(db).ExtendJobLease(ctx, queries.ExtendJobLeaseParams{LeaseUntil: &lu, UpdatedAt: formatTime(now), ID: id, Attempts: int64(attempts)}))
}

// Release returns a running job to pending without penalty: the attempt the
// lease consumed is refunded. It is for jobs interrupted by shutdown.
func (JobsRepository) Release(ctx context.Context, db queries.DBTX, id string, attempts int, runAfter, at time.Time) error {
	return requireRow(queries.New(db).ReleaseJob(ctx, queries.ReleaseJobParams{
		RunAfter: formatTime(runAfter), UpdatedAt: formatTime(at), ID: id, Attempts: int64(attempts),
	}))
}

// Complete marks the job done. attempts is the Attempts value returned by the
// LeaseNext call that claimed the job; it identifies the lease, so a late
// worker whose lease expired and was re-taken gets ErrNotFound instead of
// clobbering the new lease. The same applies to Fail and Dead.
func (JobsRepository) Complete(ctx context.Context, db queries.DBTX, id string, attempts int, at time.Time) error {
	return requireRow(queries.New(db).CompleteJob(ctx, queries.CompleteJobParams{UpdatedAt: formatTime(at), ID: id, Attempts: int64(attempts)}))
}

// Fail returns the job to pending with the error recorded, to run again at runAfter.
func (JobsRepository) Fail(ctx context.Context, db queries.DBTX, id string, attempts int, errText string, runAfter, at time.Time) error {
	return requireRow(queries.New(db).FailJob(ctx, queries.FailJobParams{
		LastError: &errText, RunAfter: formatTime(runAfter), UpdatedAt: formatTime(at), ID: id, Attempts: int64(attempts),
	}))
}

// Dead marks the job permanently failed.
func (JobsRepository) Dead(ctx context.Context, db queries.DBTX, id string, attempts int, errText string, at time.Time) error {
	return requireRow(queries.New(db).DeadJob(ctx, queries.DeadJobParams{LastError: &errText, UpdatedAt: formatTime(at), ID: id, Attempts: int64(attempts)}))
}

// ListPending returns the pending and running jobs of a kind.
func (JobsRepository) ListPending(ctx context.Context, db queries.DBTX, kind string) ([]Job, error) {
	rows, err := queries.New(db).ListPendingJobs(ctx, kind)
	if err != nil {
		return nil, err
	}
	out := make([]Job, 0, len(rows))
	for _, r := range rows {
		j, err := jobFromRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, nil
}

// Counts returns job counts grouped by kind and state.
func (JobsRepository) Counts(ctx context.Context, db queries.DBTX) ([]JobCount, error) {
	rows, err := queries.New(db).JobCounts(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]JobCount, 0, len(rows))
	for _, r := range rows {
		out = append(out, JobCount{Kind: r.Kind, State: r.State, N: r.N})
	}
	return out, nil
}
