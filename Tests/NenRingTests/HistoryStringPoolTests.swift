import XCTest
@testable import NenRing

final class HistoryStringPoolTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Builds the string at run time so equal values start in separate allocations.
    private func fresh(_ value: String) -> String { String(decoding: Array(value.utf8), as: UTF8.self) }
    private func storage(_ value: String?) -> UnsafeRawPointer? {
        let pointer = value?.utf8.withContiguousStorageIfAvailable { UnsafeRawPointer($0.baseAddress!) } ?? nil
        XCTAssertNotNil(pointer, "the comparison needs a native string allocation")
        return pointer
    }

    func testStoresShareEqualStringsAndKeepValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = "model:APPLE SSD AP0256Q:capacity-256000000000"
        let path = "IOService:/AppleARMPE/arm-io@10F00000/AppleT810xIO/ans@77400000/NS_01@1"

        let temperatureURL = directory.appendingPathComponent("temperature-history.jsonl")
        let temperatures = TemperatureHistoryStore(fileURL: temperatureURL)
        for minute in 0..<3 {
            _ = try await temperatures.appendIfNew(TemperatureSample(capturedAt: start.addingTimeInterval(Double(minute) * 60),
                                                                     deviceID: fresh(device), temperatureCelsius: 36))
        }
        let samples = try await temperatures.records()
        XCTAssertEqual(Set(samples.map { storage($0.deviceID) }).count, 1)

        let historyURL = directory.appendingPathComponent("history.jsonl")
        let history = HistoryStore(fileURL: historyURL)
        for hour in 0..<3 {
            _ = try await history.appendIfNew(DriveSnapshot(capturedAt: start.addingTimeInterval(Double(hour) * 3_600),
                deviceID: fresh(device), devicePath: fresh(path), model: fresh("APPLE SSD AP0256Q"), serialNumber: fresh("fixture-serial-0001"),
                firmware: "591", smartctlVersion: "7.4", smartctlExitStatus: 0, temperatureCelsius: 36, powerOnHours: UInt64(hour),
                powerCycleCount: 1, unsafeShutdowns: 0, percentageUsed: 5, availableSpare: 100, availableSpareThreshold: 10,
                criticalWarning: 0, mediaAndDataIntegrityErrors: 0, dataUnitsRead: UInt64(hour), dataUnitsWritten: UInt64(hour), smartPassed: true))
        }
        let snapshots = try await history.records()
        XCTAssertEqual(snapshots.count, 3)
        for field in [\DriveSnapshot.devicePath, \DriveSnapshot.deviceID] {
            XCTAssertEqual(Set(snapshots.map { storage($0[keyPath: field]) }).count, 1)
        }
        XCTAssertEqual(Set(snapshots.map { storage($0.serialNumber) }).count, 1)

        // Reloading from disk gives the same records: only memory is shared.
        let reloadedSamples = try await TemperatureHistoryStore(fileURL: temperatureURL).records()
        let reloadedSnapshots = try await HistoryStore(fileURL: historyURL).records()
        XCTAssertEqual(reloadedSamples, samples)
        XCTAssertEqual(reloadedSnapshots, snapshots)
        XCTAssertEqual(Set(reloadedSamples.map { storage($0.deviceID) }).count, 1)
    }

    func testFTLStoreSharesDeviceAndContractStrings() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("pool-ftl-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = ASPToolSnapshotStore(fileURL: fileURL)
        for day in 1...3 {
            _ = try await store.appendIfNew(ASPToolDiagnosticsSnapshot(
                capturedAt: start.addingTimeInterval(Double(day) * 86_400), deviceID: fresh("model:APPLE SSD AP0256Q:capacity"),
                hostWrites: UInt64(day)))
        }
        let records = try await store.records()
        XCTAssertEqual(Set(records.map { storage($0.deviceID) }).count, 1)
    }

    func testFTLHistogramsAreKeptAtExactCapacityWithTheSameValues() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("exact-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var spare: [UInt64] = []
        spare.reserveCapacity(64)
        spare.append(contentsOf: (0..<30).map { UInt64($0) })
        let telemetry = FTLResearchTelemetrySnapshot(nandReads: 1, ageRefreshPerTier: [1, 2, 3], backgroundRefreshMoves: 1,
            bandsPaddedForAge: 0, crossTemperatureUECC: 0, utilityUECCReads: 0, ueccReads: 0, readVerifyNative: 0,
            reducedReadVerifyNative: 0, readVerifySLC: 0, directToTLCBands: 0, directToTLCSectors: 0, fallbackToWaterfall: 0,
            nonProportionalDirectToTLCSectors: 0, raidVerificationReads: 0, crossTemperatureRaidUECC: 0,
            hostSLCReadVerifyFailures: 0, hostTLCReadVerifyFailures: 0, gcSLCToTLCReadVerifyFailures: 0,
            gcTLCToTLCReadVerifyFailures: 0, bandsMaxTempHistogram: spare, bandsMinTempHistogram: spare,
            bandsLifetimeTempHistogram: spare, bandsDeltaTempHistogram: spare, bandsCrossTempHistogram: spare)
        XCTAssertGreaterThan(spare.capacity, spare.count)
        let snapshot = ASPToolDiagnosticsSnapshot(capturedAt: start, deviceID: "drive", hostWrites: 1, researchTelemetry: telemetry)
        let store = ASPToolSnapshotStore(fileURL: fileURL)
        _ = try await store.appendIfNew(snapshot)
        for records in [try await store.records(), try await ASPToolSnapshotStore(fileURL: fileURL).records()] {
            let stored = try XCTUnwrap(records.first?.researchTelemetry)
            XCTAssertEqual(stored, telemetry, "values are unchanged")
            for histogram in [stored.bandsMaxTempHistogram, stored.bandsCrossTempHistogram, stored.ageRefreshPerTier] {
                let values = try XCTUnwrap(histogram)
                // The reserved spare (64) is gone; what remains is the
                // allocator's size-class rounding.
                XCTAssertLessThanOrEqual(values.capacity, values.count + 8)
            }
        }
    }
}
