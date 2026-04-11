# OWASP Top 10 — セキュリティレビューチェックリスト

出典: https://owasp.org/Top10/ | https://cheatsheetseries.owasp.org/

---

## A01 — Broken Access Control（アクセス制御の欠陥）

最も発生頻度が高く、全インシデントの筆頭原因。

**チェックポイント**
- すべての保護ルートで認証チェックが行われているか
- オブジェクトレベルの認可（IDOR）: URL の ID を変えて他ユーザーのデータにアクセスできないか
- 機能レベルの認可: 低権限ユーザーが管理 API を直接呼べないか
- CORS 設定が `Access-Control-Allow-Origin: *` になっていないか
- CSRF トークンが状態変更リクエストに必須か

**悪用可能コードパターン**
```python
# NG: ユーザーID をリクエストから直接取得
user_id = request.params['user_id']
data = db.query(f"SELECT * FROM orders WHERE user_id = {user_id}")

# OK: セッションから取得
user_id = session.current_user_id
```

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html

---

## A02 — Security Misconfiguration（セキュリティ設定ミス）

デフォルト設定・不要なサービス・missing セキュリティヘッダーが対象。

**チェックポイント**
- デバッグモードが本番環境で有効になっていないか（`DEBUG=True`, `NODE_ENV=development`）
- デフォルト認証情報が残っていないか（`admin/admin`, `root/root`）
- セキュリティヘッダーの有無: `Content-Security-Policy`, `X-Frame-Options`, `Strict-Transport-Security`, `X-Content-Type-Options`
- エラーレスポンスにスタックトレース・DB 詳細が含まれていないか
- クラウド設定: S3 バケット・GCS バケットが Public になっていないか

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html

---

## A03 — Injection（インジェクション）

SQL・コマンド・LDAP・XSS・NoSQL インジェクションを含む。

**チェックポイント**
- SQL: パラメータ化クエリ（プリペアドステートメント）を使用しているか
- コマンドインジェクション: `exec()`, `system()`, `eval()` にユーザー入力が渡されていないか
- XSS: 出力がコンテキスト（HTML/属性/JS/URL）に応じてエスケープされているか
- NoSQL: MongoDB の `$where`, `$regex` にユーザー入力が渡されていないか
- テンプレートインジェクション: テンプレートエンジンにユーザー入力が直接渡されていないか

**悪用可能コードパターン**
```javascript
// NG: 文字列結合 SQL
const query = `SELECT * FROM users WHERE name = '${req.body.name}'`;

// NG: eval にユーザー入力
eval(req.query.code);

// NG: シェルコマンドにユーザー入力
exec(`ls ${userInput}`);
```

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html
**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html

---

## A04 — Insecure Design（安全でない設計）

実装ではなく設計レベルの欠陥。ビジネスロジックの抜け穴。

**チェックポイント**
- レート制限がログイン・パスワードリセット・API エンドポイントにあるか
- ビジネスロジックの迂回: ステップ 2 を飛ばしてステップ 3 に直接アクセスできないか
- 数量制限の検証: 負の数量・上限超過が拒否されるか
- ワークフローの状態管理: キャンセル済み注文の再実行が防がれているか

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html

---

## A05 — Vulnerable and Outdated Components（脆弱なコンポーネント）

既知の CVE を持つ依存関係。インシデントの 28% がサプライチェーン由来。

**チェックポイント**
- `npm audit` / `pip-audit` / `govulncheck` で Critical/High CVE がないか
- ロックファイル（`package-lock.json`, `poetry.lock`）がコミットされているか
- 直接依存関係だけでなく推移的依存関係も確認

**注意を要する有名 CVE パターン**
- Log4Shell (CVE-2021-44228): Log4j 2.x の JNDI インジェクション
- Spring4Shell (CVE-2022-22965): Spring Framework のデータバインディング RCE
- node-ipc の破壊的コード（2022 年サプライチェーン攻撃）

**参照**: https://nvd.nist.gov/ | https://osv.dev/

---

## A06 — Authentication and Authorization Failures（認証・認可の失敗）

**チェックポイント**
- パスワードハッシュ: bcrypt（コスト≥12）/ argon2 / scrypt を使用しているか（MD5・SHA1 は NG）
- セッショントークン: 暗号学的に安全な乱数で生成されているか
- Cookie 属性: `HttpOnly`, `Secure`, `SameSite=Strict/Lax` が設定されているか
- ログインの失敗回数制限・アカウントロックアウト
- JWT: `alg: none` を受け入れていないか、署名検証を行っているか
- パスワードリセットトークンの有効期限と一回限りの使用

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html
**参照**: https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html

---

## A07 — Software and Data Integrity Failures（整合性の失敗）

CI/CD パイプライン・シリアライズ・更新機能が対象。

**チェックポイント**
- デシリアライズ: 信頼できないデータを `pickle`, `ObjectInputStream`, `YAML.load()` で処理していないか
- CI/CD: サードパーティ GitHub Actions のバージョンが SHA でピン留めされているか（`@main` や `@v1` は危険）
- 署名検証: ダウンロードしたバイナリ・パッケージの完全性を検証しているか

**悪用可能コードパターン**
```python
# NG: 任意コード実行につながる
import pickle
obj = pickle.loads(user_data)

# NG: YAML インジェクション
import yaml
data = yaml.load(user_input)  # yaml.safe_load() を使うべき
```

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html

---

## A08 — Security Logging and Monitoring Failures（ログ・監視の失敗）

インシデントの検知と対応に直結。

**チェックポイント**
- 認証成功/失敗、認可エラー、入力バリデーション失敗がログに記録されるか
- ログにパスワード・クレジットカード番号・PII が含まれていないか
- ログが改ざん不能な場所に保存されるか（攻撃者がログを消せないか）
- 異常検知・アラートの仕組みが存在するか

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html

---

## A09 — Server-Side Request Forgery（SSRF）

サーバーから内部リソースへのリクエストを強制する攻撃。

**チェックポイント**
- URL をユーザー入力から受け取って HTTP リクエストを行う箇所
- `http://169.254.169.254/` (AWS IMDSv1) などのクラウドメタデータへのアクセスが防がれているか
- リダイレクトの追跡が内部 IP に誘導されないか
- DNS リバインディング攻撃への対策

**悪用可能コードパターン**
```python
# NG: ユーザー指定 URL への無制限フェッチ
url = request.params['url']
response = requests.get(url)  # 内部サービスを叩ける
```

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html

---

## A10 — Cryptographic Failures（暗号化の欠陥）

**チェックポイント**
- 保存時: 機密データ（パスワード除く）が AES-256-GCM 以上で暗号化されているか
- 転送時: TLS 1.2+ を強制しているか（HTTP へのフォールバックがないか）
- アルゴリズム: DES・3DES・RC4・MD5・SHA1 を暗号化・署名目的で使用していないか
- 乱数: セキュリティ目的で `Math.random()` / `random.random()` を使用していないか
- 鍵管理: ハードコードされた暗号化キーがないか、鍵のローテーション機構があるか

**参照**: https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html
