import Foundation
import XCTest
@testable import NenRing

final class DiagnosticReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let app = DiagnosticReport.App(version: "0.2.0", build: "1", sourceRevision: "abc123")
    private let capabilities = StorageDeviceCapabilities(
        location: .internalDevice, appleDirectFTLEligible: true, usableCandidateCount: 1
    )

    private func host(build: String?) -> DiagnosticHostEnvironment {
        DiagnosticHostEnvironment(hardwareModel: "Mac14,2", cpuBrand: "Apple M2", osVersion: "26.0.0", osBuild: build)
    }

    private func smart() -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: now,
            deviceID: "serial:SECRET-SERIAL-123",
            devicePath: "/dev/rdisk0",
            logicalCapacityBytes: 512_000_000_000,
            model: "APPLE SSD AP0512Z",
            serialNumber: "SECRET-SERIAL-123",
            firmware: "1000",
            smartctlVersion: "7.4",
            smartctlExitStatus: 0,
            temperatureCelsius: 35,
            powerOnHours: 10,
            powerCycleCount: 2,
            unsafeShutdowns: 0,
            percentageUsed: 1,
            availableSpare: 100,
            availableSpareThreshold: 99,
            criticalWarning: 0,
            mediaAndDataIntegrityErrors: 0,
            dataUnitsRead: 100,
            dataUnitsWritten: 200,
            smartPassed: true
        )
    }

    private func ftl(_ date: Date, build: String, firmware: String, deviceID: String? = "serial:SECRET-SERIAL-123",
                     contractBuild: String? = "25G83") -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: date,
            captureQuality: .explicit,
            deviceID: deviceID,
            sourceArtifact: .directFTL,
            sourceBuild: build,
            contractBuild: contractBuild,
            firmware: firmware
        )
    }

    func testCurrentHostEnvironmentReadsModelAndBuild() {
        let current = DiagnosticHostEnvironment.current()
        print("DiagnosticHostEnvironment.current():", current)
        XCTAssertNotNil(current.hardwareModel)
        XCTAssertNotNil(current.osBuild)
        XCTAssertFalse(current.osVersion.isEmpty)
    }

    func testReportOmitsSerialDevicePathAndDeviceID() throws {
        let report = DiagnosticReportBuilder.make(
            host: host(build: "26A123"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [ftl(now, build: "26A123", firmware: "1000")], now: now
        )
        let json = try XCTUnwrap(String(data: DiagnosticReportBuilder.encode(report), encoding: .utf8))

        XCTAssertFalse(json.contains("SECRET-SERIAL-123"))
        XCTAssertFalse(json.contains("rdisk0"))
        XCTAssertFalse(json.contains("serial:"))
        XCTAssertTrue(json.contains("APPLE SSD AP0512Z"))
        XCTAssertTrue(json.contains("Mac14,2"))
        XCTAssertEqual(report.storage?.location, "internalDevice")
    }

    func testSharingNamesTheFileAndPrefillsOnlyTheIssueTitle() throws {
        let report = DiagnosticReportBuilder.make(
            host: host(build: "26A123"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [ftl(now, build: "26A123", firmware: "1000")], now: now
        )

        XCTAssertEqual(DiagnosticReportSharing.fileName(for: report), "nenring-report-2027-01-15-Mac14,2.json")
        XCTAssertEqual(DiagnosticReportSharing.issueTitle(for: report), "[Report] Mac14,2 / 512 GB / macOS 26.0.0 (26A123)")
        let url = DiagnosticReportSharing.issueURL(for: report)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["template", "title"], "the link carries nothing but the template and title")
        XCTAssertEqual(items.first?.value, "diagnostic-report.yml")
        XCTAssertFalse(url.absoluteString.contains("SECRET-SERIAL"))
        XCTAssertEqual(DiagnosticReportSharing.summary(for: report).map(\.value),
                       ["Mac14,2 · Apple M2", "26.0.0 (26A123)", "APPLE SSD AP0512Z · 512 GB", "保存済みの値あり"])
    }

    func testSharingFileNameKeepsOnlySafeCharacters() {
        let report = DiagnosticReportBuilder.make(
            host: DiagnosticHostEnvironment(hardwareModel: "Mac/14 2", cpuBrand: nil, osVersion: "26.0.0", osBuild: nil),
            app: app, smart: nil, capabilities: .unknown, profile: nil, ftlSnapshots: [], now: now)

        XCTAssertEqual(DiagnosticReportSharing.fileName(for: report), "nenring-report-2027-01-15-Mac-14-2.json")
        XCTAssertEqual(DiagnosticReportSharing.issueTitle(for: report), "[Report] Mac/14 2 / unknown capacity / macOS 26.0.0")
        XCTAssertEqual(DiagnosticReportSharing.summary(for: report)[2].value, "SMART未取得")
    }

    func testMissingSMARTAndFTLReportKeepsMissingValuesMissing() throws {
        let report = DiagnosticReportBuilder.make(host: host(build: "27A123"), app: app,
            smart: nil, capabilities: .unknown, profile: nil, ftlSnapshots: [], now: now)
        XCTAssertNil(report.storage)
        XCTAssertNil(report.latestFTLSnapshot)
        XCTAssertTrue(report.observedInstruments.isEmpty)
        XCTAssertTrue(report.notes.contains { $0.contains("SMART unavailable") })
        XCTAssertTrue(report.notes.contains { $0.contains("No Direct FTL") })
        let json = try XCTUnwrap(String(data: DiagnosticReportBuilder.encode(report), encoding: .utf8))
        XCTAssertFalse(json.contains("SECRET-SERIAL"))
        XCTAssertFalse(json.contains("rdisk"))
    }

    func testExternalDeviceDoesNotExportAnotherDevicesInternalFTL() {
        let external = StorageDeviceCapabilities(location: .externalDevice,
            appleDirectFTLEligible: false, usableCandidateCount: 2)
        let report = DiagnosticReportBuilder.make(host: host(build: "26A123"), app: app,
            smart: smart(), capabilities: external, profile: nil,
            ftlSnapshots: [ftl(now, build: "26A123", firmware: "1000", deviceID: "internal-device")], now: now)
        XCTAssertEqual(report.storage?.location, "externalDevice")
        XCTAssertNil(report.latestFTLSnapshot)
        XCTAssertTrue(report.observedInstruments.isEmpty)
    }

    func testReportOmitsUnknownAndOtherDeviceRecords() {
        let snapshots = [
            ftl(now.addingTimeInterval(-30), build: "25G83", firmware: "selected"),
            ftl(now.addingTimeInterval(-20), build: "25G83", firmware: "other", deviceID: "serial:OTHER"),
            ftl(now, build: "25G83", firmware: "unidentified", deviceID: nil)
        ]
        let report = DiagnosticReportBuilder.make(host: host(build: "25G83"), app: app,
            smart: smart(), capabilities: capabilities, profile: nil, ftlSnapshots: snapshots, now: now)
        XCTAssertEqual(report.latestFTLSnapshot?.firmware, "selected")
        XCTAssertEqual(report.observedInstruments.map(\.firmware), ["selected"])

        let missing = DiagnosticReportBuilder.make(host: host(build: "25G83"), app: app,
            smart: nil, capabilities: .unknown, profile: nil, ftlSnapshots: snapshots, now: now)
        XCTAssertNil(missing.latestFTLSnapshot)
        XCTAssertTrue(missing.observedInstruments.isEmpty)

        var emptyIdentity = smart()
        emptyIdentity.deviceID = ""
        let empty = DiagnosticReportBuilder.make(host: host(build: "25G83"), app: app,
            smart: emptyIdentity, capabilities: capabilities, profile: nil, ftlSnapshots: snapshots, now: now)
        XCTAssertNil(empty.latestFTLSnapshot)

        let external = StorageDeviceCapabilities(location: .externalDevice,
            appleDirectFTLEligible: false, usableCandidateCount: 1)
        let externalReport = DiagnosticReportBuilder.make(host: host(build: "25G83"), app: app,
            smart: smart(), capabilities: external, profile: nil, ftlSnapshots: snapshots, now: now)
        XCTAssertNil(externalReport.latestFTLSnapshot)
        XCTAssertTrue(externalReport.observedInstruments.isEmpty)
    }

    func testLegacyFixedBuildLabelIsReportedAsInferredNotAsRecordedBuild() {
        let snapshots = [
            // Pre-provenance probe: stored "25G83" as a fixed label after the firmware update.
            ftl(now.addingTimeInterval(-200), build: "25G83", firmware: "591", contractBuild: nil),
            ftl(now.addingTimeInterval(-100), build: "26A428", firmware: "591")
        ]
        let report = DiagnosticReportBuilder.make(
            host: host(build: "26A428"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: snapshots, now: now
        )

        XCTAssertEqual(report.observedInstruments.map(\.sourceBuild), ["unrecorded-after-fw-591", "26A428"])
        XCTAssertEqual(report.observedInstruments.map(\.buildProvenance), ["inferred", "recorded"])
        XCTAssertEqual(report.latestFTLSnapshot?.buildProvenance, "recorded")
    }

    func testEncodedDatesAreRoundedToUTCDays() throws {
        let report = DiagnosticReportBuilder.make(
            host: host(build: "26A123"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [ftl(now.addingTimeInterval(-100), build: "26A123", firmware: "1000")], now: now
        )
        let json = try XCTUnwrap(String(data: DiagnosticReportBuilder.encode(report), encoding: .utf8))

        XCTAssertNil(json.range(of: #"\d{2}:\d{2}"#, options: .regularExpression))
        // 1_800_000_000 is 2027-01-15T08:00:00Z.
        XCTAssertTrue(json.contains(#""generatedAt" : "2027-01-15""#))
        XCTAssertTrue(json.contains(#""schemaVersion" : 3"#))
    }

    func testReportListsEnvironmentsCheckedAgainstAnASPToolLog() throws {
        let records = [
            ASPToolVerifiedEnvironment(sourceBuild: "26B123", firmware: "591.40.3", macOSVersion: "27.2",
                                       logCapturedAt: now.addingTimeInterval(-3_600), recordedAt: now),
            ASPToolVerifiedEnvironment(sourceBuild: "26A100", firmware: "591", macOSVersion: nil,
                                       logCapturedAt: now.addingTimeInterval(-86_400), recordedAt: now)
        ]
        let report = DiagnosticReportBuilder.make(
            host: host(build: "26B123"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [], asptoolVerifiedEnvironments: records, now: now
        )
        XCTAssertEqual(report.asptoolVerifiedEnvironments.map(\.sourceBuild), ["26A100", "26B123"])
        XCTAssertEqual(report.asptoolVerifiedEnvironments.last?.macOSVersion, "27.2")
        let json = try XCTUnwrap(String(data: DiagnosticReportBuilder.encode(report), encoding: .utf8))
        XCTAssertTrue(json.contains(#""firmware" : "591.40.3""#))
        // The local record time is not exported; the log date is a UTC day.
        XCTAssertFalse(json.contains("recordedAt"))
        XCTAssertTrue(json.contains(#""logCapturedAt" : "2027-01-15""#))
        XCTAssertEqual(DiagnosticReportBuilder.make(
            host: host(build: "26B123"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [], now: now).asptoolVerifiedEnvironments, [])
    }

    func testContractMatchReflectsRunningBuild() {
        let reviewed = DiagnosticReportBuilder.make(
            host: host(build: "25G83"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [], now: now
        )
        XCTAssertEqual(reviewed.directFTLContract.matchedContractBuild, "25G83")
        XCTAssertEqual(reviewed.directFTLContract.reviewStatus, "reviewed")
        // The controller is not gated; a reviewed release is enough.
        XCTAssertEqual(reviewed.directFTLContract.executionReview, "reviewed")

        let other = DiagnosticReportBuilder.make(
            host: host(build: "27A123"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [], now: now
        )
        XCTAssertNil(other.directFTLContract.matchedContractBuild)
        XCTAssertEqual(other.directFTLContract.reviewStatus, "unreviewed")
        XCTAssertTrue(other.notes.contains { $0.contains("no reviewed Direct FTL contract") })

        let trial = DiagnosticReportBuilder.make(
            host: host(build: "23G90"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [], now: now
        )
        XCTAssertEqual(trial.directFTLContract.executionReview, "compatibilityTrial")
        XCTAssertEqual(trial.directFTLContract.reviewStatus, "unreviewed")
        XCTAssertNil(trial.directFTLContract.matchedContractBuild)
        XCTAssertTrue(trial.notes.contains { $0.contains("compatibility trial") })

        let local = DiagnosticReportBuilder.make(
            host: host(build: "24G90"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: [], locallyVerifiedMacOSMajors: [15], now: now
        )
        XCTAssertEqual(local.directFTLContract.executionReview, "locallyVerified")
        XCTAssertTrue(local.notes.contains { $0.contains("passed the SMART cross-check") })
    }

    func testTargetReportExportsCountsButNoRegistryIdentity() throws {
        let binding = StorageTargetBinding(smartServiceID: 9999999901, controllerEntryID: 9999999902,
            wholeMediaID: 9999999903, controllerClass: "AppleANS3NVMeController", wholeMediaCount: 1,
            appleSMARTServiceCount: 2, mediaUUID: "SECRET-MEDIA-UUID")
        let report = DiagnosticReportBuilder.make(host: host(build: "26A434"), app: app,
            smart: smart(), capabilities: capabilities, profile: nil, ftlSnapshots: [],
            targetResolution: .init(state: .matched, binding: binding, reason: "matched"), now: now)
        XCTAssertEqual(report.directFTLContract.targetSelection?.appleSMARTServiceCount, 2)
        XCTAssertEqual(report.directFTLContract.targetSelection?.scope, "singleWholeMedia")
        let json = try XCTUnwrap(String(data: DiagnosticReportBuilder.encode(report), encoding: .utf8))
        XCTAssertFalse(json.contains("999999990"))
        XCTAssertFalse(json.contains("SECRET-MEDIA"))
        XCTAssertFalse(json.contains("/dev/"))
    }

    func testObservedInstrumentsGroupBuildAndFirmwareForSelectedDevice() {
        let snapshots = [
            ftl(now.addingTimeInterval(-300), build: "25G83", firmware: "561"),
            ftl(now.addingTimeInterval(-200), build: "25G83", firmware: "561"),
            ftl(now.addingTimeInterval(-100), build: "26A123", firmware: "591"),
            ftl(now, build: "26A123", firmware: "591", deviceID: "serial:OTHER")
        ]
        let report = DiagnosticReportBuilder.make(
            host: host(build: "26A123"), app: app, smart: smart(), capabilities: capabilities,
            profile: nil, ftlSnapshots: snapshots, now: now
        )

        XCTAssertEqual(report.observedInstruments.map(\.sourceBuild), ["25G83", "26A123"])
        XCTAssertEqual(report.observedInstruments.map(\.snapshotCount), [2, 1])
        XCTAssertEqual(report.latestFTLSnapshot?.firmware, "591")
        XCTAssertEqual(report.latestFTLSnapshot?.capturedAt, now.addingTimeInterval(-100))
    }
}
