# staging エージェントログイン

quality / エージェントが staging の E2E `admin_a` セッションを取るための、
**staging 専用**ワンショット経路。Chatwoot の通常ログイン画面とパスワードを
チャットに出さない。inbound SES 作業とは独立。

対象ユーザーは fixture の `admin_a` だけ。

- メール: `back.together0607+toybaco-e2e-admin-a@gmail.com`
- Chatwoot `account_id`: `1`
- 経路: `GET` / `POST` `https://app.staging.toybaco.jp/toybaco/agent-login`

## ガード（fail-closed）

次のどれかに当たれば **404**。本番では有効化しない。

| 条件 | 結果 |
| --- | --- |
| Host が `app.toybaco.jp` | 常に 404 |
| `FRONTEND_URL` が `https://app.toybaco.jp` | 常に 404（Host 偽装でも閉じる） |
| Host が exact `app.staging.toybaco.jp` | 許可（staging ECS は `RAILS_ENV=production` でも可） |
| `TOYBACO_AGENT_LOGIN=1` かつ Rails が production 以外 | ローカル / 契約テスト用 |
| 上記以外の Host | 404 |

`app.toybaco.jp` と本番アカウントでは、フラグを立てても開かない。

## 秘密の置き場

AWS Secrets Manager（東京、staging アカウント `847883042333`）:

- 正本: `toybaco/staging/e2e-admin-a`
- 別名を使う場合: `toybaco/staging/agent-login`（アプリは `TOYBACO_AGENT_LOGIN_SECRET_ID` で切替）

JSON 形（値はここに書かない）:

```json
{
  "token": "<openssl rand -hex 32>",
  "email": "back.together0607+toybaco-e2e-admin-a@gmail.com",
  "account_id": 1
}
```

任意で `"one_shot": true` を付けると、共有 token も Redis で一回限り消費する。
通常の共有 token は再利用可。`v1.<exp>.<nonce>.<hmac>` 形式は 15 分・一回限り。

本文は PR・ログ・チャットに出さない。テストは double だけを使う。

アプリは起動時 ENV `TOYBACO_AGENT_LOGIN_SECRET_JSON`（テスト / 注入用）を優先し、
無ければ Secrets Manager `GetSecretValue` を読む。ECS タスクロールへ
`secretsmanager:GetSecretValue` をこの secret ARN だけへ足す作業は、
この draft では apply しない。

## PM / quality の使い方

staging SSO プロファイルで、同じ作業シェルから読む。パスワードは出さない。

```bash
set -Eeuo pipefail
umask 077
export AWS_PROFILE=toybaco-staging-sso
export AWS_REGION=ap-northeast-1
expected_aws_account=847883042333
actual_aws_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "$actual_aws_account" == "$expected_aws_account" ]] || {
  echo 'aws_account=NO-GO'
  exit 78
}

secret_json="$(aws secretsmanager get-secret-value \
  --secret-id toybaco/staging/e2e-admin-a \
  --query SecretString \
  --output text)"
token="$(printf '%s' "$secret_json" | jq -er '.token')"
unset secret_json

# ブラウザで開く。token をチャットへ貼らない。
open "https://app.staging.toybaco.jp/toybaco/agent-login?token=${token}"
```

成功すると Devise/Warden セッションと `cw_d_session_info` を置いて `/app/` へ 303 する。
失敗（本番ホスト・token 不一致・ユーザー不在）は区別せず 404。

15 分の署名付きワンショットが必要なときは、同じシェルで `token` を HMAC 鍵にして
`v1.<unix_exp>.<hex_nonce>.<hex_hmac>` を組み、query の `token=` に渡す。
`hmac` は `HMAC-SHA256(token, "v1|<exp>|<nonce>")`。

## やらないこと

- production への dispatch / bake / 昇格
- GitHub Environment secret の共有
- 平文パスワードを issue / PR / チャットへ書く
