package httpapi_test

import (
	"regexp"
	"strings"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

const unknownUUID = "01928f40-0000-7000-8000-0000000000ff"

func TestPairingCreateAndRedeem(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, s.Access, "POST", "/api/v1/pairing/codes", nil)
	wantStatus(t, resp, body, 201)
	var pc gen.PairingCode
	httpapitest.Decode(t, body, &pc)
	if !regexp.MustCompile(`^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{2}$`).MatchString(pc.Code) ||
		!strings.HasPrefix(pc.QrUri, "pictunnel://pair?v=1&sid="+httpapitest.ServerID) {
		t.Fatalf("pairing code: %+v", pc)
	}

	req := map[string]any{"code": pc.Code,
		"device": map[string]any{"device_name": "Alice's iPhone", "platform": "ios", "app_version": "0.1.0"}}
	resp, body = call(t, a, "", "POST", "/api/v1/pairing/redeem", req)
	wantStatus(t, resp, body, 201)
	var rr gen.RedeemResponse
	httpapitest.Decode(t, body, &rr)
	if rr.ServerId.String() != httpapitest.ServerID || rr.User.Username != adminUser ||
		rr.Device.Name != "Alice's iPhone" || !strings.HasPrefix(rr.Tokens.AccessToken, "pt_at_") {
		t.Fatalf("redeem: %+v", rr)
	}
	resp, body = call(t, a, rr.Tokens.AccessToken, "GET", "/api/v1/devices", nil)
	wantStatus(t, resp, body, 200)
}

func TestRedeemInvalidCode(t *testing.T) {
	a := httpapitest.New(t)
	req := map[string]any{"code": "K7Q2-M9XD-4T",
		"device": map[string]any{"device_name": "x", "platform": "ios", "app_version": "0.1.0"}}
	resp, body := call(t, a, "", "POST", "/api/v1/pairing/redeem", req)
	wantProblem(t, resp, body, 400, "pairing_code_invalid")
}

func TestListDevices(t *testing.T) {
	a, s := withAdmin(t)
	a.Login(t, adminUser, adminPass)
	resp, body := call(t, a, s.Access, "GET", "/api/v1/devices", nil)
	wantStatus(t, resp, body, 200)
	var dl gen.DeviceList
	httpapitest.Decode(t, body, &dl)
	if len(dl.Devices) != 2 {
		t.Fatalf("devices: %s", body)
	}
}

func TestUpdateDevice(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, s.Access, "PATCH", "/api/v1/devices/"+s.DeviceID, map[string]any{"name": "Alice's Pixel"})
	wantStatus(t, resp, body, 200)
	var d gen.Device
	httpapitest.Decode(t, body, &d)
	if d.Id.String() != s.DeviceID || d.Name != "Alice's Pixel" {
		t.Fatalf("device: %+v", d)
	}
	resp, body = call(t, a, s.Access, "PATCH", "/api/v1/devices/"+unknownUUID, map[string]any{"name": "x"})
	wantProblem(t, resp, body, 404, "not_found")
	resp, body = call(t, a, s.Access, "PATCH", "/api/v1/devices/not-a-uuid", map[string]any{"name": "x"})
	wantProblem(t, resp, body, 404, "not_found")
	resp, body = call(t, a, s.Access, "PATCH", "/api/v1/devices/"+s.DeviceID, `{"name":`)
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, s.Access, "PATCH", "/api/v1/devices/"+s.DeviceID, map[string]any{"name": ""})
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestRevokeDevice(t *testing.T) {
	a, s := withAdmin(t)
	other := a.Login(t, adminUser, adminPass)
	resp, body := call(t, a, s.Access, "DELETE", "/api/v1/devices/"+other.DeviceID, nil)
	wantStatus(t, resp, body, 204)
	resp, body = call(t, a, s.Access, "DELETE", "/api/v1/devices/"+other.DeviceID, nil)
	wantStatus(t, resp, body, 204) // idempotent
	resp, body = call(t, a, other.Access, "GET", "/api/v1/devices", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
	resp, body = call(t, a, s.Access, "DELETE", "/api/v1/devices/"+unknownUUID, nil)
	wantProblem(t, resp, body, 404, "not_found")
}
