package service

import (
	"context"
	"hash"
	"sync"
	"time"
)

// uploadLocks is the in-process lock table for upload sessions (S§6.1).
// Each entry is a one-slot semaphore plus the session's incremental hasher.
// An entry stays in the map only while someone holds or waits for it, or
// while it caches a hasher; finished, failed, expired and terminated
// sessions drop their entry (release with forget), so the map is bounded
// by the receiving sessions that have had bytes appended in this process.
type uploadLocks struct {
	mu sync.Mutex
	m  map[string]*uploadLock
}

// uploadLock is held by at most one request at a time. hasher and hashed
// are only touched by the holder: hasher has consumed exactly the first
// hashed bytes of the staging file, or is nil.
type uploadLock struct {
	id     string
	sem    chan struct{}
	refs   int
	hasher hash.Hash
	hashed int64
}

func newUploadLocks() *uploadLocks { return &uploadLocks{m: map[string]*uploadLock{}} }

func (l *uploadLocks) ref(id string) *uploadLock {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.m[id]
	if e == nil {
		e = &uploadLock{id: id, sem: make(chan struct{}, 1)}
		l.m[id] = e
	}
	e.refs++
	return e
}

// unref drops a reference and deletes the entry when nothing needs it.
// hasher is read only when refs is 0, i.e. when no holder can be writing it.
func (l *uploadLocks) unref(e *uploadLock) {
	l.mu.Lock()
	defer l.mu.Unlock()
	e.refs--
	if e.refs == 0 && e.hasher == nil && l.m[e.id] == e {
		delete(l.m, e.id)
	}
}

// tryAcquire takes the lock without waiting; nil when it is held.
func (l *uploadLocks) tryAcquire(id string) *uploadLock {
	e := l.ref(id)
	select {
	case e.sem <- struct{}{}:
		return e
	default:
		l.unref(e)
		return nil
	}
}

// acquire waits up to wait (real time; a network-style timeout) or until ctx
// ends; nil when the lock could not be taken.
func (l *uploadLocks) acquire(ctx context.Context, id string, wait time.Duration) *uploadLock {
	e := l.ref(id)
	select {
	case e.sem <- struct{}{}:
		return e
	default:
	}
	t := time.NewTimer(wait)
	defer t.Stop()
	select {
	case e.sem <- struct{}{}:
		return e
	case <-t.C:
	case <-ctx.Done():
	}
	l.unref(e)
	return nil
}

// release frees the lock. forget drops the cached hasher, which also lets
// the entry leave the map; use it whenever the session leaves receiving.
func (l *uploadLocks) release(e *uploadLock, forget bool) {
	if forget {
		// Holder-only fields: clear before handing the slot on.
		e.hasher, e.hashed = nil, 0
	}
	<-e.sem
	l.unref(e)
}

// count reports the number of entries (tests).
func (l *uploadLocks) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.m)
}
