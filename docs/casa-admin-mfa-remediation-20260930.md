# CASA 管理コンソールの MFA 是正

対象は SuperAdmin 専用ログイン、`/super_admin` 配下と `/monitoring/sidekiq`。
通常の店舗 administrator、一般ブラウザーの HttpOnly/CSRF 移行、Postiz、
認証済み DAST は別に受入を残す。この文書だけで CASA 3.3.1 全体の完了を宣言しない。

固定 Chatwoot v4.18.0 の SuperAdmin ログインはパスワードの照合だけで
Warden session を発行していた。MFA 登録済みフラグは、当該ログインでの
二段階認証が行われた証拠にはならない。

## 変更

- 正しいパスワードと有効な TOTP / 未使用の backup code をともに要求する。
  コードの消費は user row のロック内で行い、既存の MFA secret は変更しない。
- 未登録管理者は管理画面へ入れず、通常のトイバコのプロフィールで登録する案内を表示する。
- Rails session を再生成し、ランダムな nonce と Redis 側の有効期限 12 時間の証拠を結合する。
  Cookie の値だけでは管理画面・CSV・Sidekiq に到達できない。
- ログアウトで Redis 側の証拠を削除する。MFA の無効化・secret / password の変更・期限切れ・
  別ユーザーへの置換・証拠ストア障害ではアクセスを拒否する。
- 管理ログインの CSRF を有効にし、フォームの正常系と CSRF なしの否定系を確認する。
- 管理フォームのネストした email をユーザー単位の throttle に結合し、正規化した hash を使う。
  URL のエンコード・重複スラッシュ・拡張子で IP / email 制限を回避できないよう同じ正規化を使う。
- Rails 7.2 の `EXPIRE NX` 最適化と Redis::Namespace の `pipeline.call` の非互換を回避するため、
  Rails が提供する INCRBY/TTL/EXPIRE の処理を使う。既存 pool・namespace・期限を維持する。

## 配備と受入

配備前に本番 SuperAdmin の MFA 登録済み件数、既存 issuer、現行 image / flags を確認する。
配備時に旧 SuperAdmin session は再認証が必要になる。既存 Authenticator の再登録・MFA 解除は不要。

順序は、隔離 fixture 検査 → private/public の必須品質ゲート → signed image → staging 実測 →
現行状態を再確認した標準 production plan/apply → 稼働 digest と受入の記録。
通常のアプリ公開フラグや利用店舗の権利は、この変更を理由に開放しない。

合成データ専用の PostgreSQL/Redis で検証し、実顧客データ・外部投稿・メール送信・課金は使わない。
第三者評価、LoV、Google の最終承認とは区別する。
