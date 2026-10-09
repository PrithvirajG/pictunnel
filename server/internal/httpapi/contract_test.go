package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
)

// Compile-time proof that the strict server exposes every engine operation.
var _ = []any{
	gen.StrictServerInterface.GetServerInfo,
	gen.StrictServerInterface.RefreshTokens,
	gen.StrictServerInterface.CheckContent,
	gen.StrictServerInterface.OptionsUploads,
	gen.StrictServerInterface.CreateUpload,
	gen.StrictServerInterface.GetUploadOffset,
	gen.StrictServerInterface.AppendUpload,
	gen.StrictServerInterface.TerminateUpload,
	gen.StrictServerInterface.DeleteTombstone,
}

func TestCheckRequestRoundTripsSnakeCase(t *testing.T) {
	body := `{"items":[{"sha256":"fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83","size_bytes":1048576,"local_id":"a-1"}]}`
	var req gen.CheckRequest
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatal(err)
	}
	if len(req.Items) != 1 || req.Items[0].SizeBytes != 1048576 {
		t.Fatalf("unexpected decode: %+v", req)
	}
	out, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), `"size_bytes":1048576`) {
		t.Fatalf("marshal lost snake_case: %s", out)
	}
}

func TestEmbeddedSpecContainsSyncCheck(t *testing.T) {
	spec, err := gen.GetSpec()
	if err != nil {
		t.Fatal(err)
	}
	if spec.Paths.Find("/api/v1/sync/check") == nil {
		t.Fatal("embedded spec lacks /api/v1/sync/check")
	}
}
