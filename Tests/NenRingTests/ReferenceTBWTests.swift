import XCTest
@testable import NenRing

final class ReferenceTBWTests: XCTestCase {
    func testDashboardReferenceUsesSameResolverWithoutAppleTendency() throws {
        for (vendor, marketing, capacity) in [
            ("Hynix", "tlc_3d_v7_4p_512", UInt64(1_000_000_000_000)),
            ("Kioxia", "tlc_3d_g8", UInt64(512_000_000_000)),
            ("Samsung", "tlc_3d_g7", UInt64(2_000_000_000_000))
        ] {
            let hardware = profile(vendor: vendor, marketing: marketing, capacity: capacity)
            let resolution = try XCTUnwrap(ReferenceTBW.resolve(profile: hardware, capacityBytes: capacity))
            let forecast = try XCTUnwrap(PeerTBWForecast.make(profile: hardware, capacity: capacity,
                written: 60e12, measuredRate: 100e9, historicalRate: nil, now: Date()))
            XCTAssertEqual(forecast.thresholdBytes, resolution.tbwBytes)
            XCTAssertEqual(forecast.remainingBytes, max(0, resolution.tbwBytes - 60e12))
            XCTAssertEqual(forecast.reference, resolution)
            XCTAssertNil(forecast.reference?.appleTendencyBytes)
        }
        let unknown = try XCTUnwrap(PeerTBWForecast.make(profile: nil, capacity: 256_000_000_000,
            written: 60e12, measuredRate: 0, historicalRate: nil, now: Date()))
        XCTAssertNil(unknown.reference?.entryName)
        XCTAssertNil(unknown.measuredDate)
    }

    private func profile(vendor: String?, marketing: String?, capacity: UInt64) -> AppleNANDHardwareProfile {
        AppleNANDHardwareProfile(modelNumber: "APPLE SSD", logicalCapacityBytes: capacity,
                                 nandVendor: vendor, nandMarketingName: marketing)
    }

    func testHynixV6UsesGoldP31RatingsByNearestCapacity() throws {
        // The reference Mac: 256 GB, Hynix V6 -> 500 GB class, 1000 TBW/TB.
        let small = try XCTUnwrap(ReferenceTBW.resolve(
            profile: profile(vendor: "Hynix           ", marketing: "tlc_3d_v6_4p_512                ", capacity: 256_000_000_000),
            capacityBytes: 256_000_000_000))
        XCTAssertEqual(small.tbwPerTB, 1_000)
        XCTAssertEqual(small.tbwBytes, 256e12, accuracy: 1)
        XCTAssertNotNil(small.entryName)

        let oneTB = try XCTUnwrap(ReferenceTBW.resolve(
            profile: profile(vendor: "Hynix", marketing: "tlc_3d_v6_4p_512", capacity: 1_000_000_000_000),
            capacityBytes: 1_000_000_000_000))
        XCTAssertEqual(oneTB.tbwPerTB, 750)
    }

    func testKioxiaAndUnknownNANDUse600PerTB() throws {
        let bics4 = try XCTUnwrap(ReferenceTBW.resolve(
            profile: profile(vendor: "Toshiba", marketing: "itlc_3d_g4_2p_256", capacity: 512_000_000_000),
            capacityBytes: 512_000_000_000))
        XCTAssertEqual(bics4.tbwPerTB, 600)
        XCTAssertNotNil(bics4.entryName)

        let unknown = try XCTUnwrap(ReferenceTBW.resolve(profile: nil, capacityBytes: 512_000_000_000))
        XCTAssertEqual(unknown.tbwPerTB, ReferenceTBW.defaultTBWPerTB)
        XCTAssertNil(unknown.entryName)
        XCTAssertTrue(unknown.summary.contains("NAND未特定"))

        XCTAssertNil(ReferenceTBW.resolve(profile: nil, capacityBytes: nil))
    }

    func testForecastEvidenceLabelsReferenceTBW() throws {
        let reference = try XCTUnwrap(ReferenceTBW.resolve(profile: nil, capacityBytes: 512_000_000_000))
        var smart = EnduranceForecast(state: .estimated, message: "", estimatedEnduranceBytes: reference.tbwBytes)
        smart.referenceTBW = reference
        let evidence = ForecastEvidence.resolve(ftlTotal: nil, smart: smart)
        XCTAssertEqual(evidence.rowTitle, "実使用（暫定・参考TBWから）")
        UserDefaults.standard.set("ja", forKey: UIString.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: UIString.preferenceKey) }
        XCTAssertTrue(evidence.smartProvisionalNote?.contains("Appleの保証値ではありません") == true)
        XCTAssertEqual(ForecastEvidence.resolve(ftlTotal: 1e15, smart: smart), .ftl)
    }

    func testAppleInternalAddsMeasuredTendencyAboveRetailFloor() throws {
        let profile = profile(vendor: "Hynix", marketing: "tlc_3d_v6_4p_512", capacity: 256_000_000_000)
        let apple = try XCTUnwrap(ReferenceTBW.resolve(profile: profile, capacityBytes: 256_000_000_000, appleInternal: true))
        XCTAssertEqual(apple.tbwBytes, 256e12, accuracy: 1, "retail floor unchanged")
        // 256 GB × 3000 P/E ÷ 0.66 TLC writes per host byte ≈ 1.16 PB.
        XCTAssertEqual(try XCTUnwrap(apple.appleTendencyBytes), 256e9 * 3_000 / 0.66, accuracy: 1)

        let external = try XCTUnwrap(ReferenceTBW.resolve(profile: nil, capacityBytes: 256_000_000_000))
        XCTAssertNil(external.appleTendencyBytes)
    }

    func testForecastUsesRetailFloorAndAppleTendencyForAppleSSD() throws {
        let snapshot = DriveSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), deviceID: "serial:A", devicePath: "/dev/rdisk0",
            logicalCapacityBytes: 256_000_000_000, model: "APPLE SSD AP0256Z", serialNumber: "A", firmware: "1",
            smartctlVersion: nil, smartctlExitStatus: 0, temperatureCelsius: nil, powerOnHours: 100,
            powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: 0, availableSpare: nil,
            availableSpareThreshold: nil, criticalWarning: nil, mediaAndDataIntegrityErrors: nil,
            dataUnitsRead: nil, dataUnitsWritten: 1_000_000, smartPassed: true
        )
        let forecast = HistoryAnalyzer().enduranceForecast(from: [snapshot], deviceID: snapshot.deviceID, now: snapshot.capturedAt)
        let reference = try XCTUnwrap(forecast.referenceTBW)
        XCTAssertEqual(try XCTUnwrap(forecast.enduranceRangeLowerBytes), reference.tbwBytes, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(forecast.estimatedEnduranceBytes), reference.tbwBytes, accuracy: 1,
                       "dates use the retail rating, the conservative end")
        XCTAssertEqual(try XCTUnwrap(forecast.enduranceRangeUpperBytes), try XCTUnwrap(reference.appleTendencyBytes), accuracy: 1,
                       "the reference-Mac extrapolation is the upper end of the range")
        UserDefaults.standard.set("ja", forKey: UIString.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: UIString.preferenceKey) }
        let note = try XCTUnwrap(ForecastEvidence.resolve(ftlTotal: nil, smart: forecast).smartProvisionalNote)
        XCTAssertTrue(note.contains("総量を幅で示します"))
        XCTAssertTrue(note.contains("参照機1台"))
    }

    func testM5GenerationNANDIsRecognized() throws {
        let bics8 = try XCTUnwrap(ReferenceTBW.resolve(
            profile: profile(vendor: "Toshiba", marketing: "tlc_3d_g8_4p_1024", capacity: 1_000_000_000_000),
            capacityBytes: 1_000_000_000_000))
        XCTAssertEqual(bics8.entryName, "Kioxia BiCS8（218層）")
        let samsung = try XCTUnwrap(ReferenceTBW.resolve(
            profile: profile(vendor: "Samsung", marketing: "tlc_3d_g7_4p_1024", capacity: 1_000_000_000_000),
            capacityBytes: 1_000_000_000_000))
        XCTAssertNotNil(samsung.entryName)
        XCTAssertEqual(samsung.tbwPerTB, 600)
        XCTAssertTrue(samsung.generationMappingUnverified)
        XCTAssertTrue(samsung.summary.contains("世代対応未確認"))
        XCTAssertFalse(samsung.summary.contains("と同世代"))
        XCTAssertFalse(bics8.generationMappingUnverified)
    }

    func testIORegistryReadsM5ControllerClass() throws {
        XCTAssertTrue(IORegistryService.controllerClasses.contains("AppleANS3CGv2Controller"))
        // Minimal record shaped like an M5 MacBook Air (values from a public ioreg dump).
        let fixture = """
        +-o AppleANS3CGv2Controller  <class AppleANS3CGv2Controller, id 0x1>
          |   "IOClass" = "AppleANS3CGv2Controller"
          |   "Controller Characteristics" = {"default-bits-per-cell"=3,"firmware-version"="2914.80.","capacity"=1000000000000,"nand-marketing-name"="tlc_3d_g8_4p_1024               ","package_blocks_at_EOL"=20672,"chip-id"="S6E","vendor-name"="Toshiba         ","msp-version"="62.10.4.0.7.0   "}
        """
        let parsed = try XCTUnwrap(try IORegistryProfileParser().parse(data: Data(fixture.utf8), modelNumber: "APPLE SSD AP1024Z"))
        XCTAssertEqual(parsed.controllerClass, "AppleANS3CGv2Controller")
        XCTAssertEqual(parsed.chipID, "S6E")
        XCTAssertEqual(parsed.nandVendor, "Toshiba")
        XCTAssertEqual(parsed.nandMarketingName, "tlc_3d_g8_4p_1024")
        XCTAssertEqual(parsed.logicalCapacityBytes, 1_000_000_000_000)
    }
}
