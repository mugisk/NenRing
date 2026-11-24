import XCTest
@testable import NenRing

final class ThermalClientAcceptanceTests: XCTestCase {
    /// Explicit local acceptance only: reads supplied histories directly without
    /// invoking collectors, store migration, model.start(), or write workloads.
    @MainActor
    func testLocalHistoryProducesARetentionEstimate() throws {
        guard let root = ProcessInfo.processInfo.environment["NENRING_ACCEPTANCE_HISTORY"],
              let output = ProcessInfo.processInfo.environment["NENRING_ACCEPTANCE_OUTPUT"] else {
            throw XCTSkip("Local history acceptance paths are not configured")
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: output),
            withIntermediateDirectories: true
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func records<T: Decodable>(_ name: String, _: T.Type) throws -> [T] {
            let text = try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name), encoding: .utf8)
            return try text.split(separator: "\n").map { try decoder.decode(T.self, from: Data($0.utf8)) }
        }
        let smart = try records("history.jsonl", DriveSnapshot.self)
        let ftl = try records("asptool-snapshots.jsonl", ASPToolDiagnosticsSnapshot.self)
        let temperature = try records("temperature-history.jsonl", TemperatureSample.self)
        let sessions = try records("research-sessions.jsonl", ResearchSession.self)
        let latest = try XCTUnwrap(smart.max { $0.capturedAt < $1.capturedAt })
        let settingsData = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("usage-settings.json"))
        let settings = try decoder.decode([String: UsageSettings].self, from: settingsData)[latest.deviceID] ?? UsageSettings()
        let started = Date()
        let analytics = DashboardAnalyticsSnapshot.build(analyzer: HistoryAnalyzer(), history: smart,
            temperatureHistory: temperature, deviceID: latest.deviceID, period: .day, profile: nil,
            settings: settings, now: latest.capturedAt, asptoolSnapshots: ftl, researchSessions: sessions)
        let validation = analytics.directFTLCrossValidation
        XCTAssertFalse(validation.rows.isEmpty)
        XCTAssertTrue(validation.rows.contains { $0.title == "Power On Hours" })
        XCTAssertTrue(validation.rows.contains { $0.title == "D7 境界検査" })
        for row in validation.rows {
            print("LOCAL_CROSS_VALIDATION \(row.title): \(row.detail)")
        }
        guard case let .available(value) = analytics.retentionResearchEstimate else { return XCTFail("Current history should produce a provisional estimate") }
        XCTAssertGreaterThan(value.primary.totalHostBytes, 0)
        let physicalStatus: String
        if let physical = value.physicalModel {
            XCTAssertGreaterThan(physical.clientTotalHostBytes, 0)
            XCTAssertGreaterThan(physical.currentTotalHostBytes, 0)
            physicalStatus = "clientTB=\(physical.clientTotalHostBytes / 1e12) currentTB=\(physical.currentTotalHostBytes / 1e12)"
        } else {
            XCTAssertTrue(value.notes.contains { $0.contains("実効NAND容量") })
            physicalStatus = "physicalTB=unavailable(capacity)"
        }
        print("LOCAL_ACCEPTANCE seconds=\(Date().timeIntervalSince(started)) \(physicalStatus) legacyLinearTB=\(value.primary.totalHostBytes / 1e12) dailyWAF=\(value.waf?.daily ?? 0) input=\(value.primary.inputSource.title)")
    }
}
