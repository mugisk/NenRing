import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 5) {
                    Text("NenRing")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                    Text("Apple Silicon SSD telemetry & endurance")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColor.textSecondary)
                    Text(AppVersion.detailLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppColor.textPrimary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }

            Divider()
                .padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 8) {
                AboutDetailRow(label: "対応環境", value: "macOS 14以降 / Apple Silicon")
                AboutDetailRow(label: "データ", value: "このMac内に保存")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(UIString.text("閉じる")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppColor.surfaceRaised)
        .preferredColorScheme(nil)
    }
}

private struct AboutDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            localizedText(label)
                .foregroundStyle(AppColor.textSecondary)
                .frame(width: 72, alignment: .leading)
            localizedText(value)
                .foregroundStyle(AppColor.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}
