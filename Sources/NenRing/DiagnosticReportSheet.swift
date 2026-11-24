import AppKit
import SwiftUI

/// Walks a contributor through sharing a diagnostic report: what is inside,
/// saving it, and opening a GitHub issue to attach it to. The app never
/// uploads the file itself.
struct DiagnosticReportSheet: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: DiagnosticReport?
    @State private var savedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            localizedText("診断レポートを提供する")
                .font(.title3.weight(.semibold))
            localizedText("ほかのMacやmacOSでも予測が正しく動くかを確かめるために使います。ファイルを保存して、GitHubのIssueに添付してください。")
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(DiagnosticReportSharing.summary(for: report), id: \.label) { item in
                        GridRow {
                            localizedText(item.label)
                                .foregroundStyle(AppColor.textSecondary)
                            localizedText(item.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(UIString.text("含まないもの：シリアル番号、デバイスパス、デバイスID"), systemImage: "lock")
                Label(UIString.text("含むもの：SSDの使用量（稼働時間、書込量）。日付は日単位に丸めます"), systemImage: "info.circle")
                Label(UIString.text("アプリから自動で送信することはありません"), systemImage: "hand.raised")
            }
            .font(.callout)
            .foregroundStyle(AppColor.textSecondary)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "ファイルを保存します") {
                    HStack {
                        Button(UIString.text("保存…")) { save() }
                            .disabled(report == nil)
                        if let savedURL {
                            Button(UIString.text("Finderで表示")) {
                                NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                            }
                        }
                    }
                }
                step(2, "GitHubでIssueを開き、保存したファイルを本文の欄へドラッグします") {
                    Button(UIString.text("GitHubでIssueを開く")) {
                        if let report { NSWorkspace.shared.open(DiagnosticReportSharing.issueURL(for: report)) }
                    }
                    .disabled(report == nil)
                }
            }

            if let savedURL {
                Label(UIString.format("保存しました：%@", savedURL.lastPathComponent), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColor.positive)
            }
            if let errorMessage {
                Label(UIString.message(errorMessage), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColor.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                localizedText("Issueと添付ファイルは誰でも見られます。")
                    .font(.caption)
                    .foregroundStyle(AppColor.textMuted)
                Spacer()
                Button(UIString.text("閉じる")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { report = model.makeDiagnosticReport() }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number).")
                .font(.callout.monospacedDigit().weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                localizedText(title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func save() {
        guard let report else { return }
        do {
            if let url = try model.saveDiagnosticReport(report) {
                savedURL = url
                errorMessage = nil
            }
        } catch {
            errorMessage = "診断レポートを保存できませんでした: \(error.localizedDescription)"
        }
    }
}
