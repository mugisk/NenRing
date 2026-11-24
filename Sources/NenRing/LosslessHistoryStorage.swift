import CryptoKit
import Foundation

/// Self-contained blocks: common fields are stored once, while every ID,
/// timestamp and changing value remains present. No delta depends on another
/// block, and numbers never pass through a floating-point-only JSON parser.
enum LosslessHistoryBlock {
    static let recordLimit = 256

    private struct Block: Codable {
        let nenringHistoryBlock: Int
        let shared: [String: Value]
        let observations: [[String: Value]]
    }
    private struct Marker: Decodable { let nenringHistoryBlock: Int? }

    private indirect enum Value: Codable, Equatable {
        case null, bool(Bool), integer(Int64), unsigned(UInt64), real(Double)
        case string(String), array([Value]), object([String: Value])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int64.self) { self = .integer(v) }
            else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
            else if let v = try? c.decode(Double.self) { self = .real(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([Value].self) { self = .array(v) }
            else { self = .object(try c.decode([String: Value].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .integer(let v): try c.encode(v)
            case .unsigned(let v): try c.encode(v)
            case .real(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    static func encode<Record: Encodable>(_ records: [Record]) throws -> Data {
        guard !records.isEmpty, records.count <= recordLimit else { throw StorageError.invalidBlock }
        // deferredToDate preserves the full Date value. Legacy JSONL uses
        // ISO8601; the versioned envelope distinguishes the two encodings.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let objects = try records.map { record in
            try autoreleasepool {
                try decoder.decode([String: Value].self, from: encoder.encode(record))
            }
        }
        var shared = objects[0]
        // Identity and time are always explicit for each observation.
        shared.removeValue(forKey: "id")
        shared.removeValue(forKey: "capturedAt")
        for object in objects.dropFirst() {
            shared = shared.filter { object[$0.key] == $0.value }
        }
        let observations = objects.map { object in object.filter { shared[$0.key] == nil } }
        return try encoder.encode(Block(nenringHistoryBlock: 1, shared: shared, observations: observations))
    }

    static func decode<Record: Decodable>(_ data: Data, as: Record.Type) throws -> [Record] {
        try autoreleasepool {
            let decoder = JSONDecoder()
            guard try decoder.decode(Marker.self, from: data).nenringHistoryBlock != nil else {
                decoder.dateDecodingStrategy = .iso8601
                return [try decoder.decode(Record.self, from: data)]
            }
            let block = try decoder.decode(Block.self, from: data)
            guard block.nenringHistoryBlock == 1, !block.observations.isEmpty,
                  block.observations.count <= recordLimit,
                  block.shared["id"] == nil, block.shared["capturedAt"] == nil else {
                throw StorageError.invalidBlock
            }
            let encoder = JSONEncoder()
            return try block.observations.map { observation in
                try autoreleasepool {
                    guard !observation.keys.contains(where: { block.shared[$0] != nil }) else {
                        throw StorageError.invalidBlock
                    }
                    return try decoder.decode(Record.self, from: encoder.encode(block.shared.merging(observation) { _, b in b }))
                }
            }
        }
    }

    enum StorageError: LocalizedError {
        case invalidBlock, invalidManifest, corruptSegment(String)

        var errorDescription: String? {
            switch self {
            case .invalidBlock: return "Unsupported or invalid lossless history block. The original evidence was retained."
            case .invalidManifest: return "Unsupported or invalid lossless history manifest. The original evidence was retained."
            case .corruptSegment(let name): return "History integrity check failed: \(name). The original evidence was retained."
            }
        }
    }
}

/// The JSONL tail is small; sealed 256-observation blocks are immutable,
/// compressed and independently checked. Appending never rewrites the full
/// history. Callers continue to receive the original observation sequence.
struct LosslessHistoryStorage<Record: Codable & Equatable & Identifiable> where Record.ID == UUID {
    private struct Manifest: Codable {
        let version: Int
        let recordType: String
        var segments: [String]
    }

    let fileURL: URL
    private var tailCount = 0
    private var manifest: Manifest?
    private(set) var diagnostics = JSONLDecodeDiagnostics.clean
    var directoryURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("lossless")
    }
    private var manifestURL: URL { directoryURL.appendingPathComponent("manifest.json") }

    init(fileURL: URL) { self.fileURL = fileURL }

    mutating func load() throws -> [Record] {
        let fm = FileManager.default
        var records: [Record] = []
        var importedArchive = false
        if fm.fileExists(atPath: manifestURL.path) {
            let saved = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard saved.version == 1, saved.recordType == String(describing: Record.self),
                  Set(saved.segments).count == saved.segments.count else {
                throw LosslessHistoryBlock.StorageError.invalidManifest
            }
            for name in saved.segments {
                guard name.count == 75, name.hasSuffix(".json.lzfse"),
                      name.prefix(64).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                    throw LosslessHistoryBlock.StorageError.invalidManifest
                }
                // Each block's file and decompressed bytes are released
                // here rather than whenever the caller's pool drains.
                records += try autoreleasepool { () throws -> [Record] in
                    let compressed = try Data(contentsOf: directoryURL.appendingPathComponent(name))
                    let plain = try (compressed as NSData).decompressed(using: .lzfse) as Data
                    guard Self.digest(plain) == String(name.prefix(64)) else {
                        throw LosslessHistoryBlock.StorageError.corruptSegment(name)
                    }
                    return try LosslessHistoryBlock.decode(plain, as: Record.self)
                }
            }
            manifest = saved
        } else {
            // Old builds moved removed observations here. Read them once at
            // adoption; the originals are not modified or deleted.
            let archive = CompactionArchive(sourceURL: fileURL)
            if fm.fileExists(atPath: archive.directoryURL.path) {
                for name in try fm.contentsOfDirectory(atPath: archive.directoryURL.path).sorted()
                    where name.hasPrefix(archive.name + "-") &&
                        (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.lzfse")) {
                    let archiveRows = try autoreleasepool { () throws -> (records: [Record], rejected: [(lineNumber: Int, bytes: Data)]) in
                        var data = try Data(contentsOf: archive.directoryURL.appendingPathComponent(name))
                        if name.hasSuffix(".lzfse") { data = try (data as NSData).decompressed(using: .lzfse) as Data }
                        return Self.readLines(data)
                    }
                    // Stop migration if evidence is damaged. Do not mark an
                    // incomplete restoration as successfully imported.
                    guard archiveRows.rejected.isEmpty else {
                        throw LosslessHistoryBlock.StorageError.corruptSegment(name)
                    }
                    records += archiveRows.records
                    importedArchive = true
                }
            }
        }

        let data = fm.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : Data()
        if manifest == nil, !data.isEmpty {
            let backup = fileURL.deletingPathExtension().appendingPathExtension("pre-lossless-v1.jsonl")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: fileURL, to: backup) }
        }
        let decoded = Self.readLines(data)
        tailCount = decoded.records.count
        diagnostics = JSONLDecodeDiagnostics(failedLineCount: decoded.rejected.count,
            sampleLineNumbers: Array(decoded.rejected.prefix(5).map(\.lineNumber)))
        if !decoded.rejected.isEmpty { try repairTail(data, decoded) }
        // A crash after publishing a segment but before clearing the tail
        // leaves duplicates. The tail wins (also during identity migration).
        records += decoded.records
        let unique = Self.unique(records)
        if importedArchive { try replace(unique) }
        return unique
    }

    mutating func append(_ record: Record) throws {
        // Seal BEFORE appending: a maintenance failure cannot make a failed
        // append secretly accept the new observation.
        if tailCount >= LosslessHistoryBlock.recordLimit {
            let data = try Data(contentsOf: fileURL)
            let tail = Self.readLines(data)
            // A line torn by an earlier failed append is set aside as at
            // launch; refusing to seal would refuse every later observation.
            if !tail.rejected.isEmpty { try repairTail(data, tail) }
            try seal(tail.records)
            try writeTail([])
        }
        try writeTailLine(record)
        tailCount += 1
    }

    /// The tail as it stands, or nil when it has rows awaiting repair or can't
    /// be read. Nothing is repaired or moved, so this is safe while the sealed
    /// history can't be read. A damaged tail stays blocked until it is repaired.
    func cleanTail() -> [Record]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let tail = Self.readLines(data)
        return tail.rejected.isEmpty ? tail.records : nil
    }

    /// Keeps a new observation while `load()` fails. Only the tail changes:
    /// the manifest and segments stay as evidence, and the tail is sealed by
    /// the first append after a load succeeds. It is not counted here, because
    /// sealing without the loaded manifest would drop the existing segments.
    func appendWithoutLoading(_ record: Record) throws {
        try writeTailLine(record)
    }

    private func writeTailLine(_ record: Record) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try LosslessHistoryBlock.encode([record])
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        }
    }

    /// Used for a legacy identity migration or repair, never for routine
    /// appends. The full tail is published first so an interrupted manifest
    /// switch cannot lose observations. Existing segments stay recoverable.
    mutating func replace(_ records: [Record]) throws {
        try writeTail(records)
        let previous = manifest
        manifest = Manifest(version: 1, recordType: String(describing: Record.self), segments: [])
        do { try seal(records) }
        catch { manifest = previous; throw error }
        try writeTail([])
    }

    private mutating func seal(_ records: [Record]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var next = manifest ?? Manifest(version: 1, recordType: String(describing: Record.self), segments: [])
        var known = Set(next.segments)
        for offset in stride(from: 0, to: records.count, by: LosslessHistoryBlock.recordLimit) {
            let batch = Array(records[offset..<min(records.count, offset + LosslessHistoryBlock.recordLimit)])
            let plain = try LosslessHistoryBlock.encode(batch)
            let restored = try LosslessHistoryBlock.decode(plain, as: Record.self)
            guard restored == batch else { throw LosslessHistoryBlock.StorageError.invalidBlock }
            let name = Self.digest(plain) + ".json.lzfse"
            let url = directoryURL.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) {
                let compressed = try (plain as NSData).compressed(using: .lzfse) as Data
                try compressed.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let readBack = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
            guard readBack == plain else { throw LosslessHistoryBlock.StorageError.corruptSegment(name) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
            if known.insert(name).inserted { next.segments.append(name) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: manifestURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        let handle = try FileHandle(forWritingTo: manifestURL)
        try handle.synchronize()
        try handle.close()
        manifest = next
    }

    /// Moves unreadable tail lines to a quarantine file, keeping their bytes,
    /// and rewrites the tail with the readable records.
    private mutating func repairTail(_ data: Data,
                                     _ decoded: (records: [Record], rejected: [(lineNumber: Int, bytes: Data)])) throws {
        let destination: URL
        if JSONLQuarantine.isMostlyUnreadable(failedRows: decoded.rejected.count, readableRows: decoded.records.count) {
            destination = try JSONLQuarantine.setAside(sourceURL: fileURL)
        } else {
            destination = try JSONLQuarantine.archive(rows: decoded.rejected, sourceData: data, sourceURL: fileURL)
        }
        try writeTail(decoded.records)
        diagnostics = JSONLDecodeDiagnostics(failedLineCount: decoded.rejected.count,
            sampleLineNumbers: Array(decoded.rejected.prefix(5).map(\.lineNumber)),
            quarantineFileName: destination.lastPathComponent, sourceRepaired: true)
    }

    private mutating func writeTail(_ records: [Record]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for offset in stride(from: 0, to: records.count, by: LosslessHistoryBlock.recordLimit) {
            data.append(try LosslessHistoryBlock.encode(Array(records[offset..<min(records.count, offset + LosslessHistoryBlock.recordLimit)])))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.synchronize()
        try handle.close()
        tailCount = records.count
    }

    private static func readLines(_ data: Data) -> (records: [Record], rejected: [(lineNumber: Int, bytes: Data)]) {
        var records: [Record] = []
        var rejected: [(lineNumber: Int, bytes: Data)] = []
        for (offset, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            do { records += try LosslessHistoryBlock.decode(Data(line), as: Record.self) }
            catch { rejected.append((offset + 1, Data(line))) }
        }
        return (records, rejected)
    }

    private static func unique(_ records: [Record]) -> [Record] {
        var positions: [UUID: Int] = [:]
        var result: [Record] = []
        for record in records {
            if let position = positions[record.id] { result[position] = record }
            else { positions[record.id] = result.count; result.append(record) }
        }
        return result
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
