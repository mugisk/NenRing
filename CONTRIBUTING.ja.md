# NenRingへの参加

[English](CONTRIBUTING.md)

不具合の報告、他のMacからの診断レポート、プルリクエストを歓迎します。Issueやプルリクエストは英語でも日本語でも構いません。

## 報告

- **不具合**：Issueの **Bug report** テンプレートを使用してください。
- **お使いのMacのデータ**：**Diagnostic report** テンプレートを使用してください（[README](README.ja.md#他環境のデータ提供診断レポート)を参照）。検証に使用したM1 MacBook Air以外のMacからの報告は、取得可能な環境を確認する材料になります。報告のみで寿命予測の正確さを実証できるわけではありません。
- **セキュリティの問題**：公開のIssueは作成せず、[SECURITY.ja.md](SECURITY.ja.md) の手順に従ってください。

Issueと添付ファイルは誰でも閲覧できます。シリアル番号、`ioreg` や `smartctl` の出力全文、sysdiagnoseのアーカイブ、probeの生ファイルは投稿しないでください。

## ビルド

macOS 15.6以降、Xcode 26以降またはそのCommand Line Tools（Swift 6.2とmacOS 26 SDKを含む。Xcode 26.4.1以降はmacOS 26.2以降が必要）、`smartctl`（インストール方法は[README](README.ja.md#smartmontoolsの導入)を参照）が必要です。

```sh
./scripts/swiftpm.sh test     # テストを実行
./scripts/build-app.sh        # build/NenRing.app を作成
```

`swift` を直接実行せず、これらのスクリプトを使用してください。これらのスクリプトはビルドの出力を `build/swiftpm`、`build/swiftpm-cache`、`build/NenRing.app` に集約し、自身が作成した一時フォルダのみを削除します。

## プルリクエストの前の確認

プルリクエストでは、GitHub Actionsが同じ確認をmacOS 26で実行します。プルリクエストを作成する前に、手元でも次を実行してください。

```sh
./scripts/ci-local.sh
```

テストの実行、リリース版アプリのビルド、アプリと同梱の2つのprobeの署名確認を行い、最後に `LOCAL CI PASSED` と表示します。出力の末尾の数行をプルリクエストに貼り付けてください。確認後に変更を加えた場合は、変更後のコミットで再度実行してください。画面を変更した場合は、スクリーンショットも添えてください。

## 方針

- **変更は1つの話題に絞る**：1つのプルリクエストには1つの話題のみを含めてください。周囲のコードの命名や記述方法に合わせ、動作を変更した場合はテストも追加・更新してください。
- **文書**：README、SECURITY、THIRD_PARTY_NOTICES、この文書と、[目次](docs/README.md)に挙げた入門文書には日英版があります。内容を変更した場合は両方を修正してください。詳細な研究仕様は当面日本語のみとし、その旨を英語の目次に明記しています。現在の動作は現行の仕様に記載してください。過去の設計案のみに追記しないでください。
- **Appleの非公開インターフェース**：NenRingが行うのは読み取りのみで、[docs/DATA_ACQUISITION.md](docs/DATA_ACQUISITION.md) に記載した所定の呼び出しのみを使用します。新しい非公開の呼び出しやopcode、SSDコントローラへ書き込む処理を追加する場合は、先にIssueで相談してください。opcodeや関数の総当たりは行わないでください。
- **自分のデータはローカルに**：実際の履歴ファイル、probeの取得物、シリアル番号を含むものはコミットしないでください。テストには架空のデータを使用します。
- **アイコンとロゴ**：`Resources/NenRingIcons/` の画像にはMITライセンスが適用されません（[利用条件](Resources/NenRingIcons/LICENSE.md)を参照）。改変版を配布する場合は、ご自身の画像に差し替えてください。

## ライセンス

参加いただいた内容は他のソースコードや文書と同じく [MITライセンス](LICENSE) で提供されることに同意したものとします。

NenRingをもとにした改変版やプロジェクトを配布する場合は、NenRingをもとにしていることを記載してください。
