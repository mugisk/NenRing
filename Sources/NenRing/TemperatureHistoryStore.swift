import Foundation

/// Temperature is sampled independently from the cumulative SMART snapshot.
/// Its retention policy is separate so a more frequent thermal interval never
/// inflates or changes the write-counter history.
struct TemperatureHistoryRetentionPolicy: Sendable {
    static let standard = TemperatureHistoryRetentionPolicy(
        fullResolutionAge: 48 * 60 * 60,
        mediumResolutionAge: 30 * 24 * 60 * 60,
        mediumBucketDuration: 5 * 60,
        archiveBucketDuration: 24 * 60 * 60,
        maximumRecordCount: 25_000,
        compactionInterval: 256,
        preservesAllMeasurements: true
    )

    let fullResolutionAge: TimeInterval
    let mediumResolutionAge: TimeInterval
    let mediumBucketDuration: TimeInterval
    let archiveBucketDuration: TimeInterval
    let maximumRecordCount: Int
    let compactionInterval: Int
    let preservesAllMeasurements: Bool

    init(
        fullResolutionAge: TimeInterval,
        mediumResolutionAge: TimeInterval,
        mediumBucketDuration: TimeInterval,
        archiveBucketDuration: TimeInterval,
        maximumRecordCount: Int,
        compactionInterval: Int,
        preservesAllMeasurements: Bool = false
    ) {
        let normalizedFullAge = max(0, fullResolutionAge)
        let normalizedMediumAge = max(normalizedFullAge, mediumResolutionAge)
        let normalizedMediumBucket = max(30, mediumBucketDuration)
        self.fullResolutionAge = normalizedFullAge
        self.mediumResolutionAge = normalizedMediumAge
        self.mediumBucketDuration = normalizedMediumBucket
        self.archiveBucketDuration = max(normalizedMediumBucket, archiveBucketDuration)
        self.maximumRecordCount = max(2, maximumRecordCount)
        self.compactionInterval = max(1, compactionInterval)
        self.preservesAllMeasurements = preservesAllMeasurements
    }

    func compact(
        _ records: [TemperatureSample],
        referenceDate suppliedReferenceDate: Date? = nil
    ) -> [TemperatureSample] {
        guard records.count > 2 else {
            return records.sorted { $0.capturedAt < $1.capturedAt }
        }

        let ordered = records.enumerated().sorted { left, right in
            if left.element.capturedAt == right.element.capturedAt {
                return left.offset < right.offset
            }
            return left.element.capturedAt < right.element.capturedAt
        }.map(\.element)
        if preservesAllMeasurements { return ordered }
        let newestDate = ordered.last?.capturedAt ?? Date()
        let referenceDate = suppliedReferenceDate.map { max($0, newestDate) } ?? newestDate

        var retainedIDs = Set<UUID>()
        var endpointIDs = Set<UUID>()
        var daySummaries: [TemperatureSample] = []
        for series in Dictionary(grouping: ordered, by: \.deviceID).values {
            guard let first = series.first, let last = series.last else { continue }
            retainedIDs.formUnion([first.id, last.id])
            endpointIDs.formUnion([first.id, last.id])

            var bucketWinners: [TemperatureBucket: TemperatureSample] = [:]
            var dayBuckets: [Int64: [TemperatureSample]] = [:]
            for sample in series {
                let age = max(0, referenceDate.timeIntervalSince(sample.capturedAt))
                if age <= fullResolutionAge {
                    retainedIDs.insert(sample.id)
                    continue
                }
                if age > mediumResolutionAge {
                    // Endpoints are kept as they are and stay out of the day
                    // summary, so compacting again leaves the summary unchanged.
                    guard !endpointIDs.contains(sample.id) else { continue }
                    let day = Int64(floor(sample.capturedAt.timeIntervalSince1970 / archiveBucketDuration))
                    dayBuckets[day, default: []].append(sample)
                    continue
                }

                let duration = age <= mediumResolutionAge
                    ? mediumBucketDuration
                    : archiveBucketDuration
                let tier: TemperatureBucket.Tier = age <= mediumResolutionAge ? .medium : .archive
                let bucket = TemperatureBucket(
                    tier: tier,
                    index: Int64(floor(sample.capturedAt.timeIntervalSince1970 / duration))
                )
                if let previous = bucketWinners[bucket] {
                    if sample.capturedAt >= previous.capturedAt {
                        bucketWinners[bucket] = sample
                    }
                } else {
                    bucketWinners[bucket] = sample
                }
            }
            retainedIDs.formUnion(bucketWinners.values.map(\.id))
            for samples in dayBuckets.values {
                let summary = Self.daySummary(of: samples)
                if summary.id != samples.first?.id || samples.count > 1 {
                    daySummaries.append(summary)
                }
                retainedIDs.insert(summary.id)
            }
        }

        var retained = (ordered + daySummaries)
            .filter { retainedIDs.contains($0.id) }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard retained.count > maximumRecordCount else { return retained }

        var boundedIDs = Set<UUID>()
        for sample in retained where endpointIDs.contains(sample.id) {
            guard boundedIDs.count < maximumRecordCount else { break }
            boundedIDs.insert(sample.id)
        }
        for sample in retained.reversed() where boundedIDs.count < maximumRecordCount {
            boundedIDs.insert(sample.id)
        }
        retained.removeAll { !boundedIDs.contains($0.id) }
        return retained
    }
}

extension TemperatureHistoryRetentionPolicy {
    /// One sample for a day: the rounded average at the time of the day's last
    /// reading, with minimum, maximum and count. A day that is already a single
    /// summary is returned unchanged.
    static func daySummary(of samples: [TemperatureSample]) -> TemperatureSample {
        let ordered = samples.sorted { $0.capturedAt < $1.capturedAt }
        if ordered.count == 1, let only = ordered.first, only.dailySummary != nil {
            return only
        }
        var minimum = Int.max
        var maximum = Int.min
        var total = 0.0
        var count = 0
        for sample in ordered {
            let summary = sample.dailySummary ?? TemperatureSample.DailySummary(
                minimumCelsius: sample.temperatureCelsius,
                maximumCelsius: sample.temperatureCelsius,
                averageCelsius: Double(sample.temperatureCelsius),
                sampleCount: 1
            )
            minimum = min(minimum, summary.minimumCelsius)
            maximum = max(maximum, summary.maximumCelsius)
            total += summary.averageCelsius * Double(summary.sampleCount)
            count += summary.sampleCount
        }
        let last = ordered[ordered.count - 1]
        let average = total / Double(max(count, 1))
        return TemperatureSample(
            capturedAt: last.capturedAt,
            deviceID: last.deviceID,
            temperatureCelsius: Int(average.rounded()),
            dailySummary: TemperatureSample.DailySummary(
                minimumCelsius: minimum,
                maximumCelsius: maximum,
                averageCelsius: average,
                sampleCount: count
            )
        )
    }
}

private struct TemperatureBucket: Hashable {
    enum Tier: Hashable {
        case medium
        case archive
    }

    let tier: Tier
    let index: Int64
}

actor TemperatureHistoryStore {
    private let fileURL: URL
    private let retentionPolicy: TemperatureHistoryRetentionPolicy
    private var cache: [TemperatureSample]?
    private struct ChartDay: Hashable {
        let deviceID: String
        let day: Date
    }
    private struct ChartTotal {
        var sum = 0.0
        var count = 0
    }
    private var chartDays: [ChartDay: ChartTotal]?

    private func addChartSample(_ sample: TemperatureSample) {
        let key = ChartDay(deviceID: sample.deviceID, day: Calendar.current.startOfDay(for: sample.capturedAt))
        let count = sample.dailySummary?.sampleCount ?? 1
        let value = sample.dailySummary?.averageCelsius ?? Double(sample.temperatureCelsius)
        guard count > 0, value.isFinite else { return }
        chartDays?[key, default: ChartTotal()].sum += value * Double(count)
        chartDays?[key, default: ChartTotal()].count += count
    }

    /// Compact chart-only averages; the original observations remain in storage.
    func olderChartPoints(deviceID: String?, before cutoff: Date) throws -> [TemperaturePoint] {
        if chartDays == nil {
            let all = try ensureLoaded()
            chartDays = [:]
            for sample in all { addChartSample(sample) }
        }
        let boundary = Calendar.current.startOfDay(for: cutoff)
        return (chartDays ?? [:]).compactMap { key, total in
            guard (deviceID == nil || key.deviceID == deviceID), key.day < boundary, total.count > 0 else { return nil }
            return TemperaturePoint(date: key.day, celsius: total.sum / Double(total.count))
        }.sorted { $0.date < $1.date }
    }
    /// Latest capture time per device, so a per-minute append does not scan
    /// the whole history. Built once after loading; appends keep it current
    /// and compaction never removes a device's newest sample.
    private var latestCapturedAt: [String: Date]?
    private var strings = HistoryStringPool()

    /// Window of samples kept in memory once `trimToWindow` runs. The
    /// analyses read 30 days; the rest is a margin for daily trimming.
    static let memoryWindow: TimeInterval = 35 * 86_400
    /// Event temperatures for older ranges, built from the full history at
    /// load and kept current by appends and new FTL snapshot times.
    private var intervalTable: TemperatureIntervalTable?
    /// Per device, samples before this time may have been dropped from memory.
    private var coverageStart: [String: Date] = [:]
    private var trimmedBefore: Date?
    private var lastTrim: Date?
    /// Whether any sample exists, also after trimming (chart fallback).
    private var hasAnySample = false
    private var acceptedAppendsSinceCompaction = 0
    private var jsonlDecodeDiagnostics = JSONLDecodeDiagnostics.clean
    private var losslessStorage: LosslessHistoryStorage<TemperatureSample>?

    init(
        fileURL: URL? = nil,
        retentionPolicy: TemperatureHistoryRetentionPolicy = .standard
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppDataLocation.directoryURL
                .appendingPathComponent("temperature-history.jsonl")
        }
        self.retentionPolicy = retentionPolicy
        if retentionPolicy.preservesAllMeasurements {
            losslessStorage = LosslessHistoryStorage(fileURL: self.fileURL)
        }
    }

    func records() throws -> [TemperatureSample] {
        try ensureLoaded()
    }

    func decodeDiagnostics() -> JSONLDecodeDiagnostics {
        jsonlDecodeDiagnostics
    }

    private var idleEvidenceURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("idle-temperature-evidence.json")
    }

    func idleEvidence() throws -> [IdleTemperatureCandidate] {
        guard FileManager.default.fileExists(atPath: idleEvidenceURL.path) else { return [] }
        return try JSONDecoder().decode([IdleTemperatureCandidate].self, from: Data(contentsOf: idleEvidenceURL))
    }

    /// Keep all accepted intervals for the long-term retention-temperature
    /// estimate. Fresh observations are still derived from the recent window.
    func saveIdleEvidence(_ candidates: [IdleTemperatureCandidate], deviceID: String) throws {
        let old = try idleEvidence()
        // The 30-day analysis cutoff can produce only a suffix of a stored
        // run. Replace a run only with a covering observation of comparable
        // density. Shared endpoints are adjacent runs, not overlaps.
        var updated = old
        for candidate in candidates where candidate.deviceID == deviceID {
            let overlaps = updated.filter {
                $0.deviceID == deviceID && $0.firmware == candidate.firmware
                    && candidate.start < $0.end && candidate.end > $0.start
            }
            let density = Double(candidate.sampleCount) / max(1, candidate.end.timeIntervalSince(candidate.start))
            guard overlaps.allSatisfy({ stored in
                let storedDensity = Double(stored.sampleCount) / max(1, stored.end.timeIntervalSince(stored.start))
                return candidate.start <= stored.start && candidate.end >= stored.end
                    && candidate.ruleVersion >= stored.ruleVersion && density >= storedDensity / 2
            }) else { continue }
            updated.removeAll { overlaps.contains($0) }
            updated.append(candidate)
        }
        updated.sort { $0.deviceID == $1.deviceID ? $0.end < $1.end : $0.deviceID < $1.deviceID }
        guard updated != old else { return }
        try FileManager.default.createDirectory(at: idleEvidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: idleEvidenceURL, options: .atomic)
    }

    /// The samples from one day before `cutoff` on, for the per-minute
    /// chart. Only this window is copied out, so the store stays the only
    /// owner of the full history and appends do not copy it.
    func recentRecords(since cutoff: Date) throws -> (records: [TemperatureSample], hasAny: Bool) {
        let all = try ensureLoaded()
        return (Array(HistoryAnalyzer.recentSuffix(of: all, since: cutoff, capturedAt: \.capturedAt)), hasAnySample)
    }

    /// Builds the interval table from the full history. Call before
    /// `trimToWindow`, with every FTL snapshot time per device.
    func prepareIntervals(boundaries: [String: [Date]]) throws {
        let all = try ensureLoaded()
        intervalTable = TemperatureIntervalTable(boundaries: boundaries, samples: all)
    }

    /// Adds an FTL snapshot time. A time older than the device's last one,
    /// or one whose range is no longer in memory, rebuilds the table from
    /// the stored history.
    func addIntervalBoundary(deviceID: String, at boundary: Date) throws {
        guard intervalTable != nil else { return }
        let last = intervalTable?.lastBoundary(deviceID: deviceID)
        let needed = min(last ?? boundary, boundary).addingTimeInterval(-TemperatureIntervalSummaryReference.nearestLimit)
        let covered = (coverageStart[deviceID] ?? trimmedBefore).map { $0 <= needed } ?? true
        // Only the end of the history from `needed` on is visited.
        let recent = HistoryAnalyzer.recentSuffix(of: cache ?? [], since: needed, capturedAt: \.capturedAt)
        if covered, intervalTable?.appendBoundary(deviceID: deviceID, at: boundary, samples: recent) == true {
            return
        }
        var boundaries = intervalTable?.devices.mapValues(\.boundaries) ?? [:]
        boundaries[deviceID, default: []].append(boundary)
        try reloadFullHistory()
        try prepareIntervals(boundaries: boundaries)
        if let lastTrim { try trim(now: lastTrim) }
    }

    /// Drops samples older than the window from memory, at most once a day.
    /// Samples from 30 minutes before each device's last FTL snapshot time
    /// are kept, so the next snapshot time can split the open range. The
    /// stored history is not changed.
    func trimToWindow(now: Date) throws {
        guard intervalTable != nil, losslessStorage != nil else { return }
        if let lastTrim, now.timeIntervalSince(lastTrim) < 86_400 { return }
        try trim(now: now)
    }

    private func trim(now: Date) throws {
        guard let table = intervalTable, losslessStorage != nil else { return }
        _ = try ensureLoaded()
        let cutoff = now.addingTimeInterval(-Self.memoryWindow)
        var keepFrom: [String: Date] = [:]
        for (deviceID, device) in table.devices {
            if let last = device.boundaries.last {
                keepFrom[deviceID] = min(cutoff, last.addingTimeInterval(-TemperatureIntervalSummaryReference.nearestLimit))
            }
        }
        cache = cache?.filter { $0.capturedAt >= (keepFrom[$0.deviceID] ?? cutoff) }
        coverageStart = keepFrom
        trimmedBefore = cutoff
        lastTrim = now
    }

    private func reloadFullHistory() throws {
        cache = nil
        coverageStart = [:]
        trimmedBefore = nil
        _ = try ensureLoaded()
    }

    /// The samples kept in memory and the table for older event ranges.
    func analysisInput() throws -> (samples: [TemperatureSample], table: TemperatureIntervalTable?) {
        (try ensureLoaded(), intervalTable)
    }

    @discardableResult
    func appendIfNew(_ sample: TemperatureSample) throws -> Bool {
        var latest: [String: Date]
        do {
            latest = try latestCaptureTimes()
        } catch {
            guard let storage = losslessStorage, let tail = storage.cleanTail() else { throw error }
            // An unreadable block must not also lose later samples. `cache`
            // stays nil, so every later read keeps retrying the full history.
            let isDuplicate = tail.contains {
                $0.deviceID == sample.deviceID && abs(sample.capturedAt.timeIntervalSince($0.capturedAt)) < 5
            }
            guard !isDuplicate else { return false }
            try storage.appendWithoutLoading(sample)
            return true
        }
        if let last = latest[sample.deviceID],
           abs(sample.capturedAt.timeIntervalSince(last)) < 5 {
            return false
        }
        latest[sample.deviceID] = max(latest[sample.deviceID] ?? sample.capturedAt, sample.capturedAt)

        if losslessStorage != nil {
            try append(sample)
            // In place: callers receive copies of the recent window, so the
            // store is the only owner and the append does not copy the history.
            let stored = sharingStrings(sample)
            cache?.append(stored)
            addChartSample(stored)
            intervalTable?.add(stored)
            hasAnySample = true
            latestCapturedAt = latest
            return true
        }

        let current = try ensureLoaded()
        let updated = current + [sample]
        if jsonlDecodeDiagnostics.canCompact {
            acceptedAppendsSinceCompaction += 1
        }
        if jsonlDecodeDiagnostics.canCompact &&
            (updated.count > retentionPolicy.maximumRecordCount ||
             acceptedAppendsSinceCompaction >= retentionPolicy.compactionInterval) {
            let compacted = retentionPolicy.compact(updated, referenceDate: sample.capturedAt)
            if compacted.count < updated.count {
                try backupOriginalHistoryIfNeeded()
            }
            try CompactionArchive(sourceURL: fileURL).store(removedFrom: updated, keeping: compacted, capturedAt: \.capturedAt)
            try rewrite(compacted)
            cache = compacted
            acceptedAppendsSinceCompaction = 0
        } else {
            try append(sample)
            cache = updated
        }
        latestCapturedAt = latest
        addChartSample(sample)
        return true
    }

    private func latestCaptureTimes() throws -> [String: Date] {
        _ = try ensureLoaded()
        if let latestCapturedAt { return latestCapturedAt }
        let latest = (cache ?? []).reduce(into: [String: Date]()) { latest, item in
            latest[item.deviceID] = max(latest[item.deviceID] ?? item.capturedAt, item.capturedAt)
        }
        latestCapturedAt = latest
        return latest
    }

    private func sharingStrings(_ sample: TemperatureSample) -> TemperatureSample {
        TemperatureSample(id: sample.id, capturedAt: sample.capturedAt, deviceID: strings.shared(sample.deviceID),
                          temperatureCelsius: sample.temperatureCelsius, dailySummary: sample.dailySummary,
                          blockIO: sample.blockIO)
    }

    private func ensureLoaded() throws -> [TemperatureSample] {
        if let cache { return cache }
        latestCapturedAt = nil
        if var storage = losslessStorage {
            let restored = try storage.load().sorted { $0.capturedAt < $1.capturedAt }
            let loaded = Self.removingRestoredSummaries(restored)
            if loaded != restored { try storage.replace(loaded) }
            jsonlDecodeDiagnostics = storage.diagnostics
            losslessStorage = storage
            let shared = loaded.map(sharingStrings)
            cache = shared
            hasAnySample = !shared.isEmpty
            return shared
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            jsonlDecodeDiagnostics = .clean
            cache = []
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var parsed = [TemperatureSample]()
        var failedLineNumbers = [Int]()
        var rejectedRows = [(lineNumber: Int, bytes: Data)]()
        var failedLineCount = 0
        for (offset, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            guard !line.isEmpty else { continue }
            do {
                parsed.append(try decoder.decode(TemperatureSample.self, from: Data(line)))
            } catch {
                failedLineCount += 1
                if failedLineNumbers.count < 5 { failedLineNumbers.append(offset + 1) }
                rejectedRows.append((offset + 1, Data(line)))
            }
        }
        jsonlDecodeDiagnostics = JSONLDecodeDiagnostics(
            failedLineCount: failedLineCount,
            sampleLineNumbers: failedLineNumbers
        )
        if JSONLQuarantine.isMostlyUnreadable(failedRows: failedLineCount, readableRows: parsed.count) {
            let asideURL = try JSONLQuarantine.setAside(sourceURL: fileURL)
            try rewrite(parsed)
            jsonlDecodeDiagnostics = JSONLDecodeDiagnostics(
                failedLineCount: failedLineCount,
                sampleLineNumbers: failedLineNumbers,
                quarantineFileName: asideURL.lastPathComponent,
                sourceRepaired: true
            )
            cache = parsed
            acceptedAppendsSinceCompaction = 0
            return parsed
        }
        if jsonlDecodeDiagnostics.hasFailures {
            // Preserve exact malformed row bytes before rewriting the source.
            // If quarantine or repair fails, propagate the error and leave the
            // original JSONL untouched so an append cannot evade retention.
            let quarantineURL = try JSONLQuarantine.archive(
                rows: rejectedRows,
                sourceData: data,
                sourceURL: fileURL
            )
            jsonlDecodeDiagnostics = JSONLDecodeDiagnostics(
                failedLineCount: failedLineCount,
                sampleLineNumbers: failedLineNumbers,
                quarantineFileName: quarantineURL.lastPathComponent
            )
            try backupOriginalHistoryIfNeeded()
            let compacted = retentionPolicy.compact(parsed)
            try CompactionArchive(sourceURL: fileURL).store(removedFrom: parsed, keeping: compacted, capturedAt: \.capturedAt)
            try rewrite(compacted)
            jsonlDecodeDiagnostics = JSONLDecodeDiagnostics(
                failedLineCount: failedLineCount,
                sampleLineNumbers: failedLineNumbers,
                quarantineFileName: quarantineURL.lastPathComponent,
                sourceRepaired: true
            )
            cache = compacted
            acceptedAppendsSinceCompaction = 0
            return compacted
        }
        let compacted = retentionPolicy.compact(parsed)
        if compacted != parsed {
            if compacted.count < parsed.count {
                try backupOriginalHistoryIfNeeded()
            }
            try CompactionArchive(sourceURL: fileURL).store(removedFrom: parsed, keeping: compacted, capturedAt: \.capturedAt)
            try rewrite(compacted)
        }
        cache = compacted
        return compacted
    }

    private func append(_ sample: TemperatureSample) throws {
        if losslessStorage != nil {
            try losslessStorage!.append(sample)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lineData = try encoder.encode(sample) + Data([0x0A])
        try ensureDirectoryExists()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            try handle.seek(toOffset: endOffset - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: lineData)
    }

    private func rewrite(_ records: [TemperatureSample]) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func backupOriginalHistoryIfNeeded() throws {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).pre-compaction-v1.jsonl")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    /// A legacy rounded day is redundant only when its complete constituent
    /// readings have been recovered. Incomplete legacy evidence stays labeled
    /// as a summary; it is never invented as individual observations.
    private static func removingRestoredSummaries(_ records: [TemperatureSample]) -> [TemperatureSample] {
        struct Day: Hashable { let device: String; let index: Int64 }
        func key(_ sample: TemperatureSample) -> Day {
            Day(device: sample.deviceID, index: Int64(floor(sample.capturedAt.timeIntervalSince1970 / 86_400)))
        }
        let raw = Dictionary(grouping: records.filter { $0.dailySummary == nil }, by: key)
        return records.filter { sample in
            guard let summary = sample.dailySummary, summary.sampleCount > 0,
                  let candidates = raw[key(sample)] else { return true }
            let original = Array(candidates.filter { $0.capturedAt <= sample.capturedAt }.suffix(summary.sampleCount))
            guard original.count == summary.sampleCount,
                  original.last?.capturedAt == sample.capturedAt,
                  original.map(\.temperatureCelsius).min() == summary.minimumCelsius,
                  original.map(\.temperatureCelsius).max() == summary.maximumCelsius else { return true }
            let average = original.reduce(0.0) { $0 + Double($1.temperatureCelsius) } / Double(original.count)
            return abs(average - summary.averageCelsius) > 1e-12
        }
    }
}
