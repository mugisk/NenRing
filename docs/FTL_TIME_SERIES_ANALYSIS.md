# Direct FTL 時系列解析

## 目的

`ASPToolDiagnosticsSnapshot` に保存された累積値を、後から再計算できる区間観測へ変換する。ここで得る WAF、refresh、read-verify、UECC、bad-block、histogram の差分は、長期観測と研究用の根拠表示であり、TBW 倍率や故障確率を自動変更しない。

## 入力と系列境界

比較対象は `sourceArtifact = directFTL` かつ取得時刻が明示された snapshot のみである。device、Direct format、Host/NAND単位、TLC/pSLC EOL、または `coreWearVersion` の不一致は系列の境界となる。source buildやfirmware epochの変更も境界として記録し、所定の連続性検査を通った場合には損耗系列を接続する。検査を満たさない境界は跨がず、新しいアンカーから再開する。詳細は[計測器境界の連続性](INSTRUMENT_BOUNDARY_CONTINUITY.md)を参照する。
一方、`researchTelemetryVersion` の変更は histogram・refresh・reliability など研究テレメトリ
のみの系列境界であり、Host/NAND/P/E/EOL/topology の損耗系列は切断しない。

v2.4からv2.4.1への互換更新のように研究keyの意味付けのみが変更された場合、境界区間でも
Host/NAND差分と区間WAF、損耗相関は保持する。研究用keyの対応表に依存するhistogram、reliability、
refresh、研究key差分はその境界で比較せず、次の同じ研究用keyの対応表のsnapshotから再開する。
series metadataには `coreWearVersion` と `researchTelemetryVersion` を別々に記録し、
画面やexportでどの対応表が各値を支えたかを追跡できるようにする。旧snapshotに分割した対応表の
フィールドがない場合は、従来の対応表の値を互換的に両方の入力候補として扱うが、新しい意味付け済みの
対応表であるとは表示しない。

Host または NAND の累積値が減少した場合は reset として同じ区間を無効化する。時刻逆転・同秒重複・研究試験との重複も同様に比較アンカーを更新する。旧履歴に `semanticContractVersion` や `identityCapturedAt` がない場合は互換読込みするが、fresh identity や新しい意味付け済み系列とは表示しない。旧履歴の対応表の値は当時のrawデータに対応するcore／researchの対応表を再構成するための互換入力であり、研究keyの更新のみを理由に損耗系列をリセットしない。

## 区間値

各有効区間では raw counter の差分から次を導出する。

- `ΔHost`、`ΔNAND`、`ΔNANDReads`
- `ΔNAND / ΔHost`（Host 差分が正の場合のみ区間 WAF）
- Reduced read verify / NAND read
- Age refresh / selected day、Background refresh / selected day（Power On Hours優先、暦時間fallbackを区間ごとに明示）
- Cross-temperature UECC / NAND read、UECC / NAND read
- Grown bad blocks / selected day
- 終点 TLC P/E を X 軸にした各指標の相関点

新規区間の `durationDays` は、両端で取得できて減少していない `Power On Hours` の差分を 24 で割った稼働日数を優先する。従って、稼働率が低いMacでも、スリープを含む壁時計時間を稼働時間として扱わない。`wallDurationDays` は取得間隔の文脈として別に保持する。`Power On Hours` が欠測・同値・不正、または旧履歴で利用できない場合のみ、明示的な `wallClockFallback` として壁時計日数へ戻し、どの区間がフォールバックしたかを根拠へ記録する。`Power On Hours` の減少は Host/NAND reset と同じ系列境界とする。

Host 差分がゼロでも refresh や read 系 counter の差分は保持する。ただし WAF は計算しない。counter の減少は 0 に置換せず、その項目または系列を比較不能とする。

区間 WAF (`ΔNAND / ΔHost`) は表示用の記述値に留めず、同じ区間終点の TLC／pSLC P/E 相関点にも含める。これにより、主予測が使用する Host 換算分母に対応する観測を、P/E進行との相関でも追跡できる。相関は因果や確定した寿命係数を意味せず、Host 差分が正で単位・系列が有効な区間のみを対象にする。

## 区間残差と refresh の照合

同じ Direct topology が区間の両端で得られ、平均 P/E と domain 容量が有効な場合は、既知 domain の NAND 増分を次で再構成する。topologyの比較では、対応表の版の文字列が異なるのみでなく、区画境界・geometry・virtual blockの値が変化したかを確認する。研究用keyの対応表のみが更新された場合は、値が同じtopologyを同一構造として扱う。

```text
knownDomain = TLC容量 × ΔTLC平均P/E
            + pSLC書込可能容量 × ΔpSLC平均P/E
signedResidual = ΔNAND − knownDomain
```

`signedResidual` は未同定の NAND 増分として保存し、`ageRefresh`、`backgroundRefresh`、`bandsPaddedForAge`、`bandsRefreshedOnError` の同一区間差分を隣接表示する。残差を band 0、Utility、TLC、pSLC、または予算へ割り当てない。refresh との近接は原因候補を調査するための研究用の照合であり、refresh が残差の原因だと自動確定しない。topology、P/E、容量のいずれかが欠ける場合も、既知 NAND の再構成や残差を 0 で補完しない。

現在の意味付け済み keyの対応表は `25G83-ftl-all-research-v2.4.1`（`DirectFTLResearchContract.latest`）とする。互換読み込みのため旧い対応表の名前は残すが、新規 snapshot と解析結果は `latest` を使用する。レビュー済みのmacOSメジャーバージョン（macOS 26・27）以外の build、または対応表の版が対象外になった場合は解析値を無理に生成せず、「未検証」という予期された状態として表示する。

## Histogram

histogram の時間意味論は `opaqueSnapshot`、`cumulativeCandidate`、`verifiedCumulative` の3状態で保持する。現在の25G83の対応表は単調性のみを確認した `cumulativeCandidate` であり、同じ要素数で各 bin が減少しない場合に限って実験用の差分を生成する。verifiedの対応表を明示的に与えない限り、差分をP/E相関や主予測へ投入しない。`opaqueSnapshot` は差分自体を生成しない。

bin 番号は private buffer の opaque index として保存し、摂氏や累積 histogram の意味へ変換しない。空配列、全 bin 0、overflow、形状不一致を区別する。p50/p90/p99、最終非ゼロ bin、任意の tail 集計は差分配列の記述値であり、累積値・物理温度・保持特性を意味しない。

## Reliability

比較可能な区間で増加した cross-temperature UECC、UECC、read-verify failure、grown bad blocks、die failures はイベント履歴へ保存する。イベントは点時刻ではなく `intervalStart`、`intervalEnd`、`detectedAt` を持ち、温度も区間内の min/avg/max/sampleCount を保持する。区間内に温度がない場合は終点から±30分以内の近接値のみを `nearest fallback` として表示し、正確な発生温度とは扱わない。Pfail、Efail、error refresh、open-band read fail、offline blocks は keyの対応表が確認されるまで semantic event として推測しない。

イベントは `ftl-reliability-events.jsonl` へ独立保存する。raw snapshot のcompactionとは分離し、Reliability Event Journal自体は上限なしで永久保持する（利用者がApplication Supportのファイルを明示的に削除した場合を除く）。同一イベントはdevice・firmware・contract・区間・種類・deltaによるidentity dedupeで重複保存しない。短時間に大量のイベントが到着した場合はevent stormとして診断情報を残すが、検知を理由にイベントを破棄しない。書込みは前世代を `.bak` へ退避してからatomicに行い、JSONLの破損は元ファイルを `.corrupt-<UUID>.jsonl` として隔離し、検証済みバックアップから復旧する。バックアップ・atomic write・復旧に失敗した場合はエラーを呼び出し側へ返し、TBW倍率や主予測をイベント増加のみで変更しない。

イベントがない場合の表示は「取得範囲で新規イベントなし」であり、未取得項目を含む全項目正常を意味しない。macOS build が未対応になった場合は、Research を空欄にせず「build 未検証・手動の構造再検証が必要」と表示する。

## wearBalance

Direct FTL の日別終点から、pSLC/TLC の比率に加えて、同じ前日点からの TLC 正規化損耗差分、pSLC 正規化損耗差分、各傾きを表示する。取得頻度の増加のみで観測点を増やさない。これは損耗配分の傾向を調査する補助資料で、中央予測の倍率ではない。

## 保存方針

raw snapshot は既存の容量制限付き `ASPToolSnapshotStore` と compaction 方針に従う。解析結果は dashboard rebuild 時に raw から再生成し、raw counter を書き換えない。compaction境界では firmware epoch、source build、Direct format、`coreWearVersion`、`researchTelemetryVersion`、history schema の変化前後を残す。`FTLTimeSeriesGroup` は研究テレメトリの意味を混在させないためcore／researchの対応表の組合せごとに分けるが、区間観測の損耗/WAF連続性はcoreの対応表を基準に維持する。`latestSeriesID` と最新系列の `latestSemanticContractVersion` は互換表示用に残し、新規表示ではcore/researchの両方を参照する。`calendarSpanDays`（最初から最後の暦 span）、`comparableWallDays`（有効区間の壁時計合計）、`comparableOperatingDays`（Power On Hours基準区間の合計）を別々に表示する。イベントjournalにもイベント自身のresearchの対応表の版を保存し、複数系列の先頭の対応表の版へ誤って寄せない。

histogram や private raw record を無制限に保存しない。長期研究でより細かい履歴が必要な場合は、既存 store の上限・圧縮方針と別に明示的な export を設計する。

## 残差の量子化

表示P/Eは整数量子化されるため、短区間の `ΔP/E = 0` や小さい差分を精密なNAND書込と断定しない。各端点の±0.5 P/Eを差分へ反映した `knownDomainNANDLow/Best/High` と `signedResidualLow/Best/High` を保存し、0が範囲内に入る、または最大P/E進行が2未満の区間は `indeterminate by PE quantization` とする。Best値は互換表示用であり、残差をband 0・domain・予算へ割り当てない。長区間でP/E進行が十分になった場合も、直接観測ではなく量子化範囲付きの研究診断として扱う。

## Scalar異常counterの暫定比較（2026-11-04）

scalar異常counterのイベント抽出は`reliabilityPairIsComparable`で判定する。共有コアレーンの連続性と既知のscalar対応表・同一取得形式が成立すれば、実行buildが25G83以外でも暫定比較する。histogram・refresh・相関の判定は`researchTelemetryPairIsComparable`のままであり、両者を混同しない。研究対応表が変化する区間はscalarも比較しない。詳細と制約は[信頼性表示](DASHBOARD_RELIABILITY_INDICATORS.md)を参照する。
