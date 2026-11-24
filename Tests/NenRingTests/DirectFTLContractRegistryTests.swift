import XCTest
@testable import NenRing

final class DirectFTLContractRegistryTests: XCTestCase {
    func testStoredTopologyRejectsInvalidBoundariesAndGeometry() throws {
        let valid = try XCTUnwrap(DirectFTLTopology(
            contractVersion: DirectFTLResearchContract.reviewed25G83CoreV1,
            numVirtualBlocks: 722, intermediatePartitionStart: 1,
            userPartitionStart: 80, bytesPerPage: 16_384,
            pagesPerVirtualBlock: 24_576, pagesPerVirtualBlockSLC: 8_192
        ))
        let encoded = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(DirectFTLTopology.self, from: encoded), valid)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let invalidValues: [(String, Any)] = [
            ("numVirtualBlocks", 79),
            ("intermediatePartitionStart", 81),
            ("bytesPerPage", 0),
            ("topologyContractValidated", false)
        ]
        for (key, value) in invalidValues {
            var damaged = original
            damaged[key] = value
            let data = try JSONSerialization.data(withJSONObject: damaged)
            XCTAssertThrowsError(try JSONDecoder().decode(DirectFTLTopology.self, from: data), key)
        }
    }

    func testReviewed25G83DescriptorPinsPrivateInterfaceAndSemanticVersions() {
        let descriptor = DirectFTLContractRegistry.reviewed25G83

        XCTAssertEqual(descriptor.contractBuild, "25G83")
        XCTAssertEqual(descriptor.reviewedMacOSMajorVersions, [26, 27])
        XCTAssertTrue(descriptor.isReviewedRuntime("25G83"))
        XCTAssertEqual(descriptor.coreWearContractVersion, DirectFTLResearchContract.reviewed25G83CoreV1)
        XCTAssertEqual(descriptor.researchTelemetryContractVersion, DirectFTLResearchContract.reviewed25G83ResearchV241)
        XCTAssertEqual(descriptor.semanticContractVersion, DirectFTLResearchContract.latest)
        XCTAssertEqual(descriptor.payloadShapeVersion, "ftl-key-count-u64-table-v1")
        XCTAssertEqual(descriptor.topologySchemaVersion, "direct-topology-v1")
        XCTAssertEqual(descriptor.reviewStatus, .reviewed)
    }

    func testRegistryMatchesReviewedInterfaceAndRejectsUnknownBuildOrOffset() {
        let descriptor = DirectFTLContractRegistry.reviewed25G83
        XCTAssertTrue(descriptor.matchesInterface(
            service: "GetNVMeSMARTInterface",
            pluginUUID: "AA0FA6F9-C2D6-457F-B10B-59A13253292F",
            interfaceUUID: "CCD1DB19-FD9A-4DAF-BF95-12454B230AB6",
            kindRawValue: "all",
            vtableOffset: 0x108
        ))
        XCTAssertFalse(descriptor.matchesInterface(
            service: "GetNVMeSMARTInterface",
            pluginUUID: descriptor.pluginUUID,
            interfaceUUID: descriptor.interfaceUUID,
            kindRawValue: "all",
            vtableOffset: 0x110
        ))
        XCTAssertNil(DirectFTLContractRegistry.descriptor(contractBuild: "27A999"))
        XCTAssertNil(DirectFTLContractRegistry.descriptor(runtimeBuild: "27A999"))
    }

    func testReviewedRuntimeBuildsUseTheRegistry() {
        XCTAssertEqual(DirectFTLContractRegistry.descriptor(runtimeBuild: "26A434")?.contractBuild, "25G83")
        // Every build of a reviewed macOS major version is accepted.
        XCTAssertEqual(DirectFTLContractRegistry.descriptor(runtimeBuild: "26A428")?.contractBuild, "25G83")
        XCTAssertNil(DirectFTLContractRegistry.descriptor(runtimeBuild: "27A100"))

        let contract = DirectFTLResearchContract.latest
        let reviewed = DirectFTLContractStatus.validated(build: "26A434", contract: contract, topologyAvailable: true, telemetryAvailable: true)
        XCTAssertTrue(reviewed.runsOnReviewedBuild)
        XCTAssertEqual(reviewed.title, "対応済み・取得あり")

        let unreviewed = DirectFTLContractStatus.validated(build: "27A100", contract: contract, topologyAvailable: true, telemetryAvailable: true)
        XCTAssertFalse(unreviewed.runsOnReviewedBuild)
        XCTAssertEqual(unreviewed.title, "対応済み・実行buildは未確認")
    }

    func testExecutionReviewAllowsReviewedReleasesAndLocallyVerifiedOnes() {
        // A reviewed macOS release is enough; the SSD controller is not gated.
        XCTAssertEqual(DirectFTLContractRegistry.executionReview(runtimeBuild: "26A434"), .reviewed)
        XCTAssertEqual(DirectFTLContractRegistry.executionReview(runtimeBuild: "25G83"), .reviewed)
        // 14/15 may try automatically, without being labelled reviewed.
        for (build, major) in [("23G90", 14), ("24G90", 15)] {
            let trial = DirectFTLContractRegistry.executionReview(runtimeBuild: build)
            XCTAssertEqual(trial, .compatibilityTrial(macOSMajor: major))
            XCTAssertTrue(trial.allowsAutomaticCollection)
            XCTAssertFalse(trial.isReviewed)
            XCTAssertNil(DirectFTLContractRegistry.descriptor(runtimeBuild: build))
        }
        for build in ["22G90", "27A100", "unknown"] {
            XCTAssertFalse(DirectFTLContractRegistry.executionReview(runtimeBuild: build).allowsAutomaticCollection)
        }
        let local = DirectFTLContractRegistry.executionReview(runtimeBuild: "24G90", locallyVerifiedMajors: [15])
        XCTAssertEqual(local, .locallyVerified(macOSMajor: 15))
        XCTAssertTrue(local.allowsAutomaticCollection)
        XCTAssertFalse(local.isReviewed)
        // Local verification is per major release.
        XCTAssertEqual(DirectFTLContractRegistry.executionReview(runtimeBuild: "27B100", locallyVerifiedMajors: [15]), .unreviewedBuild("27B100"))
    }

    func testUnreviewedControllerIsNotShownAsReviewed() {
        let status = DirectFTLContractStatus.validated(
            build: "26A434", contract: DirectFTLResearchContract.latest,
            topologyAvailable: true, telemetryAvailable: false, hardwareReviewed: false
        )
        XCTAssertFalse(status.runsOnReviewedBuild)
        XCTAssertEqual(status.title, "対応済み・SSDコントローラは未確認")
    }

    func testOnlyExplicitRequestsPassTheUnreviewedBuildFlag() {
        let root = URL(fileURLWithPath: "/tmp/out")
        XCTAssertFalse(ASPDirectProbeRequest.ftlAll.arguments(outputRootURL: root).contains("--allow-unreviewed-build"))
        XCTAssertTrue(ASPDirectProbeRequest.ftlAll.arguments(outputRootURL: root, allowUnreviewedBuild: true).contains("--allow-unreviewed-build"))
        XCTAssertTrue(ASPDirectProbeRequest.ftlPerm.arguments(outputRootURL: root, allowUnreviewedBuild: true).contains("--allow-unreviewed-build"))
        // The snapshot probe has the same release check and flag.
        XCTAssertFalse(ASPDirectProbeRequest.snapshotHeader.arguments(outputRootURL: root).contains("--allow-unreviewed-build"))
        XCTAssertTrue(ASPDirectProbeRequest.snapshotHeader.arguments(outputRootURL: root, allowUnreviewedBuild: true).contains("--allow-unreviewed-build"))
    }

    func testCompatibilityTrialPassesFlagWithoutExpandingReviewedProbeReleases() {
        let root = URL(fileURLWithPath: "/tmp/out")
        let trial = DirectFTLContractRegistry.executionReview(runtimeBuild: "23G90")
        XCTAssertTrue(ASPDirectProbeRequest.ftlAll.arguments(
            outputRootURL: root, allowUnreviewedBuild: !trial.isReviewed
        ).contains("--allow-unreviewed-build"))
        XCTAssertEqual(DirectFTLContractRegistry.compatibilityTrialMacOSMajorVersions, [14, 15])
        XCTAssertFalse(DirectFTLContractRegistry.reviewed25G83.isReviewedRuntime("23G90"))
        XCTAssertFalse(DirectFTLContractRegistry.reviewed25G83.isReviewedRuntime("24G90"))
        XCTAssertTrue(DirectFTLContractRegistry.reviewed25G83.isReviewedRuntime("25G83"))
    }

    func testSnapshotProbeMetadataFromMacOS27IsAccepted() throws {
        // Metadata written by snapshot probe v3 on macOS 27 (26A434), where the
        // controller class is AppleANS3CGv2Controller.
        let metadata = """
        build=26A434
        contractBuild=25G83
        probeVersion=3
        controller=AppleANS3CGv2Controller
        selector=9
        opcode=0x91
        role=snapshot header
        euid=501
        captured_at_epoch=1790937968
        size_query_result=0x00000000
        size_query_response_bytes=4
        requested_bytes=4316
        snapshot_read_attempted=1
        snapshot_read_result=0x00000000
        snapshot_read_response_bytes=16384
        capacity_bytes=16384
        payload_bytes=4316
        size_query_elapsed_ms=0.408
        snapshot_read_elapsed_ms=0.400
        total_elapsed_ms=1.273
        format_status=unconfirmed
        """
        let measurement = try ASPDirectProbeMetadataParser().parse(text: metadata)
        XCTAssertEqual(measurement.controller, "AppleANS3CGv2Controller")
        XCTAssertTrue(measurement.isReviewedInterface)
        let unknown = try ASPDirectProbeMetadataParser().parse(
            text: metadata.replacingOccurrences(of: "AppleANS3CGv2Controller", with: "SomeOtherNVMeController")
        )
        XCTAssertFalse(unknown.isReviewedInterface)
    }

    func testCProbeReviewedReleasesMatchRegistry() throws {
        for name in ["asp-ftl-stats-probe.c", "asp-snapshot-probe.c"] {
            let probe = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/\(name)")
            let source = try String(contentsOf: probe, encoding: .utf8)
            let line = try XCTUnwrap(source.split(separator: "\n").first { $0.contains("kReviewedDarwinMajors[] =") }, name)
            let darwinMajors = line.matches(of: /\b([1-9][0-9])\b/).compactMap { Int($0.output.1) }
            let macOSMajors = Set(darwinMajors.compactMap { DirectFTLContractRegistry.macOSMajorVersion(fromBuild: "\($0)A1") })
            XCTAssertEqual(macOSMajors, DirectFTLContractRegistry.reviewed25G83.reviewedMacOSMajorVersions, name)
        }
    }

    func testBuildMapsToMacOSMajorVersion() {
        XCTAssertEqual(DirectFTLContractRegistry.macOSMajorVersion(fromBuild: "25G83"), 26)
        XCTAssertEqual(DirectFTLContractRegistry.macOSMajorVersion(fromBuild: "26A434"), 27)
        XCTAssertEqual(DirectFTLContractRegistry.macOSMajorVersion(fromBuild: "24G84"), 15)
        XCTAssertNil(DirectFTLContractRegistry.macOSMajorVersion(fromBuild: "unknown"))
        XCTAssertNil(DirectFTLContractRegistry.macOSMajorVersion(fromBuild: "26"))
        // Minor builds of a reviewed major are accepted; other majors are not.
        XCTAssertNotNil(DirectFTLContractRegistry.descriptor(runtimeBuild: "26B120"))
        XCTAssertNil(DirectFTLContractRegistry.descriptor(runtimeBuild: "27A100"))
    }

    private func crossCheckFTL(hostRaw: UInt64, tlcAverage: Double = 168, tlcMaximum: Double = 184, tlcEOL: Double = 3_000,
                               at: Double = 1_800_000_000, hours: UInt64? = nil,
                               controllerUsed: Double? = nil, slcUsed: Double? = nil) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: Date(timeIntervalSince1970: at), captureQuality: .explicit, deviceID: "disk0",
            sourceArtifact: .directFTL, sourceBuild: "26A434", contractBuild: "25G83",
            hostWrites: hostRaw, hostWritesUnitState: .provisional4KiB,
            tlcAveragePE: tlcAverage, tlcMaximumPE: tlcMaximum, tlcEOLPE: tlcEOL,
            slcAveragePE: 5_534, slcMaximumPE: 5_535, slcEOLPE: 100_000,
            powerOnHours: hours, controllerPercentUsed: controllerUsed, slcPercentUsed: slcUsed
        )
    }

    private func crossCheckSMART(dataUnitsWritten: UInt64?, at: Double = 1_800_000_000,
                                 hours: UInt64? = nil) -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: Date(timeIntervalSince1970: at), deviceID: "disk0", devicePath: "/dev/rdisk0",
            logicalCapacityBytes: 256_000_000_000, model: "APPLE SSD", serialNumber: nil, firmware: "591",
            smartctlVersion: nil, smartctlExitStatus: 0, temperatureCelsius: nil, powerOnHours: hours,
            powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: 5, availableSpare: nil,
            availableSpareThreshold: nil, criticalWarning: nil, mediaAndDataIntegrityErrors: nil,
            dataUnitsRead: nil, dataUnitsWritten: dataUnitsWritten, smartPassed: true
        )
    }

    func testCrossCheckPassesWhenFTLAndSMARTHostWritesAgree() {
        // 126,456,857 SMART data units ≈ 64.75 TB; FTL raw in 4 KiB units.
        let smart = crossCheckSMART(dataUnitsWritten: 126_456_857)
        let ftlHostRaw = UInt64((126_456_857.0 * 512_000.0 / 4_096.0).rounded())
        guard case let .passed(ratio) = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: ftlHostRaw), smart: smart) else {
            return XCTFail("expected pass")
        }
        XCTAssertEqual(ratio, 1, accuracy: 1e-6)
    }

    func testCrossCheckCatchesNANDWritesInTheWrongUnit() throws {
        let smart = crossCheckSMART(dataUnitsWritten: 126_456_857)
        let hostRaw = UInt64((126_456_857.0 * 512_000.0 / 4_096.0).rounded())
        let topology = try XCTUnwrap(DirectFTLTopology(
            contractVersion: DirectFTLResearchContract.reviewed25G83CoreV1, numVirtualBlocks: 722,
            intermediatePartitionStart: 1, userPartitionStart: 80, bytesPerPage: 16_384,
            pagesPerVirtualBlock: 24_576, pagesPerVirtualBlockSLC: 8_192))
        let reconstructed = try XCTUnwrap(topology.tlcCapacityBytes) * 168 + XCTUnwrap(topology.pslcWritableCapacityBytes) * 5_534
        func ftl(nandBytes: Double, withTopology: Bool = true) -> ASPToolDiagnosticsSnapshot {
            ASPToolDiagnosticsSnapshot(
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000), captureQuality: .explicit, deviceID: "disk0",
                sourceArtifact: .directFTL, sourceBuild: "26A434", contractBuild: "25G83",
                hostWrites: hostRaw, nandWrites: UInt64(nandBytes / 4_096),
                hostWritesUnitState: .provisional4KiB, nandWritesUnitState: .provisional4KiB,
                tlcAveragePE: 168, tlcMaximumPE: 184, tlcEOLPE: 3_000,
                slcAveragePE: 5_534, slcMaximumPE: 5_535, slcEOLPE: 100_000,
                directTopology: withTopology ? topology : nil)
        }

        // As on the reference Mac: NAND ≈ 1.006 × capacity × average P/E.
        guard case .passed = DirectFTLReadCrossCheck.evaluate(ftl: ftl(nandBytes: reconstructed * 1.006), smart: smart) else {
            return XCTFail("a normal read must pass")
        }
        // Read as 16 KiB pages instead of 4 KiB: four times too large.
        guard case let .failed(reason) = DirectFTLReadCrossCheck.evaluate(ftl: ftl(nandBytes: reconstructed * 4), smart: smart) else {
            return XCTFail("NAND four times too large must fail")
        }
        XCTAssertTrue(reason.contains("容量×平均P/E"))
        // Read as 512-byte sectors: an eighth, below the host writes.
        guard case let .failed(low) = DirectFTLReadCrossCheck.evaluate(
            ftl: ftl(nandBytes: reconstructed / 8, withTopology: false), smart: smart) else {
            return XCTFail("NAND below half the host writes must fail")
        }
        XCTAssertTrue(low.contains("NAND/Host"))
        // Without a topology only the host comparison applies.
        guard case .passed = DirectFTLReadCrossCheck.evaluate(ftl: ftl(nandBytes: reconstructed * 4, withTopology: false), smart: smart) else {
            return XCTFail("no topology, no reconstruction check")
        }
    }

    func testCrossCheckFailsOnUnitOrKeyMismatch() {
        let smart = crossCheckSMART(dataUnitsWritten: 126_456_857)
        let ftlHostRaw = UInt64((126_456_857.0 * 512_000.0 / 512.0).rounded())  // 512-byte units read as 4 KiB
        guard case .failed = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: ftlHostRaw), smart: smart) else {
            return XCTFail("expected failure")
        }
        guard case .failed = DirectFTLReadCrossCheck.evaluate(
            ftl: crossCheckFTL(hostRaw: 1, tlcAverage: 200, tlcMaximum: 184), smart: smart
        ) else { return XCTFail("expected P/E contradiction") }
        guard case .failed = DirectFTLReadCrossCheck.evaluate(
            ftl: crossCheckFTL(hostRaw: 1, tlcEOL: 0), smart: smart
        ) else { return XCTFail("expected EOL failure") }
    }

    func testCrossCheckIsUnavailableWithoutSMART() {
        guard case .unavailable = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: 1_000), smart: nil) else {
            return XCTFail("expected unavailable")
        }
    }

    func testCrossCheckIsIncompleteWhenWearKeysAreMissing() {
        // A changed key layout that drops the wear counters must not pass.
        let smart = crossCheckSMART(dataUnitsWritten: 126_456_857)
        let ftlHostRaw = UInt64((126_456_857.0 * 512_000.0 / 4_096.0).rounded())
        let missing = ASPToolDiagnosticsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), captureQuality: .explicit, deviceID: "disk0",
            sourceArtifact: .directFTL, sourceBuild: "26A434", contractBuild: "25G83",
            hostWrites: ftlHostRaw, hostWritesUnitState: .provisional4KiB
        )
        let check = DirectFTLReadCrossCheck.evaluate(ftl: missing, smart: smart)
        guard case .incomplete = check else { return XCTFail("expected incomplete, got \(check)") }
        guard case .passed = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: ftlHostRaw), smart: smart) else {
            return XCTFail("expected the complete snapshot to pass")
        }
    }

    func testPOHStableOffsetPassesButAbruptChangeStopsPersistence() {
        let raw: UInt64 = 15_000_000_000
        let before = crossCheckFTL(hostRaw: raw, at: 1_799_913_600, hours: 3_010)
        let oldSMART = crossCheckSMART(dataUnitsWritten: raw / 125, at: 1_799_913_600, hours: 3_000)
        let smart = crossCheckSMART(dataUnitsWritten: raw / 125, hours: 3_010)
        let stable = crossCheckFTL(hostRaw: raw, hours: 3_020)
        guard case .passed = DirectFTLReadCrossCheck.evaluate(ftl: stable, smart: smart,
            previous: before, smartHistory: [oldSMART]) else { return XCTFail("stable offset must pass") }
        let shifted = crossCheckFTL(hostRaw: raw, hours: 3_030)
        guard case .failed = DirectFTLReadCrossCheck.evaluate(ftl: shifted, smart: smart,
            previous: before, smartHistory: [oldSMART]) else { return XCTFail("Host matches but POH key shifted") }
    }

    func testPOHAllowsSamplingSkewAndRounding() {
        let before = crossCheckFTL(hostRaw: 1, at: 1_799_913_600, hours: 3_000)
        let oldSMART = crossCheckSMART(dataUnitsWritten: 1, at: 1_799_911_800, hours: 2_999)
        let latest = crossCheckFTL(hostRaw: 1, hours: 3_001)
        let smart = crossCheckSMART(dataUnitsWritten: 1, at: 1_800_001_800, hours: 3_003)
        let check = DirectFTLPowerOnHoursCheck.evaluate(ftl: latest, smart: smart, previous: before, smartHistory: [oldSMART])
        XCTAssertNil(check.failure)
        XCTAssertEqual(check.offsetChangeHours, 3)
        XCTAssertEqual(check.toleranceHours, 3)
    }

    func testPOHMissingOrInitialBaselineDoesNotRejectHostAgreement() {
        let raw: UInt64 = 15_000_000_000
        for hours: UInt64? in [nil, 3_000] {
            guard case .passed = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: raw, hours: hours),
                smart: crossCheckSMART(dataUnitsWritten: raw / 125, hours: hours)) else {
                return XCTFail("no prior POH is not evidence of a mismatch")
            }
        }
    }

    func testPOHResetIsNotSilentlyAccepted() {
        let check = DirectFTLPowerOnHoursCheck.evaluate(ftl: crossCheckFTL(hostRaw: 1, hours: 2),
            smart: crossCheckSMART(dataUnitsWritten: 1, hours: 3_020),
            previous: crossCheckFTL(hostRaw: 1, at: 1_799_913_600, hours: 3_000),
            smartHistory: [crossCheckSMART(dataUnitsWritten: 1, at: 1_799_913_600, hours: 3_000)])
        XCTAssertNotNil(check.failure)
    }

    func testHostMismatchOnlyFailsAgainstAFreshSMARTRead() {
        // 1 TB of SMART host writes against 1.1 TB in FTL: over the tolerance.
        let units: UInt64 = 2_000_000
        let raw = UInt64(1_100_000_000_000 / 4_096)
        let readAt = 1_800_000_000.0
        guard case .failed = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: raw),
            smart: crossCheckSMART(dataUnitsWritten: units, at: readAt - 120)) else {
            return XCTFail("a fresh SMART read proves the mismatch")
        }
        guard case .unavailable = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: raw),
            smart: crossCheckSMART(dataUnitsWritten: units, at: readAt - 121)) else {
            return XCTFail("writes since an old SMART read can explain the difference")
        }
    }

    func testReadCheckRejectsUnrelatedOrStaleSMARTAndNonfinitePE() {
        let raw: UInt64 = 15_000_000_000
        var smart = crossCheckSMART(dataUnitsWritten: raw / 125)
        smart.deviceID = "other"
        guard case .unavailable = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: raw), smart: smart) else {
            return XCTFail("device mismatch")
        }
        guard case .unavailable = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: raw),
            smart: crossCheckSMART(dataUnitsWritten: raw / 125, at: 1_799_827_200)) else { return XCTFail("stale SMART") }
        for pe in [Double.nan, .infinity] {
            guard case .failed = DirectFTLReadCrossCheck.evaluate(ftl: crossCheckFTL(hostRaw: raw, tlcAverage: pe),
                smart: crossCheckSMART(dataUnitsWritten: raw / 125)) else { return XCTFail("nonfinite PE") }
        }
    }

    func testWearPercentDifferenceIsDescriptiveNotAcquisitionFailure() {
        let raw: UInt64 = 15_000_000_000
        let ftl = crossCheckFTL(hostRaw: raw, controllerUsed: 25, slcUsed: 5)
        let smart = crossCheckSMART(dataUnitsWritten: raw / 125)
        guard case .passed = DirectFTLReadCrossCheck.evaluate(ftl: ftl, smart: smart) else { return XCTFail("percent difference is supplemental") }
        let result = DirectFTLCrossValidation.build(snapshots: [ftl], smartHistory: [smart], forecast: .empty, intervals: [])
        XCTAssertTrue(result.rows.first { $0.title == "Controller / SMART Used" }!.detail.contains("+20.000 pp"))
        XCTAssertTrue(result.rows.first { $0.title == "pSLC Used / P/E" }!.detail.contains("5.534%"))
        XCTAssertTrue(result.rows.first { $0.title == "生涯再構成残差" }!.detail.contains("不足"))
    }

    func testMissingSupplementalCountersStayMissing() {
        let result = DirectFTLCrossValidation.build(snapshots: [crossCheckFTL(hostRaw: 1)],
            smartHistory: [], forecast: .empty, intervals: [])
        XCTAssertTrue(result.rows.first { $0.title == "Controller / SMART Used" }!.detail.contains("未取得"))
        XCTAssertTrue(result.rows.first { $0.title == "pSLC Used / P/E" }!.detail.contains("未取得"))
        XCTAssertTrue(result.rows.first { $0.title == "直近区間残差" }!.detail.contains("なし"))
    }
}
