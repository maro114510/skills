# specialist の再起動

Step 4（go deeper）または Step 5（force-investigate）で specialist を再起動するときに読む。

Agent 呼び出しはデフォルトでステートレスであり、再起動は同一 Agent の続行ではなく新規の独立した Agent 起動である。
そのため再起動時は「go deeper」または「force-investigate」の追加指示だけでなく、diff・specialist の役割定義・Step 3 で与えた関連コンテキストを含む元のプロンプト全体と、その specialist 自身がそれまでに返した候補一覧を併せて再送する。
