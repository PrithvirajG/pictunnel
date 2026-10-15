package service

import (
	"encoding/base64"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
)

const metaSHA = "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83"

// encodeMeta builds an Upload-Metadata header from key/value pairs, in key
// order. A nil-like empty value is encoded as a bare key.
func encodeMeta(kv map[string]string) string {
	keys := make([]string, 0, len(kv))
	for k := range kv {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		if kv[k] == "" {
			parts = append(parts, k)
			continue
		}
		parts = append(parts, k+" "+base64.StdEncoding.EncodeToString([]byte(kv[k])))
	}
	return strings.Join(parts, ",")
}

// formatMeta is the inverse of ParseUploadMetadata for a valid UploadMeta.
func formatMeta(m UploadMeta) string {
	kv := map[string]string{"sha256": m.SHA256, "filename": m.Filename, "mime": m.Mime}
	set := func(k, v string) {
		if v != "" {
			kv[k] = v
		}
	}
	set("local_id", m.LocalID)
	set("stack_key", m.StackKey)
	set("pair_role", m.PairRole)
	set("pair_sha256", m.PairSHA256)
	if m.CreatedAt != nil {
		kv["created_at"] = m.CreatedAt.Format(time.RFC3339Nano)
	}
	if m.ModifiedAt != nil {
		kv["modified_at"] = m.ModifiedAt.Format(time.RFC3339Nano)
	}
	if m.OverrideTombstone {
		kv["override_tombstone"] = "1"
	}
	return encodeMeta(kv)
}

func metaEqual(a, b UploadMeta) bool {
	teq := func(x, y *time.Time) bool {
		if x == nil || y == nil {
			return x == y
		}
		_, xo := x.Zone()
		_, yo := y.Zone()
		return x.Equal(*y) && xo == yo
	}
	return a.SHA256 == b.SHA256 && a.Filename == b.Filename && a.Mime == b.Mime && a.LocalID == b.LocalID &&
		a.StackKey == b.StackKey && a.PairRole == b.PairRole && a.PairSHA256 == b.PairSHA256 &&
		a.OverrideTombstone == b.OverrideTombstone && teq(a.CreatedAt, b.CreatedAt) && teq(a.ModifiedAt, b.ModifiedAt)
}

func TestParseUploadMetadataFull(t *testing.T) {
	h := encodeMeta(map[string]string{
		"sha256": metaSHA, "filename": "IMG 🙂.JPG", "mime": "image/jpeg", "local_id": "a-1",
		"created_at": "2024-05-06T10:00:00+02:00", "modified_at": "2024-05-07T00:00:00Z",
		"stack_key": "S1", "override_tombstone": "1", "unknown_key": "ignored",
	})
	m, err := ParseUploadMetadata(h)
	if err != nil {
		t.Fatal(err)
	}
	if m.SHA256 != metaSHA || m.Filename != "IMG 🙂.JPG" || m.Mime != "image/jpeg" || m.LocalID != "a-1" ||
		m.StackKey != "S1" || !m.OverrideTombstone || m.PairRole != "primary" || m.PairSHA256 != "" {
		t.Fatalf("meta %+v", m)
	}
	if m.CreatedAt == nil || !m.CreatedAt.Equal(time.Date(2024, 5, 6, 8, 0, 0, 0, time.UTC)) {
		t.Fatalf("created_at %v", m.CreatedAt)
	}
	if _, off := m.CreatedAt.Zone(); off != 7200 {
		t.Fatalf("created_at offset %d", off)
	}
	if m.ModifiedAt == nil || !m.ModifiedAt.Equal(time.Date(2024, 5, 7, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("modified_at %v", m.ModifiedAt)
	}
}

func TestParseUploadMetadataLiveVideo(t *testing.T) {
	m, err := ParseUploadMetadata(encodeMeta(map[string]string{
		"sha256": strings.Repeat("a", 64), "filename": "IMG.MOV", "mime": "video/quicktime",
		"pair_role": "live_video", "pair_sha256": metaSHA,
	}))
	if err != nil || m.PairRole != "live_video" || m.PairSHA256 != metaSHA {
		t.Fatalf("%+v %v", m, err)
	}
}

func TestParseUploadMetadataSpacesAndBareKeys(t *testing.T) {
	h := "sha256 " + base64.StdEncoding.EncodeToString([]byte(metaSHA)) + ", filename " +
		base64.StdEncoding.EncodeToString([]byte("a.jpg")) + " , mime " +
		base64.StdEncoding.EncodeToString([]byte("image/jpeg")) + ",local_id,override_tombstone"
	m, err := ParseUploadMetadata(h)
	if err != nil || m.LocalID != "" || m.OverrideTombstone {
		t.Fatalf("%+v %v", m, err)
	}
}

func TestParseUploadMetadataRejects(t *testing.T) {
	base := map[string]string{"sha256": metaSHA, "filename": "a.jpg", "mime": "image/jpeg"}
	with := func(k, v string) string {
		kv := map[string]string{}
		for a, b := range base {
			kv[a] = b
		}
		if v == "<del>" {
			delete(kv, k)
		} else {
			kv[k] = v
		}
		return encodeMeta(kv)
	}
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	cases := map[string]string{
		"empty":             "",
		"missing sha256":    with("sha256", "<del>"),
		"missing filename":  with("filename", "<del>"),
		"missing mime":      with("mime", "<del>"),
		"uppercase sha":     with("sha256", strings.ToUpper(metaSHA)),
		"short sha":         with("sha256", metaSHA[:63]),
		"bad created_at":    with("created_at", "yesterday"),
		"bad modified_at":   with("modified_at", "2024-13-01T00:00:00Z"),
		"bad pair_role":     with("pair_role", "sidecar"),
		"live without pair": with("pair_role", "live_video"),
		"pair without live": with("pair_sha256", metaSHA),
		"bad override":      with("override_tombstone", "yes"),
		"bad key chars":     encodeMeta(base) + ",Bad-Key " + b64("x"),
		"empty key":         encodeMeta(base) + ", " + b64("x"),
		"duplicate key":     encodeMeta(base) + ",mime " + b64("image/png"),
		"url base64":        encodeMeta(base) + ",local_id " + "_-8=",
		"unpadded base64":   encodeMeta(base) + ",local_id " + strings.TrimRight(b64("ab"), "="),
		"three fields":      encodeMeta(base) + ",local_id " + b64("x") + " extra",
		"empty pair":        encodeMeta(base) + ",,",
		"invalid utf8 name": with("filename", "\xff\xfe"),
		"nul in filename":   with("filename", "a\x00b"),
		"invalid pair sha":  with("pair_role", "live_video") + ",pair_sha256 " + b64("zz"),
	}
	for name, h := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ParseUploadMetadata(h)
			ae, ok := apperr.As(err)
			if !ok || ae.Code != "invalid_request" {
				t.Fatalf("err %v", err)
			}
		})
	}
}

func TestParseUploadMetadataOverrideZero(t *testing.T) {
	m, err := ParseUploadMetadata(encodeMeta(map[string]string{
		"sha256": metaSHA, "filename": "a", "mime": "image/png", "override_tombstone": "0",
	}))
	if err != nil || m.OverrideTombstone {
		t.Fatalf("%+v %v", m, err)
	}
}

func FuzzParseMetadata(f *testing.F) {
	f.Add(encodeMeta(map[string]string{"sha256": metaSHA, "filename": "a.jpg", "mime": "image/jpeg"}))
	f.Add(encodeMeta(map[string]string{
		"sha256": metaSHA, "filename": "IMG 🙂.JPG", "mime": "image/jpeg", "local_id": "a-1",
		"created_at": "2024-05-06T10:00:00.123+02:00", "modified_at": "2024-05-07T00:00:00Z",
		"stack_key": "S1", "override_tombstone": "1",
	}))
	f.Add(encodeMeta(map[string]string{
		"sha256": metaSHA, "filename": "IMG.MOV", "mime": "video/quicktime",
		"pair_role": "live_video", "pair_sha256": metaSHA,
	}))
	f.Add("sha256,filename,mime")
	f.Add("a b,c d")
	f.Add(",,, ")
	f.Fuzz(func(t *testing.T, h string) {
		m, err := ParseUploadMetadata(h)
		if err != nil {
			if _, ok := apperr.As(err); !ok {
				t.Fatalf("non-domain error %v", err)
			}
			return
		}
		again, err := ParseUploadMetadata(formatMeta(m))
		if err != nil {
			t.Fatalf("round trip of %+v: %v", m, err)
		}
		if !metaEqual(m, again) {
			t.Fatalf("round trip %+v != %+v", m, again)
		}
	})
}
