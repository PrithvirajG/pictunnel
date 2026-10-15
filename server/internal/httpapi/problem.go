package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
)

const problemTypePrefix = "urn:pictunnel:problem:"

type ctxKey int

const (
	ctxRequestID ctxKey = iota
	ctxPrincipal
	ctxLogger
)

func withRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, ctxRequestID, id)
}

// RequestIDFrom returns the request id set by the request-id middleware.
func RequestIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(ctxRequestID).(string)
	return id
}

func withLogger(ctx context.Context, l *slog.Logger) context.Context {
	return context.WithValue(ctx, ctxLogger, l)
}

func loggerFrom(ctx context.Context) *slog.Logger {
	if l, ok := ctx.Value(ctxLogger).(*slog.Logger); ok {
		return l
	}
	return slog.Default()
}

// WriteProblem renders err as an RFC 9457 problem (S§8): type
// urn:pictunnel:problem:<code>, title, status, detail, code, request_id and
// the error's Extra members, with its Headers. An error that is not an
// *apperr.Error becomes 500 internal; it is logged with the request id and
// its text never reaches the client.
func WriteProblem(w http.ResponseWriter, r *http.Request, err error) {
	ctx := r.Context()
	rid := RequestIDFrom(ctx)
	if rid == "" {
		rid = ids.New()
	}
	e, ok := apperr.As(err)
	if !ok {
		loggerFrom(ctx).Error("internal error", "request_id", rid, "method", r.Method, "path", r.URL.Path, "err", err)
		e = apperr.Internal()
	} else if e.Status >= 500 {
		loggerFrom(ctx).Warn("server error", "request_id", rid, "code", e.Code, "err", err)
	}
	body := make(map[string]any, len(e.Extra)+6)
	for k, v := range e.Extra {
		body[k] = v
	}
	body["type"] = problemTypePrefix + e.Code
	body["title"] = e.Title
	body["status"] = e.Status
	body["code"] = e.Code
	body["request_id"] = rid
	if e.Detail != "" {
		body["detail"] = e.Detail
	} else {
		delete(body, "detail")
	}
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(body); err != nil {
		// Extra held something unencodable; fall back to the bare problem.
		buf.Reset()
		_ = json.NewEncoder(&buf).Encode(map[string]any{
			"type": problemTypePrefix + e.Code, "title": e.Title, "status": e.Status, "code": e.Code, "request_id": rid,
		})
	}
	h := w.Header()
	for k, vs := range e.Headers {
		h[k] = append([]string(nil), vs...)
	}
	h.Set("Content-Type", "application/problem+json")
	h.Del("Content-Length")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(e.Status)
	_, _ = buf.WriteTo(w)
}
