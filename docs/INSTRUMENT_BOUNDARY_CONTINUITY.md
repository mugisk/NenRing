# 計測器境界の連続性

実行OS build、probe version、FTL keyの対応表、SSD firmware は、Host/NAND/P-E
という物理量そのものではなく「計測器側の属性」として扱う。新しい取得経路が
現れたときに raw snapshot を破棄したり書き換えたりせず、境界前後の値を検査して
から損耗系列へ接続する。

## metadata と対応表

新しい probe は次の3項目を sidecar に記録する。

```text
build=<実行時の kern.osversion または unknown>
contractBuild=25G83
probeVersion=2
```

`build` は実際に probe を実行した build、`contractBuild` は key の意味を確認した
対応表のbuild であり、同じ意味ではない。後続のOSでも対応表が確認できる限り raw read
は受理し、`runsOnReviewedBuild` として実行build一致の有無を別表示する。

`ASPToolDiagnosticsSnapshot` の `sourceBuild` は互換上のJSON名を維持しつつ、実行
buildを保存する。旧 snapshot の固定ラベルは解析時のみ `LegacyBuildOverlay` で
補正する。firmware 561 系は `25G83`、その他は
`unrecorded-after-fw-<firmware>` として `inferred` provenance を付ける。raw JSON
は変更しない。

## 系列と境界

`ControllerWearSeriesIdentity` は device、source artifact、extraction、core wear
contract、unit、EOL を含む。runtime build と firmware はここから除き、別の
`InstrumentIdentity` として境界記録へ分離する。研究 telemetry は
`researchTelemetryVersion` と runtime buildで分離するが、Host/NAND/P-Eの損耗系列
を研究keyの改訂のみでリセットしない。

`WearContinuityLaneBuilder` が全分析で共通に使用するレーンを生成する。

- `verified`: D1〜D7を通過した境界を跨いで snapshot を採用する。
- `pending`: D1〜D7の必須資料が不足、またはD7不一致のsettling期間内。rawは保持するが、後続区間を率学習へ含めない。表示では「資料待ち」と「落ち着き待ち」を区別する。
- `failed`: D1〜D7の不一致。rawは保持し、同じ新計測器の後続snapshotも検証されるまでコア損耗分析から除外する。

率学習（WAF、書込ペース、損耗バランスなど）から除外する候補になるのは、同じ取得経路で
**ファームウェアのepochが変更された** verified 境界のみである。macOS buildのみの変更や、
取得経路の切り替えは候補にしない。候補の境界は次のいずれかの場合のみ、境界の前の取得から境界の72時間後までを除外する
（`InstrumentContinuity.swift` の学習除外判定）。

- 更新後72時間のWAFが直前7日間のWAFと25%を超えて異なる。
- 判定に使用できるHost書込が1 GBに満たない（判定できるまで除外しておく）。

更新後もWAFが変化しなければ除外しない。除外した区間も、グラフには除外区間として表示する。
物理累積値と長基線残差からは除外しない。SMARTが境界前後で取得できる場合、境界の空白期間に
72時間上限は設けない。SMARTがない場合はD5/D6が保留となる。

## D1〜D8

| ID | 検査 | 条件 |
| --- | --- | --- |
| D1 | geometry | bytes/page・native pages・SLC pagesが境界前後で一致（例: 256 GB機では16384 / 24576 / 8192） |
| D2 | topology | virtual・intermediate・user境界が境界前後で一致（例: 256 GB機では722 / 1 / 80） |
| D3 | EOL | TLC・pSLCのEOL P/Eが正の値で境界前後一致（例: 256 GB機ではTLC 3000、pSLC 100000） |
| D4 | monotonic | Host/NAND、平均・最大P/E、POHが非減少 |
| D5 | SMART Host比 | `FTL Host × 4096 / SMART DUW × 512000` の境界前後変化が0.5%以下（ただし5 GB相当を下回らない）。SMARTは前後24時間以内、両側があれば線形補間 |
| D6 | POH | FTL POHとSMART POHの差の変化が、2時間＋FTLと照合したSMARTの取得時刻差以下 |
| D7 | 生涯残差 | `NAND - (TLC容量×TLC PE + pSLC容量×pSLC PE)` の量子化範囲が交差 |
| D8 | 境界WAF | 直前区間比0.25〜4倍を注記するのみで、連続性のgateにはしない |

D1〜D3は特定機種の値と比較する検査ではない。容量やNAND世代で値は異なるため、境界を跨いで
変化していないことのみを確認する。

D5とD7は単調に増加する別counterへのkeyの取り違えを捕捉する中心検査である。D8の
WAFが大きく変化しても、D1〜D7を通過すれば境界は `verified` とする。

## 表示と検証上の扱い

Researchには全境界の日時、取得経路・runtime build・firmware・対応表の情報の前後、
provenance、変更属性、D1〜D8の状態、率学習除外を表示する。保留が後日再評価された
場合は初回判定と最終判定を同じ境界レコードに保持する。raw snapshotは書き換えない。
「資料待ち」「落ち着き待ち」「検証不一致」「デバイス変更」は状態を区別して示す。
probe／parser版のみの変更のうち同一計測器として吸収されたものも、境界・グラフ線・
率学習除外を生成せず、取得経路と前後の版数を「同一計測器内の変更」として一覧に残す。

書込量・NAND wear・WAFの時系列には表示中の実データ期間に含まれる境界のみを注記
する。凡例は該当境界がある場合のみ表示し、検証済み・落ち着き待ち・資料待ち・
検証不一致・デバイス変更を線種と文字で区別する。境界マーカーのヘルプには前後の
計測条件、provenance、判定結果、D1〜D8、率学習除外を示す。物理デバイス識別子の
生値は表示しない。

7日・30日WAFは名目窓と実際に観測できた日数を区別し、部分窓には実観測日数を表示する。

Write Pace の Lifetime は使用開始日がない場合、保存履歴の平均である。表示は
`保存履歴（N日）`とする。使用開始日を設定すると、この欄は使用開始からの平均になる。到達予測の扱いは設定画面に示す。
Storage Headroom の固定比は物理使用率ではないため、`Logical share of NAND`／
`論理公開比` と「構成値」を使用する。

この変更は新しい sidecar metadata、解析時の legacy overlay、境界レーン、D5/D7、
表示根拠を一つの互換更新として扱う。原始 snapshot、研究ログ、既存履歴は上書き
しない。回帰テストではOS buildのみの更新、firmwareのみの更新、旧firmware推定値から
初回の実build記録への移行を個別に固定し、検証済み境界のみ損耗レーンへ加える。
