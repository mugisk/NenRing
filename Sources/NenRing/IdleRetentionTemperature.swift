import Foundation

/// Selection rules, not a measurement of powered-off retention capability.
struct IdleTemperatureCandidate: Codable, Equatable, Sendable {
    let deviceID: String
    let firmware: String?
    let start: Date
    let end: Date
    let temperature: Double
    let sampleCount: Int
    let hostBytes: Double
    let stable: Bool
    let smartIntervalSeconds: Double?
    var ruleVersion: Int = 1
    /// Optional for v1 archives. Relative-low-I/O observations are not idle.
    var relativeLowIO: Bool?
    var ioThresholdBytesPerSecond: Double?
    /// Trapezoidal time average over the same samples used for the median.
    /// Optional because older evidence retained only the median.
    var timeWeightedTemperature: Double?
    var temperatureObservedSeconds: Double?
    var ioSource: IdleTemperatureIOSource?
    var maximumIOIntervalSeconds: Double?
    var uptimeContinuityVerified: Bool?

    var effectiveIOSource: IdleTemperatureIOSource { ioSource ?? .smart }
    var effectiveMaximumIOIntervalSeconds: Double? { maximumIOIntervalSeconds ?? smartIntervalSeconds }
}

enum ObservationConfidence: Int, Codable, Equatable, Sendable {
    case low, medium, high
    var title: String {
        switch self { case .low: return "低"; case .medium: return "中"; case .high: return "高" }
    }
}

struct IdleRetentionTemperature: Equatable, Sendable {
    enum Source: String, Sendable { case manual, idle, previous, fallback }
    let temperature: Double
    let source: Source
    let candidates: [IdleTemperatureCandidate]
    let confidence: ObservationConfidence
    let observedDays: Int
    let observedSeconds: Double
    let lastObservedAt: Date?
    let temperatureRange: ClosedRange<Double>?
    let historyDays: Int
    let historySampleCount: Int
    let historySpanDays: Double
    let relativeLowIO: Bool
    let ioThresholdBytesPerSecond: Double
    var observedMedianTemperature: Double?
    var stableMedianTemperature: Double?
    var timeWeightedTemperature: Double?
    var meanObservedSeconds: Double = 0
    var meanCandidateCount: Int = 0
    var selectedCandidateCount: Int = 0
    /// The observations predate a firmware lineage change.
    var fromEarlierFirmware = false
    var blockIOSelectionThreshold: Double?
    var smartSelectionThreshold: Double?
    /// A manual temperature is a chosen condition, not an observation, so
    /// thin observation evidence does not make it provisional.
    var provisional: Bool { source != .manual && (source == .fallback || confidence == .low) }
    var sourceTitle: String {
        switch source {
        case .manual: return "指定温度"
        case .idle: return relativeLowIO ? "低負荷実測" : "アイドル実測"
        case .previous: return fromEarlierFirmware ? "更新前FWの観測" : "過去の観測"
        case .fallback: return "既定温度"
        }
    }
    /// Research pages pass `.celsius`; user-facing pages pass `.current`.
    func displaySummary(in unit: TemperatureUnit) -> String {
        UIString.text(sourceTitle) + " " + unit.text(temperature)
            + (provisional ? " · " + UIString.text("暫定") : "")
    }
    func displayEvidenceSummary(in unit: TemperatureUnit) -> String {
        displayTemperatureStatistics(in: unit) + "\n"
            + UIString.format("新しい区間を抽出する温度履歴：%.1f日間・%d点（直近30日）。", historySpanDays, historySampleCount)
            + "\n" + UIString.text("保持温度は保存済みの低負荷区間を全期間使用します。過去の未保存区間は含みません。")
            + "\n" + UIString.format("保持温度の観測充実度：%@。", UIString.text(confidence.title))
            + "\n" + UIString.format("低負荷の採用：%d日・%.1f時間。最終採用：%@。", observedDays,
                observedSeconds / 3_600, lastObservedAt.map(ValueFormatter.shortDateTime) ?? UIString.text("未取得"))
            + "\n" + UIString.format("読込＋書込の採用上限 %.2f MiB/秒。", ioThresholdBytesPerSecond / 1_048_576)
            + "\n" + UIString.format("採用元：温度記録のI/O差分 %d区間／SMART代用 %d区間。",
                candidates.filter { $0.effectiveIOSource == .blockIO }.count,
                candidates.filter { $0.effectiveIOSource == .smart }.count)
            + (blockIOSelectionThreshold.map { "\n" + UIString.format("I/O差分の新規採用上限 %.2f MiB/秒。", $0 / 1_048_576) } ?? "")
            + (smartSelectionThreshold.map { "\n" + UIString.format("SMART代用の新規採用上限 %.2f MiB/秒。", $0 / 1_048_576) } ?? "")
            + (relativeLowIO ? "\n" + UIString.text("相対的な低負荷帯を含みます。アイドルの確認ではなく、温度観測の評価は中までです。") : "")
            + (fromEarlierFirmware ? "\n" + UIString.text("ファームウェア系列の更新後はまだ観測がないため、更新前の観測を暫定値として使っています。") : "")
    }
    func displayTemperatureStatistics(in unit: TemperatureUnit) -> String {
        let medianText = observedMedianTemperature.map {
            UIString.format("観測中央値 %@（日ごとの代表値）", unit.text($0))
        } ?? UIString.text("観測中央値：未取得")
        let stableText = stableMedianTemperature.map {
            UIString.format("安定区間の中央値 %@（参考値）", unit.text($0))
        } ?? UIString.text("安定区間の中央値：未取得")
        guard let mean = timeWeightedTemperature else {
            return medianText + "\n" + stableText + "\n" + UIString.text("時間加重平均：未取得（平均を復元できる温度記録なし）")
        }
        return medianText + "\n" + stableText + "\n" + UIString.format("時間加重平均 %@ · %.1f時間 · 採用%d区間中%d区間（参考値）",
            unit.text(mean), meanObservedSeconds / 3_600, selectedCandidateCount, meanCandidateCount)
    }
}

enum IdleRetentionTemperatureAnalyzer {
    static func assess(smart: [DriveSnapshot], temperatures: [TemperatureSample], deviceID: String,
                       manual: Double?, now: Date, excluding: [DateInterval],
                       previous: [IdleTemperatureCandidate] = [],
                       calendar: Calendar = .current) -> IdleRetentionTemperature {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let filtered = smart.filter { $0.deviceID == deviceID && $0.capturedAt >= cutoff && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
        let history = filtered.reduce(into: [DriveSnapshot]()) { result, sample in
            if result.last?.capturedAt != sample.capturedAt { result.append(sample) }
        }
        let currentFirmware = history.last?.firmware
        // A point update keeps the lineage; a run never spans the reboot
        // that installs it because the power-cycle count changes.
        let currentLineage = UpdateLineage.firmware(currentFirmware)
        let historySamples = temperatures.filter {
            $0.deviceID == deviceID && $0.capturedAt >= cutoff
                && $0.capturedAt <= now && (-40...125).contains($0.temperatureCelsius)
        }.sorted { $0.capturedAt < $1.capturedAt }
        let samples = historySamples.filter { $0.dailySummary == nil }
            .reduce(into: [TemperatureSample]()) { result, sample in
                if result.last?.capturedAt == sample.capturedAt { result[result.count - 1] = sample }
                else { result.append(sample) }
            }
        let observations = IdleTemperatureObservations.build(history: history, samples: samples,
            lineage: currentLineage, excluding: excluding)
        var candidates = observations.candidates
        let fresh = candidates
        // Keep already observed candidates when temperature history compacts.
        // A current overlapping observation replaces an earlier partial run
        // only while it still covers it, and not when it was derived from
        // thinned data: after 48 hours SMART snapshots are 15-minute buckets,
        // which can drop the first snapshot of a run, and temperature samples
        // are 5-minute buckets, so the sample density drops.
        func density(_ candidate: IdleTemperatureCandidate) -> Double {
            Double(candidate.sampleCount) / max(1, candidate.end.timeIntervalSince(candidate.start))
        }
        func overlaps(_ lhs: IdleTemperatureCandidate, _ rhs: IdleTemperatureCandidate) -> Bool {
            lhs.start < rhs.end && lhs.end > rhs.start
        }
        func valid(_ old: IdleTemperatureCandidate) -> Bool {
            (1...3).contains(old.ruleVersion) && old.deviceID == deviceID
                && (!(old.relativeLowIO ?? false) || old.ioThresholdBytesPerSecond.map { $0.isFinite && $0 > 0 && $0 <= 8 * 1_048_576 } == true)
                && old.end <= now && old.end > old.start
                && old.temperature.isFinite && (-40...125).contains(old.temperature)
                && old.sampleCount >= (old.effectiveIOSource == .blockIO ? 5 : 4) && old.hostBytes.isFinite && old.hostBytes >= 0
                && old.effectiveMaximumIOIntervalSeconds.map { $0.isFinite && $0 > 0 } == true
                && !excluding.contains { $0.intersects(DateInterval(start: old.start, end: old.end)) }
        }
        // Stored runs of one lineage can overlap when they carry different
        // point-release labels (an earlier build labelled runs with the
        // current firmware). Count each stretch once, keeping the run with
        // more samples.
        let usable = previous.filter { valid($0) && UpdateLineage.firmware($0.firmware) == currentLineage }
            .sorted { $0.sampleCount != $1.sampleCount ? $0.sampleCount > $1.sampleCount : $0.end < $1.end }
            .reduce(into: [IdleTemperatureCandidate]()) { kept, old in
                if !kept.contains(where: { $0.start < old.end && old.start < $0.end }) { kept.append(old) }
            }
        // Only a run that ended while history was still at full resolution
        // can still be growing. Older stored runs were found at full
        // resolution and are kept: thinned snapshots can hide the interval
        // that split two runs and join them into one.
        let fullResolutionStart = now.addingTimeInterval(-min(
            HistoryRetentionPolicy.standard.fullResolutionAge,
            TemperatureHistoryRetentionPolicy.standard.fullResolutionAge))
        let keptPrevious = usable.filter { old in
            old.end < fullResolutionStart || !fresh.contains {
                overlaps($0, old) && $0.start <= old.start && $0.end >= old.end && density($0) >= density(old) / 2
            }
        }
        candidates = fresh.filter { new in !keptPrevious.contains { overlaps(new, $0) } } + keptPrevious
        candidates.sort { $0.end < $1.end }
        // After a firmware lineage change, the earlier lineage's intervals
        // stand in provisionally until the new one is observed, instead of
        // the 30 °C default.
        let earlierLineage = candidates.isEmpty
            ? previous.filter { valid($0) && UpdateLineage.firmware($0.firmware) != currentLineage }
            : []
        if !earlierLineage.isEmpty { candidates = earlierLineage.sorted { $0.end < $1.end } }
        let stable = candidates.filter(\.stable)
        let selected = candidates
        // Each interval counts once, on the day of its midpoint. Runs are
        // capped at 6 hours, so one crossing midnight is not two days.
        var days: [Date: [Double]] = [:]
        for candidate in selected {
            let midpoint = candidate.start.addingTimeInterval(candidate.end.timeIntervalSince(candidate.start) / 2)
            days[calendar.startOfDay(for: midpoint), default: []].append(candidate.temperature)
        }
        let daily = days.values.map(median)
        var stableDays: [Date: [Double]] = [:]
        for candidate in stable {
            let midpoint = candidate.start.addingTimeInterval(candidate.end.timeIntervalSince(candidate.start) / 2)
            stableDays[calendar.startOfDay(for: midpoint), default: []].append(candidate.temperature)
        }
        let stableDaily = stableDays.values.map(median)
        let meanCandidates = selected.filter {
            guard let mean = $0.timeWeightedTemperature, let duration = $0.temperatureObservedSeconds else { return false }
            return mean.isFinite && (-40...125).contains(mean) && duration.isFinite
                && duration > 0 && duration <= $0.end.timeIntervalSince($0.start)
        }
        let meanSeconds = meanCandidates.reduce(0) { $0 + $1.temperatureObservedSeconds! }
        let meanIntegral = meanCandidates.reduce(0) { $0 + $1.timeWeightedTemperature! * $1.temperatureObservedSeconds! }
        let seconds = selected.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let last = selected.last?.end
        let freshEnough = last.map { now.timeIntervalSince($0) <= 7 * 86_400 } ?? false
        let range = daily.min().flatMap { lo in daily.max().map { lo...$0 } }
        let spread = range.map { $0.upperBound - $0.lowerBound } ?? .infinity
        let relative = selected.contains { $0.relativeLowIO == true }
        let stableSeconds = stable.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let stableFresh = stable.last.map { now.timeIntervalSince($0.end) <= 7 * 86_400 } ?? false
        var confidence: ObservationConfidence = stableFresh && stableDays.count >= 7 && stableSeconds >= 14 * 3_600 && spread <= 5
            ? .high : stableFresh && stableDays.count >= 3 && stableSeconds >= 3 * 3_600 && spread <= 8 ? .medium : .low
        if relative && confidence == .high { confidence = .medium }
        if !earlierLineage.isEmpty { confidence = .low }
        let validManual = manual.flatMap { $0.isFinite && (-40...85).contains($0) ? $0 : nil }
        let source: IdleRetentionTemperature.Source = validManual != nil ? .manual : selected.isEmpty ? .fallback : freshEnough && earlierLineage.isEmpty ? .idle : .previous
        return .init(temperature: validManual ?? (daily.isEmpty ? 30 : median(daily)), source: source,
            candidates: candidates, confidence: confidence, observedDays: days.count, observedSeconds: seconds,
            lastObservedAt: last, temperatureRange: range,
            historyDays: Set(historySamples.map { calendar.startOfDay(for: $0.capturedAt) }).count,
            historySampleCount: historySamples.count,
            historySpanDays: max(0, (historySamples.last?.capturedAt.timeIntervalSince(historySamples.first?.capturedAt ?? now) ?? 0) / 86_400),
            relativeLowIO: relative, ioThresholdBytesPerSecond: observations.blockIOThreshold ?? observations.smartThreshold ?? 1_048_576,
            observedMedianTemperature: daily.isEmpty ? nil : median(daily),
            stableMedianTemperature: stableDaily.isEmpty ? nil : median(stableDaily),
            timeWeightedTemperature: meanSeconds > 0 ? meanIntegral / meanSeconds : nil,
            meanObservedSeconds: meanSeconds, meanCandidateCount: meanCandidates.count,
            selectedCandidateCount: selected.count, fromEarlierFirmware: !earlierLineage.isEmpty,
            blockIOSelectionThreshold: observations.blockIOThreshold, smartSelectionThreshold: observations.smartThreshold)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }
}

struct ForecastObservationEvidence: Equatable, Sendable {
    var confidence: ObservationConfidence = .low
    var wear: ObservationConfidence = .low
    var waf: ObservationConfidence = .low
    var pace: ObservationConfidence = .low
    var wearDays = 0.0
    var wearIntervals = 0
    var wafDays = 0.0
    var wafHostBytes = 0.0
    static let ruleVersion = 1

    static func assess(wear: ControllerWearHistorySummary, wafDays: Double, wafHost: Double,
                       paceDays: Double, hasDomains: Bool, held: Bool) -> Self {
        var value = Self()
        value.wearDays = wear.observationDays
        value.wearIntervals = min(wear.tlcIntervalCount, wear.slcIntervalCount)
        value.wafDays = wafDays
        value.wafHostBytes = wafHost
        let progress = min(wear.tlcPEProgress ?? 0, wear.slcPEProgress ?? 0)
        value.wear = hasDomains && !held && value.wearIntervals >= 3 && wear.observationDays >= 90 && progress >= 3
            ? .high : hasDomains && !held && value.wearIntervals >= 2 && wear.observationDays >= 14 && progress >= 1 ? .medium : .low
        // The selected rate/WAF window is normally 30 days. Requiring 90
        // days here would make high structurally unreachable. Allow a small
        // gap at the endpoints of the 30-day collection window.
        value.waf = wafDays >= 28 && wafHost >= 1e12 ? .high : wafDays >= 7 && wafHost >= 1e11 ? .medium : .low
        value.pace = paceDays >= 28 ? .high : paceDays >= 14 ? .medium : .low
        value.confidence = [value.wear, value.waf, value.pace].min(by: { $0.rawValue < $1.rawValue }) ?? .low
        return value
    }

    var displayDetails: String {
        UIString.format("損耗 %@（%.1f日・%d区間）／WAF %@（%.1f日・%@）／ペース %@。規則 v%d。",
            UIString.text(wear.title), wearDays, wearIntervals, UIString.text(waf.title), wafDays,
            ValueFormatter.bytes(wafHostBytes), UIString.text(pace.title), Self.ruleVersion)
    }
}
