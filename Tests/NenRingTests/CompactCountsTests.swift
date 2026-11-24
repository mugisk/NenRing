import XCTest
@testable import NenRing

final class CompactCountsTests: XCTestCase {
    func testEveryWidthKeepsItsValues() {
        let cases: [[UInt64]] = [
            [], [0, 1, 65_535],
            [0, 65_536, 145_081, 35_337_687, UInt64(UInt32.max)],
            [1, UInt64(UInt32.max) + 1, UInt64.max]
        ]
        for values in cases {
            XCTAssertEqual(CompactCounts(values).values, values)
        }
        XCTAssertEqual(CompactCounts([1, 2]), CompactCounts([1, 2]))
        XCTAssertNotEqual(CompactCounts([1, 2]), CompactCounts([1, 3]))
    }

    func testStoredJSONIsUnchanged() throws {
        // The encoding written before compact storage: plain UInt64 arrays.
        let histogram: [UInt64] = [0, 12, 145_081, 35_337_687, UInt64(UInt32.max) + 7]
        let telemetry = FTLResearchTelemetrySnapshot(nandReads: 9, ageRefreshPerTier: [1, 28_615, 3],
            bandsMaxTempHistogram: histogram, bandsMinTempHistogram: [4, 5],
            bandsLifetimeTempHistogram: histogram, bandsDeltaTempHistogram: [], bandsCrossTempHistogram: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try JSONSerialization.jsonObject(with: encoder.encode(telemetry)) as? [String: Any]
        XCTAssertEqual(json?["bandsMaxTempHistogram"] as? [UInt64], histogram)
        XCTAssertEqual(json?["ageRefreshPerTier"] as? [UInt64], [1, 28_615, 3])
        XCTAssertEqual(json?["bandsDeltaTempHistogram"] as? [UInt64], [])
        XCTAssertNil(json?["bandsCrossTempHistogram"])
        XCTAssertEqual(try JSONDecoder().decode(FTLResearchTelemetrySnapshot.self, from: encoder.encode(telemetry)), telemetry)

        // Records saved under the older key names still decode.
        let legacy = Data(#"{"nandReads":1,"readTemperatureHistogram":[1,2],"slcReadRetryHistogram":[70000,0]}"#.utf8)
        let decoded = try JSONDecoder().decode(FTLResearchTelemetrySnapshot.self, from: legacy)
        XCTAssertEqual(decoded.bandsMaxTempHistogram, [1, 2])
        XCTAssertEqual(decoded.bandsCrossTempHistogram, [70_000, 0])
    }
}
