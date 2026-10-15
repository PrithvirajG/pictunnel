package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
)

// Limit allows Count requests per Per, as a token bucket with burst Count.
type Limit struct {
	Count int
	Per   time.Duration
}

func (l Limit) valid() bool { return l.Count > 0 && l.Per > 0 }

// RateLimits are the per-operation limits (S§4.4). A zero Limit selects the
// default.
type RateLimits struct {
	Login  Limit // per (IP, username)
	Redeem Limit // per IP
	Setup  Limit // per IP
}

// DefaultRateLimits: login 10/min per (IP, username), redeem 10/min per IP,
// setup 5/min per IP.
func DefaultRateLimits() RateLimits {
	return RateLimits{
		Login:  Limit{Count: 10, Per: time.Minute},
		Redeem: Limit{Count: 10, Per: time.Minute},
		Setup:  Limit{Count: 5, Per: time.Minute},
	}
}

func (l RateLimits) withDefaults() RateLimits {
	d := DefaultRateLimits()
	if l.Login.valid() {
		d.Login = l.Login
	}
	if l.Redeem.valid() {
		d.Redeem = l.Redeem
	}
	if l.Setup.valid() {
		d.Setup = l.Setup
	}
	return d
}

// maxLoginPeek bounds how much of a login body is read to find the username.
const (
	maxLoginPeek  = 64 << 10
	sweepInterval = time.Minute
)

// buckets is a keyed set of token buckets driven by an injectable clock.
// Buckets that have refilled completely are dropped periodically.
type buckets struct {
	limit Limit
	clk   clock.Clock

	mu        sync.Mutex
	m         map[string]*rate.Limiter
	lastSweep time.Time
}

func newBuckets(l Limit, clk clock.Clock) *buckets {
	return &buckets{limit: l, clk: clk, m: map[string]*rate.Limiter{}}
}

// take consumes one token for key; it returns the wait before the next
// token when the bucket is empty.
func (b *buckets) take(key string) (time.Duration, bool) {
	now := b.clk.Now()
	b.mu.Lock()
	defer b.mu.Unlock()
	if now.Sub(b.lastSweep) >= sweepInterval {
		for k, l := range b.m {
			if l.TokensAt(now) >= float64(b.limit.Count) {
				delete(b.m, k)
			}
		}
		b.lastSweep = now
	}
	l := b.m[key]
	if l == nil {
		l = rate.NewLimiter(rate.Every(b.limit.Per/time.Duration(b.limit.Count)), b.limit.Count)
		b.m[key] = l
	}
	res := l.ReserveN(now, 1)
	if !res.OK() {
		return b.limit.Per, false
	}
	if d := res.DelayFrom(now); d > 0 {
		res.CancelAt(now)
		return d, false
	}
	return 0, true
}

// rateLimiter holds the per-operation buckets.
type rateLimiter struct {
	login, redeem, setup *buckets
}

func newRateLimiter(l RateLimits, clk clock.Clock) *rateLimiter {
	l = l.withDefaults()
	return &rateLimiter{login: newBuckets(l.Login, clk), redeem: newBuckets(l.Redeem, clk), setup: newBuckets(l.Setup, clk)}
}

// remoteIP is the request's peer address without the port. Forwarding
// headers are not trusted.
func remoteIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// loginUsername reads the username from a login body and restores the body.
func loginUsername(r *http.Request) string {
	if r.Body == nil {
		return ""
	}
	buf, _ := io.ReadAll(io.LimitReader(r.Body, maxLoginPeek))
	r.Body = struct {
		io.Reader
		io.Closer
	}{io.MultiReader(bytes.NewReader(buf), r.Body), r.Body}
	var v struct {
		Username string `json:"username"`
	}
	_ = json.Unmarshal(buf, &v)
	return strings.ToLower(strings.TrimSpace(v.Username))
}

// rateLimit applies the S§4.4 limits; over the limit the response is 429
// rate_limited with Retry-After. Disabled by rate_limit.enabled = false.
func (s *server) rateLimit(next http.Handler) http.Handler {
	if !s.d.Cfg.RateLimit.Enabled {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			var b *buckets
			key := remoteIP(r)
			switch r.URL.Path {
			case pathLogin:
				b, key = s.limits.login, key+"\x00"+loginUsername(r)
			case pathRedeem:
				b = s.limits.redeem
			case pathSetup:
				b = s.limits.setup
			}
			if b != nil {
				if wait, ok := b.take(key); !ok {
					WriteProblem(w, r, apperr.RateLimited(wait))
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}
