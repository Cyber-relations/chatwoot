# トイバコのアプリアイコン

2026-09-14に背景案A「アイボリー」を採用した。C4原画（開いた箱、緑の3点吹き出し、ピンクのカメラ、封筒）の形と色を維持し、LPとアプリで共通の背景付きアイコンを使う。

背景は `#FAF7F2`、角丸の半径は一辺の23%、境界線は `#E9E1D6`。通常のマーク画像は一辺の88%に配置する。横組みロゴは既存ワードマークを維持する。

| 用途 | `overlay/app/public/` 内の資産 |
| --- | --- |
| サイドバー、管理画面、`LOGO_THUMBNAIL` | `brand-assets/toybaco-app-icon-ivory.png`（512px） |
| 明るい背景の横組みロゴ | `brand-assets/toybaco-logo-c4.png` |
| 暗い背景の横組みロゴ | `brand-assets/toybaco-logo-c4-dark.png` |
| 外部サービス向けの全面背景 | `brand-assets/toybaco-app-icon-ivory-1024.png`（RGB、不透明） |
| ブラウザ、ホーム画面、未読通知 | `favicon*`、`apple*`、`android*`、`ms-icon*` |

16px faviconは見やすさのためマーク画像を96%に拡大する。未読通知版には右上のコーラルドットを付ける。Apple、Android、Microsoft用アイコンは全面アイボリーで生成し、OSのマスクに合わせる。角丸PNGの透過部分は四隅の外側だけとする。

`brand-assets/toybaco-mark-c4.png` と `logo_thumbnail.svg` は共通アイコンの互換用URLとして維持する。`logo.svg` と `logo_dark.svg` も対応する横組みPNGと同じ画像を内包する。横組みロゴと初期設定・管理者ログイン画面のfaviconには `?v=ivory-20260914` を付け、更新前のキャッシュを切り替える。

資産はブランド管理側の固定透過原画から一度だけ背景を合成して生成する。再生成の入力に公開済みの背景付き画像を使わない。公開Chatwoot側では `tests/chatwoot-overlay-manifest.tsv` が全overlay資産の内容とファイルモードを固定し、品質ゲートとイメージ公開前に検証する。
