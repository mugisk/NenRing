import XCTest
@testable import NenRing

final class BlockIOStatisticsTests: XCTestCase {
    func testTemperatureSampleKeepsBlockIOCountersAndReadsOlderSamples() throws {
        let boot = Date(timeIntervalSince1970: 1_791_909_533)
        let counters = BlockIOCounters(bytesRead: 4_151_056_904_192, bytesWritten: 800_350_416_896, bootTime: boot)
        let samples = (0..<3).map { index in
            TemperatureSample(capturedAt: boot.addingTimeInterval(Double(index) * 60), deviceID: "drive",
                              temperatureCelsius: 36,
                              blockIO: BlockIOCounters(bytesRead: counters.bytesRead + UInt64(index) * 4_096,
                                                       bytesWritten: counters.bytesWritten, bootTime: boot))
        }
        // Lossless blocks share the boot time and keep every counter value.
        let block = try LosslessHistoryBlock.encode(samples)
        XCTAssertEqual(try LosslessHistoryBlock.decode(block, as: TemperatureSample.self), samples)

        // A sample saved before the field existed still decodes.
        let legacy = Data(#"{"id":"6A4C1C0E-4D8B-4C55-9C3A-2B7E1A0F0E11","capturedAt":"2026-10-01T00:00:00Z","deviceID":"drive","temperatureCelsius":35}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(TemperatureSample.self, from: legacy).blockIO)
    }

    func testUnknownDevicePathYieldsNoCounters() {
        let provider = IOKitBlockIOStatisticsProvider()
        XCTAssertNil(provider.counters(devicePath: "/dev/disk999"))
        XCTAssertNil(provider.counters(devicePath: "IOService:/NoSuchEntry"))
        XCTAssertNil(provider.counters(devicePath: "not a device"))
    }
}
