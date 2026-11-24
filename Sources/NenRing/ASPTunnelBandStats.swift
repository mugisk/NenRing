import Foundation

/// Fixed CoreDebugTunnel commands observed in the macOS 25G83 helper.
/// Only the 0x106 fallback band-statistics path is decoded here. The other
/// accepted probe opcodes remain raw artifacts until their layouts are known.
enum ASPTunnelOpcode: UInt32, Codable, Equatable, Sendable {
    case bandStats = 0x12b
    case aspExport = 0x129
    case aspExportFallback = 0x106

    var title: String {
        switch self {
        case .bandStats: return "band統計"
        case .aspExport: return "ASP export"
        case .aspExportFallback: return "band統計 fallback"
        }
    }
}

struct ASPTunnelMeasurement: Codable, Equatable, Sendable {
    let build: String
    let controller: String
    let selector: UInt32
    let opcode: ASPTunnelOpcode
    let effectiveUserID: UInt32
    /// Time at which the tunnel read was performed, not the later parse/store
    /// time.
    let capturedAt: Date?
    let sizeQueryResultCode: UInt32
    let sizeQueryResponseBytes: Int
    let requestedBytes: Int
    let readResultCode: UInt32
    let responseBytes: Int
    let capacityBytes: Int
    let elapsedMilliseconds: Double
    let totalElapsedMilliseconds: Double
    let formatStatus: String

    var outcome: ASPDirectReadOutcome {
        guard sizeQueryResultCode == 0,
              readResultCode == 0,
              requestedBytes > 0,
              responseBytes > 0,
              responseBytes <= capacityBytes else { return .readFailed }
        return responseBytes < requestedBytes ? .partial : .success
    }

    /// The first failing IOKit result in the two-stage tunnel operation.
    /// Keep it separate from `outcome` so the UI can distinguish permission
    /// failures from a driver/device rejection.
    var failureResultCode: UInt32? {
        if sizeQueryResultCode != 0 {
            return sizeQueryResultCode
        }
        if readResultCode != 0 {
            return readResultCode
        }
        return nil
    }

    var failureResultTitle: String? {
        guard let code = failureResultCode else { return nil }
        switch code {
        case 0xe00002c1:
            return "not privileged"
        case 0xe00002c2:
            return "bad argument"
        case 0xe00002e9:
            return "device error"
        default:
            return String(format: "IOReturn 0x%08x", code)
        }
    }

    /// On the reviewed 25G83 machine, root authorization succeeds but the
    /// two opaque tunnel commands are rejected by AppleANS3 itself. This is
    /// intentionally not treated as a retryable permission failure.
    var isDeviceRejectedOpaqueTunnel: Bool {
        effectiveUserID == 0 &&
            (opcode == .aspExport || opcode == .bandStats) &&
            failureResultCode == 0xe00002e9
    }

    var isReviewedBandStatsTarget: Bool {
        build == "25G83" &&
            controller == "AppleANS3NVMeController" &&
            selector == 9 &&
            opcode == .aspExportFallback
    }
}

enum ASPTunnelMetadataParserError: LocalizedError, Equatable, Sendable {
    case malformedLine(String)
    case missingKey(String)
    case invalidValue(key: String, value: String)
    case unsupportedOpcode(UInt32)

    var errorDescription: String? {
        switch self {
        case let .malformedLine(line):
            return "ASP tunnel metadataの行を解釈できません: \(line)"
        case let .missingKey(key):
            return "ASP tunnel metadataに必須項目がありません: \(key)"
        case let .invalidValue(key, value):
            return "ASP tunnel metadataの値が不正です: \(key)=\(value)"
        case let .unsupportedOpcode(opcode):
            return String(format: "ASP tunnel opcode 0x%03xは未対応です", opcode)
        }
    }
}

struct ASPTunnelMetadataParser: Sendable {
    func parse(text: String) throws -> ASPTunnelMeasurement {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let components = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw ASPTunnelMetadataParserError.malformedLine(String(line))
            }
            fields[String(components[0])] = String(components[1])
        }

        func required(_ key: String) throws -> String {
            guard let value = fields[key], !value.isEmpty else {
                throw ASPTunnelMetadataParserError.missingKey(key)
            }
            return value
        }

        func unsigned(_ key: String) throws -> UInt64 {
            let value = try required(key)
            let parsed: UInt64?
            if value.hasPrefix("0x") || value.hasPrefix("0X") {
                parsed = UInt64(value.dropFirst(2), radix: 16)
            } else {
                parsed = UInt64(value)
            }
            guard let parsed else {
                throw ASPTunnelMetadataParserError.invalidValue(key: key, value: value)
            }
            return parsed
        }

        func uint32(_ key: String) throws -> UInt32 {
            let value = try unsigned(key)
            guard value <= UInt64(UInt32.max) else {
                let rawValue = try required(key)
                throw ASPTunnelMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return UInt32(value)
        }

        func nonNegativeInteger(_ key: String) throws -> Int {
            let value = try unsigned(key)
            guard value <= UInt64(Int.max) else {
                let rawValue = try required(key)
                throw ASPTunnelMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return Int(value)
        }

        func decimal(_ key: String) throws -> Double {
            let value = try required(key)
            guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
                throw ASPTunnelMetadataParserError.invalidValue(key: key, value: value)
            }
            return parsed
        }

        func optionalEpoch(_ key: String) throws -> Date? {
            guard let value = fields[key], !value.isEmpty else { return nil }
            guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
                throw ASPTunnelMetadataParserError.invalidValue(key: key, value: value)
            }
            return seconds == 0 ? nil : Date(timeIntervalSince1970: seconds)
        }

        let rawOpcode = try uint32("opcode")
        guard let opcode = ASPTunnelOpcode(rawValue: rawOpcode) else {
            throw ASPTunnelMetadataParserError.unsupportedOpcode(rawOpcode)
        }

        return ASPTunnelMeasurement(
            build: try required("build"),
            controller: try required("controller"),
            selector: try uint32("selector"),
            opcode: opcode,
            effectiveUserID: try uint32("euid"),
            capturedAt: try optionalEpoch("captured_at_epoch"),
            sizeQueryResultCode: try uint32("size_query_result"),
            sizeQueryResponseBytes: try nonNegativeInteger("size_query_response_bytes"),
            requestedBytes: try nonNegativeInteger("requested_bytes"),
            readResultCode: try uint32("read_result"),
            responseBytes: try nonNegativeInteger("response_bytes"),
            capacityBytes: try nonNegativeInteger("capacity_bytes"),
            elapsedMilliseconds: try decimal("elapsed_ms"),
            totalElapsedMilliseconds: try decimal("total_elapsed_ms"),
            formatStatus: try required("format_status")
        )
    }

    func parse(fileURL: URL) throws -> ASPTunnelMeasurement {
        try parse(text: String(contentsOf: fileURL, encoding: .utf8))
    }
}

struct ASPBandStatisticsRecord: Equatable, Sendable {
    let index: Int
    let fields: [UInt32]
    let byteOffset: Int

    /// The helper trace identifies the second u32 in each 32-byte record as
    /// the erase-cycle field. Partition and EoL semantics are still separate.
    var eraseCycleField: UInt32 { fields[1] }
}

struct ASPBandEraseCycleSummary: Equatable, Sendable {
    let count: Int
    let minimum: UInt32
    let maximum: UInt32
    let average: Double
    let valueCounts: [UInt32: Int]
}

enum ASPBandStatsParserError: LocalizedError, Equatable, Sendable {
    case unsupportedTarget
    case readFailed(resultCode: UInt32)
    case unsupportedOpcode(ASPTunnelOpcode)
    case emptyPayload
    case invalidHeaderSize(actualBytes: Int)
    case invalidPayloadAlignment(actualBytes: Int)
    case invalidBandCount(UInt32)
    case invalidPartitionCount(UInt32)
    case tooManyBands(maximum: Int)
    case truncated(requiredBytes: Int, actualBytes: Int)
    case responseSizeMismatch(expectedBytes: Int, actualBytes: Int)
    case responseExceedsCapacity(responseBytes: Int, capacityBytes: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            return "ASP band statsの対象が確認済みの25G83 / AppleANS3 / selector 9ではありません"
        case let .readFailed(resultCode):
            return String(format: "ASP band stats readが失敗しました（result=0x%08x）", resultCode)
        case let .unsupportedOpcode(opcode):
            return String(format: "ASP tunnel opcode 0x%03xはband stats Parserの対象外です", opcode.rawValue)
        case .emptyPayload:
            return "ASP band stats payloadが空です"
        case let .invalidHeaderSize(actualBytes):
            return "ASP band stats headerが短すぎます（必要32 bytes / 実際 \(actualBytes) bytes）"
        case let .invalidPayloadAlignment(actualBytes):
            return "ASP band stats payloadが4 bytes境界ではありません（\(actualBytes) bytes）"
        case let .invalidBandCount(count):
            return "ASP band statsのband数が不正です（\(count)）"
        case let .invalidPartitionCount(count):
            return "ASP band statsのpartition数が不正です（\(count)）"
        case let .tooManyBands(maximum):
            return "ASP band statsのband数が上限を超えました（上限 \(maximum)）"
        case let .truncated(requiredBytes, actualBytes):
            return "ASP band statsが途中で切れています（必要 \(requiredBytes) bytes / 実際 \(actualBytes) bytes）"
        case let .responseSizeMismatch(expectedBytes, actualBytes):
            return "ASP band stats response sizeがmetadataと一致しません（期待 \(expectedBytes) / 実際 \(actualBytes)）"
        case let .responseExceedsCapacity(responseBytes, capacityBytes):
            return "ASP band stats response sizeがcapacityを超えています（response \(responseBytes) / capacity \(capacityBytes)）"
        }
    }
}

struct ASPBandStatsParseResult: Equatable, Sendable {
    let measurement: ASPTunnelMeasurement
    let headerWords: [UInt32]
    let bandCount: Int
    let partitionCount: Int
    let records: [ASPBandStatisticsRecord]
    let usedBytes: Int
    let trailingBytes: Int
    let parsedAt: Date
    let snapshot: ASPToolDiagnosticsSnapshot?
    let warnings: [String]

    var eraseCycleSummary: ASPBandEraseCycleSummary? {
        guard !records.isEmpty else { return nil }
        let values = records.map(\.eraseCycleField)
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        let total = values.reduce(0.0) { $0 + Double($1) }
        var counts: [UInt32: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return ASPBandEraseCycleSummary(
            count: values.count,
            minimum: minimum,
            maximum: maximum,
            average: total / Double(values.count),
            valueCounts: counts
        )
    }
}

/// Structural parser for the reviewed 0x106 response:
///
///   8 x uint32 header (32 bytes)
///   numBands x (8 x uint32 record) (32 bytes per record)
///   optional page-aligned trailing bytes
///
/// Only the header's first two words and each record's second word are used.
/// The rest of each record is retained verbatim and no record is classified as
/// TLC, pSLC, or EoL by this parser.
struct ASPBandStatsParser: Sendable {
    static let headerBytes = 32
    static let recordBytes = 32
    static let recordWordCount = 8
    static let maximumBandCount = 100_000

    func parse(
        data: Data,
        measurement: ASPTunnelMeasurement,
        deviceID: String? = nil,
        sourceName: String = "tunnel-0x106.bin",
        parsedAt: Date = Date()
    ) throws -> ASPBandStatsParseResult {
        guard measurement.isReviewedBandStatsTarget else {
            throw ASPBandStatsParserError.unsupportedTarget
        }
        guard measurement.opcode == .aspExportFallback else {
            throw ASPBandStatsParserError.unsupportedOpcode(measurement.opcode)
        }
        guard measurement.sizeQueryResultCode == 0,
              measurement.readResultCode == 0,
              measurement.responseBytes > 0 else {
            throw ASPBandStatsParserError.readFailed(resultCode: measurement.readResultCode)
        }
        guard measurement.responseBytes <= measurement.capacityBytes else {
            throw ASPBandStatsParserError.responseExceedsCapacity(
                responseBytes: measurement.responseBytes,
                capacityBytes: measurement.capacityBytes
            )
        }
        guard data.count == measurement.responseBytes else {
            throw ASPBandStatsParserError.responseSizeMismatch(
                expectedBytes: measurement.responseBytes,
                actualBytes: data.count
            )
        }
        guard !data.isEmpty else { throw ASPBandStatsParserError.emptyPayload }
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw ASPBandStatsParserError.invalidPayloadAlignment(actualBytes: data.count)
        }
        guard data.count >= Self.headerBytes else {
            throw ASPBandStatsParserError.invalidHeaderSize(actualBytes: data.count)
        }

        let headerWords = try readWords(data: data, offset: 0, count: Self.recordWordCount)
        let rawBandCount = headerWords[0]
        let rawPartitionCount = headerWords[1]
        guard rawBandCount > 0 else {
            throw ASPBandStatsParserError.invalidBandCount(rawBandCount)
        }
        guard rawPartitionCount > 0 else {
            throw ASPBandStatsParserError.invalidPartitionCount(rawPartitionCount)
        }
        guard rawBandCount <= UInt32(Self.maximumBandCount) else {
            throw ASPBandStatsParserError.tooManyBands(maximum: Self.maximumBandCount)
        }

        let bandCount = Int(rawBandCount)
        let requiredRecordBytes = bandCount * Self.recordBytes
        let usedBytes = Self.headerBytes + requiredRecordBytes
        guard usedBytes <= data.count else {
            throw ASPBandStatsParserError.truncated(
                requiredBytes: usedBytes,
                actualBytes: data.count
            )
        }

        var records: [ASPBandStatisticsRecord] = []
        records.reserveCapacity(bandCount)
        for index in 0..<bandCount {
            let byteOffset = Self.headerBytes + index * Self.recordBytes
            let fields = try readWords(data: data, offset: byteOffset, count: Self.recordWordCount)
            records.append(ASPBandStatisticsRecord(index: index, fields: fields, byteOffset: byteOffset))
        }

        let trailingBytes = data.count - usedBytes
        var warnings = [
            "0x106のheader、band数、record境界を検証しました",
            "各recordの第2語をerase-cycleフィールド候補として保持しました",
            "TLC / pSLC / その他の帯域分類、EoL値、partition対応は未確認です",
            "未確認のrecord末尾とpage paddingは有効なrecordとして扱っていません"
        ]
        if trailingBytes > 0 {
            warnings.append("payload末尾に\(trailingBytes) bytesの未解析領域があります")
        }
        if measurement.capturedAt == nil {
            warnings.append("read時刻がないため、parse時刻を取得時刻として扱っていません")
        }

        let snapshot: ASPToolDiagnosticsSnapshot? = measurement.capturedAt.map { capturedAt in
            ASPToolDiagnosticsSnapshot(
                capturedAt: capturedAt,
                captureQuality: .explicit,
                deviceID: deviceID,
                sourceName: sourceName,
                sourceArtifact: .directBandStats,
                extractionVersion: 1,
                observationBlockCount: bandCount,
                bandCount: UInt64(bandCount),
                parseWarnings: warnings
            )
        }

        return ASPBandStatsParseResult(
            measurement: measurement,
            headerWords: headerWords,
            bandCount: bandCount,
            partitionCount: Int(rawPartitionCount),
            records: records,
            usedBytes: usedBytes,
            trailingBytes: trailingBytes,
            parsedAt: parsedAt,
            snapshot: snapshot,
            warnings: warnings
        )
    }

    private func readWords(data: Data, offset: Int, count: Int) throws -> [UInt32] {
        let byteCount = count * MemoryLayout<UInt32>.size
        guard offset >= 0, offset <= data.count, byteCount <= data.count - offset else {
            throw ASPBandStatsParserError.truncated(
                requiredBytes: offset + byteCount,
                actualBytes: data.count
            )
        }
        return (0..<count).map { index in
            let base = offset + index * MemoryLayout<UInt32>.size
            return data.withUnsafeBytes { rawBuffer in
                let pointer = rawBuffer.baseAddress!.advanced(by: base).assumingMemoryBound(to: UInt8.self)
                var value: UInt32 = 0
                for byteIndex in 0..<MemoryLayout<UInt32>.size {
                    value |= UInt32(pointer[byteIndex]) << UInt32(byteIndex * 8)
                }
                return value
            }
        }
    }
}

enum ASPBandStatsArtifactCollectorError: LocalizedError, Equatable, Sendable {
    case unsupportedTarget
    case missingPayload(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            return "ASP band stats artifactが確認済みの25G83 / AppleANS3 / selector 9 / 0x106ではありません"
        case let .missingPayload(url):
            return "ASP band stats payloadがありません: \(url.path)"
        }
    }
}

/// Reads a previously-created 0x106 artifact. It never invokes sysdiagnose,
/// sudo, or the private IOKit method.
struct ASPBandStatsArtifactCollector: Sendable {
    let metadataParser: ASPTunnelMetadataParser
    let parser: ASPBandStatsParser

    init(
        metadataParser: ASPTunnelMetadataParser = ASPTunnelMetadataParser(),
        parser: ASPBandStatsParser = ASPBandStatsParser()
    ) {
        self.metadataParser = metadataParser
        self.parser = parser
    }

    func collect(
        from directoryURL: URL,
        deviceID: String? = nil,
        parsedAt: Date = Date()
    ) throws -> ASPBandStatsParseResult {
        let metadataURL = directoryURL.appendingPathComponent("metadata.txt")
        let measurement = try metadataParser.parse(fileURL: metadataURL)
        guard measurement.isReviewedBandStatsTarget else {
            throw ASPBandStatsArtifactCollectorError.unsupportedTarget
        }
        let payloadURL = directoryURL.appendingPathComponent("tunnel-0x106.bin")
        guard FileManager.default.fileExists(atPath: payloadURL.path) else {
            throw ASPBandStatsArtifactCollectorError.missingPayload(payloadURL)
        }
        let data = try Data(contentsOf: payloadURL, options: [.mappedIfSafe])
        return try parser.parse(
            data: data,
            measurement: measurement,
            deviceID: deviceID,
            sourceName: payloadURL.lastPathComponent,
            parsedAt: parsedAt
        )
    }
}
