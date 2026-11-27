# ドキュメントの目次

[English](README.en.md) · [プロジェクトのREADME](../README.ja.md)

この目次に掲載している文書は日本語と英語で参照できます。

## はじめに読む

- [寿命予測の読み方](FORECAST_GUIDE.md)：実使用・保持考慮・クライアント負荷・参考基準の違い、総量・残量・日付と信頼度。
- [データ取得の仕組み](DATA_ACQUISITION.md)：SMART・IORegistry・Direct FTLとリアルタイムI/O。取得間隔・権限・確認用コマンド。
- [Direct FTLの照合仕様](DIRECT_FTL_CROSS_VALIDATION.md)：保存前の確認と、取得値・予測入力の違い。
- [他環境の診断レポート](DIAGNOSTIC_REPORTS.md)：共有項目、個人情報の扱い、報告手順。
- [計測履歴の可逆集約](LOSSLESS_HISTORY_STORAGE.md)：バックアップの範囲、復旧、メモリ上の扱い。
- [ASP probe署名検証](PROBE_SIGNATURE.md)：実行前の確認とアドホック署名の限界。

## 寿命予測の根拠

- [NAND Model v2.4.1](NAND_MODEL_V2_4.md)：現行の寿命予測の計算と、Direct FTLの取得条件。
- [参考TBWとワークロードの前提](REFERENCE_TBW.md)：ダッシュボードの比較基準、FTL不足時の暫定推定と、その出典。
- [保持の研究推計](RETENTION_RESEARCH_ESTIMATE.md)：「保持考慮」の行と、保持の研究用の診断。

## 画面

- [ダッシュボードの信頼性表示](DASHBOARD_RELIABILITY_INDICATORS.md)：SMARTの警告、FTLの異常counter（内部エラー）、保持処理とそのペース、簡易チェックを分けて示す範囲と限界。

## ハードウェアと安全

- [Apple Silicon内蔵SSDのハードウェア](APPLE_SSD_HARDWARE.md)：公開情報から判明している機種別のコントローラとNAND。診断レポートで補いたい項目。
- セキュリティの考え方は [SECURITY.ja.md](../SECURITY.ja.md) を参照してください。

ライセンスの正文はMITの[LICENSE](../LICENSE)です。[アイコンとロゴのライセンス](../Resources/NenRingIcons/LICENSE.md)は別に定めています。
