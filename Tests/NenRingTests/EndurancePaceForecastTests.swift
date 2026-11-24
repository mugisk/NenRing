import Foundation
import XCTest
@testable import NenRing

final class EndurancePaceForecastTests: XCTestCase {
    func testProjectsSameRemainingBudgetAgainstCurrentAndLongTermPaces() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let remaining = 365.2425 * 86_400 * 10

        let current = try XCTUnwrap(EndurancePaceForecast.arrivalDate(
            remainingHostBytes: remaining,
            hostBytesPerDay: 2 * 86_400,
            now: now
        ))
        let longTerm = try XCTUnwrap(EndurancePaceForecast.arrivalDate(
            remainingHostBytes: remaining,
            hostBytesPerDay: 86_400,
            now: now
        ))

        XCTAssertEqual(current.timeIntervalSince(now), remaining / (2 * 86_400) * 86_400, accuracy: 1)
        XCTAssertEqual(longTerm.timeIntervalSince(now), remaining, accuracy: 1)
        XCTAssertGreaterThan(longTerm, current)
    }

    func testZeroRemainingIsReachedNowButInvalidOrZeroPaceHasNoDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(EndurancePaceForecast.arrivalDate(
            remainingHostBytes: 0, hostBytesPerDay: 1, now: now
        ), now)
        XCTAssertNil(EndurancePaceForecast.arrivalDate(
            remainingHostBytes: 100, hostBytesPerDay: 0, now: now
        ))
        XCTAssertNil(EndurancePaceForecast.arrivalDate(
            remainingHostBytes: .infinity, hostBytesPerDay: 100, now: now
        ))
    }
}
