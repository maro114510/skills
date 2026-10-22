package scan_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/maro114510/skills/oe/internal/scan"
)

// Fake secrets are assembled at run time, so this file never matches a rule itself.
func awsKey() string      { return "AK" + "IA" + strings.Repeat("Q7", 8) }
func githubToken() string { return "gh" + "p_" + strings.Repeat("a1B2", 6) }
func skKey() string       { return "s" + "k-ant-" + strings.Repeat("x9Y_", 6) }
func slackToken() string  { return "xo" + "xb-" + "1234567890" }
func keyHeader() string   { return "-----BEGIN " + "RSA PRIVATE" + " KEY-----" }
func passLiteral() string { return "hunter2" + "hunter2" }

func rulesOf(findings []scan.Finding) []string {
	rules := make([]string, 0, len(findings))
	for _, f := range findings {
		rules = append(rules, f.Rule)
	}
	return rules
}

func TestTextFindsEachContentRule(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		text string
		rule string
	}{
		"aws access key":       {"key: " + awsKey() + "\n", scan.RuleAWSKey},
		"private key header":   {keyHeader() + "\nMIIE\n", scan.RulePrivateKey},
		"github token":         {"use " + githubToken() + " here", scan.RuleGitHubToken},
		"sk api key":           {"export KEY=" + skKey(), scan.RuleSKKey},
		"slack token":          {"slack " + slackToken(), scan.RuleSlackToken},
		"quoted password":      {"pass" + `word = "` + passLiteral() + `"`, scan.RuleAssignment},
		"json token":           {`{"to` + `ken": "` + passLiteral() + `"}`, scan.RuleAssignment},
		"env token":            {"API_TO" + "KEN=" + strings.Repeat("a1", 9), scan.RuleAssignment},
		"yaml password":        {"pass" + "wd: '" + passLiteral() + "'", scan.RuleAssignment},
		"mixed-case password":  {"db_pass" + `word: "Tr0ub4` + `dor&3"`, scan.RuleAssignment},
		"go short declaration": {"pass" + `word := "` + passLiteral() + `"`, scan.RuleAssignment},
		"typed assignment":     {"pass" + `word: string = "` + passLiteral() + `"`, scan.RuleAssignment},
		"key in the last line": {"one\ntwo\n" + awsKey(), scan.RuleAWSKey},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			r := scan.Text("pr-body", []byte(tc.text))
			if r.Clean || !slices.Contains(rulesOf(r.Findings), tc.rule) {
				t.Errorf("Text() = %+v; want a %s finding", r, tc.rule)
			}
		})
	}
}

func TestTextIgnoresNonSecrets(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"go short declaration":   "token := leaseToken",
		"go comparison":          `if token == "abcdefgh12345" {`,
		"getenv":                 `token = os.Getenv("GITHUB_TOKEN")`,
		"placeholder":            `password: "<password>"`,
		"shell variable":         `TOKEN="${GITHUB_TOKEN}"`,
		"template":               `token: "{{ .Token }}"`,
		"flag":                   "--lease-token <token>",
		"short value":            `token: "abc"`,
		"bare identifier":        "token = leaseTokenFromTheCaller",
		"masked":                 `password = "********"`,
		"suffix word":            "token_count = 12345678901234567890",
		"empty":                  `owner_token=`,
		"regex in docs":          "AKIA[0-9A-Z]{16}, gh[pousr]_[A-Za-z0-9]{20,}, xox[baprs]-",
		"key header pattern":     "-----BEGIN [A-Z ]*PRIVATE KEY-----",
		"sk prefix inside words": "task-" + strings.Repeat("a", 30),
		"sha":                    "head 4d44198a0ab37c33a1af253136ce46f611e988e3",
		"go name constant":       `NoteLeftoverToken = "leftover-token"`,
		"path value":             `token_file: "/run/secrets/gh-token"`,
		"escaped newlines":       `printf 'token=tok-a\npid=1\nlstart=x\nstarted=x\n'`,
		"slack regex in docs":    `grep -E "xoxb-[0-9]+-[a-zA-Z0-9]+" .`,
	}
	for name, text := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if r := scan.Text("note", []byte(text)); !r.Clean || len(r.Findings) != 0 {
				t.Errorf("Text(%q) = %+v; want clean", text, r)
			}
		})
	}
}

func TestTextReportsSourceAndLine(t *testing.T) {
	t.Parallel()

	r := scan.Text("run-plan", []byte("one\ntwo\n"+githubToken()+"\n"))
	want := []scan.Finding{{Rule: scan.RuleGitHubToken, Where: scan.WhereText, Commit: "", Path: "", Line: 3}}
	if r.Clean || r.Source != "run-plan" || !slices.Equal(r.Findings, want) {
		t.Errorf("Text() = %+v; want source run-plan, findings %+v", r, want)
	}
}

func TestTextNeverEchoesTheValue(t *testing.T) {
	t.Parallel()

	secrets := []string{awsKey(), githubToken(), skKey(), slackToken(), keyHeader(), passLiteral()}
	text := strings.Join([]string{
		awsKey(), githubToken(), skKey(), slackToken(), keyHeader(),
		"pass" + `word: "` + passLiteral() + `"`,
	}, "\n")
	r := scan.Text("completion", []byte(text))
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if r.Clean || len(r.Findings) != len(secrets) {
		t.Fatalf("Text() = %+v; want %d findings", r, len(secrets))
	}
	for _, s := range secrets {
		if strings.Contains(string(data), s) {
			t.Errorf("report %s echoes a matched value", data)
		}
	}
}

func TestTextWithholdsASecretSourceLabel(t *testing.T) {
	t.Parallel()

	r := scan.Text("label-"+githubToken(), []byte("clean text"))
	if r.Clean || r.Source != scan.Withheld || strings.Contains(r.Source, githubToken()) {
		t.Errorf("Text() = %+v; want a withheld source and a finding", r)
	}
}

func TestTextWithNULIsUnscannable(t *testing.T) {
	t.Parallel()

	r := scan.Text("evidence", []byte("ok\nbin\x00ary\n"))
	want := []scan.Finding{{Rule: scan.RuleUnscannable, Where: scan.WhereText, Commit: "", Path: "", Line: 2}}
	if r.Clean || !slices.Equal(r.Findings, want) {
		t.Errorf("Text() = %+v; want %+v", r, want)
	}
}

func TestMatchPath(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		".env":                        scan.RulePathEnv,
		"app/.env.production":         scan.RulePathEnv,
		"certs/server.PEM":            scan.RulePathPEM,
		"tls/server.key":              scan.RulePathKey,
		"home/id_" + "rsa.pub":        scan.RulePathSSHKey,
		"aws/credentials":             scan.RulePathCredentials,
		"config/db_credentials.yml":   scan.RulePathCredentials,
		"k8s/my-secret.yaml":          scan.RulePathSecret,
		"store.p12":                   scan.RulePathP12,
		"gcp/service-account-ci.json": scan.RulePathServiceAccount,
	}
	for path, rule := range tests {
		t.Run(path, func(t *testing.T) {
			t.Parallel()
			if got := scan.MatchPath(path); !slices.Contains(got, rule) {
				t.Errorf("MatchPath(%q) = %v; want %s", path, got, rule)
			}
		})
	}
	for _, path := range []string{
		"oe/internal/scan/scan.go", "docs/env.md", "keyboard.go", "monkey.txt",
		"service-account.yaml", "skills/commit/SKILL.md", "oe/cmd/root.go",
	} {
		if got := scan.MatchPath(path); len(got) != 0 {
			t.Errorf("MatchPath(%q) = %v; want none", path, got)
		}
	}
}

// TestRepresentativeTextsAreClean scans the published templates and the documents that quote the patterns.
func TestRepresentativeTextsAreClean(t *testing.T) {
	t.Parallel()

	root := filepath.Join("..", "..", "..")
	files := []string{
		"skills/orchestrate-epic/references/templates.md",
		"skills/orchestrate-epic/references/commands.md",
		"skills/orchestrate-epic/SKILL.md",
		"skills/commit/SKILL.md",
		"docs/design/orchestrate-epic-v2/contract.md",
		"docs/design/orchestrate-epic-v2/rule-inventory.tsv",
		"agents/issue-reviewer.md",
		"AGENTS.md",
	}
	for _, f := range files {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(f))) //nolint:gosec // G304: a fixed repository file.
		if err != nil {
			t.Fatal(err)
		}
		if r := scan.Text(f, data); !r.Clean {
			t.Errorf("Text(%s) = %+v; want clean", f, r.Findings)
		}
	}
}
