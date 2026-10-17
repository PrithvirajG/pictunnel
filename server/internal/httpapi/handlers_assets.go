package httpapi

import (
	"context"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

const (
	// cacheImmutable: originals and derivatives are content-addressed by
	// the asset's sha256 (2B).
	cacheImmutable = "private, max-age=31536000, immutable"
	// cacheRevalidate: playback may switch to a transcode once one exists.
	cacheRevalidate = "private, no-cache"
	mimeOctetStream = "application/octet-stream"
	mimeJPEG        = "image/jpeg"
	mimeMP4         = "video/mp4"
	mimeWebM        = "video/webm"
)

// GetAsset returns the caller's asset metadata.
func (s *server) GetAsset(ctx context.Context, req gen.GetAssetRequestObject) (gen.GetAssetResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	v, err := s.d.Assets.Get(ctx, p, req.AssetId.String())
	if err != nil {
		return nil, err
	}
	var m mapper
	out := gen.GetAsset200JSONResponse(m.asset(v))
	return out, m.err
}

func assetIDList(b *gen.AssetIdList) []string {
	if b == nil {
		return nil
	}
	return idStrings(b.AssetIds)
}

func (s *server) bulk(ctx context.Context, ids []string,
	fn func(context.Context, service.Principal, []string) (service.BulkResult, error)) (gen.BulkResult, error) {
	p, err := principal(ctx)
	if err != nil {
		return gen.BulkResult{}, err
	}
	res, err := fn(ctx, p, ids)
	if err != nil {
		return gen.BulkResult{}, err
	}
	var m mapper
	out := m.bulk(res)
	return out, m.err
}

// TrashAssets moves the caller's assets to the trash.
func (s *server) TrashAssets(ctx context.Context, req gen.TrashAssetsRequestObject) (gen.TrashAssetsResponseObject, error) {
	out, err := s.bulk(ctx, assetIDList(req.Body), s.d.Trash.Trash)
	if err != nil {
		return nil, err
	}
	return gen.TrashAssets200JSONResponse(out), nil
}

// RestoreAssets restores the caller's assets from the trash.
func (s *server) RestoreAssets(ctx context.Context, req gen.RestoreAssetsRequestObject) (gen.RestoreAssetsResponseObject, error) {
	out, err := s.bulk(ctx, assetIDList(req.Body), s.d.Trash.Restore)
	if err != nil {
		return nil, err
	}
	return gen.RestoreAssets200JSONResponse(out), nil
}

// PurgeAssets permanently deletes the caller's trashed assets.
func (s *server) PurgeAssets(ctx context.Context, req gen.PurgeAssetsRequestObject) (gen.PurgeAssetsResponseObject, error) {
	out, err := s.bulk(ctx, assetIDList(req.Body), s.d.Trash.Purge)
	if err != nil {
		return nil, err
	}
	return gen.PurgeAssets200JSONResponse(out), nil
}

// EmptyTrash purges every trashed asset of the caller.
func (s *server) EmptyTrash(ctx context.Context, _ gen.EmptyTrashRequestObject) (gen.EmptyTrashResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	n, err := s.d.Trash.Empty(ctx, p)
	if err != nil {
		return nil, err
	}
	return gen.EmptyTrash200JSONResponse{PurgedCount: n}, nil
}

// --- Media routes (explicit mux routes, outside the strict wrapper) ---

// assetIDParam reads {asset_id}; a malformed id names nothing (not_found).
func assetIDParam(r *http.Request) (string, error) {
	u, err := uuid.Parse(r.PathValue("asset_id"))
	if err != nil {
		return "", apperr.NotFound()
	}
	return u.String(), nil
}

// rfc5987AttrChar reports whether c may appear unencoded in an RFC 5987
// ext-value (attr-char).
func rfc5987AttrChar(c byte) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	}
	return strings.IndexByte("!#$&+-.^_`|~", c) >= 0
}

// contentDisposition is `attachment; filename*=UTF-8”<pct-encoded name>`.
func contentDisposition(filename string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	b.WriteString("attachment; filename*=UTF-8''")
	for i := 0; i < len(filename); i++ {
		c := filename[i]
		if rfc5987AttrChar(c) {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hex[c>>4])
		b.WriteByte(hex[c&0x0f])
	}
	return b.String()
}

// rangeProblemWriter turns the plain-text 416 of http.ServeContent into a
// problem (OpenAPI RangeNotSatisfiable, code invalid_request).
type rangeProblemWriter struct {
	http.ResponseWriter
	r        *http.Request
	replaced bool
}

func (w *rangeProblemWriter) WriteHeader(code int) {
	if code == http.StatusRequestedRangeNotSatisfiable {
		w.replaced = true
		h := w.Header()
		h.Del("Content-Disposition")
		h.Set("Cache-Control", "no-store")
		WriteProblem(w.ResponseWriter, w.r, apperr.RangeNotSatisfiable())
		return
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *rangeProblemWriter) Write(b []byte) (int, error) {
	if w.replaced {
		return len(b), nil
	}
	return w.ResponseWriter.Write(b)
}

func (w *rangeProblemWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// serveFile serves f with Range and If-None-Match support. The caller has
// set Content-Type, ETag and Cache-Control.
func serveFile(w http.ResponseWriter, r *http.Request, f io.ReadSeeker) {
	http.ServeContent(&rangeProblemWriter{ResponseWriter: w, r: r}, r, "", time.Time{}, f)
}

// mediaRequest resolves the principal and asset id of a media route.
func mediaRequest(r *http.Request) (service.Principal, string, error) {
	p, err := principal(r.Context())
	if err != nil {
		return service.Principal{}, "", err
	}
	id, err := assetIDParam(r)
	return p, id, err
}

// serveOriginal is getAssetOriginal: the original bytes as an attachment,
// ETag "<sha256>".
func (s *server) serveOriginal(w http.ResponseWriter, r *http.Request) {
	p, id, err := mediaRequest(r)
	if err != nil {
		WriteProblem(w, r, err)
		return
	}
	f, a, err := s.d.Assets.OpenOriginal(r.Context(), p, id)
	if err != nil {
		WriteProblem(w, r, err)
		return
	}
	defer f.Close()
	h := w.Header()
	h.Set("Content-Type", mimeOctetStream)
	h.Set("ETag", `"`+a.SHA256+`"`)
	h.Set("Content-Disposition", contentDisposition(a.Filename))
	h.Set("Cache-Control", cacheImmutable)
	serveFile(w, r, f)
}

// serveThumbnail is getAssetThumbnail: a derived JPEG, ETag
// "<sha256>-<size>" (2B).
func (s *server) serveThumbnail(w http.ResponseWriter, r *http.Request) {
	p, id, err := mediaRequest(r)
	if err != nil {
		WriteProblem(w, r, err)
		return
	}
	size := r.URL.Query().Get("size")
	f, a, err := s.d.Assets.OpenThumbnail(r.Context(), p, id, size)
	if err != nil {
		WriteProblem(w, r, err)
		return
	}
	defer f.Close()
	if size == "" {
		size = service.ThumbSize
	}
	h := w.Header()
	h.Set("Content-Type", mimeJPEG)
	h.Set("ETag", `"`+a.SHA256+"-"+size+`"`)
	h.Set("Cache-Control", cacheImmutable)
	serveFile(w, r, f)
}

// servePlayback is getAssetPlayback: the browser-playable video (2B). MP4
// and QuickTime are served as video/mp4 (the documented type); WebM keeps
// its own type.
func (s *server) servePlayback(w http.ResponseWriter, r *http.Request) {
	p, id, err := mediaRequest(r)
	if err != nil {
		WriteProblem(w, r, err)
		return
	}
	f, mime, err := s.d.Assets.OpenPlayback(r.Context(), p, id)
	if err != nil {
		WriteProblem(w, r, err)
		return
	}
	defer f.Close()
	ct := mimeMP4
	if strings.EqualFold(mime, mimeWebM) {
		ct = mimeWebM
	}
	h := w.Header()
	h.Set("Content-Type", ct)
	h.Set("Cache-Control", cacheRevalidate)
	serveFile(w, r, f)
}
