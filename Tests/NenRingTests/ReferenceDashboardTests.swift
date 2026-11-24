import Foundation
import XCTest
@testable import NenRing

final class ReferenceDashboardTests: XCTestCase {
    func testHourlyWindowUsesTheSame72CalendarBucketsForAllSeries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 100 * 3_600 + 1_800)
        let cutoff = ReferenceChartWindow.cutoff(requested: nil, granularity: .hour, now: now, calendar: calendar)
        XCTAssertEqual(cutoff, Date(timeIntervalSince1970: 29 * 3_600))
        let shorter = Date(timeIntervalSince1970: 90 * 3_600 + 20)
        XCTAssertEqual(ReferenceChartWindow.cutoff(requested: shorter, granularity: .hour, now: now, calendar: calendar),
                       Date(timeIntervalSince1970: 90 * 3_600))
        let intervals = [ReferenceNANDWriteInterval(startAt: Date(timeIntervalSince1970: 0), endAt: now, bytes: 100)]
        let nand = ReferenceNANDWriteAllocator.allocate(intervals, cutoff: cutoff, granularity: .hour,
                                                         maxPointCount: .max, calendar: calendar)
        XCTAssertEqual(nand.count, 72)
        XCTAssertEqual(nand.first?.bucket, cutoff)
    }

    func testLongDailyNANDRangeIsNotTruncatedToThirtyPoints() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(90 * 86_400)
        let cutoff = ReferenceChartWindow.cutoff(requested: start, granularity: .day, now: end, calendar: calendar)
        let points = ReferenceNANDWriteAllocator.allocate(
            [ReferenceNANDWriteInterval(startAt: start, endAt: end, bytes: 900)], cutoff: cutoff,
            granularity: .day, maxPointCount: .max, calendar: calendar)
        XCTAssertEqual(points.count, 90)
        XCTAssertEqual(points.reduce(0) { $0 + $1.bytes }, 900, accuracy: 1e-8)
        XCTAssertNil(ReferenceChartWindow.cutoff(requested: nil, granularity: .week, now: end, calendar: calendar))
    }

    func testCumulativeCounterKeepsTheLastReadingOfEachBucket() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = 86_400.0
        let samples = [
            ReferenceCounterSample(at: Date(timeIntervalSince1970: 0.5 * day), bytes: 5),     // before cutoff
            ReferenceCounterSample(at: Date(timeIntervalSince1970: 1.8 * day), bytes: 30),
            ReferenceCounterSample(at: Date(timeIntervalSince1970: 1.2 * day), bytes: 20),
            ReferenceCounterSample(at: Date(timeIntervalSince1970: 2.5 * day), bytes: .nan),
            ReferenceCounterSample(at: Date(timeIntervalSince1970: 3.1 * day), bytes: 45),
        ]
        let points = ReferenceCumulativeWriteSeries.counterPoints(
            samples, cutoff: Date(timeIntervalSince1970: day), granularity: .day, calendar: calendar)
        XCTAssertEqual(points.map(\.bytes), [30, 45])
        // Plotted at the reading's own time, so the line ends at the latest value.
        XCTAssertEqual(points.map(\.bucket), [Date(timeIntervalSince1970: 1.8 * day), Date(timeIntervalSince1970: 3.1 * day)])
    }

    func testCumulativeEstimateAddsUpFromTheFirstBucket() {
        let points = [
            ReferenceNANDWritePoint(bucket: Date(timeIntervalSince1970: 200), bytes: 3),
            ReferenceNANDWritePoint(bucket: Date(timeIntervalSince1970: 100), bytes: 2),
            ReferenceNANDWritePoint(bucket: Date(timeIntervalSince1970: 300), bytes: 0),
        ]
        let totals = ReferenceCumulativeWriteSeries.runningTotals(points)
        XCTAssertEqual(totals.map(\.bytes), [2, 5, 5])
        XCTAssertEqual(totals.map(\.bucket.timeIntervalSince1970), [100, 200, 300])
    }

    func testTemperatureWeekCountsDailyAveragesAndRawSamplesPerDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // 1970-01-04 is a Sunday, the first day of a Gregorian week.
        let weekStart = Date(timeIntervalSince1970: 3 * 86_400)
        // Three older days stored as one daily average each, four newer days
        // with a sample every minute.
        var points = (0..<3).map {
            TemperaturePoint(date: weekStart.addingTimeInterval(Double($0) * 86_400), celsius: 30)
        }
        for day in 3..<7 {
            for minute in 0..<1_440 {
                points.append(TemperaturePoint(
                    date: weekStart.addingTimeInterval(Double(day) * 86_400 + Double(minute) * 60), celsius: 40))
            }
        }

        let week = ReferenceTemperatureBuckets.averages(points, granularity: .week, calendar: calendar)
        XCTAssertEqual(week.map(\.date), [weekStart])
        XCTAssertEqual(week.first?.celsius ?? 0, (3 * 30 + 4 * 40) / 7.0, accuracy: 1e-9)

        let days = ReferenceTemperatureBuckets.averages(points, granularity: .day, calendar: calendar)
        XCTAssertEqual(days.map(\.celsius), [30, 30, 30, 40, 40, 40, 40])
    }

    func testTemperatureHourAveragesItsSamples() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let hour = Date(timeIntervalSince1970: 10 * 3_600)
        let points = [30.0, 32, 40].enumerated().map {
            TemperaturePoint(date: hour.addingTimeInterval(Double($0.offset) * 60), celsius: $0.element)
        }
        let averaged = ReferenceTemperatureBuckets.averages(points, granularity: .hour, calendar: calendar)
        XCTAssertEqual(averaged.map(\.date), [hour])
        XCTAssertEqual(averaged.first?.celsius ?? 0, 34, accuracy: 1e-9)
    }

    func testDailyWearKeepsEveryDayInsteadOfTheLatestNinety() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Two readings a day for 120 days; the later one of each day is kept.
        let dates = (0..<240).map { Date(timeIntervalSince1970: Double($0) * 43_200 + 3_600) }
        let buckets = ReferenceLatestBuckets.latest(dates, date: { $0 }, granularity: .day, calendar: calendar)
        XCTAssertEqual(buckets.count, 120)
        XCTAssertEqual(buckets.first?.bucket, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(buckets.first?.item, Date(timeIntervalSince1970: 43_200 + 3_600))
        XCTAssertEqual(buckets.map(\.bucket), buckets.map(\.bucket).sorted())
    }

    func testNANDWearScaleTracksVisibleValuesInsteadOfStartingAtZero() {
        let first = ReferenceWearScale.domain(values: [5.10, 5.35], minimumSpan: 0.2)
        let shifted = ReferenceWearScale.domain(values: [6.10, 6.35], minimumSpan: 0.2)

        XCTAssertGreaterThan(first.lowerBound, 0)
        XCTAssertLessThan(first.lowerBound, 5.10)
        XCTAssertGreaterThan(first.upperBound, 5.35)
        XCTAssertLessThan(first.upperBound - first.lowerBound, 1)
        XCTAssertGreaterThan(shifted.lowerBound, first.lowerBound)
        XCTAssertGreaterThan(shifted.upperBound, first.upperBound)
    }

    func testNANDWearScaleFallsBackForMissingOrInvalidValues() {
        XCTAssertEqual(ReferenceWearScale.domain(values: [], minimumSpan: 0.2), 0...10)
        XCTAssertEqual(ReferenceWearScale.domain(values: [.infinity, .nan, -1], minimumSpan: 0.2), 0...10)
    }

    func testNANDIntervalIsAllocatedAcrossDayBuckets() {
        let start = Date(timeIntervalSince1970: 12 * 3_600)
        let end = start.addingTimeInterval(48 * 3_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let points = ReferenceNANDWriteAllocator.allocate(
            [ReferenceNANDWriteInterval(startAt: start, endAt: end, bytes: 100)],
            cutoff: nil,
            granularity: .day,
            maxPointCount: 10,
            calendar: calendar
        )

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].bytes, 25, accuracy: 1e-10)
        XCTAssertEqual(points[1].bytes, 50, accuracy: 1e-10)
        XCTAssertEqual(points[2].bytes, 25, accuracy: 1e-10)
        XCTAssertEqual(points.reduce(0) { $0 + $1.bytes }, 100, accuracy: 1e-10)
    }

    func testNANDIntervalCutoffAllocatesOnlyVisiblePortion() {
        let start = Date(timeIntervalSince1970: 12 * 3_600)
        let end = start.addingTimeInterval(48 * 3_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cutoff = start.addingTimeInterval(12 * 3_600)

        let points = ReferenceNANDWriteAllocator.allocate(
            [ReferenceNANDWriteInterval(startAt: start, endAt: end, bytes: 100)],
            cutoff: cutoff,
            granularity: .day,
            maxPointCount: 10,
            calendar: calendar
        )

        XCTAssertEqual(points[0].bytes, 50, accuracy: 1e-10)
        XCTAssertEqual(points[1].bytes, 25, accuracy: 1e-10)
        XCTAssertEqual(points.reduce(0) { $0 + $1.bytes }, 75, accuracy: 1e-10)
    }

    func testWriteEfficiencyRatiosUseOnlyIntervalsWithBothCounters() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = 86_400.0
        let gb = 1_000_000_000.0
        func at(_ days: Double) -> Date { Date(timeIntervalSince1970: days * day) }
        let intervals = [
            // Day 0: research telemetry present.
            ReferenceWriteEfficiencyInterval(startAt: at(0), endAt: at(0.5), hostBytes: 100 * gb,
                                             nandBytes: 150 * gb, directToTLCBytes: 20 * gb),
            // Day 0: no direct counter; it counts for WAF only.
            ReferenceWriteEfficiencyInterval(startAt: at(0.5), endAt: at(1), hostBytes: 100 * gb,
                                             nandBytes: 110 * gb, directToTLCBytes: nil),
            // Day 1: too little Host writing for a meaningful ratio.
            ReferenceWriteEfficiencyInterval(startAt: at(1), endAt: at(2), hostBytes: 0.5 * gb,
                                             nandBytes: 3 * gb, directToTLCBytes: 0),
        ]
        let points = ReferenceWriteEfficiencySeries.points(intervals, cutoff: nil, granularity: .day,
                                                           calendar: calendar)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].bucket, at(0))
        XCTAssertEqual(points[0].waf ?? 0, 1.3, accuracy: 1e-10)
        XCTAssertEqual(points[0].directToTLCShare ?? 0, 0.2, accuracy: 1e-10)
    }

    func testWritePointsAreWithheldForAnotherPeriodUntilTheRebuild() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func drive(_ date: Date, host: Double) -> DriveSnapshot {
            DriveSnapshot(capturedAt: date, deviceID: "d", devicePath: "/dev/rdisk0", logicalCapacityBytes: 256_000_000_000,
                model: "test", serialNumber: nil, firmware: "fw", smartctlVersion: nil, smartctlExitStatus: 0,
                temperatureCelsius: 40, powerOnHours: 3000, powerCycleCount: nil, unsafeShutdowns: nil,
                percentageUsed: 5, availableSpare: 100, availableSpareThreshold: nil, criticalWarning: 0,
                mediaAndDataIntegrityErrors: 0, dataUnitsRead: nil, dataUnitsWritten: UInt64(host / 512_000), smartPassed: true)
        }
        let history = [drive(now - 86_400, host: 60e12), drive(now, host: 60.1e12)]
        let analytics = DashboardAnalyticsSnapshot.build(analyzer: HistoryAnalyzer(), history: history, deviceID: "d",
            period: .week, profile: nil, settings: UsageSettings(), now: now)

        XCTAssertEqual(analytics.writePointsPeriod, .week)
        XCTAssertFalse(analytics.writePoints.isEmpty)
        XCTAssertEqual(analytics.writePoints(for: .week), analytics.writePoints)
        // Right after switching to days the snapshot still holds weeks.
        XCTAssertTrue(analytics.writePoints(for: .day).isEmpty)
    }
}
