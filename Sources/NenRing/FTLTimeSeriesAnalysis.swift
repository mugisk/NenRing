import Foundation

/// Metrics derived from cumulative Direct FTL observations.  The raw
/// counters remain the source of truth; these values are intentionally
/// recomputable and are not used as a TBW multiplier.
enum FTLTimeSeriesMetric: String, CaseIterable, Hashable, Sendable {
    case observedWAF
    case reducedReadVerifyPerNANDRead
    case reducedReadVerifyPerOperatingDay
    case reducedReadVerifyPerWallDay
    case ageRefreshPerDay
    case backgroundRefreshPerDay
    case ageRefreshPerOperatingDay
    case ageRefreshPerWallDay
    case backgroundRefreshPerOperatingDay
    case backgroundRefreshPerWallDay
    case crossTemperatureUECCPerNANDRead
    case crossTemperatureUECCPerOperatingDay
    case crossTemperatureUECCPerWallDay
    case UECCPerNANDRead
    case UECCPerOperatingDay
    case UECCPerWallDay
    case grownBadBlocksPerDay
    case grownBadBlocksPerOperatingDay
    case grownBadBlocksPerWallDay
    case crossTemperatureTailFraction

    var title: String {
        switch self {
        case .observedWAF: return "区間WAF"
        case .reducedReadVerifyPerNANDRead: return "Reduced read verify / ΔnandReads counter"
        case .reducedReadVerifyPerOperatingDay: return "Reduced read verify / operating day"
        case .reducedReadVerifyPerWallDay: return "Reduced read verify / wall day"
        case .ageRefreshPerDay: return "Age refresh / selected day"
        case .backgroundRefreshPerDay: return "Background refresh / selected day"
        case .ageRefreshPerOperatingDay: return "Age refresh / operating day"
        case .ageRefreshPerWallDay: return "Age refresh / wall day"
        case .backgroundRefreshPerOperatingDay: return "Background refresh / operating day"
        case .backgroundRefreshPerWallDay: return "Background refresh / wall day"
        case .crossTemperatureUECCPerNANDRead: return "Cross-temperature UECC / ΔnandReads counter"
        case .crossTemperatureUECCPerOperatingDay: return "Cross-temperature UECC / operating day"
        case .crossTemperatureUECCPerWallDay: return "Cross-temperature UECC / wall day"
        case .UECCPerNANDRead: return "UECC / ΔnandReads counter"
        case .UECCPerOperatingDay: return "UECC / operating day"
        case .UECCPerWallDay: return "UECC / wall day"
        case .grownBadBlocksPerDay: return "Grown bad blocks / selected day"
        case .grownBadBlocksPerOperatingDay: return "Grown bad blocks / operating day"
        case .grownBadBlocksPerWallDay: return "Grown bad blocks / wall day"
        case .crossTemperatureTailFraction: return "Cross-temperature histogram tail"
        }
    }

    var isOperatingDayMetric: Bool {
        switch self {
        case .reducedReadVerifyPerOperatingDay,
             .ageRefreshPerOperatingDay,
             .backgroundRefreshPerOperatingDay,
             .crossTemperatureUECCPerOperatingDay,
             .UECCPerOperatingDay,
             .grownBadBlocksPerOperatingDay:
            return true
        default:
            return false
        }
    }

    var isWallDayMetric: Bool {
        switch self {
        case .reducedReadVerifyPerWallDay,
             .ageRefreshPerWallDay,
             .backgroundRefreshPerWallDay,
             .crossTemperatureUECCPerWallDay,
             .UECCPerWallDay,
             .grownBadBlocksPerWallDay:
            return true
        default:
            return false
        }
    }
}

/// Temporal meaning of a private histogram.  A buffer being monotonic is not
/// enough to prove that it is cumulative; the semantic contract must say so.
enum FTLHistogramTemporalSemantics: String, Codable, CaseIterable, Equatable, Sendable {
    case opaqueSnapshot
    case cumulativeCandidate
    case verifiedCumulative

    var title: String {
        switch self {
        case .opaqueSnapshot: return "opaque snapshot"
        case .cumulativeCandidate: return "cumulative candidate"
        case .verifiedCumulative: return "verified cumulative"
        }
    }

    var detail: String {
        switch self {
        case .opaqueSnapshot:
            return "時系列差分・相関には使用しません。"
        case .cumulativeCandidate:
            return "単調性は保持しますが、差分は実験用に限定します。"
        case .verifiedCumulative:
            return "同形状・同系列の差分とrateへ使用できます。"
        }
    }
}

struct FTLHistogramDelta: Equatable, Sendable, Identifiable {
    let histogram: FTLResearchHistogram
    let seriesID: String?
    let startAt: Date
    let endAt: Date
    /// Bins remain opaque private-buffer indexes.  They are never converted
    /// to Celsius or otherwise assigned a semantic axis here.
    let bins: [UInt64]
    let summary: FTLHistogramSummary
    let temporalSemantics: FTLHistogramTemporalSemantics

    init(
        histogram: FTLResearchHistogram,
        seriesID: String? = nil,
        startAt: Date,
        endAt: Date,
        bins: [UInt64],
        summary: FTLHistogramSummary,
        temporalSemantics: FTLHistogramTemporalSemantics = .cumulativeCandidate
    ) {
        self.histogram = histogram
        self.seriesID = seriesID
        self.startAt = startAt
        self.endAt = endAt
        self.bins = bins
        self.summary = summary
        self.temporalSemantics = temporalSemantics
    }

    var id: String { "\(histogram.rawValue)|\(startAt.timeIntervalSinceReferenceDate)|\(endAt.timeIntervalSinceReferenceDate)" }
}

enum FTLTimeSeriesReliabilityEventType: String, CaseIterable, Codable, Sendable {
    case crossTemperatureUECC
    case crossTemperatureRaidUECC
    case utilityUECC
    case UECC
    case hostPSLCReadVerifyFailure
    case hostTLCReadVerifyFailure
    case gcPSLCToTLCReadVerifyFailure
    case gcTLCToTLCReadVerifyFailure
    case grownBadBlocks
    case dieFailures

    var title: String {
        switch self {
        case .crossTemperatureUECC: return "Cross-temperature UECC"
        case .crossTemperatureRaidUECC: return "Cross-temperature RAID UECC"
        case .utilityUECC: return "Utility UECC"
        case .UECC: return "UECC"
        case .hostPSLCReadVerifyFailure: return "Host pSLC read verify failure"
        case .hostTLCReadVerifyFailure: return "Host TLC read verify failure"
        case .gcPSLCToTLCReadVerifyFailure: return "GC pSLC→TLC read verify failure"
        case .gcTLCToTLCReadVerifyFailure: return "GC TLC→TLC read verify failure"
        case .grownBadBlocks: return "Grown bad blocks"
        case .dieFailures: return "Die failures"
        }
    }
}

/// Stable identity for a reliability event.  The persisted `id` field from
/// older journals is retained for compatibility, but deduplication uses the
/// observation identity rather than that legacy display identifier.
private func ftlReliabilityEventIdentityKey(
    deviceID: String?,
    firmwareEpoch: String?,
    semanticContractVersion: String?,
    type: FTLTimeSeriesReliabilityEventType,
    intervalStart: Date,
    intervalEnd: Date,
    delta: UInt64
) -> String {
    func dateKey(_ date: Date) -> String {
        String(Int64((date.timeIntervalSinceReferenceDate * 1_000_000).rounded()))
    }

    return [
        deviceID ?? "<unknown-device>",
        firmwareEpoch ?? "<unknown-firmware>",
        semanticContractVersion ?? "<unknown-contract>",
        type.rawValue,
        dateKey(intervalStart),
        dateKey(intervalEnd),
        String(delta)
    ].joined(separator: "|")
}

struct FTLTimeSeriesReliabilityEvent: Equatable, Sendable, Identifiable {
    let seriesID: String?
    let type: FTLTimeSeriesReliabilityEventType
    let intervalStart: Date
    let intervalEnd: Date
    let detectedAt: Date
    let delta: UInt64
    let deviceID: String?
    let firmwareEpoch: String?
    let semanticContractVersion: String?
    let tlcPE: Double?
    let pslcPE: Double?
    let nandReadsSincePrevious: UInt64?
    let temperatureSummary: FTLTemperatureIntervalSummary?
    var runtimeBuild: String? = nil
    var contractBuild: String? = nil
    var provisionalInterpretation: Bool? = nil

    /// Compatibility alias for older consumers. New UI should use the
    /// interval and detectedAt values explicitly.
    var capturedAt: Date { detectedAt }
    /// Compatibility alias. This is the rounded interval average, never a
    /// claim that the event occurred at an exact temperature.
    var temperatureCelsius: Int? {
        guard let average = temperatureSummary?.averageCelsius else { return nil }
        return Int(average.rounded())
    }

    var id: String {
        ftlReliabilityEventIdentityKey(
            deviceID: deviceID,
            firmwareEpoch: firmwareEpoch,
            semanticContractVersion: semanticContractVersion,
            type: type,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            delta: delta
        )
    }
}

struct FTLTemperatureIntervalSummary: Equatable, Sendable, Codable {
    let minimumCelsius: Int
    let averageCelsius: Double
    let maximumCelsius: Int
    let sampleCount: Int
    let usedNearestFallback: Bool
}

/// A durable, independent record of a reliability event. It is intentionally
/// not part of the compacted raw snapshot file so long-lived hard events do
/// not disappear when high-frequency telemetry is compacted.
struct FTLReliabilityEventRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let intervalStart: Date
    let intervalEnd: Date
    let detectedAt: Date
    let seriesID: String?
    let type: FTLTimeSeriesReliabilityEventType
    let delta: UInt64
    let deviceID: String?
    let firmwareEpoch: String?
    let semanticContractVersion: String?
    let tlcPE: Double?
    let pslcPE: Double?
    let nandReadsSincePrevious: UInt64?
    let temperatureSummary: FTLTemperatureIntervalSummary?
    var runtimeBuild: String? = nil
    var contractBuild: String? = nil
    var provisionalInterpretation: Bool? = nil

    init(event: FTLTimeSeriesReliabilityEvent, semanticContractVersion: String?) {
        self.id = event.id
        self.intervalStart = event.intervalStart
        self.intervalEnd = event.intervalEnd
        self.detectedAt = event.detectedAt
        self.seriesID = event.seriesID
        self.type = event.type
        self.delta = event.delta
        self.deviceID = event.deviceID
        self.firmwareEpoch = event.firmwareEpoch
        self.semanticContractVersion = event.semanticContractVersion ?? semanticContractVersion
        self.tlcPE = event.tlcPE
        self.pslcPE = event.pslcPE
        self.nandReadsSincePrevious = event.nandReadsSincePrevious
        self.temperatureSummary = event.temperatureSummary
        self.runtimeBuild = event.runtimeBuild
        self.contractBuild = event.contractBuild
        self.provisionalInterpretation = event.provisionalInterpretation
    }

    /// Identity used when a raw event is compared with a record read from the
    /// journal.  This deliberately includes the device/firmware/semantic
    /// boundary so an identical counter delta from another series is not
    /// silently discarded.
    var deduplicationKey: String {
        ftlReliabilityEventIdentityKey(
            deviceID: deviceID,
            firmwareEpoch: firmwareEpoch,
            semanticContractVersion: semanticContractVersion,
            type: type,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            delta: delta
        )
    }

    /// The counter this event belongs to. Records in the same lane count
    /// increments of the same counter.
    private var laneKey: String {
        [deviceID ?? "<unknown-device>", firmwareEpoch ?? "<unknown-firmware>",
         semanticContractVersion ?? "<unknown-contract>", type.rawValue].joined(separator: "|")
    }

    /// Removes from `derived` the increments that `known` records already
    /// count. Compaction only removes snapshots, so an event re-derived over
    /// a merged interval contains the intervals of the events found before.
    /// Their deltas are subtracted; a remaining increment is kept with the
    /// remaining delta, and a fully counted event is dropped.
    static func uncovered(_ derived: [Self], by known: [Self]) -> [Self] {
        let knownByLane = Dictionary(grouping: known, by: \.laneKey)
        let knownKeys = Set(known.map(\.deduplicationKey))
        return derived.compactMap { record in
            if knownKeys.contains(record.deduplicationKey) { return record }
            let counted = (knownByLane[record.laneKey] ?? []).reduce(UInt64(0)) { sum, other in
                guard other.intervalStart >= record.intervalStart, other.intervalEnd <= record.intervalEnd else {
                    return sum
                }
                return sum &+ other.delta
            }
            guard counted > 0 else { return record }
            guard counted < record.delta else { return nil }
            return Self(event: record.event(delta: record.delta - counted),
                        semanticContractVersion: record.semanticContractVersion)
        }
    }

    var event: FTLTimeSeriesReliabilityEvent { event(delta: delta) }

    private func event(delta: UInt64) -> FTLTimeSeriesReliabilityEvent {
        FTLTimeSeriesReliabilityEvent(
            seriesID: seriesID,
            type: type,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            detectedAt: detectedAt,
            delta: delta,
            deviceID: deviceID,
            firmwareEpoch: firmwareEpoch,
            semanticContractVersion: semanticContractVersion,
            tlcPE: tlcPE,
            pslcPE: pslcPE,
            nandReadsSincePrevious: nandReadsSincePrevious,
            temperatureSummary: temperatureSummary,
            runtimeBuild: runtimeBuild, contractBuild: contractBuild,
            provisionalInterpretation: provisionalInterpretation
        )
    }
}

enum FTLIntervalResidualStatus: String, Codable, Equatable, Sendable {
    case resolved
    case indeterminateByPEQuantization
    case unavailable

    var title: String {
        switch self {
        case .resolved: return "量子化範囲内で判定"
        case .indeterminateByPEQuantization: return "P/E量子化で判定不能"
        case .unavailable: return "未算出"
        }
    }
}

/// Per-interval residual between the measured NAND counter and the portion
/// reconstructable from the Direct topology and average P/E deltas. The
/// residual is diagnostic only: it is never assigned to band 0, a domain, or
/// the endurance budget. Refresh counters remain beside it for later paired
/// observation.
struct FTLIntervalResidualDiagnostics: Equatable, Sendable {
    let measuredNANDBytes: Double
    let knownDomainNANDLowBytes: Double
    let knownDomainNANDBestBytes: Double
    let knownDomainNANDHighBytes: Double
    let signedResidualLowBytes: Double
    let signedResidualBestBytes: Double
    let signedResidualHighBytes: Double
    let equivalentPSLCBands: Double?
    let tlcPEDelta: Double
    let pslcPEDelta: Double
    let ageRefreshDelta: UInt64?
    let backgroundRefreshDelta: UInt64?
    let bandsPaddedForAgeDelta: UInt64?
    let bandsRefreshedOnErrorDelta: UInt64?
    /// Optional calibrated key-349/350 path. This remains diagnostic and is
    /// never folded into the interval budget or Forecast WAF.
    let bandPath: FTLBandPathResidualDiagnostics?
    let status: FTLIntervalResidualStatus
    let note: String

    /// Backward-compatible best estimate used by existing callers.
    var tlcEstimatedWrittenBytes: Double? = nil
    var pslcEstimatedWrittenBytes: Double? = nil

    /// Backward-compatible best estimate used by existing callers.
    var knownDomainNANDBytes: Double { knownDomainNANDBestBytes }
    /// Backward-compatible best estimate used by existing callers.
    var signedResidualBytes: Double { signedResidualBestBytes }

}

enum FTLBandPathResidualStatus: String, Equatable, Sendable {
    case resolvedPositive
    case resolvedNegative
    case indeterminate

    var title: String {
        switch self {
        case .resolvedPositive: return "正の残差"
        case .resolvedNegative: return "負の残差"
        case .indeterminate: return "量子化範囲内"
        }
    }
}

/// Residual computed from calibrated band-program counters (keys 349/350).
/// It is intentionally separate from the average-P/E residual because the
/// counters are only meaningful after the long-baseline calibration passes.
struct FTLBandPathResidualDiagnostics: Equatable, Sendable {
    let measuredNANDBytes: Double
    let knownLowBytes: Double
    let knownBestBytes: Double
    let knownHighBytes: Double
    let signedResidualLowBytes: Double
    let signedResidualBestBytes: Double
    let signedResidualHighBytes: Double
    let tlcBandDelta: Double
    let pslcBandDelta: Double
    let status: FTLBandPathResidualStatus
    let note: String
}

struct FTLIntervalObservation: Equatable, Sendable, Identifiable {
    let seriesID: String
    let startAt: Date
    let endAt: Date
    let startSnapshotID: UUID
    let endSnapshotID: UUID
    let durationDays: Double
    let wallDurationDays: Double
    let operatingHoursDelta: Double?
    let durationBasis: FTLDurationBasis
    let deltaHostBytes: Double?
    let deltaNANDBytes: Double?
    let deltaNANDReads: UInt64?
    let observedWAF: Double?
    let tlcPEStart: Double?
    let tlcPEEnd: Double?
    let pslcPEStart: Double?
    let pslcPEEnd: Double?
    let tlcWearBalance: Double?
    let pslcWearBalance: Double?
    let metricValues: [FTLTimeSeriesMetric: Double]
    /// Rates calculated with Power On Hours when available.  Counter/read
    /// ratios are also retained here so callers can inspect one complete
    /// operating-time view without re-running the interval calculation.
    let operatingMetricValues: [FTLTimeSeriesMetric: Double]
    /// Rates calculated over wall-clock exposure.  This is intentionally
    /// separate from `metricValues`, whose compatibility semantics follow the
    /// selected duration basis.
    let wallMetricValues: [FTLTimeSeriesMetric: Double]
    let histogramDeltas: [FTLHistogramDelta]
    let reliabilityEvents: [FTLTimeSeriesReliabilityEvent]
    let intervalResidual: FTLIntervalResidualDiagnostics?
    let hostWriteCompositionAudit: HostWriteCompositionAudit?
    /// Change of the Direct-to-TLC sector counter (writes that skip pSLC).
    /// Nil when the pair fails the provisional scalar-counter comparison.
    var deltaDirectToTLCSectors: UInt64? = nil

    var id: String { "\(startSnapshotID.uuidString)-\(endSnapshotID.uuidString)" }
}

struct FTLPECorrelationPoint: Equatable, Sendable, Identifiable {
    let seriesID: String
    let capturedAt: Date
    let tlcPE: Double
    let metric: FTLTimeSeriesMetric
    let value: Double
    let intervalID: String

    var id: String { "\(intervalID)|\(metric.rawValue)" }
}

struct FTLTimeSeriesSeriesMetadata: Equatable, Sendable, Identifiable {
    let seriesID: String
    let deviceID: String?
    let sourceArtifact: ASPToolSourceArtifact
    let extractionVersion: Int
    let sourceBuild: String?
    let firmwareEpoch: String?
    let directFormatVersion: UInt32?
    let directKeyContractVersion: String?
    let semanticContractVersion: String?
    let coreWearVersion: String?
    let researchTelemetryVersion: String?
    let historySchemaVersion: Int?
    let hostWritesUnitState: ASPToolUnitState
    let nandWritesUnitState: ASPToolUnitState
    let tlcEOLPE: Double?
    let slcEOLPE: Double?

    var id: String { seriesID }
}

struct FTLTimeSeriesGroup: Equatable, Sendable, Identifiable {
    let metadata: FTLTimeSeriesSeriesMetadata
    let snapshotCount: Int
    let latestSnapshotAt: Date
    let intervals: [FTLIntervalObservation]
    let histogramDeltas: [FTLHistogramDelta]
    let reliabilityEvents: [FTLTimeSeriesReliabilityEvent]
    let peCorrelationPoints: [FTLPECorrelationPoint]

    var id: String { metadata.seriesID }
}

struct FTLTimeSeriesAnalytics: Equatable, Sendable {
    static let empty = FTLTimeSeriesAnalytics(
        schemaVersion: 2,
        semanticContractVersion: nil,
        intervals: [],
        histogramDeltas: [],
        reliabilityEvents: [],
        peCorrelationPoints: [],
        series: [],
        latestSeriesID: nil,
        latestComparableSeriesID: nil,
        latestComparableInterval: nil,
        latestSemanticContractVersion: nil,
        calendarSpanDays: nil,
        comparableWallDays: 0,
        comparableOperatingDays: 0,
        histogramSemantics: [:],
        longBaseline: .empty,
        notes: ["Direct FTLの比較可能な履歴がありません。"]
    )

    let schemaVersion: Int
    let semanticContractVersion: String?
    let intervals: [FTLIntervalObservation]
    /// Intervals left out of rate learning (research sessions, post-update
    /// transients). They are real writes, so charts still show them.
    let learningExcludedIntervals: [FTLIntervalObservation]
    let histogramDeltas: [FTLHistogramDelta]
    let reliabilityEvents: [FTLTimeSeriesReliabilityEvent]
    let peCorrelationPoints: [FTLPECorrelationPoint]
    let series: [FTLTimeSeriesGroup]
    let latestSeriesID: String?
    /// Explicit name for `latestSeriesID`, which is retained as a source
    /// compatibility alias and always means the latest observed series.
    var latestObservedSeriesID: String? { latestSeriesID }
    let latestComparableSeriesID: String?
    let latestComparableInterval: FTLIntervalObservation?
    let latestSemanticContractVersion: String?
    let calendarSpanDays: Double?
    let comparableWallDays: Double
    let comparableOperatingDays: Double
    let histogramSemantics: [FTLResearchHistogram: FTLHistogramTemporalSemantics]
    let longBaseline: LongBaselineResidualAnalytics
    let notes: [String]

    /// Calendar span is a context value. Rate calculations use the interval's
    /// duration basis, not this value.
    var observationDays: Double? { calendarSpanDays }

    /// Compatibility alias. New UI should use `latestSeriesLatestInterval` or
    /// `latestComparableInterval` to make the distinction explicit.
    var latestInterval: FTLIntervalObservation? { latestComparableInterval }

    /// The latest interval belonging to the currently observed series. It is
    /// nil immediately after a firmware/contract boundary until that series
    /// has a second comparable snapshot.
    var latestSeriesLatestInterval: FTLIntervalObservation? {
        guard let latestSeriesID else { return nil }
        return intervals.last(where: { $0.seriesID == latestSeriesID })
    }

    /// The most recent valid comparable interval, even if it belongs to an
    /// older series. This is useful as context but must not be labelled
    /// “latest” while a newer series is waiting for its second point.
    var latestAnyComparableInterval: FTLIntervalObservation? { latestComparableInterval }

    init(
        schemaVersion: Int,
        semanticContractVersion: String?,
        intervals: [FTLIntervalObservation],
        learningExcludedIntervals: [FTLIntervalObservation] = [],
        histogramDeltas: [FTLHistogramDelta],
        reliabilityEvents: [FTLTimeSeriesReliabilityEvent],
        peCorrelationPoints: [FTLPECorrelationPoint],
        series: [FTLTimeSeriesGroup] = [],
        latestSeriesID: String? = nil,
        latestComparableSeriesID: String? = nil,
        latestComparableInterval: FTLIntervalObservation? = nil,
        latestSemanticContractVersion: String? = nil,
        calendarSpanDays: Double? = nil,
        comparableWallDays: Double = 0,
        comparableOperatingDays: Double = 0,
        histogramSemantics: [FTLResearchHistogram: FTLHistogramTemporalSemantics] = [:],
        longBaseline: LongBaselineResidualAnalytics = .empty,
        notes: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.semanticContractVersion = semanticContractVersion
        self.intervals = intervals
        self.learningExcludedIntervals = learningExcludedIntervals
        self.histogramDeltas = histogramDeltas
        self.reliabilityEvents = reliabilityEvents
        self.peCorrelationPoints = peCorrelationPoints
        self.series = series
        self.latestSeriesID = latestSeriesID
        self.latestComparableSeriesID = latestComparableSeriesID
        self.latestComparableInterval = latestComparableInterval
        self.latestSemanticContractVersion = latestSemanticContractVersion
        self.calendarSpanDays = calendarSpanDays
        self.comparableWallDays = comparableWallDays
        self.comparableOperatingDays = comparableOperatingDays
        self.histogramSemantics = histogramSemantics
        self.longBaseline = longBaseline
        self.notes = notes
    }

    /// Merges the durable event journal into the raw-snapshot analysis. Raw
    /// events remain the detection source; journal records become the
    /// long-term display source after identity-based deduplication.
    func merging(journalRecords: [FTLReliabilityEventRecord]) -> Self {
        let currentRecords = FTLReliabilityEventRecord.uncovered(reliabilityEvents.map {
            FTLReliabilityEventRecord(event: $0, semanticContractVersion: semanticContractVersion)
        }, by: journalRecords)
        var recordsByIdentity: [String: FTLReliabilityEventRecord] = [:]
        for record in currentRecords + journalRecords {
            // Prefer the journal copy when available: it is the durable
            // record and may outlive the raw interval that found it.
            recordsByIdentity[record.deduplicationKey] = record
        }
        let mergedRecords = recordsByIdentity.values.sorted {
            if $0.intervalStart == $1.intervalStart {
                return $0.deduplicationKey < $1.deduplicationKey
            }
            return $0.intervalStart < $1.intervalStart
        }
        let mergedEvents = mergedRecords.map(\.event)
        let mergedSeries = series.map { group in
            FTLTimeSeriesGroup(
                metadata: group.metadata,
                snapshotCount: group.snapshotCount,
                latestSnapshotAt: group.latestSnapshotAt,
                intervals: group.intervals,
                histogramDeltas: group.histogramDeltas,
                reliabilityEvents: mergedEvents.filter { $0.seriesID == group.id },
                peCorrelationPoints: group.peCorrelationPoints
            )
        }
        var mergedNotes = notes
        if !journalRecords.isEmpty {
            mergedNotes.append("Reliability Event Journalをraw再構築eventとidentity dedupeして統合しました。")
        }
        var seenNotes = Set<String>()
        let uniqueNotes = mergedNotes.filter { seenNotes.insert($0).inserted }
        return Self(
            schemaVersion: schemaVersion,
            semanticContractVersion: semanticContractVersion,
            intervals: intervals,
            learningExcludedIntervals: learningExcludedIntervals,
            histogramDeltas: histogramDeltas,
            reliabilityEvents: mergedEvents,
            peCorrelationPoints: peCorrelationPoints,
            series: mergedSeries,
            latestSeriesID: latestSeriesID,
            latestComparableSeriesID: latestComparableSeriesID,
            latestComparableInterval: latestComparableInterval,
            latestSemanticContractVersion: latestSemanticContractVersion,
            calendarSpanDays: calendarSpanDays,
            comparableWallDays: comparableWallDays,
            comparableOperatingDays: comparableOperatingDays,
            histogramSemantics: histogramSemantics,
            longBaseline: longBaseline,
            notes: uniqueNotes
        )
    }

}

/// A detected burst is advisory: unique events are still persisted so storm
/// detection never becomes an accidental retention policy.
struct FTLReliabilityEventStorm: Equatable, Sendable {
    let detectedAt: Date
    let incomingEventCount: Int
    let uniqueEventCount: Int
    let recentEventCount: Int
    let deviceIDs: [String]
}

struct FTLReliabilityEventJournalAppendResult: Equatable, Sendable {
    let appendedCount: Int
    let duplicateCount: Int
    let eventStorm: FTLReliabilityEventStorm?
}

struct FTLReliabilityEventJournalDiagnostics: Equatable, Sendable {
    let recordCount: Int
    let latestEventStorm: FTLReliabilityEventStorm?
    let lastErrorDescription: String?
    let recoveredFromCorruption: Bool
    let lastQuarantinedCorruptionPath: String?
}

enum FTLReliabilityEventJournalError: Error, LocalizedError, Sendable {
    case corruptedFile(path: String, line: Int)
    case unrecoverableCorruption(path: String, backupPath: String?)
    case backupFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case quarantineFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .corruptedFile(path, line):
            return "Reliability Event JournalのJSONLが壊れています: \(path)（\(line)行目）"
        case let .unrecoverableCorruption(path, backupPath):
            let backup = backupPath.map { "、バックアップ: \($0)" } ?? ""
            return "Reliability Event Journalを復旧できませんでした: \(path)\(backup)"
        case let .backupFailed(path, reason):
            return "Reliability Event Journalの旧データ退避に失敗しました: \(path)（\(reason)）"
        case let .writeFailed(path, reason):
            return "Reliability Event Journalの保存に失敗しました: \(path)（\(reason)）"
        case let .quarantineFailed(path, reason):
            return "壊れたReliability Event Journalの隔離に失敗しました: \(path)（\(reason)）"
        }
    }
}

/// Long-lived journal for hard reliability events. This is deliberately a
/// separate JSONL file from the high-frequency FTL snapshot history. It has
/// no retention cap; raw event history is permanent unless the user removes
/// the application-support file explicitly.
actor FTLReliabilityEventJournal {
    static let eventStormBatchThreshold = 256
    static let eventStormWindowThreshold = 1_024
    static let eventStormWindow: TimeInterval = 60

    let fileURL: URL
    private var cache: [FTLReliabilityEventRecord]?
    private var latestEventStorm: FTLReliabilityEventStorm?
    private var lastErrorDescription: String?
    private var recoveredFromCorruption = false
    private var lastQuarantinedCorruptionPath: String?

    /// `maximumRecordCount` is retained as an ignored compatibility argument
    /// for callers from the capped-journal implementation. The journal is
    /// intentionally unbounded and never prunes records.
    init(fileURL: URL? = nil, maximumRecordCount: Int? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        _ = maximumRecordCount
    }

    func records() throws -> [FTLReliabilityEventRecord] {
        try ensureLoaded()
    }

    /// Returns only records belonging to the currently selected device.
    ///
    /// The dashboard must not render the complete journal when the current
    /// device is not known yet: an unknown device is not a valid filter and
    /// returning an empty result is safer than mixing histories from another
    /// SSD into the current one.
    func records(for deviceID: String?) throws -> [FTLReliabilityEventRecord] {
        guard let deviceID, !deviceID.isEmpty else { return [] }
        return try ensureLoaded().filter { $0.deviceID == deviceID }
    }

    @discardableResult
    func appendIfNew(_ newRecords: [FTLReliabilityEventRecord]) throws -> Int {
        try appendIfNewReportingOutcome(newRecords).appendedCount
    }

    /// Appends every unique event and reports a burst without dropping it.
    /// This keeps permanent retention and storm detection independent: a
    /// malformed collector cannot silently turn a warning into data loss.
    func appendIfNewReportingOutcome(
        _ newRecords: [FTLReliabilityEventRecord]
    ) throws -> FTLReliabilityEventJournalAppendResult {
        guard !newRecords.isEmpty else {
            return FTLReliabilityEventJournalAppendResult(
                appendedCount: 0,
                duplicateCount: 0,
                eventStorm: nil
            )
        }

        do {
            var current = try ensureLoaded()
            var knownKeys = Set(current.map(\.deduplicationKey))
            let additions = FTLReliabilityEventRecord.uncovered(newRecords, by: current)
                .filter { knownKeys.insert($0.deduplicationKey).inserted }
            let duplicateCount = newRecords.count - additions.count
            let now = Date()
            let windowStart = now.addingTimeInterval(-Self.eventStormWindow)
            let recentEventCount = current.reduce(into: 0) { count, record in
                if record.detectedAt >= windowStart { count += 1 }
            } + additions.reduce(into: 0) { count, record in
                if record.detectedAt >= windowStart { count += 1 }
            }
            // Callers pass the merged list, which repeats every journaled
            // event, so only events new to the journal count toward a storm.
            let eventStorm: FTLReliabilityEventStorm? =
                additions.count >= Self.eventStormBatchThreshold ||
                recentEventCount >= Self.eventStormWindowThreshold
                ? FTLReliabilityEventStorm(
                    detectedAt: now,
                    incomingEventCount: newRecords.count,
                    uniqueEventCount: additions.count,
                    recentEventCount: recentEventCount,
                    deviceIDs: Array(Set(additions.compactMap(\.deviceID)).sorted())
                )
                : nil
            if let eventStorm {
                latestEventStorm = eventStorm
            }

            guard !additions.isEmpty else {
                lastErrorDescription = nil
                return FTLReliabilityEventJournalAppendResult(
                    appendedCount: 0,
                    duplicateCount: duplicateCount,
                    eventStorm: eventStorm
                )
            }

            current.append(contentsOf: additions)
            current.sort { lhs, rhs in
                if lhs.detectedAt == rhs.detectedAt { return lhs.deduplicationKey < rhs.deduplicationKey }
                return lhs.detectedAt < rhs.detectedAt
            }
            try write(current, preservingPreviousAsBackup: true)
            cache = current
            lastErrorDescription = nil
            return FTLReliabilityEventJournalAppendResult(
                appendedCount: additions.count,
                duplicateCount: duplicateCount,
                eventStorm: eventStorm
            )
        } catch {
            // The in-memory cache must never claim that an append succeeded
            // when the atomic write or its backup failed. Reload on the next
            // operation so a partial filesystem result is diagnosed there.
            cache = nil
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func diagnostics() -> FTLReliabilityEventJournalDiagnostics {
        let recordCount = (try? ensureLoaded().count) ?? cache?.count ?? 0
        return FTLReliabilityEventJournalDiagnostics(
            recordCount: recordCount,
            latestEventStorm: latestEventStorm,
            lastErrorDescription: lastErrorDescription,
            recoveredFromCorruption: recoveredFromCorruption,
            lastQuarantinedCorruptionPath: lastQuarantinedCorruptionPath
        )
    }

    private func ensureLoaded() throws -> [FTLReliabilityEventRecord] {
        if let cache { return cache }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            if fileManager.fileExists(atPath: backupURL.path) {
                let recovered = try loadRecords(at: backupURL)
                try write(recovered, preservingPreviousAsBackup: false)
                cache = recovered
                recoveredFromCorruption = true
                return recovered
            }
            cache = []
            return []
        }

        do {
            let loaded = try loadRecords(at: fileURL)
            cache = loaded
            lastErrorDescription = nil
            return loaded
        } catch {
            let quarantinedURL = try quarantineCorruptFile()
            lastQuarantinedCorruptionPath = quarantinedURL.path
            guard fileManager.fileExists(atPath: backupURL.path) else {
                lastErrorDescription = error.localizedDescription
                throw error
            }
            do {
                let recovered = try loadRecords(at: backupURL)
                try write(recovered, preservingPreviousAsBackup: false)
                cache = recovered
                recoveredFromCorruption = true
                lastErrorDescription = nil
                return recovered
            } catch {
                let recoveryError = FTLReliabilityEventJournalError.unrecoverableCorruption(
                    path: fileURL.path,
                    backupPath: backupURL.path
                )
                lastErrorDescription = recoveryError.localizedDescription
                throw recoveryError
            }
        }
    }

    private func loadRecords(at url: URL) throws -> [FTLReliabilityEventRecord] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var seenKeys = Set<String>()
        var loaded: [FTLReliabilityEventRecord] = []
        for (index, line) in lines.enumerated() {
            let isWhitespaceOnly = line.allSatisfy { byte in
                byte == 0x09 || byte == 0x0D || byte == 0x20
            }
            if isWhitespaceOnly {
                if index == lines.count - 1 { continue }
                throw FTLReliabilityEventJournalError.corruptedFile(path: url.path, line: index + 1)
            }
            do {
                let record = try decoder.decode(FTLReliabilityEventRecord.self, from: Data(line))
                if seenKeys.insert(record.deduplicationKey).inserted {
                    loaded.append(record)
                }
            } catch {
                throw FTLReliabilityEventJournalError.corruptedFile(path: url.path, line: index + 1)
            }
        }
        return loaded.sorted {
            if $0.detectedAt == $1.detectedAt { return $0.deduplicationKey < $1.deduplicationKey }
            return $0.detectedAt < $1.detectedAt
        }
    }

    private func write(
        _ records: [FTLReliabilityEventRecord],
        preservingPreviousAsBackup: Bool
    ) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var encoded = Data()
            for record in records {
                encoded.append(try encoder.encode(record))
                encoded.append(0x0A)
            }
            data = encoded
        } catch {
            throw FTLReliabilityEventJournalError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if preservingPreviousAsBackup, FileManager.default.fileExists(atPath: fileURL.path) {
                let previousData = try Data(contentsOf: fileURL)
                try previousData.write(to: backupURL, options: .atomic)
            }
        } catch {
            throw FTLReliabilityEventJournalError.backupFailed(
                path: backupURL.path,
                reason: error.localizedDescription
            )
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw FTLReliabilityEventJournalError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private var backupURL: URL {
        fileURL.appendingPathExtension("bak")
    }

    private func quarantineCorruptFile() throws -> URL {
        let fileManager = FileManager.default
        let quarantineURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).jsonl")
        do {
            try fileManager.copyItem(at: fileURL, to: quarantineURL)
        } catch {
            throw FTLReliabilityEventJournalError.quarantineFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        return quarantineURL
    }

    private static func defaultFileURL() -> URL {
        AppDataLocation.directoryURL
            .appendingPathComponent("ftl-reliability-events.jsonl")
    }
}

/// Converts the retained cumulative FTL history into validated intervals.
/// It intentionally has no side effects and does not alter the endurance
/// forecast. A research/build boundary is evaluated by the shared instrument
/// continuity lane instead of being silently bridged.
struct FTLTimeSeriesAnalyzer: Sendable {
    /// Temperatures split at FTL snapshot times, covering samples that are
    /// no longer kept in memory. Nil uses `temperatureHistory` alone.
    var temperatureTable: TemperatureIntervalTable? = nil

    func analyze(
        snapshots: [ASPToolDiagnosticsSnapshot],
        excluding: [DateInterval] = [],
        temperatureHistory: [TemperatureSample] = [],
        histogramTailStartBin: Int? = nil,
        histogramSemantics: [FTLResearchHistogram: FTLHistogramTemporalSemantics] = [:],
        smartHistory: [DriveSnapshot] = [],
        continuityLane suppliedLane: WearContinuityLane? = nil
    ) -> FTLTimeSeriesAnalytics {
        let rawCandidates = snapshots
            .filter { $0.sourceArtifact.participatesInCoreWearLane && $0.captureQuality != .unknown }
            .sorted { lhs, rhs in
                if lhs.capturedAt == rhs.capturedAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.capturedAt < rhs.capturedAt
            }
        guard !rawCandidates.isEmpty else { return .empty }

        // Use the same continuity lane as the wear/WAF calculators.  A
        // rejected or SMART-pending instrument boundary is therefore visible
        // as a stopped research lane instead of being silently joined by the
        // old build/firmware comparison.
        let laneLatest = rawCandidates.last(where: { $0.sourceArtifact == .directFTL }) ?? rawCandidates.last
        let continuityLane = suppliedLane ?? WearContinuityLaneBuilder.build(
            snapshots: rawCandidates,
            smart: smartHistory,
            latest: laneLatest
        )
        let candidates = continuityLane.snapshots
        guard !candidates.isEmpty else { return .empty }
        let learningExcluding = excluding + continuityLane.rateLearningExclusions

        let longBaseline = FTLLongBaselineResidualAnalyzer().analyze(
            snapshots: candidates,
            excluding: excluding,
            smartHistory: smartHistory,
            continuityLane: continuityLane
        )
        let bandCalibrationVerified = longBaseline.calibration.last?.verified == true
        let analysisTopology = continuityLane.containsTopologylessASPTool
            ? continuityLane.verifiedCoreTopology : nil

        var notes: [String] = []
        var intervals: [FTLIntervalObservation] = []
        var learningExcludedIntervals: [FTLIntervalObservation] = []
        var histogramDeltas: [FTLHistogramDelta] = []
        var events: [FTLTimeSeriesReliabilityEvent] = []
        var correlations: [FTLPECorrelationPoint] = []
        var anchor: ASPToolDiagnosticsSnapshot?
        var contractVersion: String?
        let resolvedHistogramSemantics = Dictionary(uniqueKeysWithValues: FTLResearchHistogram.allCases.map { histogram in
            (histogram, histogramSemantics[histogram] ?? .cumulativeCandidate)
        })

        for current in candidates {
            contractVersion = contractVersion ?? current.semanticContractVersion ?? current.directKeyContractVersion
            guard let previous = anchor else {
                anchor = current
                if current.identityCapturedAt == nil {
                    notes.append("\(current.capturedAt.formatted(date: .numeric, time: .shortened)) のFTLはIORegistry identity時刻なし。旧履歴互換のため保存し、fresh identityとは表示しません。")
                }
                continue
            }

            guard sameWearSeries(previous, current) else {
                notes.append("\(current.capturedAt.formatted(date: .numeric, time: .shortened)) でdevice/coreの対応表/形式または単位が変わったため損耗系列を分割しました。")
                anchor = current
                continue
            }
            let researchComparable = sameResearchSeries(previous, current)
            if !researchComparable {
                if current.researchTelemetry != nil && !DirectFTLResearchContract.researchTelemetryIsEligible(current) {
                    let actual = current.sourceBuild ?? "不明"
                    let expected = DirectFTLResearchContract.contractBuild(for: current) ?? "未確認"
                    notes.append("\(current.capturedAt.formatted(date: .numeric, time: .shortened)) は実行build \(actual) と研究用keyの対応表のbuild \(expected) が未一致。rawは保存し、histogram・研究指標の差分と相関は保留し、scalar異常counterは対応表と連続性検査に従い暫定比較します。コア損耗差分は連続性laneで継続します。")
                } else {
                    notes.append("\(current.capturedAt.formatted(date: .numeric, time: .shortened)) でresearch telemetryの対応表が変わったため、損耗差分は接続し、histogram／reliability／研究key差分のみをその区間で分割しました。")
                }
            }
            let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
            guard current.capturedAt > previous.capturedAt else {
                notes.append("同秒重複または時刻逆転を検出し、比較アンカーを更新しました。")
                anchor = current
                continue
            }
            if learningExcluding.contains(where: { $0.intersects(interval) }) {
                notes.append("研究試験またはfirmware更新直後と重なる区間を時系列学習から除外しました。書込量の表示には含めます。")
                if !seriesCountersWentBackwards(previous, current) {
                    let excludedInterval = makeInterval(
                        previous: previous,
                        current: current,
                        seriesID: seriesID(for: current),
                        temperatureHistory: temperatureHistory,
                        histogramTailStartBin: histogramTailStartBin,
                        histogramSemantics: resolvedHistogramSemantics,
                        bandCalibrationVerified: bandCalibrationVerified,
                        researchComparable: researchComparable,
                        topologyFallback: analysisTopology
                    )
                    learningExcludedIntervals.append(excludedInterval)
                    // Detecting an event is not rate learning; the anchor
                    // moves past this interval, so it is the only chance.
                    events.append(contentsOf: excludedInterval.reliabilityEvents)
                }
                anchor = current
                continue
            }
            guard !seriesCountersWentBackwards(previous, current) else {
                notes.append("Host/NANDまたはPower On Hours累積counterの減少を検出し、reset後のsnapshotを新しいアンカーにしました。")
                anchor = current
                continue
            }

            if researchComparable {
                appendHistogramValidationNotes(
                    previous: previous,
                    current: current,
                    to: &notes
                )
            }

            let observation = makeInterval(
                previous: previous,
                current: current,
                seriesID: seriesID(for: current),
                temperatureHistory: temperatureHistory,
                histogramTailStartBin: histogramTailStartBin,
                histogramSemantics: resolvedHistogramSemantics,
                bandCalibrationVerified: bandCalibrationVerified,
                researchComparable: researchComparable,
                topologyFallback: analysisTopology
            )
            intervals.append(observation)
            histogramDeltas.append(contentsOf: observation.histogramDeltas)
            events.append(contentsOf: observation.reliabilityEvents)
            switch observation.durationBasis {
            case .operatingHours:
                notes.append("区間の日次rateはPower On Hours差分を分母にしました。暦時間は補助表示として保持しています。")
            case .wallClockFallback:
                notes.append("Power On Hours差分がない区間は暦時間をrate分母へfallbackしました。新しいDirect FTL取得では稼働時間を優先します。")
            case .unavailable:
                notes.append("稼働時間・暦時間のどちらも有限な区間長を作れないため、日次rateを算出していません。")
            }
            var correlationIDs = Set<String>()
            func appendCorrelationPoints(from values: [FTLTimeSeriesMetric: Double]) {
                guard let tlcPE = observation.tlcPEEnd else { return }
                for metric in values.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                    guard let value = values[metric], value.isFinite else { continue }
                    let point = FTLPECorrelationPoint(
                        seriesID: observation.seriesID,
                        capturedAt: observation.endAt,
                        tlcPE: tlcPE,
                        metric: metric,
                        value: value,
                        intervalID: observation.id
                    )
                    if correlationIDs.insert(point.id).inserted {
                        correlations.append(point)
                    }
                }
            }
            appendCorrelationPoints(from: observation.metricValues)
            appendCorrelationPoints(from: observation.operatingMetricValues.filter { $0.key.isOperatingDayMetric })
            appendCorrelationPoints(from: observation.wallMetricValues.filter { $0.key.isWallDayMetric })
            anchor = current
        }

        if candidates.contains(where: { $0.sourceArtifact == .directFTL && $0.semanticContractVersion == nil && $0.directKeyContractVersion == nil }) {
            notes.append("semantic contractがない旧Direct FTL履歴は、raw保存・系列境界の確認のみを行いました。")
        }
        if continuityLane.containsTopologylessASPTool {
            notes.append("asptool履歴のDirect topologyは、取得経路境界でD1/D2が検証済みのため、この解析内のみ同一構造として参照しました。raw履歴は未変更です。")
        }
        for boundary in continuityLane.boundaries {
            switch boundary.continuity {
            case .verified:
                notes.append("計測器境界 (\(boundary.boundary.after.formatted(date: .numeric, time: .shortened))) はD1〜D7検証済み。後続の研究差分を接続しました。")
            case .pending:
                notes.append("計測器境界 (\(boundary.boundary.after.formatted(date: .numeric, time: .shortened))) はSMART資料待ちのため、後続の研究差分を保留しました。")
            case .failed:
                notes.append("計測器境界 (\(boundary.boundary.after.formatted(date: .numeric, time: .shortened))) はD1〜D7不一致のため、後続の研究差分を保留しました。")
            case .deviceChange:
                notes.append("デバイス境界 (\(boundary.boundary.after.formatted(date: .numeric, time: .shortened))) の前後を別系列として分離しました。")
            case .reviewed, .sameInstrument:
                break
            }
        }
        if candidates.contains(where: { $0.researchTelemetry?.bandsMaxTempHistogram == nil }) {
            notes.append("histogram未取得のsnapshotがあります。未取得を全binゼロへ置換していません。")
        }
        if resolvedHistogramSemantics.values.contains(.cumulativeCandidate) {
            notes.append("histogramは時系列累積の候補として単調性のみを確認しています。verified cumulativeと確認した対応表がないため、差分は実験用でP/E相関へ投入していません。")
        }
        notes.append("P/E相関は同一区間の記述統計です。区間WAFも含め、主予測のHost換算分母と同じ観測差分を追跡します。将来の故障確率・TBW倍率へ自動変換しません。")

        // Notes carry timestamps, so a long history has many; a linear
        // contains check here grew with the square of the history.
        var seenNotes = Set<String>()
        let uniqueNotes = notes.filter { seenNotes.insert($0).inserted }
        var metadataBySeriesID: [String: FTLTimeSeriesSeriesMetadata] = [:]
        var snapshotCountBySeriesID: [String: Int] = [:]
        var latestSnapshotAtBySeriesID: [String: Date] = [:]
        for snapshot in candidates {
            let metadata = makeSeriesMetadata(snapshot)
            metadataBySeriesID[metadata.seriesID] = metadata
            snapshotCountBySeriesID[metadata.seriesID, default: 0] += 1
            if let latest = latestSnapshotAtBySeriesID[metadata.seriesID] {
                latestSnapshotAtBySeriesID[metadata.seriesID] = max(latest, snapshot.capturedAt)
            } else {
                latestSnapshotAtBySeriesID[metadata.seriesID] = snapshot.capturedAt
            }
        }
        let seriesGroups = metadataBySeriesID.keys.map { seriesID in
            FTLTimeSeriesGroup(
                metadata: metadataBySeriesID[seriesID]!,
                snapshotCount: snapshotCountBySeriesID[seriesID, default: 0],
                latestSnapshotAt: latestSnapshotAtBySeriesID[seriesID] ?? .distantPast,
                intervals: intervals.filter { $0.seriesID == seriesID },
                histogramDeltas: histogramDeltas.filter { $0.seriesID == seriesID },
                reliabilityEvents: events.filter { $0.seriesID == seriesID },
                peCorrelationPoints: correlations.filter { $0.seriesID == seriesID }
            )
        }.sorted { lhs, rhs in
            (lhs.intervals.last?.endAt ?? .distantPast) < (rhs.intervals.last?.endAt ?? .distantPast)
        }
        let calendarSpanDays: Double? = {
            guard let first = candidates.first?.capturedAt, let last = candidates.last?.capturedAt else { return nil }
            let value = last.timeIntervalSince(first) / 86_400
            return value.isFinite && value >= 0 ? value : nil
        }()
        let comparableWallDays = intervals.reduce(0.0) { partial, interval in
            partial + (interval.wallDurationDays.isFinite && interval.wallDurationDays > 0 ? interval.wallDurationDays : 0)
        }
        let comparableOperatingDays = intervals.reduce(0.0) { partial, interval in
            guard interval.durationBasis == .operatingHours, interval.durationDays.isFinite, interval.durationDays > 0 else {
                return partial
            }
            return partial + interval.durationDays
        }
        let latestSeriesID = makeSeriesMetadata(candidates.last!).seriesID
        let latestComparableInterval = intervals.last
        let latestSemanticContractVersion = candidates.reversed()
            .compactMap { $0.semanticContractVersion ?? $0.directKeyContractVersion }
            .first
        return FTLTimeSeriesAnalytics(
            schemaVersion: 2,
            semanticContractVersion: contractVersion,
            intervals: intervals,
            learningExcludedIntervals: learningExcludedIntervals,
            histogramDeltas: histogramDeltas,
            reliabilityEvents: events,
            peCorrelationPoints: correlations,
            series: seriesGroups,
            latestSeriesID: latestSeriesID,
            latestComparableSeriesID: latestComparableInterval?.seriesID,
            latestComparableInterval: latestComparableInterval,
            latestSemanticContractVersion: latestSemanticContractVersion,
            calendarSpanDays: calendarSpanDays,
            comparableWallDays: comparableWallDays,
            comparableOperatingDays: comparableOperatingDays,
            histogramSemantics: resolvedHistogramSemantics,
            longBaseline: longBaseline,
            notes: uniqueNotes
        )
    }

    private func makeInterval(
        previous: ASPToolDiagnosticsSnapshot,
        current: ASPToolDiagnosticsSnapshot,
        seriesID: String,
        temperatureHistory: [TemperatureSample],
        histogramTailStartBin: Int?,
        histogramSemantics: [FTLResearchHistogram: FTLHistogramTemporalSemantics],
        bandCalibrationVerified: Bool,
        researchComparable: Bool,
        topologyFallback: DirectFTLTopology?
    ) -> FTLIntervalObservation {
        let duration = FTLDurationMeasurement.between(previous, current)
        let durationDays = duration.durationDays
        let hostDelta = difference(previous.hostWrittenBytes, current.hostWrittenBytes)
        let nandDelta = difference(previous.nandWrittenBytes, current.nandWrittenBytes)
        // Wear counters remain comparable across a research-contract update.
        // Research-only telemetry is intentionally unavailable for the
        // boundary interval so old and new key meanings are never subtracted.
        let telemetryBefore = researchComparable ? previous.researchTelemetry : nil
        let telemetryAfter = researchComparable ? current.researchTelemetry : nil
        let nandReadDelta = difference(telemetryBefore?.nandReads, telemetryAfter?.nandReads)
        var counterMetrics: [FTLTimeSeriesMetric: Double] = [:]
        if let hostDelta, let nandDelta, hostDelta > 0, nandDelta >= 0 {
            let waf = nandDelta / hostDelta
            if waf.isFinite { counterMetrics[.observedWAF] = waf }
        }
        let reducedReadVerifyDelta = difference(telemetryBefore?.reducedReadVerifyNative, telemetryAfter?.reducedReadVerifyNative)
        if let delta = reducedReadVerifyDelta, let reads = nandReadDelta, reads > 0 {
            counterMetrics[.reducedReadVerifyPerNANDRead] = Double(delta) / Double(reads)
        }
        let crossTemperatureUECCDelta = difference(telemetryBefore?.crossTemperatureUECC, telemetryAfter?.crossTemperatureUECC)
        if let delta = crossTemperatureUECCDelta, let reads = nandReadDelta, reads > 0 {
            counterMetrics[.crossTemperatureUECCPerNANDRead] = Double(delta) / Double(reads)
        }
        let ueccDelta = difference(telemetryBefore?.ueccReads, telemetryAfter?.ueccReads)
        if let delta = ueccDelta, let reads = nandReadDelta, reads > 0 {
            counterMetrics[.UECCPerNANDRead] = Double(delta) / Double(reads)
        }

        var operatingMetrics = counterMetrics
        var wallMetrics = counterMetrics
        let ageDelta = difference(telemetryBefore?.ageRefreshTotal, telemetryAfter?.ageRefreshTotal)
        let backgroundDelta = difference(telemetryBefore?.backgroundRefreshMoves, telemetryAfter?.backgroundRefreshMoves)
        let grownBadDelta = researchComparable
            ? difference(previous.grownBadBlocks, current.grownBadBlocks)
            : nil
        func addDayRates(
            delta: UInt64?,
            operatingMetric: FTLTimeSeriesMetric,
            wallMetric: FTLTimeSeriesMetric
        ) {
            guard let delta else { return }
            if let operatingHours = duration.operatingHoursDelta, operatingHours > 0 {
                let value = Double(delta) / (operatingHours / 24)
                if value.isFinite { operatingMetrics[operatingMetric] = value }
            }
            if duration.wallDurationDays > 0 {
                let value = Double(delta) / duration.wallDurationDays
                if value.isFinite { wallMetrics[wallMetric] = value }
            }
        }
        addDayRates(
            delta: reducedReadVerifyDelta,
            operatingMetric: .reducedReadVerifyPerOperatingDay,
            wallMetric: .reducedReadVerifyPerWallDay
        )
        addDayRates(
            delta: crossTemperatureUECCDelta,
            operatingMetric: .crossTemperatureUECCPerOperatingDay,
            wallMetric: .crossTemperatureUECCPerWallDay
        )
        addDayRates(
            delta: ueccDelta,
            operatingMetric: .UECCPerOperatingDay,
            wallMetric: .UECCPerWallDay
        )
        if let ageDelta {
            if let operatingHours = duration.operatingHoursDelta, operatingHours > 0 {
                let value = Double(ageDelta) / (operatingHours / 24)
                if value.isFinite {
                    operatingMetrics[.ageRefreshPerDay] = value
                    operatingMetrics[.ageRefreshPerOperatingDay] = value
                }
            }
            if duration.wallDurationDays > 0 {
                let value = Double(ageDelta) / duration.wallDurationDays
                if value.isFinite {
                    wallMetrics[.ageRefreshPerDay] = value
                    wallMetrics[.ageRefreshPerWallDay] = value
                }
            }
        }
        if let backgroundDelta {
            if let operatingHours = duration.operatingHoursDelta, operatingHours > 0 {
                let value = Double(backgroundDelta) / (operatingHours / 24)
                if value.isFinite {
                    operatingMetrics[.backgroundRefreshPerDay] = value
                    operatingMetrics[.backgroundRefreshPerOperatingDay] = value
                }
            }
            if duration.wallDurationDays > 0 {
                let value = Double(backgroundDelta) / duration.wallDurationDays
                if value.isFinite {
                    wallMetrics[.backgroundRefreshPerDay] = value
                    wallMetrics[.backgroundRefreshPerWallDay] = value
                }
            }
        }
        if let grownBadDelta {
            if let operatingHours = duration.operatingHoursDelta, operatingHours > 0 {
                let value = Double(grownBadDelta) / (operatingHours / 24)
                if value.isFinite {
                    operatingMetrics[.grownBadBlocksPerDay] = value
                    operatingMetrics[.grownBadBlocksPerOperatingDay] = value
                }
            }
            if duration.wallDurationDays > 0 {
                let value = Double(grownBadDelta) / duration.wallDurationDays
                if value.isFinite {
                    wallMetrics[.grownBadBlocksPerDay] = value
                    wallMetrics[.grownBadBlocksPerWallDay] = value
                }
            }
        }

        var metrics: [FTLTimeSeriesMetric: Double]
        switch duration.basis {
        case .operatingHours:
            metrics = operatingMetrics
        case .wallClockFallback, .unavailable:
            metrics = wallMetrics
        }

        let histogramDeltas = FTLResearchHistogram.allCases.compactMap { histogram -> FTLHistogramDelta? in
            let semantics = histogramSemantics[histogram] ?? .opaqueSnapshot
            guard semantics != .opaqueSnapshot else { return nil }
            guard let before = telemetryBefore?.histogram(named: histogram),
                  let after = telemetryAfter?.histogram(named: histogram),
                  before.count == after.count,
                  let bins = subtractHistogram(before, after) else { return nil }
            return FTLHistogramDelta(
                histogram: histogram,
                seriesID: seriesID,
                startAt: previous.capturedAt,
                endAt: current.capturedAt,
                bins: bins,
                summary: FTLHistogramSummary.summarize(bins),
                temporalSemantics: semantics
            )
        }
        if let tailStart = histogramTailStartBin,
           let cross = histogramDeltas.first(where: { $0.histogram == .bandsCrossTemp }),
           cross.temporalSemantics == .verifiedCumulative,
           let tail = FTLHistogramSummary.tailFraction(cross.bins, from: tailStart) {
            metrics[.crossTemperatureTailFraction] = tail
            operatingMetrics[.crossTemperatureTailFraction] = tail
            wallMetrics[.crossTemperatureTailFraction] = tail
        }

        let reliabilityEvents = makeEvents(
            previous: previous,
            current: current,
            seriesID: seriesID,
            nandReadDelta: nandReadDelta,
            temperatureHistory: temperatureHistory,
            researchComparable: DirectFTLResearchContract.reliabilityPairIsComparable(previous, current)
        )
        let tlcStart = nonnegative(previous.tlcAveragePE)
        let tlcEnd = nonnegative(current.tlcAveragePE)
        let pslcStart = nonnegative(previous.slcAveragePE)
        let pslcEnd = nonnegative(current.slcAveragePE)
        let tlcWear = normalizedWear(pe: tlcEnd, eol: current.tlcEOLPE)
        let pslcWear = normalizedWear(pe: pslcEnd, eol: current.slcEOLPE)
        let intervalResidual = makeIntervalResidual(
            previous: previous,
            current: current,
            nandDelta: nandDelta,
            telemetryBefore: telemetryBefore,
            telemetryAfter: telemetryAfter,
            bandCalibrationVerified: bandCalibrationVerified,
            topologyFallback: topologyFallback
        )

        return FTLIntervalObservation(
            seriesID: seriesID,
            startAt: previous.capturedAt,
            endAt: current.capturedAt,
            startSnapshotID: previous.id,
            endSnapshotID: current.id,
            durationDays: durationDays,
            wallDurationDays: duration.wallDurationDays,
            operatingHoursDelta: duration.operatingHoursDelta,
            durationBasis: duration.basis,
            deltaHostBytes: hostDelta,
            deltaNANDBytes: nandDelta,
            deltaNANDReads: nandReadDelta,
            observedWAF: metrics[.observedWAF],
            tlcPEStart: tlcStart,
            tlcPEEnd: tlcEnd,
            pslcPEStart: pslcStart,
            pslcPEEnd: pslcEnd,
            tlcWearBalance: tlcWear,
            pslcWearBalance: pslcWear,
            metricValues: metrics,
            operatingMetricValues: operatingMetrics,
            wallMetricValues: wallMetrics,
            histogramDeltas: histogramDeltas,
            reliabilityEvents: reliabilityEvents,
            intervalResidual: intervalResidual,
            hostWriteCompositionAudit: HostWriteCompositionAuditor().assess(baseline: previous, latest: current),
            // A scalar counter, compared provisionally like the retention
            // counters; the strict research gate fails on newer macOS builds.
            deltaDirectToTLCSectors: DirectFTLResearchContract.reliabilityPairIsComparable(previous, current)
                ? difference(previous.researchTelemetry?.directToTLCSectors, current.researchTelemetry?.directToTLCSectors)
                : nil
        )
    }

    private func makeIntervalResidual(
        previous: ASPToolDiagnosticsSnapshot,
        current: ASPToolDiagnosticsSnapshot,
        nandDelta: Double?,
        telemetryBefore: FTLResearchTelemetrySnapshot?,
        telemetryAfter: FTLResearchTelemetrySnapshot?,
        bandCalibrationVerified: Bool,
        topologyFallback: DirectFTLTopology?
    ) -> FTLIntervalResidualDiagnostics? {
        guard let previousTopology = previous.directTopology ?? topologyFallback,
              let currentTopology = current.directTopology ?? topologyFallback,
              previousTopology.isEquivalentGeometry(to: currentTopology),
              let tlcCapacity = previousTopology.tlcCapacityBytes,
              let pslcCapacity = previousTopology.pslcWritableCapacityBytes,
              let measured = nandDelta,
              let tlcDelta = difference(previous.tlcAveragePE, current.tlcAveragePE),
              let pslcDelta = difference(previous.slcAveragePE, current.slcAveragePE),
              [tlcCapacity, pslcCapacity, measured, tlcDelta, pslcDelta].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }
        let knownBest = tlcCapacity * tlcDelta + pslcCapacity * pslcDelta
        let knownLow = tlcCapacity * max(0, tlcDelta - 1) + pslcCapacity * max(0, pslcDelta - 1)
        let knownHigh = tlcCapacity * (tlcDelta + 1) + pslcCapacity * (pslcDelta + 1)
        guard [knownLow, knownBest, knownHigh].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let residualLow = measured - knownHigh
        let residualBest = measured - knownBest
        let residualHigh = measured - knownLow
        guard [residualLow, residualBest, residualHigh].allSatisfy(\.isFinite) else { return nil }
        let peTransition = max(tlcDelta, pslcDelta)
        let status: FTLIntervalResidualStatus = residualLow <= 0 && residualHigh >= 0 || peTransition < 2
            ? .indeterminateByPEQuantization
            : .resolved
        let equivalentPSLCBands: Double? = {
            guard let bandBytes = previousTopology.pslcBandBytes, bandBytes > 0 else { return nil }
            let value = residualBest / Double(bandBytes)
            return value.isFinite ? value : nil
        }()
        let topologyNote = previous.directTopology == nil || current.directTopology == nil
            ? " asptool側topologyは、検証済み取得経路境界のD1/D2から解析時のみ補完しました。"
            : ""
        let note: String
        if status == .indeterminateByPEQuantization {
            note = "P/E量子化範囲内で説明可能なため、未知domain／内部処理の根拠とはしません。band 0や予算へ割り当てません." + topologyNote
        } else {
            note = "P/E量子化では説明しきれない区間残差です。unknown／unmodeled domain、refresh、metadata traffic、controller housekeeping、counter semantic mismatch、geometry/model error、capture skewなど複数候補と突合します。band 0や予算へ割り当てません." + topologyNote
        }
        let bandPath: FTLBandPathResidualDiagnostics? = {
            guard bandCalibrationVerified,
                  let tlcBandBytes = previousTopology.tlcBandBytes,
                  let pslcBandBytes = previousTopology.pslcBandBytes,
                  let previousTLCBands = previous.userBandsProgrammed,
                  let currentTLCBands = current.userBandsProgrammed,
                  let previousPSLCBands = previous.intermediateBandsProgrammed,
                  let currentPSLCBands = current.intermediateBandsProgrammed,
                  currentTLCBands >= previousTLCBands,
                  currentPSLCBands >= previousPSLCBands else { return nil }
            let tlcBandDelta = Double(currentTLCBands - previousTLCBands)
            let pslcBandDelta = Double(currentPSLCBands - previousPSLCBands)
            let bandQuantization = FTLLongBaselineResidualAnalyzer.bandQuantizationHalfStep
            let bandKnownBest = tlcBandDelta * Double(tlcBandBytes) + pslcBandDelta * Double(pslcBandBytes)
            let bandKnownLow = max(0, tlcBandDelta - bandQuantization) * Double(tlcBandBytes)
                + max(0, pslcBandDelta - bandQuantization) * Double(pslcBandBytes)
            let bandKnownHigh = (tlcBandDelta + bandQuantization) * Double(tlcBandBytes)
                + (pslcBandDelta + bandQuantization) * Double(pslcBandBytes)
            let bandResidualLow = measured - bandKnownHigh
            let bandResidualBest = measured - bandKnownBest
            let bandResidualHigh = measured - bandKnownLow
            guard [bandKnownLow, bandKnownBest, bandKnownHigh,
                   bandResidualLow, bandResidualBest, bandResidualHigh]
                .allSatisfy({ $0.isFinite }) else { return nil }
            let status: FTLBandPathResidualStatus
            if bandResidualLow > 0 {
                status = .resolvedPositive
            } else if bandResidualHigh < 0 {
                status = .resolvedNegative
            } else {
                status = .indeterminate
            }
            return FTLBandPathResidualDiagnostics(
                measuredNANDBytes: measured,
                knownLowBytes: bandKnownLow,
                knownBestBytes: bandKnownBest,
                knownHighBytes: bandKnownHigh,
                signedResidualLowBytes: bandResidualLow,
                signedResidualBestBytes: bandResidualBest,
                signedResidualHighBytes: bandResidualHigh,
                tlcBandDelta: tlcBandDelta,
                pslcBandDelta: pslcBandDelta,
                status: status,
                note: "key 349/350の意味検証後に算出した診断値。予算・Forecast WAF・band 0への割り当ては行いません。"
            )
        }()
        return FTLIntervalResidualDiagnostics(
            measuredNANDBytes: measured,
            knownDomainNANDLowBytes: knownLow,
            knownDomainNANDBestBytes: knownBest,
            knownDomainNANDHighBytes: knownHigh,
            signedResidualLowBytes: residualLow,
            signedResidualBestBytes: residualBest,
            signedResidualHighBytes: residualHigh,
            equivalentPSLCBands: equivalentPSLCBands,
            tlcPEDelta: tlcDelta,
            pslcPEDelta: pslcDelta,
            ageRefreshDelta: difference(telemetryBefore?.ageRefreshTotal, telemetryAfter?.ageRefreshTotal),
            backgroundRefreshDelta: difference(telemetryBefore?.backgroundRefreshMoves, telemetryAfter?.backgroundRefreshMoves),
            bandsPaddedForAgeDelta: difference(telemetryBefore?.bandsPaddedForAge, telemetryAfter?.bandsPaddedForAge),
            bandsRefreshedOnErrorDelta: difference(telemetryBefore?.bandsRefreshedOnError, telemetryAfter?.bandsRefreshedOnError),
            bandPath: bandPath,
            status: status,
            note: note,
            tlcEstimatedWrittenBytes: tlcCapacity * tlcDelta,
            pslcEstimatedWrittenBytes: pslcCapacity * pslcDelta
        )
    }

    private func appendHistogramValidationNotes(
        previous: ASPToolDiagnosticsSnapshot,
        current: ASPToolDiagnosticsSnapshot,
        to notes: inout [String]
    ) {
        guard let before = previous.researchTelemetry, let after = current.researchTelemetry else { return }
        for histogram in FTLResearchHistogram.allCases {
            guard let oldBins = before.histogram(named: histogram),
                  let newBins = after.histogram(named: histogram) else { continue }
            if oldBins.count != newBins.count {
                notes.append("\(histogram.title)は配列形状が変わったため、その区間の差分を作成しませんでした。")
            } else if zip(oldBins, newBins).contains(where: { $1 < $0 }) {
                notes.append("\(histogram.title)のbin減少を検出したため、その区間の差分を作成しませんでした。")
            }
        }
    }

    private func makeEvents(
        previous: ASPToolDiagnosticsSnapshot,
        current: ASPToolDiagnosticsSnapshot,
        seriesID: String,
        nandReadDelta: UInt64?,
        temperatureHistory: [TemperatureSample],
        researchComparable: Bool
    ) -> [FTLTimeSeriesReliabilityEvent] {
        let before = researchComparable ? previous.researchTelemetry : nil
        let after = researchComparable ? current.researchTelemetry : nil
        let pairs: [(FTLTimeSeriesReliabilityEventType, UInt64?, UInt64?)] = [
            (.crossTemperatureUECC, before?.crossTemperatureUECC, after?.crossTemperatureUECC),
            (.crossTemperatureRaidUECC, before?.crossTemperatureRaidUECC, after?.crossTemperatureRaidUECC),
            (.utilityUECC, before?.utilityUECCReads, after?.utilityUECCReads),
            (.UECC, before?.ueccReads, after?.ueccReads),
            (.hostPSLCReadVerifyFailure, before?.hostSLCReadVerifyFailures, after?.hostSLCReadVerifyFailures),
            (.hostTLCReadVerifyFailure, before?.hostTLCReadVerifyFailures, after?.hostTLCReadVerifyFailures),
            (.gcPSLCToTLCReadVerifyFailure, before?.gcSLCToTLCReadVerifyFailures, after?.gcSLCToTLCReadVerifyFailures),
            (.gcTLCToTLCReadVerifyFailure, before?.gcTLCToTLCReadVerifyFailures, after?.gcTLCToTLCReadVerifyFailures),
            (.grownBadBlocks, researchComparable ? previous.grownBadBlocks : nil,
                researchComparable ? current.grownBadBlocks : nil),
            (.dieFailures, researchComparable ? previous.numDieFailures : nil,
                researchComparable ? current.numDieFailures : nil)
        ]
        return pairs.compactMap { type, old, new in
            guard let delta = difference(old, new), delta > 0 else { return nil }
            let temperature = temperatureSummary(
                start: previous.capturedAt,
                end: current.capturedAt,
                deviceID: current.deviceID,
                history: temperatureHistory
            )
            return FTLTimeSeriesReliabilityEvent(
                seriesID: seriesID,
                type: type,
                intervalStart: previous.capturedAt,
                intervalEnd: current.capturedAt,
                detectedAt: current.capturedAt,
                delta: delta,
                deviceID: current.deviceID,
                firmwareEpoch: current.firmwareEpoch,
                semanticContractVersion: DirectFTLResearchContract.reliabilityVersion(for: current),
                tlcPE: nonnegative(current.tlcAveragePE),
                pslcPE: nonnegative(current.slcAveragePE),
                nandReadsSincePrevious: nandReadDelta,
                temperatureSummary: temperature,
                runtimeBuild: current.sourceBuild,
                contractBuild: DirectFTLResearchContract.contractBuild(for: current),
                provisionalInterpretation: !DirectFTLResearchContract.researchTelemetryIsEligible(previous)
                    || !DirectFTLResearchContract.researchTelemetryIsEligible(current)
            )
        }
    }

    /// With a table, the event temperature comes from it, so samples older
    /// than the in-memory window are not needed; otherwise from `history`.
    private func temperatureSummary(
        start: Date,
        end: Date,
        deviceID: String?,
        history: [TemperatureSample]
    ) -> FTLTemperatureIntervalSummary? {
        if let temperatureTable,
           case let .covered(summary) = temperatureTable.lookup(deviceID: deviceID, start: start, end: end) {
            return summary
        }
        return TemperatureIntervalSummaryReference.summary(start: start, end: end, deviceID: deviceID, history: history)
    }

    private func sameWearSeries(_ lhs: ASPToolDiagnosticsSnapshot, _ rhs: ASPToolDiagnosticsSnapshot) -> Bool {
        lhs.deviceID != nil && lhs.deviceID == rhs.deviceID &&
            lhs.sourceArtifact.participatesInCoreWearLane && rhs.sourceArtifact.participatesInCoreWearLane &&
            lhs.hostWritesUnitState.supportsIntervalComparison && rhs.hostWritesUnitState.supportsIntervalComparison &&
            lhs.nandWritesUnitState.supportsIntervalComparison && rhs.nandWritesUnitState.supportsIntervalComparison &&
            lhs.hostWrittenBytes?.isFinite == true && rhs.hostWrittenBytes?.isFinite == true &&
            lhs.nandWrittenBytes?.isFinite == true && rhs.nandWrittenBytes?.isFinite == true
    }

    private func sameResearchSeries(_ lhs: ASPToolDiagnosticsSnapshot, _ rhs: ASPToolDiagnosticsSnapshot) -> Bool {
        DirectFTLResearchContract.researchTelemetryPairIsComparable(lhs, rhs)
    }

    private func seriesCountersWentBackwards(_ lhs: ASPToolDiagnosticsSnapshot, _ rhs: ASPToolDiagnosticsSnapshot) -> Bool {
        (lhs.hostWrites != nil && rhs.hostWrites != nil && rhs.hostWrites! < lhs.hostWrites!) ||
            (lhs.nandWrites != nil && rhs.nandWrites != nil && rhs.nandWrites! < lhs.nandWrites!) ||
            (lhs.powerOnHours != nil && rhs.powerOnHours != nil && rhs.powerOnHours! < lhs.powerOnHours!)
    }

    private func difference(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after, after >= before else { return nil }
        return after - before
    }

    private func difference(_ before: Double?, _ after: Double?) -> Double? {
        guard let before, let after, before.isFinite, after.isFinite, after >= before else { return nil }
        let value = after - before
        return value.isFinite ? value : nil
    }

    private func subtractHistogram(_ before: [UInt64], _ after: [UInt64]) -> [UInt64]? {
        var result: [UInt64] = []
        result.reserveCapacity(before.count)
        for (old, new) in zip(before, after) {
            guard new >= old else { return nil }
            result.append(new - old)
        }
        return result
    }

    private func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func normalizedWear(pe: Double?, eol: Double?) -> Double? {
        guard let pe = nonnegative(pe), let eol = nonnegative(eol), eol > 0 else { return nil }
        let value = pe / eol
        return value.isFinite ? value : nil
    }

    private func seriesID(for snapshot: ASPToolDiagnosticsSnapshot) -> String {
        makeSeriesMetadata(snapshot).seriesID
    }

    private func makeSeriesMetadata(_ snapshot: ASPToolDiagnosticsSnapshot) -> FTLTimeSeriesSeriesMetadata {
        let semantic = snapshot.semanticContractVersion ?? snapshot.directKeyContractVersion
        let coreWear = snapshot.resolvedCoreWearVersion
        let researchTelemetry = snapshot.resolvedResearchTelemetryVersion
        let fields: [String] = [
            snapshot.deviceID ?? "?",
            snapshot.sourceArtifact.rawValue,
            String(snapshot.extractionVersion),
            snapshot.sourceBuild ?? "?",
            snapshot.directFormatVersion.map { String($0) } ?? "?",
            coreWear ?? "?",
            researchTelemetry ?? "?",
            snapshot.hostWritesUnitState.rawValue,
            snapshot.nandWritesUnitState.rawValue,
            snapshot.tlcEOLPE.map { String($0) } ?? "?",
            snapshot.slcEOLPE.map { String($0) } ?? "?"
        ]
        let stableKey = fields.joined(separator: "|")
        return FTLTimeSeriesSeriesMetadata(
            seriesID: stableKey,
            deviceID: snapshot.deviceID,
            sourceArtifact: snapshot.sourceArtifact,
            extractionVersion: snapshot.extractionVersion,
            sourceBuild: snapshot.sourceBuild,
            firmwareEpoch: snapshot.firmwareEpoch,
            directFormatVersion: snapshot.directFormatVersion,
            directKeyContractVersion: snapshot.directKeyContractVersion,
            semanticContractVersion: semantic,
            coreWearVersion: coreWear,
            researchTelemetryVersion: researchTelemetry,
            historySchemaVersion: snapshot.historySchemaVersion,
            hostWritesUnitState: snapshot.hostWritesUnitState,
            nandWritesUnitState: snapshot.nandWritesUnitState,
            tlcEOLPE: snapshot.tlcEOLPE,
            slcEOLPE: snapshot.slcEOLPE
        )
    }
}
