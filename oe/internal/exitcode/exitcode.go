// Package exitcode defines the exit codes of contract §9 and the one-line verdict every
// failing oe subcommand prints.
package exitcode

import (
	"errors"
	"strings"
)

// Code is an oe process exit code.
type Code int

// The exit codes of docs/design/orchestrate-epic-v2/contract.md §9.
const (
	OK           Code = 0 // Done or proceed.
	Unreadable   Code = 1 // Failed, partial, or rate-limited read. Writes none.
	Usage        Code = 2 // Usage error. Writes none.
	Stale        Code = 3 // Head or base moved since the verdict. Writes none.
	Stop         Code = 4 // Frozen, health failed, unknown merge outcome.
	Wait         Code = 5 // Checks or health pending. Writes none.
	Protocol     Code = 6 // v1 marker, unknown version, bad JSON, key mismatch, duplicate state.
	Coordination Code = 7 // Lock held, foreign or lost lease, moved revision.
	Refused      Code = 8 // No approval, scan finding, failed precondition, old gh, unsupported host.
)

// Word is the verdict prefix for a code.
func (c Code) Word() string {
	words := [...]string{
		OK: "ok", Unreadable: "unreadable", Usage: "usage", Stale: "stale", Stop: "stop",
		Wait: "wait", Protocol: "protocol", Coordination: "coordination", Refused: "refused",
	}
	if c < 0 || int(c) >= len(words) {
		return "unknown"
	}
	return words[c]
}

// Error is an error that carries the exit code it maps to.
type Error struct {
	Code Code
	Msg  string
	Err  error
}

// New returns an Error with a message and no cause.
func New(code Code, msg string) *Error {
	return &Error{Code: code, Msg: msg, Err: nil}
}

// Wrap returns an Error with a message and an underlying cause.
func Wrap(code Code, err error, msg string) *Error {
	return &Error{Code: code, Msg: msg, Err: err}
}

func (e *Error) Error() string {
	if e.Err == nil {
		return e.Msg
	}
	return e.Msg + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }

// CodeOf maps an error to its exit code. An error without a code fails closed as Unreadable,
// which writes nothing.
func CodeOf(err error) Code {
	if err == nil {
		return OK
	}
	if e, ok := errors.AsType[*Error](err); ok {
		return e.Code
	}
	return Unreadable
}

// Verdict renders an error as the single line `<word>: <message>`.
func Verdict(err error) string {
	msg := strings.Join(strings.Fields(err.Error()), " ")
	return CodeOf(err).Word() + ": " + msg
}
