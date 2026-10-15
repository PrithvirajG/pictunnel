package conformance

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// ScenarioCase is one server-scenario vector case (P§10.4).
type ScenarioCase struct {
	File        string           `json:"-"`
	Name        string           `json:"name"`
	Description string           `json:"description,omitempty"`
	Actors      map[string]Actor `json:"actors"`
	Steps       []Step           `json:"steps"`
}

// Actor is a device paired to a user.
type Actor struct {
	User     string `json:"user"`
	Platform string `json:"platform,omitempty"`
}

// Step is an HTTP step (Actor + Request + Expect) or a control step.
type Step struct {
	Actor     string            `json:"actor,omitempty"`
	Request   *Request          `json:"request,omitempty"`
	Transport *Transport        `json:"transport,omitempty"`
	Expect    *Expect           `json:"expect,omitempty"`
	Save      map[string]string `json:"save,omitempty"`
	Control   *Control          `json:"control,omitempty"`
}

// Request is the HTTP request of a step.
type Request struct {
	Method      string            `json:"method"`
	Path        string            `json:"path"`
	Headers     map[string]string `json:"headers,omitempty"`
	JSON        json.RawMessage   `json:"json,omitempty"`
	TusMetadata *OrderedStrings   `json:"tus_metadata,omitempty"`
	Body        *struct {
		Generate GenerateSpec `json:"generate"`
	} `json:"body,omitempty"`
}

// GenerateSpec is a generate body whose start/end may be ${var} references.
type GenerateSpec struct {
	Pattern string          `json:"pattern"`
	Seed    int             `json:"seed"`
	Length  int64           `json:"length"`
	Start   json.RawMessage `json:"start,omitempty"`
	End     json.RawMessage `json:"end,omitempty"`
}

// Transport alters how the request is sent.
type Transport struct {
	DropAfterBytes int64 `json:"drop_after_bytes"`
}

// Expect is the expected response.
type Expect struct {
	Status     int               `json:"status,omitempty"`
	NoResponse bool              `json:"no_response,omitempty"`
	Headers    map[string]string `json:"headers,omitempty"`
	Body       json.RawMessage   `json:"body,omitempty"`
}

// Control is a control step; exactly one field is set.
type Control struct {
	AdvanceClockSeconds int64  `json:"advance_clock_seconds,omitempty"`
	RunJob              string `json:"run_job,omitempty"`
	AssertLibraryPaths  *struct {
		User  string   `json:"user"`
		Paths []string `json:"paths"`
	} `json:"assert_library_paths,omitempty"`
	AssertAssetSources *struct {
		Asset   string `json:"asset"`
		Sources []struct {
			Actor   string `json:"actor"`
			LocalID string `json:"local_id"`
		} `json:"sources"`
	} `json:"assert_asset_sources,omitempty"`
}

// OrderedStrings is a JSON object of strings that keeps key order
// (tus_metadata is encoded in the listed order).
type OrderedStrings struct {
	Keys   []string
	Values map[string]string
}

// UnmarshalJSON keeps the object's key order.
func (o *OrderedStrings) UnmarshalJSON(b []byte) error {
	dec := json.NewDecoder(strings.NewReader(string(b)))
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		return fmt.Errorf("tus_metadata: want an object")
	}
	o.Values = map[string]string{}
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			return err
		}
		k := kt.(string)
		var v string
		if err := dec.Decode(&v); err != nil {
			return fmt.Errorf("tus_metadata %s: %w", k, err)
		}
		o.Keys = append(o.Keys, k)
		o.Values[k] = v
	}
	_, err = dec.Token()
	return err
}

// LoadScenarioCases reads every vectors/server-scenarios/*.json file in
// name order.
func LoadScenarioCases(protocolDir string) ([]ScenarioCase, error) {
	files, err := filepath.Glob(filepath.Join(protocolDir, "vectors", "server-scenarios", "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	var all []ScenarioCase
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		var vf vectorFile[ScenarioCase]
		if err := json.Unmarshal(raw, &vf); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		if vf.Kind != "server-scenario" {
			return nil, fmt.Errorf("%s: kind %q, want server-scenario", f, vf.Kind)
		}
		for _, c := range vf.Cases {
			c.File = filepath.Base(f)
			all = append(all, c)
		}
	}
	return all, nil
}

var varRef = regexp.MustCompile(`\$\{([a-z0-9_]+)\}`)

// Vars are the values saved by earlier steps.
type Vars map[string]string

// Subst replaces every ${name} in s; an unknown name is an error.
func (v Vars) Subst(s string) (string, error) {
	var missing []string
	out := varRef.ReplaceAllStringFunc(s, func(m string) string {
		name := m[2 : len(m)-1]
		val, ok := v[name]
		if !ok {
			missing = append(missing, name)
		}
		return val
	})
	if len(missing) > 0 {
		return "", fmt.Errorf("unknown variable(s) %v in %q", missing, s)
	}
	return out, nil
}

// SubstJSON substitutes ${name} in every JSON string value of raw.
func (v Vars) SubstJSON(raw json.RawMessage) (json.RawMessage, error) {
	var x any
	if err := json.Unmarshal(raw, &x); err != nil {
		return nil, err
	}
	var walk func(any) (any, error)
	walk = func(n any) (any, error) {
		switch t := n.(type) {
		case string:
			return v.Subst(t)
		case []any:
			for i := range t {
				r, err := walk(t[i])
				if err != nil {
					return nil, err
				}
				t[i] = r
			}
		case map[string]any:
			for k := range t {
				r, err := walk(t[k])
				if err != nil {
					return nil, err
				}
				t[k] = r
			}
		}
		return n, nil
	}
	x, err := walk(x)
	if err != nil {
		return nil, err
	}
	return json.Marshal(x)
}

// Offset resolves a generate start/end: absent → def, an integer, or a
// ${name} reference to a saved decimal value.
func (v Vars) Offset(raw json.RawMessage, def int64) (int64, error) {
	if len(raw) == 0 {
		return def, nil
	}
	var n int64
	if err := json.Unmarshal(raw, &n); err == nil {
		return n, nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return 0, fmt.Errorf("bad offset %s", raw)
	}
	s, err := v.Subst(s)
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(s, 10, 64)
}

// TusMetadata encodes the Upload-Metadata header: "key base64(value)"
// pairs, comma-separated, in the listed order.
func TusMetadata(m *OrderedStrings, v Vars) (string, error) {
	parts := make([]string, 0, len(m.Keys))
	for _, k := range m.Keys {
		val, err := v.Subst(m.Values[k])
		if err != nil {
			return "", err
		}
		parts = append(parts, k+" "+base64.StdEncoding.EncodeToString([]byte(val)))
	}
	return strings.Join(parts, ","), nil
}
