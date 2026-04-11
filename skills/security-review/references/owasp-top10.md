# OWASP Top 10 — セキュリティレビューリファレンス

出典: https://owasp.org/Top10/ | https://cheatsheetseries.owasp.org/

**読み方**: SKILL.md の Step 2 でカテゴリを特定してから該当セクションのみを参照すること。
全セクションを読む必要はない。

## 目次（クイックリファレンス）
- [A01 アクセス制御](#a01)
- [A02 設定ミス](#a02)
- [A03 インジェクション](#a03)
- [A04 安全でない設計](#a04)
- [A05 脆弱なコンポーネント](#a05)
- [A06 認証失敗](#a06)
- [A07 整合性の失敗](#a07)
- [A08 ログ・監視の失敗](#a08)
- [A09 SSRF](#a09)
- [A10 暗号化の欠陥](#a10)

---

## A01 — Broken Access Control {#a01}
> **対象差分**: アクセス制御・API エンドポイント・CORS 設定の変更

**危険パターン（差分の追加行で探す）**
```python
# NG: URL パラメータの ID をそのままDBクエリに使用 → IDOR
user_id = request.params['user_id']   # セッションから取るべき
data = db.query(f"... WHERE id = {user_id}")

# NG: 管理者確認なしの管理機能
@app.route('/admin/delete')           # 認証ミドルウェアがない
def admin_delete(): ...

# NG: CORS で全オリジン許可
Access-Control-Allow-Origin: *        # 認証情報を扱うAPIに設定されている
```

**チェックポイント**
- 新規エンドポイントに認証ミドルウェアが適用されているか
- リソース取得時にオーナー確認（`user_id == session.user_id`）があるか
- CSRF トークンが POST/PUT/DELETE に必須か

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html

---

## A02 — Security Misconfiguration {#a02}
> **対象差分**: 設定ファイル・インフラ定義・デプロイ設定の変更

**危険パターン**
```python
app.run(debug=True)           # 本番環境でデバッグモード
NODE_ENV=development          # 本番設定ファイルに混入
```

**セキュリティヘッダー（削除・弱体化を検出）**
- `Content-Security-Policy` — XSS 軽減
- `Strict-Transport-Security` — HTTPS 強制
- `X-Frame-Options` — クリックジャッキング防御
- `X-Content-Type-Options: nosniff`

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html

---

## A03 — Injection {#a03}
> **対象差分**: SQL・コマンド・テンプレート・DOM操作の変更

**危険パターン（追加行で探す）**
```python
# SQL インジェクション
query = f"SELECT * FROM users WHERE name = '{name}'"   # NG
db.execute("... WHERE name = ?", [name])               # OK

# コマンドインジェクション
subprocess.check_output(f"ls {user_input}", shell=True)  # NG
subprocess.run(["ls", user_input])                        # OK

# XSS
element.innerHTML = userInput          # NG
element.textContent = userInput        # OK
```

**JavaScript/TypeScript で特に注意**
- `eval(userInput)` — 任意コード実行
- `dangerouslySetInnerHTML={{ __html: input }}` — XSS
- テンプレートリテラルでのHTML生成

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html

---

## A04 — Insecure Design {#a04}
> **対象差分**: ビジネスロジック・ワークフロー・数量処理の変更

**チェックポイント**
- ログイン・パスワードリセット API にレート制限があるか
- ステップをスキップして次のフローに直接アクセスできないか
- 負の数量・上限超過が拒否されるか（eコマース系）
- 支払い完了前にリソースが提供されないか

---

## A05 — Vulnerable Components {#a05}
> **対象差分**: package.json・requirements.txt・go.mod の変更

新規追加・バージョン変更されたパッケージのみ確認する。
既知 CVE の確認: https://osv.dev/ または https://nvd.nist.gov/

---

## A06 — Authentication Failures {#a06}
> **対象差分**: 認証・セッション・JWT・パスワード処理の変更

**危険パターン**
```typescript
// JWT 署名未検証
jwt.decode(token)         // NG: 署名を検証しない
jwt.verify(token, SECRET) // OK

// 弱いシークレット
const JWT_SECRET = "secret"    // NG: 辞書攻撃で即座に解析可能

// 平文パスワード
password === user.password     // NG: 平文比較 → 平文保存を示唆

// 弱いハッシュ
crypto.createHash('md5').update(pw)  // NG: レインボーテーブルで解析可能
bcrypt.hash(pw, 12)                  // OK: コスト12以上
```

**追加チェック**
- パスワードリセットトークンに有効期限があるか
- ログイン失敗のレート制限があるか
- セッション Cookie に `HttpOnly`, `Secure`, `SameSite=Strict/Lax` が設定されているか

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html

---

## A07 — Integrity Failures {#a07}
> **対象差分**: デシリアライズ・CI/CD・ビルド設定の変更

**危険パターン**
```python
pickle.loads(user_data)        # NG: 任意コード実行
yaml.load(input)               # NG: yaml.safe_load() を使う
```

**CI/CD（GitHub Actions）**
```yaml
# NG: タグ/ブランチ指定 → サプライチェーン攻撃リスク
uses: actions/checkout@v3
uses: actions/checkout@main

# OK: SHA でピン留め
uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
```

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html

---

## A08 — Logging Failures {#a08}
> **対象差分**: ログ処理・エラーハンドリングの変更

**チェックポイント**
- エラーレスポンスにスタックトレース・DB 詳細が含まれていないか
- ログにパスワード・トークン・PII が出力されていないか
- 認証失敗・認可エラーがログに記録されるか

---

## A09 — SSRF {#a09}
> **対象差分**: HTTP クライアント・URL 処理・外部リソース取得の変更

**危険パターン**
```python
url = request.params['url']
response = requests.get(url)   # NG: 内部サービスを叩ける

# 悪用例: http://169.254.169.254/latest/meta-data/ (AWS IMDS)
```

**チェックポイント**
- ユーザー指定 URL への HTTP リクエスト箇所
- 内部 IP レンジ（10.x.x.x・172.16.x.x・169.254.x.x）のブロック

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html

---

## A10 — Cryptographic Failures {#a10}
> **対象差分**: 暗号化・ハッシュ・乱数・鍵管理の変更

**危険パターン**
```python
# 弱い乱数（セキュリティ目的に使用）
import random; token = random.token_hex()   # NG: 予測可能
import secrets; token = secrets.token_hex() # OK

# 弱いアルゴリズム
AES-ECB, DES, 3DES, RC4   # NG: 暗号化に使用
MD5, SHA1                   # NG: 署名・証明書に使用
```

**チェックポイント**
- TLS 1.2 未満へのフォールバックがないか
- ハードコードされた暗号化キーがないか（シークレットスキャンで検出）
- 鍵のローテーション機構があるか

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html
