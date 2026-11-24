import XCTest
@testable import NenRing

final class ForecastObservationEvidenceTests: XCTestCase {
    private func summary(days: Double, steps: Int, subdivisions: Int = 1) -> ControllerWearHistorySummary {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshots = (0...(steps * subdivisions)).map { index in
            let position = Double(index) / Double(subdivisions)
            return ASPToolDiagnosticsSnapshot(capturedAt: origin.addingTimeInterval(days * 86_400 * position / Double(max(1, steps))),
                captureQuality: .explicit, deviceID: "drive", sourceArtifact: .directFTL,
                sourceBuild: DirectFTLResearchContract.reviewedBuild, extractionVersion: 2,
                hostWrites: UInt64(10_000_000_000 + position * 500_000_000),
                nandWrites: UInt64(16_000_000_000 + position * 800_000_000),
                hostWritesUnitState: .provisional4KiB, nandWritesUnitState: .provisional4KiB,
                tlcAveragePE: 100 + floor(position), tlcEOLPE: 3_000,
                slcAveragePE: 3_000 + floor(position * 30), slcEOLPE: 100_000,
                firmware: "FW1", directKeyContractVersion: DirectFTLResearchContract.latest)
        }
        return ControllerWearHistoryAnalyzer().summarize(snapshots: snapshots, deviceID: "drive", aggregateSlopes: true)
    }

    func testEveryConfidenceStateIsReachableWithProvisionalByteUnits() {
        let low = ForecastObservationEvidence.assess(wear: summary(days: 1, steps: 1), wafDays: 1,
            wafHost: 1e10, paceDays: 1, hasDomains: true, held: false)
        XCTAssertEqual(low.confidence, .low)
        let medium = ForecastObservationEvidence.assess(wear: summary(days: 28, steps: 2), wafDays: 14,
            wafHost: 2e11, paceDays: 20, hasDomains: true, held: false)
        XCTAssertEqual(medium.confidence, .medium)
        let high = ForecastObservationEvidence.assess(wear: summary(days: 120, steps: 4), wafDays: 29,
            wafHost: 5e12, paceDays: 29, hasDomains: true, held: false)
        XCTAssertEqual(high.confidence, .high)
        let held = ForecastObservationEvidence.assess(wear: summary(days: 120, steps: 4), wafDays: 90,
            wafHost: 5e12, paceDays: 100, hasDomains: true, held: true)
        XCTAssertEqual(held.confidence, .low)
        let partial = ForecastObservationEvidence.assess(wear: summary(days: 120, steps: 4), wafDays: 90,
            wafHost: 5e12, paceDays: 100, hasDomains: false, held: false)
        XCTAssertEqual(partial.confidence, .low)
    }

    func testPollingRefinementDoesNotRaiseConfidence() {
        for (days, steps) in [(28.0, 2), (120.0, 4)] {
            func assess(_ subdivisions: Int) -> ForecastObservationEvidence {
                .assess(wear: summary(days: days, steps: steps, subdivisions: subdivisions), wafDays: 29,
                    wafHost: 2e12, paceDays: 29, hasDomains: true, held: false)
            }
            XCTAssertEqual(assess(1).confidence, assess(24).confidence)
        }
    }
}
