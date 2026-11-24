import XCTest
@testable import NenRing

final class MenuBarSummaryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func snapshot(_ at: Date, units: UInt64, device: String = "disk0") -> DriveSnapshot {
        DriveSnapshot(
            capturedAt: at, deviceID: device, devicePath: "/dev/rdisk0", logicalCapacityBytes: 256_000_000_000,
            model: "APPLE SSD", serialNumber: nil, firmware: "591", smartctlVersion: nil, smartctlExitStatus: 0,
            temperatureCelsius: 45, powerOnHours: nil, powerCycleCount: nil, unsafeShutdowns: nil, percentageUsed: 5,
            availableSpare: nil, availableSpareThreshold: nil, criticalWarning: 0, mediaAndDataIntegrityErrors: nil,
            dataUnitsRead: nil, dataUnitsWritten: units, smartPassed: true
        )
    }

    func testTodayWritesUseTheLastReadingBeforeMidnight() throws {
        // 1 data unit = 512,000 bytes; 20,000 units ≈ 10.24 GB.
        let history = [
            snapshot(date(3, 20), units: 100_000),
            snapshot(date(3, 23), units: 110_000),   // baseline: last before midnight
            snapshot(date(4, 9), units: 120_000),
            snapshot(date(4, 9), units: 999_999, device: "other")
        ]
        let latest = snapshot(date(4, 14), units: 130_000)
        let bytes = try XCTUnwrap(TodayHostWrites.bytes(history: history + [latest], latest: latest, now: date(4, 14), calendar: calendar))
        XCTAssertEqual(bytes, 20_000 * 512_000, accuracy: 1)
    }

    func testTodayWritesDoNotDependOnHistoryOrder() throws {
        let history = [
            snapshot(date(3, 20), units: 100_000),
            snapshot(date(3, 23), units: 110_000),
            snapshot(date(4, 2), units: 112_000),
            snapshot(date(4, 9), units: 120_000)
        ]
        let latest = snapshot(date(4, 14), units: 130_000)
        for ordered in [history, history.reversed(), [history[2], history[0], history[3], history[1]]] {
            let bytes = try XCTUnwrap(TodayHostWrites.bytes(history: ordered + [latest], latest: latest, now: date(4, 14), calendar: calendar))
            XCTAssertEqual(bytes, 20_000 * 512_000, accuracy: 1)
        }
        // Without a recent pre-midnight reading, the earliest reading of the day is the baseline.
        let todayOnly = [history[3], history[2]]
        let fallback = try XCTUnwrap(TodayHostWrites.bytes(history: todayOnly + [latest], latest: latest, now: date(4, 14), calendar: calendar))
        XCTAssertEqual(fallback, 18_000 * 512_000, accuracy: 1)
    }

    func testTodayWritesFallBackToTheFirstReadingOfTheDay() throws {
        // The last reading before midnight is too old to be a baseline.
        let history = [snapshot(date(1, 12), units: 50_000), snapshot(date(4, 8), units: 120_000)]
        let latest = snapshot(date(4, 14), units: 125_000)
        let bytes = try XCTUnwrap(TodayHostWrites.bytes(history: history + [latest], latest: latest, now: date(4, 14), calendar: calendar))
        XCTAssertEqual(bytes, 5_000 * 512_000, accuracy: 1)
        // No reading today yet.
        XCTAssertNil(TodayHostWrites.bytes(history: history, latest: history[0], now: date(4, 14), calendar: calendar))
    }

    func testLabelJoinsTheSelectedValuesInOneLine() {
        // Year units are checked in Japanese whatever the Mac's language is.
        UserDefaults.standard.set("ja", forKey: UIString.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: UIString.preferenceKey) }
        let all = MenuBarLabelText.Options(temperature: true, wear: true, remainingYears: true, todayWrites: true)
        XCTAssertEqual(
            MenuBarLabelText.make(options: all, temperatureCelsius: 45, wearFraction: 0.056,
                                  remainingYears: 19.6, todayWrittenBytes: 12_300_000_000,
                                  temperatureUnit: .celsius),
            "45° · 94.4% · 20年 · 12.3 GB"
        )
        XCTAssertEqual(MenuBarLabelText.make(options: .init(temperature: true), temperatureCelsius: 45, wearFraction: nil,
                                             remainingYears: nil, todayWrittenBytes: nil, temperatureUnit: .fahrenheit), "113°")
        XCTAssertEqual(MenuBarLabelText.make(options: .init(), temperatureCelsius: 45, wearFraction: nil,
                                             remainingYears: nil, todayWrittenBytes: nil), "")
        XCTAssertEqual(MenuBarLabelText.make(options: .init(remainingYears: true), temperatureCelsius: nil,
                                             wearFraction: nil, remainingYears: 25, todayWrittenBytes: nil), "25年")
        XCTAssertEqual(MenuBarLabelText.make(options: .init(wear: true), temperatureCelsius: nil,
                                             wearFraction: nil, remainingYears: nil, todayWrittenBytes: nil), "—")
    }

    func testTemperatureUnitConvertsForDisplayOnly() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(30), 86, accuracy: 1e-9)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(-40), -40, accuracy: 1e-9)
        XCTAssertEqual(TemperatureUnit.fahrenheit.celsius(from: 185), 85, accuracy: 1e-9)
        XCTAssertEqual(TemperatureUnit.celsius.value(33.8), 33.8)
        XCTAssertEqual(TemperatureUnit.fahrenheit.text(33.8), "92.8°F")
        XCTAssertEqual(TemperatureUnit.celsius.text(33.8), "33.8°C")
        XCTAssertEqual(TemperatureUnit.fahrenheit.wholeNumber(51), 124)
        XCTAssertEqual(ValueFormatter.temperature(51, unit: .fahrenheit), "124 °F")
        XCTAssertEqual(ValueFormatter.temperature(51, unit: .celsius), "51 °C")
        XCTAssertEqual(TemperatureUnit.system.resolved(locale: Locale(identifier: "en_US")), .fahrenheit)
        XCTAssertEqual(TemperatureUnit.system.resolved(locale: Locale(identifier: "ja_JP")), .celsius)
        XCTAssertEqual(TemperatureUnit.system.resolved(locale: Locale(identifier: "en_GB")), .celsius)
    }
}
