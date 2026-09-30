# CASA ログアウト時のブラウザー保存データ削除

通常ログアウトがIndexedDBの削除要求だけを出して直ちに遷移し、401・メール変更の共通処理はIndexedDB削除を通らなかったため、共通の完了待ち処理へ統合する。

- サーバーのlogout応答成功、または既に失効している401の後に、認証Cookieと下書き・返信先・検索履歴・widget設定・impersonation状態を消す。500や通信失敗をサーバー失効成功と扱わない。
- 全DataManagerの接続を閉じ、遅れて完了するopenや通信からキャッシュを再生成させない。
- `cw-store-` のDBだけを対象に、列挙結果・追跡リスト・開いていたDB名を結合し、各deleteDatabaseのsuccessを待つ。他アプリのDBを削除しない。
- 別タブへstorage event/BroadcastChannelで通知する。処理中はアプリを覆って操作を停止し、ログイン情報の再設定を拒否する。
- 削除エラーや5秒を超えるブロックは成功へ読み替えず、追跡リストと未完了markerを残す。再試行ボタンと次回読み込みで再開する。markerにユーザー情報・認証情報を保存しない。
- DB列挙非対応では追跡リストを使う。追跡リストも壊れていて対象を確認できない場合は失敗として保持する。

合成IndexedDBと分離したタブcontextで、削除完了待ち、別タブblock/retry、遅れたopen、削除error、列挙fallback、破損registry、列挙timeout、別タブ通知、reload、HTTP401/500の10シナリオを検証する。既存cache-upgradeテストも維持し、双方をイメージのasset build前に組み込む。

これはブラウザー側の是正。一般認証のHttpOnly/CSRF、全サーバーtoken失効、Postiz連動、全店舗管理者MFA、実ブラウザーの受入、認証済みDAST、第三者評価は別の残作業。配備前のローカル検査を本番完了・CASA合格にしない。
