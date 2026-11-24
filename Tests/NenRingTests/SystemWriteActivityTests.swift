import XCTest
@testable import NenRing

final class SystemWriteActivityTests: XCTestCase {
    func testIntervalRatesExcludeReusedPIDsAndCounterResets() throws {
        let old = SystemWriteActivity(uptime: 10, writers: [
            1: .init(start: 10, bytes: 200, name: "writer"),
            2: .init(start: 20, bytes: 100, name: "old"),
            3: .init(start: 30, bytes: 300, name: "reset")
        ], swapPages: 100)
        let new = SystemWriteActivity(uptime: 15, writers: [
            1: .init(start: 10, bytes: 250, name: "writer"),
            2: .init(start: 25, bytes: 900, name: "new"),
            3: .init(start: 30, bytes: 1, name: "reset")
        ], swapPages: 110)
        let rates = try XCTUnwrap(new.rates(since: old))
        XCTAssertEqual(rates.writers.map(\.name), ["writer"])
        XCTAssertEqual(rates.writers.first?.rate, 10)
        XCTAssertEqual(rates.swap, 2 * Double(getpagesize()))
        XCTAssertNil(old.rates(since: new))
    }
    func testBurstRemainsAfterExitAndExpiresAfterThirtySeconds() {
        func sample(_ t: Double, _ bytes: UInt64?) -> SystemWriteActivity {
            var writers: [Int32: SystemWriteActivity.Writer] = [1: .init(start: 1, bytes: 0, name: "idle")]
            if let bytes { writers[2] = .init(start: 2, bytes: bytes, name: "burst") }
            return .init(uptime: t, writers: writers, swapPages: nil)
        }
        var window = RecentWriteActivity()
        var old = sample(0, 0)
        for t in stride(from: 5, through: 35, by: 5) {
            let next = sample(Double(t), t == 5 ? 300 : nil)
            let result = window.ingest(next, after: old)
            XCTAssertEqual(result?.writers.first?.rate, t < 35 ? 300 / Double(t) : nil)
            old = next
        }
    }
}
