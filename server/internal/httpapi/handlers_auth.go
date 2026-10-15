package httpapi

import (
	"context"
	"net/http"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// SetupFirstAdmin creates the first admin. Off the loopback listener the
// PicTunnel-Setup-Token header must match (S§4.1).
func (s *server) SetupFirstAdmin(ctx context.Context, req gen.SetupFirstAdminRequestObject) (gen.SetupFirstAdminResponseObject, error) {
	if !s.local && !s.d.Users.CheckSetupToken(ctx, optString(req.Params.PicTunnelSetupToken)) {
		return nil, apperr.Forbidden("A valid PicTunnel-Setup-Token header is required.")
	}
	u, err := s.d.Users.Setup(ctx, req.Body.Username, req.Body.Password, optString(req.Body.DisplayName))
	if err != nil {
		return nil, err
	}
	var m mapper
	out := gen.SetupFirstAdmin201JSONResponse{User: m.user(u)}
	return out, m.err
}

// Login logs in with a password: tokens mode registers a device and returns
// a token pair; cookie mode sets pt_session and returns the CSRF token.
func (s *server) Login(ctx context.Context, req gen.LoginRequestObject) (gen.LoginResponseObject, error) {
	b := req.Body
	var m mapper
	switch b.Mode {
	case gen.Tokens:
		if b.Device == nil {
			return nil, apperr.InvalidRequest("device is required in tokens mode")
		}
		u, d, tp, err := s.d.Auth.Login(ctx, b.Username, b.Password, deviceInfo(*b.Device))
		if err != nil {
			return nil, err
		}
		out := gen.LoginResponse{User: m.user(u), Device: ptr(m.device(d)), Tokens: ptr(tokenPair(tp))}
		return gen.Login200JSONResponse(out), m.err
	case gen.Cookie:
		u, d, sess, csrf, exp, err := s.d.Auth.LoginCookie(ctx, b.Username, b.Password)
		if err != nil {
			return nil, err
		}
		out := gen.LoginResponse{User: m.user(u), Device: ptr(m.device(d)), CsrfToken: ptr(csrf)}
		return loginCookieResponse{body: out, cookie: s.sessionCookie(sess, exp)}, m.err
	default:
		return nil, apperr.InvalidRequest("mode must be tokens or cookie")
	}
}

func deviceInfo(d gen.DeviceRegistration) service.DeviceInfo {
	return service.DeviceInfo{Name: d.DeviceName, Platform: string(d.Platform), AppVersion: d.AppVersion}
}

// sessionCookie is pt_session: Path /, HttpOnly, SameSite=Lax, Secure
// except on the loopback listener (S§4.2).
func (s *server) sessionCookie(value string, expires time.Time) *http.Cookie {
	return &http.Cookie{
		Name: sessionCookie, Value: value, Path: "/", Expires: expires.UTC(),
		HttpOnly: true, Secure: !s.local, SameSite: http.SameSiteLaxMode,
	}
}

type loginCookieResponse struct {
	body   gen.LoginResponse
	cookie *http.Cookie
}

func (r loginCookieResponse) VisitLoginResponse(w http.ResponseWriter) error {
	http.SetCookie(w, r.cookie)
	return gen.Login200JSONResponse(r.body).VisitLoginResponse(w)
}

// RefreshTokens rotates a refresh token (S§4.2).
func (s *server) RefreshTokens(ctx context.Context, req gen.RefreshTokensRequestObject) (gen.RefreshTokensResponseObject, error) {
	tp, err := s.d.Auth.Refresh(ctx, req.Body.RefreshToken)
	if err != nil {
		return nil, err
	}
	return gen.RefreshTokens200JSONResponse(tokenPair(tp)), nil
}

// Logout revokes the caller's device; a cookie session also gets its cookie
// cleared.
func (s *server) Logout(ctx context.Context, _ gen.LogoutRequestObject) (gen.LogoutResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	if err := s.d.Auth.Logout(ctx, p); err != nil {
		return nil, err
	}
	if p.Via == service.ViaCookie {
		c := s.sessionCookie("", time.Unix(0, 0))
		c.MaxAge = -1
		return logoutCookieResponse{cookie: c}, nil
	}
	return gen.Logout204Response{}, nil
}

type logoutCookieResponse struct{ cookie *http.Cookie }

func (r logoutCookieResponse) VisitLogoutResponse(w http.ResponseWriter) error {
	http.SetCookie(w, r.cookie)
	return gen.Logout204Response{}.VisitLogoutResponse(w)
}

// CreatePairingCode issues a pairing code for the caller (S§4.3).
func (s *server) CreatePairingCode(ctx context.Context, _ gen.CreatePairingCodeRequestObject) (gen.CreatePairingCodeResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	code, uri, exp, err := s.d.Pairing.Create(ctx, p)
	if err != nil {
		return nil, err
	}
	return gen.CreatePairingCode201JSONResponse{Code: code, QrUri: uri, ExpiresAt: utc(exp)}, nil
}

// RedeemPairingCode exchanges a pairing code for device credentials.
func (s *server) RedeemPairingCode(ctx context.Context, req gen.RedeemPairingCodeRequestObject) (gen.RedeemPairingCodeResponseObject, error) {
	u, d, tp, err := s.d.Pairing.Redeem(ctx, req.Body.Code, deviceInfo(req.Body.Device))
	if err != nil {
		return nil, err
	}
	var m mapper
	out := gen.RedeemPairingCode201JSONResponse{
		ServerId: s.info().ServerId, User: m.user(u), Device: m.device(d), Tokens: tokenPair(tp),
	}
	return out, m.err
}
