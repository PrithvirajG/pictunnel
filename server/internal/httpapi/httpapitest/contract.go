package httpapitest

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/legacy"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
)

var (
	specOnce   sync.Once
	spec       *openapi3.T
	specRouter routers.Router
	specErr    error

	covMu    sync.Mutex
	coverage = map[string]map[int]bool{}
)

func init() {
	// Binary media bodies of the asset endpoints.
	openapi3filter.RegisterBodyDecoder("image/jpeg", openapi3filter.FileBodyDecoder)
	openapi3filter.RegisterBodyDecoder("video/mp4", openapi3filter.FileBodyDecoder)
	// kin-openapi does not check format: uuid by default; server ids are
	// canonical lowercase UUIDs.
	openapi3.DefineStringFormatValidator("uuid", openapi3.NewRegexpFormatValidator(
		`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`))
}

func loadSpec() (*openapi3.T, routers.Router, error) {
	specOnce.Do(func() {
		spec, specErr = gen.GetSwagger()
		if specErr != nil {
			return
		}
		// Match on paths only; the test server is plain http on a random port.
		spec.Servers = nil
		specRouter, specErr = legacy.NewRouter(spec)
	})
	return spec, specRouter, specErr
}

// Coverage returns the (operationId → statuses) pairs seen by AssertContract
// so far (S§11.3 contract coverage). Operation ids are as the embedded spec
// reports them. Responses of a WithTus stub are not recorded.
func Coverage() map[string][]int {
	covMu.Lock()
	defer covMu.Unlock()
	out := make(map[string][]int, len(coverage))
	for op, sts := range coverage {
		for s := range sts {
			out[op] = append(out[op], s)
		}
		sort.Ints(out[op])
	}
	return out
}

func record(op string, status int) {
	covMu.Lock()
	defer covMu.Unlock()
	if coverage[op] == nil {
		coverage[op] = map[int]bool{}
	}
	coverage[op][status] = true
}

// AssertContract validates resp (whose body must be re-readable) against the
// embedded OpenAPI document with openapi3filter.ValidateResponse, records
// the (operationId, status) pair, and checks every problem body: valid
// against the Problem schema, type = urn:pictunnel:problem:<code>, status
// equal to the HTTP status, and a request_id.
func AssertContract(t testing.TB, req *http.Request, resp *http.Response) {
	t.Helper()
	doc, router, err := loadSpec()
	if err != nil {
		t.Fatalf("load spec: %v", err)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))

	// A HEAD response carries the headers of the problem but never its body.
	ct, _, _ := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if ct == "application/problem+json" && req.Method != http.MethodHead {
		assertProblem(t, doc, resp.StatusCode, body)
	}

	route, params, err := router.FindRoute(req)
	if err != nil {
		// Not an API operation (unknown path or method): only the problem
		// body check above applies.
		return
	}
	if resp.Header.Get(StubHeader) == "" {
		record(route.Operation.OperationID, resp.StatusCode)
	}
	if resp.StatusCode == http.StatusNotModified {
		return // conditional GET; no body, not part of the documented responses
	}
	in := &openapi3filter.ResponseValidationInput{
		RequestValidationInput: &openapi3filter.RequestValidationInput{
			Request: req, PathParams: params, Route: route,
			Options: &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc},
		},
		Status:  resp.StatusCode,
		Header:  resp.Header,
		Body:    io.NopCloser(bytes.NewReader(body)),
		Options: &openapi3filter.Options{MultiError: true},
	}
	if err := openapi3filter.ValidateResponse(context.Background(), in); err != nil {
		t.Errorf("contract violation for %s %s → %d: %v\nbody: %s",
			req.Method, req.URL.Path, resp.StatusCode, err, truncate(body))
	}
}

func assertProblem(t testing.TB, doc *openapi3.T, status int, body []byte) {
	t.Helper()
	var v any
	if err := json.Unmarshal(body, &v); err != nil {
		t.Errorf("problem body is not JSON: %v: %s", err, truncate(body))
		return
	}
	if err := doc.Components.Schemas["Problem"].Value.VisitJSON(v); err != nil {
		t.Errorf("problem body violates schema: %v: %s", err, body)
	}
	var p struct {
		Type      string `json:"type"`
		Code      string `json:"code"`
		Status    int    `json:"status"`
		RequestID string `json:"request_id"`
	}
	_ = json.Unmarshal(body, &p)
	if p.Type != "urn:pictunnel:problem:"+p.Code {
		t.Errorf("problem type %q does not match code %q", p.Type, p.Code)
	}
	if p.Status != status {
		t.Errorf("problem status %d, HTTP status %d", p.Status, status)
	}
	if p.RequestID == "" {
		t.Errorf("problem without request_id: %s", body)
	}
}

func truncate(b []byte) string {
	if len(b) > 512 {
		return string(b[:512]) + "…(" + strconv.Itoa(len(b)) + " bytes)"
	}
	return string(b)
}
