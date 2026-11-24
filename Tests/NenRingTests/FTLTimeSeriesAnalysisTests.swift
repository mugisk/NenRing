import Foundation
import XCTest
@testable import NenRing

final class FTLTimeSeriesAnalysisTests: XCTestCase {
    func testDashboardReliabilityLabelsKeepRecoverySeparateFromFailure() {
        XCTAssertEqual(ReliabilityMetricLabel.text("UECC reads", language: "ja"), "訂正不能読出し（UECC）")
        XCTAssertEqual(ReliabilityMetricLabel.text("Read verify native", language: "ja"), "TLC読出し検証")
        XCTAssertEqual(ReliabilityMetricLabel.text("Host TLC read verify failures", language: "en"), "Host TLC read verify failures")
        XCTAssertEqual(ReliabilityMetricLabel.text("unknown-key-123", language: "ja"), "unknown-key-123")
    }

    private let contract = DirectFTLResearchContract.latest

    private func reliabilityEvidence(
        state: FTLReliabilityState,
        counters: [FTLReliabilityCounterDelta]
    ) -> FTLReliabilityEvidence {
        FTLReliabilityEvidence(
            baselineCapturedAt: nil,
            comparedAt: nil,
            durationDays: nil,
            wallDurationDays: nil,
            operatingHoursDelta: nil,
            durationBasis: .unavailable,
            researchSessionOverlap: false,
            state: state,
            reason: "fixture reason",
            counters: counters,
            unavailableCounters: [],
            unmappedItems: [],
            latestTelemetry: nil,
            hostWriteCompositionAudit: nil
        )
    }

    func testReliabilityCardUsesThreeStatesAndRequiresComparableEventCounter() {
        let pending = FTLReliabilityCardPresentation.make(evidence: nil, events: [])
        XCTAssertEqual(pending.state, .comparisonPending)
        XCTAssertEqual(pending.state.title, "比較待ち")

        let noEventCounters = reliabilityEvidence(state: .noNewObservedEvent, counters: [])
        XCTAssertEqual(
            FTLReliabilityCardPresentation.make(evidence: noEventCounters, events: []).state,
            .comparisonPending,
            "A computed no-event state without any comparable hard-event counter is not evidence of a clean range"
        )

        let comparedZero = FTLReliabilityCounterDelta(
            name: "UECC",
            delta: 0,
            perDay: 0,
            perNANDRead: nil,
            isReliabilityEvent: true
        )
        let clear = FTLReliabilityCardPresentation.make(
            evidence: reliabilityEvidence(state: .noNewObservedEvent, counters: [comparedZero]),
            events: []
        )
        XCTAssertEqual(clear.state, .noAnomalyObserved)
        XCTAssertEqual(clear.state.title, "取得範囲で異常なし")

        let increase = FTLReliabilityCounterDelta(
            name: "UECC",
            delta: 2,
            perDay: 2,
            perNANDRead: nil,
            isReliabilityEvent: true
        )
        let event = FTLReliabilityCardPresentation.make(
            evidence: reliabilityEvidence(state: .reliabilityEventObserved, counters: [increase]),
            events: []
        )
        XCTAssertEqual(event.state, .eventPresent)
        XCTAssertEqual(event.state.title, "eventあり")
        XCTAssertEqual(event.detail, "UECC +2")

        // A long pending reason would be cut off in the card; it shows the
        // state and keeps the reason for the hover text.
        let unreviewed = FTLReliabilityCardPresentation.make(
            evidence: reliabilityEvidence(state: .researchContractUnreviewed, counters: []),
            events: []
        )
        XCTAssertEqual(unreviewed.detail, "研究用keyの対応表が未確認")
        XCTAssertEqual(unreviewed.explanation, "fixture reason")
    }

    private func telemetry(
        reads: UInt64,
        age: UInt64,
        background: UInt64,
        reducedReadVerify: UInt64,
        crossTemperature: UInt64,
        uecc: UInt64,
        histogram: [UInt64],
        bandsPaddedForAge: UInt64? = nil,
        bandsRefreshedOnError: UInt64? = nil
    ) -> FTLResearchTelemetrySnapshot {
        FTLResearchTelemetrySnapshot(
            nandReads: reads,
            ageRefreshPerTier: [age],
            backgroundRefreshMoves: background,
            bandsPaddedForAge: bandsPaddedForAge,
            crossTemperatureUECC: crossTemperature,
            ueccReads: uecc,
            reducedReadVerifyNative: reducedReadVerify,
            bandsCrossTempHistogram: histogram,
            bandsRefreshedOnError: bandsRefreshedOnError
        )
    }

    private func snapshot(
        _ day: Double,
        host: UInt64,
        nand: UInt64,
        tlc: Double,
        pslc: Double,
        telemetry: FTLResearchTelemetrySnapshot,
        grownBadBlocks: UInt64 = 0,
        identityCapturedAt: Date? = Date(timeIntervalSince1970: 1_699_999_000),
        powerOnHours: UInt64? = nil,
        topology: DirectFTLTopology? = nil,
        historySchemaVersion: Int? = 2,
        semanticContractVersion: String? = DirectFTLResearchContract.latest,
        directKeyContractVersion: String? = DirectFTLResearchContract.latest,
        coreWearContractVersion: String? = nil,
        sourceBuild: String = DirectFTLResearchContract.reviewedBuild,
        contractBuild: String? = nil,
        firmware: String = "FW1",
        directFormatVersion: UInt32? = 1,
        intermediateBandsProgrammed: UInt64? = nil,
        userBandsProgrammed: UInt64? = nil
    ) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + day * 86_400),
            captureQuality: .explicit,
            deviceID: "test-drive",
            sourceArtifact: .directFTL,
            sourceBuild: sourceBuild,
            contractBuild: contractBuild,
            extractionVersion: 2,
            historySchemaVersion: historySchemaVersion,
            semanticContractVersion: semanticContractVersion,
            coreWearContractVersion: coreWearContractVersion,
            identityCapturedAt: identityCapturedAt,
            hostWrites: host,
            nandWrites: nand,
            hostWritesUnitState: .provisional4KiB,
            nandWritesUnitState: .provisional4KiB,
            tlcAveragePE: tlc,
            tlcEOLPE: 3_000,
            slcAveragePE: pslc,
            slcEOLPE: 100_000,
            powerOnHours: powerOnHours,
            firmware: firmware,
            grownBadBlocks: grownBadBlocks,
            intermediateBandsProgrammed: intermediateBandsProgrammed,
            userBandsProgrammed: userBandsProgrammed,
            directFormatVersion: directFormatVersion,
            directKeyContractVersion: directKeyContractVersion,
            directTopology: topology,
            researchTelemetry: telemetry
        )
    }

    func testTimeSeriesBuildsRatesHistogramDeltaPECorrelationAndEventHistory() throws {
        let samples = [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 1_000, age: 10, background: 20, reducedReadVerify: 5,
                                          crossTemperature: 2, uecc: 4, histogram: [10, 0, 2])),
            snapshot(1, host: 200, nand: 500, tlc: 110, pslc: 2_200,
                     telemetry: telemetry(reads: 2_000, age: 13, background: 25, reducedReadVerify: 7,
                                          crossTemperature: 4, uecc: 6, histogram: [15, 0, 3]),
                     grownBadBlocks: 1),
            snapshot(2, host: 400, nand: 900, tlc: 125, pslc: 2_500,
                     telemetry: telemetry(reads: 4_000, age: 20, background: 30, reducedReadVerify: 10,
                                          crossTemperature: 5, uecc: 9, histogram: [18, 1, 4]),
                     grownBadBlocks: 1)
        ]

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)

        XCTAssertEqual(result.intervals.count, 2)
        XCTAssertEqual(try XCTUnwrap(result.intervals[0].observedWAF), 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.intervals[0].metricValues[.reducedReadVerifyPerNANDRead]), 0.002, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.intervals[0].metricValues[.ageRefreshPerDay]), 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.intervals[0].metricValues[.crossTemperatureUECCPerNANDRead]), 0.002, accuracy: 1e-12)
        XCTAssertEqual(result.intervals[0].histogramDeltas.first?.bins, [5, 0, 1])
        XCTAssertEqual(result.reliabilityEvents.count, 5, "cross-temp UECC, UECC, and grown bad block deltas")
        XCTAssertTrue(result.reliabilityEvents.contains { $0.type == .grownBadBlocks && $0.delta == 1 })
        XCTAssertTrue(result.peCorrelationPoints.contains { $0.tlcPE == 110 && $0.metric == .ageRefreshPerDay })
        XCTAssertTrue(result.peCorrelationPoints.contains { $0.tlcPE == 110 && $0.metric == .ageRefreshPerWallDay })
        XCTAssertTrue(result.peCorrelationPoints.contains { $0.tlcPE == 110 && $0.metric == .observedWAF && $0.value == 3 })
    }

    func testLosslessStoragePreservesWAFWearResidualsAndReliabilityStatistics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LosslessFTLStats-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("asptool-snapshots.jsonl")
        let samples: [ASPToolDiagnosticsSnapshot] = (0..<300).map { index in
            let host = UInt64(1_000_000_000 + index * 1_000_000)
            let extra = max(0, index - 240) * 1_000_000
            let nand = UInt64(2_000_000_000 + index * 2_000_000 + extra)
            let values = telemetry(reads: UInt64(10_000 + index * 100), age: UInt64(index / 7),
                background: UInt64(index / 5), reducedReadVerify: UInt64(index / 10),
                crossTemperature: UInt64(index / 61), uecc: UInt64(index / 71), histogram: [10, 0, 2])
            return snapshot(Double(index) / 8, host: host, nand: nand,
                tlc: Double(100 + index / 24), pslc: Double(3_300 + index * 3),
                telemetry: values,
                grownBadBlocks: UInt64(index / 250), powerOnHours: UInt64(1_000 + index * 3))
        }
        let store = ASPToolSnapshotStore(fileURL: url)
        for sample in samples { _ = try await store.appendIfNew(sample) }
        let restored = try await ASPToolSnapshotStore(fileURL: url).records()
        XCTAssertEqual(restored, samples)
        let analyzer = FTLTimeSeriesAnalyzer()
        let expected = analyzer.analyze(snapshots: samples)
        XCTAssertFalse(expected.reliabilityEvents.isEmpty)
        XCTAssertGreaterThan(expected.intervals.count, 250)
        XCTAssertEqual(analyzer.analyze(snapshots: restored), expected,
            "interval timing, quantized P/E steps, histograms, residuals and event deltas must all survive")
        let waf = RetentionWAFAnalyzer()
        let now = try XCTUnwrap(samples.last).capturedAt
        let originalWAF = waf.assess(snapshots: samples, latest: samples.last!, now: now, excluding: [], client: 3.5,
            selection: nil, trials: [])
        XCTAssertNotEqual(originalWAF.windows[0].value, originalWAF.windows[1].value)
        XCTAssertEqual(waf.assess(snapshots: restored, latest: restored.last!, now: now, excluding: [], client: 3.5,
            selection: nil, trials: []), originalWAF)
    }

    func testHistogramShapeMismatchDoesNotDiscardOtherIntervalMetrics() throws {
        let samples = [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 1_000, age: 10, background: 20, reducedReadVerify: 5,
                                          crossTemperature: 2, uecc: 4, histogram: [10, 0, 2])),
            snapshot(1, host: 200, nand: 400, tlc: 105, pslc: 2_100,
                     telemetry: telemetry(reads: 2_000, age: 12, background: 21, reducedReadVerify: 6,
                                          crossTemperature: 2, uecc: 4, histogram: [12, 1]))
        ]

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)

        XCTAssertEqual(result.intervals.count, 1)
        XCTAssertTrue(result.intervals[0].histogramDeltas.isEmpty)
        XCTAssertEqual(try XCTUnwrap(result.intervals[0].metricValues[.ageRefreshPerDay]), 2, accuracy: 1e-12)
        XCTAssertTrue(result.notes.contains { $0.contains("histogram") })
    }

    func testResetAndExcludedResearchIntervalBreakTheAnchor() throws {
        let samples = [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [1])),
            snapshot(1, host: 90, nand: 190, tlc: 101, pslc: 2_010,
                     telemetry: telemetry(reads: 110, age: 2, background: 2, reducedReadVerify: 2,
                                          crossTemperature: 0, uecc: 0, histogram: [2])),
            snapshot(2, host: 120, nand: 250, tlc: 102, pslc: 2_020,
                     telemetry: telemetry(reads: 120, age: 3, background: 3, reducedReadVerify: 3,
                                          crossTemperature: 0, uecc: 0, histogram: [3]))
        ]
        let resetResult = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        XCTAssertEqual(resetResult.intervals.count, 1, "reset後は新しいanchorから比較を再開する")
        XCTAssertEqual(resetResult.intervals[0].startAt, samples[1].capturedAt)
        XCTAssertTrue(resetResult.notes.contains { $0.contains("reset") })

        let excluded = DateInterval(
            start: samples[0].capturedAt,
            end: samples[0].capturedAt.addingTimeInterval(12 * 60 * 60)
        )
        let excludedResult = FTLTimeSeriesAnalyzer().analyze(snapshots: [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [1])),
            snapshot(1, host: 120, nand: 250, tlc: 102, pslc: 2_020,
                     telemetry: telemetry(reads: 120, age: 3, background: 3, reducedReadVerify: 3,
                                          crossTemperature: 0, uecc: 0, histogram: [2])),
            snapshot(2, host: 150, nand: 310, tlc: 104, pslc: 2_040,
                     telemetry: telemetry(reads: 140, age: 5, background: 5, reducedReadVerify: 5,
                                          crossTemperature: 0, uecc: 0, histogram: [3]))
        ], excluding: [excluded])
        XCTAssertEqual(excludedResult.intervals.count, 1)
        XCTAssertEqual(excludedResult.intervals[0].startAt, samples[1].capturedAt)
        // The excluded interval stays out of learning but is kept for charts.
        XCTAssertEqual(excludedResult.learningExcludedIntervals.count, 1)
        XCTAssertEqual(excludedResult.learningExcludedIntervals[0].startAt, samples[0].capturedAt)
        XCTAssertNotNil(excludedResult.learningExcludedIntervals[0].deltaNANDBytes)
        // A bad block that grew during the excluded interval is still an event.
        let grewDuringExclusion = FTLTimeSeriesAnalyzer().analyze(snapshots: [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [1])),
            snapshot(1, host: 120, nand: 250, tlc: 102, pslc: 2_020,
                     telemetry: telemetry(reads: 120, age: 3, background: 3, reducedReadVerify: 3,
                                          crossTemperature: 0, uecc: 2, histogram: [2]),
                     grownBadBlocks: 1)
        ], excluding: [excluded])
        XCTAssertTrue(grewDuringExclusion.intervals.isEmpty)
        XCTAssertTrue(grewDuringExclusion.reliabilityEvents.contains { $0.type == .grownBadBlocks && $0.delta == 1 })
        XCTAssertTrue(grewDuringExclusion.reliabilityEvents.contains { $0.type == .UECC && $0.delta == 2 })
        // The dashboard always merges the event journal before drawing.
        XCTAssertEqual(excludedResult.merging(journalRecords: []).learningExcludedIntervals,
                       excludedResult.learningExcludedIntervals)
    }

    func testHostZeroStillProducesRecoveryRatesAndTimestampIsCodable() throws {
        let first = snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                             telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                                  crossTemperature: 0, uecc: 0, histogram: [1]))
        let second = snapshot(1, host: 100, nand: 220, tlc: 100, pslc: 2_000,
                              telemetry: telemetry(reads: 200, age: 4, background: 3, reducedReadVerify: 2,
                                                   crossTemperature: 0, uecc: 0, histogram: [2]))
        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: [first, second])
        XCTAssertNil(result.intervals[0].observedWAF)
        XCTAssertEqual(try XCTUnwrap(result.intervals[0].metricValues[.ageRefreshPerDay]), 3, accuracy: 1e-12)

        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let context = CurrentDeviceContext(capturedAt: date, deviceID: "drive", firmware: "FW")
        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(CurrentDeviceContext.self, from: encoded)
        XCTAssertEqual(decoded.capturedAt, date)
        XCTAssertEqual(decoded.firmware, "FW")

        let profile = AppleNANDHardwareProfile(capturedAt: date, modelNumber: "Test")
        let profileData = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(AppleNANDHardwareProfile.self, from: profileData).capturedAt, date)
    }

    func testRatesUseOperatingHoursAndKeepWallClockContext() throws {
        let first = snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                             telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                                  crossTemperature: 0, uecc: 0, histogram: [1]),
                             powerOnHours: 1_000)
        let second = snapshot(10, host: 200, nand: 500, tlc: 110, pslc: 2_200,
                              telemetry: telemetry(reads: 200, age: 11, background: 3, reducedReadVerify: 2,
                                                   crossTemperature: 0, uecc: 0, histogram: [2]),
                              powerOnHours: 1_024)
        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: [first, second])
        let interval = try XCTUnwrap(result.latestInterval)

        XCTAssertEqual(interval.durationDays, 1, accuracy: 1e-12)
        XCTAssertEqual(interval.wallDurationDays, 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.operatingHoursDelta), 24, accuracy: 1e-12)
        XCTAssertEqual(interval.durationBasis, .operatingHours)
        XCTAssertEqual(try XCTUnwrap(interval.metricValues[.ageRefreshPerDay]), 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.operatingMetricValues[.ageRefreshPerDay]), 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.wallMetricValues[.ageRefreshPerDay]), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.operatingMetricValues[.ageRefreshPerOperatingDay]), 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.wallMetricValues[.ageRefreshPerWallDay]), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.operatingMetricValues[.backgroundRefreshPerDay]), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.wallMetricValues[.backgroundRefreshPerDay]), 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.operatingMetricValues[.backgroundRefreshPerOperatingDay]), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.wallMetricValues[.backgroundRefreshPerWallDay]), 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.operatingMetricValues[.reducedReadVerifyPerOperatingDay]), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.wallMetricValues[.reducedReadVerifyPerWallDay]), 0.1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.operatingMetricValues[.UECCPerOperatingDay]), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(interval.wallMetricValues[.UECCPerWallDay]), 0, accuracy: 1e-12)
        XCTAssertTrue(result.peCorrelationPoints.contains { $0.tlcPE == 110 && $0.metric == .ageRefreshPerOperatingDay })
        XCTAssertTrue(result.peCorrelationPoints.contains { $0.tlcPE == 110 && $0.metric == .ageRefreshPerWallDay })
        XCTAssertTrue(result.peCorrelationPoints.contains { $0.tlcPE == 110 && $0.metric == .backgroundRefreshPerOperatingDay })
        XCTAssertTrue(result.peCorrelationPoints.contains { $0.tlcPE == 110 && $0.metric == .backgroundRefreshPerWallDay })

        let evidence = try XCTUnwrap(FTLReliabilityEvidenceAnalyzer().assess(
            snapshots: [first, second], latest: second, researchIntervals: []
        ))
        XCTAssertEqual(try XCTUnwrap(evidence.durationDays), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(evidence.wallDurationDays), 10, accuracy: 1e-12)
        XCTAssertEqual(evidence.durationBasis, .operatingHours)
    }

    func testIntervalResidualIsKeptBesideRefreshDeltasWithoutBandAllocation() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        let first = snapshot(0, host: 100, nand: 100, tlc: 10, pslc: 100,
                             telemetry: telemetry(reads: 100, age: 1, background: 2, reducedReadVerify: 1,
                                                  crossTemperature: 0, uecc: 0, histogram: [1],
                                                  bandsPaddedForAge: 10, bandsRefreshedOnError: 4),
                             topology: topology)
        let second = snapshot(1, host: 120, nand: 120, tlc: 11, pslc: 101,
                              telemetry: telemetry(reads: 120, age: 4, background: 5, reducedReadVerify: 1,
                                                   crossTemperature: 0, uecc: 0, histogram: [2],
                                                   bandsPaddedForAge: 12, bandsRefreshedOnError: 5),
                              topology: topology)

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: [first, second])
        let residual = try XCTUnwrap(result.latestInterval?.intervalResidual)

        XCTAssertEqual(residual.knownDomainNANDBytes, 65_536, accuracy: 1e-12)
        let tlcBytes = try XCTUnwrap(residual.tlcEstimatedWrittenBytes)
        let pslcBytes = try XCTUnwrap(residual.pslcEstimatedWrittenBytes)
        XCTAssertGreaterThan(tlcBytes, 0)
        XCTAssertGreaterThan(pslcBytes, 0)
        XCTAssertEqual(tlcBytes + pslcBytes, residual.knownDomainNANDBytes, accuracy: 1e-12)
        XCTAssertNotEqual(tlcBytes + pslcBytes, residual.measuredNANDBytes)
        XCTAssertEqual(residual.measuredNANDBytes, 81_920, accuracy: 1e-12)
        XCTAssertEqual(residual.signedResidualBytes, 16_384, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(residual.equivalentPSLCBands), 4, accuracy: 1e-12)
        XCTAssertEqual(residual.ageRefreshDelta, 3)
        XCTAssertEqual(residual.backgroundRefreshDelta, 3)
        XCTAssertEqual(residual.bandsPaddedForAgeDelta, 2)
        XCTAssertEqual(residual.bandsRefreshedOnErrorDelta, 1)
        XCTAssertTrue(residual.note.contains("band 0"))
        XCTAssertLessThanOrEqual(residual.knownDomainNANDLowBytes, residual.knownDomainNANDBytes)
        XCTAssertLessThanOrEqual(residual.knownDomainNANDBytes, residual.knownDomainNANDHighBytes)
        XCTAssertLessThanOrEqual(residual.signedResidualLowBytes, residual.signedResidualBytes)
        XCTAssertLessThanOrEqual(residual.signedResidualBytes, residual.signedResidualHighBytes)
        XCTAssertEqual(residual.status, .indeterminateByPEQuantization)
    }

    func testLongBaselineReportsLifetimeAndSeriesResidualWithoutEnteringBudget() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        let samples = [
            snapshot(0, host: 100, nand: 100, tlc: 10, pslc: 100,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [1]),
                     topology: topology),
            snapshot(1, host: 120, nand: 1_000, tlc: 12, pslc: 102,
                     telemetry: telemetry(reads: 200, age: 2, background: 2, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [2]),
                     topology: topology)
        ]

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        let baselines = result.longBaseline.baselines
        XCTAssertTrue(baselines.contains { $0.kind == .lifetime })
        let series = try XCTUnwrap(baselines.first { $0.kind == .series })
        XCTAssertEqual(series.status, .resolvedPositive)
        XCTAssertGreaterThan(series.residualBestBytes, 0)
        XCTAssertTrue(result.longBaseline.notes.contains { $0.contains("予算") })
    }

    func testBandCounterCalibrationEnablesDiagnosticBandPathOnly() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        let samples = [
            snapshot(0, host: 100, nand: 100, tlc: 10, pslc: 100,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [1]),
                     topology: topology, intermediateBandsProgrammed: 200, userBandsProgrammed: 70),
            snapshot(1, host: 200, nand: 300, tlc: 20, pslc: 200,
                     telemetry: telemetry(reads: 200, age: 2, background: 2, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [2]),
                     topology: topology, intermediateBandsProgrammed: 400, userBandsProgrammed: 140),
            snapshot(2, host: 300, nand: 500, tlc: 30, pslc: 300,
                     telemetry: telemetry(reads: 300, age: 3, background: 3, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [3]),
                     topology: topology, intermediateBandsProgrammed: 600, userBandsProgrammed: 210)
        ]

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        let calibration = try XCTUnwrap(result.longBaseline.calibration.last)
        XCTAssertTrue(calibration.verified)
        XCTAssertEqual(try XCTUnwrap(calibration.tlcRatio), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.pslcRatio), 1, accuracy: 1e-12)
        XCTAssertTrue(result.longBaseline.baselines.contains { $0.path == .bandsProgrammed })
        XCTAssertNotNil(result.latestInterval?.intervalResidual?.bandPath)
        XCTAssertTrue(result.latestInterval?.intervalResidual?.bandPath?.note.contains("予算") == true)
    }

    func testBandCounterIncrementRatiosValidateOverSeveralDaysWithoutCumulativeAgreement() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        var samples: [ASPToolDiagnosticsSnapshot] = []
        for day in 0...4 {
            let host = UInt64(100 + day * 100)
            let nand = UInt64(300 + day * 200)
            let tlcPE = Double(10 + day)
            let pslcPE = Double(100 + day)
            let telemetrySnapshot = telemetry(
                reads: UInt64(day + 1), age: 0, background: 0, reducedReadVerify: 0,
                crossTemperature: 0, uecc: 0, histogram: [0]
            )
            samples.append(snapshot(
                Double(day), host: host, nand: nand, tlc: tlcPE, pslc: pslcPE,
                telemetry: telemetrySnapshot, topology: topology,
                intermediateBandsProgrammed: UInt64(800 + day * 2),
                userBandsProgrammed: UInt64(70 + day * 7)
            ))
        }

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        let calibration = try XCTUnwrap(result.longBaseline.calibration.last)
        XCTAssertTrue(calibration.verified)
        XCTAssertEqual(calibration.validationMethod, "増分比")
        XCTAssertEqual(calibration.incrementalTLC.intervalCount, 3)
        XCTAssertEqual(calibration.incrementalTLC.observationDays, 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.peDelta), 3, accuracy: 1e-12)
        XCTAssertEqual(calibration.incrementalPSLC.intervalCount, 3)
        XCTAssertEqual(calibration.incrementalPSLC.observationDays, 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalPSLC.peDelta), 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.ratio), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalPSLC.ratio), 1, accuracy: 1e-12)
        XCTAssertTrue(result.longBaseline.baselines.contains { $0.path == .bandsProgrammed })
    }

    func testBandCounterIncrementRatiosRejectWrongButMonotonicCounters() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        var samples: [ASPToolDiagnosticsSnapshot] = []
        for day in 0...4 {
            let host = UInt64(100 + day * 100)
            let nand = UInt64(300 + day * 200)
            let tlcPE = Double(10 + day)
            let pslcPE = Double(100 + day)
            let telemetrySnapshot = telemetry(
                reads: UInt64(day + 1), age: 0, background: 0, reducedReadVerify: 0,
                crossTemperature: 0, uecc: 0, histogram: [0]
            )
            samples.append(snapshot(
                Double(day), host: host, nand: nand, tlc: tlcPE, pslc: pslcPE,
                telemetry: telemetrySnapshot, topology: topology,
                intermediateBandsProgrammed: UInt64(800 + day * 4),
                userBandsProgrammed: UInt64(70 + day * 14)
            ))
        }

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        let calibration = try XCTUnwrap(result.longBaseline.calibration.last)
        XCTAssertFalse(calibration.verified, "単調増加だけではcounter意味を検証しない")
        XCTAssertEqual(calibration.validationMethod, "未検証")
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.ratio), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalPSLC.ratio), 2, accuracy: 1e-12)
        XCTAssertFalse(result.longBaseline.baselines.contains { $0.path == .bandsProgrammed })
    }

    func testBandCounterIncrementRatiosValidateIntegerPEWithSixHourSampling() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        var samples: [ASPToolDiagnosticsSnapshot] = []
        for sampleIndex in 0...60 {
            let peStep = sampleIndex / 12 // one integer P/E step per three days
            let telemetrySnapshot = telemetry(
                reads: UInt64(sampleIndex + 1), age: 0, background: 0, reducedReadVerify: 0,
                crossTemperature: 0, uecc: 0, histogram: [0]
            )
            samples.append(snapshot(
                Double(sampleIndex) / 4,
                host: UInt64(100 + sampleIndex * 100), nand: UInt64(300 + sampleIndex * 200),
                tlc: Double(10 + peStep), pslc: Double(100 + peStep),
                telemetry: telemetrySnapshot, topology: topology,
                intermediateBandsProgrammed: UInt64(800 + peStep * 2),
                userBandsProgrammed: UInt64(70 + peStep * 7)
            ))
        }

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        let calibration = try XCTUnwrap(result.longBaseline.calibration.last)
        XCTAssertTrue(calibration.verified)
        XCTAssertEqual(calibration.validationMethod, "増分比")
        XCTAssertEqual(calibration.incrementalTLC.riseBoundaryCount, 5)
        XCTAssertEqual(calibration.incrementalPSLC.riseBoundaryCount, 5)
        XCTAssertEqual(calibration.incrementalTLC.intervalCount, 48)
        XCTAssertEqual(calibration.incrementalPSLC.intervalCount, 48)
        XCTAssertEqual(calibration.incrementalTLC.observationDays, 12, accuracy: 1e-12)
        XCTAssertEqual(calibration.incrementalPSLC.observationDays, 12, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.peDelta), 4, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalPSLC.peDelta), 4, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.ratio), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalPSLC.ratio), 1, accuracy: 1e-12)
        XCTAssertTrue(result.longBaseline.baselines.contains { $0.path == .bandsProgrammed })
    }

    func testBandCounterIncrementProgressIsEvaluatedIndependentlyPerDomain() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        var samples: [ASPToolDiagnosticsSnapshot] = []
        for sampleIndex in 0...40 {
            let tlcStep = sampleIndex / 8 // integer step every two days
            let pslcStep = sampleIndex >= 12 ? 1 : 0 // one pSLC rise only
            samples.append(snapshot(
                Double(sampleIndex) / 4,
                host: UInt64(100 + sampleIndex * 100), nand: UInt64(300 + sampleIndex * 200),
                tlc: Double(10 + tlcStep), pslc: Double(100 + pslcStep),
                telemetry: telemetry(
                    reads: UInt64(sampleIndex + 1), age: 0, background: 0, reducedReadVerify: 0,
                    crossTemperature: 0, uecc: 0, histogram: [0]
                ),
                topology: topology,
                intermediateBandsProgrammed: UInt64(800 + pslcStep * 2),
                userBandsProgrammed: UInt64(70 + tlcStep * 7)
            ))
        }

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        let calibration = try XCTUnwrap(result.longBaseline.calibration.last)
        XCTAssertFalse(calibration.verified, "TLCの進行をpSLCの進行として流用しない")
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.ratio), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.peDelta), 4, accuracy: 1e-12)
        XCTAssertNil(calibration.incrementalPSLC.ratio)
        XCTAssertNil(calibration.incrementalPSLC.peDelta)
    }

    func testBandCounterIncrementDoesNotBridgeExcludedRunsBelowThreePEDelta() throws {
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        var samples: [ASPToolDiagnosticsSnapshot] = []
        for day in 0...7 {
            let sample: ASPToolDiagnosticsSnapshot = snapshot(
                Double(day),
                host: UInt64(100 + day * 100),
                nand: UInt64(300 + day * 200),
                tlc: Double(10 + day),
                pslc: Double(100 + day),
                telemetry: telemetry(
                    reads: UInt64(day + 1), age: 0, background: 0, reducedReadVerify: 0,
                    crossTemperature: 0, uecc: 0, histogram: [0]
                ),
                topology: topology,
                intermediateBandsProgrammed: UInt64(800 + day * 2),
                userBandsProgrammed: UInt64(70 + day * 7)
            )
            samples.append(sample)
        }
        let excluded = DateInterval(start: samples[3].capturedAt, end: samples[4].capturedAt)

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples, excluding: [excluded])
        let calibration = try XCTUnwrap(result.longBaseline.calibration.last)
        XCTAssertFalse(calibration.verified, "excluded intervalを跨いだPE段差を合成しない")
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.ratio), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalTLC.peDelta), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalPSLC.ratio), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(calibration.incrementalPSLC.peDelta), 1, accuracy: 1e-12)
    }

    func testLongBaselineMarksTopologyChangeInsteadOfBridgingIt() throws {
        let firstTopology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        let changedTopology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: contract,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 4,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        ))
        let samples = [
            snapshot(0, host: 100, nand: 100, tlc: 10, pslc: 100,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [1]),
                     topology: firstTopology),
            snapshot(1, host: 200, nand: 300, tlc: 20, pslc: 200,
                     telemetry: telemetry(reads: 200, age: 2, background: 2, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [2]),
                     topology: changedTopology),
            snapshot(2, host: 300, nand: 500, tlc: 30, pslc: 300,
                     telemetry: telemetry(reads: 300, age: 3, background: 3, reducedReadVerify: 0,
                                          crossTemperature: 0, uecc: 0, histogram: [3]),
                     topology: firstTopology)
        ]

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: samples)
        // D/E keeps a topology mismatch as an unresolved instrument
        // boundary.  Without a comparable SMART boundary it must not be
        // promoted into a long-baseline span or silently bridged.
        XCTAssertNil(result.longBaseline.baselines.first { $0.kind == .series })
        XCTAssertTrue(
            result.notes.contains { $0.contains("SMART資料待ち") || $0.contains("計測器境界") },
            result.notes.joined(separator: " | ")
        )
    }

    func testHistogramCandidateDoesNotEnterCorrelationUntilVerified() throws {
        let samples = [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [10, 0, 2])),
            snapshot(1, host: 200, nand: 400, tlc: 105, pslc: 2_100,
                     telemetry: telemetry(reads: 200, age: 2, background: 2, reducedReadVerify: 2,
                                          crossTemperature: 0, uecc: 0, histogram: [12, 2, 4]))
        ]

        let candidate = FTLTimeSeriesAnalyzer().analyze(
            snapshots: samples,
            histogramTailStartBin: 1
        )
        XCTAssertEqual(candidate.histogramDeltas.first?.temporalSemantics, .cumulativeCandidate)
        XCTAssertNil(candidate.latestInterval?.metricValues[.crossTemperatureTailFraction])

        let verified = FTLTimeSeriesAnalyzer().analyze(
            snapshots: samples,
            histogramTailStartBin: 1,
            histogramSemantics: [.bandsCrossTemp: .verifiedCumulative]
        )
        XCTAssertEqual(verified.histogramDeltas.first?.temporalSemantics, .verifiedCumulative)
        XCTAssertEqual(try XCTUnwrap(verified.latestInterval?.metricValues[.crossTemperatureTailFraction]), 2.0 / 3.0, accuracy: 1e-12)
    }

    func testIntervalTableGivesTheSameAnalysisWithoutOldTemperatures() throws {
        // Daily FTL reads with an event in every interval, a few days
        // without reads, and temperatures every 20 minutes with gaps.
        var samples: [ASPToolDiagnosticsSnapshot] = []
        var day = 0.0
        for index in 0..<60 {
            day += index.isMultiple(of: 13) ? 3 : 1
            samples.append(snapshot(day, host: UInt64(100 + index * 100), nand: UInt64(200 + index * 220),
                                    tlc: Double(100 + index), pslc: Double(2_000 + index * 10),
                                    telemetry: telemetry(reads: UInt64(100 + index * 100), age: 1, background: 1, reducedReadVerify: 1,
                                                         crossTemperature: UInt64(index), uecc: UInt64(index / 3), histogram: [UInt64(index)]),
                                    grownBadBlocks: UInt64(index / 10)))
        }
        let first = samples.first!.capturedAt
        var temperatures: [TemperatureSample] = []
        var time = first.addingTimeInterval(-3_600)
        var step = 0
        while time < samples.last!.capturedAt.addingTimeInterval(3_600) {
            step += 1
            if !(step % 97 < 40 && step > 400) {
                temperatures.append(TemperatureSample(capturedAt: time, deviceID: "test-drive", temperatureCelsius: 30 + step % 25))
            }
            time = time.addingTimeInterval(1_200)
        }
        for snapshot in samples.enumerated() where snapshot.offset.isMultiple(of: 5) {
            temperatures.append(TemperatureSample(capturedAt: snapshot.element.capturedAt, deviceID: "test-drive", temperatureCelsius: 99))
        }
        // Empty intervals: some with a sample 10 minutes after the end
        // (nearest fallback), some with nothing within 30 minutes.
        for index in stride(from: 7, to: samples.count, by: 7) {
            let start = samples[index - 1].capturedAt, end = samples[index].capturedAt
            let quiet = index.isMultiple(of: 14) ? end.addingTimeInterval(1_800) : end
            temperatures.removeAll { $0.capturedAt >= start && $0.capturedAt <= quiet }
            if !index.isMultiple(of: 14) {
                temperatures.append(TemperatureSample(capturedAt: end.addingTimeInterval(600), deviceID: "test-drive", temperatureCelsius: 77))
            }
        }
        temperatures.sort { $0.capturedAt < $1.capturedAt }

        let full = FTLTimeSeriesAnalyzer().analyze(snapshots: samples, temperatureHistory: temperatures)
        let table = TemperatureIntervalTable(boundaries: TemperatureIntervalTable.boundaries(of: samples), samples: temperatures)
        let recent = temperatures.filter { $0.capturedAt >= samples.last!.capturedAt.addingTimeInterval(-10 * 86_400) }
        let viaTable = FTLTimeSeriesAnalyzer(temperatureTable: table).analyze(snapshots: samples, temperatureHistory: recent)
        XCTAssertGreaterThan(full.reliabilityEvents.count, 50)
        XCTAssertTrue(full.reliabilityEvents.contains { $0.temperatureSummary?.usedNearestFallback == true })
        XCTAssertTrue(full.reliabilityEvents.contains { $0.temperatureSummary == nil })
        XCTAssertEqual(viaTable, full)
        // Without the table, the recent samples alone would change old events.
        XCTAssertNotEqual(FTLTimeSeriesAnalyzer().analyze(snapshots: samples, temperatureHistory: recent).reliabilityEvents,
                          full.reliabilityEvents)
    }

    func testReliabilityEventUsesIntervalTemperatureSummaryAndSeriesMetadata() throws {
        let first = snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                             telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                                  crossTemperature: 0, uecc: 0, histogram: [1]))
        let second = snapshot(1, host: 200, nand: 400, tlc: 101, pslc: 2_010,
                              telemetry: telemetry(reads: 200, age: 2, background: 2, reducedReadVerify: 2,
                                                   crossTemperature: 1, uecc: 0, histogram: [2]))
        let start = first.capturedAt
        let temperatures = [
            TemperatureSample(capturedAt: start.addingTimeInterval(3_600), deviceID: "test-drive", temperatureCelsius: 40),
            TemperatureSample(capturedAt: start.addingTimeInterval(43_200), deviceID: "test-drive", temperatureCelsius: 50),
            TemperatureSample(capturedAt: start.addingTimeInterval(82_800), deviceID: "test-drive", temperatureCelsius: 60)
        ]

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: [first, second], temperatureHistory: temperatures)
        let event = try XCTUnwrap(result.reliabilityEvents.first)
        let summary = try XCTUnwrap(event.temperatureSummary)
        XCTAssertEqual(event.intervalStart, first.capturedAt)
        XCTAssertEqual(event.intervalEnd, second.capturedAt)
        XCTAssertEqual(summary.minimumCelsius, 40)
        XCTAssertEqual(summary.maximumCelsius, 60)
        XCTAssertEqual(summary.averageCelsius, 50, accuracy: 1e-12)
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertFalse(summary.usedNearestFallback)
        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(result.series.first?.intervals.count, 1)
        XCTAssertEqual(try XCTUnwrap(result.calendarSpanDays), 1, accuracy: 1e-12)
        XCTAssertEqual(result.comparableWallDays, 1, accuracy: 1e-12)
        XCTAssertEqual(result.comparableOperatingDays, 0, accuracy: 1e-12)
    }

    func testReliabilityEventJournalDeduplicatesWithoutPruningPermanentHistory() async throws {
        func record(_ index: Int) -> FTLReliabilityEventRecord {
            let start = Date(timeIntervalSince1970: 1_700_300_000 + Double(index * 60))
            let event = FTLTimeSeriesReliabilityEvent(
                seriesID: "series",
                type: .UECC,
                intervalStart: start,
                intervalEnd: start.addingTimeInterval(1),
                detectedAt: start.addingTimeInterval(1),
                delta: UInt64(index + 1),
                deviceID: "test-drive",
                firmwareEpoch: "FW1",
                semanticContractVersion: contract,
                tlcPE: 100,
                pslcPE: 2_000,
                nandReadsSincePrevious: 100,
                temperatureSummary: nil
            )
            return FTLReliabilityEventRecord(event: event, semanticContractVersion: contract)
        }

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ftl-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let journal = FTLReliabilityEventJournal(fileURL: fileURL, maximumRecordCount: 2)

        let firstRecord = record(0)
        let firstAppend = try await journal.appendIfNew([firstRecord, firstRecord])
        let secondAppend = try await journal.appendIfNew([record(1), record(2)])
        let storedRecords = try await journal.records()
        XCTAssertEqual(firstAppend, 1)
        XCTAssertEqual(secondAppend, 2)
        XCTAssertEqual(storedRecords.count, 3, "legacy maximumRecordCount must not prune permanent journal history")
    }

    func testReliabilityEventJournalDetectsStormWithoutDroppingEvents() async throws {
        func record(_ index: Int) -> FTLReliabilityEventRecord {
            let start = Date(timeIntervalSince1970: 1_700_400_000 + Double(index * 60))
            let event = FTLTimeSeriesReliabilityEvent(
                seriesID: "storm-series",
                type: .grownBadBlocks,
                intervalStart: start,
                intervalEnd: start.addingTimeInterval(1),
                detectedAt: start.addingTimeInterval(1),
                delta: UInt64(index + 1),
                deviceID: "test-drive",
                firmwareEpoch: "FW1",
                semanticContractVersion: contract,
                tlcPE: nil,
                pslcPE: nil,
                nandReadsSincePrevious: nil,
                temperatureSummary: nil
            )
            return FTLReliabilityEventRecord(event: event, semanticContractVersion: contract)
        }

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ftl-events-storm-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("bak"))
        }
        let journal = FTLReliabilityEventJournal(fileURL: fileURL)
        let outcome = try await journal.appendIfNewReportingOutcome((0..<256).map(record))

        XCTAssertEqual(outcome.appendedCount, 256)
        XCTAssertEqual(outcome.duplicateCount, 0)
        XCTAssertEqual(outcome.eventStorm?.incomingEventCount, 256)
        let storedRecords = try await journal.records()
        let diagnostics = await journal.diagnostics()
        XCTAssertEqual(storedRecords.count, 256)
        XCTAssertNotNil(diagnostics.latestEventStorm)

        // The next analysis passes the same journaled events again; that is
        // not a storm.
        let quiet = FTLReliabilityEventJournal(fileURL: fileURL)
        let repeated = try await quiet.appendIfNewReportingOutcome((0..<256).map(record))
        XCTAssertEqual(repeated.appendedCount, 0)
        XCTAssertNil(repeated.eventStorm)
        let quietDiagnostics = await quiet.diagnostics()
        XCTAssertNil(quietDiagnostics.latestEventStorm)
    }

    func testReliabilityEventJournalSurfacesAppendFailure() async throws {
        let blockingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftl-events-blocking-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockingParent)
        defer { try? FileManager.default.removeItem(at: blockingParent) }

        let journal = FTLReliabilityEventJournal(
            fileURL: blockingParent.appendingPathComponent("journal.jsonl")
        )
        let event = FTLTimeSeriesReliabilityEvent(
            seriesID: "series",
            type: .UECC,
            intervalStart: Date(timeIntervalSince1970: 1_700_500_000),
            intervalEnd: Date(timeIntervalSince1970: 1_700_500_001),
            detectedAt: Date(timeIntervalSince1970: 1_700_500_001),
            delta: 1,
            deviceID: "test-drive",
            firmwareEpoch: "FW1",
            semanticContractVersion: contract,
            tlcPE: nil,
            pslcPE: nil,
            nandReadsSincePrevious: nil,
            temperatureSummary: nil
        )

        do {
            _ = try await journal.appendIfNew([FTLReliabilityEventRecord(event: event, semanticContractVersion: contract)])
            XCTFail("append should fail when the parent path is a regular file")
        } catch {
            // The actor must surface the filesystem failure instead of
            // silently accepting the event in its in-memory cache.
        }
        let diagnostics = await journal.diagnostics()
        let storedRecords = try await journal.records()
        XCTAssertNotNil(diagnostics.lastErrorDescription)
        XCTAssertEqual(storedRecords.count, 0)
    }

    func testReliabilityEventJournalQuarantinesCorruptionAndRecoversBackup() async throws {
        func record(_ index: Int) -> FTLReliabilityEventRecord {
            let start = Date(timeIntervalSince1970: 1_700_600_000 + Double(index * 60))
            let event = FTLTimeSeriesReliabilityEvent(
                seriesID: "recovery-series",
                type: .UECC,
                intervalStart: start,
                intervalEnd: start.addingTimeInterval(1),
                detectedAt: start.addingTimeInterval(1),
                delta: UInt64(index + 1),
                deviceID: "test-drive",
                firmwareEpoch: "FW1",
                semanticContractVersion: contract,
                tlcPE: nil,
                pslcPE: nil,
                nandReadsSincePrevious: nil,
                temperatureSummary: nil
            )
            return FTLReliabilityEventRecord(event: event, semanticContractVersion: contract)
        }

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ftl-events-corruption-\(UUID().uuidString).jsonl")
        defer {
            let fileManager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            let prefix = fileURL.deletingPathExtension().lastPathComponent
            if let names = try? fileManager.contentsOfDirectory(atPath: directory.path) {
                for name in names where name.hasPrefix(prefix) {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(name))
                }
            }
        }

        let writer = FTLReliabilityEventJournal(fileURL: fileURL)
        _ = try await writer.appendIfNew([record(0)])
        _ = try await writer.appendIfNew([record(1)])
        try Data("{ definitely not JSON }\n".utf8).write(to: fileURL, options: .atomic)

        let recoveringJournal = FTLReliabilityEventJournal(fileURL: fileURL)
        let recovered = try await recoveringJournal.records()
        let diagnostics = await recoveringJournal.diagnostics()
        XCTAssertEqual(recovered.count, 1, "the last verified backup is preferred over corrupted current data")
        XCTAssertTrue(diagnostics.recoveredFromCorruption)
        let quarantinedPath = try XCTUnwrap(diagnostics.lastQuarantinedCorruptionPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSeriesBoundaryKeepsContractSpecificIntervalsAndEventMetadata() throws {
        let firstSeries = [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [1]),
                     semanticContractVersion: DirectFTLResearchContract.legacy25G83V24,
                     directKeyContractVersion: DirectFTLResearchContract.legacy25G83V24,
                     coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1),
            snapshot(1, host: 200, nand: 400, tlc: 101, pslc: 2_010,
                     telemetry: telemetry(reads: 200, age: 2, background: 2, reducedReadVerify: 2,
                                          crossTemperature: 1, uecc: 0, histogram: [2]),
                     semanticContractVersion: DirectFTLResearchContract.legacy25G83V24,
                     directKeyContractVersion: DirectFTLResearchContract.legacy25G83V24,
                     coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1)
        ]
        let secondSeries = [
            snapshot(2, host: 300, nand: 600, tlc: 102, pslc: 2_020,
                     telemetry: telemetry(reads: 300, age: 3, background: 3, reducedReadVerify: 3,
                                          crossTemperature: 2, uecc: 0, histogram: [3]),
                     historySchemaVersion: 3,
                     semanticContractVersion: DirectFTLResearchContract.latest,
                     directKeyContractVersion: DirectFTLResearchContract.latest,
                     coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1),
            snapshot(3, host: 400, nand: 800, tlc: 103, pslc: 2_030,
                     telemetry: telemetry(reads: 400, age: 4, background: 4, reducedReadVerify: 4,
                                          crossTemperature: 3, uecc: 0, histogram: [4]),
                     historySchemaVersion: 3,
                     semanticContractVersion: DirectFTLResearchContract.latest,
                     directKeyContractVersion: DirectFTLResearchContract.latest,
                     coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1)
        ]

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: firstSeries + secondSeries)

        // Research revisions no longer split core wear history. The interval
        // crossing the revision remains available for wear/WAF, while
        // research-only deltas are withheld at that boundary.
        XCTAssertEqual(result.series.count, 2)
        XCTAssertEqual(result.series.map { $0.intervals.count }.reduce(0, +), 3)
        XCTAssertEqual(result.latestSemanticContractVersion, DirectFTLResearchContract.latest)
        XCTAssertTrue(result.notes.contains { $0.contains("research telemetryの対応表") })
        XCTAssertEqual(result.reliabilityEvents.count, 2)
        XCTAssertEqual(Set(result.reliabilityEvents.compactMap { $0.semanticContractVersion }), Set([DirectFTLResearchContract.reviewed25G83ResearchV24, DirectFTLResearchContract.reviewed25G83ResearchV241]))
    }

    func testResearchContractRevisionBridgesWearButSplitsTelemetry() throws {
        let legacyTopology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: DirectFTLResearchContract.legacy25G83V24,
            numVirtualBlocks: 722,
            intermediatePartitionStart: 1,
            userPartitionStart: 80,
            bytesPerPage: 16_384,
            pagesPerVirtualBlock: 24_576,
            pagesPerVirtualBlockSLC: 8_192
        ))
        let currentTopology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: DirectFTLResearchContract.latest,
            numVirtualBlocks: 722,
            intermediatePartitionStart: 1,
            userPartitionStart: 80,
            bytesPerPage: 16_384,
            pagesPerVirtualBlock: 24_576,
            pagesPerVirtualBlockSLC: 8_192
        ))
        let legacy = [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 100, age: 10, background: 10, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [10]),
                     topology: legacyTopology,
                     semanticContractVersion: DirectFTLResearchContract.legacy25G83V24,
                     directKeyContractVersion: DirectFTLResearchContract.legacy25G83V24),
            snapshot(1, host: 200, nand: 400, tlc: 101, pslc: 2_010,
                     telemetry: telemetry(reads: 200, age: 12, background: 12, reducedReadVerify: 2,
                                          crossTemperature: 0, uecc: 0, histogram: [12]),
                     topology: legacyTopology,
                     semanticContractVersion: DirectFTLResearchContract.legacy25G83V24,
                     directKeyContractVersion: DirectFTLResearchContract.legacy25G83V24)
        ]
        let current = [
            snapshot(2, host: 300, nand: 600, tlc: 102, pslc: 2_020,
                     telemetry: telemetry(reads: 300, age: 14, background: 14, reducedReadVerify: 3,
                                          crossTemperature: 0, uecc: 0, histogram: [14]),
                     topology: currentTopology),
            snapshot(3, host: 400, nand: 800, tlc: 103, pslc: 2_030,
                     telemetry: telemetry(reads: 400, age: 16, background: 16, reducedReadVerify: 4,
                                          crossTemperature: 0, uecc: 0, histogram: [16]),
                     topology: currentTopology)
        ]

        XCTAssertEqual(
            ControllerWearSeriesIdentity(snapshot: legacy[1]),
            ControllerWearSeriesIdentity(snapshot: current[0]),
            "研究keyの更新だけではHost/NAND/P-E損耗系列を切らない"
        )

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: legacy + current)

        XCTAssertEqual(result.intervals.count, 3)
        XCTAssertEqual(result.series.count, 2)
        let contractTransition = try XCTUnwrap(result.intervals.first { $0.startAt == legacy[1].capturedAt })
        XCTAssertNotNil(contractTransition.deltaHostBytes)
        XCTAssertNotNil(contractTransition.observedWAF)
        XCTAssertTrue(contractTransition.histogramDeltas.isEmpty)
        XCTAssertNil(contractTransition.deltaNANDReads)
        XCTAssertTrue(result.notes.contains { $0.contains("research telemetryの対応表") })
    }

    func testLatestObservedSeriesWaitsForSecondComparableSnapshot() throws {
        let firstSeries = [
            snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [1]),
                     semanticContractVersion: "contract-a",
                     directKeyContractVersion: "contract-a",
                     coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1),
            snapshot(1, host: 200, nand: 400, tlc: 101, pslc: 2_010,
                     telemetry: telemetry(reads: 200, age: 2, background: 2, reducedReadVerify: 2,
                                          crossTemperature: 0, uecc: 0, histogram: [2]),
                     semanticContractVersion: "contract-a",
                     directKeyContractVersion: "contract-a",
                     coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1)
        ]
        let latestSeriesSnapshot = snapshot(
            2, host: 300, nand: 600, tlc: 102, pslc: 2_020,
            telemetry: telemetry(reads: 300, age: 3, background: 3, reducedReadVerify: 3,
                                 crossTemperature: 0, uecc: 0, histogram: [3]),
            historySchemaVersion: 3,
            semanticContractVersion: "contract-b",
            directKeyContractVersion: "contract-b",
            coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1
        )

        let result = FTLTimeSeriesAnalyzer().analyze(snapshots: firstSeries + [latestSeriesSnapshot])

        let latestObservedSeriesID = try XCTUnwrap(result.latestObservedSeriesID)
        let latestComparableSeriesID = try XCTUnwrap(result.latestComparableSeriesID)
        XCTAssertEqual(latestObservedSeriesID, latestComparableSeriesID)
        XCTAssertNotNil(result.series.first { $0.id == latestObservedSeriesID })
        XCTAssertNotNil(result.series.first { $0.id == latestComparableSeriesID })
        XCTAssertNotNil(result.latestSeriesLatestInterval)
        XCTAssertEqual(result.latestAnyComparableInterval?.seriesID, latestComparableSeriesID)
        XCTAssertEqual(result.series.first { $0.id == latestObservedSeriesID }?.snapshotCount, 1)
        XCTAssertEqual(result.series.first { $0.id == latestObservedSeriesID }?.latestSnapshotAt, latestSeriesSnapshot.capturedAt)
        XCTAssertEqual(result.series.first { $0.id == latestObservedSeriesID }?.intervals.count, 1)
    }

    func testReliabilityJournalIdentityIncludesDeviceFirmwareAndContractAndMerges() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(86_400)
        func event(device: String, firmware: String, contract: String) -> FTLTimeSeriesReliabilityEvent {
            FTLTimeSeriesReliabilityEvent(
                seriesID: "series-\(firmware)",
                type: .UECC,
                intervalStart: start,
                intervalEnd: end,
                detectedAt: end,
                delta: 1,
                deviceID: device,
                firmwareEpoch: firmware,
                semanticContractVersion: contract,
                tlcPE: 10,
                pslcPE: 20,
                nandReadsSincePrevious: 100,
                temperatureSummary: nil
            )
        }

        let first = FTLReliabilityEventRecord(event: event(device: "drive-a", firmware: "fw-a", contract: "contract-a"), semanticContractVersion: nil)
        let second = FTLReliabilityEventRecord(event: event(device: "drive-a", firmware: "fw-b", contract: "contract-b"), semanticContractVersion: nil)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ftl-event-identity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let journal = FTLReliabilityEventJournal(fileURL: fileURL)

        let appendCount = try await journal.appendIfNew([first, second, first])
        let storedCount = try await journal.records().count
        XCTAssertEqual(appendCount, 2)
        XCTAssertEqual(storedCount, 2)

        let base = FTLTimeSeriesAnalytics(
            schemaVersion: 2,
            semanticContractVersion: "contract-a",
            intervals: [],
            histogramDeltas: [],
            reliabilityEvents: [first.event],
            peCorrelationPoints: [],
            notes: []
        )
        let merged = base.merging(journalRecords: [first, second])
        XCTAssertEqual(merged.reliabilityEvents.count, 2)
        XCTAssertTrue(merged.notes.contains { $0.contains("Journal") })
    }

    func testCompactedIntervalsDoNotDuplicateJournaledEvents() async throws {
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        func record(_ from: Double, _ to: Double, delta: UInt64,
                    type: FTLTimeSeriesReliabilityEventType = .UECC) -> FTLReliabilityEventRecord {
            FTLReliabilityEventRecord(event: FTLTimeSeriesReliabilityEvent(
                seriesID: "series", type: type,
                intervalStart: start.addingTimeInterval(from * 3_600),
                intervalEnd: start.addingTimeInterval(to * 3_600),
                detectedAt: start.addingTimeInterval(to * 3_600), delta: delta,
                deviceID: "drive", firmwareEpoch: "fw", semanticContractVersion: "contract",
                tlcPE: 10, pslcPE: 20, nandReadsSincePrevious: nil, temperatureSummary: nil
            ), semanticContractVersion: nil)
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftl-event-compaction-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let journal = FTLReliabilityEventJournal(fileURL: fileURL)
        // Full resolution: two 10-minute intervals each saw one UECC, and a
        // grown bad block appeared in the second.
        let fine = [record(0, 1, delta: 1), record(1, 2, delta: 1), record(1, 2, delta: 1, type: .grownBadBlocks)]
        _ = try await journal.appendIfNew(fine)

        // After compaction the same increments arrive over the merged
        // interval, once fully counted and once with one new increment.
        let counted = record(0, 2, delta: 2)
        let grown = record(0, 2, delta: 3)
        let analytics = FTLTimeSeriesAnalytics(schemaVersion: 2, semanticContractVersion: "contract",
            intervals: [], histogramDeltas: [], reliabilityEvents: [counted.event],
            peCorrelationPoints: [], notes: [])
        let merged = analytics.merging(journalRecords: fine)
        XCTAssertEqual(merged.reliabilityEvents.filter { $0.type == .UECC }.map(\.delta).reduce(0, +), 2)

        let appended = try await journal.appendIfNew([counted, grown, record(0, 2, delta: 1, type: .grownBadBlocks)])
        XCTAssertEqual(appended, 1, "only the one new increment is recorded")
        let stored = try await journal.records()
        XCTAssertEqual(stored.filter { $0.type == .UECC }.map(\.delta).reduce(0, +), 3)
        XCTAssertEqual(stored.filter { $0.type == .grownBadBlocks }.map(\.delta).reduce(0, +), 1)

        // A later coarser compaction adds nothing new.
        let weekly = try await journal.appendIfNew([record(0, 2, delta: 3)])
        XCTAssertEqual(weekly, 0)
    }

    func testDashboardJournalPreservesNewEventsAfterCompaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let journal = FTLReliabilityEventJournal(fileURL: file)
        func sample(_ day: Double, _ uecc: UInt64) -> ASPToolDiagnosticsSnapshot {
            snapshot(day, host: UInt64(100 + day * 100), nand: UInt64(200 + day * 200),
                tlc: 100 + day, pslc: 2_000 + day * 10,
                telemetry: telemetry(reads: 100, age: 0, background: 0, reducedReadVerify: 0,
                    crossTemperature: 0, uecc: uecc, histogram: [0]))
        }
        let a = sample(0, 0), b = sample(0.5, 2), c = sample(1, 3)
        let fine = FTLTimeSeriesAnalyzer().analyze(snapshots: [a, b]).reliabilityEvents.map {
            FTLReliabilityEventRecord(event: $0, semanticContractVersion: contract)
        }
        _ = try await journal.appendIfNew(fine)

        func rebuild(using journal: FTLReliabilityEventJournal, end: ASPToolDiagnosticsSnapshot) async -> DashboardAnalyticsRebuildOutcome {
            await DashboardAnalyticsCoordinator(analyzer: HistoryAnalyzer(), reliabilityEventJournal: journal).rebuild(
                history: [], temperatureHistory: [], deviceID: "test-drive", period: .day,
                profile: nil, settings: UsageSettings(), now: end.capturedAt,
                asptoolSnapshots: [a, end], researchSessions: [])
        }
        // Snapshot b is removed by compaction. The display has known +2 and
        // uncovered +1; journal input must still carry the raw interval +3.
        let first = await rebuild(using: journal, end: c)
        XCTAssertEqual(first.snapshot.ftlTimeSeries.reliabilityEvents.filter { $0.type == .UECC }.reduce(0) { $0 + $1.delta }, 3)
        XCTAssertEqual(first.snapshot.reliabilityEventsForJournal.filter { $0.type == .UECC }.map(\.delta), [3])
        let appended = try await journal.appendIfNewReportingOutcome(first.snapshot.reliabilityEventsForJournal)
        XCTAssertEqual(appended.appendedCount, 1)
        let saved = try await journal.records()
        XCTAssertEqual(saved.filter { $0.type == .UECC }.reduce(0) { $0 + $1.delta }, 3)

        // Both an identical rebuild and a later coarser interval remain
        // idempotent after reloading the durable journal.
        let reloaded = FTLReliabilityEventJournal(fileURL: file)
        let repeated = await rebuild(using: reloaded, end: c)
        let duplicate = try await reloaded.appendIfNewReportingOutcome(repeated.snapshot.reliabilityEventsForJournal)
        XCTAssertEqual(duplicate.appendedCount, 0)
        let later = await rebuild(using: reloaded, end: sample(2, 4))
        _ = try await reloaded.appendIfNewReportingOutcome(later.snapshot.reliabilityEventsForJournal)
        let finalRecords = try await reloaded.records()
        XCTAssertEqual(finalRecords.filter { $0.type == .UECC }.reduce(0) { $0 + $1.delta }, 4)
    }

    func testReliabilityJournalFiltersByCurrentDevice() async throws {
        let start = Date(timeIntervalSince1970: 1_700_100_000)
        let end = start.addingTimeInterval(86_400)
        func record(for deviceID: String?) -> FTLReliabilityEventRecord {
            let event = FTLTimeSeriesReliabilityEvent(
                seriesID: "series-\(deviceID ?? "unknown")",
                type: .UECC,
                intervalStart: start,
                intervalEnd: end,
                detectedAt: end,
                delta: 1,
                deviceID: deviceID,
                firmwareEpoch: "fw",
                semanticContractVersion: "contract",
                tlcPE: 10,
                pslcPE: 20,
                nandReadsSincePrevious: 100,
                temperatureSummary: nil
            )
            return FTLReliabilityEventRecord(event: event, semanticContractVersion: nil)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftl-event-device-filter-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let journal = FTLReliabilityEventJournal(fileURL: fileURL)
        _ = try await journal.appendIfNew([
            record(for: "drive-a"),
            record(for: "drive-b"),
            record(for: nil)
        ])

        let driveARecords = try await journal.records(for: "drive-a")
        let driveBRecords = try await journal.records(for: "drive-b")
        let unknownDeviceRecords = try await journal.records(for: nil)
        XCTAssertEqual(driveARecords.map(\.deviceID), ["drive-a"])
        XCTAssertEqual(driveBRecords.map(\.deviceID), ["drive-b"])
        XCTAssertTrue(unknownDeviceRecords.isEmpty)
    }

    func testCurrentContractIsTheV241SemanticContract() {
        XCTAssertEqual(DirectFTLResearchContract.latest, DirectFTLResearchContract.reviewed25G83V241)
        XCTAssertNotEqual(DirectFTLResearchContract.latest, DirectFTLResearchContract.legacy25G83V24)
    }

    func testReliabilityComparesCompatibleRuntimeProvisionally() throws {
        let first = snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
            telemetry: telemetry(reads: 100, age: 10, background: 20, reducedReadVerify: 5,
                                 crossTemperature: 0, uecc: 0, histogram: [10]))
        let latest = snapshot(1, host: 200, nand: 400, tlc: 101, pslc: 2_010,
            telemetry: telemetry(reads: 200, age: 20, background: 30, reducedReadVerify: 8,
                                 crossTemperature: 1, uecc: 1, histogram: [20]),
            sourceBuild: "26A428", contractBuild: "25G83")

        let evidence = try XCTUnwrap(FTLReliabilityEvidenceAnalyzer().assess(
            snapshots: [first, latest], latest: latest, researchIntervals: []
        ))

        XCTAssertEqual(evidence.state, .reliabilityEventObserved)
        XCTAssertTrue(evidence.provisionalInterpretation)
        XCTAssertTrue(evidence.reason.contains("26A428"))
        XCTAssertTrue(evidence.reason.contains("25G83"))
        XCTAssertEqual(evidence.counters.first { $0.name == "UECC reads" }?.delta, 1)
        XCTAssertFalse(evidence.counters.contains { !$0.isReliabilityEvent })
        let card = FTLReliabilityCardPresentation.make(evidence: evidence, events: [])
        XCTAssertEqual(card.state, .eventPresent)
        XCTAssertTrue(card.detail.contains(UIString.text("暫定比較")))
        XCTAssertEqual(evidence.latestTelemetry, latest.researchTelemetry)
    }

    func testProvisionalScalarEventsKeepLargeIncreasesAndJournalProvenance() throws {
        func sample(_ day: Double, uecc: UInt64, bad: UInt64) -> ASPToolDiagnosticsSnapshot {
            snapshot(day, host: UInt64(100 + day * 100), nand: UInt64(200 + day * 200),
                     tlc: 100 + day, pslc: 2000 + day * 10,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: uecc, histogram: [1]),
                     grownBadBlocks: bad, sourceBuild: "26B123", contractBuild: "25G83")
        }
        let first = sample(0, uecc: 10, bad: 5)
        let latest = sample(1, uecc: 1_000_010, bad: 4) // One counter reset does not hide UECC.
        let evidence = try XCTUnwrap(FTLReliabilityEvidenceAnalyzer().assess(
            snapshots: [first, latest], latest: latest, researchIntervals: []))
        XCTAssertEqual(evidence.state, .reliabilityEventObserved)
        XCTAssertEqual(evidence.counters.first { $0.name == "UECC reads" }?.delta, 1_000_000)
        XCTAssertTrue(evidence.unavailableCounters.contains { $0.contains("Grown bad blocks") })
        let analysis = FTLTimeSeriesAnalyzer().analyze(snapshots: [first, latest])
        XCTAssertTrue(analysis.histogramDeltas.isEmpty)
        let event = try XCTUnwrap(analysis.reliabilityEvents.first { $0.type == .UECC })
        XCTAssertEqual(event.runtimeBuild, "26B123")
        XCTAssertEqual(event.provisionalInterpretation, true)
        let record = FTLReliabilityEventRecord(event: event, semanticContractVersion: nil)
        let restored = try JSONDecoder().decode(FTLReliabilityEventRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.event, event)
        XCTAssertEqual(restored.contractBuild, "25G83")
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for key in ["runtimeBuild", "contractBuild", "provisionalInterpretation"] { legacyJSON.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(FTLReliabilityEventRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(legacy.runtimeBuild)
        XCTAssertNil(legacy.provisionalInterpretation)
        var mismatchedFormat = first
        // Captures with another record format must not share a scalar comparison.
        mismatchedFormat = snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2000,
            telemetry: first.researchTelemetry!, sourceBuild: "26B123", contractBuild: "25G83", directFormatVersion: 99)
        XCTAssertFalse(DirectFTLResearchContract.reliabilityPairIsComparable(mismatchedFormat, latest))

        let unchanged = sample(1, uecc: 10, bad: 5)
        let noEvents = try XCTUnwrap(FTLReliabilityEvidenceAnalyzer().assess(
            snapshots: [first, unchanged], latest: unchanged, researchIntervals: []))
        XCTAssertEqual(FTLReliabilityCardPresentation.make(evidence: noEvents, events: []).state, .noAnomalyObserved)
        let reset = snapshot(2, host: 0, nand: 0, tlc: 0, pslc: 0,
            telemetry: telemetry(reads: 0, age: 0, background: 0, reducedReadVerify: 0,
                                 crossTemperature: 0, uecc: 1, histogram: []),
            sourceBuild: "26B123", contractBuild: "25G83")
        let resetEvidence = try XCTUnwrap(FTLReliabilityEvidenceAnalyzer().assess(
            snapshots: [first, reset], latest: reset, researchIntervals: []))
        XCTAssertNotEqual(resetEvidence.state, .reliabilityEventObserved)
        let unknown = snapshot(1, host: 200, nand: 400, tlc: 101, pslc: 2010,
            telemetry: latest.researchTelemetry!, semanticContractVersion: "unknown", directKeyContractVersion: "unknown",
            sourceBuild: "26B123", contractBuild: "25G83")
        XCTAssertNil(DirectFTLResearchContract.reliabilityVersion(for: unknown))
    }

    func testResearchKeySeriesUsesResearchVersionAndRuntimeBuildNotFormatOrFirmware() {
        let first = snapshot(0, host: 100, nand: 200, tlc: 100, pslc: 2_000,
            telemetry: telemetry(reads: 100, age: 10, background: 20, reducedReadVerify: 5,
                                 crossTemperature: 0, uecc: 0, histogram: [10]))
        let sameResearchInstrument = snapshot(1, host: 200, nand: 400, tlc: 101, pslc: 2_010,
            telemetry: telemetry(reads: 200, age: 20, background: 30, reducedReadVerify: 8,
                                 crossTemperature: 1, uecc: 1, histogram: [20]),
            firmware: "FW2", directFormatVersion: 99)
        let laterRuntime = snapshot(2, host: 300, nand: 600, tlc: 102, pslc: 2_020,
            telemetry: telemetry(reads: 300, age: 30, background: 40, reducedReadVerify: 9,
                                 crossTemperature: 1, uecc: 1, histogram: [30]),
            sourceBuild: "26A428", contractBuild: "25G83")

        XCTAssertTrue(DirectFTLResearchContract.researchTelemetryPairIsComparable(first, sameResearchInstrument))
        XCTAssertFalse(DirectFTLResearchContract.researchTelemetryIsEligible(laterRuntime))
        XCTAssertFalse(DirectFTLResearchContract.researchTelemetryPairIsComparable(first, laterRuntime))
    }

    func testWearBalanceTrendExposesDomainDeltasAndSlopes() throws {
        func sample(_ day: Double, tlc: Double, pslc: Double) -> ASPToolDiagnosticsSnapshot {
            snapshot(day, host: UInt64(100 + day), nand: UInt64(200 + day), tlc: tlc, pslc: pslc,
                     telemetry: telemetry(reads: 100, age: 1, background: 1, reducedReadVerify: 1,
                                          crossTemperature: 0, uecc: 0, histogram: [1]))
        }
        let trend = NANDEnduranceV2.makeWearBalanceTrend(
            series: [sample(0, tlc: 100, pslc: 2_000), sample(1, tlc: 110, pslc: 2_200)],
            excluding: []
        )
        XCTAssertEqual(try XCTUnwrap(trend.observations.last?.tlcWearDelta), 10.0 / 3_000.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(trend.observations.last?.pslcWearDelta), 200.0 / 100_000.0, accuracy: 1e-12)
        XCTAssertNotNil(trend.tlcWearChangePerDay)
        XCTAssertNotNil(trend.pslcWearChangePerDay)
    }
}
