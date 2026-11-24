import Foundation
import XCTest
@testable import NenRing

final class AppDataLocationTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingDataLocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var legacy: URL { base.appendingPathComponent("SmartHealthMonitor", isDirectory: true) }
    private var current: URL { base.appendingPathComponent("NenRing", isDirectory: true) }

    private func makeLegacyFolder() throws -> [String: Data] {
        let files: [String: Data] = [
            "history.jsonl": Data("{\"a\":1}\n{\"a\":2}\n".utf8),
            "temperature-history.jsonl": Data(repeating: 0x41, count: 200_000),
            "ASPDirectProbes/run-1/stats.bin": Data((0..<4096).map { UInt8($0 % 251) }),
            "usage-settings.json": Data("{}".utf8)
        ]
        for (path, data) in files {
            let url = legacy.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return files
    }

    private func contents(of root: URL, _ paths: some Sequence<String>) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in paths { result[path] = try Data(contentsOf: root.appendingPathComponent(path)) }
        return result
    }

    private func stagingFolders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".NenRing-migrating-") }
    }

    func testCopiesLegacyFolderAndLeavesItUnchanged() throws {
        let files = try makeLegacyFolder()

        let (url, outcome) = AppDataLocation.migrateIfNeeded(base: base)

        XCTAssertEqual(url.standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(outcome, .migrated(fileCount: files.count))
        XCTAssertEqual(try contents(of: current, files.keys), files)
        XCTAssertEqual(try contents(of: legacy, files.keys), files, "the old folder must stay as it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent(AppDataLocation.migrationNoteName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(AppDataLocation.migrationNoteName).path))
        XCTAssertEqual(try stagingFolders(), [])
    }

    func testExistingNenRingFolderIsNeverOverwritten() throws {
        let files = try makeLegacyFolder()
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let newer = Data("{\"newer\":true}\n".utf8)
        try newer.write(to: current.appendingPathComponent("history.jsonl"))

        let (url, outcome) = AppDataLocation.migrateIfNeeded(base: base)

        XCTAssertEqual(url.standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(outcome, .alreadyMigrated)
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("history.jsonl")), newer)
        XCTAssertEqual(try contents(of: legacy, files.keys), files)
    }

    func testFreshInstallCreatesNothing() throws {
        let (url, outcome) = AppDataLocation.migrateIfNeeded(base: base)

        XCTAssertEqual(url.standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(outcome, .freshInstall)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }

    func testFailedVerificationKeepsUsingLegacyFolderAndRemovesTheCopy() throws {
        let files = try makeLegacyFolder()

        let (url, outcome) = AppDataLocation.migrateIfNeeded(base: base, fileManager: CorruptingCopyFileManager())

        XCTAssertEqual(url.standardizedFileURL, legacy.standardizedFileURL)
        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(try stagingFolders(), [])
        XCTAssertEqual(try contents(of: legacy, files.keys), files)
    }

    func testResolveWithoutMigratingPrefersExistingFolders() throws {
        XCTAssertEqual(AppDataLocation.resolveWithoutMigrating(base: base).lastPathComponent, "NenRing")
        _ = try makeLegacyFolder()
        XCTAssertEqual(AppDataLocation.resolveWithoutMigrating(base: base).lastPathComponent, "SmartHealthMonitor")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        XCTAssertEqual(AppDataLocation.resolveWithoutMigrating(base: base).lastPathComponent, "NenRing")
    }

    func testPreferencesAreCopiedOnceWithoutOverwritingNewValues() throws {
        let domain = "NenRingTests-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(300, forKey: "refreshIntervalSeconds")
        let legacy: [String: Any] = [
            "refreshIntervalSeconds": 900,
            "temperatureMonitoringIntervalSeconds": 60,
            "aspDirectFTLLocallyVerifiedMacOSMajors": [26, 27]
        ]

        let copied = LegacyPreferencesMigration.migrateIfNeeded(legacyDomains: [(name: "old", values: legacy)], into: defaults, domainName: domain)

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(defaults.integer(forKey: "refreshIntervalSeconds"), 300, "a value already set in the new domain wins")
        XCTAssertEqual(defaults.integer(forKey: "temperatureMonitoringIntervalSeconds"), 60)
        XCTAssertEqual(defaults.array(forKey: "aspDirectFTLLocallyVerifiedMacOSMajors") as? [Int], [26, 27])

        defaults.set(120, forKey: "temperatureMonitoringIntervalSeconds")
        XCTAssertEqual(LegacyPreferencesMigration.migrateIfNeeded(legacyDomains: [(name: "old", values: legacy)], into: defaults, domainName: domain), 0)
        XCTAssertEqual(defaults.integer(forKey: "temperatureMonitoringIntervalSeconds"), 120, "the migration runs only once")
    }

    func testNewestOldDomainWinsAndOlderDomainsFillTheRest() throws {
        let domain = "NenRingTests-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let newer: [String: Any] = [
            "refreshIntervalSeconds": 900,
            LegacyPreferencesMigration.markerKey: "local.smarthealthmonitor.app"
        ]
        let older: [String: Any] = [
            "refreshIntervalSeconds": 60,
            "menuBarShowsTemperature": true
        ]

        let copied = LegacyPreferencesMigration.migrateIfNeeded(
            legacyDomains: [(name: "example.newer", values: newer),
                            (name: "local.smarthealthmonitor.app", values: older),
                            (name: "missing", values: nil)],
            into: defaults, domainName: domain)

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(defaults.integer(forKey: "refreshIntervalSeconds"), 900, "the newest old domain wins")
        XCTAssertTrue(defaults.bool(forKey: "menuBarShowsTemperature"), "older domains fill keys the newer one lacks")
        XCTAssertEqual(defaults.string(forKey: LegacyPreferencesMigration.markerKey),
                       "example.newer,local.smarthealthmonitor.app",
                       "the old domain's own marker is not copied")
    }
}

/// Copies normally, then changes one byte of the copy, so verification fails.
private final class CorruptingCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        let target = dstURL.appendingPathComponent("history.jsonl")
        var data = try Data(contentsOf: target)
        data[0] ^= 0xFF
        try data.write(to: target)
    }
}
