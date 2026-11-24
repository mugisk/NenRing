import CryptoKit
import Foundation

struct JSONLDecodeDiagnostics: Equatable, Sendable {
    static let clean = JSONLDecodeDiagnostics(failedLineCount: 0, sampleLineNumbers: [])

    let failedLineCount: Int
    let sampleLineNumbers: [Int]
    let quarantineFileName: String?
    let sourceRepaired: Bool

    init(
        failedLineCount: Int,
        sampleLineNumbers: [Int],
        quarantineFileName: String? = nil,
        sourceRepaired: Bool = false
    ) {
        self.failedLineCount = failedLineCount
        self.sampleLineNumbers = sampleLineNumbers
        self.quarantineFileName = quarantineFileName
        self.sourceRepaired = sourceRepaired
    }

    var hasFailures: Bool { failedLineCount > 0 }
    var canCompact: Bool { !hasFailures || sourceRepaired }

    var summary: String {
        guard hasFailures else { return "JSONL読み込み正常" }
        let lines = sampleLineNumbers.map(String.init).joined(separator: ", ")
        let suffix = failedLineCount > sampleLineNumbers.count ? "、…" : ""
        let archive = quarantineFileName.map { "別ファイル \($0) に退避" } ?? "別ファイルへ退避"
        let repair = sourceRepaired ? "正常行で履歴を修復し、圧縮を再開しました" : "原本を保持し修復を待っています"
        return "\(failedLineCount)行を解析できず（行 \(lines)\(suffix)、\(archive)）。\(repair)。"
    }
}

private struct JSONLRejectedRow: Codable {
    let sourceFile: String
    let sourceSHA256: String
    let lineNumber: Int
    let rawLineBase64: String
}

enum JSONLQuarantine {
    /// When most rows cannot be read (for example a build that does not
    /// understand a newer format), repairing the file would leave a nearly
    /// empty history and the old rows only in base64 form. Such a file is
    /// moved aside unchanged instead.
    static func isMostlyUnreadable(failedRows: Int, readableRows: Int) -> Bool {
        failedRows > readableRows
    }

    /// Renames the source to `<name>.unreadable-<UTC time>.jsonl` in the same
    /// folder, so every byte is kept, and returns the new location.
    static func setAside(sourceURL: URL, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let folder = sourceURL.deletingLastPathComponent()
        var destination = folder.appendingPathComponent("\(stem).unreadable-\(formatter.string(from: now)).jsonl")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(
                "\(stem).unreadable-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8)).jsonl")
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        return destination
    }

    static func destinationURL(sourceData: Data, sourceURL: URL) -> URL {
        let digest = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return sourceURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).rejected-\(digest).jsonl")
    }

    static func archive(
        rows: [(lineNumber: Int, bytes: Data)],
        sourceData: Data,
        sourceURL: URL
    ) throws -> URL {
        let digest = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined()
        let destination = destinationURL(sourceData: sourceData, sourceURL: sourceURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var archiveData = Data()
        for row in rows {
            let rejected = JSONLRejectedRow(
                sourceFile: sourceURL.lastPathComponent,
                sourceSHA256: digest,
                lineNumber: row.lineNumber,
                rawLineBase64: row.bytes.base64EncodedString()
            )
            archiveData.append(try encoder.encode(rejected))
            archiveData.append(0x0A)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  try Data(contentsOf: destination) == archiveData else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
        } else {
            try archiveData.write(to: destination, options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }
}

struct HistoryRetentionPolicy: Sendable {
    /// Standard monitoring uses bounded on-disk blocks rather than deleting
    /// observations. Age/bucket settings remain for legacy sampled histories.
    static let standard = HistoryRetentionPolicy(
        fullResolutionAge: 48 * 60 * 60,
        mediumResolutionAge: 90 * 24 * 60 * 60,
        mediumBucketDuration: 15 * 60,
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
        let normalizedMediumBucket = max(60, mediumBucketDuration)
        self.fullResolutionAge = normalizedFullAge
        self.mediumResolutionAge = normalizedMediumAge
        self.mediumBucketDuration = normalizedMediumBucket
        self.archiveBucketDuration = max(normalizedMediumBucket, archiveBucketDuration)
        self.maximumRecordCount = max(2, maximumRecordCount)
        self.compactionInterval = max(1, compactionInterval)
        self.preservesAllMeasurements = preservesAllMeasurements
    }

    func compact(
        _ records: [DriveSnapshot],
        referenceDate suppliedReferenceDate: Date? = nil
    ) -> [DriveSnapshot] {
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
        var anchorIDs = Set<UUID>()
        var endpointIDs = Set<UUID>()

        for series in Dictionary(grouping: ordered, by: \.deviceID).values {
            guard let first = series.first, let last = series.last else { continue }
            retainedIDs.formUnion([first.id, last.id])
            anchorIDs.formUnion([first.id, last.id])
            endpointIDs.formUnion([first.id, last.id])

            var bucketWinners: [HistoryBucket: DriveSnapshot] = [:]
            for snapshot in series {
                let age = max(0, referenceDate.timeIntervalSince(snapshot.capturedAt))
                if age <= fullResolutionAge {
                    retainedIDs.insert(snapshot.id)
                    continue
                }

                let duration = age <= mediumResolutionAge
                    ? mediumBucketDuration
                    : archiveBucketDuration
                let tier: HistoryBucket.Tier = age <= mediumResolutionAge ? .medium : .archive
                let bucket = HistoryBucket(
                    tier: tier,
                    index: Int64(floor(snapshot.capturedAt.timeIntervalSince1970 / duration))
                )
                if let previous = bucketWinners[bucket] {
                    if snapshot.capturedAt >= previous.capturedAt {
                        bucketWinners[bucket] = snapshot
                    }
                } else {
                    bucketWinners[bucket] = snapshot
                }
            }
            retainedIDs.formUnion(bucketWinners.values.map(\.id))

            for (previous, current) in zip(series, series.dropFirst()) {
                if isAnalysisBoundary(previous: previous, current: current) {
                    retainedIDs.formUnion([previous.id, current.id])
                    anchorIDs.formUnion([previous.id, current.id])
                }
            }
        }

        var retained = ordered.filter { retainedIDs.contains($0.id) }
        guard retained.count > maximumRecordCount else { return retained }

        // A pathological history can contain more boundaries than the hard
        // limit. Keep per-device endpoints first, then the newest analysis
        // boundaries, then the newest representative samples.
        var boundedIDs = Set<UUID>()
        let endpoints = retained.filter { endpointIDs.contains($0.id) }
        for snapshot in endpoints.suffix(maximumRecordCount) {
            boundedIDs.insert(snapshot.id)
        }

        let anchors = retained.filter {
            anchorIDs.contains($0.id) && !boundedIDs.contains($0.id)
        }
        for snapshot in anchors.reversed() where boundedIDs.count < maximumRecordCount {
            boundedIDs.insert(snapshot.id)
        }

        for snapshot in retained.reversed() where boundedIDs.count < maximumRecordCount {
            boundedIDs.insert(snapshot.id)
        }
        retained.removeAll { !boundedIDs.contains($0.id) }
        return retained
    }

    private func isAnalysisBoundary(
        previous: DriveSnapshot,
        current: DriveSnapshot
    ) -> Bool {
        if let previousPercentage = previous.percentageUsed,
           let currentPercentage = current.percentageUsed,
           previousPercentage != currentPercentage {
            return true
        }
        if let previousUnits = previous.dataUnitsWritten,
           let currentUnits = current.dataUnitsWritten,
           currentUnits < previousUnits {
            return true
        }
        if let previousHours = previous.powerOnHours,
           let currentHours = current.powerOnHours,
           currentHours < previousHours {
            return true
        }
        if let previousFirmware = previous.firmware,
           let currentFirmware = current.firmware,
           previousFirmware != currentFirmware {
            return true
        }
        // An unpowered period (elapsed time minus the Power On Hours
        // increase) keeps both sides, so `observedRetentionDays` finds the
        // same period after thinning instead of a day that merges several.
        // Power On Hours counts whole hours, so shorter gaps are noise.
        if let previousHours = previous.powerOnHours,
           let currentHours = current.powerOnHours,
           currentHours >= previousHours {
            let elapsed = current.capturedAt.timeIntervalSince(previous.capturedAt)
            if elapsed - Double(currentHours - previousHours) * 3_600 > Self.unpoweredBoundarySeconds {
                return true
            }
        }
        return false
    }

    static let unpoweredBoundarySeconds: TimeInterval = 3_600
}

private struct HistoryBucket: Hashable {
    enum Tier: Hashable {
        case medium
        case archive
    }

    let tier: Tier
    let index: Int64
}

actor HistoryStore {
    private let fileURL: URL
    private let retentionPolicy: HistoryRetentionPolicy
    private var cache: [DriveSnapshot]?
    private var acceptedAppendsSinceCompaction = 0
    private var jsonlDecodeDiagnostics = JSONLDecodeDiagnostics.clean
    private var losslessStorage: LosslessHistoryStorage<DriveSnapshot>?
    private var strings = HistoryStringPool()

    init(
        fileURL: URL? = nil,
        retentionPolicy: HistoryRetentionPolicy = .standard
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppDataLocation.directoryURL
                .appendingPathComponent("history.jsonl")
        }
        self.retentionPolicy = retentionPolicy
        if retentionPolicy.preservesAllMeasurements {
            losslessStorage = LosslessHistoryStorage(fileURL: self.fileURL)
        }
    }

    func records() throws -> [DriveSnapshot] {
        try ensureLoaded()
    }

    func decodeDiagnostics() -> JSONLDecodeDiagnostics {
        jsonlDecodeDiagnostics
    }

    @discardableResult
    func appendIfNew(_ snapshot: DriveSnapshot) throws -> Bool {
        var current: [DriveSnapshot]
        do {
            current = try ensureLoaded()
        } catch {
            guard let storage = losslessStorage, let tail = storage.cleanTail() else { throw error }
            return try appendWithoutLoading(snapshot, tail: tail, to: storage)
        }
        let migrated = migrateUnqualifiedSeries(current, for: snapshot)
        if migrated != current {
            if jsonlDecodeDiagnostics.canCompact {
                try rewrite(migrated)
            }
            cache = migrated
            current = migrated
        }

        var canonicalSnapshot = snapshot
        // The parsed values are kept; the raw smartctl output is not
        // repeated in every record. Records already saved are not changed.
        canonicalSnapshot.rawJSON = ""
        if let existingID = uniqueCapacitySeriesID(for: snapshot, in: current) {
            canonicalSnapshot.deviceID = existingID
        }
        if losslessStorage != nil {
            canonicalSnapshot = sharingStrings(canonicalSnapshot)
        }

        if let last = current
            .filter({ $0.deviceID == canonicalSnapshot.deviceID })
            .max(by: { $0.capturedAt < $1.capturedAt }),
           abs(canonicalSnapshot.capturedAt.timeIntervalSince(last.capturedAt)) < 60 {
            return false
        }

        let updated = current + [canonicalSnapshot]
        if losslessStorage == nil && jsonlDecodeDiagnostics.canCompact {
            acceptedAppendsSinceCompaction += 1
        }
        if losslessStorage != nil {
            try append(canonicalSnapshot)
            cache = updated
        } else if jsonlDecodeDiagnostics.canCompact &&
            (updated.count > retentionPolicy.maximumRecordCount ||
             acceptedAppendsSinceCompaction >= retentionPolicy.compactionInterval) {
            let compacted = retentionPolicy.compact(updated, referenceDate: canonicalSnapshot.capturedAt)
            if compacted.count < updated.count {
                try backupOriginalHistoryIfNeeded()
            }
            try CompactionArchive(sourceURL: fileURL).store(removedFrom: updated, keeping: compacted, capturedAt: \.capturedAt)
            try rewrite(compacted)
            cache = compacted
            acceptedAppendsSinceCompaction = 0
        } else {
            try append(canonicalSnapshot)
            cache = updated
        }
        return true
    }

    /// An unreadable block must not also lose the readings taken after it.
    /// `cache` stays nil, so every later read keeps retrying the full history.
    private func appendWithoutLoading(_ snapshot: DriveSnapshot, tail: [DriveSnapshot],
                                      to storage: LosslessHistoryStorage<DriveSnapshot>) throws -> Bool {
        var canonical = snapshot
        canonical.rawJSON = ""
        if let existingID = uniqueCapacitySeriesID(for: snapshot, in: tail) {
            canonical.deviceID = existingID
        }
        let isDuplicate = tail.contains {
            $0.deviceID == canonical.deviceID && abs(canonical.capturedAt.timeIntervalSince($0.capturedAt)) < 60
        }
        guard !isDuplicate else { return false }
        try storage.appendWithoutLoading(canonical)
        return true
    }

    private func ensureLoaded() throws -> [DriveSnapshot] {
        if let cache { return cache }
        if var storage = losslessStorage {
            let loaded = try storage.load().sorted { $0.capturedAt < $1.capturedAt }
            let migrated = canonicalized(loaded)
            if loaded != migrated { try storage.replace(migrated) }
            jsonlDecodeDiagnostics = storage.diagnostics
            losslessStorage = storage
            let shared = migrated.map(sharingStrings)
            cache = shared
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
        var parsed = [DriveSnapshot]()
        var failedLineNumbers = [Int]()
        var rejectedRows = [(lineNumber: Int, bytes: Data)]()
        var failedLineCount = 0
        for (offset, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            guard !line.isEmpty else { continue }
            do {
                parsed.append(try decoder.decode(DriveSnapshot.self, from: Data(line)))
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
        let migrated = canonicalized(parsed)
        if JSONLQuarantine.isMostlyUnreadable(failedRows: failedLineCount, readableRows: parsed.count) {
            let asideURL = try JSONLQuarantine.setAside(sourceURL: fileURL)
            try rewrite(migrated)
            jsonlDecodeDiagnostics = JSONLDecodeDiagnostics(
                failedLineCount: failedLineCount,
                sampleLineNumbers: failedLineNumbers,
                quarantineFileName: asideURL.lastPathComponent,
                sourceRepaired: true
            )
            cache = migrated
            acceptedAppendsSinceCompaction = 0
            return migrated
        }
        let compacted = retentionPolicy.compact(migrated)
        if jsonlDecodeDiagnostics.hasFailures {
            // Preserve exact malformed row bytes before rewriting the source.
            // Any failure here propagates so callers cannot append indefinitely
            // to a damaged file or bypass the retention limit.
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
            try CompactionArchive(sourceURL: fileURL).store(removedFrom: migrated, keeping: compacted, capturedAt: \.capturedAt)
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
        if compacted != parsed {
            if compacted.count < parsed.count {
                try backupOriginalHistoryIfNeeded()
            }
            try CompactionArchive(sourceURL: fileURL).store(removedFrom: migrated, keeping: compacted, capturedAt: \.capturedAt)
            try rewrite(compacted)
        }
        cache = compacted
        return compacted
    }

    /// Converts the path-bearing identifier used by older builds into the
    /// current serial/model/capacity key before any retention compaction.
    private func canonicalized(_ records: [DriveSnapshot]) -> [DriveSnapshot] {
        records.map { snapshot in
            guard DeviceIdentity.isLegacyPathID(snapshot.deviceID) else { return snapshot }
            var migrated = snapshot
            migrated.deviceID = DeviceIdentity.stableID(
                serialNumber: snapshot.serialNumber,
                model: snapshot.model,
                logicalCapacityBytes: snapshot.logicalCapacityBytes
            )
            return migrated
        }
    }

    /// A capacity-bearing ID can appear after an older model-only history was
    /// created. Merge it only when that model has one unambiguous model-only
    /// series; silently merging two identical-model SSDs would be worse than
    /// preserving the split.
    private func migrateUnqualifiedSeries(
        _ records: [DriveSnapshot],
        for snapshot: DriveSnapshot
    ) -> [DriveSnapshot] {
        guard
            snapshot.serialNumber == nil,
            snapshot.logicalCapacityBytes ?? 0 > 0,
            let model = snapshot.model,
            !model.isEmpty
        else { return records }

        let unqualifiedID = DeviceIdentity.stableID(
            serialNumber: nil,
            model: model,
            logicalCapacityBytes: nil
        )
        let unqualifiedSeries = records.filter {
            $0.deviceID == unqualifiedID && $0.serialNumber == nil
        }
        guard !unqualifiedSeries.isEmpty else { return records }

        let qualifiedID = DeviceIdentity.stableID(
            serialNumber: nil,
            model: model,
            logicalCapacityBytes: snapshot.logicalCapacityBytes
        )
        return records.map { record in
            guard record.deviceID == unqualifiedID else { return record }
            var migrated = record
            migrated.deviceID = qualifiedID
            return migrated
        }
    }

    /// Reuse a previously observed capacity-bearing series when a later
    /// smartctl response omits capacity. The match must be unique.
    private func uniqueCapacitySeriesID(
        for snapshot: DriveSnapshot,
        in records: [DriveSnapshot]
    ) -> String? {
        guard snapshot.serialNumber == nil, snapshot.logicalCapacityBytes == nil,
              let model = snapshot.model, !model.isEmpty else { return nil }

        let modelPrefix = DeviceIdentity.stableID(
            serialNumber: nil,
            model: model,
            logicalCapacityBytes: nil
        )
        let ids = Set(records.compactMap { record -> String? in
            guard record.serialNumber == nil,
                  record.model == model,
                  record.deviceID.hasPrefix("\(modelPrefix)|capacity:")
            else { return nil }
            return record.deviceID
        })
        return ids.count == 1 ? ids.first : nil
    }

    private func append(_ snapshot: DriveSnapshot) throws {
        if losslessStorage != nil {
            try losslessStorage!.append(snapshot)
            return
        }
        let lineData = try encode(snapshot) + Data([0x0A])
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

    private func sharingStrings(_ snapshot: DriveSnapshot) -> DriveSnapshot {
        var copy = snapshot
        copy.deviceID = strings.shared(snapshot.deviceID)
        copy.devicePath = strings.shared(snapshot.devicePath)
        copy.model = strings.shared(snapshot.model)
        copy.serialNumber = strings.shared(snapshot.serialNumber)
        return copy
    }

    private func rewrite(_ records: [DriveSnapshot]) throws {
        if losslessStorage != nil {
            try losslessStorage!.replace(records)
            return
        }
        try ensureDirectoryExists()
        var data = Data()
        for record in records {
            data.append(try encode(record))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func encode(_ snapshot: DriveSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
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
}
