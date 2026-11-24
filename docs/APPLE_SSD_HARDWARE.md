# Apple Silicon内蔵SSDのハードウェア（公開情報）

Apple Silicon内蔵SSDについて、公開情報から判明していることを2026年10月時点でまとめたものです。NenRingが各機種のSSDを判別するために使用します。実測の代わりにはならないため、最後の節に、寄稿者の[診断レポート](../README.ja.md)でしか埋められない項目を挙げています。

確度の目安は次のとおりです。

- **高**：値を含むIORegistryの実例がある。
- **中**：分解記事や二次的な報告による。
- **低**：直接閲覧できなかったフォーラムの要約による。

## IORegistryの項目の読み方

| 項目 | 意味 |
|---|---|
| コントローラのクラス | チップではなく**macOSの版**で決まる。参照機（M1）は25G83では `AppleANS3NVMeController`、macOS 27（26A434）では `AppleANS3CGv2Controller`。macOS 26.4のM5とA18 Proの実例もすでに `AppleANS3CGv2Controller`。どちらも親クラスとして `AppleANS2NVMeController` に一致する。Asahi Linuxはどれも `apple,nvme-ans2` と呼ぶが、これは別の命名体系。 |
| `chip-id` | SoCではなく、**NANDパッケージの中にあるMSP（NANDコントローラ）ダイのID**。`S5E` はM1、M1 Pro/Max、A18 ProのMacBook Neoで、`S6E` はM5で見られる。 |
| `msp-version` | MSPのファームウェア。初期のM1の実例は2.8.x、参照機（とNeo）は4.12.2、S6Eは62.10.4。 |
| `firmware-version` | チップではなくmacOSの版に連動する。例：macOS 26.4ではS5E機もS6E機も `2973.100`。 |
| `vendor-name` | NANDのメーカー。`manufacturer-id` の先頭バイト（JEDEC ID）と一致する：0x98はToshiba/Kioxia、0x45はSanDisk、0xECはSamsung、0xADはSK hynix。 |
| `nand-marketing-name` | `<種類>_3d_<世代>_<プレーン数>p_<ダイ容量Gb>` の形。Kioxia/SanDiskは `g<BiCS世代>`、SK hynixは `v<世代>`。BiCS4では `itlc_` で始まる例もある。 |
| `bus-to-msp`・`dies-per-bus`・`num-dip` | パッケージの構成。`num-dip` = ダイ数 × `cau-per-die`。 |
| `package_blocks_at_EOL` | 確認した実例では、総ブロック数のおよそ94〜95%。 |
| SSDの型番 | M1は `AP…Q`、M1 Pro/Max/Ultraは `AP…R`、M2以降とNeoは `AP…Z`。 |

NVMeのSMARTプラグイン（`kIONVMeSMARTUserClientTypeID`）は、`"NVMe SMART Capable" = Yes` の属性を持つノードから開きます。M5ではそれがnamespaceのノード `IOEmbeddedNVMeBlockDevice` で、コントローラのノードで開くと `kIOReturnUnsupported` が返ります（Anodeの報告）。NenRingのFTL probeはクラス名ではなくこの属性で検索し、そのうえで提供元が `AppleANS2NVMeController`（とその派生クラス）であるものに限定するため、この違いの影響を受けません。

NenRingがIORegistryから値を取得するときは、`AppleANS3NVMeController` → `AppleANS3CGv2Controller` → `AppleANS2NVMeController` → `AppleANSNVMeController` の順に検索します。研究用のsnapshot probe（`asp-snapshot-probe`）も親クラスの `AppleANS2NVMeController` で検索します。macOS 27（26A434）の参照機では `AppleANS3CGv2Controller` が検出され、header（0x91）を通常ユーザー権限で取得できました（2026-10-02）。tunnel probeは削除しました。

## 機種別

### M1系

| 機種・容量 | chip-id / MSP / FW | NAND（`nand-marketing-name`） | 構成 | 出典 | 確度 |
|---|---|---|---|---|---|
| MacBook Air M1 256 GB（参照機。クラスは25G83でANS3NVMe、macOS 27でANS3CGv2） | S5E / 4.12.2 / 561.100 → 591 → 591.40.3 | SK hynix `tlc_3d_v6_4p_512`（128層） | 2パッケージ、4ダイ、num-dip 16 | 本機 | 高 |
| M1 256 GB（他の個体） | S5E | Kioxia（KICM232 + KICM225）やSanDisk（SDRGJHI4 × 2）のパッケージも使用されている | 2パッケージ | [danielgontanのNAND一覧](https://danielgontan.es/en/macbook-nand-list/)、[iFixitのM1分解](https://www.ifixit.com/News/46884/m1-macbook-teardowns-something-old-something-new) | 中 |
| MacBook Air M1 512 GB | S5E / 2.8.7 / 1161.40 | Toshiba `itlc_3d_g4_2p_256`（BiCS4 96層） | 17ダイ、dies-per-bus (5,4,4,4) | [ThomasKaiser/Knowledge](https://github.com/ThomasKaiser/Knowledge/blob/master/articles/Exploring_Apple_Silicon_on_MacBookAir10.md) | 高 |
| MacBook Pro 13" M1 1 TB | S5E / 2.8.8 / 2.100.34 | SK hynix `tlc_3d_v5_4p_512`（96層） | 2パッケージ | [khronokernel/DarwinDumped](https://github.com/khronokernel/DarwinDumped) | 高 |
| M1 1 TB・2 TB | — | Kioxia、SK hynix、SanDiskのいずれかのパッケージ（1 TBはKICM229 / H23B4T84 / SDREGJHIH） | 2パッケージ | danielgontan | 中 |
| M1 Pro/Max 512 GB（Mac Studio 512 GBも同じ） | S5E / 2.8.10.2 / 387.100 | Toshiba `itlc_3d_g4_2p_256` | num-bus 8、17ダイ、bus-to-msp (0,0,1,1,2,2,3,3) | [repoman27（AnandTechフォーラム）](https://forums.anandtech.com/threads/apple-silicon-soc-thread.2587205/page-124) | 高 |
| M1 Pro/Max 1 TB（AP1024R） | S5E / 2.8.10.2 / 499.0.9 | SanDisk `itlc_3d_g4_2p_256` | — | [Apple開発者フォーラムの添付](https://developer.apple.com/forums/content/attachment/223df876-aa95-43eb-a3f1-c2a2fa1dab41) | 中（機種は推定） |
| M1 Pro/Max/Ultra 2〜8 TB | — | Kioxia / SK hynix / SanDiskのパッケージ | 4〜8パッケージ | danielgontan | 低〜中 |

M1とM1 Pro/Max/Ultraは、コントローラのクラスもchip-idも同じです。相違はバスの幅のみで、M1は4バス・MSP 2系統、Pro/Maxは8バス・MSP 4系統です。

### M2〜M4

| 機種・容量 | NAND | 構成 | 出典 | 確度 |
|---|---|---|---|---|
| MacBook Air M2 256 GB | SK hynix HN3T1BA4GAX170（世代は未確認） | 1パッケージ | [MacRumorsの分解記事](https://macrumors.com/2022/07/18/macbook-air-m2-chip-teardown) | 中 |
| Mac mini M2・MacBook Pro M2 Pro 256〜512 GB | 未確認 | 前世代よりパッケージが少ない | [MacRumors](https://macrumors.com/2023/01/24/m2-mac-mini-256gb-slower-ssd) | 低 |
| MacBook Air M3 256 GB | 未確認 | 128 GB × 2 | [Gigazine](https://gigazine.net/gsc_news/en/20240313-m3-macbook-air) | 中 |
| MacBook Pro 14" M3・M4 512 GB〜2 TB | Kioxia K5A4 / K5A5 / K6B2 / K5A8、またはSK hynix品。SanDiskの報告もある | 2パッケージ | MacRumorsの換装スレッド（要約のみ） | 低〜中 |
| Mac mini M4（着脱式モジュール） | 256 GBは128 GB × 2。換装例ではKioxia K6B2。純正品のメーカーは未確認 | 2パッケージ（表と裏） | [Tom's Hardware](https://tomshardware.com/desktops/mini-pcs/m4-mac-mini-ssd-modded-from-256gb-to-1tb-modder-solders-higher-capacity-nand-to-the-removable-ssd-module)、[iFixit](https://macrumors.com/2024/11/12/ifixit-m4-mac-mini-teardown) | 中 |

M2・M3・M4の `chip-id` や `nand-marketing-name` を含むIORegistryの実例は、公開情報では確認できませんでした。

### M5とA18 ProのMacBook Neo

| 機種・容量 | クラス / chip-id / MSP / FW | NAND | 構成 | 出典 | 確度 |
|---|---|---|---|---|---|
| MacBook Neo（A18 Pro）256 GB | ANS3CGv2 / S5E / 4.12.2 / 2973.100 | Toshiba `tlc_3d_g5_2p_512`（BiCS5） | 4ダイ、EOLブロック12560 | [公開されたIORegistryダンプ集のミラー](https://github.com/timb-machine-mirrors/dmaynor-apple-vuln-research)（二次資料。元のリポジトリの所在は未確認） | 高 |
| MacBook Neo 512 GB | 同上 | SanDisk `tlc_3d_g5_2p_512` | 8ダイ、EOLブロック25120 | 同上 | 高 |
| MacBook Air M5 1 TB | ANS3CGv2 / **S6E** / 62.10.4 / 2914.80 | Toshiba `tlc_3d_g8_4p_1024`（BiCS8 1 Tbと推定） | 8ダイ、EOLブロック20672、2パッケージ | 同上 | 高 |
| MacBook Air M5 1 TB（別の個体） | ANS3CGv2 / S6E / 62.10.4 / 2973.100 | Samsung `tlc_3d_g7_4p_1024`（世代は未確認） | EOLブロック16720 | 同上 | 高（世代は未確認） |
| MacBook Pro M5 Pro 1 TB | ANS3CGv2 | 8ダイ、cau-per-die 4、ブロックあたり7704ページ | — | [noahahoward/Anode](https://github.com/noahahoward/Anode) | 中 |

同じM5 MacBook Airの型番でも、KioxiaとSamsungのNANDが混在していました。機種からNANDを推定することはできません。

発売の流れ：

- 2025年10月：M5 MacBook Pro。SSDは約6.3 GB/s。
- 2026年3月：M5 Pro/Max MacBook ProとM5 Air。
- 2026年8月：Mac Studio M5 Max/Ultra。
- 2026年9月：Mac mini M6 / M5 Pro。NANDはロジックボード直付けに戻った。

## SMARTの振る舞い

- **取得できる項目**：smartctlではPercentage Used（整数）、Available Spare（Apple Siliconでは閾値**99%**）、Data Units Read/Written、Power Cycles、Power On Hours、Unsafe Shutdownsが取得できます。エラーログは取得できません（`GetLogPage failed`）。
- **閾値10%**：Intel／T2時代のApple SSDでのみ見られます。
- **M5のPercentage Used**：M5 Pro 1 TBで、7.31 TB書き込んでも0%のままだったという報告があります（Anode）。
- **2021年のM1損耗騒動**：書き込みが多すぎるという報告は、macOS 11.4のカーネル修正で解消しました。その後の調査では、M1機の大半は0〜6%でした（Hector Martin、[HN 2022](https://news.ycombinator.com/item?id=33024863)）。
- **WAF**：Apple SiliconのMacで、WAFやNANDとHostの書込量を公開している例は確認できませんでした。NenRingの参照機の値（WAF約1.6、TLC書込はHostの約0.66〜0.67倍）が、現時点では唯一の実測です。
- **asptoolやsysdiagnoseのASP統計**：M2〜M5で使用できている公開の証拠はありません。

## 診断レポートで埋める項目

1. M2・M3・M4（全バリエーション）のコントローラのクラス、`chip-id`、`msp-version`、`Controller Characteristics` 全体。
2. 機種・容量ごとの実際の `nand-marketing-name` とメーカー（同じ機種でもメーカーが混在するため）。
3. Mac mini M4の純正モジュール（Appleの部品番号661-43668〜661-43671）。
4. M5 Pro/Max/UltraとM6のchip-idとNAND。
5. M2以降でNVMeのSMARTプラグインとDirect FTLが使用できるか。使用できる場合の、TLCとpSLCのEOLサイクル数と仮想ブロック数。
6. 他のメーカーや容量での、WAF、TLC書込/Host、pSLC書込/Host。
7. Samsungの `g7` やSK hynixの176層・238層が、どの文字列になるか。`package_blocks_at_EOL` とP/E定格の対応。
8. Available Spareの閾値が99%以外になるApple SiliconのMacがあるか。
