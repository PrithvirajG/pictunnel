// Package discovery advertises the server on the LAN over mDNS/DNS-SD
// (S§5.3): <name>._pictunnel._tcp.local. with TXT sid, v, api and fp16.
//
// It uses github.com/brutella/dnssd (MIT; deps miekg/dns BSD-3-Clause,
// vishvananda/netlink and netns Apache-2.0), which is pure Go and builds
// with CGO_ENABLED=0 for linux, darwin and windows. Failing to bind the
// multicast port is a warning, never fatal.
package discovery

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/brutella/dnssd"
	dnssdlog "github.com/brutella/dnssd/log"
)

// ServiceType is the DNS-SD service type.
const ServiceType = "_pictunnel._tcp"

// recheckInterval is how often interface changes are checked; a change
// re-announces the service.
const recheckInterval = 60 * time.Second

// Responder advertises the service until stopped.
type Responder interface {
	// Start begins advertising. It never fails because of the network: a
	// bind failure is logged as a warning and Start returns nil.
	Start(ctx context.Context) error
	// Stop sends goodbye packets and stops. It is idempotent.
	Stop()
}

// TXT builds the TXT record: sid=<server_id>, v=<version>, api=1 and
// fp16=<first 16 chars of the SPKI fingerprint>.
func TXT(serverID, version, fingerprint string) map[string]string {
	fp16 := fingerprint
	if len(fp16) > 16 {
		fp16 = fp16[:16]
	}
	return map[string]string{"sid": serverID, "v": version, "api": "1", "fp16": fp16}
}

// newResponder binds the mDNS sockets; tests replace it.
var newResponder = dnssd.NewResponder

var quietOnce sync.Once

// quietLibrary routes dnssd's own logging (stdout by default) away.
func quietLibrary() {
	quietOnce.Do(func() {
		dnssdlog.Info.Disable()
		dnssdlog.Debug.Disable()
	})
}

type responder struct {
	name string
	port int
	txt  map[string]string
	log  *slog.Logger

	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
}

// New returns a Responder for <name>._pictunnel._tcp.local. on port.
func New(name string, port int, txt map[string]string, log *slog.Logger) Responder {
	if log == nil {
		log = slog.Default()
	}
	if strings.TrimSpace(name) == "" {
		name, _ = os.Hostname()
	}
	if name == "" {
		name = "PicTunnel"
	}
	t := make(map[string]string, len(txt))
	for k, v := range txt {
		t[k] = v
	}
	return &responder{name: name, port: port, txt: t, log: log.With("component", "mdns")}
}

func (r *responder) Start(ctx context.Context) error {
	quietLibrary()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cancel != nil {
		return nil
	}
	r.log.Info("mDNS: advertising", "name", r.name, "type", ServiceType, "port", r.port, "hint", envHint())
	rsp, err := r.bind()
	if err != nil {
		r.log.Warn("mDNS: cannot bind the multicast port; LAN discovery is off (pair by QR code or URL)", "err", err)
		return nil
	}
	ctx, cancel := context.WithCancel(ctx)
	r.cancel, r.done = cancel, make(chan struct{})
	go r.loop(ctx, rsp)
	return nil
}

func (r *responder) Stop() {
	r.mu.Lock()
	cancel, done := r.cancel, r.done
	r.cancel, r.done = nil, nil
	r.mu.Unlock()
	if cancel == nil {
		return
	}
	cancel()
	<-done
}

// bind opens the sockets and registers the service.
func (r *responder) bind() (dnssd.Responder, error) {
	svc, err := dnssd.NewService(dnssd.Config{Name: r.name, Type: ServiceType, Port: r.port, Text: r.txt})
	if err != nil {
		return nil, err
	}
	rsp, err := newResponder()
	if err != nil {
		return nil, err
	}
	if _, err := rsp.Add(svc); err != nil {
		return nil, err
	}
	return rsp, nil
}

// loop runs the responder and restarts it (goodbye, then a fresh probe and
// announcement) whenever the interface addresses change.
func (r *responder) loop(ctx context.Context, rsp dnssd.Responder) {
	defer close(r.done)
	sig := interfaceSignature()
	tick := time.NewTicker(recheckInterval)
	defer tick.Stop()
	for {
		var runDone chan struct{}
		runCancel := func() {}
		if rsp != nil {
			var runCtx context.Context
			runCtx, runCancel = context.WithCancel(ctx)
			runDone = make(chan struct{})
			go func(rsp dnssd.Responder) {
				defer close(runDone)
				if err := rsp.Respond(runCtx); err != nil && runCtx.Err() == nil {
					r.log.Warn("mDNS: responder stopped", "err", err)
				}
			}(rsp)
		}
		changed := false
		for !changed {
			select {
			case <-ctx.Done():
				runCancel()
				if runDone != nil {
					<-runDone
				}
				return
			case <-tick.C:
				if s := interfaceSignature(); s != sig || rsp == nil {
					sig, changed = s, true
				}
			}
		}
		runCancel()
		if runDone != nil {
			<-runDone
		}
		var err error
		if rsp, err = r.bind(); err != nil {
			r.log.Warn("mDNS: cannot rebind after an interface change", "err", err)
			rsp = nil
		} else {
			r.log.Info("mDNS: interfaces changed; re-announcing")
		}
	}
}

// interfaceSignature summarises the up, multicast-capable interfaces and
// their addresses.
func interfaceSignature() string {
	ifs, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var parts []string
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagMulticast == 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			parts = append(parts, ifc.Name+"="+a.String())
		}
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
}

// envHint is the one-time hint for environments where mDNS needs help
// (S§5.3 table).
func envHint() string {
	if _, err := os.Stat("/.dockerenv"); err == nil {
		return "Docker: mDNS does not cross bridge networking; use --network host on Linux or pair by QR code / URL"
	}
	switch runtime.GOOS {
	case "windows":
		return "Windows: allow inbound UDP 5353 in the firewall for LAN discovery"
	case "darwin":
		return "macOS: shares port 5353 with mDNSResponder"
	default:
		return fmt.Sprintf("%s: needs inbound UDP 5353 for LAN discovery", runtime.GOOS)
	}
}
