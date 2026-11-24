import Foundation
import XCTest
@testable import NenRing

final class LosslessHistoryStorageTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_788_220_800)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LosslessHistory-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func ftl(_ index: Int) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(capturedAt: start.addingTimeInterval(Double(index) * 3_600 + 0.125),
            deviceID: index % 3 == 0 ? "second-device" : "drive", sourceArtifact: .directFTL,
            sourceBuild: index < 270 ? "25G83" : "26A100", contractBuild: "25G83",
            hostWrites: UInt64.max - UInt64(1_000 - index), nandWrites: UInt64(index * 200),
            hostWritesUnitState: .provisional4KiB, nandWritesUnitState: .provisional4KiB,
            tlcAveragePE: Double(index / 72), tlcEOLPE: 3_000,
            slcAveragePE: Double(index * 10), slcEOLPE: 100_000,
            firmware: index < 260 ? "561" : nil,
            grownBadBlocks: index > 280 ? 1 : 0,
            parseWarnings: [String(repeating: "取得元と単位の研究上の説明。", count: 20)])
    }

    func testBlockSharesRepeatedMetadataWithoutRoundingAnyObservation() throws {
        let original = (0..<200).map(ftl)
        let block = try LosslessHistoryBlock.encode(original)
        XCTAssertEqual(try LosslessHistoryBlock.decode(block, as: ASPToolDiagnosticsSnapshot.self), original)
        let full = try JSONEncoder().encode(original)
        XCTAssertLessThan(block.count, full.count / 2, "repeated warnings and metadata are stored once")
        let mixed = (250..<300).map(ftl)
        XCTAssertEqual(try LosslessHistoryBlock.decode(LosslessHistoryBlock.encode(mixed), as: ASPToolDiagnosticsSnapshot.self), mixed,
            "missing firmware, zero counters, build boundaries and UInt64 above 2^53 remain distinct")
    }

    func testSegmentsKeepEveryObservationAndOnlyRewriteTheSmallTail() throws {
        let url = directory.appendingPathComponent("ftl.jsonl")
        var storage = LosslessHistoryStorage<ASPToolDiagnosticsSnapshot>(fileURL: url)
        XCTAssertTrue(try storage.load().isEmpty)
        let original = (0..<600).map(ftl)
        for record in original { try storage.append(record) }
        let segmentNames = try FileManager.default.contentsOfDirectory(atPath: storage.directoryURL.path).filter { $0.hasSuffix("lzfse") }
        XCTAssertEqual(segmentNames.count, 2)
        let firstURL = storage.directoryURL.appendingPathComponent(segmentNames.sorted()[0])
        let firstBytes = try Data(contentsOf: firstURL)
        let firstDate = try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var reopened = LosslessHistoryStorage<ASPToolDiagnosticsSnapshot>(fileURL: url)
        XCTAssertEqual(try reopened.load(), original)
        let next = ftl(600)
        try reopened.append(next)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, firstDate)
        XCTAssertLessThan(try Data(contentsOf: url).split(separator: 0x0A).count, 256)
        var again = LosslessHistoryStorage<ASPToolDiagnosticsSnapshot>(fileURL: url)
        XCTAssertEqual(try again.load(), original + [next])
    }

    func testCrashBetweenPublishingSegmentAndClearingTailDoesNotDoubleCount() throws {
        let url = directory.appendingPathComponent("temperature.jsonl")
        let samples = (0..<256).map { TemperatureSample(capturedAt: start.addingTimeInterval(Double($0 * 60)), deviceID: "d", temperatureCelsius: 35) }
        var storage = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        _ = try storage.load()
        for sample in samples { try storage.append(sample) }
        let beforeSeal = try Data(contentsOf: url)
        let next = TemperatureSample(capturedAt: start.addingTimeInterval(256 * 60), deviceID: "d", temperatureCelsius: 36)
        try storage.append(next)
        // Restore the tail as it could exist immediately after a committed
        // segment and before the atomic tail reset.
        try beforeSeal.write(to: url)
        var reopened = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        XCTAssertEqual(try reopened.load(), samples)
        try reopened.append(next)
        var final = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        XCTAssertEqual(try final.load(), samples + [next])
    }

    func testCorruptSegmentStopsLoadingWithoutRepairingAwayEvidence() throws {
        let url = directory.appendingPathComponent("temperature.jsonl")
        var storage = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        _ = try storage.load()
        for index in 0..<257 {
            try storage.append(TemperatureSample(capturedAt: start.addingTimeInterval(Double(index)), deviceID: "d", temperatureCelsius: 30))
        }
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: storage.directoryURL.path).first { $0.hasSuffix("lzfse") })
        let damagedURL = storage.directoryURL.appendingPathComponent(name)
        let wrong = try (Data("{}".utf8) as NSData).compressed(using: .lzfse) as Data
        try wrong.write(to: damagedURL)
        let tail = try Data(contentsOf: url)
        var reopened = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        XCTAssertThrowsError(try reopened.load())
        XCTAssertEqual(try Data(contentsOf: url), tail)
        XCTAssertEqual(try Data(contentsOf: damagedURL), wrong)
    }

    private func damageFirstSegment(in segments: URL) throws -> (url: URL, original: Data) {
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: segments.path)
            .sorted().first { $0.hasSuffix(".json.lzfse") })
        let url = segments.appendingPathComponent(name)
        let original = try Data(contentsOf: url)
        try ((Data("{}".utf8) as NSData).compressed(using: .lzfse) as Data).write(to: url)
        return (url, original)
    }

    func testUnreadableSegmentStillKeepsNewObservationsAndRecoversThemAll() async throws {
        let url = directory.appendingPathComponent("temperature-history.jsonl")
        let sample = { (index: Int) in
            TemperatureSample(capturedAt: self.start.addingTimeInterval(Double(index) * 60), deviceID: "d", temperatureCelsius: 30)
        }
        let originals = (0..<300).map(sample)
        let store = TemperatureHistoryStore(fileURL: url)
        for item in originals { _ = try await store.appendIfNew(item) }

        var storage = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        _ = try storage.load()
        let damaged = try damageFirstSegment(in: storage.directoryURL)
        let manifestURL = storage.directoryURL.appendingPathComponent("manifest.json")
        let manifest = try Data(contentsOf: manifestURL)
        let segments = try FileManager.default.contentsOfDirectory(atPath: storage.directoryURL.path).sorted()

        // More than one block's worth: nothing may be sealed without the manifest.
        let later = (300..<900).map(sample)
        let reopened = TemperatureHistoryStore(fileURL: url)
        for item in later {
            let accepted = try await reopened.appendIfNew(item)
            XCTAssertTrue(accepted)
        }
        let duplicate = TemperatureSample(capturedAt: start.addingTimeInterval(899 * 60 + 1), deviceID: "d", temperatureCelsius: 31)
        let duplicateAccepted = try await reopened.appendIfNew(duplicate)
        XCTAssertFalse(duplicateAccepted)
        do {
            _ = try await reopened.records()
            XCTFail("a partial history must not be presented as complete")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.directoryURL.path).sorted(), segments)

        // Restoring the block brings back everything, in the same store and a new one.
        try damaged.original.write(to: damaged.url)
        let recovered = try await reopened.records()
        XCTAssertEqual(recovered, originals + later)
        let next = sample(900)
        _ = try await reopened.appendIfNew(next)
        let final = try await TemperatureHistoryStore(fileURL: url).records()
        XCTAssertEqual(final, originals + later + [next])
        XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath: storage.directoryURL.path).count, segments.count,
                             "the kept tail is sealed by the first normal append")
    }

    func testUnreadableSMARTAndFTLHistoriesStillKeepNewRecords() async throws {
        let smartURL = directory.appendingPathComponent("history.jsonl")
        let smart = { (index: Int) in
            DriveSnapshot(capturedAt: self.start.addingTimeInterval(Double(index) * 600), deviceID: "d", devicePath: "/dev/rdisk0",
                          logicalCapacityBytes: 256_000_000_000, model: "m", serialNumber: nil, firmware: "f",
                          smartctlVersion: nil, smartctlExitStatus: 0, temperatureCelsius: 45, powerOnHours: nil,
                          powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: 5, availableSpare: nil,
                          availableSpareThreshold: nil, criticalWarning: 0, mediaAndDataIntegrityErrors: nil,
                          dataUnitsRead: nil, dataUnitsWritten: UInt64(index), smartPassed: true)
        }
        let smartStore = HistoryStore(fileURL: smartURL)
        for index in 0..<257 { _ = try await smartStore.appendIfNew(smart(index)) }
        var smartStorage = LosslessHistoryStorage<DriveSnapshot>(fileURL: smartURL)
        _ = try smartStorage.load()
        let damagedSMART = try damageFirstSegment(in: smartStorage.directoryURL)
        let smartReopened = HistoryStore(fileURL: smartURL)
        let smartAccepted = try await smartReopened.appendIfNew(smart(257))
        XCTAssertTrue(smartAccepted)
        let smartDuplicate = try await smartReopened.appendIfNew(smart(257))
        XCTAssertFalse(smartDuplicate)
        try damagedSMART.original.write(to: damagedSMART.url)
        let smartRecords = try await smartReopened.records()
        XCTAssertEqual(smartRecords.map(\.capturedAt), (0..<258).map { smart($0).capturedAt })

        let ftlURL = directory.appendingPathComponent("asptool-snapshots.jsonl")
        let ftlStore = ASPToolSnapshotStore(fileURL: ftlURL)
        for index in 0..<257 { _ = try await ftlStore.appendIfNew(ftl(index)) }
        var ftlStorage = LosslessHistoryStorage<ASPToolDiagnosticsSnapshot>(fileURL: ftlURL)
        _ = try ftlStorage.load()
        let damagedFTL = try damageFirstSegment(in: ftlStorage.directoryURL)
        let ftlReopened = ASPToolSnapshotStore(fileURL: ftlURL)
        let ftlAccepted = try await ftlReopened.appendIfNew(ftl(257))
        XCTAssertTrue(ftlAccepted)
        let ftlDuplicate = try await ftlReopened.appendIfNew(ftl(257))
        XCTAssertFalse(ftlDuplicate)
        try damagedFTL.original.write(to: damagedFTL.url)
        let ftlRecords = try await ftlReopened.records()
        XCTAssertEqual(ftlRecords.count, 258)
    }

    func testSealFailureDoesNotAcceptTheNextRecord() throws {
        let url = directory.appendingPathComponent("temperature.jsonl")
        var storage = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        _ = try storage.load()
        for index in 0..<256 {
            try storage.append(TemperatureSample(capturedAt: start.addingTimeInterval(Double(index)), deviceID: "d", temperatureCelsius: 30))
        }
        let before = try Data(contentsOf: url)
        try Data("blocked".utf8).write(to: storage.directoryURL)
        XCTAssertThrowsError(try storage.append(TemperatureSample(capturedAt: start.addingTimeInterval(300), deviceID: "d", temperatureCelsius: 31)))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testDefaultTemperatureStoreRestoresArchivesAndPreservesDistributionForTenYears() async throws {
        let url = directory.appendingPathComponent("temperature-history.jsonl")
        let originals = (0..<12).map { TemperatureSample(capturedAt: start.addingTimeInterval(Double($0 * 60)), deviceID: "d", temperatureCelsius: $0 == 11 ? 48 : 32) }
        let summary = TemperatureHistoryRetentionPolicy.daySummary(of: originals)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try (encoder.encode(summary) + Data([0x0A])).write(to: url)
        let archive = CompactionArchive(sourceURL: url)
        try archive.store(removedFrom: originals, keeping: [], capturedAt: \.capturedAt, now: start.addingTimeInterval(60 * 86_400))

        let store = TemperatureHistoryStore(fileURL: url)
        let restored = try await store.records()
        XCTAssertEqual(restored, originals, "summary is replaced only by its actual recovered constituents")
        let future = TemperatureSample(capturedAt: start.addingTimeInterval(10 * 365 * 86_400), deviceID: "d", temperatureCelsius: 40)
        _ = try await store.appendIfNew(future)
        let reloaded = try await TemperatureHistoryStore(fileURL: url).records()
        XCTAssertEqual(reloaded, originals + [future])
        XCTAssertTrue(reloaded.allSatisfy { $0.dailySummary == nil })
        XCTAssertEqual(reloaded.filter { $0.temperatureCelsius == 32 }.count, 11, "the median is not replaced by the rounded mean")
    }

    func testLineTornDuringASessionDoesNotBlockLaterAppends() throws {
        let url = directory.appendingPathComponent("temperature.jsonl")
        var storage = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        _ = try storage.load()
        let samples = (0..<300).map {
            TemperatureSample(capturedAt: start.addingTimeInterval(Double($0)), deviceID: "d", temperatureCelsius: 30)
        }
        for sample in samples.prefix(10) { try storage.append(sample) }
        // A failed append (for example a full disk) left half a line behind.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"torn\":".utf8))
        try handle.close()

        // The tail fills up and is sealed while the torn line is still there.
        for sample in samples.dropFirst(10) { try storage.append(sample) }

        XCTAssertEqual(storage.diagnostics.failedLineCount, 1)
        XCTAssertTrue(storage.diagnostics.sourceRepaired)
        let aside = try XCTUnwrap(storage.diagnostics.quarantineFileName)
        let quarantined = try Data(contentsOf: directory.appendingPathComponent(aside))
        let firstLine = Data(try XCTUnwrap(quarantined.split(separator: 0x0A).first))
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: firstLine) as? [String: Any])
        let raw = try XCTUnwrap(row["rawLineBase64"] as? String)
        XCTAssertEqual(Data(base64Encoded: raw), Data("{\"torn\":".utf8))
        var reloaded = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        XCTAssertEqual(try reloaded.load(), samples)
    }

    func testUnknownBlockAndTornTailArePreservedInQuarantine() throws {
        let url = directory.appendingPathComponent("temperature.jsonl")
        let sample = TemperatureSample(capturedAt: start, deviceID: "d", temperatureCelsius: 32)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var bytes = try encoder.encode(sample) + Data([0x0A])
        bytes += Data("{\"nenringHistoryBlock\":99}\n{\"torn\":".utf8)
        try bytes.write(to: url)
        var storage = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        XCTAssertEqual(try storage.load(), [sample])
        XCTAssertEqual(storage.diagnostics.failedLineCount, 2)
        XCTAssertTrue(storage.diagnostics.sourceRepaired)
        let aside = try XCTUnwrap(storage.diagnostics.quarantineFileName)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside)), bytes)
        var reloaded = LosslessHistoryStorage<TemperatureSample>(fileURL: url)
        XCTAssertEqual(try reloaded.load(), [sample])
    }
}
