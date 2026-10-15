package app_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"image/jpeg"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
	"github.com/PrithvirajG/pictunnel/server/internal/media"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "media", "testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func needFFmpeg(t *testing.T, a *app.App) {
	t.Helper()
	if tl := media.FindTools(a.Config()); tl.FFmpeg == "" || tl.FFprobe == "" {
		t.Skip("ffmpeg/ffprobe not found")
	}
}

// mediaEnv is a booted app behind an httptest server with alice logged in.
type mediaEnv struct {
	a     *app.App
	srv   *httptest.Server
	token string
	p     service.Principal
}

func newMediaEnv(t *testing.T) *mediaEnv {
	t.Helper()
	a := boot(t, opts(t))
	needFFmpeg(t, a)
	ctx := context.Background()
	if _, err := a.Users().Create(ctx, "alice", pw, "", service.RoleUser); err != nil {
		t.Fatal(err)
	}
	_, _, tp, err := a.Auth().Login(ctx, "alice", pw, service.DeviceInfo{Name: "Pixel", Platform: "android", AppVersion: "0.1.0"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := a.Auth().AuthenticateBearer(ctx, tp.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(a.Handler())
	t.Cleanup(srv.Close)
	return &mediaEnv{a: a, srv: srv, token: tp.AccessToken, p: p}
}

func (e *mediaEnv) seed(t *testing.T, content []byte, filename, mime string) string {
	t.Helper()
	v, err := upload(t, e.a, e.p, content, filename, mime)
	if err != nil || !v.Done || v.AssetID == "" {
		t.Fatalf("seed %s: %+v %v", filename, v, err)
	}
	return v.AssetID
}

func (e *mediaEnv) get(t *testing.T, path string) (*http.Response, []byte) {
	t.Helper()
	req, err := http.NewRequest("GET", e.srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+e.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	resp.Body = io.NopCloser(bytes.NewReader(body))
	httpapitest.AssertContract(t, req, resp)
	return resp, body
}

func (e *mediaEnv) run(t *testing.T, kind string) {
	t.Helper()
	if err := e.a.Jobs().RunNow(context.Background(), kind); err != nil {
		t.Fatalf("run %s: %v", kind, err)
	}
}

func wantCode(t *testing.T, resp *http.Response, body []byte, status int, code string) {
	t.Helper()
	var p struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(body, &p)
	if resp.StatusCode != status || p.Code != code {
		t.Fatalf("got %d %s, want %d %s", resp.StatusCode, body, status, code)
	}
}

func TestPlaybackRules(t *testing.T) {
	e := newMediaEnv(t)
	mp4Bytes := fixture(t, "clip_h264.mp4")
	mp4 := e.seed(t, mp4Bytes, "clip.mp4", "video/mp4")
	mov := e.seed(t, fixture(t, "clip_hevc.mov"), "clip.mov", "video/quicktime")
	photo := e.seed(t, fixture(t, "plain.png"), "plain.png", "image/png")

	resp, body := e.get(t, "/api/v1/assets/"+mp4+"/playback")
	wantCode(t, resp, body, 404, "not_ready") // playability unknown until extract_metadata

	e.run(t, service.JobExtractMetadata)
	resp, body = e.get(t, "/api/v1/assets/"+mp4+"/playback")
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "video/mp4" || !bytes.Equal(body, mp4Bytes) {
		t.Fatalf("mp4 playback: %d %q (%d bytes)", resp.StatusCode, resp.Header.Get("Content-Type"), len(body))
	}
	resp, body = e.get(t, "/api/v1/assets/"+mov+"/playback")
	wantCode(t, resp, body, 404, "not_ready") // HEVC needs the transcode

	e.run(t, service.JobTranscodeVideo)
	resp, body = e.get(t, "/api/v1/assets/"+mov+"/playback")
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "video/mp4" {
		t.Fatalf("mov playback after transcode: %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	web := filepath.Join(e.a.Config().DataDir, "derived", mov[0:2], mov[2:4], mov, "web.mp4")
	if b, err := os.ReadFile(web); err != nil || !bytes.Equal(b, body) {
		t.Fatalf("mov playback is not web.mp4 (%v)", err)
	}

	resp, body = e.get(t, "/api/v1/assets/"+photo+"/playback")
	wantCode(t, resp, body, 404, "not_found")
}

func TestThumbnailEndpointAfterJob(t *testing.T) {
	e := newMediaEnv(t)
	png := fixture(t, "plain.png")
	id := e.seed(t, png, "plain.png", "image/png")
	sum := sha256.Sum256(png)
	sha := hex.EncodeToString(sum[:])

	resp, body := e.get(t, "/api/v1/assets/"+id+"/thumbnail")
	wantCode(t, resp, body, 404, "not_ready")

	e.run(t, service.JobGenerateThumbnails)
	for _, c := range []struct{ query, size string }{{"", "thumb"}, {"?size=thumb", "thumb"}, {"?size=preview", "preview"}} {
		resp, body = e.get(t, "/api/v1/assets/"+id+"/thumbnail"+c.query)
		if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "image/jpeg" {
			t.Fatalf("thumbnail%s: %d %q", c.query, resp.StatusCode, resp.Header.Get("Content-Type"))
		}
		if got, want := resp.Header.Get("ETag"), `"`+sha+"-"+c.size+`"`; got != want {
			t.Errorf("thumbnail%s ETag %s, want %s", c.query, got, want)
		}
		if got := resp.Header.Get("Cache-Control"); got != "private, max-age=31536000, immutable" {
			t.Errorf("thumbnail%s Cache-Control %q", c.query, got)
		}
		if _, err := jpeg.Decode(bytes.NewReader(body)); err != nil {
			t.Errorf("thumbnail%s is not a JPEG: %v", c.query, err)
		}
	}
}
