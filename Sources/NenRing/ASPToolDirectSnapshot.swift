import Foundation

/// Fixed command IDs observed in the macOS 25G83 sysdiagnose_helper path.
/// No other selector/opcode is accepted by the verification parser.
enum ASPDirectProbeOpcode: UInt32, Codable, CaseIterable, Equatable, Sendable {
    case timeSensitiveSnapshotPayload = 0x16
    case snapshotHeader = 0x91

    var title: String {
        switch self {
        case .timeSensitiveSnapshotPayload:
            return "時系列snapshot payload"
        case .snapshotHeader:
            return "snapshot header"
        }
    }
}

enum ASPDirectReadOutcome: String, Codable, Equatable, Sendable {
    case success
    case readFailed
    case partial

    var title: String {
        switch self {
        case .success: return "取得成功"
        case .readFailed: return "取得失敗"
        case .partial: return "部分取得"
        }
    }
}

/// The C probe writes this small sidecar next to an optional raw artifact.
/// It is intentionally independent of the application's normal history.
struct ASPDirectProbeMeasurement: Codable, Equatable, Sendable {
    /// The build of macOS that was running the probe.  Older sidecars only
    /// have the historical fixed label, so the contract fields remain
    /// optional for compatibility.
    let build: String
    let contractBuild: String?
    let probeVersion: Int?
    let controller: String
    let selector: UInt32
    let opcode: ASPDirectProbeOpcode
    let role: String
    let effectiveUserID: UInt32
    /// Wall-clock time recorded by the probe. This is distinct from the
    /// parser/store time and may be absent in older metadata fixtures.
    let capturedAt: Date?
    let sizeQueryResultCode: UInt32
    let sizeQueryResponseBytes: Int
    let requestedBytes: Int
    let snapshotReadAttempted: Bool
    let snapshotReadResultCode: UInt32
    let snapshotReadResponseBytes: Int
    let capacityBytes: Int
    let payloadBytes: Int
    let sizeQueryElapsedMilliseconds: Double
    let snapshotReadElapsedMilliseconds: Double
    let totalElapsedMilliseconds: Double
    let formatStatus: String

    var outcome: ASPDirectReadOutcome {
        guard snapshotReadAttempted, snapshotReadResultCode == 0 else { return .readFailed }
        guard requestedBytes > 0, payloadBytes > 0 else { return .readFailed }
        return payloadBytes < requestedBytes ? .partial : .success
    }

    /// The private interface is accepted when its reviewed contract and
    /// selector match, even when the running OS has moved to a later build.
    /// Core continuity analysis decides whether that later build can be
    /// bridged; the parser must not discard its raw evidence first.
    var isReviewedInterface: Bool {
        (contractBuild ?? (build == "25G83" ? "25G83" : nil)) == "25G83" &&
            Self.recognizedControllers.contains(controller) &&
            selector == 9
    }

    /// Classes the probe can report. Probe version 3 matches the common
    /// superclass and records the actual class; older artifacts always say
    /// AppleANS3NVMeController.
    static let recognizedControllers: Set<String> = Set(IORegistryService.controllerClasses)

    var runsOnReviewedBuild: Bool {
        guard let contractBuild else { return false }
        return build == contractBuild
    }

    /// Compatibility name retained for callers and old fixtures.
    var isSupportedTarget: Bool { isReviewedInterface }
}

enum ASPDirectProbeMetadataParserError: LocalizedError, Equatable, Sendable {
    case malformedLine(String)
    case missingKey(String)
    case invalidValue(key: String, value: String)
    case unsupportedOpcode(UInt32)

    var errorDescription: String? {
        switch self {
        case let .malformedLine(line):
            return "probe metadataの行を解釈できません: \(line)"
        case let .missingKey(key):
            return "probe metadataに必須項目がありません: \(key)"
        case let .invalidValue(key, value):
            return "probe metadataの値が不正です: \(key)=\(value)"
        case let .unsupportedOpcode(opcode):
            return String(format: "probe metadataのopcode 0x%02xは未確認です", opcode)
        }
    }
}

struct ASPDirectProbeMetadataParser: Sendable {
    func parse(text: String) throws -> ASPDirectProbeMeasurement {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let components = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw ASPDirectProbeMetadataParserError.malformedLine(String(line))
            }
            let key = String(components[0])
            let value = String(components[1])
            fields[key] = value
        }

        func required(_ key: String) throws -> String {
            guard let value = fields[key], !value.isEmpty else {
                throw ASPDirectProbeMetadataParserError.missingKey(key)
            }
            return value
        }

        func uint32(_ key: String) throws -> UInt32 {
            let value = try required(key)
            let parsed: UInt64?
            if value.hasPrefix("0x") || value.hasPrefix("0X") {
                parsed = UInt64(value.dropFirst(2), radix: 16)
            } else {
                parsed = UInt64(value)
            }
            guard let parsed, parsed <= UInt64(UInt32.max) else {
                throw ASPDirectProbeMetadataParserError.invalidValue(key: key, value: value)
            }
            return UInt32(parsed)
        }

        func integer(_ key: String) throws -> Int {
            let value = try required(key)
            guard let parsed = Int(value), parsed >= 0 else {
                throw ASPDirectProbeMetadataParserError.invalidValue(key: key, value: value)
            }
            return parsed
        }

        func decimal(_ key: String) throws -> Double {
            let value = try required(key)
            guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
                throw ASPDirectProbeMetadataParserError.invalidValue(key: key, value: value)
            }
            return parsed
        }

        func boolean(_ key: String) throws -> Bool {
            let value = try required(key)
            switch value {
            case "1", "true": return true
            case "0", "false": return false
            default:
                throw ASPDirectProbeMetadataParserError.invalidValue(key: key, value: value)
            }
        }

        func optionalEpoch(_ key: String) throws -> Date? {
            guard let rawValue = fields[key], !rawValue.isEmpty else { return nil }
            guard let seconds = Double(rawValue), seconds.isFinite, seconds >= 0 else {
                throw ASPDirectProbeMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return Date(timeIntervalSince1970: seconds)
        }

        func optionalInteger(_ key: String) throws -> Int? {
            guard let rawValue = fields[key], !rawValue.isEmpty else { return nil }
            guard let parsed = Int(rawValue), parsed >= 0 else {
                throw ASPDirectProbeMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return parsed
        }

        let rawOpcode = try uint32("opcode")
        guard let opcode = ASPDirectProbeOpcode(rawValue: rawOpcode) else {
            throw ASPDirectProbeMetadataParserError.unsupportedOpcode(rawOpcode)
        }

        return ASPDirectProbeMeasurement(
            build: try required("build"),
            contractBuild: fields["contractBuild"].flatMap { $0.isEmpty ? nil : $0 },
            probeVersion: try optionalInteger("probeVersion"),
            controller: try required("controller"),
            selector: try uint32("selector"),
            opcode: opcode,
            role: try required("role"),
            effectiveUserID: try uint32("euid"),
            capturedAt: try optionalEpoch("captured_at_epoch"),
            sizeQueryResultCode: try uint32("size_query_result"),
            sizeQueryResponseBytes: try integer("size_query_response_bytes"),
            requestedBytes: try integer("requested_bytes"),
            snapshotReadAttempted: try boolean("snapshot_read_attempted"),
            snapshotReadResultCode: try uint32("snapshot_read_result"),
            snapshotReadResponseBytes: try integer("snapshot_read_response_bytes"),
            capacityBytes: try integer("capacity_bytes"),
            payloadBytes: try integer("payload_bytes"),
            sizeQueryElapsedMilliseconds: try decimal("size_query_elapsed_ms"),
            snapshotReadElapsedMilliseconds: try decimal("snapshot_read_elapsed_ms"),
            totalElapsedMilliseconds: try decimal("total_elapsed_ms"),
            formatStatus: try required("format_status")
        )
    }

    func parse(fileURL: URL) throws -> ASPDirectProbeMeasurement {
        try parse(text: String(contentsOf: fileURL, encoding: .utf8))
    }
}

/// Evidence read from the 0x91 header. The field names intentionally retain
/// their cautious status: the helper bounds the first field and compares the
/// size field, but does not expose a public format specification.
struct ASPDirectBinaryHeaderEvidence: Equatable, Sendable {
    let helperRevisionField: UInt32
    let declaredSnapshotBytes: UInt32
    let referencedTableOffset: UInt32
    let headerBytes: Int
}

enum ASPDirectBinaryParseStatus: String, Codable, Equatable, Sendable {
    case headerBoundaryValidated
    case formatUnconfirmed

    var title: String {
        switch self {
        case .headerBoundaryValidated: return "ヘッダー境界を検証済み"
        case .formatUnconfirmed: return "形式未確認"
        }
    }
}

enum ASPDirectBinaryParserError: LocalizedError, Equatable, Sendable {
    case unsupportedOpcode
    case missingExpectedSize
    case truncated(requiredBytes: Int, actualBytes: Int)
    case partialRead(expectedBytes: Int, actualBytes: Int)
    case invalidPayloadSize(expectedBytes: Int, actualBytes: Int)
    case unknownRevision(UInt32)
    case invalidDeclaredSize(expectedBytes: Int, actualBytes: Int)
    case invalidOffset(offset: Int, dataSize: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedOpcode:
            return "ASP direct parserに未確認のopcodeが渡されました"
        case .missingExpectedSize:
            return "ASPバイナリの期待サイズが指定されていません"
        case let .truncated(requiredBytes, actualBytes):
            return "ASPバイナリが短すぎます（必要 \(requiredBytes) bytes / 実際 \(actualBytes) bytes）"
        case let .partialRead(expectedBytes, actualBytes):
            return "ASPバイナリが部分取得です（要求 \(expectedBytes) bytes / 実際 \(actualBytes) bytes）"
        case let .invalidPayloadSize(expectedBytes, actualBytes):
            return "ASP payloadのサイズが想定と一致しません（要求 \(expectedBytes) bytes / 実際 \(actualBytes) bytes）"
        case let .unknownRevision(revision):
            return "ASP headerのrevision \(revision) は未確認です"
        case let .invalidDeclaredSize(expectedBytes, actualBytes):
            return "ASP headerの宣言サイズが一致しません（宣言 \(expectedBytes) bytes / 実際 \(actualBytes) bytes）"
        case let .invalidOffset(offset, dataSize):
            return "ASP headerのoffset \(offset) がデータ範囲 \(dataSize) bytes外です"
        }
    }
}

struct ASPDirectBinaryParseResult: Equatable, Sendable {
    let opcode: ASPDirectProbeOpcode
    let status: ASPDirectBinaryParseStatus
    let headerEvidence: ASPDirectBinaryHeaderEvidence?
    /// Nil is intentional until the private payload record layout is proven.
    let normalizedSnapshot: ASPToolDiagnosticsSnapshot?
    let sourceRecordAt: Date?
    let warnings: [String]
}

/// Conservative parser for the private binary returned by the reviewed path.
/// It validates only facts visible in the installed helper:
/// - 0x91 data has a bounded revision field at offset 0x04;
/// - the helper compares the declared byte count at offset 0x14 with the
///   returned header length;
/// - the helper uses an offset at 0x18 to address the header's table.
///
/// It deliberately does not interpret 0x16 records as Bad Blocks, bands, P/E,
/// or writes. Until a captured artifact and a contemporaneous text snapshot
/// establish those offsets and units, returning a partial snapshot would be
/// more dangerous than returning no snapshot.
struct ASPDirectBinaryParser: Sendable {
    /// Revisions observed in the reviewed fixture and the real 25G83 artifact.
    /// The numeric field's semantic version is still unconfirmed, so values
    /// not observed in either source remain rejected.
    static let observedHeaderRevisions: Set<UInt32> = [5, 8]
    static let minimumHeaderBytes = 0x1C
    static let revisionOffset = 0x04
    static let declaredSizeOffset = 0x14
    static let tableOffsetOffset = 0x18

    func parse(
        data: Data,
        opcode: ASPDirectProbeOpcode,
        expectedBytes: Int? = nil,
        capturedAt: Date?,
        deviceID: String? = nil
    ) throws -> ASPDirectBinaryParseResult {
        guard let expectedBytes, expectedBytes > 0 else {
            throw ASPDirectBinaryParserError.missingExpectedSize
        }
        guard data.count >= expectedBytes else {
            throw ASPDirectBinaryParserError.partialRead(
                expectedBytes: expectedBytes,
                actualBytes: data.count
            )
        }
        guard data.count == expectedBytes else {
            throw ASPDirectBinaryParserError.invalidPayloadSize(
                expectedBytes: expectedBytes,
                actualBytes: data.count
            )
        }

        switch opcode {
        case .timeSensitiveSnapshotPayload:
            return ASPDirectBinaryParseResult(
                opcode: opcode,
                status: .formatUnconfirmed,
                headerEvidence: nil,
                normalizedSnapshot: nil,
                sourceRecordAt: nil,
                warnings: [
                    "0x16は時系列snapshotの生payloadとして取得済みですが、レコード形式・単位・時刻フィールドは未確認です",
                    "現在時刻を過去レコードの時刻として補完していません",
                    deviceID == nil ? "deviceIDが未指定です" : "deviceIDを保持しました"
                ]
            )
        case .snapshotHeader:
            return try parseHeader(data: data, capturedAt: capturedAt, deviceID: deviceID)
        }
    }

    private func parseHeader(
        data: Data,
        capturedAt: Date?,
        deviceID: String?
    ) throws -> ASPDirectBinaryParseResult {
        guard data.count >= Self.minimumHeaderBytes else {
            throw ASPDirectBinaryParserError.truncated(
                requiredBytes: Self.minimumHeaderBytes,
                actualBytes: data.count
            )
        }
        let revision = try readUInt32LE(data, offset: Self.revisionOffset)
        guard Self.observedHeaderRevisions.contains(revision) else {
            throw ASPDirectBinaryParserError.unknownRevision(revision)
        }
        let declaredSize = try readUInt32LE(data, offset: Self.declaredSizeOffset)
        let declaredSizeInt = Int(declaredSize)
        if declaredSizeInt > data.count {
            throw ASPDirectBinaryParserError.truncated(
                requiredBytes: declaredSizeInt,
                actualBytes: data.count
            )
        }
        if declaredSizeInt < data.count {
            throw ASPDirectBinaryParserError.invalidDeclaredSize(
                expectedBytes: declaredSizeInt,
                actualBytes: data.count
            )
        }
        let tableOffset = try readUInt32LE(data, offset: Self.tableOffsetOffset)
        guard tableOffset <= declaredSize else {
            throw ASPDirectBinaryParserError.invalidOffset(
                offset: Int(tableOffset),
                dataSize: data.count
            )
        }

        return ASPDirectBinaryParseResult(
            opcode: .snapshotHeader,
            status: .headerBoundaryValidated,
            headerEvidence: ASPDirectBinaryHeaderEvidence(
                helperRevisionField: revision,
                declaredSnapshotBytes: declaredSize,
                referencedTableOffset: tableOffset,
                headerBytes: data.count
            ),
            normalizedSnapshot: nil,
            sourceRecordAt: nil,
            warnings: [
                "0x91 headerの境界と想定サイズを検証しました",
                "revisionの意味はhelperの上限検査以外は未公開です",
                "0x16 payloadの項目・単位は未確認のため寿命予測へ投入していません",
                deviceID == nil ? "deviceIDが未指定です" : "deviceIDを保持しました",
                "取得時刻はcapturedAtのみ保持し、内部の保存時刻で上書きしていません",
                capturedAt.map { $0.timeIntervalSince1970 > 0 }
                    ?? false ? "取得時刻を受け取りました" : "取得時刻が未確認です"
            ]
        )
    }

    private func readUInt32LE(_ data: Data, offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - MemoryLayout<UInt32>.size else {
            throw ASPDirectBinaryParserError.truncated(
                requiredBytes: offset + MemoryLayout<UInt32>.size,
                actualBytes: data.count
            )
        }
        return data[offset..<offset + 4].enumerated().reduce(into: UInt32(0)) { result, item in
            result |= UInt32(item.element) << UInt32(item.offset * 8)
        }
    }
}

struct ASPDirectArtifactInspection: Equatable, Sendable {
    let directoryPath: String
    let measurement: ASPDirectProbeMeasurement
    let binaryByteCount: Int?
    let binaryParseStatus: ASPDirectBinaryParseStatus?
    let headerEvidence: ASPDirectBinaryHeaderEvidence?
    let parseError: ASPDirectBinaryParserError?
    let warnings: [String]

    var statusTitle: String {
        if parseError != nil { return "解析失敗" }
        if let binaryParseStatus { return binaryParseStatus.title }
        return measurement.outcome.title
    }

    var formatTitle: String {
        binaryParseStatus?.title ?? measurement.formatStatus
    }
}

enum ASPDirectArtifactInspectorError: LocalizedError, Equatable, Sendable {
    case notDirectory
    case missingMetadata
    case unsupportedTarget

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            return "ASP probeのrun directoryを選択してください"
        case .missingMetadata:
            return "選択したディレクトリにmetadata.txtがありません"
        case .unsupportedTarget:
            return "このartifactはBuild 25G83 / AppleANS3NVMeController / selector 9の対象外です"
        }
    }
}

/// Loads one private probe run directory without importing any value into the
/// normal SMART/asptool history. A missing or failed binary remains a visible
/// diagnostic state instead of being represented as zero.
struct ASPDirectArtifactInspector: Sendable {
    func inspect(directoryURL: URL) throws -> ASPDirectArtifactInspection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ASPDirectArtifactInspectorError.notDirectory
        }

        let metadataURL = directoryURL.appendingPathComponent("metadata.txt")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ASPDirectArtifactInspectorError.missingMetadata
        }
        let measurement = try ASPDirectProbeMetadataParser().parse(fileURL: metadataURL)
        guard measurement.isReviewedInterface else {
            throw ASPDirectArtifactInspectorError.unsupportedTarget
        }

        let binaryName = String(format: "opcode-0x%02x.bin", measurement.opcode.rawValue)
        let binaryURL = directoryURL.appendingPathComponent(binaryName)
        let binaryExists = FileManager.default.fileExists(atPath: binaryURL.path)
        var binaryByteCount: Int?
        var binaryParseStatus: ASPDirectBinaryParseStatus?
        var headerEvidence: ASPDirectBinaryHeaderEvidence?
        var parseError: ASPDirectBinaryParserError?
        var warnings: [String] = []

        if binaryExists {
            let data = try Data(contentsOf: binaryURL)
            binaryByteCount = data.count
            if measurement.outcome != .readFailed {
                do {
                    let result = try ASPDirectBinaryParser().parse(
                        data: data,
                        opcode: measurement.opcode,
                        expectedBytes: measurement.requestedBytes,
                        capturedAt: measurement.capturedAt
                    )
                    binaryParseStatus = result.status
                    headerEvidence = result.headerEvidence
                    warnings.append(contentsOf: result.warnings)
                } catch let error as ASPDirectBinaryParserError {
                    parseError = error
                    warnings.append(error.localizedDescription)
                }
            } else {
                warnings.append("read失敗のためraw binaryは解析対象にしません")
            }
        } else {
            warnings.append("raw binaryがありません。metadataのみを表示しています")
        }

        return ASPDirectArtifactInspection(
            directoryPath: directoryURL.standardizedFileURL.path,
            measurement: measurement,
            binaryByteCount: binaryByteCount,
            binaryParseStatus: binaryParseStatus,
            headerEvidence: headerEvidence,
            parseError: parseError,
            warnings: warnings
        )
    }
}
