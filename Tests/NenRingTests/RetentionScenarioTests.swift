import XCTest
@testable import NenRing

final class RetentionScenarioTests: XCTestCase {
    func testArrheniusFactorAt1Point1EV() {
        XCTAssertEqual(RetentionScenario.accelerationFactor(storageTemperatureCelsius: 30), 1, accuracy: 1e-12)
        XCTAssertEqual(RetentionScenario.accelerationFactor(storageTemperatureCelsius: 40), 3.84, accuracy: 0.02)
        XCTAssertEqual(RetentionScenario.accelerationFactor(storageTemperatureCelsius: 55), 24.7, accuracy: 0.2)
        // Below 25 °C the factor is held at 25 °C instead of extrapolating.
        XCTAssertEqual(RetentionScenario.accelerationFactor(storageTemperatureCelsius: 10),
                       RetentionScenario.accelerationFactor(storageTemperatureCelsius: 25), accuracy: 1e-12)
    }

    func testAllowablePEFollowsAnchorAndCapsAtEOL() throws {
        XCTAssertEqual(try XCTUnwrap(RetentionScenario.allowablePE(reference: 3_000, eol: 3_000, storageTemperatureCelsius: 30, powerOffDays: 365)), 3_000, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(RetentionScenario.allowablePE(reference: 3_000, eol: 3_000, storageTemperatureCelsius: 40, powerOffDays: 365)), 781, accuracy: 5)
        // Shorter storage at 30 °C would allow more than EOL; capped.
        XCTAssertEqual(try XCTUnwrap(RetentionScenario.allowablePE(reference: 3_000, eol: 3_000, storageTemperatureCelsius: 30, powerOffDays: 30)), 3_000)
        XCTAssertNil(RetentionScenario.allowablePE(reference: 3_000, eol: 3_000, storageTemperatureCelsius: 30, powerOffDays: 0))
    }

    func testScenarioUsesMaximumTLCPEAndKeepsPSLCLimit() throws {
        let capacity = 642.0 * 16_384 * 24_576
        let tlc = NANDDomainEstimate(domain: .tlc, capacityBytes: capacity, physicalFootprintBytes: capacity,
                                     currentPE: 168, eolPE: 3_000, targetPE: 3_000,
                                     baselineBudgetBytes: capacity * 3_000, totalBudgetBytes: capacity * 3_000,
                                     usedBytes: capacity * 168, remainingBytes: capacity * 2_832)
        let scenario = try XCTUnwrap(RetentionScenario.evaluate(
            tlc: tlc, tlcMaximumPE: 184, tlcWritesPerHostByte: 0.66, pslcRemainingHostBytes: 1.1e15,
            storageTemperatureCelsius: 40, storageTemperatureSource: "test", powerOffDays: 365
        ))
        XCTAssertEqual(scenario.remainingHostBytes, capacity * (scenario.allowableTLCPE - 184) / 0.66, accuracy: 1)
        XCTAssertEqual(scenario.currentTLCPE, 184)
        XCTAssertFalse(scenario.scenarioLimitReached)
        XCTAssertLessThan(scenario.remainingHostBytesLower, scenario.remainingHostBytes)
        XCTAssertEqual(scenario.title, "保持考慮")
        XCTAssertEqual(scenario.conditionSummary, "365日 · 40°C")
        XCTAssertTrue(scenario.explanation.contains("電源OFF"))
        XCTAssertTrue(scenario.explanation.contains("保証ではありません"))

        // At the anchor the scenario is bounded by pSLC like the central forecast.
        let anchor = try XCTUnwrap(RetentionScenario.evaluate(
            tlc: tlc, tlcMaximumPE: 184, tlcWritesPerHostByte: 0.66, pslcRemainingHostBytes: 1.0e15,
            storageTemperatureCelsius: 30, storageTemperatureSource: "test", powerOffDays: 365
        ))
        XCTAssertEqual(anchor.remainingHostBytes, 1.0e15, accuracy: 1)
        let exhausted = try XCTUnwrap(RetentionScenario.evaluate(
            tlc: tlc, tlcMaximumPE: 900, tlcWritesPerHostByte: 0.66, pslcRemainingHostBytes: nil,
            storageTemperatureCelsius: 40, storageTemperatureSource: "test", powerOffDays: 365))
        XCTAssertTrue(exhausted.scenarioLimitReached)
        XCTAssertEqual(exhausted.remainingHostBytes, 0)
    }
}
