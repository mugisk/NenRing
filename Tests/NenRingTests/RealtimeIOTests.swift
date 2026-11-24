import XCTest
import SwiftUI
import AppKit
@testable import NenRing

final class RealtimeIOTests: XCTestCase {
    private func counters(_ r: UInt64, _ w: UInt64, driver: UInt64 = 1, boot: TimeInterval = 1) -> BlockIOCounters {
        BlockIOCounters(bytesRead: r, bytesWritten: w, bootTime: Date(timeIntervalSince1970: boot), driverID: driver)
    }

    func testActualElapsedAndTotalsNotAverageOfRates() {
        var data = RealtimeIOAccumulator()
        data.ingest(counters(100, 100), at: 10, maximumGap: 6)
        XCTAssertNil(data.latest)
        data.ingest(counters(1100, 2100), at: 12.5, maximumGap: 6)
        XCTAssertEqual(data.latest?.readRate, 400)
        XCTAssertEqual(data.latest?.writeRate, 800)
        data.ingest(counters(1200, 2200), at: 13.5, maximumGap: 6)
        let total = data.total(seconds: 300, at: 13.5)
        XCTAssertEqual(total.read, 1100)
        XCTAssertEqual(total.written, 2100)
        XCTAssertEqual(total.coverage, 3.5)
    }

    func testFailureSleepResetDriverAndBootDoNotBecomeSpikes() {
        var data = RealtimeIOAccumulator()
        data.ingest(counters(100, 100), at: 0, maximumGap: 6)
        data.ingest(counters(200, 200), at: 2, maximumGap: 6)
        data.ingest(nil, at: 4, maximumGap: 6)
        data.ingest(counters(900, 900), at: 6, maximumGap: 6)
        XCTAssertNil(data.latest)
        data.ingest(counters(5000, 5000), at: 50, maximumGap: 6)
        XCTAssertNil(data.latest)
        data.ingest(counters(10, 10), at: 52, maximumGap: 6)
        XCTAssertNil(data.latest)
        data.ingest(counters(100, 100, driver: 2), at: 54, maximumGap: 6)
        XCTAssertNil(data.latest)
        data.ingest(counters(200, 200, driver: 2, boot: 2), at: 56, maximumGap: 6)
        XCTAssertNil(data.latest)
        data.interrupt()
        data.ingest(counters(300, 300, driver: 2, boot: 2), at: 58, maximumGap: 6)
        XCTAssertNil(data.latest)
        XCTAssertEqual(data.sessionWritten, 100)
    }

    func testBoundedWindowAndCoverageWithMissingIntervals() {
        var data = RealtimeIOAccumulator()
        for t in 0...3600 {
            data.ingest(counters(UInt64(t * 100), UInt64(t * 200)), at: Double(t), maximumGap: 3)
        }
        XCTAssertLessThanOrEqual(data.intervals.count, 301)
        let total = data.total(seconds: 300, at: 3600.5)
        XCTAssertEqual(total.coverage, 299.5)
        XCTAssertEqual(total.read, 29_950)
        XCTAssertEqual(data.sessionWritten, 720_000)
        data.ingest(nil, at: 4000, maximumGap: 3)
        XCTAssertTrue(data.intervals.isEmpty)
    }

    func testUInt64BoundaryAndCounterReset() {
        var data = RealtimeIOAccumulator()
        data.ingest(counters(.max - 10, .max - 20), at: 0, maximumGap: 3)
        data.ingest(counters(.max, .max), at: 1, maximumGap: 3)
        XCTAssertEqual(data.latest?.read, 10)
        data.ingest(counters(0, 0), at: 2, maximumGap: 3)
        XCTAssertNil(data.latest)
        XCTAssertEqual(data.sessionRead, 10)
    }

    func testSplittingIntervalsPreservesBytesAndCoverage() {
        var dense = RealtimeIOAccumulator(), sparse = RealtimeIOAccumulator()
        for t in 0...300 {
            dense.ingest(counters(UInt64(t * 100), UInt64(t * 200)), at: Double(t), maximumGap: 3)
            if t.isMultiple(of: 5) {
                sparse.ingest(counters(UInt64(t * 100), UInt64(t * 200)), at: Double(t), maximumGap: 15)
            }
        }
        let a = dense.total(seconds: 60, at: 300)
        let b = sparse.total(seconds: 60, at: 300)
        XCTAssertEqual(a.read, b.read)
        XCTAssertEqual(a.written, b.written)
        XCTAssertEqual(a.coverage, b.coverage)
        XCTAssertEqual(dense.sessionWritten, sparse.sessionWritten)
    }

    func testLegacyCountersDecodeWithoutDriverIdentity() throws {
        let data = Data(#"{"bytesRead":1,"bytesWritten":2,"bootTime":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(BlockIOCounters.self, from: data).driverID)
    }

    func testOptInLiveDriverCounters() async throws {
        guard let path = ProcessInfo.processInfo.environment["NENRING_REALTIME_DEVICE_PATH"] else {
            throw XCTSkip("Live read requires an explicitly selected device")
        }
        let provider = IOKitBlockIOStatisticsProvider()
        let before = try XCTUnwrap(provider.counters(devicePath: path))
        try await Task.sleep(for: .milliseconds(100))
        let after = try XCTUnwrap(provider.counters(devicePath: path))
        XCTAssertEqual(before.driverID, after.driverID)
        XCTAssertNotNil(after.driverID)
        XCTAssertEqual(before.bootTime, after.bootTime)
        XCTAssertGreaterThanOrEqual(after.bytesRead, before.bytesRead)
        XCTAssertGreaterThanOrEqual(after.bytesWritten, before.bytesWritten)
        provider.invalidate()
        XCTAssertEqual(provider.counters(devicePath: path)?.driverID, after.driverID)
    }

    @MainActor
    func testMenuBarDisplayOffByDefaultAndPreferencesRoundTrip() throws {
        let name = "RealtimeIOTests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let monitor = RealtimeIOMonitor(preferences: preferences)
        XCTAssertFalse(monitor.showsInMenuBar)
        XCTAssertEqual(monitor.interval, 2)
        monitor.interval = 5
        monitor.display = .write
        monitor.showsInMenuBar = true
        let restored = RealtimeIOMonitor(preferences: preferences)
        XCTAssertTrue(restored.showsInMenuBar)
        XCTAssertEqual(restored.interval, 5)
        XCTAssertEqual(restored.display, .write)
        XCTAssertTrue(restored.data.intervals.isEmpty)
    }

    @MainActor
    func testLifecycleStopsReadsAndTargetChangeClearsTotals() async throws {
        let name = "RealtimeIOLifecycle-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let provider = PreviewIOProvider()
        let monitor = RealtimeIOMonitor(preferences: preferences, provider: provider)
        // Sampling does not depend on the menu bar display.
        XCTAssertFalse(monitor.showsInMenuBar)
        monitor.configure(deviceID: "A", path: "/dev/a", active: true)
        try await Task.sleep(for: .milliseconds(50))
        await monitor.poll()
        XCTAssertGreaterThan(monitor.data.sessionRead, 0)
        monitor.configure(deviceID: "A", path: "/dev/a", active: false)
        let count = provider.readCount
        await monitor.poll()
        XCTAssertEqual(provider.readCount, count)
        XCTAssertNil(monitor.data.latest)
        monitor.configure(deviceID: "B", path: "/dev/b", active: false)
        XCTAssertEqual(monitor.data.sessionRead, 0)
        XCTAssertTrue(monitor.data.intervals.isEmpty)
        monitor.configure(deviceID: nil, path: "/dev/b", active: true)
        await monitor.poll()
        XCTAssertEqual(provider.readCount, count)
    }

    @MainActor
    func testAdaptiveRateUnitsDoNotRoundSmallWritesToZeroGB() {
        XCTAssertEqual(RealtimeIOMonitor.rate(830_000), "830.0 kB/s")
        XCTAssertEqual(RealtimeIOMonitor.rate(12_400_000), "12.4 MB/s")
        XCTAssertEqual(RealtimeIOMonitor.rate(0), "0 B/s")
        XCTAssertEqual(RealtimeIOMonitor.rate(nil), "—")
        XCTAssertEqual(RealtimeIOMonitor.rate(.infinity), "—")
    }

    @MainActor
    func testOptInRealtimePreview() async throws {
        guard let root = ProcessInfo.processInfo.environment["NENRING_REALTIME_PREVIEW_ROOT"] else {
            throw XCTSkip("Preview requires an explicit output directory")
        }
        var data = RealtimeIOAccumulator()
        let now = ProcessInfo.processInfo.systemUptime
        var read: UInt64 = 0, written: UInt64 = 0
        for i in 0...150 {
            read += UInt64(1_000_000 + (sin(Double(i) / 8) + 1) * 12_000_000)
            written += i.isMultiple(of: 29) ? 24_000_000 : 200_000
            data.ingest(counters(read, written), at: now - 300 + Double(i * 2), maximumGap: 6)
        }
        let directory = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = NSHostingView(rootView: RealtimeIOContent(data: data)
                .padding(14).frame(width: 320).background(AppColor.canvas).preferredColorScheme(scheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = window.contentLayoutRect
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("realtime-\(name).png"))
        }
    }
}

private final class PreviewIOProvider: BlockIOStatisticsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    var readCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func counters(devicePath: String) -> BlockIOCounters? {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return BlockIOCounters(bytesRead: count * 12_000_000, bytesWritten: count * 800_000,
                               bootTime: Date(timeIntervalSince1970: 1), driverID: 1)
    }
}
