// Package apperr defines the domain error type mapped to RFC 9457 problem bodies.
package apperr

import (
	"errors"
	"net/http"
	"strconv"
	"time"
)

// Error is a domain error carrying its problem code and HTTP mapping.
type Error struct {
	Code    string
	Status  int
	Title   string
	Detail  string
	Extra   map[string]any
	Headers http.Header
}

func (e *Error) Error() string {
	if e.Detail != "" {
		return e.Code + ": " + e.Detail
	}
	return e.Code + ": " + e.Title
}

// As extracts an *Error from err's chain.
func As(err error) (*Error, bool) {
	var e *Error
	if errors.As(err, &e) {
		return e, true
	}
	return nil, false
}

func newErr(code, title, detail string) *Error {
	return &Error{Code: code, Status: Catalogue[code], Title: title, Detail: detail}
}

func (e *Error) header(k, v string) *Error {
	if e.Headers == nil {
		e.Headers = http.Header{}
	}
	e.Headers.Set(k, v)
	return e
}

func (e *Error) extra(k string, v any) *Error {
	if e.Extra == nil {
		e.Extra = map[string]any{}
	}
	e.Extra[k] = v
	return e
}

// retryAfterSeconds rounds d up to whole seconds, minimum 1.
func retryAfterSeconds(d time.Duration) string {
	s := int64((d + time.Second - 1) / time.Second)
	if s < 1 {
		s = 1
	}
	return strconv.FormatInt(s, 10)
}
