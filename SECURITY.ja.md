# セキュリティポリシー

[English](SECURITY.md)

NenRingはAppleの非公開インターフェースを通じてストレージの統計を取得します。root権限で動作することがあるのは、FTLの統計を取得するprobe 1つのみです。手動の取得が権限不足で拒否され、macOS標準の管理者認証を許可した場合に限ります。セキュリティに関する報告を歓迎します。

## 脆弱性の報告

GitHubで非公開に報告してください。このリポジトリの **Security → Report a vulnerability** から送信できます。脆弱性の詳細、認証情報、診断資料を公開のIssueへ記載しないでください。

このボタンが表示されない場合は、詳細を記載せずに「Security contact request」という題で公開のIssueを作成してください。管理者が非公開の連絡方法を用意します。

報告にはmacOSのバージョンとビルド、NenRingのコミットまたはバージョン、再現の手順を含めてください。7日以内の受領の連絡を目標にしています。

## 対象範囲

対象：

- `NenRing.app/Contents/Resources/ASPProbes` に同梱する2本のprobe。`scripts/asp-ftl-stats-probe.c` と `scripts/asp-snapshot-probe.c` からビルドします。`asp-ftl-stats-probe` がrootで動作するのは、手動の管理者再試行の場合のみです。`scripts/asp-smart-export-probe.c` は研究用で、同梱していません。
- 管理者として起動する経路（`ASPDirectProbeGenerator`）。`osascript` で `do shell script … with administrator privileges` を実行します。
- probeの署名と配置場所の検証（`ASPProbeSignature`。[docs/PROBE_SIGNATURE.md](docs/PROBE_SIGNATURE.md) を参照）。
- 利用者が「設定 → 研究」から読み込む `asptool_snapshot.log` の解析（`ASPToolSnapshotCollector`）。NenRingが `asptool` を実行することはありません。ログはDirect FTLとの照合のみに使用し、寿命予測には使用しません。
- sysdiagnoseからの `asptool_snapshot.log` の読み込み（`SysdiagnoseTerminalLauncher`・`SysdiagnoseASPToolLocator`）。アプリは `sudo /usr/bin/sysdiagnose` を記述した `.command` ファイルをターミナルで開きます。管理者認証は利用者がターミナルで行い、アプリ自身は管理者権限で実行しません。完了後、`/private/var/tmp` にある `sysdiagnose_` で始まる最新の `.tar.gz` から、`/usr/bin/tar` でこのログのみを `~/Library/Caches/io.github.mugisk.NenRing/asptool-imports/` に展開します。元のアーカイブは変更しません。
- `~/Library/Application Support/NenRing/` 以下のローカルデータの扱い。

対象外：損耗や寿命の推定の正確さ、smartmontools自体の不具合。

## 現在の安全対策

- **所定のprobeのみ**：アプリが起動できるのは、所定の一覧のprobeと所定の引数のみです。利用者が指定したopcodeやシェルの文字列を渡すことはなく、opcodeの総当たりもしません。
- **起動のたびの検証**：probeを起動する前に、アプリバンドルの中の決まった場所にあることと、コード署名が期待する識別子で厳格な検証を通過することを確認します。
- **管理者で実行するときの、より厳しい検証**：probeから `/` までのすべてのディレクトリがroot所有であり、グループとその他のユーザーのいずれも書き込めないことが必要です。そのため、グループが書き込める標準の `/Applications` に置いたアプリでは、管理者probeは拒否されます。
- **macOSのビルドの検証**：2本のprobeとも、未確認のmacOSでは `--allow-unreviewed-build` が必要です（確認済みは26・27）。アプリがこの指定を渡すのは、手動実行、macOS 14・15でのFTL `all`の互換性の試行としての定期取得、その他のリリースでSMARTとの照合を通過した後のFTL定期取得です。この試行によって確認済みの範囲が広がることはなく、snapshot header／payloadの自動取得も行いません。自動のFTL取得は通常の権限のみで行い、保存前の照合と、予測入力の境界の検査を維持します（macOS 14・15で境界検査が検出するのは値の急な変化のみです。「既知の制限」を参照してください）。
- **Appleのコントローラのみ**：2本のprobeともAppleの内蔵NVMeコントローラ（`AppleANS2NVMeController` とその派生クラス。macOS 26の `AppleANS3NVMeController`、macOS 27の `AppleANS3CGv2Controller` など）のみを開きます。他社製のNVMeに非公開の呼び出しを送ることはありません。アプリも、選択中のドライブがApple内蔵ストレージでなければ、手動のprobe実行を受け付けません。
- **FTL取得先の確認**：アプリは選択中のドライブに対応する3つのIORegistry ID（SMARTサービス、ANSコントローラ、ディスク全体を表すWhole Media）をprobeに渡します。probeは、非公開のFTLインターフェースを開く前に、これらのIDが現在のIORegistryの構成と一致し、Whole Mediaが1つのみであることを確認します。条件を満たさない場合はFTLを呼び出さずに終了し、別のドライブで代わりに取得することはありません。取得後には、probeが報告したIDが渡したIDと一致することをアプリが確認し、一致しない結果は使用しません。IDを指定せずにprobeを単独で実行した場合は、対象となり得るApple内蔵ストレージが1つのみのときに限り取得します。IORegistry IDは再起動等で変動する可能性があるため、履歴の識別には使用しません。
- **保存前の照合**：Direct FTLは取得のたびに同じデバイスのSMART Host Writesと照合し、比較用の資料がある場合はPOHの差の急変と逆行も検査します。照合が一致しない場合は保存せず、自動取得を直ちに停止します。通常の取得失敗の場合は、3回連続で失敗した時点で定期取得を停止します。必須の値が不足する場合は保存を保留し、任意のPOH資料が不足する場合はその比較を「比較待ち」とします。損耗率の補助観測は停止条件にしません。検査範囲と限界は[照合の仕様](docs/DIRECT_FTL_CROSS_VALIDATION.md)を参照してください。
- **管理者実行の終了コード**：probe自身の終了コードを管理者実行の出力から読み取ります。読み取れない場合は失敗として扱います。
- **rootでの安全なファイル操作**：rootで動作するprobeは `O_NOFOLLOW` で開いたディレクトリのファイルディスクリプタからファイルを作成し、`openat(O_EXCL)` と `fchown` を使用します。途中でパスをシンボリックリンクに差し替えられても、書き込み先や所有者の変更を乗っ取られることはありません。
- **時間の上限**：各probeは別のプロセスとして、厳しい時間の上限付きで動作します。

## 既知の制限

- `CODE_SIGN_IDENTITY` を設定しない限り、ローカルのビルドはad-hoc署名です。ad-hoc署名は改ざんを検出できますが、誰がビルドしたかは証明しません。
- GitHub Releasesの配布版はアドホック署名のみで、Appleの公証を受けていません。
- プロジェクトが確認していないmacOSのリリースでは、最初のDirect FTLの取得は、そのリリースで構造を確認していないインターフェースへの呼び出しになります。macOS 14・15の互換性の試行を除き、この最初の取得は必ず利用者が開始し、SMARTとの照合を通過した後でのみ定期取得に移行します。
- macOS 14・15では手動の最初の取得なしに定期取得を開始し、毎回のSMARTとのHost書込量の照合を通過した値を寿命予測に使用します。境界の連続性の確認で検出できるのは値の急な変化のみです。これらのリリースで非公開の値の意味が異なっていても検出できず、初めて使用する際は比較する過去の記録もありません。
