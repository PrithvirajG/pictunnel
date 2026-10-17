package service

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
)

// UploadMeta is the parsed tus Upload-Metadata (P§7.3). Its JSON form is
// upload_sessions.meta_json, read back by FinalizeService (sessionMeta): the
// keys are the protocol key names, times are RFC 3339 and override_tombstone
// is a JSON bool.
type UploadMeta struct {
	SHA256            string     `json:"sha256"`
	Filename          string     `json:"filename"`
	Mime              string     `json:"mime"`
	LocalID           string     `json:"local_id,omitempty"`
	StackKey          string     `json:"stack_key,omitempty"`
	PairRole          string     `json:"pair_role,omitempty"` // "primary" (default) or "live_video"
	PairSHA256        string     `json:"pair_sha256,omitempty"`
	CreatedAt         *time.Time `json:"created_at,omitempty"`
	ModifiedAt        *time.Time `json:"modified_at,omitempty"`
	OverrideTombstone bool       `json:"override_tombstone,omitempty"`
}

// Pair roles.
const pairRolePrimary = "primary"

var (
	metaKeyRe = regexp.MustCompile(`^[a-z0-9_]+$`)
	sha256Re  = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

func badMeta(detail string) error { return apperr.InvalidRequest("Upload-Metadata: " + detail) }

// ParseUploadMetadata parses an Upload-Metadata header strictly (S§6.1):
// comma-separated "key value" pairs, keys [a-z0-9_]+, values standard padded
// base64 (a bare key is an empty value), no duplicate keys. Unknown keys are
// ignored. sha256, filename and mime are required; pair_sha256 is required
// iff pair_role is live_video. Every failure is invalid_request.
func ParseUploadMetadata(header string) (UploadMeta, error) {
	kv := map[string]string{}
	if strings.TrimSpace(header) != "" {
		for _, pair := range strings.Split(header, ",") {
			fields := strings.Split(strings.Trim(pair, " "), " ")
			if len(fields) > 2 {
				return UploadMeta{}, badMeta("malformed pair")
			}
			key := fields[0]
			if !metaKeyRe.MatchString(key) {
				return UploadMeta{}, badMeta("invalid key")
			}
			if _, dup := kv[key]; dup {
				return UploadMeta{}, badMeta("duplicate key " + key)
			}
			val := ""
			if len(fields) == 2 {
				b, err := base64.StdEncoding.Strict().DecodeString(fields[1])
				if err != nil {
					return UploadMeta{}, badMeta("value of " + key + " is not standard base64")
				}
				val = string(b)
			}
			kv[key] = val
		}
	}
	m := UploadMeta{
		SHA256: kv["sha256"], Filename: kv["filename"], Mime: kv["mime"], LocalID: kv["local_id"],
		StackKey: kv["stack_key"], PairRole: kv["pair_role"], PairSHA256: kv["pair_sha256"],
	}
	for _, k := range []string{"created_at", "modified_at"} {
		v := kv[k]
		if v == "" {
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			return UploadMeta{}, badMeta(k + " is not RFC 3339")
		}
		if k == "created_at" {
			m.CreatedAt = &t
		} else {
			m.ModifiedAt = &t
		}
	}
	switch kv["override_tombstone"] {
	case "", "0":
	case "1":
		m.OverrideTombstone = true
	default:
		return UploadMeta{}, badMeta("override_tombstone must be 1 or 0")
	}
	if m.PairRole == "" {
		m.PairRole = pairRolePrimary
	}
	return m, m.validate()
}

// validate checks the fields of a parsed (or caller-built) UploadMeta.
// metaMaxLen bounds client strings that are stored in meta_json and rows.
var metaMaxLen = map[string]int{"filename": 1024, "mime": 255, "local_id": 1024, "stack_key": 1024}

func (m UploadMeta) validate() error {
	if !sha256Re.MatchString(m.SHA256) {
		return badMeta("sha256 is required as 64 lowercase hex digits")
	}
	for k, v := range map[string]string{"filename": m.Filename, "mime": m.Mime} {
		if v == "" {
			return badMeta(k + " is required")
		}
	}
	for k, v := range map[string]string{"filename": m.Filename, "mime": m.Mime, "local_id": m.LocalID, "stack_key": m.StackKey} {
		if !utf8.ValidString(v) || strings.ContainsRune(v, 0) {
			return badMeta(k + " must be UTF-8 without NUL")
		}
		if max := metaMaxLen[k]; len(v) > max {
			return badMeta(fmt.Sprintf("%s is longer than %d bytes", k, max))
		}
	}
	switch m.PairRole {
	case pairRolePrimary, "":
		if m.PairSHA256 != "" {
			return badMeta("pair_sha256 is only allowed with pair_role live_video")
		}
	case pairRoleLiveVideo:
		if !sha256Re.MatchString(m.PairSHA256) {
			return badMeta("pair_sha256 is required for live_video as 64 lowercase hex digits")
		}
	default:
		return badMeta("pair_role must be primary or live_video")
	}
	return nil
}

func (m UploadMeta) live() bool { return m.PairRole == pairRoleLiveVideo }
