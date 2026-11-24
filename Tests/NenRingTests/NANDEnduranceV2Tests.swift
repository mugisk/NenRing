import XCTest
import SwiftUI
@testable import NenRing

final class NANDEnduranceV2Tests: XCTestCase {
    @MainActor
    func testOptInLocalHistoryReadOnlyAndRender() throws {
        guard let path = ProcessInfo.processInfo.environment["NENRING_LOCAL_HISTORY_DIR"] else {
            throw XCTSkip("Local private history is read only with an explicit opt-in path")
        }
        let directory = URL(fileURLWithPath: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func read<T: Decodable>(_ name: String, _: T.Type) throws -> [T] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return try data.split(separator: 0x0A).map { try decoder.decode(T.self, from: Data($0)) }
        }
        let history = try read("history.jsonl", DriveSnapshot.self)
        let ftl = try read("asptool-snapshots.jsonl", ASPToolDiagnosticsSnapshot.self)
        let temperatures = try read("temperature-history.jsonl", TemperatureSample.self)
        let sessions = try read("research-sessions.jsonl", ResearchSession.self)
        let settings = try decoder.decode([String: UsageSettings].self,
            from: Data(contentsOf: directory.appendingPathComponent("usage-settings.json")))
        let smart = try XCTUnwrap(history.max { $0.capturedAt < $1.capturedAt })
        let analyzer = HistoryAnalyzer()
        let excluded = sessions.filter { $0.deviceID == smart.deviceID }.compactMap(\.analysisExcludedInterval)
        let usage = settings[smart.deviceID] ?? UsageSettings()
        let historical = analyzer.writeBasedLifeProjection(from: history, deviceID: smart.deviceID,
            settings: usage, researchSessions: sessions)?.averageDailyWriteRateBytes
        let result = NANDEnduranceV2.build(smart: smart, snapshots: ftl, history: history,
            temperatures: temperatures, settings: usage,
            rates: analyzer.writeRateSummary(from: history, deviceID: smart.deviceID, excluding: excluded),
            // The copy is fixed, so its WAF windows end at its last sample
            // rather than at the time the test runs.
            historicalRate: historical, excluding: excluded, now: smart.capturedAt)
        let matchingFTL = ftl.filter { $0.deviceID == smart.deviceID }
        let matchingSMART = history.filter { $0.deviceID == smart.deviceID }
        let latestDirect = try XCTUnwrap(matchingFTL
            .filter { $0.sourceArtifact == .directFTL }
            .max { $0.capturedAt < $1.capturedAt })
        let continuityLane = WearContinuityLaneBuilder.build(
            snapshots: matchingFTL,
            smart: matchingSMART,
            latest: latestDirect
        )
        let extractedSnapshots = matchingFTL.filter { $0.sourceArtifact == .extractedASPTool }
        XCTAssertFalse(extractedSnapshots.isEmpty, "実履歴には9/2のextractedASPTool入力がある")
        XCTAssertTrue(continuityLane.snapshots.allSatisfy { $0.sourceArtifact == .directFTL },
                      "予測のレーンはDirect FTLだけ。asptoolのテキストは照合専用")
        let firstDirect = matchingFTL.filter { $0.sourceArtifact == .directFTL }.min { $0.capturedAt < $1.capturedAt }
        XCTAssertEqual(continuityLane.snapshots.first?.id, firstDirect?.id)
        // History keeps growing (FW 591, OS-only 26A434, ...),
        // so check properties instead of a fixed count.
        XCTAssertGreaterThanOrEqual(continuityLane.boundaries.count, 1, "更新の境界がある")
        XCTAssertTrue(continuityLane.boundaries.allSatisfy { $0.continuity.isVerified }, "実履歴の境界はすべて検証済み")
        XCTAssertTrue(continuityLane.boundaries.filter {
            $0.boundary.beforeIdentity.firmwareEpoch == $0.boundary.afterIdentity.firmwareEpoch
        }.allSatisfy { !$0.boundary.hasPhysicalTransient }, "firmwareが同じOSだけの境界は更新直後の変化として扱わない")
        XCTAssertEqual(continuityLane.collapsedSameSecondSnapshots, 1,
                       "9/13の単調な同秒重複は解析レーンだけで統合しraw履歴を保持")
        XCTAssertEqual(continuityLane.rateLearningExclusions.count, 1, "率学習除外はOS/FW更新の1窓だけ")
        XCTAssertFalse(continuityLane.boundaries.contains {
            $0.boundary.beforeIdentity.sourceArtifact == .extractedASPTool
        }, "asptoolからDirectへの取得経路境界は作らない")
        XCTAssertTrue(continuityLane.boundaries.contains {
            $0.boundary.beforeIdentity.sourceArtifact == .directFTL &&
                $0.boundary.afterIdentity.sourceArtifact == .directFTL &&
                $0.boundary.hasPhysicalTransient && $0.continuity.isVerified
        })
        XCTAssertNotNil(result.nominalBudget, result.notes.joined(separator: "; "))
        XCTAssertNotNil(result.projections.first?.remaining)
        let sevenDayWAF = try XCTUnwrap(result.wafWindows.first { $0.days == 7 })
        let thirtyDayWAF = try XCTUnwrap(result.wafWindows.first { $0.days == 30 })
        XCTAssertNotNil(sevenDayWAF.value)
        XCTAssertNotNil(thirtyDayWAF.value)
        XCTAssertNotEqual(sevenDayWAF.value!, thirtyDayWAF.value!, accuracy: 0.0005,
                          "7日・30日窓が同じ短い系列へ潰れていないこと")
        XCTAssertEqual(result.reliabilityEvidence?.provisionalInterpretation, true,
                       "互換性を仮定したscalar比較を明示する")

        let integrated = DashboardAnalyticsSnapshot.build(
            analyzer: analyzer,
            history: history,
            temperatureHistory: temperatures,
            deviceID: smart.deviceID,
            period: .day,
            profile: nil,
            settings: usage,
            now: smart.capturedAt,
            asptoolSnapshots: ftl,
            researchSessions: sessions
        )
        XCTAssertEqual(integrated.controllerWearHistory.instrumentBoundaries.count, continuityLane.boundaries.count,
                       "Dashboardの損耗履歴も共有レーンの境界を使う")
        XCTAssertEqual(integrated.nandEndurance.instrumentBoundaries.count, continuityLane.boundaries.count,
                       "主予測が同じ計測器境界の判定を使う")
        XCTAssertEqual(integrated.nandEndurance.reliabilityEvidence?.provisionalInterpretation, true,
                       "信頼性比較も共有レーンを通り、暫定解釈を明示する")
        XCTAssertGreaterThan(integrated.controllerForecast.snapshotCount, 100,
                             "Controller EOLも検証済み共有レーン全体を入力に使う")
        // The central forecast prefers matched SMART Data Units Written
        // (512 KB units); Controller EOL uses the FTL Host counter (4 KiB).
        // Both describe the same lane endpoint, so they agree within 0.1%.
        let controllerHost = try XCTUnwrap(integrated.controllerForecast.currentHostWrittenBytes)
        let centralHost = try XCTUnwrap(integrated.nandEndurance.host)
        XCTAssertEqual(controllerHost, centralHost, accuracy: centralHost * 0.001,
                       "Controller EOLと主予測の現在Host値が共有レーン末尾でほぼ一致する")
        let integratedSevenDayWAF = try XCTUnwrap(integrated.nandEndurance.wafWindows.first { $0.days == 7 }?.value)
        let integratedThirtyDayWAF = try XCTUnwrap(integrated.nandEndurance.wafWindows.first { $0.days == 30 }?.value)
        XCTAssertNotEqual(integratedSevenDayWAF, integratedThirtyDayWAF, accuracy: 0.0005,
                          "Dashboard統合後も7日窓・30日窓を同じ系列へ潰さない")
        let integratedThirtyDayWindow = try XCTUnwrap(
            integrated.nandEndurance.wafWindows.first { $0.days == 30 }
        )
        XCTAssertGreaterThan(integratedThirtyDayWindow.observationDays, 14,
                             "Direct FTLの開始以降、同秒重複で窓を捨てず15日以上を反映する")
        XCTAssertEqual(integrated.controllerWearHistory.instrumentBoundaries.count, continuityLane.boundaries.count,
                       "同秒snapshot正規化で計測器境界数を変えない")
        let integratedFirstInterval = try XCTUnwrap(integrated.ftlTimeSeries.intervals.min { $0.startAt < $1.startAt })
        XCTAssertEqual(integratedFirstInterval.startAt, firstDirect?.capturedAt,
                       "時系列解析もDirect FTLの最初の取得からレーンを開始する")
        for row in result.projections {
            print("V2 local \(row.title): totalTB=\((row.total ?? -1) / 1e12) remainingTB=\((row.remaining ?? -1) / 1e12)")
        }
        print("V2 local Wlong=\(result.longWAF ?? -1) Wrecent=\(result.recentWAF ?? -1) Wforecast=\(result.forecastWAF ?? -1) q=\(result.recentWeight) currentGBday=\((result.currentPaceBytesPerDay ?? -1) / 1e9) longGBday=\((result.longTermPaceBytesPerDay ?? -1) / 1e9)")
        print("V2 local windows 7d=\(sevenDayWAF.value!) (\(sevenDayWAF.count) intervals, \(String(format: "%.2f", sevenDayWAF.observationDays)) observed days) 30d=\(thirtyDayWAF.value!) (\(thirtyDayWAF.count) intervals, \(String(format: "%.2f", thirtyDayWAF.observationDays)) observed days)")
        print("V2 local input=\(ValueFormatter.shortDateTime(result.inputDate)) latestRaw=\(ValueFormatter.shortDateTime(result.latestRawInputDate)) currentSource=\(result.currentValueSource) boundaries=\(result.instrumentBoundaries.count)")
        let firstLane = continuityLane.snapshots.first
        let laneSourceCounts = Dictionary(grouping: continuityLane.snapshots, by: \.sourceArtifact)
            .map { "\($0.key.rawValue):\($0.value.count)" }.sorted().joined(separator: ",")
        print("V2 local shared lane first=\(firstLane.map { ValueFormatter.shortDateTime($0.capturedAt) } ?? "none") source=\(firstLane?.sourceArtifact.rawValue ?? "none") count=\(continuityLane.snapshots.count) sources=[\(laneSourceCounts)] exclusions=\(continuityLane.rateLearningExclusions.count)")
        let laneBoundaries = continuityLane.boundaries.map { boundary in
            "\(boundary.boundary.beforeIdentity.sourceArtifact?.rawValue ?? "?")->\(boundary.boundary.afterIdentity.sourceArtifact?.rawValue ?? "?")@\(ValueFormatter.shortDateTime(boundary.boundary.after)) \(boundary.continuity.title)"
        }.joined(separator: " | ")
        print("V2 local shared lane boundaries \(laneBoundaries)")
        let coreTimeline = matchingFTL
            .filter { $0.sourceArtifact.participatesInCoreWearLane && $0.captureQuality != .unknown }
            .sorted { $0.capturedAt < $1.capturedAt }
        var previousInstrument: InstrumentIdentity?
        var previousHadTopology = false
        for sample in coreTimeline {
            let resolved = InstrumentIdentity.resolved(from: sample, smartHistory: matchingSMART)
            if resolved.identity != previousInstrument || (sample.directTopology != nil && !previousHadTopology) {
                print("V2 local instrument @\(ValueFormatter.shortDateTime(sample.capturedAt)) route=\(sample.sourceArtifact.rawValue) runtime=\(resolved.identity.runtimeBuild ?? "?") fw=\(resolved.identity.firmwareEpoch ?? "?") contract=\(resolved.identity.contractBuild ?? "?") topology=\(sample.directTopology != nil) provenance=\(resolved.provenance.rawValue)")
            }
            previousInstrument = resolved.identity
            previousHadTopology = sample.directTopology != nil
        }
        print("V2 local reliability=\(result.reliabilityEvidence?.state.rawValue ?? "unavailable") reason=\(result.reliabilityEvidence?.reason ?? "none")")
        print("V2 dashboard lane boundaries=\(integrated.nandEndurance.instrumentBoundaries.count) intervals=\(integrated.ftlTimeSeries.intervals.count) reliability=\(integrated.nandEndurance.reliabilityEvidence?.state.rawValue ?? "unavailable")")
        let boundarySummary = result.instrumentBoundaries.map { boundary in
            let checks = boundary.checks.map { "\($0.kind.rawValue):\($0.available ? ($0.passed ? "pass" : "fail") : "n/a")" }
                .joined(separator: ",")
            return "\(ValueFormatter.shortDateTime(boundary.boundary.after)) \(boundary.continuity.title) [\(checks)]"
        }.joined(separator: " | ")
        print("V2 local boundaries \(boundarySummary)")
        if let output = ProcessInfo.processInfo.environment["NENRING_RENDER_PATH"] {
            let renderer = ImageRenderer(content:
                NANDEnduranceDetailsView(result: result)
                    .padding(24).frame(width: 1080).background(Color.white)
                    .environment(\.colorScheme, .light))
            renderer.scale = 1
            let cg = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
        if let output = ProcessInfo.processInfo.environment["NENRING_WAF_RENDER_PATH"] {
            var previewAnalytics = DashboardAnalyticsSnapshot.empty
            previewAnalytics.nandEndurance = result
            let preferences = try XCTUnwrap(UserDefaults(suiteName: "NenRing-waf-preview-\(UUID().uuidString)"))
            let model = DashboardModel(preferences: preferences, initialAnalytics: previewAnalytics)
            let renderer = ImageRenderer(content: ReferenceWAFCard(model: model)
                .frame(width: 340)
                .padding(10)
                .background(Color.white)
                .environment(\.colorScheme, .light))
            renderer.scale = 2
            let cg = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ftl(_ date: Date, h: Double = 62e12, n: Double = 84.94e12,
                     tlc: Double? = 160, slc: Double? = 5297,
                     tlcMinimum: Double? = nil, tlcMaximum: Double? = nil,
                     slcMinimum: Double? = nil, slcMaximum: Double? = nil,
                     firmware: String = "FW1",
                     sourceBuild: String = DirectFTLResearchContract.reviewedBuild,
                     contractBuild: String? = nil,
                     powerOnHours: UInt64? = nil,
                     contractVersion: String? = DirectFTLResearchContract.latest,
                     topology: DirectFTLTopology? = nil,
                     telemetry: FTLResearchTelemetrySnapshot? = nil,
                     writeAmp: Double? = nil,
                     intermediateWriteAmp: Double? = nil) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(capturedAt: date, captureQuality: .explicit,
            deviceID: "drive-1", sourceArtifact: .directFTL, sourceBuild: sourceBuild,
            contractBuild: contractBuild, extractionVersion: 2,
            hostWrites: UInt64(h / 4096), nandWrites: UInt64(n / 4096),
            hostWritesUnitState: .provisional4KiB, nandWritesUnitState: .provisional4KiB,
            tlcAveragePE: tlc, tlcMinimumPE: tlcMinimum, tlcMaximumPE: tlcMaximum,
            tlcEOLPE: 3000, slcAveragePE: slc, slcMinimumPE: slcMinimum,
            slcMaximumPE: slcMaximum, slcEOLPE: 100000,
            powerOnHours: powerOnHours,
            firmware: firmware,
            writeAmp: writeAmp,
            intermediateWriteAmp: intermediateWriteAmp,
            directKeyContractVersion: contractVersion,
            directTopology: topology,
            researchTelemetry: telemetry)
    }

    private func directTopology(
        numVirtualBlocks: UInt64 = 722,
        intermediateStart: UInt64 = 1,
        userStart: UInt64 = 80,
        bytesPerPage: UInt64 = 16_384,
        nativePages: UInt64 = 24_576,
        slcPages: UInt64 = 8_192
    ) -> DirectFTLTopology? {
        DirectFTLTopology(
            contractVersion: DirectFTLResearchContract.latest,
            numVirtualBlocks: numVirtualBlocks,
            intermediatePartitionStart: intermediateStart,
            userPartitionStart: userStart,
            bytesPerPage: bytesPerPage,
            pagesPerVirtualBlock: nativePages,
            pagesPerVirtualBlockSLC: slcPages
        )
    }
    private func smart(_ date: Date, used: UInt64 = 5, firmware: String = "FW1",
                       hostBytes: Double = 62e12, powerOnHours: UInt64 = 1000) -> DriveSnapshot {
        let dataUnitsWritten = UInt64((hostBytes / HistoryAnalyzer.bytesPerNVMeDataUnit).rounded())
        return DriveSnapshot(capturedAt: date, deviceID: "drive-1", devicePath: "/dev/rdisk0",
            logicalCapacityBytes: 256_000_000_000, model: "Test", serialNumber: "serial", firmware: firmware,
            smartctlVersion: "7.5", smartctlExitStatus: 0, temperatureCelsius: 40,
            powerOnHours: powerOnHours, powerCycleCount: 1, unsafeShutdowns: 0, percentageUsed: used,
            availableSpare: 100, availableSpareThreshold: 10, criticalWarning: 0,
            mediaAndDataIntegrityErrors: 0, dataUnitsRead: 1,
            dataUnitsWritten: dataUnitsWritten, smartPassed: true)
    }

    private func estimate(_ snapshots: [ASPToolDiagnosticsSnapshot], settings: UsageSettings = UsageSettings(),
                          excluded: [DateInterval] = [], rate: Double = 100e9, used: UInt64 = 5,
                          hardwareProfile: AppleNANDHardwareProfile? = nil) -> NANDEnduranceV2 {
        var settings = settings
        if settings.retentionStorageTemperatureCelsius == nil { settings.retentionStorageTemperatureCelsius = 30 }
        return .build(smart: smart(now, used: used), snapshots: snapshots, history: [smart(now)],
            temperatures: [], settings: settings,
            rates: WriteRateSummary(sevenDayBytesPerDay: rate, thirtyDayBytesPerDay: rate,
                                    lifetimeBytesPerDay: rate), historicalRate: nil,
            excluding: excluded, now: now, hardwareProfile: hardwareProfile)
    }

    private func completeBandProfile() -> AppleNANDHardwareProfile {
        AppleNANDHardwareProfile(
            modelNumber: "Test",
            logicalCapacityBytes: 256_000_000_000,
            nandVendor: "Test",
            nandMarketingName: "Test NAND",
            defaultBitsPerCell: 3,
            controllerClass: "AppleANS3NVMeController",
            chipID: "S5E",
            firmwareVersion: "FW1",
            mspVersion: "MSP",
            pageSize: 16_384,
            pagesPerBlockNative: 1_536,
            pagesPerBlockSLC: 512,
            sectorsPerPage: 4,
            blocksPerCAU: 722,
            cauPerDie: 1,
            numBus: 8,
            diesPerBus: Array(repeating: 2, count: 8),
            busToMSP: Array(repeating: 0, count: 8),
            numDIP: 16,
            sectorsPerFullBand: 98_304,
            sectorsPerFullBandSLC: 32_768,
            packageBlocksAtEOL: 11_552
        )
    }
    func testRepresentativeBudgetAndClientRange() throws {
        let value = estimate([ftl(now)])
        let wear = (160.0 / 3000 + 5297.0 / 100000) / 2
        XCTAssertEqual(try XCTUnwrap(value.normalizedWear), wear, accuracy: 1e-12)
        // The parser stores the counter as whole 4 KiB units. Derive the
        // expected budget from the normalized value actually used by the
        // calculator so this test checks the v2.2 formula, not UInt64 rounding.
        let budget = try XCTUnwrap(value.nand) / wear
        XCTAssertEqual(try XCTUnwrap(value.nominalBudget), budget, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(value.capacityDiagnosticBudget), 256_000_000_000.0 * 3_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(value.currentPhysicalBytes), 256_000_000_000.0 * 160, accuracy: 1)
        XCTAssertFalse(try XCTUnwrap(value.capacityModelConsistent))
        let host = try XCTUnwrap(value.host)
        let currentPhysical = try XCTUnwrap(value.nand)
        XCTAssertEqual(try XCTUnwrap(value.clientLow), host + max(0, budget - currentPhysical) / 4, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(value.clientHigh), host + max(0, budget - currentPhysical) / 3, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(value.actualBudget), budget, accuracy: 1)
        let forecastWAF = try XCTUnwrap(value.forecastWAF)
        let expectedActualRemaining = max(0, budget - currentPhysical) / forecastWAF
        XCTAssertEqual(try XCTUnwrap(value.projections[0].remaining), expectedActualRemaining, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(value.projections[0].total), host + expectedActualRemaining, accuracy: 1)
        let differentCumulativeNAND = estimate([ftl(now, n: 200e12)])
        XCTAssertNotEqual(differentCumulativeNAND.nominalBudget, value.nominalBudget,
                          "v2.2の主予算は総NAND / 正規化損耗率なので累積NANDに追従する")
        XCTAssertEqual(differentCumulativeNAND.capacityDiagnosticBudget, value.capacityDiagnosticBudget,
                       "容量基準の検算値は累積NAND Writesから独立")
        XCTAssertEqual(value.projections.count, 3)
        XCTAssertEqual(value.projections[1].total,
                       value.projections[1].remaining.map { host + $0 })
        XCTAssertEqual(try XCTUnwrap(value.forecastWAF), 1.37, accuracy: 1e-8)
        XCTAssertEqual(value.recentWeight, 0)
    }

    func testUnvalidatedBuildIsExpectedStateAndDoesNotEnterNANDEndurancePrediction() throws {
        let value = estimate([ftl(now, sourceBuild: "26A999")])

        XCTAssertEqual(value.directContractStatus.title, "build未検証")
        XCTAssertFalse(value.directContractStatus.isValidated)
        XCTAssertEqual(value.directContractStatus.detail.contains("25G83"), true)
        XCTAssertNil(value.tlcPE)
        XCTAssertNil(value.pslcPE)
        XCTAssertNil(value.normalizedWear)
        XCTAssertNil(value.nominalBudget)
        XCTAssertFalse(value.domainModelAvailable)
        XCTAssertTrue(value.notes.contains { $0.contains("未検証") })
        XCTAssertNotNil(value.host, "raw counter is still visible, but not used as a semantic P/E input")
    }

    func testPrimaryForecastUsesTheLastAcceptedLaneValueWhenBoundaryFails() throws {
        let beforeDate = now.addingTimeInterval(-48 * 3_600)
        let afterDate = now.addingTimeInterval(-24 * 3_600)
        let before = ftl(beforeDate, h: 60e12, n: 84.94e12, firmware: "FW1", topology: directTopology())
        let after = ftl(afterDate, h: 62e12, n: 84.94e12, firmware: "FW2", topology: directTopology())
        let smartBefore = smart(beforeDate, firmware: "FW1", hostBytes: 60e12, powerOnHours: 1000)
        // Deliberately make the post-boundary SMART Host ratio disagree with
        // FTL.  D5 must fail, so the lane remains at the pre-boundary sample.
        let smartAfter = smart(afterDate, firmware: "FW2", hostBytes: 80e12, powerOnHours: 1001)

        let result = NANDEnduranceV2.build(
            smart: smartAfter,
            snapshots: [before, after],
            history: [smartBefore, smartAfter],
            temperatures: [],
            settings: UsageSettings(),
            rates: WriteRateSummary(sevenDayBytesPerDay: 100e9, thirtyDayBytesPerDay: 100e9, lifetimeBytesPerDay: 100e9),
            historicalRate: nil,
            excluding: [],
            now: now
        )

        XCTAssertEqual(result.instrumentBoundaries.last?.continuity.isFailed, true)
        XCTAssertEqual(result.inputDate, beforeDate)
        XCTAssertEqual(result.host, before.hostWrittenBytes.map { Double($0) })
        XCTAssertNotEqual(result.inputDate, afterDate)
        XCTAssertEqual(result.currentValueSource, "境界検証失敗・境界前の検証済みsnapshot")
        XCTAssertEqual(result.latestRawInputDate, afterDate)
        XCTAssertEqual(result.latestRawHost, after.hostWrittenBytes.map { Double($0) })
    }

    func testPendingBoundaryCannotPairNewerSMARTWithAcceptedFTLEndpoint() throws {
        let beforeDate = now.addingTimeInterval(-48 * 3_600)
        let afterDate = beforeDate.addingTimeInterval(6 * 3_600)
        let smartBeforeDate = beforeDate.addingTimeInterval(-20 * 3_600)
        let smartAfterDate = beforeDate.addingTimeInterval(3 * 3_600)
        let beforeHost = 60e12 + (20.0 / 23.0) * 2e12
        let topology = try XCTUnwrap(directTopology())
        let before = ftl(beforeDate, h: beforeHost, n: 84.94e12,
                         sourceBuild: "25G83", powerOnHours: 1004, topology: topology)
        // Keep a newer raw Direct FTL record to represent the pending side of
        // a build boundary; the supplied lane deliberately retains only the
        // accepted pre-boundary endpoint until continuity is resolved.
        let after = ftl(afterDate, h: 62e12, n: 85.94e12, firmware: "FW1",
                        sourceBuild: "26A999", contractBuild: "25G83",
                        powerOnHours: 1006, topology: topology)
        let smartBefore = smart(smartBeforeDate, firmware: "FW1", hostBytes: 60e12,
                                powerOnHours: 1000)
        let smartAfter = smart(smartAfterDate, firmware: "FW1", hostBytes: 62e12,
                               powerOnHours: 1005)
        let beforeIdentity = InstrumentIdentity.resolved(
            from: before,
            smartHistory: [smartBefore, smartAfter]
        ).identity
        let afterIdentity = InstrumentIdentity.resolved(
            from: after,
            smartHistory: [smartBefore, smartAfter]
        ).identity
        let boundary = InstrumentBoundary(
            before: beforeDate,
            after: afterDate,
            beforeIdentity: beforeIdentity,
            afterIdentity: afterIdentity,
            hasPhysicalTransient: true
        )
        let pendingRecord = InstrumentBoundaryRecord(
            boundary: boundary,
            continuity: .pending(boundary: boundary),
            checks: [],
            rateLearningExclusion: nil,
            note: "fixture: continuity evidence pending",
            oldBuildWasOverlayed: false
        )
        let lane = WearContinuityLane(
            snapshots: [before],
            boundaries: [pendingRecord],
            rateLearningExclusions: [],
            collapsedSameSecondSnapshots: 0
        )

        let result = NANDEnduranceV2.build(
            smart: smartAfter,
            snapshots: [before, after],
            history: [smartBefore, smartAfter],
            temperatures: [],
            settings: UsageSettings(),
            rates: WriteRateSummary(sevenDayBytesPerDay: 100e9, thirtyDayBytesPerDay: 100e9,
                                    lifetimeBytesPerDay: 100e9),
            historicalRate: nil,
            excluding: [],
            now: now,
            continuityLane: lane
        )

        XCTAssertTrue(result.instrumentBoundaries.last?.continuity.isPending == true)
        XCTAssertEqual(result.inputDate, beforeDate)
        XCTAssertEqual(try XCTUnwrap(result.host), try XCTUnwrap(smartBefore.dataUnitsWrittenBytes),
                       accuracy: 512_000)
        XCTAssertNotEqual(result.host, smartAfter.dataUnitsWrittenBytes)
        XCTAssertTrue(result.notes.contains { $0.contains("累積HostのSMART照合も検証済みFTL時刻以前") })
    }

    func testWearBalanceTrendUsesDailyPointsAndReportsObservedCrossingOnly() throws {
        let topology = try XCTUnwrap(directTopology())
        let start = now.addingTimeInterval(-2 * 86_400)
        let samples = [
            ftl(start, h: 50e12, n: 70e12, tlc: 150, slc: 4_500, topology: topology),
            ftl(start.addingTimeInterval(86_400), h: 51e12, n: 72e12, tlc: 160, slc: 6_000, topology: topology),
            ftl(now, h: 52e12, n: 74e12, tlc: 170, slc: 6_500, topology: topology)
        ]
        let value = estimate(samples)
        let trend = value.wearBalanceTrend

        XCTAssertEqual(value.directContractStatus.isValidated, true)
        XCTAssertEqual(trend.observations.count, 3)
        XCTAssertEqual(try XCTUnwrap(trend.firstRatio), 0.9, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(trend.latestRatio), 1.1470588235, accuracy: 1e-9)
        XCTAssertNotNil(trend.changePerDay)
        XCTAssertNotNil(trend.observedCrossingAt,
                        "crossing is reported only after retained samples cross 1.00")
        XCTAssertEqual(trend.note.contains("外挿せず"), true)
    }

    func testWearBalanceTrendExcludesResearchDaysAndDoesNotUseUnknownBuilds() throws {
        let topology = try XCTUnwrap(directTopology())
        let start = now.addingTimeInterval(-2 * 86_400)
        let samples = [
            ftl(start, h: 50e12, n: 70e12, tlc: 150, slc: 4_500, topology: topology),
            ftl(start.addingTimeInterval(86_400), h: 51e12, n: 72e12, tlc: 160, slc: 6_000, topology: topology),
            ftl(now, h: 52e12, n: 74e12, tlc: 170, slc: 6_500, sourceBuild: "26A999", topology: topology)
        ]
        let value = estimate(samples)

        XCTAssertEqual(value.directContractStatus.title, "build未検証")
        XCTAssertTrue(value.wearBalanceTrend.observations.isEmpty)

        let validated = [
            ftl(start, h: 50e12, n: 70e12, tlc: 150, slc: 4_500, topology: topology),
            ftl(start.addingTimeInterval(86_400), h: 51e12, n: 72e12, tlc: 160, slc: 6_000, topology: topology),
            ftl(now, h: 52e12, n: 74e12, tlc: 170, slc: 6_500, topology: topology)
        ]
        let excluded = DateInterval(start: start.addingTimeInterval(86_400), end: now)
        let trend = NANDEnduranceV2.makeWearBalanceTrend(series: validated, excluding: [excluded])
        XCTAssertEqual(trend.observations.count, 1)
        XCTAssertNil(trend.changePerDay)
        XCTAssertNil(trend.observedCrossingAt)
    }

    func testCurrentFixtureUsesAggregateNANDInsteadOfCapacityOnlyBudget() throws {
        let value = estimate([ftl(now, h: 62.16e12, n: 98.53e12)])
        let wear = try XCTUnwrap(value.normalizedWear)
        let nand = try XCTUnwrap(value.nand)
        let budget = try XCTUnwrap(value.nominalBudget)
        XCTAssertEqual(budget, nand / wear, accuracy: budget * 1e-12)
        XCTAssertEqual(try XCTUnwrap(value.capacityDiagnosticBudget), 768e12, accuracy: 1)
        XCTAssertFalse(try XCTUnwrap(value.capacityModelConsistent))
        let waf = try XCTUnwrap(value.forecastWAF)
        let expectedTotal = try XCTUnwrap(value.host) + max(0, budget - nand) / waf
        XCTAssertEqual(try XCTUnwrap(value.projections.first?.total), expectedTotal, accuracy: 1)
        XCTAssertLessThan(expectedTotal, 1.3e15,
                          "容量×TLC EOLの旧経路による1.7PB級の増幅を主表示へ戻さない")
    }
    func testFutureWAFNeverRepricesPastHost() throws {
        let a = NANDEnduranceV2.projection(title: "a", budget: 1000, host: 100, nand: 200, waf: 4, note: "")
        XCTAssertEqual(a.remaining, 200)
        XCTAssertEqual(a.total, 300)
        XCTAssertNotEqual(a.total, 1000 / 4)
        let b = NANDEnduranceV2.projection(title: "b", budget: 1000, host: 100, nand: 200, waf: 2, note: "")
        XCTAssertEqual(b.remaining, 400)
        XCTAssertEqual(b.total, 500)
        let reached = NANDEnduranceV2.projection(title: "c", budget: 100, host: 100, nand: 200, waf: 2, note: "")
        XCTAssertEqual(reached.remaining, 0)
        XCTAssertEqual(reached.total, 100)
    }
    func testTemperatureChangesActualButNotClient() throws {
        let baseline = estimate([ftl(now)])
        var settings = UsageSettings()
        settings.retentionStorageTemperatureCelsius = 45
        let warmer = estimate([ftl(now)], settings: settings)
        XCTAssertEqual(baseline.clientLow, warmer.clientLow)
        XCTAssertEqual(baseline.clientHigh, warmer.clientHigh)
        XCTAssertEqual(warmer.actualBudget, baseline.actualBudget,
                       "domain配分なしではTLC保持補正をaggregate NAND全体へ代用しない")
        XCTAssertFalse(baseline.retentionCorrectionSuppressed)
        XCTAssertEqual(baseline.projections[2], warmer.projections[2])
        settings.retentionResearchWeight = 0
        settings.retentionEnvironmentWeight = 0
        XCTAssertEqual(try XCTUnwrap(estimate([ftl(now)], settings: settings).actualBudget),
                       try XCTUnwrap(baseline.actualBudget), accuracy: 1)
    }
    func testPartialDomainAndZeroPEAndInvalidSettings() {
        let partial = estimate([ftl(now, slc: nil)])
        XCTAssertNotNil(partial.nominalBudget)
        XCTAssertTrue(partial.notes.contains { $0.contains("部分推計") })
        XCTAssertNil(estimate([ftl(now, tlc: 0, slc: 0)]).nominalBudget)
        var settings = UsageSettings()
        settings.retentionDays = -1
        let invalid = estimate([ftl(now)], settings: settings)
        XCTAssertNotNil(invalid.actualBudget)
        XCTAssertNotNil(invalid.clientHigh)
        XCTAssertEqual(estimate([ftl(now)], used: 0).projections.count, 3)
    }
    func testPeerReferenceUsesLabelledDefaultWithoutRegisteredHardwareProfile() {
        let peer = estimate([ftl(now)]).projections[2]
        XCTAssertEqual(peer.total, 153.6e12)
        XCTAssertEqual(peer.remaining, 91.6e12)
        XCTAssertTrue(peer.note.contains("NAND未特定"))
    }
    func testResetAndKnownEpochMismatchDoNotProduceCurrentBudget() {
        let reset = estimate([ftl(now.addingTimeInterval(-86400), h: 63e12), ftl(now)])
        XCTAssertNil(reset.nominalBudget)
        XCTAssertNil(reset.forecastWAF)
        let mismatch = estimate([ftl(now, firmware: "FW2")])
        XCTAssertNil(mismatch.nominalBudget)
        XCTAssertNil(mismatch.forecastWAF)
        // An older different epoch must not leak its reset into the latest series.
        let separate = estimate([ftl(now.addingTimeInterval(-86400), h: 63e12, firmware: "OLD"), ftl(now)])
        XCTAssertNotNil(separate.nominalBudget)
        XCTAssertEqual(separate.recentWeight, 0)
    }
    func testSameSecondCapturesAreNotReset() {
        let older = ftl(now.addingTimeInterval(-86400), h: 60e12, n: 80e12)
        let sameSecond = ftl(now.addingTimeInterval(-86400), h: 60e12 + 4096, n: 80e12 + 8192)
        let a = estimate([older, sameSecond, ftl(now)])
        let b = estimate([sameSecond, older, ftl(now)])
        XCTAssertNotNil(a.nominalBudget)
        XCTAssertEqual(a.nominalBudget, b.nominalBudget)
        XCTAssertEqual(a.forecastWAF, b.forecastWAF)
    }
    func testPollingSubdivisionDoesNotIncreaseWAFWeightAndTrialsExcluded() throws {
        let start = now.addingTimeInterval(-10 * 86400)
        func samples(step: Int) -> [ASPToolDiagnosticsSnapshot] {
            stride(from: 0, through: 240, by: step).map { hour in
                ftl(start.addingTimeInterval(Double(hour) * 3600),
                    h: 60e12 + Double(hour) * 10e9, n: 80e12 + Double(hour) * 20e9)
            }
        }
        let hourly = estimate(samples(step: 1))
        let sixHourly = estimate(samples(step: 6))
        XCTAssertEqual(hourly.recentWeight, sixHourly.recentWeight, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(hourly.forecastWAF), try XCTUnwrap(sixHourly.forecastWAF), accuracy: 1e-8)
        let excluded = estimate(samples(step: 1), excluded: [DateInterval(start: start, end: now)])
        XCTAssertEqual(excluded.recentWeight, 0)
        XCTAssertEqual(excluded.forecastWAF, excluded.longWAF)
        XCTAssertEqual(excluded.nand, hourly.nand) // Actual wear remains, even when learning excludes trials.
        XCTAssertEqual(estimate([ftl(now)], rate: 0).currentPaceBytesPerDay, 0)
    }
    func testDailyCadenceAllowsTimerAndWakeDelay() throws {
        let start = now.addingTimeInterval(-10 * 25 * 3600)
        let samples = (0...10).map { index in
            ftl(start.addingTimeInterval(Double(index) * 25 * 3600),
                h: 52e12 + Double(index) * 1e12,
                n: 70e12 + Double(index) * 2e12)
        }
        let value = estimate(samples)
        XCTAssertGreaterThan(value.recentWeight, 0,
                             "25時間間隔の通常系列がdailyStabilityで全除外されないこと")
        XCTAssertGreaterThan(try XCTUnwrap(value.recentWAF), 0)
    }

    func testVerifiedAcquisitionBoundaryWithoutTransientDoesNotExcludeTheWholeWAFInterval() throws {
        let start = now.addingTimeInterval(-10 * 86_400)
        let hostBefore = 60e12
        let nandBefore = 80e12
        let extracted = ASPToolDiagnosticsSnapshot(
            capturedAt: start,
            captureQuality: .fileMetadata,
            deviceID: "drive-1",
            sourceName: "asptool_snapshot.log",
            sourceArtifact: .extractedASPTool,
            sourceBuild: DirectFTLResearchContract.reviewedBuild,
            contractBuild: DirectFTLResearchContract.reviewedBuild,
            extractionVersion: 1,
            semanticContractVersion: DirectFTLResearchContract.latest,
            coreWearContractVersion: DirectFTLResearchContract.reviewed25G83CoreV1,
            hostWrites: UInt64(hostBefore / 4_096),
            nandWrites: UInt64(nandBefore / 4_096),
            hostWritesUnitState: .provisional4KiB,
            nandWritesUnitState: .provisional4KiB,
            tlcAveragePE: 160,
            tlcMaximumPE: 172,
            tlcEOLPE: 3_000,
            slcAveragePE: 5_297,
            slcMaximumPE: 5_310,
            slcEOLPE: 100_000,
            firmware: "FW1"
        )
        let direct = ftl(now, h: 62e12, n: 84.94e12)
        let beforeIdentity = InstrumentIdentity.resolved(from: extracted).identity
        let afterIdentity = InstrumentIdentity.resolved(from: direct).identity
        let boundary = InstrumentBoundary(
            before: start,
            after: now,
            beforeIdentity: beforeIdentity,
            afterIdentity: afterIdentity,
            hasPhysicalTransient: false
        )
        let record = InstrumentBoundaryRecord(
            boundary: boundary,
            continuity: .verified(boundary: boundary, checks: []),
            checks: [],
            rateLearningExclusion: nil,
            note: "Verified acquisition-route boundary with no rate exclusion",
            oldBuildWasOverlayed: false
        )
        let lane = WearContinuityLane(
            snapshots: [extracted, direct],
            boundaries: [record],
            rateLearningExclusions: [],
            collapsedSameSecondSnapshots: 0
        )
        var settings = UsageSettings()
        settings.retentionStorageTemperatureCelsius = 30

        let value = NANDEnduranceV2.build(
            smart: smart(now),
            snapshots: [extracted, direct],
            history: [smart(now)],
            temperatures: [],
            settings: settings,
            rates: WriteRateSummary(
                sevenDayBytesPerDay: 100e9,
                thirtyDayBytesPerDay: 100e9,
                lifetimeBytesPerDay: 100e9
            ),
            historicalRate: nil,
            excluding: [],
            now: now,
            continuityLane: lane
        )

        let thirtyDay = try XCTUnwrap(value.wafWindows.first { $0.days == 30 })
        XCTAssertEqual(thirtyDay.observationDays, 10, accuracy: 0.0001,
                       "取得経路境界のゼロ長placeholderはWAF除外へ変換しない")
    }

    func testWAFWindowsAreStoredWithTheForecastAssessment() throws {
        let start = now.addingTimeInterval(-31 * 86_400)
        let samples = [
            ftl(start, h: 50e12, n: 70e12),
            ftl(start.addingTimeInterval(4 * 86_400), h: 51e12, n: 71.5e12),
            ftl(start.addingTimeInterval(21 * 86_400), h: 54e12, n: 76e12),
            ftl(start.addingTimeInterval(25 * 86_400), h: 55e12, n: 77.1e12),
            ftl(start.addingTimeInterval(31 * 86_400), h: 60e12, n: 85.1e12)
        ]

        let value = estimate(samples)
        let seven = try XCTUnwrap(value.wafWindows.first { $0.days == 7 })
        let thirty = try XCTUnwrap(value.wafWindows.first { $0.days == 30 })

        XCTAssertEqual(seven.days, 7)
        XCTAssertEqual(thirty.days, 30)
        XCTAssertNotNil(seven.value)
        XCTAssertNotNil(thirty.value)
        XCTAssertNotEqual(seven.value, thirty.value,
                          "Window values must be retained from the shared assessment rather than recomputed by the view")
    }

    func testDailyStabilityWeightsVarianceByHostBytes() {
        let dayStart = floor(now.timeIntervalSince1970 / 86_400) * 86_400
        let first = Date(timeIntervalSince1970: dayStart - 2 * 86_400 + 3_600)
        let second = first.addingTimeInterval(86_400)
        let third = second.addingTimeInterval(86_400)
        let samples = [
            ftl(first, h: 50e12, n: 70e12),
            ftl(second, h: 51e12, n: 74e12),
            ftl(third, h: 351e12, n: 524e12)
        ]
        let stability = NANDEnduranceV2.dailyStability(series: samples, excluding: [], now: now, days: 30)
        XCTAssertGreaterThan(stability.factor, 0.9,
                             "大きなHost書込の安定区間が少量区間に投票で負けないこと")
        XCTAssertGreaterThan(stability.coveredDays, 1.5)
    }

    func testCapacityGateRejectsTLCOnlyConsumptionAgainstAggregateNAND() {
        XCTAssertTrue(NANDEnduranceV2.capacityModelIsConsistent(
            physicalConsumed: 95, nand: 100
        ))
        XCTAssertFalse(NANDEnduranceV2.capacityModelIsConsistent(
            physicalConsumed: 46.52, nand: 98.53
        ))
        XCTAssertFalse(NANDEnduranceV2.capacityModelIsConsistent(
            physicalConsumed: nil, nand: 100
        ))
    }

    func testDirectTopologyUses79PSLCAndKeeps80BandFitAsReconciliationOnly() throws {
        let profile = completeBandProfile()
        let topology = try XCTUnwrap(directTopology())
        let sectorBytes = Double(try XCTUnwrap(profile.geometrySectorSizeBytes))
        let tlcBandBytes = Double(try XCTUnwrap(profile.sectorsPerFullBand)) * sectorBytes
        let pslcBandBytes = Double(try XCTUnwrap(profile.sectorsPerFullBandSLC)) * sectorBytes
        let modeledNAND = 642.0 * tlcBandBytes * 160 + 80.0 * pslcBandBytes * 5_297
        let value = estimate([ftl(now, n: modeledNAND, topology: topology)], hardwareProfile: profile)
        let allocation = try XCTUnwrap(value.bandAllocationProxy)
        XCTAssertEqual(allocation.totalBands, 722)
        XCTAssertEqual(allocation.tlcBands, 642)
        XCTAssertEqual(allocation.pslcBands, 80)
        XCTAssertEqual(allocation.sectorSizeBytes, 4_096)
        XCTAssertEqual(allocation.tlcBandBytes, 384 * 1_024 * 1_024, accuracy: 0.5)
        XCTAssertEqual(allocation.pslcBandBytes, 128 * 1_024 * 1_024, accuracy: 0.5)
        XCTAssertEqual(allocation.rawPSLCBands, 80, accuracy: 1e-9)
        XCTAssertEqual(allocation.pslcPhysicalFootprintBytes,
                       80 * 384 * 1_024 * 1_024, accuracy: 0.5)
        XCTAssertLessThan(allocation.relativeError, 0.002)
        XCTAssertFalse(allocation.capacityAllocationVerified)
        XCTAssertFalse(value.capacityAllocationVerified)
        XCTAssertTrue(value.domainModelAvailable)
        XCTAssertEqual(value.directTopology?.intermediateBandCount, 79)
        XCTAssertEqual(value.directTopology?.tlcBandCount, 642)
        XCTAssertEqual(value.topologyMatchesIORegistryGeometry, true)
        XCTAssertEqual(value.domainEstimates.count, 2)
        let expectedDomainBudget = (642.0 * 384.0 * 1_024.0 * 1_024.0 * 3_000.0)
            + (79.0 * 128.0 * 1_024.0 * 1_024.0 * 100_000.0)
        let expectedDomainUsed = (642.0 * 384.0 * 1_024.0 * 1_024.0 * 160.0)
            + (79.0 * 128.0 * 1_024.0 * 1_024.0 * 5_297.0)
        XCTAssertEqual(try XCTUnwrap(value.domainBaselineBudget), expectedDomainBudget, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(value.domainUsedBytes), expectedDomainUsed, accuracy: 1)
        let diagnostics = try XCTUnwrap(value.reconstructionDiagnostics)
        XCTAssertEqual(try XCTUnwrap(diagnostics.rawEquivalentPSLCBands), 80, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(diagnostics.residualEquivalentPSLCBands), 1, accuracy: 1e-6)
        XCTAssertGreaterThan(diagnostics.signedResidualBytes, 0)
        XCTAssertTrue(value.notes.contains { $0.contains("未同定残差") })
    }

    func testDirectTopologyAtOrOverEOLKeepsObservedUseButClampsFutureRemainingToZero() throws {
        let profile = completeBandProfile()
        let topology = try XCTUnwrap(directTopology())
        let value = estimate([
            ftl(now, tlc: 3_001, slc: 100_001, topology: topology)
        ], hardwareProfile: profile)

        XCTAssertTrue(value.domainModelAvailable)
        XCTAssertEqual(try XCTUnwrap(value.domainEstimates.first { $0.domain == .tlc }).remainingBytes, 0, accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(value.domainEstimates.first { $0.domain == .pslc }).remainingBytes, 0, accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(value.domainRemainingBytes), 0, accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(value.projection(.real)).remaining), 0, accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(value.projection(.client)).remaining), 0, accuracy: 0)
    }
    func testObservedHostAmountAndPriorProduceHalfBlendWeight() {
        let prior = ftl(now.addingTimeInterval(-86400), h: 60e12, n: 80e12)
        let current = ftl(now, h: 61e12, n: 81e12)
        let value = estimate([prior, current])
        XCTAssertEqual(try XCTUnwrap(value.wafObservedHostBytes), 1e12, accuracy: 4_096)
        XCTAssertEqual(try XCTUnwrap(value.wafPriorEquivalentHostBytes), 1e12, accuracy: 0.5)
        XCTAssertEqual(value.recentWeight, 0.5, accuracy: 1e-12)
    }
    func testArrivalUsesRemainingLessSMARTHostWrittenSinceAStaleInput() throws {
        let input = now.addingTimeInterval(-10 * 86_400)
        let rates = WriteRateSummary(sevenDayBytesPerDay: 50e9, thirtyDayBytesPerDay: 50e9, lifetimeBytesPerDay: 50e9)
        var settings = UsageSettings()
        settings.retentionStorageTemperatureCelsius = 30
        func build(history: [DriveSnapshot]) -> NANDEnduranceV2 {
            .build(smart: history.last, snapshots: [ftl(input)], history: history, temperatures: [],
                   settings: settings, rates: rates, historicalRate: nil, excluding: [], now: now)
        }

        let value = build(history: [smart(input), smart(now, hostBytes: 62.5e12)])

        let real = try XCTUnwrap(value.projection(.real))
        let remaining = try XCTUnwrap(real.remaining)
        XCTAssertEqual(try XCTUnwrap(value.host), 62e12, accuracy: 1_000_000, "the projection itself stays at the input")
        XCTAssertEqual(try XCTUnwrap(value.hostWrittenSinceInput), 0.5e12, accuracy: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(value.remainingNow(remaining, workload: .real)), remaining - 0.5e12, accuracy: 1_000_000)
        XCTAssertEqual(value.remainingNow(0.1e12, workload: .real), 0, "never below zero")
        XCTAssertTrue(value.isInputStale(now: now), "no Direct FTL read for 10 days")
        XCTAssertFalse(value.isInputStale(now: input.addingTimeInterval(36 * 3_600)))
        var heldAtBoundary = value
        heldAtBoundary.latestRawInputDate = now.addingTimeInterval(-3_600)
        XCTAssertFalse(heldAtBoundary.isInputStale(now: now), "reads continue while the forecast waits at a boundary")

        // Without a SMART sample within a day of the input there is nothing
        // to measure the writes with, so the remaining amount is used as is.
        let unmatched = build(history: [smart(input.addingTimeInterval(-3 * 86_400), hostBytes: 61e12),
                                        smart(now, hostBytes: 62.5e12)])
        XCTAssertNil(unmatched.hostWrittenSinceInput)
        XCTAssertEqual(unmatched.remainingNow(remaining, workload: .real), remaining)
    }

    func testClientArrivalSubtractsConsumedNANDInClientHostUnits() throws {
        var value = NANDEnduranceV2.empty
        value.hostWrittenSinceInput = 10e12
        value.forecastWAF = 1.5
        let remaining = 100e12
        let actual = try XCTUnwrap(value.remainingNow(remaining, workload: .real))
        let client = try XCTUnwrap(value.remainingNow(remaining, workload: .client))
        XCTAssertEqual(actual, 90e12, accuracy: 1)
        XCTAssertEqual(client, remaining - 15e12 / 3.5, accuracy: 1)
        XCTAssertNotEqual(actual, client)
        XCTAssertEqual(value.remainingNow(remaining, workload: .peerReference), actual)
        XCTAssertEqual(value.remainingNow(1e12, workload: .client), 0)
        XCTAssertNil(value.remainingNow(.nan, workload: .client))
        for invalidWAF in [Optional<Double>.none, 0, -1, .infinity, .nan] {
            value.forecastWAF = invalidWAF
            XCTAssertEqual(value.remainingNow(remaining, workload: .client), remaining,
                           "without a conversion, keep the input-time Client estimate")
        }
    }

    func testMatchedSMARTProvidesCumulativeHostWhileWAFKeepsFTLPair() throws {
        let value = estimate([ftl(now, h: 60e12, n: 90e12)])
        XCTAssertEqual(value.cumulativeHostSource, .matchedSMART)
        XCTAssertEqual(try XCTUnwrap(value.ftlHost), 60e12, accuracy: 4_096)
        XCTAssertEqual(try XCTUnwrap(value.host), 62e12, accuracy: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(value.longWAF), 1.5, accuracy: 1e-8)
    }

    func testCumulativeHostFallsBackToFTLWhenSMARTAndFTLDiverge() throws {
        let value = estimate([ftl(now, h: 40e12, n: 60e12)])
        XCTAssertEqual(value.cumulativeHostSource, .ftlFallback)
        XCTAssertEqual(try XCTUnwrap(value.host), 40e12, accuracy: 4_096)
        XCTAssertEqual(try XCTUnwrap(value.longWAF), 1.5, accuracy: 1e-8)
    }

    func testCumulativeHostTenPercentToleranceUsesFTLAsReference() {
        let acceptedFTL = ftl(now, h: 100e9, n: 150e9)
        let smartSample = smart(now, hostBytes: 111e9)

        let resolution = CumulativeHostResolver.resolve(
            acceptedFTL: acceptedFTL,
            smartHistory: [smartSample]
        )

        XCTAssertEqual(resolution.source, .ftlFallback,
                       "111 GB is 11% above the 100 GB FTL reference and must exceed the tolerance")
        XCTAssertEqual(resolution.hostBytes, acceptedFTL.hostWrittenBytes.map { Double($0) })
    }

    func testRetentionChangesTLCOnlyInDomainBudget() throws {
        let profile = completeBandProfile()
        let topology = try XCTUnwrap(directTopology())
        let baseline = estimate([ftl(now, topology: topology)], hardwareProfile: profile)
        var settings = UsageSettings()
        settings.retentionStorageTemperatureCelsius = 55
        let warmer = estimate([ftl(now, topology: topology)], settings: settings, hardwareProfile: profile)
        let baseTLC = try XCTUnwrap(baseline.domainEstimates.first { $0.domain == .tlc })
        let warmTLC = try XCTUnwrap(warmer.domainEstimates.first { $0.domain == .tlc })
        let basePSLC = try XCTUnwrap(baseline.domainEstimates.first { $0.domain == .pslc })
        let warmPSLC = try XCTUnwrap(warmer.domainEstimates.first { $0.domain == .pslc })
        XCTAssertLessThan(warmTLC.targetPE, baseTLC.targetPE)
        XCTAssertEqual(warmPSLC.targetPE, basePSLC.targetPE, accuracy: 1e-9)
        XCTAssertLessThan(warmTLC.remainingBytes, baseTLC.remainingBytes)
        XCTAssertEqual(warmPSLC.remainingBytes, basePSLC.remainingBytes, accuracy: 1)
        XCTAssertEqual(
            try XCTUnwrap(baseline.baselineDomainRemainingBytes),
            try XCTUnwrap(baseline.retentionAdjustedDomainRemainingBytes),
            accuracy: 1
        )
        XCTAssertLessThan(
            try XCTUnwrap(warmer.retentionAdjustedDomainRemainingBytes),
            try XCTUnwrap(warmer.baselineDomainRemainingBytes)
        )
        XCTAssertLessThan(try XCTUnwrap(warmer.retentionDeltaRemainingBytes), 0)
    }
    func testForecastWAFPriorIsIndependentFromRetentionResearchPrior() throws {
        let profile = completeBandProfile()
        let topology = try XCTUnwrap(directTopology())
        let modeled = 642.0 * 384.0 * 1_024.0 * 1_024.0 * 160.0
            + 79.0 * 128.0 * 1_024.0 * 1_024.0 * 5_297.0
        let older = ftl(now.addingTimeInterval(-86400), h: 61e12, n: modeled - 2e12, topology: topology)
        let latest = ftl(now, h: 62e12, n: modeled, topology: topology)
        let baseline = estimate([older, latest], hardwareProfile: profile)

        var retentionOnly = UsageSettings()
        retentionOnly.retentionDailyWAFPriorHostBytes = 100e12
        let retentionChanged = estimate([older, latest], settings: retentionOnly, hardwareProfile: profile)
        XCTAssertEqual(baseline.forecastWAF, retentionChanged.forecastWAF)
        XCTAssertEqual(baseline.projections[0].remaining, retentionChanged.projections[0].remaining)

        var forecast = UsageSettings()
        forecast.forecastWAFPriorEquivalentHostBytes = 100e12
        let forecastChanged = estimate([older, latest], settings: forecast, hardwareProfile: profile)
        XCTAssertEqual(baseline.domainBaselineBudget, forecastChanged.domainBaselineBudget)
        XCTAssertEqual(baseline.domainRemainingBytes, forecastChanged.domainRemainingBytes)
        XCTAssertNotEqual(baseline.forecastWAF, forecastChanged.forecastWAF)
        XCTAssertNotEqual(baseline.projections[0].remaining, forecastChanged.projections[0].remaining)
    }

    func testHeldForecastWithholdsEveryHostRow() throws {
        // A SMART/FTL firmware mismatch holds the series. The Client row
        // used to keep a value through the domain split.
        let topology = try XCTUnwrap(directTopology())
        let held = estimate([ftl(now, firmware: "FW2", topology: topology)], hardwareProfile: completeBandProfile())
        XCTAssertNil(held.projection(.real)?.remaining)
        XCTAssertNil(held.projection(.client)?.remaining)
        XCTAssertNil(held.domainWriteShare)
        let normal = estimate([ftl(now, topology: topology)], hardwareProfile: completeBandProfile())
        XCTAssertNotNil(normal.projection(.client)?.remaining)
    }

    func testFallbackWithoutTLCSplitStaysWithoutRetentionDerating() throws {
        // pSLC P/E 0 (a new Mac) leaves no TLC/pSLC split, so the pooled
        // fallback is used. It must still ignore the retention setting.
        let topology = try XCTUnwrap(directTopology())
        let profile = completeBandProfile()
        let baseline = estimate([ftl(now, slc: 0, topology: topology)], hardwareProfile: profile)
        var settings = UsageSettings()
        settings.retentionStorageTemperatureCelsius = 55
        let warmer = estimate([ftl(now, slc: 0, topology: topology)], settings: settings, hardwareProfile: profile)
        XCTAssertNil(baseline.domainWriteShare)
        let baselineReal = try XCTUnwrap(baseline.projection(.real)?.remaining)
        XCTAssertEqual(try XCTUnwrap(warmer.projection(.real)?.remaining), baselineReal, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(warmer.projection(.client)?.remaining),
                       try XCTUnwrap(baseline.projection(.client)?.remaining), accuracy: 1)
    }

    func testIdleTemperatureChangesRetentionOnlyAndFlowsThroughDashboard() throws {
        let snapshots = [ftl(now, topology: directTopology())]
        let start = smart(now.addingTimeInterval(-7_200), powerOnHours: 998)
        let end = smart(now, powerOnHours: 1_000)
        let temperatures = (0...12).map { index in
            TemperatureSample(capturedAt: now.addingTimeInterval(-7_200 + Double(index) * 600),
                deviceID: "drive-1", temperatureCelsius: 36)
        }
        func dashboard(_ samples: [TemperatureSample]) -> DashboardAnalyticsSnapshot {
            .build(analyzer: HistoryAnalyzer(), history: [start, end], temperatureHistory: samples,
                deviceID: "drive-1", period: .day, profile: nil, settings: UsageSettings(), now: now,
                asptoolSnapshots: snapshots)
        }
        let automatic = dashboard(temperatures).nandEndurance
        let fallback = dashboard([]).nandEndurance
        XCTAssertEqual(automatic.idleRetentionTemperature?.source, .idle)
        XCTAssertEqual(automatic.retentionScenario?.storageTemperatureCelsius, 36)
        XCTAssertEqual(fallback.idleRetentionTemperature?.source, .fallback)
        XCTAssertLessThan(try XCTUnwrap(automatic.retentionScenario?.remainingHostBytes),
                          try XCTUnwrap(fallback.retentionScenario?.remainingHostBytes))
        XCTAssertEqual(automatic.projection(.real), fallback.projection(.real))
        XCTAssertEqual(automatic.projection(.client), fallback.projection(.client))
    }

    func testRetentionScenarioDefaultsToJEDECStorageTemperature() throws {
        // Sensor readings without a comparable low-I/O interval are not
        // enough to call the temperature an idle observation.
        let topology = try XCTUnwrap(directTopology())
        let warm = (0..<200).map { index in
            TemperatureSample(capturedAt: now.addingTimeInterval(Double(-index) * 600), deviceID: "drive-1", temperatureCelsius: 42)
        }
        let result = NANDEnduranceV2.build(
            smart: smart(now), snapshots: [ftl(now, topology: topology)], history: [smart(now)],
            temperatures: warm, settings: UsageSettings(),
            rates: WriteRateSummary(sevenDayBytesPerDay: 100e9, thirtyDayBytesPerDay: 100e9, lifetimeBytesPerDay: 100e9),
            historicalRate: nil, excluding: [], now: now, hardwareProfile: completeBandProfile()
        )
        let scenario = try XCTUnwrap(result.retentionScenario)
        XCTAssertEqual(scenario.storageTemperatureCelsius, 30)
        XCTAssertEqual(scenario.storageTemperatureSource, "既定温度")
    }

    func testClientRowIgnoresRetentionWhileResearchValuesKeepIt() throws {
        let profile = completeBandProfile()
        let topology = try XCTUnwrap(directTopology())
        let baseline = estimate([ftl(now, topology: topology)], hardwareProfile: profile)
        var settings = UsageSettings()
        settings.retentionStorageTemperatureCelsius = 55
        let warmer = estimate([ftl(now, topology: topology)], settings: settings, hardwareProfile: profile)

        XCTAssertLessThan(try XCTUnwrap(warmer.domainClientRemainingBytes),
                          try XCTUnwrap(baseline.domainClientRemainingBytes))
        // Retention is a hypothetical scenario, not part of the Client row.
        XCTAssertEqual(try XCTUnwrap(warmer.projections[1].remaining),
                       try XCTUnwrap(baseline.projections[1].remaining), accuracy: 1)
        XCTAssertEqual(warmer.fixedReferenceRemainingBytes, baseline.fixedReferenceRemainingBytes,
                       "30°C・365日の詳細比較は通常Client行と独立に保持する")
        XCTAssertTrue(warmer.projections[1].note.contains("保持補正なし"))
    }

    func testDirectTopologyMismatchFallsBackToAggregateNUWithout80BandMainPath() throws {
        let topology = try XCTUnwrap(directTopology())
        var profile = completeBandProfile()
        profile = AppleNANDHardwareProfile(
            modelNumber: profile.modelNumber,
            logicalCapacityBytes: profile.logicalCapacityBytes,
            nandVendor: profile.nandVendor,
            nandMarketingName: profile.nandMarketingName,
            defaultBitsPerCell: profile.defaultBitsPerCell,
            controllerClass: profile.controllerClass,
            chipID: profile.chipID,
            firmwareVersion: profile.firmwareVersion,
            mspVersion: profile.mspVersion,
            pageSize: profile.pageSize,
            pagesPerBlockNative: profile.pagesPerBlockNative,
            pagesPerBlockSLC: profile.pagesPerBlockSLC,
            sectorsPerPage: profile.sectorsPerPage,
            blocksPerCAU: profile.blocksPerCAU,
            cauPerDie: profile.cauPerDie,
            numBus: profile.numBus,
            diesPerBus: profile.diesPerBus,
            busToMSP: profile.busToMSP,
            numDIP: profile.numDIP,
            sectorsPerFullBand: 98_305,
            sectorsPerFullBandSLC: profile.sectorsPerFullBandSLC,
            packageBlocksAtEOL: profile.packageBlocksAtEOL
        )
        let value = estimate([ftl(now, topology: topology)], hardwareProfile: profile)
        XCTAssertEqual(value.topologyMatchesIORegistryGeometry, false)
        XCTAssertFalse(value.domainModelAvailable)
        XCTAssertNil(value.domainBaselineBudget)
        XCTAssertNotNil(value.nominalBudget)
        XCTAssertTrue(value.domainModelNote.contains("N/u概算"))
    }

    func testReliabilityEvidenceSeparatesRecoveryFromHardEventsAndKeepsResearchInterval() throws {
        let topology = try XCTUnwrap(directTopology())
        let start = now.addingTimeInterval(-86_400)
        let old = ftl(start, h: 60e12, n: 80e12, topology: topology,
                      telemetry: FTLResearchTelemetrySnapshot(
                        nandReads: 100, ageRefreshPerTier: [1, 0],
                        backgroundRefreshMoves: 3, ueccReads: 0,
                        reducedReadVerifyNative: 4, hostTLCReadVerifyFailures: 0
                      ))
        let current = ftl(now, h: 61e12, n: 82e12, topology: topology,
                          telemetry: FTLResearchTelemetrySnapshot(
                            nandReads: 200, ageRefreshPerTier: [3, 0],
                            backgroundRefreshMoves: 4, ueccReads: 1,
                            reducedReadVerifyNative: 5, hostTLCReadVerifyFailures: 0
                          ), writeAmp: 0.7, intermediateWriteAmp: 0.2)
        let value = estimate([old, current], excluded: [DateInterval(start: start, end: now)])
        let evidence = try XCTUnwrap(value.reliabilityEvidence)
        XCTAssertEqual(evidence.state, .reliabilityEventObserved)
        XCTAssertTrue(evidence.researchSessionOverlap)
        XCTAssertTrue(evidence.counters.contains { $0.name == "UECC reads" && $0.delta == 1 && $0.isReliabilityEvent })
        XCTAssertTrue(evidence.counters.contains { $0.name == "Age refresh" && $0.delta == 2 && !$0.isReliabilityEvent })
        XCTAssertTrue(evidence.unmappedItems.contains { $0.contains("numPfail") })
        let components = try XCTUnwrap(value.wafComponents)
        XCTAssertEqual(try XCTUnwrap(components.residual),
                       try XCTUnwrap(current.writeAmplification) - 0.7 - 0.2, accuracy: 1e-12)
        XCTAssertEqual(components.isConsistent, true)
    }

    func testWAFComponentTinyNegativeResidualIsCaptureToleranceOnly() throws {
        let value = estimate([
            ftl(now, h: 100e12, n: 99.9e12, writeAmp: 0.6, intermediateWriteAmp: 0.4)
        ])
        let components = try XCTUnwrap(value.wafComponents)
        XCTAssertEqual(try XCTUnwrap(components.residual), 0, accuracy: 1e-12)
        XCTAssertEqual(components.isConsistent, true)
        XCTAssertTrue(components.note.contains("0.5%以内"))

        let largerMismatch = estimate([
            ftl(now, h: 100e12, n: 90e12, writeAmp: 0.6, intermediateWriteAmp: 0.4)
        ])
        let mismatch = try XCTUnwrap(largerMismatch.wafComponents)
        XCTAssertLessThan(try XCTUnwrap(mismatch.residual), 0)
        XCTAssertEqual(mismatch.isConsistent, false)
    }

    func testReliabilityEvidenceFirstSnapshotAndCounterResetAreNotNormal() throws {
        let topology = try XCTUnwrap(directTopology())
        let first = ftl(now, topology: topology,
                        telemetry: FTLResearchTelemetrySnapshot(nandReads: 100, ueccReads: 0))
        XCTAssertEqual(try XCTUnwrap(estimate([first]).reliabilityEvidence).state, .noComparableHistory)

        let old = ftl(now.addingTimeInterval(-86_400), h: 61e12, n: 82e12, topology: topology,
                      telemetry: FTLResearchTelemetrySnapshot(nandReads: 200, ueccReads: 0))
        let reset = ftl(now, h: 60e12, n: 80e12, topology: topology,
                        telemetry: FTLResearchTelemetrySnapshot(nandReads: 100, ueccReads: 0))
        XCTAssertEqual(try XCTUnwrap(estimate([old, reset]).reliabilityEvidence).state, .comparisonInvalid)
    }

    func testReliabilityCounterDecreaseExcludesOnlyThatCounter() throws {
        let topology = try XCTUnwrap(directTopology())
        let old = ftl(now.addingTimeInterval(-86_400), h: 60e12, n: 80e12, topology: topology,
                      telemetry: FTLResearchTelemetrySnapshot(
                        nandReads: 100, ageRefreshPerTier: [1, 0],
                        backgroundRefreshMoves: 3, ueccReads: 4
                      ))
        let current = ftl(now, h: 61e12, n: 82e12, topology: topology,
                          telemetry: FTLResearchTelemetrySnapshot(
                            nandReads: 200, ageRefreshPerTier: [2, 0, 0],
                            backgroundRefreshMoves: 4, ueccReads: 3
                          ))
        let evidence = try XCTUnwrap(estimate([old, current]).reliabilityEvidence)

        XCTAssertEqual(evidence.state, .recoveryActivityObserved)
        XCTAssertTrue(evidence.counters.contains { $0.name == "Background refresh moves" && $0.delta == 1 })
        XCTAssertFalse(evidence.counters.contains { $0.name == "UECC reads" })
        XCTAssertFalse(evidence.counters.contains { $0.name == "Age refresh" })
        XCTAssertTrue(evidence.unavailableCounters.contains { $0.contains("UECC reads") && $0.contains("counter減少") })
        XCTAssertTrue(evidence.unavailableCounters.contains { $0.contains("Age refresh") && $0.contains("配列形状変更") })
    }

    func testLegacySnapshotWithoutV24OptionalFieldsStillDecodes() throws {
        let snapshot = ftl(now, topology: try XCTUnwrap(directTopology()),
                           telemetry: FTLResearchTelemetrySnapshot(ueccReads: 0))
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(snapshot)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "directKeyContractVersion")
        object.removeValue(forKey: "directTopology")
        object.removeValue(forKey: "researchTelemetry")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ASPToolDiagnosticsSnapshot.self, from: legacyData)

        XCTAssertNil(decoded.directKeyContractVersion)
        XCTAssertNil(decoded.directTopology)
        XCTAssertNil(decoded.researchTelemetry)
    }
    func testDivergentDomainWearUsesConservativeMaximum() throws {
        let value = estimate([ftl(now, tlc: 300, slc: 5297)])
        let tlc = try XCTUnwrap(value.tlcWear)
        let pslc = try XCTUnwrap(value.pslcWear)
        XCTAssertGreaterThan(try XCTUnwrap(value.wearDivergence), 0.05)
        XCTAssertEqual(try XCTUnwrap(value.normalizedWear), max(tlc, pslc), accuracy: 1e-12)
        XCTAssertEqual(value.wearCombination, "保守側max（乖離あり）")
        XCTAssertTrue(value.notes.contains { $0.contains("乖離") && $0.contains("保守側max") })
    }
    func testLegacyClientPriorAndTrialChoiceCannotAffectNewMainPath() {
        let a = estimate([ftl(now)])
        var settings = UsageSettings()
        settings.retentionClientWAF = 0.6
        settings.retentionDailyWAFPrior = 9
        settings.retentionClientWAFSelection = UUID().uuidString
        let b = estimate([ftl(now)], settings: settings)
        XCTAssertEqual(a.projections, b.projections)
        XCTAssertEqual(a.forecastWAF, b.forecastWAF)
    }
    func testProjectionRemainingIsMonotonicAcrossWAFGrid() throws {
        var previous = Double.infinity
        for waf in stride(from: 0.5, through: 8.0, by: 0.25) {
            let row = NANDEnduranceV2.projection(
                title: "grid",
                budget: 10e15,
                host: 2e12,
                nand: 1e15,
                waf: waf,
                note: ""
            )
            let remaining = try XCTUnwrap(row.remaining)
            XCTAssertLessThanOrEqual(remaining, previous + 1)
            previous = remaining
        }
    }

    func testDomainRemainingNeverIncreasesAcrossPEGrid() throws {
        let profile = completeBandProfile()
        let topology = try XCTUnwrap(directTopology())
        var previous = Double.infinity
        for tlcPE in stride(from: 100.0, through: 2_900.0, by: 100.0) {
            let value = estimate([
                ftl(now, tlc: tlcPE, slc: 5_297, topology: topology)
            ], hardwareProfile: profile)
            let remaining = try XCTUnwrap(value.domainRemainingBytes)
            XCTAssertLessThanOrEqual(remaining, previous + 1)
            previous = remaining
        }
    }

    func testResearchOnlyTelemetryCannotChangePrimaryForecast() throws {
        let profile = completeBandProfile()
        let topology = try XCTUnwrap(directTopology())
        let plain = estimate([
            ftl(now, topology: topology)
        ], hardwareProfile: profile)
        let research = estimate([
            ftl(
                now,
                topology: topology,
                telemetry: FTLResearchTelemetrySnapshot(
                    nandReads: 999,
                    ageRefreshPerTier: [1, 2, 3],
                    backgroundRefreshMoves: 42,
                    ueccReads: 7,
                    bandsMaxTempHistogram: [0, 1, 5, 9]
                )
            )
        ], hardwareProfile: profile)

        XCTAssertEqual(plain.domainActualBudget, research.domainActualBudget)
        XCTAssertEqual(plain.domainRemainingBytes, research.domainRemainingBytes)
        XCTAssertEqual(plain.forecastWAF, research.forecastWAF)
        XCTAssertEqual(plain.projections, research.projections)
    }

    func testIdleNANDWritesRemainInRecentWAF() throws {
        let value = estimate([
            ftl(now.addingTimeInterval(-2 * 86400), h: 60e12, n: 80e12),
            ftl(now.addingTimeInterval(-86400), h: 60e12, n: 81e12),
            ftl(now, h: 61e12, n: 82e12)
        ])
        XCTAssertEqual(try XCTUnwrap(value.recentWAF), 2, accuracy: 1e-8)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(value.forecastWAF), try XCTUnwrap(value.longWAF))
        XCTAssertLessThanOrEqual(try XCTUnwrap(value.forecastWAF), 2)
    }
}
