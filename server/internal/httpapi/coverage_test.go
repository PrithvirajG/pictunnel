package httpapi_test

// Contract coverage (S§11.3). Every HTTP-level test in this package goes
// through httpapitest.AssertContract, which records the (operationId,
// status) pairs it sees. After the whole suite has run, TestMain checks two
// things:
//
//  1. Every documented (operation, status) pair that the server can produce
//     was hit by at least one test. Pairs the server never produces are
//     listed in notProduced with the reason.
//  2. No test saw a status the contract does not document for the
//     operation (contract drift), except the entries of
//     undocumentedByDesign and undocumentedPending.
//
// The check runs only for a full, passing run of the package (no -run or
// -skip filter, no -short), so focused runs are not reported as gaps.

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

type opStatus struct {
	op     string // operation id as the embedded spec reports it
	status int
}

func (o opStatus) String() string { return fmt.Sprintf("%s %d", o.op, o.status) }

// notProduced are documented pairs no 2A/2B code path produces.
var notProduced = map[opStatus]string{
	// 429: S§4.4 rate-limits login, redeem and setup only.
	{"AppendUpload", 429}:      "not rate-limited (S§4.4 limits login, redeem and setup only)",
	{"CheckContent", 429}:      "not rate-limited (S§4.4 limits login, redeem and setup only)",
	{"CreatePairingCode", 429}: "not rate-limited (S§4.4 limits login, redeem and setup only)",
	{"CreateUpload", 429}:      "not rate-limited (S§4.4 limits login, redeem and setup only)",
	{"GetServerInfo", 429}:     "not rate-limited (S§4.4 limits login, redeem and setup only)",
	{"RefreshTokens", 429}:     "not rate-limited (S§4.4 limits login, redeem and setup only)",
	// 503: only readyz reports server_unavailable (while draining or when
	// the database does not answer); the rest is reserved for a proxy.
	{"AppendUpload", 503}:  "server_unavailable is produced by readyz only",
	{"CheckContent", 503}:  "server_unavailable is produced by readyz only",
	{"CreateUpload", 503}:  "server_unavailable is produced by readyz only",
	{"GetHealthz", 503}:    "healthz is liveness: it answers 200 while the process serves",
	{"GetServerInfo", 503}: "server_unavailable is produced by readyz only",
	// 507: free space is checked when a session is created (P§7.3 #6),
	// not per PATCH.
	{"AppendUpload", 507}: "free space is checked at create only (P§7.3 #6)",
	// 413: the size limit and the quota are checked at create (P§7.3 #1,
	// #5); a PATCH body past Upload-Length is 400. Documented for clients.
	{"AppendUpload", 413}: "max size and quota are checked at create only (P§7.3 #1, #5)",
}

// raceOnly are documented pairs the server produces only in a race this
// suite cannot stage deterministically through HTTP (outcome #4 joining a
// fully received session, P§7.3); the service tests cover the lock and
// expiry paths below the HTTP layer.
var raceOnly = map[opStatus]string{
	{"CreateUpload", 423}: "outcome #4 on a fully received session while its finalize holds the lock",
	{"CreateUpload", 404}: "outcome #4 on a fully received session that expires or loses its staging file before finalize",
}

// undocumentedByDesign are statuses the contract deliberately does not list
// per operation; status 0 means any operation.
var undocumentedByDesign = map[opStatus]string{
	{"", 500}:                  "internal errors are not enumerated per operation (problem code internal, P§10.1)",
	{"GetAssetOriginal", 304}:  "conditional GET with If-None-Match on the documented ETag (RFC 9110)",
	{"GetAssetThumbnail", 304}: "conditional GET with If-None-Match on the documented ETag (RFC 9110)",
}

// undocumentedPending are statuses the server produces that the contract
// does not document yet. Task 19 documented every earlier entry; a new one
// must be documented in api/openapi.yaml and then removed from this list.
var undocumentedPending = map[opStatus]string{}

// documentedStatuses reads every (operation, status) pair of the embedded
// spec, and each operation's HTTP method.
func documentedStatuses(tb testing.TB) (map[opStatus]bool, map[string]string) {
	tb.Helper()
	doc, err := gen.GetSpec()
	if err != nil {
		tb.Fatal(err)
	}
	pairs := map[opStatus]bool{}
	methods := map[string]string{}
	for _, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			methods[op.OperationID] = method
			for code := range op.Responses.Map() {
				n, err := strconv.Atoi(code)
				if err != nil {
					tb.Fatalf("%s: non-numeric response %q", op.OperationID, code)
				}
				pairs[opStatus{op.OperationID, n}] = true
			}
		}
	}
	return pairs, methods
}

// coverageProblems compares what the suite saw with the contract.
func coverageProblems(tb testing.TB, seen map[string][]int) []string {
	documented, _ := documentedStatuses(tb)
	hit := map[opStatus]bool{}
	for op, sts := range seen {
		for _, s := range sts {
			hit[opStatus{op, s}] = true
		}
	}
	var out []string
	for p := range documented {
		if !hit[p] && notProduced[p] == "" && raceOnly[p] == "" {
			out = append(out, "documented but never hit: "+p.String())
		}
	}
	for p := range hit {
		if documented[p] || undocumentedPending[p] != "" || undocumentedByDesign[p] != "" ||
			undocumentedByDesign[opStatus{"", p.status}] != "" {
			continue
		}
		out = append(out, "observed but not documented: "+p.String())
	}
	sort.Strings(out)
	return out
}

func fullRun() bool {
	for _, name := range []string{"test.run", "test.skip"} {
		if f := flag.Lookup(name); f != nil && f.Value.String() != "" {
			return false
		}
	}
	return !testing.Short()
}

func TestMain(m *testing.M) {
	code := m.Run()
	if code == 0 && fullRun() {
		if probs := coverageProblems(&mainTB{}, httpapitest.Coverage()); len(probs) > 0 {
			fmt.Fprintf(os.Stderr, "contract coverage (S§11.3) failed:\n  %s\n", strings.Join(probs, "\n  "))
			code = 1
		}
	}
	os.Exit(code)
}

// mainTB lets TestMain use the testing.TB helpers.
type mainTB struct{ testing.TB }

func (*mainTB) Helper() {}
func (*mainTB) Fatal(args ...any) {
	fmt.Fprintln(os.Stderr, args...)
	os.Exit(1)
}
func (*mainTB) Fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

// TestContractCoverage keeps the exception lists honest: a notProduced
// pair must be documented, an undocumented pair must really be missing
// from the contract (so documenting it forces its removal here), and every
// reason is stated. The hit check itself runs in TestMain.
func TestContractCoverage(t *testing.T) {
	documented, methods := documentedStatuses(t)
	if len(methods) != 30 {
		t.Errorf("spec has %d operations, S§11.3 expects 30", len(methods))
	}
	for p, why := range notProduced {
		if !documented[p] || why == "" {
			t.Errorf("notProduced %s: documented %v, reason %q", p, documented[p], why)
		}
	}
	for p, why := range raceOnly {
		if !documented[p] || why == "" {
			t.Errorf("raceOnly %s: documented %v, reason %q", p, documented[p], why)
		}
	}
	for _, list := range []map[opStatus]string{undocumentedPending, undocumentedByDesign} {
		for p, why := range list {
			if p.op != "" && methods[p.op] == "" {
				t.Errorf("%s: unknown operation", p)
			}
			if documented[p] || why == "" {
				t.Errorf("%s is documented now (or has no reason %q): drop it from the exception list", p, why)
			}
		}
	}
	// The self-check of the comparison: an unknown status is reported, a
	// pending one is not.
	probs := coverageProblems(t, map[string][]int{"GetAsset": {599}, "TerminateUpload": {423}})
	if !strings.Contains(strings.Join(probs, "\n"), "observed but not documented: GetAsset 599") ||
		strings.Contains(strings.Join(probs, "\n"), "TerminateUpload 423") {
		t.Errorf("coverageProblems: %v", probs)
	}
	if methods["GetUploadOffset"] != http.MethodHead {
		t.Errorf("GetUploadOffset method %q", methods["GetUploadOffset"])
	}
}
