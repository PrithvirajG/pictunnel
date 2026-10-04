// Package conformance loads the shared protocol vectors in api/protocol/vectors.
package conformance

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Generate describes a deterministic stream: byte i is (i + Seed) mod 256 for i in [0, Length).
type Generate struct {
	Pattern string `json:"pattern"`
	Seed    int    `json:"seed"`
	Length  int64  `json:"length"`
}

// HashingInput has exactly one source.
type HashingInput struct {
	File       string    `json:"file,omitempty"`
	InlineUTF8 *string   `json:"inline_utf8,omitempty"`
	Generate   *Generate `json:"generate,omitempty"`
}

type HashingCase struct {
	Name           string       `json:"name"`
	Description    string       `json:"description,omitempty"`
	Input          HashingInput `json:"input"`
	ExpectedSHA256 string       `json:"expected_sha256"`
}

type vectorFile[C any] struct {
	SchemaVersion int    `json:"schema_version"`
	Kind          string `json:"kind"`
	Cases         []C    `json:"cases"`
}

// ProtocolDir is api/protocol relative to this package's directory, which is the working directory of go test.
func ProtocolDir() string { return filepath.Join("..", "..", "..", "api", "protocol") }

// LoadHashingCases reads every vectors/hashing/*.json file in name order.
func LoadHashingCases(protocolDir string) ([]HashingCase, error) {
	files, err := filepath.Glob(filepath.Join(protocolDir, "vectors", "hashing", "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	var all []HashingCase
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		var vf vectorFile[HashingCase]
		if err := json.Unmarshal(raw, &vf); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		if vf.Kind != "hashing" {
			return nil, fmt.Errorf("%s: kind %q, want hashing", f, vf.Kind)
		}
		all = append(all, vf.Cases...)
	}
	return all, nil
}

// Open returns the bytes described by the input.
func (in HashingInput) Open(protocolDir string) (io.ReadCloser, error) {
	switch {
	case in.File != "":
		return os.Open(filepath.Join(protocolDir, filepath.FromSlash(in.File)))
	case in.InlineUTF8 != nil:
		return io.NopCloser(strings.NewReader(*in.InlineUTF8)), nil
	case in.Generate != nil:
		return io.NopCloser(CounterReader(*in.Generate, 0, in.Generate.Length)), nil
	default:
		return nil, fmt.Errorf("hashing input has no source")
	}
}
