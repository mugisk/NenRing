import Foundation
import XCTest
@testable import NenRing

final class JESDLikeTBWProxyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calculator = JESDLikeTBWProxyCalculator()

    func smart(host: Double = 60.38e12) -> DriveSnapshot {
        DriveSnapshot(capturedAt: now, deviceID: "d", devicePath: "/dev/rdisk0", logicalCapacityBytes: 256_000_000_000,
            model: "test", serialNumber: nil, firmware: "fw", smartctlVersion: nil, smartctlExitStatus: 0,
            temperatureCelsius: 40, powerOnHours: 3000, powerCycleCount: nil, unsafeShutdowns: nil,
            percentageUsed: 5, availableSpare: 100, availableSpareThreshold: nil, criticalWarning: 0,
            mediaAndDataIntegrityErrors: 0, dataUnitsRead: nil, dataUnitsWritten: UInt64(host / 512_000), smartPassed: true)
    }

    func ftl(host: Double = 60.38e12, waf: Double = 1.58725, tlc: Double? = 156, maximum: Double? = 169,
             slc: Double? = 5163, slcMax: Double? = 5164, date: Date? = nil,
             build: String? = "build", units: ASPToolUnitState = .provisional4KiB,
             source: ASPToolSourceArtifact = .directFTL, contractBuild: String? = nil) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(capturedAt: date ?? now, captureQuality: .explicit,
            deviceID: "d", sourceArtifact: source, sourceBuild: build, contractBuild: contractBuild, extractionVersion: 1,
            hostWrites: UInt64(host / 4096), nandWrites: UInt64(host * waf / 4096),
            hostWritesUnitState: units, nandWritesUnitState: units,
            tlcAveragePE: tlc, tlcMaximumPE: maximum, tlcEOLPE: 3000,
            slcAveragePE: slc, slcMaximumPE: slcMax, slcEOLPE: 100_000, firmware: "fw")
    }

    func estimate(_ snapshots: [ASPToolDiagnosticsSnapshot]? = nil, sessions: [ResearchSession] = [],
                  selection: String? = nil, host: Double = 60.38e12, rate: Double? = 100e9,
                  excluding: [DateInterval] = [], customTLCPE: Double? = nil,
                  customPSLCPE: Double? = nil) -> JESDLikeTBWProxyResult {
        let samples = snapshots ?? [ftl()]
        return calculator.estimate(JESDLikeTBWProxyInput(smart: smart(host: host), snapshots: samples, sessions: sessions,
            wearHistory: ControllerWearHistoryAnalyzer().summarize(snapshots: samples, deviceID: "d", excluding: excluding),
            selection: selection, dailyRate: rate, historicalRate: 50e9, now: now,
            customTLCPE: customTLCPE, customPSLCPE: customPSLCPE))
    }

    func session(waf: Double = 2, age: Double = 1, contamination: Bool = false,
                 legacy: Bool = false, reset: Bool = false, build: String? = "build",
                 unknownFirmware: Bool = false) -> ResearchSession {
        let start = now.addingTimeInterval(-age * 86_400)
        let phases: [ResearchObservationPhase] = [.beforeWrite, .populationComplete, .overwriteSegment, .overwriteSegment, .finished, .cooldown]
        let steps = [0, 1, 2, 3, 3, 3]
        let base: UInt64 = 1_000_000_000
        let delta: UInt64 = 250_000 // 1.024 GB/interval; exact SMART units.
        let observations = phases.enumerated().map { index, phase in
            ResearchTelemetryObservation(capturedAt: start + Double(index * 10),
                smartCapturedAt: legacy ? nil : start + Double(index * 10),
                ftlCapturedAt: legacy ? nil : start + Double(index * 10),
                deviceID: "d", hostWrites: reset && index == 2 ? 0 : base + UInt64(steps[index]) * delta,
                nandWrites: base * 2 + UInt64(Double(steps[index]) * Double(delta) * waf),
                smartDataUnitsWritten: 8_000_000 + UInt64(steps[index]) * 2000,
                hostUnitState: .provisional4KiB, nandUnitState: .provisional4KiB,
                sourceBuild: build, extractionVersion: 1,
                tlcAveragePE: 150, tlcMaximumPE: 160, slcAveragePE: 5000, slcMaximumPE: 5001,
                tlcEOLPE: 3000, slcEOLPE: 100_000, firmwareEpoch: unknownFirmware ? nil : "fw", temperatureCelsius: 40,
                criticalWarning: 0, phase: phase,
                bytesWrittenInPhase: legacy ? nil : (phase == .overwriteSegment ? (contamination && index == 2 ? 256_000_000 : 1_024_000_000) : 0))
        }
        return ResearchSession(deviceID: "d", logicalCapacityBytes: 256_000_000_000,
            firmwareEpoch: "fw", startedAt: start, finishedAt: start + 60,
            protocolVersion: legacy ? "client-proxy-v1" : "client-proxy-v2", seed: 42,
            plannedMaximumBytes: 3_072_000_000, writtenBytes: 3_072_000_000,
            state: .completed, observations: observations)
    }

    func testRegressionWithoutTrialStillDisplaysProvisionalNumbers() throws {
        let result = estimate()
        XCTAssertNil(result.unavailableReason)
        XCTAssertEqual(result.scenarios.count, 3)
        let guarded = try XCTUnwrap(result.scenarios.first { $0.id == "conservative" })
        XCTAssertEqual(guarded.totalHostBytes / 1e12, 1071.8343, accuracy: 0.01)
        XCTAssertEqual(result.wafBasis, "試験負荷補正なし · 累積WAF代用")
        XCTAssertEqual(result.unitState, .provisional4KiB)
        XCTAssertTrue(result.projections[0].basis.contains("過去平均"))
        XCTAssertNotNil(result.projections[0].date)
        XCTAssertEqual(result.allowablePESensitivity.scenarios.count, 4)
        XCTAssertEqual(result.allowablePESensitivity.wearBasis, .lifetimeAverage)
    }

    func testAllowablePESensitivityOrdersFourAssumptionsAndUsesCurrentWearForRemainder() throws {
        let result = estimate()
        let scenarios = result.allowablePESensitivity.scenarios
        XCTAssertEqual(scenarios.map(\.id), ["eol-25", "eol-50", "eol-75", "eol-100"])
        for pair in zip(scenarios, scenarios.dropFirst()) {
            XCTAssertLessThan(pair.0.totalHostBytes, pair.1.totalHostBytes)
            XCTAssertLessThanOrEqual(pair.0.remainingHostBytes, pair.1.remainingHostBytes)
        }
        let full = try XCTUnwrap(scenarios.last)
        let tlc = try XCTUnwrap(full.domains.first { $0.name == "TLC" })
        let observedHostWrites = try XCTUnwrap(smart().dataUnitsWrittenBytes)
        XCTAssertEqual(tlc.totalHostBytes, tlc.eolPE * observedHostWrites / tlc.currentAveragePE, accuracy: 10)
        XCTAssertEqual(tlc.remainingHostBytes,
            max(0, tlc.eolPE - tlc.currentAveragePE) * observedHostWrites / tlc.currentAveragePE, accuracy: 10)
        XCTAssertTrue(full.currentRateProjection.date != nil)
        XCTAssertTrue(full.historicalRateProjection.date != nil)
    }

    func testCustomAllowablePEIsAddedWithoutReplacingFixedScenarios() throws {
        let result = estimate(customTLCPE: 3_500, customPSLCPE: 80_000)
        XCTAssertEqual(result.allowablePESensitivity.scenarios.count, 5)
        let custom = try XCTUnwrap(result.allowablePESensitivity.scenarios.last)
        XCTAssertEqual(custom.id, "custom")
        XCTAssertEqual(custom.domains.first { $0.name == "TLC" }?.allowablePE, 3_500)
        XCTAssertEqual(custom.domains.first { $0.name == "pSLC" }?.allowablePE, 80_000)
        XCTAssertTrue(custom.notes.contains { $0.contains("EOL超") })

        let oneCustomDomain = estimate(customTLCPE: 1_500)
        let oneCustom = try XCTUnwrap(oneCustomDomain.allowablePESensitivity.scenarios.last)
        XCTAssertEqual(oneCustom.domains.first { $0.name == "pSLC" }?.allowablePE, 100_000)
        XCTAssertTrue(oneCustom.notes.contains { $0.contains("pSLCはEOL値") })

        let invalidCustom = estimate(customTLCPE: .nan)
        XCTAssertEqual(invalidCustom.allowablePESensitivity.scenarios.count, 4)
        XCTAssertTrue(invalidCustom.allowablePESensitivity.notes.contains { $0.contains("不正") })
    }

    func testDifferentTrialWAFUsesPhysicalRemainingNotHistoricalHostSubtraction() throws {
        let trial = session(waf: 3)
        let result = estimate(sessions: [trial])
        XCTAssertEqual(result.selectedSessionID, trial.id)
        XCTAssertEqual(result.selectedWAF, 3)
        let base = try XCTUnwrap(result.scenarios.first)
        let physical = try XCTUnwrap(result.currentPhysicalWrites)
        XCTAssertEqual(base.remainingHostBytes, (base.physicalBudget - physical) / 3, accuracy: 1)
        XCTAssertGreaterThan(abs(base.remainingHostBytes - (base.totalHostBytes - smart().dataUnitsWrittenBytes!)), 1e12)
        XCTAssertEqual(result.projections[0], estimate().projections[0])
        XCTAssertNotEqual(result.projections[2].years, estimate().projections[2].years)
        let lifetimeSensitivity = estimate().allowablePESensitivity
        XCTAssertEqual(result.allowablePESensitivity.scenarios, lifetimeSensitivity.scenarios)
        XCTAssertEqual(result.allowablePESensitivity.wearBasis, lifetimeSensitivity.wearBasis)
    }

    func testCrossDomainGuardIsSeparateScenario() throws {
        let result = estimate([ftl(tlc: 180, maximum: 180, slc: 5000, slcMax: 6000)])
        let paired = try XCTUnwrap(result.scenarios.first { $0.id == "paired" })
        let conservative = try XCTUnwrap(result.scenarios.first { $0.id == "conservative" })
        XCTAssertEqual(paired.wearFraction, 0.06, accuracy: 1e-9)
        XCTAssertEqual(conservative.wearFraction, 0.072, accuracy: 1e-9)
        XCTAssertEqual(conservative.totalHostBytes / paired.totalHostBytes, 1 / 1.2, accuracy: 1e-9)
    }

    func testMissingDomainAndMaximumKeepPartialBase() {
        let result = estimate([ftl(maximum: nil, slc: nil, slcMax: nil)])
        XCTAssertNil(result.unavailableReason)
        XCTAssertEqual(result.scenarios.count, 1)
        XCTAssertTrue(result.notes.contains { $0.contains("片側domain") })
        XCTAssertEqual(result.allowablePESensitivity.scenarios.count, 4)
        XCTAssertEqual(result.allowablePESensitivity.scenarios.first?.domains.count, 1)
        XCTAssertTrue(result.allowablePESensitivity.notes.contains { $0.contains("片側domain") })
    }

    func testAgeAndContaminationAreManualOnly() {
        for trial in [session(age: 100), session(contamination: true), session(legacy: true), session(waf: 11)] {
            let automatic = estimate(sessions: [trial])
            XCTAssertNil(automatic.selectedSessionID)
            XCTAssertTrue(automatic.trials[0].selectable, automatic.trials[0].invalidReason ?? "")
            let manual = estimate(sessions: [trial], selection: trial.id.uuidString)
            XCTAssertEqual(manual.selectedSessionID, trial.id)
            XCTAssertFalse(manual.notes.isEmpty)
        }
    }

    func testLegacyRepeatedPayloadSessionRemainsManualButIsNeverAutoSelected() throws {
        let legacy = session(legacy: true)
        let result = estimate(sessions: [legacy])

        let trial = try XCTUnwrap(result.trials.first)
        XCTAssertEqual(trial.protocolVersion, "client-proxy-v1")
        XCTAssertTrue(trial.selectable)
        XCTAssertFalse(trial.automatic)
        XCTAssertTrue(trial.reasons.contains { $0.contains("payloadを反復") })
        XCTAssertNil(result.selectedSessionID)

        let manuallySelected = estimate(sessions: [legacy], selection: legacy.id.uuidString)
        XCTAssertEqual(manuallySelected.selectedSessionID, legacy.id)
    }

    func testResetAndBuildMismatchCannotBeManuallySelected() {
        for trial in [session(reset: true), session(build: "other")] {
            let result = estimate(sessions: [trial], selection: trial.id.uuidString)
            XCTAssertNil(result.selectedSessionID)
            XCTAssertFalse(result.trials[0].selectable)
        }
    }

    func testMacOSPointUpdateKeepsATrialAndAMajorUpdateDoesNot() {
        let pointUpdate = session(build: "26A434")
        let kept = estimate([ftl(build: "26B123")], sessions: [pointUpdate], selection: pointUpdate.id.uuidString)
        XCTAssertEqual(kept.selectedSessionID, pointUpdate.id)
        XCTAssertTrue(kept.trials[0].selectable)
        let majorUpdate = session(build: "25G83")
        let dropped = estimate([ftl(build: "26B123")], sessions: [majorUpdate], selection: majorUpdate.id.uuidString)
        XCTAssertNil(dropped.selectedSessionID)
        XCTAssertFalse(dropped.trials[0].selectable)
    }

    func testUnverifiedPointUpdateBoundaryStillCutsOffEarlierTrials() {
        let trial = session(age: 3, build: "26A434")
        // Without SMART history the boundary cannot be verified (D5/D6).
        let samples = [ftl(date: now - 4 * 86400, build: "26A434", contractBuild: "25G83"),
                       ftl(date: now - 2 * 86400, build: "26B123", contractBuild: "25G83"),
                       ftl(build: "26B123", contractBuild: "25G83")]
        let result = estimate(samples, sessions: [trial], selection: trial.id.uuidString)
        XCTAssertNil(result.selectedSessionID)
    }

    func testUnknownBuildIsVisibleButNotAutomatic() {
        let trial = session(build: nil)
        let result = estimate(sessions: [trial], selection: trial.id.uuidString)
        XCTAssertEqual(result.selectedSessionID, trial.id)
        XCTAssertFalse(result.trials[0].automatic)
    }

    func testUnknownFirmwareIsShownAsBasisNoteButDoesNotDiscardObservedTrial() {
        let trial = session(unknownFirmware: true)
        let result = estimate(sessions: [trial])
        XCTAssertEqual(result.selectedSessionID, trial.id)
        XCTAssertTrue(result.trials[0].automatic)
        XCTAssertTrue(result.trials[0].basisNotes.contains { $0.contains("firmware") })
    }

    func testInvalidUnitsAndNonfinitePEHoldOnlyProxy() {
        XCTAssertNotNil(estimate([ftl(units: .unverified)]).unavailableReason)
        XCTAssertNotNil(estimate([ftl(tlc: .infinity)]).unavailableReason)
        XCTAssertNotNil(estimate([ftl(tlc: 0, slc: 0)]).unavailableReason)
    }

    func testQualityThresholdsDoNotHideNumbers() {
        let result = estimate([ftl(waf: 12, tlc: 1, maximum: 10, slc: 1)])
        XCTAssertNil(result.unavailableReason)
        XCTAssertEqual(result.scenarios.count, 3)
        XCTAssertTrue(result.notes.contains { $0.contains("1%未満") })
    }

    func testZeroRateReachedAndExtremeDate() {
        XCTAssertNil(estimate(rate: 0).projections[0].date)
        XCTAssertNil(estimate(rate: 0).projections[0].years)
        let noCurrentPace = estimate(rate: 0).allowablePESensitivity.scenarios[0]
        XCTAssertNil(noCurrentPace.currentRateProjection.date)
        XCTAssertNil(noCurrentPace.currentRateProjection.years)
        XCTAssertNotNil(noCurrentPace.historicalRateProjection.date)
        let reached = estimate([ftl(tlc: 3000, maximum: 3001)])
        XCTAssertTrue(reached.projections[0].reached)
        XCTAssertEqual(reached.scenarios[0].remainingHostBytes, 0)
        XCTAssertTrue(reached.allowablePESensitivity.scenarios.allSatisfy { $0.currentRateProjection.reached })
        let extreme = calculator.projection("test", "test", 1e20, 1, now)
        XCTAssertNil(extreme.date)
        XCTAssertNotNil(extreme.years)
    }

    func testLatestWearUpdatesRemainingAndIgnoresNewerText() {
        let before = estimate()
        let after = estimate([ftl(date: now - 1), ftl(tlc: 160, date: now), ftl(tlc: 2999, date: now + 10, source: .extractedASPTool)])
        XCTAssertEqual(after.domains.first?.averagePE, 160)
        XCTAssertLessThan(after.scenarios[0].remainingHostBytes, before.scenarios[0].remainingHostBytes)
    }

    func testLatestResetDoesNotPresentMixedLifetimeAsCurrent() {
        let result = estimate([ftl(host: 80e12, date: now - 10), ftl()])
        XCTAssertNotNil(result.unavailableReason)
    }

    func testOldSettingsAndResearchJSONRemainReadable() throws {
        let old = try JSONDecoder().decode(UsageSettings.self, from: Data("{}".utf8))
        XCTAssertNil(old.proxyWAFSelection)
        var settings = old
        settings.proxyWAFSelection = "lifetime"
        settings.proxyAllowableTLCPE = 2_500
        settings.proxyAllowablePSLCPE = 90_000
        XCTAssertFalse(settings.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(UsageSettings.self, from: JSONEncoder().encode(settings)), settings)
        let legacy = session(legacy: true)
        let decoded = try JSONDecoder().decode(ResearchSession.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded, legacy)
        XCTAssertTrue(estimate(sessions: [decoded]).trials[0].reasons.contains { $0.contains("区間検証未実施") })
    }

    func testDailyHistoryAndResearchExclusionDoNotEraseCurrentWear() {
        let samples = [
            ftl(host: 54.38e12, tlc: 140, slc: 4900, date: now - 3 * 86400),
            ftl(host: 56.38e12, tlc: 145, slc: 5000, date: now - 2 * 86400),
            ftl(host: 58.38e12, tlc: 150, slc: 5100, date: now - 86400),
            ftl()
        ]
        let observed = estimate(samples)
        XCTAssertTrue(observed.projections[0].basis.contains("日常P/E履歴"))
        XCTAssertEqual(observed.allowablePESensitivity.wearBasis, .dailyHistory)
        XCTAssertEqual(observed.allowablePESensitivity.observedIntervalCounts["TLC"], 3)
        XCTAssertEqual(observed.allowablePESensitivity.observedIntervalCounts["pSLC"], 3)
        let excluded = estimate(samples, excluding: [DateInterval(start: now - 4 * 86400, end: now)])
        XCTAssertTrue(excluded.projections[0].basis.contains("過去平均"))
        XCTAssertEqual(excluded.allowablePESensitivity.wearBasis, .lifetimeAverage)
        XCTAssertEqual(observed.domains, excluded.domains)
        XCTAssertEqual(observed.scenarios, excluded.scenarios)
    }

    func testOneDomainWithInsufficientWearIntervalsForcesLifetimeFallbackForAllDomains() {
        let samples = [
            ftl(host: 54.38e12, tlc: 141, slc: 5_000, date: now - 3 * 86400),
            ftl(host: 56.38e12, tlc: 146, slc: 5_000, date: now - 2 * 86400),
            ftl(host: 58.38e12, tlc: 151, slc: 5_000, date: now - 86400),
            ftl(tlc: 156, slc: 5_000)
        ]
        let result = estimate(samples)
        XCTAssertEqual(result.allowablePESensitivity.observedIntervalCounts["TLC"], 3)
        XCTAssertEqual(result.allowablePESensitivity.observedIntervalCounts["pSLC"], 0)
        XCTAssertEqual(result.allowablePESensitivity.wearBasis, .lifetimeAverage)
        XCTAssertTrue(result.allowablePESensitivity.scenarios.allSatisfy {
            $0.domains.allSatisfy { $0.wearBasis == .lifetimeAverage }
        })
    }

    func testEpochChangeDropsEarlierDailySlopesAndTrials() {
        let trial = session(age: 3)
        let samples = [ftl(date: now - 4 * 86400, build: "old"), ftl(date: now - 2 * 86400), ftl()]
        let result = estimate(samples, sessions: [trial], selection: trial.id.uuidString)
        XCTAssertNil(result.selectedSessionID)
        XCTAssertTrue(result.projections[0].basis.contains("過去平均"))
    }

    func testAnalyticsConnectsSelectionAndKeepsRetentionSimulationIndependent() {
        let trial = session(waf: 3)
        let snapshots = [ftl(), ftl(tlc: 2900, date: now + 1, source: .extractedASPTool)]
        func build(_ settings: UsageSettings) -> DashboardAnalyticsSnapshot {
            DashboardAnalyticsSnapshot.build(analyzer: HistoryAnalyzer(), history: [smart()], deviceID: "d",
                period: .day, profile: nil, settings: settings, now: now,
                asptoolSnapshots: snapshots, researchSessions: [trial])
        }
        var settings = UsageSettings(manualStartDate: now - 365 * 86400)
        settings.proxyAllowableTLCPE = 2_500
        let automatic = build(settings)
        XCTAssertEqual(automatic.jesdLikeProxy.selectedSessionID, trial.id)
        XCTAssertEqual(automatic.jesdLikeProxy.domains.first?.averagePE, 156)
        XCTAssertNotNil(automatic.jesdLikeProxy.projections[1].date)
        XCTAssertEqual(automatic.allowablePESensitivity.scenarios.count, 5)
        if case .available = automatic.jesdClientSimulation { XCTFail("proxy must not fill retention profiles") }
        settings.proxyWAFSelection = "lifetime"
        let lifetime = build(settings)
        XCTAssertNil(lifetime.jesdLikeProxy.selectedSessionID)
        XCTAssertNotEqual(automatic.jesdLikeProxy.scenarios, lifetime.jesdLikeProxy.scenarios)
        XCTAssertEqual(automatic.jesdLikeProxy.projections[1], lifetime.jesdLikeProxy.projections[1])
        XCTAssertEqual(automatic.allowablePESensitivity, lifetime.allowablePESensitivity)
        XCTAssertEqual(automatic.peerTBWForecast, lifetime.peerTBWForecast)
        XCTAssertEqual(automatic.controllerForecast, lifetime.controllerForecast)
    }

    func testPopulationOnlyTrialCannotBecomeReferenceWAF() {
        var trial = session()
        trial.observations = Array(trial.observations.prefix(2))
        let result = estimate(sessions: [trial], selection: trial.id.uuidString)
        XCTAssertNil(result.selectedSessionID)
        XCTAssertFalse(result.trials[0].selectable)
        XCTAssertNil(result.unavailableReason)
    }
}
