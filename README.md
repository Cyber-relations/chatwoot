# トイバコ Chatwoot

トイバコの受信箱で利用するChatwoot Community Editionの日本語化・認証連携・Postiz連携と、再現可能な本番イメージpublisherです。

## 固定している上流

- Chatwoot tag: `v4.17.1`
- source commit: `b354a9550e1fb59fa537a9c384232cb076213e72`
- source tree: `9a17426900d328a6acc2bdaecba0533e8b401120`
- amd64 base image: `chatwoot/chatwoot@sha256:0dcaaacc41ba5219b48af80b236f7707dbd5d58228320950af71a4309c349a7a`

`overlay/app/`がトイバコの変更ソースです。Chatwootの`enterprise/`ライセンス対象コードは含めず、Community Editionだけを対象にしています。

## 品質と公開

`./bin/toybaco-chatwoot-gate --quality-only`は、固定上流へのoverlay適用、日本語UI、認証・テナント連携、RSpec、amd64イメージの起動を秘密情報なしで検証します。

本番publisherは、review済み`main`、GitHub Environment承認、GitHub OIDC、immutable ECR、Critical/HighゼロのECR scan、SPDX SBOM、GitHub Artifact Attestationsを通ったdigestだけを公開します。

秘密情報や長期AWSキーはこのリポジトリへ保存しません。
