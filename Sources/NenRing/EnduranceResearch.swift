import Foundation
import Darwin

enum EnduranceWearDomain: String, Codable, CaseIterable, Sendable {
    case tlc
    case pSLC
}

private extension String {
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
}

struct ResearchTelemetryObservation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let smartCapturedAt: Date?
    let ftlCapturedAt: Date?
    let recordedAt: Date?
    let deviceID: String
    let hostWrites: UInt64?
    let nandWrites: UInt64?
    let smartDataUnitsWritten: UInt64?
    let hostUnitState: ASPToolUnitState
    let nandUnitState: ASPToolUnitState
    let sourceBuild: String?
    let extractionVersion: Int?
    let tlcAveragePE: Double?
    let tlcMaximumPE: Double?
    let slcAveragePE: Double?
    let slcMaximumPE: Double?
    let tlcEOLPE: Double?
    let slcEOLPE: Double?
    let firmwareEpoch: String?
    let temperatureCelsius: Int?
    let criticalWarning: UInt64?
    let phase: ResearchObservationPhase?
    let bytesWrittenInPhase: UInt64?

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        smartCapturedAt: Date? = nil,
        ftlCapturedAt: Date? = nil,
        recordedAt: Date? = Date(),
        deviceID: String,
        hostWrites: UInt64?,
        nandWrites: UInt64?,
        smartDataUnitsWritten: UInt64? = nil,
        hostUnitState: ASPToolUnitState,
        nandUnitState: ASPToolUnitState,
        sourceBuild: String? = nil,
        extractionVersion: Int? = nil,
        tlcAveragePE: Double?,
        tlcMaximumPE: Double? = nil,
        slcAveragePE: Double?,
        slcMaximumPE: Double? = nil,
        tlcEOLPE: Double?,
        slcEOLPE: Double?,
        firmwareEpoch: String?,
        temperatureCelsius: Int?,
        criticalWarning: UInt64?,
        phase: ResearchObservationPhase? = nil,
        bytesWrittenInPhase: UInt64? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.smartCapturedAt = smartCapturedAt
        self.ftlCapturedAt = ftlCapturedAt
        self.recordedAt = recordedAt
        self.deviceID = deviceID
        self.hostWrites = hostWrites
        self.nandWrites = nandWrites
        self.smartDataUnitsWritten = smartDataUnitsWritten
        self.hostUnitState = hostUnitState
        self.nandUnitState = nandUnitState
        self.sourceBuild = sourceBuild
        self.extractionVersion = extractionVersion
        self.tlcAveragePE = tlcAveragePE
        self.tlcMaximumPE = tlcMaximumPE
        self.slcAveragePE = slcAveragePE
        self.slcMaximumPE = slcMaximumPE
        self.tlcEOLPE = tlcEOLPE
        self.slcEOLPE = slcEOLPE
        self.firmwareEpoch = firmwareEpoch
        self.temperatureCelsius = temperatureCelsius
        self.criticalWarning = criticalWarning
        self.phase = phase
        self.bytesWrittenInPhase = bytesWrittenInPhase
    }

    var hostWrittenBytes: Double? {
        guard let hostWrites, let unit = hostUnitState.unitBytes else { return nil }
        return Double(hostWrites) * unit
    }

    var nandWrittenBytes: Double? {
        guard let nandWrites, let unit = nandUnitState.unitBytes else { return nil }
        return Double(nandWrites) * unit
    }

}

enum ResearchObservationPhase: String, Codable, Equatable, Sendable {
    case beforeWrite
    case populationWriting
    case populationComplete
    case overwriteSegment
    case finished
    case cooldown
}

enum ResearchSessionState: String, Codable, Sendable {
    case running
    case completed
    case stopped
    case interrupted
    case failed

    var title: String {
        switch self {
        case .running: return "実行中"
        case .completed: return "完了"
        case .stopped: return "停止"
        case .interrupted: return "中断"
        case .failed: return "失敗"
        }
    }
}

enum ResearchStopReasonCode: String, Codable, Equatable, Sendable {
    case writeLimit
    case durationLimit
    case userStopped
    case appInterrupted
    case powerDisconnected
    case thermalLimit
    case temperatureUnavailable
    case criticalWarning
    case insufficientSpace
    case cacheControlFailure
    case ioFailure
    case startupCaptureFailure
    case unknown

    var title: String {
        switch self {
        case .writeLimit: return "書込上限"
        case .durationLimit: return "時間上限"
        case .userStopped: return "利用者が停止"
        case .appInterrupted: return "アプリ／スリープ中断"
        case .powerDisconnected: return "AC切断"
        case .thermalLimit: return "温度上限"
        case .temperatureUnavailable: return "温度取得失敗"
        case .criticalWarning: return "Critical Warning"
        case .insufficientSpace: return "空き容量不足"
        case .cacheControlFailure: return "キャッシュ制御失敗"
        case .ioFailure: return "I/O失敗"
        case .startupCaptureFailure: return "開始時取得失敗"
        case .unknown: return "不明"
        }
    }
}

enum ResearchWearAssessment: String, Codable, Equatable, Sendable {
    case changed
    case insufficientObservation
    case unavailable

    var title: String {
        switch self {
        case .changed: return "P/E変化あり · 短期観測"
        case .insufficientObservation: return "P/E変化なし · 観測量不足"
        case .unavailable: return "P/E評価不可"
        }
    }
}

struct ResearchSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let deviceID: String
    let logicalCapacityBytes: UInt64
    var firmwareEpoch: String?
    let startedAt: Date
    var finishedAt: Date?
    let protocolVersion: String
    let seed: UInt64
    let plannedMaximumBytes: UInt64
    var writtenBytes: UInt64
    var state: ResearchSessionState
    var wearAssessment: ResearchWearAssessment?
    var stopReason: String?
    var cleanupSucceeded: Bool?
    var stopReasonCode: ResearchStopReasonCode?
    var availableBytesAtStart: UInt64?
    var availableBytesAtFinish: UInt64?
    var partialPhase: ResearchObservationPhase?
    var partialPhaseBytes: UInt64?
    var workingSetBytes: UInt64?
    var populationWriteBytes: UInt64?
    var overwriteWriteBytes: UInt64?
    var observations: [ResearchTelemetryObservation]

    init(
        id: UUID = UUID(),
        deviceID: String,
        logicalCapacityBytes: UInt64,
        firmwareEpoch: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        protocolVersion: String = "client-proxy-v2",
        seed: UInt64,
        plannedMaximumBytes: UInt64,
        writtenBytes: UInt64 = 0,
        state: ResearchSessionState = .running,
        wearAssessment: ResearchWearAssessment? = nil,
        stopReason: String? = nil,
        cleanupSucceeded: Bool? = nil,
        stopReasonCode: ResearchStopReasonCode? = nil,
        availableBytesAtStart: UInt64? = nil,
        availableBytesAtFinish: UInt64? = nil,
        partialPhase: ResearchObservationPhase? = nil,
        partialPhaseBytes: UInt64? = nil,
        workingSetBytes: UInt64? = nil,
        populationWriteBytes: UInt64? = nil,
        overwriteWriteBytes: UInt64? = nil,
        observations: [ResearchTelemetryObservation] = []
    ) {
        self.id = id
        self.deviceID = deviceID
        self.logicalCapacityBytes = logicalCapacityBytes
        self.firmwareEpoch = firmwareEpoch
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.protocolVersion = protocolVersion
        self.seed = seed
        self.plannedMaximumBytes = plannedMaximumBytes
        self.writtenBytes = writtenBytes
        self.state = state
        self.wearAssessment = wearAssessment
        self.stopReason = stopReason
        self.cleanupSucceeded = cleanupSucceeded
        self.stopReasonCode = stopReasonCode
        self.availableBytesAtStart = availableBytesAtStart
        self.availableBytesAtFinish = availableBytesAtFinish
        self.partialPhase = partialPhase
        self.partialPhaseBytes = partialPhaseBytes
        self.workingSetBytes = workingSetBytes
        self.populationWriteBytes = populationWriteBytes
        self.overwriteWriteBytes = overwriteWriteBytes
        self.observations = Array(observations.suffix(8))
    }

    var analysisExcludedInterval: DateInterval? {
        let end = finishedAt ?? Date()
        guard end > startedAt else { return nil }
        return DateInterval(start: startedAt, end: end)
    }

    var evaluatedWearAssessment: ResearchWearAssessment {
        guard observations.count >= 2,
              let first = observations.first,
              let last = observations.last,
              observationsShareEpoch(first, last) else { return .unavailable }
        let pePairs: [(Double?, Double?)] = [
            (first.tlcAveragePE, last.tlcAveragePE),
            (first.tlcMaximumPE, last.tlcMaximumPE),
            (first.slcAveragePE, last.slcAveragePE),
            (first.slcMaximumPE, last.slcMaximumPE)
        ]
        let counterRegressed = pePairs.contains { pair in
            guard let start = pair.0, let end = pair.1, start.isFinite, end.isFinite else { return false }
            return end < start
        }
        guard !counterRegressed else { return .unavailable }
        let knownPairs = pePairs.compactMap { pair -> (Double, Double)? in
            guard let start = pair.0, let end = pair.1, start.isFinite, end.isFinite, end >= start else { return nil }
            return (start, end)
        }
        guard !knownPairs.isEmpty else { return .unavailable }
        return knownPairs.contains(where: { $0.1 > $0.0 }) ? .changed : .insufficientObservation
    }

    var observedHostWriteDeltaBytes: Double? {
        guard observations.count >= 2,
              let first = observations.first,
              let last = observations.last,
              first.deviceID == last.deviceID,
              observationsShareEpoch(first, last),
              first.hostUnitState.supportsIntervalComparison,
              first.hostUnitState == last.hostUnitState,
              let firstWrites = first.hostWrites,
              let lastWrites = last.hostWrites,
              lastWrites >= firstWrites,
              let unit = first.hostUnitState.unitBytes
        else { return nil }
        return Double(lastWrites - firstWrites) * unit
    }

    var observedSmartHostWriteDeltaBytes: Double? {
        guard observations.count >= 2,
              let first = observations.first,
              let last = observations.last,
              first.deviceID == last.deviceID,
              observationsShareEpoch(first, last),
              let firstUnits = first.smartDataUnitsWritten,
              let lastUnits = last.smartDataUnitsWritten,
              lastUnits >= firstUnits else { return nil }
        return Double(lastUnits - firstUnits) * HistoryAnalyzer.bytesPerNVMeDataUnit
    }

    var observedWriteAmplification: Double? {
        guard observations.count >= 2,
              let first = observations.first,
              let last = observations.last,
              first.deviceID == last.deviceID,
              observationsShareEpoch(first, last),
              first.hostUnitState.supportsIntervalComparison,
              first.hostUnitState == last.hostUnitState,
              first.hostUnitState == first.nandUnitState,
              last.hostUnitState == last.nandUnitState,
              first.nandUnitState == last.nandUnitState,
              let hostStart = first.hostWrites,
              let hostEnd = last.hostWrites,
              hostEnd > hostStart,
              let nandStart = first.nandWrites,
              let nandEnd = last.nandWrites,
              nandEnd >= nandStart else { return nil }
        let value = Double(nandEnd - nandStart) / Double(hostEnd - hostStart)
        return value.isFinite ? value : nil
    }

    /// WAF measured only across intervals after the working set was populated.
    /// The initial sequential population and post-run cooldown are excluded.
    var clientProxyWriteAmplification: Double? {
        let eligible = clientProxyEligibleCounterIntervals
        guard !eligible.isEmpty else { return nil }
        let totalHost = eligible.reduce(0.0) { $0 + Double($1.hostDelta) }
        let totalNAND = eligible.reduce(0.0) { $0 + Double($1.nandDelta) }
        guard totalHost.isFinite, totalHost > 0, totalNAND.isFinite else { return nil }
        let waf = totalNAND / totalHost
        return waf.isFinite ? waf : nil
    }

    var clientProxyWAFIntervalCount: Int {
        clientProxyEligibleCounterIntervals.count
    }

    var clientProxyPreparationBytes: UInt64 {
        let completed = observations.filter { $0.phase == .populationComplete }
            .reduce(0) { saturatingAdd($0, $1.bytesWrittenInPhase ?? 0) }
        return saturatingAdd(
            completed,
            partialPhase == .populationWriting ? partialPhaseBytes ?? 0 : 0
        )
    }

    var clientProxyOverwriteBytes: UInt64 {
        let completed = observations.filter { $0.phase == .overwriteSegment }
            .reduce(0) { saturatingAdd($0, $1.bytesWrittenInPhase ?? 0) }
        return saturatingAdd(
            completed,
            partialPhase == .overwriteSegment ? partialPhaseBytes ?? 0 : 0
        )
    }

    var isSuccessfulClientProxyCompletion: Bool {
        let candidateIntervals = clientProxyCandidateIntervals
        guard protocolVersion == "client-proxy-v2",
              state == .completed || (state == .stopped && stopReason == "30分上限"),
              logicalCapacityBytes > 0,
              writtenBytes <= logicalCapacityBytes / 10,
              candidateIntervals.count >= 2,
              candidateIntervals.count == clientProxyWAFIntervalCount,
              clientProxyWriteAmplification != nil,
              observations.allSatisfy({ $0.criticalWarning == 0 }),
              let first = observations.first,
              let last = observations.last,
              let smartStart = first.smartDataUnitsWritten,
              let smartEnd = last.smartDataUnitsWritten,
              smartEnd >= smartStart,
              smartEnd > smartStart,
              candidateIntervals.allSatisfy({ before, after in
                  guard let smartBefore = before.smartDataUnitsWritten,
                        let smartAfter = after.smartDataUnitsWritten,
                        smartAfter >= smartBefore else { return false }
                  let pePairs: [(Double?, Double?)] = [
                      (before.tlcAveragePE, after.tlcAveragePE),
                      (before.tlcMaximumPE, after.tlcMaximumPE),
                      (before.slcAveragePE, after.slcAveragePE),
                      (before.slcMaximumPE, after.slcMaximumPE)
                  ]
                  return pePairs.allSatisfy { start, end in
                      guard let start, let end else { return true }
                      return start.isFinite && end.isFinite && end >= start
                  }
              })
        else { return false }
        guard writtenBytes > 0 else { return false }
        let attribution = Double(smartEnd - smartStart) * HistoryAnalyzer.bytesPerNVMeDataUnit / Double(writtenBytes)
        guard attribution.isFinite, (0.8...1.5).contains(attribution) else { return false }
        if first.hostUnitState != .verified {
            guard let directHost = observedHostWriteDeltaBytes,
                  let smartHost = observedSmartHostWriteDeltaBytes,
                  max(directHost, smartHost) > 0,
                  abs(directHost - smartHost) / max(directHost, smartHost) <= 0.10 else { return false }
        }
        return true
    }

    private var clientProxyEligibleCounterIntervals: [(hostDelta: UInt64, nandDelta: UInt64)] {
        clientProxyCandidateIntervals.compactMap { before, after in
            guard (before.phase == .populationComplete || before.phase == .overwriteSegment),
                  after.phase == .overwriteSegment,
                  observationsShareEpoch(before, after),
                  before.criticalWarning == 0,
                  after.criticalWarning == 0,
                  before.hostUnitState.supportsIntervalComparison,
                  before.hostUnitState == after.hostUnitState,
                  before.hostUnitState == before.nandUnitState,
                  after.hostUnitState == after.nandUnitState,
                  let host0 = before.hostWrites, let host1 = after.hostWrites, host1 > host0,
                  let nand0 = before.nandWrites, let nand1 = after.nandWrites, nand1 >= nand0,
                  Double(host1 - host0) * (before.hostUnitState.unitBytes ?? 0) >= 256_000_000 else { return nil }
            let hostDelta = host1 - host0
            let nandDelta = nand1 - nand0
            let waf = Double(nandDelta) / Double(hostDelta)
            guard waf.isFinite, (0.5...10).contains(waf) else { return nil }
            return (hostDelta, nandDelta)
        }
    }

    private var clientProxyCandidateIntervals: [(ResearchTelemetryObservation, ResearchTelemetryObservation)] {
        zip(observations, observations.dropFirst()).filter { before, after in
            (before.phase == .populationComplete || before.phase == .overwriteSegment) &&
                after.phase == .overwriteSegment
        }
    }

    private func observationsShareEpoch(
        _ first: ResearchTelemetryObservation,
        _ last: ResearchTelemetryObservation
    ) -> Bool {
        guard first.deviceID == last.deviceID,
              let firmware = first.firmwareEpoch,
              firmware == last.firmwareEpoch,
              let build = first.sourceBuild,
              build == last.sourceBuild,
              let extractionVersion = first.extractionVersion,
              extractionVersion == last.extractionVersion else { return false }
        return true
    }
}

actor ResearchSessionStore {
    static let maximumSessions = 128
    let fileURL: URL
    private var cache: [ResearchSession]?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func sessions() throws -> [ResearchSession] {
        try loadIfNeeded()
    }

    func upsert(_ session: ResearchSession) throws {
        var records = try loadIfNeeded()
        if let index = records.firstIndex(where: { $0.id == session.id }) {
            records[index] = session
        } else {
            records.append(session)
        }
        records.sort { $0.startedAt < $1.startedAt }
        records = Array(records.suffix(Self.maximumSessions))
        try write(records)
        cache = records
    }

    private func loadIfNeeded() throws -> [ResearchSession] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = data.split(separator: 0x0A).compactMap {
            try? decoder.decode(ResearchSession.self, from: Data($0))
        }.sorted { $0.startedAt < $1.startedAt }
        cache = Array(records.suffix(Self.maximumSessions))
        return cache ?? []
    }

    private func write(_ records: [ResearchSession]) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func defaultFileURL() -> URL {
        AppDataLocation.directoryURL
            .appendingPathComponent("research-sessions.jsonl")
    }
}

struct ControllerWearHistorySummary: Equatable, Sendable {
    let intervalCount: Int
    let tlcIntervalCount: Int
    let slcIntervalCount: Int
    let tlcMaximumIntervalCount: Int
    let slcMaximumIntervalCount: Int
    let observationDays: Double
    let tlcPEProgress: Double?
    let slcPEProgress: Double?
    let tlcMaximumPEProgress: Double?
    let slcMaximumPEProgress: Double?
    let coupledAverageIntervalCount: Int
    let coupledTlcAveragePEProgress: Double?
    let coupledSlcAveragePEProgress: Double?
    let coupledMaximumIntervalCount: Int
    let coupledTlcMaximumPEProgress: Double?
    let coupledSlcMaximumPEProgress: Double?
    let hostUnitState: ASPToolUnitState
    let tlcHostBytesPerPE: Double?
    let slcHostBytesPerPE: Double?
    let tlcHostBytesPerMaximumPE: Double?
    let slcHostBytesPerMaximumPE: Double?
    let medianWAF: Double?
    let tlcSlopeCoefficientOfVariation: Double?
    let slcSlopeCoefficientOfVariation: Double?
    let seriesIdentity: ControllerWearSeriesIdentity?
    /// Instrument provenance of the accepted lane tail. A caller must not
    /// combine a raw latest snapshot from a pending/failed instrument with
    /// this wear summary.
    let latestInstrumentIdentity: InstrumentIdentity?
    let unavailableReason: String?
    let hostBytesObserved: Double
    /// Analysis-only instrument boundary records. Raw snapshots are never
    /// rewritten; callers use these records to distinguish a verified bridge
    /// from a pending or rejected boundary.
    let instrumentBoundaries: [InstrumentBoundaryRecord]
}

struct ControllerWearSeriesIdentity: Equatable, Sendable {
    let deviceID: String?
    let sourceArtifact: ASPToolSourceArtifact
    let extractionVersion: Int
    /// Only the stable Host/NAND/P-E/EOL/topology contract belongs in wear
    /// identity. Research telemetry revisions are allowed to split their own
    /// metrics without resetting wear history.
    let coreWearVersion: String?
    let sourceBuild: String?
    let firmwareEpoch: String?
    let hostUnitState: ASPToolUnitState
    let nandUnitState: ASPToolUnitState
    let tlcEOLPE: Double?
    let slcEOLPE: Double?

    init(snapshot: ASPToolDiagnosticsSnapshot) {
        deviceID = snapshot.deviceID
        sourceArtifact = snapshot.sourceArtifact
        extractionVersion = snapshot.extractionVersion
        coreWearVersion = snapshot.resolvedCoreWearVersion
        sourceBuild = snapshot.sourceBuild
        firmwareEpoch = snapshot.firmwareEpoch
        hostUnitState = snapshot.hostWritesUnitState
        nandUnitState = snapshot.nandWritesUnitState
        tlcEOLPE = snapshot.tlcEOLPE
        slcEOLPE = snapshot.slcEOLPE
    }

    /// Compatibility label for older callers. It is not an independent field
    /// in Equatable identity; it resolves to the stable core contract.
    var semanticContractVersion: String? { coreWearVersion }

    /// Wear-series identity is physical-device identity only. Runtime build,
    /// firmware, contract, format, extraction and unit labels are instrument
    /// provenance; WearContinuityLaneBuilder audits those as boundaries.
    static func == (lhs: ControllerWearSeriesIdentity, rhs: ControllerWearSeriesIdentity) -> Bool {
        lhs.deviceID == rhs.deviceID
    }
}

struct ControllerWearHistoryAnalyzer: Sendable {
    func summarize(
        snapshots: [ASPToolDiagnosticsSnapshot],
        deviceID: String?,
        excluding: [DateInterval] = [],
        provisional: Bool = false,
        aggregateSlopes: Bool = false,
        smartHistory: [DriveSnapshot] = [],
        continuityLane suppliedLane: WearContinuityLane? = nil
    ) -> ControllerWearHistorySummary {
        let ordered = snapshots.filter { deviceID == nil || $0.deviceID == deviceID }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let orderedLast = ordered.last else {
            return ControllerWearHistorySummary(intervalCount: 0, tlcIntervalCount: 0,
                slcIntervalCount: 0, tlcMaximumIntervalCount: 0, slcMaximumIntervalCount: 0,
                observationDays: 0,
                tlcPEProgress: nil, slcPEProgress: nil, tlcMaximumPEProgress: nil,
                slcMaximumPEProgress: nil, coupledAverageIntervalCount: 0,
                coupledTlcAveragePEProgress: nil, coupledSlcAveragePEProgress: nil,
                coupledMaximumIntervalCount: 0, coupledTlcMaximumPEProgress: nil,
                coupledSlcMaximumPEProgress: nil, hostUnitState: .unavailable,
                tlcHostBytesPerPE: nil, slcHostBytesPerPE: nil,
                tlcHostBytesPerMaximumPE: nil, slcHostBytesPerMaximumPE: nil, medianWAF: nil,
                tlcSlopeCoefficientOfVariation: nil, slcSlopeCoefficientOfVariation: nil,
                seriesIdentity: nil,
                latestInstrumentIdentity: nil,
                unavailableReason: "FTL履歴がありません", hostBytesObserved: 0, instrumentBoundaries: [])
        }
        // Always build the lane.  With no SMART history a firmware/build
        // boundary remains pending instead of being silently bridged; with
        // SMART history the lane can apply D5/D6 and retain a verified bridge.
        let lane = suppliedLane ?? WearContinuityLaneBuilder.build(
            snapshots: ordered,
            smart: smartHistory,
            latest: orderedLast
        )
        let seriesCandidates = lane.snapshots
        guard let last = seriesCandidates.last else {
            return ControllerWearHistorySummary(intervalCount: 0, tlcIntervalCount: 0,
                slcIntervalCount: 0, tlcMaximumIntervalCount: 0, slcMaximumIntervalCount: 0,
                observationDays: 0,
                tlcPEProgress: nil, slcPEProgress: nil, tlcMaximumPEProgress: nil,
                slcMaximumPEProgress: nil, coupledAverageIntervalCount: 0,
                coupledTlcAveragePEProgress: nil, coupledSlcAveragePEProgress: nil,
                coupledMaximumIntervalCount: 0, coupledTlcMaximumPEProgress: nil,
                coupledSlcMaximumPEProgress: nil, hostUnitState: .unavailable,
                tlcHostBytesPerPE: nil, slcHostBytesPerPE: nil,
                tlcHostBytesPerMaximumPE: nil, slcHostBytesPerMaximumPE: nil, medianWAF: nil,
                tlcSlopeCoefficientOfVariation: nil, slcSlopeCoefficientOfVariation: nil,
                seriesIdentity: nil, latestInstrumentIdentity: nil,
                unavailableReason: "連続性を満たすFTL履歴がありません", hostBytesObserved: 0, instrumentBoundaries: [])
        }
        let latestIdentity = ControllerWearSeriesIdentity(snapshot: last)
        let latestSeries = Array(seriesCandidates.reversed().prefix { ControllerWearSeriesIdentity(snapshot: $0) == latestIdentity }.reversed())
        let newest = last
        let effectiveExcluding = excluding + lane.rateLearningExclusions
        var intervals: [(start: ASPToolDiagnosticsSnapshot, end: ASPToolDiagnosticsSnapshot)] = []
        var anchor: ASPToolDiagnosticsSnapshot?
        for sample in latestSeries {
            guard sample.captureQuality != .unknown,
                  sample.hostWritesUnitState.supportsIntervalComparison,
                  sample.nandWritesUnitState.supportsIntervalComparison,
                  sample.hostWrittenBytes != nil,
                  sample.nandWrittenBytes != nil else { anchor = nil; continue }
            guard let previous = anchor else { anchor = sample; continue }
            guard let previousDeviceID = previous.deviceID,
                  previousDeviceID == sample.deviceID,
                  Self.monotonic(previous.tlcAveragePE, sample.tlcAveragePE),
                  Self.monotonic(previous.slcAveragePE, sample.slcAveragePE),
                  Self.monotonic(previous.tlcMaximumPE, sample.tlcMaximumPE),
                  Self.monotonic(previous.slcMaximumPE, sample.slcMaximumPE),
                  let before = previous.hostWrittenBytes,
                  let after = sample.hostWrittenBytes,
                  after >= before
            else {
                intervals.removeAll(keepingCapacity: true)
                anchor = sample
                continue
            }
            guard sample.capturedAt.timeIntervalSince(previous.capturedAt) >= (provisional ? 0.001 : ControllerEOLAnalyzer.minimumInterval),
                  after - before >= (provisional ? 0.001 : ControllerEOLAnalyzer.minimumHostWriteDelta),
                  Self.wearAdvanced(previous, sample)
            else { continue }
            let interval = DateInterval(start: previous.capturedAt, end: sample.capturedAt)
            guard !effectiveExcluding.contains(where: { $0.intersects(interval) }) else {
                anchor = sample
                continue
            }
            intervals.append((previous, sample))
            anchor = sample
        }

        let tlc = intervals.compactMap { item -> Double? in
            guard let a = item.start.tlcAveragePE, let b = item.end.tlcAveragePE, b > a,
                  let before = item.start.hostWrittenBytes, let after = item.end.hostWrittenBytes else { return nil }
            return (after - before) / (b - a)
        }
        let slc = intervals.compactMap { item -> Double? in
            guard let a = item.start.slcAveragePE, let b = item.end.slcAveragePE, b > a,
                  let before = item.start.hostWrittenBytes, let after = item.end.hostWrittenBytes else { return nil }
            return (after - before) / (b - a)
        }
        let tlcIntervalCount = intervals.filter { item in
            guard let before = item.start.tlcAveragePE, let after = item.end.tlcAveragePE else { return false }
            return after > before
        }.count
        let slcIntervalCount = intervals.filter { item in
            guard let before = item.start.slcAveragePE, let after = item.end.slcAveragePE else { return false }
            return after > before
        }.count
        let tlcMaximum = maximumSlope(intervals, start: \.tlcMaximumPE, end: \.tlcMaximumPE)
        let slcMaximum = maximumSlope(intervals, start: \.slcMaximumPE, end: \.slcMaximumPE)
        let waf = intervals.compactMap { item -> Double? in
            guard let host0 = item.start.hostWrittenBytes, let host1 = item.end.hostWrittenBytes,
                  let nand0 = item.start.nandWrittenBytes, let nand1 = item.end.nandWrittenBytes,
                  host1 > host0, nand1 >= nand0 else { return nil }
            return (nand1 - nand0) / (host1 - host0)
        }
        let days = intervals.reduce(0.0) { $0 + $1.end.capturedAt.timeIntervalSince($1.start.capturedAt) / 86_400 }
        let hostBytesObserved = intervals.reduce(0.0) {
            guard let before = $1.start.hostWrittenBytes, let after = $1.end.hostWrittenBytes else { return $0 }
            return $0 + max(0, after - before)
        }
        let tlcProgress = zip(intervals.map(\.start.tlcAveragePE), intervals.map(\.end.tlcAveragePE))
            .compactMap { start, end -> Double? in guard let start, let end else { return nil }; return end - start }
            .reduce(0, +)
        let slcProgress = zip(intervals.map(\.start.slcAveragePE), intervals.map(\.end.slcAveragePE))
            .compactMap { start, end -> Double? in guard let start, let end else { return nil }; return end - start }
            .reduce(0, +)
        let tlcMaximumProgress = peProgress(intervals, start: \.tlcMaximumPE, end: \.tlcMaximumPE)
        let slcMaximumProgress = peProgress(intervals, start: \.slcMaximumPE, end: \.slcMaximumPE)
        let coupledAverage = pairedProgress(
            intervals,
            tlcStart: \.tlcAveragePE,
            tlcEnd: \.tlcAveragePE,
            slcStart: \.slcAveragePE,
            slcEnd: \.slcAveragePE
        )
        let coupledMaximum = pairedProgress(
            intervals,
            tlcStart: \.tlcMaximumPE,
            tlcEnd: \.tlcMaximumPE,
            slcStart: \.slcMaximumPE,
            slcEnd: \.slcMaximumPE
        )
        let hasTLCProjectionInputs = newest.tlcAveragePE != nil && newest.tlcEOLPE != nil
        let hasSLCProjectionInputs = newest.slcAveragePE != nil && newest.slcEOLPE != nil
        let missingRequiredDomainSlope =
            (hasTLCProjectionInputs && tlc.isEmpty) ||
            (hasSLCProjectionInputs && slc.isEmpty)
        let unavailableReason: String?
        if intervals.count < 2 {
            unavailableReason = "24時間・1 TB・P/E進行を満たす日常区間が2本未満です"
        } else if missingRequiredDomainSlope {
            unavailableReason = "必要domainの平均P/E進行が不足しています"
        } else {
            unavailableReason = nil
        }
        return ControllerWearHistorySummary(
            intervalCount: intervals.count,
            tlcIntervalCount: tlcIntervalCount,
            slcIntervalCount: slcIntervalCount,
            tlcMaximumIntervalCount: tlcMaximum.count,
            slcMaximumIntervalCount: slcMaximum.count,
            observationDays: days,
            tlcPEProgress: tlcProgress > 0 ? tlcProgress : nil,
            slcPEProgress: slcProgress > 0 ? slcProgress : nil,
            tlcMaximumPEProgress: tlcMaximumProgress,
            slcMaximumPEProgress: slcMaximumProgress,
            coupledAverageIntervalCount: coupledAverage.count,
            coupledTlcAveragePEProgress: coupledAverage.tlc > 0 ? coupledAverage.tlc : nil,
            coupledSlcAveragePEProgress: coupledAverage.slc > 0 ? coupledAverage.slc : nil,
            coupledMaximumIntervalCount: coupledMaximum.count,
            coupledTlcMaximumPEProgress: coupledMaximum.tlc > 0 ? coupledMaximum.tlc : nil,
            coupledSlcMaximumPEProgress: coupledMaximum.slc > 0 ? coupledMaximum.slc : nil,
            hostUnitState: newest.hostWritesUnitState,
            tlcHostBytesPerPE: aggregateSlopes ? aggregateSlope(intervals, key: \.tlcAveragePE) : Self.median(tlc),
            slcHostBytesPerPE: aggregateSlopes ? aggregateSlope(intervals, key: \.slcAveragePE) : Self.median(slc),
            tlcHostBytesPerMaximumPE: aggregateSlopes ? aggregateSlope(intervals, key: \.tlcMaximumPE) : Self.median(tlcMaximum),
            slcHostBytesPerMaximumPE: aggregateSlopes ? aggregateSlope(intervals, key: \.slcMaximumPE) : Self.median(slcMaximum),
            medianWAF: Self.median(waf),
            tlcSlopeCoefficientOfVariation: Self.coefficientOfVariation(tlc),
            slcSlopeCoefficientOfVariation: Self.coefficientOfVariation(slc),
            seriesIdentity: latestIdentity,
            latestInstrumentIdentity: InstrumentIdentity.resolved(from: newest, smartHistory: smartHistory).identity,
            unavailableReason: unavailableReason,
            hostBytesObserved: hostBytesObserved,
            instrumentBoundaries: lane.boundaries
        )
    }

    private func aggregateSlope(_ intervals: [(start: ASPToolDiagnosticsSnapshot, end: ASPToolDiagnosticsSnapshot)],
                                key: KeyPath<ASPToolDiagnosticsSnapshot, Double?>) -> Double? {
        var host = 0.0, pe = 0.0
        for item in intervals {
            guard let a = item.start[keyPath: key], let b = item.end[keyPath: key], b >= a,
                  let h0 = item.start.hostWrittenBytes, let h1 = item.end.hostWrittenBytes else { continue }
            host += h1 - h0; pe += b - a
        }
        let value = host / pe
        return pe > 0 && value.isFinite && value > 0 ? value : nil
    }

    private static func monotonic(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) { case let (.some(a), .some(b)): return b >= a; case (.none, .none): return true; default: return false }
    }

    private static func wearAdvanced(_ lhs: ASPToolDiagnosticsSnapshot, _ rhs: ASPToolDiagnosticsSnapshot) -> Bool {
        if let before = lhs.tlcAveragePE, let after = rhs.tlcAveragePE, after > before { return true }
        if let before = lhs.slcAveragePE, let after = rhs.slcAveragePE, after > before { return true }
        if let before = lhs.tlcMaximumPE, let after = rhs.tlcMaximumPE, after > before { return true }
        if let before = lhs.slcMaximumPE, let after = rhs.slcMaximumPE, after > before { return true }
        return false
    }

    private func maximumSlope(
        _ intervals: [(start: ASPToolDiagnosticsSnapshot, end: ASPToolDiagnosticsSnapshot)],
        start: KeyPath<ASPToolDiagnosticsSnapshot, Double?>,
        end: KeyPath<ASPToolDiagnosticsSnapshot, Double?>
    ) -> [Double] {
        intervals.compactMap { item in
            guard let before = item.start[keyPath: start],
                  let after = item.end[keyPath: end], after > before,
                  let hostBefore = item.start.hostWrittenBytes,
                  let hostAfter = item.end.hostWrittenBytes, hostAfter > hostBefore else { return nil }
            return (hostAfter - hostBefore) / (after - before)
        }
    }

    private func peProgress(
        _ intervals: [(start: ASPToolDiagnosticsSnapshot, end: ASPToolDiagnosticsSnapshot)],
        start: KeyPath<ASPToolDiagnosticsSnapshot, Double?>,
        end: KeyPath<ASPToolDiagnosticsSnapshot, Double?>
    ) -> Double? {
        let progress = intervals.compactMap { item -> Double? in
            guard let before = item.start[keyPath: start],
                  let after = item.end[keyPath: end], after > before else { return nil }
            return after - before
        }.reduce(0, +)
        return progress > 0 ? progress : nil
    }

    private func pairedProgress(
        _ intervals: [(start: ASPToolDiagnosticsSnapshot, end: ASPToolDiagnosticsSnapshot)],
        tlcStart: KeyPath<ASPToolDiagnosticsSnapshot, Double?>,
        tlcEnd: KeyPath<ASPToolDiagnosticsSnapshot, Double?>,
        slcStart: KeyPath<ASPToolDiagnosticsSnapshot, Double?>,
        slcEnd: KeyPath<ASPToolDiagnosticsSnapshot, Double?>
    ) -> (count: Int, tlc: Double, slc: Double) {
        let pairs = intervals.compactMap { item -> (Double, Double)? in
            guard let tlc0 = item.start[keyPath: tlcStart], let tlc1 = item.end[keyPath: tlcEnd],
                  let slc0 = item.start[keyPath: slcStart], let slc1 = item.end[keyPath: slcEnd],
                  tlc1 >= tlc0, slc1 >= slc0,
                  tlc1 > tlc0 || slc1 > slc0 else { return nil }
            return (tlc1 - tlc0, slc1 - slc0)
        }
        return (
            pairs.count,
            pairs.reduce(0) { $0 + $1.0 },
            pairs.reduce(0) { $0 + $1.1 }
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return nil }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance) / mean
    }
}
