import SwiftUI

/// Display labels only. Persisted private-key names and event identities are
/// unchanged, and an unknown name is never assigned a guessed meaning.
enum ReliabilityMetricLabel {
    static func text(_ raw: String, language: String? = nil) -> String {
        let labels = [
            "UECC": "訂正不能読出し（UECC）",
            "UECC reads": "訂正不能読出し（UECC）",
            "Utility UECC": "Utility訂正不能読出し",
            "Utility UECC reads": "Utility訂正不能読出し",
            "Cross-temperature UECC": "温度差関連UECC",
            "Cross-temperature RAID UECC": "温度差関連RAID UECC",
            "Grown bad blocks": "使用後の不良ブロック",
            "Die failures": "NAND die障害",
            "Host pSLC read verify failure": "Host pSLC読出し検証失敗",
            "Host pSLC read verify failures": "Host pSLC読出し検証失敗",
            "Host TLC read verify failure": "Host TLC読出し検証失敗",
            "Host TLC read verify failures": "Host TLC読出し検証失敗",
            "GC pSLC→TLC read verify failure": "GC pSLC→TLC読出し検証失敗",
            "GC pSLC→TLC read verify failures": "GC pSLC→TLC読出し検証失敗",
            "GC TLC→TLC read verify failure": "GC TLC→TLC読出し検証失敗",
            "GC TLC→TLC read verify failures": "GC TLC→TLC読出し検証失敗",
            "Age refresh": "時間の経過による書き直し",
            "Background refresh moves": "バックグラウンドでの移し替え",
            "Bands padded for age": "書きかけ領域を閉じる処理",
            "Read verify native": "TLC読出し検証",
            "Read verify pSLC": "pSLC読出し検証",
            "Reduced read verify native": "TLC読出し検証（reduced）"
        ]
        return UIString.text(labels[raw] ?? raw, language: language)
    }

    /// A plain explanation for the retention counters whose names alone say
    /// little. Their meaning is read from the name, not confirmed, so the
    /// wording stays tentative; nil for counters without one.
    static func explanation(_ raw: String, language: String? = nil) -> String? {
        let explanations = [
            "Age refresh": "書き込んでから時間がたったデータを、保持のために書き直したと考えられる回数",
            "Background refresh moves": "SSDが自分でデータを別の場所へ移したと考えられる回数",
            "Bands padded for age": "書きかけのまま時間がたった場所の残りを埋めて、閉じたと考えられる領域の数",
            "Reduced read verify native": "reducedの意味がまだ分からないため、元の名前で表示しています"
        ]
        return explanations[raw].map { UIString.text($0, language: language) }
    }
}

extension View {
    /// Shows `ReliabilityMetricLabel.explanation` on hover when there is one.
    @ViewBuilder
    func reliabilityMetricHelp(_ raw: String) -> some View {
        if let explanation = ReliabilityMetricLabel.explanation(raw) {
            help(explanation)
        } else {
            self
        }
    }
}
