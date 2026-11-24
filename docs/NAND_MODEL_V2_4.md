# NAND Model v2.4.1 — Direct topology・残差分離・FTL内部イベント

更新日: 2026-10-02
対象: NenRing の研究用 Apple Silicon SSD 耐久推計

## v2.4.1のレビュー修正

v2.4.1 は v2.4 の入力の解釈を補正した互換更新である。25G83 の key 327–331 は
温度そのものや read retry の意味へ再分類せず、次の opaque histogram として保存する。

| key | 正規化名 |
| --- | --- |
| 327 | `bandsMaxTempHistogram` |
| 328 | `bandsMinTempHistogram` |
| 329 | `bandsLifetimeTempHistogram` |
| 330 | `bandsDeltaTempHistogram` |
| 331 | `bandsCrossTempHistogram` |

bin番号は温度単位へ変換せず、累積histogramとも仮定しない。旧JSONの
`readTemperatureHistogram` などのキーは読み込み時のみ上記の新しい意味へ対応付けるが、
新規保存は v2.4.1 名で行う。旧い対応表の値を新しい意味で暗黙に再解釈しない。

旧histogram名はdecode専用のエイリアスとして受け入れ、新規encodeでは上表の名前のみを使用する。
読み替えは保存形式の互換性のためであり、値の意味を検証し直したことにはならない。
元の取得時刻・build・契約版を保持し、欠けた配列を現在のsnapshotから補完しない。
旧値は診断・比較用に保つが、現行の対応表へ意味付き昇格させず、TBW/WAF/保持補正には使用しない。
研究契約の変更のみではcore損耗系列を分割しない一方、研究契約に依存する差分は
互換性が確認できる範囲で扱う。現行の取得条件は[データ取得の仕組み](DATA_ACQUISITION.md)、
差分の条件は[FTL時系列解析](FTL_TIME_SERIES_ANALYSIS.md)を参照する。

Direct FTL snapshot には取得時の `deviceID`、firmware epoch、source build、firmware、
MSP version、chip ID をOptional contextとして添付する。取得できない値はnilのままにし、
別時点のIORegistry値で補完しない。macOSの取得条件はメジャーバージョン単位で扱い、
各取得のSMART照合と更新境界の連続性検査を行う。確認できない研究用keyは未検証として表示する。

保持推計の `retentionDays` は将来必要な無通電保持条件であり、未設定時は365日を使用する。
SMARTのPower On Hours差分から得た無通電露出は観測診断として保存するのみで、必要保持日数へ
置換しない。pSLCにはTLCの保持曲線や比率を流用せず、中央推計の保持係数を1.0として
取得したpSLC Controller EOLを使用する。WAF成分の負残差は全体値の0.5%以内なら丸め・取得時差の
研究上の許容として表示上0とするが、成分定義をForecast WAFへ戻さない。

## 位置付け

v2.4 は `FTL all` のレビュー済み区画境界を使用して TLC と Intermediate pSLC の
書込予算を組み立てる。これは Apple の公称TBW、JEDEC適合、物理NAND容量の独立確認、
故障確率、または保持保証を表すものではない。25G83でレビューした private buffer の
意味付けと、このMacで観測したP/E・Host/NAND counterを組み合わせる研究推計である。

以前の「累積NANDとP/Eから80 pSLC bandsを逆算する」値は削除しない。ただし v2.4 では
**Researchの整合比較**のみに残し、中央予測、残Host、到達時期の入力には使用しない。

## 適用範囲と、取得および解析の方法

semantic parser が意味付き値を生成するのは、次をすべて満たす `FTL all` artifact のみである。

* 実行buildと、artifactの取得および解析の方法を区別する。レビュー済みの実行環境はmacOS 26・27。
  macOS 14・15は自動取得の暫定対象だが、レビュー済み環境には追加しない。
  意味付き値は25G83で解釈したUUID・vtable・recordの対応表との一致から抽出し、
  未検証の実行buildにはその状態を残す（`DirectFTLContractRegistry.reviewed25G83`）。
* `GetNVMeSMARTInterface`
* レビュー済み plugin/interface UUID
* `all` の確認済み vtable offset と正常な response size
* read時刻を持つ artifact

そのうえで、取得のたびにSMARTと照合する（`DirectFTLReadCrossCheck`）。FTLのHost書込が
SMARTと1%または5 GBの大きい方の範囲で一致し、EOL P/Eが正で、平均P/Eが最大P/E以下で
あることを確認する。一致しなければ保存せず自動取得を停止する。照合に必要な値が欠けている
取得値も保存しない。自動取得はApple Siliconの内蔵Apple SSDに限定し、26・27は確認済み、
14・15は互換性を想定した暫定対象（`compatibilityTrial`）とする。それ以外は手動取得が
SMART照合を通過した後に自動取得を許す（`locallyVerified`）。14・15でも照合成功後はローカル
照合済みと記録するが、研究keyの意味まで確認済みにしない。照合失敗時は保存と自動取得を停止する。
自動取得はSMARTと同じ周期（既定10分、5分〜1時間）で行い、失敗後も設定した間隔を待つ。保存済みの手動のみ設定は維持する。

別interface、`perm`、未知のrecord layoutはこの対応表のsemantic値には昇格しない。
未検証の実行buildでも対応表との一致から抽出したコア値は暫定表示できるが、予測採用には保存前照合と
別の連続性lane検査を使用する。研究telemetryの意味付けは実行buildの対応表の確認と分離する。
通常監視は再検証・sysdiagnose・追加の管理者取得を自動実行しない。以前の0x106 tunnel probeは
削除した（保存済みのtunnel取得物は手動で解析できる）。

scalarの `0` は有効な観測値である。欠測、scalar/pair/arrayの形状不正、重複key、
配列上限超過は `0` に置き換えず `nil` と警告へ変換する。P/Eは
`min <= avg <= max` を検査するが、現在P/EがEOLに達した／超えたこと自体はparse失敗に
しない。後段で当該domainの残量を0にする。

生のrecord列はparse中のみ保持し、履歴へ無制限には保存しない。正規化したOptional値は
既存のASP履歴へ可逆形式で保存する。過去のJSONに新しいOptional keyがない場合、
現在のtopologyやイベント値を埋めず、そのまま読み込む。

## 25G83 keyの対応表

以下は private record key の、今回確認済みの範囲のみを記す。rawは表示・比較用であり、
明記しない限り公開単位ではない。

| key | 形状 | 正規化先 / 用途 | 単位・根拠 |
| --- | --- | --- | --- |
| 4 / 18 / 19 | scalar | Host writes / NAND writes / NAND reads | 4/18はasptool近接値から4 KiB暫定、19はraw |
| 20 / 34 | scalar | band erases / Power-on hours | raw / hours |
| 46 / 47 | scalar | Factory / Grown Bad Blocks | raw counter |
| 49 / 50 / 129 | scalar | bytes/page、native pages/block、pSLC pages/block | Direct geometry |
| 52 / 85 / 86 | scalar | virtual blocks、Intermediate開始、User開始 | Direct topology |
| 84 | scalar | Intermediate erases | raw、累積範囲未確認 |
| 124 / 503 / 125 | pair | TLC/pSLC min、avg、max P/E | `min <= avg <= max` を検証 |
| 942 / 943 | scalar | pSLC / TLC Controller EOL P/E | 正のP/E基準 |
| 93 | array (最大64) | age refresh tiers | raw、配列長も比較 |
| 97 / 112 | scalar | background refresh moves / bands padded for age | raw |
| 327–331 | array (最大1024) | bands max/min/lifetime/delta/cross-temperature histogram | bin indexのまま保存、温度へ変換しない |
| 340 / 343 / 414 | scalar | cross-temp UECC / utility UECC / UECC reads | reliability evidence |
| 422 / 423 / 424 | scalar | native / reduced native / pSLC read verify | recovery evidence |
| 427 / 461 / 462 / 485 | scalar | Direct→TLC / waterfall write-path | raw表示のみ |
| 659 / 953 | scalar | RAID verification reads / cross-temp RAID UECC | raw / reliability evidence |
| 1050–1053 | scalar | Host/GC pSLC/TLC read-verify failures | reliability evidence |
| 349–352、430–433、531–532、561、565、707–708 | scalar | 既存ASP内部統計 | asptoolラベルと照合済みのraw表示 |

`numPfail`、`numEfail`、Host書込み内訳、RAIDの個別内訳は対応keyを確認できていない。
UIには「未照合」として残し、ゼロ、正常、またはTBW補正値とは表示しない。

今回の追加監査ではDirect FTL artifact上で key 5 / 6 / 27 がscalarとして存在することを
確認できる形にした。候補値は `ASPToolDiagnosticsSnapshot` にraw値として保存し、同一系列の
snapshotではdelta合計とkey 4 Host Writesの一致を検算表示する。ただし、近接asptoolの名前・
delta・合計不変量を複数回照合するまでは `hostWritesDyn` / `hostWritesStatic` / `hostWritesMeta`
という意味へ昇格させない。Host Writes、WAF、寿命予測へは投入しない。

同様に `numPfail`、`numEfail`、`bandsRefreshedOnError`、`openBandReadFail`、
`offlineBlocksCnt` は、25G83の対応key番号とasptool named fieldの対照が完了していない。
候補keyの推測走査や0埋めは行わず、Researchの未照合項目として残す。

histogramは温度への変換や累積histogramという仮定を行わない。UIはbin数、平均bin、
P50/P90/P99、最終非ゼロbinを表示し、空配列と全binゼロを分ける。利用者がResearchで
選択した開始bin以上の `tailFraction` は研究集計のみであり、警告閾値・寿命倍率にはしない。

## Direct topologyによる中央予測

Direct topologyがあり、正のgeometry積を構成でき、同時に利用可能なIORegistry geometryと
明白に不整合でなければ、次を使用する。

```text
Intermediate bands = userPartitionStart - intermediatePartitionStart
TLC bands          = numVirtualBlocks - userPartitionStart

TLC band bytes     = bytesPerPage × pagesPerVirtualBlock
pSLC band bytes    = bytesPerPage × pagesPerVirtualBlockSlc

TLC capacity        = TLC bands × TLC band bytes
pSLC writable cap.  = Intermediate bands × pSLC band bytes
pSLC physical space = Intermediate bands × TLC band bytes
```

pSLCは「書込可能容量」と「TLC-modeの物理占有量」を分離して表示する。耐久計算は前者を
使用する。`topologyContractValidated=true` は25G83 key／形の対応表の検証結果であり、実装置の
物理配分が独立に確認されたことは意味しない。従って
`physicalCapacityAllocationVerified=false` を維持する。

25G83 fixtureの `numVirtualBlocks=722`、`intermediateStart=1`、`userStart=80` は、
**79 Intermediate pSLC bands** と **642 TLC bands** になる。16,384 B/page、
24,576 native pages、8,192 pSLC pagesなら、1 bandはそれぞれ384 MiBと128 MiBになる。
これらは回帰fixtureの確認値であり、別buildの定数ではない。

### 予算と保持補正

```text
TLC target P/E  = TLC Controller EOL × Kret   （中央予測では Kret = 1）
pSLC target P/E = pSLC Controller EOL

domain baseline budget = domain capacity × domain Controller EOL
domain used            = domain capacity × current average P/E
domain remaining       = domain capacity × max(0, target P/E - current average P/E)

remaining NAND = Σ domain remaining
```

`Kret` は現在設定の保持日数・保管温度から求める減額方向の研究係数で、上限は1である。
研究用の系統でTLCのみに適用し、pSLCは独立保持曲線が未確認のため係数1とする。
中央予測は下の節のとおり `Kret = 1` を使用する。Program温度補正をdomain予算へ重ね掛けしない。

### 保持補正なしの基準値と研究用の補正値

ドメイン予算は常に2つの系統を持ちます。

```text
基準の系統      Kret = 1.0
研究用の系統    Kret = 現在の研究用の保持の方針
```

中央予測は**基準の系統（Kret = 1.0）**を使用します。保持補正を含めない基準と、電源OFFでの保管条件を仮定した「保持考慮」を分ける計算方針です。通電中に保持劣化が起きないと断定するものではありません。研究用の系統は残りNANDとその差を別に保存します。保持考慮の条件は[保持の研究推計](RETENTION_RESEARCH_ESTIMATE.md)で説明します。研究用のテレメトリ、ヒストグラムの解釈、残差の診断、信頼性イベントは、どちらの予算も変えません。

### HostとWAFのカウンタの扱い

全期間と区間のWAFは同じFTLの計測器のカウンタの比のままです。

```text
FTL WAF = FTLのNAND書込 ÷ FTLのHost書込
```

`総Host = 過去のHost + 将来の残Host` の過去のHostの項には、受け入れたFTLのレーンの終点と照合した、標準のNVMe SMARTのData Units Writtenを優先して使用します。照合の条件は次のとおりです。

- 同じデバイスである。
- 24時間以内に取得している。
- 両方でファームウェアが判明している場合、互換である。
- FTLのHostカウンタとの差が10%以内である。

条件を満たさない場合は、FTLのHostカウンタを、暫定であることが判別できる形で代わりに使用します。このように分けることで、比は同じ計測器どうしで単位が打ち消し合う性質を保ちつつ、累積Hostの総量が暫定の4 KiBという絶対単位に不要に依存するのを避けています。

### 予測WAFの根拠の尺度

FTL入力後にSMARTで増えたHost書込量は、到達日を今日から数える際の補正に使用する。入力時点の総量・残量の表は維持する。実使用・保持考慮・参考基準ではHost増分を差し引く。クライアント負荷では同じ増分を`Forecast WAF / 3.5`倍して差し引く。これは入力後のNAND消費量をForecast WAFで推定し、ClientのHost単位へ換算した値であり、その間もdomain配分が続く仮定を含む。Forecast WAFが取得できない場合はClientの補正を行わない。FTLを2日以上取得できない場合は古い予測として表示し、自動取得の停止後や手動取得設定でも鮮度の注意表示を維持する。

直近のWAFの混ぜ方はRetention Researchとは独立しています。

```text
q = 観測したHost ÷ (観測したHost + forecastWAFPriorEquivalentHostBytes)
W予測 = exp((1-q) ln(W全期間) + q ln(W直近))
```

根拠の尺度の既定値は1 TBです。`retentionDailyWAFPriorHostBytes` は、別系統のRetention ResearchのWAFの事前値のためのもので、中央の予測WAFを変えることはできません。

### Host換算と予測の行（先に尽きるdomain・保持補正なし）

pSLCは大容量の書込キャッシュとして機能し、寿命の長いデータのみがTLCへ移される（folding）。
そのためTLCとpSLCはHost 1 byteあたり別々の速度で損耗する。参照機の全期間ではTLC約0.66〜0.67倍・
pSLC約0.90〜0.91倍（全期間比と直近比の混ぜ方により若干変化する）。中央予測はdomainごとに残量をHost換算し、**先に尽きる方**で決める。
残量を合算してWAFで割る旧方式は、TLC律速を薄めるため使用しない。

```text
TLC配分 s    = TLC NAND書込 ÷ (TLC + pSLC NAND書込)
              全期間比（P/E × 容量）と、予測WAFと同じ窓の直近比を、ForecastWAFと同じqで対数混合する。
直近比 s_r   = (ΔNAND − ΔpSLC平均P/E × pSLC容量) ÷ ΔNAND
              窓内の取得の組ごとに増分を加算し、率学習除外に重なる組のみを外す。
              ΔpSLC平均P/Eが50未満、またはpSLC分がΔNANDを超える場合は全期間比のみ。
a_TLC        = ForecastWAF × s
a_pSLC       = ForecastWAF × (1 − s)
実使用残Host = min( TLC残NAND ÷ a_TLC , pSLC残NAND ÷ a_pSLC )
Client残Host = 同じ式でForecastWAFの代わりに3.5を使用する
各総Host     = 現在の累積Host + 各残Host
```

残NANDは保持補正なし（Kret = 1）のdomain予算から求める。日常的に使用するMacは無通電の期間がほとんどなく、
通常利用の基準と保管条件の比較を分けるためである。保持を考慮した値はTLCのみに適用する別の仮想シナリオとして扱う。
pSLC（EOL 100000）には保持補正をかけない。参照機ではTLCとpSLCが僅差で、2026-10-17の直近比の見直し後はpSLC律速、残Hostは約1.09 PB。

TLC配分が算出できない場合（新しいMacでpSLCのP/Eが0など）は、保持補正なし（Kret = 1）のdomain残量を
合算して予測WAFで割る。カウンタのリセットやSMARTとFTLのfirmware不一致で系列を保留している間は、
実使用・Clientを含むすべてのHost予測を算出しない。見出しの損耗は実使用と同じ累積Host ÷ 予測総Hostとし、Host予測を算出できない間はdomainの損耗（domain別の予測があれば先に尽きるdomain）を使用する。Percentage Usedとの比較には常にdomainの損耗を使用する。

#### TLCとpSLCを並べる表示

先に尽きる方のみを表示すると、2つのdomainがほぼ同時に尽きる場合でも片方しか表示されない。
参照機（2026-10-01）はTLC 5.6%・pSLC 5.5%で、Host換算の残量はTLC約1.11 PB・pSLC約1.12 PBと差が1%ほどしかない。
そこで寿命予測カードではHost基準の実使用行のすぐ下に、TLCとpSLCの横棒を左右に並べて配置する（`DomainForecastRow`）。

* 単位はNAND書込量。`使用量 / 総量` の総量は「目標P/E × domain容量」で、書込量カードの内訳（TLC・pSLC）と同じ値になる。
* 横棒は現在の平均P/E ÷ 目標P/E。残量は（目標P/E − 現在の平均P/E）× domain容量で、換算比を使用しない。
* 年数は残量をそのdomainの書込/Host（上の `a_TLC`・`a_pSLC`）でHost換算し、現在のHost書込ペースで割る。
* Host基準の実使用行の残量は各domainのHost換算のうち小さい方と同じ値である。TLCとpSLCはP/Eの刻みが異なるため、僅差の順位や基準への到達は故障を意味しない。
* 計算は1系統のみで、30日経過した時点で別の方式へ切り替えることはしない。TLC配分は最初のFTL取得から全期間比で算出でき、
  直近比はpSLCのP/Eが窓内で50以上進むと、ForecastWAFと同じ重みqで段階的に加わる。
* 直近比はTLCのP/EではなくNAND書込量とpSLCのP/Eから求める。TLCのP/Eは数日に1しか進まず、
  短い窓では配分が数十%揺れるためである。参照機の7日・14日の窓では、TLCのP/Eから求めた比と平均は同じで、
  ばらつきは半分以下だった（2026-10-17）。NAND書込量にはTLC・pSLC以外の書込も含まれるが、
  生涯では容量 × 平均P/Eとの差が約1%で、偏りは小さい。
* 参照機では、直近の書込がpSLC寄りのため、この見直しで律速がTLCからpSLCに切り替わり、
  残Hostは約1.11 PBから約1.09 PBになった（2026-10-17）。
* TLCの平均P/Eは整数で、参照機では約3日に1しか進まない。そのため日付はTLCのP/Eペースではなく、
  連続して取得できるSMARTのHostペースから算出する。
* FTLがない場合（SMARTのみ・参考TBW）は表示しない。

Client負荷・保持考慮・参考基準の行はHost基準のままにする。市販品のTBWもClientのWAFも定義上Host量で、
TLC基準に換算するにはTLCへの配分の仮定がもう1つ必要となるためである。

* 参考基準：2026-10-12からNAND世代と論理容量による参考TBWへ統一した。Apple SSDの定格ではなく、NAND未登録時の既定値使用も明示する（REFERENCE_TBW.md）。
* Client負荷：WAF 3〜4はTLCとpSLCを合わせた比で、配分は公表されていない。この行は本機の配分が続くと仮定している。

寿命予測カードの行は上から「実使用」（とTLC・pSLCのNAND横棒）、「保持考慮」（日数・温度）、
「クライアント負荷」（WAF 3.5）、「参考基準」（採用したTBW）の順に並べる。名称と条件を分離し、詳細は行と見出しの情報ボタンにまとめる。
表示用語は [FORECAST_UI_TERMINOLOGY.md](FORECAST_UI_TERMINOLOGY.md) を参照。行は表示名ではなく種類（`Projection.Kind`）で選択する。

* 実使用行は観測量ベースの `ForecastWAF` を使用する。
* Client行も保持補正なし（Kret = 1）で、違いは将来WAFの3.5（比較レンジ3–4）のみである。
  「今後Client負荷・Hostペースは共通」の反実仮想である。
* 保持考慮の行はTLCのみに適用する別の仮想シナリオである。保管温度は利用者の明示的な指定、
  通電中の低負荷時の実測温度、保存済みの低負荷候補、JEDEC Clientの30°Cの順に選択する。
  選択方法の詳細は [RETENTION_RESEARCH_ESTIMATE.md](RETENTION_RESEARCH_ESTIMATE.md) を参照。
* 現在P/Eがtarget/EOLに達したdomainの残量は0。0書込ペースなら日付未算出として表示する。

Direct topologyが欠ける、境界・積が不正、またはIORegistry geometryとの不整合が確認された
場合は、中央予測を `N / u` の**「domain配分未取得・累積損耗概算」**へ戻す。80-band
当てはめはこのfallbackの入力にも戻さない。

## 残差とWAF成分

Direct topologyから再構成した既知domain使用量を `Nknown`、累積NANDを `Nmeasured` とする。

```text
signed residual = Nmeasured - Nknown
current reconstruction error = |Nknown - Nmeasured| / Nmeasured
budget reconciliation error = |Direct baseline budget - (N/u budget)| / (N/u budget)
```

符号付き残差はUtility/Special bandsや「約1 pSLC band」へ自動配賦しない。予算にも加算せず、
raw pSLC相当band数とDirect band数との差としてResearchに残す。再構成誤差と従来`N/u`予算の
比較誤差は別の値であり、前者が小さいことを容量の独立検証とは呼ばない。

既存の`WriteAmp`と`IntermediateWriteAmp`はerase/geometryから再構成した成分として表示する。

```text
component residual = total WAF - native component - intermediate component
```

全体WAFの0.5%以内の小さな負残差は丸め・取得時差の許容として0に表示し、それを超える負値は
不整合として保持する。成分WAF、Direct→TLC raw、
保存済み試験WAFはForecastWAFへ直接代入しない。

## FTLの信頼性イベントの根拠

比較は同じdevice、artifact、build、firmware epoch、extraction/format、keyの対応表を満たす
時刻順のDirect FTL snapshotのみで行う。初回は「比較履歴なし」とし、時刻逆転・同秒重複、
Host/NAND書込みcounterの減少は新系列として区間全体を無効にする。

個別イベントcounterの減少、NAND-read counterの減少、refresh tier配列の形状変更は、
**そのcounterのみ**を比較から除外する。他の比較可能なcounterは継続し、除外理由を
Researchに表示する。

* 回復活動: age/background refresh、age padding、read verify。
* 信頼性イベント: UECC、read-verify failures、grown bad blocks、die failures。
* 「取得範囲で新規イベントなし」は、比較できたcounterに増加がない意味であり、未取得項目を
  含めた全項目正常ではない。

差分には日あたりrateとNAND readあたりrateを分けて表示する。分母が0または取得不能なら
該当rateは算出しない。研究用軽量試験と重なる区間のイベントは履歴として残し、試験由来の
可能性を表示する。いずれのイベントもTBW倍率を自動変更しない。

## UIと履歴

通常画面には4つのHost予測の行とTLC・pSLCのNAND横棒に加え、Direct domain基準予算、
実測累積NAND、推定使用量、残量（保持補正なし）をコンパクトに表示する。Researchでは次を確認できる。

* Direct topologyの対応表、IORegistry照合、79対逆算約80の比較、pSLC物理占有量。
* TLC/pSLCの容量、現在/EOL/目標P/E、予算、使用量、残量。
* 符号付き残差、二種類の整合誤差、WAF成分残差、bottleneck比較。
* refresh/read recovery/failure/write-path/histogramのraw値と比較状態。
* 未照合keyと、個別counterを比較除外した理由。

解析は取得・履歴・設定変更時にバックグラウンドで更新し、画面再描画ごとに全履歴を走査しない。
収集間隔、通常のsmartctl/ioreg収集はv2.4で変更しない。（アプリ内の軽量試験の実行機能はその後削除した。保存済みの試験sessionは、重なる区間の識別のために読み込む。）

## 回帰検証

自動テストでは少なくとも次を固定する。

* `722/1/80` から79 pSLC / 642 TLC、128 MiB / 384 MiB bandを再現する。
* 逆算80-band proxyを保持しても、中央予算が79-band Direct topologyを使用する。
* 不正境界、IORegistry mismatch、EOL到達/超過、Direct欠測fallback、残差非加算。
* 保持設定を変更しても実使用・Clientの両行は変化せず（Kret = 1）、研究用の値と保持考慮の行のみが変化する。
* TLC配分が出せない場合も保持補正をかけず、系列の保留中はすべてのHost予測を出さない。
* WAFの変更がNAND予算を変えず、各総Hostが累積Host+残Hostになる。
* duplicate key、ゼロscalar、oversize histogram、empty/all-zero histogram、旧JSON読込み。
* v2.4.1 histogram名、Direct FTL context、必要保持日数と観測OFF期間の分離、pSLC保持係数1。
* 初回、系列reset、個別counter減少、研究試験重複、hard eventとrecoveryの分離。

この仕様の入力・仮定・未確認範囲をUIと履歴で辿れることを、v2.4の完了条件とする。
