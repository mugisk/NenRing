# 寿命予測の計算の構成

NAND Model v2.4.1 以降に導入した、計算の内部の分担をまとめたものです。新しい寿命モデルではなく、実装の見取り図です。

## 全体の流れ

`NANDEnduranceV2.build` が、連続性の判定、根拠の選択、最終的な予測行の組み立てをまとめて行います。単独で性質を保てる計算は次の純粋な部品に任せています。

- `ForecastWAFEstimator`：全期間のWAFと直近のWAFを重み付けする。予測用の「事前に見込むHost量」の尺度を持ち、Retention Researchの設定は参照しない。
- `CumulativeHostResolver`：時刻・デバイス・ファームウェアが合うSMARTの累積Hostを選択する。合うものがない場合は、明示的にFTLのHostカウンタを使用する。
- `RetentionDeratingPolicy`：保持モデルの比率を、TLCの予算を減らす方向にのみ働く係数に変換する。Kret=1を基準として保つ。現在は研究用の値にのみ使用し、中央予測には使用しない。
- `DirectDomainBudgetCalculator`：Direct topologyとP/Eから、TLCとpSLCのNAND予算を算出する（保持補正なしの基準値と、研究用の補正後の値）。
- `DomainWriteShare`：NAND書込のうちTLCとpSLCが占める割合を、P/E × 容量から求める。全期間の割合と、予測WAFと同じ期間の直近の割合を、同じ重みqで混合する。直近の割合は期間内のNAND書込量の増分からpSLCのP/E増分 × 容量を引いて求め、pSLCのP/Eが50以上進んだ場合のみ使用する。率学習の除外期間に重なる取得の組は除外する。全期間の割合は、TLCのP/Eが10以上になってから使用する。
- `DomainBottleneckRemaining`：領域ごとに「残りNAND ÷（予測WAF × その領域の割合）」を求め、先に尽きる方の残Hostを中央予測とする。参照機ではTLCが先に尽きる。
- `RetentionScenario`：電源を切って保管した場合の仮想の値（TLCのみ）。30°C・1年 = 3000 P/Eを基準に、Arrheniusで換算する。詳しくは [RETENTION_RESEARCH_ESTIMATE.md](RETENTION_RESEARCH_ESTIMATE.md)。
- `DomainWriteBreakdown`：TLCとpSLCへの推定書込量とHostに対する倍率を、表示用に出力する。
- `EnduranceProjectionBuilder`：残りNANDを将来のHost量に換算し、すでに観測した累積Hostのみを加算する（ドメイン別の予算を使用できない場合の経路）。
- `NANDReconciliationDiagnosticsBuilder`：実測NANDとドメインからの再構成、N/uの照合を、予算の計算とは切り離して扱う。
- `EndurancePaceForecast`：到達日への換算をここでのみ行う。以前の50/35/15の混合ペースは、寿命予測の結果には残っていない。

## 守っている性質

テストで、次の性質を確認しています。

1. NAND予算が同じなら、将来のWAFを上げても残Host書込量は増えない。
2. topology・EOL・保持条件が同じなら、P/Eが増えても残りNANDは増えない。
3. 研究用のテレメトリは中央の予算や予測を変えない。
4. 取得の間隔を細かくしても、予測WAFの根拠の重みは増えない。
5. 保留中または失敗した計測器境界があると、中央の状態は最後に受け入れた系列のサンプルより先に進まない。
6. 将来のWAFを変更しても、過去の累積Host書込量の評価は変化しない。
7. topologyとIORegistryが一致しない場合、Directのドメイン予算は採用しない。

これらはモデルが守る性質であり、精度を保証するものではありません。

## Direct FTLの対応表と版

非公開インターフェースへの対応は、`DirectFTLContractRegistry` の `DirectFTLContractDescriptor` で表します。現行の確認済みの記述子は次の内容を固定しています。

- 確認済みのmacOSのメジャーバージョン（26・27）と、確認済みの `chip-id`（S5E。NANDパッケージ内のMSPダイのID）。
- サービス名、プラグインとインターフェースのUUID、vtableのオフセット。
- payloadの形の版、キーの意味の版、中心とresearchのkeyの対応表の版。
- topologyのスキーマ、値の範囲、テスト用データの識別子、確認の状態。

さらに、取得のたびに `DirectFTLReadCrossCheck` でSMARTと照合します（Host書込量が1%または5 GB以内で一致すること、など）。

新しいmacOSや新しいコントローラに対応するときは、まず記述子を追加して確認します。解析の計算は共通のままにし、収集や分析の処理の各所にOSの版の分岐を分散させないようにします。
