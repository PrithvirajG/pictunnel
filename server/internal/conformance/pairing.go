package conformance

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

// PairURI is a parsed pairing QR payload (sync-protocol §6.3).
type PairURI struct {
	ServerID    string
	Code        string
	Fingerprint string
	Endpoints   []string // deduplicated, first-occurrence order
}

// PairError is a parse failure; Code is one of the P§10.3 error names.
type PairError struct{ Code string }

func (e *PairError) Error() string { return "pairing uri: " + e.Code }

var pairCodeRe = regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$`)

// ParsePairURI applies the P§10.3 parsing rules, checking errors in the
// listed order: invalid_scheme, unsupported_version, missing_server_id,
// invalid_code, missing_fingerprint, missing_endpoint, insecure_endpoint.
func ParsePairURI(raw string) (PairURI, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "pictunnel" || u.Host != "pair" || (u.Path != "" && u.Path != "/") || u.Opaque != "" {
		return PairURI{}, &PairError{"invalid_scheme"}
	}
	q := u.Query()
	if v := q["v"]; len(v) != 1 || v[0] != "1" {
		return PairURI{}, &PairError{"unsupported_version"}
	}
	sid := q.Get("sid")
	if sid == "" {
		return PairURI{}, &PairError{"missing_server_id"}
	}
	code := q.Get("code")
	if !pairCodeRe.MatchString(code) {
		return PairURI{}, &PairError{"invalid_code"}
	}
	fp := q.Get("fp")
	if fp == "" {
		return PairURI{}, &PairError{"missing_fingerprint"}
	}
	us := q["u"]
	if len(us) == 0 {
		return PairURI{}, &PairError{"missing_endpoint"}
	}
	seen := make(map[string]bool, len(us))
	var eps []string
	for _, e := range us {
		pu, err := url.Parse(e)
		if err != nil || pu.Scheme != "https" || pu.Host == "" {
			return PairURI{}, &PairError{"insecure_endpoint"}
		}
		if !seen[e] {
			seen[e] = true
			eps = append(eps, e)
		}
	}
	return PairURI{ServerID: sid, Code: code, Fingerprint: fp, Endpoints: eps}, nil
}

// AcceptConnection is the P§6.3 pinning rule: a system-trusted chain is
// accepted; otherwise the leaf's SPKI SHA-256 must equal fp.
func AcceptConnection(fp string, systemTrusted bool, spkiSHA256 string) bool {
	return systemTrusted || spkiSHA256 == fp
}

// PairingConnection is the optional TLS observation of a pairing case.
type PairingConnection struct {
	Endpoint      string `json:"endpoint"`
	SystemTrusted bool   `json:"system_trusted"`
	SPKISHA256    string `json:"spki_sha256"`
}

// PairingExpect is the expected outcome of a pairing case.
type PairingExpect struct {
	Parse            string   `json:"parse"` // ok | error
	Error            string   `json:"error,omitempty"`
	ServerID         string   `json:"server_id,omitempty"`
	Code             string   `json:"code,omitempty"`
	Fingerprint      string   `json:"fingerprint,omitempty"`
	Endpoints        []string `json:"endpoints,omitempty"`
	AcceptConnection *bool    `json:"accept_connection,omitempty"`
}

// PairingCase is one vectors/pairing case.
type PairingCase struct {
	Name        string             `json:"name"`
	Description string             `json:"description,omitempty"`
	URI         string             `json:"uri"`
	Connection  *PairingConnection `json:"connection,omitempty"`
	Expect      PairingExpect      `json:"expect"`
}

// LoadPairingCases reads every vectors/pairing/*.json file in name order.
func LoadPairingCases(protocolDir string) ([]PairingCase, error) {
	files, err := filepath.Glob(filepath.Join(protocolDir, "vectors", "pairing", "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	var all []PairingCase
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		var vf vectorFile[PairingCase]
		if err := json.Unmarshal(raw, &vf); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		if vf.Kind != "pairing" {
			return nil, fmt.Errorf("%s: kind %q, want pairing", f, vf.Kind)
		}
		all = append(all, vf.Cases...)
	}
	return all, nil
}
