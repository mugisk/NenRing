# 参考TBWとワークロードの前提

ここに記載する値はダッシュボードの参考基準と、損耗の実測がまだない段階の暫定推定に使用する計画用の参考値です。**Appleの定格値や保証値ではありません。** 実装は `ReferenceTBW.swift` です。

## 予測の根拠の切り替え

取得できるデータに応じて、予測の根拠を次のように切り替えます。

| 状態 | 予測の根拠 | 表示 |
|---|---|---|
| 確認済みのDirect FTLがある | NANDのdomain予算（FTL実測） | 実使用 |
| FTLなし・Percentage Usedが2%以上 | SMART（累積Host書込 ÷ Percentage Used） | 実使用（暫定・SMARTのみ） |
| FTLなし・Percentage Usedが0〜1% | **参考TBW**（NAND世代と容量から） | 実使用（暫定・参考TBWから） |

参考TBWを使用する場合の範囲は、次のとおりです。

- **Apple内蔵SSD**：総量を、市販品からの比較基準から、参照機1台からの外挿値（後述）までの幅で示します。日付・残り期間・メニューバーの年数のように1つの値が必要な箇所では、控えめな側の比較基準を使用します。この幅はApple SSDで確認した下限や統計的な信頼区間ではありません。
- **それ以外のSSD**：下限が参考値の⅔（例：600に対して400）、中心と上限が参考値。同じNAND世代でも、メーカーによって定格はおよそ400〜1000 TBW/TBの幅があります。

## NAND世代ごとの参考TBW

NANDはIORegistryの `vendor-name` と `nand-marketing-name` から判定します。表にないNANDには **600 TBW/TB** を使用します。一般的なクライアント向けの定格です（例：1 TB品で600 TBW）。

容量はMacの容量に最も近い市販品の容量（対数で比較）を使用します。

| NAND | IORegistryでの判定 | 同世代の市販品 | TBW/TB（容量別） | 確度 |
|---|---|---|---|---|
| SK hynix 128層TLC（V6） | `hynix` / `tlc_3d_v6*` | SK hynix Gold P31：500 GB = 500 TBW、1 TB = 750、2 TB = 1200 | 1000 / 750 / 600 | 高 |
| SK hynix 176層TLC（V7） | `hynix` / `tlc_3d_v7*` | SK hynix Platinum P41：同じ定格 | 1000 / 750 / 600 | 中（報道値） |
| Kioxia/SanDisk BiCS4（96層） | `toshiba`/`kioxia`/`sandisk` / `tlc_3d_g4*`・`itlc_3d_g4*` | WD Blue SN550 1 TB = 600 TBW | 600 | 中 |
| Kioxia/SanDisk BiCS5（112層） | 同上 / `tlc_3d_g5*`・`itlc_3d_g5*` | WD Black SN770 1 TB = 600 TBW | 600 | 中 |
| Kioxia BiCS8（218層） | `toshiba`/`kioxia`/`sandisk` / `tlc_3d_g8*` | Kioxia EXCERIA PRO G2 = 600 TBW/TB | 600 | 中（M5 MacBook Airで確認） |
| Samsung V-NAND TLC（`g7`） | `samsung` / `tlc_3d_g7*` | Samsung 990 PRO = 600 TBW/TB | 600 | 低（世代の対応は未確認。M5 MacBook Airで確認） |

例：参照機（256 GB・Hynix V6）は500 GBの区分に該当するため、1000 TBW/TB × 0.256 TB = **256 TB** になります。2026-10-12からダッシュボードの「参考基準」も同じresolverを使用します。旧250 TBの固定比較は現行表示から廃止し、過去仕様は変更しません。M世代のみで値を決定せず、その個体のIORegistry情報と論理容量から選択します。未登録NANDは既定値と明示します。世代の対応が未確認のエントリは、対応を保証するものではありません。

参考行の残量は `max(0, 参考TBW − 予測で採用した累積Host)`、日付は既存の現在／長期書込ペースから算出します。保持補正・試験WAF・参照機からのApple外挿値はこの行へ加えません。実使用予測の入力が境界前で停止している場合も、その採用Hostに統一します。

世代対応が未確認のエントリは、結果の `generationMappingUnverified` にその状態を引き継ぎます。現在はSamsung `g7` が該当し、画面の参考基準の情報ボタンの説明にも「世代対応未確認の市販品参考値」と表示します。数値は参考値として表示しますが、対応が確認できたエントリと同じ説明にはしません。NAND未特定の既定値は別の状態です。

出典：

- SK hynix Gold P31 製品ページ（NANDは「SK hynix 128L 3D TLC」、2 TB = 1200 TBW）：https://ssd.skhynix.com/gold_p31/。500 GBと1 TBの定格はレビュー記事（StorageReview、TechPowerUp）によります。
- Macに搭載されているNANDは、公開されているIORegistryの実例から収集しました。機種ごとの表と出典は [APPLE_SSD_HARDWARE.md](APPLE_SSD_HARDWARE.md) にあります。
- 同じNAND世代でも市販品の定格はメーカーによって異なります。例えばBiCS4品は400 TBW/TB（Kioxia EXCERIA PLUS）から600（WD Blue SN550）まであります。不足する部分は診断レポートで補います。

## 参照機からの外挿（暫定値の幅の上側）

参照機ではTLC書込/Host比を約0.66として観測しています。暫定推定ではこの比と3000 P/Eを他のApple内蔵SSDへ転用します。256 GBの例では約1.17 PBになりますが、これは保持条件を検証した市販品の定格とは別の値です。市販品のTBWがApple SSDを一律に過小評価すると判断する根拠にはしません。

そこで、この値は幅の上側としてのみ示し、日付の計算には使用しません。式は次のとおりです。

```text
Appleの実測傾向 = 容量 × 3000 P/E ÷ 0.66（参照機のTLC書込/Host）
```

0.66は参照機1台の値です。他機種への転用と3000 P/Eの採用は仮定であり、診断レポートを用いて適用範囲を検証する必要があります。

## クライアントワークロードのWAF

| 値 | 用途 | 出典 | 状態 |
|---|---|---|---|
| 約2（代表値）、1.8〜2.2（sTLCの実測） | 一般的なクライアントのWAF | NI「LabVIEW Real-Timeシステムでのフラッシュストレージの予想寿命を理解する」（2025-10-30更新）の「ライトアンプリフィケーションファクターとデータワークロード」節：JESD219 ClientのWAFは約2。https://www.ni.com/ja/support/documentation/supplemental/12/understanding-life-expectancy-of-flash-storage.html ／ Advantech SQFlash 640-C データシート Rev 1.3（2021-05-02）7ページ：JEDEC 219 Client Workloadで7日間実測、3D sTLC（BiCS4）のWAFは1.8〜2.2。https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/7188/SQF-SMSZ2-64.pdf | 確認済み |
| 2.5〜3.0（TLCの実測） | TLCとして使用した場合のクライアントWAF | 同じAdvantechのデータシート：3D TLC（BiCS4）のWAFは2.98（256 GB）、2.52（512 GB）、2.54（1 TB） | 確認済み |
| 3.5（範囲3〜4） | Client負荷シナリオ（保守側） | Micronブログ「Tackling SSD endurance made me a better product manager」（2024-08-27）：典型的なクライアント負荷のWAFは3〜4程度。https://www.micron.com/about/blog/storage/ssd/tackling-ssd-endurance-made-me-a-better-product-manager | 確認済み（ホワイトペーパーではなくブログ） |

WAFは容量、予備領域、空き容量によって変化します。特定のMacの性質ではなく、シナリオの入力として扱ってください。

### 定格TBWとP/Eの関係

Advantechのデータシートには `TBW = NANDのP/E × 容量 ÷ WAF` という式が記載されており、3D TLCの表は3000 P/Eで計算が合います（例：3000 × 0.256 TB ÷ 2.98 ≈ 258 TBW。表の256 GB品の値と一致）。

JEDECはTBWを「電源を切った状態での保持要件（クライアントは30°C・1年）を満たしたまま書き込めるHost量」と定義しています（Alvin Cox「JEDEC SSD Specifications Explained」25〜26ページ：https://www.jedec.org/sites/default/files/Alvin_Cox%20[Compatibility%20Mode]_0.pdf ）。

この2つを合わせると、少なくともこのメーカーは3D TLCを3000 P/E・30°C1年保持として定格を付けていることになります。256 GBで約258 TBという値は、上のGold P31からの参考値（256 TB）とも一致します。

JEDECの解説資料には損耗の偏りに備えて2倍の余裕を見込む式（`TBW < 容量 × 書換能力 ÷ (2 × WAF)`）も記載されています。こちらは最も酷使されたブロックを基準にした考え方です。参照機の最大P/Eと平均P/Eの差は約1.1倍しかありません。

## Percentage UsedとData Units Written（NVMe）

どちらもNVMeのSMART／Health Informationログ（ログページ02h）の項目です。

- **Data Units Written**：Hostの書込量を1000 × 512バイト単位（切り上げ）で数えた値です。
- **Percentage Used**：定格寿命のうちどれだけ使用したかを、メーカーが独自に推定した値です。100を超えることもあり、故障を意味するわけではありません。整数で報告されるため、新しいMacでは長期間0〜1%のままになります。
