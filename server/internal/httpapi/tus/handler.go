// Package tus is the hand-written tus 1.0 handler mounted on
// /api/v1/uploads (S§6.1, P§7.3). It parses and validates the tus headers,
// streams the body into UploadService and renders the tus response headers;
// the upload state machine lives in the service.
//
// The handler sits behind the API middleware (request id, recover, access
// log, version gate, auth, CSRF, rate limit). It does not import httpapi:
// the caller injects the principal lookup and the problem writer.
package tus

import (
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// Protocol constants (P§7.3, P§11.5).
const (
	Version       = "1.0.0"
	Extensions    = "creation,creation-with-upload,termination,expiration,checksum"
	ChecksumAlgo  = "sha256"
	ContentType   = "application/offset+octet-stream"
	BasePath      = "/api/v1/uploads"
	sha256Size    = 32
	excessProbeSz = 1
)

// idleTimeout bounds each body read (S§6.1); tests shorten it.
var idleTimeout = 60 * time.Second

// ProblemWriter renders an error as a problem response (httpapi.WriteProblem).
type ProblemWriter func(http.ResponseWriter, *http.Request, error)

type handler struct {
	up      *service.UploadService
	auth    func(*http.Request) (service.Principal, error)
	problem ProblemWriter
	maxSize int64
	idle    time.Duration
	log     *slog.Logger
}

// New returns the tus handler for /api/v1/uploads and
// /api/v1/uploads/{upload_id}. auth returns the authenticated caller (the
// principal the auth middleware stored); problem renders errors.
func New(up *service.UploadService, auth func(*http.Request) (service.Principal, error), cfg config.Config,
	log *slog.Logger, problem ProblemWriter) http.Handler {
	max := cfg.Upload.MaxFileBytes
	if max <= 0 {
		max = service.DefaultMaxFileBytes
	}
	if log == nil {
		log = slog.Default()
	}
	return &handler{up: up, auth: auth, problem: problem, maxSize: max, idle: idleTimeout, log: log}
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Tus-Resumable", Version)
	id, resource, ok := splitPath(r.URL.Path)
	if !ok {
		h.problem(w, r, apperr.NotFound())
		return
	}
	if r.Method == http.MethodOptions {
		h.options(w)
		return
	}
	var serve func(http.ResponseWriter, *http.Request, service.Principal, string)
	switch {
	case !resource && r.Method == http.MethodPost:
		serve = h.create
	case resource && r.Method == http.MethodHead:
		serve = h.head
	case resource && r.Method == http.MethodPatch:
		serve = h.patch
	case resource && r.Method == http.MethodDelete:
		serve = h.terminate
	default:
		h.problem(w, r, apperr.NotFound()) // unknown method
		return
	}
	if r.Method == http.MethodHead {
		w.Header().Set("Cache-Control", "no-store")
	}
	if r.Header.Get("Tus-Resumable") != Version {
		h.problem(w, r, apperr.TusPrecondition())
		return
	}
	p, err := h.auth(r)
	if err != nil {
		h.problem(w, r, err)
		return
	}
	serve(w, r, p, id)
}

// splitPath returns the upload id of /api/v1/uploads/{id} (resource true)
// or "" for /api/v1/uploads.
func splitPath(p string) (id string, resource, ok bool) {
	if p == BasePath {
		return "", false, true
	}
	id, found := strings.CutPrefix(p, BasePath+"/")
	if !found || id == "" || strings.Contains(id, "/") {
		return "", false, false
	}
	return id, true, true
}

func (h *handler) options(w http.ResponseWriter) {
	hd := w.Header()
	hd.Set("Tus-Version", Version)
	hd.Set("Tus-Extension", Extensions)
	hd.Set("Tus-Max-Size", strconv.FormatInt(h.maxSize, 10))
	hd.Set("Tus-Checksum-Algorithm", ChecksumAlgo)
	w.WriteHeader(http.StatusNoContent)
}

// create is POST /api/v1/uploads (creation, creation-with-upload).
func (h *handler) create(w http.ResponseWriter, r *http.Request, p service.Principal, _ string) {
	if r.Header.Get("Upload-Defer-Length") != "" {
		h.problem(w, r, apperr.InvalidRequest("Upload-Defer-Length is not supported."))
		return
	}
	length, ok := parseNonNegative(r.Header.Get("Upload-Length"))
	if !ok {
		h.problem(w, r, apperr.InvalidRequest("Upload-Length is required as a non-negative integer."))
		return
	}
	meta, err := service.ParseUploadMetadata(r.Header.Get("Upload-Metadata"))
	if err != nil {
		h.problem(w, r, err)
		return
	}
	hasBody := r.ContentLength != 0
	if hasBody && !isOffsetOctetStream(r) {
		h.problem(w, r, apperr.InvalidRequest("A request body requires Content-Type: "+ContentType+"."))
		return
	}
	checksum, err := parseChecksum(r.Header.Get("Upload-Checksum"))
	if err != nil {
		h.problem(w, r, err)
		return
	}
	if hasBody && r.ContentLength > length {
		h.problem(w, r, apperr.InvalidRequest("The request body exceeds Upload-Length."))
		return
	}
	in := service.CreateInput{Length: length, Meta: meta, BodyChecksum: checksum}
	b := h.newBody(w, r)
	if hasBody {
		in.Body = b
	}
	v, err := h.up.Create(r.Context(), p, in)
	if !h.finishBody(w, r, b, err) {
		return
	}
	hd := w.Header()
	hd.Set("Location", BasePath+"/"+v.ID)
	if v.Offset > 0 || v.Done {
		hd.Set("Upload-Offset", strconv.FormatInt(v.Offset, 10))
	}
	setProgress(hd, v, true)
	w.WriteHeader(http.StatusCreated)
}

// head is HEAD /api/v1/uploads/{id}.
func (h *handler) head(w http.ResponseWriter, r *http.Request, p service.Principal, id string) {
	v, err := h.up.Head(r.Context(), p, id)
	if err != nil {
		h.problem(w, r, err)
		return
	}
	hd := w.Header()
	hd.Set("Upload-Offset", strconv.FormatInt(v.Offset, 10))
	hd.Set("Upload-Length", strconv.FormatInt(v.Length, 10))
	setProgress(hd, v, false)
	w.WriteHeader(http.StatusOK)
}

// patch is PATCH /api/v1/uploads/{id}.
func (h *handler) patch(w http.ResponseWriter, r *http.Request, p service.Principal, id string) {
	if !isOffsetOctetStream(r) {
		h.problem(w, r, apperr.InvalidRequest("PATCH requires Content-Type: "+ContentType+"."))
		return
	}
	offset, ok := parseNonNegative(r.Header.Get("Upload-Offset"))
	if !ok {
		h.problem(w, r, apperr.InvalidRequest("Upload-Offset is required as a non-negative integer."))
		return
	}
	checksum, err := parseChecksum(r.Header.Get("Upload-Checksum"))
	if err != nil {
		h.problem(w, r, err)
		return
	}
	if r.ContentLength > 0 {
		// Reject a body that cannot fit before reading any of it. A wrong
		// offset is left to the service (409 offset_mismatch).
		cur, err := h.up.Peek(r.Context(), p, id)
		if err != nil {
			h.problem(w, r, err)
			return
		}
		if !cur.Done && offset <= cur.Length && r.ContentLength > cur.Length-offset {
			h.problem(w, r, apperr.InvalidRequest("The request body exceeds the remaining Upload-Length."))
			return
		}
	}
	b := h.newBody(w, r)
	v, err := h.up.Append(r.Context(), p, id, offset, b, checksum)
	if !h.finishBody(w, r, b, err) {
		return
	}
	w.Header().Set("Upload-Offset", strconv.FormatInt(v.Offset, 10))
	setProgress(w.Header(), v, true)
	w.WriteHeader(http.StatusNoContent)
}

// terminate is DELETE /api/v1/uploads/{id}.
func (h *handler) terminate(w http.ResponseWriter, r *http.Request, p service.Principal, id string) {
	if err := h.up.Terminate(r.Context(), p, id); err != nil {
		h.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// setProgress sets Upload-Expires while the upload is receiving, and the
// asset headers once it is done (PicTunnel-Asset-Created when created is
// requested: POST and PATCH, not HEAD).
func setProgress(hd http.Header, v service.UploadView, created bool) {
	if !v.Done {
		hd.Set("Upload-Expires", v.ExpiresAt.UTC().Format(http.TimeFormat))
		return
	}
	hd.Set("PicTunnel-Asset-Id", v.AssetID)
	if created {
		hd.Set("PicTunnel-Asset-Created", strconv.FormatBool(v.AssetCreated))
	}
}

// finishBody handles the end of a request that streamed a body. It reports
// whether the caller should write its success response: a body read error
// means the client went away (or idled out), so the response is aborted
// and nothing more is written; a service error is rendered; a chunked body
// that continues past Upload-Length is invalid_request (the bytes up to
// the length are kept).
func (h *handler) finishBody(w http.ResponseWriter, r *http.Request, b *body, err error) bool {
	if b.err == nil && err == nil && b.touched && !b.eof && r.ContentLength < 0 {
		var one [excessProbeSz]byte
		if n, _ := b.Read(one[:]); n > 0 {
			b.done()
			h.problem(w, r, apperr.InvalidRequest("The request body exceeds Upload-Length."))
			return false
		}
	}
	if b.err != nil {
		// Leave an expired deadline: net/http drains the rest of the body
		// before closing an aborted connection, which must not wait for a
		// client that stopped sending.
		b.setDeadline(time.Now())
		h.abort(r, b.err)
	}
	b.done()
	if err != nil {
		h.problem(w, r, err)
		return false
	}
	return true
}

// abort ends a request whose client went away mid-body without writing a
// response (net/http closes the connection).
func (h *handler) abort(r *http.Request, cause error) {
	reason := "client went away"
	var ne net.Error
	if errors.As(cause, &ne) && ne.Timeout() {
		reason = "body idle timeout"
	}
	h.log.Info("tus: request body ended early", "method", r.Method, "path", r.URL.Path, "reason", reason, "err", cause)
	panic(http.ErrAbortHandler)
}

// body is the request body seen by the service: each read extends the
// connection's read deadline by the idle timeout, and the first read error
// is recorded.
type body struct {
	r       io.Reader
	rc      *http.ResponseController
	idle    time.Duration
	log     *slog.Logger
	touched bool
	eof     bool
	err     error
}

func (h *handler) newBody(w http.ResponseWriter, r *http.Request) *body {
	return &body{r: r.Body, rc: http.NewResponseController(w), idle: h.idle, log: h.log}
}

func (b *body) Read(p []byte) (int, error) {
	b.touched = true
	if b.err != nil {
		return 0, b.err
	}
	if b.eof {
		return 0, io.EOF
	}
	b.setDeadline(time.Now().Add(b.idle))
	n, err := b.r.Read(p)
	switch {
	case err == io.EOF:
		b.eof = true
	case err != nil:
		b.err = err
	}
	return n, err
}

// done clears the read deadline set by Read.
func (b *body) done() {
	if b.touched {
		b.setDeadline(time.Time{})
	}
}

func (b *body) setDeadline(t time.Time) {
	if err := b.rc.SetReadDeadline(t); err != nil && !errors.Is(err, http.ErrNotSupported) {
		b.log.Debug("tus: set read deadline", "err", err)
	}
}

func parseNonNegative(s string) (int64, bool) {
	if s == "" || strings.TrimSpace(s) != s || strings.HasPrefix(s, "+") {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil && n >= 0
}

func isOffsetOctetStream(r *http.Request) bool {
	mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	return err == nil && mt == ContentType
}

// parseChecksum parses Upload-Checksum ("sha256 <base64 digest>"); an empty
// header is nil. Another algorithm or a malformed digest is invalid_request.
func parseChecksum(s string) ([]byte, error) {
	if s == "" {
		return nil, nil
	}
	algo, val, ok := strings.Cut(strings.TrimSpace(s), " ")
	if !ok || algo != ChecksumAlgo {
		return nil, apperr.InvalidRequest("Upload-Checksum must use the sha256 algorithm.")
	}
	sum, err := base64.StdEncoding.Strict().DecodeString(strings.TrimSpace(val))
	if err != nil || len(sum) != sha256Size {
		return nil, apperr.InvalidRequest("Upload-Checksum must carry a base64 SHA-256 digest.")
	}
	return sum, nil
}
