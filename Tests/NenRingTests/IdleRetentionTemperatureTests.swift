import XCTest
@testable import NenRing

final class IdleRetentionTemperatureTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func smart(_ hour: Double, read: UInt64? = 100, write: UInt64 = 100,
                       power: UInt64? = nil, firmware: String = "FW1", cycles: UInt64? = 1) -> DriveSnapshot {
        DriveSnapshot(capturedAt: origin.addingTimeInterval(hour * 3_600), deviceID: "drive", devicePath: "/dev/disk0",
            model: "Test", serialNumber: "serial", firmware: firmware, smartctlVersion: nil, smartctlExitStatus: 0,
            temperatureCelsius: 36, powerOnHours: power ?? UInt64(100 + hour), powerCycleCount: cycles,
            unsafeShutdowns: 0, percentageUsed: 5, availableSpare: 100, availableSpareThreshold: 10,
            criticalWarning: 0, mediaAndDataIntegrityErrors: 0, dataUnitsRead: read, dataUnitsWritten: write, smartPassed: true)
    }

    private func temperatures(start: Double = 0, hours: Double = 2, temperature: Int = 36) -> [TemperatureSample] {
        (0...Int(hours * 6)).map { index in
            .init(capturedAt: origin.addingTimeInterval(start * 3_600 + Double(index) * 600),
                  deviceID: "drive", temperatureCelsius: temperature)
        }
    }

    private func assess(_ smart: [DriveSnapshot], _ temperatures: [TemperatureSample],
                        manual: Double? = nil, nowHours: Double = 2,
                        excluding: [DateInterval] = [], previous: [IdleTemperatureCandidate] = []) -> IdleRetentionTemperature {
        IdleRetentionTemperatureAnalyzer.assess(smart: smart, temperatures: temperatures, deviceID: "drive",
            manual: manual, now: origin.addingTimeInterval(nowHours * 3_600), excluding: excluding, previous: previous)
    }

    func testSmallIdleObservationIsDisplayedProvisionally() {
        let history = [smart(0), smart(1), smart(2)]
        let value = assess(history, temperatures())
        XCTAssertEqual(value.source, .idle)
        XCTAssertEqual(value.temperature, 36)
        XCTAssertTrue(value.provisional)
        XCTAssertEqual(value.confidence, .low)
        XCTAssertEqual(value.observedSeconds, 7_200)
        // Duplicate current snapshot must not split or erase the idle run.
        XCTAssertEqual(value, assess(history + [history.last!], temperatures()))
    }

    func testStableAndUnstableLowLoadDaysBothContributeToMainMedian() {
        var previous: [IdleTemperatureCandidate] = []
        for day in 0..<3 {
            let start = origin.addingTimeInterval(Double(day) * 86_400)
            let temperature: Double = day == 0 ? 30 : 38
            previous.append(IdleTemperatureCandidate(deviceID: "drive", firmware: "FW1",
                start: start, end: start.addingTimeInterval(3_600),
                temperature: temperature, sampleCount: 7, hostBytes: 0,
                stable: day == 0, smartIntervalSeconds: 3_600))
        }
        let result = assess([smart(49)], [], nowHours: 49, previous: previous)
        XCTAssertEqual(result.temperature, 38)
        XCTAssertEqual(result.observedMedianTemperature, 38)
        XCTAssertEqual(result.stableMedianTemperature, 30)
        XCTAssertEqual(result.selectedCandidateCount, 3)
        XCTAssertEqual(result.confidence, .low, "unstable days must not promote stable evidence")
        XCTAssertTrue(result.provisional)
    }

    func testSavedIntervalsOlderThanThirtyDaysContributeWithoutCrossingFirmwareOrExcludedIntervals() {
        let old = IdleTemperatureCandidate(deviceID: "drive", firmware: "FW1", start: origin,
            end: origin.addingTimeInterval(3_600), temperature: 30, sampleCount: 7,
            hostBytes: 0, stable: true, smartIntervalSeconds: 3_600)
        let otherFirmware = IdleTemperatureCandidate(deviceID: "drive", firmware: "FW2", start: origin.addingTimeInterval(86_400),
            end: origin.addingTimeInterval(90_000), temperature: 10, sampleCount: 7,
            hostBytes: 0, stable: true, smartIntervalSeconds: 3_600)
        let recentHour = 40.0 * 24
        let result = assess([smart(recentHour), smart(recentHour + 1), smart(recentHour + 2)],
            temperatures(start: recentHour, temperature: 38), nowHours: recentHour + 2,
            previous: [old, otherFirmware])
        XCTAssertEqual(result.observedDays, 2)
        XCTAssertEqual(result.temperature, 34, accuracy: 0.001)
        XCTAssertEqual(result.candidates.count, 2)

        let excluded = DateInterval(start: old.start, end: old.end)
        let afterExclusion = assess([smart(recentHour), smart(recentHour + 1), smart(recentHour + 2)],
            temperatures(start: recentHour, temperature: 38), nowHours: recentHour + 2,
            excluding: [excluded], previous: [old, otherFirmware])
        XCTAssertEqual(afterExclusion.temperature, 38, accuracy: 0.001)
        XCTAssertEqual(afterExclusion.observedDays, 1)
    }

    func testThermalModelUsesTheSameObservedStorageTemperature() {
        let history = [smart(0), smart(1), smart(2)]
        let samples = temperatures()
        let idle = assess(history, samples)
        let now = origin.addingTimeInterval(2 * 3_600)
        let thermal = ThermalRetentionAnalyzer().assess(smartHistory: history, temperatureHistory: samples,
            deviceID: "drive", storageTemperature: nil, activationEnergy: 1.1, programCorrection: false,
            now: now, observedStorage: idle)
        XCTAssertEqual(thermal.storageTemperature, idle.temperature)
        XCTAssertEqual(thermal.storageSource, "アイドル実測・保管温度proxy")
        // A manual override still wins, and the 30 °C fallback is not
        // presented as an observation.
        let manual = ThermalRetentionAnalyzer().assess(smartHistory: history, temperatureHistory: samples,
            deviceID: "drive", storageTemperature: 25, activationEnergy: 1.1, programCorrection: false,
            now: now, observedStorage: idle)
        XCTAssertEqual(manual.storageTemperature, 25)
        let fallback = assess([], [])
        XCTAssertEqual(fallback.source, .fallback)
        let unobserved = ThermalRetentionAnalyzer().assess(smartHistory: history, temperatureHistory: samples,
            deviceID: "drive", storageTemperature: nil, activationEnergy: 1.1, programCorrection: false,
            now: now, observedStorage: fallback)
        XCTAssertFalse(unobserved.storageSource.hasPrefix("既定温度"))
    }

    func testThinnedTemperaturesDoNotReplaceStoredIntervals() throws {
        let history = [smart(0), smart(1), smart(2)]
        let fine = (0...120).map { minute in
            TemperatureSample(capturedAt: origin.addingTimeInterval(Double(minute) * 60), deviceID: "drive",
                              temperatureCelsius: minute < 90 ? 36 : 38)
        }
        let stored = try XCTUnwrap(assess(history, fine).candidates.first)
        // The same run re-derived after the temperature history was thinned
        // to 5-minute buckets must not replace the stored observation.
        let thinned = fine.filter { Int($0.capturedAt.timeIntervalSince(origin)) % 300 == 0 }
        let later = assess(history, thinned, previous: [stored])
        XCTAssertEqual(later.candidates, [stored])
        // Thinned SMART can drop the first snapshot of the run; a shorter
        // re-derived run must not replace the stored one either.
        let shorter = assess([smart(0.5), smart(1), smart(2)], fine, previous: [stored])
        XCTAssertEqual(shorter.candidates, [stored])
        // A run that keeps the same density still replaces its earlier part.
        let partial = try XCTUnwrap(assess([smart(0), smart(1)], Array(fine.prefix(61)), nowHours: 1).candidates.first)
        let extended = assess(history, fine, previous: [partial])
        XCTAssertEqual(extended.candidates.count, 1)
        XCTAssertEqual(extended.candidates.first?.end, origin.addingTimeInterval(7_200))
    }

    func testThinnedHistoryDoesNotJoinOlderStoredRuns() throws {
        // Two runs found at full resolution, split by a busy interval that
        // thinning later hid.
        let history = (0...4).map { smart(Double($0)) }
        let samples = (0...240).map { minute in
            TemperatureSample(capturedAt: origin.addingTimeInterval(Double(minute) * 60), deviceID: "drive",
                              temperatureCelsius: 36)
        }
        let first = try XCTUnwrap(assess(Array(history.prefix(3)), Array(samples.prefix(121))).candidates.first)
        let second = try XCTUnwrap(assess(Array(history.suffix(3)), Array(samples.suffix(121)), nowHours: 4).candidates.first)
        XCTAssertLessThan(first.end, second.end)

        // Three days later the joined run must not replace them.
        let later = assess(history, samples, nowHours: 72, previous: [first, second])
        XCTAssertEqual(later.candidates, [first, second])
        // While recent, a covering run still replaces its earlier part.
        let recent = assess(history, samples, nowHours: 4, previous: [first])
        XCTAssertEqual(recent.candidates.count, 1)
        XCTAssertEqual(recent.candidates.first?.end, origin.addingTimeInterval(4 * 3_600))
    }

    func testTimeWeightedMeanUsesElapsedTimeWithoutChangingMedian() {
        let points: [(Double, Int)] = [(0, 30), (300, 30), (900, 32), (1_800, 32)]
        let samples = points.map { seconds, temperature in
            TemperatureSample(capturedAt: origin.addingTimeInterval(seconds), deviceID: "drive", temperatureCelsius: temperature)
        }
        let history = [smart(0), smart(0.5)]
        let value = assess(history, samples, nowHours: 0.5)
        XCTAssertEqual(value.temperature, 31)
        XCTAssertEqual(value.observedMedianTemperature, 31)
        XCTAssertEqual(value.timeWeightedTemperature!, 56_400.0 / 1_800, accuracy: 1e-9)
        XCTAssertEqual(value.meanObservedSeconds, 1_800)
        let midpoint = TemperatureSample(capturedAt: origin.addingTimeInterval(600), deviceID: "drive", temperatureCelsius: 31)
        let refined = assess(history, samples + [midpoint], nowHours: 0.5)
        XCTAssertEqual(refined.timeWeightedTemperature!, value.timeWeightedTemperature!, accuracy: 1e-9)
        XCTAssertEqual(refined.temperature, value.temperature)
        let manual = assess(history, samples, manual: 40, nowHours: 0.5)
        XCTAssertEqual(manual.temperature, 40)
        XCTAssertEqual(manual.observedMedianTemperature, 31)
        XCTAssertEqual(manual.timeWeightedTemperature, value.timeWeightedTemperature)
    }

    func testLegacyEvidenceDoesNotInventMeanAndPersistsNewStatistics() throws {
        let value = assess([smart(0), smart(1), smart(2)], temperatures())
        let restored = try JSONDecoder().decode([IdleTemperatureCandidate].self,
            from: JSONEncoder().encode(value.candidates))
        XCTAssertEqual(restored, value.candidates)
        let fromArchive = assess([smart(24)], [], nowHours: 24, previous: restored)
        XCTAssertEqual(fromArchive.timeWeightedTemperature, 36)
        let legacyStart = origin.addingTimeInterval(-86_400)
        let legacy = IdleTemperatureCandidate(deviceID: "drive", firmware: "FW1", start: legacyStart,
            end: legacyStart.addingTimeInterval(7_200), temperature: 40, sampleCount: 13,
            hostBytes: 0, stable: true, smartIntervalSeconds: 3_600)
        let mixed = assess([smart(24)], [], nowHours: 24, previous: restored + [legacy])
        XCTAssertEqual(mixed.timeWeightedTemperature, 36)
        XCTAssertEqual(mixed.meanCandidateCount, 1)
        XCTAssertEqual(mixed.selectedCandidateCount, 2)
        let oldOnly = assess([smart(24)], [], nowHours: 24, previous: [legacy])
        XCTAssertNil(oldOnly.timeWeightedTemperature)
        XCTAssertEqual(oldOnly.temperature, 40)
        XCTAssertNil(assess([], []).timeWeightedTemperature)
    }

    func testReadsMissingCountersSleepAndExclusionsDoNotBecomeIdle() {
        let cases: [[DriveSnapshot]] = [
            [smart(0), smart(1, read: 10_000_000), smart(2, read: 20_000_000)],
            [smart(0, read: nil), smart(1, read: nil), smart(2, read: nil)],
            [smart(0, power: 100), smart(4, power: 100)],
            [smart(0), smart(1, write: 1), smart(2, write: 0)],
            [smart(0), smart(2, firmware: "FW2")]
        ]
        for history in cases {
            XCTAssertEqual(assess(history, temperatures(hours: 4), nowHours: 4).source, .fallback)
        }
        XCTAssertEqual(assess([smart(0), smart(1), smart(2)], temperatures(),
            excluding: [.init(start: origin, duration: 7_200)]).source, .fallback)
        XCTAssertEqual(assess([smart(0), smart(2)], [temperatures()[0]]).source, .fallback)
    }

    func testFirmwareLineageKeepsPointUpdatesAndBridgesANewLineageProvisionally() {
        XCTAssertEqual(UpdateLineage.firmware("591.40.3"), "591")
        XCTAssertEqual(UpdateLineage.firmware("561.100."), "561")
        XCTAssertEqual(UpdateLineage.firmware("FW1"), "FW1")
        XCTAssertEqual(UpdateLineage.firmwareEpoch("591.40.3|12"), "591|12")
        XCTAssertEqual(UpdateLineage.build("26B123"), UpdateLineage.build("26A434"))
        XCTAssertNotEqual(UpdateLineage.build("26A428"), UpdateLineage.build("25G83"))

        // The macOS 27.2 update moved the firmware from 591 to 591.40.3.
        let before = assess([smart(0, firmware: "591"), smart(1, firmware: "591"), smart(2, firmware: "591")], temperatures())
        let pointUpdate = assess([smart(24, firmware: "591.40.3")], [], nowHours: 24, previous: before.candidates)
        XCTAssertEqual(pointUpdate.source, .idle)
        XCTAssertEqual(pointUpdate.temperature, 36)
        XCTAssertFalse(pointUpdate.fromEarlierFirmware)

        // 561.100. -> 591 is a new lineage: the earlier observation stands in
        // provisionally instead of the 30 °C default.
        let earlier = assess([smart(0, firmware: "561.100."), smart(1, firmware: "561.100."),
                              smart(2, firmware: "561.100.")], temperatures(temperature: 40))
        let newLineage = assess([smart(24, firmware: "591")], [], nowHours: 24, previous: earlier.candidates)
        XCTAssertEqual(newLineage.source, .previous)
        XCTAssertEqual(newLineage.temperature, 40)
        XCTAssertTrue(newLineage.fromEarlierFirmware)
        XCTAssertTrue(newLineage.provisional)
        XCTAssertEqual(newLineage.sourceTitle, "更新前FWの観測")

        // Once the new lineage is observed, only it is used.
        let observed = assess([smart(24, firmware: "591"), smart(25, firmware: "591"), smart(26, firmware: "591")],
            temperatures(start: 24), nowHours: 26, previous: earlier.candidates)
        XCTAssertEqual(observed.source, .idle)
        XCTAssertEqual(observed.temperature, 36)
        XCTAssertFalse(observed.fromEarlierFirmware)
        XCTAssertFalse(observed.candidates.contains { $0.firmware == "561.100." })
    }

    func testRunsKeepTheFirmwareTheyWereMeasuredUnderAndOverlapsCountOnce() {
        let history = [smart(0, firmware: "591"), smart(1, firmware: "591"), smart(2, firmware: "591"),
                       smart(24, firmware: "591.40.3")]
        let value = assess(history, temperatures(), nowHours: 24)
        XCTAssertEqual(value.candidates.map(\.firmware), ["591"])
        // A run stored twice under two point-release labels counts once.
        let run = value.candidates[0]
        let relabelled = IdleTemperatureCandidate(deviceID: run.deviceID, firmware: "591.40.3",
            start: run.start.addingTimeInterval(600), end: run.end, temperature: 30, sampleCount: run.sampleCount - 1,
            hostBytes: run.hostBytes, stable: run.stable, smartIntervalSeconds: run.smartIntervalSeconds, ruleVersion: 2)
        let stored = assess([smart(24, firmware: "591.40.3")], [], nowHours: 24, previous: [run, relabelled])
        XCTAssertEqual(stored.candidates, [run])
        XCTAssertEqual(stored.observedSeconds, 7_200)
        XCTAssertEqual(stored.temperature, 36)
    }

    func testManualFallbackAndPreviousObservationAreDistinct() {
        let history = [smart(0), smart(1), smart(2)]
        let observed = assess(history, temperatures())
        XCTAssertEqual(assess(history, temperatures(), manual: 40).temperature, 40)
        XCTAssertEqual(assess(history, temperatures(), manual: 40).source, .manual)
        XCTAssertFalse(assess([], [], manual: 40).provisional, "a chosen temperature is not provisional")
        XCTAssertEqual(assess([], [], manual: .nan).source, .fallback)
        XCTAssertEqual(assess([], []).temperature, 30)
        let restored = assess([smart(10 * 24)], [], nowHours: 10 * 24, previous: observed.candidates)
        XCTAssertEqual(restored.source, .previous)
        XCTAssertEqual(restored.temperature, 36)
        XCTAssertTrue(restored.provisional)
        let older = assess([smart(31 * 24)], [], nowHours: 31 * 24, previous: observed.candidates)
        XCTAssertEqual(older.source, .previous)
        XCTAssertTrue(older.provisional)
    }

    func testIntervalCrossingMidnightCountsAsOneDay() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let midnight = utc.startOfDay(for: origin).addingTimeInterval(86_400)
        let crossing = IdleTemperatureCandidate(deviceID: "drive", firmware: "FW1",
            start: midnight.addingTimeInterval(-2 * 3_600), end: midnight.addingTimeInterval(3_600),
            temperature: 34, sampleCount: 19, hostBytes: 0, stable: true, smartIntervalSeconds: 3_600, ruleVersion: 2)
        let now = midnight.addingTimeInterval(2 * 3_600)
        let value = IdleRetentionTemperatureAnalyzer.assess(smart: [smart(now.timeIntervalSince(origin) / 3_600)],
            temperatures: [], deviceID: "drive", manual: nil, now: now, excluding: [], previous: [crossing],
            calendar: utc)
        XCTAssertEqual(value.observedDays, 1)
        XCTAssertEqual(value.observedSeconds, 3 * 3_600)
    }

    func testIndependentDaysRaiseTemperatureEvidenceButPollingAloneDoesNot() {
        func observations(days: Int) -> IdleRetentionTemperature {
            let history = (0..<days).flatMap { day in (0...2).map { smart(Double(day * 24 + $0)) } }
            let samples = (0..<days).flatMap { temperatures(start: Double($0 * 24)) }
            return assess(history, samples, nowHours: Double((days - 1) * 24 + 2))
        }
        XCTAssertEqual(observations(days: 3).confidence, .medium)
        XCTAssertEqual(observations(days: 7).confidence, .high)
        let frequent = (0...120).map { smart(Double($0) / 60) }
        XCTAssertEqual(assess(frequent, temperatures()).confidence, .low)
    }

    func testCoolingAndCompactedDailySamplesRemainProvisionalOrUnavailable() {
        let history = [smart(0), smart(1), smart(2)]
        let cooling = temperatures().enumerated().map { index, sample in
            TemperatureSample(capturedAt: sample.capturedAt, deviceID: "drive", temperatureCelsius: 55 - index)
        }
        let value = assess(history, cooling)
        XCTAssertEqual(value.source, .idle)
        XCTAssertFalse(value.candidates[0].stable)
        XCTAssertTrue(value.provisional)
        let daily = temperatures().map { sample in
            TemperatureSample(capturedAt: sample.capturedAt, deviceID: "drive", temperatureCelsius: 36,
                dailySummary: .init(minimumCelsius: 30, maximumCelsius: 50, averageCelsius: 36, sampleCount: 100))
        }
        XCTAssertEqual(assess(history, daily).source, .fallback)
    }

    func testEvidencePersistenceAndCorruptionDoNotOverwriteOriginal() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemperatureHistoryStore(fileURL: root.appendingPathComponent("temperatures.jsonl"))
        let value = assess([smart(0), smart(1), smart(2)], temperatures())
        try await store.saveIdleEvidence(value.candidates, deviceID: "drive")
        let restored = try await store.idleEvidence()
        XCTAssertEqual(restored, value.candidates)
        let url = root.appendingPathComponent("idle-temperature-evidence.json")
        let broken = Data("broken".utf8)
        try broken.write(to: url)
        do {
            try await store.saveIdleEvidence(value.candidates, deviceID: "drive")
            XCTFail("Corrupt evidence must be reported")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testFirmwareUpdateKeepsEarlierEvidenceStored() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemperatureHistoryStore(fileURL: root.appendingPathComponent("temperatures.jsonl"))
        let before = assess([smart(0), smart(1), smart(2)], temperatures())
        try await store.saveIdleEvidence(before.candidates, deviceID: "drive")
        // After an update the analyzer cannot use FW1 evidence, but the
        // store must not lose it.
        let history = [smart(24, firmware: "FW2"), smart(25, firmware: "FW2"), smart(26, firmware: "FW2")]
        let previous = try await store.idleEvidence()
        let after = assess(history, temperatures(start: 24), nowHours: 26, previous: previous)
        XCTAssertFalse(after.candidates.contains { $0.firmware == "FW1" })
        try await store.saveIdleEvidence(after.candidates, deviceID: "drive")
        let stored = try await store.idleEvidence()
        XCTAssertEqual(Set(stored.compactMap(\.firmware)), ["FW1", "FW2"])
        // A newer overlapping observation still replaces the stored one.
        try await store.saveIdleEvidence(before.candidates, deviceID: "drive")
        let replaced = try await store.idleEvidence()
        XCTAssertEqual(replaced.count, stored.count)
    }

    func testThirtyDayCutoffPreservesCompleteStoredEvidence() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("temperatures.jsonl")
        let store = TemperatureHistoryStore(fileURL: file)
        let history = [smart(0), smart(1), smart(2)]
        let before = assess(history, temperatures())
        try await store.saveIdleEvidence(before.candidates, deviceID: "drive")

        // The raw-data cutoff moves into the original run, but the saved
        // complete interval remains the observation used for the estimate.
        let after = assess(history, temperatures(), nowHours: 30 * 24 + 1, previous: before.candidates)
        XCTAssertEqual(after.candidates, before.candidates)
        try await store.saveIdleEvidence(after.candidates, deviceID: "drive")
        let reloaded = TemperatureHistoryStore(fileURL: file)
        let stored = try await reloaded.idleEvidence()
        XCTAssertEqual(stored, before.candidates)
    }

    func testEvidenceReplacementRequiresCoverageAndKeepsAdjacentRuns() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemperatureHistoryStore(fileURL: root.appendingPathComponent("temperatures.jsonl"))
        let fine = (0...180).map {
            TemperatureSample(capturedAt: origin.addingTimeInterval(Double($0) * 60),
                deviceID: "drive", temperatureCelsius: 36)
        }
        let partial = assess([smart(0), smart(1)], Array(fine.prefix(61)), nowHours: 1)
        try await store.saveIdleEvidence(partial.candidates, deviceID: "drive")
        let full = assess([smart(0), smart(1), smart(2)], Array(fine.prefix(121)))
        try await store.saveIdleEvidence(full.candidates, deviceID: "drive")
        let extended = try await store.idleEvidence()
        XCTAssertEqual(extended, full.candidates)

        let thinned = full.candidates.map { candidate in
            IdleTemperatureCandidate(deviceID: candidate.deviceID, firmware: candidate.firmware,
                start: candidate.start, end: candidate.end, temperature: 40, sampleCount: 4,
                hostBytes: candidate.hostBytes, stable: candidate.stable,
                smartIntervalSeconds: candidate.smartIntervalSeconds, ruleVersion: candidate.ruleVersion)
        }
        try await store.saveIdleEvidence(thinned, deviceID: "drive")
        let kept = try await store.idleEvidence()
        XCTAssertEqual(kept, full.candidates)

        let adjacent = assess([smart(2), smart(3)], Array(fine.suffix(61)), nowHours: 3)
        try await store.saveIdleEvidence(adjacent.candidates, deviceID: "drive")
        let joined = try await store.idleEvidence()
        XCTAssertEqual(joined, full.candidates + adjacent.candidates)
        let otherFirmware = assess([smart(0, firmware: "FW2"), smart(1, firmware: "FW2")],
            Array(fine.prefix(61)), nowHours: 1)
        try await store.saveIdleEvidence(otherFirmware.candidates, deviceID: "drive")
        let all = try await store.idleEvidence()
        XCTAssertEqual(all.count, joined.count + otherFirmware.candidates.count)
    }

    func testEvidenceOlderThanTheAnalysisWindowStaysStored() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemperatureHistoryStore(fileURL: root.appendingPathComponent("temperatures.jsonl"))
        let early = assess([smart(0), smart(1), smart(2)], temperatures())
        try await store.saveIdleEvidence(early.candidates, deviceID: "drive")
        // 40 days later the saved early interval is still part of the estimate.
        let later = 40.0 * 24
        let history = [smart(later), smart(later + 1), smart(later + 2)]
        let previous = try await store.idleEvidence()
        let current = assess(history, temperatures(start: later), nowHours: later + 2, previous: previous)
        XCTAssertTrue(current.candidates.contains { $0.end <= self.origin.addingTimeInterval(2 * 3_600) })
        // Saving the combined result keeps both intervals once.
        try await store.saveIdleEvidence(current.candidates, deviceID: "drive")
        let stored = try await store.idleEvidence()
        XCTAssertEqual(stored.count, current.candidates.count)
        XCTAssertTrue(early.candidates.allSatisfy(stored.contains))
    }

    func testLocalDatesAndWholeHistoryAreSeparateFromSelection() throws {
        let parse: (String) -> Date = { ISO8601DateFormatter().date(from: $0)! }
        let now = parse("2026-10-07T02:00:00Z")
        let candidates = ["2026-10-06T18:00:00Z", "2026-10-07T00:00:00Z"].map { date in
            let start = parse(date)
            return IdleTemperatureCandidate(deviceID: "drive", firmware: nil, start: start,
                end: start.addingTimeInterval(3_600), temperature: 35, sampleCount: 6,
                hostBytes: 0, stable: true, smartIntervalSeconds: 900)
        }
        let temperatures = (0..<20).map { index in
            TemperatureSample(capturedAt: now.addingTimeInterval(-Double(index) * 86_400),
                deviceID: "drive", temperatureCelsius: 40)
        }
        func assessment(_ zone: String) -> IdleRetentionTemperature {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            return IdleRetentionTemperatureAnalyzer.assess(smart: [], temperatures: temperatures,
                deviceID: "drive", manual: nil, now: now, excluding: [], previous: candidates, calendar: calendar)
        }
        XCTAssertEqual(assessment("Asia/Tokyo").observedDays, 1)
        XCTAssertEqual(assessment("UTC").observedDays, 2)
        XCTAssertEqual(assessment("Asia/Tokyo").historyDays, 20)
        XCTAssertEqual(assessment("Asia/Tokyo").historySampleCount, 20)
        // Optional v2 fields do not invalidate the existing v1 evidence file.
        let restored = try JSONDecoder().decode([IdleTemperatureCandidate].self,
            from: JSONEncoder().encode(candidates))
        XCTAssertNil(restored.first?.relativeLowIO)
        XCTAssertEqual(restored.first?.ruleVersion, 1)
    }

    func testRelativeLowLoadIsLabeledBoundedAndFrequencyIndependent() {
        let hours = 7 * 24
        let history = (0...hours).map { smart(Double($0), read: UInt64(100 + 30_000 * $0)) }
        let samples = temperatures(hours: Double(hours))
        let relative = assess(history, samples, nowHours: Double(hours))
        XCTAssertTrue(relative.relativeLowIO)
        XCTAssertEqual(relative.sourceTitle, "低負荷実測")
        XCTAssertEqual(relative.confidence, .medium)
        XCTAssertGreaterThan(relative.observedDays, 2)
        XCTAssertGreaterThan(relative.ioThresholdBytesPerSecond, 1_048_576)
        let refinedHistory = (0...(hours * 2)).map { smart(Double($0) / 2, read: UInt64(100 + 15_000 * $0)) }
        let refined = assess(refinedHistory, samples, nowHours: Double(hours))
        XCTAssertEqual(relative.ioThresholdBytesPerSecond, refined.ioThresholdBytesPerSecond, accuracy: 1e-6)
        XCTAssertEqual(relative.observedDays, refined.observedDays)
        XCTAssertEqual(relative.confidence, refined.confidence)
        let busy = (0...12).map { smart(Double($0), read: UInt64(100 + 100_000 * $0)) }
        let rejected = assess(busy, temperatures(hours: 12), nowHours: 12)
        XCTAssertEqual(rejected.source, .fallback)
        XCTAssertEqual(rejected.ioThresholdBytesPerSecond, 8 * 1_048_576)
    }

    private func ioSamples(minutes: Int, step: Double = 60,
                           counters: (Int) -> BlockIOCounters = { index in
                               .init(bytesRead: UInt64(index) * 6_000, bytesWritten: UInt64(index) * 600,
                                     bootTime: Date(timeIntervalSince1970: 1_799_999_000), driverID: 7,
                                     observedUptime: 1_000 + Double(index) * 60)
                           }) -> [TemperatureSample] {
        (0...minutes).map { index in
            .init(capturedAt: origin.addingTimeInterval(Double(index) * step), deviceID: "drive",
                  temperatureCelsius: 36, blockIO: counters(index))
        }
    }

    func testMinuteIODetectsTenMinutesDespiteBusyFifteenMinuteSMARTAverage() throws {
        let history = [smart(0), smart(0.25, read: 10_000_000), smart(0.5, read: 20_000_000)]
        let value = assess(history, ioSamples(minutes: 10), nowHours: 0.5)
        let run = try XCTUnwrap(value.candidates.first)
        XCTAssertEqual(value.candidates.count, 1)
        XCTAssertEqual(run.end.timeIntervalSince(run.start), 600)
        XCTAssertEqual(run.effectiveIOSource, .blockIO)
        XCTAssertNil(run.smartIntervalSeconds)
        XCTAssertEqual(run.maximumIOIntervalSeconds, 60)
        XCTAssertEqual(run.uptimeContinuityVerified, true)
        XCTAssertEqual(run.ruleVersion, 3)
        XCTAssertTrue(run.stable)
        XCTAssertTrue(value.provisional)
    }

    func testShortRunsAndFewerThanFiveIOPointsAreNotAccepted() {
        let history = [smart(0), smart(1)]
        XCTAssertTrue(assess(history, ioSamples(minutes: 9), nowHours: 1).candidates.isEmpty)
        let four = ioSamples(minutes: 3, step: 200, counters: { index in
            .init(bytesRead: UInt64(index) * 600, bytesWritten: 0, bootTime: self.origin, driverID: 7)
        })
        XCTAssertTrue(assess(history, four, nowHours: 1).candidates.isEmpty)
    }

    func testTimestampJitterDoesNotRequireAnExtraIOOrSMARTInterval() {
        let history = [smart(0), smart(1)]
        let io = ioSamples(minutes: 10, step: 59.96, counters: { index in
            .init(bytesRead: UInt64(index) * 6_000, bytesWritten: 0, bootTime: self.origin, driverID: 7)
        })
        XCTAssertEqual(assess(history, io, nowHours: 1).candidates.count, 1)
        let almostThirty = 1_799.9
        let fallback = [0.0, 600, 1_200, almostThirty].map {
            TemperatureSample(capturedAt: origin.addingTimeInterval($0), deviceID: "drive", temperatureCelsius: 36)
        }
        let result = assess([smart(0), smart(899.95 / 3_600), smart(almostThirty / 3_600)], fallback, nowHours: 1)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.effectiveIOSource, .smart)
    }

    func testIOBurstSplitsRunsAndCannotBeHiddenByQuietSMARTFallback() {
        let samples = ioSamples(minutes: 22, counters: { index in
            .init(bytesRead: UInt64(index) * 6_000 + (index >= 11 ? 100_000_000 : 0), bytesWritten: 0,
                  bootTime: self.origin, driverID: 7)
        })
        let value = assess([smart(0), smart(1)], samples, nowHours: 1)
        XCTAssertEqual(value.candidates.count, 2)
        XCTAssertTrue(value.candidates.allSatisfy { $0.effectiveIOSource == .blockIO })
        XCTAssertEqual(value.candidates.first?.end, origin.addingTimeInterval(600))
        XCTAssertEqual(value.candidates.last?.start, origin.addingTimeInterval(660))
    }

    func testIOGapSleepResetBootAndDriverBoundariesDoNotJoinRuns() {
        for kind in 0..<4 {
            let samples = ioSamples(minutes: 21, counters: { index in
                let changed = index >= 11
                return .init(bytesRead: UInt64(kind == 0 && changed ? index - 11 : index) * 6_000,
                    bytesWritten: 0,
                    bootTime: self.origin.addingTimeInterval(kind == 1 && changed ? 1 : 0),
                    driverID: kind == 2 && changed ? 8 : 7,
                    observedUptime: 1_000 + Double(index) * 60 - (kind == 3 && changed ? 30 : 0))
            })
            let value = assess([smart(0), smart(1)], samples, nowHours: 1)
            XCTAssertEqual(value.candidates.count, 2, "boundary \(kind)")
            XCTAssertEqual(value.candidates.first?.end, origin.addingTimeInterval(600))
            XCTAssertEqual(value.candidates.last?.start, origin.addingTimeInterval(660))
        }
        let samples = ioSamples(minutes: 31).filter {
            let minute = Int($0.capturedAt.timeIntervalSince(origin) / 60)
            return minute <= 10 || minute >= 21
        }
        let value = assess([smart(0), smart(1)], samples, nowHours: 1)
        XCTAssertEqual(value.candidates.count, 2)
        XCTAssertEqual(value.observedSeconds, 1_200)
    }

    func testIncompleteIOIdentityCannotFallBackToAQuietSMARTAverage() {
        let samples = ioSamples(minutes: 30, counters: { index in
            .init(bytesRead: UInt64(index) * 6_000, bytesWritten: 0, bootTime: self.origin)
        })
        XCTAssertTrue(assess([smart(0), smart(1)], samples, nowHours: 1).candidates.isEmpty)
        XCTAssertTrue(assess([smart(0)], ioSamples(minutes: 10).map {
            TemperatureSample(capturedAt: $0.capturedAt.addingTimeInterval(7_200), deviceID: $0.deviceID,
                              temperatureCelsius: $0.temperatureCelsius, blockIO: $0.blockIO)
        }, nowHours: 3).candidates.isEmpty, "stale SMART firmware context")
    }

    func testExcludedMinuteSplitsPreciseObservations() {
        let exclusion = DateInterval(start: origin.addingTimeInterval(630), duration: 1)
        let value = assess([smart(0), smart(1)], ioSamples(minutes: 21), nowHours: 1, excluding: [exclusion])
        XCTAssertEqual(value.candidates.count, 2)
        XCTAssertTrue(value.candidates.allSatisfy { !DateInterval(start: $0.start, end: $0.end).intersects(exclusion) })
    }

    func testSparseShortIOObservationsStayLowConfidenceRegardlessOfPolling() {
        func value(step: Double) -> IdleRetentionTemperature {
            let history = (0..<3).map { smart(Double($0) * 24) }
            let samples = (0..<3).flatMap { day in
                ioSamples(minutes: Int(600 / step), step: step, counters: { index in
                    .init(bytesRead: UInt64(index) * 100, bytesWritten: 0,
                          bootTime: self.origin.addingTimeInterval(Double(day) * 86_400), driverID: 7)
                }).map {
                    TemperatureSample(capturedAt: $0.capturedAt.addingTimeInterval(Double(day) * 86_400),
                                      deviceID: $0.deviceID, temperatureCelsius: $0.temperatureCelsius, blockIO: $0.blockIO)
                }
            }
            return assess(history, samples, nowHours: 49)
        }
        let minute = value(step: 60), denser = value(step: 30)
        XCTAssertEqual(minute.candidates.count, 3)
        XCTAssertEqual(minute.observedDays, 3)
        XCTAssertEqual(minute.observedSeconds, 1_800)
        XCTAssertEqual(minute.confidence, .low)
        XCTAssertEqual(minute.confidence, denser.confidence)
        XCTAssertEqual(minute.observedSeconds, denser.observedSeconds)
    }

    func testIOThresholdUsesItsOwnCounterSeriesAndEvidenceRoundTrips() throws {
        let history = (0...7).map { smart(Double($0), read: UInt64($0) * 1_000_000) }
        let samples = ioSamples(minutes: 7 * 60, counters: { index in
            .init(bytesRead: UInt64(index) * 60 * 2 * 1_048_576, bytesWritten: 0, bootTime: self.origin, driverID: 7)
        })
        let value = assess(history, samples, nowHours: 7)
        XCTAssertEqual(value.blockIOSelectionThreshold, 2 * 1_048_576)
        XCTAssertNil(value.smartSelectionThreshold)
        XCTAssertTrue(value.relativeLowIO)
        XCTAssertFalse(value.candidates.isEmpty)
        let decoded = try JSONDecoder().decode([IdleTemperatureCandidate].self, from: JSONEncoder().encode(value.candidates))
        XCTAssertEqual(decoded, value.candidates)
        XCTAssertEqual(decoded.first?.ioSource, .blockIO)
        let oldCounter = Data("{\"bytesRead\":0,\"bytesWritten\":0,\"bootTime\":0,\"driverID\":7}".utf8)
        XCTAssertNil(try JSONDecoder().decode(BlockIOCounters.self, from: oldCounter).observedUptime)
    }

    func testPowerCycleContextAndDuplicateTemperaturePointsDoNotCreateEvidence() {
        let after = smart(11.0 / 60, cycles: 2)
        let value = assess([smart(0), after], ioSamples(minutes: 21), nowHours: 1)
        XCTAssertEqual(value.candidates.count, 2)
        let four = ioSamples(minutes: 3, step: 200, counters: { index in
            .init(bytesRead: UInt64(index) * 600, bytesWritten: 0, bootTime: self.origin, driverID: 7)
        })
        XCTAssertTrue(assess([smart(0), smart(1)], four + [four[1], four[2]], nowHours: 1).candidates.isEmpty)
    }

    func testNewIOEvidencePreservesOlderOverlappingSMARTCandidate() {
        let old = IdleTemperatureCandidate(deviceID: "drive", firmware: "FW1", start: origin,
            end: origin.addingTimeInterval(1_800), temperature: 30, sampleCount: 31, hostBytes: 0,
            stable: true, smartIntervalSeconds: 900, ruleVersion: 2)
        let samples = ioSamples(minutes: 50).filter {
            let minute = Int($0.capturedAt.timeIntervalSince(origin) / 60)
            return minute <= 10 || minute >= 40
        }
        let value = assess([smart(0), smart(0.5), smart(1)], samples, nowHours: 1, previous: [old])
        XCTAssertEqual(value.candidates.count, 2)
        XCTAssertTrue(value.candidates.contains(old))
        XCTAssertEqual(value.candidates.last?.ioSource, .blockIO)
        XCTAssertEqual(value.observedSeconds, 2_400)
    }
}
