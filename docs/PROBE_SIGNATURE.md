# ASP probe署名検証

[English](PROBE_SIGNATURE.en.md) · [文書の目次](README.md)

## 目的

`asp-ftl-stats-probe` と `asp-snapshot-probe` は、Appleの内蔵SSDコントローラから統計を取得します。`asp-ftl-stats-probe` は手動での再試行の際に、macOSの管理者認証を経てrootとして実行されることがあります（以前の `asp-tunnel-probe` は削除しました）。そのため、取得値の正しさのみでなく、**管理者実行へ渡すバイナリが想定したprobeであること**を実行直前に検証します。

## 実行前の検証

`ASPDirectProbeGenerator` は通常実行と管理者実行の両方で次を確認します。

1. probe名が固定されたenumのいずれかであること。
2. 実行ファイルがアプリバンドルの `Contents/Resources/ASPProbes` 直下にあること。
3. 通常の実行ファイルであり、実行権限があること。
4. `SecStaticCodeCheckValidity` を strict modeで通過すること。
5. 署名のidentifierがprobe名（例: `asp-ftl-stats-probe`）と一致すること。
6. アプリとprobeのTeam Identifierが一致すること。片側のみにTeam Identifierがある場合も拒否する。
7. 管理者実行時はprobeからルートまでのパスがroot所有で、group/otherから書き込み可能でないこと。

いずれかに失敗した場合、probeを起動せず、管理者認証ダイアログも表示しません。FTL allを通常権限で取得できず管理者権限で再試行する場合も、再試行の直前に同じ検証を再度行います。標準の `/Applications` は管理者実行のパス条件を満たさないため、ここにインストールしても管理者での再試行は有効になりません。

## 署名方式の範囲

現在のローカルReleaseビルドは、`CODE_SIGN_IDENTITY` で署名identityが指定されない場合にad-hoc署名を使用します。これは署名後の変更を検出するtamper evidenceとidentifier/path検証を提供しますが、発行者の身元や、ダウンロードしたアプリの配布元を証明するものではありません。利用者が書き込める場所のアプリを置き換えて再署名できる攻撃者は、ad-hoc署名のみでは防げません。

当面の実験版配布はad-hoc署名を使用します。利用者によるGatekeeperの個別許可が必要になる場合があります。配布物の署名検証と初回起動確認はローカルでの起動確認とは別に行います。root所有でない場所からの管理者実行は許可しません。

アプリとprobeのTeam Identifierの一致は現在も実行時に検査します。ただし、特定の発行者のTeam Identifierへの固定ではありません。Developer IDへ移行する場合は、`CODE_SIGN_IDENTITY` にDeveloper ID Applicationの署名identityを指定し、公証の手順と、発行者のTeam Identifierを固定する検証を別途整備します。現行スクリプトでidentityを指定するのみで、公証まで完了するわけではありません。

## ビルド時の検証

`scripts/build-app.sh` は、2本のprobeをprobe名をidentifierとして個別に署名した後、アプリを署名します。いずれもHardened Runtimeを有効にし、署名identityを指定した場合はsecure timestampも付けます。署名後、アプリと2本のprobeへ `codesign --verify --strict` を実行し、Hardened Runtimeが有効であることを確認します。署名が欠けている場合、Hardened Runtimeが無効な場合、ビルドしたMacのホームフォルダまたはリポジトリのパスがバンドルに含まれる場合は、Releaseビルドを成功扱いにしません。アプリの実行ファイルからは、絶対パスを含むデバッグ情報を `strip -S` で取り除きます。

## テスト用例外

fixtureのshell scriptを使用する単体テストに限り、`ASPProbeSignatureVerifier(allowUnsignedForTesting: true)` を明示的に注入できます。この例外はアプリ本体の初期化経路やReleaseバンドルでは使用しません。

## 非対象

- probeの返却値の意味付け、寿命予測の正しさ、ハードウェアの互換性は、この検証では保証しません。
- ad-hoc署名をDeveloper ID署名と呼びません。
- 改ざんされたアプリを修復する処理は追加しません。
- sysdiagnoseの実行、未知opcode走査、probeの自動再実行は行いません。
