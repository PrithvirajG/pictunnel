package httpapi

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
)

// readyRetryAfter is the Retry-After of a failed readiness probe.
const readyRetryAfter = 5 * time.Second

// info returns the server info with the current server time.
func (s *server) info() gen.ServerInfo {
	var out gen.ServerInfo
	if s.d.Info != nil {
		out = s.d.Info()
	}
	out.Time = s.d.Clock.Now().UTC()
	if out.Capabilities == nil {
		out.Capabilities = []string{}
	}
	return out
}

// GetHealthz is the liveness probe.
func (s *server) GetHealthz(context.Context, gen.GetHealthzRequestObject) (gen.GetHealthzResponseObject, error) {
	return gen.GetHealthz200TextResponse("ok"), nil
}

// GetReadyz is the readiness probe: 503 server_unavailable while Ready
// fails. A non-domain failure is logged, never sent.
func (s *server) GetReadyz(ctx context.Context, _ gen.GetReadyzRequestObject) (gen.GetReadyzResponseObject, error) {
	if s.d.Ready != nil {
		if err := s.d.Ready(ctx); err != nil {
			if _, ok := apperr.As(err); ok {
				return nil, err
			}
			loggerFrom(ctx).Warn("not ready", "request_id", RequestIDFrom(ctx), "err", err)
			return nil, apperr.ServerUnavailable(readyRetryAfter)
		}
	}
	return gen.GetReadyz200TextResponse("ready"), nil
}

// GetServerInfo returns identity, versions, capabilities and upload limits.
func (s *server) GetServerInfo(context.Context, gen.GetServerInfoRequestObject) (gen.GetServerInfoResponseObject, error) {
	return gen.GetServerInfo200JSONResponse(s.info()), nil
}
