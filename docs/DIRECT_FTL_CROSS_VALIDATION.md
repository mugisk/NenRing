# Direct FTL / SMART照合

[English](DIRECT_FTL_CROSS_VALIDATION.en.md) · [文書の目次](README.md)

## 保存前の確認

手動・定期取得とも、同じ保存前処理で確認する。対象OSと取得間隔は[データ取得の仕組み](DATA_ACQUISITION.md)を参照する。

1. 正で有限のEOL、有限で非負の平均P/E、平均≤最大を確認する。EOLへの到達や超過のみでは解析失敗としない。
2. 同device・取得時刻差24時間以内のSMARTを用い、Host Writesの差が `max(SMART Host × 1%, 5 GB)` 以下であることを確認する。
3. NANDがHostの半分未満でないことを確認する。容量×平均P/Eによる再構成量が1 TB以上なら、NANDがその0.5〜2倍の範囲内かも確認する。単位の大きな取り違えを検出する幅であり、容量配分や全keyの意味を独立に保証するものではない。
4. POHはFTLとSMARTの値の一致を要求せず、前回からのoffset変化を検査する。

```text
offset = FTL POH − SMART POH
変化 = abs(offset_now − offset_previous)
許容 = 2 h + (現在と前回のFTL/SMART取得時刻差の絶対値の合計) / 3600
```

前回のDirect FTLに最も近い、同device・24時間以内のSMART（現在SMARTより前）を参照する。FTLとSMARTそれぞれのPOH逆行も失敗とする。失敗時は保存せず、自動取得を停止する。初回やPOH欠測・参照不足ではPOH比較のみを保留し、Host照合を通過していれば、この保留が保存を妨げることはない。安定した固定offsetを異常としない。取得時刻差は実際の通電時間差の上限として使用し、スリープ中の通電時間を仮定しない。

Host照合に必要なSMARTが欠ける、古すぎる、別deviceである場合は保存を保留するが、それのみでスケジュールを停止しない。比較先のSMARTが2分より古いときのHost書込量の不一致も、間の書込で説明できるため同様に保留する。これらの検査のみで全private keyの意味を保証できるわけではない。境界D1〜D7とcontinuity laneによる予測現在値・率学習の保護は維持する。

## 補助観測

- key431 Controller Percent UsedとSMART Percentage Usedの差。
- key430 pSLC Percent Usedと `100 × pSLC avgPE / pSLC EOL` の差。

差の単位はpercentage point（pp）。値の定義や丸め方式が同じとは確定していないので、差を表示するが、閾値で保存停止・信頼度昇格・TBW倍率変更を行わない。欠測は0で補完しない。入力FTL／SMART日時を併記する。

SMARTのData Units WrittenはHost Writesであり、物理NAND Writesではない。SMARTのHost Reads、Media Errors等を定義の異なる内部read／UECC counterへ直接一致させない。

## 境界と残差

ResearchのRaw DataとResidualに共通の照合表示を置く。解析は既存バックグラウンド再計算に組み込み、描画中に履歴を走査しない。

- 生涯残差：既存の `Nmeasured − Σ(capacity × avgPE)`。N/uから容量を逆算して照合する循環検算は使用しない。
- D7：最後の計測境界の既存検査結果。±0.5 P/Eの量子化範囲の連続性を表示する。
- 区間残差：最新の検証済みlane区間のbest値と量子化範囲を表示する。最新区間が比較不能なら古い区間を現在値に代用しない。
- 同区間のAge／BG／error refresh増分をrawで併記する。相関のみで残差の原因や同一単位を断定しない。

最新rawの補助照合と、検証済み予測入力／区間の日時を分ける。pending／failed境界後のrawを主予算の現在値に混ぜない。未同定残差を予算に加算せず、予測倍率も変更しない。保存済み原履歴は書き換えない。
