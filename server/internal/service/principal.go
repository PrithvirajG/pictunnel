// Package service holds the domain services. Each service takes a deps
// struct naming exactly the repositories it uses, plus Store and Clock, and
// returns *apperr.Error for domain failures.
package service

import (
	"strings"
	"time"
	"unicode/utf8"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
)

// Principal is the authenticated caller resolved from a bearer token or a
// session cookie.
type Principal struct {
	UserID, Username, Slug, Role, DeviceID, Platform string
	Via                                              string // "bearer" | "cookie"
	SessionHash                                      string // web session token hash (cookie only)
}

// Principal.Via values.
const (
	ViaBearer = "bearer"
	ViaCookie = "cookie"
)

// TokenPair is an access/refresh pair with their expiries.
type TokenPair struct {
	AccessToken      string
	AccessExpiresAt  time.Time
	RefreshToken     string
	RefreshExpiresAt time.Time
}

// DeviceInfo is the client's device registration (DeviceRegistration in the
// OpenAPI contract).
type DeviceInfo struct{ Name, Platform, AppVersion string }

// User roles (OpenAPI User.role known values).
const (
	RoleAdmin = "admin"
	RoleUser  = "user"
)

var devicePlatforms = map[string]bool{"android": true, "ios": true, "web": true, "other": true}

const maxDeviceName = 100

// cleanDeviceName trims and validates a device name (1..100 characters).
func cleanDeviceName(name string) (string, error) {
	n := strings.TrimSpace(name)
	if n == "" || utf8.RuneCountInString(n) > maxDeviceName {
		return "", apperr.InvalidRequest("device name must be 1 to 100 characters")
	}
	return n, nil
}

// validate checks the registration and returns it with a trimmed name.
func (d DeviceInfo) validate() (DeviceInfo, error) {
	n, err := cleanDeviceName(d.Name)
	if err != nil {
		return DeviceInfo{}, err
	}
	if !devicePlatforms[d.Platform] {
		return DeviceInfo{}, apperr.InvalidRequest("platform must be one of android, ios, web, other")
	}
	d.Name = n
	d.AppVersion = strings.TrimSpace(d.AppVersion)
	return d, nil
}
