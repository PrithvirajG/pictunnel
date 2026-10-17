package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
)

// The tus operations and the three media operations are served outside the
// strict wrapper (S§2.2, Task 13); their strict methods only satisfy the
// interface and return internal.
func TestBypassedStrictMethodsReturnInternal(t *testing.T) {
	s := &server{}
	ctx := context.Background()
	calls := map[string]func() (any, error){
		"OptionsUploads":    func() (any, error) { return s.OptionsUploads(ctx, gen.OptionsUploadsRequestObject{}) },
		"CreateUpload":      func() (any, error) { return s.CreateUpload(ctx, gen.CreateUploadRequestObject{}) },
		"GetUploadOffset":   func() (any, error) { return s.GetUploadOffset(ctx, gen.GetUploadOffsetRequestObject{}) },
		"AppendUpload":      func() (any, error) { return s.AppendUpload(ctx, gen.AppendUploadRequestObject{}) },
		"TerminateUpload":   func() (any, error) { return s.TerminateUpload(ctx, gen.TerminateUploadRequestObject{}) },
		"GetAssetOriginal":  func() (any, error) { return s.GetAssetOriginal(ctx, gen.GetAssetOriginalRequestObject{}) },
		"GetAssetThumbnail": func() (any, error) { return s.GetAssetThumbnail(ctx, gen.GetAssetThumbnailRequestObject{}) },
		"GetAssetPlayback":  func() (any, error) { return s.GetAssetPlayback(ctx, gen.GetAssetPlaybackRequestObject{}) },
	}
	for name, f := range calls {
		resp, err := f()
		e, ok := apperr.As(err)
		if !ok || e.Code != "internal" || resp != nil {
			t.Errorf("%s: resp %v err %v, want internal", name, resp, err)
		}
	}
}

func TestContentDisposition(t *testing.T) {
	cases := map[string]string{
		"IMG_0001.JPG":        `attachment; filename*=UTF-8''IMG_0001.JPG`,
		"Ünïcode photo 1.jpg": `attachment; filename*=UTF-8''%C3%9Cn%C3%AFcode%20photo%201.jpg`,
		`a"b;c\d%e'f.jpg`:     `attachment; filename*=UTF-8''a%22b%3Bc%5Cd%25e%27f.jpg`,
		"x!#$&+-.^_`|~y":      "attachment; filename*=UTF-8''x!#$&+-.^_`|~y",
	}
	for in, want := range cases {
		if got := contentDisposition(in); got != want {
			t.Errorf("contentDisposition(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestClientVersionBelow(t *testing.T) {
	cases := []struct {
		v, min string
		below  bool
	}{
		{"0.0.1", "0.1.0", true},
		{"0.1.0", "0.1.0", false},
		{"0.1.0-beta.1", "0.1.0", false}, // pre-release suffix ignored
		{"0.10.0", "0.9.0", false},
		{"1.0", "0.9.9", false},
		{"0.9", "0.9.1", true},
		{"garbage", "0.1.0", false}, // unparsable versions pass
		{"0.1.0", "", false},
	}
	for _, c := range cases {
		if got := versionBelow(c.v, c.min); got != c.below {
			t.Errorf("versionBelow(%q, %q) = %v", c.v, c.min, got)
		}
	}
}

func TestWriteProblemHidesUnknownErrors(t *testing.T) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/x", nil)
	WriteProblem(w, r, errors.New("sqlite: database password=hunter2"))
	if w.Code != 500 || w.Header().Get("Content-Type") != "application/problem+json" {
		t.Fatalf("status %d type %q", w.Code, w.Header().Get("Content-Type"))
	}
	if strings.Contains(w.Body.String(), "hunter2") {
		t.Fatalf("500 leaks: %s", w.Body)
	}
	var p map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
		t.Fatal(err)
	}
	if p["code"] != "internal" || p["type"] != "urn:pictunnel:problem:internal" || p["request_id"] == "" || p["request_id"] == nil {
		t.Fatalf("problem: %v", p)
	}
}

func TestWriteProblemExtrasAndHeaders(t *testing.T) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/x", nil)
	r = r.WithContext(withRequestID(r.Context(), "rid-1"))
	WriteProblem(w, r, apperr.RateLimited(1500*time.Millisecond))
	if w.Code != 429 || w.Header().Get("Retry-After") != "2" {
		t.Fatalf("429: %d %v", w.Code, w.Header())
	}

	w = httptest.NewRecorder()
	WriteProblem(w, r, apperr.ClientTooOld("0.1.0"))
	var p map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
		t.Fatal(err)
	}
	if w.Code != 426 || p["min_version"] != "0.1.0" || p["request_id"] != "rid-1" || p["status"] != float64(426) ||
		p["title"] == "" || p["detail"] == "" {
		t.Fatalf("426 problem: %v", p)
	}

	// Extra fields never override the standard members.
	e := apperr.NotFound()
	e.Extra = map[string]any{"code": "evil", "request_id": "evil", "hint": 1}
	w = httptest.NewRecorder()
	WriteProblem(w, r, e)
	p = nil
	_ = json.Unmarshal(w.Body.Bytes(), &p)
	if p["code"] != "not_found" || p["request_id"] != "rid-1" || p["hint"] != float64(1) {
		t.Fatalf("extras: %v", p)
	}
}
