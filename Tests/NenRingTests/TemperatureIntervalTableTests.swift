import XCTest
@testable import NenRing

final class TemperatureIntervalTableTests: XCTestCase {
    /// A small deterministic generator so failures can be reproduced.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// FTL snapshot times and temperature samples for two devices, with
    /// gaps, samples exactly at snapshot times, repeated times and ranges
    /// with no sample within 30 minutes.
    private func scenario(seed: UInt64) -> (boundaries: [String: [Date]], samples: [TemperatureSample]) {
        var random = SplitMix(state: seed)
        var boundaries: [String: [Date]] = [:]
        var samples: [TemperatureSample] = []
        for device in ["drive", "other"] {
            var time = start
            var times: [Date] = []
            for _ in 0..<120 {
                let gap: TimeInterval = [600, 900, 1_200, 3_600, 7 * 3_600, 3 * 86_400][Int.random(in: 0..<6, using: &random)]
                time = time.addingTimeInterval(gap + TimeInterval(Int.random(in: 0..<60, using: &random)))
                times.append(time)
            }
            boundaries[device] = times
            var sampleTime = start.addingTimeInterval(-3_600)
            let end = times.last!.addingTimeInterval(3_600)
            while sampleTime < end {
                let roll = Int.random(in: 0..<100, using: &random)
                if roll < 3 {
                    sampleTime = sampleTime.addingTimeInterval(TimeInterval(Int.random(in: 2...40, using: &random)) * 3_600)
                    continue
                }
                let celsius = Int.random(in: 25...70, using: &random)
                samples.append(TemperatureSample(capturedAt: sampleTime, deviceID: device, temperatureCelsius: celsius))
                if roll < 6 {
                    samples.append(TemperatureSample(capturedAt: sampleTime, deviceID: device, temperatureCelsius: celsius + 1))
                }
                sampleTime = sampleTime.addingTimeInterval(60 * TimeInterval(Int.random(in: 1...15, using: &random)))
            }
            // Samples exactly at some snapshot times.
            for time in times where Int.random(in: 0..<4, using: &random) == 0 {
                samples.append(TemperatureSample(capturedAt: time, deviceID: device, temperatureCelsius: Int.random(in: 25...70, using: &random)))
            }
        }
        samples.sort { $0.capturedAt < $1.capturedAt }
        return (boundaries, samples)
    }

    private func assertMatchesReference(_ table: TemperatureIntervalTable, boundaries: [String: [Date]],
                                        samples: [TemperatureSample], file: StaticString = #filePath, line: UInt = #line) {
        var kinds: [String: Int] = [:]
        for (device, times) in boundaries {
            let history = samples.filter { $0.deviceID == device }
            for i in times.indices {
                for j in i..<min(times.count, i + 4) {
                    let expected = TemperatureIntervalSummaryReference.summary(start: times[i], end: times[j], deviceID: device, history: history)
                    XCTAssertEqual(table.lookup(deviceID: device, start: times[i], end: times[j]), .covered(expected),
                                   "\(device) [\(i), \(j)]", file: file, line: line)
                    let kind = expected == nil ? "none" : expected!.usedNearestFallback ? "nearest" : "range"
                    kinds[kind, default: 0] += 1
                }
            }
        }
        // Every path of the reference is exercised, not only the common one.
        for kind in ["range", "nearest", "none"] {
            XCTAssertGreaterThan(kinds[kind] ?? 0, 0, "no \(kind) case", file: file, line: line)
        }
    }

    func testBatchTableMatchesTheReferenceForEveryInterval() {
        for seed: UInt64 in [1, 42] {
            let (boundaries, samples) = scenario(seed: seed)
            let table = TemperatureIntervalTable(boundaries: boundaries, samples: samples)
            assertMatchesReference(table, boundaries: boundaries, samples: samples)
        }
    }

    func testIncrementalTableMatchesTheReference() {
        for seed: UInt64 in [5, 7] {
            let (boundaries, samples) = scenario(seed: seed)
            // Replay in time order as the app does: samples arrive, and each
            // FTL snapshot adds a boundary with only the samples seen so far.
            // Ties keep the samples' order, which the reference also follows;
            // a sample at T is seen before T's boundary.
            var events: [(Date, Int, Int, TemperatureSample?, String?)] =
                samples.enumerated().map { ($1.capturedAt, 1, $0, $1, nil) }
            for (device, times) in boundaries { events += times.map { ($0, 0, 0, nil, device) } }
            events.sort { ($0.0, -$0.1, $0.2) < ($1.0, -$1.1, $1.2) }
            var table = TemperatureIntervalTable()
            var seen: [TemperatureSample] = []
            for (time, _, _, sample, device) in events {
                if let sample {
                    seen.append(sample)
                    table.add(sample)
                } else if let device {
                    let window = seen.filter { $0.deviceID == device && $0.capturedAt >= time.addingTimeInterval(-86_400 * 4) }
                    XCTAssertTrue(table.appendBoundary(deviceID: device, at: time, samples: window))
                }
            }
            assertMatchesReference(table, boundaries: boundaries, samples: samples)
        }
    }

    func testOlderBoundaryIsRejectedAndUnknownRangesAreNotCovered() {
        var table = TemperatureIntervalTable()
        XCTAssertTrue(table.appendBoundary(deviceID: "drive", at: start, samples: []))
        XCTAssertTrue(table.appendBoundary(deviceID: "drive", at: start.addingTimeInterval(600), samples: []))
        XCTAssertFalse(table.appendBoundary(deviceID: "drive", at: start.addingTimeInterval(300), samples: []))
        XCTAssertEqual(table.lookup(deviceID: "drive", start: start, end: start.addingTimeInterval(300)), .notCovered)
        XCTAssertEqual(table.lookup(deviceID: "missing", start: start, end: start.addingTimeInterval(600)), .notCovered)
        XCTAssertEqual(table.lookup(deviceID: "drive", start: start, end: start.addingTimeInterval(600)), .covered(nil))
    }

    func testStoreTrimsMemoryButKeepsEventTemperaturesAndTheDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("interval-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("temperature-history.jsonl")
        var samples: [TemperatureSample] = []
        for minute in stride(from: 0, to: 60 * 24 * 60, by: 10) {
            samples.append(TemperatureSample(capturedAt: start.addingTimeInterval(Double(minute) * 60), deviceID: "drive",
                                             temperatureCelsius: 30 + minute % 37))
        }
        // Written as an older history file; the store adopts it on load.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try samples.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let store = TemperatureHistoryStore(fileURL: fileURL)
        var boundaries = stride(from: 3.0, to: 59 * 24, by: 7.5).map { start.addingTimeInterval($0 * 3_600) }
        try await store.prepareIntervals(boundaries: ["drive": boundaries])
        let now = samples.last!.capturedAt
        try await store.trimToWindow(now: now)

        func assertTable(_ label: String) async throws {
            let input = try await store.analysisInput()
            let table = try XCTUnwrap(input.table)
            for (i, j) in zip(boundaries.indices, boundaries.indices.dropFirst()) {
                XCTAssertEqual(table.lookup(deviceID: "drive", start: boundaries[i], end: boundaries[j]),
                               .covered(TemperatureIntervalSummaryReference.summary(start: boundaries[i], end: boundaries[j],
                                                                                    deviceID: "drive", history: samples)), label)
            }
        }
        let trimmed = try await store.analysisInput().samples
        XCTAssertLessThan(trimmed.count, samples.count)
        XCTAssertTrue(trimmed.allSatisfy { $0.capturedAt >= now.addingTimeInterval(-TemperatureHistoryStore.memoryWindow) })
        try await assertTable("after trim")

        // A new FTL snapshot splits the open range from the samples in memory.
        for minute in 1...12 {
            let sample = TemperatureSample(capturedAt: now.addingTimeInterval(Double(minute) * 600), deviceID: "drive", temperatureCelsius: 41 + minute)
            samples.append(sample)
            _ = try await store.appendIfNew(sample)
        }
        boundaries.append(now.addingTimeInterval(3_600))
        try await store.addIntervalBoundary(deviceID: "drive", at: boundaries.last!)
        try await assertTable("new boundary")

        // An older time (an imported log) rebuilds the table from disk.
        let older = start.addingTimeInterval(5 * 3_600)
        boundaries.append(older)
        boundaries.sort()
        try await store.addIntervalBoundary(deviceID: "drive", at: older)
        try await assertTable("rebuilt")
        let afterRebuild = try await store.analysisInput().samples
        XCTAssertLessThan(afterRebuild.count, samples.count, "memory is trimmed again after the rebuild")

        // The stored history is unchanged.
        let reloaded = try await TemperatureHistoryStore(fileURL: fileURL).records()
        XCTAssertEqual(reloaded.map(\.id), samples.map(\.id))
    }

    /// Opt-in: the whole analysis from a copy of local history is the same
    /// with all temperatures and with the 35-day window plus the table.
    func testOptInLocalHistoryAnalysisIsUnchangedByTheTable() async throws {
        guard let path = ProcessInfo.processInfo.environment["NENRING_LOCAL_HISTORY_DIR"] else {
            throw XCTSkip("Local private history is read only with an explicit opt-in path")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("interval-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        let history = try await HistoryStore(fileURL: copy.appendingPathComponent("history.jsonl")).records()
        let ftl = try await ASPToolSnapshotStore(fileURL: copy.appendingPathComponent("asptool-snapshots.jsonl")).records()
        let store = TemperatureHistoryStore(fileURL: copy.appendingPathComponent("temperature-history.jsonl"))
        let all = try await store.records()
        let latest = try XCTUnwrap(history.max { $0.capturedAt < $1.capturedAt })
        let now = latest.capturedAt
        try await store.prepareIntervals(boundaries: TemperatureIntervalTable.boundaries(of: ftl))
        try await store.trimToWindow(now: now)
        let input = try await store.analysisInput()
        func analysis(_ temperatures: [TemperatureSample], _ table: TemperatureIntervalTable?) -> DashboardAnalyticsSnapshot {
            DashboardAnalyticsSnapshot.build(analyzer: HistoryAnalyzer(), history: history, temperatureHistory: temperatures,
                deviceID: latest.deviceID, period: .day, profile: nil, settings: UsageSettings(), now: now,
                asptoolSnapshots: ftl, temperatureTable: table)
        }
        XCTAssertEqual(analysis(input.samples, input.table), analysis(all, nil))
    }
}
