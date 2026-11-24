import Foundation
import XCTest
@testable import NenRing

final class EnduranceResearchTests: XCTestCase {








    func testResearchWearAssessmentDoesNotCallUnchangedPEAConfirmedPrediction() {
        func observation(day: Int, tlcPE: Double) -> ResearchTelemetryObservation {
            ResearchTelemetryObservation(
                capturedAt: date(day: day),
                deviceID: "drive-1",
                hostWrites: UInt64(day) * 1_000,
                nandWrites: UInt64(day) * 2_000,
                smartDataUnitsWritten: UInt64(day) * 100,
                hostUnitState: .verified,
                nandUnitState: .verified,
                sourceBuild: "25G83",
                extractionVersion: 1,
                tlcAveragePE: tlcPE,
                tlcMaximumPE: tlcPE + 5,
                slcAveragePE: 1_000,
                slcMaximumPE: 1_100,
                tlcEOLPE: 3_000,
                slcEOLPE: 100_000,
                firmwareEpoch: "FW1",
                temperatureCelsius: 40,
                criticalWarning: 0
            )
        }
        let unchanged = ResearchSession(
            deviceID: "drive-1",
            logicalCapacityBytes: 256_000_000_000,
            seed: 1,
            plannedMaximumBytes: 100,
            observations: [observation(day: 1, tlcPE: 100), observation(day: 2, tlcPE: 100)]
        )
        let changed = ResearchSession(
            deviceID: "drive-1",
            logicalCapacityBytes: 256_000_000_000,
            seed: 2,
            plannedMaximumBytes: 100,
            observations: [observation(day: 1, tlcPE: 100), observation(day: 2, tlcPE: 101)]
        )

        XCTAssertEqual(unchanged.evaluatedWearAssessment, .insufficientObservation)
        XCTAssertEqual(changed.evaluatedWearAssessment, .changed)
    }

    func testClientProxyWAFUsesOnlyPostPopulationOverwriteIntervalsAndDoesNotRequireWearTransition() {
        let observations = [
            clientObservation(phase: .beforeWrite, host: 0, nand: 0, smartUnits: 0),
            clientObservation(phase: .populationComplete, host: 1_000_000, nand: 2_000_000, smartUnits: 8_000),
            clientObservation(phase: .overwriteSegment, host: 2_250_000, nand: 3_875_000, smartUnits: 18_000),
            clientObservation(phase: .overwriteSegment, host: 3_500_000, nand: 5_875_000, smartUnits: 28_000),
            clientObservation(phase: .overwriteSegment, host: 4_750_000, nand: 7_750_000, smartUnits: 38_000),
            clientObservation(phase: .overwriteSegment, host: 6_000_000, nand: 9_750_000, smartUnits: 48_000),
            clientObservation(phase: .finished, host: 6_000_000, nand: 9_750_000, smartUnits: 48_000),
            clientObservation(phase: .cooldown, host: 6_000_000, nand: 9_750_000, smartUnits: 48_000)
        ]
        let written: UInt64 = 24_576_000_000
        let session = ResearchSession(
            deviceID: "drive-1",
            logicalCapacityBytes: 256_000_000_000,
            startedAt: date(day: 1),
            finishedAt: date(day: 1) + 60,
            seed: 42,
            plannedMaximumBytes: written,
            writtenBytes: written,
            state: .completed,
            observations: observations
        )

        XCTAssertEqual(session.clientProxyWAFIntervalCount, 4)
        XCTAssertEqual(session.clientProxyWriteAmplification ?? 0, 1.55, accuracy: 0.0001)
        XCTAssertTrue(session.isSuccessfulClientProxyCompletion)
        XCTAssertEqual(session.evaluatedWearAssessment, .insufficientObservation)
    }

    func testClientProxyCompletionRejectsAResetInsideOneOverwriteInterval() {
        let observations = [
            clientObservation(phase: .beforeWrite, host: 0, nand: 0, smartUnits: 0),
            clientObservation(phase: .populationComplete, host: 1_000_000, nand: 2_000_000, smartUnits: 8_000),
            clientObservation(phase: .overwriteSegment, host: 2_250_000, nand: 3_875_000, smartUnits: 18_000),
            clientObservation(phase: .overwriteSegment, host: 2_000_000, nand: 5_875_000, smartUnits: 28_000),
            clientObservation(phase: .overwriteSegment, host: 4_750_000, nand: 7_750_000, smartUnits: 38_000),
            clientObservation(phase: .overwriteSegment, host: 6_000_000, nand: 9_750_000, smartUnits: 48_000),
            clientObservation(phase: .finished, host: 6_000_000, nand: 9_750_000, smartUnits: 48_000),
            clientObservation(phase: .cooldown, host: 6_000_000, nand: 9_750_000, smartUnits: 48_000)
        ]
        let written: UInt64 = 24_576_000_000
        let session = ResearchSession(
            deviceID: "drive-1", logicalCapacityBytes: 256_000_000_000,
            startedAt: date(day: 1), finishedAt: date(day: 1) + 60,
            seed: 7, plannedMaximumBytes: written, writtenBytes: written,
            state: .completed, observations: observations
        )

        XCTAssertLessThan(session.clientProxyWAFIntervalCount, 4)
        XCTAssertFalse(session.isSuccessfulClientProxyCompletion)
    }

    func testLegacyResearchObservationWithoutPhaseStillDecodes() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","capturedAt":"1970-01-01T00:00:00Z","deviceID":"drive-1","hostUnitState":"verified","nandUnitState":"verified"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ResearchTelemetryObservation.self, from: data)

        XCTAssertNil(decoded.phase)
        XCTAssertEqual(decoded.deviceID, "drive-1")
    }

    func testLegacyResearchSessionWithoutNewSafetyFieldsStillDecodes() throws {
        let newer = ResearchSession(
            id: UUID(),
            deviceID: "drive-1",
            logicalCapacityBytes: 256_000_000_000,
            startedAt: date(day: 1),
            protocolVersion: "sequential-v1",
            seed: 3,
            plannedMaximumBytes: 1_000,
            stopReasonCode: .thermalLimit,
            availableBytesAtStart: 30_000_000_000,
            availableBytesAtFinish: 29_000_000_000,
            partialPhase: .overwriteSegment,
            partialPhaseBytes: 512_000
        )
        let encoded = try JSONEncoder().encode(newer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "stopReasonCode")
        object.removeValue(forKey: "availableBytesAtStart")
        object.removeValue(forKey: "availableBytesAtFinish")
        object.removeValue(forKey: "partialPhase")
        object.removeValue(forKey: "partialPhaseBytes")
        object.removeValue(forKey: "workingSetBytes")
        object.removeValue(forKey: "populationWriteBytes")
        object.removeValue(forKey: "overwriteWriteBytes")
        let oldFormat = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ResearchSession.self, from: oldFormat)

        XCTAssertEqual(decoded.protocolVersion, "sequential-v1")
        XCTAssertNil(decoded.stopReasonCode)
        XCTAssertNil(decoded.availableBytesAtStart)
        XCTAssertNil(decoded.partialPhase)
        XCTAssertNil(decoded.partialPhaseBytes)
        XCTAssertNil(decoded.availableBytesAtFinish)
        XCTAssertNil(decoded.workingSetBytes)
        XCTAssertNil(decoded.populationWriteBytes)
        XCTAssertNil(decoded.overwriteWriteBytes)
    }

    func testResearchPhaseByteTotalsSaturateForMalformedOrLegacyHistory() {
        let session = ResearchSession(
            deviceID: "drive-1",
            logicalCapacityBytes: 256_000_000_000,
            startedAt: date(day: 1),
            seed: 1,
            plannedMaximumBytes: UInt64.max,
            partialPhase: .populationWriting,
            partialPhaseBytes: 1,
            observations: [
                clientObservation(
                    phase: .populationComplete, host: 0, nand: 0, smartUnits: 1,
                    bytesWrittenInPhase: UInt64.max
                )
            ]
        )

        XCTAssertEqual(session.clientProxyPreparationBytes, UInt64.max)
        XCTAssertEqual(session.clientProxyOverwriteBytes, 0)
    }

    func testWearHistoryKeepsThePreBoundaryLaneWhenTheBoundaryCannotBeVerified() {
        let snapshots = [
            makeFTL(day: 1, host: 0, nand: 0, tlcPE: 10),
            makeFTL(day: 3, host: 400_000_000, nand: 800_000_000, tlcPE: 11),
            makeFTL(day: 5, host: 800_000_000, nand: 1_600_000_000, tlcPE: 12),
            makeFTL(day: 7, host: 1_200_000_000, nand: 2_400_000_000, tlcPE: 13, firmware: "FW2"),
            makeFTL(day: 9, host: 1_600_000_000, nand: 3_200_000_000, tlcPE: 14, firmware: "FW2")
        ]

        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: snapshots, deviceID: "drive-1")

        XCTAssertEqual(summary.intervalCount, 2)
        XCTAssertEqual(summary.seriesIdentity?.firmwareEpoch, "FW1")
        XCTAssertEqual(summary.observationDays, 4, accuracy: 0.001)
        XCTAssertEqual(summary.instrumentBoundaries.count, 1)
        XCTAssertTrue(summary.instrumentBoundaries[0].continuity.isPending)
    }

    func testJESDClientSimulationWaitsForSourcedRetentionAndWorkloadProfiles() {
        let snapshots = makeSimulationSnapshots()
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: snapshots, deviceID: "drive-1")
        let input = makeSimulationInput(summary: summary, latest: snapshots.last!)

        guard case let .unavailable(reason) = AppleEnduranceSimulator().estimate(input) else {
            return XCTFail("出典付きモデルが未設定なら数値は保留すべきです")
        }
        XCTAssertTrue(reason.contains("保持限度"))
    }

    func testJESDClientSimulationCalculatesReferenceRangeAndDailyDateRangeFromSeparateInputs() {
        let snapshots = makeSimulationSnapshots()
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: snapshots, deviceID: "drive-1")
        let input = makeSimulationInput(
            summary: summary,
            latest: snapshots.last!,
            retention: makeRetentionProfile(),
            workload: makeWorkloadProfile()
        )

        guard case let .available(estimate) = AppleEnduranceSimulator().estimate(input) else {
            return XCTFail("fixtureで指定した仮定の範囲は計算できるべきです")
        }
        XCTAssertEqual(estimate.estimatedTBWLowerBytes, 40_960_000_000_000, accuracy: 1)
        XCTAssertEqual(estimate.estimatedTBWUpperBytes, 81_920_000_000_000, accuracy: 1)
        XCTAssertEqual(estimate.limitingDomain, .tlc)
        XCTAssertEqual(estimate.validWearIntervals, 2)
        XCTAssertEqual(estimate.dailyWorkloadEndDateRange?.lowerBound.timeIntervalSince(input.now) ?? 0, 294.912 * 86_400, accuracy: 1)
        XCTAssertGreaterThan(estimate.dailyWorkloadEndDateRange?.upperBound ?? .distantPast, estimate.dailyWorkloadEndDateRange?.lowerBound ?? .distantFuture)
        XCTAssertTrue(estimate.basis.contains(where: { $0.contains("電源OFF / 30°C / 1年以上") }))
    }

    func testJESDClientSimulationRejectsMismatchedLatestFTLSeriesAndMissingDomain() {
        let snapshots = makeSimulationSnapshots()
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: snapshots, deviceID: "drive-1")
        let mismatchedLatest = makeFTL(
            day: 5, host: 800_000_000, nand: 1_600_000_000, tlcPE: 12, build: "25G84",
            contractBuild: "25G83"
        )
        let mismatchInput = makeSimulationInput(
            summary: summary, latest: mismatchedLatest,
            retention: makeRetentionProfile(), workload: makeWorkloadProfile()
        )
        guard case .unavailable = AppleEnduranceSimulator().estimate(mismatchInput) else {
            return XCTFail("別build系列の現在値で計算してはいけません")
        }

        let noSLCProfile = makeRetentionProfile(includeSLC: false)
        let missingDomainInput = makeSimulationInput(
            summary: summary, latest: snapshots.last!,
            retention: noSLCProfile, workload: makeWorkloadProfile()
        )
        guard case let .unavailable(reason) = AppleEnduranceSimulator().estimate(missingDomainInput) else {
            return XCTFail("pSLC domainがないとSSD全体の推計を出してはいけません")
        }
        XCTAssertTrue(reason.contains("TLC・pSLC"))
    }

    func testJESDClientSimulationRejectsRetentionProfileOutsideDefaultClientCondition() {
        let snapshots = makeSimulationSnapshots()
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: snapshots, deviceID: "drive-1")
        let input = makeSimulationInput(
            summary: summary, latest: snapshots.last!,
            retention: makeRetentionProfile(temperature: 40),
            workload: makeWorkloadProfile()
        )

        guard case let .unavailable(reason) = AppleEnduranceSimulator().estimate(input) else {
            return XCTFail("40°Cのデータを30°CClient条件へそのまま適用してはいけません")
        }
        XCTAssertTrue(reason.contains("電源OFF・30°C・1年"))
    }






    func testWearHistoryKeepsAnchorUntilPEAndWriteThresholdsAligns() {
        let snapshots = [
            makeFTL(day: 1, host: 1_000_000_000, nand: 2_000_000_000, tlcPE: 100),
            makeFTL(day: 2, host: 1_100_000_000, nand: 2_200_000_000, tlcPE: 100),
            makeFTL(day: 3, host: 1_200_000_000, nand: 2_400_000_000, tlcPE: 101),
            makeFTL(day: 4, host: 1_300_000_000, nand: 2_600_000_000, tlcPE: 101),
            makeFTL(day: 7, host: 1_600_000_000, nand: 3_200_000_000, tlcPE: 102)
        ]
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: snapshots, deviceID: "drive-1")

        XCTAssertEqual(summary.intervalCount, 2)
        XCTAssertEqual(summary.observationDays, 6, accuracy: 0.001)
        XCTAssertEqual(summary.tlcPEProgress, 2)
        XCTAssertEqual(summary.hostUnitState, .provisional4KiB)
        XCTAssertNotNil(summary.tlcHostBytesPerPE)
        XCTAssertNotNil(summary.medianWAF)
    }

    func testWearHistoryBreaksOnFirmwareEpochBuildOrCounterReset() {
        let base = makeFTL(day: 1, host: 1_000_000_000, nand: 2_000_000_000, tlcPE: 100)
        let firmwareChanged = makeFTL(day: 4, host: 1_500_000_000, nand: 3_000_000_000, tlcPE: 110, firmware: "FW2")
        let buildChanged = makeFTL(day: 8, host: 2_000_000_000, nand: 4_000_000_000, tlcPE: 120, build: "25G84")
        let counterReset = makeFTL(day: 12, host: 1_000, nand: 2_000, tlcPE: 130, firmware: "FW2", build: "25G84")
        let summary = ControllerWearHistoryAnalyzer().summarize(
            snapshots: [base, firmwareChanged, buildChanged, counterReset],
            deviceID: "drive-1"
        )

        XCTAssertEqual(summary.intervalCount, 0)
        XCTAssertNil(summary.tlcHostBytesPerPE)
        XCTAssertNotNil(summary.unavailableReason)
    }

    func testControllerEOLBreaksAcrossExtractionFormatVersions() {
        let samples = [
            makeFTL(day: 1, host: 1_000_000_000, nand: 2_000_000_000, tlcPE: 100),
            makeFTL(day: 31, host: 1_300_000_000, nand: 2_600_000_000, tlcPE: 110),
            makeFTL(day: 61, host: 1_600_000_000, nand: 3_200_000_000, tlcPE: 120, extractionVersion: 2)
        ]

        let forecast = ControllerEOLAnalyzer().forecast(
            from: samples,
            deviceID: "drive-1",
            now: samples.last!.capturedAt
        )

        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertEqual(forecast.intervalCount, 0)
        XCTAssertNil(forecast.lowerDate)
        XCTAssertNil(forecast.upperDate)
    }

    func testControllerEOLDoesNotInferAcrossUnknownFirmwareOrDifferentDevices() {
        let unknownFirmwareSamples = [
            makeFTL(day: 1, host: 1_000_000_000, nand: 2_000_000_000, tlcPE: 100, firmware: nil),
            makeFTL(day: 31, host: 1_300_000_000, nand: 2_600_000_000, tlcPE: 110, firmware: nil),
            makeFTL(day: 61, host: 1_600_000_000, nand: 3_200_000_000, tlcPE: 120, firmware: nil)
        ]
        let unknownFirmwareForecast = ControllerEOLAnalyzer().forecast(
            from: unknownFirmwareSamples,
            deviceID: "drive-1",
            now: unknownFirmwareSamples.last!.capturedAt
        )
        XCTAssertEqual(unknownFirmwareForecast.state, .collecting)
        XCTAssertEqual(unknownFirmwareForecast.intervalCount, 0)

        let samples = [
            makeFTL(day: 1, host: 1_000_000_000, nand: 2_000_000_000, tlcPE: 100, firmware: nil),
            makeFTL(day: 31, host: 1_300_000_000, nand: 2_600_000_000, tlcPE: 110, firmware: nil),
            makeFTL(day: 61, host: 1_600_000_000, nand: 3_200_000_000, tlcPE: 120, deviceID: "drive-2"),
            makeFTL(day: 91, host: 1_900_000_000, nand: 3_800_000_000, tlcPE: 130, deviceID: "drive-2")
        ]

        let forecast = ControllerEOLAnalyzer().forecast(from: samples, deviceID: nil, now: samples.last!.capturedAt)

        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertEqual(forecast.intervalCount, 0)
        XCTAssertNil(forecast.lowerDate)
        XCTAssertNil(forecast.upperDate)
    }

    func testControllerEOLWaitsWhenAReportedWearDomainHasNoDailySlope() {
        let samples = [
            makeFTL(day: 1, host: 1_000_000_000, nand: 2_000_000_000, tlcPE: 100),
            makeFTL(day: 31, host: 1_300_000_000, nand: 2_600_000_000, tlcPE: 110, slcPE: 1_000),
            makeFTL(day: 61, host: 1_600_000_000, nand: 3_200_000_000, tlcPE: 120, slcPE: 1_000)
        ]

        let forecast = ControllerEOLAnalyzer().forecast(
            from: samples,
            deviceID: "drive-1",
            now: samples.last!.capturedAt
        )
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: samples, deviceID: "drive-1")

        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertNil(forecast.lowerDate)
        XCTAssertNil(forecast.upperDate)
        XCTAssertTrue(summary.unavailableReason?.contains("必要domain") == true)
    }

    func testControllerEOLDoesNotLearnFromResearchInterval() {
        let samples = [
            makeFTL(day: 1, host: 1_000_000_000, nand: 2_000_000_000, tlcPE: 100, unit: .verified),
            makeFTL(day: 31, host: 1_300_000_000, nand: 2_600_000_000, tlcPE: 110, unit: .verified),
            makeFTL(day: 61, host: 1_600_000_000, nand: 3_200_000_000, tlcPE: 120, unit: .verified),
            makeFTL(day: 91, host: 1_900_000_000, nand: 3_800_000_000, tlcPE: 130, unit: .verified)
        ]
        let excluded = DateInterval(start: date(day: 30), end: date(day: 92))
        let forecast = ControllerEOLAnalyzer().forecast(
            from: samples,
            deviceID: "drive-1",
            now: samples.last!.capturedAt,
            excluding: [excluded]
        )

        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertNil(forecast.lowerDate)
        XCTAssertNil(forecast.upperDate)
    }

    func testWriteRateExcludesResearchIntervalButGraphRetainsItsBytes() {
        let start = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 1), units: 1_000)
        let during = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 2), units: 2_000)
        let after = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 3), units: 2_100)
        let last = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 4), units: 2_200)
        let analyzer = HistoryAnalyzer(calendar: Calendar(identifier: .gregorian))
        let interval = DateInterval(start: date(day: 1).addingTimeInterval(12 * 60 * 60), end: date(day: 2).addingTimeInterval(12 * 60 * 60))

        let all = analyzer.writeRateSummary(from: [start, during, after, last], deviceID: "drive-1")
        let excluding = analyzer.writeRateSummary(from: [start, during, after, last], deviceID: "drive-1", excluding: [interval])
        let points = analyzer.writePoints(from: [start, during, after, last], deviceID: "drive-1", period: .day)

        XCTAssertNotNil(all.lifetimeBytesPerDay)
        XCTAssertNotNil(excluding.lifetimeBytesPerDay)
        XCTAssertEqual(excluding.lifetimeBytesPerDay ?? 0, 100 * 512_000 / 2, accuracy: 0.1)
        XCTAssertLessThan(excluding.lifetimeBytesPerDay ?? .infinity, all.lifetimeBytesPerDay ?? 0)
        XCTAssertEqual(points.reduce(0) { $0 + $1.bytes }, 1_200 * 512_000, accuracy: 0.1)
    }

    func testRollingDayProratesTheIntervalAcrossItsStart() {
        let end = date(day: 4).addingTimeInterval(6 * 3600)
        let samples = [
            DriveSnapshot.makeResearchTestSnapshot(date: end.addingTimeInterval(-36 * 3600), units: 100),
            DriveSnapshot.makeResearchTestSnapshot(date: end.addingTimeInterval(-12 * 3600), units: 500),
            DriveSnapshot.makeResearchTestSnapshot(date: end, units: 600)
        ]
        let summary = HistoryAnalyzer().writeRateSummary(from: samples, deviceID: "drive-1")
        XCTAssertEqual(summary.oneDayBytesPerDay, 300 * 512_000)
        XCTAssertEqual(summary.oneDayObservedDays, 1)
    }

    func testWriteRateSummaryMarksYoungWindowsAsPartialInsteadOfHidingTheEstimate() {
        let analyzer = HistoryAnalyzer(calendar: Calendar(identifier: .gregorian))
        let shortHistory = (0...3).map { index in
            DriveSnapshot.makeResearchTestSnapshot(
                date: date(day: index),
                units: 1_000 + UInt64(index * 100)
            )
        }

        let short = analyzer.writeRateSummary(from: shortHistory, deviceID: "drive-1")

        XCTAssertNotNil(short.sevenDayBytesPerDay)
        XCTAssertNotNil(short.thirtyDayBytesPerDay)
        XCTAssertNotNil(short.ninetyDayBytesPerDay)
        XCTAssertEqual(short.sevenDayObservedDays ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(short.thirtyDayObservedDays ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(short.ninetyDayObservedDays ?? 0, 3, accuracy: 1e-9)
        XCTAssertTrue(short.currentWorkloadIsPartial)
        XCTAssertTrue(short.currentWorkloadIsProvisional, "three days of pace are too few to settle an arrival time")

        let monthHistory = (0...31).map { index in
            DriveSnapshot.makeResearchTestSnapshot(
                date: date(day: index),
                units: 1_000 + UInt64(index * 100)
            )
        }
        let month = analyzer.writeRateSummary(from: monthHistory, deviceID: "drive-1")

        XCTAssertEqual(month.thirtyDayObservedDays ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(month.ninetyDayObservedDays ?? 0, 31, accuracy: 1e-9)
        XCTAssertFalse(month.currentWorkloadIsPartial)
        XCTAssertFalse(month.currentWorkloadIsProvisional)
        XCTAssertLessThan(month.ninetyDayObservedDays ?? 0, 90)
    }

    func testWriteRateSummaryUsesDeclaredUsageStartForLifetimeAnchor() {
        let analyzer = HistoryAnalyzer(calendar: Calendar(identifier: .gregorian))
        let recent = DriveSnapshot.makeResearchTestSnapshot(
            date: date(day: 1_216), units: 999_000_000
        )
        let latest = DriveSnapshot.makeResearchTestSnapshot(
            date: date(day: 1_236), units: 1_000_000_000
        )
        let declaredStart = date(day: 0)

        let recentOnly = analyzer.writeRateSummary(
            from: [recent, latest], deviceID: "drive-1"
        )
        let anchored = analyzer.writeRateSummary(
            from: [recent, latest], deviceID: "drive-1", usageStartDate: declaredStart
        )

        XCTAssertEqual(recentOnly.lifetimeObservedDays ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(anchored.lifetimeObservedDays ?? 0, 1_236, accuracy: 1e-9)
        XCTAssertEqual(anchored.lifetimeStartDate, declaredStart)
        XCTAssertEqual(anchored.lifetimeRateBasis, "使用開始設定から累積Host / 暦日")
        XCTAssertEqual(
            anchored.lifetimeBytesPerDay ?? 0,
            Double(1_000_000_000) * HistoryAnalyzer.bytesPerNVMeDataUnit / 1_236,
            accuracy: 0.1
        )
        XCTAssertNotEqual(anchored.lifetimeBytesPerDay, recentOnly.lifetimeBytesPerDay)
        XCTAssertEqual(anchored.recordedHistoryBytesPerDay, recentOnly.lifetimeBytesPerDay)
        XCTAssertEqual(anchored.recordedHistoryObservedDays ?? 0, 20, accuracy: 1e-9)

        let reset = DriveSnapshot.makeResearchTestSnapshot(
            date: date(day: 1_237), units: 10
        )
        let resetResult = analyzer.writeRateSummary(
            from: [recent, latest, reset], deviceID: "drive-1", usageStartDate: declaredStart
        )
        XCTAssertNil(resetResult.lifetimeRateBasis)
        XCTAssertEqual(resetResult.lifetimeObservedDays ?? 0, 0, accuracy: 1e-9)
        XCTAssertNil(resetResult.recordedHistoryBytesPerDay)
    }

    func testWriteBasedProjectionKeepsTrialWritesButExcludesThemFromDailyRate() {
        let first = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 1), units: 100)
        let latest = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 31), units: 2_000)
        let session = ResearchSession(
            deviceID: "drive-1",
            logicalCapacityBytes: 256_000_000_000,
            startedAt: date(day: 15),
            finishedAt: date(day: 16),
            seed: 99,
            plannedMaximumBytes: 512_000_000,
            writtenBytes: 512_000_000,
            state: .completed,
            observations: [
                ResearchTelemetryObservation(
                    capturedAt: date(day: 15), deviceID: "drive-1", hostWrites: 100, nandWrites: 200,
                    smartDataUnitsWritten: 300, hostUnitState: .verified, nandUnitState: .verified,
                    sourceBuild: "25G83", extractionVersion: 1,
                    tlcAveragePE: 100, slcAveragePE: 1_000, tlcEOLPE: 3_000, slcEOLPE: 100_000,
                    firmwareEpoch: "FW1", temperatureCelsius: 40, criticalWarning: 0
                ),
                ResearchTelemetryObservation(
                    capturedAt: date(day: 16), deviceID: "drive-1", hostWrites: 200, nandWrites: 400,
                    smartDataUnitsWritten: 1_300, hostUnitState: .verified, nandUnitState: .verified,
                    sourceBuild: "25G83", extractionVersion: 1,
                    tlcAveragePE: 100, slcAveragePE: 1_000, tlcEOLPE: 3_000, slcEOLPE: 100_000,
                    firmwareEpoch: "FW1", temperatureCelsius: 40, criticalWarning: 0
                )
            ]
        )
        let analyzer = HistoryAnalyzer(calendar: Calendar(identifier: .gregorian))
        let settings = UsageSettings(manualStartDate: date(day: 1))

        let withoutSession = analyzer.writeBasedLifeProjection(
            from: [first, latest], deviceID: "drive-1", settings: settings
        )
        let withSession = analyzer.writeBasedLifeProjection(
            from: [first, latest], deviceID: "drive-1", settings: settings, researchSessions: [session]
        )

        XCTAssertNotNil(withoutSession)
        XCTAssertNotNil(withSession)
        XCTAssertEqual(withSession?.observedWrittenBytes, withoutSession?.observedWrittenBytes)
        XCTAssertEqual(withSession?.estimatedTotalLifetimeBytes, withoutSession?.estimatedTotalLifetimeBytes)
        XCTAssertEqual(session.observedWriteAmplification ?? -1, 2, accuracy: 0.001)
        XCTAssertLessThan(
            withSession?.averageDailyWriteRateBytes ?? .infinity,
            withoutSession?.averageDailyWriteRateBytes ?? 0
        )
    }

    func testWriteBasedProjectionWaitsWhenTrialWritesCannotBeSubtracted() {
        let first = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 1), units: 100)
        let latest = DriveSnapshot.makeResearchTestSnapshot(date: date(day: 31), units: 2_000)
        let session = ResearchSession(
            deviceID: "drive-1",
            logicalCapacityBytes: 256_000_000_000,
            startedAt: date(day: 15),
            finishedAt: date(day: 16),
            seed: 99,
            plannedMaximumBytes: 512_000_000,
            writtenBytes: 512_000_000,
            state: .completed
        )

        let projection = HistoryAnalyzer(calendar: Calendar(identifier: .gregorian)).writeBasedLifeProjection(
            from: [first, latest],
            deviceID: "drive-1",
            settings: UsageSettings(manualStartDate: date(day: 1)),
            researchSessions: [session]
        )

        XCTAssertNil(projection)
    }

    func testResearchSessionStoreRoundTripsAndCapsTheRetainedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shm-session-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchSessionStore(fileURL: root.appendingPathComponent("research-sessions.jsonl"))
        let readAt = date(day: 1)
        let recordedAt = date(day: 1).addingTimeInterval(2)
        let first = ResearchSession(
            deviceID: "drive-1",
            logicalCapacityBytes: 1_000_000,
            firmwareEpoch: "FW1|MSP1",
            seed: 7,
            plannedMaximumBytes: 100_000,
            state: .completed,
            wearAssessment: .insufficientObservation,
            observations: [
                ResearchTelemetryObservation(
                    capturedAt: readAt,
                    smartCapturedAt: readAt,
                    ftlCapturedAt: readAt.addingTimeInterval(1),
                    recordedAt: recordedAt,
                    deviceID: "drive-1",
                    hostWrites: 10,
                    nandWrites: 20,
                    hostUnitState: .verified,
                    nandUnitState: .verified,
                    sourceBuild: "25G83",
                    extractionVersion: 1,
                    tlcAveragePE: 100,
                    slcAveragePE: 1_000,
                    tlcEOLPE: 3_000,
                    slcEOLPE: 100_000,
                    firmwareEpoch: "FW1|MSP1",
                    temperatureCelsius: 40,
                    criticalWarning: 0
                )
            ]
        )
        try await store.upsert(first)
        let initial = try await store.sessions()
        XCTAssertEqual(initial, [first])
        XCTAssertEqual(initial.first?.observations.first?.smartCapturedAt, readAt)
        XCTAssertEqual(initial.first?.observations.first?.recordedAt, recordedAt)
        XCTAssertEqual(initial.first?.firmwareEpoch, "FW1|MSP1")
        XCTAssertEqual(initial.first?.wearAssessment, .insufficientObservation)

        for index in 0..<ResearchSessionStore.maximumSessions {
            let session = ResearchSession(
                deviceID: "drive-\(index)",
                logicalCapacityBytes: 1_000_000,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                seed: UInt64(index),
                plannedMaximumBytes: 100_000
            )
            try await store.upsert(session)
        }
        let bounded = try await store.sessions()
        XCTAssertEqual(bounded.count, ResearchSessionStore.maximumSessions)
        XCTAssertFalse(bounded.contains(where: { $0.id == first.id }))
    }




    private func makeFTL(
        day: Int,
        host: UInt64,
        nand: UInt64,
        tlcPE: Double,
        firmware: String? = "FW1",
        build: String = "25G83",
        contractBuild: String? = nil,
        extractionVersion: Int = 1,
        deviceID: String = "drive-1",
        slcPE: Double? = nil,
        unit: ASPToolUnitState = .provisional4KiB
    ) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: date(day: day),
            captureQuality: .explicit,
            deviceID: deviceID,
            sourceArtifact: .directFTL,
            sourceBuild: build,
            contractBuild: contractBuild,
            extractionVersion: extractionVersion,
            hostWrites: host,
            nandWrites: nand,
            hostWritesUnitState: unit,
            nandWritesUnitState: unit,
            tlcAveragePE: tlcPE,
            tlcEOLPE: 3_000,
            slcAveragePE: slcPE ?? tlcPE * 10,
            slcEOLPE: 100_000,
            firmware: firmware
        )
    }

    private func makeSimulationSnapshots() -> [ASPToolDiagnosticsSnapshot] {
        [
            makeFTL(day: 1, host: 0, nand: 0, tlcPE: 10, slcPE: 100, unit: .verified),
            makeFTL(day: 3, host: 400_000_000, nand: 800_000_000, tlcPE: 11, slcPE: 101, unit: .verified),
            makeFTL(day: 5, host: 800_000_000, nand: 1_600_000_000, tlcPE: 12, slcPE: 102, unit: .verified)
        ]
    }

    private func makeSimulationInput(
        summary: ControllerWearHistorySummary,
        latest: ASPToolDiagnosticsSnapshot,
        retention: RetentionReferenceProfile? = nil,
        workload: ReferenceWorkloadProfile? = nil
    ) -> AppleEnduranceSimulationInput {
        AppleEnduranceSimulationInput(
            deviceID: "drive-1",
            nandVendor: "VendorX",
            nandFamily: "FamilyX",
            bitsPerCell: 3,
            controllerWear: summary,
            latestFTL: latest,
            dailyHostWriteBytes: 100_000_000_000,
            currentHostWrittenBytes: latest.hostWrittenBytes,
            retentionProfile: retention,
            workloadProfile: workload,
            now: latest.capturedAt
        )
    }

    private func makeRetentionProfile(
        temperature: Double = 30,
        includeSLC: Bool = true
    ) -> RetentionReferenceProfile {
        var allowance: [EnduranceWearDomain: PELimitRange] = [
            .tlc: PELimitRange(lower: 30, upper: 40)
        ]
        if includeSLC {
            allowance[.pSLC] = PELimitRange(lower: 100_000, upper: 120_000)
        }
        return RetentionReferenceProfile(
            id: "test-retention",
            version: 1,
            modelName: "Synthetic test envelope",
            nandVendor: "VendorX",
            nandFamily: "FamilyX",
            bitsPerCell: 3,
            powerOff: true,
            retentionTemperatureCelsius: temperature,
            retentionDays: 365,
            peAllowanceByDomain: allowance,
            acceptanceCriterion: "synthetic fixture only",
            fitDescription: "synthetic PE envelope for unit tests; not a measured NAND result",
            sourceTitle: "Unit test fixture",
            sourceURL: "https://example.invalid/test-fixture",
            sourceDetails: "No empirical source; mathematical test data only",
            assumptions: ["not an Apple or vendor measurement"],
            applicability: .matchingNAND
        )
    }

    private func makeWorkloadProfile() -> ReferenceWorkloadProfile {
        ReferenceWorkloadProfile(
            id: "test-workload",
            version: 1,
            standardVersion: "fixture",
            observedWorkloadName: "synthetic daily workload",
            referenceWorkloadName: "JESD219 Client fixture",
            targetToObservedWAFRatio: PELimitRange(lower: 0.8, upper: 1.2),
            sourceTitle: "Unit test fixture",
            sourceURL: "https://example.invalid/test-workload",
            mappingDetails: "synthetic range for formula verification only"
        )
    }

    private func clientObservation(
        phase: ResearchObservationPhase,
        host: UInt64,
        nand: UInt64,
        smartUnits: UInt64,
        bytesWrittenInPhase: UInt64? = nil
    ) -> ResearchTelemetryObservation {
        ResearchTelemetryObservation(
            capturedAt: date(day: 1) + TimeInterval(smartUnits),
            smartCapturedAt: date(day: 1) + TimeInterval(smartUnits),
            ftlCapturedAt: date(day: 1) + TimeInterval(smartUnits),
            deviceID: "drive-1",
            hostWrites: host,
            nandWrites: nand,
            smartDataUnitsWritten: smartUnits,
            hostUnitState: .verified,
            nandUnitState: .verified,
            sourceBuild: "25G83",
            extractionVersion: 1,
            tlcAveragePE: 100,
            tlcMaximumPE: 110,
            slcAveragePE: 1_000,
            slcMaximumPE: 1_100,
            tlcEOLPE: 3_000,
            slcEOLPE: 100_000,
            firmwareEpoch: "FW1",
            temperatureCelsius: 40,
            criticalWarning: 0,
            phase: phase,
            bytesWrittenInPhase: bytesWrittenInPhase
        )
    }

    private func date(day: Int) -> Date {
        Date(timeIntervalSince1970: Double(day) * 86_400)
    }
}

private actor ResearchCheckpointRecorder {
    private(set) var values: [UInt64] = []
    func append(_ value: UInt64) { values.append(value) }
}

private actor ResearchPhaseRecorder {
    private(set) var values: [(UInt64, ResearchObservationPhase)] = []

    func append(_ value: (UInt64, ResearchObservationPhase)) {
        values.append(value)
    }
}

private extension DriveSnapshot {
    static func makeResearchTestSnapshot(
        date: Date,
        units: UInt64,
        logicalCapacityBytes: UInt64? = 256_000_000_000,
        model: String? = "Test SSD",
        serialNumber: String? = nil,
        deviceID: String = "drive-1",
        usageStartDate: Date? = nil
    ) -> DriveSnapshot {
        DriveSnapshot(
            id: UUID(), capturedAt: date, deviceID: deviceID, devicePath: "/dev/rdisk0",
            logicalCapacityBytes: logicalCapacityBytes, model: model, serialNumber: serialNumber,
            firmware: "FW1", smartctlVersion: "7.5", smartctlExitStatus: 0,
            usageStartDate: usageStartDate, temperatureCelsius: 40, powerOnHours: 1_000,
            powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: 5,
            availableSpare: 100, availableSpareThreshold: 10, criticalWarning: 0,
            mediaAndDataIntegrityErrors: 0, dataUnitsRead: 1, dataUnitsWritten: units,
            filesystemTotalCapacityBytes: nil, filesystemFreeBytes: nil, smartPassed: true,
            messages: [], parseWarnings: [], rawJSON: "{}"
        )
    }
}
