package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strings"
	"time"

	"rsc.io/qr"
)

const pairUsage = `usage: pictunnel pair [flags]

Creates a one-time pairing code (valid 10 minutes) on the running server and
prints it with its QR code for the phone app to scan. It talks to the
server's loopback listener, so run it on the server machine (or with
docker compose exec inside the server container).

  --user NAME       account to pair the phone to (default admin)
  --password PW     its password (default $PICTUNNEL_PASSWORD)
  --create          create NAME as the first admin if the server has no
                    account yet; without --password a password is generated
                    and printed once
  --url URL         the loopback listener (default $PICTUNNEL_LOCAL_URL or
                    http://127.0.0.1:8080)
  --uri-only        print only the pictunnel://pair link (for scripts)
  --png PATH        also write the QR code to PATH as a PNG image
`

// pairOptions are the parsed pair flags.
type pairOptions struct {
	user, password, url, png string
	create, uriOnly          bool
}

// pairCmd creates a pairing code through the loopback API: optional
// first-run setup, a cookie login, then POST /api/v1/pairing/codes.
func pairCmd(ctx context.Context, args, env []string, stdout, stderr io.Writer) int {
	envMap := map[string]string{}
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok {
			envMap[k] = v
		}
	}
	o := pairOptions{}
	fs := flag.NewFlagSet("pair", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.user, "user", "admin", "")
	fs.StringVar(&o.password, "password", envMap["PICTUNNEL_PASSWORD"], "")
	fs.StringVar(&o.url, "url", firstNonEmpty(envMap["PICTUNNEL_LOCAL_URL"], "http://127.0.0.1:8080"), "")
	fs.BoolVar(&o.create, "create", false, "")
	fs.BoolVar(&o.uriOnly, "uri-only", false, "")
	fs.StringVar(&o.png, "png", "", "")
	if err := fs.Parse(args); err != nil || fs.NArg() > 0 {
		_, _ = fmt.Fprint(stderr, pairUsage)
		return 2
	}
	// Notes go to stderr with --uri-only, so stdout is just the link.
	notes := stdout
	if o.uriOnly {
		notes = stderr
	}
	c, err := newLocalClient(o.url)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel pair: %v\n", err)
		return 2
	}

	if o.create {
		generated := false
		if o.password == "" {
			o.password = randomPassword()
			generated = true
		}
		created, err := c.setup(ctx, o.user, o.password)
		switch {
		case err != nil:
			_, _ = fmt.Fprintf(stderr, "pictunnel pair: create the admin: %v\n", err)
			return 1
		case created && generated:
			_, _ = fmt.Fprintf(notes, "Created the admin account %q with the password %s\nKeep it: it is not shown again (pictunnel reset-password %s sets a new one).\n\n", o.user, o.password, o.user)
		case created:
			_, _ = fmt.Fprintf(notes, "Created the admin account %q.\n\n", o.user)
		case generated:
			_, _ = fmt.Fprintf(stderr, "pictunnel pair: the server already has an account; pass --password (or PICTUNNEL_PASSWORD) for %q\n", o.user)
			return 1
		}
	}
	if o.password == "" {
		_, _ = fmt.Fprintf(stderr, "pictunnel pair: pass --password (or set PICTUNNEL_PASSWORD) for %q, or --create on a new server\n", o.user)
		return 2
	}
	if err := c.login(ctx, o.user, o.password); err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel pair: log in as %q: %v\n", o.user, err)
		return 1
	}
	pc, err := c.pairingCode(ctx)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "pictunnel pair: create a pairing code: %v\n", err)
		return 1
	}
	if o.png != "" {
		q, err := qr.Encode(pc.QRURI, qr.L)
		if err == nil {
			err = os.WriteFile(o.png, q.PNG(), 0o644)
		}
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "pictunnel pair: write the QR image: %v\n", err)
			return 1
		}
	}
	if o.uriOnly {
		_, _ = fmt.Fprintln(stdout, pc.QRURI)
		return 0
	}
	printPairing(stdout, pc)
	return 0
}

func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

func randomPassword() string {
	b := make([]byte, 15)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

type pairingCode struct {
	Code      string    `json:"code"`
	QRURI     string    `json:"qr_uri"`
	ExpiresAt time.Time `json:"expires_at"`
}

// printPairing shows the code, the QR code (light modules as full blocks, so
// it reads dark-on-light in a dark terminal), the endpoints and the
// certificate pin for manual setup.
func printPairing(w io.Writer, pc pairingCode) {
	var eps []string
	var fp string
	if u, err := url.Parse(pc.QRURI); err == nil {
		q := u.Query()
		eps, fp = q["u"], q.Get("fp")
	}
	_, _ = fmt.Fprintf(w, "Scan this in the PicTunnel app (Pair with a QR code):\n\n")
	if q, err := qr.Encode(pc.QRURI, qr.L); err == nil {
		_, _ = io.WriteString(w, renderQR(q))
	}
	_, _ = fmt.Fprintf(w, "\nPairing code:  %s (single use, expires %s)\n", pc.Code, pc.ExpiresAt.Local().Format("15:04:05 MST"))
	if fp != "" {
		_, _ = fmt.Fprintf(w, "Security code: %s (first 16 characters of the certificate pin %s)\n", short(fp, 16), fp)
	}
	if len(eps) > 0 {
		_, _ = fmt.Fprintf(w, "Server URLs:   %s\n", strings.Join(eps, ", "))
	}
	_, _ = fmt.Fprintf(w, "Pairing link:  %s\n", pc.QRURI)
}

func short(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// renderQR draws the code two rows per line with half blocks and a 4-module
// quiet zone. Light modules are drawn, dark ones are left as background.
func renderQR(c *qr.Code) string {
	const quiet = 4
	light := func(x, y int) bool {
		if x < 0 || y < 0 || x >= c.Size || y >= c.Size {
			return true
		}
		return !c.Black(x, y)
	}
	var b strings.Builder
	for y := -quiet; y < c.Size+quiet; y += 2 {
		for x := -quiet; x < c.Size+quiet; x++ {
			top, bottom := light(x, y), light(x, y+1)
			switch {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

// localClient calls the loopback listener with a cookie session.
type localClient struct {
	base string
	http *http.Client
	csrf string
}

func newLocalClient(base string) (*localClient, error) {
	u, err := url.Parse(base)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, fmt.Errorf("--url %q is not an http(s) URL", base)
	}
	jar, _ := cookiejar.New(nil)
	return &localClient{base: strings.TrimRight(base, "/"), http: &http.Client{Jar: jar, Timeout: 30 * time.Second}}, nil
}

// problemError is a server problem response.
type problemError struct {
	Status int
	Code   string
	Detail string
}

func (e *problemError) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("server answered %d %s: %s", e.Status, e.Code, e.Detail)
	}
	return fmt.Sprintf("server answered %d %s", e.Status, e.Code)
}

func (c *localClient) post(ctx context.Context, path string, body any, want int, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+path, rd)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.csrf != "" {
		req.Header.Set("X-CSRF-Token", c.csrf)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("is the server running? %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != want {
		p := &problemError{Status: resp.StatusCode}
		var pj struct{ Code, Detail string }
		if json.Unmarshal(raw, &pj) == nil {
			p.Code, p.Detail = pj.Code, pj.Detail
		}
		return p
	}
	if out != nil {
		return json.Unmarshal(raw, out)
	}
	return nil
}

// setup creates the first admin; false (no error) when the server already has one.
func (c *localClient) setup(ctx context.Context, user, password string) (bool, error) {
	err := c.post(ctx, "/api/v1/auth/setup", map[string]string{"username": user, "password": password}, http.StatusCreated, nil)
	var p *problemError
	if errors.As(err, &p) && p.Status == http.StatusConflict && p.Code == "setup_already_done" {
		return false, nil
	}
	return err == nil, err
}

func (c *localClient) login(ctx context.Context, user, password string) error {
	var r struct {
		CSRF string `json:"csrf_token"`
	}
	err := c.post(ctx, "/api/v1/auth/login", map[string]string{"username": user, "password": password, "mode": "cookie"}, http.StatusOK, &r)
	if err != nil {
		return err
	}
	if r.CSRF == "" {
		return errors.New("the login response has no csrf_token")
	}
	c.csrf = r.CSRF
	return nil
}

func (c *localClient) pairingCode(ctx context.Context) (pairingCode, error) {
	var pc pairingCode
	err := c.post(ctx, "/api/v1/pairing/codes", nil, http.StatusCreated, &pc)
	if err == nil && (pc.Code == "" || pc.QRURI == "") {
		err = errors.New("the response has no code or qr_uri")
	}
	return pc, err
}
