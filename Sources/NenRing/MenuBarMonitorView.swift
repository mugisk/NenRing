import AppKit
import SwiftUI

@MainActor
private enum NenRingMenuBarIcon {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "nenring-menubar",
            withExtension: "svg",
            subdirectory: "NenRingIcons"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

private struct NenRingMenuBarGlyph: View {
    var body: some View {
        Group {
            if let image = NenRingMenuBarIcon.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "internaldrive.fill")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 18, height: 18)
        .foregroundStyle(AppColor.textPrimary)
        .accessibilityHidden(true)
    }
}

/// Status shown in the menu bar and at the top of the popup.
struct MenuBarStatus {
    let title: String
    let color: Color
    /// True when the status needs attention (warning, partial data, failure).
    let needsAttention: Bool

    @MainActor
    init(model: DashboardModel) {
        var failed = false
        if case .failed = model.state { failed = true }
        self.init(isRefreshing: model.isInteractiveRefreshing, failed: failed,
                  failure: model.lastSmartctlFailure, evaluation: model.currentEvaluation,
                  hasSnapshot: model.snapshot != nil)
    }

    /// A SMART warning from the last reading outranks a later failed read:
    /// the drive still needs attention, and the failure is shown in the
    /// popup and on the dashboard.
    init(isRefreshing: Bool, failed: Bool, failure: SmartctlServiceError?,
         evaluation: HealthEvaluation?, hasSnapshot: Bool) {
        if isRefreshing {
            self.init(title: "更新中", color: AppColor.accent, needsAttention: false)
            return
        }
        if case .warning = evaluation {
            self.init(title: "警告", color: AppColor.red, needsAttention: true)
            return
        }
        if failed {
            self.init(title: failure == .executableNotFound ? "smartctl未導入" : "取得不可",
                      color: AppColor.amber, needsAttention: true)
            return
        }
        switch evaluation {
        case .normal:
            self.init(title: "正常", color: AppColor.positive, needsAttention: false)
        case .warning:
            self.init(title: "警告", color: AppColor.red, needsAttention: true)
        case .limited:
            self.init(title: "部分取得", color: AppColor.amber, needsAttention: true)
        case nil:
            self.init(title: hasSnapshot ? "監視中" : "待機中", color: AppColor.textMuted, needsAttention: false)
        }
    }

    private init(title: String, color: Color, needsAttention: Bool) {
        self.title = title
        self.color = color
        self.needsAttention = needsAttention
    }
}

/// The menu bar item. macOS draws only one image and one line of text for a
/// MenuBarExtra label, so the selected values are joined into one string and
/// a problem is shown by swapping the icon rather than by a coloured dot.
struct MenuBarStatusItem: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppIconController.preferenceKey) private var appIconAppearanceRaw = AppIconAppearance.system.rawValue
    var showsMetrics = true

    var body: some View {
        HStack(spacing: 4) {
            if status.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                NenRingMenuBarGlyph()
            }
            if showsMetrics, !labelText.isEmpty {
                Text(labelText)
                    .monospacedDigit()
            }
            if showsMetrics { RealtimeIOLabel(monitor: model.realtimeIO) }
        }
        .accessibilityLabel(accessibilityText)
        .help(accessibilityText)
        .onAppear {
            Task { @MainActor in
                AppIconController.applyCurrentPreference()
            }
        }
        .onChange(of: colorScheme) { _, _ in
            guard appIconAppearanceRaw == AppIconAppearance.system.rawValue else { return }
            Task { @MainActor in
                AppIconController.applyCurrentPreference()
            }
        }
        .onChange(of: appIconAppearanceRaw) { _, _ in
            Task { @MainActor in
                AppIconController.applyCurrentPreference()
            }
        }
    }

    private var status: MenuBarStatus { MenuBarStatus(model: model) }

    private var labelText: String {
        MenuBarLabelText.make(
            options: model.menuBarLabelOptions,
            temperatureCelsius: model.snapshot?.temperatureCelsius,
            wearFraction: model.headlineWearFraction,
            remainingYears: model.headlineRemainingYears,
            todayWrittenBytes: model.menuBarLabelOptions.todayWrites ? model.todayHostWrittenBytes : nil
        )
    }

    private var accessibilityText: String {
        var values = ["NenRing", UIString.readout(status.title)]
        if showsMetrics, !labelText.isEmpty { values.append(labelText) }
        return values.joined(separator: "。")
    }
}

/// The window actions of the popup. The popup is hosted in an NSMenu, which
/// has no SwiftUI scene, so the app passes the actions in.
struct MenuBarPopupActions {
    var showMainWindow: @MainActor () -> Void = {}
    var showSettings: @MainActor () -> Void = {}
    var showAbout: @MainActor () -> Void = {}
    var refresh: @MainActor () -> Void = {}
}

struct MenuBarMonitorView: View {
    @ObservedObject var model: DashboardModel
    /// Preview rendering must not start collectors or load the user's history.
    var startsMonitoring = true
    var windowActions = MenuBarPopupActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.lastSmartctlFailure == .executableNotFound {
                setupNotice
            } else if case .failed = model.state, model.snapshot != nil {
                VStack(alignment: .leading, spacing: 3) {
                    localizedText("前回取得した値を表示しています。")
                    if let date = model.lastSuccessfulRefreshAt {
                        Text(verbatim: UIString.format("最終成功 %@", UIString.dateTime(date)))
                    }
                }
                .font(.caption)
                .foregroundStyle(AppColor.amber)
            }
            lifespan
            if !model.analytics.nandEndurance.domainForecastRows.isEmpty {
                domainWear
            }
            metrics
            RealtimeIOPanel(monitor: model.realtimeIO)
            Divider()
            actions
        }
        .font(.system(size: 12))
        .foregroundStyle(AppColor.textPrimary)
        .padding(14)
        .frame(width: 320)
        .task {
            if startsMonitoring { await model.start() }
        }
    }

    private var status: MenuBarStatus { MenuBarStatus(model: model) }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // The icon and model name open the main window, as before.
            Button {
                showMainWindow()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    NenRingDeviceIcon(size: 46)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: model.snapshot?.model ?? UIString.text("ストレージを確認中"))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: UIString.format("最終取得 %@", lastRefreshText))
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(UIString.text("NenRingのメイン画面を開く"))
            .accessibilityLabel(UIString.format("%@。メイン画面を開く", model.snapshot?.model ?? UIString.text("ストレージを確認中")))
            Spacer(minLength: 4)
            Label(UIString.text(status.title), systemImage: "circle.fill")
                .labelStyle(StatusPillLabelStyle(color: status.color))
        }
    }

    private var setupNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            localizedText("SSDの状態を読むには、smartmontoolsを入れる必要があります。")
                .fixedSize(horizontal: false, vertical: true)
            Button(UIString.text("入れ方を見る")) {
                showMainWindow()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // The bar and the large value show what is left; wear stays as a smaller
    // value beside it. Both rows are always present, so the popup height does
    // not change when the values arrive.
    private var lifespan: some View {
        let wear = model.headlineWearFraction
        let remaining = wear.map { max(0, 1 - $0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                localizedText("残り")
                    .foregroundStyle(AppColor.textSecondary)
                Text(verbatim: remaining.map { String(format: "%.1f%%", $0 * 100) } ?? UIString.text("未取得"))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                Spacer()
                Text(verbatim: UIString.format("損耗 %@", wear.map { String(format: "%.1f%%", $0 * 100) } ?? UIString.text("未取得")))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(AppColor.textSecondary)
            }
            MenuBarMeter(value: remaining ?? 0, color: AppColor.overall)
            localizedText(model.headline.remaining ?? "残りの期間は、書込のペースが分かると表示します")
                .font(.system(size: 11))
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var domainWear: some View {
        let rows = model.analytics.nandEndurance.domainForecastRows
        return HStack(spacing: 12) {
            ForEach(rows, id: \.domain) { row in
                let remaining = max(0, 1 - row.wearFraction)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(row.domain.title)
                            .font(.system(size: 11, weight: .semibold))
                        Text(String(format: "%.1f%%", remaining * 100))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                        Spacer(minLength: 2)
                        Text(verbatim: UIString.format("損耗 %@", String(format: "%.1f%%", row.wearFraction * 100)))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                    }
                    MenuBarMeter(value: remaining, color: row.domain == .tlc ? AppColor.tlc : AppColor.pslc)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                MenuBarMetric(title: "温度", value: ValueFormatter.temperature(model.snapshot?.temperatureCelsius))
                MenuBarMetric(title: "今日の書込", value: model.todayHostWrittenBytes.map { ValueFormatter.bytes($0) } ?? "未取得")
            }
            GridRow {
                MenuBarMetric(title: model.writeRateSummary.usesUsageStartPace ? "使用開始からのペース" : "保存履歴ペース", value: model.headlinePaceBytesPerDay.map { "\(ValueFormatter.bytes($0))/日" } ?? "未取得")
                MenuBarMetric(title: "Host書込（累計）", value: ValueFormatter.bytes(model.snapshot?.dataUnitsWrittenBytes))
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showMainWindow()
                } label: {
                    localizedText("メイン画面を開く")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    windowActions.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractiveRefreshing)
                .help(UIString.text("今すぐ更新"))
                .accessibilityLabel(UIString.text("今すぐ更新"))
            }
            HStack {
                Button(UIString.text("設定…")) { showSettings() }
                Button(UIString.text("NenRingについて")) { showAbout() }
                Spacer()
                Button(UIString.text("終了")) { NSApp.terminate(nil) }
                    .help(UIString.text("NenRingを完全に終了します（メニューバーの監視も止まります）"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(AppColor.textSecondary)
        }
    }

    private var lastRefreshText: String {
        guard let date = model.lastSuccessfulRefreshAt else { return UIString.text("未取得") }
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .numeric, time: .shortened)
    }

    // MARK: Actions

    private func showMainWindow() { windowActions.showMainWindow() }

    private func showSettings() { windowActions.showSettings() }

    private func showAbout() { windowActions.showAbout() }
}

private struct StatusPillLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        StatusPill(configuration: configuration, color: color)
    }
}

/// The menu is almost white in light mode, so the text is darkened there
/// and the tint made stronger to keep the status readable.
private struct StatusPill: View {
    let configuration: LabelStyleConfiguration
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let light = colorScheme == .light
        let text = light ? Color(nsColor: NSColor(color).blended(withFraction: 0.25, of: .black) ?? NSColor(color)) : color
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(color)
            configuration.title
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(light ? 0.18 : 0.12), in: Capsule())
    }
}

/// A drawn bar: inside an NSMenu, ProgressView ignores its tint and is
/// drawn grey.
private struct MenuBarMeter: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColor.gaugeTrack)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 6)
    }
}

private struct MenuBarMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            localizedText(title)
                .font(.system(size: 10))
                .foregroundStyle(AppColor.textSecondary)
            localizedText(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(value == "未取得" ? AppColor.textMuted : AppColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
