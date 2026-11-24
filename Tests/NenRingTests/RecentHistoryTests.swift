import XCTest
@testable import NenRing

final class RecentHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    func testChartKeepsOldDailyTemperaturesAfterMemoryTrim() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemperatureHistoryStore(fileURL: directory.appendingPathComponent("temperature-history.jsonl"))
        for day in 0..<65 {
            for hour in [0, 12] {
                let date = start.addingTimeInterval(Double(day * 24 + hour) * 3_600)
                _ = try await store.appendIfNew(TemperatureSample(capturedAt: date, deviceID: "drive", temperatureCelsius: hour == 0 ? 30 : 40))
            }
        }
        let now = start.addingTimeInterval(65 * 86_400)
        let cutoff = Calendar.current.startOfDay(for: now.addingTimeInterval(-30 * 86_400))
        try await store.prepareIntervals(boundaries: [:])
        let before = try await store.olderChartPoints(deviceID: "drive", before: cutoff)
        try await store.trimToWindow(now: now)
        let after = try await store.olderChartPoints(deviceID: "drive", before: cutoff)
        XCTAssertEqual(before, after)
        XCTAssertGreaterThan(after.count, 30)
        XCTAssertTrue(after.contains { $0.celsius == 35 })
        let other = try await store.olderChartPoints(deviceID: "other", before: cutoff)
        XCTAssertTrue(other.isEmpty)
    }

    func testWriteChartKeepsMoreThanThirtyDailyBuckets() {
        let samples = (0...65).map { day in
            DriveSnapshot(capturedAt: start.addingTimeInterval(Double(day) * 86_400), deviceID: "drive", devicePath: "p", model: nil, serialNumber: nil,
                firmware: nil, smartctlVersion: nil, smartctlExitStatus: 0, temperatureCelsius: nil, powerOnHours: nil,
                powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: nil, availableSpare: nil, availableSpareThreshold: nil,
                criticalWarning: nil, mediaAndDataIntegrityErrors: nil, dataUnitsRead: nil, dataUnitsWritten: UInt64(day * 10), smartPassed: nil)
        }
        let points = HistoryAnalyzer().writePoints(from: samples, deviceID: "drive", period: .day, now: samples.last!.capturedAt)
        XCTAssertGreaterThan(points.count, 60)
        XCTAssertEqual(points.reduce(0) { $0 + $1.bytes }, 650 * HistoryAnalyzer.bytesPerNVMeDataUnit, accuracy: 1)
    }

    func testRecentChartMatchesTheFullScan() {
        // Capture order with SMART readings and thermal polls seconds apart.
        var samples: [TemperatureSample] = []
        for minute in 0..<(45 * 24 * 60 / 7) {
            let jitter = minute.isMultiple(of: 11) ? -20.0 : 0
            samples.append(TemperatureSample(capturedAt: start.addingTimeInterval(Double(minute) * 420 + jitter),
                                             deviceID: minute.isMultiple(of: 97) ? "other" : "drive",
                                             temperatureCelsius: 30 + minute % 15))
        }
        let now = samples.last!.capturedAt
        let cutoff = Calendar.current.startOfDay(for: now.addingTimeInterval(-30 * 86_400))
        let expected = samples.filter { $0.deviceID == "drive" && $0.capturedAt >= cutoff }
            .sorted { $0.capturedAt < $1.capturedAt }
            .map { TemperaturePoint(date: $0.capturedAt, celsius: Double($0.temperatureCelsius)) }
        XCTAssertEqual(HistoryAnalyzer().temperaturePoints(from: samples, deviceID: "drive", now: now), expected)
        let suffix = HistoryAnalyzer.recentSuffix(of: samples, since: cutoff, capturedAt: \.capturedAt)
        XCTAssertLessThan(suffix.count, samples.count)
        XCTAssertTrue(samples[..<suffix.startIndex].allSatisfy { $0.capturedAt < cutoff })
    }

    func testRecentWindowAndChartFallbackMatchTheFullHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TemperatureHistoryStore(fileURL: directory.appendingPathComponent("temperature-history.jsonl"))
        let empty = try await store.recentRecords(since: start)
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertFalse(empty.hasAny)
        for day in 0..<40 {
            _ = try await store.appendIfNew(TemperatureSample(capturedAt: start.addingTimeInterval(Double(day) * 86_400),
                                                              deviceID: "drive", temperatureCelsius: 30 + day % 5))
        }
        let all = try await store.records()
        let now = all.last!.capturedAt
        let cutoff = Calendar.current.startOfDay(for: now.addingTimeInterval(-30 * 86_400))
        let recent = try await store.recentRecords(since: cutoff)
        XCTAssertTrue(recent.hasAny)
        XCTAssertEqual(recent.records, all.filter { $0.capturedAt >= cutoff.addingTimeInterval(-86_400) })

        // The chart from the window equals the chart from the full history.
        let smart = [DriveSnapshot(capturedAt: now, deviceID: "drive", devicePath: "p", model: nil, serialNumber: nil,
            firmware: nil, smartctlVersion: nil, smartctlExitStatus: 0, temperatureCelsius: 50, powerOnHours: nil,
            powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: nil, availableSpare: nil, availableSpareThreshold: nil,
            criticalWarning: nil, mediaAndDataIntegrityErrors: nil, dataUnitsRead: nil, dataUnitsWritten: nil, smartPassed: nil)]
        var fromWindow = DashboardAnalyticsSnapshot.empty
        fromWindow.updateTemperatureChart(analyzer: HistoryAnalyzer(), history: smart, temperatureHistory: recent.records,
                                          hasTemperatureHistory: recent.hasAny, deviceID: "drive", now: now)
        var fromAll = DashboardAnalyticsSnapshot.empty
        fromAll.updateTemperatureChart(analyzer: HistoryAnalyzer(), history: smart, temperatureHistory: all,
                                       deviceID: "drive", now: now)
        XCTAssertEqual(fromWindow.temperaturePoints, fromAll.temperaturePoints)
        // With samples only older than the window, the chart stays empty
        // rather than switching to SMART temperatures, as with the full history.
        var stale = DashboardAnalyticsSnapshot.empty
        stale.updateTemperatureChart(analyzer: HistoryAnalyzer(), history: smart, temperatureHistory: [],
                                     hasTemperatureHistory: true, deviceID: "drive", now: now.addingTimeInterval(60 * 86_400))
        var staleAll = DashboardAnalyticsSnapshot.empty
        staleAll.updateTemperatureChart(analyzer: HistoryAnalyzer(), history: smart, temperatureHistory: all,
                                        deviceID: "drive", now: now.addingTimeInterval(60 * 86_400))
        XCTAssertEqual(stale.temperaturePoints, staleAll.temperaturePoints)
    }

    func testTemperatureStoreStillRejectsNearDuplicatesAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("temperature-history.jsonl")
        let store = TemperatureHistoryStore(fileURL: fileURL)
        let first = TemperatureSample(capturedAt: start, deviceID: "drive", temperatureCelsius: 36)
        let appendedFirst = try await store.appendIfNew(first)
        let duplicate = try await store.appendIfNew(TemperatureSample(capturedAt: start.addingTimeInterval(3), deviceID: "drive", temperatureCelsius: 36))
        let otherDevice = try await store.appendIfNew(TemperatureSample(capturedAt: start.addingTimeInterval(3), deviceID: "other", temperatureCelsius: 36))
        let next = try await store.appendIfNew(TemperatureSample(capturedAt: start.addingTimeInterval(60), deviceID: "drive", temperatureCelsius: 37))
        XCTAssertEqual([appendedFirst, duplicate, otherDevice, next], [true, false, true, true])

        let reloaded = TemperatureHistoryStore(fileURL: fileURL)
        let repeated = try await reloaded.appendIfNew(TemperatureSample(capturedAt: start.addingTimeInterval(62), deviceID: "drive", temperatureCelsius: 37))
        XCTAssertFalse(repeated, "the latest time is rebuilt from the loaded history")
        let records = try await reloaded.records()
        XCTAssertEqual(records.count, 3)
    }
}
