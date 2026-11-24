import AppKit
import Charts
import SwiftUI

/// The four product-level destinations described by the UI specification.
/// The enum is presentation-only: it does not alter the analytics pipeline.
enum DashboardDestination: String, CaseIterable, Hashable, Identifiable {
    case overview
    case healthIndicators
    case diskInformation
    case endurance
    case trends
    case reliability
    case research

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "ダッシュボード"
        case .healthIndicators: return "健康指標"
        case .diskInformation: return "ディスク情報"
        case .endurance: return "寿命"
        case .trends: return "推移"
        case .reliability: return "内部エラーと保持処理"
        case .research: return "研究"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "概要"
        case .healthIndicators: return "SMART・温度・容量"
        case .diskInformation: return "SMART・IORegistry"
        case .endurance: return "残量と到達予測"
        case .trends: return "履歴と相関"
        case .reliability: return "FTLイベント"
        case .research: return "FTL・診断・根拠"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "rectangle.3.group.fill"
        case .healthIndicators: return "waveform.path.ecg.rectangle.fill"
        case .diskInformation: return "internaldrive"
        case .endurance: return "chart.line.uptrend.xyaxis"
        case .trends: return "chart.xyaxis.line"
        case .reliability: return "checkmark.shield.fill"
        case .research: return "magnifyingglass"
        }
    }
}

/// A research destination is an independent screen, not a visual state of one
/// long Research page. Keeping it separate also lets the sidebar highlight the
/// item that was actually selected instead of colouring every child at once.
enum ResearchDestination: String, CaseIterable, Hashable, Identifiable {
    case topology
    case histogram
    case residual
    case waf
    case retention
    case composition
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topology: return "FTL構成"
        case .histogram: return "ヒストグラム"
        case .residual: return "残差分析"
        case .waf: return "WAF分解"
        case .retention: return "保持分析"
        case .composition: return "Host書込の構成"
        case .raw: return "生データ"
        }
    }

    var subtitle: String {
        switch self {
        case .topology: return "区画境界・geometry・対応状況"
        case .histogram: return "bin番号のまま保持した内部分布"
        case .residual: return "未同定残差と長基線の診断"
        case .waf: return "観測・予測WAFの分解"
        case .retention: return "保持条件・温度・外挿"
        case .composition: return "Host書込み構成の候補値"
        case .raw: return "取得時刻・原データ・内部エラー"
        }
    }

    var systemImage: String {
        switch self {
        case .topology: return "point.3.connected.trianglepath.dotted"
        case .histogram: return "chart.bar.xaxis"
        case .residual: return "waveform.path.ecg"
        case .waf: return "chart.pie.fill"
        case .retention: return "thermometer.medium"
        case .composition: return "square.stack.3d.up"
        case .raw: return "doc.text.magnifyingglass"
        }
    }
}

/// Compatibility entry point used by App.swift. The application lifecycle,
/// menu-bar scene, and DashboardModel remain unchanged.
///
/// SwiftUI keeps a closed `Window`'s views alive and keeps updating them on
/// every model change, which made the closed dashboard cost as much CPU as
/// an open one. While the main window is closed this view shows nothing and,
/// not observing the model itself, is not redrawn either.
struct DashboardView: View {
    let model: DashboardModel
    @State private var isWindowOpen = true

    var body: some View {
        Group {
            if isWindowOpen {
                DashboardShellView(model: model)
            } else {
                Color.clear
                    .frame(minWidth: 900, minHeight: 680)
            }
        }
        .background(DashboardWindowAccessor())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if Self.isMainWindow(notification) { isWindowOpen = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if Self.isMainWindow(notification) { isWindowOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            if Self.isMainWindow(notification),
               let window = notification.object as? NSWindow,
               window.isVisible, window.occlusionState.contains(.visible) {
                isWindowOpen = true
            }
        }
    }

    private static func isMainWindow(_ notification: Notification) -> Bool {
        (notification.object as? NSWindow)?.identifier == MainWindowCoordinator.identifier
    }
}

struct DashboardShellView: View {
    @ObservedObject var model: DashboardModel
    /// Read-only preview hosts must not start collectors or load live history.
    var startsMonitoring = true
    @State private var selection: DashboardDestination = .overview
    @State private var researchSelection: ResearchDestination = .topology
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(
                selection: $selection,
                researchSelection: $researchSelection
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 286)
        } detail: {
            DashboardDestinationView(
                destination: selection,
                researchSelection: researchSelection,
                model: model
            ) { destination in
                selection = destination
            }
                .toolbar { dashboardToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 680)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task {
            if startsMonitoring { await model.start() }
        }
        .preferredColorScheme(AppearanceMode(rawValue: appearanceModeRaw)?.colorScheme)
    }

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            pageTitleToolbarItem.sharedBackgroundVisibility(.hidden)
            toolbarAlignmentSpacer.sharedBackgroundVisibility(.hidden)
        } else {
            pageTitleToolbarItem
            toolbarAlignmentSpacer
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isInteractiveRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(UIString.text("更新"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
            }
            .help(UIString.text("更新（⌘R）"))
            .accessibilityLabel(UIString.text(model.isInteractiveRefreshing ? "更新中" : "更新"))
            .disabled(model.isRefreshing)
        }
    }

    private var pageTitleToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(UIString.text(selection == .research ? researchSelection.title : selection.title))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Match the detail's inset without using a title-shaped button.
                .padding(.leading, 20)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var toolbarAlignmentSpacer: some ToolbarContent {
        // Keep a principal slot so AppKit does not group the refresh control
        // next to the leading navigation title in a compact toolbar.
        ToolbarItem(placement: .principal) {
            Spacer(minLength: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct DashboardSidebar: View {
    @Binding var selection: DashboardDestination
    @Binding var researchSelection: ResearchDestination

    var body: some View {
        ReferenceSidebarContent(
            selection: $selection,
            researchSelection: $researchSelection
        )
    }
}

private struct DashboardDestinationView: View {
    let destination: DashboardDestination
    let researchSelection: ResearchDestination
    @ObservedObject var model: DashboardModel
    let onNavigate: (DashboardDestination) -> Void

    var body: some View {
        ScrollView {
            Group {
                switch destination {
                case .overview:
                    ReferenceDashboardView(model: model, onNavigate: onNavigate)
                case .healthIndicators:
                    ReferenceHealthIndicatorsView(model: model)
                case .diskInformation:
                    DiskInformationView(model: model)
                case .endurance:
                    EnduranceView(model: model)
                case .trends:
                    TrendsView(model: model)
                case .reliability:
                    ReferenceReliabilityView(model: model)
                case .research:
                    ResearchView(model: model, destination: researchSelection)
                }
            }
            .frame(maxWidth: destination == .overview ? 1320 : 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        // Keep the window surface quiet and native.  The old under-page canvas
        // read as a large gray panel, which made every section look like a
        // detached card.  Sections now use spacing and rules for structure.
        .background(AppColor.surface)
        .navigationTitle(UIString.text(destination == .research ? researchSelection.title : destination.title))
    }
}

private struct DashboardWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTagView { WindowTagView() }
    func updateNSView(_ nsView: WindowTagView, context: Context) {
        MainWindowCoordinator.register(nsView.window)
        DashboardWindowChrome.apply(to: nsView.window)
    }

    final class WindowTagView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainWindowCoordinator.register(window)
            DashboardWindowChrome.apply(to: window)
        }
    }
}

/// Keep native traffic lights and toolbar behaviour, but use one semantic
/// surface for the title bar and detail in both appearances.
@MainActor
enum DashboardWindowChrome {
    static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .controlBackgroundColor
    }
}

struct DashboardSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct DashboardSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DashboardSidebarMaterial()
            // Retain the native material but soften its light-mode contrast
            // against the white detail. Dark mode keeps its existing depth.
            if colorScheme == .light {
                AppColor.surface.opacity(0.55)
            }
        }
    }
}

private struct MetricGauge: View {
    let title: String
    let value: Double?
    let display: String
    /// A smaller value under the main one, such as the wear beside the
    /// share left.
    var secondary: String? = nil
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            localizedText(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColor.textPrimary)
            ZStack {
                Circle()
                    .stroke(AppColor.gaugeTrack, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: clampedValue / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    localizedText(display)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if let secondary {
                        localizedText(secondary)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(AppColor.textSecondary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(width: 90, height: 90)
            .opacity(value == nil ? 0.42 : 1)

            localizedText(detail)
                .font(.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UIString.format("%@ %@。%@", UIString.text(title), UIString.readout(display), UIString.readout(detail)))
    }

    private var clampedValue: Double {
        min(100, max(0, value ?? 0))
    }
}

private struct GaugeDivider: View {
    var body: some View {
        Divider()
            .frame(height: 78)
            .padding(.horizontal, 18)
            .padding(.top, 2)
    }
}

private struct RateValue: View {
    let label: String
    let rate: Double?
    let observedDays: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: UIString.text(label) + (isProvisional ? "*" : ""))
                .font(.caption)
                .foregroundStyle(AppColor.textSecondary)
            localizedText(rate.map { ValueFormatter.bytes($0) + "/日" } ?? "—")
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(rate == nil ? AppColor.textMuted : AppColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if isProvisional {
                Text(verbatim: UIString.format("観測 %@", observedDays.map { UIString.format("%.1f日", $0) } ?? UIString.text("不足")))
                    .font(.caption2)
                    .foregroundStyle(AppColor.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isProvisional: Bool {
        guard let observedDays else { return false }
        let target: Double
        switch label {
        case "7日": target = 7
        case "30日": target = 30
        case "90日": target = 90
        default: target = observedDays
        }
        return observedDays + 0.001 < target
    }
}

private struct EnduranceView: View {
    @ObservedObject var model: DashboardModel

    private var usageStartSummary: UsageStartSummary? {
        guard let start = model.writeRateSummary.lifetimeStartDate, let snapshot = model.snapshot else { return nil }
        return UsageStartSummary(start: start, snapshot: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageIntro(title: "寿命予測", subtitle: "観測値・日常履歴・研究モデルを分けて表示します。")
            EnduranceGaugeSection(model: model)
            ForecastTable(model: model)
            if let summary = usageStartSummary {
                UsageStartSection(summary: summary)
            }
            ResponsiveColumns {
                EnduranceNANDSection(model: model)
                EnduranceEvidenceSection(model: model)
            }
            EnduranceAdvancedSection(model: model)
        }
    }
}

private struct EnduranceGaugeSection: View {
    @ObservedObject var model: DashboardModel

    private var tlcRemaining: Double? {
        model.analytics.nandEndurance.tlcWear.map { (1 - $0) * 100 }
    }

    private var pslcRemaining: Double? {
        model.analytics.nandEndurance.pslcWear.map { (1 - $0) * 100 }
    }

    private var nandRemaining: Double? {
        guard let tlc = tlcRemaining, let pslc = pslcRemaining else {
            return tlcRemaining ?? pslcRemaining
        }
        return min(tlc, pslc)
    }

    var body: some View {
        DashboardSection(title: "NAND残量", subtitle: "Controller EOLまでの平均P/E基準") {
            HStack(alignment: .top, spacing: 0) {
                MetricGauge(
                    title: "総合残量",
                    value: nandRemaining,
                    display: nandRemaining.map { String(format: "%.1f%%", $0) } ?? "未取得",
                    secondary: nandRemaining.map { UIString.format("損耗 %@", String(format: "%.1f%%", 100 - $0)) },
                    detail: "残量の小さい領域を表示",
                    tint: enduranceTint(nandRemaining)
                )
                GaugeDivider()
                MetricGauge(
                    title: "TLC残量",
                    value: tlcRemaining,
                    display: tlcRemaining.map { String(format: "%.1f%%", $0) } ?? "未取得",
                    secondary: tlcRemaining.map { UIString.format("損耗 %@", String(format: "%.1f%%", 100 - $0)) },
                    detail: "\(peText(model.analytics.nandEndurance.tlcPE, model.analytics.nandEndurance.tlcEOL))",
                    tint: enduranceTint(tlcRemaining, healthy: AppColor.tlc)
                )
                GaugeDivider()
                MetricGauge(
                    title: "pSLC残量",
                    value: pslcRemaining,
                    display: pslcRemaining.map { String(format: "%.1f%%", $0) } ?? "未取得",
                    secondary: pslcRemaining.map { UIString.format("損耗 %@", String(format: "%.1f%%", 100 - $0)) },
                    detail: "\(peText(model.analytics.nandEndurance.pslcPE, model.analytics.nandEndurance.pslcEOL))",
                    tint: enduranceTint(pslcRemaining, healthy: AppColor.pslc)
                )
            }
        }
    }

    private func peText(_ current: Double?, _ eol: Double?) -> String {
        guard let current, let eol else { return "P/E 未取得" }
        return "P/E \(String(format: "%.0f", current)) / \(String(format: "%.0f", eol))"
    }
}

/// Same colours as the dashboard rings: `healthy` (the overall ring's blue or
/// a NAND domain's colour), amber at half left or less, red at a quarter or
/// less.
private func enduranceTint(_ value: Double?, healthy: Color = AppColor.overall) -> Color {
    guard let value else { return AppColor.textMuted }
    if value <= 25 { return AppColor.redFill }
    if value <= 50 { return AppColor.amberFill }
    return healthy
}

private struct ForecastTable: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "到達予測", subtitle: "総量・残量・日常ペース") {
            if usageStartRate != nil {
                // Three date columns leave no room for the scenario names at
                // the minimum window width, so the names move above the values.
                ViewThatFits(in: .horizontal) {
                    rows(stacked: false)
                    rows(stacked: true)
                }
            } else {
                rows(stacked: false)
            }
            localizedText("各シナリオの残量を、直近と保存履歴全体の書込ペースで換算します。同じシナリオ内では両方の到達時期に同じ残量を使用します。")
                .font(.caption).foregroundStyle(AppColor.textSecondary).padding(.horizontal, 12).padding(.bottom, 8)
            if usageStartRate != nil {
                localizedText("使用開始からの列は計測前の使い方を含む平均です。現在の使い方と異なる場合があります。")
                    .font(.caption).foregroundStyle(AppColor.textSecondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if model.writeRateSummary.currentWorkloadIsPartial {
                localizedText("*は直近の対象期間に対して観測日数が不足している暫定値です。")
                    .font(.caption).foregroundStyle(AppColor.textSecondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    private func rows(stacked: Bool) -> some View {
        VStack(spacing: 0) {
                ForecastHeaderRow(recentLabel: recentPaceLabel, showsUsageStart: usageStartRate != nil, stacked: stacked)
                ForecastRow(title: "実使用", detail: nil, total: realTotal, remaining: realRemaining, recentDate: projectedDate(for: adjusted(realRemaining, .real), rate: recentRate), historyDate: projectedDate(for: adjusted(realRemaining, .real), rate: historyRate), usageStartDate: projectedDate(for: adjusted(realRemaining, .real), rate: usageStartRate), showsUsageStart: usageStartRate != nil, stacked: stacked, recentProvisional: recentProvisional, historyProvisional: historyProvisional, kind: .projected, source: .history)
                if let scenario = model.analytics.nandEndurance.retentionScenario, let host = model.analytics.nandEndurance.host {
                    ForecastRow(title: "保持考慮", detail: retentionDetail(scenario), total: host + scenario.remainingHostBytes, remaining: scenario.remainingHostBytes, recentDate: projectedDate(for: adjusted(scenario.remainingHostBytes, .real), rate: recentRate), historyDate: projectedDate(for: adjusted(scenario.remainingHostBytes, .real), rate: historyRate), usageStartDate: projectedDate(for: adjusted(scenario.remainingHostBytes, .real), rate: usageStartRate), showsUsageStart: usageStartRate != nil, stacked: stacked, recentProvisional: recentProvisional, historyProvisional: historyProvisional, kind: .estimated, source: .research)
                }
                ForecastRow(title: "クライアント負荷", detail: "WAF 3.5", total: clientTotal, remaining: clientRemaining, recentDate: projectedDate(for: adjusted(clientRemaining, .client), rate: recentRate), historyDate: projectedDate(for: adjusted(clientRemaining, .client), rate: historyRate), usageStartDate: projectedDate(for: adjusted(clientRemaining, .client), rate: usageStartRate), showsUsageStart: usageStartRate != nil, stacked: stacked, recentProvisional: recentProvisional, historyProvisional: historyProvisional, kind: .estimated, source: .research)
                    .help(UIString.text("今後のWAFを3.5とした比較。保持補正は加えず、現在のTLC／pSLC配分が続くと仮定します。JEDEC試験結果ではありません。"))
                ForecastRow(title: "参考基準", detail: nil, total: peerTotal, remaining: peerRemaining, recentDate: projectedDate(for: peerRemaining, rate: recentRate), historyDate: projectedDate(for: peerRemaining, rate: historyRate), usageStartDate: projectedDate(for: peerRemaining, rate: usageStartRate), showsUsageStart: usageStartRate != nil, stacked: stacked, recentProvisional: recentProvisional, historyProvisional: historyProvisional, kind: .research, source: .research)
        }
    }

    private var realTotal: Double? {
        model.analytics.nandEndurance.projection(.real)?.total ?? model.enduranceForecast.estimatedEnduranceBytes
    }

    private var realRemaining: Double? {
        model.analytics.nandEndurance.projection(.real)?.remaining ?? model.enduranceForecast.remainingHostWriteBytes
    }

    private var clientTotal: Double? {
        model.analytics.nandEndurance.projection(.client)?.total
    }

    private var clientRemaining: Double? {
        model.analytics.nandEndurance.projection(.client)?.remaining
    }

    private var peerTotal: Double? {
        model.analytics.peerTBWForecast?.thresholdBytes
    }

    private var peerRemaining: Double? {
        model.analytics.peerTBWForecast?.remainingBytes
    }

    private var recentRate: Double? {
        model.writeRateSummary.currentWorkloadTargetDays == nil ? nil : model.writeRateSummary.currentWorkloadBytesPerDay
    }
    private var historyRate: Double? { model.writeRateSummary.recordedHistoryBytesPerDay }
    private var usageStartRate: Double? {
        model.writeRateSummary.lifetimeRateBasis == nil ? nil : model.writeRateSummary.lifetimeBytesPerDay
    }
    private var recentProvisional: Bool { model.writeRateSummary.currentWorkloadIsProvisional }
    private var historyProvisional: Bool { model.writeRateSummary.recordedHistoryIsProvisional }
    private func retentionDetail(_ scenario: RetentionScenario) -> String {
        let temperature = model.analytics.nandEndurance.idleRetentionTemperature?.displaySummary(in: .current)
            ?? TemperatureUnit.current.text(scenario.storageTemperatureCelsius)
        return UIString.format("%.0f日 · %@", scenario.powerOffDays, temperature)
    }
    private var recentPaceLabel: String {
        guard let days = model.writeRateSummary.currentWorkloadTargetDays else { return UIString.text("直近ペース") }
        return UIString.format("直近%.0f日", days) + (model.writeRateSummary.currentWorkloadIsPartial ? "*" : "")
    }

    private func adjusted(_ remaining: Double?, _ workload: NANDEnduranceV2.Projection.Kind) -> Double? {
        model.analytics.nandEndurance.remainingNow(remaining, workload: workload)
    }

    private func projectedDate(for remaining: Double?, rate: Double?) -> Date? {
        guard let remaining, remaining.isFinite, remaining >= 0 else { return nil }
        return EndurancePaceForecast.arrivalDate(
            remainingHostBytes: remaining,
            hostBytesPerDay: rate,
            now: Date()
        )
    }
}

private struct ForecastHeaderRow: View {
    let recentLabel: String
    let showsUsageStart: Bool
    let stacked: Bool
    private var dateWidth: CGFloat { showsUsageStart ? forecastCompactDateWidth : forecastDateWidth }
    private var hostWidth: CGFloat { stacked ? forecastCompactDateWidth : forecastHostWidth }
    var body: some View {
        HStack {
            if stacked {
                Spacer(minLength: 0)
            } else {
                localizedText("シナリオ").frame(maxWidth: .infinity, alignment: .leading)
            }
            localizedText("総Host").frame(width: hostWidth, alignment: .trailing)
            localizedText("残りHost").frame(width: hostWidth, alignment: .trailing)
            Text(verbatim: recentLabel).frame(width: dateWidth, alignment: .trailing)
            localizedText("保存履歴ペース").frame(width: dateWidth, alignment: .trailing)
            if showsUsageStart {
                localizedText("使用開始から").frame(width: dateWidth, alignment: .trailing)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(AppColor.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColor.accent.opacity(0.07))
    }
}

private struct ForecastRow: View {
    let title: String
    let detail: String?
    let total: Double?
    let remaining: Double?
    let recentDate: Date?
    let historyDate: Date?
    let usageStartDate: Date?
    let showsUsageStart: Bool
    let stacked: Bool
    let recentProvisional: Bool
    let historyProvisional: Bool
    let kind: DataKind
    let source: DataSource

    private var hostWidth: CGFloat { stacked ? forecastCompactDateWidth : forecastHostWidth }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    scenario
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Spacer(minLength: 0)
                        values
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    scenario.frame(maxWidth: .infinity, alignment: .leading)
                    values
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColor.border).frame(height: 1)
        }
    }

    private var scenario: some View {
        VStack(alignment: .leading, spacing: 4) {
            localizedText(title).font(.body.weight(.medium))
            DataKindBadge(kind: kind, source: source)
            if let detail {
                Text(verbatim: UIString.readout(detail))
                    .font(.caption).foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    @ViewBuilder private var values: some View {
        Text(total.map(ValueFormatter.bytes) ?? "—")
            .frame(width: hostWidth, alignment: .trailing)
            .font(.body.monospacedDigit())
        Text(remaining.map(ValueFormatter.bytes) ?? "—")
            .frame(width: hostWidth, alignment: .trailing)
            .font(.body.monospacedDigit())
        // Arrival is years away, so show the year (not just month/day).
        dateValue(recentDate, provisional: recentProvisional)
        dateValue(historyDate, provisional: historyProvisional)
        if showsUsageStart {
            dateValue(usageStartDate, provisional: false)
        }
    }

    private func dateValue(_ date: Date?, provisional: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(date.map { UIString.yearMonth($0) } ?? UIString.text("未算出"))
                .foregroundStyle(date == nil ? AppColor.textMuted : AppColor.textPrimary)
            if let date {
                let years = max(0, date.timeIntervalSinceNow / (365.2425 * 86_400))
                Text(verbatim: years == 0 ? UIString.text("到達済み") : (provisional ? UIString.text("暫定") + " · " : "") + UIString.format("約%.1f年", years))
                    .font(.caption).foregroundStyle(AppColor.textSecondary)
            }
        }
        .frame(width: showsUsageStart ? forecastCompactDateWidth : forecastDateWidth, alignment: .trailing)
        .font(.body.monospacedDigit())
    }
}

private let forecastHostWidth: CGFloat = 120
private let forecastDateWidth: CGFloat = 140
/// Three date columns must still fit beside the sidebar at the minimum window size.
private let forecastCompactDateWidth: CGFloat = 104

private struct UsageStartSection: View {
    let summary: UsageStartSummary

    var body: some View {
        DashboardSection(title: "使用開始から", subtitle: "計測前を含む累積値から算出") {
            HStack(alignment: .top, spacing: 16) {
                value("使用日数", UIString.format("%@日", ValueFormatter.integer(UInt64(summary.elapsedDays))))
                value("平均稼働時間", summary.averagePowerOnHoursPerDay.map { UIString.format("%.1f時間/日", $0) })
                value("1日平均書込", summary.hostBytesPerDay.map { ValueFormatter.bytes($0) + "/日" })
            }
            .padding(12)
        }
    }

    private func value(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            localizedText(title).font(.caption).foregroundStyle(AppColor.textSecondary)
            localizedText(value ?? "未取得").font(.body.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EnduranceNANDSection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "NAND予算", subtitle: model.analytics.nandEndurance.domainModelAvailable ? "Direct topology · 暫定研究推計" : "累積損耗による概算") {
            VStack(spacing: 0) {
                EnduranceValueRow(title: "NAND基準予算", value: model.analytics.nandEndurance.nominalBudget.map(ValueFormatter.bytes) ?? "未取得", detail: "EOL基準")
                EnduranceValueRow(title: "実測累積NAND", value: model.analytics.nandEndurance.nand.map(ValueFormatter.bytes) ?? "未取得", detail: "Direct FTL")
                EnduranceValueRow(title: "推定使用量", value: model.analytics.nandEndurance.domainUsedBytes.map(ValueFormatter.bytes) ?? model.analytics.nandEndurance.currentPhysicalBytes.map(ValueFormatter.bytes) ?? "未取得", detail: "domain合計")
                EnduranceValueRow(title: "推定残量", value: model.analytics.nandEndurance.baselineDomainRemainingBytes.map(ValueFormatter.bytes) ?? "未取得", detail: "保持補正なし・domain合計")
            }
        }
    }
}

private struct EnduranceEvidenceSection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "観測の根拠", subtitle: "予測の意味") {
            VStack(alignment: .leading, spacing: 10) {
                EvidenceLine(title: "観測期間", value: UIString.format("%.1f日", model.analytics.controllerWearHistory.observationDays))
                EvidenceLine(title: "Direct FTL", value: model.analytics.controllerWearHistory.intervalCount > 0 ? UIString.format("%d区間", model.analytics.controllerWearHistory.intervalCount) : "比較履歴なし")
                EvidenceLine(title: "WAF", value: model.analytics.nandEndurance.forecastWAF.map { String(format: "%.3f", $0) } ?? "未取得")
                EvidenceLine(title: "保持補正", value: String(format: "%.3f", model.analytics.nandEndurance.retentionFactor))
                if let note = model.analytics.nandEndurance.notes.first {
                    localizedDiagnosticText(note)
                        .font(.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct EnduranceValueRow: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack {
            localizedText(title).foregroundStyle(AppColor.textSecondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                localizedText(value).font(.body.weight(.medium).monospacedDigit())
                localizedText(detail).font(.caption2).foregroundStyle(AppColor.textMuted)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(AppColor.border).frame(height: 1) }
    }
}

private struct EvidenceLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            localizedText(title).font(.caption).foregroundStyle(AppColor.textSecondary)
            Spacer()
            localizedText(value).font(.body.monospacedDigit())
        }
    }
}

private struct EnduranceAdvancedSection: View {
    @ObservedObject var model: DashboardModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ResearchDisclosure(title: "平均／最大P/E", detail: "\(model.analytics.nandEndurance.tlcPE.map { String(format: "TLC %.1f", $0) } ?? "TLC —") · \(model.analytics.nandEndurance.pslcPE.map { String(format: "pSLC %.1f", $0) } ?? "pSLC —")")
                ResearchDisclosure(title: "残差", detail: model.analytics.nandEndurance.reconstructionDiagnostics.map { String(describing: $0) } ?? "未取得")
                ResearchDisclosure(title: "WAF components", detail: model.analytics.nandEndurance.wafComponents.map { String(describing: $0) } ?? "未取得")
                localizedText("詳細値はResearchで取得元・単位・対応表の版とともに確認できます。")
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .padding(.top, 12)
        } label: {
            SectionHeading("詳細", subtitle: "研究用の比較値")
        }
    }
}

private struct TrendsView: View {
    @ObservedObject var model: DashboardModel
    @State private var range: TrendRange = .thirtyDays
    @State private var metric: TrendMetric = .writes

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageIntro(title: "推移", subtitle: "観測履歴とイベントを同じ系列で比較します。")

            HStack {
                Picker(UIString.text("期間"), selection: $range) {
                    ForEach(TrendRange.allCases) { value in
                        localizedText(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                Picker(UIString.text("指標"), selection: $metric) {
                    ForEach(TrendMetric.allCases) { value in
                        localizedText(value.title).tag(value)
                    }
                }
                .pickerStyle(.menu)
            }
            .onChange(of: range) { _, newValue in
                model.selectedPeriod = newValue.historyPeriod
            }
            .onAppear {
                // Apply the page's initial range too, not only later changes.
                if model.selectedPeriod != range.historyPeriod {
                    model.selectedPeriod = range.historyPeriod
                }
            }

            DashboardSection(title: metric.title, subtitle: range.title) {
                TrendChart(model: model, metric: metric, range: range)
                    .frame(height: 300)
            }

            ResponsiveColumns {
                TrendRatesSection(model: model)
                TrendReliabilitySection(model: model)
            }
        }
    }
}

private enum TrendRange: String, CaseIterable, Identifiable {
    case sevenDays, thirtyDays, ninetyDays, year, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sevenDays: return "7日"
        case .thirtyDays: return "30日"
        case .ninetyDays: return "90日"
        case .year: return "1年"
        case .all: return "全期間"
        }
    }
    var days: Double? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .year: return 365
        case .all: return nil
        }
    }
    var historyPeriod: HistoryPeriod {
        switch self {
        case .sevenDays, .thirtyDays, .ninetyDays: return .day
        case .year: return .week
        case .all: return .month
        }
    }
}

private enum TrendMetric: String, CaseIterable, Identifiable {
    case writes, wear, waf, temperature, reliability
    var id: String { rawValue }
    var title: String {
        switch self {
        case .writes: return "書き込み"
        case .wear: return "損耗"
        case .waf: return "WAF"
        case .temperature: return "温度"
        case .reliability: return "Reliability"
        }
    }
}

private struct TrendChart: View {
    @ObservedObject var model: DashboardModel
    let metric: TrendMetric
    let range: TrendRange

    private var cutoff: Date? {
        range.days.map { Date().addingTimeInterval(-$0 * 86_400) }
    }

    var body: some View {
        switch metric {
        case .writes:
            if filteredWritePoints.isEmpty {
                TrendEmptyState()
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Chart {
                        ForEach(filteredWritePoints) { point in
                            BarMark(x: .value("時刻", point.bucket), y: .value("書き込み", point.bytes))
                                .foregroundStyle(AppColor.hostWrite)
                        }
                        ForEach(visibleBoundaryRecords, id: \.boundary.after) { record in
                            RuleMark(x: .value("計測器境界", record.boundary.after))
                                .foregroundStyle(instrumentBoundaryColor(record))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: instrumentBoundaryDash(record)))
                                .annotation(position: .top, alignment: .center, spacing: 2) {
                                    InstrumentBoundaryAnnotation(record: record)
                                }
                        }
                    }
                    .chartYAxisLabel("Host Writes")
                    .accessibilityLabel(UIString.text("書き込み履歴"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    InstrumentBoundaryLegendView(records: visibleBoundaryRecords)
                }
            }
        case .wear:
            if filteredWearPoints.count < 2 {
                TrendEmptyState(message: "同一系列の損耗観測が2点以上集まると、pSLC／TLCの比を表示します。")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Chart {
                        ForEach(filteredWearPoints) { point in
                            LineMark(
                                x: .value("時刻", point.capturedAt),
                                y: .value("pSLC / TLC", point.ratio)
                            )
                            .foregroundStyle(AppColor.overall)
                            PointMark(
                                x: .value("時刻", point.capturedAt),
                                y: .value("pSLC / TLC", point.ratio)
                            )
                            .foregroundStyle(AppColor.overall)
                        }
                        RuleMark(y: .value("均衡", 1.0))
                            .foregroundStyle(AppColor.textMuted)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        ForEach(visibleBoundaryRecords, id: \.boundary.after) { record in
                            RuleMark(x: .value("計測器境界", record.boundary.after))
                                .foregroundStyle(instrumentBoundaryColor(record))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: instrumentBoundaryDash(record)))
                                .annotation(position: .top, alignment: .center, spacing: 2) {
                                    InstrumentBoundaryAnnotation(record: record)
                                }
                        }
                    }
                    .chartYAxisLabel("pSLC / TLC")
                    .accessibilityLabel(UIString.text("pSLCとTLCの損耗比。破線は1.0"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    InstrumentBoundaryLegendView(records: visibleBoundaryRecords)
                }
            }
        case .waf:
            if filteredWAFIntervals.count < 2 {
                TrendEmptyState(message: "同一系列の有効な区間WAFが2点以上集まると表示します。")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Chart {
                        ForEach(filteredWAFIntervals) { interval in
                            if let waf = interval.observedWAF {
                                LineMark(
                                    x: .value("時刻", interval.endAt),
                                    y: .value("WAF", waf)
                                )
                                .foregroundStyle(AppColor.overall)
                                PointMark(
                                    x: .value("時刻", interval.endAt),
                                    y: .value("WAF", waf)
                                )
                                .foregroundStyle(AppColor.overall)
                            }
                        }
                        ForEach(visibleBoundaryRecords, id: \.boundary.after) { record in
                            RuleMark(x: .value("計測器境界", record.boundary.after))
                                .foregroundStyle(instrumentBoundaryColor(record))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: instrumentBoundaryDash(record)))
                                .annotation(position: .top, alignment: .center, spacing: 2) {
                                    InstrumentBoundaryAnnotation(record: record)
                                }
                        }
                    }
                    .chartYAxisLabel("×")
                    .accessibilityLabel(UIString.text("同一系列の区間WAF"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    InstrumentBoundaryLegendView(records: visibleBoundaryRecords)
                }
            }
        case .temperature:
            if filteredTemperaturePoints.count < 2 {
                TrendEmptyState()
            } else {
                let unit = TemperatureUnit.current
                let points = filteredTemperaturePoints
                Chart {
                    ForEach(TemperatureLineRun.runs(sections: [points])) { run in
                        ForEach(run.points) { point in
                            LineMark(x: .value("時刻", point.date), y: .value("温度", unit.value(point.celsius)), series: .value("区間", run.id))
                                .foregroundStyle(run.isWarm ? AppColor.temperatureWarm : AppColor.temperature)
                        }
                    }
                    ForEach(points) { point in
                        PointMark(x: .value("時刻", point.date), y: .value("温度", unit.value(point.celsius)))
                            .foregroundStyle(point.celsius > TemperatureLineRun.warmThreshold ? AppColor.temperatureWarm : AppColor.temperature)
                    }
                }
                .chartYAxisLabel(unit.symbol)
            }
        case .reliability:
            if filteredReliabilityEvents.isEmpty {
                EmptyState(title: "新規イベントなし", message: "取得範囲で比較可能な増加はありません。", systemImage: "checkmark.circle")
            } else {
                Chart(filteredReliabilityEvents) { event in
                    BarMark(
                        x: .value("時刻", event.intervalEnd),
                        y: .value("増加", Double(event.delta))
                    )
                    .foregroundStyle(AppColor.amber)
                }
                .chartYAxisLabel("イベント増分")
                .accessibilityLabel(UIString.text("Reliabilityイベント増分"))
            }
        }
    }

    private var filteredWritePoints: [WritePoint] {
        model.writePoints.filter { cutoff == nil || $0.bucket >= cutoff! }
    }

    private var visibleBoundaryRecords: [InstrumentBoundaryRecord] {
        InstrumentBoundaryPresentation.visibleRecords(
            model.analytics.nandEndurance.instrumentBoundaries,
            in: chartDates
        )
    }

    private var chartDates: [Date] {
        switch metric {
        case .writes:
            return filteredWritePoints.map(\.bucket)
        case .wear:
            return filteredWearPoints.map(\.capturedAt)
        case .waf:
            return filteredWAFIntervals.map(\.endAt)
        case .temperature:
            return []
        case .reliability:
            return []
        }
    }

    private var filteredTemperaturePoints: [TemperaturePoint] {
        TemperaturePoint.downsampled(model.temperaturePoints.filter { cutoff == nil || $0.date >= cutoff! },
                                     maximumCount: 600)
    }

    private var filteredWearPoints: [WearBalanceObservation] {
        model.analytics.nandEndurance.wearBalanceTrend.observations
            .filter { cutoff == nil || $0.capturedAt >= cutoff! }
    }

    private var filteredWAFIntervals: [FTLIntervalObservation] {
        let seriesID = model.analytics.ftlTimeSeries.latestSeriesID
        let bridges = model.analytics.nandEndurance.firmwareBoundaryBridges
        return model.analytics.ftlTimeSeries.intervals
            .filter { interval in
                let isLatestSeries = seriesID != nil && interval.seriesID == seriesID
                let isBridgedPredecessor = bridges.contains { bridge in
                    interval.endAt >= bridge.before.addingTimeInterval(-7 * 86_400) &&
                        interval.endAt <= bridge.before
                }
                return (isLatestSeries || isBridgedPredecessor)
                    && (cutoff == nil || interval.endAt >= cutoff!)
                    && interval.observedWAF != nil
            }
    }

    private var filteredReliabilityEvents: [FTLTimeSeriesReliabilityEvent] {
        let seriesID = model.analytics.ftlTimeSeries.latestSeriesID
        return model.analytics.ftlTimeSeries.reliabilityEvents
            .filter { event in
                guard let seriesID else { return false }
                return event.seriesID == seriesID
                    && (cutoff == nil || event.intervalEnd >= cutoff!)
            }
            .sorted { $0.intervalEnd < $1.intervalEnd }
    }
}

private struct TrendEmptyState: View {
    let message: String

    init(message: String = "2件以上の同系列snapshotが集まると表示できます。") {
        self.message = message
    }

    var body: some View {
        EmptyState(title: "比較可能な履歴がありません", message: message, systemImage: "chart.xyaxis.line")
    }
}

private struct TrendRatesSection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "書き込みペース", subtitle: "観測不足は * で表示") {
            VStack(spacing: 8) {
                RateValue(label: "7日", rate: model.writeRateSummary.sevenDayBytesPerDay, observedDays: model.writeRateSummary.sevenDayObservedDays)
                RateValue(label: "30日", rate: model.writeRateSummary.thirtyDayBytesPerDay, observedDays: model.writeRateSummary.thirtyDayObservedDays)
                RateValue(label: "90日", rate: model.writeRateSummary.ninetyDayBytesPerDay, observedDays: model.writeRateSummary.ninetyDayObservedDays)
                if model.writeRateSummary.lifetimeRateBasis != nil {
                    RateValue(label: "保存履歴", rate: model.writeRateSummary.recordedHistoryBytesPerDay, observedDays: model.writeRateSummary.recordedHistoryObservedDays)
                }
                RateValue(
                    label: lifetimeRateLabel,
                    rate: model.writeRateSummary.lifetimeBytesPerDay,
                    observedDays: model.writeRateSummary.lifetimeObservedDays
                )
            }
        }
    }

    private var lifetimeRateLabel: String {
        let summary = model.writeRateSummary
        if summary.lifetimeRateBasis != nil { return "使用開始から" }
        if let days = summary.lifetimeObservedDays, days > 0, days.isFinite {
            return UIString.format("保存履歴（%.1f日）", days)
        }
        return "保存履歴"
    }
}

private struct TrendReliabilitySection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "イベント", subtitle: "TBW倍率は自動変更しません") {
            if model.analytics.ftlTimeSeries.reliabilityEvents.isEmpty {
                EmptyState(title: "新規イベントなし", message: "取得範囲で比較可能な増加はありません。", systemImage: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.analytics.ftlTimeSeries.reliabilityEvents.sorted { $0.intervalEnd > $1.intervalEnd }.prefix(5)) { event in
                        HStack {
                            localizedText(event.type.title)
                            Spacer()
                            localizedText("+\(event.delta)").font(.body.monospacedDigit())
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

struct ResearchView: View {
    @ObservedObject var model: DashboardModel
    let destination: ResearchDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageIntro(title: destination.title, subtitle: destination.subtitle)
            destinationContent
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .topology:
            ResearchOverviewSection(model: model)
            ResponsiveColumns {
                ResearchTopologySection(model: model)
                ResearchModelSection(model: model)
            }
            ResearchDisclosure(title: "FTL Key Map & Identity", detail: contractDetail)
            ResearchDisclosure(title: "Topology & Geometry", detail: topologyDetail)
        case .histogram:
            ResearchDirectFTLSection(model: model)
            ResearchDisclosure(title: "Histograms", detail: histogramDetail)
            ResearchDisclosure(title: "Time-Series Evidence", detail: timeSeriesDetail)
        case .residual:
            crossValidationSection
            ResearchDisclosure(title: "Residual / Reconstruction", detail: residualDetail)
            ResearchDisclosure(title: "Long-baseline residual", detail: longBaselineDetail)
            ResearchDisclosure(title: "Time-Series Evidence", detail: timeSeriesDetail)
            ResearchDirectFTLSection(model: model)
        case .waf:
            ResearchModelSection(model: model)
            DashboardSection(title: "NAND / Direct FTL 詳細", subtitle: "取得値・予測値・比較値を分離") {
                NANDEnduranceDetailsView(result: model.analytics.nandEndurance)
            }
            ResearchDisclosure(title: "WAF Decomposition", detail: wafDetail)
        case .retention:
            ResponsiveColumns {
                ResearchTemperatureSection(model: model)
                ResearchModelSection(model: model)
            }
            ResearchDisclosure(title: "Retention Research", detail: retentionDetail)
            ResearchDisclosure(title: "Topology & Geometry", detail: topologyDetail)
        case .composition:
            ResearchDirectFTLSection(model: model)
            ResearchDisclosure(title: "Host Composition Candidates", detail: compositionDetail)
            ResearchDisclosure(title: "WAF Decomposition", detail: wafDetail)
        case .raw:
            ResponsiveColumns {
                ResearchReliabilitySummarySection(model: model)
                ResearchTemperatureSection(model: model)
            }
            ResearchReliabilitySection(model: model)
            SectionHeading("取得値と原データ", subtitle: "取得値・原データ・不足理由を分けて表示")
            crossValidationSection
            DashboardSection(title: "NAND / Direct FTL 詳細", subtitle: "取得値・予測値・研究用比較値を分離") {
                NANDEnduranceDetailsView(result: model.analytics.nandEndurance)
            }
            asptoolComparisonSection
            ResearchDisclosure(title: "ASP / asptool", detail: aspDetail)
            ResearchDisclosure(title: "IORegistry", detail: ioregDetail)
            ResearchDisclosure(title: "Raw Diagnostics", detail: diagnosticsDetail)
        }
    }

    private var asptoolComparisonSection: some View {
        DashboardSection(title: "asptoolログ / Direct FTL 照合", subtitle: "自分で取得したasptool_snapshot.logを読み込むと、近い時刻のDirect FTLと比べます") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(model.analytics.asptoolLogComparison.rows) { row in
                    GridRow {
                        localizedText(row.title).foregroundStyle(AppColor.textSecondary)
                        localizedText(row.detail).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var crossValidationSection: some View {
        DashboardSection(title: "SMART / FTL 照合", subtitle: "保存前チェック・補助観測・検証済み残差") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(model.analytics.directFTLCrossValidation.rows) { row in
                    GridRow {
                        localizedText(row.title).foregroundStyle(AppColor.textSecondary)
                        localizedText(row.detail).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var latestSeries: FTLTimeSeriesGroup? {
        model.analytics.ftlTimeSeries.series.max { $0.latestSnapshotAt < $1.latestSnapshotAt }
    }

    private var contractDetail: String {
        guard let latestSeries else { return "比較可能なDirect FTL系列なし" }
        return "\(latestSeries.metadata.semanticContractVersion ?? "対応表の版が不明") · build \(latestSeries.metadata.sourceBuild ?? "不明") · \(latestSeries.snapshotCount) snapshots"
    }

    private var topologyDetail: String {
        guard let topology = model.analytics.nandEndurance.directTopology else { return "Direct topology未取得。現在geometryは予測へ補完していません。" }
        return String(describing: topology)
    }

    private var wafDetail: String {
        let nand = model.analytics.nandEndurance
        return UIString.format("累積 %@ · 観測 %@ · 予測 %@",
            nand.longWAF.map { String(format: "%.4f", $0) } ?? UIString.text("未取得"),
            nand.recentWAF.map { String(format: "%.4f", $0) } ?? UIString.text("未取得"),
            nand.forecastWAF.map { String(format: "%.4f", $0) } ?? UIString.text("未取得"))
    }

    private var retentionDetail: String {
        let nand = model.analytics.nandEndurance
        return "Kret \(String(format: "%.4f", nand.retentionFactor)) · \(nand.requiredRetentionDays.map { UIString.format("必要 %.0f日", $0) } ?? "必要日数未取得") · \(nand.requiredRetentionDaysSource.isEmpty ? "根拠未取得" : nand.requiredRetentionDaysSource)"
    }

    private var timeSeriesDetail: String {
        let series = model.analytics.ftlTimeSeries
        return "\(series.intervals.count) intervals · wall \(UIString.format("%.1f日", series.comparableWallDays)) · operating \(UIString.format("%.1f日", series.comparableOperatingDays)) · latest \(series.series.max { $0.latestSnapshotAt < $1.latestSnapshotAt }.map { UIString.dateTime($0.latestSnapshotAt) } ?? "未取得")"
    }

    private var histogramDetail: String {
        let count = model.analytics.ftlTimeSeries.histogramDeltas.count
        return count == 0 ? UIString.text("未取得または形式未確認") : UIString.format("%d件。bin番号のまま保存し、温度や累積値へ変換していません。", count)
    }

    private var compositionDetail: String {
        guard let snapshot = model.latestASPToolSnapshot else { return "未取得" }
        return "key 5 \(snapshot.hostWriteCompositionCandidateKey5.map(String.init) ?? "—") · key 6 \(snapshot.hostWriteCompositionCandidateKey6.map(String.init) ?? "—") · key 27 \(snapshot.hostWriteCompositionCandidateKey27.map(String.init) ?? "—") · raw only"
    }

    private var residualDetail: String {
        model.analytics.nandEndurance.reconstructionDiagnostics.map { String(describing: $0) } ?? "未取得。残差をdomain予算へ割り当てていません。"
    }

    private var longBaselineDetail: String {
        let analytics = model.analytics.ftlTimeSeries.longBaseline
        guard !analytics.baselines.isEmpty else {
            return ([analytics.notes.first ?? "長基線を構築できません。", "Direct FTLの同一系列・安定topology・単調counterが必要です。"])
                .joined(separator: "\n")
        }
        var lines: [String] = []
        if let calibration = analytics.calibration.last {
            let tlc = calibration.tlcRatio.map { String(format: "%.4f", $0) } ?? "未取得"
            let pslc = calibration.pslcRatio.map { String(format: "%.4f", $0) } ?? "未取得"
            func incrementSummary(_ evidence: BandCounterIncrementEvidence) -> String {
                let ratio = evidence.ratio.map { String(format: "%.4f", $0) } ?? "—"
                let peDelta = evidence.peDelta.map { String(format: "%.0f", $0) } ?? "—"
                return UIString.format("%@ (ΔPE %@, %.1f日 / %d区間)", ratio, peDelta, evidence.observationDays, evidence.intervalCount)
            }
            lines.append(UIString.format("band counter calibration: %@ · %@ · 累積 TLC %@ / pSLC %@ · 増分 TLC %@ / pSLC %@", UIString.text(calibration.verified ? "検証済み" : "未検証"), UIString.text(calibration.validationMethod), tlc, pslc, incrementSummary(calibration.incrementalTLC), incrementSummary(calibration.incrementalPSLC)))
        }
        for baseline in analytics.baselines.prefix(6) {
            let range = "\(signedBytes(baseline.residualLowBytes)) … \(signedBytes(baseline.residualHighBytes))"
            let boundary = baseline.spansInstrumentBoundary ? " · " + UIString.text("計測器境界を跨ぐ") : ""
            lines.append("\(baseline.kind.displayTitle) · \(UIString.text(baseline.path.title)) · \(UIString.text(baseline.status.title)) · best \(signedBytes(baseline.residualBestBytes)) · range \(range)\(boundary)")
        }
        if let projection = analytics.projection,
           let days = projection.estimatedDays {
            lines.append(UIString.format("量子化幅を越える観測見込み: %.0f〜%.0f日（診断仮説）", days.lowerBound, days.upperBound))
        }
        lines.append(contentsOf: analytics.notes.map { UIString.message($0) })
        lines.append(UIString.text("この値は未同定NAND残差の研究診断です。予算・TBW・Forecast WAF・band 0へは使用していません。"))
        return lines.joined(separator: "\n")
    }

    private var aspDetail: String {
        model.latestASPToolSnapshot.map { "\($0.sourceName) · \($0.captureQuality.title) · \(ValueFormatter.fullDate($0.capturedAt))" } ?? "未取得"
    }

    private func signedBytes(_ value: Double) -> String {
        guard value.isFinite else { return "未取得" }
        let sign = value >= 0 ? "+" : "−"
        return sign + ValueFormatter.bytes(abs(value))
    }

    private var ioregDetail: String {
        model.appleStorageProfile.map { "\(UIString.text($0.geometryConfidence.title)) · \(UIString.dateTime($0.capturedAt))" } ?? "未取得"
    }

    private var diagnosticsDetail: String {
        model.diagnostic ?? "診断メッセージなし"
    }
}

private struct ResearchOverviewSection: View {
    @ObservedObject var model: DashboardModel

    private var latestSeries: FTLTimeSeriesGroup? {
        model.analytics.ftlTimeSeries.series.max { $0.latestSnapshotAt < $1.latestSnapshotAt }
    }

    var body: some View {
        DashboardSection(title: "研究データの現在地", subtitle: "空欄ではなく、観測状態と不足理由を表示") {
            VStack(spacing: 0) {
                StatusSummaryRow(
                    title: "Direct FTL",
                    source: .directFTL,
                    status: contractState,
                    detail: model.analytics.nandEndurance.directContractStatus.displayDetail()
                )
                StatusSummaryRow(
                    title: "最新系列",
                    source: .history,
                    status: latestSeries == nil ? .unavailable : .observed,
                    detail: latestSeries.map { "\($0.snapshotCount) snapshots · \(UIString.dateTime($0.latestSnapshotAt))" } ?? "比較可能な系列がありません"
                )
                StatusSummaryRow(
                    title: "Topology",
                    source: .directFTL,
                    status: model.analytics.nandEndurance.directTopology == nil ? .unavailable : .observed,
                    detail: topologySummary
                )
                StatusSummaryRow(
                    title: "イベント",
                    source: .history,
                    status: model.analytics.ftlTimeSeries.reliabilityEvents.isEmpty ? .observed : .attention,
                    detail: model.analytics.ftlTimeSeries.reliabilityEvents.isEmpty ? UIString.text("取得範囲で新規イベントなし") : UIString.format("%d件・詳細は下記", model.analytics.ftlTimeSeries.reliabilityEvents.count)
                )
            }
        }
    }

    private var contractState: StatusSummaryState {
        let status = model.analytics.nandEndurance.directContractStatus
        if status == .noSnapshot { return .unavailable }
        if status.isValidated { return status.runsOnReviewedBuild ? .clear : .observed }
        return .attention
    }

    private var topologySummary: String {
        guard let topology = model.analytics.nandEndurance.directTopology else {
            return "未取得。対応状況と照合結果は取得設定で確認できます"
        }
        return "pSLC \(topology.intermediateBandCount) / TLC \(topology.tlcBandCount) bands · \(topology.contractVersion)"
    }
}

private struct ResearchTopologySection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "Direct topology", subtitle: "区画境界とgeometry") {
            if let topology = model.analytics.nandEndurance.directTopology {
                VStack(spacing: 0) {
                    EvidenceLine(title: "pSLC / TLC bands", value: "\(topology.intermediateBandCount) / \(topology.tlcBandCount)")
                    EvidenceLine(title: "partition境界", value: "\(topology.intermediatePartitionStart) / \(topology.userPartitionStart) / \(topology.numVirtualBlocks)")
                    EvidenceLine(title: "band容量 TLC", value: ValueFormatter.bytes(topology.tlcBandBytes.map { Double($0) }))
                    EvidenceLine(title: "band容量 pSLC", value: ValueFormatter.bytes(topology.pslcBandBytes.map { Double($0) }))
                    EvidenceLine(title: "pSLC物理占有", value: ValueFormatter.bytes(topology.pslcPhysicalFootprintBytes))
                    EvidenceLine(title: "IORegistry照合", value: topologyMatch(model.analytics.nandEndurance.topologyMatchesIORegistryGeometry))
                }
            } else {
                EmptyState(title: "Direct topology未取得", message: "累積損耗の概算は継続しますが、区画配分は補完しません。", systemImage: "questionmark.folder")
            }
        }
    }

    private func topologyMatch(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "整合"
        case .some(false): return "不整合"
        case .none: return "比較なし"
        }
    }
}

private struct ResearchModelSection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "損耗・WAF・保持", subtitle: "予測へ使った入力") {
            VStack(spacing: 0) {
                EvidenceLine(title: "累積 / 観測 / 将来WAF", value: "\(number(result.longWAF)) / \(number(result.recentWAF)) / \(number(result.forecastWAF))")
                EvidenceLine(title: "WAF観測量 / prior", value: "\(ValueFormatter.bytes(result.wafObservedHostBytes)) / \(ValueFormatter.bytes(result.wafPriorEquivalentHostBytes))")
                EvidenceLine(title: "TLC / pSLC損耗", value: "\(number(result.tlcWear)) / \(number(result.pslcWear))")
                EvidenceLine(title: "wearBalance", value: number(result.wearBalance) + " · " + UIString.format("%d点", result.wearBalanceTrend.observations.count))
                EvidenceLine(title: "保持補正 Kret", value: String(format: "%.4f", result.retentionFactor))
                EvidenceLine(title: "保管温度", value: result.thermal.map { String(format: "%.1f°C · %@", $0.storageTemperature, UIString.text($0.storageSource)) } ?? UIString.text("未取得"))
                EvidenceLine(
                    title: "到達ペース",
                    value: UIString.format("現在 %@/日 / %@ %@/日", ValueFormatter.bytes(result.currentPaceBytesPerDay), UIString.text(result.longTermPaceBasis.isEmpty ? "長期" : result.longTermPaceBasis), ValueFormatter.bytes(result.longTermPaceBytesPerDay))
                )
            }
        }
    }

    private var result: NANDEnduranceV2 { model.analytics.nandEndurance }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "未取得"
    }
}

/// A compact, visible readout of the values that used to be reachable only
/// deep inside Advanced.  The values remain raw/estimated as labelled; this
/// section is deliberately not another endurance calculation.
private struct ResearchDirectFTLSection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "Direct FTL / 原取得値", subtitle: "最新snapshot・内部counter・histogramを意味付け状態付きで表示") {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = latestSnapshot {
                    ResponsiveColumns {
                        VStack(alignment: .leading, spacing: 0) {
                            EvidenceLine(title: "取得元", value: "\(snapshot.sourceName) · \(UIString.dateTime(snapshot.capturedAt))")
                            EvidenceLine(title: "build / key map", value: "\(snapshot.sourceBuild ?? "不明") / \(snapshot.directKeyContractVersion ?? snapshot.semanticContractVersion ?? "未取得")")
                            EvidenceLine(title: "firmware epoch", value: snapshot.firmwareEpoch ?? "未取得")
                            EvidenceLine(title: "format / quality", value: "\(snapshot.directFormatVersion.map(String.init) ?? "未取得") / \(snapshot.captureQuality.title)")
                            EvidenceLine(title: "Host / NAND raw", value: "\(uint(snapshot.hostWrites)) / \(uint(snapshot.nandWrites))")
                            EvidenceLine(title: "counter unit", value: "\(snapshot.hostWritesUnitState.title) / \(snapshot.nandWritesUnitState.title)")
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            EvidenceLine(title: "TLC P/E avg / min / max", value: "\(decimal(snapshot.tlcAveragePE)) / \(decimal(snapshot.tlcMinimumPE)) / \(decimal(snapshot.tlcMaximumPE))")
                            EvidenceLine(title: "pSLC P/E avg / min / max", value: "\(decimal(snapshot.slcAveragePE)) / \(decimal(snapshot.slcMinimumPE)) / \(decimal(snapshot.slcMaximumPE))")
                            EvidenceLine(title: "TLC / pSLC EOL", value: "\(decimal(snapshot.tlcEOLPE)) / \(decimal(snapshot.slcEOLPE))")
                            EvidenceLine(title: "write amp / intermediate", value: "\(decimal(snapshot.writeAmp)) / \(decimal(snapshot.intermediateWriteAmp))")
                            EvidenceLine(title: "bad blocks / die failures", value: "\(uint(snapshot.grownBadBlocks)) / \(uint(snapshot.numDieFailures))")
                            EvidenceLine(title: "power-on / spare", value: "\(uint(snapshot.powerOnHours)) h / \(decimal(snapshot.spareAvailablePercent))%")
                        }
                    }

                    if let telemetry = snapshot.researchTelemetry {
                        Divider().padding(.vertical, 2)
                        localizedText("内部イベント・write path")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColor.textSecondary)
                        ResponsiveColumns {
                            VStack(alignment: .leading, spacing: 0) {
                                EvidenceLine(title: "NAND reads", value: uint(telemetry.nandReads))
                                EvidenceLine(title: "Age refresh tier / total", value: "\(telemetry.ageRefreshPerTier.map { $0.map(String.init).joined(separator: ", ") } ?? "未取得") / \(uint(telemetry.ageRefreshTotal))")
                                EvidenceLine(title: "Background refresh", value: uint(telemetry.backgroundRefreshMoves))
                                EvidenceLine(title: "UECC / cross-temperature", value: "\(uint(telemetry.ueccReads)) / \(uint(telemetry.crossTemperatureUECC))")
                                EvidenceLine(title: "Read verify native / pSLC", value: "\(uint(telemetry.readVerifyNative)) / \(uint(telemetry.readVerifySLC))")
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                EvidenceLine(title: "Direct→TLC bands / sectors", value: "\(uint(telemetry.directToTLCBands)) / \(uint(telemetry.directToTLCSectors))")
                                EvidenceLine(title: "Waterfall / non-proportional", value: "\(uint(telemetry.fallbackToWaterfall)) / \(uint(telemetry.nonProportionalDirectToTLCSectors))")
                                EvidenceLine(title: "Pfail / Efail", value: "\(uint(telemetry.numPfail)) / \(uint(telemetry.numEfail))")
                                EvidenceLine(title: "Refresh-on-error / open-band", value: "\(uint(telemetry.bandsRefreshedOnError)) / \(uint(telemetry.openBandReadFail))")
                                EvidenceLine(title: "Offline blocks", value: uint(telemetry.offlineBlocksCnt))
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            localizedText("Histogram（opaque bin）")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColor.textSecondary)
                            ForEach(FTLResearchHistogram.allCases, id: \.rawValue) { histogram in
                                EvidenceLine(
                                    title: histogram.title,
                                    value: histogramSummary(telemetry.histogram(named: histogram))
                                )
                            }
                            localizedText("bin番号を温度・P/Eへ変換せず、取得値として保存しています。")
                                .font(.caption2)
                                .foregroundStyle(AppColor.textMuted)
                        }
                    } else {
                        EmptyState(title: "研究telemetry未取得", message: "Direct FTLのraw snapshotはありますが、build／対応表が未確認のため内部統計を意味付けしていません。", systemImage: "waveform.path.ecg")
                    }
                } else {
                    EmptyState(title: "Direct FTL snapshot未取得", message: "SMART監視は継続し、次回のFTL取得で研究データを表示します。", systemImage: "externaldrive.badge.questionmark")
                }

                if let interval = model.analytics.ftlTimeSeries.latestSeriesLatestInterval {
                    Divider().padding(.vertical, 2)
                    localizedText("最新の比較区間")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColor.textSecondary)
                    ResponsiveColumns {
                        VStack(alignment: .leading, spacing: 0) {
                            EvidenceLine(title: "期間 / basis", value: "\(UIString.format("%.2f日", interval.durationDays)) / \(UIString.text(interval.durationBasis.title))")
                            EvidenceLine(title: "ΔHost / ΔNAND", value: "\(ValueFormatter.bytes(interval.deltaHostBytes)) / \(ValueFormatter.bytes(interval.deltaNANDBytes))")
                            EvidenceLine(title: "区間WAF", value: decimal(interval.observedWAF))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            EvidenceLine(title: "TLC / pSLC P/E", value: "\(decimal(interval.tlcPEStart))→\(decimal(interval.tlcPEEnd)) / \(decimal(interval.pslcPEStart))→\(decimal(interval.pslcPEEnd))")
                            EvidenceLine(title: "operating / wall", value: "\(interval.operatingHoursDelta.map { String(format: "%.1fh", $0) } ?? "未取得") / \(UIString.format("%.2f日", interval.wallDurationDays))")
                            EvidenceLine(title: "residual", value: interval.intervalResidual.map { signedBytes($0.signedResidualBytes) } ?? "未算出")
                            if let bandPath = interval.intervalResidual?.bandPath {
                                EvidenceLine(title: "band path residual", value: "\(bandPath.status.title) · \(signedBytes(bandPath.signedResidualBestBytes))")
                            }
                        }
                    }
                }
            }
        }
    }

    private var latestSnapshot: ASPToolDiagnosticsSnapshot? {
        model.asptoolSnapshots
            .filter { $0.sourceArtifact == .directFTL }
            .max { $0.capturedAt < $1.capturedAt }
    }

    private func uint(_ value: UInt64?) -> String {
        value.map { ValueFormatter.integer($0) } ?? "未取得"
    }

    private func decimal(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "未取得"
    }

    private func histogramSummary(_ bins: [UInt64]?) -> String {
        guard let bins else { return "未取得" }
        let summary = FTLHistogramSummary.summarize(bins)
        let total = summary.totalCount.map { ValueFormatter.integer($0) } ?? "overflow"
        let tail = summary.finalNonZeroBin.map(String.init) ?? "なし"
        return "\(summary.binCount) bins · total \(total) · p50 \(summary.p50Bin.map(String.init) ?? "—") · p90 \(summary.p90Bin.map(String.init) ?? "—") · 最終非zero \(tail)"
    }

    private func signedBytes(_ value: Double) -> String {
        guard value.isFinite else { return "未取得" }
        let sign = value >= 0 ? "+" : "−"
        return sign + ValueFormatter.bytes(abs(value))
    }
}

private struct ResearchReliabilitySummarySection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "Reliability evidence", subtitle: "イベントは寿命倍率へ自動反映しません") {
            VStack(alignment: .leading, spacing: 8) {
                if let evidence = model.analytics.nandEndurance.reliabilityEvidence {
                    HStack {
                        localizedText(evidence.state.title).font(.callout.weight(.medium))
                        Spacer()
                        localizedText(evidence.reason).font(.caption).foregroundStyle(AppColor.textSecondary)
                    }
                    .lineLimit(2)
                    if let telemetry = evidence.latestTelemetry {
                        EvidenceLine(title: "UECC / NAND reads", value: "\(telemetry.ueccReads.map(String.init) ?? "未取得") / \(telemetry.nandReads.map(String.init) ?? "未取得")")
                        EvidenceLine(title: "Age refresh", value: telemetry.ageRefreshPerTier.map { $0.map(String.init).joined(separator: ", ") } ?? "未取得")
                        EvidenceLine(title: "Histogram", value: histogramText)
                    }
                } else {
                    EmptyState(title: "比較履歴なし", message: "次回のDirect FTL取得で比較を開始します。", systemImage: "clock.arrow.circlepath")
                }
                if let event = model.analytics.ftlTimeSeries.reliabilityEvents.sorted(by: { $0.intervalEnd > $1.intervalEnd }).first {
                    HStack {
                        localizedText(event.type.title)
                        Spacer()
                        localizedText("+\(event.delta)").monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(AppColor.amber)
                }
            }
        }
    }

    private var histogramText: String {
        let count = model.analytics.ftlTimeSeries.histogramDeltas.count
        return count == 0 ? "未取得または形式未確認" : UIString.format("%d系列・bin番号のまま", count)
    }
}

private struct ResearchTemperatureSection: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DashboardSection(title: "温度と保持条件", subtitle: "観測値と研究上の仮定を分離") {
            if let thermal = model.analytics.nandEndurance.thermal {
                VStack(spacing: 0) {
                    EvidenceLine(title: "Program / Active", value: "\(temperature(thermal.programTemperature)) / \(temperature(thermal.activeTemperature))")
                    EvidenceLine(title: "Idle / 保管proxy", value: "\(temperature(thermal.idleTemperature)) / \(String(format: "%.1f°C", thermal.storageTemperature))")
                    EvidenceLine(title: "保管温度の由来", value: thermal.storageSource)
                    EvidenceLine(title: "取得率 / 根拠", value: "\(String(format: "%.0f%%", thermal.coverage * 100)) / \(thermal.storageEvidenceScore)/100")
                    EvidenceLine(title: "保持日数", value: model.analytics.nandEndurance.requiredRetentionDays.map { UIString.format("%.1f日", $0) } ?? UIString.text("未取得"))
                    EvidenceLine(title: "外挿倍率", value: model.analytics.nandEndurance.retentionExtrapolationRatio.map { String(format: "%.2f×", $0) } ?? "未取得")
                }
            } else {
                EmptyState(title: "温度評価未取得", message: "SMART／温度履歴が集まると保持条件を表示します。", systemImage: "thermometer.medium")
            }
        }
    }

    private func temperature(_ value: Double?) -> String {
        value.map { String(format: "%.1f°C", $0) } ?? "未取得"
    }
}

private struct ResearchReliabilitySection: View {
    @ObservedObject var model: DashboardModel
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.analytics.ftlTimeSeries.reliabilityEvents.sorted { $0.intervalEnd > $1.intervalEnd }) { event in
                    ReliabilityEventRow(event: event)
                }
            }
            .padding(.top, 8)
        } label: {
            SectionHeading("内部エラーの記録", subtitle: "このデバイス · 永久保存")
        }
        .padding(.vertical, 4)
    }
}

private struct ReliabilityEventRow: View {
    let event: FTLTimeSeriesReliabilityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AppColor.amber)
            VStack(alignment: .leading, spacing: 3) {
                localizedText(event.type.title).font(.callout.weight(.medium))
                if event.provisionalInterpretation == true {
                    Text(verbatim: UIString.text("暫定比較") + " · build " + (event.runtimeBuild ?? "unknown")
                         + " / " + (event.contractBuild ?? "unknown"))
                        .font(.caption).foregroundStyle(AppColor.textSecondary)
                }
                localizedText("\(UIString.dateTime(event.intervalStart)) – \(UIString.dateTime(event.intervalEnd))")
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            Spacer()
            localizedText("+\(event.delta)")
                .font(.body.monospacedDigit())
        }
        .padding(.vertical, 6)
    }
}

private enum DataKind: String {
    case measured = "実測"
    case estimated = "推定"
    case projected = "予測"
    case research = "研究"

    var color: Color {
        switch self {
        case .measured: return AppColor.positive
        case .estimated: return AppColor.accent
        case .projected: return AppColor.blue
        case .research: return AppColor.textSecondary
        }
    }
}

private enum DataSource: String {
    case smart = "SMART"
    case directFTL = "Direct FTL"
    case ioreg = "ioreg"
    case asp = "ASP"
    case history = "履歴"
    case research = "研究"
}

private struct DataKindBadge: View {
    let kind: DataKind
    let source: DataSource

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(kind.color).frame(width: 5, height: 5)
            localizedText(kind.rawValue)
            localizedText("·")
            localizedText(source.rawValue)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(kind.color)
        .accessibilityLabel(UIString.text("\(kind.rawValue)、\(source.rawValue)"))
    }
}

private enum StatusSummaryState {
    case clear, observed, attention, unavailable

    var title: String {
        switch self {
        case .clear: return "取得済み"
        case .observed: return "観測中"
        case .attention: return "確認あり"
        case .unavailable: return "未取得"
        }
    }

    var color: Color {
        switch self {
        case .clear: return AppColor.positive
        case .observed: return AppColor.accent
        case .attention: return AppColor.amber
        case .unavailable: return AppColor.textMuted
        }
    }
}

private struct StatusSummaryRow: View {
    let title: String
    let source: DataSource
    let status: StatusSummaryState
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            localizedText(title).frame(width: 82, alignment: .leading)
            localizedText(status.title).foregroundStyle(status.color).frame(width: 64, alignment: .leading)
            localizedText(detail).foregroundStyle(AppColor.textSecondary)
            Spacer()
            localizedText(source.rawValue).font(.caption2.monospaced()).foregroundStyle(AppColor.textMuted)
        }
        .font(.callout)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(AppColor.border).frame(height: 1) }
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title, subtitle: subtitle)
            content()
        }
    }
}

private struct PageIntro: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            localizedText(title).font(.title2.weight(.semibold))
            localizedText(subtitle).font(.callout).foregroundStyle(AppColor.textSecondary)
        }
    }
}

private struct ResearchDisclosure: View {
    let title: String
    let detail: String
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            localizedText(detail)
                .font(.caption.monospaced())
                .foregroundStyle(AppColor.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } label: {
            HStack {
                localizedText(title).font(.body.weight(.medium))
                Spacer()
                localizedText(isExpanded ? "表示中" : "詳細")
                    .font(.caption)
                    .foregroundStyle(AppColor.textMuted)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(AppColor.border).frame(height: 1) }
    }
}

private struct EmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                localizedText(title).font(.callout.weight(.medium))
                localizedText(message).font(.caption).foregroundStyle(AppColor.textSecondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(AppColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct ResponsiveColumns<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                content()
            }
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
        }
    }
}
