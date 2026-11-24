import Foundation
import Testing
import XCTest
@testable import NenRing

@Test("Swift Testing runner is available")
func swiftTestingRunnerIsAvailable() {
    #expect(Bool(true))
}

final class NenRingCoreTests: XCTestCase {
    func testPeerTBWCapacityScalingAndDatesWithoutWearPercentage() throws {
        let profile = AppleNANDHardwareProfile(nandVendor: "Hynix",
            nandMarketingName: "tlc_3d_v6_4p_512", defaultBitsPerCell: 3)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try XCTUnwrap(PeerTBWForecast.make(profile: profile,
            capacity: 256_000_000_000, written: 60_000_000_000_000,
            measuredRate: 100_000_000_000, historicalRate: 50_000_000_000, now: now))
        XCTAssertEqual(result.thresholdBytes, 256_000_000_000_000)
        XCTAssertEqual(result.remainingBytes, 196_000_000_000_000)
        XCTAssertEqual(try XCTUnwrap(result.measuredDate).timeIntervalSince(now), 1960 * 86_400)
        XCTAssertEqual(try XCTUnwrap(result.historicalDate).timeIntervalSince(now), 3920 * 86_400)
        XCTAssertEqual(PeerTBWForecast.threshold(profile: profile, capacity: 512_000_000_000), 512e12)
        XCTAssertNotNil(result.reference?.entryName)
        let conservative = result.conservativeComparison
        XCTAssertEqual(conservative.thresholdBytes, 150_000_000_000_000)
        XCTAssertEqual(conservative.remainingBytes, 90_000_000_000_000)
        XCTAssertEqual(try XCTUnwrap(conservative.measuredDate).timeIntervalSince(now), 900 * 86_400)
        XCTAssertEqual(PeerTBWForecast.threshold(profile: nil, capacity: 256_000_000_000), 153.6e12)
        XCTAssertEqual(PeerTBWForecast.threshold(profile: AppleNANDHardwareProfile(
            nandVendor: "Hynix", nandMarketingName: "unknown", defaultBitsPerCell: 3), capacity: 256_000_000_000), 153.6e12)
        XCTAssertNil(PeerTBWForecast.threshold(profile: profile, capacity: 0))
        let reached = try XCTUnwrap(PeerTBWForecast.make(profile: profile,
            capacity: 256_000_000_000, written: 260_000_000_000_000,
            measuredRate: 0, historicalRate: nil, now: now))
        XCTAssertTrue(reached.reached)
        XCTAssertEqual(reached.remainingBytes, 0)
        XCTAssertNil(reached.measuredDate)
        XCTAssertTrue(reached.conservativeComparison.reached)
        XCTAssertEqual(reached.conservativeComparison.writtenBytes, 260_000_000_000_000)
    }
    func testAppearanceModeOffersSystemLightAndDark() {
        XCTAssertEqual(
            AppearanceMode.allCases.map(\.rawValue),
            ["system", "light", "dark"]
        )
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.title, "ライト")
        XCTAssertEqual(AppearanceMode.dark.title, "ダーク")
    }

    func testParserPreservesMissingHealthFields() throws {
        let parser = SmartctlJSONParser()
        let snapshot = try parser.parse(
            data: Data(Self.basicFixture.utf8),
            capturedAt: Self.date(day: 1),
            devicePath: "/dev/rdisk0"
        )

        XCTAssertEqual(snapshot.model, "APPLE SSD AP0256Q")
        XCTAssertEqual(snapshot.temperatureCelsius, 47)
        XCTAssertEqual(snapshot.powerOnHours, 1234)
        XCTAssertEqual(snapshot.powerCycleCount, 321)
        XCTAssertNil(snapshot.percentageUsed)
        XCTAssertNil(snapshot.dataUnitsWritten)
        XCTAssertTrue(snapshot.healthMetricsMissing.contains(.percentageUsed))
        XCTAssertTrue(snapshot.healthMetricsMissing.contains(.dataUnitsWritten))
        if case .limited = snapshot.evaluation {
            XCTAssertTrue(true)
        } else {
            XCTFail("health logが欠損しているため部分取得であるべきです")
        }
    }

    func testParserReadsNestedNVMeHealthAndStringNumbers() throws {
        let parser = SmartctlJSONParser()
        let snapshot = try parser.parse(
            data: Data(Self.healthFixture.utf8),
            capturedAt: Self.date(day: 1),
            devicePath: "/dev/rdisk0"
        )

        XCTAssertEqual(snapshot.smartPassed, true)
        XCTAssertEqual(snapshot.percentageUsed, 5)
        XCTAssertEqual(snapshot.availableSpare, 100)
        XCTAssertEqual(snapshot.availableSpareThreshold, 99)
        XCTAssertEqual(snapshot.criticalWarning, 0)
        XCTAssertEqual(snapshot.mediaAndDataIntegrityErrors, 0)
        XCTAssertEqual(snapshot.dataUnitsRead, 123_456_789)
        XCTAssertEqual(snapshot.dataUnitsWritten, 45_678_901)
        XCTAssertEqual(snapshot.dataUnitsWrittenBytes, Double(45_678_901) * 512_000)
        XCTAssertEqual(snapshot.healthMetricsMissing, [])
        XCTAssertEqual(snapshot.evaluation, .normal)
    }

    func testParserReadsOptionalReportedUsageStartDate() throws {
        let parser = SmartctlJSONParser()
        let snapshot = try parser.parse(
            data: Data("""
            {
              "model_name": "Test NVMe",
              "usage_start_date": "2025-01-02T03:04:05Z",
              "data_units_written": 100,
              "percentage_used": 5
            }
            """.utf8),
            capturedAt: Self.date(day: 400),
            devicePath: "/dev/rdisk0"
        )

        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(
            snapshot.usageStartDate,
            formatter.date(from: "2025-01-02T03:04:05Z")
        )
    }

    func testASPToolParserExtractsLatestNANDStatsAndEraseSummaries() throws {
        let result = try ASPToolSnapshotParser().parse(
            text: """
            INTERMEDIATE PARTITION : Erase Cycles: Max ( 5164, 5% of EoL ) Min ( 5163, 5% of EoL ) Avg ( 5163, 5% of EoL )
                                     Max band age:     ( 0 )
                                     EoL erase cycles: ( 100000 )
            USER PARTITION         : Erase Cycles: Max ( 169, 5% of EoL ) Min ( 136, 4% of EoL ) Avg ( 156, 5% of EoL )
                                     Max band age:     ( 2 )
                                     EoL erase cycles: ( 3000 )
            NAND stats:
              hostWrites: 14740498136
              nandWrites: 23396871500
              averageTLCPECycles: 156
              averageSLCPECycles: 5163
              powerOnHours: 2956
              spareAvailablePercent: 100
              numDieFailures: 0
              WriteAmp: 0.669845
              IntermediateWriteAmp: 0.906460
            NAND stats:
              hostWrites: 14740499014
              nandWrites: 23396872644
              averageTLCPECycles: 156
              averageSLCPECycles: 5163
              powerOnHours: 2956
              WriteAmp: 0.000000
            """,
            capturedAt: Self.date(day: 10),
            captureQuality: .unknown,
            deviceID: "model:Apple SSD"
        )

        let snapshot = result.snapshot
        XCTAssertEqual(snapshot.observationBlockCount, 2)
        XCTAssertEqual(snapshot.hostWrites, 14_740_499_014)
        XCTAssertEqual(snapshot.nandWrites, 23_396_872_644)
        XCTAssertEqual(snapshot.hostWritesUnitState, .provisional4KiB)
        XCTAssertEqual(snapshot.tlcAveragePE, 156)
        XCTAssertEqual(snapshot.tlcMinimumPE, 136)
        XCTAssertEqual(snapshot.tlcMaximumPE, 169)
        XCTAssertEqual(snapshot.tlcEOLPE, 3_000)
        XCTAssertEqual(snapshot.slcAveragePE, 5_163)
        XCTAssertEqual(snapshot.slcEOLPE, 100_000)
        XCTAssertEqual(snapshot.powerOnHours, 2_956)
        XCTAssertEqual(snapshot.writeAmp!, 0.669845, accuracy: 0.000001)
        XCTAssertEqual(snapshot.writeAmplification!, 23_396_872_644.0 / 14_740_499_014.0, accuracy: 0.000001)
        XCTAssertTrue(result.recognizedKeys.contains("averageTLCPECycles"))
        XCTAssertTrue(result.recognizedKeys.contains("USER EoL erase cycles"))
    }

    func testASPToolParserEmitsVerifiedUnitOnlyWhenExplicitlyProvided() throws {
        let result = try ASPToolSnapshotParser().parse(
            text: """
            NAND stats:
              hostWrites: 100
              nandWrites: 200
            """,
            capturedAt: Self.date(day: 11),
            captureQuality: .explicit,
            unitState: .verified
        )

        XCTAssertEqual(result.snapshot.hostWritesUnitState, .verified)
        XCTAssertEqual(result.snapshot.nandWritesUnitState, .verified)
        XCTAssertTrue(result.snapshot.parseWarnings.contains {
            $0.contains("検証済み4 KiB")
        })
    }

    func testASPToolFileParserKeepsOnlyBoundedStreamingState() throws {
        let text = """
        INTERMEDIATE PARTITION : Erase Cycles: Max ( 5164 ) Min ( 5163 ) Avg ( 5163 )
                                 EoL erase cycles: ( 100000 )
        USER PARTITION         : Erase Cycles: Max ( 169 ) Min ( 136 ) Avg ( 156 )
                                 EoL erase cycles: ( 3000 )
        NAND stats:
          hostWrites: 14740498136
          nandWrites: 23396871500
          averageTLCPECycles: 156
          averageSLCPECycles: 5163
          powerOnHours: 2956
          WriteAmp: 0.669845
        NAND stats:
          hostWrites: 14740499014
          nandWrites: 23396872644
          averageTLCPECycles: 157
          WriteAmp: 0.000000
        """
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPToolStreaming-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(text.utf8).write(to: fileURL)

        let result = try ASPToolSnapshotParser().parse(
            fileURL: fileURL,
            capturedAt: Self.date(day: 12),
            captureQuality: .fileMetadata,
            deviceID: "model:Apple SSD"
        )

        XCTAssertEqual(result.snapshot.observationBlockCount, 2)
        XCTAssertEqual(result.snapshot.hostWrites, 14_740_499_014)
        XCTAssertEqual(result.snapshot.nandWrites, 23_396_872_644)
        XCTAssertEqual(result.snapshot.tlcAveragePE, 157)
        XCTAssertEqual(result.snapshot.tlcEOLPE, 3_000)
        XCTAssertEqual(result.snapshot.slcEOLPE, 100_000)
        XCTAssertEqual(result.snapshot.writeAmp!, 0.669845, accuracy: 0.000001)
    }

    func testASPToolFileParserRejectsOversizedLineWithoutReadingTheWholeFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fileURL = root.appendingPathComponent("build/.asptool-long-line-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(repeating: 0x41, count: 1_048_577).write(to: fileURL)

        XCTAssertThrowsError(try ASPToolSnapshotParser().parse(fileURL: fileURL,
            capturedAt: Self.date(day: 12))) { error in
            XCTAssertEqual(error as? ASPToolSnapshotParserError, .lineTooLong)
        }
    }

    func testASPToolFileParserHonorsCancellation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fileURL = root.appendingPathComponent("build/.asptool-cancel-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("NAND stats:\n  hostWrites: 100\n".utf8).write(to: fileURL)

        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ASPToolSnapshotParser().parse(fileURL: fileURL,
                capturedAt: Date(timeIntervalSince1970: 1_790_000_000))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled import should not parse the file")
        } catch is CancellationError {
            // The user can cancel a pending manual import.
        }
    }

    func testASPToolParserKeepsBadBlocksAndBandCountOptional() throws {
        let result = try ASPToolSnapshotParser().parse(
            text: """
            Grown Bad Blocks Count: 12
            Factory Bad Blocks Count: 34
            numBands: 733
            NAND stats:
              hostWrites: 100
              percentUsed: 5
              slcPercentUsed: 5
              oslcTransitions: 211
              oslcBaseAvgPE: 3
              hostAutoWrites: 14540518998
              hostAutoWriteXacts: 2146829946
              RxBurnIntBandsProgrammed: 159
              RxBurnUsrBandsProgrammed: 1214
              RxBurnIntNandWrites: 5210112
              RxBurnUsrNandWrites: 125958059
              perfUserErases: 23
              perfIntErases: 24
              numTLC_pgs: 17
            """,
            capturedAt: Self.date(day: 13),
            deviceID: "model:Apple SSD"
        )

        XCTAssertEqual(result.snapshot.grownBadBlocks, 12)
        XCTAssertEqual(result.snapshot.factoryBadBlocks, 34)
        XCTAssertEqual(result.snapshot.bandCount, 733)
        XCTAssertEqual(result.snapshot.controllerPercentUsed, 5)
        XCTAssertEqual(result.snapshot.slcPercentUsed, 5)
        XCTAssertEqual(result.snapshot.oslcTransitions, 211)
        XCTAssertEqual(result.snapshot.oslcBaseAveragePE, 3)
        XCTAssertEqual(result.snapshot.hostAutoWrites, 14_540_518_998)
        XCTAssertEqual(result.snapshot.hostAutoWriteTransactions, 2_146_829_946)
        XCTAssertEqual(result.snapshot.intermediateBandsProgrammed, 159)
        XCTAssertEqual(result.snapshot.userBandsProgrammed, 1_214)
        XCTAssertEqual(result.snapshot.intermediateNandWrites, 5_210_112)
        XCTAssertEqual(result.snapshot.userNandWrites, 125_958_059)
        XCTAssertEqual(result.snapshot.performanceUserErases, 23)
        XCTAssertEqual(result.snapshot.performanceIntermediateErases, 24)
        XCTAssertEqual(result.snapshot.numberOfTLCPages, 17)
        XCTAssertTrue(result.recognizedKeys.contains("Grown Bad Blocks Count"))
        XCTAssertTrue(result.recognizedKeys.contains("Factory Bad Blocks Count"))
        XCTAssertTrue(result.recognizedKeys.contains("bandCount"))
        XCTAssertTrue(result.snapshot.parseWarnings.contains("ASP内部書込カウンタは単位未確認のため容量・寿命予測へ投入していません"))
    }

    func testASPDirectProbeMetadataParserPreservesReadEvidence() throws {
        let metadata = """
        build=25G83
        controller=AppleANS3NVMeController
        selector=9
        opcode=0x16
        role=time-sensitive snapshot payload
        euid=0
        captured_at_epoch=1757412345
        size_query_result=0x00000000
        size_query_response_bytes=4
        requested_bytes=854016
        snapshot_read_attempted=1
        snapshot_read_result=0x00000000
        snapshot_read_response_bytes=868352
        capacity_bytes=868352
        payload_bytes=854016
        size_query_elapsed_ms=0.120
        snapshot_read_elapsed_ms=4.250
        total_elapsed_ms=4.500
        format_status=unconfirmed
        """

        let measurement = try ASPDirectProbeMetadataParser().parse(text: metadata)
        XCTAssertEqual(measurement.opcode, .timeSensitiveSnapshotPayload)
        XCTAssertEqual(measurement.effectiveUserID, 0)
        XCTAssertEqual(measurement.requestedBytes, 854_016)
        XCTAssertEqual(measurement.payloadBytes, 854_016)
        XCTAssertEqual(measurement.capturedAt, Date(timeIntervalSince1970: 1_757_412_345))
        XCTAssertEqual(measurement.outcome, .success)
        XCTAssertTrue(measurement.isSupportedTarget)
    }

    func testASPDirectArtifactInspectorKeepsCaptureTimeAndHeaderEvidence() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPDirectArtifact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let metadata = """
        build=25G83
        controller=AppleANS3NVMeController
        selector=9
        opcode=0x91
        role=snapshot header
        euid=0
        captured_at_epoch=1757412345
        size_query_result=0x00000000
        size_query_response_bytes=4
        requested_bytes=32
        snapshot_read_attempted=1
        snapshot_read_result=0x00000000
        snapshot_read_response_bytes=4096
        capacity_bytes=4096
        payload_bytes=32
        size_query_elapsed_ms=0.120
        snapshot_read_elapsed_ms=4.250
        total_elapsed_ms=4.500
        format_status=unconfirmed
        """
        try Data(metadata.utf8).write(to: directoryURL.appendingPathComponent("metadata.txt"))

        var header = Data(repeating: 0, count: 32)
        Self.writeUInt32LE(5, to: &header, at: 0x04)
        Self.writeUInt32LE(32, to: &header, at: 0x14)
        Self.writeUInt32LE(28, to: &header, at: 0x18)
        try header.write(to: directoryURL.appendingPathComponent("opcode-0x91.bin"))

        let inspection = try ASPDirectArtifactInspector().inspect(directoryURL: directoryURL)
        XCTAssertEqual(inspection.measurement.outcome, .success)
        XCTAssertEqual(inspection.binaryByteCount, 32)
        XCTAssertEqual(inspection.binaryParseStatus, .headerBoundaryValidated)
        XCTAssertEqual(inspection.headerEvidence?.referencedTableOffset, 28)
        XCTAssertNil(inspection.parseError)
        XCTAssertEqual(inspection.measurement.capturedAt, Date(timeIntervalSince1970: 1_757_412_345))
    }

    func testASPDirectProbeMetadataParserDistinguishesReadFailure() throws {
        let metadata = """
        build=25G83
        controller=AppleANS3NVMeController
        selector=9
        opcode=0x16
        role=time-sensitive snapshot payload
        euid=501
        size_query_result=0x00000000
        size_query_response_bytes=4
        requested_bytes=854016
        snapshot_read_attempted=1
        snapshot_read_result=0xe00002be
        snapshot_read_response_bytes=868352
        capacity_bytes=868352
        payload_bytes=0
        size_query_elapsed_ms=0.120
        snapshot_read_elapsed_ms=15.250
        total_elapsed_ms=15.500
        format_status=unconfirmed
        """

        let measurement = try ASPDirectProbeMetadataParser().parse(text: metadata)
        XCTAssertEqual(measurement.outcome, .readFailed)
        XCTAssertTrue(measurement.snapshotReadAttempted)
        XCTAssertEqual(measurement.snapshotReadResultCode, 0xe00002be)
        XCTAssertEqual(measurement.payloadBytes, 0)
    }

    func testASPDirectBinaryParserValidatesHeaderContractWithoutInventingValues() throws {
        var header = Data(repeating: 0, count: 32)
        Self.writeUInt32LE(5, to: &header, at: 0x04)
        Self.writeUInt32LE(32, to: &header, at: 0x14)
        Self.writeUInt32LE(28, to: &header, at: 0x18)

        let result = try ASPDirectBinaryParser().parse(
            data: header,
            opcode: .snapshotHeader,
            expectedBytes: header.count,
            capturedAt: Self.date(day: 14),
            deviceID: "model:Apple SSD"
        )

        XCTAssertEqual(result.status, .headerBoundaryValidated)
        XCTAssertEqual(result.headerEvidence?.helperRevisionField, 5)
        XCTAssertEqual(result.headerEvidence?.declaredSnapshotBytes, 32)
        XCTAssertEqual(result.headerEvidence?.referencedTableOffset, 28)
        XCTAssertNil(result.normalizedSnapshot)
        XCTAssertNil(result.sourceRecordAt)

        var observedRevisionEight = Data(repeating: 0, count: 32)
        Self.writeUInt32LE(8, to: &observedRevisionEight, at: 0x04)
        Self.writeUInt32LE(32, to: &observedRevisionEight, at: 0x14)
        Self.writeUInt32LE(28, to: &observedRevisionEight, at: 0x18)
        let revisionEightResult = try ASPDirectBinaryParser().parse(
            data: observedRevisionEight,
            opcode: .snapshotHeader,
            expectedBytes: observedRevisionEight.count,
            capturedAt: Self.date(day: 14),
            deviceID: "model:Apple SSD"
        )
        XCTAssertEqual(revisionEightResult.status, .headerBoundaryValidated)
        XCTAssertEqual(revisionEightResult.headerEvidence?.helperRevisionField, 8)
    }

    func testASPDirectBinaryParserRejectsTruncatedSizeOffsetAndUnknownRevision() throws {
        let parser = ASPDirectBinaryParser()

        XCTAssertThrowsError(try parser.parse(
            data: Data(repeating: 0, count: 27),
            opcode: .snapshotHeader,
            expectedBytes: 27,
            capturedAt: Self.date(day: 15)
        )) { error in
            XCTAssertEqual(
                error as? ASPDirectBinaryParserError,
                .truncated(requiredBytes: 28, actualBytes: 27)
            )
        }

        var invalidSize = Data(repeating: 0, count: 32)
        Self.writeUInt32LE(5, to: &invalidSize, at: 0x04)
        Self.writeUInt32LE(28, to: &invalidSize, at: 0x14)
        Self.writeUInt32LE(28, to: &invalidSize, at: 0x18)
        XCTAssertThrowsError(try parser.parse(
            data: invalidSize,
            opcode: .snapshotHeader,
            expectedBytes: invalidSize.count,
            capturedAt: Self.date(day: 15)
        )) { error in
            XCTAssertEqual(
                error as? ASPDirectBinaryParserError,
                .invalidDeclaredSize(expectedBytes: 28, actualBytes: 32)
            )
        }

        var invalidOffset = Data(repeating: 0, count: 32)
        Self.writeUInt32LE(5, to: &invalidOffset, at: 0x04)
        Self.writeUInt32LE(32, to: &invalidOffset, at: 0x14)
        Self.writeUInt32LE(33, to: &invalidOffset, at: 0x18)
        XCTAssertThrowsError(try parser.parse(
            data: invalidOffset,
            opcode: .snapshotHeader,
            expectedBytes: invalidOffset.count,
            capturedAt: Self.date(day: 15)
        )) { error in
            XCTAssertEqual(
                error as? ASPDirectBinaryParserError,
                .invalidOffset(offset: 33, dataSize: 32)
            )
        }

        var unknownRevision = Data(repeating: 0, count: 32)
        Self.writeUInt32LE(6, to: &unknownRevision, at: 0x04)
        Self.writeUInt32LE(32, to: &unknownRevision, at: 0x14)
        Self.writeUInt32LE(28, to: &unknownRevision, at: 0x18)
        XCTAssertThrowsError(try parser.parse(
            data: unknownRevision,
            opcode: .snapshotHeader,
            expectedBytes: unknownRevision.count,
            capturedAt: Self.date(day: 15)
        )) { error in
            XCTAssertEqual(
                error as? ASPDirectBinaryParserError,
                .unknownRevision(6)
            )
        }
    }

    func testASPDirectBinaryParserMarksPartialPayloadAndDoesNotCreateCurrentRecord() throws {
        let parser = ASPDirectBinaryParser()
        XCTAssertThrowsError(try parser.parse(
            data: Data(),
            opcode: .timeSensitiveSnapshotPayload,
            capturedAt: Self.date(day: 16)
        )) { error in
            XCTAssertEqual(error as? ASPDirectBinaryParserError, .missingExpectedSize)
        }

        XCTAssertThrowsError(try parser.parse(
            data: Data(repeating: 0, count: 4),
            opcode: .timeSensitiveSnapshotPayload,
            expectedBytes: 8,
            capturedAt: Self.date(day: 16)
        )) { error in
            XCTAssertEqual(
                error as? ASPDirectBinaryParserError,
                .partialRead(expectedBytes: 8, actualBytes: 4)
            )
        }

        let payload = Data(repeating: 0xA5, count: 8)
        let result = try parser.parse(
            data: payload,
            opcode: .timeSensitiveSnapshotPayload,
            expectedBytes: payload.count,
            capturedAt: Self.date(day: 16),
            deviceID: "model:Apple SSD"
        )
        XCTAssertEqual(result.status, .formatUnconfirmed)
        XCTAssertNil(result.normalizedSnapshot)
        XCTAssertNil(result.sourceRecordAt)
    }

    func testASPToolDirectFTLParserNormalizesConfirmedAllCountersConservatively() throws {
        let capturedAt = Self.date(day: 20)
        let parsedAt = Self.date(day: 21)
        let payload = Self.makeASPFTLRecords([
            (4, [1_000]),       // hostWrites
            (5, [100]),         // Host-write composition candidate; semantic label unverified
            (6, [200]),         // Host-write composition candidate; semantic label unverified
            (27, [700]),        // Host-write composition candidate; semantic label unverified
            (18, [2_000]),      // nandWrites; 4 KiB provisional on 25G83
            (19, [3_000]),      // NAND reads, raw counter
            (20, [2]),          // bandErases
            (34, [3_011]),      // powerOnHours
            (46, [9]),          // factory bad blocks
            (47, [0]),          // grown bad blocks
            (49, [4_096]),      // bytesPerPage
            (50, [100]),        // pagesPerVirtualBlock
            (52, [722]),        // numVirtualBlocks
            (84, [3]),          // intermediateBandErases
            (85, [1]),          // intermediate partition start
            (86, [80]),         // user partition start
            (93, [7, 0, 2]),    // age refresh per tier
            (97, [8]),          // background refresh moves
            (112, [9]),         // bands padded for age
            (129, [20]),        // pagesPerVirtualBlockSlc
            (124, [100, 5_000]), // 25G83 minimum TLC / pSLC P/E
            (503, [120, 5_500]), // 25G83 average TLC / pSLC P/E
            (125, [140, 6_000]), // 25G83 maximum TLC / pSLC P/E
            (942, [100_000]),    // 25G83 pSLC EoL P/E
            (943, [3_000]),      // 25G83 TLC EoL P/E
            (430, [5]),           // 25G83 pSLC % Used
            (431, [5]),           // 25G83 controller % Used
            (432, [14_540_518_998]), // 25G83 hostAutoWrites
            (433, [2_146_829_946]),  // 25G83 hostAutoWriteXacts
            (349, [159]),          // 25G83 RxBurnIntBandsProgrammed
            (350, [1_214]),        // 25G83 RxBurnUsrBandsProgrammed
            (351, [5_210_112]),    // 25G83 RxBurnIntNandWrites
            (352, [125_958_059]),  // 25G83 RxBurnUsrNandWrites
            (531, [0]),            // 25G83 numDieFailures
            (532, [100]),          // 25G83 spareAvailablePercent
            (561, [211]),          // 25G83 oslcTransitions
            (565, [3]),            // 25G83 oslcBaseAvgPE
            (707, [23]),           // 25G83 perfUserErases
            (708, [24]),           // 25G83 perfIntErases
            (327, [0, 0, 7]),      // bands max-temperature histogram
            (328, [0, 3, 4]),      // bands min-temperature histogram
            (329, [4, 0, 0]),      // bands lifetime-temperature histogram
            (330, [0, 0]),         // bands delta-temperature histogram
            (331, [0, 0, 0]),      // bands cross-temperature histogram
            (340, [0]),            // cross-temperature UECC
            (343, [0]),            // utility UECC
            (414, [0]),            // UECC
            (422, [0]),            // native RV
            (423, [10]),           // reduced native RV
            (424, [0]),            // pSLC RV
            (427, [11]),           // direct-to-TLC bands
            (461, [12]),           // direct-to-TLC sectors
            (462, [13]),           // fallback-to-waterfall
            (485, [14]),           // non-proportional direct-to-TLC sectors
            (659, [15]),           // RAID verification reads
            (953, [0]),            // cross-temperature RAID UECC
            (1050, [0]),           // host pSLC RV failures
            (1051, [0]),           // host TLC RV failures
            (1052, [0]),           // GC pSLC-to-TLC RV failures
            (1053, [0])            // GC TLC-to-TLC RV failures
        ])
        let measurement = try ASPToolDirectFTLMetadataParser().parse(
            text: Self.aspFTLMetadata(
                kind: "all",
                responseBytes: payload.count,
                capturedAt: capturedAt
            )
        )

        let context = CurrentDeviceContext(
            deviceID: "model:Apple SSD|capacity:256000000000",
            controllerID: "AppleANS3NVMeController",
            firmware: "FWCTX",
            mspVersion: "MSPCTX",
            chipID: "S5E",
            sourceBuild: "25G83"
        )
        let result = try ASPToolDirectFTLParser().parse(
            data: payload,
            measurement: measurement,
            deviceID: "model:Apple SSD|capacity:256000000000",
            deviceContext: context,
            parsedAt: parsedAt
        )
        let snapshot = try XCTUnwrap(result.snapshot)

        XCTAssertEqual(result.measurement.kind, .all)
        XCTAssertEqual(result.parsedAt, parsedAt)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
        XCTAssertEqual(snapshot.sourceArtifact, .directFTL)
        XCTAssertEqual(snapshot.sourceBuild, "25G83")
        XCTAssertEqual(snapshot.deviceID, context.deviceID)
        XCTAssertEqual(snapshot.firmware, "FWCTX")
        XCTAssertEqual(snapshot.mspVersion, "MSPCTX")
        XCTAssertEqual(snapshot.chipID, "S5E")
        XCTAssertEqual(snapshot.firmwareEpoch, "FWCTX|MSPCTX")
        XCTAssertEqual(snapshot.hostWrites, 1_000)
        XCTAssertEqual(snapshot.nandWrites, 2_000)
        XCTAssertEqual(snapshot.hostWritesUnitState, .provisional4KiB)
        XCTAssertEqual(snapshot.nandWritesUnitState, .provisional4KiB)
        XCTAssertEqual(try XCTUnwrap(snapshot.hostWrittenBytes), 4_096_000, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(snapshot.nandWrittenBytes), 8_192_000, accuracy: 0.1)
        XCTAssertEqual(snapshot.writeAmplification!, 2.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot.powerOnHours, 3_011)
        XCTAssertEqual(snapshot.factoryBadBlocks, 9)
        XCTAssertEqual(snapshot.grownBadBlocks, 0)
        XCTAssertEqual(snapshot.spareAvailablePercent, 100)
        XCTAssertEqual(snapshot.numDieFailures, 0)
        XCTAssertEqual(snapshot.controllerPercentUsed, 5)
        XCTAssertEqual(snapshot.slcPercentUsed, 5)
        XCTAssertEqual(snapshot.oslcTransitions, 211)
        XCTAssertEqual(snapshot.oslcBaseAveragePE, 3)
        XCTAssertEqual(snapshot.hostAutoWrites, 14_540_518_998)
        XCTAssertEqual(snapshot.hostAutoWriteTransactions, 2_146_829_946)
        XCTAssertEqual(snapshot.intermediateBandErases, 3)
        XCTAssertEqual(snapshot.intermediateBandsProgrammed, 159)
        XCTAssertEqual(snapshot.userBandsProgrammed, 1_214)
        XCTAssertEqual(snapshot.intermediateNandWrites, 5_210_112)
        XCTAssertEqual(snapshot.userNandWrites, 125_958_059)
        XCTAssertEqual(snapshot.performanceUserErases, 23)
        XCTAssertEqual(snapshot.performanceIntermediateErases, 24)
        XCTAssertEqual(snapshot.hostWriteCompositionCandidateKey5, 100)
        XCTAssertEqual(snapshot.hostWriteCompositionCandidateKey6, 200)
        XCTAssertEqual(snapshot.hostWriteCompositionCandidateKey27, 700)
        XCTAssertEqual(snapshot.writeAmp!, 0.2, accuracy: 0.000001)
        XCTAssertEqual(snapshot.intermediateWriteAmp!, 0.06, accuracy: 0.000001)
        XCTAssertEqual(snapshot.tlcMinimumPE, 100)
        XCTAssertEqual(snapshot.tlcAveragePE, 120)
        XCTAssertEqual(snapshot.tlcMaximumPE, 140)
        XCTAssertEqual(snapshot.tlcEOLPE, 3_000)
        XCTAssertEqual(snapshot.slcMinimumPE, 5_000)
        XCTAssertEqual(snapshot.slcAveragePE, 5_500)
        XCTAssertEqual(snapshot.slcMaximumPE, 6_000)
        XCTAssertEqual(snapshot.slcEOLPE, 100_000)
        XCTAssertEqual(snapshot.directKeyContractVersion, DirectFTLResearchContract.latest)
        let topology = try XCTUnwrap(snapshot.directTopology)
        XCTAssertEqual(topology.numVirtualBlocks, 722)
        XCTAssertEqual(topology.intermediatePartitionStart, 1)
        XCTAssertEqual(topology.userPartitionStart, 80)
        XCTAssertEqual(topology.intermediateBandCount, 79)
        XCTAssertEqual(topology.tlcBandCount, 642)
        let telemetry = try XCTUnwrap(snapshot.researchTelemetry)
        XCTAssertEqual(telemetry.nandReads, 3_000)
        XCTAssertEqual(telemetry.ageRefreshPerTier, [7, 0, 2])
        XCTAssertEqual(telemetry.ageRefreshTotal, 9)
        XCTAssertEqual(telemetry.backgroundRefreshMoves, 8)
        XCTAssertEqual(telemetry.reducedReadVerifyNative, 10)
        XCTAssertEqual(telemetry.bandsMaxTempHistogram, [0, 0, 7])
        XCTAssertEqual(telemetry.bandsCrossTempHistogram, [0, 0, 0])
        XCTAssertEqual(FTLHistogramSummary.summarize(try XCTUnwrap(telemetry.bandsMaxTempHistogram)).finalNonZeroBin, 2)
        XCTAssertTrue(FTLHistogramSummary.summarize(try XCTUnwrap(telemetry.bandsCrossTempHistogram)).allBinsZero)
        XCTAssertNil(snapshot.bandCount)
        XCTAssertTrue(snapshot.parseWarnings.contains {
            $0.contains("4 KiB暫定")
        })
        XCTAssertTrue(snapshot.parseWarnings.contains {
            $0.contains("25G83で照合済み")
        })
        XCTAssertTrue(snapshot.parseWarnings.contains {
            $0.contains("asptoolラベルとFTL keyを照合")
        })
        XCTAssertTrue(snapshot.parseWarnings.contains {
            $0.contains("composition候補 key 5 / 6 / 27")
        })

        let composition = try XCTUnwrap(
            HostWriteCompositionAuditor().assess(baseline: nil, latest: snapshot)
        )
        XCTAssertEqual(composition.comparison, .snapshot)
        XCTAssertEqual(composition.candidateSum, 1_000)
        XCTAssertEqual(composition.hostWrites, 1_000)
        XCTAssertEqual(composition.status, .exactMatch)
        XCTAssertEqual(try XCTUnwrap(composition.relativeError), 0, accuracy: 0.000001)
        XCTAssertTrue(composition.note.contains("未確定"))

        let baseline = ASPToolDiagnosticsSnapshot(
            capturedAt: Self.date(day: 20),
            deviceID: "drive",
            sourceArtifact: .directFTL,
            sourceBuild: "25G83",
            hostWrites: 1_000,
            firmware: "FW",
            mspVersion: "MSP",
            hostWriteCompositionCandidateKey5: 100,
            hostWriteCompositionCandidateKey6: 200,
            hostWriteCompositionCandidateKey27: 700,
            directKeyContractVersion: DirectFTLResearchContract.latest,
            researchTelemetry: FTLResearchTelemetrySnapshot()
        )
        let later = ASPToolDiagnosticsSnapshot(
            capturedAt: Self.date(day: 21),
            deviceID: "drive",
            sourceArtifact: .directFTL,
            sourceBuild: "25G83",
            hostWrites: 1_100,
            firmware: "FW",
            mspVersion: "MSP",
            hostWriteCompositionCandidateKey5: 150,
            hostWriteCompositionCandidateKey6: 225,
            hostWriteCompositionCandidateKey27: 725,
            directKeyContractVersion: DirectFTLResearchContract.latest,
            researchTelemetry: FTLResearchTelemetrySnapshot()
        )
        let deltaComposition = try XCTUnwrap(
            HostWriteCompositionAuditor().assess(baseline: baseline, latest: later)
        )
        XCTAssertEqual(deltaComposition.comparison, .delta)
        XCTAssertEqual(deltaComposition.candidateValues, [50, 25, 25])
        XCTAssertEqual(deltaComposition.candidateSum, 100)
        XCTAssertEqual(deltaComposition.hostWrites, 100)
        XCTAssertEqual(deltaComposition.status, .exactMatch)

        let verifiedResult = try ASPToolDirectFTLParser().parse(
            data: payload,
            measurement: measurement,
            deviceID: "model:Apple SSD|capacity:256000000000",
            parsedAt: parsedAt,
            unitState: .verified
        )
        XCTAssertEqual(try XCTUnwrap(verifiedResult.snapshot).hostWritesUnitState, .verified)
    }

    func testASPToolDirectFTLParserKeepsEOLStateButRejectsDuplicateAndOversizedResearchFields() throws {
        let capturedAt = Self.date(day: 21)
        let oversizedHistogram = Array(repeating: UInt64(0), count: DirectFTLResearchContract.maximumHistogramBins + 1)
        let payload = Self.makeASPFTLRecords([
            (4, [0]), (4, [1]), // duplicate scalar must not silently pick one
            (18, [0]),
            (49, [16_384]), (50, [24_576]), (129, [8_192]),
            (52, [722]), (85, [1]), (86, [80]),
            (124, [3_001, 100_001]),
            (503, [3_001, 100_001]),
            (125, [3_001, 100_001]),
            (942, [100_000]), (943, [3_000]),
            (327, oversizedHistogram)
        ])
        let measurement = try ASPToolDirectFTLMetadataParser().parse(
            text: Self.aspFTLMetadata(kind: "all", responseBytes: payload.count, capturedAt: capturedAt)
        )
        let snapshot = try XCTUnwrap(ASPToolDirectFTLParser().parse(
            data: payload, measurement: measurement, deviceID: "drive", parsedAt: capturedAt
        ).snapshot)

        XCTAssertNil(snapshot.hostWrites)
        XCTAssertEqual(snapshot.nandWrites, 0, "scalar zero is a valid observed value")
        XCTAssertEqual(snapshot.tlcAveragePE, 3_001, "EOL超過はparse失敗ではない")
        XCTAssertEqual(snapshot.slcAveragePE, 100_001, "EOL超過はparse失敗ではない")
        XCTAssertNotNil(snapshot.directTopology)
        XCTAssertNil(snapshot.researchTelemetry?.bandsMaxTempHistogram)
        XCTAssertTrue(snapshot.parseWarnings.contains { $0.contains("重複record") })
        XCTAssertTrue(snapshot.parseWarnings.contains { $0.contains("配列数") })
    }

    func testFTLHistogramSummaryKeepsEmptyAndAllZeroDistinctAndComputesSelectedTail() {
        let empty = FTLHistogramSummary.summarize([])
        XCTAssertEqual(empty.binCount, 0)
        XCTAssertTrue(empty.allBinsZero)
        XCTAssertEqual(empty.totalCount, 0)

        let zero = FTLHistogramSummary.summarize([0, 0, 0])
        XCTAssertEqual(zero.binCount, 3)
        XCTAssertTrue(zero.allBinsZero)
        XCTAssertEqual(zero.totalCount, 0)

        let populated: [UInt64] = [1, 2, 7]
        let summary = FTLHistogramSummary.summarize(populated)
        XCTAssertFalse(summary.allBinsZero)
        XCTAssertEqual(summary.finalNonZeroBin, 2)
        XCTAssertEqual(try XCTUnwrap(FTLHistogramSummary.tailFraction(populated, from: 1)), 0.9, accuracy: 1e-12)
        XCTAssertNil(FTLHistogramSummary.tailFraction(populated, from: 3))
    }

    func testFTLResearchTelemetryDecodesLegacyHistogramKeysButWritesV241Keys() throws {
        let legacy = Data(#"{"nandReads":1,"readTemperatureHistogram":[1,2],"slcReadRetryHistogram":[0,0]}"#.utf8)
        let decoded = try JSONDecoder().decode(FTLResearchTelemetrySnapshot.self, from: legacy)
        XCTAssertEqual(decoded.bandsMaxTempHistogram, [1, 2])
        XCTAssertEqual(decoded.bandsCrossTempHistogram, [0, 0])

        let encoded = try JSONEncoder().encode(decoded)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("bandsMaxTempHistogram"))
        XCTAssertTrue(text.contains("bandsCrossTempHistogram"))
        XCTAssertFalse(text.contains("readTemperatureHistogram"))
        XCTAssertFalse(text.contains("slcReadRetryHistogram"))
    }

    func testASPToolDirectFTLParserRejectsTruncationAndUnconfirmedPermFormat() throws {
        let capturedAt = Self.date(day: 22)
        let truncated = Self.makeASPFTLRecords([(4, [1_000, 2_000])])
            .dropLast(MemoryLayout<UInt64>.size)
        let allMeasurement = try ASPToolDirectFTLMetadataParser().parse(
            text: Self.aspFTLMetadata(
                kind: "all",
                responseBytes: truncated.count,
                capturedAt: capturedAt
            )
        )

        XCTAssertThrowsError(try ASPToolDirectFTLParser().parse(
            data: Data(truncated),
            measurement: allMeasurement
        )) { error in
            XCTAssertEqual(
                error as? ASPToolDirectFTLParserError,
                .truncatedRecord(offset: 0, requiredBytes: 24, actualBytes: 16)
            )
        }

        let payload = Self.makeASPFTLRecords([(4, [1_000])])
        let permMeasurement = try ASPToolDirectFTLMetadataParser().parse(
            text: Self.aspFTLMetadata(
                kind: "perm",
                responseBytes: payload.count,
                capturedAt: capturedAt
            )
        )
        XCTAssertThrowsError(try ASPToolDirectFTLParser().parse(
            data: payload,
            measurement: permMeasurement
        )) { error in
            XCTAssertEqual(error as? ASPToolDirectFTLParserError, .unsupportedKind(.perm))
        }
    }

    func testASPToolDirectFTLParserDoesNotUseParseTimeWhenReadTimeIsMissing() throws {
        let payload = Self.makeASPFTLRecords([(4, [1_000])])
        let measurement = try ASPToolDirectFTLMetadataParser().parse(
            text: Self.aspFTLMetadata(
                kind: "all",
                responseBytes: payload.count,
                capturedAt: nil
            )
        )

        let result = try ASPToolDirectFTLParser().parse(
            data: payload,
            measurement: measurement,
            parsedAt: Self.date(day: 23)
        )

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.parsedAt, Self.date(day: 23))
        XCTAssertTrue(result.warnings.contains {
            $0.contains("parse時刻を取得時刻として扱っていません")
        })
    }

    func testASPToolDirectFTLArtifactCollectorReadsOnlyExistingArtifacts() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPFTL-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let payload = Self.makeASPFTLRecords([(34, [3_011])])
        try Data(Self.aspFTLMetadata(
            kind: "all",
            responseBytes: payload.count,
            capturedAt: Self.date(day: 24)
        ).utf8).write(to: directoryURL.appendingPathComponent("metadata.txt"))
        try payload.write(to: directoryURL.appendingPathComponent("asp-ftl-all.bin"))

        let result = try ASPToolDirectFTLArtifactCollector().collect(
            from: directoryURL,
            parsedAt: Self.date(day: 25)
        )
        XCTAssertEqual(result.snapshot?.powerOnHours, 3_011)
        XCTAssertEqual(result.snapshot?.sourceName, "asp-ftl-all.bin")
        XCTAssertEqual(result.parsedAt, Self.date(day: 25))
    }

    func testASPBandStatsParserValidates0x106StructureAndKeepsClassificationUnconfirmed() throws {
        let capturedAt = Self.date(day: 26)
        let parsedAt = Self.date(day: 27)
        let payload = Self.makeASPTunnelBandPayload(
            bandCount: 3,
            partitionCount: 2,
            eraseCycles: [137, 5_232, 172],
            trailingBytes: 16
        )
        let measurement = try ASPTunnelMetadataParser().parse(
            text: Self.aspTunnelMetadata(
                opcode: "0x106",
                responseBytes: payload.count,
                requestedBytes: payload.count,
                capturedAt: capturedAt
            )
        )

        let result = try ASPBandStatsParser().parse(
            data: payload,
            measurement: measurement,
            deviceID: "model:Apple SSD|capacity:256000000000",
            parsedAt: parsedAt
        )

        XCTAssertEqual(measurement.opcode, .aspExportFallback)
        XCTAssertEqual(measurement.outcome, .success)
        XCTAssertEqual(result.parsedAt, parsedAt)
        XCTAssertEqual(result.measurement.capturedAt, capturedAt)
        XCTAssertEqual(result.headerWords[0], 3)
        XCTAssertEqual(result.headerWords[1], 2)
        XCTAssertEqual(result.bandCount, 3)
        XCTAssertEqual(result.partitionCount, 2)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.records[1].fields.count, 8)
        XCTAssertEqual(result.records[1].eraseCycleField, 5_232)
        XCTAssertEqual(result.usedBytes, 32 + 3 * 32)
        XCTAssertEqual(result.trailingBytes, 16)
        XCTAssertEqual(result.eraseCycleSummary?.count, 3)
        XCTAssertEqual(result.eraseCycleSummary?.minimum, 137)
        XCTAssertEqual(result.eraseCycleSummary?.maximum, 5_232)
        XCTAssertEqual(try XCTUnwrap(result.eraseCycleSummary?.average), 1_847, accuracy: 0.000001)
        XCTAssertEqual(result.eraseCycleSummary?.valueCounts[137], 1)
        XCTAssertEqual(result.eraseCycleSummary?.valueCounts[5_232], 1)
        XCTAssertEqual(result.snapshot?.bandCount, 3)
        XCTAssertEqual(result.snapshot?.sourceArtifact, .directBandStats)
        XCTAssertNil(result.snapshot?.tlcAveragePE)
        XCTAssertNil(result.snapshot?.slcAveragePE)
        XCTAssertNil(result.snapshot?.tlcEOLPE)
        XCTAssertTrue(result.warnings.contains {
            $0.contains("TLC / pSLC")
        })
        XCTAssertTrue(result.warnings.contains {
            $0.contains("未解析領域")
        })
    }

    func testASPBandStatsParserRejectsTruncatedPayloadAndNonBandOpcode() throws {
        let fullPayload = Self.makeASPTunnelBandPayload(
            bandCount: 2,
            partitionCount: 2,
            eraseCycles: [137, 172]
        )
        let truncated = fullPayload.dropLast(8)
        let measurement = try ASPTunnelMetadataParser().parse(
            text: Self.aspTunnelMetadata(
                opcode: "0x106",
                responseBytes: truncated.count,
                requestedBytes: truncated.count,
                capturedAt: Self.date(day: 28)
            )
        )

        XCTAssertThrowsError(try ASPBandStatsParser().parse(
            data: Data(truncated),
            measurement: measurement
        )) { error in
            XCTAssertEqual(
                error as? ASPBandStatsParserError,
                .truncated(requiredBytes: 32 + 2 * 32, actualBytes: fullPayload.count - 8)
            )
        }

        let unsupportedMeasurement = try ASPTunnelMetadataParser().parse(
            text: Self.aspTunnelMetadata(
                opcode: "0x12b",
                responseBytes: fullPayload.count,
                requestedBytes: fullPayload.count,
                capturedAt: Self.date(day: 28)
            )
        )
        XCTAssertThrowsError(try ASPBandStatsParser().parse(
            data: fullPayload,
            measurement: unsupportedMeasurement
        )) { error in
            XCTAssertEqual(
                error as? ASPBandStatsParserError,
                .unsupportedTarget
            )
        }
    }

    func testASPBandStatsParserDoesNotInventCaptureTime() throws {
        let payload = Self.makeASPTunnelBandPayload(
            bandCount: 1,
            partitionCount: 2,
            eraseCycles: [137]
        )
        let measurement = try ASPTunnelMetadataParser().parse(
            text: Self.aspTunnelMetadata(
                opcode: "0x106",
                responseBytes: payload.count,
                requestedBytes: payload.count,
                capturedAt: nil
            )
        )

        let result = try ASPBandStatsParser().parse(
            data: payload,
            measurement: measurement,
            parsedAt: Self.date(day: 29)
        )
        XCTAssertNil(result.measurement.capturedAt)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.parsedAt, Self.date(day: 29))
        XCTAssertTrue(result.warnings.contains {
            $0.contains("parse時刻を取得時刻として扱っていません")
        })
    }

    func testASPDirectArtifactRouterRoutesFTLAndBandDirectories() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPArtifactRouter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let ftlDirectory = rootURL.appendingPathComponent("ftl")
        try FileManager.default.createDirectory(at: ftlDirectory, withIntermediateDirectories: true)
        let ftlPayload = Self.makeASPFTLRecords([(34, [3_011])])
        try Data(Self.aspFTLMetadata(
            kind: "all",
            responseBytes: ftlPayload.count,
            capturedAt: Self.date(day: 30)
        ).utf8).write(to: ftlDirectory.appendingPathComponent("metadata.txt"))
        try ftlPayload.write(to: ftlDirectory.appendingPathComponent("asp-ftl-all.bin"))

        switch try ASPDirectArtifactRouter().inspect(
            directoryURL: ftlDirectory,
            parsedAt: Self.date(day: 31)
        ) {
        case let .ftl(result):
            XCTAssertEqual(result.snapshot?.powerOnHours, 3_011)
            XCTAssertEqual(result.parsedAt, Self.date(day: 31))
        default:
            XCTFail("FTL artifactはFTL Parserへ振り分けられるべきです")
        }

        let bandDirectory = rootURL.appendingPathComponent("band")
        try FileManager.default.createDirectory(at: bandDirectory, withIntermediateDirectories: true)
        let bandPayload = Self.makeASPTunnelBandPayload(
            bandCount: 2,
            partitionCount: 2,
            eraseCycles: [137, 172]
        )
        try Data(Self.aspTunnelMetadata(
            opcode: "0x106",
            responseBytes: bandPayload.count,
            requestedBytes: bandPayload.count,
            capturedAt: Self.date(day: 32)
        ).utf8).write(to: bandDirectory.appendingPathComponent("metadata.txt"))
        try bandPayload.write(to: bandDirectory.appendingPathComponent("tunnel-0x106.bin"))

        switch try ASPDirectArtifactRouter().inspect(
            directoryURL: bandDirectory,
            parsedAt: Self.date(day: 33)
        ) {
        case let .bandStats(result):
            XCTAssertEqual(result.bandCount, 2)
            XCTAssertEqual(result.parsedAt, Self.date(day: 33))
        default:
            XCTFail("0x106 artifactはband Parserへ振り分けられるべきです")
        }
    }

    func testASPDirectArtifactRouterRoutesOpaquePermAndTunnelDirectories() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPOpaqueRouter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let permDirectory = rootURL.appendingPathComponent("perm")
        try FileManager.default.createDirectory(at: permDirectory, withIntermediateDirectories: true)
        let permPayload = Data(repeating: 0xA5, count: 64)
        try Data(Self.aspFTLMetadata(
            kind: "perm",
            responseBytes: permPayload.count,
            capturedAt: Self.date(day: 34)
        ).utf8).write(to: permDirectory.appendingPathComponent("metadata.txt"))
        try permPayload.write(to: permDirectory.appendingPathComponent("asp-ftl-perm.bin"))

        switch try ASPDirectArtifactRouter().inspect(
            directoryURL: permDirectory,
            parsedAt: Self.date(day: 35)
        ) {
        case let .opaque(.ftl(inspection)):
            XCTAssertEqual(inspection.measurement.kind, .perm)
            XCTAssertEqual(inspection.payloadByteCount, permPayload.count)
            XCTAssertEqual(inspection.parsedAt, Self.date(day: 35))
        default:
            XCTFail("perm artifactはopaque FTL inspectionへ振り分けられるべきです")
        }

        let tunnelDirectory = rootURL.appendingPathComponent("tunnel")
        try FileManager.default.createDirectory(at: tunnelDirectory, withIntermediateDirectories: true)
        let tunnelPayload = Data(repeating: 0x5A, count: 64)
        try Data(Self.aspTunnelMetadata(
            opcode: "0x129",
            responseBytes: tunnelPayload.count,
            requestedBytes: tunnelPayload.count,
            capturedAt: Self.date(day: 36)
        ).utf8).write(to: tunnelDirectory.appendingPathComponent("metadata.txt"))
        try tunnelPayload.write(to: tunnelDirectory.appendingPathComponent("tunnel-0x129.bin"))

        switch try ASPDirectArtifactRouter().inspect(
            directoryURL: tunnelDirectory,
            parsedAt: Self.date(day: 37)
        ) {
        case let .opaque(.tunnel(inspection)):
            XCTAssertEqual(inspection.measurement.opcode, .aspExport)
            XCTAssertEqual(inspection.payloadByteCount, tunnelPayload.count)
            XCTAssertEqual(inspection.parsedAt, Self.date(day: 37))
        default:
            XCTFail("0x129 artifactはopaque tunnel inspectionへ振り分けられるべきです")
        }
    }

    func testASPOpaqueInspectionKeepsFailedMetadataWithoutPayload() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPOpaqueFailure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let directory = rootURL.appendingPathComponent("perm-failed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.aspFTLMetadata(
            kind: "perm",
            responseBytes: 0,
            capturedAt: Self.date(day: 38)
        ).utf8).write(to: directory.appendingPathComponent("metadata.txt"))

        switch try ASPDirectArtifactRouter().inspect(
            directoryURL: directory,
            parsedAt: Self.date(day: 39)
        ) {
        case let .opaque(.ftl(inspection)):
            XCTAssertFalse(inspection.measurement.isSuccessfulRead)
            XCTAssertNil(inspection.payloadByteCount)
            XCTAssertTrue(inspection.warnings.contains { $0.contains("取得失敗") })
        default:
            XCTFail("payloadのない失敗metadataもopaque FTL inspectionへ振り分けられるべきです")
        }
    }

    func testASPTunnelDeviceErrorIsDistinctFromPermissionFailure() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPTunnelDeviceError-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let directory = rootURL.appendingPathComponent("tunnel-0x129-device-error")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.aspTunnelMetadata(
            opcode: "0x129",
            responseBytes: 0,
            requestedBytes: 0,
            capturedAt: Self.date(day: 40),
            sizeQueryResult: "0xe00002e9"
        ).utf8).write(to: directory.appendingPathComponent("metadata.txt"))

        let inspection = try ASPDirectArtifactRouter().inspect(
            directoryURL: directory,
            parsedAt: Self.date(day: 41)
        )
        guard case let .opaque(.tunnel(inspection)) = inspection else {
            return XCTFail("device error metadataはopaque tunnel inspectionへ振り分けられるべきです")
        }
        XCTAssertEqual(inspection.measurement.effectiveUserID, 0)
        XCTAssertEqual(inspection.measurement.failureResultCode, 0xe00002e9)
        XCTAssertEqual(inspection.measurement.failureResultTitle, "device error")
        XCTAssertTrue(inspection.measurement.isDeviceRejectedOpaqueTunnel)
        XCTAssertTrue(inspection.warnings.contains {
            $0.contains("権限不足ではなく")
        })
    }

    func testSettingsSaveKeepsFieldsTheWindowDoesNotEdit() {
        var stored = UsageSettings()
        stored.forecastWAFPriorEquivalentHostBytes = 2e12
        stored.retentionDailyWAFPriorHostBytes = 3e12
        stored.retentionStorageTemperatureCelsius = 30
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = stored.withStartBasis(manualStartDate: start)
        XCTAssertEqual(updated.manualStartDate, start)
        XCTAssertEqual(updated.forecastWAFPriorEquivalentHostBytes, 2e12)
        XCTAssertEqual(updated.retentionDailyWAFPriorHostBytes, 3e12)
        XCTAssertEqual(updated.retentionStorageTemperatureCelsius, 30)
    }

    func testSettingsSaveLeavesDefaultRetentionInputsUnset() {
        let untouched = UsageSettings().withRetentionInputs(manualTemperatureCelsius: nil, days: 365)
        XCTAssertNil(untouched.retentionDays)
        XCTAssertNil(untouched.retentionTemperatureOverrideEnabled)
        XCTAssertNil(untouched.retentionStorageTemperatureCelsius)
        XCTAssertTrue(untouched.isEmpty)

        let manual = UsageSettings().withRetentionInputs(manualTemperatureCelsius: 30, days: 180)
        XCTAssertEqual(manual.effectiveRetentionStorageTemperatureCelsius, 30)
        XCTAssertEqual(manual.retentionDays, 180)

        // Turning the override off returns to the automatic temperature;
        // an explicitly stored 365 days stays explicit.
        var stored = manual
        stored.retentionDays = 365
        let automatic = stored.withRetentionInputs(manualTemperatureCelsius: nil, days: 365)
        XCTAssertNil(automatic.effectiveRetentionStorageTemperatureCelsius)
        XCTAssertEqual(automatic.retentionDays, 365)
    }

    func testAdministratorOutputReadsExitStatusAfterCarriageReturns() throws {
        // `do shell script` returns "probe out\r__NENRING_EXIT__7" (CR, not LF).
        let failed = try XCTUnwrap(ASPAdministratorOutput.parse("stats_read=0x12b\r__NENRING_EXIT__7\n"))
        XCTAssertEqual(failed.status, 7)
        XCTAssertEqual(failed.output, "stats_read=0x12b")
        let ok = try XCTUnwrap(ASPAdministratorOutput.parse("a\r\nb\n__NENRING_EXIT__0"))
        XCTAssertEqual(ok.status, 0)
        XCTAssertEqual(ok.output, "a\nb")
        XCTAssertNil(ASPAdministratorOutput.parse("no marker here"))
    }

    func testASPDirectProbeGeneratorKeepsMetadataAfterProbeFailure() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPDirectGenerator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let probeDirectoryURL = rootURL.appendingPathComponent("Probes")
        let outputRootURL = rootURL.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: probeDirectoryURL, withIntermediateDirectories: true)

        let executableURL = probeDirectoryURL.appendingPathComponent("asp-snapshot-probe")
        let script = """
        #!/bin/sh
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-dir" ]; then
            output="$2"
            shift 2
          else
            shift
          fi
        done
        run="$output/fake-run"
        mkdir -p "$run"
        printf '%s\n' 'probe=fixture' > "$run/metadata.txt"
        printf 'artifact_dir=%s\n' "$run"
        exit 4
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executableURL.path
        )

        let generator = ASPDirectProbeGenerator(
            policy: ASPToolExecutionPolicy(
                timeout: 5,
                terminationGracePeriod: 0.2,
                outputDrainTimeout: 1,
                diagnosticBufferLimitBytes: 4096,
                retainFailedWorkspaces: true
            ),
            probeDirectoryURL: probeDirectoryURL,
            outputRootURL: outputRootURL,
            signatureVerifier: ASPProbeSignatureVerifier(allowUnsignedForTesting: true)
        )
        let result = try generator.generate(request: .snapshotPayload)

        XCTAssertEqual(result.request, .snapshotPayload)
        XCTAssertEqual(result.exitStatus, 4)
        XCTAssertEqual(result.privilege, .currentUser)
        XCTAssertTrue(result.runDirectoryURL.path.hasPrefix(outputRootURL.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.metadataURL.path))
        XCTAssertEqual(
            ASPDirectProbeRequest.ftlAll.arguments(outputRootURL: outputRootURL),
            ["--kind", "all", "--output-dir", outputRootURL.path]
        )
        XCTAssertEqual(
            ASPDirectProbeRequest.ftlAll.arguments(
                outputRootURL: outputRootURL,
                ownerUID: 501,
                ownerGID: 20
            ),
            [
                "--kind", "all", "--output-dir", outputRootURL.path,
                "--owner-uid", "501", "--owner-gid", "20"
            ]
        )
        XCTAssertEqual(
            ASPDirectProbeRequest.snapshotPayload.arguments(
                outputRootURL: outputRootURL,
                ownerUID: 501,
                ownerGID: 20
            ),
            ["--opcode", "0x16", "--output-dir", outputRootURL.path]
        )
    }

    func testASPDirectProbePrivilegeFailureDetectionIsNarrow() {
        let startedAt = Self.date(day: 1)
        let failed = ASPToolExecutionResult(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(1),
            terminationStatus: 4,
            stdoutTail: Data("plugin_result=resource shortage\n".utf8),
            stderrTail: Data()
        )
        let successful = ASPToolExecutionResult(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(1),
            terminationStatus: 0,
            stdoutTail: Data("resource shortage was not reported\n".utf8),
            stderrTail: Data()
        )

        XCTAssertTrue(ASPDirectProbeGenerator.shouldRetryWithAdministrator(failed))
        XCTAssertFalse(ASPDirectProbeGenerator.shouldRetryWithAdministrator(successful))
    }

    func testASPProbeSignatureVerifierRejectsProbeOutsideApplicationBundle() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPProbeSignature-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let probeURL = rootURL.appendingPathComponent("asp-ftl-stats-probe")
        let bundleURL = rootURL.appendingPathComponent("NenRing.app")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: probeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: probeURL.path
        )

        XCTAssertThrowsError(
            try ASPProbeSignatureVerifier().verify(
                executableURL: probeURL,
                expectedIdentifier: "asp-ftl-stats-probe",
                bundleURL: bundleURL,
                requiresAdministrator: false
            )
        ) { error in
            guard case let ASPProbeSignatureError.outsideBundle(path) = error else {
                return XCTFail("アプリバンドル外のprobeは拒否されるべきです: \(error)")
            }
            XCTAssertEqual(path, probeURL.resolvingSymlinksInPath().standardizedFileURL.path)
        }
    }

    func testASPProbeSignatureVerifierRejectsUserOwnedPathForAdministrator() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPProbeAdmin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let bundleURL = rootURL.appendingPathComponent("NenRing.app")
        let probeDirectoryURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("ASPProbes")
        try FileManager.default.createDirectory(at: probeDirectoryURL, withIntermediateDirectories: true)
        let probeURL = probeDirectoryURL.appendingPathComponent("asp-tunnel-probe")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: probeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: probeURL.path
        )

        XCTAssertThrowsError(
            try ASPProbeSignatureVerifier().verify(
                executableURL: probeURL,
                expectedIdentifier: "asp-tunnel-probe",
                bundleURL: bundleURL,
                requiresAdministrator: true
            )
        ) { error in
            guard case ASPProbeSignatureError.unprotectedForAdministrator = error else {
                return XCTFail("利用者所有のパスからroot probeを実行してはいけません: \(error)")
            }
        }
    }

    func testASPProbeSignatureVerifierRejectsUnsignedProbeInsideBundle() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPProbeUnsigned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let bundleURL = rootURL.appendingPathComponent("NenRing.app")
        let probeDirectoryURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("ASPProbes")
        try FileManager.default.createDirectory(at: probeDirectoryURL, withIntermediateDirectories: true)
        let probeURL = probeDirectoryURL.appendingPathComponent("asp-snapshot-probe")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: probeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: probeURL.path
        )

        XCTAssertThrowsError(
            try ASPProbeSignatureVerifier().verify(
                executableURL: probeURL,
                expectedIdentifier: "asp-snapshot-probe",
                bundleURL: bundleURL,
                requiresAdministrator: false
            )
        ) { error in
            guard let signatureError = error as? ASPProbeSignatureError else {
                return XCTFail("署名エラー型が想定外です: \(error)")
            }
            let signatureFailure: Bool
            switch signatureError {
            case .createFailed, .invalidSignature:
                signatureFailure = true
            default:
                signatureFailure = false
            }
            XCTAssertTrue(signatureFailure, "署名のないprobeはstrict検証で拒否されるべきです: \(signatureError)")
        }
    }

    func testASPDirectProbeRequestsUseTheTwoBundledProbes() {
        // The tunnel probes were the only targets that always elevated; they
        // are removed. A manual FTL read may still retry with authorization.
        XCTAssertEqual(ASPDirectProbeRequest.allCases, [.snapshotPayload, .snapshotHeader, .ftlAll, .ftlPerm])
        XCTAssertEqual(Set(ASPDirectProbeRequest.allCases.map(\.executableName)), ["asp-snapshot-probe", "asp-ftl-stats-probe"])
        // Snapshot probes now accept the unreviewed-build flag like the FTL probe.
        let root = URL(fileURLWithPath: "/tmp/probes")
        XCTAssertTrue(ASPDirectProbeRequest.snapshotHeader.arguments(outputRootURL: root, allowUnreviewedBuild: true)
            .contains("--allow-unreviewed-build"))
    }

    /// The Direct FTL probes run through this runner, so its time limit must hold.
    func testProcessRunnerTimesOutALongRunningProcess() throws {
        let runner = ASPToolProcessRunner(
            policy: ASPToolExecutionPolicy(timeout: 0.05, terminationGracePeriod: 0.05)
        )
        let invocation = ASPToolInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            environment: [:],
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            outputContract: .standardOutput(snapshotFileName: "sleep")
        )
        XCTAssertThrowsError(try runner.run(invocation)) { error in
            XCTAssertEqual(error as? ASPToolGenerationError, .timedOut)
        }
    }

    func testControllerEOLSingleSnapshotIsVisibleButDoesNotInventDates() throws {
        let snapshot = ASPToolDiagnosticsSnapshot(
            capturedAt: Self.date(day: 10),
            captureQuality: .unknown,
            deviceID: "model:Apple SSD",
            hostWrites: 14_740_499_014,
            nandWrites: 23_396_872_644,
            tlcAveragePE: 156,
            tlcEOLPE: 3_000,
            slcAveragePE: 5_163,
            slcEOLPE: 100_000
        )

        let forecast = ControllerEOLAnalyzer().forecast(
            from: [snapshot],
            deviceID: snapshot.deviceID,
            now: snapshot.capturedAt
        )

        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertEqual(forecast.projection, .singleSnapshot)
        XCTAssertEqual(forecast.unitState, .provisional4KiB)
        XCTAssertNil(forecast.lowerDate)
        XCTAssertNil(forecast.upperDate)
        XCTAssertEqual(
            forecast.estimatedEnduranceBytes!,
            Double(14_740_499_014) * 4_096 * 3_000 / 156,
            accuracy: 1
        )
        XCTAssertEqual(forecast.confidence, .veryLow)
    }

    func testControllerEOLUsesIntervalSlopeOnlyAfterTwoValidIntervals() throws {
        func makeControllerSnapshot(day: Int, hostWrites: UInt64, tlcPE: Double, slcPE: Double) -> ASPToolDiagnosticsSnapshot {
            ASPToolDiagnosticsSnapshot(
                capturedAt: Self.date(day: day),
                captureQuality: .explicit,
                deviceID: "model:Apple SSD",
                sourceBuild: "25G83",
                hostWrites: hostWrites,
                nandWrites: hostWrites * 2,
                hostWritesUnitState: .verified,
                tlcAveragePE: tlcPE,
                tlcEOLPE: 3_000,
                slcAveragePE: slcPE,
                slcEOLPE: 100_000,
                firmware: "FW1"
            )
        }

        let snapshots = [
            makeControllerSnapshot(day: 1, hostWrites: 10_000_000_000, tlcPE: 100, slcPE: 5_000),
            makeControllerSnapshot(day: 31, hostWrites: 10_300_000_000, tlcPE: 110, slcPE: 5_010),
            makeControllerSnapshot(day: 61, hostWrites: 10_600_000_000, tlcPE: 120, slcPE: 5_020)
        ]

        let forecast = ControllerEOLAnalyzer().forecast(
            from: snapshots,
            deviceID: "model:Apple SSD",
            now: snapshots.last!.capturedAt
        )

        XCTAssertEqual(forecast.state, .estimated)
        XCTAssertEqual(forecast.projection, .intervalSlope)
        XCTAssertEqual(forecast.intervalCount, 2)
        XCTAssertEqual(forecast.observationDays, 60, accuracy: 0.001)
        XCTAssertNotNil(forecast.lowerDate)
        XCTAssertNotNil(forecast.upperDate)
        XCTAssertEqual(forecast.confidence, .medium)
        XCTAssertGreaterThan(forecast.estimatedEnduranceBytes!, forecast.currentHostWrittenBytes!)
    }

    func testControllerEOLUsesRelativeIntervalSlopeForProvisionalCounters() throws {
        func makeControllerSnapshot(day: Int, hostWrites: UInt64, tlcPE: Double, slcPE: Double) -> ASPToolDiagnosticsSnapshot {
            ASPToolDiagnosticsSnapshot(
                capturedAt: Self.date(day: day),
                captureQuality: .explicit,
                deviceID: "model:Apple SSD",
                sourceBuild: "25G83",
                hostWrites: hostWrites,
                nandWrites: hostWrites * 2,
                hostWritesUnitState: .provisional4KiB,
                tlcAveragePE: tlcPE,
                tlcEOLPE: 3_000,
                slcAveragePE: slcPE,
                slcEOLPE: 100_000,
                firmware: "FW1"
            )
        }

        let snapshots = [
            makeControllerSnapshot(day: 1, hostWrites: 10_000_000_000, tlcPE: 100, slcPE: 5_000),
            makeControllerSnapshot(day: 31, hostWrites: 10_300_000_000, tlcPE: 110, slcPE: 5_010),
            makeControllerSnapshot(day: 61, hostWrites: 10_600_000_000, tlcPE: 120, slcPE: 5_020)
        ]

        let forecast = ControllerEOLAnalyzer().forecast(
            from: snapshots,
            deviceID: "model:Apple SSD",
            now: snapshots.last!.capturedAt
        )

        XCTAssertEqual(forecast.state, .estimated)
        XCTAssertEqual(forecast.projection, .intervalSlope)
        XCTAssertEqual(forecast.intervalCount, 2)
        XCTAssertEqual(forecast.observationDays, 60, accuracy: 0.001)
        XCTAssertNotNil(forecast.lowerDate)
        XCTAssertNotNil(forecast.upperDate)
        XCTAssertEqual(forecast.confidence, .low)
        XCTAssertTrue(forecast.basis.contains("relative interval"))
        XCTAssertGreaterThan(forecast.estimatedEnduranceBytes!, forecast.currentHostWrittenBytes!)
    }

    func testControllerEOLDoesNotBridgeDirectFTLBuildEpochs() throws {
        func makeControllerSnapshot(
            day: Int,
            hostWrites: UInt64,
            tlcPE: Double,
            sourceBuild: String
        ) -> ASPToolDiagnosticsSnapshot {
            ASPToolDiagnosticsSnapshot(
                capturedAt: Self.date(day: day),
                captureQuality: .explicit,
                deviceID: "model:Apple SSD",
                sourceArtifact: .directFTL,
                sourceBuild: sourceBuild,
                hostWrites: hostWrites,
                nandWrites: hostWrites * 2,
                hostWritesUnitState: .verified,
                tlcAveragePE: tlcPE,
                tlcEOLPE: 3_000,
                slcAveragePE: tlcPE * 10,
                slcEOLPE: 100_000,
                firmware: "FW1"
            )
        }

        let snapshots = [
            makeControllerSnapshot(day: 1, hostWrites: 10_000_000_000, tlcPE: 100, sourceBuild: "25G82"),
            makeControllerSnapshot(day: 31, hostWrites: 10_300_000_000, tlcPE: 110, sourceBuild: "25G83"),
            makeControllerSnapshot(day: 61, hostWrites: 10_600_000_000, tlcPE: 120, sourceBuild: "25G83"),
            makeControllerSnapshot(day: 91, hostWrites: 10_900_000_000, tlcPE: 130, sourceBuild: "25G83")
        ]

        let forecast = ControllerEOLAnalyzer().forecast(
            from: snapshots,
            deviceID: "model:Apple SSD",
            now: snapshots.last!.capturedAt
        )

        XCTAssertEqual(forecast.state, .estimated)
        XCTAssertEqual(forecast.intervalCount, 2)
        XCTAssertEqual(forecast.observationDays, 60, accuracy: 0.001)
    }

    func testDashboardAnalyticsRestoresBoundedControllerForecastWithoutRawLog() {
        let drive = makeSnapshot(day: 10, written: 100_000, percentage: 5, powerHours: 100)
        let controller = ASPToolDiagnosticsSnapshot(
            capturedAt: drive.capturedAt,
            captureQuality: .fileMetadata,
            deviceID: drive.deviceID,
            sourceArtifact: .directFTL,
            hostWrites: 14_740_499_014,
            nandWrites: 23_396_872_644,
            tlcAveragePE: 156,
            tlcEOLPE: 3_000,
            slcAveragePE: 5_163,
            slcEOLPE: 100_000
        )

        let analytics = DashboardAnalyticsSnapshot.build(
            analyzer: HistoryAnalyzer(calendar: Self.fixedCalendar),
            history: [drive],
            deviceID: drive.deviceID,
            period: .day,
            profile: nil,
            settings: UsageSettings(),
            now: drive.capturedAt,
            asptoolSnapshots: [controller]
        )

        XCTAssertEqual(analytics.controllerForecast.state, .collecting)
        XCTAssertEqual(analytics.controllerForecast.currentHostWrittenBytes!, 14_740_499_014 * 4_096, accuracy: 1)
        XCTAssertEqual(analytics.controllerForecast.currentTLCPE, 156)
        XCTAssertEqual(analytics.controllerForecast.currentSLCPE, 5_163)
        XCTAssertEqual(analytics.controllerForecast.projection, .singleSnapshot)
        XCTAssertNil(analytics.controllerForecast.lowerDate)
    }

    func testASPToolSnapshotStoreBoundsAndRoundTripsRecords() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPTool-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = ASPToolSnapshotStore(fileURL: fileURL, maximumRecordCount: 2, preservesAllMeasurements: false)
        for day in 1...3 {
            let snapshot = ASPToolDiagnosticsSnapshot(
                capturedAt: Self.date(day: day),
                deviceID: "model:Apple SSD",
                hostWrites: UInt64(day)
            )
            let appended = try await store.appendIfNew(snapshot)
            XCTAssertTrue(appended)
        }

        let records = try await store.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.hostWrites), [2, 3])
    }

    func testASPToolSnapshotStoreKeepsTornLinesAsideAndAppendsOnAFreshLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPToolTorn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("asptool-snapshots.jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(ASPToolDiagnosticsSnapshot(capturedAt: Self.date(day: 1), deviceID: "d", hostWrites: 1))
        data.append(0x0A)
        let torn = Data(#"{"capturedAt":"2026-"#.utf8)  // crash mid-append, no newline
        data.append(torn)
        try data.write(to: fileURL)

        let store = ASPToolSnapshotStore(fileURL: fileURL)
        let loaded = try await store.records()
        XCTAssertEqual(loaded.map(\.hostWrites), [1])
        let quarantine = JSONLQuarantine.destinationURL(sourceData: data, sourceURL: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path), "torn row must be kept aside")

        _ = try await store.appendIfNew(ASPToolDiagnosticsSnapshot(capturedAt: Self.date(day: 2), deviceID: "d", hostWrites: 2))
        let reloaded = ASPToolSnapshotStore(fileURL: fileURL)
        let reloadedRecords = try await reloaded.records()
        XCTAssertEqual(reloadedRecords.map(\.hostWrites), [1, 2])
    }

    func testASPToolSnapshotStoreAppendsOnAFreshLineAfterAMissingNewline() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPToolNL-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // A complete record whose trailing newline was never written.
        try encoder.encode(ASPToolDiagnosticsSnapshot(capturedAt: Self.date(day: 1), deviceID: "d", hostWrites: 1))
            .write(to: fileURL)
        let store = ASPToolSnapshotStore(fileURL: fileURL)
        _ = try await store.appendIfNew(ASPToolDiagnosticsSnapshot(capturedAt: Self.date(day: 2), deviceID: "d", hostWrites: 2))
        let reloaded = ASPToolSnapshotStore(fileURL: fileURL)
        let reloadedRecords = try await reloaded.records()
        XCTAssertEqual(reloadedRecords.map(\.hostWrites), [1, 2])
    }

    func testASPToolSnapshotStoreSharesEqualWarningsWithoutChangingTheFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPToolWarnings-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let warnings = ["固定の説明文その1（共有されるはずの長い文字列）", "固定の説明文その2（共有されるはずの長い文字列）"]
        func record(_ day: Int, _ list: [String]) -> ASPToolDiagnosticsSnapshot {
            ASPToolDiagnosticsSnapshot(capturedAt: Self.date(day: day), deviceID: "d", hostWrites: UInt64(day),
                                       parseWarnings: list)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for day in 1...3 {
            data.append(try encoder.encode(record(day, warnings)))
            data.append(0x0A)
        }
        try data.write(to: fileURL)

        let store = ASPToolSnapshotStore(fileURL: fileURL)
        _ = try await store.appendIfNew(record(4, warnings))
        _ = try await store.appendIfNew(record(5, ["別の説明文（共有しない）"]))
        let records = try await store.records()
        func address(_ list: [String]) -> UnsafeRawPointer? {
            list.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        }
        let shared = Set(records.prefix(4).map { address($0.parseWarnings) })
        XCTAssertEqual(shared.count, 1, "equal lists share one buffer")
        XCTAssertEqual(records.prefix(4).map(\.parseWarnings), Array(repeating: warnings, count: 4))
        XCTAssertEqual(records.last?.parseWarnings, ["別の説明文（共有しない）"])

        // The append tail remains independently readable, including its
        // versioned envelopes. Sealed blocks share equal fields on disk.
        let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        let decoded = try lines.flatMap { try LosslessHistoryBlock.decode(Data($0.utf8), as: ASPToolDiagnosticsSnapshot.self) }
        XCTAssertEqual(decoded.map(\.parseWarnings), records.map(\.parseWarnings))
    }

    func testASPToolSnapshotStoreThinsByAgeAndKeepsBoundaries() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPToolAge-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let start = Self.date(day: 1)
        let step: TimeInterval = 30 * 60
        let count = 60 * 48
        let firmwareChange = 20 * 48
        let decrease = 10 * 48
        let routeChange = 5 * 48
        var host: UInt64 = 1_000
        var records: [ASPToolDiagnosticsSnapshot] = []
        for index in 0..<count {
            host += index == decrease ? 0 : 7
            records.append(ASPToolDiagnosticsSnapshot(
                capturedAt: start.addingTimeInterval(Double(index) * step),
                deviceID: "drive",
                sourceArtifact: index == routeChange ? .extractedASPTool : .directFTL,
                hostWrites: index == decrease ? 10 : host,
                firmware: index < firmwareChange ? "FW-A" : "FW-B"
            ))
        }
        // Most records are already on disk; the default limit is far away,
        // so thinning must run on the append count.
        let appended = ASPToolSnapshotStore.compactionInterval
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records.dropLast(appended) {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: fileURL)
        let store = ASPToolSnapshotStore(fileURL: fileURL, preservesAllMeasurements: false)
        for record in records.suffix(appended) {
            _ = try await store.appendIfNew(record)
        }
        let retained = try await store.records()
        let retainedIDs = Set(retained.map(\.id))
        let newest = records.last!.capturedAt
        XCTAssertLessThan(retained.count, records.count, "old records are thinned without reaching the limit")

        // Every record of the last 35 days stays.
        let recent = records.filter { newest.timeIntervalSince($0.capturedAt) <= ASPToolSnapshotStore.fullResolutionWindow }
        XCTAssertTrue(recent.allSatisfy { retainedIDs.contains($0.id) })
        // Older ones keep about one per hour (two 30-minute samples per bucket).
        let old = records.filter { !recent.contains($0) }
        let unprotectedOld = old.filter {
            abs($0.capturedAt.timeIntervalSince(records[firmwareChange].capturedAt)) > 9 * 86_400
        }
        let keptUnprotected = unprotectedOld.filter { retainedIDs.contains($0.id) }.count
        XCTAssertEqual(Double(keptUnprotected), Double(unprotectedOld.count) / 2, accuracy: 8)

        // Around the firmware change everything stays; a counter decrease
        // and a route change keep both sides.
        let firmwareWindow = records.filter {
            let offset = $0.capturedAt.timeIntervalSince(records[firmwareChange].capturedAt)
            return offset >= -7 * 86_400 && offset <= 72 * 3_600
        }
        XCTAssertTrue(firmwareWindow.allSatisfy { retainedIDs.contains($0.id) })
        for index in [decrease - 1, decrease, routeChange - 1, routeChange, routeChange + 1] {
            XCTAssertTrue(retainedIDs.contains(records[index].id), "boundary record \(index)")
        }
        XCTAssertEqual(retained.first?.id, records.first?.id)
        XCTAssertEqual(retained.last?.id, records.last?.id)
    }

    func testASPToolSnapshotStorePreservesFirstSnapshotOfEachFTLSeries() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingASPToolSeries-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let topology = DirectFTLTopology(
            contractVersion: DirectFTLResearchContract.latest,
            numVirtualBlocks: 10,
            intermediatePartitionStart: 1,
            userPartitionStart: 3,
            bytesPerPage: 4_096,
            pagesPerVirtualBlock: 2,
            pagesPerVirtualBlockSLC: 1
        )
        func record(_ day: Int, firmware: String, host: UInt64) -> ASPToolDiagnosticsSnapshot {
            ASPToolDiagnosticsSnapshot(
                capturedAt: Self.date(day: day),
                captureQuality: .explicit,
                deviceID: "drive-series",
                sourceArtifact: .directFTL,
                sourceBuild: DirectFTLResearchContract.reviewedBuild,
                extractionVersion: 2,
                historySchemaVersion: 2,
                semanticContractVersion: DirectFTLResearchContract.latest,
                hostWrites: host,
                nandWrites: host * 2,
                hostWritesUnitState: .provisional4KiB,
                nandWritesUnitState: .provisional4KiB,
                tlcAveragePE: Double(host),
                tlcEOLPE: 3_000,
                slcAveragePE: Double(host),
                slcEOLPE: 100_000,
                firmware: firmware,
                directFormatVersion: 1,
                directKeyContractVersion: DirectFTLResearchContract.latest,
                directTopology: topology
            )
        }

        let records = [
            record(1, firmware: "FW-A", host: 1),
            record(2, firmware: "FW-A", host: 2),
            record(3, firmware: "FW-A", host: 3),
            record(4, firmware: "FW-B", host: 4),
            record(5, firmware: "FW-B", host: 5),
            record(6, firmware: "FW-B", host: 6)
        ]
        let store = ASPToolSnapshotStore(fileURL: fileURL, maximumRecordCount: 4, preservesAllMeasurements: false)
        for record in records {
            let appended = try await store.appendIfNew(record)
            XCTAssertTrue(appended)
        }

        let retained = try await store.records()
        XCTAssertEqual(retained.count, 4)
        XCTAssertTrue(retained.contains { $0.id == records[0].id }, "FW-Aの系列先頭を保持")
        XCTAssertTrue(retained.contains { $0.id == records[3].id }, "FW-Bの系列先頭を保持")
        XCTAssertTrue(retained.contains { $0.id == records[5].id }, "最新snapshotを保持")
    }

    func testParserReadsLogicalCapacityFromSmartctlUserCapacity() throws {
        let parser = SmartctlJSONParser()
        let snapshot = try parser.parse(
            data: Data("""
            {
              "model_name": "Test NVMe",
              "user_capacity": {"bytes": 256000000000},
              "percentage_used": 4
            }
            """.utf8),
            capturedAt: Self.date(day: 1),
            devicePath: "/dev/rdisk0"
        )

        XCTAssertEqual(snapshot.logicalCapacityBytes, 256_000_000_000)
    }

    func testParserStableIdentityDoesNotContainDevicePathWhenSerialIsMissing() throws {
        let parser = SmartctlJSONParser()
        let first = try parser.parse(
            data: Data(Self.basicFixture.utf8),
            capturedAt: Self.date(day: 1),
            devicePath: "/dev/rdisk0"
        )
        let second = try parser.parse(
            data: Data(Self.basicFixture.utf8),
            capturedAt: Self.date(day: 2),
            devicePath: "/dev/rdisk4"
        )

        XCTAssertEqual(first.deviceID, second.deviceID)
        XCTAssertFalse(first.deviceID.contains("path:"))
        XCTAssertEqual(first.deviceID, "model:APPLE SSD AP0256Q")
    }

    func testTemperatureParserReadsLightweightTemperaturePayload() throws {
        let parser = SmartctlJSONParser()
        let temperature = try parser.parseTemperature(data: Data(Self.healthFixture.utf8))

        XCTAssertEqual(temperature, 54)
    }

    func testDashboardAnalyticsUsesIndependentTemperatureHistory() {
        let snapshot = makeSnapshot(
            day: 40,
            written: 1_100,
            powerHours: 20,
            capturedAt: Self.date(day: 40)
        )
        let temperatureSample = TemperatureSample(
            capturedAt: Self.date(day: 40).addingTimeInterval(30),
            deviceID: snapshot.deviceID,
            temperatureCelsius: 58
        )
        let analytics = DashboardAnalyticsSnapshot.build(
            analyzer: HistoryAnalyzer(calendar: Self.fixedCalendar),
            history: [snapshot],
            temperatureHistory: [temperatureSample],
            deviceID: snapshot.deviceID,
            period: .day,
            profile: nil,
            settings: UsageSettings(),
            now: temperatureSample.capturedAt
        )

        XCTAssertEqual(analytics.temperaturePoints.map(\.celsius), [58])
    }

    func testValueFormatterShowsYearForUsageStartDate() {
        // Dates are shown in the Mac's time zone, so use local noon: a UTC
        // time falls on the previous day west of UTC.
        let date = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 12))!

        XCTAssertEqual(ValueFormatter.fullDate(date), "2025/01/02")
    }

    func testValueFormatterUsesPetabytesForLargeForecasts() {
        XCTAssertTrue(ValueFormatter.bytes(1_900_000_000_000_000).contains("PB"))
        XCTAssertEqual(ValueFormatter.bytes(1_001_514_701_160_448, zeroPadded: true), "1.00 PB")
        // Past Int64.max: Double(Int64.max) rounds up to 2^63, which Int64 cannot hold.
        XCTAssertTrue(ValueFormatter.bytes(3.4e19).contains("PB"))
    }

    func testForecastsRecoverOnceHistoryContinuesAfterACounterReset() {
        let analyzer = HistoryAnalyzer(calendar: Self.fixedCalendar)
        // Power-on hours step back once on day 2, then 40 normal days follow.
        var history = [makeSnapshot(day: 1, written: 1_000_000, powerHours: 1_200),
                       makeSnapshot(day: 2, written: 1_000_100, powerHours: 1_199)]
        for day in 3...42 {
            history.append(makeSnapshot(day: day, written: 1_000_100 + UInt64(day) * 100,
                                        powerHours: 1_199 + UInt64(day) * 24))
        }
        let now = history.last!.capturedAt
        XCTAssertNotNil(analyzer.peerTBWForecast(from: history, deviceID: nil, profile: nil,
                                                 historicalRate: nil, now: now))
        XCTAssertNotEqual(analyzer.enduranceForecast(from: history, deviceID: nil, now: now).basis, "counter reset")

        // Right after the reset there is nothing to measure from yet.
        let justReset = Array(history.prefix(2))
        XCTAssertEqual(analyzer.enduranceForecast(from: justReset, deviceID: nil, now: justReset[1].capturedAt).basis,
                       "counter reset")
    }

    func testFirmwarePointUpdateDoesNotLowerForecastConfidence() {
        let analyzer = HistoryAnalyzer(calendar: Self.fixedCalendar)
        func forecast(_ before: String, _ after: String) -> EnduranceForecast {
            let history = (1...120).map { day in
                makeSnapshot(day: day, written: 1_000_000 + UInt64(day) * 10_000,
                             percentage: 5 + UInt64(day / 30), powerHours: 1_000 + UInt64(day) * 24,
                             firmware: day < 100 ? before : after)
            }
            return analyzer.enduranceForecast(from: history, deviceID: nil, now: history.last!.capturedAt)
        }
        let unchanged = forecast("591", "591")
        XCTAssertEqual(forecast("591", "591.40.3").confidenceScore, unchanged.confidenceScore)
        XCTAssertLessThan(forecast("561.100.", "591").confidenceScore, unchanged.confidenceScore)
    }

    func testOneLowWriteCounterReadingIsNotAResetOrABurstOfWrites() {
        let analyzer = HistoryAnalyzer(calendar: Self.fixedCalendar)
        // 100 units a day; on day 25 one read returns a far lower value.
        let history = (1...30).map { day in
            makeSnapshot(day: day, written: day == 25 ? 5 : 1_000_000 + UInt64(day) * 100,
                         powerHours: 1_000 + UInt64(day) * 24)
        }
        let now = history.last!.capturedAt
        let rates = analyzer.writeRateSummary(from: history, deviceID: nil)
        XCTAssertEqual(rates.sevenDayBytesPerDay ?? 0, 100 * 512_000, accuracy: 1)
        XCTAssertNotNil(analyzer.peerTBWForecast(from: history, deviceID: nil, profile: nil,
                                                 historicalRate: nil, now: now))
        XCTAssertNotEqual(analyzer.enduranceForecast(from: history, deviceID: nil, now: now).basis, "counter reset")
    }

    func testAnalyzerAggregatesPositiveWriteDeltasByDay() {
        let first = makeSnapshot(day: 1, written: 100, powerHours: 10)
        let second = makeSnapshot(day: 2, written: 110, powerHours: 11)
        let third = makeSnapshot(day: 3, written: 130, powerHours: 12)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let points = analyzer.writePoints(
            from: [first, second, third],
            deviceID: first.deviceID,
            period: .day,
            now: Self.date(day: 3)
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].bytes, 10 * 512_000)
        XCTAssertEqual(points[1].bytes, 20 * 512_000)
    }

    func testAnalyzerDoesNotCreateNegativeDeltaAcrossCounterReset() {
        let first = makeSnapshot(day: 1, written: 100, powerHours: 10)
        let second = makeSnapshot(day: 2, written: 150, powerHours: 11)
        let reset = makeSnapshot(day: 3, written: 20, powerHours: 12)
        let afterReset = makeSnapshot(day: 4, written: 30, powerHours: 13)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let points = analyzer.writePoints(
            from: [first, second, reset, afterReset],
            deviceID: first.deviceID,
            period: .day,
            now: Self.date(day: 4)
        )

        XCTAssertEqual(points.map(\.bytes), [Double(50 * 512_000), Double(10 * 512_000)])
        XCTAssertTrue(points.allSatisfy { $0.bytes >= 0 })
    }

    func testAnalyzerProvidesHourlyBucketsAndMarksLongGaps() {
        let start = Self.date(day: 10)
        let first = makeSnapshot(day: 10, written: 100, powerHours: 10, capturedAt: start)
        let second = makeSnapshot(
            day: 10,
            written: 160,
            powerHours: 12,
            capturedAt: start.addingTimeInterval(3 * 3_600)
        )
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let points = analyzer.writePoints(
            from: [first, second],
            deviceID: first.deviceID,
            period: .hour,
            now: second.capturedAt
        )

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.reduce(0) { $0 + $1.bytes }, 60 * 512_000, accuracy: 0.1)
        XCTAssertTrue(points.allSatisfy(\.containsSpanningDelta))
        XCTAssertTrue(points.allSatisfy(\.isPartial))
    }

    func testRetentionPlanningUsesCapacityScaledDWPDScenario() {
        let first = makeSnapshot(day: 1, written: 110_000_000, percentage: 5, powerHours: 10)
        let latest = makeSnapshot(day: 11, written: 120_000_000, percentage: 5, powerHours: 20)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let estimate = analyzer.retentionPlanningEstimate(
            from: [first, latest],
            deviceID: first.deviceID,
            now: latest.capturedAt
        )

        guard let estimate else {
            return XCTFail("十分な書き込み履歴があれば保守シナリオを算出できるべきです")
        }

        let planningDays = RetentionPlanningEstimate.planningYears * RetentionPlanningEstimate.daysPerYear
        let expectedLower = 256_000_000_000.0 * RetentionPlanningEstimate.lowerPlanningDWPD * planningDays
        let expectedUpper = 256_000_000_000.0 * RetentionPlanningEstimate.upperPlanningDWPD * planningDays
        XCTAssertEqual(estimate.capacityBytes, 256_000_000_000)
        XCTAssertEqual(estimate.lowerPlanningDWPD, 0.3)
        XCTAssertEqual(estimate.upperPlanningDWPD, 0.6)
        XCTAssertEqual(estimate.thresholdLowerBytes, expectedLower, accuracy: 0.1)
        XCTAssertEqual(estimate.thresholdUpperBytes, expectedUpper, accuracy: 0.1)
        XCTAssertEqual(estimate.currentHostWrittenBytes, 120_000_000 * 512_000)
        XCTAssertEqual(estimate.rateBytesPerDay, 512_000_000_000, accuracy: 0.1)
        XCTAssertEqual(
            estimate.remainingLowerBytes,
            expectedLower - 120_000_000 * 512_000,
            accuracy: 0.1
        )
        XCTAssertEqual(
            estimate.remainingUpperBytes,
            expectedUpper - 120_000_000 * 512_000,
            accuracy: 0.1
        )
        XCTAssertEqual(estimate.referenceDate, latest.capturedAt)
        XCTAssertNotNil(estimate.lowerDate)
        XCTAssertNotNil(estimate.upperDate)
        XCTAssertFalse(estimate.thresholdAlreadyReached)
        XCTAssertTrue(estimate.basis.contains("0.3–0.6 DWPD"))
    }

    func testRetentionPlanningFallsBackToUsageStartAverageWhenNoDeltaExists() {
        let latest = makeSnapshot(
            day: 365,
            written: 10_000,
            percentage: 10,
            powerHours: 2_400
        )
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)
        let fallbackRate = Double(10_000 * 512_000) / 100

        let estimate = analyzer.retentionPlanningEstimate(
            from: [latest],
            deviceID: latest.deviceID,
            fallbackRateBytesPerDay: fallbackRate,
            now: latest.capturedAt
        )

        guard let estimate else {
            return XCTFail("使用開始日ベースの日次レートがあれば保守シナリオを算出できるべきです")
        }

        XCTAssertEqual(estimate.rateBytesPerDay, fallbackRate, accuracy: 0.1)
        XCTAssertTrue(estimate.basis.contains("Usage-start average"))
        XCTAssertNotNil(estimate.lowerDate)
    }

    func testRetentionPlanningStopsAfterCounterReset() {
        let first = makeSnapshot(day: 1, written: 10_000, percentage: 5, powerHours: 10)
        let reset = makeSnapshot(day: 2, written: 100, percentage: 5, powerHours: 1)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let estimate = analyzer.retentionPlanningEstimate(
            from: [first, reset],
            deviceID: first.deviceID,
            fallbackRateBytesPerDay: 50_000_000_000,
            now: reset.capturedAt
        )

        XCTAssertNil(estimate)
    }

    func testAnalyzerSplitsShortHourlyDeltaAcrossCalendarBoundary() {
        let start = Self.date(day: 10).addingTimeInterval(45 * 60)
        let first = makeSnapshot(day: 10, written: 100, powerHours: 10, capturedAt: start)
        let second = makeSnapshot(
            day: 10,
            written: 140,
            powerHours: 10,
            capturedAt: start.addingTimeInterval(30 * 60)
        )
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let points = analyzer.writePoints(
            from: [first, second],
            deviceID: first.deviceID,
            period: .hour,
            now: second.capturedAt
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.reduce(0) { $0 + $1.bytes }, 40 * 512_000, accuracy: 0.1)
        XCTAssertEqual(points[0].bytes, 20 * 512_000, accuracy: 0.1)
        XCTAssertEqual(points[1].bytes, 20 * 512_000, accuracy: 0.1)
    }

    func testWearTransitionsKeepIntervalsAndExcludeFirstLeftCensoredStep() {
        let first = makeSnapshot(day: 1, written: 1_000, percentage: 5, powerHours: 10)
        let second = makeSnapshot(day: 11, written: 1_100, percentage: 6, powerHours: 20)
        let third = makeSnapshot(day: 21, written: 1_200, percentage: 7, powerHours: 30)
        let fourth = makeSnapshot(day: 31, written: 1_300, percentage: 8, powerHours: 40)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let transitions = analyzer.wearTransitions(
            from: [first, second, third, fourth],
            deviceID: first.deviceID
        )

        XCTAssertEqual(transitions.count, 3)
        XCTAssertTrue(transitions[0].isLeftCensored)
        XCTAssertFalse(transitions[1].isLeftCensored)
        XCTAssertEqual(transitions[1].percentageDelta, 1)
        XCTAssertEqual(transitions[1].previousDataUnitsWritten, 1_100)
        XCTAssertEqual(transitions[1].detectedDataUnitsWritten, 1_200)
        XCTAssertEqual(transitions[1].hostWrittenBytesPerPercentage, 100 * 512_000)
    }

    func testEnduranceForecastUsesRobustTransitionsAndReportsHostWriteRange() {
        let samples = [
            makeSnapshot(day: 1, written: 1_000, percentage: 5, powerHours: 10),
            makeSnapshot(day: 11, written: 1_100, percentage: 6, powerHours: 20),
            makeSnapshot(day: 21, written: 1_200, percentage: 7, powerHours: 30),
            makeSnapshot(day: 31, written: 1_310, percentage: 8, powerHours: 40),
            makeSnapshot(day: 41, written: 1_410, percentage: 9, powerHours: 50)
        ]
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)
        let forecast = analyzer.enduranceForecast(
            from: samples,
            deviceID: samples[0].deviceID,
            now: samples.last!.capturedAt
        )

        XCTAssertEqual(forecast.state, .estimated)
        XCTAssertEqual(forecast.transitionCount, 3)
        XCTAssertEqual(forecast.currentPercentage, 9)
        XCTAssertNotNil(forecast.estimatedEnduranceBytes)
        XCTAssertNotNil(forecast.remainingHostWriteBytes)
        XCTAssertNotNil(forecast.lowerDate)
        XCTAssertNotNil(forecast.upperDate)
        XCTAssertNotNil(forecast.currentWorkloadLowerDate)
        XCTAssertNotNil(forecast.currentWorkloadUpperDate)
        XCTAssertNotNil(forecast.typicalWorkloadLowerDate)
        XCTAssertNotNil(forecast.typicalWorkloadUpperDate)
        XCTAssertNotNil(forecast.writeRates.sevenDayBytesPerDay)
        XCTAssertLessThanOrEqual(forecast.enduranceRangeLowerBytes!, forecast.estimatedEnduranceBytes!)
        XCTAssertLessThanOrEqual(forecast.estimatedEnduranceBytes!, forecast.enduranceRangeUpperBytes!)
    }

    func testEnduranceForecastDoesNotUseIORegistryGeometryAsALifeMultiplier() {
        let samples = [
            makeSnapshot(day: 1, written: 1_000, percentage: 5, powerHours: 10),
            makeSnapshot(day: 11, written: 1_100, percentage: 6, powerHours: 20),
            makeSnapshot(day: 21, written: 1_200, percentage: 7, powerHours: 30),
            makeSnapshot(day: 31, written: 1_310, percentage: 8, powerHours: 40),
            makeSnapshot(day: 41, written: 1_410, percentage: 9, powerHours: 50)
        ]
        let profile = AppleNANDHardwareProfile(
            nandVendor: "Hynix",
            nandMarketingName: "fixture",
            defaultBitsPerCell: 3,
            packageBlocksAtEOL: 1
        )
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)
        let withoutProfile = analyzer.enduranceForecast(
            from: samples,
            deviceID: samples[0].deviceID,
            now: samples.last!.capturedAt
        )
        let withProfile = analyzer.enduranceForecast(
            from: samples,
            deviceID: samples[0].deviceID,
            profile: profile,
            now: samples.last!.capturedAt
        )

        XCTAssertEqual(withProfile.estimatedEnduranceBytes, withoutProfile.estimatedEnduranceBytes)
        XCTAssertEqual(withProfile.enduranceRangeLowerBytes, withoutProfile.enduranceRangeLowerBytes)
        XCTAssertEqual(withProfile.enduranceRangeUpperBytes, withoutProfile.enduranceRangeUpperBytes)
    }

    func testEnduranceForecastUsesQuantizedLowConfidenceFallback() {
        let snapshot = makeSnapshot(day: 100, written: 10_000, percentage: 5, powerHours: 100)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let forecast = analyzer.enduranceForecast(
            from: [snapshot],
            deviceID: snapshot.deviceID,
            now: snapshot.capturedAt
        )

        XCTAssertEqual(forecast.state, .estimated)
        XCTAssertEqual(forecast.confidence, .veryLow)
        XCTAssertNil(forecast.lowerDate)
        XCTAssertGreaterThan(forecast.enduranceRangeUpperBytes!, forecast.enduranceRangeLowerBytes!)
        XCTAssertTrue(forecast.basis.contains("フォールバック"))
    }

    func testEnduranceForecastUsesReferenceTBWAtPUZeroOrOne() throws {
        let snapshot = makeSnapshot(day: 100, written: 10_000, percentage: 1, powerHours: 100)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let forecast = analyzer.enduranceForecast(
            from: [snapshot],
            deviceID: snapshot.deviceID,
            now: snapshot.capturedAt
        )

        // Unknown NAND, 256 GB: 600 TBW/TB -> 153.6 TB reference total.
        let reference = try XCTUnwrap(forecast.referenceTBW)
        XCTAssertEqual(reference.tbwPerTB, ReferenceTBW.defaultTBWPerTB)
        XCTAssertEqual(try XCTUnwrap(forecast.estimatedEnduranceBytes), 600 * 256e9, accuracy: 1)
        XCTAssertTrue(forecast.basis.contains("参考TBW"))
    }

    func testEnduranceForecastWaitsAtPUZeroOrOneWithoutCapacity() {
        let snapshot = makeSnapshot(day: 100, written: 10_000, percentage: 1, powerHours: 100, logicalCapacityBytes: nil)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let forecast = analyzer.enduranceForecast(
            from: [snapshot],
            deviceID: snapshot.deviceID,
            now: snapshot.capturedAt
        )

        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertNil(forecast.referenceTBW)
        XCTAssertNil(forecast.lowerDate)
    }

    func testEnduranceForecastDisablesLifetimeFallbackAfterCounterReset() {
        let first = makeSnapshot(day: 1, written: 10_000, percentage: 5, powerHours: 100)
        let reset = makeSnapshot(day: 2, written: 10, percentage: 5, powerHours: 1)
        let latest = makeSnapshot(day: 40, written: 100, percentage: 6, powerHours: 20)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let forecast = analyzer.enduranceForecast(
            from: [first, reset, latest],
            deviceID: first.deviceID,
            now: latest.capturedAt
        )

        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertTrue(forecast.message.contains("リセット"))
        XCTAssertNil(forecast.lowerDate)
    }

    func testIORegistryParserReadsAllowListedProfileAndGeometry() throws {
        let parser = IORegistryProfileParser()
        let profile = try XCTUnwrap(
            try parser.parse(data: Data(Self.ioregFixture.utf8), modelNumber: "APPLE SSD AP0256Q")
        )

        XCTAssertEqual(profile.controllerClass, "AppleANS3NVMeController")
        XCTAssertEqual(profile.logicalCapacityBytes, 256_000_000_000)
        XCTAssertEqual(profile.nandVendor, "Hynix")
        XCTAssertEqual(profile.nandMarketingName, "tlc_3d_v6_4p_512")
        XCTAssertEqual(profile.pagesPerBlockNative, 1_536)
        XCTAssertEqual(profile.pagesPerBlockSLC, 512)
        XCTAssertEqual(profile.diesPerBus, [1, 1, 1, 1])
        XCTAssertEqual(profile.geometryConfidence, .consistent)
        XCTAssertEqual(profile.geometrySectorSizeBytes, 4_096)
        XCTAssertEqual(profile.packageBlocksAtEOL, 10_976)
        XCTAssertEqual(profile.dieCount, 4)
        XCTAssertEqual(profile.concurrentUnitCount, 16)
        XCTAssertEqual(profile.totalBlocks, 11_552)
        XCTAssertEqual(profile.nativeToSLCPageRatio, 3)
        XCTAssertEqual(profile.eolGeometryRatio!, 10_976.0 / 11_552.0, accuracy: 0.000_001)
    }

    func testCapacityProfileShowsFinderAvailableSpaceAndKeepsUnusedSpace() throws {
        var snapshot = makeSnapshot(day: 1, written: 100_000, percentage: 4, powerHours: 100)
        snapshot.filesystemTotalCapacityBytes = 245_100_000_000
        snapshot.filesystemFreeBytes = 19_500_000_000
        snapshot.filesystemAvailableBytes = 38_400_000_000
        let capacity = SSDCapacityProfile(snapshot: snapshot, hardwareProfile: nil)
        // Finder's value is displayed; the purgeable part is shown apart.
        XCTAssertEqual(capacity.displayedFreeBytes, 38_400_000_000)
        XCTAssertEqual(capacity.displayedFreeRatio!, 38.4 / 245.1, accuracy: 0.000_001)
        XCTAssertEqual(capacity.purgeableBytes, 18_900_000_000)
        // Space not used by any file stays the input for analyses.
        XCTAssertEqual(capacity.filesystemFreeRatio!, 19.5 / 245.1, accuracy: 0.000_001)
        // The rating follows the displayed value: 15.7% is not "limited"
        // although the unused space alone is 8%.
        XCTAssertNotEqual(capacity.headroomRating, .limited)
        var tight = snapshot
        tight.filesystemAvailableBytes = 24_000_000_000
        XCTAssertEqual(SSDCapacityProfile(snapshot: tight, hardwareProfile: nil).headroomRating, .limited)

        // Records saved before the field existed still decode and display.
        var legacy = snapshot
        legacy.filesystemAvailableBytes = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "filesystemAvailableBytes")
        let decoded = try decoder.decode(DriveSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let legacyCapacity = SSDCapacityProfile(snapshot: decoded, hardwareProfile: nil)
        XCTAssertEqual(legacyCapacity.displayedFreeBytes, 19_500_000_000)
        XCTAssertNil(legacyCapacity.purgeableBytes)
    }

    func testCapacityProfileSeparatesLogicalFreePhysicalAndEOLValues() throws {
        let parser = IORegistryProfileParser()
        let profile = try XCTUnwrap(
            try parser.parse(data: Data(Self.ioregFixture.utf8), modelNumber: "APPLE SSD AP0256Q")
        )
        var snapshot = makeSnapshot(day: 1, written: 100_000, percentage: 4, powerHours: 100)
        snapshot.logicalCapacityBytes = 256_000_000_000
        snapshot.filesystemTotalCapacityBytes = 512_000_000_000
        snapshot.filesystemFreeBytes = 287_000_000_000

        let capacity = SSDCapacityProfile(snapshot: snapshot, hardwareProfile: profile)
        let expectedGeometry = UInt64(16) * 722 * 1_536 * 16_384

        XCTAssertEqual(profile.geometryCapacityBytes, expectedGeometry)
        XCTAssertEqual(capacity.logicalCapacityBytes, 256_000_000_000)
        XCTAssertEqual(capacity.geometryCapacityBytes, expectedGeometry)
        XCTAssertEqual(
            capacity.hiddenPhysicalMarginBytes,
            expectedGeometry - 256_000_000_000
        )
        XCTAssertEqual(
            capacity.hiddenPhysicalMarginRatio!,
            Double(expectedGeometry - 256_000_000_000) / Double(expectedGeometry),
            accuracy: 0.000_001
        )
        XCTAssertEqual(capacity.filesystemFreeBytes, 287_000_000_000)
        XCTAssertEqual(capacity.filesystemFreeRatio!, 287.0 / 512.0, accuracy: 0.000_001)
        XCTAssertEqual(capacity.totalGeometryBlocks, 11_552)
        XCTAssertEqual(capacity.packageBlocksAtEOL, 10_976)
        XCTAssertEqual(capacity.eolBlockAllowance, 576)
        XCTAssertEqual(capacity.headroomRating, .excellent)
    }

    func testFilesystemFreeSamplesAreMatchedOnceAcrossSortedWAFIntervals() {
        let start = Self.date(day: 1)
        let intervals = [
            DateInterval(start: start, end: start.addingTimeInterval(100)),
            DateInterval(start: start.addingTimeInterval(100), end: start.addingTimeInterval(200)),
            DateInterval(start: start.addingTimeInterval(300), end: start.addingTimeInterval(400))
        ]
        let samples = [-1.0, 0, 50, 100, 150, 200, 250, 300, 400, 401].map { offset -> DriveSnapshot in
            var sample = makeSnapshot(
                day: 1,
                written: 100,
                powerHours: 10,
                capturedAt: start.addingTimeInterval(offset)
            )
            sample.filesystemFreeBytes = 1_000
            return sample
        }
        let expected = samples.filter { sample in
            intervals.contains { $0.contains(sample.capturedAt) }
        }
        let matched = RetentionWAFAnalyzer.filesystemSamples(
            in: samples.sorted { $0.capturedAt < $1.capturedAt },
            coveredBy: intervals
        )

        XCTAssertEqual(matched.map(\.id), expected.map(\.id))
        XCTAssertEqual(Set(matched.map(\.id)).count, matched.count, "A boundary sample must not be counted twice")
    }

    func testIORegistryParserReturnsNilWhenControllerProfileIsMissing() throws {
        let parser = IORegistryProfileParser()
        XCTAssertNil(try parser.parse(data: Data("| | \\\"IOClass\\\" = \\\"OtherController\\\"".utf8), modelNumber: "Test"))
    }

    func testAnalyzerDoesNotBridgeTwoDeviceIdentitiesWhenFilterIsNil() {
        let first = makeSnapshot(day: 1, written: 1_000, percentage: 5, powerHours: 10)
        let second = makeSnapshot(
            day: 2,
            written: 1_100,
            percentage: 6,
            powerHours: 11,
            deviceID: "serial:other-drive",
            serialNumber: "other-drive"
        )
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        XCTAssertTrue(analyzer.wearTransitions(from: [first, second], deviceID: nil).isEmpty)
        let forecast = analyzer.enduranceForecast(from: [first, second], deviceID: nil, now: second.capturedAt)
        XCTAssertEqual(forecast.state, .collecting)
        XCTAssertNil(forecast.lowerDate)
    }

    func testLifeEstimateWaitsForObservedHealthAndCounterHistory() {
        let first = makeSnapshot(day: 1, written: 1_000, percentage: 5, powerHours: 100)
        let second = makeSnapshot(day: 41, written: 1_200, percentage: 10, powerHours: 130)
        let third = makeSnapshot(day: 81, written: 1_500, percentage: 15, powerHours: 160)
        let fourth = makeSnapshot(day: 121, written: 1_700, percentage: 20, powerHours: 190)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let estimate = analyzer.lifeEstimate(
            from: [first, second, third, fourth],
            deviceID: first.deviceID,
            now: Self.date(day: 121)
        )

        guard case let .estimated(lowerDate, upperDate, confidence, remaining, dailyRate, powerRate) = estimate else {
            return XCTFail("十分な履歴があれば推定レンジを返すべきです: \(estimate)")
        }
        XCTAssertLessThan(lowerDate, upperDate)
        XCTAssertEqual(confidence, .medium)
        XCTAssertEqual(remaining, 80)
        XCTAssertNotNil(dailyRate)
        XCTAssertNotNil(powerRate)
    }

    func testLifeEstimateIsCollectingWhenCountersAreMissing() {
        let first = makeSnapshot(day: 1, written: nil, percentage: 5, powerHours: nil)
        let second = makeSnapshot(day: 41, written: nil, percentage: 10, powerHours: nil)
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let estimate = analyzer.lifeEstimate(
            from: [first, second],
            deviceID: first.deviceID,
            now: Self.date(day: 41)
        )

        guard case .collecting = estimate else {
            return XCTFail("書き込み量と稼働時間が無い場合は推定を保留すべきです")
        }
    }

    func testWriteBasedProjectionUsesPowerOnHoursAsApproximateStart() {
        let latestDate = Self.date(day: 365)
        let latest = makeSnapshot(
            day: 365,
            written: 10_000,
            percentage: 10,
            powerHours: 2_400,
            capturedAt: latestDate
        )
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let projection = analyzer.writeBasedLifeProjection(
            from: [latest],
            deviceID: latest.deviceID
        )

        guard let projection else {
            return XCTFail("Power On Hours と累積書き込み量から概算できるべきです")
        }
        XCTAssertEqual(projection.usageStart.source, .powerOnHours)
        XCTAssertEqual(projection.elapsedDays, 100, accuracy: 0.001)
        XCTAssertEqual(projection.observedWrittenBytes, 10_000 * 512_000, accuracy: 0.1)
        XCTAssertEqual(projection.averageDailyWriteRateBytes, 10_000 * 512_000 / 100, accuracy: 0.1)
        XCTAssertEqual(projection.remainingPercent, 90, accuracy: 0.001)
        XCTAssertLessThan(projection.lowerDate, projection.upperDate)
    }

    func testWriteBasedProjectionPrefersReportedStartDate() {
        let latest = makeSnapshot(
            day: 365,
            written: 10_000,
            percentage: 10,
            powerHours: 24,
            capturedAt: Self.date(day: 365),
            usageStartDate: Self.date(day: 1)
        )
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let projection = analyzer.writeBasedLifeProjection(
            from: [latest],
            deviceID: latest.deviceID
        )

        XCTAssertEqual(projection?.usageStart.source, .reported)
        guard let elapsedDays = projection?.elapsedDays else {
            return XCTFail("報告された使用開始日から経過日数を計算できるべきです")
        }
        XCTAssertEqual(elapsedDays, 364, accuracy: 0.001)
    }

    func testWriteBasedProjectionPrefersManualStartDate() {
        let latest = makeSnapshot(
            day: 365,
            written: 10_000,
            percentage: 10,
            powerHours: 2_400,
            capturedAt: Self.date(day: 365),
            usageStartDate: Self.date(day: 1)
        )
        let settings = UsageSettings(manualStartDate: Self.date(day: 100))
        let analyzer = HistoryAnalyzer(calendar: fixedCalendar)

        let projection = analyzer.writeBasedLifeProjection(
            from: [latest],
            deviceID: latest.deviceID,
            settings: settings
        )

        guard let projection else {
            return XCTFail("手動の使用開始日から概算できるべきです")
        }
        XCTAssertEqual(projection.usageStart.source, .manual)
        XCTAssertEqual(projection.elapsedDays, 265, accuracy: 0.001)
    }


    func testUsageSettingsStoreRoundTripsPerDeviceAndCanReset() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingSettings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = UsageSettingsStore(fileURL: fileURL)
        let settings = UsageSettings(
            manualStartDate: Self.date(day: 10),
            proxyAllowableTLCPE: 2_500,
            proxyAllowablePSLCPE: 90_000
        )

        try await store.save(settings, for: "serial:drive-a")
        let loadedSettings = try await store.settings(for: "serial:drive-a")
        let otherSettings = try await store.settings(for: "serial:drive-b")
        XCTAssertEqual(loadedSettings, settings)
        XCTAssertEqual(otherSettings, UsageSettings())

        try await store.save(UsageSettings(), for: "serial:drive-a")
        let resetSettings = try await store.settings(for: "serial:drive-a")
        XCTAssertEqual(resetSettings, UsageSettings())
    }

    func testHistoryStoreMigratesPathIdentityToStableModelCapacityIdentity() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingIdentityMigration-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let legacyID = DeviceIdentity.legacyPathID(model: "Test NVMe", devicePath: "/dev/rdisk0")
        let legacySnapshot = makeSnapshot(
            day: 1,
            written: 100,
            powerHours: 10,
            deviceID: legacyID,
            serialNumber: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacySnapshot).write(to: fileURL)

        let records = try await HistoryStore(fileURL: fileURL).records()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            records.first?.deviceID,
            DeviceIdentity.stableID(
                serialNumber: nil,
                model: "Test NVMe",
                logicalCapacityBytes: 256_000_000_000
            )
        )
        XCTAssertFalse(records.first?.deviceID.contains("path:") == true)
    }

    func testHistoryStoreQuarantinesMalformedRowsAndResumesRetentionCompaction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingMalformedHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let first = makeSnapshot(day: 1, written: 100, powerHours: 10)
        let second = makeSnapshot(day: 1, written: 200, powerHours: 20, capturedAt: Self.date(day: 1).addingTimeInterval(120))
        let malformedLine = Data("{ malformed history row }".utf8)
        var original = try encoder.encode(first) + Data([0x0A])
        original.append(try encoder.encode(second))
        original.append(0x0A)
        original.append(malformedLine)
        try original.write(to: fileURL)

        let policy = HistoryRetentionPolicy(
            fullResolutionAge: 0,
            mediumResolutionAge: 0,
            mediumBucketDuration: 60,
            archiveBucketDuration: 60,
            maximumRecordCount: 2,
            compactionInterval: 1
        )
        let store = HistoryStore(fileURL: fileURL, retentionPolicy: policy)
        let initialRecords = try await store.records()
        XCTAssertEqual(initialRecords.count, 2)
        let diagnostics = await store.decodeDiagnostics()
        XCTAssertEqual(diagnostics.failedLineCount, 1)
        XCTAssertEqual(diagnostics.sampleLineNumbers, [3])
        XCTAssertTrue(diagnostics.sourceRepaired)
        XCTAssertNotNil(diagnostics.quarantineFileName)
        XCTAssertNil(try Data(contentsOf: fileURL).range(of: malformedLine))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.pre-compaction-v1.jsonl").path))
        let quarantineURL = directory.appendingPathComponent(try XCTUnwrap(diagnostics.quarantineFileName))
        let quarantinedLine = try XCTUnwrap(try Data(contentsOf: quarantineURL)
            .split(separator: 0x0A)
            .first)
        let quarantinedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(quarantinedLine)) as? [String: Any])
        XCTAssertEqual(quarantinedObject["rawLineBase64"] as? String, malformedLine.base64EncodedString())
        XCTAssertEqual(quarantinedObject["lineNumber"] as? Int, 3)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("history.pre-compaction-v1.jsonl")), original)

        let later = makeSnapshot(day: 1, written: 300, powerHours: 30, capturedAt: Self.date(day: 1).addingTimeInterval(3_600))
        let didAppend = try await store.appendIfNew(later)
        XCTAssertTrue(didAppend)
        let afterAppend = try Data(contentsOf: fileURL)
        XCTAssertNil(afterAppend.range(of: malformedLine), "Malformed bytes should live only in the quarantine file")
        let appendedRecords = try await store.records()
        let appendedDiagnostics = await store.decodeDiagnostics()
        XCTAssertLessThanOrEqual(appendedRecords.count, 2, "The configured record cap applies after repair")
        XCTAssertEqual(appendedDiagnostics.failedLineCount, 1)
        XCTAssertTrue(appendedDiagnostics.sourceRepaired)
        let reloadedStore = HistoryStore(fileURL: fileURL, retentionPolicy: policy)
        let reloadedRecords = try await reloadedStore.records()
        let reloadedDiagnostics = await reloadedStore.decodeDiagnostics()
        XCTAssertLessThanOrEqual(reloadedRecords.count, 2)
        XCTAssertEqual(reloadedDiagnostics.failedLineCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path), "Quarantined bytes survive source repair and reload")
    }

    /// Writes one readable row and three unreadable ones, and returns the
    /// folder, the store file and the exact original bytes.
    private func mostlyUnreadableFile(named name: String, readable: Data) throws -> (URL, URL, Data) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingUnreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(name)
        var original = readable + Data([0x0A])
        for index in 1...3 {
            original.append(Data(#"{"futureFormat":\#(index)}"#.utf8))
            original.append(0x0A)
        }
        try original.write(to: fileURL)
        return (directory, fileURL, original)
    }

    private func setAsideFile(in directory: URL, stem: String) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("\(stem).unreadable-") && $0.hasSuffix(".jsonl") }
        XCTAssertEqual(names.count, 1, "\(names)")
        return directory.appendingPathComponent(try XCTUnwrap(names.first))
    }

    func testHistoryStoreKeepsParsedValuesButNotTheRawOutput() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingRawJSON-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var snapshot = makeSnapshot(day: 1, written: 100, powerHours: 10)
        snapshot.rawJSON = String(repeating: "x", count: 3_000)

        let store = HistoryStore(fileURL: fileURL)
        _ = try await store.appendIfNew(snapshot)

        let stored = try await HistoryStore(fileURL: fileURL).records()
        XCTAssertEqual(stored.map(\.dataUnitsWritten), [100])
        XCTAssertEqual(stored.first?.rawJSON, "")
        XCTAssertLessThan(try Data(contentsOf: fileURL).count, 2_000)
    }

    func testLosslessSMARTStoragePreservesWritePaceAndAllOldPoints() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LosslessSMART-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let original: [DriveSnapshot] = (0..<300).map { index in
            let extra = max(0, index - 250) * 1_000
            let written = UInt64(1_000_000 + index * 1_000 + extra)
            let date = Self.date(day: 1).addingTimeInterval(Double(index) * 21_600)
            return makeSnapshot(day: 1, written: written, percentage: UInt64(5 + index / 240),
                powerHours: UInt64(1_000 + index * 6), capturedAt: date)
        }
        let store = HistoryStore(fileURL: url)
        for snapshot in original { _ = try await store.appendIfNew(snapshot) }
        let restored = try await HistoryStore(fileURL: url).records()
        XCTAssertEqual(restored, original)
        let analyzer = HistoryAnalyzer()
        let expected = analyzer.writeRateSummary(from: original, deviceID: "serial:test-drive")
        XCTAssertNotEqual(expected.sevenDayBytesPerDay, expected.thirtyDayBytesPerDay)
        XCTAssertEqual(analyzer.writeRateSummary(from: restored, deviceID: "serial:test-drive"), expected)
        let decadeLater = makeSnapshot(day: 1, written: 2_000_000, powerHours: 3_000,
            capturedAt: original.last!.capturedAt.addingTimeInterval(10 * 365 * 86_400))
        _ = try await store.appendIfNew(decadeLater)
        let future = try await HistoryStore(fileURL: url).records()
        XCTAssertEqual(Array(future.dropLast()), original, "age does not remove or round old measurements")
    }

    func testTemperatureDownsamplingKeepsPeaksAndOrder() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points = (0..<10_000).map { TemperaturePoint(date: start.addingTimeInterval(Double($0) * 60), celsius: 40) }
        points[4_321] = TemperaturePoint(date: points[4_321].date, celsius: 71)
        points[8_765] = TemperaturePoint(date: points[8_765].date, celsius: 22)

        let drawn = TemperaturePoint.downsampled(points, maximumCount: 120)

        XCTAssertLessThanOrEqual(drawn.count, 120)
        XCTAssertEqual(drawn.map(\.celsius).max(), 71)
        XCTAssertEqual(drawn.map(\.celsius).min(), 22)
        XCTAssertEqual(drawn.map(\.date), drawn.map(\.date).sorted())
        XCTAssertEqual(drawn.first?.date, start)
        XCTAssertEqual(TemperaturePoint.downsampled(Array(points.prefix(50)), maximumCount: 120).count, 50, "short series are unchanged")
    }

    func testTemperatureLineRunsMeetAtTheWarmThreshold() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func reading(_ seconds: TimeInterval, _ celsius: Double) -> TemperaturePoint {
            TemperaturePoint(date: start.addingTimeInterval(seconds), celsius: celsius)
        }
        let runs = TemperatureLineRun.runs(sections: [[reading(0, 40), reading(100, 60), reading(200, 60), reading(300, 40)]])
        XCTAssertEqual(runs.map(\.isWarm), [false, true, false])
        XCTAssertEqual(runs[0].points, [reading(0, 40), reading(50, 50)])
        XCTAssertEqual(runs[1].points, [reading(50, 50), reading(100, 60), reading(200, 60), reading(250, 50)])
        XCTAssertEqual(runs[2].points, [reading(250, 50), reading(300, 40)])

        let exactlyAtThreshold = TemperatureLineRun.runs(sections: [[reading(0, 50), reading(10, 60)]])
        XCTAssertEqual(exactlyAtThreshold.map(\.isWarm), [true], "50 °C itself is not above the threshold")
        XCTAssertEqual(exactlyAtThreshold[0].points, [reading(0, 50), reading(10, 60)])

        let sections = TemperatureLineRun.runs(sections: [[reading(0, 40), reading(1, 41)], [reading(5, 42)], [reading(9, 43), reading(10, 44)]])
        XCTAssertEqual(sections.map(\.id), [0, 1], "a lone reading draws no line and ids stay unique")
    }

    func testHistoryStoreSetsAMostlyUnreadableFileAsideUnchanged() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let (directory, fileURL, original) = try mostlyUnreadableFile(
            named: "history.jsonl", readable: try encoder.encode(makeSnapshot(day: 1, written: 100, powerHours: 10)))
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(fileURL: fileURL)
        let records = try await store.records()

        XCTAssertEqual(records.map(\.dataUnitsWritten), [100])
        let aside = try setAsideFile(in: directory, stem: "history")
        XCTAssertEqual(try Data(contentsOf: aside), original, "the whole original file is kept byte for byte")
        let diagnostics = await store.decodeDiagnostics()
        XCTAssertEqual(diagnostics.failedLineCount, 3)
        XCTAssertEqual(diagnostics.quarantineFileName, aside.lastPathComponent)
        XCTAssertTrue(diagnostics.sourceRepaired)

        let later = makeSnapshot(day: 2, written: 200, powerHours: 20)
        let didAppend = try await store.appendIfNew(later)
        XCTAssertTrue(didAppend)
        let reloaded = try await HistoryStore(fileURL: fileURL).records()
        XCTAssertEqual(reloaded.map(\.dataUnitsWritten), [100, 200])
        XCTAssertEqual(try Data(contentsOf: aside), original)
    }

    func testTemperatureHistoryStoreSetsAMostlyUnreadableFileAsideUnchanged() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sample = TemperatureSample(capturedAt: Self.date(day: 1), deviceID: "serial:test", temperatureCelsius: 40)
        let (directory, fileURL, original) = try mostlyUnreadableFile(
            named: "temperature-history.jsonl", readable: try encoder.encode(sample))
        defer { try? FileManager.default.removeItem(at: directory) }

        let records = try await TemperatureHistoryStore(fileURL: fileURL).records()

        XCTAssertEqual(records.map(\.temperatureCelsius), [40])
        XCTAssertEqual(try Data(contentsOf: setAsideFile(in: directory, stem: "temperature-history")), original)
        let reloaded = try await TemperatureHistoryStore(fileURL: fileURL).records()
        XCTAssertEqual(reloaded.map(\.temperatureCelsius), [40])
    }

    func testASPToolSnapshotStoreSetsAMostlyUnreadableFileAsideUnchanged() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = ASPToolDiagnosticsSnapshot(capturedAt: Self.date(day: 1), deviceID: "d", hostWrites: 1)
        let (directory, fileURL, original) = try mostlyUnreadableFile(
            named: "asptool-snapshots.jsonl", readable: try encoder.encode(snapshot))
        defer { try? FileManager.default.removeItem(at: directory) }

        let records = try await ASPToolSnapshotStore(fileURL: fileURL).records()

        XCTAssertEqual(records.map(\.hostWrites), [1])
        XCTAssertEqual(try Data(contentsOf: setAsideFile(in: directory, stem: "asptool-snapshots")), original)
        let reloaded = try await ASPToolSnapshotStore(fileURL: fileURL).records()
        XCTAssertEqual(reloaded.map(\.hostWrites), [1])
    }

    func testHistoryStoreDoesNotAppendWhenMalformedRowsCannotBeQuarantined() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingQuarantineFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("history.jsonl")
        // Mostly readable, so the file is repaired in place rather than set aside.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var original = try encoder.encode(makeSnapshot(day: 1, written: 100, powerHours: 10)) + Data([0x0A])
        original.append(Data("{broken-json}\n".utf8))
        original.append(try encoder.encode(makeSnapshot(day: 1, written: 150, powerHours: 15,
                                                        capturedAt: Self.date(day: 1).addingTimeInterval(3_600))))
        original.append(0x0A)
        try original.write(to: fileURL)
        let quarantineURL = JSONLQuarantine.destinationURL(sourceData: original, sourceURL: fileURL)
        try FileManager.default.createDirectory(at: quarantineURL, withIntermediateDirectories: false)

        let store = HistoryStore(fileURL: fileURL)
        do {
            _ = try await store.records()
            XCTFail("A failed quarantine must not be treated as a repaired history")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }
        do {
            _ = try await store.appendIfNew(makeSnapshot(day: 2, written: 200, powerHours: 20))
            XCTFail("Appending must remain blocked until quarantine and repair succeed")
        } catch {
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }
    }

    func testUsageSettingsStoreMigratesLegacyPathKeyForStableSnapshot() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingUsageMigration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = UsageSettingsStore(fileURL: fileURL)
        let snapshot = makeSnapshot(day: 1, written: 100, powerHours: 10, serialNumber: nil)
        let settings = UsageSettings(manualStartDate: Self.date(day: 0))
        let legacyID = DeviceIdentity.legacyPathID(model: snapshot.model, devicePath: snapshot.devicePath)
        try await store.save(settings, for: legacyID)

        let loaded = try await store.settings(for: snapshot)
        XCTAssertEqual(loaded, settings)
        let savedData = try Data(contentsOf: fileURL)
        let savedText = String(decoding: savedData, as: UTF8.self)
        XCTAssertTrue(savedText.contains(snapshot.deviceID))
        XCTAssertFalse(savedText.contains("|path:"))
    }

    func testRefreshIntervalOffersStandardMonitoringChoices() {
        XCTAssertEqual(RefreshInterval.allCases.map(\.rawValue), [300, 600, 900, 1800, 3600])
        XCTAssertEqual(RefreshInterval.allCases.map(\.title), ["5分", "10分", "15分", "30分", "1時間"])
        XCTAssertEqual(RefreshInterval.defaultInterval, .tenMinutes)
        // Values saved by earlier builds map to the nearest remaining option.
        XCTAssertEqual(RefreshInterval(savedSeconds: 60), .fiveMinutes)
        XCTAssertEqual(RefreshInterval(savedSeconds: 180), .fiveMinutes)
        XCTAssertEqual(RefreshInterval(savedSeconds: 21_600), .oneHour)
        XCTAssertNil(RefreshInterval(savedSeconds: 0))
    }

    @MainActor
    func testDirectFTLIsDueInTheSMARTCycleDespiteTimerJitter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A ten-minute cycle that fires a few seconds early still reads FTL.
        XCTAssertTrue(DashboardModel.isDirectFTLAttemptDue(
            lastAttemptAt: now.addingTimeInterval(-597),
            interval: DashboardModel.directFTLDueInterval(for: .tenMinutes), now: now))
        // Right after a read, the next SMART-only refresh does not read again.
        XCTAssertFalse(DashboardModel.isDirectFTLAttemptDue(
            lastAttemptAt: now.addingTimeInterval(-120),
            interval: DashboardModel.directFTLDueInterval(for: .tenMinutes), now: now))
        XCTAssertEqual(DashboardModel.directFTLDueInterval(for: .fiveMinutes), 240)
        XCTAssertEqual(DashboardModel.directFTLDueInterval(for: .oneHour), 3_540)
    }

    func testCollectorIntervalsExposeIndependentOptionsAndMinimums() {
        XCTAssertEqual(
            IORegistryCollectionInterval.allCases.map(\.title),
            ["起動時のみ", "30分", "1時間", "3時間", "6時間", "12時間", "1日"]
        )
        XCTAssertEqual(IORegistryCollectionInterval.defaultInterval, .oneDay)
        XCTAssertTrue(IORegistryCollectionInterval.oneDay.detail.contains("1日間隔"))
        XCTAssertTrue(ASPToolUnitState.verified.supportsIntervalComparison)
        XCTAssertTrue(ASPToolUnitState.provisional4KiB.supportsIntervalComparison)
        XCTAssertFalse(ASPToolUnitState.unverified.supportsIntervalComparison)
        XCTAssertFalse(ASPToolUnitState.unavailable.supportsIntervalComparison)
    }

    func testSleepMonitoringModeOffersWakeOnlyAndBestEffort() {
        XCTAssertEqual(
            SleepMonitoringMode.allCases.map(\.rawValue),
            ["wakeOnly", "bestEffort"]
        )
        XCTAssertEqual(SleepMonitoringMode.wakeOnly.title, "復帰時のみ取得（推奨）")
        XCTAssertTrue(SleepMonitoringMode.bestEffort.detail.contains("保証されません"))
    }

    func testLoginItemStatusDescribesApprovalStates() {
        XCTAssertEqual(LoginItemStatus.enabled.title, "有効")
        XCTAssertTrue(LoginItemStatus.requiresApproval.detail.contains("システム設定"))
        XCTAssertTrue(LoginItemStatus.notFound.detail.contains("Applications"))
    }

    @MainActor
    func testDashboardModelPersistsAndRestoresRefreshInterval() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(RefreshInterval.fiveMinutes.rawValue, forKey: "refreshIntervalSeconds")
        defaults.set(TemperatureMonitoringInterval.threeMinutes.rawValue, forKey: "temperatureMonitoringIntervalSeconds")
        defaults.set(IORegistryCollectionInterval.sixHours.rawValue, forKey: "ioRegistryCollectionIntervalSeconds")
        let model = DashboardModel(preferences: defaults)

        XCTAssertEqual(model.refreshInterval, .fiveMinutes)
        XCTAssertEqual(model.temperatureMonitoringInterval, .threeMinutes)
        XCTAssertEqual(model.ioRegistryCollectionInterval, .sixHours)
        XCTAssertTrue(model.aspDirectFTLAutomaticCollection)
        model.refreshInterval = .thirtyMinutes
        model.temperatureMonitoringInterval = .thirtySeconds
        model.ioRegistryCollectionInterval = .oneDay
        model.aspDirectFTLAutomaticCollection = false
        XCTAssertEqual(defaults.integer(forKey: "refreshIntervalSeconds"), RefreshInterval.thirtyMinutes.rawValue)
        XCTAssertEqual(defaults.integer(forKey: "temperatureMonitoringIntervalSeconds"), TemperatureMonitoringInterval.thirtySeconds.rawValue)
        XCTAssertEqual(defaults.integer(forKey: "ioRegistryCollectionIntervalSeconds"), IORegistryCollectionInterval.oneDay.rawValue)
        XCTAssertEqual(defaults.object(forKey: "aspDirectFTLAutomaticCollection") as? Bool, false)
    }

    @MainActor
    func testTurningAutomaticFTLBackOnClearsTheFailureCount() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Collection stopped after three failures in a row.
        defaults.set(false, forKey: "aspDirectFTLAutomaticCollection")
        defaults.set(3, forKey: "aspDirectFTLConsecutiveFailures")
        let model = DashboardModel(preferences: defaults)
        XCTAssertEqual(model.aspDirectFTLConsecutiveFailures, 3)

        // Otherwise the next single failure would stop it again at once.
        model.aspDirectFTLAutomaticCollection = true
        XCTAssertEqual(model.aspDirectFTLConsecutiveFailures, 0)
        XCTAssertEqual(defaults.integer(forKey: "aspDirectFTLConsecutiveFailures"), 0)
    }

    @MainActor
    func testSavedPreferencesFromEarlierBuildsCarryOver() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A separate FTL interval of 3 days, and ioreg every week.
        defaults.set(259_200, forKey: "aspDirectFTLCollectionIntervalSeconds")
        defaults.set(604_800, forKey: "ioRegistryCollectionIntervalSeconds")
        XCTAssertTrue(DashboardModel(preferences: defaults).aspDirectFTLAutomaticCollection,
                      "an automatic FTL interval stays automatic, now in the SMART cycle")
        XCTAssertEqual(DashboardModel(preferences: defaults).ioRegistryCollectionInterval, .oneDay)

        // Manual only (0) stays off.
        defaults.set(0, forKey: "aspDirectFTLCollectionIntervalSeconds")
        XCTAssertFalse(DashboardModel(preferences: defaults).aspDirectFTLAutomaticCollection)
        XCTAssertEqual(IORegistryCollectionInterval.allCases.map(\.rawValue).max(), 86_400)
    }

    @MainActor
    func testDashboardModelUsesExplicitDefaultsWhenCollectionPreferencesAreMissing() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = DashboardModel(preferences: defaults)

        XCTAssertEqual(model.ioRegistryCollectionInterval, IORegistryCollectionInterval.defaultInterval)
        XCTAssertTrue(model.aspDirectFTLAutomaticCollection)
        XCTAssertEqual(model.backgroundMonitoringEnabled, DashboardModel.defaultBackgroundMonitoringEnabled)
    }

    @MainActor
    func testLocalDirectFTLVerificationIsPerReleaseAndCanBeRevoked() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = DashboardModel(preferences: defaults)

        // A reviewed release needs no local record.
        model.runtimeOSBuild = { "26A434" }
        model.recordLocalDirectFTLVerificationIfNeeded()
        XCTAssertTrue(model.aspDirectFTLLocallyVerifiedMacOSMajors.isEmpty)

        // macOS 15 becomes eligible after a passing read on this Mac.
        model.runtimeOSBuild = { "24G90" }
        model.recordLocalDirectFTLVerificationIfNeeded()
        XCTAssertEqual(model.aspDirectFTLLocallyVerifiedMacOSMajors, [15])
        XCTAssertEqual(
            DirectFTLContractRegistry.executionReview(
                runtimeBuild: "24G91", locallyVerifiedMajors: model.aspDirectFTLLocallyVerifiedMacOSMajors
            ),
            .locallyVerified(macOSMajor: 15)
        )
        // A failed cross-check withdraws it.
        model.revokeLocalDirectFTLVerification()
        XCTAssertTrue(model.aspDirectFTLLocallyVerifiedMacOSMajors.isEmpty)
        XCTAssertEqual(DirectFTLContractRegistry.executionReview(runtimeBuild: "24G90"),
                       .compatibilityTrial(macOSMajor: 15))
        XCTAssertTrue(model.aspDirectFTLAutomaticCollection)
    }

    @MainActor
    func testFailedDirectFTLAttemptsWaitForConfiguredInterval() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DashboardModel.isDirectFTLAttemptDue(lastAttemptAt: nil, interval: 21600, now: now))
        XCTAssertFalse(DashboardModel.isDirectFTLAttemptDue(lastAttemptAt: now.addingTimeInterval(-60), interval: 21600, now: now))
        // An attempt recorded in the future (clock set back) is due now.
        XCTAssertTrue(DashboardModel.isDirectFTLAttemptDue(lastAttemptAt: now.addingTimeInterval(60), interval: 21600, now: now))
        XCTAssertTrue(DashboardModel.isDirectFTLAttemptDue(lastAttemptAt: now.addingTimeInterval(30 * 86_400), interval: 21600, now: now))
        XCTAssertTrue(DashboardModel.isDirectFTLAttemptDue(lastAttemptAt: now.addingTimeInterval(-21600), interval: 21600, now: now))
    }

    @MainActor
    func testDashboardModelPersistsBackgroundMonitoringPreference() {
        let suiteName = "NenRingTests-(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "backgroundMonitoringEnabled")
        let model = DashboardModel(preferences: defaults)

        XCTAssertFalse(model.backgroundMonitoringEnabled)
        model.backgroundMonitoringEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "backgroundMonitoringEnabled"))
    }

    @MainActor
    func testDashboardModelPersistsMenuBarDisplayAndSleepPreferences() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("bestEffort", forKey: "sleepMonitoringMode")
        defaults.set(true, forKey: "menuBarShowsTemperature")
        defaults.set(true, forKey: "menuBarShowsTodayWrites")
        defaults.set(true, forKey: "launchAtLoginEnabled")
        defaults.set(false, forKey: "dockIconVisible")
        let model = DashboardModel(preferences: defaults)

        XCTAssertEqual(model.sleepMonitoringMode, .bestEffort)
        XCTAssertTrue(model.menuBarShowsTemperature)
        XCTAssertTrue(model.menuBarShowsTodayWrites)
        XCTAssertFalse(model.menuBarShowsWear)
        XCTAssertTrue(model.launchAtLoginEnabled)
        XCTAssertFalse(model.dockIconVisible)

        model.sleepMonitoringMode = .wakeOnly
        model.menuBarShowsTemperature = false
        model.menuBarShowsTodayWrites = false
        model.menuBarShowsRemainingYears = true
        model.launchAtLoginEnabled = false
        model.dockIconVisible = true

        XCTAssertEqual(defaults.string(forKey: "sleepMonitoringMode"), "wakeOnly")
        XCTAssertFalse(defaults.bool(forKey: "menuBarShowsTemperature"))
        XCTAssertFalse(defaults.bool(forKey: "menuBarShowsTodayWrites"))
        XCTAssertTrue(defaults.bool(forKey: "menuBarShowsRemainingYears"))
        XCTAssertFalse(defaults.bool(forKey: "launchAtLoginEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "dockIconVisible"))
        XCTAssertTrue(model.dockVisibilityRequiresRestart)
    }

    @MainActor
    func testDockPresentationMigratesExistingInstallToMenuBarModeOnce() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: DockVisibilityController.preferenceKey)
        DockVisibilityController.migrateToMenuBarDefaultIfNeeded(preferences: defaults)

        XCTAssertFalse(DockVisibilityController.preferredDockVisibility(preferences: defaults))
        XCTAssertEqual(
            defaults.integer(forKey: DockVisibilityController.migrationVersionKey),
            DockVisibilityController.currentMigrationVersion
        )

        defaults.set(true, forKey: DockVisibilityController.preferenceKey)
        DockVisibilityController.migrateToMenuBarDefaultIfNeeded(preferences: defaults)

        XCTAssertTrue(DockVisibilityController.preferredDockVisibility(preferences: defaults))
    }

    @MainActor
    func testDashboardModelUsesMenuBarModeByDefaultAndDefersDockChange() {
        let suiteName = "NenRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = DashboardModel(preferences: defaults)

        XCTAssertFalse(model.dockIconVisible)
        XCTAssertFalse(model.dockVisibilityRequiresRestart)

        model.dockIconVisible = true

        XCTAssertTrue(defaults.bool(forKey: DockVisibilityController.preferenceKey))
        XCTAssertTrue(model.dockVisibilityRequiresRestart)

        model.dockIconVisible = false

        XCTAssertFalse(model.dockVisibilityRequiresRestart)
    }

    func testHistoryStoreRoundTripsAndDeduplicatesWithinSixtySeconds() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = HistoryStore(fileURL: fileURL)
        let first = makeSnapshot(day: 1, written: 100, powerHours: 10)
        let duplicate = makeSnapshot(day: 1, written: 110, powerHours: 10, capturedAt: first.capturedAt.addingTimeInterval(30))
        let later = makeSnapshot(day: 1, written: 120, powerHours: 11, capturedAt: first.capturedAt.addingTimeInterval(61))

        let firstAdded = try await store.appendIfNew(first)
        let duplicateAdded = try await store.appendIfNew(duplicate)
        let laterAdded = try await store.appendIfNew(later)
        XCTAssertTrue(firstAdded)
        XCTAssertFalse(duplicateAdded)
        XCTAssertTrue(laterAdded)

        let records = try await store.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.dataUnitsWritten, 120)
    }

    func testSmartctlRunnerTimesOutAndStopsChildProcess() throws {
        let runner = LocalSmartctlRunner(
            timeout: 0.05,
            terminationGracePeriod: 0.2
        )
        let startedAt = Date()

        XCTAssertThrowsError(
            try runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            )
        ) { error in
            XCTAssertEqual(error as? SmartctlServiceError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testSmartctlRunnerDrainsLargeStandardErrorWithoutDeadlock() throws {
        let runner = LocalSmartctlRunner(timeout: 2)
        let result = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/dd if=/dev/zero bs=262144 count=1 1>&2"]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertGreaterThanOrEqual(result.stderr.count, 262_144)
    }

    func testHistoryCompactionPreservesWearTransitionBoundaries() {
        let policy = HistoryRetentionPolicy(
            fullResolutionAge: 0,
            mediumResolutionAge: 0,
            mediumBucketDuration: 15 * 60,
            archiveBucketDuration: 24 * 60 * 60,
            maximumRecordCount: 100,
            compactionInterval: 1
        )
        let start = Self.date(day: 1)
        var snapshots: [DriveSnapshot] = []
        for index in 0..<20 {
            let percentage: UInt64 = index < 10 ? 5 : 6
            let snapshot = makeSnapshot(
                day: 1,
                written: UInt64(100 + index),
                percentage: percentage,
                powerHours: UInt64(10 + index),
                capturedAt: start.addingTimeInterval(Double(index * 120))
            )
            snapshots.append(snapshot)
        }

        let compacted = policy.compact(
            snapshots,
            referenceDate: start.addingTimeInterval(7 * 24 * 60 * 60)
        )
        let retainedIDs = Set(compacted.map { $0.id })

        XCTAssertTrue(retainedIDs.contains(snapshots[9].id))
        XCTAssertTrue(retainedIDs.contains(snapshots[10].id))
        XCTAssertEqual(compacted.first?.id, snapshots.first?.id)
        XCTAssertEqual(compacted.last?.id, snapshots.last?.id)
        XCTAssertLessThan(compacted.count, snapshots.count)
    }

    func testHistoryCompactionKeepsUnpoweredPeriods() throws {
        let policy = HistoryRetentionPolicy(
            fullResolutionAge: 0,
            mediumResolutionAge: 0,
            mediumBucketDuration: 15 * 60,
            archiveBucketDuration: 24 * 60 * 60,
            maximumRecordCount: 1_000,
            compactionInterval: 1
        )
        let start = Self.date(day: 1)
        var snapshots: [DriveSnapshot] = []
        var time = start
        var hours: UInt64 = 100
        func add() {
            snapshots.append(makeSnapshot(day: 1, written: UInt64(100 + snapshots.count), percentage: 5,
                                          powerHours: hours, capturedAt: time))
        }
        // Powered hours with an 8-hour and a 2-hour unpowered gap on the same day.
        for index in 0..<72 {
            add()
            if index == 20 {
                time += 8 * 3_600
            } else if index == 30 {
                time += 2 * 3_600
            } else {
                time += 3_600
                hours += 1
            }
        }
        let now = time
        let before = RetentionModelEvaluator.observedRetentionDays(smartHistory: snapshots, deviceID: snapshots[0].deviceID, now: now)
        let compacted = policy.compact(snapshots, referenceDate: now.addingTimeInterval(200 * 86_400))
        let after = RetentionModelEvaluator.observedRetentionDays(smartHistory: compacted, deviceID: snapshots[0].deviceID, now: now)
        XCTAssertLessThan(compacted.count, snapshots.count)
        let longestBefore = try XCTUnwrap(before.longest?.durationDays)
        XCTAssertEqual(longestBefore * 24, 8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(after.longest?.durationDays), longestBefore, accuracy: 0.001,
                       "thinning must not merge the two gaps into one longer period")
    }

    func testHistoryStoreEnforcesHardLimitAndPersistsCompaction() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingBoundedTests-\(UUID().uuidString).jsonl")
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent).pre-compaction-v1.jsonl"
        )
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: backupURL)
        }
        let policy = HistoryRetentionPolicy(
            fullResolutionAge: 365 * 24 * 60 * 60,
            mediumResolutionAge: 365 * 24 * 60 * 60,
            mediumBucketDuration: 15 * 60,
            archiveBucketDuration: 24 * 60 * 60,
            maximumRecordCount: 5,
            compactionInterval: 1
        )
        let store = HistoryStore(fileURL: fileURL, retentionPolicy: policy)
        let start = Self.date(day: 1)
        var snapshots: [DriveSnapshot] = []
        for index in 0..<12 {
            let snapshot = makeSnapshot(
                day: 1,
                written: UInt64(100 + index),
                powerHours: UInt64(10 + index),
                capturedAt: start.addingTimeInterval(Double(index * 120))
            )
            snapshots.append(snapshot)
            let appended = try await store.appendIfNew(snapshot)
            XCTAssertTrue(appended)
        }

        let retained = try await store.records()
        XCTAssertEqual(retained.count, 5)
        XCTAssertEqual(retained.first?.id, snapshots.first?.id)
        XCTAssertEqual(retained.last?.id, snapshots.last?.id)

        let reloaded = try await HistoryStore(
            fileURL: fileURL,
            retentionPolicy: policy
        ).records()
        XCTAssertEqual(reloaded, retained)
    }

    func testHistoryStoreBacksUpExistingRowsBeforeFirstCompaction() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingMigrationTests-\(UUID().uuidString).jsonl")
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).pre-compaction-v1.jsonl")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: backupURL)
        }

        let start = Self.date(day: 1)
        var snapshots: [DriveSnapshot] = []
        for index in 0..<8 {
            let snapshot = makeSnapshot(
                day: 1,
                written: UInt64(100 + index),
                powerHours: UInt64(10 + index),
                capturedAt: start.addingTimeInterval(Double(index * 120))
            )
            snapshots.append(snapshot)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var sourceData = Data()
        for snapshot in snapshots {
            sourceData.append(try encoder.encode(snapshot))
            sourceData.append(0x0A)
        }
        try sourceData.write(to: fileURL)

        let policy = HistoryRetentionPolicy(
            fullResolutionAge: 0,
            mediumResolutionAge: 0,
            mediumBucketDuration: 15 * 60,
            archiveBucketDuration: 24 * 60 * 60,
            maximumRecordCount: 5,
            compactionInterval: 1
        )
        let compacted = try await HistoryStore(
            fileURL: fileURL,
            retentionPolicy: policy
        ).records()

        XCTAssertLessThan(compacted.count, snapshots.count)
        XCTAssertEqual(try Data(contentsOf: backupURL), sourceData)
    }

    func testTemperatureHistoryStoreIsBoundedAndRoundTrips() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingTemperatureTests-\(UUID().uuidString).jsonl")
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent).pre-compaction-v1.jsonl"
        )
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: backupURL)
        }

        let policy = TemperatureHistoryRetentionPolicy(
            fullResolutionAge: 0,
            mediumResolutionAge: 0,
            mediumBucketDuration: 60,
            archiveBucketDuration: 60,
            maximumRecordCount: 5,
            compactionInterval: 1
        )
        let store = TemperatureHistoryStore(fileURL: fileURL, retentionPolicy: policy)
        let start = Self.date(day: 1)
        var samples: [TemperatureSample] = []
        for index in 0..<12 {
            let sample = TemperatureSample(
                capturedAt: start.addingTimeInterval(Double(index * 30)),
                deviceID: "serial:test-drive",
                temperatureCelsius: 40 + index
            )
            samples.append(sample)
            let appended = try await store.appendIfNew(sample)
            XCTAssertTrue(appended)
        }

        let retained = try await store.records()
        XCTAssertEqual(retained.count, 5)
        XCTAssertEqual(retained.first?.id, samples.first?.id)
        XCTAssertEqual(retained.last?.id, samples.last?.id)
        let reloaded = try await TemperatureHistoryStore(fileURL: fileURL, retentionPolicy: policy).records()
        XCTAssertEqual(reloaded, retained)
    }

    func testTemperatureHistoryStoreQuarantinesMalformedRowsAndResumesRetentionCompaction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NenRingMalformedTemperature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("temperature-history.jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let first = TemperatureSample(capturedAt: Self.date(day: 1), deviceID: "serial:test", temperatureCelsius: 40)
        let second = TemperatureSample(capturedAt: Self.date(day: 1).addingTimeInterval(120), deviceID: "serial:test", temperatureCelsius: 41)
        let malformedLine = Data("not-json".utf8)
        var original = try encoder.encode(first) + Data([0x0A])
        original.append(try encoder.encode(second))
        original.append(0x0A)
        original.append(malformedLine)
        try original.write(to: fileURL)

        let policy = TemperatureHistoryRetentionPolicy(
            fullResolutionAge: 0,
            mediumResolutionAge: 0,
            mediumBucketDuration: 30,
            archiveBucketDuration: 30,
            maximumRecordCount: 2,
            compactionInterval: 1
        )
        let store = TemperatureHistoryStore(fileURL: fileURL, retentionPolicy: policy)
        let initialRecords = try await store.records()
        XCTAssertEqual(initialRecords.count, 2)
        let diagnostics = await store.decodeDiagnostics()
        XCTAssertEqual(diagnostics.failedLineCount, 1)
        XCTAssertEqual(diagnostics.sampleLineNumbers, [3])
        XCTAssertTrue(diagnostics.sourceRepaired)
        let quarantineURL = directory.appendingPathComponent(try XCTUnwrap(diagnostics.quarantineFileName))
        let quarantinedLine = try XCTUnwrap(try Data(contentsOf: quarantineURL)
            .split(separator: 0x0A)
            .first)
        let quarantinedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(quarantinedLine)) as? [String: Any])
        XCTAssertEqual(quarantinedObject["rawLineBase64"] as? String, malformedLine.base64EncodedString())
        XCTAssertEqual(quarantinedObject["lineNumber"] as? Int, 3)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("temperature-history.pre-compaction-v1.jsonl")), original)
        XCTAssertNil(try Data(contentsOf: fileURL).range(of: malformedLine))

        let later = TemperatureSample(capturedAt: Self.date(day: 1).addingTimeInterval(3_600), deviceID: "serial:test", temperatureCelsius: 42)
        let didAppend = try await store.appendIfNew(later)
        XCTAssertTrue(didAppend)
        let afterAppend = try Data(contentsOf: fileURL)
        XCTAssertNil(afterAppend.range(of: malformedLine))
        let appendedRecords = try await store.records()
        let appendedDiagnostics = await store.decodeDiagnostics()
        XCTAssertLessThanOrEqual(appendedRecords.count, 2)
        XCTAssertEqual(appendedDiagnostics.failedLineCount, 1)
        XCTAssertTrue(appendedDiagnostics.sourceRepaired)
        let reloadedStore = TemperatureHistoryStore(fileURL: fileURL, retentionPolicy: policy)
        let reloadedRecords = try await reloadedStore.records()
        let reloadedDiagnostics = await reloadedStore.decodeDiagnostics()
        XCTAssertLessThanOrEqual(reloadedRecords.count, 2)
        XCTAssertEqual(reloadedDiagnostics.failedLineCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testDiskutilLocationParserReadsInternalFlag() throws {
        let internalPlist = try PropertyListSerialization.data(
            fromPropertyList: ["Internal": true], format: .xml, options: 0
        )
        let externalPlist = try PropertyListSerialization.data(
            fromPropertyList: ["Internal": false], format: .xml, options: 0
        )

        XCTAssertEqual(LocalStorageDeviceLocator.parseLocation(plistData: internalPlist), .internalDevice)
        XCTAssertEqual(LocalStorageDeviceLocator.parseLocation(plistData: externalPlist), .externalDevice)
        XCTAssertEqual(LocalStorageDeviceLocator.parseLocation(plistData: Data("not a plist".utf8)), .unknown)
    }

    func testServicePrefersInternalCandidateWhenMultipleDevicesAreUsable() async throws {
        let runner = FixtureRunner(
            scanJSON: """
            {"devices":[
              {"name":"/dev/rdisk4","type":"nvme"},
              {"name":"/dev/rdisk0","type":"nvme"}
            ]}
            """,
            deviceJSON: Self.healthFixture
        )
        let service = SmartctlService(
            runner: runner,
            storageDeviceLocator: FixedStorageDeviceLocator(
                locations: [
                    "/dev/rdisk4": .externalDevice,
                    "/dev/rdisk0": .internalDevice
                ],
                defaultLocation: .externalDevice
            ),
            storageTargetResolver: FixtureStorageTargetResolver()
        )

        let report = try await service.probe(
            capturedAt: Self.date(day: 1),
            includeIORegistry: false
        )

        XCTAssertEqual(report.snapshot.devicePath, "/dev/rdisk0")
        XCTAssertEqual(report.deviceCapabilities.location, .internalDevice)
        XCTAssertEqual(report.deviceCapabilities.appleDirectFTLEligible,
                       DirectFTLContractRegistry.isAppleSiliconHost)
        XCTAssertGreaterThanOrEqual(report.deviceCapabilities.usableCandidateCount, 2)
    }

    func testExternalSmartCandidateIsNotEligibleForAppleDirectFTL() async throws {
        let runner = FixtureRunner(
            scanJSON: """
            {"devices":[{"name":"/dev/rdisk4","type":"nvme"}]}
            """,
            deviceJSON: Self.healthFixture
        )
        let service = SmartctlService(
            runner: runner,
            storageDeviceLocator: FixedStorageDeviceLocator(
                locations: [:],
                defaultLocation: .externalDevice
            )
        )

        let report = try await service.probe(
            capturedAt: Self.date(day: 1),
            includeIORegistry: false
        )

        XCTAssertEqual(report.deviceCapabilities.location, .externalDevice)
        XCTAssertFalse(report.deviceCapabilities.appleDirectFTLEligible)
    }

    func testMultipleAnonymousAppleTargetsRequirePersistentIdentity() async throws {
        for uuid in [Optional<String>.none, "12345678-1234-1234-1234-123456789012"] {
            let service = SmartctlService(runner: FixtureRunner(
                scanJSON: "{\"devices\":[{\"name\":\"/dev/rdisk0\",\"type\":\"nvme\"}]}",
                deviceJSON: Self.healthFixture),
                storageDeviceLocator: FixedStorageDeviceLocator(locations: ["/dev/rdisk0": .internalDevice],
                    defaultLocation: .externalDevice),
                storageTargetResolver: FixtureStorageTargetResolver(appleServiceCount: 2, mediaUUID: uuid))
            let report = try await service.probe(capturedAt: Self.date(day: 1), includeIORegistry: false)
            if let uuid {
                XCTAssertEqual(report.snapshot.deviceID, "media:\(uuid)")
                XCTAssertEqual(report.storageTargetResolution?.state, .matched)
                XCTAssertEqual(report.storageTargetResolution?.recordsSMARTHistory, true)
                XCTAssertEqual(report.deviceCapabilities.appleDirectFTLEligible, DirectFTLContractRegistry.isAppleSiliconHost)
            } else {
                XCTAssertEqual(report.storageTargetResolution?.state, .ambiguous)
                XCTAssertEqual(report.storageTargetResolution?.appleSMARTServiceCount, 2)
                XCTAssertEqual(report.storageTargetResolution?.recordsSMARTHistory, false,
                               "an indistinguishable disk must not share SMART history")
                XCTAssertFalse(report.deviceCapabilities.appleDirectFTLEligible)
            }
        }
    }

    func testCachedTemperatureKeepsTheMediaHistoryID() async throws {
        let uuid = "12345678-1234-1234-1234-123456789012"
        let service = SmartctlService(runner: FixtureRunner(
            scanJSON: "{\"devices\":[{\"name\":\"/dev/rdisk0\",\"type\":\"nvme\"}]}",
            deviceJSON: Self.healthFixture),
            storageDeviceLocator: FixedStorageDeviceLocator(locations: ["/dev/rdisk0": .internalDevice],
                defaultLocation: .externalDevice),
            storageTargetResolver: FixtureStorageTargetResolver(appleServiceCount: 2, mediaUUID: uuid))
        let report = try await service.probe(capturedAt: Self.date(day: 1), includeIORegistry: false)
        XCTAssertEqual(report.snapshot.deviceID, "media:\(uuid)")
        // Both readings go through the cached path; neither may switch to
        // the serial-less stable ID, or the samples would not be recorded.
        for _ in 0..<2 {
            let reading = try await service.probeTemperature(capturedAt: Self.date(day: 1))
            XCTAssertEqual(reading.deviceID, report.snapshot.deviceID)
        }
    }

    func testUnboundMultipleAppleTargetsDoNotFallBackToSharedHistory() async throws {
        let cases: [(String?, String?, Bool)] = [(nil, nil, false), ("unique-media", nil, true),
                                                 (nil, "unique-serial", true)]
        for (uuid, serial, recordsHistory) in cases {
            let fixture = serial.map { Self.healthFixture.replacingOccurrences(of: "\"model_name\"",
                with: "\"serial_number\": \"\($0)\", \"model_name\"") } ?? Self.healthFixture
            let service = SmartctlService(runner: FixtureRunner(scanJSON:
                "{\"devices\":[{\"name\":\"/dev/rdisk0\",\"type\":\"nvme\"}]}", deviceJSON: fixture),
                storageDeviceLocator: FixedStorageDeviceLocator(locations: ["/dev/rdisk0": .internalDevice],
                    defaultLocation: .externalDevice),
                storageTargetResolver: FixtureStorageTargetResolver(unboundResolution:
                    .init(state: .ambiguous, binding: nil, reason: "fixture", appleSMARTServiceCount: 2,
                          persistentMediaUUID: uuid)))
            let report = try await service.probe(includeIORegistry: false)
            XCTAssertEqual(report.storageTargetResolution?.recordsSMARTHistory, recordsHistory)
            XCTAssertNil(report.storageTargetResolution?.binding)
            XCTAssertFalse(report.deviceCapabilities.appleDirectFTLEligible)
            if let uuid { XCTAssertEqual(report.snapshot.deviceID, "media:\(uuid)") }
        }
    }

    @MainActor
    func testCapacityContextRecoversAfterTransientBindingLossWithoutRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NenRing-profile-recovery-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        preferences.set(false, forKey: "backgroundMonitoringEnabled")
        preferences.set(false, forKey: "aspDirectFTLAutomaticCollection")
        let resolver = RecoveringStorageTargetResolver()
        let reader = RecoveringProfileReader()
        let registry = IORegistryService(reader: { _, _, _ in await reader.read() })
        let model = DashboardModel(
            service: SmartctlService(runner: FixtureRunner(scanJSON:
                "{\"devices\":[{\"name\":\"/dev/rdisk0\",\"type\":\"nvme\"}]}",
                deviceJSON: Self.healthFixture), ioRegistryService: registry,
                storageDeviceLocator: FixedStorageDeviceLocator(locations: [:], defaultLocation: .internalDevice),
                storageTargetResolver: resolver),
            historyStore: HistoryStore(fileURL: directory.appendingPathComponent("smart.jsonl")),
            temperatureHistoryStore: TemperatureHistoryStore(fileURL: directory.appendingPathComponent("temperature.jsonl")),
            asptoolSnapshotStore: ASPToolSnapshotStore(fileURL: directory.appendingPathComponent("ftl.jsonl")),
            reliabilityEventJournal: FTLReliabilityEventJournal(fileURL: directory.appendingPathComponent("journal.jsonl")),
            researchSessionStore: ResearchSessionStore(fileURL: directory.appendingPathComponent("research.jsonl")),
            usageSettingsStore: UsageSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            preferences: preferences)
        await model.refresh(trigger: .initial)
        let original = try XCTUnwrap(model.appleStorageProfile)
        let margin = try XCTUnwrap(model.capacityProfile?.hiddenPhysicalMarginRatio)
        XCTAssertNotNil(model.freshIdentityContext)
        resolver.set(.unavailable)
        await model.refresh(trigger: .background)
        XCTAssertNil(model.appleStorageProfile, "Unresolved target must not supply geometry")
        XCTAssertNil(model.freshIdentityContext)
        resolver.set(FixtureStorageTargetResolver().resolve(devicePath: "/dev/rdisk0"))
        await model.refresh(trigger: .background)
        XCTAssertEqual(model.appleStorageProfile, original)
        XCTAssertEqual(model.capacityProfile?.hiddenPhysicalMarginRatio, margin)
        XCTAssertNotNil(ReferenceTBW.resolve(profile: model.appleStorageProfile,
                                            capacityBytes: model.capacityProfile?.logicalCapacityBytes))
        XCTAssertNil(model.freshIdentityContext, "Cache recovery is not a fresh identity observation")
        let readsAfterRecovery = await reader.reads
        XCTAssertEqual(readsAfterRecovery, 1, "Normal SMART polls must not acquire IORegistry")

        // A forced read failure must not erase the cache either.
        await reader.fail()
        await model.refresh(trigger: .wake)
        XCTAssertEqual(model.appleStorageProfile, original)
        resolver.set(.unavailable)
        await model.refresh(trigger: .background)
        resolver.set(FixtureStorageTargetResolver().resolve(devicePath: "/dev/rdisk0"))
        await model.refresh(trigger: .manual)
        XCTAssertEqual(model.appleStorageProfile, original)
        XCTAssertEqual(model.capacityProfile?.hiddenPhysicalMarginRatio, margin)
        let readsAfterFailure = await reader.reads
        XCTAssertEqual(readsAfterFailure, 2)

        // A different live target cannot reuse the old controller's profile.
        resolver.set(.init(state: .matched, binding: .init(smartServiceID: 22,
            controllerEntryID: 21, wholeMediaID: 23, controllerClass: "AppleANS3NVMeController",
            wholeMediaCount: 1, appleSMARTServiceCount: 1, mediaUUID: nil), reason: "new target"))
        await model.refresh(trigger: .background)
        XCTAssertNil(model.appleStorageProfile)
        XCTAssertNil(model.capacityProfile?.hiddenPhysicalMarginRatio)
    }

    @MainActor
    func testBackgroundSMARTFailureIsVisibleAndClearsAfterRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-failure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NenRing-monitor-failure-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        preferences.set(false, forKey: "aspDirectFTLAutomaticCollection")
        let runner = FixtureRunner(scanJSON: "{\"devices\":[{\"name\":\"/dev/rdisk0\",\"type\":\"nvme\"}]}",
                                   deviceJSON: Self.healthFixture)
        let model = DashboardModel(
            service: SmartctlService(runner: runner,
                storageDeviceLocator: FixedStorageDeviceLocator(locations: [:], defaultLocation: .externalDevice)),
            historyStore: HistoryStore(fileURL: directory.appendingPathComponent("smart.jsonl")),
            temperatureHistoryStore: TemperatureHistoryStore(fileURL: directory.appendingPathComponent("temperature.jsonl")),
            asptoolSnapshotStore: ASPToolSnapshotStore(fileURL: directory.appendingPathComponent("ftl.jsonl")),
            reliabilityEventJournal: FTLReliabilityEventJournal(fileURL: directory.appendingPathComponent("journal.jsonl")),
            researchSessionStore: ResearchSessionStore(fileURL: directory.appendingPathComponent("research.jsonl")),
            usageSettingsStore: UsageSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            preferences: preferences)
        await model.refresh(trigger: .manual)
        let previous = try XCTUnwrap(model.snapshot)
        let lastSuccess = try XCTUnwrap(model.lastSuccessfulRefreshAt)
        for failure in [SmartctlServiceError.timedOut, .invalidJSON("fixture")] {
            runner.setFailure(failure)
            await model.refresh(trigger: .background)
            guard case .failed = model.state else { return XCTFail("a background failure must be visible") }
            XCTAssertEqual(model.snapshot, previous)
            XCTAssertEqual(model.lastSuccessfulRefreshAt, lastSuccess)
            XCTAssertNotNil(model.lastSmartctlFailure)
            let guidance = try XCTUnwrap(DashboardGuidance.make(state: model.state, hasSnapshot: true,
                                                              failure: model.lastSmartctlFailure))
            XCTAssertTrue(guidance.message.contains("前回取得した値"))
            XCTAssertFalse(model.isInteractiveRefreshing)
        }
        runner.setFailure(nil)
        await model.refresh(trigger: .background)
        guard case .ready = model.state else { return XCTFail("recovery must clear the failure") }
        XCTAssertNil(model.lastSmartctlFailure)
        XCTAssertNil(DashboardGuidance.make(state: model.state, hasSnapshot: true, failure: nil))
    }

    @MainActor
    func testUnreadableTemperatureHistoryDoesNotBecomeAnEmptyForecastInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temperature-read-failure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NenRing-temperature-read-failure-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        preferences.set(false, forKey: "aspDirectFTLAutomaticCollection")
        let temperaturePath = directory.appendingPathComponent("temperature.jsonl")
        try FileManager.default.createDirectory(at: temperaturePath, withIntermediateDirectories: true)
        let model = DashboardModel(
            service: SmartctlService(runner: FixtureRunner(
                scanJSON: "{\"devices\":[{\"name\":\"/dev/rdisk0\",\"type\":\"nvme\"}]}",
                deviceJSON: Self.healthFixture),
                storageDeviceLocator: FixedStorageDeviceLocator(locations: [:], defaultLocation: .externalDevice)),
            historyStore: HistoryStore(fileURL: directory.appendingPathComponent("smart.jsonl")),
            temperatureHistoryStore: TemperatureHistoryStore(fileURL: temperaturePath),
            asptoolSnapshotStore: ASPToolSnapshotStore(fileURL: directory.appendingPathComponent("ftl.jsonl")),
            reliabilityEventJournal: FTLReliabilityEventJournal(fileURL: directory.appendingPathComponent("journal.jsonl")),
            researchSessionStore: ResearchSessionStore(fileURL: directory.appendingPathComponent("research.jsonl")),
            usageSettingsStore: UsageSettingsStore(fileURL: directory.appendingPathComponent("settings.json")),
            preferences: preferences)
        await model.refresh(trigger: .manual)
        XCTAssertNotNil(model.snapshot, "SMART may succeed independently of temperature history")
        XCTAssertEqual(model.analytics, .empty, "A failed temperature read must not replace the prior analytics")
        XCTAssertTrue(model.lastErrorMessage?.contains("温度履歴を読み込めないため") == true)
    }

    func testServicePrefersAUsableScanCandidateAndUsesFixedArguments() async throws {
        let runner = FixtureRunner(
            scanJSON: """
            {"devices":[{"name":"IOService:/AppleANS3NVMeController/NS_01@1","type":"nvme","open_error":"IOCreatePlugInInterfaceForService failed"}]}
            """,
            deviceJSON: Self.basicFixture
        )
        let service = SmartctlService(runner: runner)
        let report = try await service.probe(capturedAt: Self.date(day: 1))

        XCTAssertEqual(report.snapshot.model, "APPLE SSD AP0256Q")
        XCTAssertEqual(report.snapshot.devicePath, "IOService:/AppleANS3NVMeController/NS_01@1")
        let probeArguments = runner.recordedProbeArguments().first { $0.count == 6 }
        XCTAssertEqual(Array(probeArguments?.prefix(4) ?? []), ["-j", "-i", "-H", "-A"])
        XCTAssertEqual(probeArguments?[4], "-c")
    }

    func testServiceCachesSuccessfulCandidateUntilIdentityFails() async throws {
        let runner = FixtureRunner(
            scanJSON: """
            {"devices":[{"name":"/dev/rdisk0","type":"nvme"}]}
            """,
            deviceJSON: Self.healthFixture
        )
        let service = SmartctlService(runner: runner)

        _ = try await service.probe(capturedAt: Self.date(day: 1))
        _ = try await service.probe(capturedAt: Self.date(day: 2))

        let arguments = runner.recordedProbeArguments()
        XCTAssertEqual(arguments.filter { $0 == ["--scan-open", "-j"] }.count, 1)
        let fullProbeArguments = arguments.filter { $0.count == 6 }
        let uniqueFullProbePaths = Set(fullProbeArguments.compactMap(\.last))
        XCTAssertEqual(fullProbeArguments.count, uniqueFullProbePaths.count + 1)
    }

    func testServiceUsesCachedCandidateForTemperatureOnlyProbe() async throws {
        let runner = FixtureRunner(
            scanJSON: """
            {"devices":[{"name":"/dev/rdisk0","type":"nvme"}]}
            """,
            deviceJSON: Self.healthFixture
        )
        let service = SmartctlService(runner: runner)

        _ = try await service.probe(capturedAt: Self.date(day: 1))
        let reading = try await service.probeTemperature(capturedAt: Self.date(day: 1).addingTimeInterval(30))

        XCTAssertEqual(reading.temperatureCelsius, 54)
        XCTAssertEqual(runner.recordedProbeArguments().filter { $0 == ["--scan-open", "-j"] }.count, 1)
        XCTAssertEqual(runner.recordedProbeArguments().filter { $0.count == 4 }.count, 1)
    }

    func testTemperatureProbeKeepsCachedCandidateWhenSmartctlOmitsIdentityWithoutInfoFlag() async throws {
        let runner = FixtureRunner(
            scanJSON: """
            {"devices":[{"name":"/dev/rdisk0","type":"nvme"}]}
            """,
            deviceJSON: Self.healthFixture,
            omitsIdentityWithoutInfoFlag: true
        )
        let service = SmartctlService(runner: runner)

        _ = try await service.probe(capturedAt: Self.date(day: 1))
        let fullProbeCount = runner.recordedProbeArguments().filter { $0.count == 6 }.count
        for minute in 1...3 {
            _ = try await service.probeTemperature(capturedAt: Self.date(day: 1).addingTimeInterval(Double(minute) * 60))
        }

        let arguments = runner.recordedProbeArguments()
        XCTAssertEqual(arguments.filter { $0 == ["--scan-open", "-j"] }.count, 1)
        XCTAssertEqual(arguments.filter { $0.count == 6 }.count, fullProbeCount)
        XCTAssertEqual(arguments.filter { $0.count == 4 }.count, 3)
    }

    func testServiceAttachesFilesystemCapacityToSnapshot() async throws {
        let runner = FixtureRunner(
            scanJSON: """
            {"devices":[{"name":"/dev/rdisk0","type":"nvme"}]}
            """,
            deviceJSON: Self.healthFixture
        )
        let provider = FixedFilesystemCapacityProvider(
            capacity: FilesystemCapacity(totalBytes: 512_000_000_000, freeBytes: 287_000_000_000)
        )
        let service = SmartctlService(
            runner: runner,
            filesystemCapacityProvider: provider
        )

        let report = try await service.probe(capturedAt: Self.date(day: 1))

        XCTAssertEqual(report.snapshot.filesystemTotalCapacityBytes, 512_000_000_000)
        XCTAssertEqual(report.snapshot.filesystemFreeBytes, 287_000_000_000)
        XCTAssertEqual(report.snapshot.filesystemFreeRatio!, 287.0 / 512.0, accuracy: 0.000_001)
    }

    private func makeSnapshot(
        day: Int,
        written: UInt64?,
        percentage: UInt64? = 5,
        powerHours: UInt64?,
        capturedAt: Date? = nil,
        usageStartDate: Date? = nil,
        deviceID: String = "serial:test-drive",
        serialNumber: String? = "test-drive",
        logicalCapacityBytes: UInt64? = 256_000_000_000,
        firmware: String = "test"
    ) -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: capturedAt ?? Self.date(day: day),
            deviceID: deviceID,
            devicePath: "/dev/rdisk0",
            logicalCapacityBytes: logicalCapacityBytes,
            model: "Test NVMe",
            serialNumber: serialNumber,
            firmware: firmware,
            smartctlVersion: "7.5",
            smartctlExitStatus: 0,
            usageStartDate: usageStartDate,
            temperatureCelsius: 45,
            powerOnHours: powerHours,
            powerCycleCount: 10,
            unsafeShutdowns: 0,
            percentageUsed: percentage,
            availableSpare: 100,
            availableSpareThreshold: 10,
            criticalWarning: 0,
            mediaAndDataIntegrityErrors: 0,
            dataUnitsRead: 1_000,
            dataUnitsWritten: written,
            smartPassed: true
        )
    }

    private static let fixedCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private var fixedCalendar: Calendar { Self.fixedCalendar }

    private static func date(day: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
    }

    private static func writeUInt32LE(_ value: UInt32, to data: inout Data, at offset: Int) {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ]
        data.replaceSubrange(offset..<offset + 4, with: bytes)
    }

    private static func makeASPFTLRecords(_ records: [(UInt32, [UInt64])]) -> Data {
        var data = Data()
        for (key, values) in records {
            let descriptor = (UInt64(values.count) << 32) | UInt64(key)
            var descriptorBytes = [UInt8](repeating: 0, count: MemoryLayout<UInt64>.size)
            for index in 0..<MemoryLayout<UInt64>.size {
                descriptorBytes[index] = UInt8(truncatingIfNeeded: descriptor >> UInt64(index * 8))
            }
            data.append(contentsOf: descriptorBytes)
            for value in values {
                var valueBytes = [UInt8](repeating: 0, count: MemoryLayout<UInt64>.size)
                for index in 0..<MemoryLayout<UInt64>.size {
                    valueBytes[index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
                }
                data.append(contentsOf: valueBytes)
            }
        }
        return data
    }

    private static func aspFTLMetadata(
        kind: String,
        responseBytes: Int,
        capturedAt: Date?
    ) -> String {
        let epoch = capturedAt.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "0"
        let vtable = kind == "all" ? "0x108" : "0x110"
        return """
        build=25G83
        service=GetNVMeSMARTInterface
        plugin_uuid=AA0FA6F9-C2D6-457F-B10B-59A13253292F
        interface_uuid=CCD1DB19-FD9A-4DAF-BF95-12454B230AB6
        kind=\(kind)
        vtable_offset=\(vtable)
        input_arg=null
        role=ASP FTL \(kind) statistics
        euid=0
        captured_at_epoch=\(epoch)
        result=0x00000000
        response_bytes=\(responseBytes)
        capacity_bytes=1048576
        elapsed_ms=10.649
        total_elapsed_ms=10.900
        format_status=unconfirmed
        """
    }

    private static func makeASPTunnelBandPayload(
        bandCount: UInt32,
        partitionCount: UInt32,
        eraseCycles: [UInt32],
        trailingBytes: Int = 0
    ) -> Data {
        precondition(Int(bandCount) == eraseCycles.count)
        var words = [UInt32](repeating: 0, count: 8)
        words[0] = bandCount
        words[1] = partitionCount
        var data = Data()
        for word in words {
            Self.appendUInt32LE(word, to: &data)
        }
        for (index, eraseCycle) in eraseCycles.enumerated() {
            let fields: [UInt32] = [
                UInt32(index),
                eraseCycle,
                UInt32(index + 10),
                UInt32(index + 20),
                UInt32(index + 30),
                UInt32(index + 40),
                UInt32(index + 50),
                UInt32(index + 60)
            ]
            for field in fields {
                Self.appendUInt32LE(field, to: &data)
            }
        }
        if trailingBytes > 0 {
            data.append(contentsOf: [UInt8](repeating: 0, count: trailingBytes))
        }
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ])
    }

    private static func aspTunnelMetadata(
        opcode: String,
        responseBytes: Int,
        requestedBytes: Int,
        capturedAt: Date?,
        sizeQueryResult: String = "0x00000000",
        readResult: String = "0x00000000"
    ) -> String {
        let epoch = capturedAt.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "0"
        return """
        build=25G83
        controller=AppleANS3NVMeController
        selector=9
        opcode=\(opcode)
        euid=0
        captured_at_epoch=\(epoch)
        size_query_result=\(sizeQueryResult)
        size_query_response_bytes=4
        requested_bytes=\(requestedBytes)
        read_result=\(readResult)
        response_bytes=\(responseBytes)
        capacity_bytes=32768
        elapsed_ms=1.250
        total_elapsed_ms=1.500
        format_status=unconfirmed
        """
    }

    private static let basicFixture = """
    {
      "json_format_version": [1, 0],
      "smartctl": {"version": [7, 5], "exit_status": 0},
      "model_name": "APPLE SSD AP0256Q",
      "firmware_version": "561.100.",
      "temperature": {"current": 47},
      "power_on_time": {"hours": 1234},
      "power_cycle_count": 321
    }
    """

    private static let healthFixture = """
    {
      "json_format_version": [1, 0],
      "smartctl": {"version": [7, 5], "exit_status": 0},
      "smart_status": {"passed": true},
      "model_name": "APPLE SSD AP0256Q",
      "firmware_version": "561.100.",
      "temperature": {"current": 54},
      "power_on_time": {"hours": 1200},
      "power_cycle_count": 320,
      "unsafe_shutdowns": 7,
      "nvme_smart_health_information_log": {
        "critical_warning": 0,
        "temperature": 54,
        "available_spare": 100,
        "available_spare_threshold": 99,
        "percentage_used": 5,
        "data_units_read": "123456789",
        "data_units_written": "45678901",
        "media_and_data_integrity_errors": 0
      }
    }
    """

    private static let ioregFixture = """
    +-o AppleANS3NVMeController  <class AppleANS3NVMeController, id 0x1>
      |   \"IOClass\" = \"AppleANS3NVMeController\"
      |   \"AppleNANDStatus\" = \"Ready\"
      |   \"Physical Interconnect\" = \"Apple Fabric\"
      |   \"Physical Interconnect Location\" = \"Internal\"
      |   \"Controller Characteristics\" = {\"default-bits-per-cell\"=3,\"firmware-version\"=\"561.100.\",\"capacity\"=256000000000,\"pages-per-block-mlc\"=1536,\"sec-per-full-band-slc\"=32768,\"bus-to-msp\"=(0,0,1,1),\"num-dip\"=16,\"nand-marketing-name\"=\"tlc_3d_v6_4p_512                \",\"package_blocks_at_EOL\"=10976,\"sec-per-full-band\"=98304,\"cau-per-die\"=4,\"page-size\"=16384,\"pages-per-block-slc\"=512,\"sec-per-page\"=4,\"num-bus\"=4,\"chip-id\"=\"S5E\",\"vendor-name\"=\"Hynix           \",\"blocks-per-cau\"=722,\"dies-per-bus\"=(1,1,1,1),\"msp-version\"=\"4.12.2.0.0.0    \"}
    """
}

private final class FixtureRunner: SmartctlProcessRunning, @unchecked Sendable {
    let scanJSON: String
    let deviceJSON: String
    /// Like real smartctl, leave out the identity fields unless `-i` is given.
    let omitsIdentityWithoutInfoFlag: Bool
    private let lock = NSLock()
    private var probeArguments: [[String]] = []
    private var failure: SmartctlServiceError?

    func setFailure(_ error: SmartctlServiceError?) {
        lock.lock()
        defer { lock.unlock() }
        failure = error
    }

    init(scanJSON: String, deviceJSON: String, omitsIdentityWithoutInfoFlag: Bool = false) {
        self.scanJSON = scanJSON
        self.deviceJSON = deviceJSON
        self.omitsIdentityWithoutInfoFlag = omitsIdentityWithoutInfoFlag
    }

    func run(executable: URL, arguments: [String]) throws -> SmartctlCommandResult {
        _ = executable
        lock.lock()
        probeArguments.append(arguments)
        let failure = failure
        lock.unlock()
        if let failure { throw failure }
        let output: Data
        if arguments == ["--scan-open", "-j"] {
            output = Data(scanJSON.utf8)
        } else if omitsIdentityWithoutInfoFlag, !arguments.contains("-i"),
                  var object = try JSONSerialization.jsonObject(with: Data(deviceJSON.utf8)) as? [String: Any] {
            for key in ["model_name", "serial_number", "user_capacity"] {
                object.removeValue(forKey: key)
            }
            output = try JSONSerialization.data(withJSONObject: object)
        } else {
            output = Data(deviceJSON.utf8)
        }
        return SmartctlCommandResult(stdout: output, stderr: Data(), terminationStatus: 0)
    }

    func recordedProbeArguments() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return probeArguments
    }
}

private struct FixedStorageDeviceLocator: StorageDeviceLocating {
    let locations: [String: StorageDeviceLocation]
    let defaultLocation: StorageDeviceLocation

    init(
        locations: [String: StorageDeviceLocation],
        defaultLocation: StorageDeviceLocation = .unknown
    ) {
        self.locations = locations
        self.defaultLocation = defaultLocation
    }

    func location(forPath path: String) async -> StorageDeviceLocation {
        locations[path] ?? defaultLocation
    }
}

private struct FixedFilesystemCapacityProvider: FilesystemCapacityProviding {
    let capacity: FilesystemCapacity

    func current() -> FilesystemCapacity {
        capacity
    }
}

private final class RecoveringStorageTargetResolver: StorageTargetResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var value = FixtureStorageTargetResolver().resolve(devicePath: "/dev/rdisk0")
    func set(_ value: StorageTargetResolution) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
    func resolve(devicePath: String) -> StorageTargetResolution {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor RecoveringProfileReader {
    private(set) var reads = 0
    private var failing = false
    func fail() { failing = true }
    func read() -> AppleNANDHardwareProfile? {
        reads += 1
        guard !failing else { return nil }
        return AppleNANDHardwareProfile(modelNumber: "APPLE SSD AP0256Q", logicalCapacityBytes: 256_000_000_000,
            nandVendor: "Hynix", nandMarketingName: "tlc_3d_v6_4p_512", pageSize: 16384,
            pagesPerBlockNative: 1536, blocksPerCAU: 722, cauPerDie: 4, numBus: 4, diesPerBus: [1, 1, 1, 1], numDIP: 16)
    }
}
