package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"regexp"
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
	Login   Limit // per (IP, username)
	LoginIP Limit // per IP, across usernames (coarse guard)
	Redeem  Limit // per IP
	Setup   Limit // per IP
}

// DefaultRateLimits: login 10/min per (IP, username) and 30/min per IP,
// redeem 10/min per IP, setup 5/min per IP.
func DefaultRateLimits() RateLimits {
	return RateLimits{
		Login:   Limit{Count: 10, Per: time.Minute},
		LoginIP: Limit{Count: 30, Per: time.Minute},
		Redeem:  Limit{Count: 10, Per: time.Minute},
		Setup:   Limit{Count: 5, Per: time.Minute},
	}
}

func (l RateLimits) withDefaults() RateLimits {
	d := DefaultRateLimits()
	if l.Login.valid() {
		d.Login = l.Login
	}
	if l.LoginIP.valid() {
		d.LoginIP = l.LoginIP
	}
	if l.Redeem.valid() {
		d.Redeem = l.Redeem
	}
	if l.Setup.valid() {
		d.Setup = l.Setup
	}
	return d
}

const (
	// maxLoginPeek bounds how much of a login body is read to find the
	// username.
	maxLoginPeek  = 64 << 10
	sweepInterval = time.Minute
	// maxBucketKeys caps the keys of one bucket set; when it is full of
	// active buckets, new keys are rejected (rate_limited) rather than
	// growing memory.
	maxBucketKeys = 10000
	// invalidUsernameKey stands in for any username that cannot exist, so
	// attacker-chosen names do not create distinct buckets.
	invalidUsernameKey = "#invalid" // "#" never occurs in a valid username
)

// usernameRe is the username rule of S§4.1 (after lowercasing).
var usernameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{2,31}$`)

// buckets is a keyed set of token buckets driven by an injectable clock.
// Buckets that have refilled completely are dropped periodically, or at
// once when the set is full.
type buckets struct {
	limit   Limit
	clk     clock.Clock
	maxKeys int

	mu        sync.Mutex
	m         map[string]*rate.Limiter
	lastSweep time.Time
}

func newBuckets(l Limit, clk clock.Clock) *buckets {
	return &buckets{limit: l, clk: clk, maxKeys: maxBucketKeys, m: map[string]*rate.Limiter{}}
}

// sweep drops buckets that have refilled completely.
func (b *buckets) sweep(now time.Time) {
	for k, l := range b.m {
		if l.TokensAt(now) >= float64(b.limit.Count) {
			delete(b.m, k)
		}
	}
	b.lastSweep = now
}

func (b *buckets) size() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.m)
}

// take consumes one token for key; it returns the wait before the next
// token when the bucket is empty.
func (b *buckets) take(key string) (time.Duration, bool) {
	now := b.clk.Now()
	b.mu.Lock()
	defer b.mu.Unlock()
	if now.Sub(b.lastSweep) >= sweepInterval {
		b.sweep(now)
	}
	l := b.m[key]
	if l == nil {
		if len(b.m) >= b.maxKeys {
			b.sweep(now)
			if len(b.m) >= b.maxKeys {
				return b.limit.Per, false
			}
		}
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
	login, loginIP, redeem, setup *buckets
}

func newRateLimiter(l RateLimits, clk clock.Clock) *rateLimiter {
	l = l.withDefaults()
	return &rateLimiter{
		login: newBuckets(l.Login, clk), loginIP: newBuckets(l.LoginIP, clk),
		redeem: newBuckets(l.Redeem, clk), setup: newBuckets(l.Setup, clk),
	}
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
// A name that fails the username rule maps to one shared key.
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
	u := strings.ToLower(strings.TrimSpace(v.Username))
	if !usernameRe.MatchString(u) {
		return invalidUsernameKey
	}
	return u
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
				if wait, ok := s.limits.loginIP.take(key); !ok {
					WriteProblem(w, r, apperr.RateLimited(wait))
					return
				}
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
