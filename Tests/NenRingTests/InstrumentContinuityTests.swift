import Foundation
import XCTest
@testable import NenRing

final class InstrumentContinuityTests: XCTestCase {
    private let boundaryDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func topology(numVirtualBlocks: UInt64 = 722, userPartitionStart: UInt64 = 80) throws -> DirectFTLTopology {
        try XCTUnwrap(DirectFTLTopology(
            contractVersion: DirectFTLResearchContract.reviewed25G83CoreV1,
            numVirtualBlocks: numVirtualBlocks,
            intermediatePartitionStart: 1,
            userPartitionStart: userPartitionStart,
            bytesPerPage: 16_384,
            pagesPerVirtualBlock: 24_576,
            pagesPerVirtualBlockSLC: 8_192
        ))
    }

    private func nandRaw(tlcPE: Double, pslcPE: Double, tlcBands: Double = 642, pslcBands: Double = 79) -> UInt64 {
        let tlcCapacity = tlcBands * 16_384.0 * 24_576.0
        let pslcCapacity = pslcBands * 16_384.0 * 8_192.0
        return UInt64(((tlcCapacity * tlcPE + pslcCapacity * pslcPE) / 4_096.0).rounded())
    }

    private func ftl(
        date: Date,
        sourceBuild: String,
        firmware: String,
        hostRaw: UInt64,
        nandRaw: UInt64,
        tlcPE: Double,
        pslcPE: Double,
        powerOnHours: UInt64,
        contractBuild: String? = "25G83",
        directKeyContract: String? = DirectFTLResearchContract.latest,
        probeVersion: Int? = 2,
        extractionVersion: Int = 1,
        directFormatVersion: UInt32? = nil,
        unit: ASPToolUnitState = .provisional4KiB,
        includeTopology: Bool = true,
        topologyOverride: DirectFTLTopology? = nil,
        tlcEOL: Double = 3_000,
        slcEOL: Double = 100_000,
        deviceID: String = "disk0"
    ) throws -> ASPToolDiagnosticsSnapshot {
        let directTopology = includeTopology ? try topologyOverride ?? topology() : nil
        return ASPToolDiagnosticsSnapshot(
            capturedAt: date,
            captureQuality: .explicit,
            deviceID: deviceID,
            sourceArtifact: .directFTL,
            sourceBuild: sourceBuild,
            contractBuild: contractBuild,
            probeVersion: probeVersion,
            extractionVersion: extractionVersion,
            semanticContractVersion: directKeyContract,
            coreWearContractVersion: directKeyContract == nil ? nil : DirectFTLResearchContract.reviewed25G83CoreV1,
            researchTelemetryContractVersion: directKeyContract == nil ? nil : DirectFTLResearchContract.reviewed25G83ResearchV241,
            hostWrites: hostRaw,
            nandWrites: nandRaw,
            hostWritesUnitState: unit,
            nandWritesUnitState: unit,
            tlcAveragePE: tlcPE,
            tlcMaximumPE: tlcPE + 10,
            tlcEOLPE: tlcEOL,
            slcAveragePE: pslcPE,
            slcMaximumPE: pslcPE + 10,
            slcEOLPE: slcEOL,
            powerOnHours: powerOnHours,
            firmware: firmware,
            directFormatVersion: directFormatVersion,
            directTopology: directTopology
        )
    }

    private func extractedASPTool(
        date: Date,
        hostRaw: UInt64,
        nandRaw: UInt64,
        tlcPE: Double,
        pslcPE: Double,
        powerOnHours: UInt64
    ) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: date,
            captureQuality: .fileMetadata,
            deviceID: "disk0",
            sourceName: "asptool_snapshot.log",
            sourceArtifact: .extractedASPTool,
            sourceBuild: "25G83",
            contractBuild: "25G83",
            extractionVersion: 1,
            semanticContractVersion: DirectFTLResearchContract.latest,
            coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1,
            hostWrites: hostRaw,
            nandWrites: nandRaw,
            hostWritesUnitState: .provisional4KiB,
            nandWritesUnitState: .provisional4KiB,
            tlcAveragePE: tlcPE,
            tlcMaximumPE: tlcPE + 10,
            tlcEOLPE: 3_000,
            slcAveragePE: pslcPE,
            slcMaximumPE: pslcPE + 10,
            slcEOLPE: 100_000,
            powerOnHours: powerOnHours,
            firmware: "561.100"
        )
    }

    private func smart(date: Date, firmware: String, hostRaw: UInt64, powerOnHours: UInt64) -> DriveSnapshot {
        let dataUnits = UInt64((Double(hostRaw) * 4_096.0 / 512_000.0).rounded())
        return DriveSnapshot(
            capturedAt: date,
            deviceID: "disk0",
            devicePath: "/dev/rdisk0",
            logicalCapacityBytes: 256_000_000_000,
            model: "Apple SSD",
            serialNumber: nil,
            firmware: firmware,
            smartctlVersion: nil,
            smartctlExitStatus: 0,
            temperatureCelsius: 40,
            powerOnHours: powerOnHours,
            powerCycleCount: nil,
            unsafeShutdowns: nil,
            percentageUsed: 5,
            availableSpare: 100,
            availableSpareThreshold: nil,
            criticalWarning: 0,
            mediaAndDataIntegrityErrors: 0,
            dataUnitsRead: nil,
            dataUnitsWritten: dataUnits,
            smartPassed: true
        )
    }

    private func pair(
        beforeInterval: TimeInterval = 3_600,
        afterHostRaw: UInt64 = 1_500_000_000,
        afterTLCPE: Double = 101,
        afterPSLCPE: Double = 1_001,
        afterNANDRaw: UInt64? = nil,
        beforeHasTopology: Bool = true,
        afterHasTopology: Bool = true
    ) throws -> ([ASPToolDiagnosticsSnapshot], [DriveSnapshot]) {
        let beforeDate = boundaryDate.addingTimeInterval(-beforeInterval)
        let beforeHost: UInt64 = 1_000_000_000
        let beforeTLC = 100.0
        let beforePSLC = 1_000.0
        let afterNAND = afterNANDRaw ?? nandRaw(tlcPE: afterTLCPE, pslcPE: afterPSLCPE)
        let before = try ftl(
            date: beforeDate,
            sourceBuild: "25G83",
            firmware: "561.100",
            hostRaw: beforeHost,
            nandRaw: nandRaw(tlcPE: beforeTLC, pslcPE: beforePSLC),
            tlcPE: beforeTLC,
            pslcPE: beforePSLC,
            powerOnHours: 100,
            includeTopology: beforeHasTopology
        )
        let after = try ftl(
            date: boundaryDate,
            sourceBuild: "26A123",
            firmware: "591",
            hostRaw: afterHostRaw,
            nandRaw: afterNAND,
            tlcPE: afterTLCPE,
            pslcPE: afterPSLCPE,
            powerOnHours: 101,
            includeTopology: afterHasTopology
        )
        return (
            [before, after],
            [
                smart(date: beforeDate, firmware: "561.100", hostRaw: beforeHost, powerOnHours: 100),
                smart(date: boundaryDate, firmware: "591", hostRaw: 1_500_000_000, powerOnHours: 101)
            ]
        )
    }

    func testVerifiedBoundaryRequiresD5AndD7AndAddsOnlyPostBoundaryLearningExclusion() throws {
        let (snapshots, smartHistory) = try pair()
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)

        XCTAssertEqual(lane.snapshots.count, 2)
        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertEqual(try XCTUnwrap(boundary.rateLearningExclusion?.duration), 73 * 3_600, accuracy: 0.001)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d5SmartHostRatio }?.passed == true)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d7LifetimeResidual }?.passed == true)
        XCTAssertEqual(lane.rateLearningExclusions.count, 1)
    }

    func testVerifiedBoundaryDoesNotImposeA72HourLimitWhenSMARTCoversAFiveDayGap() throws {
        let (snapshots, smartHistory) = try pair(beforeInterval: 5 * 86_400)
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d5SmartHostRatio }?.available == true)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d6PowerOnHours }?.available == true)
    }

    func testBoundaryStaysVerifiedAfterSMARTHistoryIsThinnedToDaily() throws {
        // A young drive (200 GB written) whose 3 GB of writes all land between
        // the two reads, with SMART sampled every 15 minutes. The reads sit at
        // 11:00 and 13:00 UTC, so after daily thinning they are matched with
        // SMART samples from different days.
        let beforeDate = boundaryDate.addingTimeInterval(3 * 3_600)
        let afterDate = boundaryDate.addingTimeInterval(5 * 3_600)
        let baseHost: UInt64 = 48_828_125
        let burst: UInt64 = 732_422
        let start = boundaryDate.addingTimeInterval(-3 * 86_400)
        let smartHistory = (0..<(6 * 96)).map { step -> DriveSnapshot in
            let date = start.addingTimeInterval(Double(step) * 900)
            return smart(
                date: date,
                firmware: date < beforeDate.addingTimeInterval(1_800) ? "561.100" : "591",
                hostRaw: date < afterDate ? baseHost : baseHost + burst,
                powerOnHours: UInt64(100 + date.timeIntervalSince(beforeDate) / 3_600)
            )
        }
        let snapshots = [
            try ftl(date: beforeDate, sourceBuild: "25G83", firmware: "561.100", hostRaw: baseHost,
                    nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000), tlcPE: 100, pslcPE: 1_000, powerOnHours: 100),
            try ftl(date: afterDate, sourceBuild: "26A123", firmware: "591", hostRaw: baseHost + burst,
                    nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001), tlcPE: 101, pslcPE: 1_001, powerOnHours: 102)
        ]
        let fresh = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)
        XCTAssertTrue(try XCTUnwrap(fresh.boundaries.first).continuity.isVerified)

        // Historical sampled files must still be analyzable; current default
        // storage preserves all measurements instead of creating new thinning.
        let p = HistoryRetentionPolicy.standard
        let legacy = HistoryRetentionPolicy(fullResolutionAge: p.fullResolutionAge,
            mediumResolutionAge: p.mediumResolutionAge, mediumBucketDuration: p.mediumBucketDuration,
            archiveBucketDuration: p.archiveBucketDuration, maximumRecordCount: p.maximumRecordCount,
            compactionInterval: p.compactionInterval)
        let thinned = legacy.compact(
            smartHistory, referenceDate: boundaryDate.addingTimeInterval(95 * 86_400))
        XCTAssertLessThanOrEqual(thinned.count, 10, "SMART history should be down to about one sample a day")
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: thinned, latest: snapshots.last)

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d5SmartHostRatio }?.passed == true,
                      boundary.checks.first { $0.kind == .d5SmartHostRatio }?.detail ?? "")
        XCTAssertTrue(boundary.checks.first { $0.kind == .d6PowerOnHours }?.passed == true,
                      boundary.checks.first { $0.kind == .d6PowerOnHours }?.detail ?? "")
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertEqual(lane.snapshots.count, 2)
    }

    func testD6AllowsForTheGapToADailySMARTSample() throws {
        // Daily SMART samples at 23:45 UTC; the reads at 11:00 and 13:00 are
        // each matched with a sample about 11 hours away, on different days.
        let beforeDate = boundaryDate.addingTimeInterval(3 * 3_600)
        let afterDate = boundaryDate.addingTimeInterval(5 * 3_600)
        let hostPerHour: UInt64 = 1_000
        let smartHistory = [-8.25, 15.75, 39.75].map { hours -> DriveSnapshot in
            let date = boundaryDate.addingTimeInterval(hours * 3_600)
            let sinceBefore = date.timeIntervalSince(beforeDate) / 3_600
            return smart(
                date: date,
                firmware: hours < 0 ? "561.100" : "591",
                hostRaw: UInt64(Double(1_000_000_000) + sinceBefore * Double(hostPerHour)),
                powerOnHours: UInt64((100 + sinceBefore).rounded())
            )
        }
        let snapshots = [
            try ftl(date: beforeDate, sourceBuild: "25G83", firmware: "561.100", hostRaw: 1_000_000_000,
                    nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000), tlcPE: 100, pslcPE: 1_000, powerOnHours: 100),
            try ftl(date: afterDate, sourceBuild: "26A123", firmware: "591", hostRaw: 1_000_000_000 + 2 * hostPerHour,
                    nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001), tlcPE: 101, pslcPE: 1_001, powerOnHours: 102)
        ]

        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)

        let d6 = try XCTUnwrap(try XCTUnwrap(lane.boundaries.first).checks.first { $0.kind == .d6PowerOnHours })
        XCTAssertTrue(d6.available)
        XCTAssertTrue(d6.passed, d6.detail)
        XCTAssertGreaterThan(d6.relativeChange ?? 0, 2, "the residual change itself exceeds the old fixed 2 hours")
    }

    func testD6StillRejectsAPOHJumpWhenSMARTIsClose() throws {
        let (snapshots, smartHistory) = try pair()
        var shifted = snapshots
        shifted[1] = try ftl(date: boundaryDate, sourceBuild: "26A123", firmware: "591", hostRaw: 1_500_000_000,
                             nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001), tlcPE: 101, pslcPE: 1_001, powerOnHours: 110)

        let lane = WearContinuityLaneBuilder.build(snapshots: shifted, smart: smartHistory, latest: shifted.last)

        let d6 = try XCTUnwrap(try XCTUnwrap(lane.boundaries.first).checks.first { $0.kind == .d6PowerOnHours })
        XCTAssertFalse(d6.passed, d6.detail)
    }

    func testNearestSmartFirmwareLookupMatchesTheLinearSearch() {
        // Random histories with repeated times and equal distances on both
        // sides, compared with the linear search the lookup replaces.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let count = Int.random(in: 0...30, using: &generator)
            let history = (0..<count).map { index -> DriveSnapshot in
                var snapshot = smart(date: boundaryDate.addingTimeInterval(Double(Int.random(in: 0...20, using: &generator)) * 60),
                                     firmware: "fw\(index)", hostRaw: 1, powerOnHours: 1)
                snapshot.deviceID = ["disk0", "disk1"].randomElement(using: &generator)!
                return snapshot
            }
            let lookup = WearContinuityLaneBuilder.NearestSmartFirmware(history: history)
            for minute in -2...22 {
                let date = boundaryDate.addingTimeInterval(Double(minute) * 60 + [0, 30].randomElement(using: &generator)!)
                for deviceID in ["disk0", "disk1", nil] as [String?] {
                    let linear = history
                        .filter { deviceID == nil || $0.deviceID == deviceID }
                        .min { abs($0.capturedAt.timeIntervalSince(date)) < abs($1.capturedAt.timeIntervalSince(date)) }?
                        .firmware
                    XCTAssertEqual(lookup.firmware(near: date, deviceID: deviceID), linear)
                }
            }
        }
    }

    func testStructuralChecksAcceptOtherCapacitiesWhenUnchangedAcrossBoundary() throws {
        let larger = try topology(numVirtualBlocks: 1_444, userPartitionStart: 160)
        let checks = try structuralChecks(beforeTopology: larger, afterTopology: larger, afterTLCEOL: 5_000, beforeTLCEOL: 5_000)

        XCTAssertEqual(checks[.d1Geometry]?.passed, true)
        XCTAssertEqual(checks[.d2Topology]?.passed, true)
        XCTAssertTrue(checks[.d2Topology]?.detail.contains("virtual 1444") == true)
        XCTAssertEqual(checks[.d3EOL]?.passed, true)
        XCTAssertTrue(checks[.d3EOL]?.detail.contains("TLC 5000") == true)
    }

    func testStructuralChecksFailWhenValuesChangeAcrossBoundary() throws {
        let checks = try structuralChecks(
            beforeTopology: topology(),
            afterTopology: topology(numVirtualBlocks: 1_444, userPartitionStart: 160),
            afterTLCEOL: 5_000,
            beforeTLCEOL: 3_000
        )

        XCTAssertEqual(checks[.d2Topology]?.passed, false)
        XCTAssertEqual(checks[.d3EOL]?.passed, false)
    }

    private func structuralChecks(
        beforeTopology: DirectFTLTopology,
        afterTopology: DirectFTLTopology,
        afterTLCEOL: Double,
        beforeTLCEOL: Double
    ) throws -> [ContinuityCheckKind: ContinuityCheckResult] {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000,
            nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000, tlcBands: Double(beforeTopology.tlcBandCount), pslcBands: Double(beforeTopology.intermediateBandCount)),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100,
            topologyOverride: beforeTopology, tlcEOL: beforeTLCEOL
        )
        let after = try ftl(
            date: boundaryDate, sourceBuild: "26A123", firmware: "591",
            hostRaw: 1_500_000_000,
            nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001, tlcBands: Double(afterTopology.tlcBandCount), pslcBands: Double(afterTopology.intermediateBandCount)),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101,
            topologyOverride: afterTopology, tlcEOL: afterTLCEOL
        )
        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, after],
            smart: [
                smart(date: beforeDate, firmware: "561.100", hostRaw: 1_000_000_000, powerOnHours: 100),
                smart(date: boundaryDate, firmware: "591", hostRaw: 1_500_000_000, powerOnHours: 101)
            ],
            latest: after
        )
        let boundary = try XCTUnwrap(lane.boundaries.first)
        return Dictionary(boundary.checks.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func testSmartInterpolationDoesNotBridgeFiveDayPrecedingGap() throws {
        let date = boundaryDate
        let samples: [(Date, Double)] = [
            (date.addingTimeInterval(-5 * 86_400), 100),
            (date.addingTimeInterval(3_600), 200)
        ]

        // The one-hour future sample is a valid nearest fallback.  The value
        // must not be blended with a SMART sample five days before the FTL
        // boundary.
        let value = try XCTUnwrap(WearContinuityLaneBuilder.interpolated(at: date, samples: samples))
        XCTAssertEqual(value, 200, accuracy: 0.0001)
    }

    /// asptool text (imported, or extracted by earlier builds) is evidence only:
    /// it never joins the forecast lane or creates an acquisition-route boundary.
    func testExtractedASPToolTextStaysOutOfTheCoreLane() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-5 * 86_400)
        let before = extractedASPTool(
            date: beforeDate,
            hostRaw: 1_000_000_000,
            nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100,
            pslcPE: 1_000,
            powerOnHours: 100
        )
        let after = try ftl(
            date: boundaryDate,
            sourceBuild: "25G83",
            firmware: "561.100",
            hostRaw: 1_500_000_000,
            nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101,
            pslcPE: 1_001,
            powerOnHours: 101
        )
        let smartHistory = [
            smart(date: beforeDate, firmware: "561.100", hostRaw: 1_000_000_000, powerOnHours: 100),
            smart(date: boundaryDate, firmware: "561.100", hostRaw: 1_500_000_000, powerOnHours: 101)
        ]

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, after], smart: smartHistory, latest: after
        )

        XCTAssertFalse(ASPToolSourceArtifact.extractedASPTool.participatesInCoreWearLane)
        XCTAssertFalse(ASPToolSourceArtifact.importedFixture.participatesInCoreWearLane)
        XCTAssertEqual(lane.snapshots.map(\.sourceArtifact), [.directFTL])
        XCTAssertTrue(lane.boundaries.isEmpty)
        XCTAssertFalse(lane.containsTopologylessASPTool)
    }

    func testSameSecondMonotonicCaptureDuplicateDoesNotResetWAFWindow() throws {
        let start = boundaryDate.addingTimeInterval(-10 * 86_400)
        let duplicateDate = boundaryDate.addingTimeInterval(-5 * 86_400)
        let startSnapshot = try ftl(
            date: start, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 10_000_000_000, nandRaw: 20_000_000_000,
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )
        let duplicateEarlier = try ftl(
            date: duplicateDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 11_000_000_000, nandRaw: 22_000_000_000,
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )
        let duplicateLater = try ftl(
            date: duplicateDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 11_000_001_000, nandRaw: 22_000_002_000,
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )
        let finish = try ftl(
            date: boundaryDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 12_000_000_000, nandRaw: 24_000_000_000,
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [startSnapshot, duplicateEarlier, duplicateLater, finish],
            smart: [],
            latest: finish
        )

        XCTAssertEqual(lane.snapshots.count, 3)
        XCTAssertEqual(lane.collapsedSameSecondSnapshots, 1)
        XCTAssertEqual(lane.snapshots[1].hostWrites, duplicateLater.hostWrites)

        let waf = RetentionWAFAnalyzer().assess(
            snapshots: lane.snapshots,
            latest: finish,
            now: boundaryDate.addingTimeInterval(86_400),
            excluding: [],
            client: 3.5,
            selection: nil,
            trials: [],
            continuityLane: lane
        )
        let thirtyDay = try XCTUnwrap(waf.windows.first { $0.days == 30 })
        XCTAssertEqual(thirtyDay.observationDays, 10, accuracy: 0.0001,
                       "単調な同秒重複で、それ以前の累積観測窓をreset扱いにしない")
    }

    func testLaterDirectTopologyCompletesTheFirmwareBoundary() throws {
        let base = boundaryDate.addingTimeInterval(-5 * 86_400)
        let aHost: UInt64 = 1_000_000_000
        let bHost: UInt64 = 1_500_000_000
        let cHost: UInt64 = 2_000_000_000
        let firstDirect = try ftl(
            date: boundaryDate,
            sourceBuild: "25G83",
            firmware: "561.100",
            hostRaw: bHost,
            nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101,
            pslcPE: 1_001,
            powerOnHours: 101,
            includeTopology: false
        )
        let directWithTopology = try ftl(
            date: boundaryDate.addingTimeInterval(2 * 3_600),
            sourceBuild: "25G83",
            firmware: "561.100",
            hostRaw: bHost + 10_000,
            nandRaw: nandRaw(tlcPE: 101.1, pslcPE: 1_001.1),
            tlcPE: 101.1,
            pslcPE: 1_001.1,
            powerOnHours: 103
        )
        let firstAfterUpdate = try ftl(
            date: boundaryDate.addingTimeInterval(9 * 86_400),
            sourceBuild: "26A428",
            firmware: "591",
            hostRaw: cHost,
            nandRaw: nandRaw(tlcPE: 102, pslcPE: 1_002),
            tlcPE: 102,
            pslcPE: 1_002,
            powerOnHours: 110,
            includeTopology: false
        )
        let updateWithTopology = try ftl(
            date: boundaryDate.addingTimeInterval(9 * 86_400 + 3_600),
            sourceBuild: "26A428",
            firmware: "591",
            hostRaw: cHost + 10_000,
            nandRaw: nandRaw(tlcPE: 102.1, pslcPE: 1_002.1),
            tlcPE: 102.1,
            pslcPE: 1_002.1,
            powerOnHours: 111
        )
        let smartHistory = [
            smart(date: base, firmware: "561.100", hostRaw: aHost, powerOnHours: 100),
            smart(date: boundaryDate, firmware: "561.100", hostRaw: bHost, powerOnHours: 101),
            smart(date: directWithTopology.capturedAt, firmware: "561.100", hostRaw: bHost + 10_000, powerOnHours: 103),
            smart(date: firstAfterUpdate.capturedAt, firmware: "591", hostRaw: cHost, powerOnHours: 110),
            smart(date: updateWithTopology.capturedAt, firmware: "591", hostRaw: cHost + 10_000, powerOnHours: 111)
        ]
        let snapshots = [firstDirect, directWithTopology, firstAfterUpdate, updateWithTopology]
        let lane = WearContinuityLaneBuilder.build(
            snapshots: snapshots,
            smart: smartHistory,
            latest: updateWithTopology
        )

        XCTAssertEqual(lane.snapshots.map(\.id), snapshots.map(\.id))
        XCTAssertEqual(lane.boundaries.count, 1)
        XCTAssertTrue(lane.boundaries.allSatisfy { $0.continuity.isVerified })
        XCTAssertTrue(lane.boundaries[0].boundary.hasPhysicalTransient)
        // Only two hours of Direct reads precede the update, too little to
        // compare the post-update WAF with, so the window stays excluded
        // from rate learning (see the C2 tests below).
        XCTAssertEqual(lane.rateLearningExclusions.count, 1)
        XCTAssertNotNil(lane.boundaries[0].rateLearningExclusion)
    }

    func testMissingSMARTKeepsTheBoundaryPending() throws {
        let (snapshots, _) = try pair(beforeInterval: 5 * 86_400)
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: [], latest: snapshots.last)

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isPending)
        XCTAssertEqual(InstrumentBoundaryPresentation.status(for: boundary), .evidencePending)
        XCTAssertNotNil(boundary.initialEvaluation)
        XCTAssertEqual(boundary.lastEvaluatedAt, boundary.boundary.after)
        XCTAssertEqual(lane.snapshots.count, 1)
        XCTAssertTrue(lane.rateLearningExclusions.isEmpty)
    }

    func testPendingInstrumentDoesNotBecomeTheNextBoundaryOrigin() throws {
        let firstDate = boundaryDate.addingTimeInterval(-2 * 3_600)
        let secondDate = boundaryDate.addingTimeInterval(-3_600)
        let thirdDate = boundaryDate
        let first = try ftl(
            date: firstDate,
            sourceBuild: "25G83",
            firmware: "561.100",
            hostRaw: 1_000_000_000,
            nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100,
            pslcPE: 1_000,
            powerOnHours: 100
        )
        let pending = try ftl(
            date: secondDate,
            sourceBuild: "26A123",
            firmware: "591",
            hostRaw: 1_100_000_000,
            nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101,
            pslcPE: 1_001,
            powerOnHours: 100
        )
        let newInstrument = try ftl(
            date: thirdDate,
            sourceBuild: "27A123",
            firmware: "601",
            hostRaw: 1_200_000_000,
            nandRaw: nandRaw(tlcPE: 102, pslcPE: 1_002),
            tlcPE: 102,
            pslcPE: 1_002,
            powerOnHours: 100
        )

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [first, pending, newInstrument],
            smart: [],
            latest: newInstrument
        )

        XCTAssertEqual(lane.snapshots.map(\.capturedAt), [firstDate])
        XCTAssertEqual(lane.boundaries.count, 2)
        XCTAssertEqual(lane.boundaries[0].boundary.before, firstDate)
        XCTAssertEqual(lane.boundaries[0].boundary.afterIdentity.firmwareEpoch, "591")
        XCTAssertEqual(lane.boundaries[1].boundary.before, firstDate)
        XCTAssertEqual(lane.boundaries[1].boundary.afterIdentity.firmwareEpoch, "601")
        XCTAssertTrue(lane.boundaries.allSatisfy(\.continuity.isPending))
        XCTAssertTrue(lane.rateLearningExclusions.isEmpty)
    }

    func testExtractionVersionAndUnitLabelsDoNotSplitTheWearLane() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100,
            extractionVersion: 1, unit: .provisional4KiB
        )
        let after = try ftl(
            date: boundaryDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101,
            extractionVersion: 2, unit: .verified
        )

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, after],
            smart: [
                smart(date: beforeDate, firmware: "561.100", hostRaw: 1_000_000_000, powerOnHours: 100),
                smart(date: boundaryDate, firmware: "561.100", hostRaw: 1_500_000_000, powerOnHours: 101)
            ],
            latest: after
        )

        XCTAssertEqual(lane.snapshots.count, 2)
        XCTAssertTrue(lane.boundaries.isEmpty)
    }

    func testResearchContractRevisionDoesNotSplitCoreWearLane() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100,
            directKeyContract: DirectFTLResearchContract.legacy25G83V24
        )
        let after = try ftl(
            date: boundaryDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101,
            directKeyContract: DirectFTLResearchContract.latest
        )
        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, after],
            smart: [
                smart(date: beforeDate, firmware: "561.100", hostRaw: 1_000_000_000, powerOnHours: 100),
                smart(date: boundaryDate, firmware: "561.100", hostRaw: 1_500_000_000, powerOnHours: 101)
            ],
            latest: after
        )

        XCTAssertTrue(lane.boundaries.isEmpty)
        XCTAssertEqual(lane.snapshots.count, 2)
    }

    func testDirectFormatChangeIsAuditedWithoutLearningExclusion() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100,
            directFormatVersion: nil
        )
        let after = try ftl(
            date: boundaryDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101,
            directFormatVersion: 1
        )
        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, after],
            smart: [
                smart(date: beforeDate, firmware: "561.100", hostRaw: 1_000_000_000, powerOnHours: 100),
                smart(date: boundaryDate, firmware: "561.100", hostRaw: 1_500_000_000, powerOnHours: 101)
            ],
            latest: after
        )

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertFalse(boundary.boundary.hasPhysicalTransient)
        XCTAssertNil(boundary.rateLearningExclusion)
    }

    func testProbeReleaseDoesNotSplitSameRuntimeBuildAndFirmware() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        func make(_ date: Date, _ probe: Int?) throws -> ASPToolDiagnosticsSnapshot {
            try ftl(
                date: date, sourceBuild: "25G83", firmware: "561.100",
                hostRaw: date == beforeDate ? 1_000_000_000 : 1_500_000_000,
                nandRaw: nandRaw(tlcPE: date == beforeDate ? 100 : 101, pslcPE: date == beforeDate ? 1_000 : 1_001),
                tlcPE: date == beforeDate ? 100 : 101,
                pslcPE: date == beforeDate ? 1_000 : 1_001,
                powerOnHours: date == beforeDate ? 100 : 101,
                probeVersion: probe
            )
        }
        let compatibleBefore = try make(beforeDate, nil)
        let compatibleAfter = try make(boundaryDate, 1)
        let compatibleLane = WearContinuityLaneBuilder.build(
            snapshots: [compatibleBefore, compatibleAfter], smart: [], latest: compatibleAfter
        )
        XCTAssertTrue(compatibleLane.boundaries.isEmpty)
        XCTAssertTrue(compatibleLane.instrumentMetadataChanges.isEmpty,
                      "nil→1 is metadata enrichment, not a version transition")

        let probeOne = try make(beforeDate, 1)
        let probeTwo = try make(boundaryDate, 2)
        let auditedLane = WearContinuityLaneBuilder.build(
            snapshots: [probeOne, probeTwo], smart: [], latest: probeTwo
        )
        XCTAssertTrue(auditedLane.boundaries.isEmpty)
        let metadataChange = try XCTUnwrap(auditedLane.instrumentMetadataChanges.first)
        XCTAssertEqual(metadataChange.beforeAt, beforeDate)
        XCTAssertEqual(metadataChange.afterAt, boundaryDate)
        XCTAssertEqual(metadataChange.changedAttributes, ["probe版 1 → 2"])
        XCTAssertEqual(auditedLane.snapshots.count, 2)
    }

    func testOSBuildChangeAloneIsAuditedAndBridgedOnlyAfterCounterChecks() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "26A428", firmware: "591",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )
        let after = try ftl(
            date: boundaryDate, sourceBuild: "27A123", firmware: "591",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101
        )
        let smartHistory = [
            smart(date: beforeDate, firmware: "591", hostRaw: 1_000_000_000, powerOnHours: 100),
            smart(date: boundaryDate, firmware: "591", hostRaw: 1_500_000_000, powerOnHours: 101)
        ]

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, after], smart: smartHistory, latest: after
        )

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertEqual(lane.boundaries.count, 1)
        XCTAssertEqual(boundary.boundary.beforeIdentity.runtimeBuild, "26A428")
        XCTAssertEqual(boundary.boundary.afterIdentity.runtimeBuild, "27A123")
        XCTAssertEqual(boundary.boundary.beforeIdentity.firmwareEpoch, "591")
        XCTAssertEqual(boundary.boundary.afterIdentity.firmwareEpoch, "591")
        XCTAssertTrue(boundary.continuity.isVerified)
        // Same SSD firmware: an OS update does not change controller behaviour.
        XCTAssertFalse(boundary.boundary.hasPhysicalTransient)
        let displaySummary = InstrumentBoundaryPresentation.rawDataViewerSummary(for: boundary)
        XCTAssertTrue(displaySummary.contains("OS build境界"))
        XCTAssertTrue(displaySummary.contains("WAF学習除外なし"))
        XCTAssertEqual(lane.snapshots.map(\.capturedAt), [beforeDate, boundaryDate])
        XCTAssertNil(boundary.rateLearningExclusion)
        XCTAssertTrue(lane.rateLearningExclusions.isEmpty)
    }

    /// C2: a firmware boundary is excluded from rate learning only when the
    /// WAF over the 72 hours after it departs from the preceding 7 days.
    private func firmwareBoundaryLane(postTLCPE: Double, postPSLCPE: Double) throws -> WearContinuityLane {
        let hostStep: UInt64 = 60_000_000
        let dates = [
            boundaryDate.addingTimeInterval(-3 * 86_400),
            boundaryDate.addingTimeInterval(-3_600),
            boundaryDate,
            boundaryDate.addingTimeInterval(24 * 3_600)
        ]
        let hosts: [UInt64] = [1_000_000_000, 1_000_000_000 + hostStep, 1_000_000_000 + hostStep + 1_000, 1_000_000_000 + 2 * hostStep]
        let pes: [(Double, Double)] = [(100, 1_000), (101, 1_001), (101, 1_001), (postTLCPE, postPSLCPE)]
        let firmwares = ["591", "591", "592", "592"]
        var snapshots: [ASPToolDiagnosticsSnapshot] = []
        var smartHistory: [DriveSnapshot] = []
        for index in dates.indices {
            snapshots.append(try ftl(
                date: dates[index], sourceBuild: "26A434", firmware: firmwares[index],
                hostRaw: hosts[index], nandRaw: nandRaw(tlcPE: pes[index].0, pslcPE: pes[index].1),
                tlcPE: pes[index].0, pslcPE: pes[index].1, powerOnHours: UInt64(100 + index * 24)
            ))
            smartHistory.append(smart(date: dates[index], firmware: firmwares[index], hostRaw: hosts[index],
                                      powerOnHours: UInt64(100 + index * 24)))
        }
        return WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last!)
    }

    func testFirmwareBoundaryWithSteadyWAFIsNotExcluded() throws {
        let lane = try firmwareBoundaryLane(postTLCPE: 102, postPSLCPE: 1_002)
        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertTrue(boundary.boundary.hasPhysicalTransient)
        XCTAssertNil(boundary.rateLearningExclusion)
        XCTAssertTrue(lane.rateLearningExclusions.isEmpty)
    }

    func testFirmwareBoundaryAboveTwentyFivePercentIsExcluded() throws {
        // Like the FW 591 update on the reference Mac: post-update WAF +28%.
        let lane = try firmwareBoundaryLane(postTLCPE: 102.28, postPSLCPE: 1_002.28)
        XCTAssertNotNil(try XCTUnwrap(lane.boundaries.first).rateLearningExclusion)
    }

    func testFirmwareBoundaryWithinTwentyFivePercentIsNotExcluded() throws {
        let lane = try firmwareBoundaryLane(postTLCPE: 102.2, postPSLCPE: 1_002.2)
        XCTAssertNil(try XCTUnwrap(lane.boundaries.first).rateLearningExclusion)
    }

    func testFirmwareBoundaryWithPostUpdateWAFSpikeIsExcluded() throws {
        // Twice the NAND work for the same host writes after the update.
        let lane = try firmwareBoundaryLane(postTLCPE: 103, postPSLCPE: 1_003)
        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.boundary.hasPhysicalTransient)
        XCTAssertEqual(boundary.rateLearningExclusion?.end, boundaryDate.addingTimeInterval(72 * 3_600))
    }

    func testFirmwareChangeAloneIsAuditedAndBridgedOnlyAfterCounterChecks() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "26A428", firmware: "591",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )
        let after = try ftl(
            date: boundaryDate, sourceBuild: "26A428", firmware: "592",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101
        )
        let smartHistory = [
            smart(date: beforeDate, firmware: "591", hostRaw: 1_000_000_000, powerOnHours: 100),
            smart(date: boundaryDate, firmware: "592", hostRaw: 1_500_000_000, powerOnHours: 101)
        ]

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, after], smart: smartHistory, latest: after
        )

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertEqual(lane.boundaries.count, 1)
        XCTAssertEqual(boundary.boundary.beforeIdentity.runtimeBuild, "26A428")
        XCTAssertEqual(boundary.boundary.afterIdentity.runtimeBuild, "26A428")
        XCTAssertEqual(boundary.boundary.beforeIdentity.firmwareEpoch, "591")
        XCTAssertEqual(boundary.boundary.afterIdentity.firmwareEpoch, "592")
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertTrue(boundary.boundary.hasPhysicalTransient)
        let displaySummary = InstrumentBoundaryPresentation.rawDataViewerSummary(for: boundary)
        XCTAssertTrue(displaySummary.contains("FW境界"))
        // No 7-day baseline exists, so the post-update WAF cannot be judged
        // and the conservative exclusion stays.
        XCTAssertTrue(displaySummary.contains("境界後72時間を学習除外"))
        XCTAssertEqual(lane.snapshots.map(\.capturedAt), [beforeDate, boundaryDate])
        XCTAssertEqual(boundary.rateLearningExclusion?.start, beforeDate)
        XCTAssertEqual(boundary.rateLearningExclusion?.end, boundaryDate.addingTimeInterval(72 * 3_600))
    }

    func testLegacyFirmwareOverlayBridgesToFirstRecordedBuildWithoutExtraBoundary() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let legacy = try ftl(
            date: beforeDate, sourceBuild: "25G83", firmware: "591",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100,
            contractBuild: nil
        )
        let recorded = try ftl(
            date: boundaryDate, sourceBuild: "26A428", firmware: "591",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101
        )

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [legacy, recorded], smart: [], latest: recorded
        )

        XCTAssertEqual(
            InstrumentIdentity.resolved(from: legacy).identity.runtimeBuild,
            "unrecorded-after-fw-591"
        )
        XCTAssertTrue(lane.boundaries.isEmpty)
        XCTAssertEqual(lane.snapshots.map(\.capturedAt), [beforeDate, boundaryDate])
    }

    func testLegacyReviewedBuildInfersStableCoreWearContract() throws {
        let legacy = try ftl(
            date: boundaryDate,
            sourceBuild: "25G83",
            firmware: "561.100",
            hostRaw: 1_000_000_000,
            nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100,
            pslcPE: 1_000,
            powerOnHours: 100,
            directKeyContract: nil
        )

        XCTAssertEqual(legacy.resolvedCoreWearVersion, DirectFTLResearchContract.reviewed25G83CoreV1)
    }

    func testBoundaryCanUseLaterValidatedTopologyForLegacySnapshotWithoutIt() throws {
        let (snapshots, smartHistory) = try pair(beforeHasTopology: false)
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d1Geometry }?.detail.contains("片側") == true)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d2Topology }?.detail.contains("片側") == true)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d7LifetimeResidual }?.detail.contains("片側") == true)
        XCTAssertEqual(lane.snapshots.count, 2)
    }

    func testVerifiedInstrumentBoundaryKeepsAllPostBoundarySnapshots() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )
        let pending = try ftl(
            date: boundaryDate, sourceBuild: "26A428", firmware: "591",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 200, pslcPE: 1_100),
            tlcPE: 200, pslcPE: 1_100, powerOnHours: 101
        )
        let verified = try ftl(
            date: boundaryDate.addingTimeInterval(24 * 3_600), sourceBuild: "26A428", firmware: "591",
            hostRaw: 1_600_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 102
        )
        let smartHistory = [
            smart(date: beforeDate, firmware: "561.100", hostRaw: 1_000_000_000, powerOnHours: 100),
            smart(date: boundaryDate, firmware: "591", hostRaw: 1_500_000_000, powerOnHours: 101),
            smart(date: verified.capturedAt, firmware: "591", hostRaw: 1_600_000_000, powerOnHours: 102)
        ]
        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, pending, verified], smart: smartHistory, latest: verified
        )

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertTrue(try XCTUnwrap(boundary.initialEvaluation).continuity.isVerified)
        XCTAssertEqual(boundary.initialEvaluation?.evaluatedAt, boundaryDate)
        XCTAssertEqual(boundary.lastEvaluatedAt, boundaryDate)
        XCTAssertEqual(InstrumentBoundaryPresentation.status(for: boundary), .verified)
        XCTAssertEqual(lane.snapshots.map(\.capturedAt), [beforeDate, boundaryDate, verified.capturedAt])
        XCTAssertEqual(lane.rateLearningExclusions.count, 1)
        XCTAssertEqual(try XCTUnwrap(lane.rateLearningExclusions.first?.duration), 73 * 3_600, accuracy: 0.001)
    }

    func testPendingBoundaryRetainsFirstEvaluationWhenLaterSMARTResolvesIt() throws {
        let beforeDate = boundaryDate.addingTimeInterval(-48 * 3_600)
        let verifiedDate = boundaryDate.addingTimeInterval(48 * 3_600)
        let before = try ftl(
            date: beforeDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100
        )
        let initialBoundary = try ftl(
            date: boundaryDate, sourceBuild: "26A428", firmware: "591",
            hostRaw: 1_500_000_000, nandRaw: nandRaw(tlcPE: 101, pslcPE: 1_001),
            tlcPE: 101, pslcPE: 1_001, powerOnHours: 101
        )
        let later = try ftl(
            date: verifiedDate, sourceBuild: "26A428", firmware: "591",
            hostRaw: 1_600_000_000, nandRaw: nandRaw(tlcPE: 102, pslcPE: 1_002),
            tlcPE: 102, pslcPE: 1_002, powerOnHours: 102
        )
        let smartHistory = [
            smart(date: beforeDate, firmware: "561.100", hostRaw: 1_000_000_000, powerOnHours: 100),
            smart(date: verifiedDate, firmware: "591", hostRaw: 1_600_000_000, powerOnHours: 102)
        ]

        let lane = WearContinuityLaneBuilder.build(
            snapshots: [before, initialBoundary, later],
            smart: smartHistory,
            latest: later
        )

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertEqual(lane.boundaries.count, 1, "boundary records=\(lane.boundaries)")
        XCTAssertTrue(try XCTUnwrap(boundary.initialEvaluation).continuity.isPending)
        XCTAssertEqual(boundary.initialEvaluation?.evaluatedAt, boundaryDate)
        XCTAssertTrue(boundary.continuity.isVerified)
        XCTAssertEqual(boundary.lastEvaluatedAt, verifiedDate)
        XCTAssertEqual(InstrumentBoundaryPresentation.status(for: boundary), .verified)
        XCTAssertEqual(lane.snapshots.map(\.capturedAt), [beforeDate, boundaryDate, verifiedDate])
    }

    func testDeviceChangeIsRecordedAndResetsTheAcceptedLane() throws {
        let first = try ftl(
            date: boundaryDate.addingTimeInterval(-3_600), sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100, deviceID: "disk0"
        )
        let second = try ftl(
            date: boundaryDate, sourceBuild: "25G83", firmware: "561.100",
            hostRaw: 1_000_000_000, nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100, pslcPE: 1_000, powerOnHours: 100, deviceID: "disk1"
        )
        let lane = WearContinuityLaneBuilder.build(snapshots: [first, second], smart: [], latest: second)

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.title.contains("デバイス"))
        XCTAssertEqual(InstrumentBoundaryPresentation.status(for: boundary), .deviceChange)
        XCTAssertTrue(InstrumentBoundaryPresentation.changedAttributes(for: boundary).contains("物理デバイス識別子が変更（値は非表示）"))
        let tooltip = InstrumentBoundaryPresentation.tooltip(for: boundary)
        XCTAssertFalse(tooltip.contains("disk0"))
        XCTAssertFalse(tooltip.contains("disk1"))
        XCTAssertTrue(tooltip.contains("D1:"))
        XCTAssertTrue(tooltip.contains("D8:"))
        XCTAssertEqual(InstrumentBoundaryPresentation.legendItems(for: [boundary]).map(\.status), [.deviceChange])
        XCTAssertTrue(InstrumentBoundaryPresentation.visibleRecords([boundary], in: [boundary.boundary.after]).count == 1)
        XCTAssertTrue(InstrumentBoundaryPresentation.visibleRecords([boundary], in: [boundary.boundary.before.addingTimeInterval(-1)]).isEmpty)
        XCTAssertEqual(lane.snapshots.map(\.deviceID), ["disk1"])
    }

    func testD5RejectsAKeyThatIsMonotonicButDoesNotMatchSMARTHost() throws {
        let (snapshots, smartHistory) = try pair(afterHostRaw: 1_600_000_000)
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isFailed)
        XCTAssertFalse(boundary.checks.first { $0.kind == .d5SmartHostRatio }?.passed ?? true)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d7LifetimeResidual }?.passed == true)
        XCTAssertEqual(lane.snapshots.count, 1)
        XCTAssertTrue(lane.rateLearningExclusions.isEmpty)
    }

    func testD7RejectsAChangedLifetimeResidualWithoutRejectingD5() throws {
        let (baseline, _) = try pair()
        let afterNAND = baseline[1].nandWrites!
        let (snapshots, smartHistory) = try pair(afterTLCPE: 200, afterPSLCPE: 1_100, afterNANDRaw: afterNAND)
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)

        let boundary = try XCTUnwrap(lane.boundaries.first)
        XCTAssertTrue(boundary.continuity.isPending, "D7不一致は境界後72時間未満ならsettlingとして保留する")
        XCTAssertEqual(InstrumentBoundaryPresentation.status(for: boundary), .settlingWait)
        XCTAssertTrue(boundary.checks.first { $0.kind == .d5SmartHostRatio }?.passed == true)
        XCTAssertFalse(boundary.checks.first { $0.kind == .d7LifetimeResidual }?.passed ?? true)
    }

    func testBoundaryRecordRemainsDecodableWithoutDisplayEnrichment() throws {
        let (snapshots, smartHistory) = try pair()
        let lane = WearContinuityLaneBuilder.build(snapshots: snapshots, smart: smartHistory, latest: snapshots.last)
        let record = try XCTUnwrap(lane.boundaries.first)
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "initialEvaluation")
        object.removeValue(forKey: "lastEvaluatedAt")
        object.removeValue(forKey: "beforeBuildProvenance")
        object.removeValue(forKey: "afterBuildProvenance")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(InstrumentBoundaryRecord.self, from: legacyData)
        XCTAssertNil(decoded.initialEvaluation)
        XCTAssertNil(decoded.lastEvaluatedAt)
        XCTAssertNil(decoded.beforeBuildProvenance)
        XCTAssertNil(decoded.afterBuildProvenance)
        XCTAssertEqual(decoded.boundary, record.boundary)
    }

    func testLegacyBuildOverlayIsAnalysisOnlyAndPreservesTheRawLabel() throws {
        let legacy561 = try ftl(
            date: boundaryDate,
            sourceBuild: "25G83",
            firmware: "561.100",
            hostRaw: 1_000_000_000,
            nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100,
            pslcPE: 1_000,
            powerOnHours: 100,
            contractBuild: nil,
            directKeyContract: nil
        )
        let overlay561 = LegacyBuildOverlay.resolve(legacy561, smartHistory: [])
        XCTAssertEqual(overlay561.build, "25G83")
        XCTAssertEqual(overlay561.provenance, .inferred)
        XCTAssertNil(legacy561.contractBuild)
        XCTAssertEqual(legacy561.sourceBuild, "25G83")

        let legacy591 = try ftl(
            date: boundaryDate,
            sourceBuild: "25G83",
            firmware: "591",
            hostRaw: 1_000_000_000,
            nandRaw: nandRaw(tlcPE: 100, pslcPE: 1_000),
            tlcPE: 100,
            pslcPE: 1_000,
            powerOnHours: 100,
            contractBuild: nil,
            directKeyContract: nil
        )
        let overlay591 = LegacyBuildOverlay.resolve(legacy591, smartHistory: [])
        XCTAssertEqual(overlay591.build, "unrecorded-after-fw-591")
        XCTAssertEqual(overlay591.provenance, .inferred)
        XCTAssertEqual(legacy591.sourceBuild, "25G83")
    }

    func testProbeAndFTLMetadataSeparateRuntimeBuildFromReviewedContract() throws {
        let probeOnLaterBuild = try ASPDirectProbeMetadataParser().parse(text: probeMetadata(
            build: "26A428", contractBuild: "25G83", probeVersion: 2
        ))
        XCTAssertEqual(probeOnLaterBuild.build, "26A428")
        XCTAssertEqual(probeOnLaterBuild.contractBuild, "25G83")
        XCTAssertTrue(probeOnLaterBuild.isReviewedInterface)
        XCTAssertFalse(probeOnLaterBuild.runsOnReviewedBuild)

        let probeOnReviewedBuild = try ASPDirectProbeMetadataParser().parse(text: probeMetadata(
            build: "25G83", contractBuild: "25G83", probeVersion: 2
        ))
        XCTAssertTrue(probeOnReviewedBuild.isReviewedInterface)
        XCTAssertTrue(probeOnReviewedBuild.runsOnReviewedBuild)

        let legacyProbe = try ASPDirectProbeMetadataParser().parse(text: probeMetadata(
            build: "25G83", contractBuild: nil, probeVersion: nil
        ))
        XCTAssertTrue(legacyProbe.isReviewedInterface, "旧metadataは解析時のoverlayへ渡せる必要がある")
        XCTAssertFalse(legacyProbe.runsOnReviewedBuild)

        let laterFTL = try ASPToolDirectFTLMetadataParser().parse(text: ftlMetadata(
            build: "27A100", contractBuild: "25G83", probeVersion: 2
        ))
        XCTAssertTrue(laterFTL.isReviewedInterface)
        XCTAssertFalse(laterFTL.runsOnReviewedBuild)

        // A later build of a reviewed macOS major version is accepted.
        let sameMajorFTL = try ASPToolDirectFTLMetadataParser().parse(text: ftlMetadata(
            build: "26A428", contractBuild: "25G83", probeVersion: 2
        ))
        XCTAssertTrue(sameMajorFTL.runsOnReviewedBuild)

        let unreviewedFTL = try ASPToolDirectFTLMetadataParser().parse(text: ftlMetadata(
            build: "26A428", contractBuild: "26A428", probeVersion: 3
        ))
        XCTAssertFalse(unreviewedFTL.isReviewedInterface)
        XCTAssertThrowsError(try ASPToolDirectFTLParser().parse(
            data: Data(repeating: 0, count: 1), measurement: unreviewedFTL
        )) { error in
            XCTAssertEqual(error as? ASPToolDirectFTLParserError, .unsupportedTarget)
        }
    }

    private func probeMetadata(build: String, contractBuild: String?, probeVersion: Int?) -> String {
        let contract = contractBuild.map { "contractBuild=\($0)\n" } ?? ""
        let version = probeVersion.map { "probeVersion=\($0)\n" } ?? ""
        return """
        build=\(build)
        \(contract)\(version)controller=AppleANS3NVMeController
        selector=9
        opcode=0x16
        role=time-sensitive snapshot payload
        euid=0
        captured_at_epoch=1800000000
        size_query_result=0x00000000
        size_query_response_bytes=4
        requested_bytes=854016
        snapshot_read_attempted=1
        snapshot_read_result=0x00000000
        snapshot_read_response_bytes=854016
        capacity_bytes=854016
        payload_bytes=854016
        size_query_elapsed_ms=0.120
        snapshot_read_elapsed_ms=4.250
        total_elapsed_ms=4.500
        format_status=unconfirmed
        """
    }

    private func ftlMetadata(build: String, contractBuild: String?, probeVersion: Int?) -> String {
        let contract = contractBuild.map { "contractBuild=\($0)\n" } ?? ""
        let version = probeVersion.map { "probeVersion=\($0)\n" } ?? ""
        return """
        build=\(build)
        \(contract)\(version)service=GetNVMeSMARTInterface
        plugin_uuid=AA0FA6F9-C2D6-457F-B10B-59A13253292F
        interface_uuid=CCD1DB19-FD9A-4DAF-BF95-12454B230AB6
        kind=all
        vtable_offset=0x108
        input_arg=null
        role=ASP FTL all statistics
        euid=0
        captured_at_epoch=1800000000
        result=0x00000000
        response_bytes=8
        capacity_bytes=1048576
        elapsed_ms=1.0
        total_elapsed_ms=1.2
        format_status=unconfirmed
        """
    }
}
