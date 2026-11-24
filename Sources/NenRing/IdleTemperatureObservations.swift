import Foundation

enum IdleTemperatureIOSource: String, Codable, Sendable {
    case blockIO, smart

    var title: String {
        switch self {
        case .blockIO: return "温度記録のI/O差分"
        case .smart: return "SMART区間平均（代用）"
        }
    }
}

/// Pure analysis of counters already saved with temperature readings. No polling.
enum IdleTemperatureObservations {
    struct Result {
        let candidates: [IdleTemperatureCandidate]
        let blockIOThreshold: Double?
        let smartThreshold: Double?
    }

    private struct Interval {
        let start: Date
        let end: Date
        let bytes: Double
        let firmware: String?
        let uptimeVerified: Bool
        var duration: Double { end.timeIntervalSince(start) }
        var rate: Double { bytes / duration }
    }

    static func build(history: [DriveSnapshot], samples: [TemperatureSample],
                      lineage: String?, excluding: [DateInterval]) -> Result {
        let smartGaps = zip(history, history.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }.filter { $0 > 0 }
        let smartCap = min(6 * 3_600, max(1_800, median(smartGaps) * 3))
        let thermalGaps = zip(samples, samples.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }.filter { $0 > 0 }
        // Never infer a quiet interval across a long temperature polling gap.
        let ioCap = min(300, max(120, median(thermalGaps) * 3))
        func excluded(_ start: Date, _ end: Date) -> Bool {
            excluding.contains { $0.intersects(DateInterval(start: start, end: end)) }
        }
        func compatible(_ a: DriveSnapshot, _ b: DriveSnapshot) -> Bool {
            let duration = b.capturedAt.timeIntervalSince(a.capturedAt)
            return duration >= 0 && duration <= smartCap
                && UpdateLineage.firmware(a.firmware) == lineage && UpdateLineage.firmware(b.firmware) == lineage
                && a.powerCycleCount != nil && a.powerCycleCount == b.powerCycleCount
                && a.powerOnHours.map { p0 in b.powerOnHours.map { p1 in
                    p1 >= p0 && Double(p1 - p0) * 3_600 + 3_600 >= duration
                } ?? false } == true
                && a.dataUnitsRead.map { r0 in b.dataUnitsRead.map { $0 >= r0 } ?? false } == true
                && a.dataUnitsWritten.map { w0 in b.dataUnitsWritten.map { $0 >= w0 } ?? false } == true
        }
        func context(at date: Date) -> DriveSnapshot? {
            var lo = 0, hi = history.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if history[mid].capturedAt <= date { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return nil }
            let value = history[lo - 1]
            return date.timeIntervalSince(value.capturedAt) <= smartCap ? value : nil
        }
        var io: [Interval] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            let duration = b.capturedAt.timeIntervalSince(a.capturedAt)
            guard duration > 0, duration <= ioCap,
                  let x = a.blockIO, let y = b.blockIO,
                  let driver = x.driverID, driver == y.driverID, x.bootTime == y.bootTime,
                  y.bytesRead >= x.bytesRead, y.bytesWritten >= x.bytesWritten,
                  let before = context(at: a.capturedAt), let after = context(at: b.capturedAt),
                  compatible(before, after), !excluded(a.capturedAt, b.capturedAt) else { continue }
            let uptimeVerified: Bool
            if let first = x.observedUptime, let last = y.observedUptime {
                // Wall-clock time includes sleep; the monotonic uptime does not.
                // A small allowance covers sequential timestamp/counter reads.
                guard first.isFinite, last.isFinite, first >= 0, last > first,
                      abs((last - first) - duration) <= 5 else { continue }
                uptimeVerified = true
            } else {
                uptimeVerified = false
            }
            io.append(.init(start: a.capturedAt, end: b.capturedAt,
                bytes: Double(y.bytesRead - x.bytesRead) + Double(y.bytesWritten - x.bytesWritten),
                firmware: after.firmware, uptimeVerified: uptimeVerified))
        }

        // A failed/reset/missing precise interval must not be replaced with a
        // coarse SMART average which could hide the same burst or gap.
        let ioDates = samples.filter { $0.blockIO != nil }.map(\.capturedAt)
        func hasIO(between start: Date, and end: Date) -> Bool {
            var lo = 0, hi = ioDates.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ioDates[mid] < start { lo = mid + 1 } else { hi = mid }
            }
            return lo < ioDates.count && ioDates[lo] <= end
        }
        var fallback: [Interval] = []
        for (a, b) in zip(history, history.dropFirst()) {
            guard b.capturedAt > a.capturedAt, compatible(a, b),
                  !excluded(a.capturedAt, b.capturedAt), !hasIO(between: a.capturedAt, and: b.capturedAt),
                  let r0 = a.dataUnitsReadBytes, let r1 = b.dataUnitsReadBytes,
                  let w0 = a.dataUnitsWrittenBytes, let w1 = b.dataUnitsWrittenBytes else { continue }
            fallback.append(.init(start: a.capturedAt, end: b.capturedAt,
                bytes: r1 - r0 + w1 - w0, firmware: b.firmware, uptimeVerified: false))
        }
        let ioThreshold = io.isEmpty ? nil : threshold(io)
        let smartThreshold = fallback.isEmpty ? nil : threshold(fallback)
        let candidates = makeCandidates(io, samples: samples, source: .blockIO, threshold: ioThreshold ?? 1_048_576)
            + makeCandidates(fallback, samples: samples, source: .smart, threshold: smartThreshold ?? 1_048_576)
        return .init(candidates: candidates, blockIOThreshold: ioThreshold, smartThreshold: smartThreshold)
    }

    private static func threshold(_ intervals: [Interval]) -> Double {
        let total = intervals.reduce(0) { $0 + $1.duration }
        guard total >= 6 * 3_600 else { return 1_048_576 }
        var seconds = 0.0
        for value in intervals.sorted(by: { $0.rate < $1.rate }) {
            seconds += value.duration
            if seconds >= total * 0.2 { return max(1_048_576, min(8 * 1_048_576, value.rate)) }
        }
        return 1_048_576
    }

    private static func makeCandidates(_ intervals: [Interval], samples: [TemperatureSample],
                                       source: IdleTemperatureIOSource, threshold: Double) -> [IdleTemperatureCandidate] {
        let minimumDuration = source == .blockIO ? 600.0 : 1_800.0
        let minimumPoints = source == .blockIO ? 5 : 4
        var result: [IdleTemperatureCandidate] = []
        var start: Date?, end: Date?
        var bytes = 0.0, longest = 0.0
        var relative = false, uptimeVerified = true
        var firmware: String?
        var cursor = 0
        func finish() {
            defer { start = nil; end = nil; bytes = 0; longest = 0; relative = false; uptimeVerified = true; firmware = nil }
            // One second admits timestamp jitter, not an extra polling interval.
            guard let firstAt = start, let lastAt = end,
                  lastAt.timeIntervalSince(firstAt) >= minimumDuration - 1 else { return }
            while cursor < samples.count && samples[cursor].capturedAt < firstAt { cursor += 1 }
            let points = Array(samples.dropFirst(cursor).prefix { $0.capturedAt <= lastAt })
            let endpointLimit = source == .blockIO ? 0.0 : 600.0
            guard points.count >= minimumPoints, let first = points.first, let last = points.last,
                  first.capturedAt.timeIntervalSince(firstAt) <= endpointLimit,
                  lastAt.timeIntervalSince(last.capturedAt) <= endpointLimit else { return }
            let gaps = zip(points, points.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }
            let cap = source == .blockIO ? min(300, max(120, median(gaps) * 3)) : min(1_800, max(600, median(gaps) * 3))
            guard gaps.allSatisfy({ $0 > 0 && $0 <= cap }) else { return }
            let tail = points.filter { $0.capturedAt >= lastAt.addingTimeInterval(-1_800) }
            let values = tail.map { Double($0.temperatureCelsius) }
            let stableSpan = source == .blockIO ? min(900, lastAt.timeIntervalSince(firstAt)) - 1 : 900
            let stable = tail.count >= 3 && tail.last!.capturedAt.timeIntervalSince(tail.first!.capturedAt) >= stableSpan
                && values.max()! - values.min()! <= 2
            let selected = stable ? tail : points
            let seconds = selected.last!.capturedAt.timeIntervalSince(selected.first!.capturedAt)
            let integral = zip(selected, selected.dropFirst()).reduce(0.0) { sum, pair in
                sum + Double(pair.0.temperatureCelsius + pair.1.temperatureCelsius) / 2
                    * pair.1.capturedAt.timeIntervalSince(pair.0.capturedAt)
            }
            result.append(.init(deviceID: first.deviceID, firmware: firmware, start: firstAt, end: lastAt,
                temperature: median(selected.map { Double($0.temperatureCelsius) }), sampleCount: points.count,
                hostBytes: bytes, stable: stable, smartIntervalSeconds: source == .smart ? longest : nil,
                ruleVersion: 3, relativeLowIO: relative, ioThresholdBytesPerSecond: threshold,
                timeWeightedTemperature: seconds > 0 ? integral / seconds : nil,
                temperatureObservedSeconds: seconds > 0 ? seconds : nil,
                ioSource: source, maximumIOIntervalSeconds: longest,
                uptimeContinuityVerified: source == .blockIO ? uptimeVerified : nil))
        }
        for interval in intervals {
            guard interval.rate.isFinite, interval.rate <= threshold else { finish(); continue }
            if end != interval.start { finish(); start = interval.start }
            end = interval.end
            bytes += interval.bytes
            longest = max(longest, interval.duration)
            relative = relative || interval.rate > 1_048_576
            uptimeVerified = uptimeVerified && interval.uptimeVerified
            firmware = interval.firmware
            if let first = start, interval.end.timeIntervalSince(first) >= 6 * 3_600 { finish() }
        }
        finish()
        return result
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }
}
