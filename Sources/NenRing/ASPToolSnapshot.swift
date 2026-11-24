import Foundation

enum ASPToolCaptureQuality: String, Codable, Equatable, Sendable {
    case explicit
    case fileMetadata
    case unknown

    var title: String {
        switch self {
        case .explicit: return "取得時刻あり"
        case .fileMetadata: return "ファイル時刻"
        case .unknown: return "時刻未確認"
        }
    }
}

enum ASPToolUnitState: String, Codable, Equatable, Sendable {
    /// A parser may emit this only when its caller has an independently
    /// verified 4 KiB unit contract. Current asptool/FTL collectors do not
    /// have that evidence and therefore keep emitting `provisional4KiB`.
    case verified
    case provisional4KiB
    case unverified
    case unavailable

    var title: String {
        switch self {
        case .verified: return "Verified 4 KiB"
        case .provisional4KiB: return "4 KiB provisional"
        case .unverified: return "Unverified"
        case .unavailable: return "Unavailable"
        }
    }

    var unitBytes: Double? {
        switch self {
        case .verified, .provisional4KiB:
            return 4_096
        case .unverified, .unavailable:
            return nil
        }
    }

    /// A provisional 4 KiB counter is not an absolute unit guarantee, but it
    /// can still be compared between captures when both endpoints carry the
    /// same state. The unit scale cancels out of a time-to-wear-rate estimate;
    /// the resulting absolute byte values and confidence must remain marked
    /// provisional.
    var supportsIntervalComparison: Bool {
        switch self {
        case .verified, .provisional4KiB:
            return true
        case .unverified, .unavailable:
            return false
        }
    }
}

/// Hardware identity captured alongside a Direct FTL read.  Direct FTL
/// artifacts do not carry all of the controller metadata themselves, so the
/// current IORegistry profile is attached at collection time.  Optional
/// fields intentionally remain nil when the identity source could not supply
/// them; they are never inferred from an unrelated historical snapshot.
struct CurrentDeviceContext: Codable, Equatable, Sendable {
    /// Timestamp of the IORegistry read that supplied this context.  This is
    /// intentionally optional for backward-compatible imported fixtures.
    let capturedAt: Date?
    let deviceID: String?
    let controllerID: String?
    let firmware: String?
    let mspVersion: String?
    let chipID: String?
    let sourceBuild: String?
    let hardwareGeneration: String?
    var targetBinding: StorageTargetBinding? = nil

    init(
        capturedAt: Date? = nil,
        deviceID: String? = nil,
        controllerID: String? = nil,
        firmware: String? = nil,
        mspVersion: String? = nil,
        chipID: String? = nil,
        sourceBuild: String? = nil,
        hardwareGeneration: String? = nil,
        targetBinding: StorageTargetBinding? = nil
    ) {
        self.capturedAt = capturedAt
        self.deviceID = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.controllerID = controllerID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.firmware = firmware?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.mspVersion = mspVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.chipID = chipID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sourceBuild = sourceBuild?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.hardwareGeneration = hardwareGeneration?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.targetBinding = targetBinding
    }

    var firmwareEpoch: String? {
        switch (firmware, mspVersion) {
        case let (.some(firmware), .some(msp)): return "\(firmware)|\(msp)"
        case let (.some(firmware), .none): return firmware
        case let (.none, .some(msp)): return msp
        case (.none, .none): return nil
        }
    }
}

enum ASPToolSourceArtifact: String, Codable, Equatable, Sendable {
    case extractedASPTool
    case importedFixture
    /// Raw bytes captured through the reviewed AppleANS3 selector/opcode path.
    /// This is deliberately distinct from the text produced by asptool.
    case directBinary
    case directBinaryHeader
    /// Raw FTL statistics captured through the reviewed private SMART method.
    /// This is distinct from both the text snapshot and the older 0x16/0x91
    /// probe artifacts.
    case directFTL
    /// Structural band statistics captured through the reviewed 0x106 tunnel.
    /// P/E partition semantics remain separate until they are confirmed.
    case directBandStats

    /// Only reviewed Direct FTL captures feed the forecast and wear lane.
    /// asptool text (imported, or extracted by earlier builds) is kept as
    /// evidence and compared in `ASPToolLogComparison`, never forecast from.
    var participatesInCoreWearLane: Bool {
        self == .directFTL
    }
}

/// A compact, bounded representation of the useful part of an asptool log.
/// The full log is never kept in the monitoring history.
struct ASPToolDiagnosticsSnapshot: Codable, Equatable, Identifiable, Sendable {
    /// Local provenance only. Volatile registry IDs never identify a wear lane.
    var acquisitionBinding: StorageTargetBinding? = nil
    let id: UUID
    let capturedAt: Date
    let captureQuality: ASPToolCaptureQuality
    var deviceID: String?
    let sourceName: String
    let sourceArtifact: ASPToolSourceArtifact
    /// Runtime OS build recorded by the probe.  The field keeps its historic
    /// name in JSON for compatibility; `contractBuild` identifies the key
    /// contract independently.
    let sourceBuild: String?
    let contractBuild: String?
    let probeVersion: Int?
    /// Optional so snapshots written before the metadata split remain
    /// decodable.  Analysis resolves a missing value to the legacy overlay;
    /// the raw record itself is never rewritten.
    let runtimeBuildProvenance: BuildProvenance?
    let extractionVersion: Int
    /// Schema and semantic contract are separate: schema is the persisted
    /// record shape, while semanticContractVersion identifies the private FTL
    /// key meanings used by a direct capture.
    let historySchemaVersion: Int?
    var semanticContractVersion: String?
    /// v2.4.1 changed research-key interpretation but not the Host/NAND/P/E/
    /// EOL/topology wear inputs. These fields are optional so old JSON remains
    /// readable; `DirectFTLResearchContract` derives them for legacy records.
    let coreWearContractVersion: String?
    var researchTelemetryContractVersion: String?
    /// IORegistry identity timestamp copied into a Direct FTL capture.
    let identityCapturedAt: Date?
    let observationBlockCount: Int

    let hostWrites: UInt64?
    let nandWrites: UInt64?
    let hostWritesUnitState: ASPToolUnitState
    let nandWritesUnitState: ASPToolUnitState

    let tlcAveragePE: Double?
    let tlcMinimumPE: Double?
    let tlcMaximumPE: Double?
    let tlcEOLPE: Double?
    let slcAveragePE: Double?
    let slcMinimumPE: Double?
    let slcMaximumPE: Double?
    let slcEOLPE: Double?

    let powerOnHours: UInt64?
    let firmware: String?
    let mspVersion: String?
    let chipID: String?
    let writeAmp: Double?
    let intermediateWriteAmp: Double?
    let spareAvailablePercent: Double?
    let numDieFailures: UInt64?
    let grownBadBlocks: UInt64?
    let factoryBadBlocks: UInt64?
    let bandCount: UInt64?
    /// Controller-reported values from the text snapshot. Their relationship
    /// to the NVMe SMART Percentage Used field is not assumed.
    let controllerPercentUsed: Double?
    let slcPercentUsed: Double?
    let oslcTransitions: UInt64?
    let oslcBaseAveragePE: Double?
    /// Raw ASP counters. Their storage unit is intentionally unverified.
    let hostAutoWrites: UInt64?
    let hostAutoWriteTransactions: UInt64?
    /// Raw key 84 from the direct FTL payload. The unit and accumulation
    /// range are not verified; it is never converted into P/E by itself.
    let intermediateBandErases: UInt64?
    let intermediateBandsProgrammed: UInt64?
    let userBandsProgrammed: UInt64?
    let intermediateNandWrites: UInt64?
    let userNandWrites: UInt64?
    let performanceUserErases: UInt64?
    let performanceIntermediateErases: UInt64?
    /// Raw scalar observations for the proposed 25G83 Host-write composition
    /// keys. Their labels are not accepted as semantics until paired
    /// asptool captures prove the sum invariant, so they never feed Host
    /// Writes, WAF, or any forecast.
    let hostWriteCompositionCandidateKey5: UInt64?
    let hostWriteCompositionCandidateKey6: UInt64?
    let hostWriteCompositionCandidateKey27: UInt64?
    let numberOfTLCPages: UInt64?
    /// Populated only after the private binary format version is verified.
    let directFormatVersion: UInt32?
    /// A reviewed semantic key contract for a private Direct FTL buffer. This
    /// is independent of the opaque buffer format and remains optional so
    /// historical snapshots can be decoded without inventing a contract.
    var directKeyContractVersion: String?
    /// Direct partition topology decoded only when the reviewed key contract,
    /// record shape, and overflow checks all succeeded.
    var directTopology: DirectFTLTopology?
    /// Optional Direct FTL research telemetry. It is preserved as raw
    /// counters/histograms for reliability evidence and is never used as a
    /// TBW multiplier.
    let researchTelemetry: FTLResearchTelemetrySnapshot?
    /// Fixed explanations from the parser; almost every record repeats the
    /// same list. `ASPToolSnapshotStore` shares equal lists in memory.
    var parseWarnings: [String]

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        captureQuality: ASPToolCaptureQuality = .unknown,
        deviceID: String? = nil,
        sourceName: String = "asptool.log",
        sourceArtifact: ASPToolSourceArtifact = .extractedASPTool,
        sourceBuild: String? = nil,
        contractBuild: String? = nil,
        probeVersion: Int? = nil,
        runtimeBuildProvenance: BuildProvenance? = nil,
        extractionVersion: Int = 1,
        historySchemaVersion: Int? = 2,
        semanticContractVersion: String? = nil,
        coreWearContractVersion: String? = nil,
        researchTelemetryContractVersion: String? = nil,
        identityCapturedAt: Date? = nil,
        observationBlockCount: Int = 0,
        hostWrites: UInt64? = nil,
        nandWrites: UInt64? = nil,
        hostWritesUnitState: ASPToolUnitState = .provisional4KiB,
        nandWritesUnitState: ASPToolUnitState = .provisional4KiB,
        tlcAveragePE: Double? = nil,
        tlcMinimumPE: Double? = nil,
        tlcMaximumPE: Double? = nil,
        tlcEOLPE: Double? = nil,
        slcAveragePE: Double? = nil,
        slcMinimumPE: Double? = nil,
        slcMaximumPE: Double? = nil,
        slcEOLPE: Double? = nil,
        powerOnHours: UInt64? = nil,
        firmware: String? = nil,
        mspVersion: String? = nil,
        chipID: String? = nil,
        writeAmp: Double? = nil,
        intermediateWriteAmp: Double? = nil,
        spareAvailablePercent: Double? = nil,
        numDieFailures: UInt64? = nil,
        grownBadBlocks: UInt64? = nil,
        factoryBadBlocks: UInt64? = nil,
        bandCount: UInt64? = nil,
        controllerPercentUsed: Double? = nil,
        slcPercentUsed: Double? = nil,
        oslcTransitions: UInt64? = nil,
        oslcBaseAveragePE: Double? = nil,
        hostAutoWrites: UInt64? = nil,
        hostAutoWriteTransactions: UInt64? = nil,
        intermediateBandErases: UInt64? = nil,
        intermediateBandsProgrammed: UInt64? = nil,
        userBandsProgrammed: UInt64? = nil,
        intermediateNandWrites: UInt64? = nil,
        userNandWrites: UInt64? = nil,
        performanceUserErases: UInt64? = nil,
        performanceIntermediateErases: UInt64? = nil,
        hostWriteCompositionCandidateKey5: UInt64? = nil,
        hostWriteCompositionCandidateKey6: UInt64? = nil,
        hostWriteCompositionCandidateKey27: UInt64? = nil,
        numberOfTLCPages: UInt64? = nil,
        directFormatVersion: UInt32? = nil,
        directKeyContractVersion: String? = nil,
        directTopology: DirectFTLTopology? = nil,
        researchTelemetry: FTLResearchTelemetrySnapshot? = nil,
        parseWarnings: [String] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.captureQuality = captureQuality
        self.deviceID = deviceID
        self.sourceName = sourceName
        self.sourceArtifact = sourceArtifact
        self.sourceBuild = sourceBuild
        self.contractBuild = contractBuild
        self.probeVersion = probeVersion
        self.runtimeBuildProvenance = runtimeBuildProvenance
        self.extractionVersion = extractionVersion
        self.historySchemaVersion = historySchemaVersion
        self.semanticContractVersion = semanticContractVersion
        self.coreWearContractVersion = coreWearContractVersion
        self.researchTelemetryContractVersion = researchTelemetryContractVersion
        self.identityCapturedAt = identityCapturedAt
        self.observationBlockCount = max(0, observationBlockCount)
        self.hostWrites = hostWrites
        self.nandWrites = nandWrites
        self.hostWritesUnitState = hostWrites == nil ? .unavailable : hostWritesUnitState
        self.nandWritesUnitState = nandWrites == nil ? .unavailable : nandWritesUnitState
        self.tlcAveragePE = tlcAveragePE
        self.tlcMinimumPE = tlcMinimumPE
        self.tlcMaximumPE = tlcMaximumPE
        self.tlcEOLPE = tlcEOLPE
        self.slcAveragePE = slcAveragePE
        self.slcMinimumPE = slcMinimumPE
        self.slcMaximumPE = slcMaximumPE
        self.slcEOLPE = slcEOLPE
        self.powerOnHours = powerOnHours
        self.firmware = firmware
        self.mspVersion = mspVersion
        self.chipID = chipID
        self.writeAmp = writeAmp
        self.intermediateWriteAmp = intermediateWriteAmp
        self.spareAvailablePercent = spareAvailablePercent
        self.numDieFailures = numDieFailures
        self.grownBadBlocks = grownBadBlocks
        self.factoryBadBlocks = factoryBadBlocks
        self.bandCount = bandCount
        self.controllerPercentUsed = controllerPercentUsed
        self.slcPercentUsed = slcPercentUsed
        self.oslcTransitions = oslcTransitions
        self.oslcBaseAveragePE = oslcBaseAveragePE
        self.hostAutoWrites = hostAutoWrites
        self.hostAutoWriteTransactions = hostAutoWriteTransactions
        self.intermediateBandErases = intermediateBandErases
        self.intermediateBandsProgrammed = intermediateBandsProgrammed
        self.userBandsProgrammed = userBandsProgrammed
        self.intermediateNandWrites = intermediateNandWrites
        self.userNandWrites = userNandWrites
        self.performanceUserErases = performanceUserErases
        self.performanceIntermediateErases = performanceIntermediateErases
        self.hostWriteCompositionCandidateKey5 = hostWriteCompositionCandidateKey5
        self.hostWriteCompositionCandidateKey6 = hostWriteCompositionCandidateKey6
        self.hostWriteCompositionCandidateKey27 = hostWriteCompositionCandidateKey27
        self.numberOfTLCPages = numberOfTLCPages
        self.directFormatVersion = directFormatVersion
        self.directKeyContractVersion = directKeyContractVersion
        self.directTopology = directTopology
        self.researchTelemetry = researchTelemetry
        self.parseWarnings = parseWarnings
    }

    var hostWrittenBytes: Double? {
        guard let hostWrites, let unitBytes = hostWritesUnitState.unitBytes else { return nil }
        return Double(hostWrites) * unitBytes
    }

    var nandWrittenBytes: Double? {
        guard let nandWrites, let unitBytes = nandWritesUnitState.unitBytes else { return nil }
        return Double(nandWrites) * unitBytes
    }

    var writeAmplification: Double? {
        guard let hostWrittenBytes, hostWrittenBytes > 0,
              let nandWrittenBytes, nandWrittenBytes >= 0
        else { return nil }
        return nandWrittenBytes / hostWrittenBytes
    }

    /// Resolved versions are compatibility accessors. They use explicit
    /// fields from new captures and derive reviewed legacy versions when an
    /// older JSON record has no split-contract fields.
    var resolvedCoreWearVersion: String? {
        DirectFTLResearchContract.coreWearVersion(for: self)
    }

    var resolvedResearchTelemetryVersion: String? {
        DirectFTLResearchContract.researchTelemetryVersion(for: self)
    }

    var firmwareEpoch: String? {
        let firmware = firmware?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let msp = mspVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch (firmware, msp) {
        case let (.some(firmware), .some(msp)):
            return "\(firmware)|\(msp)"
        case let (.some(firmware), .none):
            return firmware
        case let (.none, .some(msp)):
            return msp
        case (.none, .none):
            return nil
        }
    }

    var hasControllerWearData: Bool {
        (tlcAveragePE != nil || slcAveragePE != nil) &&
            (tlcEOLPE != nil || slcEOLPE != nil)
    }

    /// Creates an in-memory analysis view only. Persisted raw snapshots are
    /// never rewritten when a shared topology is supplied after a verified
    /// asptool-to-Direct boundary.
    func analysisCopy(overridingTopology topology: DirectFTLTopology) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            id: id, capturedAt: capturedAt, captureQuality: captureQuality,
            deviceID: deviceID, sourceName: sourceName, sourceArtifact: sourceArtifact,
            sourceBuild: sourceBuild, contractBuild: contractBuild, probeVersion: probeVersion,
            runtimeBuildProvenance: runtimeBuildProvenance, extractionVersion: extractionVersion,
            historySchemaVersion: historySchemaVersion, semanticContractVersion: semanticContractVersion,
            coreWearContractVersion: coreWearContractVersion,
            researchTelemetryContractVersion: researchTelemetryContractVersion,
            identityCapturedAt: identityCapturedAt, observationBlockCount: observationBlockCount,
            hostWrites: hostWrites, nandWrites: nandWrites,
            hostWritesUnitState: hostWritesUnitState, nandWritesUnitState: nandWritesUnitState,
            tlcAveragePE: tlcAveragePE, tlcMinimumPE: tlcMinimumPE, tlcMaximumPE: tlcMaximumPE,
            tlcEOLPE: tlcEOLPE, slcAveragePE: slcAveragePE, slcMinimumPE: slcMinimumPE,
            slcMaximumPE: slcMaximumPE, slcEOLPE: slcEOLPE, powerOnHours: powerOnHours,
            firmware: firmware, mspVersion: mspVersion, chipID: chipID,
            writeAmp: writeAmp, intermediateWriteAmp: intermediateWriteAmp,
            spareAvailablePercent: spareAvailablePercent, numDieFailures: numDieFailures,
            grownBadBlocks: grownBadBlocks, factoryBadBlocks: factoryBadBlocks, bandCount: bandCount,
            controllerPercentUsed: controllerPercentUsed, slcPercentUsed: slcPercentUsed,
            oslcTransitions: oslcTransitions, oslcBaseAveragePE: oslcBaseAveragePE,
            hostAutoWrites: hostAutoWrites, hostAutoWriteTransactions: hostAutoWriteTransactions,
            intermediateBandErases: intermediateBandErases,
            intermediateBandsProgrammed: intermediateBandsProgrammed,
            userBandsProgrammed: userBandsProgrammed, intermediateNandWrites: intermediateNandWrites,
            userNandWrites: userNandWrites, performanceUserErases: performanceUserErases,
            performanceIntermediateErases: performanceIntermediateErases,
            hostWriteCompositionCandidateKey5: hostWriteCompositionCandidateKey5,
            hostWriteCompositionCandidateKey6: hostWriteCompositionCandidateKey6,
            hostWriteCompositionCandidateKey27: hostWriteCompositionCandidateKey27,
            numberOfTLCPages: numberOfTLCPages, directFormatVersion: directFormatVersion,
            directKeyContractVersion: directKeyContractVersion,
            directTopology: directTopology ?? topology, researchTelemetry: researchTelemetry,
            parseWarnings: parseWarnings
        )
    }
}

struct ASPToolSnapshotParseResult: Equatable, Sendable {
    let snapshot: ASPToolDiagnosticsSnapshot
    let recognizedKeys: Set<String>
}

enum ASPToolSnapshotParserError: LocalizedError, Equatable, Sendable {
    case invalidEncoding
    case noRecognizedValues
    case lineTooLong
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "asptoolのログをUTF-8テキストとして読み取れませんでした"
        case .noRecognizedValues:
            return "asptoolの既知の項目を見つけられませんでした"
        case .lineTooLong:
            return UIString.text("asptoolログの1行が長すぎます（上限1 MiB）")
        case .fileTooLarge:
            return UIString.text("asptoolログが大きすぎます（上限512 MiB）")
        }
    }
}

struct ASPToolSnapshotParser: Sendable {
    private static let maximumLineBytes = 1 * 1_024 * 1_024
    static let maximumFileBytes = 512 * 1_024 * 1_024
    func parse(
        data: Data,
        capturedAt: Date,
        captureQuality: ASPToolCaptureQuality = .unknown,
        deviceID: String? = nil,
        sourceName: String = "asptool.log",
        sourceArtifact: ASPToolSourceArtifact = .extractedASPTool,
        unitState: ASPToolUnitState = .provisional4KiB
    ) throws -> ASPToolSnapshotParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ASPToolSnapshotParserError.invalidEncoding
        }
        return try parse(
            text: text,
            capturedAt: capturedAt,
            captureQuality: captureQuality,
            deviceID: deviceID,
            sourceName: sourceName,
            sourceArtifact: sourceArtifact,
            unitState: unitState
        )
    }

    /// Parses an asptool source without materializing the complete log in a
    /// String or retaining every line. Only the last recognized counter and a
    /// bounded partition summary are kept in memory.
    func parse(
        fileURL: URL,
        capturedAt: Date,
        captureQuality: ASPToolCaptureQuality = .unknown,
        deviceID: String? = nil,
        sourceName: String = "asptool.log",
        sourceArtifact: ASPToolSourceArtifact = .extractedASPTool,
        unitState: ASPToolUnitState = .provisional4KiB
    ) throws -> ASPToolSnapshotParseResult {
        try Task<Never, Never>.checkCancellation()
        if let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > Self.maximumFileBytes {
            throw ASPToolSnapshotParserError.fileTooLarge
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var state = StreamingState()
        var pending = Data()
        var bytesRead = 0

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task<Never, Never>.checkCancellation()
            guard bytesRead <= Self.maximumFileBytes - chunk.count else {
                throw ASPToolSnapshotParserError.fileTooLarge
            }
            bytesRead += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                try Task<Never, Never>.checkCancellation()
                guard newline <= Self.maximumLineBytes else {
                    throw ASPToolSnapshotParserError.lineTooLong
                }
                let lineData = pending.subdata(in: 0..<newline)
                pending.removeSubrange(0...newline)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw ASPToolSnapshotParserError.invalidEncoding
                }
                state.consume(line: line)
            }
            guard pending.count <= Self.maximumLineBytes else {
                throw ASPToolSnapshotParserError.lineTooLong
            }
        }

        if !pending.isEmpty {
            guard let line = String(data: pending, encoding: .utf8) else {
                throw ASPToolSnapshotParserError.invalidEncoding
            }
            state.consume(line: line)
        }

        return try state.result(
            capturedAt: capturedAt,
            captureQuality: captureQuality,
            deviceID: deviceID,
            sourceName: sourceName,
            sourceArtifact: sourceArtifact,
            unitState: unitState
        )
    }

    func parse(
        text: String,
        capturedAt: Date,
        captureQuality: ASPToolCaptureQuality = .unknown,
        deviceID: String? = nil,
        sourceName: String = "asptool.log",
        sourceArtifact: ASPToolSourceArtifact = .extractedASPTool,
        unitState: ASPToolUnitState = .provisional4KiB
    ) throws -> ASPToolSnapshotParseResult {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let blockCount = lines.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "NAND stats:" }.count

        let knownNumericKeys = [
            "hostWrites", "nandWrites", "powerOnHours", "averageTLCPECycles",
            "averageSLCPECycles", "WriteAmp", "IntermediateWriteAmp",
            "spareAvailablePercent", "numDieFailures", "Grown Bad Blocks Count",
            "Factory Bad Blocks Count", "bandCount", "percentUsed", "slcPercentUsed",
            "oslcTransitions", "oslcBaseAvgPE", "hostAutoWrites", "hostAutoWriteXacts",
            "RxBurnIntBandsProgrammed", "RxBurnUsrBandsProgrammed",
            "RxBurnIntNandWrites", "RxBurnUsrNandWrites", "perfUserErases",
            "perfIntErases", "numTLC_pgs"
        ]
        var recognizedKeys = Set<String>()

        func uint(_ key: String) -> UInt64? {
            if key == "bandCount",
               let value = lines.reversed().compactMap({ bandCount(in: $0) }).first {
                recognizedKeys.insert(key)
                return value
            }
            guard let value = lastNumericValue(for: key, lines: lines, as: UInt64.self) else { return nil }
            recognizedKeys.insert(key)
            return value
        }

        func double(_ key: String) -> Double? {
            guard let value = lastNumericValue(for: key, lines: lines, as: Double.self) else { return nil }
            recognizedKeys.insert(key)
            return value
        }

        func positiveDouble(_ key: String) -> Double? {
            guard let value = lastPositiveNumericValue(for: key, lines: lines) else { return nil }
            recognizedKeys.insert(key)
            return value
        }

        let intermediate = eraseSummary(for: "INTERMEDIATE", lines: lines)
        let user = eraseSummary(for: "USER", lines: lines)
        if intermediate.eol != nil { recognizedKeys.insert("INTERMEDIATE EoL erase cycles") }
        if user.eol != nil { recognizedKeys.insert("USER EoL erase cycles") }
        if intermediate.average != nil { recognizedKeys.insert("INTERMEDIATE average erase cycles") }
        if user.average != nil { recognizedKeys.insert("USER average erase cycles") }

        let hostWrites = uint("hostWrites")
        let nandWrites = uint("nandWrites")
        let tlcAverage = double("averageTLCPECycles") ?? user.average
        let slcAverage = double("averageSLCPECycles") ?? intermediate.average
        let controllerPercentUsed = double("percentUsed")
        let slcPercentUsed = double("slcPercentUsed")
        let oslcTransitions = uint("oslcTransitions")
        let oslcBaseAveragePE = double("oslcBaseAvgPE")
        let hostAutoWrites = uint("hostAutoWrites")
        let hostAutoWriteTransactions = uint("hostAutoWriteXacts")
        let intermediateBandsProgrammed = uint("RxBurnIntBandsProgrammed")
        let userBandsProgrammed = uint("RxBurnUsrBandsProgrammed")
        let intermediateNandWrites = uint("RxBurnIntNandWrites")
        let userNandWrites = uint("RxBurnUsrNandWrites")
        let performanceUserErases = uint("perfUserErases")
        let performanceIntermediateErases = uint("perfIntErases")
        let numberOfTLCPages = uint("numTLC_pgs")
        let recognizedNumericKeyCount = knownNumericKeys.reduce(into: 0) { count, key in
            if recognizedKeys.contains(key) { count += 1 }
        }

        guard recognizedNumericKeyCount > 0 || !recognizedKeys.isEmpty else {
            throw ASPToolSnapshotParserError.noRecognizedValues
        }

        var warnings: [String] = []
        if blockCount == 0 {
            warnings.append("NAND statsブロックを検出できませんでした")
        }
        if hostWrites != nil {
            warnings.append(Self.hostWritesUnitWarning(for: unitState))
        } else {
            warnings.append("hostWritesが未取得です")
        }
        if nandWrites == nil {
            warnings.append("nandWritesが未取得です")
        }
        if intermediateNandWrites != nil || userNandWrites != nil || hostAutoWrites != nil {
            warnings.append("ASP内部書込カウンタは単位未確認のため容量・寿命予測へ投入していません")
        }
        if captureQuality == .unknown {
            warnings.append("取得時刻の品質が未確認です")
        }

        let snapshot = ASPToolDiagnosticsSnapshot(
            capturedAt: capturedAt,
            captureQuality: captureQuality,
            deviceID: deviceID,
            sourceName: sourceName,
            sourceArtifact: sourceArtifact,
            observationBlockCount: blockCount,
            hostWrites: hostWrites,
            nandWrites: nandWrites,
            hostWritesUnitState: hostWrites == nil ? .unavailable : unitState,
            nandWritesUnitState: nandWrites == nil ? .unavailable : unitState,
            tlcAveragePE: tlcAverage,
            tlcMinimumPE: user.minimum,
            tlcMaximumPE: user.maximum,
            tlcEOLPE: user.eol,
            slcAveragePE: slcAverage,
            slcMinimumPE: intermediate.minimum,
            slcMaximumPE: intermediate.maximum,
            slcEOLPE: intermediate.eol,
            powerOnHours: uint("powerOnHours"),
            firmware: nil,
            mspVersion: nil,
            chipID: nil,
            writeAmp: positiveDouble("WriteAmp"),
            intermediateWriteAmp: positiveDouble("IntermediateWriteAmp"),
            spareAvailablePercent: double("spareAvailablePercent"),
            numDieFailures: uint("numDieFailures"),
            grownBadBlocks: uint("Grown Bad Blocks Count"),
            factoryBadBlocks: uint("Factory Bad Blocks Count"),
            bandCount: uint("bandCount"),
            controllerPercentUsed: controllerPercentUsed,
            slcPercentUsed: slcPercentUsed,
            oslcTransitions: oslcTransitions,
            oslcBaseAveragePE: oslcBaseAveragePE,
            hostAutoWrites: hostAutoWrites,
            hostAutoWriteTransactions: hostAutoWriteTransactions,
            intermediateBandsProgrammed: intermediateBandsProgrammed,
            userBandsProgrammed: userBandsProgrammed,
            intermediateNandWrites: intermediateNandWrites,
            userNandWrites: userNandWrites,
            performanceUserErases: performanceUserErases,
            performanceIntermediateErases: performanceIntermediateErases,
            numberOfTLCPages: numberOfTLCPages,
            parseWarnings: warnings
        )

        return ASPToolSnapshotParseResult(snapshot: snapshot, recognizedKeys: recognizedKeys)
    }

    private static func hostWritesUnitWarning(for unitState: ASPToolUnitState) -> String {
        switch unitState {
        case .verified:
            return "hostWritesは検証済み4 KiB単位です"
        case .provisional4KiB:
            return "hostWritesは4 KiB換算の暫定値です"
        case .unverified:
            return "hostWritesは取得済みですが単位未確認です"
        case .unavailable:
            return "hostWritesの単位は利用不可です"
        }
    }

    private struct StreamingPartitionSummary {
        var minimum: Double?
        var maximum: Double?
        var average: Double?
        var eol: Double?
    }

    private struct PendingPartitionEOL {
        let partition: String
        var remainingLines: Int
    }

    private struct StreamingState {
        private static let knownNumericKeys = [
            "hostWrites", "nandWrites", "powerOnHours", "averageTLCPECycles",
            "averageSLCPECycles", "WriteAmp", "IntermediateWriteAmp",
            "spareAvailablePercent", "numDieFailures", "Grown Bad Blocks Count",
            "Factory Bad Blocks Count", "bandCount", "percentUsed", "slcPercentUsed",
            "oslcTransitions", "oslcBaseAvgPE", "hostAutoWrites", "hostAutoWriteXacts",
            "RxBurnIntBandsProgrammed", "RxBurnUsrBandsProgrammed",
            "RxBurnIntNandWrites", "RxBurnUsrNandWrites", "perfUserErases",
            "perfIntErases", "numTLC_pgs"
        ]

        private(set) var blockCount = 0
        private var numericTokens: [String: String] = [:]
        private var positiveValues: [String: Double] = [:]
        private var partitionSummaries: [String: StreamingPartitionSummary] = [:]
        private var pendingPartitionEOL: PendingPartitionEOL?

        mutating func consume(line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "NAND stats:" {
                blockCount += 1
            }

            if let bandCount = Self.bandCount(in: trimmed) {
                numericTokens["bandCount"] = String(bandCount)
            }

            if let pending = pendingPartitionEOL {
                if line.contains("EoL erase cycles:") {
                    var summary = partitionSummaries[pending.partition] ?? StreamingPartitionSummary(
                        minimum: nil,
                        maximum: nil,
                        average: nil,
                        eol: nil
                    )
                    summary.eol = Self.firstNumericToken(
                        after: "EoL erase cycles:",
                        in: line
                    ).flatMap(Double.init)
                    partitionSummaries[pending.partition] = summary
                    pendingPartitionEOL = nil
                } else if line.contains("PARTITION") && line.contains("Erase Cycles:") {
                    pendingPartitionEOL = nil
                } else if pending.remainingLines <= 1 {
                    pendingPartitionEOL = nil
                } else {
                    pendingPartitionEOL = PendingPartitionEOL(
                        partition: pending.partition,
                        remainingLines: pending.remainingLines - 1
                    )
                }
            }

            if let partition = partitionName(in: line), line.contains("Erase Cycles:") {
                partitionSummaries[partition] = StreamingPartitionSummary(
                    minimum: Self.number(after: "Min (", in: line),
                    maximum: Self.number(after: "Max (", in: line),
                    average: Self.number(after: "Avg (", in: line),
                    eol: nil
                )
                pendingPartitionEOL = PendingPartitionEOL(
                    partition: partition,
                    remainingLines: 4
                )
            }

            guard let separator = trimmed.firstIndex(of: ":") else { return }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard Self.knownNumericKeys.contains(name) else { return }
            let rawValue = trimmed[trimmed.index(after: separator)...]
            guard let token = Self.firstNumericToken(String(rawValue)) else { return }
            guard Double(token)?.isFinite == true else { return }

            numericTokens[name] = token
            if let value = Double(token), value > 0 {
                positiveValues[name] = value
            }
        }

        func result(
            capturedAt: Date,
            captureQuality: ASPToolCaptureQuality,
            deviceID: String?,
            sourceName: String,
            sourceArtifact: ASPToolSourceArtifact,
            unitState: ASPToolUnitState
        ) throws -> ASPToolSnapshotParseResult {
            var recognizedKeys = Set<String>()

            func uint(_ key: String) -> UInt64? {
                guard let token = numericTokens[key], let value = UInt64(token) else { return nil }
                recognizedKeys.insert(key)
                return value
            }

            func double(_ key: String) -> Double? {
                guard let token = numericTokens[key], let value = Double(token) else { return nil }
                recognizedKeys.insert(key)
                return value
            }

            func positiveDouble(_ key: String) -> Double? {
                guard let value = positiveValues[key] else { return nil }
                recognizedKeys.insert(key)
                return value
            }

            let intermediate = partitionSummaries["INTERMEDIATE"] ?? StreamingPartitionSummary(
                minimum: nil,
                maximum: nil,
                average: nil,
                eol: nil
            )
            let user = partitionSummaries["USER"] ?? StreamingPartitionSummary(
                minimum: nil,
                maximum: nil,
                average: nil,
                eol: nil
            )
            if intermediate.eol != nil { recognizedKeys.insert("INTERMEDIATE EoL erase cycles") }
            if user.eol != nil { recognizedKeys.insert("USER EoL erase cycles") }
            if intermediate.average != nil { recognizedKeys.insert("INTERMEDIATE average erase cycles") }
            if user.average != nil { recognizedKeys.insert("USER average erase cycles") }

            let hostWrites = uint("hostWrites")
            let nandWrites = uint("nandWrites")
            let tlcAverage = double("averageTLCPECycles") ?? user.average
            let slcAverage = double("averageSLCPECycles") ?? intermediate.average
            let controllerPercentUsed = double("percentUsed")
            let slcPercentUsed = double("slcPercentUsed")
            let oslcTransitions = uint("oslcTransitions")
            let oslcBaseAveragePE = double("oslcBaseAvgPE")
            let hostAutoWrites = uint("hostAutoWrites")
            let hostAutoWriteTransactions = uint("hostAutoWriteXacts")
            let intermediateBandsProgrammed = uint("RxBurnIntBandsProgrammed")
            let userBandsProgrammed = uint("RxBurnUsrBandsProgrammed")
            let intermediateNandWrites = uint("RxBurnIntNandWrites")
            let userNandWrites = uint("RxBurnUsrNandWrites")
            let performanceUserErases = uint("perfUserErases")
            let performanceIntermediateErases = uint("perfIntErases")
            let numberOfTLCPages = uint("numTLC_pgs")
            let recognizedNumericKeyCount = Self.knownNumericKeys.reduce(into: 0) { count, key in
                if recognizedKeys.contains(key) { count += 1 }
            }

            guard recognizedNumericKeyCount > 0 || !recognizedKeys.isEmpty else {
                throw ASPToolSnapshotParserError.noRecognizedValues
            }

            var warnings: [String] = []
            if blockCount == 0 {
                warnings.append("NAND statsブロックを検出できませんでした")
            }
            if hostWrites != nil {
                warnings.append(ASPToolSnapshotParser.hostWritesUnitWarning(for: unitState))
            } else {
                warnings.append("hostWritesが未取得です")
            }
            if nandWrites == nil {
                warnings.append("nandWritesが未取得です")
            }
            if intermediateNandWrites != nil || userNandWrites != nil || hostAutoWrites != nil {
                warnings.append("ASP内部書込カウンタは単位未確認のため容量・寿命予測へ投入していません")
            }
            if captureQuality == .unknown {
                warnings.append("取得時刻の品質が未確認です")
            }

            let snapshot = ASPToolDiagnosticsSnapshot(
                capturedAt: capturedAt,
                captureQuality: captureQuality,
                deviceID: deviceID,
                sourceName: sourceName,
                sourceArtifact: sourceArtifact,
                observationBlockCount: blockCount,
                hostWrites: hostWrites,
                nandWrites: nandWrites,
                hostWritesUnitState: hostWrites == nil ? .unavailable : unitState,
                nandWritesUnitState: nandWrites == nil ? .unavailable : unitState,
                tlcAveragePE: tlcAverage,
                tlcMinimumPE: user.minimum,
                tlcMaximumPE: user.maximum,
                tlcEOLPE: user.eol,
                slcAveragePE: slcAverage,
                slcMinimumPE: intermediate.minimum,
                slcMaximumPE: intermediate.maximum,
                slcEOLPE: intermediate.eol,
                powerOnHours: uint("powerOnHours"),
                firmware: nil,
                mspVersion: nil,
                chipID: nil,
                writeAmp: positiveDouble("WriteAmp"),
                intermediateWriteAmp: positiveDouble("IntermediateWriteAmp"),
                spareAvailablePercent: double("spareAvailablePercent"),
                numDieFailures: uint("numDieFailures"),
                grownBadBlocks: uint("Grown Bad Blocks Count"),
                factoryBadBlocks: uint("Factory Bad Blocks Count"),
                bandCount: uint("bandCount"),
                controllerPercentUsed: controllerPercentUsed,
                slcPercentUsed: slcPercentUsed,
                oslcTransitions: oslcTransitions,
                oslcBaseAveragePE: oslcBaseAveragePE,
                hostAutoWrites: hostAutoWrites,
                hostAutoWriteTransactions: hostAutoWriteTransactions,
                intermediateBandsProgrammed: intermediateBandsProgrammed,
                userBandsProgrammed: userBandsProgrammed,
                intermediateNandWrites: intermediateNandWrites,
                userNandWrites: userNandWrites,
                performanceUserErases: performanceUserErases,
                performanceIntermediateErases: performanceIntermediateErases,
                numberOfTLCPages: numberOfTLCPages,
                parseWarnings: warnings
            )
            return ASPToolSnapshotParseResult(snapshot: snapshot, recognizedKeys: recognizedKeys)
        }

        private func partitionName(in line: String) -> String? {
            if line.contains("INTERMEDIATE PARTITION") { return "INTERMEDIATE" }
            if line.contains("USER PARTITION") { return "USER" }
            return nil
        }

        private static func number(after marker: String, in line: String) -> Double? {
            firstNumericToken(after: marker, in: line).flatMap(Double.init)
        }

        private static func firstNumericToken(after marker: String, in line: String) -> String? {
            guard let range = line.range(of: marker) else { return nil }
            return firstNumericToken(String(line[range.upperBound...]))
        }

        private static func firstNumericToken(_ value: String) -> String? {
            let characters = Array(value)
            guard let start = characters.firstIndex(where: { $0.isNumber || $0 == "-" }) else {
                return nil
            }
            var end = start
            var decimalPointSeen = false
            while end < characters.count {
                let character = characters[end]
                if character.isNumber || character == "-" && end == start {
                    end += 1
                } else if character == "." && !decimalPointSeen {
                    decimalPointSeen = true
                    end += 1
                } else {
                    break
                }
            }
            return String(characters[start..<end])
        }

        private static func bandCount(in line: String) -> UInt64? {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix("numBands:") {
                return firstNumericToken(
                    String(normalized.dropFirst("numBands:".count))
                ).flatMap(UInt64.init)
            }
            guard normalized.hasSuffix(" bands") else { return nil }
            let prefix = String(normalized.dropLast(" bands".count))
            guard !prefix.isEmpty,
                  prefix.allSatisfy(\.isNumber),
                  let value = UInt64(prefix)
            else { return nil }
            return value
        }
    }

    private func lastNumericValue<T: LosslessStringConvertible>(
        for key: String,
        lines: [String],
        as type: T.Type
    ) -> T? {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            let rawValue = trimmed[trimmed.index(after: separator)...]
            guard let token = firstNumericToken(String(rawValue)),
                  let value = T(token)
            else { continue }
            return value
        }
        return nil
    }

    private func firstNumericToken(_ value: String) -> String? {
        let characters = Array(value)
        guard let start = characters.firstIndex(where: { $0.isNumber || $0 == "-" }) else {
            return nil
        }
        var end = start
        var decimalPointSeen = false
        while end < characters.count {
            let character = characters[end]
            if character.isNumber || character == "-" && end == start {
                end += 1
            } else if character == "." && !decimalPointSeen {
                decimalPointSeen = true
                end += 1
            } else {
                break
            }
        }
        return String(characters[start..<end])
    }

    private func bandCount(in line: String) -> UInt64? {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("numBands:") {
            return firstNumericToken(
                String(normalized.dropFirst("numBands:".count))
            ).flatMap(UInt64.init)
        }
        guard normalized.hasSuffix(" bands") else { return nil }
        let prefix = String(normalized.dropLast(" bands".count))
        guard !prefix.isEmpty,
              prefix.allSatisfy(\.isNumber),
              let value = UInt64(prefix)
        else { return nil }
        return value
    }

    private func lastPositiveNumericValue(for key: String, lines: [String]) -> Double? {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            let rawValue = trimmed[trimmed.index(after: separator)...]
            guard let token = firstNumericToken(String(rawValue)),
                  let value = Double(token),
                  value.isFinite,
                  value > 0
            else { continue }
            return value
        }
        return nil
    }

    private func eraseSummary(
        for partition: String,
        lines: [String]
    ) -> (minimum: Double?, maximum: Double?, average: Double?, eol: Double?) {
        for index in lines.indices {
            let line = lines[index]
            guard line.contains("\(partition) PARTITION"), line.contains("Erase Cycles:") else { continue }
            let maximum = number(after: "Max (", in: line)
            let minimum = number(after: "Min (", in: line)
            let average = number(after: "Avg (", in: line)
            var eol: Double?
            for nextIndex in (index + 1)..<min(index + 5, lines.count) {
                let nextLine = lines[nextIndex]
                if nextLine.contains("EoL erase cycles:") {
                    eol = firstNumericToken(after: "EoL erase cycles:", in: nextLine).flatMap(Double.init)
                    break
                }
                if nextLine.contains("PARTITION") && nextLine.contains("Erase Cycles:") {
                    break
                }
            }
            return (minimum, maximum, average, eol)
        }
        return (nil, nil, nil, nil)
    }

    private func number(after marker: String, in line: String) -> Double? {
        firstNumericToken(after: marker, in: line).flatMap(Double.init)
    }

    private func firstNumericToken(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return firstNumericToken(String(line[range.upperBound...]))
    }
}

enum ControllerEOLState: String, Codable, Equatable, Sendable {
    case unavailable
    case collecting
    case estimated

    var title: String {
        switch self {
        case .unavailable: return "未取得"
        case .collecting: return "観測中"
        case .estimated: return "推定"
        }
    }
}

enum ControllerWearMedium: String, Codable, Equatable, Sendable {
    case tlc
    case slc
    case unknown

    var title: String {
        switch self {
        case .tlc: return "TLC"
        case .slc: return "SLC"
        case .unknown: return "不明"
        }
    }
}

enum ControllerProjectionKind: String, Codable, Equatable, Sendable {
    case none
    case singleSnapshot
    case intervalSlope

    var title: String {
        switch self {
        case .none: return "未算出"
        case .singleSnapshot: return "単一snapshot・到達日なし"
        case .intervalSlope: return "時系列P/E区間"
        }
    }
}

struct ControllerEOLForecast: Equatable, Sendable {
    let state: ControllerEOLState
    let message: String
    let currentHostWrittenBytes: Double?
    let currentTLCPE: Double?
    let currentTLCEOLPE: Double?
    let currentSLCPE: Double?
    let currentSLCEOLPE: Double?
    let projectedTLCEnduranceBytes: Double?
    let projectedSLCEnduranceBytes: Double?
    let estimatedEnduranceBytes: Double?
    let remainingHostWriteBytes: Double?
    let lowerDate: Date?
    let upperDate: Date?
    let limitingMedium: ControllerWearMedium
    let unitState: ASPToolUnitState
    let projection: ControllerProjectionKind
    let confidence: ForecastConfidence
    let confidenceScore: Int
    let snapshotCount: Int
    let intervalCount: Int
    let observationDays: Double
    let basis: String

    init(
        state: ControllerEOLState = .unavailable,
        message: String = "物理P/E snapshotを取得していません",
        currentHostWrittenBytes: Double? = nil,
        currentTLCPE: Double? = nil,
        currentTLCEOLPE: Double? = nil,
        currentSLCPE: Double? = nil,
        currentSLCEOLPE: Double? = nil,
        projectedTLCEnduranceBytes: Double? = nil,
        projectedSLCEnduranceBytes: Double? = nil,
        estimatedEnduranceBytes: Double? = nil,
        remainingHostWriteBytes: Double? = nil,
        lowerDate: Date? = nil,
        upperDate: Date? = nil,
        limitingMedium: ControllerWearMedium = .unknown,
        unitState: ASPToolUnitState = .unavailable,
        projection: ControllerProjectionKind = .none,
        confidence: ForecastConfidence = .veryLow,
        confidenceScore: Int = 0,
        snapshotCount: Int = 0,
        intervalCount: Int = 0,
        observationDays: Double = 0,
        basis: String = ""
    ) {
        self.state = state
        self.message = message
        self.currentHostWrittenBytes = currentHostWrittenBytes
        self.currentTLCPE = currentTLCPE
        self.currentTLCEOLPE = currentTLCEOLPE
        self.currentSLCPE = currentSLCPE
        self.currentSLCEOLPE = currentSLCEOLPE
        self.projectedTLCEnduranceBytes = projectedTLCEnduranceBytes
        self.projectedSLCEnduranceBytes = projectedSLCEnduranceBytes
        self.estimatedEnduranceBytes = estimatedEnduranceBytes
        self.remainingHostWriteBytes = remainingHostWriteBytes
        self.lowerDate = lowerDate
        self.upperDate = upperDate
        self.limitingMedium = limitingMedium
        self.unitState = unitState
        self.projection = projection
        self.confidence = confidence
        self.confidenceScore = min(max(confidenceScore, 0), 100)
        self.snapshotCount = snapshotCount
        self.intervalCount = intervalCount
        self.observationDays = max(0, observationDays)
        self.basis = basis
    }
}

struct ControllerEOLAnalyzer: Sendable {
    static let minimumInterval: TimeInterval = 24 * 60 * 60
    static let minimumHostWriteDelta = 1_000_000_000_000.0
    static let daysPerYear = 365.2425

    func forecast(
        from snapshots: [ASPToolDiagnosticsSnapshot],
        deviceID: String?,
        now: Date = Date(),
        excluding: [DateInterval] = [],
        continuityLane suppliedLane: WearContinuityLane? = nil
    ) -> ControllerEOLForecast {
        let rawSeries = snapshots
            .filter { deviceID == nil || $0.deviceID == deviceID }
            .sorted { $0.capturedAt < $1.capturedAt }
        let series = suppliedLane?.snapshots ?? rawSeries

        guard let latest = series.last,
              let currentHost = latest.hostWrittenBytes,
              latest.hasControllerWearData
        else {
            return ControllerEOLForecast(
                message: series.isEmpty
                    ? "物理P/E snapshotを取得していません"
                    : "P/Eまたはhost writesが不足しています",
                snapshotCount: series.count,
                basis: "asptool fields unavailable"
            )
        }

        let singleTLC = project(
            hostBytes: currentHost,
            currentPE: latest.tlcAveragePE,
            eolPE: latest.tlcEOLPE
        )
        let singleSLC = project(
            hostBytes: currentHost,
            currentPE: latest.slcAveragePE,
            eolPE: latest.slcEOLPE
        )

        // Forecast only from the latest private-data lane. Occasional full
        // asptool imports must not break the anchor chain of periodic direct
        // FTL snapshots (and vice versa), nor may a different build/firmware
        // epoch inflate confidence for the current lane.
        let projectionSeries: [ASPToolDiagnosticsSnapshot]
        if suppliedLane != nil {
            // The shared lane has already checked D1-D7 at each instrument
            // boundary. Do not re-split a verified route/build transition
            // with a second, private identity rule here.
            projectionSeries = series
        } else {
            projectionSeries = series.filter { snapshot in
                latest.deviceID != nil && latest.firmwareEpoch != nil &&
                    snapshot.deviceID == latest.deviceID &&
                    snapshot.sourceArtifact == latest.sourceArtifact &&
                    snapshot.extractionVersion == latest.extractionVersion &&
                    snapshot.firmwareEpoch == latest.firmwareEpoch &&
                    sameSourceBuild(snapshot, latest)
            }
        }
        let continuityExclusions = excluding + (suppliedLane?.rateLearningExclusions ?? [])
        let intervals = validIntervals(
            in: projectionSeries,
            excluding: continuityExclusions,
            acceptsVerifiedInstrumentTransitions: suppliedLane != nil
        )
        let intervalProjection = latest.hostWritesUnitState.supportsIntervalComparison
            ? intervalProjection(from: intervals, latest: latest)
            : nil
        let selected = intervalProjection ?? Projection(
            tlc: singleTLC,
            slc: singleSLC,
            rateBytesPerDay: nil,
            observationDays: 0,
            intervalCount: 0,
            projection: .singleSnapshot
        )

        let limiting = limitingMedium(tlc: selected.tlc, slc: selected.slc)
        let estimated = limiting == .tlc ? selected.tlc : limiting == .slc ? selected.slc : nil
        let remaining = estimated.map { max(0, $0 - currentHost) }
        let hasIntervalForecast = selected.projection == .intervalSlope
        let state: ControllerEOLState = hasIntervalForecast ? .estimated : .collecting
        let score = confidenceScore(
            snapshotCount: projectionSeries.count,
            intervalCount: selected.intervalCount,
            observationDays: selected.observationDays,
            unitState: latest.hostWritesUnitState,
            captureQuality: latest.captureQuality
        )
        let confidence = confidence(for: score, unitState: latest.hostWritesUnitState)
        let dates: (lower: Date?, upper: Date?)
        if hasIntervalForecast {
            dates = projectionDates(
                remainingBytes: remaining,
                rateBytesPerDay: selected.rateBytesPerDay,
                now: now
            )
        } else {
            dates = (lower: nil, upper: nil)
        }

        var basis = "asptool (\(selected.projection.title))"
        if latest.hostWritesUnitState == .provisional4KiB {
            basis += " / hostWrites 4 KiB provisional / relative interval"
        }
        if selected.intervalCount > 0 {
            basis += " / \(selected.intervalCount) valid intervals"
        }

        let message: String
        if hasIntervalForecast {
            message = latest.hostWritesUnitState == .provisional4KiB
                ? "同じ暫定単位のP/E進行から算出した到達目安。絶対書込量と故障日ではありません"
                : "複数時点のP/E進行から算出した物理EOL到達目安。故障日ではありません"
        } else {
            message = "物理P/E snapshotは取得済み。複数時点のP/E観測を収集中のため到達日は未算出"
        }

        return ControllerEOLForecast(
            state: state,
            message: message,
            currentHostWrittenBytes: currentHost,
            currentTLCPE: latest.tlcAveragePE,
            currentTLCEOLPE: latest.tlcEOLPE,
            currentSLCPE: latest.slcAveragePE,
            currentSLCEOLPE: latest.slcEOLPE,
            projectedTLCEnduranceBytes: selected.tlc,
            projectedSLCEnduranceBytes: selected.slc,
            estimatedEnduranceBytes: estimated,
            remainingHostWriteBytes: remaining,
            lowerDate: dates.lower,
            upperDate: dates.upper,
            limitingMedium: limiting,
            unitState: latest.hostWritesUnitState,
            projection: selected.projection,
            confidence: confidence,
            confidenceScore: score,
            snapshotCount: projectionSeries.count,
            intervalCount: selected.intervalCount,
            observationDays: selected.observationDays,
            basis: basis
        )
    }

    private struct WearInterval: Sendable {
        let start: ASPToolDiagnosticsSnapshot
        let end: ASPToolDiagnosticsSnapshot
        let hostDelta: Double
        let days: Double
    }

    private struct Projection: Sendable {
        let tlc: Double?
        let slc: Double?
        let rateBytesPerDay: Double?
        let observationDays: Double
        let intervalCount: Int
        let projection: ControllerProjectionKind
    }

    private func validIntervals(
        in series: [ASPToolDiagnosticsSnapshot],
        excluding: [DateInterval],
        acceptsVerifiedInstrumentTransitions: Bool = false
    ) -> [WearInterval] {
        guard series.count >= 2 else { return [] }
        var result: [WearInterval] = []
        var anchor: ASPToolDiagnosticsSnapshot?

        for current in series {
            guard current.captureQuality == .explicit,
                  current.hostWritesUnitState.supportsIntervalComparison,
                  current.hostWrittenBytes != nil
            else {
                anchor = nil
                continue
            }

            guard let previous = anchor else {
                anchor = current
                continue
            }

            let acceptedInstrumentTransition = acceptsVerifiedInstrumentTransitions
                || (sameEpoch(previous, current)
                    && previous.sourceArtifact == current.sourceArtifact
                    && sameSourceBuild(previous, current))
            let sameCounterScale = acceptsVerifiedInstrumentTransitions
                ? previous.hostWritesUnitState.unitBytes == current.hostWritesUnitState.unitBytes
                : previous.hostWritesUnitState == current.hostWritesUnitState
            guard acceptedInstrumentTransition,
                  previous.hostWritesUnitState.supportsIntervalComparison,
                  sameCounterScale,
                  sameWearScale(previous, current),
                  wearCountersAreMonotonic(from: previous, to: current),
                  let previousHost = previous.hostWrittenBytes,
                  let currentHost = current.hostWrittenBytes,
                  currentHost > previousHost
            else {
                anchor = current
                continue
            }

            let elapsed = current.capturedAt.timeIntervalSince(previous.capturedAt)
            let hostDelta = currentHost - previousHost
            let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
            if excluding.contains(where: { $0.intersects(interval) }) {
                // Break the anchor across research activity. The actual
                // cumulative counters remain untouched for residual-life math.
                anchor = current
                continue
            }
            guard elapsed >= Self.minimumInterval,
                  hostDelta >= Self.minimumHostWriteDelta,
                  wearAdvanced(from: previous, to: current)
            else {
                // Keep the original anchor so daily samples accumulate until
                // enough host writes and P/E movement overcome integer counter
                // quantization.
                continue
            }

            result.append(WearInterval(
                start: previous,
                end: current,
                hostDelta: hostDelta,
                days: elapsed / 86_400
            ))
            anchor = current
        }
        return result
    }

    private func sameWearScale(
        _ lhs: ASPToolDiagnosticsSnapshot,
        _ rhs: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        lhs.tlcEOLPE == rhs.tlcEOLPE && lhs.slcEOLPE == rhs.slcEOLPE
    }

    private func sameSourceBuild(
        _ lhs: ASPToolDiagnosticsSnapshot,
        _ rhs: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        switch (lhs.sourceBuild, rhs.sourceBuild) {
        case let (.some(lhs), .some(rhs)):
            return lhs == rhs
        default:
            // Unknown-build snapshots remain readable but cannot extend a
            // new interval forecast across an unverified software epoch.
            return false
        }
    }

    private func wearCountersAreMonotonic(
        from previous: ASPToolDiagnosticsSnapshot,
        to current: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        func monotonic(_ start: Double?, _ end: Double?) -> Bool {
            switch (start, end) {
            case let (.some(start), .some(end)):
                return end >= start
            case (.none, .none):
                return true
            default:
                return false
            }
        }
        return monotonic(previous.tlcAveragePE, current.tlcAveragePE) &&
            monotonic(previous.slcAveragePE, current.slcAveragePE)
    }

    private func wearAdvanced(
        from previous: ASPToolDiagnosticsSnapshot,
        to current: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        let tlcAdvanced: Bool = {
            guard let start = previous.tlcAveragePE, let end = current.tlcAveragePE else { return false }
            return end > start
        }()
        let slcAdvanced: Bool = {
            guard let start = previous.slcAveragePE, let end = current.slcAveragePE else { return false }
            return end > start
        }()
        return tlcAdvanced || slcAdvanced
    }

    private func intervalProjection(
        from intervals: [WearInterval],
        latest: ASPToolDiagnosticsSnapshot
    ) -> Projection? {
        guard intervals.count >= 2 else { return nil }

        let tlcSlopes = intervals.compactMap { interval -> Double? in
            guard let start = interval.start.tlcAveragePE,
                  let end = interval.end.tlcAveragePE,
                  end > start,
                  let eol = interval.end.tlcEOLPE,
                  eol > end,
                  interval.hostDelta > 0
            else { return nil }
            return interval.hostDelta / (end - start)
        }
        let slcSlopes = intervals.compactMap { interval -> Double? in
            guard let start = interval.start.slcAveragePE,
                  let end = interval.end.slcAveragePE,
                  end > start,
                  let eol = interval.end.slcEOLPE,
                  eol > end,
                  interval.hostDelta > 0
            else { return nil }
            return interval.hostDelta / (end - start)
        }

        let requiresTLC = latest.tlcAveragePE != nil && latest.tlcEOLPE != nil
        let requiresSLC = latest.slcAveragePE != nil && latest.slcEOLPE != nil
        guard (!requiresTLC || !tlcSlopes.isEmpty),
              (!requiresSLC || !slcSlopes.isEmpty) else { return nil }
        guard !tlcSlopes.isEmpty || !slcSlopes.isEmpty else { return nil }

        let tlc: Double?
        if let current = latest.tlcAveragePE,
           let slope = median(tlcSlopes),
           let eol = latest.tlcEOLPE,
           eol > current,
           let hostBytes = latest.hostWrittenBytes {
            tlc = hostBytes + (eol - current) * slope
        } else {
            tlc = nil
        }
        let slc: Double?
        if let current = latest.slcAveragePE,
           let slope = median(slcSlopes),
           let eol = latest.slcEOLPE,
           eol > current,
           let hostBytes = latest.hostWrittenBytes {
            slc = hostBytes + (eol - current) * slope
        } else {
            slc = nil
        }
        let rate = median(intervals.map { $0.hostDelta / $0.days })
        let observationDays = intervals.reduce(0) { $0 + $1.days }

        return Projection(
            tlc: tlc,
            slc: slc,
            rateBytesPerDay: rate,
            observationDays: observationDays,
            intervalCount: intervals.count,
            projection: .intervalSlope
        )
    }

    private func project(hostBytes: Double, currentPE: Double?, eolPE: Double?) -> Double? {
        guard let currentPE, let eolPE,
              currentPE > 0, eolPE > currentPE
        else { return nil }
        return hostBytes * eolPE / currentPE
    }

    private func sameEpoch(
        _ lhs: ASPToolDiagnosticsSnapshot,
        _ rhs: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        guard lhs.deviceID != nil,
              lhs.deviceID == rhs.deviceID,
              lhs.extractionVersion == rhs.extractionVersion,
              let leftFirmwareEpoch = lhs.firmwareEpoch,
              let rightFirmwareEpoch = rhs.firmwareEpoch else { return false }
        return leftFirmwareEpoch == rightFirmwareEpoch
    }

    private func limitingMedium(tlc: Double?, slc: Double?) -> ControllerWearMedium {
        switch (tlc, slc) {
        case (.some, .some): return tlc! <= slc! ? .tlc : .slc
        case (.some, .none): return .tlc
        case (.none, .some): return .slc
        case (.none, .none): return .unknown
        }
    }

    private func confidenceScore(
        snapshotCount: Int,
        intervalCount: Int,
        observationDays: Double,
        unitState: ASPToolUnitState,
        captureQuality: ASPToolCaptureQuality
    ) -> Int {
        var score = intervalCount >= 5 ? 70 : intervalCount >= 2 ? 50 : snapshotCount > 0 ? 15 : 0
        if observationDays >= 90 { score += 15 }
        else if observationDays >= 30 { score += 8 }
        if unitState == .verified { score += 15 }
        if captureQuality == .explicit { score += 5 }
        if unitState == .provisional4KiB { score = min(score, 39) }
        if intervalCount < 3 { score = min(score, 69) }
        if intervalCount < 2 { score = min(score, 29) }
        return min(max(score, 0), 100)
    }

    private func confidence(for score: Int, unitState: ASPToolUnitState) -> ForecastConfidence {
        if unitState == .provisional4KiB { return score >= 30 ? .low : .veryLow }
        switch score {
        case 85...: return .veryHigh
        case 70..<85: return .high
        case 50..<70: return .medium
        case 30..<50: return .low
        default: return .veryLow
        }
    }

    private func projectionDates(
        remainingBytes: Double?,
        rateBytesPerDay: Double?,
        now: Date
    ) -> (lower: Date?, upper: Date?) {
        guard let remainingBytes, remainingBytes > 0,
              let rateBytesPerDay, rateBytesPerDay.isFinite, rateBytesPerDay > 0
        else { return (nil, nil) }
        let fasterRate = max(rateBytesPerDay * 1.25, 1)
        let slowerRate = max(rateBytesPerDay * 0.75, 1)
        return (
            now.addingTimeInterval(remainingBytes / fasterRate * 86_400),
            now.addingTimeInterval(remainingBytes / slowerRate * 86_400)
        )
    }

    private func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted.count / 2
            return (sorted[upper - 1] + sorted[upper]) / 2
        }
        return sorted[sorted.count / 2]
    }
}

actor ASPToolSnapshotStore {
    /// Limits below apply only to the explicitly selected legacy sampled
    /// mode. Normal monitoring keeps every observation in lossless blocks.
    static let defaultMaximumRecordCount = 50_000
    static let compactionInterval = 256
    /// Analyses that pair FTL intervals with temperature or split writes by
    /// hour look back 30 days, so every record of the last 35 days stays.
    static let fullResolutionWindow: TimeInterval = 35 * 86_400
    static let hourlyResolutionWindow: TimeInterval = 180 * 86_400
    private static let hourlyBucket: TimeInterval = 3_600
    private static let dailyBucket: TimeInterval = 86_400
    /// Around a firmware, build, contract or structure change every record
    /// stays, so the post-update transient check
    /// (`postUpdateBaselineWindow` before, `postUpdateWindow` after) keeps
    /// reading the same data after thinning.
    private static let boundaryWindowBefore: TimeInterval = 8 * 86_400
    private static let boundaryWindowAfter: TimeInterval = 4 * 86_400

    let fileURL: URL
    let maximumRecordCount: Int
    private var cache: [ASPToolDiagnosticsSnapshot]?
    private var appendsSinceCompaction = 0
    /// One shared copy of each distinct `parseWarnings` list. The file
    /// still stores every record in full.
    private var warningPool: [[String]: [String]] = [:]
    private var strings = HistoryStringPool()
    private var losslessStorage: LosslessHistoryStorage<ASPToolDiagnosticsSnapshot>?

    init(
        fileURL: URL? = nil,
        maximumRecordCount: Int = ASPToolSnapshotStore.defaultMaximumRecordCount,
        preservesAllMeasurements: Bool = true
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.maximumRecordCount = max(1, maximumRecordCount)
        if preservesAllMeasurements {
            losslessStorage = LosslessHistoryStorage(fileURL: self.fileURL)
        }
    }

    func records() throws -> [ASPToolDiagnosticsSnapshot] {
        try ensureLoaded()
    }

    private func sharingStrings(_ snapshot: ASPToolDiagnosticsSnapshot) -> ASPToolDiagnosticsSnapshot {
        var copy = snapshot
        if let shared = warningPool[snapshot.parseWarnings] {
            copy.parseWarnings = shared
        } else {
            warningPool[snapshot.parseWarnings] = snapshot.parseWarnings
        }
        copy.deviceID = strings.shared(snapshot.deviceID)
        copy.semanticContractVersion = strings.shared(snapshot.semanticContractVersion)
        copy.researchTelemetryContractVersion = strings.shared(snapshot.researchTelemetryContractVersion)
        copy.directKeyContractVersion = strings.shared(snapshot.directKeyContractVersion)
        if let topology = snapshot.directTopology {
            copy.directTopology?.contractVersion = strings.shared(topology.contractVersion)
        }
        return copy
    }

    @discardableResult
    func appendIfNew(_ incoming: ASPToolDiagnosticsSnapshot) throws -> Bool {
        func isDuplicate(_ snapshot: ASPToolDiagnosticsSnapshot, in records: [ASPToolDiagnosticsSnapshot]) -> Bool {
            records.contains { existing in
                existing.deviceID == snapshot.deviceID &&
                    existing.sourceArtifact == snapshot.sourceArtifact &&
                    existing.capturedAt == snapshot.capturedAt &&
                    existing.hostWrites == snapshot.hostWrites &&
                    existing.nandWrites == snapshot.nandWrites
            }
        }
        var current: [ASPToolDiagnosticsSnapshot]
        do {
            current = try ensureLoaded()
        } catch {
            guard let storage = losslessStorage, let tail = storage.cleanTail() else { throw error }
            // An unreadable block must not also lose later snapshots. `cache`
            // stays nil, so every later read keeps retrying the full history.
            guard !isDuplicate(incoming, in: tail) else { return false }
            try storage.appendWithoutLoading(incoming)
            return true
        }
        let snapshot = sharingStrings(incoming)
        guard !isDuplicate(snapshot, in: current) else { return false }

        current.append(snapshot)
        current.sort { $0.capturedAt < $1.capturedAt }
        if losslessStorage != nil {
            try append(snapshot)
            cache = current
            return true
        }
        appendsSinceCompaction += 1
        if current.count <= maximumRecordCount && appendsSinceCompaction < Self.compactionInterval {
            try append(snapshot)
            cache = current
            return true
        }
        appendsSinceCompaction = 0

        let protectedDirectSeriesStartIDs = directSeriesStartIDs(in: current)
        let beforeCompaction = current
        current = compact(current)
        if current.count == beforeCompaction.count && current.count <= maximumRecordCount {
            // Nothing old enough to thin: append instead of rewriting.
            try append(snapshot)
            cache = current
            return true
        }
        if current.count > maximumRecordCount {
            var bounded: [ASPToolDiagnosticsSnapshot] = []
            var selectedIDs = Set<UUID>()
            for record in current where protectedDirectSeriesStartIDs.contains(record.id) {
                guard bounded.count < maximumRecordCount else { break }
                bounded.append(record)
                selectedIDs.insert(record.id)
            }
            for record in current.reversed() where !selectedIDs.contains(record.id) {
                guard bounded.count < maximumRecordCount else { break }
                bounded.append(record)
                selectedIDs.insert(record.id)
            }
            current = bounded.sorted { $0.capturedAt < $1.capturedAt }
        }
        try CompactionArchive(sourceURL: fileURL).store(
            removedFrom: beforeCompaction, keeping: current, capturedAt: \.capturedAt)
        try write(current)
        cache = current
        return true
    }

    private func ensureLoaded() throws -> [ASPToolDiagnosticsSnapshot] {
        if let cache { return cache }
        if var storage = losslessStorage {
            let loaded = try storage.load().map { sharingStrings($0) }.sorted { $0.capturedAt < $1.capturedAt }
            losslessStorage = storage
            cache = loaded
            return loaded
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [ASPToolDiagnosticsSnapshot] = []
        var rejectedRows: [(lineNumber: Int, bytes: Data)] = []
        for (offset, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            guard !line.isEmpty else { continue }
            if let record = try? decoder.decode(ASPToolDiagnosticsSnapshot.self, from: Data(line)) {
                loaded.append(sharingStrings(record))
            } else {
                rejectedRows.append((offset + 1, Data(line)))
            }
        }
        loaded.sort { $0.capturedAt < $1.capturedAt }
        if JSONLQuarantine.isMostlyUnreadable(failedRows: rejectedRows.count, readableRows: loaded.count) {
            _ = try JSONLQuarantine.setAside(sourceURL: fileURL)
            try write(loaded)
        } else if !rejectedRows.isEmpty {
            // Keep the exact bytes of unreadable rows (for example a line torn
            // by a crash) beside the store, then repair the source so the next
            // append does not join a new record onto the torn line.
            _ = try JSONLQuarantine.archive(rows: rejectedRows, sourceData: data, sourceURL: fileURL)
            try write(loaded)
        }
        cache = loaded
        return loaded
    }

    private func compact(_ records: [ASPToolDiagnosticsSnapshot]) -> [ASPToolDiagnosticsSnapshot] {
        guard let newest = records.map(\.capturedAt).max() else { return records }
        let fullCutoff = newest.addingTimeInterval(-Self.fullResolutionWindow)
        let hourlyCutoff = newest.addingTimeInterval(-Self.hourlyResolutionWindow)

        struct Lane: Hashable {
            let deviceID: String
            let source: ASPToolSourceArtifact
        }
        struct Bucket: Hashable {
            let hourly: Bool
            let index: Int64
        }

        let grouped = Dictionary(grouping: records) { record in
            Lane(deviceID: record.deviceID ?? "unknown", source: record.sourceArtifact)
        }
        var retained: [UUID: ASPToolDiagnosticsSnapshot] = [:]
        var protectedWindows: [String: [DateInterval]] = [:]

        for (lane, laneRecords) in grouped {
            let sorted = laneRecords.sorted { $0.capturedAt < $1.capturedAt }
            // The latest record of each bucket stays; cumulative counters
            // keep their totals because window sums telescope.
            var winners: [Bucket: ASPToolDiagnosticsSnapshot] = [:]
            for record in sorted {
                if record.capturedAt >= fullCutoff {
                    retained[record.id] = record
                    continue
                }
                let hourly = record.capturedAt >= hourlyCutoff
                let width = hourly ? Self.hourlyBucket : Self.dailyBucket
                winners[Bucket(hourly: hourly, index: Int64(floor(record.capturedAt.timeIntervalSince1970 / width)))] = record
            }
            for record in winners.values { retained[record.id] = record }

            for (previous, current) in zip(sorted, sorted.dropFirst()) {
                switch Self.boundary(between: previous, and: current) {
                case .none:
                    break
                case .pair:
                    retained[previous.id] = previous
                    retained[current.id] = current
                case .window:
                    retained[previous.id] = previous
                    retained[current.id] = current
                    protectedWindows[lane.deviceID, default: []].append(DateInterval(
                        start: previous.capturedAt.addingTimeInterval(-Self.boundaryWindowBefore),
                        end: current.capturedAt.addingTimeInterval(Self.boundaryWindowAfter)))
                }
            }
        }

        // A change of route (asptool ↔ Direct) is a boundary between lanes.
        let byDevice = Dictionary(grouping: records) { $0.deviceID ?? "unknown" }
        for (device, deviceRecords) in byDevice {
            let sorted = deviceRecords.sorted { $0.capturedAt < $1.capturedAt }
            for (previous, current) in zip(sorted, sorted.dropFirst())
            where previous.sourceArtifact != current.sourceArtifact {
                retained[previous.id] = previous
                retained[current.id] = current
            }
            if let windows = protectedWindows[device] {
                for record in sorted where windows.contains(where: { $0.contains(record.capturedAt) }) {
                    retained[record.id] = record
                }
            }
        }
        for startID in directSeriesStartIDs(in: records) {
            if let start = records.first(where: { $0.id == startID }) {
                retained[start.id] = start
            }
        }
        return retained.values.sorted { $0.capturedAt < $1.capturedAt }
    }

    enum CompactionBoundary: Equatable {
        case none
        /// Keep the two records on either side.
        case pair
        /// Also keep every record around it (see `boundaryWindowBefore`).
        case window
    }

    /// Records that analyses use as anchors are never thinned away, or a
    /// boundary would move to a bucket edge.
    static func boundary(
        between previous: ASPToolDiagnosticsSnapshot,
        and current: ASPToolDiagnosticsSnapshot
    ) -> CompactionBoundary {
        let contractChanged = previous.historySchemaVersion != current.historySchemaVersion ||
            previous.directFormatVersion != current.directFormatVersion ||
            previous.directKeyContractVersion != current.directKeyContractVersion ||
            previous.semanticContractVersion != current.semanticContractVersion ||
            previous.contractBuild != current.contractBuild
        if previous.firmwareEpoch != current.firmwareEpoch || previous.sourceBuild != current.sourceBuild ||
            contractChanged || WearContinuityLaneBuilder.structuralAttributesChanged(before: previous, after: current) {
            return .window
        }
        func decreased<T: Comparable>(_ before: T?, _ after: T?) -> Bool {
            guard let before, let after else { return false }
            return after < before
        }
        let researchBefore = previous.researchTelemetry
        let researchAfter = current.researchTelemetry
        let counterDecreased = decreased(previous.hostWrites, current.hostWrites) ||
            decreased(previous.nandWrites, current.nandWrites) ||
            decreased(previous.powerOnHours, current.powerOnHours) ||
            decreased(previous.tlcAveragePE, current.tlcAveragePE) ||
            decreased(previous.slcAveragePE, current.slcAveragePE) ||
            decreased(previous.grownBadBlocks, current.grownBadBlocks) ||
            decreased(previous.numDieFailures, current.numDieFailures) ||
            decreased(researchBefore?.crossTemperatureUECC, researchAfter?.crossTemperatureUECC) ||
            decreased(researchBefore?.crossTemperatureRaidUECC, researchAfter?.crossTemperatureRaidUECC) ||
            decreased(researchBefore?.utilityUECCReads, researchAfter?.utilityUECCReads) ||
            decreased(researchBefore?.ueccReads, researchAfter?.ueccReads) ||
            decreased(researchBefore?.hostSLCReadVerifyFailures, researchAfter?.hostSLCReadVerifyFailures) ||
            decreased(researchBefore?.hostTLCReadVerifyFailures, researchAfter?.hostTLCReadVerifyFailures) ||
            decreased(researchBefore?.gcSLCToTLCReadVerifyFailures, researchAfter?.gcSLCToTLCReadVerifyFailures) ||
            decreased(researchBefore?.gcTLCToTLCReadVerifyFailures, researchAfter?.gcTLCToTLCReadVerifyFailures)
        let stateChanged = previous.hostWritesUnitState != current.hostWritesUnitState ||
            previous.nandWritesUnitState != current.nandWritesUnitState ||
            ControllerWearSeriesIdentity(snapshot: previous) != ControllerWearSeriesIdentity(snapshot: current)
        return counterDecreased || stateChanged ? .pair : .none
    }

    /// The first retained snapshot of every Direct FTL series is a semantic
    /// anchor. Daily/weekly compaction may remove it, but doing so would turn
    /// a long baseline into an accidental recent-window calculation.
    private func directSeriesStartIDs(in records: [ASPToolDiagnosticsSnapshot]) -> Set<UUID> {
        var starts = Set<UUID>()
        var identities: [ControllerWearSeriesIdentity] = []
        for record in records
            .filter({ $0.sourceArtifact == .directFTL })
            .sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let identity = ControllerWearSeriesIdentity(snapshot: record)
            if !identities.contains(identity) {
                identities.append(identity)
                starts.insert(record.id)
            }
        }
        return starts
    }

    private func append(_ record: ASPToolDiagnosticsSnapshot) throws {
        if losslessStorage != nil {
            try losslessStorage!.append(record)
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                // Start on a fresh line if the previous write was cut short.
                try handle.seek(toOffset: end - 1)
                if handle.readData(ofLength: 1) != Data([0x0A]) {
                    line.insert(0x0A, at: 0)
                }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }

    private func write(_ records: [ASPToolDiagnosticsSnapshot]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private static func defaultFileURL() -> URL {
        AppDataLocation.directoryURL
            .appendingPathComponent("asptool-snapshots.jsonl")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
