import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import NenRing

final class SMARTAdditionalInformationTests: XCTestCase {
    private func snapshot(at seconds: Double = 100, reads: UInt64 = 10, writes: UInt64 = 20,
                          busy: UInt64 = 0, errors: UInt64 = 0, units: UInt64 = 10,
                          firmware: String = "test-fw") throws -> DriveSnapshot {
        try SmartctlJSONParser().parse(data: Data("""
        {"model_name":"Test NVMe","firmware_version":"\(firmware)",
         "nvme_smart_health_information_log":{"host_reads":"\(reads)",
          "host_writes":\(writes),"controller_busy_time":\(busy),"num_err_log_entries":\(errors),
          "data_units_read":\(units),"data_units_written":\(units)},
         "nvme_optional_admin_commands":{"value":4},
         "nvme_optional_nvm_commands":{"value":4},
         "nvme_log_page_attributes":{"value":0},
         "nvme_firmware_update_capabilities":{"slots":1},
         "nvme_maximum_data_transfer_pages":256}
        """.utf8), capturedAt: Date(timeIntervalSince1970: seconds), devicePath: "/dev/test")
    }

    func testParsesAdditionalCountersAndReportedCapabilities() throws {
        let s = try snapshot()
        XCTAssertEqual(s.additionalSMART, SMARTAdditionalCounters(hostReadCommands: 10,
            hostWriteCommands: 20, controllerBusyMinutes: 0, errorLogEntries: 0))
        XCTAssertEqual(s.nvmeCapabilities?.selfTestSupported, false)
        XCTAssertEqual(s.nvmeCapabilities?.deallocateSupported, true)
        XCTAssertEqual(s.nvmeCapabilities?.telemetrySupported, false)
        XCTAssertEqual(s.nvmeCapabilities?.firmwareSlots, 1)
        XCTAssertEqual(s.nvmeCapabilities?.maximumTransferPages, 256)
        let unsupported = NVMeCapabilities(nvmCommands: 0)
        XCTAssertEqual(unsupported.deallocateSupported, false)
        XCTAssertNil(unsupported.selfTestSupported)
        XCTAssertEqual(NVMeCapabilities(adminCommands: 16, logPageAttributes: 8).selfTestSupported, true)
        XCTAssertEqual(NVMeCapabilities(adminCommands: 16, logPageAttributes: 8).telemetrySupported, true)
    }

    func testCountersAtTheTopOfUInt64DoNotCrashTheParser() throws {
        // Both round to exactly 2^64 as a Double, one past UInt64.max.
        for value in ["\(UInt64.max)", "\"18446744073709551616\""] {
            let s = try SmartctlJSONParser().parse(data: Data("""
            {"model_name":"Test NVMe","nvme_smart_health_information_log":{"data_units_written":\(value)}}
            """.utf8), capturedAt: Date(timeIntervalSince1970: 100), devicePath: "/dev/test")
            XCTAssertNil(s.dataUnitsWritten, value)
        }
    }

    func testMissingMetadataIsNotUnsupportedOrZero() throws {
        let s = try SmartctlJSONParser().parse(data: Data("{}".utf8),
            capturedAt: Date(), devicePath: "/dev/test")
        XCTAssertNil(s.additionalSMART)
        XCTAssertNil(s.nvmeCapabilities)
        XCTAssertNil(IORegistryService.unmapSupport(in: [:]))
        XCTAssertEqual(IORegistryService.unmapSupport(in: ["IOStorageFeatures": ["Unmap": true]]), true)
        XCTAssertEqual(IORegistryService.unmapSupport(in: ["IOStorageFeatures": ["Unmap": false]]), false)
        XCTAssertNil(IORegistryService.unmapSupport(in: ["IOStorageFeatures": ["Unmap": "unknown"]]))
    }

    func testRequestSizeUsesSmallUnitsRatherThanRoundingToZeroGB() {
        XCTAssertTrue(SMARTRequestSizeFormatter.string(460_800)?.contains("kB") == true)
        XCTAssertTrue(SMARTRequestSizeFormatter.string(0)?.contains("B") == true)
        XCTAssertTrue(SMARTRequestSizeFormatter.string(1_048_576)?.contains("MB") == true)
        XCTAssertNil(SMARTRequestSizeFormatter.string(nil))
        XCTAssertNil(SMARTRequestSizeFormatter.string(.infinity))
        XCTAssertNil(SMARTRequestSizeFormatter.string(-1))
    }

    func testDeltasAndAverageSizesUseSameInterval() throws {
        let a = try snapshot()
        let b = try snapshot(at: 200, reads: 15, writes: 30, busy: 2, errors: 3, units: 20)
        let interval = SMARTCounterInterval.make(history: [b, a], deviceID: a.deviceID)
        XCTAssertEqual(interval.start, a.capturedAt)
        XCTAssertEqual(interval.end, b.capturedAt)
        XCTAssertEqual(interval.readCommands.value, 5)
        XCTAssertEqual(interval.writeCommands.value, 10)
        XCTAssertEqual(interval.busyMinutes.value, 2)
        XCTAssertEqual(interval.errorLogEntries.value, 3)
        XCTAssertEqual(interval.averageReadBytes, 10 * 512_000 / 5)
        XCTAssertEqual(interval.averageWriteBytes, 10 * 512_000 / 10)
    }

    func testResetIsLocalAndDoesNotUnderflowOrInventAnAverage() throws {
        let a = try snapshot(reads: 100, errors: 5)
        let b = try snapshot(at: 200, reads: 1, writes: 30, errors: 0, units: 20)
        let interval = SMARTCounterInterval.make(history: [a, b], deviceID: a.deviceID)
        XCTAssertEqual(interval.readCommands.state, .reset)
        XCTAssertEqual(interval.errorLogEntries.state, .reset)
        XCTAssertNil(interval.readCommands.value)
        XCTAssertNil(interval.averageReadBytes)
        XCTAssertEqual(interval.writeCommands.value, 10)
        XCTAssertEqual(interval.busyMinutes.value, 0)
    }

    func testFirmwareAndTimeBoundariesDeferComparison() throws {
        let a = try snapshot()
        for b in [try snapshot(at: 200, firmware: "new-fw"), try snapshot(at: 100)] {
            let interval = SMARTCounterInterval.make(history: [a, b], deviceID: a.deviceID)
            XCTAssertEqual(interval.writeCommands.state, .boundary)
            XCTAssertNil(interval.averageWriteBytes)
        }
    }

    func testDeviceFilteringFirstReadMissingCountersAndNoCommands() throws {
        let a = try snapshot()
        var other = try snapshot(at: 300, reads: 999)
        other.deviceID = "other-device"
        let first = SMARTCounterInterval.make(history: [a, other], deviceID: a.deviceID)
        XCTAssertEqual(first.readCommands.state, .noBaseline)
        XCTAssertEqual(first.end, a.capturedAt)
        let b = try snapshot(at: 200)
        let same = SMARTCounterInterval.make(history: [a, b], deviceID: a.deviceID)
        XCTAssertEqual(same.readCommands.value, 0)
        XCTAssertNil(same.averageReadBytes)
        var missing = b
        missing.additionalSMART = nil
        XCTAssertEqual(SMARTCounterInterval.make(history: [a, missing], deviceID: a.deviceID).readCommands.state, .missing)
        XCTAssertEqual(SMARTCounterInterval.make(history: [a, b], deviceID: nil), .empty)
    }

    func testOldJSONAndNewMetadataRoundTrip() throws {
        let s = try snapshot()
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(s)) as? [String: Any])
        json.removeValue(forKey: "additionalSMART")
        json.removeValue(forKey: "nvmeCapabilities")
        let old = try JSONDecoder().decode(DriveSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.additionalSMART)
        XCTAssertNil(old.nvmeCapabilities)
        XCTAssertEqual(try JSONDecoder().decode(DriveSnapshot.self, from: encoder.encode(s)), s)
        let profile = AppleNANDHardwareProfile()
        XCTAssertNil(try JSONDecoder().decode(AppleNANDHardwareProfile.self, from: encoder.encode(profile)).unmapSupported)
        var withTrim = profile
        withTrim.unmapSupported = true
        XCTAssertEqual(try JSONDecoder().decode(AppleNANDHardwareProfile.self, from: encoder.encode(withTrim)).unmapSupported, true)
    }

    func testLosslessHistoryPreservesCountersAndCapabilities() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("smart-extra-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.jsonl")
        let store = HistoryStore(fileURL: url)
        for i in 0..<257 {
            let record = try snapshot(at: Double(i) * 600 + 100, writes: UInt64(i))
            _ = try await store.appendIfNew(record)
        }
        let reloaded = try await HistoryStore(fileURL: url).records()
        XCTAssertEqual(reloaded.count, 257)
        XCTAssertEqual(reloaded.last?.additionalSMART?.hostWriteCommands, 256)
        XCTAssertEqual(reloaded.first?.additionalSMART?.hostWriteCommands, 0)
        XCTAssertEqual(reloaded.last?.nvmeCapabilities?.deallocateSupported, true)
        XCTAssertEqual(reloaded.last?.rawJSON, "")
    }

    @MainActor
    func testOptInAdditionalDiskInformationPreview() throws {
        guard let root = ProcessInfo.processInfo.environment["NENRING_SMART_PREVIEW_ROOT"] else {
            throw XCTSkip("Preview requires an explicit output directory")
        }
        let directory = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = try snapshot()
        let after = try snapshot(at: 700, reads: 110, writes: 220, units: 100)
        var profile = AppleNANDHardwareProfile(modelNumber: "Test NVMe")
        profile.unmapSupported = true
        let interval = SMARTCounterInterval.make(history: [before, after], deviceID: after.deviceID)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = NSHostingView(rootView: DiskInformationContent(snapshot: after, profile: profile,
                counterInterval: interval).padding(24).frame(width: 1100)
                .background(AppColor.canvas).preferredColorScheme(scheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = window.contentLayoutRect
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("smart-additional-\(name).png"))
        }
    }
}
