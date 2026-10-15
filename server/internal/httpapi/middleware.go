package httpapi

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
)

const (
	headerRequestID = "X-Request-Id"
	headerClient    = "PicTunnel-Client"
	maxRequestIDLen = 128
)

// statusWriter records the status and size of a response. Unwrap keeps
// http.ResponseController (deadlines, flush) working through it.
type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	return n, err
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// validRequestID accepts short printable ASCII ids from clients.
func validRequestID(id string) bool {
	if id == "" || len(id) > maxRequestIDLen {
		return false
	}
	for i := 0; i < len(id); i++ {
		if id[i] < 0x21 || id[i] > 0x7e {
			return false
		}
	}
	return true
}

// requestID echoes a valid X-Request-Id or generates one (P§3) and puts it,
// with the logger, in the request context.
func (s *server) requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get(headerRequestID)
		if !validRequestID(id) {
			id = ids.New()
		}
		w.Header().Set(headerRequestID, id)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			// API responses are per-user; the media routes override this.
			w.Header().Set("Cache-Control", "no-store")
		}
		ctx := withLogger(withRequestID(r.Context(), id), s.log)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// stackPanic carries a recovered panic value with the stack where it was
// first recovered, so re-panicking middleware does not lose it.
type stackPanic struct {
	value any
	stack string
}

func withStack(v any) stackPanic {
	if p, ok := v.(stackPanic); ok {
		return p
	}
	return stackPanic{value: v, stack: string(debug.Stack())}
}

// recoverer turns a panic into 500 internal (logged with the stack, never
// sent to the client). http.ErrAbortHandler is re-raised.
func (s *server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sw := &statusWriter{ResponseWriter: w}
		defer func() {
			v := recover()
			if v == nil {
				return
			}
			p := withStack(v)
			if err, ok := p.value.(error); ok && errors.Is(err, http.ErrAbortHandler) {
				panic(p.value)
			}
			s.log.Error("panic", "request_id", RequestIDFrom(r.Context()), "method", r.Method,
				"path", r.URL.Path, "panic", fmt.Sprint(p.value), "stack", p.stack)
			if sw.status == 0 {
				WriteProblem(w, r, apperr.Internal())
			}
		}()
		next.ServeHTTP(sw, r)
	})
}

// accessLog logs one line per request.
func (s *server) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w}
		defer func() {
			v := recover()
			status := sw.status
			switch {
			case v != nil:
				status = http.StatusInternalServerError
			case status == 0:
				status = http.StatusOK
			}
			defer func() {
				if v != nil {
					panic(withStack(v)) // handled by recoverer
				}
			}()
			s.log.Info("http", "request_id", RequestIDFrom(r.Context()), "method", r.Method, "path", r.URL.Path,
				"status", status, "bytes", sw.bytes, "duration_ms", time.Since(start).Milliseconds(),
				"remote", remoteIP(r))
		}()
		next.ServeHTTP(sw, r)
	})
}

// versionGateExempt reports whether the request skips the version gate:
// server info, health probes and OPTIONS (S§4.4).
func versionGateExempt(r *http.Request) bool {
	if r.Method == http.MethodOptions {
		return true
	}
	switch r.URL.Path {
	case "/api/v1/server/info", "/healthz", "/readyz":
		return true
	}
	return false
}

// versionGate answers 426 client_too_old when PicTunnel-Client names a
// platform/version below cfg.Clients.MinVersion (S§4.4). A missing or
// unparsable header, or a platform without a minimum, passes.
func (s *server) versionGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if hdr := r.Header.Get(headerClient); hdr != "" && !versionGateExempt(r) {
			platform, version, ok := strings.Cut(strings.TrimSpace(hdr), "/")
			if ok {
				min := s.d.Cfg.Clients.MinVersion[strings.ToLower(platform)]
				if versionBelow(version, min) {
					WriteProblem(w, r, apperr.ClientTooOld(min))
					return
				}
			}
		}
		next.ServeHTTP(w, r)
	})
}

// parseVersion reads up to three dot-separated numeric components, ignoring
// any pre-release or build suffix ("-…", "+…").
func parseVersion(v string) ([3]int, bool) {
	var out [3]int
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	parts := strings.Split(v, ".")
	if v == "" || len(parts) > 3 {
		return out, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return out, false
		}
		out[i] = n
	}
	return out, true
}

// versionBelow reports whether version is strictly below min. Unparsable
// input (either side) is not below.
func versionBelow(version, min string) bool {
	v, ok1 := parseVersion(version)
	m, ok2 := parseVersion(min)
	if !ok1 || !ok2 {
		return false
	}
	for i := range v {
		if v[i] != m[i] {
			return v[i] < m[i]
		}
	}
	return false
}

// newLogger returns l or a discarding logger.
func newLogger(l *slog.Logger) *slog.Logger {
	if l != nil {
		return l
	}
	return slog.New(slog.DiscardHandler)
}
