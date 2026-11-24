import Foundation

/// Whether the drive's recovery activity (refresh, age padding, reduced read
/// verify) has recently become more frequent than its own longer history.
///
/// The counters are research keys whose meaning is not confirmed. A higher
/// pace is a change worth watching, not evidence of weaker retention, and it
/// never feeds the forecast. Only stored snapshots are read; nothing is
/// collected for this.
enum RecoveryActivityPaceMetric: String, CaseIterable, Sendable, Identifiable {
    case backgroundRefresh
    case ageRefresh
    case bandsPaddedForAge
    case reducedReadVerify

    var id: String { rawValue }

    /// The raw counter name, as `ReliabilityMetricLabel` knows it.
    var counterName: String {
        switch self {
        case .backgroundRefresh: return "Background refresh moves"
        case .ageRefresh: return "Age refresh"
        case .bandsPaddedForAge: return "Bands padded for age"
        case .reducedReadVerify: return "Reduced read verify native"
        }
    }

    /// Refresh follows how long data has been stored, which only advances
    /// while the drive is powered; read verify follows how much is read.
    var basis: RecoveryActivityPaceBasis {
        self == .reducedReadVerify ? .nandReads : .operatingHours
    }

    func value(_ telemetry: FTLResearchTelemetrySnapshot) -> UInt64? {
        switch self {
        case .backgroundRefresh: return telemetry.backgroundRefreshMoves
        case .ageRefresh: return telemetry.ageRefreshTotal
        case .bandsPaddedForAge: return telemetry.bandsPaddedForAge
        case .reducedReadVerify: return telemetry.reducedReadVerifyNative
        }
    }
}

enum RecoveryActivityPaceBasis: Equatable, Sendable {
    case operatingHours
    case nandReads

    /// Exposure is kept in hours or reads; rates are shown per operating day
    /// or per million NAND reads.
    var rateScale: Double {
        switch self {
        case .operatingHours: return 24
        case .nandReads: return 1_000_000
        }
    }

    var unit: String {
        switch self {
        case .operatingHours: return "/稼働日"
        case .nandReads: return "/100万読出し"
        }
    }
}

enum RecoveryActivityPaceState: String, Equatable, Sendable {
    case insufficientHistory
    case steady
    case elevated

    var title: String {
        switch self {
        case .insufficientHistory: return "比較できる履歴が不足"
        case .steady: return "長期の基準と同程度"
        case .elevated: return "最近のペースが上昇"
        }
    }
}

struct RecoveryActivityPaceRow: Equatable, Sendable, Identifiable {
    let metric: RecoveryActivityPaceMetric
    let recentCount: UInt64
    let recentExposure: Double
    let baselineCount: UInt64
    let baselineExposure: Double
    /// The busiest 7-day block of the baseline, per `basis.rateScale`.
    var baselineWeeklyMaximumRate: Double? = nil
    let state: RecoveryActivityPaceState

    var id: String { metric.rawValue }

    var recentRate: Double? {
        recentExposure > 0 ? Double(recentCount) / recentExposure * metric.basis.rateScale : nil
    }

    var baselineRate: Double? {
        baselineExposure > 0 ? Double(baselineCount) / baselineExposure * metric.basis.rateScale : nil
    }

    /// Nil when the baseline saw none, so "new" is not shown as a ratio.
    var ratio: Double? {
        guard let recentRate, let baselineRate, baselineRate > 0 else { return nil }
        return recentRate / baselineRate
    }
}

struct RecoveryActivityPace: Equatable, Sendable {
    static let empty = RecoveryActivityPace(
        state: .insufficientHistory, recentStart: nil, recentEnd: nil, baselineStart: nil,
        recentOperatingHours: 0, baselineOperatingHours: 0, rows: [])

    let state: RecoveryActivityPaceState
    let recentStart: Date?
    let recentEnd: Date?
    let baselineStart: Date?
    let recentOperatingHours: Double
    let baselineOperatingHours: Double
    let rows: [RecoveryActivityPaceRow]

    var elevatedRows: [RecoveryActivityPaceRow] { rows.filter { $0.state == .elevated } }
}

struct RecoveryActivityPaceAnalyzer: Sendable {
    /// Refresh runs as one job every few days, so a 7-day window holds only
    /// two or three and one large job reads as a jump; 14 days holds more.
    var recentDays: Double = 14
    var baselineDays: Double = 56
    /// Below these, a week of light use or a short history would make the
    /// comparison mostly noise.
    var minimumRecentOperatingHours: Double = 12
    var minimumBaselineOperatingHours: Double = 48
    /// Refresh comes in bursts several days apart, so a plain count test
    /// fires on ordinary weeks. A metric is elevated only when the recent
    /// rate is at least `elevationFactor` times the baseline average, above
    /// `weeklyMaximumFactor` times the busiest baseline week, and clear of
    /// Poisson noise; the baseline needs `minimumBaselineWeeks` usable weeks.
    var elevationFactor: Double = 2
    var weeklyMaximumFactor: Double = 2
    var noiseSigmas: Double = 3
    var minimumBaselineWeeks = 4

    func assess(snapshots: [ASPToolDiagnosticsSnapshot], excluding excluded: [DateInterval] = []) -> RecoveryActivityPace {
        let ordered = snapshots
            .filter { $0.sourceArtifact == .directFTL && $0.researchTelemetry != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let latest = ordered.last else { return .empty }
        let recentStart = latest.capturedAt.addingTimeInterval(-recentDays * 86_400)
        let baselineStart = recentStart.addingTimeInterval(-baselineDays * 86_400)
        let metrics = RecoveryActivityPaceMetric.allCases

        struct Window {
            var hours: Double = 0
            var counts: [RecoveryActivityPaceMetric: UInt64] = [:]
            var exposure: [RecoveryActivityPaceMetric: Double] = [:]
        }
        var recent = Window()
        var baseline = Window()
        var weeks: [Int: Window] = [:]
        var earliestBaseline: Date?

        // Consecutive comparable pairs only: a decrease, a series change or a
        // research session drops that pair instead of inventing a delta. A
        // pair crossing the window edge is left out of both windows.
        for (before, after) in zip(ordered, ordered.dropFirst()) {
            guard before.capturedAt >= baselineStart,
                  after.capturedAt > before.capturedAt,
                  DirectFTLResearchContract.reliabilityPairIsComparable(before, after),
                  let start = before.researchTelemetry, let end = after.researchTelemetry,
                  let hours = difference(before.powerOnHours, after.powerOnHours),
                  !excluded.contains(where: { $0.start < after.capturedAt && before.capturedAt < $0.end })
            else { continue }
            let isRecent: Bool
            if before.capturedAt >= recentStart {
                isRecent = true
            } else if after.capturedAt <= recentStart {
                isRecent = false
            } else {
                continue
            }
            let reads = difference(start.nandReads, end.nandReads)
            var window = isRecent ? recent : baseline
            window.hours += Double(hours)
            for metric in metrics {
                guard let delta = difference(metric.value(start), metric.value(end)) else { continue }
                let exposure: Double
                switch metric.basis {
                case .operatingHours: exposure = Double(hours)
                case .nandReads:
                    guard let reads else { continue }
                    exposure = Double(reads)
                }
                window.counts[metric, default: 0] += delta
                window.exposure[metric, default: 0] += exposure
            }
            if isRecent { recent = window } else {
                baseline = window
                earliestBaseline = min(earliestBaseline ?? before.capturedAt, before.capturedAt)
                let week = Int(recentStart.timeIntervalSince(after.capturedAt) / (7 * 86_400))
                var block = weeks[week] ?? Window()
                block.hours += Double(hours)
                for metric in metrics {
                    guard let delta = difference(metric.value(start), metric.value(end)) else { continue }
                    switch metric.basis {
                    case .operatingHours:
                        block.exposure[metric, default: 0] += Double(hours)
                    case .nandReads:
                        guard let reads else { continue }
                        block.exposure[metric, default: 0] += Double(reads)
                    }
                    block.counts[metric, default: 0] += delta
                }
                weeks[week] = block
            }
        }

        let enoughTime = recent.hours >= minimumRecentOperatingHours
            && baseline.hours >= minimumBaselineOperatingHours
        let rows = metrics.compactMap { metric -> RecoveryActivityPaceRow? in
            guard let recentExposure = recent.exposure[metric],
                  let baselineExposure = baseline.exposure[metric] else { return nil }
            let recentCount = recent.counts[metric] ?? 0
            let baselineCount = baseline.counts[metric] ?? 0
            // Weeks with too little use say little about their rate.
            let weeklyRates = weeks.values.compactMap { block -> Double? in
                guard block.hours >= minimumRecentOperatingHours,
                      let exposure = block.exposure[metric], exposure > 0 else { return nil }
                return Double(block.counts[metric] ?? 0) / exposure
            }
            let weeklyMaximum = weeklyRates.max()
            let state: RecoveryActivityPaceState
            if !enoughTime || recentExposure <= 0 || baselineExposure <= 0 || weeklyRates.count < minimumBaselineWeeks {
                state = .insufficientHistory
            } else {
                let expected = Double(baselineCount) / baselineExposure * recentExposure
                let observed = Double(recentCount)
                let recentRate = observed / recentExposure
                let elevated = observed >= elevationFactor * expected
                    && recentRate > weeklyMaximumFactor * (weeklyMaximum ?? 0)
                    && observed - expected >= noiseSigmas * max(expected, 1).squareRoot()
                state = elevated ? .elevated : .steady
            }
            return RecoveryActivityPaceRow(
                metric: metric, recentCount: recentCount, recentExposure: recentExposure,
                baselineCount: baselineCount, baselineExposure: baselineExposure,
                baselineWeeklyMaximumRate: weeklyMaximum.map { $0 * metric.basis.rateScale },
                state: state)
        }
        let state: RecoveryActivityPaceState
        if rows.contains(where: { $0.state == .elevated }) {
            state = .elevated
        } else if rows.contains(where: { $0.state == .steady }) {
            state = .steady
        } else {
            state = .insufficientHistory
        }
        return RecoveryActivityPace(
            state: state, recentStart: recentStart, recentEnd: latest.capturedAt,
            baselineStart: earliestBaseline, recentOperatingHours: recent.hours,
            baselineOperatingHours: baseline.hours, rows: rows)
    }

    private func difference(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after, after >= before else { return nil }
        return after - before
    }
}

// MARK: - Light check

/// How often the light check runs and may notify. It only compares results
/// the app already has; it never starts a collection of its own.
enum ReliabilityCheckSchedule: String, CaseIterable, Identifiable, Sendable {
    case everyCollection
    case daily
    case weekly
    case off

    static let defaultSchedule: Self = .off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyCollection: return "毎回の取得時"
        case .daily: return "毎日"
        case .weekly: return "毎週"
        case .off: return "オフ"
        }
    }

    /// Nil means every new Direct FTL reading, or never for `.off`.
    var interval: TimeInterval? {
        switch self {
        case .daily: return 86_400
        case .weekly: return 7 * 86_400
        case .everyCollection, .off: return nil
        }
    }
}

struct ReliabilityCheckFinding: Codable, Equatable, Sendable, Identifiable {
    /// Stable across checks, so a finding is notified once, not each time.
    let key: String
    let message: String

    var id: String { key }
}

/// What one check saw. The counters are kept so the next check can report
/// what changed since this one, even when several readings came in between.
struct ReliabilityCheckRecord: Codable, Equatable, Sendable {
    let checkedAt: Date
    let latestFTLCapturedAt: Date?
    let deviceID: String?
    let mediaErrors: UInt64?
    let errorLogEntries: UInt64?
    let reliabilityEventCount: Int
    let latestReliabilityEventEnd: Date?
    let findings: [ReliabilityCheckFinding]

    var hasFindings: Bool { !findings.isEmpty }
}

enum ReliabilityCheck {
    static func isDue(
        schedule: ReliabilityCheckSchedule,
        previous: ReliabilityCheckRecord?,
        latestFTLCapturedAt: Date?,
        now: Date
    ) -> Bool {
        guard schedule != .off else { return false }
        guard let previous else { return true }
        if let interval = schedule.interval {
            return now.timeIntervalSince(previous.checkedAt) >= interval
        }
        guard let latestFTLCapturedAt else { return false }
        return previous.latestFTLCapturedAt.map { latestFTLCapturedAt > $0 } ?? true
    }

    static func run(
        smart: DriveSnapshot?,
        events: [FTLTimeSeriesReliabilityEvent],
        pace: RecoveryActivityPace,
        latestFTLCapturedAt: Date?,
        previous: ReliabilityCheckRecord?,
        now: Date
    ) -> ReliabilityCheckRecord {
        let deviceID = smart?.deviceID
        // A different drive starts over rather than comparing counters.
        let baseline = previous?.deviceID == deviceID ? previous : nil
        var findings: [ReliabilityCheckFinding] = []

        if let warning = smart?.criticalWarning, warning != 0 {
            findings.append(.init(key: "smart.criticalWarning.\(warning)",
                message: UIString.format("SMARTの重大な警告：0x%02x", Int(warning))))
        }
        if let current = smart?.mediaAndDataIntegrityErrors,
           let before = baseline?.mediaErrors, current > before {
            findings.append(.init(key: "smart.mediaErrors.\(current)",
                message: UIString.format("データ整合性エラー：前回のチェックから +%llu", current - before)))
        }
        if let current = smart?.additionalSMART?.errorLogEntries,
           let before = baseline?.errorLogEntries, current > before {
            findings.append(.init(key: "smart.errorLog.\(current)",
                message: UIString.format("SMARTエラーログ：前回のチェックから +%llu", current - before)))
        }
        // Events recorded before the first check are history the dashboard
        // already shows; only events after the previous check are new.
        if let since = baseline?.checkedAt {
            let cutoff = baseline?.latestReliabilityEventEnd ?? since
            let fresh = events.filter { $0.intervalEnd > cutoff }
            if let last = fresh.max(by: { $0.intervalEnd < $1.intervalEnd }) {
                let total = fresh.reduce(UInt64(0)) { $0 + $1.delta }
                findings.append(.init(key: "ftl.event.\(last.id)",
                    message: UIString.format("内部エラー：%@ ほか 計 +%llu",
                        ReliabilityMetricLabel.text(last.type.title), total)))
            }
        }
        for row in pace.elevatedRows {
            let ratio = row.ratio.map { String(format: "%.1f", $0) }
            findings.append(.init(key: "pace.\(row.metric.rawValue)",
                message: ratio.map {
                    UIString.format("保持処理のペース上昇：%@ が長期の基準の %@倍", ReliabilityMetricLabel.text(row.metric.counterName), $0)
                } ?? UIString.format("保持処理のペース上昇：%@ が最近増加", ReliabilityMetricLabel.text(row.metric.counterName))))
        }

        let latestEvent = events.max { $0.intervalEnd < $1.intervalEnd }
        return ReliabilityCheckRecord(
            checkedAt: now,
            latestFTLCapturedAt: latestFTLCapturedAt,
            deviceID: deviceID,
            mediaErrors: smart?.mediaAndDataIntegrityErrors ?? baseline?.mediaErrors,
            errorLogEntries: smart?.additionalSMART?.errorLogEntries ?? baseline?.errorLogEntries,
            reliabilityEventCount: events.count,
            latestReliabilityEventEnd: latestEvent?.intervalEnd ?? baseline?.latestReliabilityEventEnd,
            findings: findings)
    }

    /// Findings the previous check had not already reported.
    static func newFindings(_ record: ReliabilityCheckRecord, previous: ReliabilityCheckRecord?) -> [ReliabilityCheckFinding] {
        let known = Set(previous?.findings.map(\.key) ?? [])
        return record.findings.filter { !known.contains($0.key) }
    }
}
