# ディスクと取得先の対応付け

2026-10-15。SMART・Direct FTL・NANDプロフィールを、選択中の内蔵ディスクと同じ取得先に関連付ける。
MacBook、mini、iMac、Studioの名前や容量からコントローラ数を固定しない。

## 調査の根拠と限界

- [Apple：Mac Studio 2023 SSD Modules](https://support.apple.com/en-us/104013)は、容量による1／2モジュール構成と接続位置00／01を説明する。これは独立したBSDディスクやFTL取得先の数の根拠ではない。
- [iFixit：MacBook Pro M1／M2の分解比較](https://www.ifixit.com/News/71442/tearing-down-the-14-macbook-pro-with-apples-help)、[iMac M1](https://www.ifixit.com/Teardown/iMac+M1+24-Inch+Teardown/142850)、[Mac mini 2024](https://www.ifixit.com/News/104302/all-hail-the-return-of-upgradeable-storage-mac-mini-2024-teardown)は、NANDパッケージとモジュールの違いを確認する資料。パッケージ数をSSD台数へ変換しない。
- [LinuxのApple ANSドライバ](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/apple.c)は公開の外部解析。macOSのprivate FTL key・集計範囲を全機種で検証した資料ではない。

## 選択と再検査

1. 選択中の物理ディスクのBSD名、またはSMART用IOServiceパスを起点にする。APFSの合成ディスクやpartitionを物理ディスクとして選択しない。
2. IOServiceの親をたどり、NVMe SMARTサービスとApple ANSコントローラを対応付ける。列挙順による「最初の候補」は使用しない。
3. 同じサービス配下の物理Whole IOMediaを数える。AppleAPFS／AppleRAID系の合成メディアは除く。複数namespace、または同じANSコントローラ配下の複数SMARTサービスはFTLの集計範囲が未確認であるため関連付けを保留する。この場合もディスク自体を識別できれば、SMARTと温度の履歴は記録を継続する。配下をたどるのはApple ANS配下のサービスのみで、外付けなど他社のNVMeはたどらない（配下の多い外付けドライブが、内蔵SSDの対応付けを停止させないようにするため）。
4. C probeへSMARTサービス・コントローラ・Whole Mediaの3つのregistry IDを渡す。probeはApple ANS配下、3つの対応、物理Whole Mediaが1つであることを確認してから固定のFTLメソッドを呼び出す。
5. metadataの3つのIDをParser／保存前にも照合する。取得先不一致や消失は拒否し、別候補へフォールバックしない。保存の直前に取得先の情報そのものが無い場合も、照合を省かずに保存しない。単独のCLI実行で指定がない場合も、候補が一意でなければ呼び出さない。
6. 研究用のsnapshot probeは取得先のIDを受け取らない。そのため、Apple ANSコントローラが1つのみの場合に限って開き、複数ある場合は呼び出さない。

registry IDは再起動までの実行時アドレスであり、履歴系列の永続キーにしない。
旧probe metadata／旧JSONは引き続き読み取れる。旧取得物に新しいbindingを補完しない。
既存のcore／researchの対応表、境界lane、SMART照合、権限・署名制約は維持する。
FTL／Host／NAND／geometry／P/Eを複数候補間で自動合算しない。

## IORegistryと履歴

プロフィールは対応付けたコントローラ、またはそのSMARTサービスのController Characteristicsから取得する。
キャッシュはmodel名ではなく、このbootの対応付けをキーにする。別対象へ変更された場合はfresh identityと以前のプロフィールを除外する。
通常のプロフィール取得間隔は変更せず、取得先の確認は軽量な公開IOKit APIで行う。

シリアルがある場合は既存の系列キーを維持する。単一SSDのmodel＋capacity fallbackも維持する。
複数のApple SMART取得先があり、シリアルがない場合は、取得可能なWhole Media UUIDで区別する。
永続識別情報がない場合は曖昧な関連付けを保留し、SMARTの現在値は表示するがその更新を既存の履歴へ追記しない。
FTLの対象範囲が曖昧で`binding`を返さない場合も、検出したSMARTサービス数と、選択ディスクの一意なUUIDを識別判定へ渡す。重複UUIDは履歴識別に使用しない。シリアルで区別できる場合はSMART履歴を記録できるが、FTLの対象範囲の保留は解除しない。
過去のmodel＋capacity系列を別デバイスへ自動移行・マージしない。UUIDの存在や永続性が全機種で保証されるとは扱わない。

## 診断と検証

設定の研究画面に対応状態・不足理由を表示する。共有用診断レポートには対応方式・状態・候補数・物理メディア数・範囲のみを記載し、registry ID、BSDパス、UUID、シリアルは含めない。
ローカルのFTL履歴にはOptionalの取得元bindingを保存するが、損耗系列の識別には使用しない。

回帰テストは列挙順変更、別コントローラ、外付け混在、同一対象のalias、複数namespace、APFS合成メディア、循環／重複ID、metadata不一致、旧JSON、レポート匿名化を扱う。
実機検証は明示指定したディスクのみを対象とし、通常テストではprivate FTLを呼び出さない。
複数SSD／複数namespaceの実機検証と、各機種のFTL集計範囲の確認は外部診断資料を待つ。
