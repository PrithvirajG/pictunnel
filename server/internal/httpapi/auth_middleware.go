package httpapi

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

const (
	sessionCookie  = "pt_session"
	headerCSRF     = "X-CSRF-Token"
	touchTimeout   = 10 * time.Second
	bearerPrefix   = "bearer "
	pathUploads    = "/api/v1/uploads"
	pathSetup      = "/api/v1/auth/setup"
	pathLogin      = "/api/v1/auth/login"
	pathRedeem     = "/api/v1/pairing/redeem"
	pathServerInfo = "/api/v1/server/info"
)

// publicRoutes are the operations without security (OpenAPI security: []).
var publicRoutes = map[string]bool{
	"GET /healthz":              true,
	"GET /readyz":               true,
	"GET " + pathServerInfo:     true,
	"POST " + pathSetup:         true,
	"POST " + pathLogin:         true,
	"POST /api/v1/auth/refresh": true,
	"POST " + pathRedeem:        true,
	"OPTIONS " + pathUploads:    true,
	"HEAD /healthz":             true,
	"HEAD /readyz":              true,
	"HEAD " + pathServerInfo:    true,
}

func isPublic(r *http.Request) bool { return publicRoutes[r.Method+" "+r.URL.Path] }

func withPrincipal(ctx context.Context, p service.Principal) context.Context {
	return context.WithValue(ctx, ctxPrincipal, p)
}

// PrincipalFrom returns the authenticated caller set by the auth middleware.
func PrincipalFrom(ctx context.Context) (service.Principal, bool) {
	p, ok := ctx.Value(ctxPrincipal).(service.Principal)
	return p, ok
}

// principal is PrincipalFrom for handlers behind the auth middleware.
func principal(ctx context.Context) (service.Principal, error) {
	p, ok := PrincipalFrom(ctx)
	if !ok {
		return service.Principal{}, apperr.Unauthorized()
	}
	return p, nil
}

// authenticate resolves a bearer token (preferred) or the pt_session cookie
// (S§4.2). An Authorization header that is not a bearer token is
// unauthorized.
func (s *server) authenticate(r *http.Request) (service.Principal, error) {
	if h := r.Header.Get("Authorization"); h != "" {
		if len(h) <= len(bearerPrefix) || !strings.EqualFold(h[:len(bearerPrefix)], bearerPrefix) {
			return service.Principal{}, apperr.Unauthorized()
		}
		return s.d.Auth.AuthenticateBearer(r.Context(), strings.TrimSpace(h[len(bearerPrefix):]))
	}
	if c, err := r.Cookie(sessionCookie); err == nil && c.Value != "" {
		return s.d.Auth.AuthenticateCookie(r.Context(), c.Value)
	}
	return service.Principal{}, apperr.Unauthorized()
}

// auth requires credentials on every non-public operation, stores the
// principal in the context and records device activity asynchronously
// (TouchLastSeen coalesces to one write per device per minute).
func (s *server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isPublic(r) {
			next.ServeHTTP(w, r)
			return
		}
		p, err := s.authenticate(r)
		if err != nil {
			WriteProblem(w, r, err)
			return
		}
		if s.d.Devices != nil {
			go s.touch(p.DeviceID, RequestIDFrom(r.Context()))
		}
		next.ServeHTTP(w, r.WithContext(withPrincipal(r.Context(), p)))
	})
}

func (s *server) touch(deviceID, requestID string) {
	ctx, cancel := context.WithTimeout(context.Background(), touchTimeout)
	defer cancel()
	if err := s.d.Devices.TouchLastSeen(ctx, deviceID); err != nil {
		s.log.Warn("touch last_seen_at", "request_id", requestID, "device_id", deviceID, "err", err)
	}
}

func safeMethod(m string) bool {
	return m == http.MethodGet || m == http.MethodHead || m == http.MethodOptions
}

// csrf requires a matching X-CSRF-Token on state-changing requests
// authenticated by cookie (S§4.2); otherwise 403 forbidden.
func (s *server) csrf(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if p, ok := PrincipalFrom(r.Context()); ok && p.Via == service.ViaCookie && !safeMethod(r.Method) {
			if !s.d.Auth.CheckCSRF(r.Context(), p, r.Header.Get(headerCSRF)) {
				WriteProblem(w, r, apperr.Forbidden("Missing or invalid X-CSRF-Token."))
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}
