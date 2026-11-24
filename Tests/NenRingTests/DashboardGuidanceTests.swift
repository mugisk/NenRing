import XCTest
@testable import NenRing

final class DashboardGuidanceTests: XCTestCase {
    @MainActor
    func testOldForecastRemainsStaleWhenAutomaticCollectionStops() throws {
        let suite = "NenRing-freshness-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var analytics = DashboardAnalyticsSnapshot.empty
        analytics.nandEndurance.inputDate = Date().addingTimeInterval(-3 * 86_400)
        let model = DashboardModel(preferences: preferences, initialAnalytics: analytics)
        XCTAssertTrue(model.forecastInputIsStale)
        model.aspDirectFTLAutomaticCollection = false
        XCTAssertTrue(model.forecastInputIsStale)
        model.aspDirectFTLAutomaticCollection = true
        XCTAssertTrue(model.forecastInputIsStale)
    }

    @MainActor
    func testAutomaticCollectionCountsAsStoppedWithoutBackgroundMonitoring() throws {
        let suite = "NenRing-collection-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        model.aspDirectFTLAutomaticCollection = true
        model.backgroundMonitoringEnabled = true
        XCTAssertTrue(model.automaticDirectFTLCollectionRuns)
        model.backgroundMonitoringEnabled = false
        XCTAssertFalse(model.automaticDirectFTLCollectionRuns)
    }

    func testSmartWarningOutranksFailedRefreshInMenuBar() {
        let warned = MenuBarStatus(isRefreshing: false, failed: true, failure: .timedOut,
                                   evaluation: .warning("critical"), hasSnapshot: true)
        XCTAssertEqual(warned.title, "警告")
        XCTAssertTrue(warned.needsAttention)

        let normal = MenuBarStatus(isRefreshing: false, failed: true, failure: .timedOut,
                                   evaluation: .normal, hasSnapshot: true)
        XCTAssertEqual(normal.title, "取得不可")

        let missing = MenuBarStatus(isRefreshing: false, failed: true, failure: .executableNotFound,
                                    evaluation: nil, hasSnapshot: false)
        XCTAssertEqual(missing.title, "smartctl未導入")
    }

    func testMissingSmartctlOffersInstallCommand() throws {
        let guidance = try XCTUnwrap(DashboardGuidance.make(
            state: .failed("smartctl が見つかりません。"), hasSnapshot: false, failure: .executableNotFound
        ))
        XCTAssertEqual(guidance.command, "brew install smartmontools")
        XCTAssertEqual(guidance.severity, .info, "a first-run setup step, not a failure")
        XCTAssertEqual(guidance.steps.count, 2)
        XCTAssertEqual(guidance.links.map(\.url.absoluteString),
                       ["https://brew.sh", "https://www.smartmontools.org/wiki/Download"])
        XCTAssertTrue(guidance.retriesWhenAppBecomesActive)
    }

    func testOtherFailuresExplainAndKeepLastValuesNote() throws {
        let guidance = try XCTUnwrap(DashboardGuidance.make(
            state: .failed("利用可能なストレージ候補を開けませんでした。"), hasSnapshot: true, failure: .noUsableDevice([])
        ))
        XCTAssertNil(guidance.command)
        XCTAssertFalse(guidance.retriesWhenAppBecomesActive)
        XCTAssertTrue(guidance.message.contains("前回取得した値"))
        XCTAssertTrue(guidance.message.contains("利用可能なストレージ候補"))
    }

    func testRepeatedCandidateMessagesAreShownOnce() throws {
        let guidance = try XCTUnwrap(DashboardGuidance.make(
            state: .failed("認識できるメトリクスがありません\n認識できるメトリクスがありません\nopen error"),
            hasSnapshot: false, failure: .noUsableDevice([])
        ))
        XCTAssertEqual(guidance.message, "認識できるメトリクスがありません\nopen error")
    }

    func testRemainingTimeUsesMonthsBelowAYearAndMarksZeroAsReached() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15
        let pace = 100e9
        func text(_ remaining: Double, upper: Double? = nil, provisional: Bool = false) -> String? {
            DashboardHeadline.remainingText(remainingHostBytes: remaining, upper: upper, paceBytesPerDay: pace,
                                            provisional: provisional, now: now)
        }

        XCTAssertEqual(text(0), "推定の総量に到達済み")
        XCTAssertEqual(text(pace * 120), "保存履歴のペースで残り約4か月（2027年5月頃）")
        XCTAssertEqual(text(pace * 3), "保存履歴のペースで残り約1か月（2027年1月頃）", "never shows 0 months before the total is reached")
        XCTAssertEqual(text(pace * 365.25 * 8), "保存履歴のペースで残り約8年（2035年頃）")
        XCTAssertEqual(text(pace * 365.25 * 8, upper: pace * 365.25 * 15, provisional: true),
                       "暫定・保存履歴のペースで残り約8〜15年（2035〜2042年頃）")
        // Long times are shown as they are; there is no "20 years or more".
        XCTAssertEqual(text(pace * 365.25 * 8, upper: pace * 365.25 * 40, provisional: true),
                       "暫定・保存履歴のペースで残り約8〜40年（2035〜2067年頃）")
        XCTAssertEqual(text(pace * 365.25 * 120), "保存履歴のペースで残り約120年（2147年頃）")
        XCTAssertNil(DashboardHeadline.remainingText(remainingHostBytes: 1e12, paceBytesPerDay: 0, provisional: false, now: now))
    }

    func testRemainingTimeTextsAreTranslated() {
        let cases = [
            ("推定の総量に到達済み", "estimated total reached"),
            ("保存履歴のペースで残り約4か月（2027年5月頃）", "about 4 months remaining at the recorded-history rate (around 2027-5)"),
            ("保存履歴のペースで残り約8〜15年（2035〜2042年頃）", "about 8–15 years remaining at the recorded-history rate (around 2035–2042)"),
            ("3行を解析できず（行 2, 3, 4、別ファイル history.unreadable-1.jsonl に退避）。正常行で履歴を修復し、圧縮を再開しました。",
             "3 rows could not be read (lines 2, 3, 4; moved to history.unreadable-1.jsonl). the history was repaired from the readable rows and compaction resumed.")
        ]
        for (source, english) in cases {
            XCTAssertEqual(UIString.message(source, language: "en"), english)
        }
    }

    func testMenuBarYearsShowMonthsAndReached() {
        UserDefaults.standard.set("ja", forKey: UIString.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: UIString.preferenceKey) }
        XCTAssertEqual(MenuBarLabelText.yearsText(0), "到達")
        XCTAssertEqual(MenuBarLabelText.yearsText(0.25), "3か月")
        XCTAssertEqual(MenuBarLabelText.yearsText(7.6), "8年")
        XCTAssertEqual(MenuBarLabelText.yearsText(25), "25年")
        UserDefaults.standard.set("en", forKey: UIString.preferenceKey)
        XCTAssertEqual(MenuBarLabelText.yearsText(0.25), "3mo")
        XCTAssertEqual(MenuBarLabelText.yearsText(7.6), "8y")
    }

    func testNoGuidanceUnlessFailed() {
        for state in [DashboardState.idle, .probing, .ready, .limited] {
            XCTAssertNil(DashboardGuidance.make(state: state, hasSnapshot: false, failure: nil))
        }
    }

    func testSmartCardNeverShowsHealthyWithoutData() {
        let missing = SmartStatusCardContent.make(snapshot: nil)
        XCTAssertEqual(missing.value, "未取得")
        XCTAssertEqual(missing.tone, .unknown)
        XCTAssertNotEqual(missing.icon, "checkmark.shield.fill")

        XCTAssertEqual(SmartStatusCardContent.make(snapshot: snapshot(passed: true)).tone, .positive)
        XCTAssertEqual(SmartStatusCardContent.make(snapshot: snapshot(passed: false)).tone, .warning)
        XCTAssertEqual(SmartStatusCardContent.make(snapshot: snapshot(passed: nil)).tone, .unknown)
    }

    func testCriticalWarningOverridesPassedAndUnknownHealth() {
        for passed in [true, false, nil] as [Bool?] {
            let drive = snapshot(passed: passed, warning: 1)
            let card = SmartStatusCardContent.make(snapshot: drive)
            XCTAssertEqual(card.tone, .warning)
            XCTAssertEqual(card.value, "要確認")
            XCTAssertEqual(card.detail, "Critical Warning")
            let headline = DashboardHeadline.make(snapshot: drive, nandWearFraction: nil,
                remainingHostBytes: nil, paceBytesPerDay: nil, provisional: false)
            XCTAssertEqual(headline.tone, .warning)
            XCTAssertEqual(headline.status, card.value)
        }
    }

    func testTimeoutDistinguishesInitialFailureFromLastKnownValues() throws {
        let initial = try XCTUnwrap(DashboardGuidance.make(state: .failed("timeout"),
            hasSnapshot: false, failure: .timedOut))
        let stale = try XCTUnwrap(DashboardGuidance.make(state: .failed("timeout"),
            hasSnapshot: true, failure: .timedOut))
        XCTAssertFalse(initial.message.contains("前回取得した値"))
        XCTAssertTrue(stale.message.contains("前回取得した値"))
        XCTAssertNil(initial.command)
        XCTAssertNil(stale.command)
    }

    func testNoHistoryDoesNotInventForecastOrHealthyStatus() {
        let empty = DashboardAnalyticsSnapshot.empty
        XCTAssertTrue(empty.ftlTimeSeries.intervals.isEmpty)
        XCTAssertEqual(ForecastEvidence.resolve(ftlTotal: nil, smart: empty.enduranceForecast), .unavailable)
        XCTAssertEqual(SmartStatusCardContent.make(snapshot: nil).tone, .unknown)
    }

    func testPassedSummaryDoesNotHideSpareOrMediaWarnings() {
        for drive in [snapshot(passed: true, spare: 10, threshold: 11), snapshot(passed: true, errors: 1)] {
            XCTAssertEqual(SmartStatusCardContent.make(snapshot: drive).tone, .warning)
            XCTAssertEqual(DashboardHeadline.make(snapshot: drive, nandWearFraction: nil,
                remainingHostBytes: nil, paceBytesPerDay: nil, provisional: false).tone, .warning)
        }
        let multiple = snapshot(passed: false, warning: 4, spare: 10, threshold: 11, errors: 2)
        XCTAssertEqual(SMARTWarningReason.collect(from: multiple), [.criticalWarning, .spareBelowThreshold, .mediaErrors, .selfAssessmentFailed])
        XCTAssertEqual(SMARTWarningReason.collect(from: snapshot(passed: true, warning: 0, spare: 11, threshold: 11, errors: 0)), [])
        XCTAssertEqual(SMARTWarningReason.collect(from: snapshot(passed: nil)), [])
        XCTAssertEqual(SMARTWarningReason.collect(from: nil), [])
        XCTAssertEqual(SmartStatusCardContent.make(snapshot: snapshot(passed: nil)).tone, .unknown)
    }

    private func snapshot(passed: Bool?, warning: UInt64? = nil, spare: UInt64? = nil,
                          threshold: UInt64? = nil, errors: UInt64? = nil) -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), deviceID: "disk0", devicePath: "/dev/rdisk0",
            logicalCapacityBytes: nil, model: "APPLE SSD", serialNumber: nil, firmware: nil, smartctlVersion: nil,
            smartctlExitStatus: 0, temperatureCelsius: nil, powerOnHours: nil, powerCycleCount: nil,
            unsafeShutdowns: nil, percentageUsed: nil, availableSpare: spare, availableSpareThreshold: threshold,
            criticalWarning: warning, mediaAndDataIntegrityErrors: errors, dataUnitsRead: nil, dataUnitsWritten: nil,
            smartPassed: passed
        )
    }

    func testForecastEvidencePrefersFTLAndLabelsSMARTOnlyAsProvisional() {
        let smart = EnduranceForecast(
            state: .estimated, message: "",
            estimatedEnduranceBytes: 1.19e15,
            enduranceRangeLowerBytes: 1.08e15,
            enduranceRangeUpperBytes: 1.30e15,
            confidence: .veryLow
        )
        XCTAssertEqual(ForecastEvidence.resolve(ftlTotal: 1.17e15, smart: smart), .ftl)

        // The note is checked in Japanese whatever the Mac's language is.
        UserDefaults.standard.set("ja", forKey: UIString.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: UIString.preferenceKey) }
        let provisional = ForecastEvidence.resolve(ftlTotal: nil, smart: smart)
        XCTAssertTrue(provisional.isSmartProvisional)
        XCTAssertTrue(provisional.smartProvisionalNote?.contains("暫定") == true)
        XCTAssertTrue(provisional.smartProvisionalNote?.contains("非常に低い") == true)

        let none = ForecastEvidence.resolve(ftlTotal: nil, smart: EnduranceForecast(state: .unavailable, message: ""))
        XCTAssertEqual(none, .unavailable)
        XCTAssertNil(none.smartProvisionalNote)
    }

    private func headlineSnapshot(pu: UInt64?, passed: Bool? = true) -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), deviceID: "disk0", devicePath: "/dev/rdisk0",
            logicalCapacityBytes: nil, model: "APPLE SSD", serialNumber: nil, firmware: nil, smartctlVersion: nil,
            smartctlExitStatus: 0, temperatureCelsius: nil, powerOnHours: nil, powerCycleCount: nil,
            unsafeShutdowns: nil, percentageUsed: pu, availableSpare: nil, availableSpareThreshold: nil,
            criticalWarning: 0, mediaAndDataIntegrityErrors: nil, dataUnitsRead: nil, dataUnitsWritten: nil,
            smartPassed: passed
        )
    }

    func testHeadlineCrossChecksControllerEstimateWithNANDWear() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let agree = DashboardHeadline.make(snapshot: headlineSnapshot(pu: 5), nandWearFraction: 0.056,
                                           remainingHostBytes: 1.10e15, paceBytesPerDay: 159e9, provisional: false, now: now)
        XCTAssertEqual(agree.status, "正常")
        XCTAssertEqual(agree.wear, "損耗 5.60%")
        XCTAssertTrue(agree.crossCheck?.contains("PU 5%") == true, "PU must be the value, not a bit pattern")
        XCTAssertTrue(agree.crossCheck?.contains("一致") == true)
        XCTAssertEqual(agree.remaining, "保存履歴のペースで残り約19年（2045年頃）")

        let differ = DashboardHeadline.make(snapshot: headlineSnapshot(pu: 9), nandWearFraction: 0.056,
                                            remainingHostBytes: nil, paceBytesPerDay: nil, provisional: false, now: now)
        XCTAssertTrue(differ.crossCheck?.contains("差があります") == true)

        let smartOnly = DashboardHeadline.make(snapshot: headlineSnapshot(pu: 5), nandWearFraction: nil,
                                               remainingHostBytes: 1e17, paceBytesPerDay: 159e9, provisional: true, now: now)
        XCTAssertEqual(smartOnly.wear, "損耗 5%（PU）")
        XCTAssertEqual(smartOnly.remaining, "暫定・保存履歴のペースで残り約1722年（3748年頃）")

        XCTAssertEqual(DashboardHeadline.make(snapshot: nil, nandWearFraction: nil, remainingHostBytes: nil,
                                              paceBytesPerDay: nil, provisional: false).status, "未取得")
    }

    func testHeadlineWearFollowsTheDomainThatRunsOutFirst() {
        func row(_ domain: NANDDomain, wear: Double, remainingHost: Double) -> DomainForecastRow {
            DomainForecastRow(domain: domain, wearFraction: wear, usedNANDBytes: 0, remainingNANDBytes: 0,
                              nandBytesPerHostByte: 1, remainingHostBytes: remainingHost)
        }
        // pSLC runs out first here, so the headline must quote pSLC wear.
        let rows = [row(.tlc, wear: 0.05, remainingHost: 2e15), row(.pslc, wear: 0.30, remainingHost: 1e15)]
        XCTAssertEqual(DashboardHeadline.nandWearFraction(rows: rows, estimates: []), 0.30)
        let tlc = NANDDomainEstimate(domain: .tlc, capacityBytes: 1, physicalFootprintBytes: nil, currentPE: 300,
                                     eolPE: 3_000, targetPE: 3_000, baselineBudgetBytes: 1, totalBudgetBytes: 1,
                                     usedBytes: 0, remainingBytes: 0)
        XCTAssertEqual(DashboardHeadline.nandWearFraction(rows: [], estimates: [tlc]), 0.1)
        XCTAssertNil(DashboardHeadline.nandWearFraction(rows: [], estimates: []))
    }

    func testHeadlineOmitsYearsForAnInfinitePace() {
        let snapshot = DriveSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), deviceID: "disk0", devicePath: "/dev/rdisk0",
            logicalCapacityBytes: 256_000_000_000, model: "APPLE SSD", serialNumber: nil, firmware: "591",
            smartctlVersion: nil, smartctlExitStatus: 0, temperatureCelsius: nil, powerOnHours: nil,
            powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: 5, availableSpare: nil,
            availableSpareThreshold: nil, criticalWarning: 0, mediaAndDataIntegrityErrors: nil,
            dataUnitsRead: nil, dataUnitsWritten: nil, smartPassed: true
        )
        let headline = DashboardHeadline.make(snapshot: snapshot, nandWearFraction: nil, remainingHostBytes: 1e15,
                                              paceBytesPerDay: .infinity, provisional: false)
        XCTAssertNil(headline.remaining)
    }

    func testChartGapSegmenterBreaksLinesAcrossGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let hours: [Double] = [0, 1, 2, 10, 11, 30]
        let dates = hours.map { start.addingTimeInterval($0 * 3_600) }
        XCTAssertEqual(ChartGapSegmenter.segments(dates: dates, bucketSeconds: 3_600), [0, 0, 0, 1, 1, 2])
        // Consecutive daily buckets stay in one segment.
        let days = (0..<4).map { start.addingTimeInterval(Double($0) * 86_400) }
        XCTAssertEqual(ChartGapSegmenter.segments(dates: days, bucketSeconds: HistoryPeriod.day.bucketSeconds), [0, 0, 0, 0])
        XCTAssertEqual(ChartGapSegmenter.segments(dates: [], bucketSeconds: 3_600), [])
    }

    func testRecordedHistoryPaceIsProvisionalUntilSevenObservedDays() {
        XCTAssertTrue(WriteRateSummary().recordedHistoryIsProvisional)
        XCTAssertTrue(WriteRateSummary(recordedHistoryObservedDays: 6.9).recordedHistoryIsProvisional)
        XCTAssertFalse(WriteRateSummary(recordedHistoryObservedDays: 7).recordedHistoryIsProvisional)
    }

    @MainActor
    func testHeadlineUsesRecordedHistoryPaceInsteadOfRecentPace() throws {
        let empty = DashboardAnalyticsSnapshot.empty
        let analytics = DashboardAnalyticsSnapshot(
            writePoints: empty.writePoints,
            temperaturePoints: empty.temperaturePoints,
            writeRateSummary: WriteRateSummary(
                thirtyDayBytesPerDay: 500e9, recordedHistoryBytesPerDay: 100e9,
                recordedHistoryObservedDays: 30, thirtyDayObservedDays: 30
            ),
            retentionPlanningEstimate: empty.retentionPlanningEstimate,
            lifeEstimate: empty.lifeEstimate,
            enduranceForecast: empty.enduranceForecast,
            writeBasedLifeProjection: empty.writeBasedLifeProjection,
            controllerForecast: empty.controllerForecast,
            controllerWearHistory: empty.controllerWearHistory,
            jesdClientSimulation: empty.jesdClientSimulation,
            retentionResearchEstimate: empty.retentionResearchEstimate,
            controllerInternalTelemetry: empty.controllerInternalTelemetry
        )
        let suite = "NenRing-headline-pace-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences, initialAnalytics: analytics)
        XCTAssertEqual(model.headlinePaceBytesPerDay, 100e9)
    }

    func testForecastPaceUsesUsageStartOnlyUntilHistorySettles() {
        let early = WriteRateSummary(lifetimeBytesPerDay: 50e9, recordedHistoryBytesPerDay: 130e9,
                                     recordedHistoryObservedDays: 6.9, lifetimeRateBasis: "使用開始設定から累積Host / 暦日")
        XCTAssertTrue(early.usesUsageStartPace)
        XCTAssertEqual(early.forecastPaceBytesPerDay, 50e9)

        let settled = WriteRateSummary(lifetimeBytesPerDay: 50e9, recordedHistoryBytesPerDay: 130e9,
                                       recordedHistoryObservedDays: 7, lifetimeRateBasis: "使用開始設定から累積Host / 暦日")
        XCTAssertFalse(settled.usesUsageStartPace)
        XCTAssertEqual(settled.forecastPaceBytesPerDay, 130e9)

        let noStartDate = WriteRateSummary(lifetimeBytesPerDay: 130e9, recordedHistoryBytesPerDay: 130e9,
                                           recordedHistoryObservedDays: 3)
        XCTAssertFalse(noStartDate.usesUsageStartPace)
        XCTAssertEqual(noStartDate.forecastPaceBytesPerDay, 130e9)
    }

    func testRemainingTextNamesTheUsageStartPace() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = DashboardHeadline.remainingText(remainingHostBytes: 100e9 * 365.25 * 8, paceBytesPerDay: 100e9,
                                                   provisional: true, usesUsageStartPace: true, now: now)
        XCTAssertEqual(text?.hasPrefix("暫定・使用開始からのペースで残り約8年"), true)
        XCTAssertEqual(UIString.message(text ?? "", language: "en").contains("at the rate since first use"), true)
    }

    func testUsageStartSummaryAndValidation() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = headlineSnapshot(pu: 5)
        let now = snapshot.capturedAt
        XCTAssertEqual(UsageStartSummary.validationMessage(start: now.addingTimeInterval(86_400), snapshot: snapshot, now: now),
                       "使用開始日は今日以前の日付を指定してください。")
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 23
        components.month = 5
        components.day = 1
        let typedTwoDigitYear = try XCTUnwrap(components.date)
        XCTAssertEqual(UsageStartSummary.validationMessage(start: typedTwoDigitYear, snapshot: snapshot, now: now),
                       "使用開始日は2000年以降の日付を指定してください。")
        XCTAssertNil(UsageStartSummary(start: now, snapshot: snapshot))
        XCTAssertNil(UsageStartSummary(start: now.addingTimeInterval(60), snapshot: snapshot))
        XCTAssertNotNil(UsageStartSummary(start: min(start, now.addingTimeInterval(-86_400)), snapshot: snapshot))
    }

    private func makeUsageStartSnapshot(powerOnHours: UInt64, writtenUnits: UInt64) -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), deviceID: "disk0", devicePath: "/dev/rdisk0",
            logicalCapacityBytes: nil, model: "APPLE SSD", serialNumber: nil, firmware: nil, smartctlVersion: nil,
            smartctlExitStatus: 0, temperatureCelsius: nil, powerOnHours: powerOnHours, powerCycleCount: nil,
            unsafeShutdowns: nil, percentageUsed: 5, availableSpare: nil, availableSpareThreshold: nil,
            criticalWarning: 0, mediaAndDataIntegrityErrors: nil, dataUnitsRead: nil, dataUnitsWritten: writtenUnits,
            smartPassed: true
        )
    }

    func testUsageStartValidationRejectsDatesLaterThanPowerOnHoursAllow() {
        let snapshot = makeUsageStartSnapshot(powerOnHours: 2_400, writtenUnits: 1_000_000)
        let now = snapshot.capturedAt
        // 2,400 h cannot fit in 10 days.
        XCTAssertEqual(UsageStartSummary.validationMessage(start: now.addingTimeInterval(-10 * 86_400), snapshot: snapshot, now: now),
                       "使用開始日がSSDの稼働時間と矛盾します。以前の使用分も含む日付を指定してください。")
        XCTAssertNil(UsageStartSummary.validationMessage(start: now.addingTimeInterval(-100 * 86_400), snapshot: snapshot, now: now))
        let summary = UsageStartSummary(start: now.addingTimeInterval(-100 * 86_400), snapshot: snapshot)
        XCTAssertEqual(summary?.elapsedDays ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(summary?.averagePowerOnHoursPerDay ?? 0, 24, accuracy: 1e-6)
        XCTAssertEqual(summary?.hostBytesPerDay ?? 0, 1_000_000 * 512_000 / 100, accuracy: 1)
    }

    func testHeadlineShowsHostWearAndKeepsNANDForTheCrossCheck() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let headline = DashboardHeadline.make(snapshot: headlineSnapshot(pu: 5), nandWearFraction: 0.059, hostWearFraction: 0.0574,
                                              remainingHostBytes: 1.1e15, paceBytesPerDay: 100e9, provisional: false, now: now)
        XCTAssertEqual(headline.wear, "損耗 5.74%")
        XCTAssertEqual(headline.crossCheck, "コントローラの推定（PU 5%）とNAND実測（5.90%）が一致")
    }

    func testRealHostWearFractionUsesTheActualUseProjection() {
        var nand = NANDEnduranceV2()
        XCTAssertNil(nand.realHostWearFraction)
        nand.host = 68.5e12
        XCTAssertNil(nand.realHostWearFraction)
        nand.projections = [.init(title: "実使用", total: 1_194e12, remaining: 1_125.5e12, note: "")]
        XCTAssertEqual(nand.realHostWearFraction ?? 0, 68.5 / 1_194, accuracy: 1e-9)
    }
}
