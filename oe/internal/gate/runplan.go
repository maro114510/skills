package gate

import (
	"fmt"
	"strings"

	"github.com/maro114510/skills/oe/internal/board"
	"github.com/maro114510/skills/oe/internal/checks"
	"github.com/maro114510/skills/oe/internal/coord"
	"github.com/maro114510/skills/oe/internal/health"
	"github.com/maro114510/skills/oe/internal/snapshot"
	"github.com/maro114510/skills/oe/internal/state"
)

// The per-Issue worst case and the landing limits the Run Plan states. The budget multipliers
// and the fix-cycle cap are coord's own, so the plan can never state a bound the ledger lacks.
const (
	// ReviewerPassesWorstCase is the reviewer passes one Issue can take in a round: the initial
	// review, one per fix cycle, and one uncharged staleness pass.
	ReviewerPassesWorstCase = coord.ReviewerPassesPerIssue
	// LandingPolls is how many times landing polls per invocation, resetting after each merge.
	LandingPolls = 30
	// LandingPollSeconds is the time between two landing polls.
	LandingPollSeconds = 60
	// SilentPRPolls is how many polls a PR with no check reported waits before it goes to a person.
	SilentPRPolls = 5
	// ExtraRounds is how many rounds past its merges one invocation runs at most.
	ExtraRounds = 2

	secondsPerMinute = 60
)

// Plan is everything the Run Plan states. Every number in it comes from oe.
type Plan struct {
	Epic          int
	DefaultBranch string
	Protection    snapshot.Protection
	Checks        checks.Set
	Issues        []board.Issue
	MaxParallel   int
	// Budget is the Epic-wide budget: the ledger's when one exists, else the one a ledger
	// created now would hold.
	Budget state.Ledger
}

// Render renders the Run Plan note's text. The comment writer adds the marker.
func Render(p Plan) string {
	var b strings.Builder
	fmt.Fprintf(&b, "## Run Plan — Epic #%d\n\n", p.Epic)
	renderFacts(&b, p)
	renderIssues(&b, p)
	renderBounds(&b, p)
	b.WriteString(nextActions())
	return b.String()
}

func renderFacts(b *strings.Builder, p Plan) {
	b.WriteString("### リポジトリ事実\n")
	pr := p.Protection
	if pr.Configured {
		checksText := "なし"
		if len(pr.RequiredChecks) > 0 {
			checksText = strings.Join(codes(pr.RequiredChecks), ", ")
		}
		reviewers := "なし"
		if pr.RequiredReviewers > 0 {
			reviewers = fmt.Sprintf("%d 人", pr.RequiredReviewers)
		}
		fmt.Fprintf(b, "- branch protection (`%s`): あり（required checks: %s、required reviewers: %s）\n", p.DefaultBranch, checksText, reviewers)
	} else {
		fmt.Fprintf(b, "- branch protection (`%s`): なし\n", p.DefaultBranch)
	}
	b.WriteString("  - ruleset は読み取っていません。ruleset による必須チェックやレビューがあれば、GitHub がマージ時に強制します\n")
	var runnable, runner []string
	for _, e := range p.Checks.Entries {
		if e.Runnable {
			runnable = append(runnable, fmt.Sprintf("    - %s: %s（working directory: %s）", entryName(e), code(e.Command), code(orDot(e.WorkingDirectory))))
		} else {
			runner = append(runner, fmt.Sprintf("    - %s: %s — %s", entryName(e), code(entryText(e)), oneLine(e.RequiresRunnerReason)))
		}
	}
	fmt.Fprintf(b, "- 導出した CHECKS_SET（`.github/workflows/` の %s から derive。script 名からの推測ではない）\n", code(short(p.Checks.Revision)))
	b.WriteString("  - 実行可能:" + list(runnable) + "\n")
	b.WriteString("  - ローカル検証不可（このループは実行しない）:" + list(runner) + "\n")
	if !pr.Gated() {
		b.WriteString("- [!] required checks も required reviewers も未設定です。このループの reviewer pass と CHECKS_SET の実行可能エントリが、マージ前の唯一のゲートです。\n")
	}
	switch p.Checks.DefaultBranchPush {
	case checks.PushNone:
		b.WriteString("- [!] default branch への push で動く workflow がありません。マージ後の default branch のチェックを確認できないため、このループがマージするたびに Epic を凍結します。マージは手動で行うことを検討してください。\n")
	case checks.PushFiltered:
		b.WriteString("- [!] default branch への push で動く workflow はすべて `paths` / `paths-ignore` で絞られています。どのパスにも触れないマージではチェックが報告されず、同じように Epic を凍結します。\n")
	}
	b.WriteString("\n")
}

func renderIssues(b *strings.Builder, p Plan) {
	b.WriteString("### Issue 一覧\n| Issue | タイトル | 状態 | 待ち | base branch |\n|-------|---------|------|------|-------------|\n")
	for _, i := range p.Issues {
		waiting := "-"
		if len(i.WaitingOn) > 0 {
			refs := make([]string, 0, len(i.WaitingOn))
			for _, n := range i.WaitingOn {
				refs = append(refs, fmt.Sprintf("#%d", n))
			}
			waiting = strings.Join(refs, ", ")
		}
		base := p.DefaultBranch
		if i.State == board.Done {
			base = "-"
		}
		fmt.Fprintf(b, "| #%d | %s | %s | %s | %s |\n", i.Number, cell(i.Title), i.State, waiting, base)
	}
	b.WriteString("\nbase branch はすべて default branch です。依存先がマージされてから着手するため、ブランチを積み重ねません。\n")
	b.WriteString("状態はブランチ・PR・このループのコメントから判定しています。ラベルは読み取りも付与もしません。\n\n")
}

func renderBounds(b *strings.Builder, p Plan) {
	c := p.Budget.Counters
	b.WriteString("### Bounds\n")
	fmt.Fprintf(b, "- max-parallel: %d\n", p.MaxParallel)
	fmt.Fprintf(b, "- fix-cycle cap: Issue あたり %d（reviewer 指摘を受けた worker 再 dispatch と再 review を、blocking・nit のみを問わず 1 cycle と数えます）\n", coord.MaxCycle)
	fmt.Fprintf(b, "- Issue あたりのワースト想定（予測ではなく上限）: worker 最大 %d 回（初回 + 回答済み BLOCKED の再送 1 回 + FAILED 再試行 1 回 + fix cycle %d 回）、reviewer 最大 %d 回（初回 + fix cycle %d 回 + staleness 再検証 1 回。FAILED 再試行では reviewer を呼びません）。同じ round で再び stale になった Issue は次回の実行に回します\n",
		coord.WorkerDispatchesPerIssue, coord.MaxCycle, ReviewerPassesWorstCase, coord.MaxCycle)
	fmt.Fprintf(b, "- Epic 全体の予算（N = %d、セッションや再実行をまたいで累積）: worker dispatch %d 回（使用 %d）、reviewer 実行 %d 回（使用 %d。staleness 再検証は数えません）、fix cycle %d 回（使用 %d）。spawn の前に毎回差し引き、超える操作をしようとした時点で Epic を凍結して、`epic-release` が投稿されるまで dispatch・review・PR 作成・マージをすべて止めます。`epic-retry` で Issue 単位の cycle を戻しても、この予算は戻りません\n",
		p.Budget.N, c.WorkerDispatches.Bound, c.WorkerDispatches.Used, c.ReviewerPasses.Bound, c.ReviewerPasses.Used, c.FixCycles.Bound, c.FixCycles.Used)
	b.WriteString("- [!] 予算は spawn の回数だけを数えます。wall-clock やトークン消費量による自動停止はありません\n")
	b.WriteString("- PR の修復（CI 失敗・レビュー指摘・conflict）は fix cycle として数え、上記の fix-cycle cap と Epic 全体の予算に含めます。修復専用の上限は設けません\n")
	fmt.Fprintf(b, "- CI 待ちのポーリング: 1 回の実行につき %d 秒間隔で最大 %d 回（マージのたびに数え直し）。チェックが 1 件も報告されない PR は push から %d 回で打ち切り、人の対応待ちにします。使い切ったら待ち中の PR は次回の実行に回します\n",
		LandingPollSeconds, LandingPolls, SilentPRPolls)
	fmt.Fprintf(b, "- マージ後の継続: このループがマージした PR の default branch チェックがすべて通ったら、同じセッションのまま GitHub の状態を読み直し、ready になった Issue を dispatch します。1 回の実行で進むのは、マージした件数 + %d round までです\n\n", ExtraRounds)
}

// nextActions tells the human how to approve and how to grant merging.
func nextActions() string {
	return `### 次のアクション
このプランに問題がなければ、この Epic に ` + "`epic-approve`" + ` とだけ書いたコメントを投稿してください。この Run Plan より後に、OWNER・MEMBER・COLLABORATOR が投稿したものだけが承認になります。投稿されるまで dispatch は行われません。
` + "`epic-approve`" + ` を文中に含めただけのコメント（例: 「確認したら epic-approve します」）は承認になりません。補足や条件は別のコメントに書いてください。ラベルは承認として読み取りません。
承認した後に、このループが対話で確認を求めることはありません。介入は Issue や Epic へのコメントで行えます。

### マージ権限
` + "`epic-approve`" + ` が許可するのは実装と PR 作成までです。PR のマージは許可しません。
ループにマージも任せる場合は、この Run Plan より後に ` + "`epic-auto-merge`" + ` とだけ書いたコメントを別に投稿してください。取り消すときは ` + "`epic-revoke-auto-merge`" + ` とだけ書いたコメントを投稿します。両者のうち最も新しいコメントが有効で、ループはマージの直前に毎回読み直します。
マージを許可しても、必須レビュー・ruleset・人の確認を求めるリポジトリ側の制御は迂回しません。GitHub の auto-merge は使いません。
マージは 1 件ずつ、レビュー済みの HEAD を expected SHA として指定して行います。マージのたびに default branch 上のマージコミットのチェックがすべて通るまで、次の PR はマージしません。失敗・キャンセルされた場合、` +
		fmt.Sprintf("%d 分経ってもチェックが 1 件も報告されない場合、%d 分経っても終わらないチェックがある場合", health.NoChecksGrace/secondsPerMinute, health.PendingLimit/secondsPerMinute) +
		`は Epic を凍結してお知らせします。自動で revert はしません。
CI 失敗・レビュー指摘・conflict の修復は ` + "`epic-approve`" + ` だけで行います。マージ権限が無い場合も PR を修復し、マージはあなたに任せます。
`
}

func entryName(e checks.Entry) string {
	name := e.Step
	if name == "" {
		name = fmt.Sprintf("step %d", e.StepIndex+1)
	}
	return fmt.Sprintf("%s / %s / %s", e.File, e.Job, oneLine(name))
}

func entryText(e checks.Entry) string {
	if e.Command != "" {
		return e.Command
	}
	return e.Action
}

func list(items []string) string {
	if len(items) == 0 {
		return " なし"
	}
	return "\n" + strings.Join(items, "\n")
}

func orDot(dir string) string {
	if dir == "" {
		return "."
	}
	return dir
}

func short(sha string) string {
	const shortSHA = 12
	if len(sha) > shortSHA {
		return sha[:shortSHA]
	}
	return sha
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// code renders text as one inline code span. A multi-line command is joined into one line, and
// a backtick in it widens the fence so the span cannot end early.
func code(s string) string {
	s = oneLine(s)
	if s == "" {
		return "(なし)"
	}
	fence := "`"
	for strings.Contains(s, fence) {
		fence += "`"
	}
	if strings.HasPrefix(s, "`") || strings.HasSuffix(s, "`") || len(fence) > 1 {
		return fence + " " + s + " " + fence
	}
	return fence + s + fence
}

func codes(items []string) []string {
	out := make([]string, 0, len(items))
	for _, s := range items {
		out = append(out, code(s))
	}
	return out
}

// cell keeps a title inside its table cell.
func cell(s string) string { return strings.ReplaceAll(oneLine(s), "|", `\|`) }
