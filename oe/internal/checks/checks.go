// Package checks derives CHECKS_SET from a repository's own workflow files and runs its runnable
// entries. Derivation walks an ordered YAML node tree, so job order, step order, duplicate
// entries, and multi-line run blocks survive exactly, and nothing is ever inferred from
// package.json or Makefile script names. A set carries the revision it was derived from, and a
// moved revision invalidates it.
package checks

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// GitReader reads git output. *gh.Client satisfies it.
type GitReader interface {
	Git(ctx context.Context, args ...string) ([]byte, error)
}

// workflowsDir is the only directory derivation reads, relative to the repository root.
const workflowsDir = ".github/workflows"

// nullTag marks a YAML null value, such as an event with no configuration.
const nullTag = "!!null"

// mapPair is the number of nodes in one mapping entry: key then value.
const mapPair = 2

// The shells a runnable entry can carry.
const (
	shellBash = "bash"
	shellSh   = "sh"
)

// The two kinds of captured step.
const (
	kindRun    = "run"
	kindAction = "action"
)

// DefaultBranchPush values: whether any kept workflow runs on a push to the default branch.
const (
	pushRuns     = "runs"          // at least one kept workflow runs on an unfiltered default-branch push
	pushFiltered = "path_filtered" // every default-branch push workflow is path-filtered
	pushNone     = "none"          // no kept workflow triggers on a default-branch push
)

// Set is CHECKS_SET: the ordered entries a revision would run, plus the revision it came from.
type Set struct {
	Ref               string  `json:"ref"`
	Base              string  `json:"base"`
	Revision          string  `json:"revision"`
	DefaultBranchPush string  `json:"default_branch_push"`
	Entries           []Entry `json:"entries"`
}

// Entry is one captured workflow step. A run entry carries Command; an action entry carries
// Action and no command. Runnable is false for every requires-runner entry, which is reported
// but never executed.
type Entry struct {
	File                 string            `json:"file"`
	Job                  string            `json:"job"`
	Step                 string            `json:"step"`
	StepIndex            int               `json:"step_index"`
	Kind                 string            `json:"kind"`
	Command              string            `json:"command"`
	Action               string            `json:"action"`
	WorkingDirectory     string            `json:"working_directory"`
	Env                  map[string]string `json:"env"`
	Shell                string            `json:"shell"`
	Runnable             bool              `json:"runnable"`
	RequiresRunnerReason string            `json:"requires_runner_reason"`
}

// LoadSet reads a CHECKS_SET file written by `oe checks derive`.
func LoadSet(path string) (Set, error) {
	data, err := os.ReadFile(path) //nolint:gosec // The set path is an explicit operator argument.
	if err != nil {
		return Set{}, exitcode.Wrap(exitcode.Usage, err, "read CHECKS_SET file")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var set Set
	if err := dec.Decode(&set); err != nil {
		return Set{}, exitcode.Wrap(exitcode.Usage, err, "parse CHECKS_SET file")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return Set{}, exitcode.New(exitcode.Usage, "parse CHECKS_SET file: trailing data")
	}
	if set.Ref == "" || set.Revision == "" {
		return Set{}, exitcode.New(exitcode.Usage, "CHECKS_SET file has no ref or revision")
	}
	for i := range set.Entries {
		if set.Entries[i].Env == nil {
			set.Entries[i].Env = map[string]string{}
		}
	}
	return set, nil
}
