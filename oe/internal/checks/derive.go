package checks

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"regexp"
	"strings"

	"go.yaml.in/yaml/v3"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// Derive reads every workflow file under .github/workflows at ref and returns CHECKS_SET: every
// entry CI would run for a pull request or for a push to base, in file, job, and step order,
// each classified as runnable or requires-runner. Unparseable YAML is an explicit error, never an
// empty set.
func Derive(ctx context.Context, git GitReader, base, ref string) (Set, error) {
	if base == "" {
		return Set{}, exitcode.New(exitcode.Usage, "no base branch given; pass --base")
	}
	if ref == "" {
		return Set{}, exitcode.New(exitcode.Usage, "no ref given; pass --ref")
	}
	revision, err := refRevision(ctx, git, ref)
	if err != nil {
		return Set{}, err
	}
	list, err := git.Git(ctx, "ls-tree", "-r", "--full-tree", "--name-only", ref, "--", ":(top)"+workflowsDir)
	if err != nil {
		return Set{}, err
	}
	set := Set{Ref: ref, Base: base, Revision: revision, DefaultBranchPush: PushNone, Entries: []Entry{}}
	push := PushNone
	for file := range strings.SplitSeq(string(list), "\n") {
		if !isWorkflowFile(file) {
			continue
		}
		body, err := git.Git(ctx, "show", ref+":"+file)
		if err != nil {
			return Set{}, exitcode.Wrap(exitcode.Unreadable, err, "read "+file+" at "+ref)
		}
		entries, info, err := parseWorkflow(file, body, base)
		if err != nil {
			return Set{}, err
		}
		if !info.keep {
			continue
		}
		set.Entries = append(set.Entries, entries...)
		push = strongerPush(push, info.push)
	}
	set.DefaultBranchPush = push
	return set, nil
}

// refRevision resolves ref to the commit SHA the set is bound to.
func refRevision(ctx context.Context, git GitReader, ref string) (string, error) {
	out, err := git.Git(ctx, "rev-parse", "--verify", ref+"^{commit}")
	if err != nil {
		return "", err
	}
	revision := strings.TrimSpace(string(out))
	if revision == "" {
		return "", exitcode.New(exitcode.Unreadable, "git rev-parse returned no commit for "+ref)
	}
	return revision, nil
}

func isWorkflowFile(path string) bool {
	return strings.HasSuffix(path, ".yml") || strings.HasSuffix(path, ".yaml")
}

// wfInfo is what a workflow contributes beyond its entries.
type wfInfo struct {
	keep bool
	push string
}

func strongerPush(a, b string) string {
	if a == PushRuns || b == PushRuns {
		return PushRuns
	}
	if a == PushFiltered || b == PushFiltered {
		return PushFiltered
	}
	return PushNone
}

// parseWorkflow walks one workflow's ordered YAML tree. It keeps the workflow only when a trigger
// is a pull request or a push to base, and reports whether such pushes are path-filtered.
func parseWorkflow(file string, body []byte, base string) ([]Entry, wfInfo, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(body, &doc); err != nil {
		return nil, wfInfo{}, exitcode.Wrap(exitcode.Unreadable, err, file+": unparseable YAML")
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) == 0 {
		return nil, wfInfo{keep: false, push: PushNone}, nil // An empty document triggers nothing.
	}
	root := doc.Content[0]
	if root.Kind != yaml.MappingNode {
		return nil, wfInfo{}, exitcode.New(exitcode.Unreadable, file+": YAML root is not a mapping")
	}
	on, _ := lookup(root, "on")
	keep, push, err := triggersKeep(on, base)
	if err != nil {
		return nil, wfInfo{}, exitcode.Wrap(exitcode.Unreadable, err, file)
	}
	if !keep {
		return nil, wfInfo{keep: false, push: PushNone}, nil
	}
	return keptWorkflow(file, root, push)
}

// keptWorkflow captures the entries of a workflow whose triggers keep it.
func keptWorkflow(file string, root *yaml.Node, push string) ([]Entry, wfInfo, error) {
	jobs, ok := lookup(root, "jobs")
	if ok && jobs.Kind == yaml.AliasNode {
		jobs = jobs.Alias
	}
	if !ok || jobs.Kind != yaml.MappingNode {
		return nil, wfInfo{keep: true, push: push}, nil
	}
	workflowDefaults, _ := lookup(root, "defaults")
	workflowRun, _ := lookup(workflowDefaults, "run")
	workflowEnv, err := envMap(lookupNode(root, "env"))
	if err != nil {
		return nil, wfInfo{}, exitcode.Wrap(exitcode.Unreadable, err, file)
	}
	entries, err := jobEntries(file, jobs, scalarValue(workflowRun, "working-directory"), scalarValue(workflowRun, "shell"), workflowEnv)
	if err != nil {
		return nil, wfInfo{}, exitcode.Wrap(exitcode.Unreadable, err, file)
	}
	return entries, wfInfo{keep: true, push: push}, nil
}

// lookup returns the value of key in a mapping node, in document order.
// deref follows YAML aliases to the anchored node.
func deref(node *yaml.Node) *yaml.Node {
	for node != nil && node.Kind == yaml.AliasNode {
		node = node.Alias
	}
	return node
}

func lookup(node *yaml.Node, key string) (*yaml.Node, bool) {
	node = deref(node)
	if node == nil || node.Kind != yaml.MappingNode {
		return nil, false
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			return node.Content[i+1], true
		}
	}
	return nil, false
}

func scalarValue(node *yaml.Node, key string) string {
	child, ok := lookup(node, key)
	child = deref(child)
	if !ok || child.Kind != yaml.ScalarNode {
		return ""
	}
	return child.Value
}

// trigger is one event under `on:`.
type trigger struct {
	name   string
	config *yaml.Node
}

func triggers(on *yaml.Node) ([]trigger, error) {
	on = deref(on)
	switch {
	case on == nil:
		return nil, nil
	case on.Kind == yaml.AliasNode:
		return triggers(on.Alias)
	case on.Tag == nullTag:
		return nil, nil
	case on.Kind == yaml.ScalarNode:
		return scalarTriggers(on)
	case on.Kind == yaml.SequenceNode:
		return sequenceTriggers(on)
	case on.Kind == yaml.MappingNode:
		return mappingTriggers(on)
	}
	return nil, errors.New("on is neither a scalar, a sequence, nor a mapping")
}

func scalarTriggers(on *yaml.Node) ([]trigger, error) {
	if on.Value == "" {
		return nil, nil
	}
	return []trigger{{name: on.Value, config: nil}}, nil
}

func sequenceTriggers(on *yaml.Node) ([]trigger, error) {
	out := make([]trigger, 0, len(on.Content))
	for _, item := range on.Content {
		switch item.Kind {
		case yaml.ScalarNode:
			out = append(out, trigger{name: item.Value, config: nil})
		case yaml.MappingNode:
			if len(item.Content) != mapPair {
				return nil, fmt.Errorf("on entry has %d keys; want one event", len(item.Content)/mapPair)
			}
			out = append(out, trigger{name: item.Content[0].Value, config: item.Content[1]})
		default:
			return nil, errors.New("on entry is neither an event name nor a mapping")
		}
	}
	return out, nil
}

func mappingTriggers(on *yaml.Node) ([]trigger, error) {
	out := make([]trigger, 0, len(on.Content)/mapPair)
	for i := 0; i+1 < len(on.Content); i += mapPair {
		out = append(out, trigger{name: on.Content[i].Value, config: on.Content[i+1]})
	}
	return out, nil
}

func triggersKeep(on *yaml.Node, base string) (bool, string, error) {
	trs, err := triggers(on)
	if err != nil {
		return false, PushNone, err
	}
	keep := false
	push := PushNone
	for _, t := range trs {
		switch t.name {
		case "pull_request":
			keep = true
		case "push":
			fires, filtered, err := pushFires(t.config, base)
			if err != nil {
				return false, PushNone, err
			}
			if fires {
				keep = true
				if filtered {
					push = strongerPush(push, PushFiltered)
				} else {
					push = strongerPush(push, PushRuns)
				}
			}
		}
	}
	return keep, push, nil
}

// pushFires reports whether a push trigger fires on base and whether a paths filter narrows it.
func pushFires(cfg *yaml.Node, base string) (bool, bool, error) {
	cfg = deref(cfg)
	if cfg == nil || cfg.Kind != yaml.MappingNode {
		return true, false, nil // An unrestricted push fires on every branch.
	}
	branches, hasBranches := lookup(cfg, "branches")
	branchesIgnore, hasIgnore := lookup(cfg, "branches-ignore")
	_, hasTags := lookup(cfg, "tags")
	var fires bool
	var err error
	switch {
	case hasBranches:
		fires, err = anyGlob(branches, base)
	case hasIgnore:
		var ignored bool
		ignored, err = anyGlob(branchesIgnore, base)
		fires = !ignored
	default:
		fires = !hasTags
	}
	if err != nil {
		return false, false, err
	}
	return fires, hasNonEmpty(cfg, "paths") || hasNonEmpty(cfg, "paths-ignore"), nil
}

func anyGlob(node *yaml.Node, base string) (bool, error) {
	patterns, err := scalars(node)
	if err != nil {
		return false, err
	}
	matched := false
	for _, pattern := range patterns {
		negated := strings.HasPrefix(pattern, "!")
		if matchBranch(strings.TrimPrefix(pattern, "!"), base) {
			matched = !negated
		}
	}
	return matched, nil
}

// scalars reads a scalar or a sequence of scalars, such as a branches or paths filter.
func scalars(node *yaml.Node) ([]string, error) {
	node = deref(node)
	if node == nil || node.Tag == nullTag {
		return nil, nil
	}
	switch node.Kind {
	case yaml.ScalarNode:
		return []string{node.Value}, nil
	case yaml.SequenceNode:
		out := make([]string, 0, len(node.Content))
		for _, item := range node.Content {
			if item.Kind != yaml.ScalarNode {
				return nil, errors.New("filter list holds a non-scalar")
			}
			out = append(out, item.Value)
		}
		return out, nil
	default:
		return nil, errors.New("filter is neither a scalar nor a sequence")
	}
}

// matchBranch applies GitHub's `*` branch glob well enough to tell whether the default branch
// itself is matched or excluded, which is all the trigger filter needs.
func matchBranch(pattern, base string) bool {
	re := "^" + globRegexp(pattern) + "$"
	ok, err := regexp.MatchString(re, base)
	return err == nil && ok
}

// globRegexp converts a GitHub branch filter to a regexp. `*` matches within one path segment,
// `**` crosses segments, and `?` matches one non-slash character.
func globRegexp(pattern string) string {
	var out strings.Builder
	runes := []rune(pattern)
	for i := 0; i < len(runes); i++ {
		switch runes[i] {
		case '*':
			if i+1 < len(runes) && runes[i+1] == '*' {
				out.WriteString(".*")
				i++
			} else {
				out.WriteString("[^/]*")
			}
		case '?':
			out.WriteString("[^/]")
		default:
			out.WriteString(regexp.QuoteMeta(string(runes[i])))
		}
	}
	return out.String()
}

func hasNonEmpty(node *yaml.Node, key string) bool {
	child, ok := lookup(node, key)
	if !ok {
		return false
	}
	child = deref(child)
	switch child.Kind {
	case yaml.ScalarNode:
		return child.Value != ""
	case yaml.SequenceNode:
		return len(child.Content) > 0
	default:
		return false
	}
}

// jobEntries walks jobs and their steps in document order and captures every run and uses step.
func jobEntries(file string, jobs *yaml.Node, workflowWD, workflowShell string, workflowEnv map[string]string) ([]Entry, error) {
	entries := []Entry{}
	for i := 0; i+1 < len(jobs.Content); i += mapPair {
		more, err := jobEntriesFor(file, jobs.Content[i].Value, jobs.Content[i+1], workflowWD, workflowShell, workflowEnv)
		if err != nil {
			return nil, err
		}
		entries = append(entries, more...)
	}
	return entries, nil
}

func jobEntriesFor(file, jobName string, job *yaml.Node, workflowWD, workflowShell string, workflowEnv map[string]string) ([]Entry, error) {
	if job.Kind == yaml.AliasNode {
		job = job.Alias
	}
	if job.Kind != yaml.MappingNode {
		return nil, nil
	}
	jobWD, jobShell := jobRunDefaults(job, workflowWD, workflowShell)
	jobEnv, err := envMap(lookupNode(job, "env"))
	if err != nil {
		return nil, fmt.Errorf("job %s: %w", jobName, err)
	}
	baseEnv := map[string]string{}
	maps.Copy(baseEnv, workflowEnv)
	maps.Copy(baseEnv, jobEnv)
	steps, _ := lookup(job, "steps")
	if steps != nil && steps.Kind == yaml.AliasNode {
		steps = steps.Alias
	}
	if steps == nil || steps.Kind != yaml.SequenceNode {
		if uses := scalarValue(job, "uses"); uses != "" {
			return []Entry{reusableWorkflowCall(file, jobName, uses, jobWD, jobShell, baseEnv)}, nil
		}
		return nil, nil
	}
	return stepEntries(file, jobName, steps, jobWD, jobShell, baseEnv)
}

// reusableWorkflowCall is the entry for a job that calls a reusable workflow. The job has no
// steps, and the called file usually triggers only on workflow_call and so is not derived on its
// own, so this entry is what keeps the checks it runs in CHECKS_SET. Like a uses-only step, it is
// part of what CI runs but not something a shell can replay.
func reusableWorkflowCall(file, jobName, uses, wd, shell string, env map[string]string) Entry {
	return Entry{
		File: file, Job: jobName, Step: "", StepIndex: 0, Kind: kindAction, Command: "", Action: uses,
		WorkingDirectory: wd, Env: env, Shell: shell, Runnable: false, RequiresRunnerReason: "reusable workflow call",
	}
}

// jobRunDefaults resolves a job's shell and working directory, inheriting the workflow's.
func jobRunDefaults(job *yaml.Node, workflowWD, workflowShell string) (string, string) {
	defaults, _ := lookup(job, "defaults")
	runDefaults, _ := lookup(defaults, "run")
	jobWD := scalarValue(runDefaults, "working-directory")
	if jobWD == "" {
		jobWD = workflowWD
	}
	jobShell := scalarValue(runDefaults, "shell")
	if jobShell == "" {
		jobShell = workflowShell
	}
	return jobWD, jobShell
}

func stepEntries(file, jobName string, steps *yaml.Node, jobWD, jobShell string, jobEnv map[string]string) ([]Entry, error) {
	entries := make([]Entry, 0, len(steps.Content))
	for index, step := range steps.Content {
		if step.Kind == yaml.AliasNode {
			step = step.Alias
		}
		if step.Kind != yaml.MappingNode {
			continue
		}
		entry, ok, err := stepEntry(file, jobName, index, step, jobWD, jobShell, jobEnv)
		if err != nil {
			return nil, err
		}
		if ok {
			entries = append(entries, entry)
		}
	}
	return entries, nil
}

func lookupNode(node *yaml.Node, key string) *yaml.Node {
	child, _ := lookup(node, key)
	return deref(child)
}

// envMap flattens one env mapping. A non-scalar value is an error, never a silently dropped key.
func envMap(node *yaml.Node) (map[string]string, error) {
	node = deref(node)
	env := map[string]string{}
	if node == nil || node.Tag == nullTag {
		return env, nil
	}
	if node.Kind != yaml.MappingNode {
		return nil, errors.New("env is not a mapping")
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		name := node.Content[i].Value
		value := deref(node.Content[i+1])
		if value.Kind != yaml.ScalarNode {
			return nil, fmt.Errorf("env %s is not a scalar", name)
		}
		env[name] = value.Value
	}
	return env, nil
}

func stepEntry(file, job string, index int, step *yaml.Node, jobWD, jobShell string, jobEnv map[string]string) (Entry, bool, error) {
	wd := scalarValue(step, "working-directory")
	if wd == "" {
		wd = jobWD
	}
	shell := scalarValue(step, "shell")
	if shell == "" {
		shell = jobShell
	}
	stepEnv, err := envMap(lookupNode(step, "env"))
	if err != nil {
		return Entry{}, false, fmt.Errorf("step %d: %w", index, err)
	}
	env := map[string]string{}
	maps.Copy(env, jobEnv)
	maps.Copy(env, stepEnv)
	entry := Entry{
		File: file, Job: job, Step: scalarValue(step, "name"), StepIndex: index,
		Kind: "", Command: "", Action: "", WorkingDirectory: wd, Env: env, Shell: shell,
		Runnable: false, RequiresRunnerReason: "",
	}
	if run := lookupNode(step, "run"); run != nil && run.Kind == yaml.ScalarNode {
		entry.Kind = kindRun
		entry.Command = run.Value
		entry.Runnable, entry.RequiresRunnerReason = classifyRun(entry)
		return entry, true, nil
	}
	if uses := lookupNode(step, "uses"); uses != nil && uses.Kind == yaml.ScalarNode {
		if isDroppedAction(uses.Value) {
			var none Entry
			return none, false, nil
		}
		entry.Kind = kindAction
		entry.Action = uses.Value
		entry.RequiresRunnerReason = "uses-only step"
		return entry, true, nil
	}
	var none Entry
	return none, false, nil
}

// isDroppedAction reports the closed exclusion list of commands.md §1.6 step 4: actions/checkout,
// actions/setup-*, and actions/cache. The name ends at the action boundary, so an action that
// merely starts like one of them, such as actions/checkout-lint, is a different action and is kept.
func isDroppedAction(uses string) bool {
	name, _, _ := strings.Cut(uses, "@")
	return isAction(name, "actions/checkout") || isAction(name, "actions/cache") ||
		strings.HasPrefix(name, "actions/setup-")
}

// isAction reports whether name is the action base or a path inside it, as actions/cache/restore.
func isAction(name, base string) bool {
	return name == base || strings.HasPrefix(name, base+"/")
}

// classifyRun decides whether an entry is safe to replay unattended in a worktree. It never
// guesses from the command's name: only the conditions the rule names make an entry
// requires-runner.
func classifyRun(entry Entry) (bool, string) {
	if hasExpression(entry.Command) || anyExpression(entry.Env) {
		return false, "GitHub Actions expression in the command or env"
	}
	if hasRunnerEnv(entry.Command) {
		return false, "command depends on a runner-provided environment variable"
	}
	if reason := globalMutation(entry.Command); reason != "" {
		return false, reason
	}
	if entry.Shell != "" && entry.Shell != shellBash && entry.Shell != shellSh {
		return false, fmt.Sprintf("shell %q is not bash or sh", entry.Shell)
	}
	return true, ""
}

func hasExpression(text string) bool {
	return strings.Contains(text, "${{") && strings.Contains(text, "}}")
}

// runnerEnvPattern matches every variable a hosted runner provides under the RUNNER_, GITHUB_, or
// ACTIONS_ prefix. Listing names would miss the rest, and a missed one expands to nothing locally:
// rm -rf $GITHUB_WORKSPACE/* becomes rm -rf /*.
var runnerEnvPattern = regexp.MustCompile(`\$\{?(RUNNER_|GITHUB_|ACTIONS_)`)

// hasRunnerEnv reports a command that reads a variable only a hosted runner provides. Its value
// is empty or meaningless locally, and writes to GITHUB_PATH/GITHUB_ENV cannot affect later
// entries, so replaying it would not reproduce CI.
func hasRunnerEnv(command string) bool {
	return runnerEnvPattern.MatchString(command)
}

func anyExpression(env map[string]string) bool {
	for _, value := range env {
		if hasExpression(value) {
			return true
		}
	}
	return false
}

// globalMutation reports a global-scope install or mutation, which mutates state outside the
// worktree and so is never replayed locally.
func globalMutation(command string) string {
	command = strings.ReplaceAll(command, "\\\r\n", " ")
	command = strings.ReplaceAll(command, "\\\n", " ")
	patterns := []struct {
		re     *regexp.Regexp
		reason string
	}{
		{regexp.MustCompile(`(^|[\s;&|()])(\S*/)?sudo(\s|$)`), "sudo"},
		{regexp.MustCompile(`\bgh\s+release\s+create\b`), "gh release create"},
		{regexp.MustCompile(`\bgit\s+config\s+--global\b`), "git config --global"},
		{regexp.MustCompile(`--scope(\s+|=)user\b`), "user-scope install"},
		// pip accepts general options before the subcommand, with or without a value, so install
		// is any later word of the same command, and python -m pip is the same pip.
		{regexp.MustCompile(`(\bpip[0-9.]*|\s-mpip)\b[^\n;&|]*\binstall\b`), "pip install mutates the ambient Python environment"},
		{regexp.MustCompile(`\b(npm|yarn|pnpm|bun|gem|pip[0-9.]*)\b[^\n;&|]*(\s|=)(-g|--global)(\s|$)`), "global-scope package flag"},
		{regexp.MustCompile(`\b(brew|cargo|gem|go)\s+install\b`), "global-scope install"},
	}
	for _, pattern := range patterns {
		if pattern.re.MatchString(command) {
			return pattern.reason
		}
	}
	return ""
}
