import Foundation
import XCTest
@testable import NenRing

final class CompactionArchiveTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01T00:00:00Z

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingCompactionArchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var liveURL: URL { directory.appendingPathComponent("temperature-history.jsonl") }

    private func samples(days: Int, perDay: Int, from date: Date) -> [TemperatureSample] {
        (0..<days).flatMap { day in
            (0..<perDay).map { index in
                TemperatureSample(
                    capturedAt: date.addingTimeInterval(Double(day) * 86_400 + Double(index) * 3_600),
                    deviceID: "disk",
                    temperatureCelsius: 30 + index
                )
            }
        }
    }

    private func archived(_ archive: CompactionArchive) throws -> [TemperatureSample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [TemperatureSample] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: archive.directoryURL.path) {
            var data = try Data(contentsOf: archive.directoryURL.appendingPathComponent(name))
            if name.hasSuffix(".lzfse") {
                data = try (data as NSData).decompressed(using: .lzfse) as Data
            }
            result += try data.split(separator: 0x0A).map { try decoder.decode(TemperatureSample.self, from: Data($0)) }
        }
        return result
    }

    func testRemovedRecordsGoToMonthlyFilesAndCompressionKeepsThemIdentical() throws {
        let archive = CompactionArchive(sourceURL: liveURL)
        let original = samples(days: 40, perDay: 3, from: start)
        let kept = Array(original.suffix(10))

        try archive.store(removedFrom: original, keeping: kept, capturedAt: \.capturedAt,
                          now: start.addingTimeInterval(20 * 86_400))
        // September is still the current month: kept as plain JSONL.
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.plainURL(month: "2026-09").path))
        let beforeCompression = try Data(contentsOf: archive.plainURL(month: "2026-09"))

        archive.compressCompletedMonths(now: start.addingTimeInterval(45 * 86_400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.plainURL(month: "2026-09").path))
        let compressedURL = archive.directoryURL.appendingPathComponent("temperature-history-2026-09.jsonl.lzfse")
        let restored = try (Data(contentsOf: compressedURL) as NSData).decompressed(using: .lzfse) as Data
        XCTAssertEqual(restored, beforeCompression)

        let all = try archived(archive)
        XCTAssertEqual(Set(all.map(\.id)), Set(original.dropLast(10).map(\.id)), "every removed record is archived exactly once")
    }

    func testDaySummaryKeepsMinimumMaximumAverageAndIsStable() {
        let policy = sampledPolicy
        let old = samples(days: 3, perDay: 4, from: start) // 30, 31, 32, 33 °C each day
        let recent = samples(days: 1, perDay: 2, from: start.addingTimeInterval(60 * 86_400))
        let compacted = policy.compact(old + recent)

        let summaries = compacted.compactMap(\.dailySummary)
        XCTAssertFalse(summaries.isEmpty)
        for summary in summaries where summary.sampleCount == 4 {
            XCTAssertEqual(summary.minimumCelsius, 30)
            XCTAssertEqual(summary.maximumCelsius, 33)
            XCTAssertEqual(summary.averageCelsius, 31.5, accuracy: 0.0001)
        }
        XCTAssertEqual(policy.compact(compacted), compacted, "compacting again changes nothing")
    }

    func testStoreKeepsEveryReadingInTheLiveFileOrTheArchive() async throws {
        let original = samples(days: 40, perDay: 6, from: start)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for sample in original { data.append(try encoder.encode(sample)); data.append(0x0A) }
        try data.write(to: liveURL)

        let store = TemperatureHistoryStore(fileURL: liveURL, retentionPolicy: sampledPolicy)
        let live = try await store.records()
        let archive = CompactionArchive(sourceURL: liveURL)
        let archivedIDs = Set(try archived(archive).map(\.id))

        XCTAssertLessThan(live.count, original.count)
        for sample in original {
            XCTAssertTrue(live.contains { $0.id == sample.id } || archivedIDs.contains(sample.id),
                          "reading at \(sample.capturedAt) was lost")
        }
    }

    func testLiveFileIsUntouchedWhenTheArchiveCannotBeWritten() async throws {
        let original = samples(days: 40, perDay: 6, from: start)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for sample in original { data.append(try encoder.encode(sample)); data.append(0x0A) }
        try data.write(to: liveURL)
        // A plain file where the archive folder should be makes archiving fail.
        try Data("blocked".utf8).write(to: directory.appendingPathComponent("archive"))

        let store = TemperatureHistoryStore(fileURL: liveURL, retentionPolicy: sampledPolicy)
        do {
            _ = try await store.records()
            XCTFail("compaction must not succeed without an archive")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: liveURL), data)
    }

    private var sampledPolicy: TemperatureHistoryRetentionPolicy {
        let p = TemperatureHistoryRetentionPolicy.standard
        return TemperatureHistoryRetentionPolicy(fullResolutionAge: p.fullResolutionAge,
            mediumResolutionAge: p.mediumResolutionAge, mediumBucketDuration: p.mediumBucketDuration,
            archiveBucketDuration: p.archiveBucketDuration, maximumRecordCount: p.maximumRecordCount,
            compactionInterval: p.compactionInterval)
    }
}
