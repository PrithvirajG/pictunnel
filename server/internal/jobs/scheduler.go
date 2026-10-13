package jobs

import (
	"context"
	"database/sql"
	"time"
)

// schedule enqueues a periodic job at start and then once per period. The
// dedupe key carries the period bucket, so an overlapping run never doubles
// up while the previous one is still pending or running.
func (r *Runner) schedule(ctx context.Context, p Periodic) {
	defer r.wg.Done()
	r.enqueuePeriodic(ctx, p)
	t := time.NewTicker(p.Every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			r.enqueuePeriodic(ctx, p)
		}
	}
}

func (r *Runner) enqueuePeriodic(ctx context.Context, p Periodic) {
	now := r.clk.Now()
	key := p.Kind + ":" + now.Truncate(p.Every).Format(time.RFC3339)
	err := r.st.WithTx(ctx, func(tx *sql.Tx) error {
		return r.Enqueue(ctx, tx, p.Kind, key, nil, now)
	})
	if err != nil && ctx.Err() == nil {
		r.log.Error("jobs: scheduling periodic job failed", "kind", p.Kind, "err", err)
	}
}
