import Foundation
import XCTest
@testable import NenRing

final class SmartctlMediaErrorsTests: XCTestCase {
    func testSmartctl75ZeroIsAnObservedValue() throws {
        let snapshot = try parse("""
        {"nvme_smart_health_information_log":{"media_errors":0}}
        """)
        XCTAssertEqual(snapshot.mediaAndDataIntegrityErrors, 0)
        XCTAssertFalse(snapshot.healthMetricsMissing.contains(.mediaAndDataIntegrityErrors))
        XCTAssertFalse(SMARTWarningReason.collect(from: snapshot).contains(.mediaErrors))
    }

    func testSmartctl75NonzeroCounterReachesDashboardWarning() throws {
        let snapshot = try parse("""
        {"smart_status":{"passed":true},
         "nvme_smart_health_information_log":{"media_errors":7}}
        """)
        XCTAssertEqual(snapshot.mediaAndDataIntegrityErrors, 7)
        XCTAssertEqual(SMARTWarningReason.collect(from: snapshot), [.mediaErrors])
        XCTAssertEqual(SmartStatusCardContent.make(snapshot: snapshot).tone, .warning)
    }

    func testCanonicalAndLegacyKeysAtBothLocations() throws {
        for healthFields in [
            "\"nvme_smart_health_information_log\":{\"media_errors\":\"42\"}",
            "\"nvme_smart_health_information_log\":{\"media_and_data_integrity_errors\":\"42\"}",
            "\"media_errors\":\"42\"",
            "\"media_and_data_integrity_errors\":\"42\""
        ] {
            let snapshot = try parse("{\(healthFields)}")
            XCTAssertEqual(snapshot.mediaAndDataIntegrityErrors, 42, healthFields)
        }
    }

    func testCanonicalNestedKeyWinsIncludingZero() throws {
        let snapshot = try parse("""
        {"nvme_smart_health_information_log":{
           "media_errors":0,"media_and_data_integrity_errors":9},
         "media_errors":10,"media_and_data_integrity_errors":11}
        """)
        XCTAssertEqual(snapshot.mediaAndDataIntegrityErrors, 0)
    }

    func testNestedLegacyKeyKeepsPriorityOverTopLevelFallback() throws {
        let snapshot = try parse("""
        {"nvme_smart_health_information_log":{"media_and_data_integrity_errors":4},
         "media_errors":8}
        """)
        XCTAssertEqual(snapshot.mediaAndDataIntegrityErrors, 4)
    }

    func testUnavailableValuesStayMissing() throws {
        for json in [
            "{}",
            "{\"nvme_smart_health_information_log\":{}}",
            "{\"nvme_smart_health_information_log\":{\"media_errors\":null}}",
            "{\"nvme_smart_health_information_log\":{\"media_errors\":\"unavailable\"}}"
        ] {
            let snapshot = try parse(json)
            XCTAssertNil(snapshot.mediaAndDataIntegrityErrors, json)
            XCTAssertTrue(snapshot.healthMetricsMissing.contains(.mediaAndDataIntegrityErrors), json)
            XCTAssertFalse(SMARTWarningReason.collect(from: snapshot).contains(.mediaErrors), json)
        }
    }

    func testInvalidCanonicalValueCanUseLegacyCounter() throws {
        let snapshot = try parse("""
        {"nvme_smart_health_information_log":{
           "media_errors":null,"media_and_data_integrity_errors":3}}
        """)
        XCTAssertEqual(snapshot.mediaAndDataIntegrityErrors, 3)
    }

    private func parse(_ json: String) throws -> DriveSnapshot {
        try SmartctlJSONParser().parse(
            data: Data(json.utf8),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            devicePath: "/dev/disk0"
        )
    }
}
