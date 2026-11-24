import Charts
import SwiftUI

/// A deliberately denser overview surface inspired by the supplied reference
/// image. It keeps the existing analytics model intact and changes only the
/// presentation hierarchy: device identity first, then wear, forecasts,
/// history, and reliability evidence.
struct ReferenceSidebarContent: View {
    @Binding var selection: DashboardDestination
    @Binding var researchSelection: ResearchDestination
    @State private var researchExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // All navigation rows fit the window's 680 pt minimum height.
            // A nested ScrollView in the split-view sidebar can apply the
            // title-bar inset to drawing but not hit testing on macOS 27.
            // Keep one layout coordinate space for labels and click targets.
            Group {
                VStack(alignment: .leading, spacing: 4) {
                    ReferenceSidebarButton(
                        title: "ダッシュボード",
                        icon: "rectangle.3.group.fill",
                        selected: selection == .overview
                    ) {
                        selection = .overview
                    }

                    ReferenceSidebarButton(
                        title: "健康指標",
                        icon: "waveform.path.ecg.rectangle.fill",
                        selected: selection == .healthIndicators
                    ) {
                        selection = .healthIndicators
                    }

                    ReferenceSidebarButton(
                        title: "ディスク情報",
                        icon: "internaldrive",
                        selected: selection == .diskInformation
                    ) {
                        selection = .diskInformation
                    }

                    ReferenceSidebarButton(
                        title: "寿命",
                        icon: "chart.line.uptrend.xyaxis",
                        selected: selection == .endurance
                    ) {
                        selection = .endurance
                    }

                    ReferenceSidebarButton(
                        title: "推移",
                        icon: "chart.xyaxis.line",
                        selected: selection == .trends
                    ) {
                        selection = .trends
                    }

                    ReferenceSidebarButton(
                        title: "内部エラーと保持処理",
                        icon: "checkmark.shield.fill",
                        selected: selection == .reliability
                    ) {
                        selection = .reliability
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                researchExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .frame(width: 18)
                                localizedText("研究")
                                Spacer()
                                Image(systemName: researchExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .font(.body.weight(.medium))
                            .foregroundStyle(AppColor.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityValue(UIString.text(researchExpanded ? "展開" : "折りたたむ"))

                        if researchExpanded {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(ResearchDestination.allCases) { destination in
                                    Button {
                                        selection = .research
                                        researchSelection = destination
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: destination.systemImage)
                                                .frame(width: 18)
                                            localizedText(destination.title)
                                        }
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppColor.textPrimary)
                                        .padding(.leading, 30)
                                        .padding(.trailing, 10)
                                        .padding(.vertical, 7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .background(
                                            selection == .research && researchSelection == destination
                                                ? AppColor.sidebarSelection : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .accessibilityAddTraits(selection == .research && researchSelection == destination ? [.isSelected] : [])
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                ReferenceSidebarButton(title: "設定", icon: "gearshape", selected: false) {
                    openSettings()
                }
                ReferenceSidebarButton(title: "このアプリについて", icon: "info.circle", selected: false) {
                    openWindow(id: "about")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background {
            DashboardSidebarBackground()
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

}

private struct ReferenceSidebarButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                localizedText(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.body.weight(selected ? .semibold : .regular))
            .foregroundStyle(AppColor.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? AppColor.sidebarSelection : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityRemoveTraits(.isSelected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private func referenceStatusColor(_ state: DashboardState) -> Color {
    switch state {
    case .ready: return AppColor.positive
    case .limited: return AppColor.amber
    case .failed: return AppColor.red
    case .probing: return AppColor.accent
    case .idle: return AppColor.textMuted
    }
}

/// Colour for a remaining budget fraction: amber at half left or less, red
/// at a quarter left or less.
private func referenceRemainingColor(_ remaining: Double?, healthy: Color) -> Color {
    guard let remaining else { return AppColor.textMuted }
    if remaining <= 0.25 { return AppColor.redFill }
    if remaining <= 0.50 { return AppColor.amberFill }
    return healthy
}

private enum ReferenceDashboardLayout {
    static let statusCardHeight: CGFloat = 84
    static let statusCardMinimumWidth: CGFloat = 158
    static let statusCardMaximumWidth: CGFloat = 210
    static let metricCardHeight: CGFloat = 220
    static let metricCardMinimumWidth: CGFloat = 220
    /// Three rings share a row at the narrowest window.
    static let ringCardMinimumWidth: CGFloat = 190
    /// On a single row the rings give way first, so the free-space and WAF
    /// tables keep the width their values need.
    static let ringCardMaximumWidth: CGFloat = 220
    static let ringCardCompactWidth: CGFloat = 134
    static let wearTableTargetWidth: CGFloat = 290
    static let pairedCardSpacing: CGFloat = 12

    /// Side by side, the three rings span the Writes card below them. When
    /// the paired cards stack, the rings give way to the two tables.
    static func ringCardWidth(contentWidth: CGFloat) -> CGFloat {
        if contentWidth >= pairedCardsBreakpoint {
            let column = (contentWidth - pairedCardSpacing) / 2
            return max(ringCardCompactWidth, (column - 20) / 3)
        }
        let available = (contentWidth - pairedCardSpacing - 30 - 2 * wearTableTargetWidth) / 3
        return min(ringCardMaximumWidth, max(ringCardCompactWidth, available))
    }
    static let mainCardHeight: CGFloat = 352
    static let mainCardMinimumWidth: CGFloat = 420
    static let trendCardHeight: CGFloat = 270
    static let trendCardPadding: CGFloat = 16
    static let trendLabelFont: Font = .system(size: 12).monospacedDigit()
    static let trendCardMinimumWidth: CGFloat = 420
    /// Below this content width the paired cards stack vertically. The chart
    /// cards' picker rows need about 490 pt each, more than their minimum width.
    static let pairedCardsBreakpoint: CGFloat = 1000
    /// Below this content width the five wear tiles use two rows: the rings,
    /// then free space and WAF. A 1200 pt window keeps the single row.
    static let wearRowBreakpoint: CGFloat = 900
    /// Below these widths the header moves the status cards, then the metrics,
    /// onto their own rows.
    /// Raised from 1110 for the fourth status card (retention work pace); the
    /// header metrics and title block were narrowed so four cards fit here.
    static let headerSingleRowBreakpoint: CGFloat = 1280
    static let headerMetricsRowBreakpoint: CGFloat = 700
}

private struct ReferenceContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ReferenceForecastHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ReferenceDashboardView: View {
    @ObservedObject var model: DashboardModel
    let onNavigate: (DashboardDestination) -> Void
    @State private var writeRange: ReferenceWriteRange = .sixMonths
    @State private var writeGranularity: HistoryPeriod = .day
    @State private var wearSeries: ReferenceWearSeriesSelection = .both
    @State private var wearValueMode: ReferenceWearValueMode = .percentage
    @State private var contentWidth: CGFloat = 1180
    @State private var forecastCardHeight: CGFloat = ReferenceDashboardLayout.mainCardHeight

    private var stacksPairedCards: Bool {
        contentWidth < ReferenceDashboardLayout.pairedCardsBreakpoint
    }

    private var headline: DashboardHeadline { model.headline }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReferenceDeviceHeader(model: model, contentWidth: contentWidth) {
                onNavigate(.reliability)
            }

            if let guidance = DashboardGuidance.make(
                state: model.state,
                hasSnapshot: model.snapshot != nil,
                failure: model.lastSmartctlFailure
            ) {
                DashboardGuidanceBanner(guidance: guidance, lastSuccessfulRefreshAt: model.lastSuccessfulRefreshAt) {
                    Task { await model.refresh() }
                }
                // Keep the last reading's verdict visible, so a failed
                // refresh does not hide a SMART warning.
                if model.snapshot != nil {
                    DashboardHeadlineRow(headline: headline, wearFraction: model.headlineWearFraction)
                }
            } else {
                DashboardHeadlineRow(headline: headline, wearFraction: model.headlineWearFraction)
            }

            if let message = model.lastErrorMessage {
                DashboardErrorBar(message: message) { model.dismissLastErrorMessage() }
            }

            if model.snapshot != nil, !model.storageTargetResolution.recordsSMARTHistory {
                Label(UIString.text("このSSDを他のディスクと区別できないため、履歴と温度を記録していません。表示は最新の取得値のみです。"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColor.amber)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AppColor.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(UIString.message(model.storageTargetResolution.reason))
            }

            if model.smartHistoryDecodeDiagnostics.hasFailures {
                ReferenceHistoryDecodeWarning(title: "SMART履歴", diagnostics: model.smartHistoryDecodeDiagnostics)
            }
            if model.temperatureHistoryDecodeDiagnostics.hasFailures {
                ReferenceHistoryDecodeWarning(title: "温度履歴", diagnostics: model.temperatureHistoryDecodeDiagnostics)
            }

            ReferenceWearRow(
                model: model,
                usesGrid: contentWidth < ReferenceDashboardLayout.wearRowBreakpoint,
                ringCardWidth: ReferenceDashboardLayout.ringCardWidth(contentWidth: contentWidth)
            )

            pairedCards {
                ReferenceWriteHistoryCard(model: model, range: $writeRange, granularity: $writeGranularity,
                    cardHeight: stacksPairedCards ? ReferenceDashboardLayout.mainCardHeight : forecastCardHeight)
                    .frame(
                        minWidth: ReferenceDashboardLayout.mainCardMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .top
                    )
                    .frame(height: stacksPairedCards ? ReferenceDashboardLayout.mainCardHeight : forecastCardHeight, alignment: .top)
                ReferenceForecastCard(model: model, minHeight: stacksPairedCards ? nil : ReferenceDashboardLayout.mainCardHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        minWidth: ReferenceDashboardLayout.mainCardMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .top
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ReferenceForecastHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .onPreferenceChange(ReferenceForecastHeightKey.self) { height in
                let resolved = max(ReferenceDashboardLayout.mainCardHeight, height)
                if abs(forecastCardHeight - resolved) > 0.5 { forecastCardHeight = resolved }
            }

            pairedCards {
                ReferenceWearTrendCard(
                    model: model,
                    range: $writeRange,
                    granularity: $writeGranularity,
                    seriesSelection: $wearSeries,
                    valueMode: $wearValueMode
                )
                    .frame(
                        minWidth: ReferenceDashboardLayout.trendCardMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .top
                    )
                    .frame(height: ReferenceDashboardLayout.trendCardHeight, alignment: .top)
                ReferenceTemperatureTrendCard(model: model, range: $writeRange, granularity: $writeGranularity)
                    .frame(
                        minWidth: ReferenceDashboardLayout.trendCardMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .top
                    )
                    .frame(height: ReferenceDashboardLayout.trendCardHeight, alignment: .top)
            }
        }
        // Measure the width offered by the window, not the content's own
        // width, which grows when cards overflow.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ReferenceContentWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(ReferenceContentWidthKey.self) { width in
            guard width > 0 else { return }
            contentWidth = width
        }
        .onAppear {
            let supported = supportedGranularity(model.selectedPeriod)
            writeGranularity = supported
            // The Trends page can leave the model on a granularity this page
            // does not offer; onChange would not fire if the picker already
            // shows the supported value, so push it explicitly.
            if model.selectedPeriod != supported {
                model.selectedPeriod = supported
            }
        }
        .onChange(of: writeGranularity) { _, newValue in
            guard model.selectedPeriod != newValue else { return }
            model.selectedPeriod = newValue
        }
        .onChange(of: model.selectedPeriod) { _, newValue in
            let supported = supportedGranularity(newValue)
            if writeGranularity != supported {
                writeGranularity = supported
            }
        }
    }

    /// Side by side when wide, stacked when the window is narrow.
    private func pairedCards<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = stacksPairedCards
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: ReferenceDashboardLayout.pairedCardSpacing))
        return layout(content)
    }

    private func supportedGranularity(_ period: HistoryPeriod) -> HistoryPeriod {
        switch period {
        case .hour, .day, .week: return period
        case .month: return .day
        }
    }
}

private struct ReferenceHistoryDecodeWarning: View {
    let title: String
    let diagnostics: JSONLDecodeDiagnostics

    var body: some View {
        Label(UIString.format("%@: %@", UIString.text(title), UIString.message(diagnostics.summary)), systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(AppColor.amber)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppColor.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The one-line verdict: status, wear with the controller/NAND cross-check,
/// and the remaining time at the forecast pace.
private struct DashboardHeadlineRow: View {
    let headline: DashboardHeadline
    /// The same wear as `headline.wear`; what is left leads, wear follows.
    let wearFraction: Double?

    private var tint: Color {
        switch headline.tone {
        case .positive: return AppColor.positive
        case .warning: return AppColor.amber
        case .unknown: return AppColor.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(UIString.text(headline.status), systemImage: headline.tone == .positive ? "checkmark.seal.fill" : "questionmark.circle")
                .font(.headline)
                .foregroundStyle(tint)
            if let wearFraction {
                localizedText(UIString.format("残り %@", String(format: "%.2f%%", max(0, 1 - wearFraction) * 100)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
            }
            if let wear = headline.wear {
                localizedText(wear)
                    .font(wearFraction == nil ? .headline.monospacedDigit() : .callout.monospacedDigit())
                    .foregroundStyle(wearFraction == nil ? AppColor.textPrimary : AppColor.textSecondary)
            }
            if let crossCheck = headline.crossCheck {
                localizedText(crossCheck)
                    .font(.callout)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            if let remaining = headline.remaining {
                localizedText(remaining)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Cause, remedy and retry for a failed SMART refresh.
/// An error from loading or saving data, shown until it is dismissed.
private struct DashboardErrorBar: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.amber)
            localizedText(message)
                .font(.callout)
                .foregroundStyle(AppColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(UIString.text("閉じる"))
            .accessibilityLabel(UIString.text("エラーの表示を閉じる"))
        }
        .padding(10)
        .background(AppColor.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DashboardGuidanceBanner: View {
    let guidance: DashboardGuidance
    var lastSuccessfulRefreshAt: Date? = nil
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: guidance.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.title3)
                .foregroundStyle(guidance.severity == .error ? AppColor.red : AppColor.accent)
            VStack(alignment: .leading, spacing: 6) {
                localizedText(guidance.title)
                    .font(.headline)
                    .foregroundStyle(AppColor.textPrimary)
                localizedText(guidance.message)
                    .font(.callout)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastSuccessfulRefreshAt {
                    Text(verbatim: UIString.format("最終成功 %@", UIString.dateTime(lastSuccessfulRefreshAt)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppColor.textSecondary)
                }
                ForEach(Array(guidance.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(index + 1).")
                            .font(.callout.monospacedDigit().weight(.semibold))
                        localizedText(step)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(AppColor.textPrimary)
                }
                if let command = guidance.command {
                    HStack(spacing: 8) {
                        if guidance.retriesWhenAppBecomesActive {
                            Button(UIString.text("ターミナルを開く")) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                            }
                        }
                        localizedText(command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button(UIString.text("コピー")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .accessibilityLabel(UIString.text("コマンドをコピー"))
                    }
                }
                ForEach(guidance.links, id: \.url) { link in
                    Link(destination: link.url) {
                        localizedText(link.title)
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 8)
            // ⌘R is the 操作 > 更新 menu command, which does the same refresh.
            Button(UIString.text("再試行"), action: onRetry)
        }
        .padding(12)
        .background(
            (guidance.severity == .error ? AppColor.red : AppColor.accent).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if guidance.retriesWhenAppBecomesActive { onRetry() }
        }
    }
}

private struct ReferenceDeviceHeader: View {
    @ObservedObject var model: DashboardModel
    var contentWidth: CGFloat = .infinity
    let onOpenReliability: () -> Void

    private var isSingleRow: Bool {
        contentWidth >= ReferenceDashboardLayout.headerSingleRowBreakpoint
    }

    private var metricsShareTitleRow: Bool {
        contentWidth >= ReferenceDashboardLayout.headerMetricsRowBreakpoint
    }

    private var smartCard: SmartStatusCardContent {
        SmartStatusCardContent.make(snapshot: model.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                NenRingDeviceIcon(size: 64)
                    .frame(width: 68, height: 70)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(referenceStatusColor(model.state))
                            .frame(width: 13, height: 13)
                        localizedText(model.state.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(referenceStatusColor(model.state))
                    }
                    localizedText(model.snapshot?.model ?? "Apple SSD")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    localizedText(deviceSubtitle)
                        .font(.callout)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .frame(minWidth: 200, maxWidth: 270, alignment: .leading)
                .layoutPriority(1)
                // Only the title block is combined; the metrics and status
                // cards (including the reliability button) stay reachable.
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(UIString.readout(model.state.title)). \(model.snapshot?.model ?? "Apple SSD"). \(UIString.readout(deviceSubtitle))")

                if metricsShareTitleRow {
                    ReferenceHeaderMetrics(model: model)
                        .layoutPriority(0)
                }

                Spacer(minLength: 4)

                if isSingleRow {
                    statusCards
                }
            }
            if !metricsShareTitleRow {
                ReferenceHeaderMetrics(model: model)
            }
            if !isSingleRow {
                if fitsCardsInOneRow {
                    HStack(alignment: .top, spacing: 10) {
                        statusCards
                    }
                } else {
                    // Four cards at their minimum width do not fit the
                    // narrowest window, so they go two by two.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            temperatureCard
                            smartStatusCard
                        }
                        HStack(alignment: .top, spacing: 10) {
                            ReferenceTopReliabilityCard(model: model, onOpen: onOpenReliability)
                            ReferenceTopRetentionPaceCard(pace: model.analytics.recoveryActivityPace, onOpen: onOpenReliability)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 0)
    }

    private var fitsCardsInOneRow: Bool {
        contentWidth >= 4 * ReferenceDashboardLayout.statusCardMinimumWidth + 3 * 10
    }

    @ViewBuilder
    private var statusCards: some View {
        temperatureCard
        smartStatusCard
        ReferenceTopReliabilityCard(model: model, onOpen: onOpenReliability)
        ReferenceTopRetentionPaceCard(pace: model.analytics.recoveryActivityPace, onOpen: onOpenReliability)
    }

    private var temperatureCard: some View {
        ReferenceTopStatusCard(
            title: "温度",
            value: ValueFormatter.temperature(model.snapshot?.temperatureCelsius),
            detail: temperatureRange,
            icon: "thermometer.medium",
            tint: temperatureTint,
            points: model.temperaturePoints
        )
    }

    private var smartStatusCard: some View {
        ReferenceTopStatusCard(
            title: "S.M.A.R.T.",
            value: smartCard.value,
            detail: smartCard.detail,
            icon: smartCard.icon,
            tint: {
                switch smartCard.tone {
                case .positive: return AppColor.positive
                case .warning: return AppColor.amber
                case .unknown: return AppColor.textMuted
                }
            }(),
            smartDetails: model.snapshot,
            offersSmartDetails: true
        )
    }

    private var deviceSubtitle: String {
        return "\(UIString.readout(model.displayCapacitySummary))  ·  \(UIString.text(connectionSummary))  ·  \(firmware)"
    }

    private var connectionSummary: String {
        if model.deviceCapabilities.appleDirectFTLEligible {
            return UIString.text("Apple内蔵") + " / NVMe"
        }
        switch model.deviceCapabilities.location {
        case .internalDevice:
            return "内蔵ストレージ / SMART"
        case .externalDevice:
            return "外付けストレージ / SMART"
        case .unknown:
            return "ストレージ / SMART"
        }
    }

    private var firmware: String {
        let value = model.appleStorageProfile?.firmwareVersion ?? model.snapshot?.firmware
        return value.map { "FW \($0)" } ?? UIString.format("FW %@", UIString.text("未取得"))
    }

    private var temperatureTint: Color {
        guard let value = model.snapshot?.temperatureCelsius else { return AppColor.textMuted }
        if value >= 70 { return AppColor.red }
        if value >= 60 { return AppColor.amber }
        if Double(value) > TemperatureLineRun.warmThreshold { return AppColor.temperatureWarmText }
        return AppColor.temperatureText
    }

    private var temperatureRange: String {
        guard let values = model.temperaturePoints.map(\.celsius).nilIfEmpty else { return "観測範囲 未取得" }
        let unit = TemperatureUnit.current
        return UIString.format("実測 %.0f–%.0f %@", unit.value(values.min() ?? 0), unit.value(values.max() ?? 0), unit.symbol)
    }

}

private struct ReferenceHeaderMetrics: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                metric(
                    title: "Host読込",
                    value: model.snapshot?.dataUnitsReadBytes.map(ValueFormatter.bytes) ?? "未取得",
                    color: AppColor.read
                )
                metric(
                    title: "Host書込",
                    value: model.snapshot?.dataUnitsWrittenBytes.map(ValueFormatter.bytes) ?? "未取得",
                    color: AppColor.hostWriteText
                )
                metric(
                    title: observedPeriodTitle,
                    value: observedDaysText,
                    color: AppColor.textSecondary
                )
            }
            HStack(spacing: 10) {
                metric(title: "稼働時間", value: powerOnHours, color: AppColor.textPrimary)
                metric(title: "電源投入", value: powerCycles, color: AppColor.textPrimary)
                metric(title: "最終取得", value: compactCaptureDate, color: AppColor.textSecondary)
            }
        }
        .frame(width: 266, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UIString.format("Host読込 %@。Host書込 %@。%@ %@。稼働時間 %@。電源投入 %@。最終取得 %@", model.snapshot?.dataUnitsReadBytes.map(ValueFormatter.bytes) ?? UIString.text("未取得"), model.snapshot?.dataUnitsWrittenBytes.map(ValueFormatter.bytes) ?? UIString.text("未取得"), UIString.text(observedPeriodTitle), observedDaysText, powerOnHours, powerCycles, compactCaptureDate))
    }

    private var observedPeriodTitle: String {
        "履歴期間"
    }

    private func metric(title: String, value: String, color: Color) -> some View {
        ReferenceHeaderMetric(title: title, value: value, color: color)
            .frame(width: 82, alignment: .leading)
    }

    private var powerOnHours: String {
        guard let value = model.snapshot?.powerOnHours else { return "未取得" }
        return "\(ValueFormatter.integer(value)) h"
    }

    private var powerCycles: String {
        model.snapshot?.powerCycleCount.map(ValueFormatter.integer) ?? "未取得"
    }

    private var observedDaysText: String {
        guard let days = model.writeRateSummary.recordedHistoryObservedDays,
              days.isFinite, days >= 0 else { return "未取得" }
        return String(format: "%.1f日", days)
    }

    private var compactCaptureDate: String {
        guard let date = model.snapshot?.capturedAt else { return "未取得" }
        return Self.compactCaptureFormatter.string(from: date)
    }

    private static let compactCaptureFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}

private struct ReferenceHeaderMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            localizedText(title)
                .font(.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            localizedText(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct ReferenceWritePaceSummary: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .foregroundStyle(AppColor.accent)
                localizedText("書込ペース")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppColor.textPrimary)
            }
            .fixedSize()
            .padding(.trailing, 8)

            Divider()
                .frame(height: 34)
                .padding(.trailing, 8)

            // The last metric becomes the average since first use once a date
            // is set, so the pace that forecasts use needs its own place. Five
            // values do not fit beside the title in a narrow card.
            if summary.lifetimeRateBasis != nil {
                ViewThatFits(in: .horizontal) {
                    // Columns follow their contents here, so the row wraps only
                    // when the values really do not fit.
                    HStack(alignment: .top, spacing: 0) {
                        oneDayMetric(fillsColumn: false)
                        Spacer(minLength: 8)
                        sevenDayMetric(fillsColumn: false)
                        Spacer(minLength: 8)
                        thirtyDayMetric(fillsColumn: false)
                        Spacer(minLength: 8)
                        allHistoryMetric(fillsColumn: false)
                        Spacer(minLength: 8)
                        lifetimeMetric(fillsColumn: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 0) { recentMetrics }
                        HStack(alignment: .top, spacing: 0) {
                            allHistoryMetric(fillsColumn: true)
                            lifetimeMetric(fillsColumn: true)
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            } else {
                recentMetrics
                lifetimeMetric(fillsColumn: true)
            }
        }
            if let footnote {
                localizedText(footnote)
                    .font(.caption2)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppColor.border.opacity(0.7))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColor.border.opacity(0.7))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var summary: WriteRateSummary { model.writeRateSummary }

    private var recentMetrics: some View {
        Group {
            oneDayMetric(fillsColumn: true)
            sevenDayMetric(fillsColumn: true)
            thirtyDayMetric(fillsColumn: true)
        }
    }

    private func oneDayMetric(fillsColumn: Bool) -> some View {
        ReferencePaceMetric(title: "直近24時間", value: oneDayRate, marker: oneDayIsProvisional, fillsColumn: fillsColumn,
                            markerHelp: UIString.text("*：観測期間が24時間に満たないため、書込ペースは暫定値です。"))
    }

    private func sevenDayMetric(fillsColumn: Bool) -> some View {
        ReferencePaceMetric(title: "7日", value: summary.sevenDayBytesPerDay, marker: isPartial(summary.sevenDayObservedDays, target: 7), fillsColumn: fillsColumn,
                            markerHelp: observedHelp(summary.sevenDayObservedDays, target: 7))
    }

    private func thirtyDayMetric(fillsColumn: Bool) -> some View {
        ReferencePaceMetric(title: "30日", value: summary.thirtyDayBytesPerDay, marker: isPartial(summary.thirtyDayObservedDays, target: 30), fillsColumn: fillsColumn,
                            markerHelp: observedHelp(summary.thirtyDayObservedDays, target: 30))
    }

    private func allHistoryMetric(fillsColumn: Bool) -> some View {
        ReferencePaceMetric(title: "保存履歴", value: summary.recordedHistoryBytesPerDay, marker: summary.recordedHistoryIsProvisional, fillsColumn: fillsColumn,
                            markerHelp: UIString.text("*：保存履歴が7日に満たない暫定値です。"))
    }

    private func lifetimeMetric(fillsColumn: Bool) -> some View {
        ReferencePaceMetric(title: lifetimeLabel, value: summary.lifetimeBytesPerDay, marker: summary.lifetimeRateBasis == nil, fillsColumn: fillsColumn,
                            markerHelp: UIString.text("*：使用開始日が未設定のため、保存履歴の平均を表示しています。"))
    }

    private var accessibilitySummary: String {
        if summary.lifetimeRateBasis != nil {
            return UIString.format("書込ペース。直近24時間 %@。7日 %@。30日 %@。保存履歴 %@。%@ %@", rateText(oneDayRate), rateText(summary.sevenDayBytesPerDay), rateText(summary.thirtyDayBytesPerDay), rateText(summary.recordedHistoryBytesPerDay), UIString.text(lifetimeLabel), rateText(summary.lifetimeBytesPerDay))
        }
        return UIString.format("書込ペース。直近24時間 %@。7日 %@。30日 %@。%@ %@", rateText(oneDayRate), rateText(summary.sevenDayBytesPerDay), rateText(summary.thirtyDayBytesPerDay), UIString.text(lifetimeLabel), rateText(summary.lifetimeBytesPerDay))
    }

    private var lifetimeLabel: String {
        if summary.lifetimeRateBasis != nil { return "使用開始から" }
        if let days = summary.lifetimeObservedDays, days > 0, days.isFinite {
            return UIString.format("保存履歴 (%.1f日)", days)
        }
        return "保存履歴"
    }

    private var oneDayRate: Double? { summary.oneDayBytesPerDay }

    private var oneDayIsProvisional: Bool {
        oneDayRate != nil && isPartial(summary.oneDayObservedDays, target: 1)
    }

    private func isPartial(_ observed: Double?, target: Double) -> Bool {
        guard let observed, observed.isFinite else { return false }
        return observed + 1e-9 < target
    }

    private func observedHelp(_ observed: Double?, target: Int) -> String {
        UIString.format("*：%d日のうち、観測できたのは%@日です。", target, observed.map { String(format: "%.1f", $0) } ?? "—")
    }

    /// One line under the values that says what the marks mean; only the
    /// meanings that are on screen are listed.
    private var footnote: String? {
        var parts: [String] = []
        if oneDayIsProvisional || isPartial(summary.sevenDayObservedDays, target: 7)
            || isPartial(summary.thirtyDayObservedDays, target: 30)
            || (summary.lifetimeRateBasis != nil && summary.recordedHistoryIsProvisional) {
            parts.append(UIString.text("観測日数が対象期間に満たない暫定値"))
        }
        if summary.lifetimeRateBasis == nil {
            parts.append(UIString.text("使用開始日が未設定のため保存履歴の平均"))
        }
        return parts.isEmpty ? nil : UIString.format("*：%@", parts.joined(separator: UIString.text("／")))
    }

    private func rateText(_ value: Double?) -> String {
        value.map { "\(ValueFormatter.bytes($0))/日" } ?? "未取得"
    }
}

private struct ReferencePaceMetric: View {
    let title: String
    let value: Double?
    let marker: Bool
    var fillsColumn = true
    var markerHelp: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            localizedText(UIString.text(title) + (marker ? "*" : ""))
                .font(.system(size: 11))
                .foregroundStyle(AppColor.textSecondary)
            localizedText(value.map { UIString.format("%@/日", ValueFormatter.bytes($0)) } ?? UIString.text("未取得"))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.95)
        }
        .frame(maxWidth: fillsColumn ? .infinity : nil, alignment: .leading)
        .fixedSize(horizontal: !fillsColumn, vertical: false)
        .help(marker ? (markerHelp ?? "") : "")
    }
}

private struct ReferenceTopStatusCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color
    var points: [TemperaturePoint] = []
    var smartDetails: DriveSnapshot? = nil
    var offersSmartDetails = false
    @State private var showsSmartDetails = false

    var body: some View {
        ReferenceCard(minHeight: ReferenceDashboardLayout.statusCardHeight, padding: 11) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: icon)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        localizedText(title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .layoutPriority(1)
                        if offersSmartDetails {
                            Button { showsSmartDetails.toggle() } label: {
                                Image(systemName: "info.circle").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help(UIString.text("S.M.A.R.T.の警告と取得値"))
                            .popover(isPresented: $showsSmartDetails) {
                                ReferenceSMARTWarningDetails(snapshot: smartDetails)
                            }
                        }
                        if !points.isEmpty {
                            Spacer(minLength: 4)
                            // Beside the title rather than beside the value
                            // and range, so "実測 26–64 °C" keeps the card's
                            // full text width when four cards share the row.
                            // Gives way to a longer title ("Temperature").
                            MiniTemperatureChart(points: points)
                                .frame(minWidth: 24, maxWidth: 44)
                                .frame(height: 20)
                        }
                    }
                    localizedText(value)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    localizedText(detail)
                        .font(.caption2)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(UIString.readout(detail))
                }
                // Fills the card frame, so the three status cards share one
                // width instead of each hugging its own text.
                Spacer(minLength: 0)
            }
        }
        .frame(
            minWidth: ReferenceDashboardLayout.statusCardMinimumWidth,
            maxWidth: ReferenceDashboardLayout.statusCardMaximumWidth,
            alignment: .top
        )
        .frame(height: ReferenceDashboardLayout.statusCardHeight, alignment: .top)
    }
}

private struct ReferenceSMARTWarningDetails: View {
    let snapshot: DriveSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            localizedText("S.M.A.R.T.の警告と取得値").font(.headline)
            if let snapshot {
                let reasons = SMARTWarningReason.collect(from: snapshot)
                if reasons.isEmpty {
                    localizedText(snapshot.smartPassed == true ? "取得した警告項目の該当なし" : "総合判定未取得")
                } else {
                    ForEach(reasons, id: \.self) { reason in
                        Label(UIString.text(reason.title), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColor.amber)
                    }
                }
                Divider()
                metric("総合判定", snapshot.smartPassed.map { $0 ? "PASSED" : "FAILED" })
                metric("Critical Warning", snapshot.criticalWarning.map { "0x" + String($0, radix: 16, uppercase: true) })
                metric("Available Spare", snapshot.availableSpare.map { "\($0)%" })
                metric("閾値", snapshot.availableSpareThreshold.map { "\($0)%" })
                metric("Media / Data Errors", snapshot.mediaAndDataIntegrityErrors.map { String($0) })
                Text(verbatim: UIString.format("最終取得 %@", UIString.dateTime(snapshot.capturedAt)))
                    .font(.caption).foregroundStyle(AppColor.textSecondary)
                localizedText("未取得は0ではありません。累積エラーは今回の増加とは限らず、警告なしも故障しない保証ではありません。")
                    .font(.caption).foregroundStyle(AppColor.textSecondary)
            } else {
                localizedText("未取得")
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 370)
    }

    private func metric(_ name: String, _ value: String?) -> some View {
        HStack {
            localizedText(name)
            Spacer()
            Text(verbatim: value ?? UIString.text("未取得")).monospacedDigit()
        }
    }
}

private struct ReferenceTopReliabilityCard: View {
    @ObservedObject var model: DashboardModel
    let onOpen: () -> Void
    @State private var showsEvidence = false

    var body: some View {
        ReferenceCard(minHeight: ReferenceDashboardLayout.statusCardHeight, padding: 11) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: iconName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        localizedText("内部エラー")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Button { showsEvidence.toggle() } label: {
                            Image(systemName: "info.circle").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(UIString.text("内部エラーと保持処理の内訳"))
                        .popover(isPresented: $showsEvidence) {
                            ReferenceReliabilityEvidenceDetails(model: model)
                        }
                        Spacer(minLength: 2)
                        // In the label row so the status and detail lines can
                        // use the full card width.
                        Button(action: onOpen) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColor.textSecondary)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .help(UIString.text("内部エラーと保持処理を表示"))
                    }
                    localizedText(title)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    localizedText(detail)
                        .font(.caption2)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(UIString.readout(presentation.explanation ?? detail))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            minWidth: ReferenceDashboardLayout.statusCardMinimumWidth,
            maxWidth: ReferenceDashboardLayout.statusCardMaximumWidth,
            alignment: .top
        )
        .frame(height: ReferenceDashboardLayout.statusCardHeight, alignment: .top)
    }

    private var presentation: FTLReliabilityCardPresentation {
        FTLReliabilityCardPresentation.make(
            evidence: model.analytics.nandEndurance.reliabilityEvidence,
            events: model.analytics.ftlTimeSeries.reliabilityEvents
        )
    }

    private var title: String {
        presentation.state.title
    }

    private var detail: String {
        let value = baseDetail
        let latestEvent = model.analytics.ftlTimeSeries.reliabilityEvents.max { $0.intervalEnd < $1.intervalEnd }
        let provisional = model.analytics.nandEndurance.reliabilityEvidence?.provisionalInterpretation == true
            || latestEvent?.provisionalInterpretation == true
        return provisional && !value.contains(UIString.text("暫定比較"))
            ? value + " · " + UIString.text("暫定比較") : value
    }

    private var baseDetail: String {
        if let event = model.analytics.ftlTimeSeries.reliabilityEvents.max(by: { $0.intervalEnd < $1.intervalEnd }) {
            return UIString.format("記録 %@ +%llu", ReliabilityMetricLabel.text(event.type.title), event.delta)
        }
        if let evidence = model.analytics.nandEndurance.reliabilityEvidence {
            if let event = evidence.counters.first(where: { $0.isReliabilityEvent && $0.delta > 0 }) {
                return UIString.format("%@ +%llu", ReliabilityMetricLabel.text(event.name), event.delta)
            }
            if presentation.state == .noAnomalyObserved {
                let compared = evidence.counters.filter(\.isReliabilityEvent).count
                let recovering = evidence.counters.filter { !$0.isReliabilityEvent && $0.delta > 0 }.count
                return UIString.format("エラー比較 %d項目 · 保持処理 %d項目", compared, recovering)
            }
        }
        return presentation.detail
    }

    private var tint: Color {
        switch presentation.state {
        case .comparisonPending: return AppColor.textMuted
        case .noAnomalyObserved: return AppColor.positive
        case .eventPresent: return AppColor.amber
        }
    }

    private var iconName: String {
        switch presentation.state {
        case .comparisonPending: return "clock.arrow.circlepath"
        case .noAnomalyObserved: return "checkmark.shield.fill"
        case .eventPresent: return "exclamationmark.shield.fill"
        }
    }
}

/// The recent pace of retention work (refresh, padding, read verify) against
/// the drive's own longer history. Reads the cached analysis only.
private struct ReferenceTopRetentionPaceCard: View {
    let pace: RecoveryActivityPace
    let onOpen: () -> Void

    var body: some View {
        ReferenceCard(minHeight: ReferenceDashboardLayout.statusCardHeight, padding: 11) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: iconName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        localizedText("保持処理のペース")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 2)
                        Button(action: onOpen) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColor.textSecondary)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .help(UIString.text("内部エラーと保持処理を表示"))
                    }
                    localizedText(title)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(verbatim: detail)
                        .font(.caption2)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(UIString.text("この14日間と、その前の最長8週間を比べます。書き直し・移し替え・書きかけを閉じる処理は動いていた時間あたりで、読出し検証はNANDから読んだ量あたりで比べます。"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            minWidth: ReferenceDashboardLayout.statusCardMinimumWidth,
            maxWidth: ReferenceDashboardLayout.statusCardMaximumWidth,
            alignment: .top
        )
        .frame(height: ReferenceDashboardLayout.statusCardHeight, alignment: .top)
    }

    private var title: String {
        switch pace.state {
        case .insufficientHistory: return "比較待ち"
        case .steady: return "通常のペース"
        case .elevated: return "ペース上昇"
        }
    }

    /// The elevated item, or how many items stayed in their usual range. A
    /// ratio alone could read as alarming while the busiest-week guard says
    /// the week is ordinary, so steady weeks show no ratio here.
    private var detail: String {
        if let row = pace.elevatedRows.max(by: { ($0.ratio ?? .infinity) < ($1.ratio ?? .infinity) }) {
            return "\(ReliabilityMetricLabel.text(row.metric.counterName)) \(RecoveryPaceText.comparison(row))"
        }
        let steady = pace.rows.filter { $0.state == .steady }.count
        guard steady > 0 else { return UIString.text("比較できる履歴が不足") }
        return UIString.format("直近14日 · %d項目とも通常の範囲", steady)
    }

    private var tint: Color {
        switch pace.state {
        case .insufficientHistory: return AppColor.textMuted
        case .steady: return AppColor.positive
        case .elevated: return AppColor.amber
        }
    }

    private var iconName: String {
        switch pace.state {
        case .insufficientHistory: return "clock.arrow.circlepath"
        case .steady: return "arrow.triangle.2.circlepath"
        case .elevated: return "exclamationmark.arrow.triangle.2.circlepath"
        }
    }
}

/// Read the cached analysis only; opening this view never runs a collector or
/// scans the history. Retention work is not an uncorrectable-error alert.
private struct ReferenceReliabilityEvidenceDetails: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                localizedText("内部エラーと保持処理の内訳").font(.headline)
                localizedText("兆候の参考情報 · 故障予測は保留")
                    .font(.subheadline.weight(.medium)).foregroundStyle(AppColor.textSecondary)
                if let evidence = model.analytics.nandEndurance.reliabilityEvidence {
                    Text(verbatim: UIString.readout(evidence.reason)).font(.callout)
                    if let start = evidence.baselineCapturedAt, let end = evidence.comparedAt {
                        Text(verbatim: "\(UIString.dateTime(start)) → \(UIString.dateTime(end))")
                            .font(.caption.monospacedDigit()).foregroundStyle(AppColor.textSecondary)
                    }
                    counterSection("異常イベント", counters: evidence.counters.filter(\.isReliabilityEvent))
                    counterSection("保持処理", counters: evidence.counters.filter { !$0.isReliabilityEvent })
                    paceSection(model.analytics.recoveryActivityPace)
                    localizedText("保持処理は変化を観測するための参考値です。増加のみで保持力の低下や故障接近を確定できません。")
                        .foregroundStyle(AppColor.textSecondary)
                    if let telemetry = evidence.latestTelemetry {
                        DisclosureGroup(UIString.text("最新取得値 · raw")) {
                            VStack(spacing: 5) {
                                rawMetric("UECC reads", telemetry.ueccReads)
                                rawMetric("Cross-temperature UECC", telemetry.crossTemperatureUECC)
                                rawMetric("Host TLC read verify failures", telemetry.hostTLCReadVerifyFailures)
                                rawMetric("Host pSLC read verify failures", telemetry.hostSLCReadVerifyFailures)
                                rawMetric("Age refresh", telemetry.ageRefreshTotal)
                                rawMetric("Background refresh moves", telemetry.backgroundRefreshMoves)
                            }
                            .padding(.top, 5)
                        }
                    }
                    if !evidence.unavailableCounters.isEmpty {
                        localizedText("比較できない項目").font(.subheadline.weight(.semibold))
                        Text(verbatim: evidence.unavailableCounters.map { UIString.readout($0) }.joined(separator: " · "))
                            .foregroundStyle(AppColor.textSecondary)
                    }
                } else {
                    localizedText("比較可能なFTL履歴を待機中")
                }
                if let event = model.analytics.ftlTimeSeries.reliabilityEvents.max(by: { $0.intervalEnd < $1.intervalEnd }) {
                    Divider()
                    localizedText("最後に記録した異常イベント").font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(ReliabilityMetricLabel.text(event.type.title)) +\(event.delta) · \(UIString.dateTime(event.intervalEnd))")
                    localizedText("記録済みイベントは、今回の比較区間の増加とは別です。")
                        .foregroundStyle(AppColor.textSecondary)
                }
                Divider()
                localizedText("保持処理の増加のみで故障とは判定しません。ECC訂正余裕と故障確率は未取得です。")
                localizedText("Pfail／Efail・error refresh・open-band read fail・offline blocksはkey未照合のため監視保留です。")
                    .foregroundStyle(AppColor.textSecondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
        }
        .frame(width: 410, height: 460)
    }

    private func counterSection(_ title: String, counters: [FTLReliabilityCounterDelta]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            localizedText(title).font(.subheadline.weight(.semibold))
            if counters.isEmpty {
                localizedText("比較可能な項目なし").foregroundStyle(AppColor.textSecondary)
            }
            ForEach(counters) { counter in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: ReliabilityMetricLabel.text(counter.name))
                        .reliabilityMetricHelp(counter.name)
                    Spacer()
                    Text(verbatim: "+\(counter.delta)").monospacedDigit()
                        .foregroundStyle(counter.isReliabilityEvent && counter.delta > 0 ? AppColor.amber : AppColor.textSecondary)
                }
            }
        }
    }

    private func rawMetric(_ name: String, _ value: UInt64?) -> some View {
        HStack {
            Text(verbatim: ReliabilityMetricLabel.text(name))
                .reliabilityMetricHelp(name)
            Spacer()
            Text(verbatim: value.map { String($0) } ?? UIString.text("未取得")).monospacedDigit()
        }
    }

    private func paceSection(_ pace: RecoveryActivityPace) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            localizedText("保持処理のペース（直近14日／長期の基準）").font(.subheadline.weight(.semibold))
            if pace.rows.isEmpty {
                localizedText(pace.state.title).foregroundStyle(AppColor.textSecondary)
            }
            ForEach(pace.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: ReliabilityMetricLabel.text(row.metric.counterName))
                        .reliabilityMetricHelp(row.metric.counterName)
                    Spacer()
                    Text(verbatim: RecoveryPaceText.comparison(row)).monospacedDigit()
                        .foregroundStyle(row.state == .elevated ? AppColor.amber : AppColor.textSecondary)
                }
            }
        }
    }
}

enum RecoveryPaceText {
    static func rate(_ value: Double?, basis: RecoveryActivityPaceBasis) -> String {
        guard let value else { return UIString.text("未取得") }
        let digits = basis == .nandReads ? "%.3f" : "%.2f"
        return String(format: digits, value) + UIString.text(basis.unit)
    }

    /// "×1.3", or the state when no ratio can be formed.
    static func comparison(_ row: RecoveryActivityPaceRow) -> String {
        guard row.state != .insufficientHistory else { return UIString.text("履歴不足") }
        if let ratio = row.ratio { return String(format: "×%.2f", ratio) }
        return row.recentCount > 0 ? UIString.text("基準0から増加") : UIString.text("基準・最近とも0")
    }
}

/// The recent pace of recovery activity against the drive's own longer
/// history, and the light check's last result. Cached analysis only.
private struct ReferenceRecoveryPaceCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ReferenceCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    localizedText("保持処理のペース")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    localizedText(pace.state.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(stateTint)
                }
                localizedText("この14日間と、その前の最長8週間を比べます。書き直し・移し替え・書きかけを閉じる処理は動いていた時間あたりで、読出し検証はNANDから読んだ量あたりで比べます。")
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pace.rows.isEmpty {
                    ReferenceEmptyState(title: "比較できる履歴が不足", message: "研究用カウンタを含むDirect FTLの取得が増えると表示します。", systemImage: "clock.arrow.circlepath")
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            localizedText("項目")
                            localizedText("直近14日").gridColumnAlignment(.trailing)
                            localizedText("長期の基準").gridColumnAlignment(.trailing)
                            localizedText("比").gridColumnAlignment(.trailing)
                        }
                        .font(.caption)
                        .foregroundStyle(AppColor.textMuted)
                        ForEach(pace.rows) { row in
                            GridRow {
                                Text(verbatim: ReliabilityMetricLabel.text(row.metric.counterName))
                                    .reliabilityMetricHelp(row.metric.counterName)
                                Text(verbatim: RecoveryPaceText.rate(row.recentRate, basis: row.metric.basis))
                                Text(verbatim: RecoveryPaceText.rate(row.baselineRate, basis: row.metric.basis))
                                    .foregroundStyle(AppColor.textSecondary)
                                Text(verbatim: RecoveryPaceText.comparison(row))
                                    .foregroundStyle(row.state == .elevated ? AppColor.amber : AppColor.textSecondary)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    localizedText(UIString.format("稼働時間 直近 %.0f h · 基準 %.0f h", pace.recentOperatingHours, pace.baselineOperatingHours))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppColor.textMuted)
                }
                localizedText("研究用keyの観測値です。ペースの上昇は変化の目安で、保持力の低下を確定するものではありません。寿命予測には使いません。")
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                checkSummary
            }
        }
    }

    @ViewBuilder
    private var checkSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                localizedText("簡易チェック")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                localizedText(UIString.format("頻度: %@", UIString.text(model.reliabilityCheckSchedule.title)))
                    .font(.caption)
                    .foregroundStyle(AppColor.textMuted)
            }
            if let check = model.lastReliabilityCheck {
                localizedText(UIString.format("前回のチェック: %@", UIString.dateTime(check.checkedAt)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppColor.textSecondary)
                if check.findings.isEmpty {
                    localizedText("前回のチェックからの新たな検出はありません。")
                        .font(.callout)
                } else {
                    ForEach(check.findings) { finding in
                        Label {
                            Text(verbatim: UIString.readout(finding.message))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppColor.amber)
                        }
                        .font(.callout)
                    }
                }
            } else {
                localizedText(model.reliabilityCheckSchedule == .off
                    ? "簡易チェックはオフです。設定の「監視」で頻度を選ぶと、結果をここに表示します。"
                    : "次の分析の更新でチェックします。")
                    .font(.callout)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    private var pace: RecoveryActivityPace { model.analytics.recoveryActivityPace }

    private var stateTint: Color {
        switch pace.state {
        case .insufficientHistory: return AppColor.textMuted
        case .steady: return AppColor.positive
        case .elevated: return AppColor.amber
        }
    }
}

private struct ReferenceWearRow: View {
    @ObservedObject var model: DashboardModel
    var usesGrid = false
    var ringCardWidth = ReferenceDashboardLayout.ringCardMaximumWidth

    var body: some View {
        if usesGrid {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    overallCard
                    tlcCard
                    pslcCard
                }
                HStack(alignment: .top, spacing: 10) {
                    ReferenceStorageHeadroomCard(capacity: model.capacityProfile)
                    ReferenceWAFCard(model: model)
                }
            }
        } else {
            // The same gap as the paired cards, so the rings line up with the
            // Writes card and the tables with the forecast card.
            HStack(alignment: .top, spacing: ReferenceDashboardLayout.pairedCardSpacing) {
                HStack(alignment: .top, spacing: 10) {
                    overallCard
                    tlcCard
                    pslcCard
                }
                HStack(alignment: .top, spacing: 10) {
                    ReferenceStorageHeadroomCard(capacity: model.capacityProfile)
                    ReferenceWAFCard(model: model)
                }
            }
        }
    }

    /// Fixed on a single row; the two-row layout lets the rings share the row.
    private var ringWidth: CGFloat? {
        usesGrid ? nil : ringCardWidth
    }

    /// The same wear as the headline and the actual-use forecast row.
    private var overallCard: some View {
        ReferenceWearGaugeCard(
            title: "全体残量",
            tint: AppColor.overall,
            wearRatio: model.headlineWearFraction,
            detail: hostEnduranceText,
            width: ringWidth,
            explanation: UIString.text("実使用の予測に基づく推定残量です。累積Host書込量を、現在の損耗と予測WAFから換算した予測総Host書込量で割って求めます。SSDの残り寿命を直接測った値ではありません。予測WAFが下がると、書込量が増えても残量が上がることがあります。予測を求められないときは、NAND実測またはコントローラの推定（PU）を表示します。\n\nTLCとpSLCのリングは、各領域のP/E回数を目標P/Eと比べた値です。")
        )
    }

    private var tlcCard: some View {
        ReferenceWearGaugeCard(
            title: "TLC残量",
            tint: AppColor.tlc,
            wearRatio: tlcRatio,
            detail: peText(model.analytics.nandEndurance.tlcPE, model.analytics.nandEndurance.tlcEOL),
            width: ringWidth
        )
    }

    private var pslcCard: some View {
        ReferenceWearGaugeCard(
            title: "pSLC残量",
            tint: AppColor.pslc,
            wearRatio: pslcRatio,
            detail: peText(model.analytics.nandEndurance.pslcPE, model.analytics.nandEndurance.pslcEOL),
            width: ringWidth
        )
    }

    /// Host writes against the actual-use forecast total, as in that row.
    private var hostEnduranceText: String {
        let endurance = model.analytics.nandEndurance
        guard let current = endurance.host
                ?? model.enduranceForecast.currentHostWrittenBytes
                ?? model.snapshot?.dataUnitsWrittenBytes,
              let total = endurance.projection(.real)?.total
                ?? model.enduranceForecast.estimatedEnduranceBytes else { return "未取得" }
        return UIString.readout(ValueFormatter.bytes(current, zeroPadded: true))
            + " / " + UIString.readout(ValueFormatter.bytes(total, zeroPadded: true))
    }

    private var tlcRatio: Double? {
        ratio(current: model.analytics.nandEndurance.tlcPE, eol: model.analytics.nandEndurance.tlcEOL)
            ?? model.analytics.nandEndurance.tlcWear
    }

    private var pslcRatio: Double? {
        ratio(current: model.analytics.nandEndurance.pslcPE, eol: model.analytics.nandEndurance.pslcEOL)
            ?? model.analytics.nandEndurance.pslcWear
    }

    private func ratio(current: Double?, eol: Double?) -> Double? {
        guard let current, let eol, current.isFinite, eol.isFinite, eol > 0 else { return nil }
        return max(0, current / eol)
    }

    private func peText(_ current: Double?, _ eol: Double?) -> String {
        guard let current, let eol else { return "P/E 未取得" }
        return "\(String(format: "%.0f", current)) / \(String(format: "%.0f", eol)) P/E"
    }
}

/// The ring shows the budget left; wear stays below as a smaller value.
/// Wear past the rated P/E shows 0% left and the wear above 100%.
private struct ReferenceWearGaugeCard: View {
    let title: String
    /// The domain's colour, shared with its bars and charts. Low remaining
    /// budget still switches the ring to the warning colours.
    let tint: Color
    let wearRatio: Double?
    let detail: String
    let width: CGFloat?
    /// Shown behind an info button beside the title when the value needs
    /// context, such as a forecast-based estimate.
    var explanation: String?
    @State private var showsExplanation = false

    private var remainingRatio: Double? {
        wearRatio.map { max(0, 1 - $0) }
    }

    var body: some View {
        ReferenceCard(minHeight: ReferenceDashboardLayout.metricCardHeight, padding: 12) {
            // The ring sits centred in the space below the title.
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    localizedText(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppColor.textPrimary)
                    if let explanation {
                        Button { showsExplanation.toggle() } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(AppColor.textSecondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(UIString.text("説明を表示"))
                        .accessibilityLabel(UIString.format("%@の説明を表示", UIString.readout(title)))
                        .popover(isPresented: $showsExplanation) {
                            ForecastExplanationContent(title: UIString.readout(title), explanation: explanation)
                        }
                    }
                }
                // The info button's height, so the rings line up across cards.
                .frame(minHeight: 22, alignment: .leading)
                Spacer(minLength: 8)
                ReferenceRingGauge(
                    ratio: remainingRatio,
                    valueText: remainingRatio.map { String(format: "%.2f%%", $0 * 100) } ?? "未取得",
                    tint: referenceRemainingColor(remainingRatio, healthy: tint),
                    secondary: UIString.format("損耗 %@", wearRatio.map { String(format: "%.2f%%", $0 * 100) } ?? UIString.text("未取得")),
                    detail: detail,
                    diameter: width.map { min(130, $0 - 24) } ?? 130
                )
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(
            minWidth: width ?? ReferenceDashboardLayout.ringCardMinimumWidth,
            maxWidth: width ?? .infinity,
            alignment: .top
        )
        .frame(height: ReferenceDashboardLayout.metricCardHeight, alignment: .top)
    }

    private func logicalShareText(_ capacity: SSDCapacityProfile) -> String {
        guard let logical = capacity.logicalCapacityBytes,
              let geometry = capacity.geometryCapacityBytes,
              geometry > 0 else { return "未取得" }
        let ratio = Double(logical) / Double(geometry)
        guard ratio.isFinite else { return "未取得" }
        let margin = capacity.hiddenPhysicalMarginBytes.map(ValueFormatter.decimalCapacity) ?? "未取得"
        return "\(ValueFormatter.ratioPercent(min(1, max(0, ratio)))) · 構成値 · margin ≈ \(margin)"
    }
}

private struct ReferenceRingGauge: View {
    let ratio: Double?
    let valueText: String
    let tint: Color
    let secondary: String
    let detail: String
    var diameter: CGFloat = 130

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppColor.gaugeTrack, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(1, max(0, ratio ?? 0)))
                .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                localizedText(valueText)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
                localizedText(secondary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                localizedText(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: diameter - 28)
        }
        .frame(width: diameter, height: diameter)
        .frame(maxWidth: .infinity)
        .opacity(ratio == nil ? 0.48 : 1)
    }
}

struct ReferenceStorageHeadroomCard: View {
    let capacity: SSDCapacityProfile?

    var body: some View {
        ReferenceCard(minHeight: ReferenceDashboardLayout.metricCardHeight, padding: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(headroomColor)
                    localizedText("空き容量")
                        .font(.headline.weight(.semibold))
                    localizedText(headroomTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(headroomColor)
                    Spacer(minLength: 4)
                }

                if let capacity, capacity.hasDisplayableValues {
                    ReferenceKeyValueRow(
                        title: "論理容量",
                        value: ValueFormatter.decimalCapacity(capacity.logicalCapacityBytes),
                        fitsOneLine: true
                    )
                    ReferenceKeyValueRow(
                        title: "空き（ファイルシステム）",
                        value: freeSpaceText(capacity),
                        fitsOneLine: true
                    )
                    .help(UIString.text("Finderと同じ、使える空き容量です。キャッシュなど、必要になるとmacOSが空ける領域（パージ可能）を含みます。"))
                    if let purgeable = capacity.purgeableBytes {
                        ReferenceKeyValueRow(
                            title: "うちパージ可能",
                            value: ValueFormatter.decimalCapacity(purgeable),
                        fitsOneLine: true
                        )
                        .help(UIString.text("パージ可能な領域は、空けられるまでSSD上ではデータとして書かれたままです。書込効率（WAF）の分析には、これを除いた空きを使います。"))
                    }
                    ReferenceKeyValueRow(
                        title: "物理容量（推定）",
                        value: ValueFormatter.decimalCapacity(capacity.geometryCapacityBytes),
                        fitsOneLine: true
                    )
                    .help(UIString.text("NANDのジオメトリから推定した総容量です。論理容量に加え、予備領域・管理用途などに相当する領域を含みます。"))
                    ReferenceKeyValueRow(
                        title: "物理マージン（推定）",
                        value: physicalMarginText(capacity),
                        fitsOneLine: true
                    )
                    .help(UIString.text("推定NAND容量と論理容量の差です。予備領域・管理用途などを含み得るため、残っている予備ブロック容量とは異なります。"))
                    HStack {
                        localizedText("ジオメトリ")
                            .font(.caption2)
                            .foregroundStyle(AppColor.textMuted)
                        Spacer()
                        localizedText(capacity.geometryConfidence.title)
                            .font(.caption2.monospaced())
                            .foregroundStyle(AppColor.textMuted)
                    }
                    ReferenceHeadroomGauge(
                        title: "空きの割合",
                        ratio: capacity.displayedFreeRatio,
                        color: headroomFillColor
                    )
                    ReferenceHeadroomGauge(
                        title: "物理マージンの割合",
                        ratio: capacity.hiddenPhysicalMarginRatio,
                        color: headroomFillColor
                    )
                } else {
                    ReferenceEmptyState(
                        title: "容量情報を取得していません",
                        message: "SMARTまたはioregの次回取得で更新されます。",
                        systemImage: "internaldrive"
                    )
                }
            }
        }
        .frame(
            minWidth: ReferenceDashboardLayout.metricCardMinimumWidth,
            maxWidth: .infinity,
            alignment: .top
        )
        .frame(height: ReferenceDashboardLayout.metricCardHeight, alignment: .top)
    }

    private var headroomTitle: String {
        capacity?.headroomRating.title ?? "不明"
    }

    private var headroomFillColor: Color {
        guard let rating = capacity?.headroomRating else { return AppColor.textMuted }
        switch rating {
        case .excellent: return AppColor.positiveFill
        case .good: return AppColor.overall
        case .limited: return AppColor.amberFill
        case .critical: return AppColor.redFill
        case .unknown: return AppColor.textMuted
        }
    }

    private var headroomColor: Color {
        guard let rating = capacity?.headroomRating else { return AppColor.textMuted }
        switch rating {
        case .excellent: return AppColor.positive
        case .good: return AppColor.blue
        case .limited: return AppColor.amber
        case .critical: return AppColor.red
        case .unknown: return AppColor.textMuted
        }
    }

    private func freeSpaceText(_ capacity: SSDCapacityProfile) -> String {
        let bytes = ValueFormatter.decimalCapacity(capacity.displayedFreeBytes)
        guard let ratio = capacity.displayedFreeRatio else { return bytes }
        return "\(bytes) · \(ValueFormatter.ratioPercent(ratio))"
    }

    private func physicalMarginText(_ capacity: SSDCapacityProfile) -> String {
        guard let bytes = capacity.hiddenPhysicalMarginBytes else { return "未取得" }
        let value = "≈ " + ValueFormatter.decimalCapacity(bytes)
        guard let ratio = capacity.hiddenPhysicalMarginRatio else { return value }
        return "\(value) · \(ValueFormatter.ratioPercent(ratio))"
    }

}

private struct ReferenceHeadroomGauge: View {
    let title: String
    let ratio: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                localizedText(title)
                    .font(.caption2)
                    .foregroundStyle(AppColor.textSecondary)
                Spacer()
                localizedText(ValueFormatter.ratioPercent(ratio))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
            }
            // A tinted ProgressView turns gray while the window is inactive.
            ReferenceMeterBar(value: ratio ?? 0, color: color)
        }
    }
}

struct ReferenceWAFCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ReferenceCard(minHeight: ReferenceDashboardLayout.metricCardHeight, padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                localizedText("WAF（FTL NAND / FTL Host）")
                    .font(.headline.weight(.semibold))
                WAFScale(value: result.forecastWAF, clientValue: NANDEnduranceV2.clientWorkloadWAF)
                HStack {
                    localizedText("予測WAF")
                        .foregroundStyle(AppColor.textSecondary)
                    Spacer()
                    localizedText(number(result.forecastWAF))
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                ReferenceKeyValueRow(title: windowTitle(days: 7), value: number(window(days: 7)?.value))
                    .help(partialWindowHelp(days: 7))
                windowSpaceContext(days: 7)
                ReferenceKeyValueRow(title: windowTitle(days: 30), value: number(window(days: 30)?.value))
                    .help(partialWindowHelp(days: 30))
                windowSpaceContext(days: 30)
                ReferenceKeyValueRow(title: "全期間平均 · Client予測", value: "\(number(result.longWAF)) · \(clientWAF)")
            }
        }
        .frame(
            minWidth: ReferenceDashboardLayout.metricCardMinimumWidth,
            maxWidth: .infinity,
            alignment: .top
        )
        .frame(height: ReferenceDashboardLayout.metricCardHeight, alignment: .top)
    }

    private var result: NANDEnduranceV2 { model.analytics.nandEndurance }

    private var clientWAF: String {
        String(format: "%.2f", NANDEnduranceV2.clientWorkloadWAF)
    }

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "未取得"
    }

    private func window(days: Int) -> RetentionWAFWindow? {
        result.wafWindows.first(where: { $0.days == days })
    }

    private func isPartialWindow(days: Int) -> Bool {
        guard let observationDays = window(days: days)?.observationDays,
              observationDays.isFinite else { return false }
        return observationDays + 0.5 < Double(days)
    }

    private func partialWindowHelp(days: Int) -> String {
        isPartialWindow(days: days)
            ? UIString.format("*：%d日の窓のうち、実際に観測できたのは%@日です。", days, observationDays(days: days))
            : UIString.format("%d日の窓のWAF", days)
    }

    private func windowTitle(days: Int) -> String {
        UIString.format("直近%d日", days) + (isPartialWindow(days: days) ? "*" : "")
    }

    /// "*観測 22.4日 · " for a window the card marks, so the mark is
    /// explained where it appears.
    private func observedPrefix(days: Int) -> String {
        isPartialWindow(days: days) ? UIString.format("*観測 %@日", observationDays(days: days)) + " · " : ""
    }

    private func observationDays(days: Int) -> String {
        guard let value = window(days: days)?.observationDays, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    @ViewBuilder
    private func windowSpaceContext(days: Int) -> some View {
        if let window = window(days: days), window.filesystemFreeSampleCount > 0 {
            localizedText(observedPrefix(days: days) + UIString.format("空き最小 %@ · %@ · n=%d", ValueFormatter.decimalCapacity(window.minimumFilesystemFreeBytes), ValueFormatter.ratioPercent(window.minimumFilesystemFreeRatio), window.filesystemFreeSampleCount))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppColor.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(UIString.text("このWAF窓に含まれる取得済みSMARTスナップショットのホストファイルシステム空き容量の最小値。NAND予備領域ではありません。"))
        } else {
            localizedText(observedPrefix(days: days) + UIString.text("空き容量履歴なし"))
                .font(.caption2)
                .foregroundStyle(AppColor.textMuted)
                .help(UIString.text("このWAF窓と時間が重なるSMART空き容量履歴はありません。現在値で代用していません。"))
        }
    }
}

private struct WAFScale: View {
    let value: Double?
    let clientValue: Double

    var body: some View {
        GeometryReader { proxy in
            let lower = 1.0
            let upper = 4.0
            let normalized = min(1, max(0, ((value ?? lower) - lower) / (upper - lower)))
            let clientNormalized = min(1, max(0, (clientValue - lower) / (upper - lower)))
            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColor.gaugeTrack)
                        .frame(height: 5)
                    Capsule()
                        .fill(AppColor.teal)
                        .frame(width: 2, height: 13)
                        .offset(x: max(0, min(proxy.size.width - 2, proxy.size.width * clientNormalized - 1)))
                    Circle()
                        .fill(AppColor.overall)
                        .frame(width: 16, height: 16)
                        .offset(x: max(0, min(proxy.size.width - 16, proxy.size.width * normalized - 8)))
                }
                HStack {
                    localizedText("1.0")
                    Spacer()
                    localizedText("2.0")
                    Spacer()
                    localizedText("3.0")
                    Spacer()
                    localizedText("4.0")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppColor.textSecondary)
            }
        }
        .frame(height: 30)
    }
}

private struct ReferenceKeyValueRow: View {
    let title: String
    let value: String
    /// Keeps the row on one line in a narrow card: the value stays whole and
    /// the title shrinks.
    var fitsOneLine = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            localizedText(title)
                .font(.callout)
                .foregroundStyle(AppColor.textSecondary)
                .lineLimit(fitsOneLine ? 1 : nil)
                .minimumScaleFactor(fitsOneLine ? 0.7 : 1)
            Spacer(minLength: 8)
            localizedText(value)
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: fitsOneLine, vertical: false)
        }
    }
}

private enum ReferenceWriteDisplay: String, CaseIterable {
    case overall, domains, efficiency
    var title: String {
        switch self {
        case .overall: return "全体"
        case .domains: return "内訳"
        case .efficiency: return "WAF"
        }
    }
}

private enum ReferenceWriteAccumulation: String, CaseIterable {
    case interval, cumulative
    var title: String { self == .interval ? "差分" : "累計" }
}

private struct ReferenceWriteHistoryCard: View {
    @ObservedObject var model: DashboardModel
    @Binding var range: ReferenceWriteRange
    @Binding var granularity: HistoryPeriod
    var cardHeight: CGFloat = ReferenceDashboardLayout.mainCardHeight
    @State private var display: ReferenceWriteDisplay = .overall
    @State private var overallSeries = 0
    @State private var accumulation: ReferenceWriteAccumulation = .interval

    var body: some View {
        // Derive the series once per render; the axis labels and boundary
        // markers used to rebuild them (including the NAND allocation) per use.
        // WAF and the direct-write share are ratios; they have no running total.
        let cumulative = accumulation == .cumulative && display != .efficiency
        let efficiencyPoints = display == .efficiency ? efficiencySeries : []
        let points = cumulative || display == .efficiency ? [] : filteredPoints
        let nandPoints = cumulative ? [] : filteredNANDPoints
        // The overall totals are the drive's own counters, so the line ends
        // at the values shown in the tiles below. The estimates have no
        // lifetime counter and add up from the start of the visible range.
        let hostTotals = cumulative && display == .overall && overallSeries != 2 ? hostCounterPoints : []
        let nandTotals = cumulative && display == .overall && overallSeries != 1 ? nandCounterPoints : []
        let tlcIntervals = display == .domains ? domainPoints(tlc: true) : []
        let pslcIntervals = display == .domains ? domainPoints(tlc: false) : []
        let tlcPoints = cumulative ? ReferenceCumulativeWriteSeries.runningTotals(tlcIntervals) : tlcIntervals
        let pslcPoints = cumulative ? ReferenceCumulativeWriteSeries.runningTotals(pslcIntervals) : pslcIntervals
        let chartDates: [Date] = {
            switch display {
            case .overall:
                return points.map(\.bucket) + nandPoints.map(\.bucket) + hostTotals.map(\.bucket) + nandTotals.map(\.bucket)
            case .domains:
                return tlcPoints.map(\.bucket) + pslcPoints.map(\.bucket)
            case .efficiency:
                return efficiencyPoints.map(\.bucket)
            }
        }()
        let visibleBoundaryRecords = visibleBoundaryRecords(in: chartDates)
        let chartHeight = 180 + max(0, cardHeight - ReferenceDashboardLayout.mainCardHeight)
        let controls = HStack(spacing: 10) {
            Picker(UIString.text("書込表示"), selection: $display) {
                ForEach(ReferenceWriteDisplay.allCases, id: \.self) { item in
                    localizedText(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(UIString.text("平均P/Eの量子化と時間按分を含む推定値です。実測NANDの厳密な内訳ではありません。"))
            if display != .efficiency {
                Picker(UIString.text("書込の集計"), selection: $accumulation) {
                    ForEach(ReferenceWriteAccumulation.allCases, id: \.self) { item in
                        localizedText(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(UIString.text("累計：全体はSMARTとFTLの累計カウンタの推移、内訳は表示範囲の始めからの積み上げです。"))
            }
            if cumulative && display == .overall {
                Picker(UIString.text("系列"), selection: $overallSeries) {
                    localizedText("両方").tag(0)
                    Text("Host").tag(1)
                    Text("NAND").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        let legends = HStack(spacing: 10) {
            if display == .efficiency {
                ReferenceLegend(color: AppColor.nand, title: "WAF")
                    .help(UIString.text("NANDに書いた量をHostから書いた量で割った値です。Hostの書込が1 GBに満たない区切りは出しません。"))
                ReferenceLegend(color: AppColor.tlc, title: "TLCへ直接書いた割合")
                    .help(UIString.text("pSLCを通さずにTLCへ直接書いた量を、Hostから書いた量と比べた割合です。直接書く分が増えると、pSLCからTLCへ移す書込が減り、WAFが下がりやすくなります。1セクタを4,096バイトとして換算した目安です。"))
            } else if cumulative && display == .overall {
                ReferenceLegend(color: AppColor.hostWrite, title: "Host")
                ReferenceLegend(color: AppColor.nand, title: "NAND")
            } else if display == .overall {
                ReferenceLegend(color: AppColor.hostWrite, title: "Host書込")
                if !nandPoints.isEmpty {
                    ReferenceLegend(color: AppColor.nand, title: "NAND書込（FTL差分）")
                }
            } else {
                ReferenceLegend(color: AppColor.tlc, title: "TLC推定")
                ReferenceLegend(color: AppColor.pslc, title: "pSLC推定")
            }
            InstrumentBoundaryLegendView(records: visibleBoundaryRecords)
            if granularity == .hour {
                localizedText("直近72時間")
                    .font(.caption2)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        ReferenceCard(minHeight: cardHeight, padding: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    localizedText("書込量")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    HStack(spacing: 8) {
                        Picker(ReferenceDashboardLabels.granularityLabel, selection: $granularity) {
                            localizedText(ReferenceDashboardLabels.granularity(.hour)).tag(HistoryPeriod.hour)
                            localizedText(ReferenceDashboardLabels.granularity(.day)).tag(HistoryPeriod.day)
                            localizedText(ReferenceDashboardLabels.granularity(.week)).tag(HistoryPeriod.week)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()

                        Picker(UIString.text("表示範囲"), selection: $range) {
                            ForEach(ReferenceWriteRange.allCases) { item in
                                localizedText(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                if chartDates.isEmpty {
                    ReferenceEmptyState(title: emptyTitle, message: emptyMessage, systemImage: "chart.bar.xaxis")
                        .frame(minHeight: 145, idealHeight: chartHeight, maxHeight: chartHeight)
                } else if display == .efficiency {
                    ReferenceWriteEfficiencyChart(
                        points: efficiencyPoints,
                        granularity: granularity,
                        chartDates: chartDates
                    )
                    .frame(minHeight: 145, idealHeight: chartHeight, maxHeight: chartHeight)
                } else {
                    Chart {
                        if cumulative {
                            if display == .overall {
                                ForEach(hostTotals) { point in
                                    LineMark(x: .value("時刻", point.bucket), y: .value("Host Writes", point.bytes),
                                             series: .value("系列", "Host Writes"))
                                        .foregroundStyle(AppColor.hostWrite)
                                        .lineStyle(StrokeStyle(lineWidth: 2))
                                }
                                ForEach(nandTotals) { point in
                                    LineMark(x: .value("時刻", point.bucket), y: .value("NAND Writes", point.bytes),
                                             series: .value("系列", "NAND Writes"))
                                        .foregroundStyle(AppColor.nand)
                                        .lineStyle(StrokeStyle(lineWidth: 2))
                                }
                            } else {
                                ForEach(tlcPoints) { point in
                                    LineMark(x: .value("時刻", point.bucket), y: .value("TLC", point.bytes),
                                             series: .value("系列", "TLC"))
                                        .foregroundStyle(AppColor.tlc)
                                        .lineStyle(StrokeStyle(lineWidth: 2))
                                }
                                ForEach(pslcPoints) { point in
                                    LineMark(x: .value("時刻", point.bucket), y: .value("pSLC", point.bytes),
                                             series: .value("系列", "pSLC"))
                                        .foregroundStyle(AppColor.pslc)
                                        .lineStyle(StrokeStyle(lineWidth: 2))
                                }
                            }
                        } else if display == .overall {
                        overlappingBars(host: points, nand: nandPoints)
                        } else {
                            ForEach(tlcPoints) { point in
                                BarMark(x: .value("時刻", point.bucket, unit: barUnit), y: .value("TLC", point.bytes))
                                    .foregroundStyle(AppColor.tlc)
                            }
                            ForEach(pslcPoints) { point in
                                BarMark(x: .value("時刻", point.bucket, unit: barUnit), y: .value("pSLC", point.bytes))
                                    .foregroundStyle(AppColor.pslc)
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
                    // Drive totals start far above zero; a zero baseline would
                    // flatten the growth inside the range.
                    .chartYScale(domain: .automatic(includesZero: !(cumulative && display == .overall)))
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(AppColor.border.opacity(0.55))
                            AxisValueLabel {
                                if let bytes = value.as(Double.self) {
                                    localizedText(ValueFormatter.bytes(bytes))
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(AppColor.border.opacity(0.4))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    localizedText(ReferenceChartAxis.label(date, period: granularity, dates: chartDates))
                                        .font(.caption2.monospacedDigit())
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.78)
                                }
                            }
                        }
                    }
                    // Room above the plot for the boundary markers, which are
                    // drawn above the top edge.
                    .padding(.top, visibleBoundaryRecords.isEmpty ? 0 : 14)
                    .frame(minHeight: 145, idealHeight: chartHeight, maxHeight: chartHeight)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        controls
                        legends
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        controls
                        legends
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .overlay(AppColor.border.opacity(0.6))

                ReferenceWriteStatistics(model: model, showsDomains: display == .domains) {
                    display = .domains
                }
            }
        }
    }

    private var emptyTitle: String {
        switch display {
        case .overall: return "書き込み履歴なし"
        case .domains: return "内訳履歴なし"
        case .efficiency: return "WAF履歴なし"
        }
    }

    private var emptyMessage: String {
        switch display {
        case .overall: return "SMART履歴が集まると推移を表示します。"
        case .domains: return "同系列のgeometryとP/E差分が揃うと表示します。"
        case .efficiency: return "Direct FTLの取得が続くと推移を表示します。"
        }
    }

    private var efficiencySeries: [ReferenceWriteEfficiencyPoint] {
        let analysis = model.analytics.ftlTimeSeries
        let sectorBytes = Double(model.appleStorageProfile?.geometrySectorSizeBytes
            ?? ReferenceWriteEfficiencySeries.fallbackSectorBytes)
        let intervals = (analysis.intervals + analysis.learningExcludedIntervals).map { interval in
            ReferenceWriteEfficiencyInterval(
                startAt: interval.startAt,
                endAt: interval.endAt,
                hostBytes: interval.deltaHostBytes,
                nandBytes: interval.deltaNANDBytes,
                directToTLCBytes: interval.deltaDirectToTLCSectors.map { Double($0) * sectorBytes }
            )
        }
        return ReferenceWriteEfficiencySeries.points(intervals, cutoff: chartCutoff, granularity: granularity)
    }

    private var barUnit: Calendar.Component {
        switch granularity {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    /// Host and NAND overlap by half a bar, both from zero: stacking would
    /// read as Host + NAND written, and side by side bars get too thin on
    /// long ranges.
    @ChartContentBuilder
    private func overlappingBars(host: [WritePoint], nand: [ReferenceNANDWritePoint]) -> some ChartContent {
        ForEach(nand) { point in
            RectangleMark(
                xStart: .value("時刻", barEdge(point.bucket, at: 0.375)),
                xEnd: .value("時刻", barEdge(point.bucket, at: 0.875)),
                yStart: .value("NAND Writes", 0.0),
                yEnd: .value("NAND Writes", point.bytes)
            )
            .foregroundStyle(AppColor.nand)
        }
        ForEach(host) { point in
            RectangleMark(
                xStart: .value("時刻", barEdge(point.bucket, at: 0.125)),
                xEnd: .value("時刻", barEdge(point.bucket, at: 0.625)),
                yStart: .value("Host Writes", 0.0),
                yEnd: .value("Host Writes", point.bytes)
            )
            .foregroundStyle(AppColor.hostWrite)
        }
    }

    /// A point inside the bucket, as a fraction of its length.
    private func barEdge(_ bucket: Date, at fraction: Double) -> Date {
        let next = Calendar.current.date(byAdding: barUnit, value: 1, to: bucket) ?? bucket
        return bucket.addingTimeInterval(next.timeIntervalSince(bucket) * fraction)
    }

    private var filteredPoints: [WritePoint] {
        // Until the rebuild for a new granularity lands, the model still holds
        // the old buckets; drawing them at the new bar width looks wrong.
        let points = model.analytics.writePoints(for: granularity)
        guard let cutoff = chartCutoff else { return points }
        return points.filter { $0.bucket >= cutoff }
    }

    private var chartCutoff: Date? {
        ReferenceChartWindow.cutoff(requested: range.cutoff, granularity: granularity)
    }

    private var filteredNANDPoints: [ReferenceNANDWritePoint] {
        // Learning-excluded intervals are real NAND writes; show them too.
        let analysis = model.analytics.ftlTimeSeries
        let intervals = (analysis.intervals + analysis.learningExcludedIntervals).compactMap { interval -> ReferenceNANDWriteInterval? in
            guard let delta = interval.deltaNANDBytes,
                  delta.isFinite, delta >= 0 else { return nil }
            return ReferenceNANDWriteInterval(startAt: interval.startAt, endAt: interval.endAt, bytes: delta)
        }
        return ReferenceNANDWriteAllocator.allocate(
            intervals,
            cutoff: chartCutoff,
            granularity: granularity,
            maxPointCount: .max
        )
    }

    private func domainPoints(tlc: Bool) -> [ReferenceNANDWritePoint] {
        let analysis = model.analytics.ftlTimeSeries
        let intervals = (analysis.intervals + analysis.learningExcludedIntervals).compactMap { interval -> ReferenceNANDWriteInterval? in
            guard let residual = interval.intervalResidual,
                  let bytes = tlc ? residual.tlcEstimatedWrittenBytes : residual.pslcEstimatedWrittenBytes,
                  bytes.isFinite, bytes >= 0 else { return nil }
            return ReferenceNANDWriteInterval(startAt: interval.startAt, endAt: interval.endAt, bytes: bytes)
        }
        return ReferenceNANDWriteAllocator.allocate(intervals, cutoff: chartCutoff,
            granularity: granularity, maxPointCount: .max)
    }

    private var hostCounterPoints: [ReferenceNANDWritePoint] {
        ReferenceCumulativeWriteSeries.counterPoints(model.analytics.hostWriteCounterSamples,
            cutoff: chartCutoff, granularity: granularity)
    }

    private var nandCounterPoints: [ReferenceNANDWritePoint] {
        ReferenceCumulativeWriteSeries.counterPoints(model.analytics.nandWriteCounterSamples,
            cutoff: chartCutoff, granularity: granularity)
    }

    private func visibleBoundaryRecords(in chartDates: [Date]) -> [InstrumentBoundaryRecord] {
        InstrumentBoundaryPresentation.visibleRecords(
            model.analytics.nandEndurance.instrumentBoundaries,
            in: chartDates
        )
    }

}

struct ReferenceNANDWriteInterval: Equatable, Sendable {
    let startAt: Date
    let endAt: Date
    let bytes: Double
}

struct ReferenceNANDWritePoint: Identifiable, Equatable, Sendable {
    let bucket: Date
    let bytes: Double

    var id: Date { bucket }
}

struct ReferenceCounterSample: Equatable, Sendable {
    let at: Date
    let bytes: Double
}

/// Series for the cumulative view of the Writes chart.
enum ReferenceCumulativeWriteSeries {
    /// The last reading of a lifetime counter in each bucket, plotted at the
    /// time it was taken, so the line ends at the latest reading.
    static func counterPoints(
        _ samples: [ReferenceCounterSample],
        cutoff: Date?,
        granularity: HistoryPeriod,
        calendar: Calendar = .current
    ) -> [ReferenceNANDWritePoint] {
        let component: Calendar.Component
        switch granularity {
        case .hour: component = .hour
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        var latest: [Date: ReferenceCounterSample] = [:]
        for sample in samples {
            guard sample.bytes.isFinite, sample.bytes >= 0,
                  cutoff.map({ sample.at >= $0 }) ?? true,
                  let bucket = calendar.dateInterval(of: component, for: sample.at)?.start else { continue }
            if let current = latest[bucket], current.at >= sample.at { continue }
            latest[bucket] = sample
        }
        return latest.values
            .sorted { $0.at < $1.at }
            .map { ReferenceNANDWritePoint(bucket: $0.at, bytes: $0.bytes) }
    }

    /// Thins counter readings to the last one of each hour.
    static func hourlyReadings(_ samples: [ReferenceCounterSample], calendar: Calendar = .current) -> [ReferenceCounterSample] {
        counterPoints(samples, cutoff: nil, granularity: .hour, calendar: calendar)
            .map { ReferenceCounterSample(at: $0.bucket, bytes: $0.bytes) }
    }

    /// Adds up per-bucket amounts from the first bucket onwards.
    static func runningTotals(_ points: [ReferenceNANDWritePoint]) -> [ReferenceNANDWritePoint] {
        var total = 0.0
        return points.sorted { $0.bucket < $1.bucket }.map { point in
            total += point.bytes
            return ReferenceNANDWritePoint(bucket: point.bucket, bytes: total)
        }
    }
}

struct ReferenceWriteEfficiencyInterval: Equatable, Sendable {
    let startAt: Date
    let endAt: Date
    let hostBytes: Double?
    let nandBytes: Double?
    let directToTLCBytes: Double?
}

struct ReferenceWriteEfficiencyPoint: Identifiable, Equatable, Sendable {
    let bucket: Date
    let waf: Double?
    let directToTLCShare: Double?

    var id: Date { bucket }
}

/// Per-bucket WAF and the share of Host writes that went straight to TLC.
/// Both are ratios of bytes allocated to the same calendar buckets, so a
/// long polling gap spreads evenly instead of spiking one bucket.
enum ReferenceWriteEfficiencySeries {
    /// Geometry sector on the reference Mac (16 KiB page / 4 sectors).
    static let fallbackSectorBytes: UInt64 = 4_096
    /// A bucket with only metadata writes would show a WAF of 5 or more.
    static let minimumHostBytes = 1_000_000_000.0

    static func points(
        _ intervals: [ReferenceWriteEfficiencyInterval],
        cutoff: Date?,
        granularity: HistoryPeriod,
        calendar: Calendar = .current
    ) -> [ReferenceWriteEfficiencyPoint] {
        func allocate(_ source: [ReferenceWriteEfficiencyInterval],
                      _ bytes: (ReferenceWriteEfficiencyInterval) -> Double?) -> [Date: Double] {
            let mapped = source.compactMap { interval -> ReferenceNANDWriteInterval? in
                guard let value = bytes(interval) else { return nil }
                return ReferenceNANDWriteInterval(startAt: interval.startAt, endAt: interval.endAt, bytes: value)
            }
            let points = ReferenceNANDWriteAllocator.allocate(mapped, cutoff: cutoff, granularity: granularity,
                                                              maxPointCount: .max, calendar: calendar)
            return Dictionary(points.map { ($0.bucket, $0.bytes) }, uniquingKeysWith: +)
        }
        // Each ratio only uses intervals where both of its counters exist.
        let wafSource = intervals.filter { $0.hostBytes != nil && $0.nandBytes != nil }
        let directSource = intervals.filter { $0.hostBytes != nil && $0.directToTLCBytes != nil }
        let wafHost = allocate(wafSource) { $0.hostBytes }
        let wafNAND = allocate(wafSource) { $0.nandBytes }
        let directHost = allocate(directSource) { $0.hostBytes }
        let direct = allocate(directSource) { $0.directToTLCBytes }

        func ratio(_ numerator: Double?, _ host: Double?) -> Double? {
            guard let numerator, let host, host >= minimumHostBytes else { return nil }
            let value = numerator / host
            return value.isFinite && value >= 0 ? value : nil
        }
        return Set(wafHost.keys).union(directHost.keys).sorted().compactMap { bucket in
            let waf = ratio(wafNAND[bucket], wafHost[bucket])
            let share = ratio(direct[bucket], directHost[bucket])
            guard waf != nil || share != nil else { return nil }
            return ReferenceWriteEfficiencyPoint(bucket: bucket, waf: waf, directToTLCShare: share)
        }
    }
}

/// WAF line above, direct-to-TLC share bars below, on one shared time axis.
private struct ReferenceWriteEfficiencyChart: View {
    let points: [ReferenceWriteEfficiencyPoint]
    let granularity: HistoryPeriod
    let chartDates: [Date]

    private static let axisLabelWidth: CGFloat = 38

    var body: some View {
        GeometryReader { proxy in
            let shareHeight = max(44, proxy.size.height * 0.3)
            VStack(spacing: 12) {
                Chart {
                    ForEach(wafPoints, id: \.bucket) { point in
                        LineMark(x: .value("時刻", point.bucket, unit: unit), y: .value("WAF", point.value),
                                 series: .value("区間", point.section))
                            .foregroundStyle(AppColor.nand)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("時刻", point.bucket, unit: unit), y: .value("WAF", point.value))
                            .foregroundStyle(AppColor.nand)
                            .symbolSize(14)
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(AppColor.border.opacity(0.55))
                        AxisValueLabel {
                            if let waf = value.as(Double.self) {
                                Text(String(format: "%.2f", waf))
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: Self.axisLabelWidth, alignment: .trailing)
                            }
                        }
                    }
                }
                .chartXAxis(.hidden)

                Chart {
                    ForEach(sharePoints, id: \.bucket) { point in
                        BarMark(x: .value("時刻", point.bucket, unit: unit), y: .value("直接書込", point.value))
                            .foregroundStyle(AppColor.tlc)
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: 0...shareTop)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, shareTop]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(AppColor.border.opacity(0.4))
                        AxisValueLabel {
                            if let share = value.as(Double.self) {
                                Text(String(format: "%.0f%%", share * 100))
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: Self.axisLabelWidth, alignment: .trailing)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                localizedText(ReferenceChartAxis.label(date, period: granularity, dates: chartDates))
                                    .font(.caption2.monospacedDigit())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }
                        }
                    }
                }
                .frame(height: shareHeight)
            }
        }
    }

    private var wafPoints: [(bucket: Date, value: Double, section: Int)] {
        var nextBucket: Date?
        var section = 0
        return points.compactMap { point in
            guard let waf = point.waf else { return nil }
            if point.bucket != nextBucket { section += 1 }
            nextBucket = Calendar.current.date(byAdding: unit, value: 1, to: point.bucket)
            return (point.bucket, waf, section)
        }
    }

    private var sharePoints: [(bucket: Date, value: Double)] {
        points.compactMap { point in point.directToTLCShare.map { (point.bucket, $0) } }
    }

    /// The top of the share axis, rounded up to a 10 % step.
    private var shareTop: Double {
        let peak = sharePoints.map(\.value).max() ?? 0
        return max(0.1, (peak * 10).rounded(.up) / 10)
    }

    private var unit: Calendar.Component {
        switch granularity {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private var xDomain: ClosedRange<Date> {
        let first = points.first?.bucket ?? Date()
        let last = points.last?.bucket ?? first
        let end = Calendar.current.date(byAdding: unit, value: 1, to: last) ?? last.addingTimeInterval(1)
        return first...end
    }
}

/// Allocates a cumulative interval across the calendar buckets it spans. A
/// long FTL polling gap therefore does not appear as a false one-day NAND
/// spike. The allocation is temporal visualization only; it never changes
/// the source interval or the endurance model.
enum ReferenceNANDWriteAllocator {
    static func allocate(
        _ intervals: [ReferenceNANDWriteInterval],
        cutoff: Date?,
        granularity: HistoryPeriod,
        maxPointCount: Int,
        calendar: Calendar = .current
    ) -> [ReferenceNANDWritePoint] {
        guard maxPointCount > 0 else { return [] }
        let component: Calendar.Component
        switch granularity {
        case .hour: component = .hour
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }

        var buckets: [Date: Double] = [:]
        for interval in intervals {
            guard interval.startAt.timeIntervalSinceReferenceDate.isFinite,
                  interval.endAt.timeIntervalSinceReferenceDate.isFinite,
                  interval.endAt > interval.startAt,
                  interval.bytes.isFinite,
                  interval.bytes >= 0 else { continue }
            let visibleStart = max(interval.startAt, cutoff ?? .distantPast)
            let visibleEnd = interval.endAt
            guard visibleEnd > visibleStart,
                  let firstBucket = calendar.dateInterval(of: component, for: visibleStart)?.start else { continue }
            let duration = interval.endAt.timeIntervalSince(interval.startAt)
            guard duration.isFinite, duration > 0 else { continue }

            var bucketStart = firstBucket
            while bucketStart < visibleEnd {
                guard let bucketEnd = calendar.date(byAdding: component, value: 1, to: bucketStart),
                      bucketEnd > bucketStart else { break }
                let overlapStart = max(bucketStart, visibleStart)
                let overlapEnd = min(bucketEnd, visibleEnd)
                if overlapEnd > overlapStart {
                    let fraction = overlapEnd.timeIntervalSince(overlapStart) / duration
                    let contribution = interval.bytes * fraction
                    if contribution.isFinite, contribution >= 0 {
                        buckets[bucketStart, default: 0] += contribution
                    }
                }
                bucketStart = bucketEnd
            }
        }

        let points = buckets.compactMap { bucket, bytes -> ReferenceNANDWritePoint? in
            guard bytes.isFinite, bytes >= 0 else { return nil }
            return ReferenceNANDWritePoint(bucket: bucket, bytes: bytes)
        }.sorted { $0.bucket < $1.bucket }
        return Array(points.suffix(maxPointCount))
    }
}

private enum ReferenceChartAxis {
    static func label(_ date: Date, period: HistoryPeriod, dates: [Date]) -> String {
        let years = Set(dates.map { Calendar.current.component(.year, from: $0) })
        let includeYear = years.count > 1
        let includeDateForHour: Bool = {
            guard period == .hour else { return false }
            let days = Set(dates.map { Calendar.current.startOfDay(for: $0) })
            return days.count > 1 || includeYear
        }()
        return ValueFormatter.chartAxisDate(
            date,
            period: period,
            includeYear: includeYear,
            includeDateForHour: includeDateForHour
        )
    }
}

private func referenceChartBucket(_ date: Date, granularity: HistoryPeriod,
                                  calendar: Calendar = .current) -> Date? {
    let component: Calendar.Component
    switch granularity {
    case .hour: component = .hour
    case .day: component = .day
    case .week: component = .weekOfYear
    case .month: component = .month
    }
    return calendar.dateInterval(of: component, for: date)?.start
}

/// Temperatures older than 30 days arrive as one average per day, newer ones
/// as every sample. Each bucket averages its daily averages, so a week or
/// month that spans both counts every day once instead of letting the
/// per-minute samples outweigh the older days.
enum ReferenceTemperatureBuckets {
    static func averages(_ points: [TemperaturePoint], granularity: HistoryPeriod,
                         calendar: Calendar = .current) -> [TemperaturePoint] {
        var buckets: [Date: [Date: (sum: Double, count: Int)]] = [:]
        for point in points {
            guard let bucket = referenceChartBucket(point.date, granularity: granularity, calendar: calendar) else { continue }
            let day = calendar.startOfDay(for: point.date)
            let total = buckets[bucket]?[day] ?? (0, 0)
            buckets[bucket, default: [:]][day] = (total.sum + point.celsius, total.count + 1)
        }
        return buckets.compactMap { bucket, days -> TemperaturePoint? in
            let daily = days.values.map { $0.sum / Double($0.count) }
            guard !daily.isEmpty else { return nil }
            let average = daily.reduce(0, +) / Double(daily.count)
            guard average.isFinite else { return nil }
            return TemperaturePoint(date: bucket, celsius: average)
        }.sorted { $0.date < $1.date }
    }
}

/// The latest item in each calendar bucket, oldest bucket first. Every
/// bucket in the range is kept; the range alone decides how far back a
/// chart reaches.
enum ReferenceLatestBuckets {
    static func latest<Item>(_ items: [Item], date: (Item) -> Date, granularity: HistoryPeriod,
                             calendar: Calendar = .current) -> [(bucket: Date, item: Item)] {
        var latest: [Date: Item] = [:]
        for item in items {
            guard let bucket = referenceChartBucket(date(item), granularity: granularity, calendar: calendar) else { continue }
            if let existing = latest[bucket], date(existing) >= date(item) { continue }
            latest[bucket] = item
        }
        return latest.map { (bucket: $0.key, item: $0.value) }.sorted { $0.bucket < $1.bucket }
    }
}

/// Align the requested range to the same calendar bucket for each series.
/// Hourly charts show at most the current hour and the previous 71 hours.
enum ReferenceChartWindow {
    static func cutoff(requested: Date?, granularity: HistoryPeriod, now: Date = Date(),
                       calendar: Calendar = .current) -> Date? {
        let component: Calendar.Component
        switch granularity {
        case .hour: component = .hour
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        let aligned = requested.map { calendar.dateInterval(of: component, for: $0)?.start ?? $0 }
        guard granularity == .hour,
              let currentHour = calendar.dateInterval(of: .hour, for: now)?.start,
              let hourlyStart = calendar.date(byAdding: .hour, value: -71, to: currentHour) else { return aligned }
        return aligned.map { max($0, hourlyStart) } ?? hourlyStart
    }
}

private enum ReferenceWriteRange: String, CaseIterable, Identifiable {
    case month, threeMonths, sixMonths, year, all

    var id: String { rawValue }

    var title: String {
        ReferenceDashboardLabels.range(self)
    }

    var accessibilityTitle: String {
        ReferenceDashboardLabels.range(self, compact: false)
    }

    var cutoff: Date? {
        switch self {
        case .month: return Date().addingTimeInterval(-30 * 86_400)
        case .threeMonths: return Date().addingTimeInterval(-90 * 86_400)
        case .sixMonths: return Date().addingTimeInterval(-182 * 86_400)
        case .year: return Date().addingTimeInterval(-365 * 86_400)
        case .all: return nil
        }
    }
}

private enum ReferenceWearSeriesSelection: String, CaseIterable, Identifiable {
    case tlc
    case pslc
    case both

    var id: String { rawValue }
}

private enum ReferenceWearValueMode: String, CaseIterable, Identifiable {
    case percentage
    case pe

    var id: String { rawValue }
}

/// The dashboard uses short, unit-aware labels in segmented controls. This
/// avoids the ambiguous `1M`/`1Y` notation while keeping the existing model
/// and stored history language-independent.
private enum ReferenceDashboardLabels {
    private static var usesEnglish: Bool {
        !UIString.selectedLanguage.lowercased().hasPrefix("ja")
    }

    static func granularity(_ period: HistoryPeriod, compact: Bool = true) -> String {
        if usesEnglish {
            switch period {
            case .hour: return compact ? "1h" : "Hour"
            case .day: return compact ? "1d" : "Day"
            case .week: return compact ? "1w" : "Week"
            case .month: return compact ? "1mo" : "Month"
            }
        }
        switch period {
        case .hour: return "時間"
        case .day: return "日"
        case .week: return "週"
        case .month: return "月"
        }
    }

    static func range(_ range: ReferenceWriteRange, compact: Bool = true) -> String {
        if usesEnglish {
            switch range {
            case .month: return compact ? "1 mo" : "1 month"
            case .threeMonths: return compact ? "3 mo" : "3 months"
            case .sixMonths: return compact ? "6 mo" : "6 months"
            case .year: return compact ? "1 yr" : "1 year"
            case .all: return compact ? "All" : "All time"
            }
        }
        switch range {
        case .month: return "1か月"
        case .threeMonths: return "3か月"
        case .sixMonths: return "6か月"
        case .year: return "1年"
        case .all: return "全期間"
        }
    }

    static func wearSeries(_ selection: ReferenceWearSeriesSelection, compact: Bool = true) -> String {
        if usesEnglish {
            switch selection {
            case .tlc: return "TLC"
            case .pslc: return "pSLC"
            case .both: return compact ? "Both" : "TLC + pSLC"
            }
        }
        switch selection {
        case .tlc: return "TLC"
        case .pslc: return "pSLC"
        case .both: return "両方"
        }
    }

    static func wearValueMode(_ mode: ReferenceWearValueMode, compact: Bool = true) -> String {
        if usesEnglish {
            switch mode {
            case .percentage: return compact ? "%" : "Wear %"
            case .pe: return compact ? "P/E" : "P/E cycles"
            }
        }
        switch mode {
        case .percentage: return "%"
        case .pe: return "P/E"
        }
    }

    static var rangeLabel: String { usesEnglish ? "Range" : "期間" }
    static var granularityLabel: String { usesEnglish ? "Bucket" : "集計単位" }
    static var seriesLabel: String { usesEnglish ? "Series" : "系列" }
    static var valueLabel: String { usesEnglish ? "Value" : "表示" }
}

private struct ReferenceCumulativeTile: View {
    let title: String
    let value: String
    let color: Color
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: compact ? 3 : 4, height: 25)
            VStack(alignment: .leading, spacing: 2) {
                localizedText(title)
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                localizedText(value)
                    .font((compact ? Font.headline : Font.title3).weight(.bold).monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 8 : 10)
        .background(AppColor.canvas.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReferenceWriteStatistics: View {
    @ObservedObject var model: DashboardModel
    var showsDomains = false
    var selectDomains: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            localizedText("書込の内訳")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppColor.textPrimary)
            localizedText("SMART HostとDirect FTL NANDは別カウンタ。WAFはFTL同系列の区間比。")
                .font(.caption2)
                .foregroundStyle(AppColor.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // pSLC is a write cache; only longer-lived data is folded into
            // TLC, so the split shows where the wear actually lands.
            let breakdown = DomainWriteBreakdown.make(
                estimates: model.analytics.nandEndurance.domainBaselineEstimates,
                hostBytes: model.analytics.nandEndurance.host
            )
            let compact = !breakdown.isEmpty
            HStack(spacing: 6) {
                ReferenceCumulativeTile(
                    title: "Host書込（SMART）",
                    value: model.snapshot?.dataUnitsWrittenBytes.map(ValueFormatter.bytes) ?? "未取得",
                    color: AppColor.hostWrite,
                    compact: compact
                )
                ReferenceCumulativeTile(
                    title: "NAND書込（FTL）",
                    value: model.analytics.nandEndurance.nand.map(ValueFormatter.bytes) ?? "未取得",
                    color: AppColor.nand,
                    compact: compact
                )
                ForEach(breakdown, id: \.domain) { item in
                    Button(action: selectDomains) {
                    ReferenceCumulativeTile(
                        title: UIString.format("%@推定", item.domain.title) + (item.perHostByte.map { String(format: " · Host×%.2f", $0) } ?? ""),
                        value: ValueFormatter.bytes(item.bytes),
                        color: item.domain == .tlc ? AppColor.tlc : AppColor.pslc,
                        compact: true
                    )
                    }
                    .buttonStyle(.plain)
                    .opacity(showsDomains ? 1 : 0.75)
                    .help(UIString.format("%@への推定書込量（平均P/E × 容量）。Host書込1バイトあたりの倍率を併記。", item.domain.title))
                }
            }
        }
    }
}

struct ReferenceForecastCard: View {
    @ObservedObject var model: DashboardModel
    var minHeight: CGFloat? = ReferenceDashboardLayout.mainCardHeight
    @State private var showsConditions = false

    var body: some View {
        ReferenceCard(minHeight: minHeight, padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    localizedText("寿命予測")
                        .font(.headline.weight(.semibold))
                    Button {
                        showsConditions.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(UIString.text("予測の比較条件"))
                    .accessibilityLabel(UIString.text("予測の比較条件を表示"))
                    .popover(isPresented: $showsConditions) {
                        comparisonConditions.padding(16).frame(width: 360)
                    }
                    Spacer(minLength: 8)
                    if let forecastObservedPeriodLabel {
                        localizedText(forecastObservedPeriodLabel)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                            .help(UIString.text(model.writeRateSummary.usesUsageStartPace ? "記録が7日未満のため、使用開始日からの書込ペースを暫定で使用しています。" : "保存済みの連続した計測履歴から算出した書込ペースの対象期間です。"))
                    }
                }

                ReferenceForecastProgressRow(
                    title: evidence.rowTitle,
                    subtitle: referenceRangeSubtitle,
                    current: currentHost,
                    total: realTotal,
                    remaining: realRemaining,
                    longTermPaceDate: longTermPaceDate(for: realRemaining),
                    longTermPaceTitle: longTermPaceTitle,
                    arrivalProvisional: model.writeRateSummary.recordedHistoryIsProvisional,
                    color: AppColor.overall,
                    emphasized: true,
                    explanation: UIString.text("現在の損耗とForecast WAFによる予測。保持補正は加えていません。到達時期は保存履歴の書込ペース、記録が7日未満で使用開始日がある場合は使用開始からのペースで換算します。") + "\n\n" + forecastConfidenceDetails,
                    confidence: evidence.smartProvisionalNote == nil ? model.analytics.nandEndurance.observationEvidence.confidence : nil
                )
                if case .ftl = evidence, domainRows.count == 2 {
                    ReferenceDomainWearBars(rows: domainRows, currentPace: longTermPace, provisional: model.writeRateSummary.recordedHistoryIsProvisional)
                }
                if let note = evidence.smartProvisionalNote {
                    Label(UIString.message(note), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                } else {
                    if let scenario = model.analytics.nandEndurance.retentionScenario, let host = currentHost {
                        ReferenceForecastProgressRow(
                            title: scenario.title,
                            subtitle: retentionCondition(scenario) + (scenario.scenarioLimitReached ? " · " + UIString.text("仮定上の限界") : ""),
                            current: currentHost,
                            total: host + scenario.remainingHostBytes,
                            remaining: scenario.remainingHostBytes,
                            longTermPaceDate: longTermPaceDate(for: scenario.remainingHostBytes),
                            longTermPaceTitle: longTermPaceTitle,
                            arrivalProvisional: model.writeRateSummary.recordedHistoryIsProvisional,
                            color: AppColor.retentionScenario,
                            explanation: scenario.displayExplanation + "\n\n" + retentionConfidenceDetails,
                            confidence: retentionConfidence
                        )
                    }
                    ReferenceForecastProgressRow(
                        title: "クライアント負荷",
                        subtitle: "WAF 3.5",
                        current: currentHost,
                        total: clientTotal,
                        remaining: clientRemaining,
                        longTermPaceDate: longTermPaceDate(for: clientRemaining, workload: .client),
                        longTermPaceTitle: longTermPaceTitle,
                        arrivalProvisional: model.writeRateSummary.recordedHistoryIsProvisional,
                        color: AppColor.clientScenario,
                        explanation: UIString.text("今後のWAFを3.5とした比較。保持補正は加えず、現在のTLC／pSLC配分が続くと仮定します。JEDEC試験結果ではありません。")
                    )
                }
                ReferenceForecastProgressRow(
                    title: "参考基準",
                    subtitle: peerTotal.map { ValueFormatter.bytes($0) } ?? UIString.text("未取得"),
                    current: currentHost,
                    total: peerTotal,
                    remaining: peerRemaining,
                    longTermPaceDate: longTermPaceDate(for: peerRemaining, workload: .peerReference),
                    longTermPaceTitle: longTermPaceTitle,
                    arrivalProvisional: model.writeRateSummary.recordedHistoryIsProvisional,
                    color: AppColor.reference,
                    explanation: peerExplanation
                )

                ReferenceWritePaceSummary(model: model)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    localizedText(forecastBasis)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(UIString.text("残Host量はNAND残量を混合Forecast WAFでHost換算した値です。到達時期は保存履歴の書込ペース、記録が7日未満で使用開始日がある場合は使用開始からのペースによる目安です。"))
                    Spacer(minLength: 4)
                    if let forecastInputDate {
                        if model.forecastInputIsStale {
                            Text(verbatim: UIString.format("古い予測・入力 %@", UIString.dateTime(forecastInputDate)))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(AppColor.amber)
                                .lineLimit(1)
                                .help(UIString.text("Direct FTLを2日以上取得できていません。到達日は入力後のSMART Host書込量から補正した目安です。クライアント負荷はForecast WAFでNAND消費量を推定し、WAF 3.5で換算します。"))
                            if !model.automaticDirectFTLCollectionRuns {
                                localizedText("自動取得停止中")
                                    .font(.caption2)
                                    .foregroundStyle(AppColor.amber)
                            }
                        } else {
                            Text(verbatim: UIString.format("入力 %@", UIString.dateTime(forecastInputDate)))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(AppColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var comparisonConditions: some View {
        VStack(alignment: .leading, spacing: 12) {
            localizedText("比較条件").font(.headline)
            localizedText("実使用：現在の損耗とForecast WAFによる推計。日付は表示された書込ペースで換算します。")
            Text(verbatim: forecastConfidenceDetails)
            if let scenario = model.analytics.nandEndurance.retentionScenario {
                Text(verbatim: UIString.format("保持考慮：%@", scenario.displayExplanation))
                Text(verbatim: retentionConfidenceDetails)
                Text(verbatim: UIString.format("現在TLC最大P/E %.0f / 仮定上の許容P/E %.0f。実測の保持試験結果ではありません。", scenario.currentTLCPE, scenario.allowableTLCPE))
                localizedText(UIString.format("許容TLC最大P/E %.0f。基準1500 P/Eの場合は%.0f、残りHost %@。温度の出典：%@。", scenario.allowableTLCPE, scenario.allowableTLCPELower, ValueFormatter.bytes(scenario.remainingHostBytesLower), UIString.readout(scenario.storageTemperatureSource)))
                    .foregroundStyle(AppColor.textSecondary)
            }
            localizedText("クライアント負荷：将来WAF 3.5（比較範囲3〜4）。保持補正は加えず、本機のTLC／pSLC配分が続くと仮定します。JEDEC試験結果ではありません。")
            Text(verbatim: peerExplanation)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var forecastConfidenceDetails: String {
        UIString.text("信頼度は観測データの充実度です。予測の的中率や保持の保証ではありません。")
            + "\n" + model.analytics.nandEndurance.observationEvidence.displayDetails
            + "\n" + UIString.text("容量配分・将来の負荷・保持モデルの仮定は、観測が増えても残ります。")
    }

    private var retentionConfidence: ObservationConfidence {
        let base = model.analytics.nandEndurance.observationEvidence.confidence
        guard let idle = model.analytics.nandEndurance.idleRetentionTemperature else { return .low }
        // Manual temperature is a chosen scenario, not observed evidence.
        if idle.source == .manual { return base }
        return base.rawValue < idle.confidence.rawValue ? base : idle.confidence
    }

    private func retentionCondition(_ scenario: RetentionScenario) -> String {
        guard let idle = model.analytics.nandEndurance.idleRetentionTemperature else { return scenario.displayConditionSummary }
        return UIString.format("%.0f日 · %@", scenario.powerOffDays, idle.displaySummary(in: .current))
    }

    private var retentionConfidenceDetails: String {
        var text = forecastConfidenceDetails
        if let idle = model.analytics.nandEndurance.idleRetentionTemperature {
            text += "\n" + idle.displayEvidenceSummary(in: .current)
            if let range = idle.temperatureRange {
                let unit = TemperatureUnit.current
                text += "\n" + UIString.format("日別代表温度 %@〜%@。", unit.text(range.lowerBound), unit.text(range.upperBound))
            }
            text += "\n" + UIString.text("読書込量は取得区間の平均です。短い負荷や内部処理の停止までは確認できません。")
        }
        return text
    }

    private var currentHost: Double? {
        // The forecast rows must use the same continuity-lane epoch as the
        // remaining and total projections.  The header may continue to show
        // the newest SMART counter, but mixing it into this row makes the
        // displayed total no longer equal current + remaining.
        model.analytics.nandEndurance.host
            ?? model.enduranceForecast.currentHostWrittenBytes
            ?? model.snapshot?.dataUnitsWrittenBytes
    }

    private var forecastInputDate: Date? {
        model.analytics.nandEndurance.inputDate
    }

    private var domainRows: [DomainForecastRow] {
        model.analytics.nandEndurance.domainForecastRows
    }

    private var realProjection: NANDEnduranceV2.Projection? {
        model.analytics.nandEndurance.projection(.real)
    }

    private var clientProjection: NANDEnduranceV2.Projection? {
        model.analytics.nandEndurance.projection(.client)
    }

    private var realTotal: Double? {
        realProjection?.total ?? model.enduranceForecast.estimatedEnduranceBytes
    }

    private var realRemaining: Double? {
        realProjection?.remaining ?? model.enduranceForecast.remainingHostWriteBytes
    }

    private var clientTotal: Double? {
        clientProjection?.total
    }

    private var clientRemaining: Double? {
        clientProjection?.remaining
    }

    private var peerTotal: Double? {
        model.analytics.peerTBWForecast?.thresholdBytes
    }

    private var peerRemaining: Double? {
        guard let total = peerTotal, let host = currentHost else { return nil }
        return max(0, total - host)
    }

    private var peerExplanation: String {
        model.analytics.peerTBWForecast?.reference?.displaySummary
            ?? UIString.text("論理容量未取得・参考基準を算出できません")
    }

    /// For a reference TBW estimate on an Apple SSD, the total as a range
    /// from the retail rating to the reference-Mac extrapolation.
    private var referenceRangeSubtitle: String? {
        guard case let .referenceTBW(reference) = evidence, let upper = reference.appleTendencyBytes else { return nil }
        return UIString.format("総量の幅 %@〜%@", ValueFormatter.bytes(reference.tbwBytes), ValueFormatter.bytes(upper))
    }

    private var evidence: ForecastEvidence {
        ForecastEvidence.resolve(ftlTotal: realProjection?.total, smart: model.enduranceForecast)
    }

    private var forecastBasis: String {
        switch evidence {
        case let .referenceTBW(reference):
            return "暫定：\(reference.summary)"
        case .smartProvisional:
            return "SMART Percentage Used ÷ 累積Host Writesからの暫定推定"
        case .ftl, .unavailable:
            break
        }
        if model.analytics.nandEndurance.domainBottleneckRemaining != nil {
            let waf = model.analytics.nandEndurance.forecastWAF.map { String(format: "%.2f", $0) } ?? "未取得"
            let ratioBasis = model.analytics.nandEndurance.domainWriteShare?.recentTLCShare == nil
                ? "換算比は全期間"
                : "換算比は全期間と直近の加重"
            return UIString.format("WAF %@ · %@ · 保持補正なし", waf, UIString.text(ratioBasis))
        }
        let modelName = model.analytics.nandEndurance.domainModelAvailable
            ? "Direct topology / NAND domain予算"
            : "累積損耗からの概算"
        let waf = model.analytics.nandEndurance.forecastWAF.map { String(format: "%.2f", $0) } ?? "未取得"
        return "\(modelName) · 残Host換算WAF \(waf)"
    }

    private var longTermPace: Double? {
        validRate(model.writeRateSummary.forecastPaceBytesPerDay)
    }

    private var longTermPaceTitle: String {
        UIString.text(model.writeRateSummary.usesUsageStartPace ? "使用開始から" : "保存履歴")
    }

    private var forecastObservedPeriodLabel: String? {
        let summary = model.writeRateSummary
        if summary.usesUsageStartPace, let days = summary.lifetimeObservedDays, days.isFinite, days > 0 {
            return UIString.format("使用開始から%.0f日", days)
        }
        guard let days = summary.recordedHistoryObservedDays, days.isFinite, days > 0 else { return nil }
        return UIString.format("保存履歴%.0f日", days)
    }

    private func longTermPaceDate(for remaining: Double?, workload: NANDEnduranceV2.Projection.Kind = .real) -> Date? {
        EndurancePaceForecast.arrivalDate(
            remainingHostBytes: model.analytics.nandEndurance.remainingNow(remaining, workload: workload),
            hostBytesPerDay: longTermPace,
            now: Date()
        )
    }

    private func validRate(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0 else { return nil }
        return rate
    }
}

/// The real-use forecast in NAND writes, measured by Direct FTL: TLC with
/// pSLC attached below, each as the share of NAND writes left, with
/// used / total NAND writes below. The host-based
/// rows below keep their own units.
private struct ReferenceDomainWearBars: View {
    let rows: [DomainForecastRow]
    let currentPace: Double?
    let provisional: Bool

    var body: some View {
        // The percentage column has the real-use row's width, so the pSLC
        // bar ends where the real-use bar ends.
        HStack(alignment: .top, spacing: 14) {
            ForEach(rows, id: \.domain) { row in
                bar(row)
            }
        }
        .padding(.leading, 10)
        .help(UIString.text("実使用のNAND内訳（FTL実測）。総量は目標P/E × 領域の容量です。予測にはHost換算の残量が小さい領域を使用しますが、基準への到達は故障を意味しません。"))
    }

    // Two lines: domain, bar and percentage left; then wear, NAND writes
    // and years.
    private func bar(_ row: DomainForecastRow) -> some View {
        let total = row.usedNANDBytes + row.remainingNANDBytes
        let remaining = max(0, 1 - row.wearFraction)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: ReferenceForecastProgressRow.columnSpacing) {
                localizedText(row.domain.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .padding(.trailing, 4)
                ReferenceMeterBar(value: remaining, color: domainColor(row.domain))
                    .frame(minWidth: 40)
                    .accessibilityLabel(UIString.format("%@ 残り", row.domain.title))
                    .accessibilityValue(String(format: "%.2f%%", remaining * 100))
                localizedText(String(format: "%.2f%%", remaining * 100))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(row.domain == .tlc ? AppColor.tlcText : AppColor.pslcText)
                    // Leading, so the value sits next to its bar; the column
                    // keeps the real-use row's width, so the bars end together.
                    .frame(width: ReferenceForecastProgressRow.percentColumnWidth, alignment: .leading)
            }
            // One line when it fits; otherwise the years move to a second
            // line whole, instead of breaking inside "~24 years".
            let amounts = "\(UIString.format("損耗 %@", String(format: "%.2f%%", row.wearFraction * 100))) · \(ValueFormatter.bytes(row.usedNANDBytes, zeroPadded: true)) / \(ValueFormatter.bytes(total, zeroPadded: true))"
            let years = yearsText(row.remainingHostBytes)
            ViewThatFits(in: .horizontal) {
                localizedText("\(amounts) · \(years)")
                    .fixedSize()
                VStack(alignment: .leading, spacing: 0) {
                    localizedText(amounts)
                    localizedText(years)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(AppColor.textSecondary)
            .help(UIString.format("NAND残り %@。%@書込/Host %.2f で、Host換算 %@。到達時期と同じHost書込ペースで年数にしています。", ValueFormatter.bytes(row.remainingNANDBytes, zeroPadded: true), row.domain.title, row.nandBytesPerHostByte, ValueFormatter.bytes(row.remainingHostBytes, zeroPadded: true)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func domainColor(_ domain: NANDDomain) -> Color {
        domain == .tlc ? AppColor.tlc : AppColor.pslc
    }

    private func yearsText(_ remainingHostBytes: Double) -> String {
        guard let currentPace, currentPace > 0 else { return "期間 未取得" }
        let years = remainingHostBytes / currentPace / 365.25
        guard years.isFinite else { return "期間 未取得" }
        let prefix = provisional ? UIString.text("暫定") + " " : ""
        if years < 1 { return prefix + UIString.format("約%dか月", max(1, Int((years * 12).rounded()))) }
        return prefix + UIString.format("約%.0f年", years)
    }
}

/// A plain capsule meter. Unlike a tinted ProgressView, light or muted
/// colours are drawn as given instead of being darkened by the system.
private struct ReferenceMeterBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColor.gaugeTrack)
                Capsule().fill(color)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 6)
    }
}

struct ForecastExplanationContent: View {
    let title: String
    let explanation: String

    var body: some View {
        ScrollView {
            ForecastExplanationBody(title: title, explanation: explanation)
        }
        // Popovers inherit the row's environment, including its one-line limit.
        .lineLimit(nil)
        .frame(width: 380)
        .frame(maxHeight: 480, alignment: .leading)
    }
}

struct ForecastExplanationBody: View {
    let title: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.headline)
            Text(verbatim: explanation).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .lineLimit(nil)
    }
}

private struct ReferenceForecastProgressRow: View {
    /// Shared with `ReferenceDomainWearBars`, so the pSLC bar ends where the
    /// real-use bar ends.
    /// The English titles ("Actual use · Confidence: Medium") need the wider
    /// column; the Japanese ones fit in a narrower one, leaving the bar longer.
    static var titleColumnWidth: CGFloat {
        UIString.selectedLanguage.lowercased().hasPrefix("ja") ? 180 : 220
    }
    static let columnSpacing: CGFloat = 8
    static let percentColumnWidth: CGFloat = 56

    let title: String
    let subtitle: String?
    let current: Double?
    let total: Double?
    let remaining: Double?
    let longTermPaceDate: Date?
    let longTermPaceTitle: String
    /// The saved history is still too short to settle the pace.
    let arrivalProvisional: Bool
    let color: Color
    /// Only the real-use row is drawn at full strength; the comparison rows
    /// use a light fill and a gray percentage so they do not read as alerts.
    let emphasized: Bool
    let explanation: String?
    let confidence: ObservationConfidence?
    @State private var showsExplanation = false

    init(
        title: String,
        subtitle: String? = nil,
        current: Double?,
        total: Double?,
        remaining: Double?,
        longTermPaceDate: Date?,
        longTermPaceTitle: String,
        arrivalProvisional: Bool = false,
        color: Color,
        emphasized: Bool = false,
        explanation: String? = nil,
        confidence: ObservationConfidence? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.current = current
        self.total = total
        self.remaining = remaining
        self.longTermPaceDate = longTermPaceDate
        self.longTermPaceTitle = longTermPaceTitle
        self.arrivalProvisional = arrivalProvisional
        self.color = color
        self.emphasized = emphasized
        self.explanation = explanation
        self.confidence = confidence
    }

    // Two lines: title, bar and percentage; then amounts and arrival dates.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: Self.columnSpacing) {
                HStack(spacing: 6) {
                    localizedText(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.textPrimary)
                    if let explanation {
                        Button { showsExplanation.toggle() } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(AppColor.textSecondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(UIString.text("説明を表示"))
                        .accessibilityLabel(UIString.format("%@の説明を表示", UIString.readout(title)))
                        .popover(isPresented: $showsExplanation) {
                            ForecastExplanationContent(title: UIString.readout(title), explanation: explanation)
                        }
                    }
                    if let subtitle, confidence == nil {
                        localizedText(subtitle)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    if let confidence {
                        Text(verbatim: UIString.format("信頼度：%@", UIString.text(confidence.title)))
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                            .help(UIString.text("信頼度は観測データの充実度です。予測の的中率や保持の保証ではありません。"))
                    }
                }
                .lineLimit(1)
                // Preserve the shared column and row height, not a smaller font.
                .frame(width: Self.titleColumnWidth, alignment: .leading)
                .accessibilityElement(children: .combine)
                ReferenceMeterBar(value: remainingFraction ?? 0, color: color)
                    .frame(minWidth: 60)
                localizedText(remainingPercentText)
                    .font(.headline.weight(emphasized ? .bold : .semibold).monospacedDigit())
                    .foregroundStyle(emphasized ? AppColor.overallText : AppColor.textSecondary)
                    .frame(width: Self.percentColumnWidth, alignment: .trailing)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    amounts.fixedSize()
                    arrivalDates.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    amounts
                    arrivalDates
                }
            }
            .foregroundStyle(AppColor.textSecondary)
            if confidence != nil, let subtitle {
                Text(verbatim: UIString.readout(subtitle))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }

    private var amounts: some View {
        localizedText(UIString.format("損耗 %@", usedPercentText) + " · " + UIString.format("%@ / %@ · 残り %@", UIString.readout(ValueFormatter.bytes(current, zeroPadded: true)), UIString.readout(ValueFormatter.bytes(total, zeroPadded: true)), UIString.readout(ValueFormatter.bytes(remaining, zeroPadded: true))))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var arrivalDates: some View {
        longTermArrival
        .font(.system(size: 11).monospacedDigit())
    }

    private var longTermArrival: some View {
        localizedText("\(longTermPaceTitle) \(arrivalProvisional && longTermPaceDate != nil ? UIString.text("暫定") + " " : "")\(shortDate(longTermPaceDate))")
            .fixedSize()
            .help(UIString.format("%@の書込ペースによる到達年月。", longTermPaceTitle))
    }

    /// The bar and the large value show the share left; the share used
    /// stays beside them as a smaller value.
    private var usedFraction: Double? {
        guard let current, let total, total > 0 else { return nil }
        return min(1, max(0, current / total))
    }

    private var remainingFraction: Double? {
        usedFraction.map { 1 - $0 }
    }

    private var usedPercentText: String {
        usedFraction.map { String(format: "%.2f%%", $0 * 100) } ?? "—"
    }

    private var remainingPercentText: String {
        remainingFraction.map { String(format: "%.2f%%", $0 * 100) } ?? "—"
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let years = max(0, date.timeIntervalSinceNow / (365.2425 * 86_400))
        return UIString.format("約%.1f年 · %@", years, UIString.yearMonth(date))
    }
}

/// Keeps a value computed from inputs that are cheap to compare. Every
/// change to the model redraws the dashboard, and several happen in each
/// collection cycle; the trend cards then reuse their bucketed series
/// instead of walking the whole history again.
@MainActor
private final class ReferenceMemo<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    func value(for key: Key, compute: () -> Value) -> Value {
        if let value, self.key == key { return value }
        let fresh = compute()
        self.key = key
        value = fresh
        return fresh
    }
}

private struct ReferenceWearTrendCard: View {
    @ObservedObject var model: DashboardModel
    @Binding var range: ReferenceWriteRange
    @Binding var granularity: HistoryPeriod
    @Binding var seriesSelection: ReferenceWearSeriesSelection
    @Binding var valueMode: ReferenceWearValueMode
    @State private var observationsMemo = ReferenceMemo<ObservationsKey, [ReferenceWearPoint]>()

    /// What the series is computed from, in a form that is cheap to compare.
    private struct ObservationsKey: Equatable {
        let ftlCount: Int
        let latestFTL: Date?
        let deviceID: String?
        let boundaryCount: Int
        let unverifiedBoundaryCount: Int
        let trendCount: Int
        let range: ReferenceWriteRange
        let granularity: HistoryPeriod
    }

    var body: some View {
        // Derive the series only when its inputs change; it walks every FTL
        // snapshot.
        let boundaries = model.analytics.nandEndurance.instrumentBoundaries
        let observations = observationsMemo.value(for: ObservationsKey(
            ftlCount: model.asptoolSnapshots.count,
            latestFTL: model.asptoolSnapshots.last?.capturedAt,
            deviceID: model.snapshot?.deviceID,
            boundaryCount: boundaries.count,
            unverifiedBoundaryCount: boundaries.filter { !$0.continuity.isVerified }.count,
            trendCount: model.analytics.nandEndurance.wearBalanceTrend.observations.count,
            range: range,
            granularity: granularity
        )) { self.observations }
        let displayableObservations = displayable(observations)
        let chartDates = observations.map(\.bucket)
        let visibleBoundaryRecords = visibleBoundaryRecords(in: chartDates)
        ReferenceCard(minHeight: ReferenceDashboardLayout.trendCardHeight, padding: ReferenceDashboardLayout.trendCardPadding) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    localizedText("NAND損耗")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    HStack(spacing: 4) {
                        ReferenceTrendGranularityPicker(selection: $granularity)
                        ReferenceTrendRangePicker(selection: $range)
                    }
                }
                HStack(spacing: 6) {
                    localizedText(ReferenceDashboardLabels.seriesLabel)
                        .font(.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    Picker(ReferenceDashboardLabels.seriesLabel, selection: $seriesSelection) {
                        ForEach(ReferenceWearSeriesSelection.allCases) { selection in
                            localizedText(ReferenceDashboardLabels.wearSeries(selection)).tag(selection)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    localizedText(ReferenceDashboardLabels.valueLabel)
                        .font(.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    Picker(ReferenceDashboardLabels.valueLabel, selection: $valueMode) {
                        ForEach(ReferenceWearValueMode.allCases) { mode in
                            localizedText(ReferenceDashboardLabels.wearValueMode(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 0)
                }

                if displayableObservations.isEmpty {
                    Label(UIString.text(valueMode == .pe ? "P/E履歴を収集中" : "損耗履歴を収集中"), systemImage: "chart.line.uptrend.xyaxis")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 138, maxHeight: .infinity)
                } else {
                    ReferenceWearChart(
                        observations: displayableObservations,
                        seriesSelection: seriesSelection,
                        valueMode: valueMode,
                        visibleBoundaryRecords: visibleBoundaryRecords,
                        granularity: granularity,
                        chartDates: chartDates
                    )
                    // Room above the plot for the boundary markers.
                    .padding(.top, visibleBoundaryRecords.isEmpty ? 0 : 14)
                    .frame(minHeight: 138, maxHeight: .infinity)
                }

                HStack(spacing: 14) {
                    if seriesSelection == .tlc || seriesSelection == .both {
                        ReferenceLegend(color: AppColor.tlc, title: "TLC " + latestValue(for: .tlc, in: displayableObservations), font: ReferenceDashboardLayout.trendLabelFont)
                    }
                    if seriesSelection == .pslc || seriesSelection == .both {
                        ReferenceLegend(color: AppColor.pslc, title: "pSLC " + latestValue(for: .pslc, in: displayableObservations), font: ReferenceDashboardLayout.trendLabelFont)
                    }
                    InstrumentBoundaryLegendView(records: visibleBoundaryRecords)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: ReferenceDashboardLayout.trendCardHeight - 2 * ReferenceDashboardLayout.trendCardPadding)
        }
    }

    private var observations: [ReferenceWearPoint] {
        let source = directWearPoints.isEmpty
            ? model.analytics.nandEndurance.wearBalanceTrend.observations.map {
                ReferenceWearPoint(bucket: $0.capturedAt, tlcWear: $0.tlcWear, pslcWear: $0.pslcWear)
            }
            : directWearPoints
        let cutoff = ReferenceChartWindow.cutoff(requested: range.cutoff, granularity: granularity)
        let filtered = cutoff.map { cutoff in source.filter { $0.bucket >= cutoff } } ?? source
        return bucketed(filtered)
    }

    private func displayable(_ observations: [ReferenceWearPoint]) -> [ReferenceWearPoint] {
        observations.filter { point in
            switch seriesSelection {
            case .tlc: return point.displayValue(for: .tlc, mode: valueMode) != nil
            case .pslc: return point.displayValue(for: .pslc, mode: valueMode) != nil
            case .both:
                return point.displayValue(for: .tlc, mode: valueMode) != nil ||
                    point.displayValue(for: .pslc, mode: valueMode) != nil
            }
        }
    }

    private func visibleBoundaryRecords(in chartDates: [Date]) -> [InstrumentBoundaryRecord] {
        InstrumentBoundaryPresentation.visibleRecords(
            model.analytics.nandEndurance.instrumentBoundaries,
            in: chartDates
        )
    }

    private var directWearPoints: [ReferenceWearPoint] {
        let currentDeviceID = model.snapshot?.deviceID
        let snapshots = model.asptoolSnapshots
            .filter { snapshot in
                snapshot.sourceArtifact == .directFTL &&
                    (currentDeviceID == nil || snapshot.deviceID == nil || snapshot.deviceID == currentDeviceID)
            }
            .sorted { $0.capturedAt < $1.capturedAt }

        return snapshots.compactMap { snapshot in
            guard let tlcPE = snapshot.tlcAveragePE,
                  let tlcEOL = snapshot.tlcEOLPE,
                  let pslcPE = snapshot.slcAveragePE,
                  let pslcEOL = snapshot.slcEOLPE,
                  tlcPE.isFinite, tlcPE >= 0,
                  tlcEOL.isFinite, tlcEOL > 0,
                  pslcPE.isFinite, pslcPE >= 0,
                  pslcEOL.isFinite, pslcEOL > 0 else {
                return nil
            }
            let tlcWear = tlcPE / tlcEOL
            let pslcWear = pslcPE / pslcEOL
            guard tlcWear.isFinite, pslcWear.isFinite else { return nil }
            return ReferenceWearPoint(
                bucket: snapshot.capturedAt,
                tlcWear: tlcWear,
                pslcWear: pslcWear,
                tlcPE: tlcPE,
                pslcPE: pslcPE,
                tlcEOLPE: tlcEOL,
                pslcEOLPE: pslcEOL,
                seriesID: continuitySeriesID(for: snapshot)
            )
        }
    }

    private func continuitySeriesID(for snapshot: ASPToolDiagnosticsSnapshot) -> String {
        let core = snapshot.resolvedCoreWearVersion ?? "core-unknown"
        let unit = "\(snapshot.hostWritesUnitState.rawValue)-\(snapshot.nandWritesUnitState.rawValue)"
        let breaks = model.analytics.nandEndurance.instrumentBoundaries.reduce(into: 0) { count, record in
            if record.boundary.after <= snapshot.capturedAt && !record.continuity.isVerified {
                count += 1
            }
        }
        // Verified instrument transitions intentionally keep the same line;
        // pending/failed transitions start a new visible segment.
        return "\(core)|\(snapshot.extractionVersion)|\(unit)|break-\(breaks)"
    }

    private func bucketed(_ points: [ReferenceWearPoint]) -> [ReferenceWearPoint] {
        ReferenceLatestBuckets.latest(points, date: \.bucket, granularity: granularity)
            .map { $0.item.withBucket($0.bucket) }
    }

    private func latestValue(
        for series: ReferenceWearSeriesSelection,
        in displayableObservations: [ReferenceWearPoint]
    ) -> String {
        guard let point = displayableObservations.last,
              let value = point.displayValue(for: series, mode: valueMode) else { return "—" }
        if valueMode == .percentage {
            return String(format: "%.2f%%", value)
        }
        return String(format: "%.0f P/E", value)
    }
}

private struct ReferenceWearChart: View {
    let observations: [ReferenceWearPoint]
    let seriesSelection: ReferenceWearSeriesSelection
    let valueMode: ReferenceWearValueMode
    let visibleBoundaryRecords: [InstrumentBoundaryRecord]
    let granularity: HistoryPeriod
    let chartDates: [Date]

    var body: some View {
        if valueMode == .pe && seriesSelection == .both {
            VStack(spacing: 0) {
                chart(for: .tlc, showXAxis: false)
                chart(for: .pslc, showXAxis: true)
            }
        } else {
            chart(for: seriesSelection, showXAxis: true)
        }
    }

    @ViewBuilder
    private func chart(for selection: ReferenceWearSeriesSelection, showXAxis: Bool) -> some View {
        if showXAxis {
            baseChart(for: selection)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(AppColor.border.opacity(0.4))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                localizedText(ReferenceChartAxis.label(date, period: granularity, dates: chartDates))
                                    .font(ReferenceDashboardLayout.trendLabelFont)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                            }
                        }
                    }
                }
        } else {
            baseChart(for: selection)
                .chartXAxis(.hidden)
        }
    }

    private func baseChart(for selection: ReferenceWearSeriesSelection) -> some View {
        Chart {
            marks(for: selection)
        }
        .chartYScale(domain: yDomain(for: selection))
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel().font(ReferenceDashboardLayout.trendLabelFont)
            }
        }
        .chartYAxisLabel(valueMode == .percentage ? "%" : "P/E")
    }

    @ChartContentBuilder
    private func marks(for selection: ReferenceWearSeriesSelection) -> some ChartContent {
        ForEach(observations) { observation in
            if (selection == .tlc || selection == .both),
               let value = observation.displayValue(for: .tlc, mode: valueMode) {
                LineMark(
                    x: .value("時刻", observation.bucket),
                    y: .value("TLC", value),
                    series: .value("系列", "TLC-\(observation.seriesID)")
                )
                    .foregroundStyle(AppColor.tlc)
                PointMark(x: .value("時刻", observation.bucket), y: .value("TLC", value))
                    .foregroundStyle(AppColor.tlc)
            }
            if (selection == .pslc || selection == .both),
               let value = observation.displayValue(for: .pslc, mode: valueMode) {
                LineMark(
                    x: .value("時刻", observation.bucket),
                    y: .value("pSLC", value),
                    series: .value("系列", "pSLC-\(observation.seriesID)")
                )
                    .foregroundStyle(AppColor.pslc)
                PointMark(x: .value("時刻", observation.bucket), y: .value("pSLC", value))
                    .foregroundStyle(AppColor.pslc)
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

    private func yDomain(for selection: ReferenceWearSeriesSelection) -> ClosedRange<Double> {
        let values = observations.flatMap { point -> [Double] in
            var result: [Double] = []
            if selection == .tlc || selection == .both,
               let value = point.displayValue(for: .tlc, mode: valueMode) {
                result.append(value)
            }
            if selection == .pslc || selection == .both,
               let value = point.displayValue(for: .pslc, mode: valueMode) {
                result.append(value)
            }
            return result
        }
        return ReferenceWearScale.domain(
            values: values,
            minimumSpan: valueMode == .percentage ? 0.2 : 2.0
        )
    }
}

enum ReferenceWearScale {
    static func domain(values: [Double], minimumSpan: Double) -> ClosedRange<Double> {
        let finiteValues = values.filter { $0.isFinite && $0 >= 0 }
        guard let minimum = finiteValues.min(), let maximum = finiteValues.max() else { return 0...10 }
        let spanFloor = minimumSpan.isFinite && minimumSpan > 0 ? minimumSpan : 1
        let dataSpan = max(maximum - minimum, spanFloor)
        let padding = max(dataSpan * 0.18, spanFloor * 0.5)
        let lower = max(0, minimum - padding)
        let upper = max(maximum + padding, lower + spanFloor)
        return lower...upper
    }
}

private struct ReferenceWearPoint: Identifiable {
    let bucket: Date
    let tlcWear: Double
    let pslcWear: Double
    let tlcPE: Double?
    let pslcPE: Double?
    let tlcEOLPE: Double?
    let pslcEOLPE: Double?
    let seriesID: String

    init(
        bucket: Date,
        tlcWear: Double,
        pslcWear: Double,
        tlcPE: Double? = nil,
        pslcPE: Double? = nil,
        tlcEOLPE: Double? = nil,
        pslcEOLPE: Double? = nil,
        seriesID: String = "wear"
    ) {
        self.bucket = bucket
        self.tlcWear = tlcWear
        self.pslcWear = pslcWear
        self.tlcPE = tlcPE
        self.pslcPE = pslcPE
        self.tlcEOLPE = tlcEOLPE
        self.pslcEOLPE = pslcEOLPE
        self.seriesID = seriesID
    }

    var id: Date { bucket }

    func withBucket(_ bucket: Date) -> ReferenceWearPoint {
        ReferenceWearPoint(
            bucket: bucket,
            tlcWear: tlcWear,
            pslcWear: pslcWear,
            tlcPE: tlcPE,
            pslcPE: pslcPE,
            tlcEOLPE: tlcEOLPE,
            pslcEOLPE: pslcEOLPE,
            seriesID: seriesID
        )
    }

    func displayValue(for series: ReferenceWearSeriesSelection, mode: ReferenceWearValueMode) -> Double? {
        switch (series, mode) {
        case (.tlc, .percentage): return tlcWear.isFinite ? tlcWear * 100 : nil
        case (.pslc, .percentage): return pslcWear.isFinite ? pslcWear * 100 : nil
        case (.both, .percentage): return nil
        case (.tlc, .pe): return tlcPE?.isFinite == true ? tlcPE : nil
        case (.pslc, .pe): return pslcPE?.isFinite == true ? pslcPE : nil
        case (.both, .pe): return nil
        }
    }
}

private struct ReferenceTemperatureTrendCard: View {
    @ObservedObject var model: DashboardModel
    @Binding var range: ReferenceWriteRange
    @Binding var granularity: HistoryPeriod
    @State private var pointsMemo = ReferenceMemo<PointsKey, [ReferenceTemperaturePoint]>()

    /// What the bucketed series is computed from, in a form that is cheap to
    /// compare. New samples change the count or the latest time.
    private struct PointsKey: Equatable {
        let count: Int
        let first: Date?
        let latest: Date?
        let range: ReferenceWriteRange
        let granularity: HistoryPeriod
    }

    var body: some View {
        // Bucketing walks the whole temperature history, so do it only when
        // the samples or the chosen range change, not on every redraw.
        let source = model.temperaturePoints
        let points = pointsMemo.value(for: PointsKey(
            count: source.count, first: source.first?.date, latest: source.last?.date,
            range: range, granularity: granularity
        )) { filteredPoints }
        let chartDates = points.map(\.date)
        ReferenceCard(minHeight: ReferenceDashboardLayout.trendCardHeight, padding: ReferenceDashboardLayout.trendCardPadding) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    localizedText("温度")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    HStack(spacing: 4) {
                        ReferenceTrendGranularityPicker(selection: $granularity)
                        ReferenceTrendRangePicker(selection: $range)
                    }
                }
                if points.isEmpty {
                    ReferenceEmptyState(title: "温度履歴を収集中", message: "次回取得から推移を表示します。", systemImage: "thermometer.medium")
                        .frame(minHeight: 155, maxHeight: .infinity)
                } else {
                    let unit = TemperatureUnit.current
                    // A gap (sleep, app not running) starts a new section so
                    // the line does not imply measurements in between.
                    let runs = TemperatureLineRun.runs(sections: Self.gaplessSections(points))
                    Chart {
                        ForEach(runs) { run in
                            ForEach(run.points) { point in
                                LineMark(x: .value("時刻", point.date), y: .value("温度", unit.value(point.celsius)),
                                         series: .value("区間", run.id))
                                    .foregroundStyle(run.isWarm ? AppColor.temperatureWarm : AppColor.temperature)
                            }
                        }
                        ForEach(points) { point in
                            PointMark(x: .value("時刻", point.date), y: .value("温度", unit.value(point.celsius)))
                                .foregroundStyle(point.celsius > TemperatureLineRun.warmThreshold ? AppColor.temperatureWarm : AppColor.temperature)
                        }
                    }
                    .chartYScale(domain: Self.temperatureDomain(points, unit: unit))
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine()
                            AxisValueLabel().font(ReferenceDashboardLayout.trendLabelFont)
                        }
                    }
                    .chartYAxisLabel(unit.symbol)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(AppColor.border.opacity(0.4))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    localizedText(ReferenceChartAxis.label(date, period: granularity, dates: chartDates))
                                        .font(ReferenceDashboardLayout.trendLabelFont)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.9)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 155, maxHeight: .infinity)
                }
                HStack {
                    if granularity == .hour {
                        localizedText("直近72時間")
                    }
                    Text(verbatim: UIString.format("観測 %d点", points.count))
                    Spacer()
                    localizedText(Self.temperatureRange(points))
                }
                .font(ReferenceDashboardLayout.trendLabelFont)
                .foregroundStyle(AppColor.textSecondary)
            }
            .frame(height: ReferenceDashboardLayout.trendCardHeight - 2 * ReferenceDashboardLayout.trendCardPadding)
        }
    }

    private var filteredPoints: [ReferenceTemperaturePoint] {
        let cutoff = ReferenceChartWindow.cutoff(requested: range.cutoff, granularity: granularity)
        let source = model.temperaturePoints.filter { point in
            point.celsius.isFinite && (cutoff.map { point.date >= $0 } ?? true)
        }
        let averaged = ReferenceTemperatureBuckets.averages(source, granularity: granularity)
        let segments = ChartGapSegmenter.segments(dates: averaged.map(\.date), bucketSeconds: granularity.bucketSeconds)
        return zip(averaged, segments).map { ReferenceTemperaturePoint(date: $0.0.date, celsius: $0.0.celsius, segment: $0.1) }
    }

    private static func gaplessSections(_ points: [ReferenceTemperaturePoint]) -> [[TemperaturePoint]] {
        var sections: [[TemperaturePoint]] = []
        var currentSegment: Int?
        for point in points {
            let reading = TemperaturePoint(date: point.date, celsius: point.celsius)
            if point.segment == currentSegment {
                sections[sections.count - 1].append(reading)
            } else {
                sections.append([reading])
                currentSegment = point.segment
            }
        }
        return sections
    }

    /// Chosen in Celsius, then converted, so the axis covers the same
    /// temperatures in either unit.
    private static func temperatureDomain(_ points: [ReferenceTemperaturePoint], unit: TemperatureUnit) -> ClosedRange<Double> {
        let values = points.map(\.celsius)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 70
        return unit.value(max(0, minimum - 5))...unit.value(max(70, maximum + 5))
    }

    private static func temperatureRange(_ points: [ReferenceTemperaturePoint]) -> String {
        guard let minValue = points.map(\.celsius).min(), let maxValue = points.map(\.celsius).max() else { return "範囲 未取得" }
        // The chart plots bucket averages, so its range is narrower than the
        // measured range on the top card.
        let unit = TemperatureUnit.current
        return UIString.format("区間平均 %.0f–%.0f %@", unit.value(minValue), unit.value(maxValue), unit.symbol)
    }
}

private struct ReferenceTemperaturePoint: Identifiable {
    let date: Date
    let celsius: Double
    var segment = 0

    var id: Date { date }
}

private struct ReferenceReliabilityCard: View {
    @ObservedObject var model: DashboardModel
    let onOpen: () -> Void

    var body: some View {
        ReferenceCard {
            VStack(alignment: .leading, spacing: 9) {
                localizedText("最近の内部エラー")
                    .font(.headline.weight(.semibold))
                if events.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(AppColor.positive)
                        VStack(alignment: .leading, spacing: 3) {
                            localizedText("新しい異常イベントはありません")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(AppColor.positive)
                            localizedText("取得範囲で増加したイベント: なし")
                                .font(.caption)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                    }
                } else {
                    ForEach(events.prefix(3)) { event in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppColor.amber)
                            localizedText(event.type.title)
                            Spacer()
                            localizedText("+\(event.delta)").monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                Button(UIString.text("イベント履歴を表示…"), action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(minHeight: 155)
    }

    private var events: [FTLTimeSeriesReliabilityEvent] {
        model.analytics.ftlTimeSeries.reliabilityEvents.sorted { $0.intervalEnd > $1.intervalEnd }
    }
}

private struct ReferenceTrendRangePicker: View {
    @Binding var selection: ReferenceWriteRange

    var body: some View {
        Picker(ReferenceDashboardLabels.rangeLabel, selection: $selection) {
            ForEach(ReferenceWriteRange.allCases) { item in
                localizedText(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 270)
        .controlSize(.small)
        .labelsHidden()
        .help(UIString.text("\(ReferenceDashboardLabels.rangeLabel): \(selection.accessibilityTitle)"))
    }
}

private struct ReferenceTrendGranularityPicker: View {
    @Binding var selection: HistoryPeriod

    var body: some View {
        Picker(ReferenceDashboardLabels.granularityLabel, selection: $selection) {
            localizedText(ReferenceDashboardLabels.granularity(.hour)).tag(HistoryPeriod.hour)
            localizedText(ReferenceDashboardLabels.granularity(.day)).tag(HistoryPeriod.day)
            localizedText(ReferenceDashboardLabels.granularity(.week)).tag(HistoryPeriod.week)
        }
        .pickerStyle(.segmented)
        .frame(width: 185)
        .controlSize(.small)
        .labelsHidden()
        .help(UIString.text("\(ReferenceDashboardLabels.granularityLabel): \(ReferenceDashboardLabels.granularity(selection, compact: false))"))
    }
}

private struct ReferenceLegend: View {
    let color: Color
    let title: String
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 18, height: 4)
            localizedText(title)
        }
        .font(font)
        .foregroundStyle(AppColor.textSecondary)
    }
}

private struct MiniTemperatureChart: View {
    let points: [TemperaturePoint]

    var body: some View {
        // A 30-day history holds about 10,000 readings; a sparkline needs few.
        Chart(TemperatureLineRun.runs(sections: [TemperaturePoint.downsampled(points, maximumCount: 120)])) { run in
            ForEach(run.points) { point in
                LineMark(x: .value("時刻", point.date), y: .value("温度", point.celsius), series: .value("区間", run.id))
                    .foregroundStyle(run.isWarm ? AppColor.temperatureWarm : AppColor.temperature)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }
}

struct ReferenceHealthIndicatorsView: View {
    @ObservedObject var model: DashboardModel
    @State private var temperatureRange: ReferenceWriteRange = .all
    @State private var temperatureGranularity: HistoryPeriod = .day

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReferencePageHeading(title: "健康指標", subtitle: "SMART・温度・容量を観測値として確認します。")
            ReferenceWearRow(model: model)
            HStack(alignment: .top, spacing: 16) {
                ReferenceSmartDetailsCard(model: model)
                ReferenceStorageDetailsCard(model: model)
            }
            ReferenceTemperatureTrendCard(model: model, range: $temperatureRange, granularity: $temperatureGranularity)
        }
    }
}

private struct ReferenceSmartDetailsCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ReferenceCard {
            VStack(alignment: .leading, spacing: 10) {
                localizedText("SMART")
                    .font(.headline.weight(.semibold))
                ReferenceKeyValueRow(title: "使用率（Percentage Used）", value: ValueFormatter.percentage(model.snapshot?.percentageUsed))
                ReferenceKeyValueRow(title: "予備領域（Available Spare）", value: ValueFormatter.percentage(model.snapshot?.availableSpare))
                ReferenceKeyValueRow(title: "重大な警告（Critical Warning）", value: model.snapshot?.criticalWarning.map { String(format: "0x%02x", $0) } ?? "未取得")
                ReferenceKeyValueRow(title: "データ整合性エラー", value: ValueFormatter.integer(model.snapshot?.mediaAndDataIntegrityErrors))
                ReferenceKeyValueRow(title: "電源投入回数", value: ValueFormatter.integer(model.snapshot?.powerCycleCount))
                ReferenceKeyValueRow(title: "異常終了（Unsafe Shutdowns）", value: ValueFormatter.integer(model.snapshot?.unsafeShutdowns))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ReferenceStorageDetailsCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ReferenceCard {
            VStack(alignment: .leading, spacing: 10) {
                localizedText("空き容量")
                    .font(.headline.weight(.semibold))
                if let capacity = model.capacityProfile, capacity.hasDisplayableValues {
                    ReferenceKeyValueRow(
                        title: "論理容量",
                        value: capacity.logicalCapacityBytes.map(ValueFormatter.decimalCapacity) ?? "未取得"
                    )
                    ReferenceKeyValueRow(title: "空き（ファイルシステム）", value: capacity.displayedFreeBytes.map(ValueFormatter.decimalCapacity) ?? "未取得")
                    if let purgeable = capacity.purgeableBytes {
                        ReferenceKeyValueRow(title: "うちパージ可能", value: ValueFormatter.decimalCapacity(purgeable))
                    }
                    ReferenceKeyValueRow(title: "NANDに占める論理容量", value: logicalShareText(capacity))
                    ReferenceKeyValueRow(title: "ジオメトリ", value: capacity.geometryConfidence.title)
                } else {
                    ReferenceEmptyState(title: "容量情報を取得していません", message: "SMARTまたはioregの次回取得で更新されます。", systemImage: "internaldrive")
                }
                ReferenceKeyValueRow(title: "読込量（Data Units Read）", value: ValueFormatter.dataUnits(model.snapshot?.dataUnitsRead, bytes: model.snapshot?.dataUnitsReadBytes))
                ReferenceKeyValueRow(title: "書込量（Data Units Written）", value: ValueFormatter.dataUnits(model.snapshot?.dataUnitsWritten, bytes: model.snapshot?.dataUnitsWrittenBytes))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func logicalShareText(_ capacity: SSDCapacityProfile) -> String {
        guard let logical = capacity.logicalCapacityBytes,
              let geometry = capacity.geometryCapacityBytes,
              geometry > 0 else { return "未取得" }
        let ratio = Double(logical) / Double(geometry)
        guard ratio.isFinite else { return "未取得" }
        let margin = capacity.hiddenPhysicalMarginBytes.map(ValueFormatter.decimalCapacity) ?? "未取得"
        return "\(ValueFormatter.ratioPercent(min(1, max(0, ratio)))) · 構成値 · margin ≈ \(margin)"
    }
}

struct ReferenceReliabilityView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReferencePageHeading(title: "内部エラーと保持処理", subtitle: "Direct FTLの比較可能な増加を、寿命倍率とは分けて表示します。")
            ReferenceReliabilityCard(model: model, onOpen: {})
            ReferenceRecoveryPaceCard(model: model)
            ReferenceCard {
                VStack(alignment: .leading, spacing: 9) {
                    localizedText("イベントの記録")
                        .font(.headline.weight(.semibold))
                    if events.isEmpty {
                        ReferenceEmptyState(title: "新規イベントなし", message: "取得範囲で比較可能な増加はありません。", systemImage: "checkmark.circle")
                    } else {
                        ForEach(events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(AppColor.amber)
                                VStack(alignment: .leading, spacing: 2) {
                                    localizedText(event.type.title)
                                        .font(.callout.weight(.medium))
                                    localizedText("\(UIString.dateTime(event.intervalStart)) – \(UIString.dateTime(event.intervalEnd))")
                                        .font(.caption)
                                        .foregroundStyle(AppColor.textSecondary)
                                }
                                Spacer()
                                localizedText("+\(event.delta)")
                                    .font(.body.monospacedDigit())
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
        }
    }

    private var events: [FTLTimeSeriesReliabilityEvent] {
        model.analytics.ftlTimeSeries.reliabilityEvents.sorted { $0.intervalEnd > $1.intervalEnd }
    }
}

private struct ReferencePageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            localizedText(title)
                .font(.title2.weight(.bold))
            localizedText(subtitle)
                .font(.callout)
                .foregroundStyle(AppColor.textSecondary)
        }
    }
}

private struct ReferenceCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    private let minHeight: CGFloat?
    private let contentPadding: CGFloat

    init(
        minHeight: CGFloat? = nil,
        padding: CGFloat = 16,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.minHeight = minHeight
        self.contentPadding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(contentPadding)
            .frame(minHeight: minHeight, alignment: .top)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            }
    }
}

private struct ReferenceEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                localizedText(title)
                    .font(.callout.weight(.medium))
                localizedText(message)
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(AppColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private extension Array where Element == Double {
    var nilIfEmpty: [Double]? { isEmpty ? nil : self }
}

/// Splits chart points into runs so a line is not drawn across a gap.
enum ChartGapSegmenter {
    /// A gap longer than this many buckets starts a new segment.
    static let gapFactor = 1.5

    static func segments(dates: [Date], bucketSeconds: TimeInterval) -> [Int] {
        var segment = 0
        var result: [Int] = []
        for (index, date) in dates.enumerated() {
            if index > 0, date.timeIntervalSince(dates[index - 1]) > bucketSeconds * gapFactor {
                segment += 1
            }
            result.append(segment)
        }
        return result
    }
}

extension HistoryPeriod {
    var bucketSeconds: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 31 * 86_400
        }
    }
}
