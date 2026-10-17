package conformance

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	uuidRe   = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	intRe    = regexp.MustCompile(`^-?[0-9]+$`)
	sha256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)
	wholeVar = regexp.MustCompile(`^\$\{([a-z0-9_]+)\}$`)
)

// MatchString applies a string matcher (P§10.4) to a present value:
// $any, $uuid, $int, $sha256, $datetime, ${name} (equals the saved value);
// any other expectation (after ${name} substitution) must be equal.
func MatchString(want, got string, v Vars) error {
	ok := false
	switch want {
	case "$any":
		ok = true
	case "$uuid":
		ok = uuidRe.MatchString(got)
	case "$int":
		ok = intRe.MatchString(got)
	case "$sha256":
		ok = sha256Re.MatchString(got)
	case "$datetime":
		_, err := time.Parse(time.RFC3339Nano, got)
		ok = err == nil
	default:
		if m := wholeVar.FindStringSubmatch(want); m != nil {
			saved, has := v[m[1]]
			if !has {
				return fmt.Errorf("matcher %s: variable not saved", want)
			}
			ok = got == saved
			want = fmt.Sprintf("%s (=%q)", want, saved)
		} else {
			w, err := v.Subst(want)
			if err != nil {
				return err
			}
			ok = got == w
		}
	}
	if !ok {
		return fmt.Errorf("got %q, want %s", got, want)
	}
	return nil
}

// MatchJSON matches got against the expectation want (both decoded JSON):
// objects match as subsets, arrays as ordered subsequences, {"$len": n}
// matches an array of exactly n items, strings use MatchString ($int also
// accepts a JSON integer), and other values must be equal.
func MatchJSON(want, got any, v Vars) error {
	return matchAt("", want, got, v)
}

func matchAt(path string, want, got any, v Vars) error {
	at := func(err error) error {
		if err == nil || path == "" {
			return err
		}
		return fmt.Errorf("%s: %w", path, err)
	}
	switch w := want.(type) {
	case map[string]any:
		if n, ok := lenMatcher(w); ok {
			arr, isArr := got.([]any)
			if !isArr || len(arr) != n {
				return at(fmt.Errorf("want an array of exactly %d items, got %s", n, short(got)))
			}
			return nil
		}
		g, ok := got.(map[string]any)
		if !ok {
			return at(fmt.Errorf("want an object, got %s", short(got)))
		}
		for k, wv := range w {
			gv, has := g[k]
			if !has {
				return at(fmt.Errorf("missing key %q in %s", k, short(got)))
			}
			if err := matchAt(path+"/"+k, wv, gv, v); err != nil {
				return err
			}
		}
		return nil
	case []any:
		g, ok := got.([]any)
		if !ok {
			return at(fmt.Errorf("want an array, got %s", short(got)))
		}
		// Ordered subsequence: greedy earliest match is optimal because
		// each element matches independently.
		j := 0
		for i, wv := range w {
			found := false
			for ; j < len(g); j++ {
				if matchAt(path+"/"+strconv.Itoa(i), wv, g[j], v) == nil {
					found, j = true, j+1
					break
				}
			}
			if !found {
				return at(fmt.Errorf("element %d %s not found in order in %s", i, short(wv), short(got)))
			}
		}
		return nil
	case string:
		switch g := got.(type) {
		case string:
			return at(MatchString(w, g, v))
		case float64:
			if w == "$int" && g == float64(int64(g)) {
				return nil
			}
			if w == "$any" {
				return nil
			}
			// Saved values are decimal strings (P§10.4), so ${name}
			// matches a JSON number with the same decimal form.
			if m := wholeVar.FindStringSubmatch(w); m != nil {
				if saved, ok := v[m[1]]; ok && saved == strconv.FormatFloat(g, 'f', -1, 64) {
					return nil
				}
			}
			return at(fmt.Errorf("want %s, got number %v", w, g))
		default:
			if w == "$any" && got != nil {
				return nil
			}
			return at(fmt.Errorf("want string %s, got %s", w, short(got)))
		}
	case float64:
		if g, ok := got.(float64); !ok || g != w {
			return at(fmt.Errorf("got %s, want %v", short(got), w))
		}
		return nil
	default: // bool, nil
		if want != got {
			return at(fmt.Errorf("got %s, want %v", short(got), want))
		}
		return nil
	}
}

func lenMatcher(m map[string]any) (int, bool) {
	if len(m) != 1 {
		return 0, false
	}
	n, ok := m["$len"].(float64)
	return int(n), ok
}

func short(x any) string {
	b, _ := json.Marshal(x)
	if len(b) > 300 {
		return string(b[:300]) + "…"
	}
	return string(b)
}

// NormalizeLocation reduces a Location header to its path (P§10.4).
func NormalizeLocation(loc string) string {
	if u, err := url.Parse(loc); err == nil && u.Path != "" {
		p := u.Path
		if u.RawQuery != "" {
			p += "?" + u.RawQuery
		}
		return p
	}
	return loc
}

// JSONPointer resolves an RFC 6901 pointer in decoded JSON; numbers come
// back as decimal strings.
func JSONPointer(doc any, ptr string) (string, error) {
	if !strings.HasPrefix(ptr, "/") {
		return "", fmt.Errorf("bad JSON pointer %q", ptr)
	}
	cur := doc
	for _, tok := range strings.Split(ptr[1:], "/") {
		tok = strings.ReplaceAll(strings.ReplaceAll(tok, "~1", "/"), "~0", "~")
		switch c := cur.(type) {
		case map[string]any:
			v, ok := c[tok]
			if !ok {
				return "", fmt.Errorf("pointer %s: no key %q", ptr, tok)
			}
			cur = v
		case []any:
			i, err := strconv.Atoi(tok)
			if err != nil || i < 0 || i >= len(c) {
				return "", fmt.Errorf("pointer %s: bad index %q", ptr, tok)
			}
			cur = c[i]
		default:
			return "", fmt.Errorf("pointer %s: cannot descend into %s", ptr, short(cur))
		}
	}
	switch c := cur.(type) {
	case string:
		return c, nil
	case float64:
		return strconv.FormatFloat(c, 'f', -1, 64), nil
	case json.Number:
		return c.String(), nil
	default:
		return short(c), nil
	}
}
