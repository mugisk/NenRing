import Foundation

/// Presentation only. Persisted evidence and original diagnostic text are unchanged.
extension DirectFTLContractStatus {
    func displayDetail(language: String? = nil) -> String {
        let selected = language ?? UIString.selectedLanguage
        if selected.lowercased().hasPrefix("ja") { return detail }
        func text(_ key: String) -> String { UIString.text(key, language: selected) }
        func format(_ key: String, _ values: CVarArg...) -> String {
            String(format: text(key), locale: Locale(identifier: "en_US"), arguments: values)
        }
        switch self {
        case .noSnapshot:
            return text("Direct FTL snapshotがありません。SMART監視は継続しています。")
        case let .validated(build, contract, topology, telemetry, hardwareReviewed):
            let runtime = DirectFTLContractRegistry.reviewed25G83.isReviewedRuntime(build)
                ? format("実行build %@ 検証済み", build)
                : format("実行build %@（対応表のbuild %@・未確認）", build, DirectFTLResearchContract.reviewedBuild)
            return "\(runtime) / \(contract) · \(text(topology ? "topologyあり" : "topology未取得")) · \(text(telemetry ? "reliabilityあり" : "reliability未取得"))"
                + (hardwareReviewed ? "" : " · " + text("SSDコントローラ未検証（キーの意味が異なる可能性）"))
        case let .unsupportedBuild(expected, actual):
            return format("現在のbuild %@ は未検証です。%@専用のkey意味付け・損耗予測・reliability比較を停止しています。手動の構造再検証が必要です。", actual ?? text("不明"), expected)
        case let .contractUnavailable(build):
            return format("build %@ ですがkeyの対応表を取得できません。private bufferは保存しても意味付け・予測へ投入しません。", build)
        case let .contractMismatch(expected, actual):
            return format("keyの対応表 %@ は未確認です。想定する対応表は %@ で、意味付け・予測へ投入しません。", actual, expected)
        }
    }
}

extension LongBaselineKind {
    var displayTitle: String {
        if case let .segment(index) = self { return UIString.format("非重複セグメント %d", index + 1) }
        return UIString.text(title)
    }
}
