import XCTest
@testable import NenRing

final class DomainBottleneckTests: XCTestCase {
    private let tlcCapacity = 642.0 * 16_384 * 24_576
    private let pslcCapacity = 79.0 * 16_384 * 8_192

    private func estimates(tlcPE: Double, pslcPE: Double) -> [NANDDomainEstimate] {
        [
            NANDDomainEstimate(domain: .tlc, capacityBytes: tlcCapacity, physicalFootprintBytes: tlcCapacity,
                               currentPE: tlcPE, eolPE: 3_000, targetPE: 3_000,
                               baselineBudgetBytes: tlcCapacity * 3_000, totalBudgetBytes: tlcCapacity * 3_000,
                               usedBytes: tlcCapacity * tlcPE, remainingBytes: tlcCapacity * (3_000 - tlcPE)),
            NANDDomainEstimate(domain: .pslc, capacityBytes: pslcCapacity, physicalFootprintBytes: nil,
                               currentPE: pslcPE, eolPE: 100_000, targetPE: 100_000,
                               baselineBudgetBytes: pslcCapacity * 100_000, totalBudgetBytes: pslcCapacity * 100_000,
                               usedBytes: pslcCapacity * pslcPE, remainingBytes: pslcCapacity * (100_000 - pslcPE))
        ]
    }

    private func topology() throws -> DirectFTLTopology {
        try XCTUnwrap(DirectFTLTopology(contractVersion: DirectFTLResearchContract.reviewed25G83CoreV1,
            numVirtualBlocks: 722, intermediatePartitionStart: 1, userPartitionStart: 80,
            bytesPerPage: 16_384, pagesPerVirtualBlock: 24_576, pagesPerVirtualBlockSLC: 8_192))
    }

    func testLifetimeSplitWaitsForTenTLCCycles() throws {
        // Early in life a one-cycle step in the integer P/E counter moves the
        // split by tens of percent; the combined estimate is used until then.
        XCTAssertNil(DomainWriteShare.estimate(
            estimates: estimates(tlcPE: 2, pslcPE: 60), series: [], topology: try topology(),
            windowDays: nil, recentWeight: 0, excluding: []
        ))
        XCTAssertNotNil(DomainWriteShare.estimate(
            estimates: estimates(tlcPE: 10, pslcPE: 300), series: [], topology: try topology(),
            windowDays: nil, recentWeight: 0, excluding: []
        ))
    }

    func testReferenceMacIsTLCLimitedNearOnePetabyte() throws {
        // Reference Mac: TLC 168 / 3000, pSLC 5541 / 100000, WAF 1.56.
        let share = try XCTUnwrap(DomainWriteShare.estimate(
            estimates: estimates(tlcPE: 168, pslcPE: 5_541), series: [], topology: topology(),
            windowDays: nil, recentWeight: 0, excluding: []
        ))
        XCTAssertEqual(share.tlcShare, 0.425, accuracy: 0.005)
        let bottleneck = try XCTUnwrap(DomainBottleneckRemaining.evaluate(
            estimates: estimates(tlcPE: 168, pslcPE: 5_541), waf: 1.56, share: share
        ))
        XCTAssertEqual(bottleneck.limitingDomain, .tlc)
        XCTAssertEqual(bottleneck.limitingDomainBytesPerHostByte, 0.66, accuracy: 0.01)
        XCTAssertEqual(bottleneck.remainingHostBytes, 1.10e15, accuracy: 0.02e15)
    }

    func testForecastRowsShowBothDomainsNearATie() throws {
        // Reference Mac on 2026-10-01: TLC 168 / 3000, pSLC 5544 / 100000.
        let share = DomainWriteShare(tlcShare: 0.425, lifetimeTLCShare: 0.425, recentTLCShare: nil)
        let rows = try XCTUnwrap(DomainForecastRow.rows(
            estimates: estimates(tlcPE: 168, pslcPE: 5_544), waf: 1.56, share: share
        ))
        XCTAssertEqual(rows.map(\.domain), [.tlc, .pslc])
        XCTAssertEqual(rows[0].wearFraction, 0.056, accuracy: 0.001)
        XCTAssertEqual(rows[1].wearFraction, 0.0554, accuracy: 0.001)
        XCTAssertEqual(rows[0].usedNANDBytes, 4.343e13, accuracy: 0.001e13)
        XCTAssertEqual(rows[0].remainingNANDBytes, 7.32e14, accuracy: 0.01e14)
        XCTAssertEqual(rows[1].remainingNANDBytes, 1.00e15, accuracy: 0.01e15)
        XCTAssertEqual(rows[0].nandBytesPerHostByte, 0.663, accuracy: 0.001)
        XCTAssertEqual(rows[1].nandBytesPerHostByte, 0.897, accuracy: 0.001)
        // Host-equivalent remainders are within a few percent of each other.
        XCTAssertEqual(rows[0].remainingHostBytes / rows[1].remainingHostBytes, 0.99, accuracy: 0.03)

        let bottleneck = try XCTUnwrap(DomainBottleneckRemaining.evaluate(
            estimates: estimates(tlcPE: 168, pslcPE: 5_544), waf: 1.56, share: share
        ))
        let first = try XCTUnwrap(rows.min { $0.remainingHostBytes < $1.remainingHostBytes })
        XCTAssertEqual(bottleneck.limitingDomain, first.domain)
        XCTAssertEqual(bottleneck.remainingHostBytes, first.remainingHostBytes)
    }

    func testForecastRowsNeedAPositiveWAF() {
        let share = DomainWriteShare(tlcShare: 0.4, lifetimeTLCShare: 0.4, recentTLCShare: nil)
        XCTAssertNil(DomainForecastRow.rows(estimates: estimates(tlcPE: 1, pslcPE: 1), waf: 0, share: share))
        XCTAssertNil(DomainForecastRow.rows(estimates: Array(estimates(tlcPE: 1, pslcPE: 1).prefix(1)),
                                            waf: 1.5, share: share))
    }

    func testPSLCLimitsWhenItWearsFaster() throws {
        let share = DomainWriteShare(tlcShare: 0.2, lifetimeTLCShare: 0.2, recentTLCShare: nil)
        let bottleneck = try XCTUnwrap(DomainBottleneckRemaining.evaluate(
            estimates: estimates(tlcPE: 100, pslcPE: 90_000), waf: 1.5, share: share
        ))
        XCTAssertEqual(bottleneck.limitingDomain, .pslc)
    }

    func testRecentSplitComesFromNANDWritesLessPSLCWrites() throws {
        let topology = try topology()
        let nandPerDay = 225e9
        let pslcPEPerDay = 12.0
        func series(days: Int, pslcPerDay: Double = pslcPEPerDay, nandPerDay: Double = nandPerDay) -> [ASPToolDiagnosticsSnapshot] {
            (0...days).map { day in
                ASPToolDiagnosticsSnapshot(
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400),
                    captureQuality: .explicit, deviceID: "disk0", sourceArtifact: .directFTL, sourceBuild: "26A434",
                    hostWrites: UInt64(Double(day) * 100e9 / 4_096), nandWrites: UInt64((90e12 + Double(day) * nandPerDay) / 4_096),
                    hostWritesUnitState: .provisional4KiB, nandWritesUnitState: .provisional4KiB,
                    // TLC P/E does not move at all in this window.
                    tlcAveragePE: 170, slcAveragePE: 5_000 + Double(day) * pslcPerDay)
            }
        }
        let pslcCapacity = try XCTUnwrap(topology.pslcWritableCapacityBytes)
        let expected = (nandPerDay - pslcPEPerDay * pslcCapacity) / nandPerDay

        let recent = try XCTUnwrap(DomainWriteShare.recentShare(
            series: series(days: 30), topology: topology, windowDays: 30, excluding: []))
        XCTAssertEqual(recent, expected, accuracy: 0.002, "TLC P/E standing still no longer blocks the recent split")
        let share = try XCTUnwrap(DomainWriteShare.estimate(
            estimates: estimates(tlcPE: 170, pslcPE: 5_360), series: series(days: 30), topology: topology,
            windowDays: 30, recentWeight: 1, excluding: []))
        XCTAssertEqual(share.tlcShare, try XCTUnwrap(share.recentTLCShare), accuracy: 1e-12, "q = 1 uses the recent split")

        // An excluded interval drops only the pairs it overlaps.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let excluded = [DateInterval(start: start.addingTimeInterval(5.5 * 86_400), duration: 3 * 86_400)]
        XCTAssertEqual(try XCTUnwrap(DomainWriteShare.recentShare(
            series: series(days: 30), topology: topology, windowDays: 30, excluding: excluded)), expected, accuracy: 0.002)

        // Fewer than 50 pSLC cycles in the window: not enough to measure.
        XCTAssertNil(DomainWriteShare.recentShare(series: series(days: 4), topology: topology, windowDays: 30, excluding: []))
        // pSLC writes above all NAND writes point to a unit mismatch.
        XCTAssertNil(DomainWriteShare.recentShare(series: series(days: 30, nandPerDay: 50e9),
                                                  topology: topology, windowDays: 30, excluding: []))
    }

    func testWriteBreakdownShowsDomainBytesAndHostRatio() {
        let breakdown = DomainWriteBreakdown.make(estimates: estimates(tlcPE: 168, pslcPE: 5_541), hostBytes: 64.83e12)
        XCTAssertEqual(breakdown.map(\.domain), [.tlc, .pslc])
        XCTAssertEqual(breakdown[0].bytes, 43.43e12, accuracy: 0.01e12)
        XCTAssertEqual(try XCTUnwrap(breakdown[0].perHostByte), 0.67, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(breakdown[1].perHostByte), 0.91, accuracy: 0.01)
        XCTAssertNil(DomainWriteBreakdown.make(estimates: estimates(tlcPE: 168, pslcPE: 5_541), hostBytes: nil)[0].perHostByte)
        XCTAssertTrue(DomainWriteBreakdown.make(estimates: [], hostBytes: 1).isEmpty)
    }
}
