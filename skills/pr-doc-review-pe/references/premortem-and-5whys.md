# Premortem and 5-Whys Checklist

## Purpose

設計ドキュメントが暗黙の仮定を持っていないかを、プリモーテム (事前検討) と
5-Whys 根因分析の手法で検査する。
「このプランが失敗したら」を逆算することで、文書内で識別・緩和されていない
リスクを顕在化させる。

## Checklist

**プリモーテム (Klein, HBR 2007)**

1. 「このプランが 6 ヶ月後に失敗したとしたら、最もあり得る理由 3 件は何か」を逆生成する。
2. 逆生成した失敗シナリオがドキュメント内で識別されているかを確認する。
3. 識別されている場合: 緩和策 (mitigation) が具体的に記述されているか。
4. 識別されていない場合: `[must]` または `[ask]` として指摘する (Risk Register への追加を提案)。

**5-Whys 根因分析**

1. 提案の動機 (なぜこの設計が必要か) を起点に Why を 5 回繰り返す。
2. 掘り下げた根本原因と、提案の解決策が対応しているかを確認する。
3. 表面的な症状だけを解決しており根本原因を未解決の場合は `[ask]` で確認する。

**暗黙の仮定の可視化**

- 「これは自明だから書かなかった」が読者に通じない前提になっていないか。
- インフラ・コスト・チーム体制・スケジュール・規制について文書外に依存した前提がないか。
- 前提が崩れたときの設計への影響が記述されているか。

## Anti-patterns

- プリモーテムを「単なる悲観論」として実施しない。
- 5-Whys を 2〜3 回で止め、表面的な原因に留まる。
- 「失敗するとしたら実装ミス」のような実装詳細に話をすり替える。
- 暗黙の前提として「サービスは常に利用可能」「レイテンシは常に低い」を置く。

## Sources

- Gary Klein — Performing a Project Premortem (HBR, 2007)
  https://hbr.org/2007/09/performing-a-project-premortem
- Taiichi Ohno — Toyota Production System: 5-Whys methodology (1978)
  https://www.toyota-global.com/company/vision_philosophy/toyota_production_system/
- arXiv:2504.20781 — Design Rationale auto-generation and assumption detection
  https://arxiv.org/abs/2504.20781
