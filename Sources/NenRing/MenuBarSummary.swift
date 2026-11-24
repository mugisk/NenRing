import Foundation

/// Host writes since local midnight, from the SMART history of one device.
/// The baseline is the last reading before midnight when it is recent enough;
/// otherwise the first reading of the day (so the value can only undercount).
enum TodayHostWrites {
    /// A reading older than this before midnight is not used as the baseline.
    static let maximumBaselineAge: TimeInterval = 36 * 3_600

    static func bytes(
        history: [DriveSnapshot],
        latest: DriveSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Double? {
        guard let latest, let latestBytes = latest.dataUnitsWrittenBytes else { return nil }
        let midnight = calendar.startOfDay(for: now)
        // The menu bar label calls this on every redraw, so only the recent
        // end of the history is visited, in one pass without sorting.
        let recent = HistoryAnalyzer.recentSuffix(of: history, since: midnight.addingTimeInterval(-maximumBaselineAge),
                                                  capturedAt: \.capturedAt)
        var beforeMidnight: DriveSnapshot?
        var firstOfDay: DriveSnapshot?
        for snapshot in recent where snapshot.deviceID == latest.deviceID && snapshot.dataUnitsWrittenBytes != nil {
            if snapshot.capturedAt < midnight {
                guard midnight.timeIntervalSince(snapshot.capturedAt) <= maximumBaselineAge else { continue }
                if beforeMidnight.map({ snapshot.capturedAt >= $0.capturedAt }) ?? true {
                    beforeMidnight = snapshot
                }
            } else if firstOfDay.map({ snapshot.capturedAt < $0.capturedAt }) ?? true {
                firstOfDay = snapshot
            }
        }
        let baseline = beforeMidnight ?? firstOfDay
        guard let baselineBytes = baseline?.dataUnitsWrittenBytes, latest.capturedAt >= midnight else {
            return nil
        }
        let delta = latestBytes - baselineBytes
        return delta.isFinite && delta >= 0 ? delta : nil
    }
}

/// The short text next to the menu bar icon. The menu bar shows one image
/// and one line of text, so every selected value goes into a single string.
struct MenuBarLabelText: Equatable, Sendable {
    struct Options: Equatable, Sendable {
        var temperature = false
        var wear = false
        var remainingYears = false
        var todayWrites = false
    }

    static func make(
        options: Options,
        temperatureCelsius: Int?,
        wearFraction: Double?,
        remainingYears: Double?,
        todayWrittenBytes: Double?,
        temperatureUnit: TemperatureUnit = .current
    ) -> String {
        var parts: [String] = []
        if options.temperature {
            parts.append(temperatureCelsius.map { "\(temperatureUnit.wholeNumber(Double($0)))°" } ?? "—")
        }
        // The `wear` option keeps its stored key; the label shows the share
        // left, as the popup and dashboard do.
        if options.wear {
            parts.append(wearFraction.map { String(format: "%.1f%%", max(0, 1 - $0) * 100) } ?? "—")
        }
        if options.remainingYears {
            parts.append(remainingYears.map(yearsText) ?? "—")
        }
        if options.todayWrites {
            parts.append(todayWrittenBytes.map { ValueFormatter.bytes($0) } ?? "—")
        }
        return parts.joined(separator: " · ")
    }

    /// Short form for the menu bar: years, months below one year, and a
    /// mark at zero. The label is drawn verbatim, so it is translated here.
    static func yearsText(_ years: Double) -> String {
        guard years.isFinite, years >= 0 else { return "—" }
        if years == 0 { return UIString.text("到達") }
        if years < 1 { return UIString.format("%dか月", max(1, Int((years * 12).rounded()))) }
        return UIString.format("%.0f年", years)
    }
}

/// Lifespan values shared by the dashboard headline and the menu bar, so both
/// always show the same wear and remaining time.
@MainActor
extension DashboardModel {
    /// Matches the actual-use row of the forecast card.
    var headlineWearFraction: Double? {
        let nand = analytics.nandEndurance
        if let fraction = nand.realHostWearFraction {
            return fraction
        }
        if let fraction = DashboardHeadline.nandWearFraction(
            rows: nand.domainForecastRows, estimates: nand.domainBaselineEstimates
        ) {
            return fraction
        }
        // Not `.map(Double.init)`: on UInt64 that resolves to Double(bitPattern:).
        return snapshot?.percentageUsed.map { Double($0) / 100 }
    }

    /// Remaining host writes as of now: the FTL projection less the writes
    /// SMART has recorded since its input, else the SMART-based forecast.
    var headlineRemainingHostBytes: Double? {
        analytics.nandEndurance.remainingNow(analytics.nandEndurance.projection(.real)?.remaining, workload: .real)
            ?? enduranceForecast.remainingHostWriteBytes
    }

    /// The upper end of a reference TBW range, as remaining host writes.
    func headlineRemainingHostBytesUpper(evidence: ForecastEvidence) -> Double? {
        guard case .referenceTBW = evidence,
              let upper = enduranceForecast.enduranceRangeUpperBytes,
              let current = enduranceForecast.currentHostWrittenBytes else { return nil }
        return max(0, upper - current)
    }

    var headlinePaceBytesPerDay: Double? {
        analytics.writeRateSummary.forecastPaceBytesPerDay
    }

    var headlineRemainingYears: Double? {
        guard let remaining = headlineRemainingHostBytes, let pace = headlinePaceBytesPerDay,
              remaining.isFinite, pace.isFinite, pace > 0 else { return nil }
        let years = remaining / pace / 365.25
        return years.isFinite && years >= 0 ? years : nil
    }

    var headline: DashboardHeadline {
        let nand = analytics.nandEndurance
        let evidence = ForecastEvidence.resolve(ftlTotal: nand.projection(.real)?.total, smart: enduranceForecast)
        return DashboardHeadline.make(
            snapshot: snapshot,
            nandWearFraction: DashboardHeadline.nandWearFraction(
                rows: nand.domainForecastRows, estimates: nand.domainBaselineEstimates
            ),
            hostWearFraction: nand.realHostWearFraction,
            remainingHostBytes: headlineRemainingHostBytes,
            remainingHostBytesUpper: headlineRemainingHostBytesUpper(evidence: evidence),
            paceBytesPerDay: headlinePaceBytesPerDay,
            provisional: evidence.isSmartProvisional || writeRateSummary.recordedHistoryIsProvisional,
            usesUsageStartPace: writeRateSummary.usesUsageStartPace
        )
    }

    var todayHostWrittenBytes: Double? {
        TodayHostWrites.bytes(history: history, latest: snapshot)
    }
}
