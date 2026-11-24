import Foundation

/// The two fixed private SMART methods observed in the macOS 25G83 helper.
/// `all` is the only method whose record layout is currently decoded by the
/// application. `perm` remains an opaque artifact until its layout is
/// independently confirmed.
enum ASPToolDirectFTLKind: String, Codable, Equatable, Sendable {
    case all
    case perm

    var vtableOffset: UInt32 {
        let descriptor = DirectFTLContractRegistry.reviewed25G83
        switch self {
        case .all: return descriptor.allVtableOffset
        case .perm: return descriptor.permVtableOffset
        }
    }
}

/// Metadata written beside an `asp-ftl-*.bin` artifact by
/// `scripts/asp-ftl-stats-probe.c`.
struct ASPToolDirectFTLMeasurement: Codable, Equatable, Sendable {
    var smartServiceEntryID: UInt64? = nil
    var controllerEntryID: UInt64? = nil
    var wholeMediaEntryID: UInt64? = nil
    /// `build` is the runtime OS build written by the probe.  The optional
    /// contract fields were added after the original probe, whose `build` was
    /// a fixed 25G83 label.
    let build: String
    let contractBuild: String?
    let probeVersion: Int?
    let service: String
    let pluginUUID: String
    let interfaceUUID: String
    let kind: ASPToolDirectFTLKind
    let vtableOffset: UInt32
    let inputArgument: String
    let role: String
    let effectiveUserID: UInt32
    /// The time at which the private SMART method returned. This is not the
    /// time at which the artifact was later parsed or stored.
    let capturedAt: Date?
    let resultCode: UInt32
    let responseBytes: Int
    let capacityBytes: Int
    let elapsedMilliseconds: Double
    let totalElapsedMilliseconds: Double
    let formatStatus: String

    var isSuccessfulRead: Bool {
        resultCode == 0 && responseBytes > 0 && responseBytes <= capacityBytes
    }

    /// This deliberately describes the one reviewed target rather than
    /// treating a similarly named future method as compatible.
    var isReviewedInterface: Bool {
        let resolvedBuild = contractBuild ?? DirectFTLContractRegistry
            .descriptor(runtimeBuild: build)?.contractBuild
        guard let descriptor = DirectFTLContractRegistry.descriptor(contractBuild: resolvedBuild),
              descriptor.reviewStatus == .reviewed
        else { return false }
        return descriptor.matchesInterface(
            service: service,
            pluginUUID: pluginUUID,
            interfaceUUID: interfaceUUID,
            kindRawValue: kind.rawValue,
            vtableOffset: vtableOffset
        )
    }

    var runtimeBuild: String { build }

    var runsOnReviewedBuild: Bool {
        DirectFTLContractRegistry.descriptor(contractBuild: contractBuild)?.isReviewedRuntime(build) == true
    }

    /// Compatibility name retained for imported artifacts and older callers.
    var isReviewedTarget: Bool { isReviewedInterface }
}

enum ASPToolDirectFTLMetadataParserError: LocalizedError, Equatable, Sendable {
    case malformedLine(String)
    case missingKey(String)
    case invalidValue(key: String, value: String)
    case unsupportedKind(String)

    var errorDescription: String? {
        switch self {
        case let .malformedLine(line):
            return "ASP FTL metadataの行を解釈できません: \(line)"
        case let .missingKey(key):
            return "ASP FTL metadataに必須項目がありません: \(key)"
        case let .invalidValue(key, value):
            return "ASP FTL metadataの値が不正です: \(key)=\(value)"
        case let .unsupportedKind(kind):
            return "ASP FTL metadataのkindが未確認です: \(kind)"
        }
    }
}

struct ASPToolDirectFTLMetadataParser: Sendable {
    func parse(text: String) throws -> ASPToolDirectFTLMeasurement {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let components = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw ASPToolDirectFTLMetadataParserError.malformedLine(String(line))
            }
            fields[String(components[0])] = String(components[1])
        }

        func required(_ key: String) throws -> String {
            guard let value = fields[key], !value.isEmpty else {
                throw ASPToolDirectFTLMetadataParserError.missingKey(key)
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
                throw ASPToolDirectFTLMetadataParserError.invalidValue(key: key, value: value)
            }
            return parsed
        }

        func uint32(_ key: String) throws -> UInt32 {
            let value = try unsigned(key)
            guard value <= UInt64(UInt32.max) else {
                let rawValue = try required(key)
                throw ASPToolDirectFTLMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return UInt32(value)
        }

        func nonNegativeInteger(_ key: String) throws -> Int {
            let value = try unsigned(key)
            guard value <= UInt64(Int.max) else {
                let rawValue = try required(key)
                throw ASPToolDirectFTLMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return Int(value)
        }

        func decimal(_ key: String) throws -> Double {
            let value = try required(key)
            guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
                throw ASPToolDirectFTLMetadataParserError.invalidValue(key: key, value: value)
            }
            return parsed
        }

        func optionalEpoch(_ key: String) throws -> Date? {
            guard let value = fields[key], !value.isEmpty else { return nil }
            guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
                let rawValue = fields[key] ?? ""
                throw ASPToolDirectFTLMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return seconds == 0 ? nil : Date(timeIntervalSince1970: seconds)
        }

        func optionalInteger(_ key: String) throws -> Int? {
            guard let rawValue = fields[key], !rawValue.isEmpty else { return nil }
            guard let parsed = Int(rawValue), parsed >= 0 else {
                throw ASPToolDirectFTLMetadataParserError.invalidValue(key: key, value: rawValue)
            }
            return parsed
        }

        let rawKind = try required("kind")
        guard let kind = ASPToolDirectFTLKind(rawValue: rawKind) else {
            throw ASPToolDirectFTLMetadataParserError.unsupportedKind(rawKind)
        }

        var measurement = ASPToolDirectFTLMeasurement(
            build: try required("build"),
            contractBuild: fields["contractBuild"].flatMap { $0.isEmpty ? nil : $0 },
            probeVersion: try optionalInteger("probeVersion"),
            service: try required("service"),
            pluginUUID: try required("plugin_uuid"),
            interfaceUUID: try required("interface_uuid"),
            kind: kind,
            vtableOffset: try uint32("vtable_offset"),
            inputArgument: try required("input_arg"),
            role: try required("role"),
            effectiveUserID: try uint32("euid"),
            capturedAt: try optionalEpoch("captured_at_epoch"),
            resultCode: try uint32("result"),
            responseBytes: try nonNegativeInteger("response_bytes"),
            capacityBytes: try nonNegativeInteger("capacity_bytes"),
            elapsedMilliseconds: try decimal("elapsed_ms"),
            totalElapsedMilliseconds: try decimal("total_elapsed_ms"),
            formatStatus: try required("format_status")
        )
        for key in ["smart_service_entry_id", "controller_entry_id", "whole_media_entry_id"] where fields[key] != nil {
            let value = try unsigned(key)
            if key == "smart_service_entry_id" { measurement.smartServiceEntryID = value == 0 ? nil : value }
            else if key == "controller_entry_id" { measurement.controllerEntryID = value == 0 ? nil : value }
            else { measurement.wholeMediaEntryID = value == 0 ? nil : value }
        }
        guard (measurement.smartServiceEntryID == nil) == (measurement.controllerEntryID == nil),
              (measurement.smartServiceEntryID == nil) == (measurement.wholeMediaEntryID == nil) else {
            throw ASPToolDirectFTLMetadataParserError.invalidValue(key: "target_binding", value: "incomplete")
        }
        return measurement
    }

    func parse(fileURL: URL) throws -> ASPToolDirectFTLMeasurement {
        try parse(text: String(contentsOf: fileURL, encoding: .utf8))
    }
}

struct ASPToolDirectFTLRecord: Equatable, Sendable {
    let key: UInt32
    let values: [UInt64]
    let byteOffset: Int
}

/// The `all` response is a key/count/value table, not a public Apple format.
/// These keys were verified on the paired 25G83 direct artifact and the
/// nearby `asptool_snapshot.log`. Keep the contract build-scoped. P/E keys
/// require their expected shapes before they can enter the forecast; the
/// secondary ASP keys below are display-only raw counters.
private enum ASPToolDirectFTL25G83Key {
    // Core counters / geometry.  These are record keys, not a public Apple
    // interface.  The parser validates one record with the expected shape
    // before assigning semantics.
    static let hostWrites = 4
    static let nandWrites = 18
    static let nandReads = 19
    static let bandErases = 20
    static let powerOnHours = 34
    static let factoryBadBlocks = 46
    static let grownBadBlocks = 47
    static let bytesPerPage = 49
    static let pagesPerVirtualBlock = 50
    static let numVirtualBlocks = 52
    static let intermediateBandErases = 84
    static let intermediatePartitionStart = 85
    static let userPartitionStart = 86
    static let ageRefreshPerTier = 93
    static let backgroundRefreshMoves = 97
    static let bandsPaddedForAge = 112
    static let pagesPerVirtualBlockSLC = 129

    static let minimumPE = 124
    static let averagePE = 503
    static let maximumPE = 125
    static let slcEOLPE = 942
    static let tlcEOLPE = 943

    // Cross-checked against the named fields in the paired asptool output.
    static let slcPercentUsed = 430
    static let controllerPercentUsed = 431
    static let hostAutoWrites = 432
    static let hostAutoWriteTransactions = 433
    static let intermediateBandsProgrammed = 349
    static let userBandsProgrammed = 350
    static let intermediateNandWrites = 351
    static let userNandWrites = 352
    static let numDieFailures = 531
    static let spareAvailablePercent = 532
    static let performanceUserErases = 707
    static let performanceIntermediateErases = 708
    static let oslcTransitions = 561
    static let oslcBaseAveragePE = 565

    // Candidate Host-write composition records. The numeric presence and
    // scalar shape are verified on the direct artifact; the semantic labels
    // remain unconfirmed until paired asptool deltas prove their invariant.
    static let hostWriteCompositionCandidateKey5 = 5
    static let hostWriteCompositionCandidateKey6 = 6
    static let hostWriteCompositionCandidateKey27 = 27

    // Reviewed 25G83 research telemetry.  These raw counters and histograms
    // are retained for reliability evidence only; no inferred TBW multiplier
    // is attached to them.
    static let bandsMaxTempHistogram = 327
    static let bandsMinTempHistogram = 328
    static let bandsLifetimeTempHistogram = 329
    static let bandsDeltaTempHistogram = 330
    static let bandsCrossTempHistogram = 331
    static let crossTemperatureUECC = 340
    static let utilityUECCReads = 343
    static let ueccReads = 414
    static let readVerifyNative = 422
    static let reducedReadVerifyNative = 423
    static let readVerifySLC = 424
    static let directToTLCBands = 427
    static let directToTLCSectors = 461
    static let fallbackToWaterfall = 462
    static let nonProportionalDirectToTLCSectors = 485
    static let raidVerificationReads = 659
    static let crossTemperatureRaidUECC = 953
    static let hostSLCReadVerifyFailures = 1050
    static let hostTLCReadVerifyFailures = 1051
    static let gcSLCToTLCReadVerifyFailures = 1052
    static let gcTLCToTLCReadVerifyFailures = 1053
}

enum ASPToolDirectFTLParserError: LocalizedError, Equatable, Sendable {
    case unsupportedTarget
    case readFailed(resultCode: UInt32)
    case unsupportedKind(ASPToolDirectFTLKind)
    case emptyPayload
    case invalidPayloadAlignment(actualBytes: Int)
    case tooManyRecords(maximum: Int)
    case tooManyValues(key: UInt32, count: UInt64)
    case truncatedRecord(offset: Int, requiredBytes: Int, actualBytes: Int)
    case responseSizeMismatch(expectedBytes: Int, actualBytes: Int)
    case missingCapturedAt

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            return "ASP FTL direct pathが確認済みの25G83ターゲットではありません"
        case let .readFailed(resultCode):
            return String(format: "ASP FTL direct readが失敗しました（result=0x%08x）", resultCode)
        case let .unsupportedKind(kind):
            return "ASP FTLの\(kind.rawValue)形式はまだ正規化していません"
        case .emptyPayload:
            return "ASP FTL direct payloadが空です"
        case let .invalidPayloadAlignment(actualBytes):
            return "ASP FTL direct payloadの長さが8 bytes境界ではありません（\(actualBytes) bytes）"
        case let .tooManyRecords(maximum):
            return "ASP FTL direct payloadのレコード数が上限を超えました（上限 \(maximum)）"
        case let .tooManyValues(key, count):
            return "ASP FTL key \(key) の値数が上限を超えました（\(count)）"
        case let .truncatedRecord(offset, requiredBytes, actualBytes):
            return "ASP FTL recordが途中で切れています（offset \(offset), 必要 \(requiredBytes), 実際 \(actualBytes)）"
        case let .responseSizeMismatch(expectedBytes, actualBytes):
            return "ASP FTL response sizeがmetadataと一致しません（期待 \(expectedBytes), 実際 \(actualBytes)）"
        case .missingCapturedAt:
            return "ASP FTL read時刻がないため正規化snapshotを作成できません"
        }
    }
}

struct ASPToolDirectFTLParseResult: Equatable, Sendable {
    let measurement: ASPToolDirectFTLMeasurement
    let records: [ASPToolDirectFTLRecord]
    /// This is the time the application parsed/staged the artifact. It must
    /// never replace `measurement.capturedAt` in the monitoring history.
    let parsedAt: Date
    let snapshot: ASPToolDiagnosticsSnapshot?
    let warnings: [String]

    func values(for key: UInt32) -> [UInt64] {
        records.last(where: { $0.key == key })?.values ?? []
    }

    func firstValue(for key: UInt32) -> UInt64? {
        values(for: key).first
    }
}

/// Parser for the confirmed `all` FTL buffer. Each record begins with a
/// little-endian u64 descriptor: low 32 bits are the key and high 32 bits are
/// the number of following little-endian u64 values.
struct ASPToolDirectFTLParser: Sendable {
    static let maximumRecordCount = 65_536
    static let maximumValuesPerRecord: UInt64 = 65_536

    func parse(
        data: Data,
        measurement: ASPToolDirectFTLMeasurement,
        deviceID: String? = nil,
        deviceContext: CurrentDeviceContext? = nil,
        sourceName: String = "asp-ftl-all.bin",
        parsedAt: Date = Date(),
        unitState: ASPToolUnitState = .provisional4KiB
    ) throws -> ASPToolDirectFTLParseResult {
        guard measurement.isReviewedInterface else {
            throw ASPToolDirectFTLParserError.unsupportedTarget
        }
        guard measurement.isSuccessfulRead else {
            throw ASPToolDirectFTLParserError.readFailed(resultCode: measurement.resultCode)
        }
        guard measurement.kind == .all else {
            throw ASPToolDirectFTLParserError.unsupportedKind(measurement.kind)
        }
        guard data.count == measurement.responseBytes else {
            throw ASPToolDirectFTLParserError.responseSizeMismatch(
                expectedBytes: measurement.responseBytes,
                actualBytes: data.count
            )
        }
        guard !data.isEmpty else { throw ASPToolDirectFTLParserError.emptyPayload }
        guard data.count.isMultiple(of: MemoryLayout<UInt64>.size) else {
            throw ASPToolDirectFTLParserError.invalidPayloadAlignment(actualBytes: data.count)
        }

        let records = try parseRecords(data: data)
        let unitWarning: String
        switch unitState {
        case .verified:
            unitWarning = "host/NAND counterは検証済み4 KiB単位です"
        case .provisional4KiB:
            unitWarning = "host/NAND counterは近接asptool出力と照合した4 KiB暫定値です。Appleの公開単位仕様ではありません"
        case .unverified:
            unitWarning = "host/NAND counterは取得済みですが単位未確認です"
        case .unavailable:
            unitWarning = "host/NAND counterの単位は利用不可です"
        }
        var warnings = [
            "ASP FTL private SMART all bufferを直接解析しました",
            unitWarning,
            "P/E/EoLは25G83で照合済みの固定のkeyの対応表です。macOS更新後は再検証が必要です"
        ]

        guard let capturedAt = measurement.capturedAt else {
            warnings.append("read時刻がないため、parse時刻を取得時刻として扱っていません")
            return ASPToolDirectFTLParseResult(
                measurement: measurement,
                records: records,
                parsedAt: parsedAt,
                snapshot: nil,
                warnings: warnings
            )
        }

        if let expected = deviceContext?.targetBinding,
           measurement.smartServiceEntryID != nil || (measurement.probeVersion ?? 0) >= 3 {
            guard measurement.smartServiceEntryID == expected.smartServiceID,
                  measurement.controllerEntryID == expected.controllerEntryID,
                  measurement.wholeMediaEntryID == expected.wholeMediaID else {
                throw ASPToolDirectFTLParserError.unsupportedTarget
            }
        }
        var snapshot = makeSnapshot(
            records: records,
            capturedAt: capturedAt,
            deviceID: deviceID,
            deviceContext: deviceContext,
            sourceName: sourceName,
            sourceBuild: measurement.runtimeBuild,
            contractBuild: measurement.contractBuild,
            probeVersion: measurement.probeVersion,
            runtimeBuildProvenance: measurement.contractBuild == nil ? .legacyFixedLabel : .recorded,
            warnings: warnings,
            unitState: unitState
        )
        if measurement.smartServiceEntryID != nil {
            snapshot.acquisitionBinding = deviceContext?.targetBinding
        }
        return ASPToolDirectFTLParseResult(
            measurement: measurement,
            records: records,
            parsedAt: parsedAt,
            snapshot: snapshot,
            warnings: warnings
        )
    }

    private func parseRecords(data: Data) throws -> [ASPToolDirectFTLRecord] {
        var records: [ASPToolDirectFTLRecord] = []
        records.reserveCapacity(min(data.count / MemoryLayout<UInt64>.size, 512))
        var offset = 0

        while offset < data.count {
            guard records.count < Self.maximumRecordCount else {
                throw ASPToolDirectFTLParserError.tooManyRecords(maximum: Self.maximumRecordCount)
            }
            guard data.count - offset >= MemoryLayout<UInt64>.size else {
                throw ASPToolDirectFTLParserError.truncatedRecord(
                    offset: offset,
                    requiredBytes: MemoryLayout<UInt64>.size,
                    actualBytes: data.count - offset
                )
            }

            let descriptor = readUInt64LE(from: data, at: offset)
            let key = UInt32(descriptor & 0xffff_ffff)
            let valueCount = descriptor >> 32
            guard valueCount <= Self.maximumValuesPerRecord else {
                throw ASPToolDirectFTLParserError.tooManyValues(key: key, count: valueCount)
            }

            let valueBytes: Int
            if valueCount > UInt64(Int.max / MemoryLayout<UInt64>.size) {
                throw ASPToolDirectFTLParserError.tooManyValues(key: key, count: valueCount)
            }
            valueBytes = Int(valueCount) * MemoryLayout<UInt64>.size
            let requiredBytes = MemoryLayout<UInt64>.size + valueBytes
            guard data.count - offset >= requiredBytes else {
                throw ASPToolDirectFTLParserError.truncatedRecord(
                    offset: offset,
                    requiredBytes: requiredBytes,
                    actualBytes: data.count - offset
                )
            }

            var values: [UInt64] = []
            values.reserveCapacity(Int(valueCount))
            var valueOffset = offset + MemoryLayout<UInt64>.size
            for _ in 0..<Int(valueCount) {
                values.append(readUInt64LE(from: data, at: valueOffset))
                valueOffset += MemoryLayout<UInt64>.size
            }
            records.append(ASPToolDirectFTLRecord(key: key, values: values, byteOffset: offset))
            offset += requiredBytes
        }
        return records
    }

    private func readUInt64LE(from data: Data, at offset: Int) -> UInt64 {
        data.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            var value: UInt64 = 0
            for byteIndex in 0..<MemoryLayout<UInt64>.size {
                value |= UInt64(pointer[byteIndex]) << UInt64(byteIndex * 8)
            }
            return value
        }
    }

    private func makeSnapshot(
        records: [ASPToolDirectFTLRecord],
        capturedAt: Date,
        deviceID: String?,
        deviceContext: CurrentDeviceContext?,
        sourceName: String,
        sourceBuild: String?,
        contractBuild: String?,
        probeVersion: Int?,
        runtimeBuildProvenance: BuildProvenance,
        warnings: [String],
        unitState: ASPToolUnitState
    ) -> ASPToolDiagnosticsSnapshot {
        let recordsByKey = Dictionary(grouping: records, by: \.key)
        var snapshotWarnings = warnings

        func uniqueValues(_ key: UInt32, label: String) -> [UInt64]? {
            guard let matching = recordsByKey[key] else { return nil }
            guard matching.count == 1 else {
                snapshotWarnings.append("\(label) key \(key) は重複recordのため未取得として扱いました")
                return nil
            }
            return matching[0].values
        }

        func counter(_ key: UInt32, label: String) -> UInt64? {
            guard let values = uniqueValues(key, label: label) else { return nil }
            guard values.count == 1, let value = values.first else {
                snapshotWarnings.append("\(label) key \(key) のscalar形状が不正です")
                return nil
            }
            // A zero counter is a valid observed value.  Do not replace it
            // with either an unavailable marker or a fabricated positive value.
            return value
        }

        func pair(_ key: UInt32, label: String) -> (UInt64, UInt64)? {
            guard let values = uniqueValues(key, label: label) else { return nil }
            guard values.count == 2, values.allSatisfy({ $0 <= 1_000_000 }) else {
                snapshotWarnings.append("\(label) key \(key) のpair形状または範囲が不正です")
                return nil
            }
            return (values[0], values[1])
        }

        func positiveScalar(_ key: UInt32, label: String) -> UInt64? {
            guard let value = counter(key, label: label), value > 0, value <= 1_000_000 else {
                if recordsByKey[key] != nil {
                    snapshotWarnings.append("\(label) key \(key) の値が不正です")
                }
                return nil
            }
            return value
        }

        func rawArray(_ key: UInt32, label: String, maximumCount: Int) -> [UInt64]? {
            guard let values = uniqueValues(key, label: label) else { return nil }
            guard values.count <= maximumCount else {
                snapshotWarnings.append("\(label) key \(key) の配列数\(values.count)が上限\(maximumCount)を超えました")
                return nil
            }
            // Preserve [] separately from nil so UI can distinguish an empty
            // record from an all-zero populated histogram.
            return values
        }

        let hostWrites = counter(UInt32(ASPToolDirectFTL25G83Key.hostWrites), label: "Host writes")
        let nandWrites = counter(UInt32(ASPToolDirectFTL25G83Key.nandWrites), label: "NAND writes")
        let bandErases = counter(UInt32(ASPToolDirectFTL25G83Key.bandErases), label: "Band erases")
        let powerOnHours = counter(UInt32(ASPToolDirectFTL25G83Key.powerOnHours), label: "Power-on hours")
        let factoryBadBlocks = counter(UInt32(ASPToolDirectFTL25G83Key.factoryBadBlocks), label: "Factory bad blocks")
        let grownBadBlocks = counter(UInt32(ASPToolDirectFTL25G83Key.grownBadBlocks), label: "Grown bad blocks")
        let bytesPerPage = positiveScalar(UInt32(ASPToolDirectFTL25G83Key.bytesPerPage), label: "Bytes per page")
        let pagesPerVirtualBlock = positiveScalar(UInt32(ASPToolDirectFTL25G83Key.pagesPerVirtualBlock), label: "Pages per virtual block")
        let intermediateBandErases = counter(UInt32(ASPToolDirectFTL25G83Key.intermediateBandErases), label: "Intermediate erases")
        let pagesPerVirtualBlockSLC = positiveScalar(UInt32(ASPToolDirectFTL25G83Key.pagesPerVirtualBlockSLC), label: "Pages per pSLC virtual block")

        let minimumPE = pair(UInt32(ASPToolDirectFTL25G83Key.minimumPE), label: "Minimum P/E")
        let averagePE = pair(UInt32(ASPToolDirectFTL25G83Key.averagePE), label: "Average P/E")
        let maximumPE = pair(UInt32(ASPToolDirectFTL25G83Key.maximumPE), label: "Maximum P/E")
        let tlcEOLPE = positiveScalar(UInt32(ASPToolDirectFTL25G83Key.tlcEOLPE), label: "TLC EOL P/E")
        let slcEOLPE = positiveScalar(UInt32(ASPToolDirectFTL25G83Key.slcEOLPE), label: "pSLC EOL P/E")

        func percentage(_ key: UInt32, label: String) -> Double? {
            guard let raw = counter(key, label: label), raw <= 100 else { return nil }
            return Double(raw)
        }

        let controllerPercentUsed = percentage(UInt32(ASPToolDirectFTL25G83Key.controllerPercentUsed), label: "Controller percent used")
        let slcPercentUsed = percentage(UInt32(ASPToolDirectFTL25G83Key.slcPercentUsed), label: "pSLC percent used")
        let spareAvailablePercent = percentage(UInt32(ASPToolDirectFTL25G83Key.spareAvailablePercent), label: "Spare available")
        let hostAutoWrites = counter(UInt32(ASPToolDirectFTL25G83Key.hostAutoWrites), label: "Host auto writes")
        let hostAutoWriteTransactions = counter(UInt32(ASPToolDirectFTL25G83Key.hostAutoWriteTransactions), label: "Host auto write transactions")
        let intermediateBandsProgrammed = counter(UInt32(ASPToolDirectFTL25G83Key.intermediateBandsProgrammed), label: "Intermediate bands programmed")
        let userBandsProgrammed = counter(UInt32(ASPToolDirectFTL25G83Key.userBandsProgrammed), label: "User bands programmed")
        let intermediateNandWrites = counter(UInt32(ASPToolDirectFTL25G83Key.intermediateNandWrites), label: "Intermediate NAND writes")
        let userNandWrites = counter(UInt32(ASPToolDirectFTL25G83Key.userNandWrites), label: "User NAND writes")
        let numDieFailures = counter(UInt32(ASPToolDirectFTL25G83Key.numDieFailures), label: "Die failures")
        let performanceUserErases = counter(UInt32(ASPToolDirectFTL25G83Key.performanceUserErases), label: "Performance user erases")
        let performanceIntermediateErases = counter(UInt32(ASPToolDirectFTL25G83Key.performanceIntermediateErases), label: "Performance intermediate erases")
        let oslcTransitions = counter(UInt32(ASPToolDirectFTL25G83Key.oslcTransitions), label: "oSLC transitions")
        let oslcBaseAveragePE = counter(UInt32(ASPToolDirectFTL25G83Key.oslcBaseAveragePE), label: "oSLC base P/E").map { Double($0) }
        let hostWriteCompositionCandidateKey5 = counter(
            UInt32(ASPToolDirectFTL25G83Key.hostWriteCompositionCandidateKey5),
            label: "Host-write composition candidate key 5"
        )
        let hostWriteCompositionCandidateKey6 = counter(
            UInt32(ASPToolDirectFTL25G83Key.hostWriteCompositionCandidateKey6),
            label: "Host-write composition candidate key 6"
        )
        let hostWriteCompositionCandidateKey27 = counter(
            UInt32(ASPToolDirectFTL25G83Key.hostWriteCompositionCandidateKey27),
            label: "Host-write composition candidate key 27"
        )

        let hasValidPEContract: Bool = {
            guard let minimumPE, let averagePE, let maximumPE,
                  tlcEOLPE != nil, slcEOLPE != nil else { return false }
            // EOL and over-EOL are valid observed states, not parse errors.
            // Later forecasting turns an at-or-over-target domain into zero
            // remaining NAND.
            return minimumPE.0 <= averagePE.0 && averagePE.0 <= maximumPE.0 &&
                minimumPE.1 <= averagePE.1 && averagePE.1 <= maximumPE.1
        }()

        let tlcAveragePE: Double? = hasValidPEContract ? averagePE.map { Double($0.0) } : nil
        let tlcMinimumPE: Double? = hasValidPEContract ? minimumPE.map { Double($0.0) } : nil
        let tlcMaximumPE: Double? = hasValidPEContract ? maximumPE.map { Double($0.0) } : nil
        let slcAveragePE: Double? = hasValidPEContract ? averagePE.map { Double($0.1) } : nil
        let slcMinimumPE: Double? = hasValidPEContract ? minimumPE.map { Double($0.1) } : nil
        let slcMaximumPE: Double? = hasValidPEContract ? maximumPE.map { Double($0.1) } : nil

        let semanticBuild = contractBuild ?? DirectFTLContractRegistry
            .descriptor(runtimeBuild: sourceBuild)?.contractBuild
        let contractDescriptor = DirectFTLContractRegistry.descriptor(contractBuild: semanticBuild)
        let contractVersion = contractDescriptor?.semanticContractVersion
        let topology: DirectFTLTopology? = {
            guard let contractVersion,
                  let numVirtualBlocks = positiveScalar(UInt32(ASPToolDirectFTL25G83Key.numVirtualBlocks), label: "Number of virtual blocks"),
                  let intermediateStart = counter(UInt32(ASPToolDirectFTL25G83Key.intermediatePartitionStart), label: "Intermediate partition start"),
                  let userStart = counter(UInt32(ASPToolDirectFTL25G83Key.userPartitionStart), label: "User partition start"),
                  let bytesPerPage, let pagesPerVirtualBlock, let pagesPerVirtualBlockSLC
            else { return nil }
            let topology = DirectFTLTopology(contractVersion: contractVersion,
                                              numVirtualBlocks: numVirtualBlocks,
                                              intermediatePartitionStart: intermediateStart,
                                              userPartitionStart: userStart,
                                              bytesPerPage: bytesPerPage,
                                              pagesPerVirtualBlock: pagesPerVirtualBlock,
                                              pagesPerVirtualBlockSLC: pagesPerVirtualBlockSLC)
            if topology == nil {
                snapshotWarnings.append("Direct topologyの区画境界またはgeometryが不正のため未取得として扱いました")
            }
            return topology
        }()

        let telemetry: FTLResearchTelemetrySnapshot? = {
            guard contractVersion != nil else { return nil }
            let value = FTLResearchTelemetrySnapshot(
                nandReads: counter(UInt32(ASPToolDirectFTL25G83Key.nandReads), label: "NAND reads"),
                ageRefreshPerTier: rawArray(UInt32(ASPToolDirectFTL25G83Key.ageRefreshPerTier), label: "Age refresh per tier", maximumCount: DirectFTLResearchContract.maximumTierValues),
                backgroundRefreshMoves: counter(UInt32(ASPToolDirectFTL25G83Key.backgroundRefreshMoves), label: "Background refresh moves"),
                bandsPaddedForAge: counter(UInt32(ASPToolDirectFTL25G83Key.bandsPaddedForAge), label: "Bands padded for age"),
                crossTemperatureUECC: counter(UInt32(ASPToolDirectFTL25G83Key.crossTemperatureUECC), label: "Cross-temperature UECC"),
                utilityUECCReads: counter(UInt32(ASPToolDirectFTL25G83Key.utilityUECCReads), label: "Utility UECC reads"),
                ueccReads: counter(UInt32(ASPToolDirectFTL25G83Key.ueccReads), label: "UECC reads"),
                readVerifyNative: counter(UInt32(ASPToolDirectFTL25G83Key.readVerifyNative), label: "Read verify native"),
                reducedReadVerifyNative: counter(UInt32(ASPToolDirectFTL25G83Key.reducedReadVerifyNative), label: "Reduced read verify native"),
                readVerifySLC: counter(UInt32(ASPToolDirectFTL25G83Key.readVerifySLC), label: "Read verify pSLC"),
                directToTLCBands: counter(UInt32(ASPToolDirectFTL25G83Key.directToTLCBands), label: "Direct-to-TLC bands"),
                directToTLCSectors: counter(UInt32(ASPToolDirectFTL25G83Key.directToTLCSectors), label: "Direct-to-TLC sectors"),
                fallbackToWaterfall: counter(UInt32(ASPToolDirectFTL25G83Key.fallbackToWaterfall), label: "Fallback to waterfall"),
                nonProportionalDirectToTLCSectors: counter(UInt32(ASPToolDirectFTL25G83Key.nonProportionalDirectToTLCSectors), label: "Non-proportional direct-to-TLC sectors"),
                raidVerificationReads: counter(UInt32(ASPToolDirectFTL25G83Key.raidVerificationReads), label: "RAID verification reads"),
                crossTemperatureRaidUECC: counter(UInt32(ASPToolDirectFTL25G83Key.crossTemperatureRaidUECC), label: "Cross-temperature RAID UECC"),
                hostSLCReadVerifyFailures: counter(UInt32(ASPToolDirectFTL25G83Key.hostSLCReadVerifyFailures), label: "Host pSLC RV failures"),
                hostTLCReadVerifyFailures: counter(UInt32(ASPToolDirectFTL25G83Key.hostTLCReadVerifyFailures), label: "Host TLC RV failures"),
                gcSLCToTLCReadVerifyFailures: counter(UInt32(ASPToolDirectFTL25G83Key.gcSLCToTLCReadVerifyFailures), label: "GC pSLC-to-TLC RV failures"),
                gcTLCToTLCReadVerifyFailures: counter(UInt32(ASPToolDirectFTL25G83Key.gcTLCToTLCReadVerifyFailures), label: "GC TLC-to-TLC RV failures"),
                bandsMaxTempHistogram: rawArray(UInt32(ASPToolDirectFTL25G83Key.bandsMaxTempHistogram), label: "Bands max-temperature histogram", maximumCount: DirectFTLResearchContract.maximumHistogramBins),
                bandsMinTempHistogram: rawArray(UInt32(ASPToolDirectFTL25G83Key.bandsMinTempHistogram), label: "Bands min-temperature histogram", maximumCount: DirectFTLResearchContract.maximumHistogramBins),
                bandsLifetimeTempHistogram: rawArray(UInt32(ASPToolDirectFTL25G83Key.bandsLifetimeTempHistogram), label: "Bands lifetime-temperature histogram", maximumCount: DirectFTLResearchContract.maximumHistogramBins),
                bandsDeltaTempHistogram: rawArray(UInt32(ASPToolDirectFTL25G83Key.bandsDeltaTempHistogram), label: "Bands delta-temperature histogram", maximumCount: DirectFTLResearchContract.maximumHistogramBins),
                bandsCrossTempHistogram: rawArray(UInt32(ASPToolDirectFTL25G83Key.bandsCrossTempHistogram), label: "Bands cross-temperature histogram", maximumCount: DirectFTLResearchContract.maximumHistogramBins)
            )
            return value.hasValues ? value : nil
        }()

        func calculatedWriteAmp(
            erases: UInt64?,
            pagesPerBlock: UInt64?
        ) -> Double? {
            guard let erases, let pagesPerBlock, let bytesPerPage, let hostWrites,
                  hostWrites > 0, bytesPerPage > 0 else { return nil }
            let numerator = Double(erases) * Double(pagesPerBlock) * Double(bytesPerPage)
            let denominator = Double(4_096) * Double(hostWrites)
            let result = numerator / denominator
            return result.isFinite && result >= 0 ? result : nil
        }

        if !hasValidPEContract {
            snapshotWarnings.append("P/E/EoLの固定keyが不足または範囲不正のため、寿命予測へ投入していません")
        }
        if controllerPercentUsed != nil || slcPercentUsed != nil || hostAutoWrites != nil ||
            intermediateBandErases != nil ||
            intermediateNandWrites != nil || performanceUserErases != nil || oslcTransitions != nil {
            snapshotWarnings.append("ASP内部統計は25G83のasptoolラベルとFTL keyを照合した表示専用raw値です。単位未確認のため容量・寿命予測には使用していません")
        }
        if hostWriteCompositionCandidateKey5 != nil ||
            hostWriteCompositionCandidateKey6 != nil ||
            hostWriteCompositionCandidateKey27 != nil {
            snapshotWarnings.append("Host書込みcomposition候補 key 5 / 6 / 27 はscalar観測値として保存しました。asptoolとのdelta・合計不変量が未確認のため、意味付け・Host Writes・WAF・寿命予測には使用していません")
        }

        let context = deviceContext ?? CurrentDeviceContext(deviceID: deviceID)
        if context.capturedAt == nil {
            snapshotWarnings.append("IORegistry identityの取得時刻がありません。Direct FTL系列へ新しいfirmware／controller identityを結び付けず、未確認として保存しました")
        }
        return ASPToolDiagnosticsSnapshot(
            capturedAt: capturedAt,
            captureQuality: .explicit,
            deviceID: context.deviceID ?? deviceID,
            sourceName: sourceName,
            sourceArtifact: .directFTL,
            sourceBuild: sourceBuild ?? context.sourceBuild,
            contractBuild: contractBuild,
            probeVersion: probeVersion,
            runtimeBuildProvenance: runtimeBuildProvenance,
            extractionVersion: 1,
            historySchemaVersion: 2,
            semanticContractVersion: contractVersion,
            coreWearContractVersion: contractDescriptor?.coreWearContractVersion,
            researchTelemetryContractVersion: contractDescriptor?.researchTelemetryContractVersion,
            identityCapturedAt: context.capturedAt,
            observationBlockCount: records.count,
            hostWrites: hostWrites,
            nandWrites: nandWrites,
            hostWritesUnitState: hostWrites == nil ? .unavailable : unitState,
            nandWritesUnitState: nandWrites == nil ? .unavailable : unitState,
            tlcAveragePE: tlcAveragePE,
            tlcMinimumPE: tlcMinimumPE,
            tlcMaximumPE: tlcMaximumPE,
            tlcEOLPE: hasValidPEContract ? Double(tlcEOLPE!) : nil,
            slcAveragePE: slcAveragePE,
            slcMinimumPE: slcMinimumPE,
            slcMaximumPE: slcMaximumPE,
            slcEOLPE: hasValidPEContract ? Double(slcEOLPE!) : nil,
            powerOnHours: powerOnHours,
            firmware: context.firmware,
            mspVersion: context.mspVersion,
            chipID: context.chipID,
            writeAmp: calculatedWriteAmp(erases: bandErases, pagesPerBlock: pagesPerVirtualBlock),
            intermediateWriteAmp: calculatedWriteAmp(
                erases: intermediateBandErases,
                pagesPerBlock: pagesPerVirtualBlockSLC
            ),
            spareAvailablePercent: spareAvailablePercent,
            numDieFailures: numDieFailures,
            grownBadBlocks: grownBadBlocks,
            factoryBadBlocks: factoryBadBlocks,
            controllerPercentUsed: controllerPercentUsed,
            slcPercentUsed: slcPercentUsed,
            oslcTransitions: oslcTransitions,
            oslcBaseAveragePE: oslcBaseAveragePE,
            hostAutoWrites: hostAutoWrites,
            hostAutoWriteTransactions: hostAutoWriteTransactions,
            intermediateBandErases: intermediateBandErases,
            intermediateBandsProgrammed: intermediateBandsProgrammed,
            userBandsProgrammed: userBandsProgrammed,
            intermediateNandWrites: intermediateNandWrites,
            userNandWrites: userNandWrites,
            performanceUserErases: performanceUserErases,
            performanceIntermediateErases: performanceIntermediateErases,
            hostWriteCompositionCandidateKey5: hostWriteCompositionCandidateKey5,
            hostWriteCompositionCandidateKey6: hostWriteCompositionCandidateKey6,
            hostWriteCompositionCandidateKey27: hostWriteCompositionCandidateKey27,
            directKeyContractVersion: contractVersion,
            directTopology: topology,
            researchTelemetry: telemetry,
            parseWarnings: snapshotWarnings
        )
    }
}

enum ASPToolDirectFTLArtifactCollectorError: LocalizedError, Equatable, Sendable {
    case unsupportedTarget
    case missingPayload(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget:
            return "ASP FTL artifactの取得対象が確認済みの25G83 direct pathではありません"
        case let .missingPayload(url):
            return "ASP FTL payloadがありません: \(url.path)"
        }
    }
}

/// Reads an already-created private artifact directory. It never invokes
/// sysdiagnose, sudo, or the private IOKit method itself. Live acquisition is
/// intentionally kept in the standalone/root-gated probe until a helper
/// boundary is designed and reviewed.
struct ASPToolDirectFTLArtifactCollector: Sendable {
    let metadataParser: ASPToolDirectFTLMetadataParser
    let parser: ASPToolDirectFTLParser

    init(
        metadataParser: ASPToolDirectFTLMetadataParser = ASPToolDirectFTLMetadataParser(),
        parser: ASPToolDirectFTLParser = ASPToolDirectFTLParser()
    ) {
        self.metadataParser = metadataParser
        self.parser = parser
    }

    func collect(
        from directoryURL: URL,
        deviceID: String? = nil,
        deviceContext: CurrentDeviceContext? = nil,
        parsedAt: Date = Date()
    ) throws -> ASPToolDirectFTLParseResult {
        let metadataURL = directoryURL.appendingPathComponent("metadata.txt")
        let measurement = try metadataParser.parse(fileURL: metadataURL)
        guard measurement.isReviewedInterface else {
            throw ASPToolDirectFTLArtifactCollectorError.unsupportedTarget
        }
        let payloadURL = directoryURL.appendingPathComponent("asp-ftl-\(measurement.kind.rawValue).bin")
        guard FileManager.default.fileExists(atPath: payloadURL.path) else {
            throw ASPToolDirectFTLArtifactCollectorError.missingPayload(payloadURL)
        }
        let data = try Data(contentsOf: payloadURL, options: [.mappedIfSafe])
        return try parser.parse(
            data: data,
            measurement: measurement,
            deviceID: deviceID,
            deviceContext: deviceContext,
            sourceName: payloadURL.lastPathComponent,
            parsedAt: parsedAt
        )
    }
}
