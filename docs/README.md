# ドキュメントの目次

[English](README.en.md) · [プロジェクトのREADME](../README.ja.md)

この目次と、以下の入門文書7本には日本語版と英語版があります。プロジェクトの[README](../README.ja.md)、[貢献の手引き](../CONTRIBUTING.ja.md)、[セキュリティ方針](../SECURITY.ja.md)、[第三者ソフトウェアの表記](../THIRD_PARTY_NOTICES.ja.md)にも英語版があります。既存の日本語文書のパスは変更せず、英語版のファイル名には `.en.md` を付けます。詳細な研究仕様は当面日本語のみです。現行の動作を説明する文書と、過去の設計・検討の記録は区別して扱います。

## はじめに読む

- [寿命予測の読み方](FORECAST_GUIDE.md)：実使用・保持考慮・クライアント負荷・参考基準の違い、総量・残量・日付と信頼度。
- [データ取得の仕組み](DATA_ACQUISITION.md)：SMART・IORegistry・Direct FTLとリアルタイムI/O。取得間隔・権限・確認用コマンド。
- [Direct FTLの照合仕様](DIRECT_FTL_CROSS_VALIDATION.md)：保存前の確認と、取得値・予測入力の違い。
- [他環境の診断レポート](DIAGNOSTIC_REPORTS.md)：共有項目、個人情報の扱い、報告手順。
- [計測履歴の可逆集約](LOSSLESS_HISTORY_STORAGE.md)：バックアップの範囲、復旧、メモリ上の扱い。
- [ASP probe署名検証](PROBE_SIGNATURE.md)：実行前の確認とアドホック署名の限界。

## 詳細仕様（日本語）

- [ディスクと取得先の対応付け](STORAGE_TARGET_BINDING.md)：SMART・FTL・NAND情報の対象固定、複数候補とnamespaceの保留、診断レポートの範囲。
- [NAND Model v2.4.1](NAND_MODEL_V2_4.md)：現行の寿命予測の計算と、Direct FTLの取得条件。

## 寿命予測

- [寿命予測の根拠とダッシュボードの分担](ENDURANCE_FORECAST_EVIDENCE_PLAN.md)：到達日、WAFの期間、空き容量の扱い。
- [寿命予測の計算の構成](ENDURANCE_CORE_ARCHITECTURE.md)：計算を分担する部品の構成。
- [参考TBWとワークロードの前提](REFERENCE_TBW.md)：ダッシュボードの比較基準、FTL不足時の暫定推定と、その出典。
- [保持の研究推計](RETENTION_RESEARCH_ESTIMATE.md)：「保持考慮」の行と、保持の研究用の診断。
- [寿命予測の表示用語](FORECAST_UI_TERMINOLOGY.md)：短い表示名、説明の階層、研究仮定の説明。

## FTLの時系列と連続性

- [計測器境界の連続性](INSTRUMENT_BOUNDARY_CONTINUITY.md)：macOS・ファームウェア・取得経路の更新をまたぐ際の確認と、学習除外の規則。
- [Direct FTL 時系列解析](FTL_TIME_SERIES_ANALYSIS.md)：区間の差分と残差の扱い。
- [長基線 NAND 残差](FTL_LONG_BASELINE_RESIDUAL.md)：長い期間での再構成の残差。
- [Direct FTLの照合仕様](DIRECT_FTL_CROSS_VALIDATION.md)：取得のたびに行うSMARTとの照合、補助の比較、残差の扱い。

## 画面

- [ダッシュボードの信頼性表示](DASHBOARD_RELIABILITY_INDICATORS.md)：SMARTの警告、FTLの異常counter（内部エラー）、保持処理とそのペース、簡易チェックを分けて示す範囲と限界。
- [書込量グラフの読み方](WRITE_GRAPH_DOMAIN_DISPLAY.md)：Host／NANDの差分と累計、TLC／pSLCの推定内訳、期間別のWAF。

## ハードウェアと安全

- [Apple Silicon内蔵SSDのハードウェア](APPLE_SSD_HARDWARE.md)：公開情報から判明している機種別のコントローラとNAND。診断レポートで補いたい項目。
- [ASP probe署名検証](PROBE_SIGNATURE.md)：probeを起動する前の確認。
- セキュリティの考え方は [SECURITY.ja.md](../SECURITY.ja.md) を参照してください。

## 履歴の保存とメモリ

- [計測履歴の可逆集約](LOSSLESS_HISTORY_STORAGE.md)：観測点を減らさない保存形式、旧履歴からの移行、復旧とバックアップの範囲。

## 開発・公開・配布

- [他環境の診断レポート](DIAGNOSTIC_REPORTS.md)：取得・共有・保守側の確認とプライバシー上の制約。
- [英語UIの用語と実装方針](UI_LOCALIZATION.md)：日本語から英語へ展開する際の表示・単位・日時・互換性。
- [メニューバーポップの外観](MENU_BAR_APPEARANCE.md)：標準メニューの角・影を維持した外観設定の反映と、実描画の検証。
- [実験版の作成と初回起動](EXPERIMENTAL_RELEASE.md)：UIと文書の整備後に行う最終工程。

ライセンスの正文はMITの[LICENSE](../LICENSE)です。[アイコンとロゴのライセンス](../Resources/NenRingIcons/LICENSE.md)は別に定めています。
