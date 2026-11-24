import Foundation
import XCTest
@testable import NenRing

final class RetentionResearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let evaluator = RetentionModelEvaluator()

    func testClientNormalizationIsIndependentOfCurrentStorageAndClientWAFDoesNotChangeDailyForecast() throws {
        let ftl = makeFTLHistory()
        let history = ControllerWearHistoryAnalyzer().summarize(snapshots: ftl, deviceID: "drive-1")
        func result(_ settings: UsageSettings) throws -> RetentionResearchEstimate {
            guard case let .available(value) = RetentionResearchEstimator().estimate(
                latestSMART: makeSMART(at: now, hostBytes: 7e12), latestDirectFTL: ftl.last,
                wearHistory: history, settings: settings, currentDailyWriteRate: 1e11,
                historicalDailyWriteRate: nil, now: now, ftlHistory: ftl) else { throw NSError(domain: "test", code: 1) }
            return value
        }
        var settings = UsageSettings(retentionStorageTemperatureCelsius: 30)
        let base = try result(settings)
        settings.retentionStorageTemperatureCelsius = 100
        settings.retentionDays = 730
        let hot = try result(settings)
        XCTAssertEqual(base.clientTotalHostBytes, hot.clientTotalHostBytes)
        XCTAssertEqual(base.clientRemainingHostBytes, hot.clientRemainingHostBytes)
        XCTAssertNotEqual(base.primary.totalHostBytes, hot.primary.totalHostBytes)
        settings.retentionClientWAF = 4.4
        let higherWAF = try result(settings)
        XCTAssertEqual(hot.primary, higherWAF.primary)
        let observedHost = 7e12
        let futureAt2xWAF = try XCTUnwrap(hot.clientRemainingHostBytes) / 2
        XCTAssertEqual(try XCTUnwrap(higherWAF.clientTotalHostBytes), observedHost + futureAt2xWAF, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(higherWAF.clientRemainingHostBytes), try XCTUnwrap(hot.clientRemainingHostBytes) / 2, accuracy: 1)
        XCTAssertTrue(higherWAF.primary.domains.allSatisfy { $0.allowablePE.isFinite && $0.allowablePE >= 0 })
        settings.retentionClientWAF = .nan
        guard case .unavailable = estimate(smart: makeSMART(at: now, hostBytes: 7e12), ftl: ftl.last, history: history, settings: settings) else { return XCTFail("invalid WAF") }
    }

    func testPhysicalTBWUsesCapacityAndWAFInsteadOfQuantizedHostPerPEAsCenter() throws {
        let ftl = makeFTLHistory()
        let history = ControllerWearHistoryAnalyzer().summarize(snapshots: ftl, deviceID: "drive-1")
        let value = try XCTUnwrap(availableEstimate(settings: UsageSettings(), ftl: ftl, history: history))
        let physical = try XCTUnwrap(value.physicalModel)

        XCTAssertEqual(physical.effectiveNANDCapacityBytes, 256_000_000_000, accuracy: 0.5)
        XCTAssertEqual(physical.capacitySource, .logicalCapacityProxy)
        let observedHost = 4_915_200_000_000.0
        let expectedRemaining = (3_000.0 - 7) * 256_000_000_000 / 2.2
        XCTAssertEqual(physical.clientTotalHostBytes, observedHost + expectedRemaining, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(value.clientTotalHostBytes), physical.clientTotalHostBytes, accuracy: 1)
        XCTAssertNotEqual(physical.clientTotalHostBytes, value.primary.totalHostBytes)
        XCTAssertEqual(physical.clientCorrectedPE, 3_000, accuracy: 1e-9)
        XCTAssertTrue(value.hostPerPEDiagnostics.contains { $0.domain == .tlc && $0.priorHostBytesPerPE != nil })
        XCTAssertTrue(physical.notes.contains { $0.contains("pSLC") && $0.contains("加算していません") })
    }

    func testPhysicalTBWCanUseConsistentGeometryButNeverAddsPSLCAsAnotherCapacity() throws {
        let ftl = makeFTLHistory()
        let history = ControllerWearHistoryAnalyzer().summarize(snapshots: ftl, deviceID: "drive-1")
        let profile = AppleNANDHardwareProfile(
            modelNumber: "Test SSD",
            logicalCapacityBytes: 256_000_000_000,
            nandVendor: "Fixture",
            nandMarketingName: "fixture-tlc",
            defaultBitsPerCell: 3,
            pageSize: 16_384,
            pagesPerBlockNative: 1_536,
            pagesPerBlockSLC: 512,
            sectorsPerPage: 4,
            blocksPerCAU: 3_309,
            cauPerDie: 1,
            numBus: 4,
            diesPerBus: [1, 1, 1, 1],
            busToMSP: [0, 0, 1, 1],
            numDIP: 4,
            sectorsPerFullBand: 24_576,
            sectorsPerFullBandSLC: 8_192
        )
        guard case let .available(value) = estimate(
            smart: makeSMART(at: now, hostBytes: 4_915_200_000_000),
            ftl: ftl.last,
            history: history,
            hardwareProfile: profile
        ) else {
            return XCTFail("consistent geometry should provide a physical research proxy")
        }
        let physical = try XCTUnwrap(value.physicalModel)
        let geometryCapacity = Double(4 * 3_309 * 1_536 * 16_384)

        XCTAssertEqual(profile.geometryConfidence, .consistent)
        XCTAssertEqual(physical.capacitySource, .geometryResearchProxy)
        XCTAssertEqual(physical.effectiveNANDCapacityBytes, geometryCapacity, accuracy: 0.5)
        let expectedRemaining = (3_000.0 - 7) * geometryCapacity / 2.2
        XCTAssertEqual(physical.clientTotalHostBytes, 4_915_200_000_000 + expectedRemaining, accuracy: 1)
        XCTAssertFalse(physical.notes.contains { $0.contains("pSLC容量") })
    }

    func testControllerEOLAnchorsClientAndCurrentConditionUsesWeakResearchRatio() throws {
        let ftl = makeFTLHistory()
        let history = ControllerWearHistoryAnalyzer().summarize(snapshots: ftl, deviceID: "drive-1")
        var settings = UsageSettings(retentionDays: 365, retentionStorageTemperatureCelsius: 30,
            retentionResearchWeight: 0)
        let nominal = try XCTUnwrap(availableEstimate(settings: settings, ftl: ftl, history: history))
        XCTAssertEqual(try XCTUnwrap(nominal.clientEffectiveTLCPE), 3_000, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(nominal.effectiveTLCPE), 3_000, accuracy: 1e-9)
        XCTAssertEqual(nominal.clientAllowance?.targetTemperatureCelsius, 30)
        XCTAssertEqual(nominal.clientAllowance?.targetRetentionDays, 365)

        settings.retentionStorageTemperatureCelsius = 0
        settings.retentionResearchWeight = 1
        let cool = try XCTUnwrap(availableEstimate(settings: settings, ftl: ftl, history: history))
        XCTAssertEqual(try XCTUnwrap(cool.clientEffectiveTLCPE), 3_000, accuracy: 1e-9)
        XCTAssertGreaterThan(cool.effectiveTLCPE!, cool.tlcControllerEOLPE)
        XCTAssertLessThanOrEqual(cool.legacyEOLLimitedTLCPE!, cool.tlcControllerEOLPE)
        XCTAssertTrue(cool.notes.contains { $0.contains("Controller EOLを超える") })
        XCTAssertEqual(cool.retentionResearchWeight, 1)
        XCTAssertGreaterThan(cool.researchRetentionRatio!, 1)
    }

    func testWAFUsesPriorAndObservedLogBlendWithoutIntervalCountBoost() throws {
        let samples = makeFTLHistory()
        let analyzer = RetentionWAFAnalyzer()
        let value = analyzer.assess(snapshots: samples, latest: samples.last!, now: now,
            excluding: [], client: 2.2, prior: 2.2, selection: nil, trials: [])
        let observed = try XCTUnwrap(value.observed)
        XCTAssertGreaterThan(observed, 0)
        XCTAssertGreaterThan(value.blended, min(value.prior, observed))
        XCTAssertLessThan(value.blended, max(value.prior, observed))
        XCTAssertGreaterThan(value.blendWeight, 0)
        XCTAssertLessThan(value.blendWeight, 1)
        XCTAssertEqual(value.confidenceScore, Int((value.blendWeight * 100).rounded()))
        XCTAssertEqual(value.current, observed, accuracy: 1e-10)
        XCTAssertTrue(value.currentSource.contains("実測値") || value.currentSource.contains("累積実測値"))

        let split = [
            makeFTL(at: now.addingTimeInterval(-2 * 86_400), hostRaw: 600_000_000),
            makeFTL(at: now.addingTimeInterval(-86_400), hostRaw: 900_000_000),
            makeFTL(at: now, hostRaw: 1_200_000_000)
        ]
        let splitValue = analyzer.assess(snapshots: split, latest: split.last!, now: now,
            excluding: [], client: 2.2, prior: 2.2, selection: nil, trials: [])
        let splitObservedHost = splitValue.observedHostBytes
        XCTAssertEqual(splitValue.blendWeight,
                       splitObservedHost / (splitObservedHost + splitValue.priorEquivalentHostBytes),
                       accuracy: 1e-12)
        XCTAssertNotEqual(splitValue.blendWeight, value.blendWeight,
                          "観測Host量を重みに使うため、別の累積観測量ではqが変わる")
    }

    func testDomainFallbackCanUseObservedTLCAndLifetimePSLCIndependently() throws {
        let samples = [
            makeFTL(at: now.addingTimeInterval(-2 * 86_400), hostRaw: 400_000_000,
                tlcAverage: 3, tlcMaximum: 5, slcAverage: 84, slcMaximum: 88),
            makeFTL(at: now.addingTimeInterval(-86_400), hostRaw: 800_000_000,
                tlcAverage: 4, tlcMaximum: 6, slcAverage: 84, slcMaximum: 88),
            makeFTL(at: now, hostRaw: 1_200_000_000,
                tlcAverage: 5, tlcMaximum: 7, slcAverage: 84, slcMaximum: 88)
        ]
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: samples, deviceID: "drive-1")
        let value = try XCTUnwrap(availableEstimate(settings: UsageSettings(), ftl: samples, history: summary))
        XCTAssertEqual(value.primary.inputSource, .mixed)
        let tlc = try XCTUnwrap(value.primary.domainEvidence.first { $0.domain == .tlc })
        let pslc = try XCTUnwrap(value.primary.domainEvidence.first { $0.domain == .pSLC })
        XCTAssertEqual(tlc.inputSource, .dailyHistory)
        XCTAssertEqual(pslc.inputSource, .lifetimeAverage)
        XCTAssertEqual(pslc.observedIntervals, 0)
        XCTAssertTrue(value.primary.notes.contains { $0.contains("利用可能な入力源") })
    }

    func testProgramTemperaturePrefersDirectFTLNANDWeight() throws {
        let times = [-120.0, -60.0, 0.0]
        let temperatures = [30, 50, 50].enumerated().map { index, temperature in
            TemperatureSample(capturedAt: now.addingTimeInterval(times[index]), deviceID: "drive-1",
                temperatureCelsius: temperature)
        }
        let ftl = [
            makeFTL(at: now.addingTimeInterval(-120), hostRaw: 100),
            makeFTL(at: now.addingTimeInterval(-60), hostRaw: 200),
            makeFTL(at: now, hostRaw: 400)
        ]
        let smart = times.map { offset in makeSMART(at: now.addingTimeInterval(offset), hostBytes: 1e9 + (offset + 120) * 1e8) }
        let value = ThermalRetentionAnalyzer().assess(smartHistory: smart, temperatureHistory: temperatures,
            deviceID: "drive-1", storageTemperature: 30, activationEnergy: 1.1,
            programCorrection: false, now: now, ftlHistory: ftl)
        XCTAssertEqual(value.programWeightSource, "Direct FTL NAND Writes")
        XCTAssertEqual(try XCTUnwrap(value.programTemperature), 46.6666666667, accuracy: 0.01)
        XCTAssertEqual(value.coverage, 1, accuracy: 1e-9)
    }

    func testTemperatureCoverageCooldownOverrideAndGapExclusion() throws {
        let start = now.addingTimeInterval(-3_600)
        let temperatures = [44, 46, 45, 42, 36, 31, 29].enumerated().map { i, t in
            TemperatureSample(capturedAt: start.addingTimeInterval(Double(i) * 600), deviceID: "drive-1", temperatureCelsius: t)
        }
        let smart = [makeSMART(at: start, hostBytes: 1e9), makeSMART(at: start.addingTimeInterval(1_800), hostBytes: 11e9), makeSMART(at: now, hostBytes: 12e9)]
        func thermal(_ user: Double? = nil, enabled: Bool = false, excluded: [DateInterval] = []) -> ThermalRetentionAssessment {
            ThermalRetentionAnalyzer().assess(smartHistory: smart, temperatureHistory: temperatures,
                deviceID: "drive-1", storageTemperature: user, activationEnergy: 1.1,
                programCorrection: enabled, now: now, excluding: excluded)
        }
        let value = thermal()
        XCTAssertGreaterThan(try XCTUnwrap(value.programTemperature), 40)
        XCTAssertEqual(value.programFactor, 1)
        XCTAssertEqual(value.coverage, 1, accuracy: 1e-6)
        XCTAssertTrue((25...35).contains(value.storageTemperature))
        XCTAssertTrue(value.storageSource.contains("cooldown"))
        XCTAssertEqual(thermal(30).stressRelativeTo30, 1, accuracy: 1e-9)
        XCTAssertEqual(thermal(25).storageSource, "利用者指定")
        XCTAssertGreaterThan(thermal(enabled: true).programFactor, 1)
        XCTAssertLessThanOrEqual(thermal(enabled: true).programFactor, 1.02)
        XCTAssertNil(thermal(excluded: [DateInterval(start: start, end: now)]).programTemperature)
        let empty = ThermalRetentionAnalyzer().assess(smartHistory: [], temperatureHistory: [], deviceID: "drive-1",
            storageTemperature: nil, activationEnergy: 1.1, programCorrection: true, now: now)
        XCTAssertEqual(empty.storageTemperature, 30)
        XCTAssertEqual(empty.coverage, 0)
        XCTAssertEqual(empty.programFactor, 1)
    }

    func testCooldownSearchIsBoundedForThousandsOfTemperatureSamples() throws {
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let flatHistory = (0..<4_058).map { index in
            TemperatureSample(
                capturedAt: firstDate.addingTimeInterval(Double(index) * 900),
                deviceID: "drive-1",
                temperatureCelsius: 40
            )
        }

        let start = ProcessInfo.processInfo.systemUptime
        let noCooldown = ThermalRetentionAnalyzer.cooldownSamples(
            in: flatHistory,
            maxGap: 2_700,
            excluding: []
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertNil(noCooldown)
        XCTAssertLessThan(elapsed, 5, "Cooldown analysis should not rescan and copy the full history per endpoint")

        let tailStart = try XCTUnwrap(flatHistory.last?.capturedAt.addingTimeInterval(3_600))
        let validCooldown = [40, 39, 38, 36].enumerated().map { index, temperature in
            TemperatureSample(
                capturedAt: tailStart.addingTimeInterval(Double(index) * 600),
                deviceID: "drive-1",
                temperatureCelsius: temperature
            )
        }
        let latest = try XCTUnwrap(ThermalRetentionAnalyzer.cooldownSamples(
            in: flatHistory + validCooldown,
            maxGap: 2_700,
            excluding: []
        ))
        XCTAssertEqual(latest, validCooldown)
    }

    func testShortWearDoesNotResetRegularAnchorAndRemainsProvisional() throws {
        let samples: [ASPToolDiagnosticsSnapshot] = (0...24).map { i in
            let date = now.addingTimeInterval(Double(i - 24) * 3_600)
            let raw = UInt64(i + 1) * 20_000_000
            return makeFTL(at: date, hostRaw: raw,
                tlcAverage: 100 + Double(i), tlcMaximum: 110 + Double(i), slcAverage: 200 + Double(i), slcMaximum: 210 + Double(i))
        }
        let regular = ControllerWearHistoryAnalyzer().summarize(snapshots: samples, deviceID: "drive-1", aggregateSlopes: true)
        let short = ControllerWearHistoryAnalyzer().summarize(snapshots: samples, deviceID: "drive-1", provisional: true, aggregateSlopes: true)
        XCTAssertEqual(regular.intervalCount, 1)
        XCTAssertEqual(short.intervalCount, 24)
        XCTAssertEqual(regular.tlcHostBytesPerPE, short.tlcHostBytesPerPE)
        guard case let .available(value) = RetentionResearchEstimator().estimate(latestSMART: makeSMART(at: now, hostBytes: 4e12),
            latestDirectFTL: samples.last, wearHistory: regular, settings: UsageSettings(), currentDailyWriteRate: 1e11,
            historicalDailyWriteRate: nil, now: now, provisionalHistory: short) else { return XCTFail("provisional") }
        XCTAssertEqual(value.primary.inputSource, .limitedDailyHistory)
    }

    func testWAFWorksWithoutWearProgressAndExcludesResearchAndEpochs() throws {
        let samples = [1, 2, 5].enumerated().map { i, h in
            makeFTL(at: now.addingTimeInterval(Double(i - 2) * 3_600), hostRaw: UInt64(h) * 1_000_000)
        }
        func assess(_ data: [ASPToolDiagnosticsSnapshot], excluding: [DateInterval] = []) -> RetentionWAFAssessment {
            RetentionWAFAnalyzer().assess(snapshots: data, latest: data.last!, now: now, excluding: excluding, client: 2.2, selection: nil, trials: [])
        }
        let waf = assess(samples)
        XCTAssertEqual(try XCTUnwrap(waf.daily), 1.7, accuracy: 1e-10)
        XCTAssertEqual(waf.windows[1].count, 2)
        XCTAssertEqual(waf.windows[1].hostBytes, 4_000_000 * 4096)
        let excluded = assess(samples, excluding: [DateInterval(start: samples[0].capturedAt, end: now)])
        XCTAssertEqual(excluded.windows[1].count, 0)
        XCTAssertEqual(excluded.dailySource, "累積比")
        let reset = samples + [makeFTL(at: now.addingTimeInterval(60), hostRaw: 10)]
        XCTAssertEqual(assess(reset).windows[1].count, 0)
    }

    func testWAFWindowFreeSpaceUsesOnlyMatchingSMARTSamplesInsideContributingIntervals() throws {
        let ftl = [
            makeFTL(at: now.addingTimeInterval(-6 * 86_400), hostRaw: 100_000),
            makeFTL(at: now.addingTimeInterval(-2 * 86_400), hostRaw: 200_000),
            makeFTL(at: now, hostRaw: 300_000)
        ]
        func smart(at date: Date, freeBytes: UInt64, deviceID: String = "drive-1",
                   includesCapacity: Bool = true) -> DriveSnapshot {
            var value = makeSMART(at: date, hostBytes: 1_000_000, deviceID: deviceID)
            value.filesystemTotalCapacityBytes = includesCapacity ? 100_000 : nil
            value.filesystemFreeBytes = freeBytes
            return value
        }
        let filesystemHistory = [
            smart(at: now.addingTimeInterval(-8 * 86_400), freeBytes: 1_000), // Outside 7d WAF intervals.
            smart(at: now.addingTimeInterval(-5 * 86_400), freeBytes: 15_000, includesCapacity: false), // Bytes remain useful without a ratio.
            smart(at: now.addingTimeInterval(-3 * 86_400), freeBytes: 20_000),
            smart(at: now.addingTimeInterval(-86_400), freeBytes: 30_000),
            smart(at: now.addingTimeInterval(-86_400), freeBytes: 1_000, deviceID: "other-drive")
        ]

        let assessment = RetentionWAFAnalyzer().assess(
            snapshots: ftl,
            latest: ftl.last!,
            now: now,
            excluding: [],
            client: 2.2,
            selection: nil,
            trials: [],
            filesystemHistory: filesystemHistory
        )
        let sevenDay = try XCTUnwrap(assessment.windows.first { $0.days == 7 })
        XCTAssertEqual(sevenDay.filesystemFreeSampleCount, 3)
        XCTAssertEqual(sevenDay.minimumFilesystemFreeBytes, 15_000)
        XCTAssertEqual(try XCTUnwrap(sevenDay.minimumFilesystemFreeRatio), 0.2, accuracy: 1e-12)

        let withoutHistory = RetentionWAFAnalyzer().assess(
            snapshots: ftl,
            latest: ftl.last!,
            now: now,
            excluding: [],
            client: 2.2,
            selection: nil,
            trials: []
        )
        let noSpace = try XCTUnwrap(withoutHistory.windows.first { $0.days == 7 })
        XCTAssertEqual(noSpace.filesystemFreeSampleCount, 0)
        XCTAssertNil(noSpace.minimumFilesystemFreeBytes)
        XCTAssertNil(noSpace.minimumFilesystemFreeRatio)
    }

    func testThermalClientSettingsRoundTripAndOldDefaults() throws {
        let old = try JSONDecoder().decode(UsageSettings.self, from: Data("{}".utf8))
        XCTAssertNil(old.retentionClientWAF)
        XCTAssertNil(old.retentionProgramCorrectionEnabled)
        var settings = old
        settings.retentionClientWAF = 3.1
        settings.retentionProgramCorrectionEnabled = true
        settings.retentionClientWAFSelection = UUID().uuidString
        settings.retentionDailyWAFPrior = 2.2
        settings.retentionResearchWeight = 0.2
        settings.retentionTLCBytesPerPEPrior = 1.2e12
        settings.retentionPSLCBytesPerPEPrior = 2.4e12
        XCTAssertFalse(settings.isEmpty)
        XCTAssertEqual(settings, try JSONDecoder().decode(UsageSettings.self, from: JSONEncoder().encode(settings)))
    }

    func testTemperatureDoesNotBridgeLongSleepGapOrOtherDevice() {
        let offsets: [Double] = [-7_200, -7_140, -7_080, -120, -60, 0]
        let temperatures = offsets.map { offset in
            TemperatureSample(capturedAt: now.addingTimeInterval(offset), deviceID: "drive-1", temperatureCelsius: 40)
        } + [TemperatureSample(capturedAt: now, deviceID: "other", temperatureCelsius: 120)]
        let smart = [makeSMART(at: now.addingTimeInterval(-7_200), hostBytes: 1e9), makeSMART(at: now, hostBytes: 2e9)]
        let value = ThermalRetentionAnalyzer().assess(smartHistory: smart, temperatureHistory: temperatures,
            deviceID: "drive-1", storageTemperature: nil, activationEnergy: 1.1, programCorrection: false, now: now)
        XCTAssertEqual(value.coverage, 240 / 7_200.0, accuracy: 1e-8)
        XCTAssertEqual(value.programTemperature, 40)
        XCTAssertEqual(value.storageTemperature, 40)
    }

    func testWAFUsesRatioOfSumsAndAggregatesZeroHostIntervals() throws {
        func sample(_ i: Int, _ h: UInt64, _ n: UInt64, build: String = "A") -> ASPToolDiagnosticsSnapshot {
            ASPToolDiagnosticsSnapshot(capturedAt: now.addingTimeInterval(Double(i - 3) * 600), captureQuality: .explicit,
                deviceID: "drive-1", sourceArtifact: .directFTL, sourceBuild: build, extractionVersion: 1,
                hostWrites: h, nandWrites: n, hostWritesUnitState: .provisional4KiB, nandWritesUnitState: .provisional4KiB)
        }
        let samples = [sample(0, 100, 100), sample(1, 100, 200), sample(2, 200, 400), sample(3, 1_100, 1_300)]
        func assessment(_ data: [ASPToolDiagnosticsSnapshot]) -> RetentionWAFAssessment {
            RetentionWAFAnalyzer().assess(snapshots: data, latest: data.last!, now: now,
                excluding: [], client: 2.2, selection: nil, trials: [])
        }
        let waf = assessment(samples)
        XCTAssertEqual(try XCTUnwrap(waf.daily), 1.2, accuracy: 1e-10)
        XCTAssertEqual(waf.windows[1].count, 2)
        let pendingEpochWAF = assessment(samples + [sample(3, 1_200, 1_400, build: "B")]).windows[1]
        XCTAssertEqual(pendingEpochWAF.count, waf.windows[1].count,
                       "未検証の新計測器を拒否しても、境界前の有効区間は保持する")
        XCTAssertEqual(try XCTUnwrap(pendingEpochWAF.value), try XCTUnwrap(waf.windows[1].value), accuracy: 1e-10)
        // NAND falls below the immediately preceding zero-Host sample but not the anchor.
        let reset = assessment([sample(0, 100, 100), sample(1, 100, 300), sample(2, 200, 200)])
        XCTAssertEqual(reset.windows[1].count, 0)
    }

    func testLuo2018TableTwoModelValuesWithExplicitNaturalLogAndSecondsFixture() throws {
        let profile = RetentionResearchProfile.luo2018

        XCTAssertEqual(try XCTUnwrap(profile.msbRBER.rber(pe: 10_000, retentionSeconds: 420)), 0.0000280380, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(profile.msbRBER.rber(pe: 10_000, retentionSeconds: 86_400)), 0.0000880781, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(profile.msbRBER.rber(pe: 10_000, retentionSeconds: 2_073_600)), 0.0001743714, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(profile.lsbRBER.rber(pe: 10_000, retentionSeconds: 420)), 0.0000303247, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(profile.lsbRBER.rber(pe: 10_000, retentionSeconds: 86_400)), 0.0001751149, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(profile.lsbRBER.rber(pe: 10_000, retentionSeconds: 2_073_600)), 0.0004985270, accuracy: 1e-9)
    }

    func testDefaultRetentionScenarioRecordsLongTimeAndPEExtrapolation() throws {
        let allowance = try XCTUnwrap(evaluate(temperature: 30, days: 365))

        XCTAssertEqual(allowance.targetTemperatureCelsius, 30)
        XCTAssertEqual(allowance.targetRetentionDays, 365)
        XCTAssertEqual(allowance.referenceRBERThreshold, 3e-3)
        XCTAssertEqual(allowance.activationEnergyEV, 1.1)
        XCTAssertGreaterThan(allowance.equivalentRetentionDaysAtReferenceTemperature, 1_500)
        XCTAssertGreaterThan(allowance.retentionTimeExtrapolationRatio, 60)
        XCTAssertGreaterThan(allowance.allowableTLCPE, 10_000)
        XCTAssertEqual(allowance.peExtrapolationRatio, allowance.allowableTLCPE / 10_000, accuracy: 1e-12)
        XCTAssertEqual(allowance.limitingBitClass, "LSB")
        XCTAssertLessThan(allowance.allowableLSBPE, allowance.allowableMSBPE)
        XCTAssertEqual(allowance.allowableTLCPE, allowance.allowableLSBPE)
        XCTAssertTrue(allowance.assumptions.contains { $0.contains("自然対数・秒") })
        XCTAssertTrue(allowance.assumptions.contains { $0.contains("ECC能力") })
        XCTAssertTrue(allowance.assumptions.contains { $0.contains("pSLC") })

        let modeledRBER = try XCTUnwrap(RetentionResearchProfile.luo2018.lsbRBER.rber(
            pe: allowance.allowableTLCPE,
            retentionSeconds: allowance.equivalentRetentionSecondsAtReferenceTemperature
        ))
        XCTAssertEqual(modeledRBER, 3e-3, accuracy: 1e-10)
    }

    func testRetentionRequirementIsSeparateFromObservedUnpoweredDiagnostic() throws {
        let smartHistory = [
            makeSMART(at: now.addingTimeInterval(-3 * 86_400), hostBytes: 1e12, powerOnHours: 100),
            makeSMART(at: now.addingTimeInterval(-86_400), hostBytes: 2e12, powerOnHours: 102),
            makeSMART(at: now, hostBytes: 3e12, powerOnHours: 102)
        ]
        let observation = RetentionModelEvaluator.observedRetentionDays(
            smartHistory: smartHistory, deviceID: "drive-1", now: now
        )

        // Two days elapsed minus two powered hours is 46 hours. The final
        // one-day interval is shorter, so the longest measured candidate wins.
        XCTAssertEqual(observation.candidateCount, 2)
        XCTAssertEqual(try XCTUnwrap(observation.days), 46.0 / 24.0, accuracy: 1e-12)
        XCTAssertTrue(observation.source.contains("Power On Hours"))

        let ftl = makeFTLHistory()
        let wearHistory = ControllerWearHistoryAnalyzer().summarize(snapshots: ftl, deviceID: "drive-1")
        let estimate = try XCTUnwrap(availableEstimate(
            settings: UsageSettings(retentionDays: 365), ftl: ftl, history: wearHistory,
            smartHistory: smartHistory
        ))
        XCTAssertEqual(estimate.allowance.targetRetentionDays, 365, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(estimate.observedLongestUnpoweredDays), 46.0 / 24.0, accuracy: 1e-12)
        XCTAssertTrue(estimate.retentionDaysSource.contains("必要保持条件"))
        XCTAssertFalse(estimate.retentionDaysSource.contains("Power On Hours"))
        XCTAssertTrue(estimate.notes.contains { $0.contains("代用にはしていません") })

        let excluded = RetentionModelEvaluator.observedRetentionDays(
            smartHistory: smartHistory, deviceID: "drive-1", now: now,
            excluding: [DateInterval(start: now.addingTimeInterval(-3 * 86_400),
                                     end: now.addingTimeInterval(-86_400 - 1))]
        )
        XCTAssertEqual(excluded.candidateCount, 1)
        XCTAssertEqual(try XCTUnwrap(excluded.days), 1, accuracy: 1e-12)
    }

    func testRetentionWeightsSeparateObservedDaysFromTemperatureResidual() throws {
        let smartHistory = [
            makeSMART(at: now.addingTimeInterval(-3 * 86_400), hostBytes: 1e12, powerOnHours: 100),
            makeSMART(at: now, hostBytes: 3e12, powerOnHours: 100)
        ]
        let ftl = makeFTLHistory()
        let wearHistory = ControllerWearHistoryAnalyzer().summarize(snapshots: ftl, deviceID: "drive-1")
        var settings = UsageSettings(
            retentionDays: 730,
            retentionStorageTemperatureCelsius: 30,
            retentionDaysWeight: 0.5,
            retentionEnvironmentWeight: 0.2
        )
        let observedDays = try XCTUnwrap(availableEstimate(
            settings: settings, ftl: ftl, history: wearHistory, smartHistory: smartHistory
        ))

        // The configured required condition is 730 days. The observed three
        // day power-off interval is diagnostic only and must not replace it.
        XCTAssertEqual(observedDays.allowance.targetRetentionDays, 730, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(observedDays.observedLongestUnpoweredDays), 3, accuracy: 1e-12)
        settings.retentionDaysWeight = 0
        let durationDisabled = try XCTUnwrap(availableEstimate(
            settings: settings, ftl: ftl, history: wearHistory, smartHistory: smartHistory
        ))
        XCTAssertLessThan(observedDays.effectiveTLCPE!, durationDisabled.effectiveTLCPE!)

        // At the 30°C reference temperature the residual environment ratio is
        // exactly one, so changing its weight must not change the result.
        settings.retentionDaysWeight = 0.5
        settings.retentionEnvironmentWeight = 0
        let environmentDisabledAtReference = try XCTUnwrap(availableEstimate(
            settings: settings, ftl: ftl, history: wearHistory, smartHistory: smartHistory
        ))
        XCTAssertEqual(observedDays.effectiveTLCPE!, environmentDisabledAtReference.effectiveTLCPE!, accuracy: 1e-9)

        // Away from the reference temperature the residual is active, but it
        // remains separately controlled by the lower environment weight.
        settings.retentionStorageTemperatureCelsius = 45
        settings.retentionEnvironmentWeight = 0.2
        let weightedEnvironment = try XCTUnwrap(availableEstimate(
            settings: settings, ftl: ftl, history: wearHistory, smartHistory: smartHistory
        ))
        settings.retentionEnvironmentWeight = 0
        let unweightedEnvironment = try XCTUnwrap(availableEstimate(
            settings: settings, ftl: ftl, history: wearHistory, smartHistory: smartHistory
        ))
        XCTAssertLessThan(weightedEnvironment.effectiveTLCPE!, unweightedEnvironment.effectiveTLCPE!)
        XCTAssertEqual(weightedEnvironment.retentionDaysWeight, 0.5, accuracy: 1e-12)
        XCTAssertEqual(weightedEnvironment.retentionEnvironmentWeight, 0.2, accuracy: 1e-12)

        var legacySettings = UsageSettings(retentionStorageTemperatureCelsius: 30,
                                           retentionResearchWeight: 0.2)
        let migrated = try XCTUnwrap(availableEstimate(
            settings: legacySettings, ftl: ftl, history: wearHistory, smartHistory: smartHistory
        ))
        XCTAssertEqual(migrated.retentionDaysWeight, 0.5, accuracy: 1e-12)
        XCTAssertTrue(migrated.notes.contains { $0.contains("互換移行") })
        legacySettings.retentionResearchWeight = 0.35
        let explicitLegacy = try XCTUnwrap(availableEstimate(
            settings: legacySettings, ftl: ftl, history: wearHistory, smartHistory: smartHistory
        ))
        XCTAssertEqual(explicitLegacy.retentionDaysWeight, 0.35, accuracy: 1e-12)
    }

    func testMoreSevereTemperatureAndLongerStorageReduceAllowablePE() throws {
        let cool = try XCTUnwrap(evaluate(temperature: 20, days: 365))
        let nominal = try XCTUnwrap(evaluate(temperature: 30, days: 365))
        let hot = try XCTUnwrap(evaluate(temperature: 45, days: 365))
        let longer = try XCTUnwrap(evaluate(temperature: 30, days: 730))

        XCTAssertGreaterThan(cool.allowableTLCPE, nominal.allowableTLCPE)
        XCTAssertGreaterThan(nominal.allowableTLCPE, hot.allowableTLCPE)
        XCTAssertGreaterThan(nominal.allowableTLCPE, longer.allowableTLCPE)
        XCTAssertNotEqual(cool.equivalentRetentionSecondsAtReferenceTemperature,
                          hot.equivalentRetentionSecondsAtReferenceTemperature)
    }

    func testRetentionEvaluatorRejectsInvalidAndNoNonnegativeSolutionCases() {
        guard case let .unavailable(invalid) = evaluator.evaluate(
            profile: .luo2018,
            targetTemperatureCelsius: .infinity,
            targetRetentionDays: 365
        ) else { return XCTFail("non-finite temperature must be rejected") }
        XCTAssertTrue(invalid.contains("範囲外"))

        guard case let .unavailable(noSolution) = evaluator.evaluate(
            profile: .luo2018,
            targetTemperatureCelsius: 30,
            targetRetentionDays: 365,
            rberThreshold: 1e-12
        ) else { return XCTFail("negative P/E solution must not be clamped to zero") }
        XCTAssertTrue(noSolution.contains("非負P/E解"))
    }

    func testDailyWearHistoryDrivesIndependentAverageAndMaximumEstimates() throws {
        let samples = makeFTLHistory()
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: samples, deviceID: "drive-1")
        let smart = makeSMART(at: now, hostBytes: 4_915_200_000_000)
        let result = estimate(smart: smart, ftl: samples.last, history: summary)

        guard case let .available(value) = result else { return XCTFail("daily history should yield both bases") }
        XCTAssertEqual(value.primaryPEBasis, .maximum)
        XCTAssertEqual(value.primary.inputSource, .dailyHistory)
        XCTAssertEqual(value.primary.intervalCounts[.tlc], 2)
        XCTAssertEqual(value.primary.intervalCounts[.pSLC], 2)
        XCTAssertNotNil(value.averagePEEstimate)
        XCTAssertNotNil(value.maximumPEEstimate)
        XCTAssertEqual(value.smartSnapshotID, smart.id)
        XCTAssertEqual(value.ftlSnapshotID, samples.last?.id)
        XCTAssertEqual(value.smartCapturedAt, smart.capturedAt)
        XCTAssertEqual(value.ftlCapturedAt, samples.last?.capturedAt)
        XCTAssertEqual(value.allowablePSLCPe!, value.pslcControllerEOLPE!, accuracy: 1e-8)
        XCTAssertTrue(value.primary.domains.allSatisfy { $0.allowablePE.isFinite && $0.allowablePE >= 0 })
        XCTAssertTrue(value.notes.contains { $0.contains("校正anchor") })
        XCTAssertEqual(try XCTUnwrap(value.domainPERelationship.pslcToTLCAveragePEProgressRatio), 2, accuracy: 1e-8)
        XCTAssertEqual(value.domainPERelationship.averageProgressIntervalCount, 2)
        XCTAssertEqual(value.domainPERelationship.pslcAverageCurrentPE, 84)
        XCTAssertEqual(value.maximumPEEstimate?.domains.first(where: { $0.domain == .pSLC })?.currentPE, 88)
        XCTAssertTrue(value.notes.contains { $0.contains("暫定") })
        XCTAssertTrue(value.primary.totalHostBytes.isFinite && value.primary.totalHostBytes > 0)
        XCTAssertTrue(value.primary.remainingHostBytes.isFinite && value.primary.remainingHostBytes > 0)
        XCTAssertNotNil(value.primary.currentRateProjection.date)
        XCTAssertNotNil(value.primary.historicalRateProjection.date)
    }

    func testInsufficientHistoryShowsProvisionalLifetimeEstimateAndReportsPartialDomain() throws {
        let samples = makeFTLHistory()
        let oneSnapshot = samples.last!
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: [oneSnapshot], deviceID: "drive-1")
        let smart = makeSMART(at: now, hostBytes: 4_915_200_000_000)

        guard case let .available(provisional) = estimate(smart: smart, ftl: oneSnapshot, history: summary) else {
            return XCTFail("a SMART lifetime write counter should support a clearly provisional estimate")
        }
        XCTAssertEqual(provisional.primary.inputSource, .lifetimeAverage)
        XCTAssertTrue(provisional.primary.inputSource.isProvisional)
        XCTAssertGreaterThan(provisional.primary.totalHostBytes, 0)
        XCTAssertGreaterThan(provisional.primary.remainingHostBytes, 0)
        XCTAssertEqual(provisional.primary.intervalCounts[.tlc], 0)
        XCTAssertEqual(provisional.primary.intervalCounts[.pSLC], 0)
        XCTAssertTrue(provisional.primary.notes.contains { $0.contains("按分") })

        let oneInterval = Array(samples.suffix(2))
        let oneIntervalSummary = ControllerWearHistoryAnalyzer().summarize(
            snapshots: oneInterval, deviceID: "drive-1"
        )
        guard case let .available(limited) = estimate(
            smart: smart, ftl: oneInterval.last, history: oneIntervalSummary,
            provisionalHistory: oneIntervalSummary
        ) else {
            return XCTFail("one valid same-series interval should remain provisionally displayable")
        }
        XCTAssertEqual(limited.primary.inputSource, .limitedDailyHistory)
        XCTAssertEqual(limited.primary.intervalCounts[.tlc], 1)
        XCTAssertEqual(limited.primary.intervalCounts[.pSLC], 1)
        XCTAssertTrue(limited.primary.notes.contains { $0.contains("暫定表示") })

        let missingPSLC = makeFTL(at: now, hostRaw: 1_200_000_000,
            tlcAverage: 5, tlcMaximum: 7, slcAverage: nil, slcMaximum: nil)
        let partialSeries = [
            makeFTL(at: now.addingTimeInterval(-2 * 86_400), hostRaw: 400_000_000,
                tlcAverage: 3, tlcMaximum: 5, slcAverage: nil, slcMaximum: nil),
            makeFTL(at: now.addingTimeInterval(-86_400), hostRaw: 800_000_000,
                tlcAverage: 4, tlcMaximum: 6, slcAverage: nil, slcMaximum: nil),
            missingPSLC
        ]
        let partialHistory = ControllerWearHistoryAnalyzer().summarize(snapshots: partialSeries, deviceID: "drive-1")
        guard case let .available(partial) = estimate(smart: smart, ftl: missingPSLC, history: partialHistory) else {
            return XCTFail("a TLC domain with sufficient observed deltas remains a partial estimate")
        }
        XCTAssertEqual(partial.primary.inputSource, .dailyHistory)
        XCTAssertEqual(partial.primary.domains.map(\.domain), [.tlc])
        XCTAssertTrue(partial.notes.contains { $0.contains("片側domain") })
    }

    func testRetentionEstimateRejectsCrossDeviceButCanShowCapacityModelWithoutLifetimeHostCounter() throws {
        let ftl = makeFTL(at: now, hostRaw: 1_200_000_000)
        let summary = ControllerWearHistoryAnalyzer().summarize(snapshots: [ftl], deviceID: "drive-1")
        let wrongDevice = makeSMART(at: now, hostBytes: 4e12, deviceID: "another-drive")
        XCTAssertEqual(estimate(smart: wrongDevice, ftl: ftl, history: summary),
                       .unavailable("同一device・連続系列の最新SMART／Direct FTLが必要です"))

        let noLifetimeWrites = makeSMART(at: now, hostBytes: nil)
        guard case let .available(value) = estimate(smart: noLifetimeWrites, ftl: ftl, history: summary) else {
            return XCTFail("capacity model should remain provisionally displayable without lifetime SMART writes")
        }
        XCTAssertNotNil(value.physicalModel)
        XCTAssertEqual(value.primary.inputSource, .capacityOnly)
        XCTAssertTrue(value.notes.contains { $0.contains("Host/P/E損耗傾き") })
    }

    func testSettingsWithNoNewRetentionKeysRemainCompatible() throws {
        let encoded = try JSONEncoder().encode(UsageSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        ["retentionResearchProfileID", "retentionDays", "retentionStorageTemperatureCelsius",
         "retentionRBERThreshold", "retentionActivationEnergyEV"].forEach { object.removeValue(forKey: $0) }
        let decoded = try JSONDecoder().decode(UsageSettings.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.retentionResearchProfileID)
        XCTAssertNil(decoded.retentionDays)
        XCTAssertNil(decoded.retentionStorageTemperatureCelsius)
        XCTAssertNil(decoded.retentionRBERThreshold)
        XCTAssertNil(decoded.retentionActivationEnergyEV)
        XCTAssertNil(decoded.retentionDaysWeight)
        XCTAssertNil(decoded.retentionEnvironmentWeight)

        let current = UsageSettings(retentionDaysWeight: 0.5, retentionEnvironmentWeight: 0.2)
        let roundTrip = try JSONDecoder().decode(UsageSettings.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip.retentionDaysWeight, 0.5)
        XCTAssertEqual(roundTrip.retentionEnvironmentWeight, 0.2)
    }

    func testControllerInternalTelemetryUsesOnlyExplicitSameSeriesDeltasAndLeavesRawUnitsUnconverted() throws {
        let start = makeTelemetryFTL(at: now.addingTimeInterval(-4 * 86_400), hostAutoWrites: 100,
            grownBadBlocks: 2, factoryBadBlocks: 10, dieFailures: 0, spare: 100,
            oslcTransitions: 40, oslcBasePE: 5, tlcAverage: 5, tlcMaximum: 7,
            slcAverage: 84, slcMaximum: 88)
        let end = makeTelemetryFTL(at: now, hostAutoWrites: 500,
            grownBadBlocks: 3, factoryBadBlocks: 10, dieFailures: 1, spare: 99.5,
            oslcTransitions: 45, oslcBasePE: 6, tlcAverage: 7, tlcMaximum: 10,
            slcAverage: 88, slcMaximum: 93)

        let value = ControllerInternalTelemetryAnalyzer().summarize(
            snapshots: [start, end], deviceID: "drive-1"
        )

        XCTAssertEqual(value.hostAutoWritesRawDelta, 400)
        XCTAssertEqual(try XCTUnwrap(value.hostAutoWritesRawPerDay), 100, accuracy: 1e-9)
        XCTAssertEqual(value.hostWritesUnitState, .provisional4KiB)
        XCTAssertEqual(value.grownBadBlocksDelta, 1)
        XCTAssertEqual(value.factoryBadBlocksDelta, 0)
        XCTAssertEqual(value.dieFailuresDelta, 1)
        XCTAssertEqual(try XCTUnwrap(value.spareAvailablePercentChange), -0.5, accuracy: 1e-9)
        XCTAssertEqual(value.oslcTransitionsDelta, 5)
        XCTAssertEqual(value.oslcBaseAveragePEStart, 5)
        XCTAssertEqual(value.oslcBaseAveragePEEnd, 6)
        XCTAssertEqual(value.tlcWearSpread?.absoluteSpreadStart, 2)
        XCTAssertEqual(value.tlcWearSpread?.absoluteSpreadEnd, 3)
        XCTAssertEqual(value.pslcWearSpread?.absoluteSpreadChange, 1)
        XCTAssertTrue(value.notes.contains { $0.contains("GB換算") })

        let excluded = ControllerInternalTelemetryAnalyzer().summarize(
            snapshots: [start, end], deviceID: "drive-1",
            excluding: [DateInterval(start: start.capturedAt, end: end.capturedAt)]
        )
        XCTAssertNil(excluded.hostAutoWritesRawDelta)
        XCTAssertNil(excluded.endCapturedAt)
    }

    private func evaluate(temperature: Double, days: Double) -> RetentionModelAllowance? {
        guard case let .available(allowance) = evaluator.evaluate(
            profile: .luo2018,
            targetTemperatureCelsius: temperature,
            targetRetentionDays: days
        ) else { return nil }
        return allowance
    }

    private func estimate(
        smart: DriveSnapshot,
        ftl: ASPToolDiagnosticsSnapshot?,
        history: ControllerWearHistorySummary,
        settings: UsageSettings = UsageSettings(),
        provisionalHistory: ControllerWearHistorySummary? = nil,
        ftlHistory: [ASPToolDiagnosticsSnapshot] = [],
        smartHistory: [DriveSnapshot] = [],
        hardwareProfile: AppleNANDHardwareProfile? = nil
    ) -> RetentionResearchEstimateResult {
        RetentionResearchEstimator().estimate(
            latestSMART: smart,
            latestDirectFTL: ftl,
            wearHistory: history,
            settings: settings,
            currentDailyWriteRate: 1_000_000_000_000,
            historicalDailyWriteRate: 800_000_000_000,
            now: now,
            smartHistory: smartHistory,
            ftlHistory: ftlHistory,
            provisionalHistory: provisionalHistory,
            hardwareProfile: hardwareProfile
        )
    }

    private func availableEstimate(
        settings: UsageSettings,
        ftl: [ASPToolDiagnosticsSnapshot],
        history: ControllerWearHistorySummary,
        smartHistory: [DriveSnapshot] = []
    ) -> RetentionResearchEstimate? {
        let latestSMART = smartHistory.last ?? makeSMART(at: now, hostBytes: 4_915_200_000_000)
        guard case let .available(value) = estimate(
            smart: latestSMART,
            ftl: ftl.last,
            history: history,
            settings: settings,
            ftlHistory: ftl,
            smartHistory: smartHistory
        ) else { return nil }
        return value
    }

    private func makeFTLHistory() -> [ASPToolDiagnosticsSnapshot] {
        [0, 1, 2].enumerated().map { index, day in
            makeFTL(
                at: now.addingTimeInterval(Double(day - 2) * 86_400),
                hostRaw: UInt64(index + 1) * 600_000_000,
                tlcAverage: Double(index + 3),
                tlcMaximum: Double(index + 5),
                slcAverage: Double(80 + index * 2),
                slcMaximum: Double(84 + index * 2)
            )
        }
    }

    private func makeFTL(
        at date: Date,
        hostRaw: UInt64,
        tlcAverage: Double? = 5,
        tlcMaximum: Double? = 7,
        slcAverage: Double? = 84,
        slcMaximum: Double? = 88
    ) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: date,
            captureQuality: .explicit,
            deviceID: "drive-1",
            sourceArtifact: .directFTL,
            sourceBuild: "25G83",
            extractionVersion: 2,
            hostWrites: hostRaw,
            nandWrites: UInt64(Double(hostRaw) * 1.7),
            hostWritesUnitState: .provisional4KiB,
            nandWritesUnitState: .provisional4KiB,
            tlcAveragePE: tlcAverage,
            tlcMaximumPE: tlcMaximum,
            tlcEOLPE: 3_000,
            slcAveragePE: slcAverage,
            slcMaximumPE: slcMaximum,
            slcEOLPE: 100_000,
            firmware: "FW1",
            mspVersion: "MSP1"
        )
    }

    private func makeTelemetryFTL(
        at date: Date,
        hostAutoWrites: UInt64,
        grownBadBlocks: UInt64,
        factoryBadBlocks: UInt64,
        dieFailures: UInt64,
        spare: Double,
        oslcTransitions: UInt64,
        oslcBasePE: Double,
        tlcAverage: Double,
        tlcMaximum: Double,
        slcAverage: Double,
        slcMaximum: Double
    ) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: date,
            captureQuality: .explicit,
            deviceID: "drive-1",
            sourceArtifact: .directFTL,
            sourceBuild: "25G83",
            extractionVersion: 2,
            hostWrites: 1_200_000_000,
            nandWrites: 2_000_000_000,
            tlcAveragePE: tlcAverage,
            tlcMaximumPE: tlcMaximum,
            tlcEOLPE: 3_000,
            slcAveragePE: slcAverage,
            slcMaximumPE: slcMaximum,
            slcEOLPE: 100_000,
            firmware: "FW1",
            mspVersion: "MSP1",
            spareAvailablePercent: spare,
            numDieFailures: dieFailures,
            grownBadBlocks: grownBadBlocks,
            factoryBadBlocks: factoryBadBlocks,
            oslcTransitions: oslcTransitions,
            oslcBaseAveragePE: oslcBasePE,
            hostAutoWrites: hostAutoWrites,
            directKeyContractVersion: DirectFTLResearchContract.latest,
            researchTelemetry: FTLResearchTelemetrySnapshot()
        )
    }

    private func makeSMART(at date: Date, hostBytes: Double?, deviceID: String = "drive-1",
                           powerOnHours: UInt64 = 1_000) -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: date,
            deviceID: deviceID,
            devicePath: "/dev/rdisk0",
            logicalCapacityBytes: 256_000_000_000,
            model: "Test SSD",
            serialNumber: "serial",
            firmware: "FW1",
            smartctlVersion: "7.5",
            smartctlExitStatus: 0,
            temperatureCelsius: 40,
            powerOnHours: powerOnHours,
            powerCycleCount: 1,
            unsafeShutdowns: 0,
            percentageUsed: 1,
            availableSpare: 100,
            availableSpareThreshold: 10,
            criticalWarning: 0,
            mediaAndDataIntegrityErrors: 0,
            dataUnitsRead: 1,
            dataUnitsWritten: hostBytes.map { UInt64($0 / HistoryAnalyzer.bytesPerNVMeDataUnit) },
            smartPassed: true
        )
    }
}
