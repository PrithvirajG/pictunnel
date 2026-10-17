package httpapi

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
)

func limiterServer(t *testing.T, l RateLimits) (*server, http.Handler) {
	t.Helper()
	var cfg config.Config
	cfg.RateLimit.Enabled = true
	clk := clocktest.NewFake(time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC))
	s := &server{d: Deps{Cfg: cfg, Clock: clk}, log: newLogger(nil), limits: newRateLimiter(l, clk)}
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	return s, s.rateLimit(ok)
}

func login(h http.Handler, ip, body string) int {
	r := httptest.NewRequest("POST", pathLogin, strings.NewReader(body))
	r.RemoteAddr = ip + ":40000"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w.Code
}

// Attacker-chosen usernames that cannot exist share one bucket, so N
// distinct long names do not grow the map.
func TestLoginLimiterInvalidUsernamesShareKey(t *testing.T) {
	s, h := limiterServer(t, RateLimits{LoginIP: Limit{Count: 1 << 20, Per: time.Minute}})
	for i := 0; i < 500; i++ {
		name := fmt.Sprintf("%s-%d", strings.Repeat("A", 1000), i)
		login(h, "10.0.0.1", `{"username":"`+name+`","password":"x","mode":"tokens"}`)
	}
	if n := s.limits.login.size(); n != 1 {
		t.Fatalf("login buckets = %d, want 1", n)
	}
	for _, u := range []string{"", "ab", "-bad", strings.Repeat("a", 33), "has space", "#invalid"} {
		r := httptest.NewRequest("POST", pathLogin, strings.NewReader(`{"username":"`+u+`"}`))
		if got := loginUsername(r); got != invalidUsernameKey {
			t.Errorf("loginUsername(%q) = %q", u, got)
		}
	}
	r := httptest.NewRequest("POST", pathLogin, strings.NewReader(`{"username":" Alice.B "}`))
	if got := loginUsername(r); got != "alice.b" {
		t.Errorf("valid username key = %q", got)
	}
}

// A bucket set never exceeds its cap; new keys are rejected while it is
// full of active buckets and accepted again once they refill.
func TestBucketSetIsBounded(t *testing.T) {
	clk := clocktest.NewFake(time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC))
	b := newBuckets(Limit{Count: 2, Per: time.Minute}, clk)
	b.maxKeys = 100
	rejected := 0
	for i := 0; i < 1000; i++ {
		if _, ok := b.take(fmt.Sprintf("k%d", i)); !ok {
			rejected++
		}
	}
	if n := b.size(); n > 100 || rejected != 900 {
		t.Fatalf("size %d rejected %d", n, rejected)
	}
	clk.Advance(time.Minute)
	if _, ok := b.take("fresh"); !ok {
		t.Fatal("refilled buckets were not swept")
	}
	if n := b.size(); n > 100 {
		t.Fatalf("size %d after sweep", n)
	}
}

// Rotating addresses inside one IPv6 /64 does not escape the per-IP limit.
func TestLoginLimiterIPv6SharesSlash64(t *testing.T) {
	_, h := limiterServer(t, RateLimits{LoginIP: Limit{Count: 3, Per: time.Minute}})
	codes := map[int]int{}
	for i := 1; i <= 10; i++ {
		ip := fmt.Sprintf("[2001:db8:1:2::%x]", i)
		codes[login(h, ip, fmt.Sprintf(`{"username":"user%d","password":"x"}`, i))]++
	}
	if codes[http.StatusTooManyRequests] != 7 {
		t.Fatalf("codes %v, want 7 rejected", codes)
	}
	// Another /64 has its own budget.
	if c := login(h, "[2001:db8:1:3::1]", `{"username":"other","password":"x"}`); c == http.StatusTooManyRequests {
		t.Fatal("different /64 was limited")
	}
	if k := ipKey("[2001:db8::1]:5"); k != "2001:db8::/64" {
		t.Errorf("ipKey v6 = %q", k)
	}
	if k := ipKey("10.1.2.3:5"); k != "10.1.2.3" {
		t.Errorf("ipKey v4 = %q", k)
	}
}

// A full set of active buckets is re-swept at most once per second, so a
// flood of new keys does not run an O(n) scan per request.
func TestFullSetSweepIsThrottled(t *testing.T) {
	clk := clocktest.NewFake(time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC))
	b := newBuckets(Limit{Count: 2, Per: time.Minute}, clk)
	b.maxKeys = 10
	for i := 0; i < 500; i++ {
		b.take(fmt.Sprintf("k%d", i))
	}
	if b.fullSweeps > 1 {
		t.Fatalf("full sweeps = %d, want ≤ 1 within a second", b.fullSweeps)
	}
	clk.Advance(2 * time.Second)
	b.take("again")
	if b.fullSweeps != 2 {
		t.Fatalf("full sweeps = %d after a second, want 2", b.fullSweeps)
	}
}

func TestLoginLimiterPerIP(t *testing.T) {
	_, h := limiterServer(t, RateLimits{LoginIP: Limit{Count: 3, Per: time.Minute}})
	for i := 0; i < 3; i++ {
		if c := login(h, "10.0.0.2", fmt.Sprintf(`{"username":"user%d"}`, i)); c != 204 {
			t.Fatalf("login %d: %d", i, c)
		}
	}
	if c := login(h, "10.0.0.2", `{"username":"another"}`); c != 429 {
		t.Fatalf("4th distinct username from one IP: %d, want 429", c)
	}
	if c := login(h, "10.0.0.3", `{"username":"another"}`); c != 204 {
		t.Fatalf("other IP: %d", c)
	}
	if d := DefaultRateLimits().LoginIP; d.Count != 30 || d.Per != time.Minute {
		t.Fatalf("default per-IP login limit %+v", d)
	}
}
