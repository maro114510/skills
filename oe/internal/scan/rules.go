// Package scan is the secret scan of contract §14.
// A finding names a location and never the value.
// A scan that cannot finish returns an error, never a clean report.
package scan

import (
	"bytes"
	"path"
	"regexp"
	"strings"
)

// Content rules cover at least the commit skill's patterns and the earlier secret screen.
const (
	RuleAWSKey      = "aws-access-key"
	RulePrivateKey  = "private-key-header"
	RuleGitHubToken = "github-token"
	RuleSKKey       = "sk-api-key"
	RuleSlackToken  = "slack-token"
	RuleAssignment  = "password-or-token-literal"
	// RuleUnscannable marks binary content.
	RuleUnscannable = "unscannable"
)

// Path rules match the base name of a changed path in any case.
const (
	RulePathEnv            = "env-file"
	RulePathPEM            = "pem-file"
	RulePathKey            = "key-file"
	RulePathSSHKey         = "ssh-key-file"
	RulePathCredentials    = "credentials-file"
	RulePathSecret         = "secret-file"
	RulePathP12            = "p12-file"
	RulePathServiceAccount = "service-account-file"
)

// Withheld replaces a path or label that matches a content rule.
const Withheld = "(withheld)"

// A bare value needs more length than a quoted one to count as a literal.
const (
	minQuotedLiteral = 8
	minBareLiteral   = 16
)

var (
	awsKeyRE      = regexp.MustCompile(`AKIA[0-9A-Z]{16}`)
	privateKeyRE  = regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)
	githubTokenRE = regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{20,}`)
	skKeyRE       = regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{20,}`)
	// A real Slack token always has a token character after the prefix, and a pattern quoted in documentation does not.
	slackTokenRE = regexp.MustCompile(`xox[baprs]-[0-9A-Za-z]`)
	// assignmentRE finds a value assigned to a key ending in password, passwd, or token.
	// The operator is `:=`, `=`, `:`, or a type annotation followed by `=`.
	// A bare value ends at a backslash, which starts an escape.
	assignmentRE = regexp.MustCompile(`(?i)(?:password|passwd|token)["']?[ \t]*(?::[ \t]*[A-Za-z_][A-Za-z0-9_.\[\]]*[ \t]*=|:=|[:=])[ \t]*("[^"]*"|'[^']*'|[^\s"',;)}\]\\]+)`)
)

type contentRule struct {
	name string
	re   *regexp.Regexp
}

func contentRules() []contentRule {
	return []contentRule{
		{RuleAWSKey, awsKeyRE},
		{RulePrivateKey, privateKeyRE},
		{RuleGitHubToken, githubTokenRE},
		{RuleSKKey, skKeyRE},
		{RuleSlackToken, slackTokenRE},
	}
}

// matchLine returns the content rules a line matches.
func matchLine(line []byte) []string {
	var rules []string
	for _, r := range contentRules() {
		if r.re.Match(line) {
			rules = append(rules, r.name)
		}
	}
	if hasLiteralAssignment(line) {
		rules = append(rules, RuleAssignment)
	}
	return rules
}

func hasLiteralAssignment(line []byte) bool {
	for _, m := range assignmentRE.FindAllSubmatchIndex(line, -1) {
		if literalValue(string(line[m[2]:m[3]])) {
			return true
		}
	}
	return false
}

// literalValue reports whether an assigned value looks like a secret and not like code or a placeholder.
func literalValue(v string) bool {
	quoted := len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0]
	if quoted {
		v = v[1 : len(v)-1]
	}
	if placeholder(v) {
		return false
	}
	if quoted {
		// A name like leftover-token uses one class, and a password mixes them.
		return len(v) >= minQuotedLiteral && charClasses(v) >= 2
	}
	return len(v) >= minBareLiteral && strings.ContainsAny(v, "0123456789") &&
		strings.IndexFunc(v, isLetter) >= 0
}

// placeholder reports an empty value, a reference, a template, a value with spaces, or one repeated character.
func placeholder(v string) bool {
	return v == "" || strings.ContainsAny(v[:1], "<${%*[(=") || strings.ContainsAny(v, " \t") ||
		strings.Count(v, v[:1]) == len(v) || strings.Contains(v, "{{")
}

func isLetter(r rune) bool { return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') }

// charClasses counts the classes among lower case, upper case, digits, and symbols in v.
// Name and path separators count as none.
func charClasses(v string) int {
	var lower, upper, digit, symbol int
	for _, r := range v {
		switch {
		case r >= 'a' && r <= 'z':
			lower = 1
		case r >= 'A' && r <= 'Z':
			upper = 1
		case r >= '0' && r <= '9':
			digit = 1
		case strings.ContainsRune("-_./", r):
		default:
			symbol = 1
		}
	}
	return lower + upper + digit + symbol
}

// MatchPath returns the path rules a changed path matches.
func MatchPath(p string) []string {
	base := strings.ToLower(path.Base(p))
	var rules []string
	add := func(rule string, ok bool) {
		if ok {
			rules = append(rules, rule)
		}
	}
	add(RulePathEnv, strings.HasPrefix(base, ".env"))
	add(RulePathPEM, strings.HasSuffix(base, ".pem"))
	add(RulePathKey, strings.HasSuffix(base, ".key"))
	add(RulePathSSHKey, hasAnyPrefix(base, "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"))
	add(RulePathCredentials, strings.Contains(base, "credentials"))
	add(RulePathSecret, strings.Contains(base, "secret"))
	add(RulePathP12, strings.HasSuffix(base, ".p12") || strings.HasSuffix(base, ".pfx"))
	add(RulePathServiceAccount, strings.HasPrefix(base, "service-account") && strings.HasSuffix(base, ".json"))
	return rules
}

func hasAnyPrefix(s string, prefixes ...string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// locate returns a printable location and the content rules the location matches.
func locate(name string) (string, []string) {
	rules := matchLine([]byte(name))
	if len(rules) > 0 {
		return Withheld, rules
	}
	return name, nil
}

// nulLine returns the line of the first NUL byte, or 0 when there is none.
func nulLine(data []byte) int {
	before, _, found := bytes.Cut(data, []byte{0})
	if !found {
		return 0
	}
	return 1 + bytes.Count(before, []byte("\n"))
}

// scanLines returns a finding for each rule each line matches, numbering lines from first.
func scanLines(data []byte, first int, at Finding) []Finding {
	var out []Finding
	for i, line := range bytes.Split(data, []byte("\n")) {
		for _, rule := range matchLine(line) {
			f := at
			f.Rule = rule
			f.Line = first + i
			out = append(out, f)
		}
	}
	return out
}
