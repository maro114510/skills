package scan

// Where a finding sits.
const (
	WhereCommitContent   = "commit-content"
	WhereCommitMessage   = "commit-message"
	WhereCommitPath      = "commit-path"
	WhereWorktreeContent = "worktree-content"
	WhereWorktreePath    = "worktree-path"
	WhereText            = "text"
)

// Finding names the rule and the location of a suspected secret, never the value.
// Line 0 means the whole path.
type Finding struct {
	Rule   string `json:"rule"`
	Where  string `json:"where"`
	Commit string `json:"commit,omitempty"`
	Path   string `json:"path,omitempty"`
	Line   int    `json:"line,omitempty"`
}

// TextReport is the scan of one text.
type TextReport struct {
	Clean    bool      `json:"clean"`
	Source   string    `json:"source"`
	Findings []Finding `json:"findings"`
}

// Text scans one text before it is published.
func Text(source string, data []byte) TextReport {
	at := Finding{Rule: "", Where: WhereText, Commit: "", Path: "", Line: 0}
	label, labelRules := locate(source)
	findings := make([]Finding, 0, len(labelRules))
	for _, rule := range labelRules {
		f := at
		f.Rule = rule
		findings = append(findings, f)
	}
	if line := nulLine(data); line > 0 {
		f := at
		f.Rule = RuleUnscannable
		f.Line = line
		findings = append(findings, f)
	} else {
		findings = append(findings, scanLines(data, 1, at)...)
	}
	return TextReport{Clean: len(findings) == 0, Source: label, Findings: findings}
}
