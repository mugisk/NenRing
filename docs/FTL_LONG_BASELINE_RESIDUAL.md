# 長基線 NAND 残差 実装仕様 v1

- 対象コミット: `ecfbe8d`
- 作成日: 2026-09-18
- 置き場所: `docs/FTL_LONG_BASELINE_RESIDUAL.md`
- 関連: `docs/FTL_TIME_SERIES_ANALYSIS.md`（区間残差・量子化）、`docs/NAND_MODEL_V2_4.md`（Direct topology）

---

## 0. 要約

現在の区間残差 `FTLIntervalResidualDiagnostics` は、連続する snapshot 対のみから算出される。P/E 量子化による不確かさは区間長に依存しない定数（約 ±269 GB）である一方、残差は時間とともに増加するため、**日次区間では構造的に常に `indeterminate` になる**。

本仕様は次を追加する。

| # | 追加 | 分解能 | 判定可能になる時期 |
| --- | --- | --- | --- |
| A | 生涯基線（出荷時アンカー） | 片端 ±0.5 P/E（±135 GB） | **現時点で判定可能** |
| B | 系列基線・P/E 目標基線 | 両端 ±1 P/E（±269 GB） | 約 5〜6か月（§2） |
| C | 非重複セグメント | 同上 | B と同時期、判別用 |
| D | band 書込回数経路（候補） | ±2 band/domain（±1.1 GB） | **意味検証を通過すれば日次で判定可能** |

**D の意味検証を最初に行うことを推奨する。** 検証を通過すれば B/C の待ち時間はほぼ不要になる。通過しなくても A は即日、B/C は数か月で機能する。

いずれも解析結果であり、予算・TBW・主予測・band 0 への割り当ては行わない（既存方針を継承）。

---

## 1. 背景：連続区間では判定できない理由

区間残差の量子化範囲（既存実装）:

```text
knownLow  = C_TLC × max(0, ΔTLC − 1) + C_pSLC × max(0, ΔpSLC − 1)
knownHigh = C_TLC × (ΔTLC + 1)       + C_pSLC × (ΔpSLC + 1)
片側幅    = C_TLC + C_pSLC = 258.503 + 10.603 = 269.1 GB     ← 区間長によらず一定
```

不確かさの **96% は TLC 側**（258.5 GB / P/E）。TLC 平均 P/E は現ペースで約 0.27 / 日しか進行しないため、日次区間では ±1 P/E が進行量の約 4 倍になる。

実測値（2026-09-02 → 09-17、15日区間）:

```text
ΔN         = 2,700 GB
Δknown     = 258.503 × 4 + 10.603 × 146 = 2,582.0 GB
残差 best  = +117.9 GB
範囲       = [−151.2, +387.1] GB        → 0 を含むため indeterminate
```

---

## 2. 前回の推定（約34日）の訂正

前回レビューで「残差は約 7.9 GB/日で増え、約34日で判定可能」と述べたが、**この 7.9 GB/日は上記の判定不能な 15 日区間から算出した値であり、根拠にならない**。範囲 [−151, +387] GB を 15 日で割れば −10〜+26 GB/日であり、成長率はこの区間からは決まらない。

判定可能な唯一の観測は次節 A の生涯残差である。

```text
2026-09-17 生涯残差 = +878.2 GB（範囲 +743.6〜+1,012.7 GB）
累積 Host          = 62,160 GB
残差 / Host        = 1.41%（範囲 1.20〜1.63%）
```

この比率が今後も続くと仮定した場合（Host 比例仮説）、現ペース 119 GB/日 で残差は 1.42〜1.94 GB/日増加する。両端 ±269.1 GB を超えるまでの日数:

| 仮説 | 残差成長 | 判定まで |
| --- | ---: | ---: |
| Host 比例（下限 1.20%） | 1.42 GB/日 | 189 日 |
| Host 比例（中央 1.41%） | 1.68 GB/日 | **160 日** |
| Host 比例（上限 1.63%） | 1.94 GB/日 | 139 日 |
| 壁時計比例（878 GB / 1,231 日） | 0.71 GB/日 | 377 日 |

**P/E 経路（B/C）単独では 5〜6 か月、仮説によっては約 1 年を要する。** これが §7 の band 経路を優先する理由である。

---

## 3. 基線の種類

### 3.1 A：生涯基線（出荷時アンカー）

出荷時点を `NAND = 0`、`平均 P/E = 0` のアンカーとみなす。アンカー側の P/E は量子化されていないため、**不確かさは終点側の ±0.5 P/E のみ**になる。

```text
片側幅 = 0.5 × (C_TLC + C_pSLC) = 134.55 GB
```

| 日付 | 既知 domain | 残差 best | 範囲 | 状態 |
| --- | ---: | ---: | --- | --- |
| 09-02 | 95,069.8 GB | +760.2 GB | [+625.7, +894.8] | resolved |
| 09-17 | 97,651.8 GB | +878.2 GB | [+743.6, +1,012.7] | resolved |

**既に判定可能であり、残差が正で存在することは確定している。**

前提（注記に必ず出すこと）:

- NAND counter と平均 P/E counter が出荷時に 0 から開始している
- 生涯を通じて Direct topology（区画境界・band 容量）が一定である
- 工場試験の書込が両 counter に同じ比率で含まれている

これらは検証できないため、生涯基線は「存在の確認」に用い、成長率の推定には B/C/D を用いる。既存の `signedResidualBytes`（NANDEnduranceV2）はこの生涯基線と同一量であり、本仕様では量子化範囲と状態を付与する。

### 3.2 B1：系列基線

同一 `FTLTimeSeriesGroup` の先頭有効 snapshot から最新 snapshot まで。系列内で最長の基線。

### 3.3 B2：P/E 目標基線

最新 snapshot `L` に対し、`TLC_PE(L) − TLC_PE(S) ≥ k` を満たす最も新しい `S` をアンカーとする。

```swift
static let tlcProgressTargets: [Double] = [10, 20, 40, 80]
```

日数ではなく ΔTLC P/E を目標にする理由は、判定可否を支配するのが TLC 量子化だからである。現ペースで 10 ≒ 37 日、40 ≒ 150 日、80 ≒ 300 日。§2 の見込みでは **40 付近で判定可能になり始める**。

### 3.4 C：非重複セグメント

判別分析（§6）用。系列の先頭から貪欲に、ΔTLC ≥ 20 を満たした時点で区切り、次のセグメントを開始する。

B1/B2 は互いに期間が重複するため独立な観測にならない。成長率の比較・正規化の比較には C のみを使用する。

---

## 4. 基線の成立条件

アンカー `S` と終点 `E` の間で、次をすべて満たすこと。

| 条件 | 判定 | 不成立時の状態 |
| --- | --- | --- |
| 同一 `FTLTimeSeriesGroup` | 既存 `sameSeries` 境界を跨がない | 構築しない |
| topology 一定 | **区間内の全 snapshot** で `directTopology` が一致 | `topologyChangedWithinSpan` |
| Host / NAND / P/E が単調非減少 | 区間内の全 snapshot で確認 | 構築しない |
| Power On Hours が単調非減少 | 同上。欠測は許容（壁時計へフォールバックを記録） | 構築しない（減少時） |
| 両端に topology・平均 P/E・NAND が存在 | nil を 0 で補完しない | 構築しない |

**topology は端点比較ではなく全 snapshot で確認する。** 端点のみでは `A → B → A` のような途中の再配分（`oslcTransitions` による動的変更の可能性）を見落とす。区間途中で変化した場合、容量が一定という前提が崩れるため基線を構築しない。区分積分は v1 の対象外。

### 研究試験との重複

既存の区間解析は研究試験区間を学習から除外している。長基線では**跨ぐことを許可し、`spansResearchSession` を記録する**。

理由：試験書込は ΔNAND と ΔP/E の両方に同じ物理として現れるため、残差の比較は内部整合が保たれる。除外が必要なのはレート学習（試験が日常ペースを歪める）であり、長基線ではレートを学習しない。除外すると試験のたびに長基線が切断され、判定可能時期がさらに遅れる。

---

## 5. 計算

### 5.1 P/E 経路（A / B / C 共通）

```text
ΔTLC   = TLC_PE(E) − TLC_PE(S)          （A では S 側 = 0）
ΔpSLC  = pSLC_PE(E) − pSLC_PE(S)
q      = 1.0（両端量子化）または 0.5（A：片端のみ）

knownBest = C_TLC × ΔTLC + C_pSLC × ΔpSLC
knownLow  = C_TLC × max(0, ΔTLC − q) + C_pSLC × max(0, ΔpSLC − q)
knownHigh = C_TLC × (ΔTLC + q)       + C_pSLC × (ΔpSLC + q)

residualBest = ΔN − knownBest
residualLow  = ΔN − knownHigh
residualHigh = ΔN − knownLow
```

`ΔN` は表示用に丸めた TB 値ではなく、**raw UInt64 counter の差 × 単位**から求める。

量子化の扱いは丸め方式に依存しない。controller が四捨五入でも切り捨てでも、端点誤差は幅 1 の区間に収まり、差分の誤差は (−1, +1) になる。

### 5.2 状態

```swift
enum LongBaselineResidualStatus: String, Sendable {
    case resolvedPositive        // residualLow > 0
    case resolvedNegative        // residualHigh < 0
    case indeterminate           // 範囲が 0 を含む
    case insufficientProgress    // ΔTLC < 2 かつ ΔpSLC < 2（既存規則を継承）
    case topologyChangedWithinSpan
}
```

`resolvedNegative` を独立させる。負の残差は「既知 domain が NAND counter より多く書いた」ことを意味し、容量過大・counter の意味違いを示す別種の信号である。

### 5.3 正規化（記述値）

resolved の基線に限り、次を併記する。

| 正規化 | 式 | 対応する仮説 |
| --- | --- | --- |
| Host 比 | residual / ΔHost | 書込比例の第3ストリーム（メタデータ・ジャーナル） |
| 既知 domain 比 | residual / knownBest | 容量モデルの尺度誤差 |
| 稼働日あたり | residual / ΔPOH × 24 | 稼働時間比例の内部処理 |
| 壁時計日あたり | residual / Δ壁時計日 | 電源断中も進む何か（本来は想定しにくい） |

それぞれ Best と範囲（Low/High から伝播）を出す。`equivalentPSLCBands` は resolved のときのみ表示する（前回レビュー指摘の反映）。

---

## 6. 判別分析（記述統計のみ）

### 6.1 方法

非重複セグメント（§3.4）が **resolved で 3 本以上**揃った時点で、§5.3 の各正規化について**セグメント間の変動係数（CV）**を表示する。

```text
CV が小さい正規化 = 残差がその量に比例している可能性が高い
```

例：Host 比の CV が 5%、壁時計日あたりの CV が 60% なら、残差は書込比例に近い。**因果は確定しない**。表示は「最も安定した正規化」を示すに留め、自動で原因を選択しない。

### 6.2 refresh との対応に関する注意

前回レビューで「時間比例なら refresh / scrub」と述べたが、補足が必要である。

**既知 domain（TLC 642 bands / pSLC 79 bands）内への refresh 書込は、その domain の P/E を消費するため `knownDomain` 側に含まれ、残差には現れない。** 残差に refresh が寄与するのは次の場合に限られる。

- refresh の書込先が既知 domain の外（band 0 等）
- P/E counter（erase 時点で加算）と NAND counter（program 時点で加算）の時間差

したがって refresh 増分との相関は「refresh が残差の原因」ではなく「域外 refresh または計数時点差」の示唆として扱う。隣接表示する refresh 系 delta（`ageRefresh` / `backgroundRefresh` / `bandsPaddedForAge` / `bandsRefreshedOnError`）について、resolved セグメントで次を記述値として出す。

```text
残差 / Δ refresh 事象数 = 事象あたりの未同定書込量
参照線: TLC band 402.65 MB、pSLC band 134.22 MB
```

事象あたりの値が一定で band 容量に近ければ、域外への band 単位の移動を示唆する。近くなければ refresh は主因でない可能性が高い。

### 6.3 共線性の限界

TLC と pSLC の損耗が揃っている間（`wearBalance ≈ 1`）は ΔTLC と ΔpSLC がほぼ比例するため、**「TLC 容量の誤差」と「pSLC 容量の誤差」は分離できない**。既知 domain 比（§5.3）はその合成値である。domain 別の尺度誤差を推定するのは、損耗バランスが崩れた後に限る。

---

## 7. D：band 書込回数経路（候補・意味検証が前提）

### 7.1 動機

`userBandsProgrammed`（key 350）と `intermediateBandsProgrammed`（key 349）は既に `ASPToolDiagnosticsSnapshot` に保存されている。これが「band を 1 本書き切るたびに 1 増える counter」であれば、平均 P/E を経由せずに既知 domain の NAND 書込を再構成できる。

```text
knownBand = ΔuserBandsProgrammed × TLC_band_bytes
          + ΔintermediateBandsProgrammed × pSLC_band_bytes
```

| 経路 | 量子化の片側幅 | 判定まで（Host 比例・中央） |
| --- | ---: | ---: |
| 平均 P/E | 269.1 GB | 160 日 |
| **band counter** | **1.07 GB**（±2 band/domain） | **1 日未満** |

±2 band は ±1 の計数量子化に加えて、書込途中の open band を domain あたり 1 本許容する。

さらに、平均 P/E は erase 時点、NAND counter は program 時点で加算されるのに対し、band 書込回数は program 側の counter と考えられるため、**NAND counter との計数時点が揃う**利点がある。

### 7.2 意味検証ゲート（必須）

key 349/350 の意味は未確認であり、検証を通過するまで D は計算しない。

```text
比率_TLC  = userBandsProgrammed          / (TLC bands  × TLC 平均 P/E)
比率_pSLC = intermediateBandsProgrammed  / (pSLC bands × pSLC 平均 P/E)

2026-09-17 の期待値: 642 × 160 = 102,720 / 79 × 5,309 = 419,411
```

| 結果 | 扱い |
| --- | --- |
| 両比率が 0.95〜1.05、かつ 3 snapshot 以上で ±1% 以内に安定 | **検証済み**。D を計算・表示 |
| 比率が一定だが 1 から離れる（例：0.5、2、4） | **未検証**。plane 数・部分 band 等の別意味の可能性。自動で倍率補正しない |
| 比率が不安定 | 意味不一致。D を計算しない |
| counter が減少・欠測 | D を計算しない |

**この検証は既存履歴のみで今日実施できる。** 実装の第一段階はこの比率の表示である。

### 7.3 検証後の扱い

検証済みの場合、D は連続区間（日次）でも判定可能なので、既存の `FTLIntervalResidualDiagnostics` に `bandPath` として併記する。P/E 経路（A/B/C）は独立な検算として残す。両経路の残差が一致すれば相互検証になり、乖離すれば §6.2 の計数時点差の大きさを示す。

---

## 8. 副次的な確認：NAND counter の単位

生涯残差が小さいこと自体が、NAND counter の単位（暫定 4 KiB）の強い傍証になる。既知 domain 側は geometry と P/E から算出され、単位を含まない。

| 仮定単位 | NAND 累積 | 生涯残差 |
| --- | ---: | ---: |
| 512 B | 12.32 TB | −692.9% |
| **4 KiB** | **98.53 TB** | **+0.9%** |
| 8 KiB | 197.06 TB | +50.4% |

単位は離散的な選択肢なので、±1% 級の一致は 4 KiB 以外を実質的に排除する。ただし数 % の単位誤差は検出できない。既存の `hostWritesUnitState` を自動で `verified` へ昇格させる根拠にはせず、Research の注記に留める。

---

## 9. データ保持

現在の標準保存は[計測履歴の可逆集約](LOSSLESS_HISTORY_STORAGE.md)を使用する。観測は全件保持し、旧 `archive/` の記録も復元する。以下は旧サンプリング形式の互換処理であり、通常監視では新たな間引きを行わない。

`ASPToolSnapshotStore.compact` は、記録の経過時間で間引く。

| 経過 | 残す記録 |
|---|---|
| 35日以内 | すべて |
| 180日以内 | 1時間ごとの最終点 |
| それより前 | 1日ごとの最終点 |

- 35日以内をすべて残すのは、FTL の区間を温度と照合する分析や、書込を時間帯で分ける分析が30日をさかのぼるためである。
- 間引きは256回の追記ごとに行う。`maximumRecordCount`（50,000件）は安全のための上限で、5分間隔の取得でも通常は到達しない。
- 間引いた記録は `archive/` に残す（`CompactionArchive`）。
- 次の記録は経過時間にかかわらず残す。
  - 各系列の先頭 snapshot（B1 の最長アンカー）
  - firmware・build・対応表・構造（topology、EOL）が変化した境界の前後。境界の8日前から4日後まではすべての記録を残す。更新直後の一時的な変化の判定（更新前7日・更新後72時間）が、間引いた後も同じデータを読み取れるようにするためである。
  - カウンタの減少、単位の状態の変化、取得経路（asptool と Direct）の切り替えが発生した前後の2点

長基線は週1点あれば構築できるため、この方針で十分である。間引きにより長基線のアンカーが変化した場合は、アンカー snapshot の ID と `capturedAt` を結果に記録し、表示で判別できるようにする。

---

## 10. データ構造

```swift
enum LongBaselineKind: Equatable, Sendable {
    case lifetime                       // A
    case series                         // B1
    case tlcProgressTarget(Double)      // B2
    case segment(index: Int)            // C
}

enum ResidualReconstructionPath: String, Sendable {
    case averagePE                      // A / B / C
    case bandsProgrammed                // D（検証済みのみ）
}

struct LongBaselineResidual: Equatable, Sendable, Identifiable {
    let kind: LongBaselineKind
    let path: ResidualReconstructionPath
    let anchorSnapshotID: UUID?         // lifetime は nil
    let endSnapshotID: UUID
    let anchorAt: Date?
    let endAt: Date
    let wallDays: Double?
    let operatingDays: Double?
    let usedWallClockFallback: Bool
    let spansResearchSession: Bool

    let deltaHostBytes: Double
    let deltaNANDBytes: Double
    let tlcPEDelta: Double
    let pslcPEDelta: Double
    let quantizationHalfStep: Double    // 0.5（lifetime）または 1.0

    let knownLowBytes: Double
    let knownBestBytes: Double
    let knownHighBytes: Double
    let residualLowBytes: Double
    let residualBestBytes: Double
    let residualHighBytes: Double
    let status: LongBaselineResidualStatus

    // §5.3（resolved のときのみ非 nil）
    let residualPerHost: ClosedRange<Double>?
    let residualPerKnown: ClosedRange<Double>?
    let residualPerOperatingDay: ClosedRange<Double>?
    let residualPerWallDay: ClosedRange<Double>?
    let equivalentPSLCBands: Double?

    // §6.2 隣接表示
    let ageRefreshDelta: UInt64?
    let backgroundRefreshDelta: UInt64?
    let bandsPaddedForAgeDelta: UInt64?
    let bandsRefreshedOnErrorDelta: UInt64?

    let notes: [String]
}

struct BandCounterCalibration: Equatable, Sendable {
    let capturedAt: Date
    let tlcRatio: Double?               // userBandsProgrammed / (tlcBands × tlcPE)
    let pslcRatio: Double?
    let stableSnapshotCount: Int
    let verified: Bool
    let note: String
}

struct LongBaselineResidualAnalytics: Equatable, Sendable {
    let baselines: [LongBaselineResidual]
    let calibration: [BandCounterCalibration]
    let normalizationStability: [String: Double]   // §6.1 CV（resolved セグメント 3 本以上）
    let projection: ResolutionProjection?          // §11
    let notes: [String]
}
```

`FTLTimeSeriesAnalytics` に `longBaseline: LongBaselineResidualAnalytics` を追加し、dashboard rebuild 時に raw から再生成する。保存しない。

---

## 11. 表示

### 11.1 Research「未同定 NAND 残差」

```text
未同定 NAND 残差                                   研究診断・予算へ割り当てません

  生涯（出荷時アンカー）   +878 GB  [+744, +1,013]   判定可能 ✓
                            Host比 1.41%（1.20–1.63%）
                            前提: counterが0開始・topology一定

  系列基線 15日            +118 GB  [−151, +387]     判定不能（P/E量子化）
  ΔTLC ≥ 10               未到達（現在 ΔTLC 4 / 必要 10）

  判定見込み（Host比例仮説・生涯比率による）
    ΔTLC ≥ 40 付近、約 140〜190 日後
    壁時計比例の場合は約 380 日

  band 書込回数経路
    TLC 比率 1.002 / pSLC 比率 0.998   安定 3/3   → 検証済み   ← 例
    日次区間残差を併記しています
```

判定見込みは §2 の式で動的に再計算する。

```text
必要日数 = (C_TLC + C_pSLC) × q_両端 / (生涯残差比率 × 直近 Host ペース)
```

生涯比率は範囲付きで扱い、見込みも範囲で示す。

### 11.2 表示しないもの

- `indeterminate` の基線の `equivalentPSLCBands`・正規化値
- 1 本のみの resolved セグメントに基づく「最も安定した正規化」
- 残差の原因の推定（band 0、metadata、refresh 等）。§6 の候補一覧は注記として出すが順位は付けない

---

## 12. テスト

### 12.1 実機 fixture（2026-09-02 / 09-17）

入力は raw 値のみを置き、期待値は本仕様の手計算から与える（前回の `sectorsPerFullBand` 問題の再発防止）。

| # | 内容 | 期待値 |
| --- | --- | --- |
| 1 | 生涯基線 09-02 | best +760.2 GB、[+625.7, +894.8]、`resolvedPositive` |
| 2 | 生涯基線 09-17 | best +878.2 GB、[+743.6, +1,012.7]、`resolvedPositive` |
| 3 | 系列基線 09-02 → 09-17 | best +117.9 GB、[−151.2, +387.1]、`indeterminate` |
| 4 | Host 比（生涯 09-17） | 1.41%（1.20–1.63%） |
| 5 | ΔTLC 目標 10 | 未到達、ΔTLC 4 を報告 |
| 6 | 判定見込み（Host 比例） | 139〜189 日 |

許容誤差は ±0.5 GB（raw counter から計算するため）。

### 12.2 合成 fixture

| # | 内容 | 期待 |
| --- | --- | --- |
| 7 | 160 日・残差 Host 比 1.41% 一定 | 系列基線が `resolvedPositive` |
| 8 | 同条件で非重複セグメント 3 本 | Host 比の CV が壁時計比より小さい |
| 9 | topology A → B → A | `topologyChangedWithinSpan`、端点一致でも構築しない |
| 10 | 研究試験を跨ぐ | 構築し `spansResearchSession = true` |
| 11 | 残差が負で範囲が 0 を含まない | `resolvedNegative` |
| 12 | 生涯基線で topology 欠測 | 構築しない（0 補完しない） |
| 13 | band 比率 1.00 が 3 点安定 | `verified = true`、D を計算 |
| 14 | band 比率 0.50 が安定 | `verified = false`、自動補正なし |
| 15 | band 比率が不安定 | `verified = false` |
| 16 | compaction 後も系列先頭 snapshot が残る | 先頭 ID が保持される |
| 17 | indeterminate のとき `equivalentPSLCBands` | nil |

---

## 13. 実装順序

1. **band counter の比率表示（§7.2）** — 既存履歴で即日結果が得られる。検証を通過するかどうかで以後の重要度が変化する
2. 生涯基線に量子化範囲と状態を付与（§3.1）— 既存 `signedResidualBytes` の拡張
3. 系列基線・P/E 目標基線・判定見込み表示（§3.2, §3.3, §11）
4. compaction で系列先頭を保持（§9）
5. 非重複セグメントと判別分析（§3.4, §6）— resolved が 3 本揃うまで表示されないため最後でよい
6. band 経路の日次区間残差（§7.3）— 1 の検証を通過した場合のみ

---

## 14. 非対象

- 残差の予算・TBW・主予測・Forecast WAF への反映
- 残差の band 0・Utility・特定 domain への割り当て
- topology 変化を跨ぐ区分積分
- key 349/350 以外の未確認 counter の意味推定
- 判別分析の結果に基づく原因の自動確定
