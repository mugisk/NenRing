import Foundation

struct ThermalRetentionAssessment: Equatable, Sendable {
    let programTemperature: Double?
    let activeTemperature: Double?
    let idleTemperature: Double?
    let storageTemperature: Double
    let storageSource: String
    let sourceDate: Date?
    let coverage: Double
    let programFactor: Double
    let stressRelativeTo30: Double
    let storageMinimumTemperature: Double?
    let storageMaximumTemperature: Double?
    let storageEvidenceScore: Int
    let programWeightSource: String
    let storageFitDescription: String?
}

private struct CooldownFit: Equatable, Sendable {
    let ambient: Double
    let start: Date
    let end: Date
    let minimum: Double
    let maximum: Double
    let rms: Double
    let tauSeconds: Double
}

struct ThermalRetentionAnalyzer: Sendable {
    func assess(smartHistory: [DriveSnapshot], temperatureHistory: [TemperatureSample],
                deviceID: String, storageTemperature: Double?, activationEnergy: Double,
                programCorrection: Bool, now: Date, excluding: [DateInterval] = [],
                ftlHistory: [ASPToolDiagnosticsSnapshot] = [],
                continuityLane suppliedLane: WearContinuityLane? = nil,
                observedStorage: IdleRetentionTemperature? = nil) -> ThermalRetentionAssessment {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let temperatures = temperatureHistory.filter {
            $0.deviceID == deviceID && $0.capturedAt >= cutoff && $0.capturedAt <= now
                && (-40...125).contains($0.temperatureCelsius)
        }.sorted { $0.capturedAt < $1.capturedAt }
        let gaps = zip(temperatures, temperatures.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }.filter { $0 > 0 }.sorted()
        let maxGap = gaps.isEmpty ? 0 : gaps[gaps.count / 2] * 3
        let spans = zip(temperatures, temperatures.dropFirst()).filter { a, b in
            let gap = b.capturedAt.timeIntervalSince(a.capturedAt)
            return gap > 0 && gap <= maxGap && !excluding.contains { $0.intersects(DateInterval(start: a.capturedAt, end: b.capturedAt)) }
        }
        let activeSeconds = spans.reduce(0.0) { $0 + $1.1.capturedAt.timeIntervalSince($1.0.capturedAt) }
        let active = spans.reduce(0.0) { result, span in
            result + Double(span.0.temperatureCelsius + span.1.temperatureCelsius) / 2 * span.1.capturedAt.timeIntervalSince(span.0.capturedAt)
        }
        let smart = smartHistory.filter { $0.deviceID == deviceID && $0.capturedAt >= cutoff && $0.capturedAt <= now }.sorted { $0.capturedAt < $1.capturedAt }
        var weighted = 0.0, coveredBytes = 0.0, totalBytes = 0.0
        var spanCursor = 0
        for (a, b) in zip(smart, smart.dropFirst()) {
            guard a.firmware == b.firmware, let h0 = a.dataUnitsWrittenBytes, let h1 = b.dataUnitsWrittenBytes,
                  h1 > h0, b.capturedAt > a.capturedAt else { continue }
            let interval = DateInterval(start: a.capturedAt, end: b.capturedAt)
            guard !excluding.contains(where: { $0.intersects(interval) }) else { continue }
            totalBytes += h1 - h0
            var seconds = 0.0, integral = 0.0
            while spanCursor < spans.count && spans[spanCursor].1.capturedAt <= a.capturedAt { spanCursor += 1 }
            for span in spans.dropFirst(spanCursor) {
                let (t0, t1) = span
                if t0.capturedAt >= b.capturedAt { break }
                let start = max(a.capturedAt, t0.capturedAt), end = min(b.capturedAt, t1.capturedAt)
                guard end > start else { continue }
                let duration = end.timeIntervalSince(start)
                seconds += duration
                integral += duration * Double(t0.temperatureCelsius + t1.temperatureCelsius) / 2
            }
            if seconds > 0 {
                let bytes = (h1 - h0) * min(1, seconds / interval.duration)
                coveredBytes += bytes
                weighted += bytes * integral / seconds
            }
        }
        var ftlWeighted = 0.0
        var ftlCoveredBytes = 0.0
        var ftlTotalBytes = 0.0
        let rawOrderedFTL = ftlHistory
            .filter { $0.deviceID == deviceID && $0.capturedAt <= now && $0.sourceArtifact.participatesInCoreWearLane }
            .sorted { $0.capturedAt < $1.capturedAt }
        let ftlLane: WearContinuityLane? = {
            if let suppliedLane { return suppliedLane }
            guard let latest = rawOrderedFTL.last else { return nil }
            return WearContinuityLaneBuilder.build(
                snapshots: rawOrderedFTL,
                smart: smartHistory,
                latest: latest
            )
        }()
        let orderedFTL = (ftlLane?.snapshots.isEmpty == false ? ftlLane!.snapshots : rawOrderedFTL)
            .filter { $0.capturedAt >= cutoff && $0.capturedAt <= now }
        let ftlExcluding = excluding + (ftlLane?.rateLearningExclusions ?? [])
        // Both lists are in time order, so a cursor skips the temperature
        // spans that end before each FTL interval, as in the SMART loop
        // above. Spans that do not overlap added nothing before either.
        var ftlSpanCursor = 0
        for (a, b) in zip(orderedFTL, orderedFTL.dropFirst()) {
            guard a.captureQuality != .unknown, b.captureQuality != .unknown,
                  a.nandWritesUnitState.supportsIntervalComparison,
                  b.nandWritesUnitState.supportsIntervalComparison,
                  let n0 = a.nandWrittenBytes, let n1 = b.nandWrittenBytes,
                  n1 > n0, b.capturedAt > a.capturedAt else { continue }
            let interval = DateInterval(start: a.capturedAt, end: b.capturedAt)
            guard !ftlExcluding.contains(where: { $0.intersects(interval) }) else { continue }
            var seconds = 0.0
            var integral = 0.0
            while ftlSpanCursor < spans.count && spans[ftlSpanCursor].1.capturedAt <= interval.start { ftlSpanCursor += 1 }
            for span in spans.dropFirst(ftlSpanCursor) {
                if span.0.capturedAt >= interval.end { break }
                let start = max(interval.start, span.0.capturedAt)
                let end = min(interval.end, span.1.capturedAt)
                guard end > start else { continue }
                let duration = end.timeIntervalSince(start)
                seconds += duration
                integral += duration * Double(span.0.temperatureCelsius + span.1.temperatureCelsius) / 2
            }
            ftlTotalBytes += Double(n1 - n0)
            guard seconds > 0 else { continue }
            let bytes = Double(n1 - n0) * min(1, seconds / interval.duration)
            ftlCoveredBytes += bytes
            ftlWeighted += bytes * integral / seconds
        }
        let programWeightSource = ftlCoveredBytes > 0 ? "Direct FTL NAND Writes" : "SMART Host Writes代用"
        if ftlCoveredBytes > 0 {
            weighted = ftlWeighted
            coveredBytes = ftlCoveredBytes
            totalBytes = ftlTotalBytes
        }

        var off = 30.0, source = "30°C fallback", date: Date?
        var storageScore = 10
        var storageRange: (minimum: Double, maximum: Double)?
        var fitDescription: String?
        let sortedTemperatures = temperatures.map { Double($0.temperatureCelsius) }.sorted()
        if let minimum = sortedTemperatures.first, let maximum = sortedTemperatures.last {
            storageRange = (minimum, maximum)
        }
        let idleValues = idleTemperatureValues(smart: smart, temperatures: temperatures, excluding: excluding)
        let latestCooldown = Self.cooldownSamples(in: temperatures, maxGap: maxGap, excluding: excluding)
        // The low-I/O observation also sets the retention scenario's
        // temperature; using it here keeps one storage temperature per Mac.
        if storageTemperature == nil, let observedStorage,
           observedStorage.source == .idle || observedStorage.source == .previous {
            off = observedStorage.temperature
            source = observedStorage.sourceTitle + "・保管温度proxy"
            date = observedStorage.lastObservedAt
            switch observedStorage.confidence {
            case .high: storageScore = 80
            case .medium: storageScore = 65
            case .low: storageScore = 45
            }
            storageRange = observedStorage.temperatureRange.map { ($0.lowerBound, $0.upperBound) }
        } else if storageTemperature == nil, let latestCooldown,
           let fit = cooldownFit(for: latestCooldown) {
            off = fit.ambient
            source = "cooldown指数fit・保管温度proxy"
            date = fit.end
            storageScore = 70
            storageRange = (fit.minimum, fit.maximum)
            fitDescription = "A=\(String(format: "%.1f", fit.ambient))°C · τ=\(String(format: "%.0f", fit.tauSeconds / 60))分 · RMS=\(String(format: "%.2f", fit.rms))°C"
        } else if storageTemperature == nil, let latestCooldown {
            let tail = latestCooldown.suffix(3).map { Double($0.temperatureCelsius) }.sorted()
            if tail.count == 3 {
                off = tail[1]
                source = "cooldown末尾・保管温度proxy"
                date = latestCooldown.last?.capturedAt
                storageScore = 55
                storageRange = (latestCooldown.map { Double($0.temperatureCelsius) }.min()!,
                                latestCooldown.map { Double($0.temperatureCelsius) }.max()!)
            }
        } else if storageTemperature == nil, let idle = percentile(idleValues, fraction: 0.2) {
            off = idle
            source = "Idle温度下側20%・保管温度proxy"
            date = temperatures.last?.capturedAt
            storageScore = 40
            let values = idleValues.sorted()
            storageRange = values.isEmpty ? nil : (values.first!, values.last!)
        } else if storageTemperature == nil, let ambient = percentile(sortedTemperatures, fraction: 0.2) {
            off = ambient
            source = "30日下側20%・保管温度proxy"
            date = temperatures.last?.capturedAt
            storageScore = 30
        }
        if let storageTemperature {
            off = storageTemperature
            source = "利用者指定"
            date = nil
            storageScore = 90
            storageRange = nil
        }
        let idleTemperature = percentile(idleValues, fraction: 0.5)
        let program = coveredBytes > 0 ? weighted / coveredBytes : nil
        let factor = programCorrection ? program.map { min(1.02, max(0.98, 1 + ($0 - 20) / 30 * 0.02)) } ?? 1 : 1
        let stress = exp(-activationEnergy / 8.617333262145e-5 * (1 / (off + 273.15) - 1 / 303.15))
        return ThermalRetentionAssessment(programTemperature: program, activeTemperature: activeSeconds > 0 ? active / activeSeconds : nil,
            idleTemperature: idleTemperature,
            storageTemperature: off, storageSource: source, sourceDate: date,
            coverage: totalBytes > 0 ? min(1, coveredBytes / totalBytes) : 0, programFactor: factor, stressRelativeTo30: stress,
            storageMinimumTemperature: storageRange?.minimum,
            storageMaximumTemperature: storageRange?.maximum,
            storageEvidenceScore: storageScore,
            programWeightSource: programWeightSource,
            storageFitDescription: fitDescription)
    }

    private func idleTemperatureValues(
        smart: [DriveSnapshot],
        temperatures: [TemperatureSample],
        excluding: [DateInterval]
    ) -> [Double] {
        var result: [Double] = []
        for (a, b) in zip(smart, smart.dropFirst()) {
            guard a.firmware == b.firmware,
                  let before = a.dataUnitsWrittenBytes,
                  let after = b.dataUnitsWrittenBytes,
                  after == before, b.capturedAt > a.capturedAt else { continue }
            let interval = DateInterval(start: a.capturedAt, end: b.capturedAt)
            guard !excluding.contains(where: { $0.intersects(interval) }) else { continue }
            result += temperatures.filter { interval.contains($0.capturedAt) }
                .map { Double($0.temperatureCelsius) }
        }
        return result
    }

    /// Finds the newest valid cooldown without materializing every candidate
    /// slice. The input is chronological (as prepared by `assess`).
    static func cooldownSamples(
        in temperatures: [TemperatureSample],
        maxGap: TimeInterval,
        excluding: [DateInterval]
    ) -> [TemperatureSample]? {
        guard maxGap.isFinite, maxGap > 0, temperatures.count >= 4 else { return nil }

        // Prefix summaries make each candidate's gap and rebound checks O(1).
        // The 90-minute bound below limits candidates to the relevant window;
        // older history is never copied or rescanned for each endpoint.
        var invalidGapPrefix = [Int](repeating: 0, count: temperatures.count)
        var positiveRisePrefix = [Int](repeating: 0, count: temperatures.count)
        for index in 1..<temperatures.count {
            let gap = temperatures[index].capturedAt.timeIntervalSince(temperatures[index - 1].capturedAt)
            invalidGapPrefix[index] = invalidGapPrefix[index - 1] + (gap > maxGap ? 1 : 0)
            let rise = max(0, temperatures[index].temperatureCelsius - temperatures[index - 1].temperatureCelsius)
            positiveRisePrefix[index] = positiveRisePrefix[index - 1] + rise
        }

        for end in temperatures.indices.reversed() where end >= 3 {
            var bestStart: Int?
            for start in stride(from: end - 3, through: 0, by: -1) {
                let startAt = temperatures[start].capturedAt
                let endAt = temperatures[end].capturedAt
                let duration = endAt.timeIntervalSince(startAt)
                // Since starts move backward, every older candidate is longer.
                if duration > 5_400 { break }
                guard duration >= 300,
                      invalidGapPrefix[end] == invalidGapPrefix[start] else { continue }

                let interval = DateInterval(start: startAt, end: endAt)
                guard !excluding.contains(where: { $0.intersects(interval) }) else { continue }
                let drop = Double(temperatures[start].temperatureCelsius - temperatures[end].temperatureCelsius)
                let rise = Double(positiveRisePrefix[end] - positiveRisePrefix[start])
                guard drop >= 3, rise <= drop * 0.2 else { continue }
                // Keep the earliest valid start for this end, matching the
                // previous preference for the longest qualifying sample span.
                bestStart = start
            }
            if let bestStart { return Array(temperatures[bestStart...end]) }
        }
        return nil
    }

    private func cooldownFit(for samples: [TemperatureSample]) -> CooldownFit? {
        guard samples.count >= 6, let first = samples.first else { return nil }
        let y = samples.map { Double($0.temperatureCelsius) }
        let times = samples.map { $0.capturedAt.timeIntervalSince(first.capturedAt) }
        let observedDrop = y[0] - y[y.count - 1]
        guard observedDrop >= 3 else { return nil }
        var best: CooldownFit?
        for step in 1...180 {
            let tau = Double(step) * 60
            let x = times.map { exp(-$0 / tau) }
            let n = Double(x.count)
            let sumX = x.reduce(0, +)
            let sumY = y.reduce(0, +)
            let sumXX = x.reduce(0) { $0 + $1 * $1 }
            let sumXY = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
            let denominator = n * sumXX - sumX * sumX
            guard denominator > 0 else { continue }
            let b = (n * sumXY - sumX * sumY) / denominator
            let a = (sumY - b * sumX) / n
            guard a.isFinite, b.isFinite, b > 0, a >= -40, a <= y.min()! else { continue }
            let residuals = zip(x, y).map { $1 - (a + b * $0) }
            let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / n)
            let fittedDrop = b * (1 - x.last!)
            let dropError = abs(fittedDrop - observedDrop) / observedDrop
            guard rms <= 1, dropError <= 0.2 else { continue }
            let candidate = CooldownFit(
                ambient: a,
                start: samples.first!.capturedAt,
                end: samples.last!.capturedAt,
                minimum: y.min()!,
                maximum: y.max()!,
                rms: rms,
                tauSeconds: tau
            )
            if best == nil || candidate.rms < best!.rms { best = candidate }
        }
        return best
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}

struct RetentionWAFWindow: Equatable, Sendable {
    let days: Int
    let value: Double?
    let count: Int
    let hostBytes: Double
    let observationDays: Double
    let coefficientOfVariation: Double?
    /// SMART filesystem-space observations captured inside the intervals that
    /// contributed to this WAF window. These are host-volume values, not NAND
    /// spare capacity.
    let filesystemFreeSampleCount: Int
    let minimumFilesystemFreeBytes: UInt64?
    let minimumFilesystemFreeRatio: Double?
}

struct RetentionWAFAssessment: Equatable, Sendable {
    let windows: [RetentionWAFWindow]
    let lifetime: Double?
    /// Raw observed WAF selected from the 30/90/7-day or lifetime window.
    let daily: Double?
    let dailySource: String
    let prior: Double
    let observed: Double?
    /// Historical prior/observed blend retained for Advanced diagnostics.
    let blended: Double
    /// WAF used by the current-condition estimate. A valid observed value is
    /// provisionally preferred; the prior is used only when observation is unavailable.
    let current: Double
    let currentSource: String
    let blendWeight: Double
    /// Host bytes from the selected observed interval. A lifetime fallback
    /// deliberately reports zero here because it is not a monitoring delta.
    let observedHostBytes: Double
    let priorEquivalentHostBytes: Double
    let confidenceScore: Int
    let unitScore: Double
    let seriesScore: Double
    let client: Double
    let clientSource: String
    let notes: [String]
}

struct RetentionWAFAnalyzer: Sendable {
    func assess(snapshots: [ASPToolDiagnosticsSnapshot], latest: ASPToolDiagnosticsSnapshot,
                now: Date, excluding: [DateInterval], client: Double, prior: Double = 2.2,
                selection: String?, trials: [ProxyTrial],
                priorEquivalentHostBytes: Double = 1e12,
                continuityLane suppliedLane: WearContinuityLane? = nil,
                filesystemHistory: [DriveSnapshot] = []) -> RetentionWAFAssessment {
        let fallbackPrior = prior.isFinite && prior > 0 ? prior : 2.2
        let identity = ControllerWearSeriesIdentity(snapshot: latest)
        let ordered = snapshots.filter { $0.deviceID == latest.deviceID && $0.capturedAt <= latest.capturedAt }
            .sorted { $0.capturedAt < $1.capturedAt }
        let lane = suppliedLane ?? WearContinuityLaneBuilder.build(
            snapshots: ordered,
            smart: [],
            latest: latest
        )
        let series = lane.snapshots
        let sortedFilesystemHistory = filesystemHistory
            .filter { $0.deviceID == latest.deviceID && $0.filesystemFreeBytes != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        let windows = [7, 30, 90].map { days -> RetentionWAFWindow in
            var anchor: ASPToolDiagnosticsSnapshot?
            var previousSample: ASPToolDiagnosticsSnapshot?
            var host = 0.0, nand = 0.0, seconds = 0.0
            var ratios: [Double] = []
            var contributingIntervals: [DateInterval] = []
            for sample in series where sample.capturedAt >= now.addingTimeInterval(-Double(days) * 86_400) {
                defer { previousSample = sample }
                guard sample.captureQuality != .unknown,
                      sample.hostWritesUnitState.supportsIntervalComparison,
                      sample.nandWritesUnitState.supportsIntervalComparison,
                      sample.hostWritesUnitState.unitBytes == sample.nandWritesUnitState.unitBytes,
                      let h1 = sample.hostWrittenBytes, let n1 = sample.nandWrittenBytes, h1.isFinite, n1.isFinite else { anchor = nil; continue }
                if let previous = previousSample,
                   sample.capturedAt <= previous.capturedAt || h1 < (previous.hostWrittenBytes ?? h1) || n1 < (previous.nandWrittenBytes ?? n1) {
                    host = 0; nand = 0; seconds = 0; ratios = []; anchor = sample; continue
                }
                guard let a = anchor, let h0 = a.hostWrittenBytes, let n0 = a.nandWrittenBytes else { anchor = sample; continue }
                guard sample.capturedAt > a.capturedAt, h1 >= h0, n1 >= n0 else {
                    host = 0; nand = 0; seconds = 0; ratios = []; anchor = sample; continue
                }
                let interval = DateInterval(start: a.capturedAt, end: sample.capturedAt)
                guard !excluding.contains(where: { $0.intersects(interval) }) else { anchor = sample; continue }
                guard h1 > h0 else { continue }
                host += h1 - h0; nand += n1 - n0; seconds += interval.duration
                ratios.append((n1 - n0) / (h1 - h0)); anchor = sample
                contributingIntervals.append(interval)
            }
            let mean = ratios.isEmpty ? 0 : ratios.reduce(0, +) / Double(ratios.count)
            let cv = mean > 0 ? sqrt(ratios.reduce(0) { $0 + pow($1 - mean, 2) } / Double(ratios.count)) / mean : nil
            let freeSamples = Self.filesystemSamples(
                in: sortedFilesystemHistory,
                coveredBy: contributingIntervals
            )
            let minimumFreeBytes = freeSamples.compactMap(\.filesystemFreeBytes).min()
            let minimumFreeRatio = freeSamples.compactMap(\.filesystemFreeRatio).filter(\.isFinite).min()
            return RetentionWAFWindow(days: days, value: host > 0 && nand > 0 ? nand / host : nil,
                count: ratios.count, hostBytes: host, observationDays: seconds / 86_400, coefficientOfVariation: cv,
                filesystemFreeSampleCount: freeSamples.count,
                minimumFilesystemFreeBytes: minimumFreeBytes,
                minimumFilesystemFreeRatio: minimumFreeRatio)
        }
        let lifetime: Double? = {
            guard latest.hostWritesUnitState.supportsIntervalComparison,
                  latest.nandWritesUnitState.supportsIntervalComparison,
                  latest.hostWritesUnitState.unitBytes == latest.nandWritesUnitState.unitBytes,
                  let h = latest.hostWrittenBytes, let n = latest.nandWrittenBytes,
                  h > 0, n > 0, (n / h).isFinite else { return nil }
            return n / h
        }()
        let chosen = windows.first { $0.days == 30 && $0.value != nil }
            ?? windows.first { $0.days == 90 && $0.value != nil }
            ?? windows.first { $0.days == 7 && $0.value != nil }
        let observed = chosen?.value ?? lifetime
        let unitScore: Double = {
            switch latest.hostWritesUnitState {
            case .verified: return 1
            case .provisional4KiB: return 0.5
            case .unverified, .unavailable: return 0
            }
        }()
        let seriesScore: Double = identity.firmwareEpoch != nil && identity.sourceBuild != nil ? 1 : 0.5
        let equivalentPrior = priorEquivalentHostBytes.isFinite && priorEquivalentHostBytes > 0
            ? priorEquivalentHostBytes : 1e12
        let observedHostBytes = chosen?.hostBytes ?? 0
        let blendWeight: Double
        if observedHostBytes > 0 {
            blendWeight = min(1, observedHostBytes / (observedHostBytes + equivalentPrior))
        } else {
            blendWeight = 0
        }
        let blended: Double
        if let observed, observed.isFinite, observed > 0 {
            blended = exp((1 - blendWeight) * log(fallbackPrior) + blendWeight * log(observed))
        } else {
            blended = fallbackPrior
        }
        let current: Double
        let currentSource: String
        if let observed, observed.isFinite, observed > 0 {
            current = observed
            currentSource = chosen.map { "\($0.days)日区間の実測値（暫定採用）" }
                ?? "累積実測値（暫定採用）"
        } else {
            current = fallbackPrior
            currentSource = "日常WAF prior（観測値なし）"
        }
        var selected = client.isFinite && client > 0 ? client : fallbackPrior
        var source = "手動仮定"
        var notes = [
            "WAFは30日・90日・7日区間、最後に累積比の順で同系列の実測値を探します。",
            "実測WAFが得られた場合は現在条件へ暫定採用し、priorとの対数混合値はAdvancedの診断として保持します。",
            "WAFは寿命計算の入力です。workload分類は説明情報として保持します。"
        ]
        if let selection {
            if let trial = trials.first(where: { $0.id.uuidString == selection && $0.selectable }), let waf = trial.waf, waf.isFinite, waf > 0 {
                selected = waf; source = "試験 \(trial.date.formatted())"; notes += trial.reasons + trial.basisNotes
            } else { notes.append("選択試験を現在系列で利用できないため、Client想定WAFへ戻しました。") }
        }
        if observed == nil { notes.append("観測WAFがないため、日常priorを使用しています。") }
        if unitScore < 1 { notes.append("WAFカウンタ単位は暫定です。比率は単位相殺ですが、絶対Host量の観測根拠は暫定表示です。") }
        if seriesScore < 1 { notes.append("WAF系列情報が不足しています。観測値は暫定表示し、系列不一致は採用しません。") }
        notes.append("WAF混合重み q は観測Host量 / (観測Host量 + prior相当Host量) で算出。安定度・取得頻度はqを減らさず根拠として別表示します。")
        return RetentionWAFAssessment(windows: windows, lifetime: lifetime, daily: observed,
            dailySource: chosen.map { "\($0.days)日区間" } ?? (lifetime == nil ? "未取得" : "累積比"),
            prior: fallbackPrior, observed: observed, blended: blended,
            current: current, currentSource: currentSource,
            blendWeight: blendWeight, observedHostBytes: observedHostBytes,
            priorEquivalentHostBytes: equivalentPrior,
            confidenceScore: Int((blendWeight * 100).rounded()),
            unitScore: unitScore, seriesScore: seriesScore,
            client: selected, clientSource: source, notes: notes)
    }

    /// Matches time-sorted filesystem observations to ordered WAF intervals in
    /// O(samples + intervals), rather than scanning every interval per sample.
    /// A sample is counted at most once, including at touching boundaries.
    static func filesystemSamples(
        in sortedSamples: [DriveSnapshot],
        coveredBy suppliedIntervals: [DateInterval]
    ) -> [DriveSnapshot] {
        let intervals = suppliedIntervals.sorted { $0.start < $1.start }
        guard !intervals.isEmpty, !sortedSamples.isEmpty else { return [] }

        var result: [DriveSnapshot] = []
        var intervalIndex = 0
        for sample in sortedSamples {
            while intervalIndex < intervals.count,
                  sample.capturedAt >= intervals[intervalIndex].end,
                  !intervals[intervalIndex].contains(sample.capturedAt) {
                intervalIndex += 1
            }
            guard intervalIndex < intervals.count else { break }
            if intervals[intervalIndex].contains(sample.capturedAt) {
                result.append(sample)
            }
        }
        return result
    }
}
