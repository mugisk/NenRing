import Foundation

/// Keeps every record that history compaction removes, so thinning the live
/// files never loses a measurement.
///
/// Removed records are appended to `archive/<name>-<yyyy-MM>.jsonl` next to
/// the live file and flushed to disk before the live file is rewritten. Once a
/// month is over, its file is compressed to `.jsonl.lzfse`; the compressed
/// copy is decoded and compared with the original before the plain file is
/// removed. The archive is for safekeeping only and is never read by the app.
struct CompactionArchive: Sendable {
    let directoryURL: URL
    let name: String

    init(sourceURL: URL) {
        self.directoryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("archive", isDirectory: true)
        self.name = sourceURL.deletingPathExtension().lastPathComponent
    }

    /// Archives the records of `original` that are not in `kept`. Throws if
    /// they cannot be written, so the caller keeps its live file unchanged.
    func store<Record: Encodable & Identifiable>(
        removedFrom original: [Record],
        keeping kept: [Record],
        capturedAt: (Record) -> Date,
        now: Date = Date()
    ) throws where Record.ID == UUID {
        let keptIDs = Set(kept.map(\.id))
        let removed = original.filter { !keptIDs.contains($0.id) }
        guard !removed.isEmpty else { return }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let byMonth = Dictionary(grouping: removed) { Self.month(of: capturedAt($0)) }
        for (month, records) in byMonth.sorted(by: { $0.key < $1.key }) {
            var data = Data()
            for record in records.sorted(by: { capturedAt($0) < capturedAt($1) }) {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try append(data, to: plainURL(month: month))
        }
        compressCompletedMonths(now: now)
    }

    /// Compresses the plain files of months before `now`. Failures leave the
    /// plain file in place; nothing is deleted until the compressed copy has
    /// been read back and matches.
    func compressCompletedMonths(now: Date = Date()) {
        let currentMonth = Self.month(of: now)
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        for fileName in names where fileName.hasPrefix("\(name)-") && fileName.hasSuffix(".jsonl") {
            let month = String(fileName.dropFirst(name.count + 1).dropLast(".jsonl".count))
            guard month.count == 7, month < currentMonth else { continue }
            let plainURL = directoryURL.appendingPathComponent(fileName)
            do {
                let original = try Data(contentsOf: plainURL)
                let compressed = try (original as NSData).compressed(using: .lzfse) as Data
                var targetURL = directoryURL.appendingPathComponent("\(name)-\(month).jsonl.lzfse")
                if fileManager.fileExists(atPath: targetURL.path) {
                    // Records that arrived after the month was compressed.
                    let suffix = Int(now.timeIntervalSince1970)
                    targetURL = directoryURL.appendingPathComponent("\(name)-\(month)-\(suffix).jsonl.lzfse")
                }
                try compressed.write(to: targetURL, options: .withoutOverwriting)
                let readBack = try Data(contentsOf: targetURL)
                let decoded = try (readBack as NSData).decompressed(using: .lzfse) as Data
                guard decoded == original else {
                    try? fileManager.removeItem(at: targetURL)
                    continue
                }
                try fileManager.removeItem(at: plainURL)
            } catch {
                continue
            }
        }
    }

    func plainURL(month: String) -> URL {
        directoryURL.appendingPathComponent("\(name)-\(month).jsonl")
    }

    static func month(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func append(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            // A previous write may have been cut short; start on a new line.
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            try reader.seek(toOffset: endOffset - 1)
            if try reader.read(upToCount: 1) != Data([0x0A]) {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
