// Package httpapi is the HTTP layer: the strict-server implementation of
// the generated interface, the problem+json writer, middleware (request id,
// recover, access log, version gate, auth, CSRF, rate limits) and the
// explicit media routes. Handlers map request → service call → response or
// apperr and hold no business logic (S§2.1).
package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// Deps are the HTTP layer's dependencies.
type Deps struct {
	Users   *service.UserService
	Auth    *service.AuthService
	Devices *service.DeviceService
	Pairing *service.PairingService
	Check   *service.CheckService
	Feed    *service.FeedService
	Assets  *service.AssetService
	Trash   *service.TrashService
	// Tus serves /api/v1/uploads and /api/v1/uploads/{id} (Task 14). Nil
	// answers 404 not_found.
	Tus http.Handler
	// Info returns the server info; Time is overwritten with Clock.Now().
	Info func() gen.ServerInfo
	// Ready reports readiness for /readyz; nil means ready.
	Ready func(ctx context.Context) error
	Cfg   config.Config
	Clock clock.Clock
	Log   *slog.Logger
	// Limits overrides the rate limits (tests); nil selects the defaults.
	Limits *RateLimits
}

// maxJSONBody bounds non-upload request bodies (a full check batch is well
// under 1 MiB).
const maxJSONBody = 4 << 20

// server implements gen.StrictServerInterface.
type server struct {
	d      Deps
	local  bool
	log    *slog.Logger
	limits *rateLimiter
}

var _ gen.StrictServerInterface = (*server)(nil)

// NewHandler returns the API handler. local is true for the loopback
// listener: setup needs no setup token and the session cookie is not
// Secure.
func NewHandler(d Deps, local bool) http.Handler {
	if d.Clock == nil {
		d.Clock = clock.Real{}
	}
	s := &server{d: d, local: local, log: newLogger(d.Log)}
	var lim RateLimits
	if d.Limits != nil {
		lim = *d.Limits
	}
	s.limits = newRateLimiter(lim, d.Clock)

	strict := gen.NewStrictHandlerWithOptions(s, nil, gen.StrictHTTPServerOptions{
		RequestErrorHandlerFunc:  requestError,
		ResponseErrorHandlerFunc: WriteProblem,
	})
	api := http.NewServeMux()
	gen.HandlerWithOptions(strict, gen.StdHTTPServerOptions{BaseRouter: api, ErrorHandlerFunc: paramError})

	tus := d.Tus
	if tus == nil {
		tus = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { WriteProblem(w, r, apperr.NotFound()) })
	}
	mux := http.NewServeMux()
	mux.Handle(pathUploads, tus)
	mux.Handle(pathUploads+"/{upload_id}", tus)
	mux.HandleFunc("GET /api/v1/assets/{asset_id}/original", s.serveOriginal)
	mux.HandleFunc("GET /api/v1/assets/{asset_id}/thumbnail", s.serveThumbnail)
	mux.HandleFunc("GET /api/v1/assets/{asset_id}/playback", s.servePlayback)
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pattern := api.Handler(r); pattern == "" {
			WriteProblem(w, r, apperr.NotFound()) // unknown path or method
			return
		}
		if r.Body != nil {
			r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
		}
		api.ServeHTTP(w, r)
	}))

	// Outermost first: request id → loopback host guard → recover → access
	// log → version gate → auth → CSRF → rate limit.
	var h http.Handler = mux
	for _, mw := range []func(http.Handler) http.Handler{
		s.rateLimit, s.csrf, s.auth, s.versionGate, s.accessLog, s.recoverer, s.hostGuard, s.requestID,
	} {
		h = mw(h)
	}
	return h
}

// requestError maps strict-server decode errors to 400 invalid_request.
func requestError(w http.ResponseWriter, r *http.Request, err error) {
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		WriteProblem(w, r, apperr.InvalidRequest("request body is too large"))
		return
	}
	WriteProblem(w, r, apperr.InvalidRequest(err.Error()))
}

// paramError maps parameter binding errors: a malformed id in the path
// cannot name an existing resource (404 not_found); anything else is 400
// invalid_request.
func paramError(w http.ResponseWriter, r *http.Request, err error) {
	var pf *gen.InvalidParamFormatError
	if errors.As(err, &pf) && (pf.ParamName == "asset_id" || pf.ParamName == "device_id") {
		WriteProblem(w, r, apperr.NotFound())
		return
	}
	WriteProblem(w, r, apperr.InvalidRequest(err.Error()))
}

// The tus operations are routed to Deps.Tus before the strict router (S§2.2)
// and the media operations to the explicit routes in handlers_assets.go.
// These methods only satisfy the interface.

func (s *server) OptionsUploads(context.Context, gen.OptionsUploadsRequestObject) (gen.OptionsUploadsResponseObject, error) {
	return nil, apperr.Internal()
}

func (s *server) CreateUpload(context.Context, gen.CreateUploadRequestObject) (gen.CreateUploadResponseObject, error) {
	return nil, apperr.Internal()
}

func (s *server) GetUploadOffset(context.Context, gen.GetUploadOffsetRequestObject) (gen.GetUploadOffsetResponseObject, error) {
	return nil, apperr.Internal()
}

func (s *server) AppendUpload(context.Context, gen.AppendUploadRequestObject) (gen.AppendUploadResponseObject, error) {
	return nil, apperr.Internal()
}

func (s *server) TerminateUpload(context.Context, gen.TerminateUploadRequestObject) (gen.TerminateUploadResponseObject, error) {
	return nil, apperr.Internal()
}

func (s *server) GetAssetOriginal(context.Context, gen.GetAssetOriginalRequestObject) (gen.GetAssetOriginalResponseObject, error) {
	return nil, apperr.Internal()
}

func (s *server) GetAssetThumbnail(context.Context, gen.GetAssetThumbnailRequestObject) (gen.GetAssetThumbnailResponseObject, error) {
	return nil, apperr.Internal()
}

func (s *server) GetAssetPlayback(context.Context, gen.GetAssetPlaybackRequestObject) (gen.GetAssetPlaybackResponseObject, error) {
	return nil, apperr.Internal()
}
