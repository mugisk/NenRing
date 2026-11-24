import Foundation

/// The temperature attached to a reliability event: every sample of the
/// device in `[start, end]`, or, when there is none, the sample nearest to
/// `end` within 30 minutes (the earlier one on a tie). This is the reference
/// that `TemperatureIntervalTable` reproduces without the samples.
enum TemperatureIntervalSummaryReference {
    static let nearestLimit: TimeInterval = 30 * 60

    static func summary(
        start: Date,
        end: Date,
        deviceID: String?,
        history: [TemperatureSample]
    ) -> FTLTemperatureIntervalSummary? {
        let candidates = history.filter {
            $0.deviceID == deviceID && $0.capturedAt >= start && $0.capturedAt <= end
        }
        if !candidates.isEmpty {
            let values = candidates.map(\.temperatureCelsius)
            return FTLTemperatureIntervalSummary(
                minimumCelsius: values.min()!,
                averageCelsius: Double(values.reduce(0, +)) / Double(values.count),
                maximumCelsius: values.max()!,
                sampleCount: values.count,
                usedNearestFallback: false
            )
        }
        let nearest = history
            .filter { $0.deviceID == deviceID }
            .min { abs($0.capturedAt.timeIntervalSince(end)) < abs($1.capturedAt.timeIntervalSince(end)) }
        guard let nearest, abs(nearest.capturedAt.timeIntervalSince(end)) <= nearestLimit else { return nil }
        return FTLTemperatureIntervalSummary(
            minimumCelsius: nearest.temperatureCelsius,
            averageCelsius: Double(nearest.temperatureCelsius),
            maximumCelsius: nearest.temperatureCelsius,
            sampleCount: 1,
            usedNearestFallback: true
        )
    }
}

/// Count, sum, minimum and maximum of temperatures. All four add up across
/// adjacent ranges, so any range's summary can be composed exactly.
struct TemperatureAggregate: Equatable, Sendable {
    var count = 0
    var sum = 0
    var minimum = Int.max
    var maximum = Int.min

    mutating func add(_ celsius: Int) {
        count += 1
        sum += celsius
        minimum = min(minimum, celsius)
        maximum = max(maximum, celsius)
    }

    mutating func add(_ other: TemperatureAggregate) {
        guard other.count > 0 else { return }
        count += other.count
        sum += other.sum
        minimum = min(minimum, other.minimum)
        maximum = max(maximum, other.maximum)
    }
}

struct NearestTemperature: Equatable, Sendable {
    let capturedAt: Date
    let celsius: Int
}

/// One device's temperatures split at its FTL snapshot times T₀ < T₁ < ….
/// `between[k]` holds the samples strictly between Tₖ₋₁ and Tₖ (`between[0]`
/// those before T₀, the last entry those after the last boundary).
struct DeviceTemperatureIntervals: Equatable, Sendable {
    private(set) var boundaries: [Date] = []
    private(set) var atBoundary: [TemperatureAggregate] = []
    private(set) var between: [TemperatureAggregate] = [TemperatureAggregate()]
    private(set) var nearestBefore: [NearestTemperature?] = []
    private(set) var nearestAfter: [NearestTemperature?] = []

    init(boundaries: [Date] = []) {
        let sorted = Array(Set(boundaries)).sorted()
        self.boundaries = sorted
        atBoundary = Array(repeating: TemperatureAggregate(), count: sorted.count)
        between = Array(repeating: TemperatureAggregate(), count: sorted.count + 1)
        nearestBefore = Array(repeating: nil, count: sorted.count)
        nearestAfter = Array(repeating: nil, count: sorted.count)
    }

    /// Index of the first boundary at or after `date`.
    private func lowerBound(_ date: Date) -> Int {
        var low = 0, high = boundaries.count
        while low < high {
            let middle = (low + high) / 2
            if boundaries[middle] < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Adds a sample in capture order (equal times keep the first one as
    /// nearest, as the reference's `min` does on a time-sorted history).
    mutating func add(_ sample: TemperatureSample) {
        let time = sample.capturedAt
        let celsius = sample.temperatureCelsius
        let index = lowerBound(time)
        if index < boundaries.count, boundaries[index] == time {
            atBoundary[index].add(celsius)
        } else {
            between[index].add(celsius)
        }
        let limit = TemperatureIntervalSummaryReference.nearestLimit
        var k = lowerBound(time.addingTimeInterval(-limit))
        while k < boundaries.count, boundaries[k] <= time.addingTimeInterval(limit) {
            updateNearest(at: k, time: time, celsius: celsius)
            k += 1
        }
    }

    private mutating func updateNearest(at k: Int, time: Date, celsius: Int) {
        let boundary = boundaries[k]
        let limit = TemperatureIntervalSummaryReference.nearestLimit
        if time <= boundary, boundary.timeIntervalSince(time) <= limit,
           nearestBefore[k].map({ time > $0.capturedAt }) ?? true {
            nearestBefore[k] = NearestTemperature(capturedAt: time, celsius: celsius)
        }
        if time >= boundary, time.timeIntervalSince(boundary) <= limit,
           nearestAfter[k].map({ time < $0.capturedAt }) ?? true {
            nearestAfter[k] = NearestTemperature(capturedAt: time, celsius: celsius)
        }
    }

    /// Adds a boundary after the last one, splitting the open last range.
    /// `samples` must hold every sample of the device after the previous
    /// boundary and from 30 minutes before `boundary`, in capture order.
    /// Returns false for a boundary that is not the newest.
    mutating func appendBoundary(_ boundary: Date, samples: [TemperatureSample]) -> Bool {
        if let last = boundaries.last {
            if boundary == last { return true }
            if boundary < last { return false }
        }
        let previous = boundaries.last
        var before = TemperatureAggregate(), at = TemperatureAggregate(), after = TemperatureAggregate()
        boundaries.append(boundary)
        nearestBefore.append(nil)
        nearestAfter.append(nil)
        let k = boundaries.count - 1
        for sample in samples {
            let time = sample.capturedAt
            if previous.map({ time > $0 }) ?? true {
                if time < boundary { before.add(sample.temperatureCelsius) }
                else if time == boundary { at.add(sample.temperatureCelsius) }
                else { after.add(sample.temperatureCelsius) }
            }
            updateNearest(at: k, time: time, celsius: sample.temperatureCelsius)
        }
        between[between.count - 1] = before
        atBoundary.append(at)
        between.append(after)
        return true
    }

    enum Lookup: Equatable {
        case covered(FTLTemperatureIntervalSummary?)
        case notCovered
    }

    /// The reference summary for `[start, end]` when both are boundaries.
    func lookup(start: Date, end: Date) -> Lookup {
        let i = lowerBound(start), j = lowerBound(end)
        guard i <= j, i < boundaries.count, boundaries[i] == start,
              j < boundaries.count, boundaries[j] == end else { return .notCovered }
        var total = atBoundary[i]
        if j > i {
            for k in (i + 1)...j {
                total.add(between[k])
                total.add(atBoundary[k])
            }
        }
        if total.count > 0 {
            return .covered(FTLTemperatureIntervalSummary(
                minimumCelsius: total.minimum,
                averageCelsius: Double(total.sum) / Double(total.count),
                maximumCelsius: total.maximum,
                sampleCount: total.count,
                usedNearestFallback: false
            ))
        }
        let candidates = [nearestBefore[j], nearestAfter[j]].compactMap { $0 }
        guard let nearest = candidates.min(by: {
            abs($0.capturedAt.timeIntervalSince(end)) < abs($1.capturedAt.timeIntervalSince(end))
        }) else { return .covered(nil) }
        return .covered(FTLTemperatureIntervalSummary(
            minimumCelsius: nearest.celsius,
            averageCelsius: Double(nearest.celsius),
            maximumCelsius: nearest.celsius,
            sampleCount: 1,
            usedNearestFallback: true
        ))
    }
}

/// Per-device interval tables, so reliability events can be given their
/// temperature without keeping temperature samples older than the window.
struct TemperatureIntervalTable: Equatable, Sendable {
    private(set) var devices: [String: DeviceTemperatureIntervals] = [:]

    /// Every FTL snapshot time per device. The analyses' FTL intervals run
    /// between some of these times, so any of them can be composed.
    static func boundaries(of snapshots: [ASPToolDiagnosticsSnapshot]) -> [String: [Date]] {
        Dictionary(grouping: snapshots.compactMap { snapshot in snapshot.deviceID.map { ($0, snapshot.capturedAt) } },
                   by: \.0).mapValues { $0.map(\.1) }
    }

    init(boundaries: [String: [Date]] = [:], samples: [TemperatureSample] = []) {
        devices = boundaries.mapValues { DeviceTemperatureIntervals(boundaries: $0) }
        for sample in samples { add(sample) }
    }

    /// Only devices with FTL snapshots need a table.
    mutating func add(_ sample: TemperatureSample) {
        devices[sample.deviceID]?.add(sample)
    }

    /// Updates the device's table in place. A rejected boundary leaves it unchanged.
    mutating func appendBoundary(deviceID: String, at boundary: Date, samples: some Sequence<TemperatureSample>) -> Bool {
        let filtered = samples.filter { $0.deviceID == deviceID }
        return devices[deviceID, default: DeviceTemperatureIntervals()].appendBoundary(boundary, samples: filtered)
    }

    func lookup(deviceID: String?, start: Date, end: Date) -> DeviceTemperatureIntervals.Lookup {
        guard let deviceID, let table = devices[deviceID] else { return .notCovered }
        return table.lookup(start: start, end: end)
    }

    func lastBoundary(deviceID: String) -> Date? {
        devices[deviceID]?.boundaries.last
    }
}
