import XCTest
@testable import NenRing

final class RecoveryActivityPaceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// One reading every 6 hours with 2 operating hours between readings.
    /// `background` gives the refresh moves added in each 6-hour step.
    private func series(days: Int, background: (Int) -> UInt64, reads: UInt64 = 1_000_000,
                        readVerify: UInt64 = 1) -> [ASPToolDiagnosticsSnapshot] {
        var moves: UInt64 = 0
        var verify: UInt64 = 0
        var nandReads: UInt64 = 0
        return (0...(days * 4)).map { step in
            if step > 0 {
                moves += background(step)
                verify += readVerify
                nandReads += reads
            }
            return snapshot(step: step, moves: moves, verify: verify, reads: nandReads)
        }
    }

    private func snapshot(step: Int, moves: UInt64, verify: UInt64, reads: UInt64,
                          powerOnHours: UInt64? = nil) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: origin.addingTimeInterval(Double(step) * 6 * 3_600),
            captureQuality: .explicit,
            deviceID: "test-drive",
            sourceArtifact: .directFTL,
            sourceBuild: DirectFTLResearchContract.reviewedBuild,
            extractionVersion: 2,
            historySchemaVersion: 2,
            semanticContractVersion: DirectFTLResearchContract.latest,
            hostWrites: UInt64(step) * 10,
            nandWrites: UInt64(step) * 20,
            hostWritesUnitState: .provisional4KiB,
            nandWritesUnitState: .provisional4KiB,
            powerOnHours: powerOnHours ?? UInt64(step) * 2,
            firmware: "FW1",
            directFormatVersion: 1,
            directKeyContractVersion: DirectFTLResearchContract.latest,
            researchTelemetry: FTLResearchTelemetrySnapshot(
                nandReads: reads,
                ageRefreshPerTier: [moves * 10],
                backgroundRefreshMoves: moves,
                bandsPaddedForAge: 0,
                reducedReadVerifyNative: verify
            )
        )
    }

    private func row(_ pace: RecoveryActivityPace, _ metric: RecoveryActivityPaceMetric) throws -> RecoveryActivityPaceRow {
        try XCTUnwrap(pace.rows.first { $0.metric == metric })
    }

    func testSteadyActivityIsSteady() throws {
        let pace = RecoveryActivityPaceAnalyzer().assess(snapshots: series(days: 70) { _ in 1 })
        XCTAssertEqual(pace.state, .steady)
        let background = try row(pace, .backgroundRefresh)
        XCTAssertEqual(background.ratio ?? 0, 1, accuracy: 0.05)
        // 1 move per 2 operating hours is 12 per operating day.
        XCTAssertEqual(background.recentRate ?? 0, 12, accuracy: 0.01)
        XCTAssertEqual(try row(pace, .reducedReadVerify).recentRate ?? 0, 1, accuracy: 0.01,
                       "read verify is per million NAND reads")
        XCTAssertEqual(pace.recentOperatingHours, 112, accuracy: 0.1,
                       "the recent window is 14 days")
    }

    func testRecentRefreshFiveTimesTheBaselineIsElevated() throws {
        let recent = 56 * 4
        let pace = RecoveryActivityPaceAnalyzer().assess(snapshots: series(days: 70) { $0 > recent ? 5 : 1 })
        XCTAssertEqual(pace.state, .elevated)
        let background = try row(pace, .backgroundRefresh)
        XCTAssertEqual(background.state, .elevated)
        XCTAssertEqual(background.ratio ?? 0, 5, accuracy: 0.2)
        XCTAssertEqual(try row(pace, .reducedReadVerify).state, .steady)
    }

    /// Refresh comes in bursts. A recent window as busy as an earlier burst
    /// week is ordinary for this drive, even at twice the long average.
    func testRecentWindowNoBusierThanAnEarlierBurstWeekIsSteady() throws {
        let burstWeek = 20 * 4...27 * 4
        let recent = 56 * 4
        let pace = RecoveryActivityPaceAnalyzer().assess(snapshots: series(days: 70) { step in
            burstWeek.contains(step) || step > recent ? 6 : 1
        })
        let background = try row(pace, .backgroundRefresh)
        XCTAssertGreaterThan(background.ratio ?? 0, 2)
        XCTAssertEqual(background.state, .steady)
        // The burst week straddles a 7-day block, so its block is a little
        // below the burst's own 72 per operating day.
        XCTAssertGreaterThan(background.baselineWeeklyMaximumRate ?? 0, 60)
    }

    /// Refresh runs as one job every few days. Two large jobs in one week
    /// double a 7-day rate, while 14 days hold enough jobs to stay level.
    func testTwoLargeJobsInOneWeekStaySteadyOverFourteenDays() throws {
        let jobs: (Int) -> UInt64 = { step in
            guard step % 12 == 0 else { return 0 }
            switch step {
            case 276: return 80
            case 264: return 60
            default: return 20
            }
        }
        let snapshots = series(days: 70, background: jobs)
        XCTAssertEqual(try row(RecoveryActivityPaceAnalyzer().assess(snapshots: snapshots), .backgroundRefresh).state, .steady)
        var sevenDays = RecoveryActivityPaceAnalyzer()
        sevenDays.recentDays = 7
        XCTAssertEqual(try row(sevenDays.assess(snapshots: snapshots), .backgroundRefresh).state, .elevated,
                       "the same history reads as a jump in a 7-day window")
    }

    func testShortHistoryIsInsufficient() {
        let pace = RecoveryActivityPaceAnalyzer().assess(snapshots: series(days: 28) { $0 > 14 * 4 ? 9 : 1 })
        XCTAssertEqual(pace.state, .insufficientHistory, "only 2 baseline weeks")
        XCTAssertTrue(pace.rows.allSatisfy { $0.state == .insufficientHistory })
    }

    func testNoTelemetryGivesEmptyResult() {
        XCTAssertEqual(RecoveryActivityPaceAnalyzer().assess(snapshots: []), .empty)
    }

    func testDecreasedCounterAndResearchSessionPairsAreLeftOut() throws {
        var snapshots = series(days: 70) { _ in 1 }
        let last = snapshots.count - 1
        // A reset in the recent window: the counter restarts from 0 and counts on.
        let resetAt = last - 4
        for step in resetAt...last {
            let original = snapshots[step]
            snapshots[step] = snapshot(step: step, moves: UInt64(step - resetAt),
                                       verify: original.researchTelemetry?.reducedReadVerifyNative ?? 0,
                                       reads: original.researchTelemetry?.nandReads ?? 0)
        }
        let session = DateInterval(start: snapshots[last - 10].capturedAt, end: snapshots[last - 8].capturedAt)
        let pace = RecoveryActivityPaceAnalyzer().assess(snapshots: snapshots, excluding: [session])
        let background = try row(pace, .backgroundRefresh)
        XCTAssertEqual(background.state, .steady)
        // The pair falling into the reset is dropped, not counted as negative.
        XCTAssertEqual(background.recentRate ?? 0, 12, accuracy: 0.01)
        XCTAssertLessThan(pace.recentOperatingHours, 112, "the research session's pairs are not counted")
    }

    // MARK: - Light check

    private func smart(errors: UInt64?, errorLog: UInt64?, warning: UInt64? = 0, device: String = "disk0") -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: origin, deviceID: device, devicePath: "/dev/rdisk0", model: "APPLE SSD",
            serialNumber: nil, firmware: nil, smartctlVersion: nil, smartctlExitStatus: 0,
            temperatureCelsius: nil, powerOnHours: nil, powerCycleCount: nil, unsafeShutdowns: nil,
            percentageUsed: nil, availableSpare: nil, availableSpareThreshold: nil,
            criticalWarning: warning, mediaAndDataIntegrityErrors: errors, dataUnitsRead: nil,
            dataUnitsWritten: nil, smartPassed: true,
            additionalSMART: SMARTAdditionalCounters(errorLogEntries: errorLog))
    }

    private func event(endingAt end: Date, delta: UInt64 = 1) -> FTLTimeSeriesReliabilityEvent {
        FTLTimeSeriesReliabilityEvent(
            seriesID: "s", type: .crossTemperatureUECC,
            intervalStart: end.addingTimeInterval(-600), intervalEnd: end, detectedAt: end,
            delta: delta, deviceID: "test-drive", firmwareEpoch: nil, semanticContractVersion: nil,
            tlcPE: nil, pslcPE: nil, nandReadsSincePrevious: nil, temperatureSummary: nil)
    }

    func testFirstCheckRecordsABaselineWithoutReportingOldEvents() {
        let record = ReliabilityCheck.run(
            smart: smart(errors: 0, errorLog: 3), events: [event(endingAt: origin)],
            pace: .empty, latestFTLCapturedAt: origin, previous: nil, now: origin)
        XCTAssertTrue(record.findings.isEmpty)
        XCTAssertEqual(record.errorLogEntries, 3)
        XCTAssertEqual(record.reliabilityEventCount, 1)
    }

    func testLaterCheckReportsChangesSinceThePreviousCheckOnce() throws {
        let first = ReliabilityCheck.run(
            smart: smart(errors: 0, errorLog: 3), events: [event(endingAt: origin)],
            pace: .empty, latestFTLCapturedAt: origin, previous: nil, now: origin)
        let day = origin.addingTimeInterval(86_400)
        let elevated = RecoveryActivityPaceAnalyzer().assess(snapshots: series(days: 70) { $0 > 56 * 4 ? 5 : 1 })
        let second = ReliabilityCheck.run(
            smart: smart(errors: 2, errorLog: 5),
            events: [event(endingAt: origin), event(endingAt: day, delta: 3)],
            pace: elevated, latestFTLCapturedAt: day, previous: first, now: day)
        let keys = second.findings.map(\.key)
        XCTAssertTrue(keys.contains("smart.mediaErrors.2"))
        XCTAssertTrue(keys.contains("smart.errorLog.5"))
        XCTAssertTrue(keys.contains { $0.hasPrefix("ftl.event.") })
        XCTAssertTrue(keys.contains("pace.backgroundRefresh"))
        XCTAssertEqual(ReliabilityCheck.newFindings(second, previous: first).count, second.findings.count)

        // Nothing new happened: the pace is still elevated but already notified.
        let later = day.addingTimeInterval(86_400)
        let third = ReliabilityCheck.run(
            smart: smart(errors: 2, errorLog: 5),
            events: [event(endingAt: origin), event(endingAt: day, delta: 3)],
            pace: elevated, latestFTLCapturedAt: later, previous: second, now: later)
        XCTAssertEqual(Set(third.findings.map(\.key)), ["pace.backgroundRefresh", "pace.ageRefresh"],
                       "age refresh rises with background refresh in this fixture")
        XCTAssertTrue(ReliabilityCheck.newFindings(third, previous: second).isEmpty)
    }

    func testCriticalWarningIsReportedAndAnotherDriveStartsOver() {
        let first = ReliabilityCheck.run(
            smart: smart(errors: 0, errorLog: 3), events: [], pace: .empty,
            latestFTLCapturedAt: origin, previous: nil, now: origin)
        let other = ReliabilityCheck.run(
            smart: smart(errors: 9, errorLog: 99, warning: 4, device: "disk4"), events: [], pace: .empty,
            latestFTLCapturedAt: origin, previous: first, now: origin.addingTimeInterval(60))
        XCTAssertEqual(other.findings.map(\.key), ["smart.criticalWarning.4"],
                       "a different drive's counters are not compared with this one's")
    }

    func testDueFollowsTheSchedule() {
        let previous = ReliabilityCheck.run(smart: nil, events: [], pace: .empty,
            latestFTLCapturedAt: origin, previous: nil, now: origin)
        let hour = origin.addingTimeInterval(3_600)
        let day = origin.addingTimeInterval(86_400)
        XCTAssertFalse(ReliabilityCheck.isDue(schedule: .off, previous: nil, latestFTLCapturedAt: origin, now: origin))
        XCTAssertTrue(ReliabilityCheck.isDue(schedule: .weekly, previous: nil, latestFTLCapturedAt: nil, now: origin))
        XCTAssertFalse(ReliabilityCheck.isDue(schedule: .daily, previous: previous, latestFTLCapturedAt: hour, now: hour))
        XCTAssertTrue(ReliabilityCheck.isDue(schedule: .daily, previous: previous, latestFTLCapturedAt: hour, now: day))
        XCTAssertFalse(ReliabilityCheck.isDue(schedule: .weekly, previous: previous, latestFTLCapturedAt: day, now: day))
        XCTAssertFalse(ReliabilityCheck.isDue(schedule: .everyCollection, previous: previous,
                                              latestFTLCapturedAt: origin, now: hour))
        XCTAssertTrue(ReliabilityCheck.isDue(schedule: .everyCollection, previous: previous,
                                             latestFTLCapturedAt: hour, now: hour))
    }

    func testRecordRoundTripsThroughJSON() throws {
        let record = ReliabilityCheck.run(
            smart: smart(errors: 1, errorLog: 2, warning: 1), events: [], pace: .empty,
            latestFTLCapturedAt: origin, previous: nil, now: origin)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ReliabilityCheckRecord.self, from: encoder.encode(record)), record)
    }
}
