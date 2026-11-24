import Foundation

/// A diagnostic baseline for the NAND that cannot be reconstructed from the
/// known Direct-topology domains.  These values are descriptive only: they
/// are never assigned to a domain and never enter the endurance budget.
enum LongBaselineKind: Equatable, Sendable {
    case lifetime
    case series
    case tlcProgressTarget(Double)
    case segment(index: Int)

    var title: String {
        switch self {
        case .lifetime:
            return "生涯基線（出荷時アンカー）"
        case .series:
            return "系列基線"
        case let .tlcProgressTarget(target):
            return String(format: "ΔTLC ≥ %.0f", target)
        case let .segment(index):
            return "非重複セグメント \(index + 1)"
        }
    }
}

enum ResidualReconstructionPath: String, Equatable, Sendable {
    case averagePE
    case bandsProgrammed

    var title: String {
        switch self {
        case .averagePE: return "平均P/E経路"
        case .bandsProgrammed: return "band書込回数経路"
        }
    }
}

enum LongBaselineResidualStatus: String, Equatable, Sendable {
    case resolvedPositive
    case resolvedNegative
    case indeterminate
    case insufficientProgress
    case topologyChangedWithinSpan

    var title: String {
        switch self {
        case .resolvedPositive: return "判定可能・正の残差"
        case .resolvedNegative: return "判定可能・負の残差"
        case .indeterminate: return "P/E量子化で判定不能"
        case .insufficientProgress: return "P/E進行不足"
        case .topologyChangedWithinSpan: return "区間内topology変更"
        }
    }

    var isResolved: Bool {
        switch self {
        case .resolvedPositive, .resolvedNegative: return true
        case .indeterminate, .insufficientProgress, .topologyChangedWithinSpan: return false
        }
    }
}

/// A dynamic estimate of when the lifetime residual may exceed the two-sided
/// P/E quantization width. It is a hypothesis-based observation forecast, not
/// a prediction of NAND failure or of a future TBW.
struct ResolutionProjection: Equatable, Sendable {
    let targetTLCProgress: Double
    let currentTLCProgress: Double?
    let hostBytesPerDay: Double?
    let estimatedDays: ClosedRange<Double>?
    let basis: String
}

struct LongBaselineResidual: Equatable, Sendable, Identifiable {
    let kind: LongBaselineKind
    let path: ResidualReconstructionPath
    let anchorSnapshotID: UUID?
    let endSnapshotID: UUID
    let anchorAt: Date?
    let endAt: Date
    let wallDays: Double?
    let operatingDays: Double?
    let usedWallClockFallback: Bool
    let spansResearchSession: Bool
    let spansInstrumentBoundary: Bool

    let deltaHostBytes: Double
    let deltaNANDBytes: Double
    let tlcPEDelta: Double
    let pslcPEDelta: Double
    let quantizationHalfStep: Double

    let knownLowBytes: Double
    let knownBestBytes: Double
    let knownHighBytes: Double
    let residualLowBytes: Double
    let residualBestBytes: Double
    let residualHighBytes: Double
    let status: LongBaselineResidualStatus

    let residualPerHost: ClosedRange<Double>?
    let residualPerKnown: ClosedRange<Double>?
    let residualPerOperatingDay: ClosedRange<Double>?
    let residualPerWallDay: ClosedRange<Double>?
    let equivalentPSLCBands: Double?
    let tlcBandDelta: Double?
    let pslcBandDelta: Double?

    let ageRefreshDelta: UInt64?
    let backgroundRefreshDelta: UInt64?
    let bandsPaddedForAgeDelta: UInt64?
    let bandsRefreshedOnErrorDelta: UInt64?
    let notes: [String]

    var id: String {
        "\(kind.title)|\(path.rawValue)|\(endSnapshotID.uuidString)"
    }
}

struct BandCounterCalibration: Equatable, Sendable, Identifiable {
    let capturedAt: Date
    let tlcRatio: Double?
    let pslcRatio: Double?
    let stableSnapshotCount: Int
    let incrementalTLC: BandCounterIncrementEvidence
    let incrementalPSLC: BandCounterIncrementEvidence
    let validationMethod: String
    let verified: Bool
    let note: String

    var id: Date { capturedAt }
}

struct BandCounterIncrementEvidence: Equatable, Sendable {
    let ratio: Double?
    let peDelta: Double?
    let riseBoundaryCount: Int
    let intervalCount: Int
    let observationDays: Double
}

struct LongBaselineResidualAnalytics: Equatable, Sendable {
    static let empty = LongBaselineResidualAnalytics(
        baselines: [],
        calibration: [],
        normalizationStability: [:],
        projection: nil,
        notes: ["長基線残差を構築できるDirect FTL履歴がありません。"]
    )

    let baselines: [LongBaselineResidual]
    let calibration: [BandCounterCalibration]
    let normalizationStability: [String: Double]
    let projection: ResolutionProjection?
    let notes: [String]
}

/// Builds long baselines from retained Direct FTL snapshots. This analyzer is
/// intentionally independent from `NANDEnduranceV2`: a residual is evidence
/// about an unmodelled write stream, never a budget or a forecast multiplier.
struct FTLLongBaselineResidualAnalyzer: Sendable {
    static let tlcProgressTargets: [Double] = [10, 20, 40, 80]
    static let nonOverlappingSegmentTarget: Double = 20
    static let bandQuantizationHalfStep = 2.0
    static let minimumBandCounterIncrementPEDelta = 3.0

    func analyze(
        snapshots: [ASPToolDiagnosticsSnapshot],
        excluding researchIntervals: [DateInterval] = [],
        smartHistory: [DriveSnapshot] = [],
        continuityLane suppliedLane: WearContinuityLane? = nil
    ) -> LongBaselineResidualAnalytics {
        let rawCandidates = snapshots
            .filter { $0.sourceArtifact.participatesInCoreWearLane && $0.captureQuality != .unknown }
            .sorted {
                if $0.capturedAt == $1.capturedAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.capturedAt < $1.capturedAt
            }
        guard let rawLatest = rawCandidates.last(where: { $0.sourceArtifact == .directFTL }) ?? rawCandidates.last else {
            return .empty
        }

        // Long-baseline residuals intentionally do not remove the verified
        // boundary-exclusion window.  They do, however, use the same lane so
        // a failed or SMART-pending boundary cannot make a new instrument
        // look like a continuation of the old residual baseline.
        let lane = suppliedLane ?? WearContinuityLaneBuilder.build(
            snapshots: rawCandidates,
            smart: smartHistory,
            latest: rawLatest
        )
        let candidates = lane.snapshots
        guard let latest = candidates.last else { return .empty }

        let analysisSeries: [ASPToolDiagnosticsSnapshot]
        if let sharedTopology = lane.verifiedCoreTopology, lane.containsTopologylessASPTool {
            analysisSeries = candidates.map { sample in
                sample.directTopology == nil ? sample.analysisCopy(overridingTopology: sharedTopology) : sample
            }
        } else {
            analysisSeries = candidates
        }

        let latestIdentity = ControllerWearSeriesIdentity(snapshot: latest)
        let latestSeries = analysisSeries.filter {
            ControllerWearSeriesIdentity(snapshot: $0) == latestIdentity
        }
        guard !latestSeries.isEmpty else { return .empty }

        let calibration = makeBandCalibration(
            series: latestSeries,
            excluding: researchIntervals + lane.rateLearningExclusions
        )
        let bandVerified = calibration.last?.verified == true
        var baselines: [LongBaselineResidual] = []
        var notes: [String] = []

        if let lifetime = makeLifetimeBaseline(
            series: latestSeries,
            latest: latest,
            researchIntervals: researchIntervals,
            instrumentBoundaries: lane.boundaries
        ) {
            baselines.append(lifetime)
            if bandVerified,
               let bandBaseline = makeLifetimeBandBaseline(
                   series: latestSeries,
                   latest: latest,
                   researchIntervals: researchIntervals,
                   instrumentBoundaries: lane.boundaries
               ) {
                baselines.append(bandBaseline)
            }
        } else {
            notes.append("生涯基線は、現在系列のtopology・NAND・平均P/Eが連続して確認できないため未構築です。")
        }

        if latestSeries.count >= 2 {
            if let seriesBaseline = makeBaseline(
                kind: .series,
                series: latestSeries,
                startIndex: 0,
                endIndex: latestSeries.count - 1,
                quantizationHalfStep: 1,
                researchIntervals: researchIntervals,
                instrumentBoundaries: lane.boundaries
            ) {
                baselines.append(seriesBaseline)
            }
            if bandVerified,
               let bandBaseline = makeBandBaseline(
                   kind: .series,
                   series: latestSeries,
                   startIndex: 0,
                   endIndex: latestSeries.count - 1,
                   researchIntervals: researchIntervals,
                   instrumentBoundaries: lane.boundaries
               ) {
                baselines.append(bandBaseline)
            }

            for target in Self.tlcProgressTargets {
                guard let startIndex = latestSeries.indices.reversed().first(where: { index in
                    guard let endPE = latest.tlcAveragePE,
                          let startPE = latestSeries[index].tlcAveragePE else { return false }
                    return endPE - startPE >= target
                }) else {
                    let currentProgress = latestSeries.compactMap(\.tlcAveragePE).first.map { (latest.tlcAveragePE ?? 0) - $0 }
                    notes.append(String(format: "ΔTLC ≥ %.0f は未到達（現在の系列内進行 %.3f）。", target, currentProgress ?? 0))
                    continue
                }
                if startIndex < latestSeries.count - 1,
                   let baseline = makeBaseline(
                       kind: .tlcProgressTarget(target),
                       series: latestSeries,
                       startIndex: startIndex,
                       endIndex: latestSeries.count - 1,
                       quantizationHalfStep: 1,
                       researchIntervals: researchIntervals,
                       instrumentBoundaries: lane.boundaries
                   ) {
                    baselines.append(baseline)
                }
            }

            var segmentStart = 0
            var segmentIndex = 0
            while segmentStart < latestSeries.count - 1 {
                guard let endIndex = (segmentStart + 1..<latestSeries.count).first(where: { index in
                    guard let startPE = latestSeries[segmentStart].tlcAveragePE,
                          let endPE = latestSeries[index].tlcAveragePE else { return false }
                    return endPE - startPE >= Self.nonOverlappingSegmentTarget
                }) else { break }
                if let segment = makeBaseline(
                    kind: .segment(index: segmentIndex),
                    series: latestSeries,
                    startIndex: segmentStart,
                    endIndex: endIndex,
                    quantizationHalfStep: 1,
                    researchIntervals: researchIntervals,
                    instrumentBoundaries: lane.boundaries
                ) {
                    baselines.append(segment)
                    segmentIndex += 1
                }
                segmentStart = endIndex
            }
        }

        if bandVerified {
            notes.append("key 349/350のband counter比率が3点以上で安定したため、区間band経路を検証済みとして併記します。")
        } else {
            notes.append("key 349/350の意味検証が未完了です。band書込回数経路は表示・予測に使用していません。")
        }
        if latestSeries.count < 2 {
            notes.append("系列基線には2点以上の比較可能なsnapshotが必要です。")
        }
        notes.append("長基線の観測は日常書込レートの学習対象ではありません。")
        notes.append("長基線残差は研究診断です。予算・TBW・Forecast WAF・band 0への割り当ては行いません。")
        if lane.containsTopologylessASPTool {
            notes.append("旧asptool snapshotのtopologyは、取得経路境界D1/D2検証済みのDirect値から解析時のみ補完。保存rawは変更していません。")
        }

        let stability = normalizationStability(baselines: baselines)
        let projection = makeProjection(baselines: baselines, series: latestSeries)
        return LongBaselineResidualAnalytics(
            baselines: baselines,
            calibration: calibration,
            normalizationStability: stability,
            projection: projection,
            notes: unique(notes)
        )
    }

    private func makeLifetimeBaseline(
        series: [ASPToolDiagnosticsSnapshot],
        latest: ASPToolDiagnosticsSnapshot,
        researchIntervals: [DateInterval],
        instrumentBoundaries: [InstrumentBoundaryRecord]
    ) -> LongBaselineResidual? {
        guard let topology = latest.directTopology,
              series.allSatisfy({ $0.directTopology?.isEquivalentGeometry(to: topology) == true }),
              spanIsMonotonic(series),
              let host = latest.hostWrittenBytes,
              let nand = latest.nandWrittenBytes,
              let tlcPE = finiteNonnegative(latest.tlcAveragePE),
              let pslcPE = finiteNonnegative(latest.slcAveragePE),
              host >= 0, nand >= 0 else { return nil }

        let synthetic = makeValues(
            kind: .lifetime,
            path: .averagePE,
            anchor: nil,
            end: latest,
            deltaHost: host,
            deltaNAND: nand,
            tlcDelta: tlcPE,
            pslcDelta: pslcPE,
            topology: topology,
            quantizationHalfStep: 0.5,
            operatingDays: latest.powerOnHours.map { Double($0) / 24 },
            wallDays: nil,
            usedWallClockFallback: false,
            spansResearchSession: researchIntervals.contains { $0.end <= latest.capturedAt },
            spansInstrumentBoundary: instrumentBoundaries.contains { $0.boundary.after <= latest.capturedAt },
            refreshDeltas: (
                latest.researchTelemetry?.ageRefreshTotal,
                latest.researchTelemetry?.backgroundRefreshMoves,
                latest.researchTelemetry?.bandsPaddedForAge,
                latest.researchTelemetry?.bandsRefreshedOnError
            ),
            notes: [
                "出荷時のNAND／平均P/Eが0開始という仮定です。",
                "保持された現在系列内でDirect topologyが一定であることのみを確認しています。",
                latest.powerOnHours == nil ? "Power On Hoursがないため稼働日正規化は未算出です。" : ""
            ].filter { !$0.isEmpty }
        )
        return synthetic
    }

    private func makeLifetimeBandBaseline(
        series: [ASPToolDiagnosticsSnapshot],
        latest: ASPToolDiagnosticsSnapshot,
        researchIntervals: [DateInterval],
        instrumentBoundaries: [InstrumentBoundaryRecord]
    ) -> LongBaselineResidual? {
        guard let topology = latest.directTopology,
              series.allSatisfy({ $0.directTopology?.isEquivalentGeometry(to: topology) == true }),
              spanIsMonotonic(series),
              bandCountersAreMonotonic(series),
              let host = latest.hostWrittenBytes,
              let nand = latest.nandWrittenBytes,
              let tlcPE = finiteNonnegative(latest.tlcAveragePE),
              let pslcPE = finiteNonnegative(latest.slcAveragePE),
              let tlcCounter = latest.userBandsProgrammed,
              let pslcCounter = latest.intermediateBandsProgrammed,
              let tlcBandBytes = topology.tlcBandBytes,
              let pslcBandBytes = topology.pslcBandBytes,
              host >= 0, nand >= 0,
              tlcBandBytes > 0, pslcBandBytes > 0 else { return nil }

        let tlcDelta = Double(tlcCounter)
        let pslcDelta = Double(pslcCounter)
        let knownBest = tlcDelta * Double(tlcBandBytes) + pslcDelta * Double(pslcBandBytes)
        let knownLow = max(0, tlcDelta - Self.bandQuantizationHalfStep) * Double(tlcBandBytes)
            + max(0, pslcDelta - Self.bandQuantizationHalfStep) * Double(pslcBandBytes)
        let knownHigh = (tlcDelta + Self.bandQuantizationHalfStep) * Double(tlcBandBytes)
            + (pslcDelta + Self.bandQuantizationHalfStep) * Double(pslcBandBytes)
        guard [knownLow, knownBest, knownHigh].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return makeValues(
            kind: .lifetime,
            path: .bandsProgrammed,
            anchor: nil,
            end: latest,
            deltaHost: host,
            deltaNAND: nand,
            tlcDelta: tlcPE,
            pslcDelta: pslcPE,
            topology: topology,
            quantizationHalfStep: Self.bandQuantizationHalfStep,
            operatingDays: latest.powerOnHours.map { Double($0) / 24 },
            wallDays: nil,
            usedWallClockFallback: false,
            spansResearchSession: researchIntervals.contains { $0.end <= latest.capturedAt },
            spansInstrumentBoundary: instrumentBoundaries.contains { $0.boundary.after <= latest.capturedAt },
            refreshDeltas: (
                latest.researchTelemetry?.ageRefreshTotal,
                latest.researchTelemetry?.backgroundRefreshMoves,
                latest.researchTelemetry?.bandsPaddedForAge,
                latest.researchTelemetry?.bandsRefreshedOnError
            ),
            notes: [
                "key 349/350のband/P/E比率を検証済みとして使用しました。",
                "band counterが出荷時0開始という仮定です。平均P/E経路とは別の診断値です。"
            ],
            knownValues: (low: knownLow, best: knownBest, high: knownHigh),
            bandDeltas: (tlc: tlcDelta, pslc: pslcDelta)
        )
    }

    private func makeBandBaseline(
        kind: LongBaselineKind,
        series: [ASPToolDiagnosticsSnapshot],
        startIndex: Int,
        endIndex: Int,
        researchIntervals: [DateInterval],
        instrumentBoundaries: [InstrumentBoundaryRecord]
    ) -> LongBaselineResidual? {
        guard series.indices.contains(startIndex), series.indices.contains(endIndex), startIndex < endIndex else { return nil }
        let start = series[startIndex]
        let end = series[endIndex]
        let span = Array(series[startIndex...endIndex])
        guard let topology = end.directTopology,
              span.allSatisfy({ $0.directTopology?.isEquivalentGeometry(to: topology) == true }),
              spanIsMonotonic(span),
              bandCountersAreMonotonic(span),
              let startHost = start.hostWrittenBytes,
              let endHost = end.hostWrittenBytes,
              let startNAND = start.nandWrittenBytes,
              let endNAND = end.nandWrittenBytes,
              let startTLC = finiteNonnegative(start.tlcAveragePE),
              let endTLC = finiteNonnegative(end.tlcAveragePE),
              let startPSLC = finiteNonnegative(start.slcAveragePE),
              let endPSLC = finiteNonnegative(end.slcAveragePE),
              let startTLCBands = start.userBandsProgrammed,
              let endTLCBands = end.userBandsProgrammed,
              let startPSLCBands = start.intermediateBandsProgrammed,
              let endPSLCBands = end.intermediateBandsProgrammed,
              let tlcBandBytes = topology.tlcBandBytes,
              let pslcBandBytes = topology.pslcBandBytes,
              endHost >= startHost, endNAND >= startNAND,
              endTLC >= startTLC, endPSLC >= startPSLC,
              endTLCBands >= startTLCBands, endPSLCBands >= startPSLCBands,
              tlcBandBytes > 0, pslcBandBytes > 0 else { return nil }

        let tlcDelta = Double(endTLCBands - startTLCBands)
        let pslcDelta = Double(endPSLCBands - startPSLCBands)
        let knownBest = tlcDelta * Double(tlcBandBytes) + pslcDelta * Double(pslcBandBytes)
        let knownLow = max(0, tlcDelta - Self.bandQuantizationHalfStep) * Double(tlcBandBytes)
            + max(0, pslcDelta - Self.bandQuantizationHalfStep) * Double(pslcBandBytes)
        let knownHigh = (tlcDelta + Self.bandQuantizationHalfStep) * Double(tlcBandBytes)
            + (pslcDelta + Self.bandQuantizationHalfStep) * Double(pslcBandBytes)
        guard [knownLow, knownBest, knownHigh].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

        let wallDays = end.capturedAt.timeIntervalSince(start.capturedAt) / 86_400
        guard wallDays.isFinite, wallDays > 0 else { return nil }
        let operatingDays: Double? = {
            guard let startHours = start.powerOnHours, let endHours = end.powerOnHours,
                  endHours >= startHours else { return nil }
            let days = Double(endHours - startHours) / 24
            return days.isFinite && days > 0 ? days : nil
        }()
        return makeValues(
            kind: kind,
            path: .bandsProgrammed,
            anchor: start,
            end: end,
            deltaHost: endHost - startHost,
            deltaNAND: endNAND - startNAND,
            tlcDelta: endTLC - startTLC,
            pslcDelta: endPSLC - startPSLC,
            topology: topology,
            quantizationHalfStep: Self.bandQuantizationHalfStep,
            operatingDays: operatingDays,
            wallDays: wallDays,
            usedWallClockFallback: operatingDays == nil,
            spansResearchSession: researchIntervals.contains { $0.intersects(DateInterval(start: start.capturedAt, end: end.capturedAt)) },
            spansInstrumentBoundary: instrumentBoundaries.contains { $0.boundary.after > start.capturedAt && $0.boundary.after <= end.capturedAt },
            refreshDeltas: refreshDeltas(start: start, end: end),
            notes: operatingDays == nil ? ["Power On Hoursが欠測のため壁時計日を補助的に使用しました。"] : [],
            knownValues: (low: knownLow, best: knownBest, high: knownHigh),
            bandDeltas: (tlc: tlcDelta, pslc: pslcDelta)
        )
    }

    private func makeBaseline(
        kind: LongBaselineKind,
        series: [ASPToolDiagnosticsSnapshot],
        startIndex: Int,
        endIndex: Int,
        quantizationHalfStep: Double,
        researchIntervals: [DateInterval],
        instrumentBoundaries: [InstrumentBoundaryRecord]
    ) -> LongBaselineResidual? {
        guard series.indices.contains(startIndex), series.indices.contains(endIndex), startIndex < endIndex else { return nil }
        let start = series[startIndex]
        let end = series[endIndex]
        guard let topology = end.directTopology,
              let startHost = start.hostWrittenBytes,
              let endHost = end.hostWrittenBytes,
              let startNAND = start.nandWrittenBytes,
              let endNAND = end.nandWrittenBytes,
              let startTLC = finiteNonnegative(start.tlcAveragePE),
              let endTLC = finiteNonnegative(end.tlcAveragePE),
              let startPSLC = finiteNonnegative(start.slcAveragePE),
              let endPSLC = finiteNonnegative(end.slcAveragePE),
              endHost >= startHost, endNAND >= startNAND,
              endTLC >= startTLC, endPSLC >= startPSLC else { return nil }

        let span = Array(series[startIndex...endIndex])
        let topologyChanged = span.contains { $0.directTopology?.isEquivalentGeometry(to: topology) != true }
        guard span.allSatisfy({ $0.capturedAt >= start.capturedAt && $0.capturedAt <= end.capturedAt }) else { return nil }
        guard spanIsMonotonic(span) else {
            return topologyChanged ? makeDiagnosticBaseline(
                kind: kind, start: start, end: end, topology: topology,
                startHost: startHost, endHost: endHost, startNAND: startNAND,
                endNAND: endNAND, startTLC: startTLC, endTLC: endTLC,
                startPSLC: startPSLC, endPSLC: endPSLC,
                quantizationHalfStep: quantizationHalfStep,
                researchIntervals: researchIntervals,
                instrumentBoundaries: instrumentBoundaries,
                topologyChanged: true
            ) : nil
        }
        if topologyChanged {
            return makeDiagnosticBaseline(
                kind: kind, start: start, end: end, topology: topology,
                startHost: startHost, endHost: endHost, startNAND: startNAND,
                endNAND: endNAND, startTLC: startTLC, endTLC: endTLC,
                startPSLC: startPSLC, endPSLC: endPSLC,
                quantizationHalfStep: quantizationHalfStep,
                researchIntervals: researchIntervals,
                instrumentBoundaries: instrumentBoundaries,
                topologyChanged: true
            )
        }

        let wallDays = end.capturedAt.timeIntervalSince(start.capturedAt) / 86_400
        guard wallDays.isFinite, wallDays > 0 else { return nil }
        let operatingDays: Double? = {
            guard let startHours = start.powerOnHours, let endHours = end.powerOnHours,
                  endHours >= startHours else { return nil }
            let days = Double(endHours - startHours) / 24
            return days.isFinite && days > 0 ? days : nil
        }()
        return makeValues(
            kind: kind,
            path: .averagePE,
            anchor: start,
            end: end,
            deltaHost: endHost - startHost,
            deltaNAND: endNAND - startNAND,
            tlcDelta: endTLC - startTLC,
            pslcDelta: endPSLC - startPSLC,
            topology: topology,
            quantizationHalfStep: quantizationHalfStep,
            operatingDays: operatingDays,
            wallDays: wallDays,
            usedWallClockFallback: operatingDays == nil,
            spansResearchSession: researchIntervals.contains { $0.intersects(DateInterval(start: start.capturedAt, end: end.capturedAt)) },
            spansInstrumentBoundary: instrumentBoundaries.contains { $0.boundary.after > start.capturedAt && $0.boundary.after <= end.capturedAt },
            refreshDeltas: refreshDeltas(start: start, end: end),
            notes: operatingDays == nil ? ["Power On Hoursが欠測のため壁時計日を補助的に使用しました。"] : []
        )
    }

    private func makeDiagnosticBaseline(
        kind: LongBaselineKind,
        start: ASPToolDiagnosticsSnapshot,
        end: ASPToolDiagnosticsSnapshot,
        topology: DirectFTLTopology,
        startHost: Double,
        endHost: Double,
        startNAND: Double,
        endNAND: Double,
        startTLC: Double,
        endTLC: Double,
        startPSLC: Double,
        endPSLC: Double,
        quantizationHalfStep: Double,
        researchIntervals: [DateInterval],
        instrumentBoundaries: [InstrumentBoundaryRecord],
        topologyChanged: Bool
    ) -> LongBaselineResidual {
        makeValues(
            kind: kind,
            path: .averagePE,
            anchor: start,
            end: end,
            deltaHost: max(0, endHost - startHost),
            deltaNAND: max(0, endNAND - startNAND),
            tlcDelta: max(0, endTLC - startTLC),
            pslcDelta: max(0, endPSLC - startPSLC),
            topology: topology,
            quantizationHalfStep: quantizationHalfStep,
            operatingDays: nil,
            wallDays: max(0, end.capturedAt.timeIntervalSince(start.capturedAt) / 86_400),
            usedWallClockFallback: true,
            spansResearchSession: researchIntervals.contains { $0.intersects(DateInterval(start: start.capturedAt, end: end.capturedAt)) },
            spansInstrumentBoundary: instrumentBoundaries.contains { $0.boundary.after > start.capturedAt && $0.boundary.after <= end.capturedAt },
            refreshDeltas: refreshDeltas(start: start, end: end),
            notes: topologyChanged ? ["区間途中でtopologyが変化したため、端点容量による診断値を予算・判別統計へ使用しません。"] : [],
            forcedStatus: .topologyChangedWithinSpan
        )
    }

    private func makeValues(
        kind: LongBaselineKind,
        path: ResidualReconstructionPath,
        anchor: ASPToolDiagnosticsSnapshot?,
        end: ASPToolDiagnosticsSnapshot,
        deltaHost: Double,
        deltaNAND: Double,
        tlcDelta: Double,
        pslcDelta: Double,
        topology: DirectFTLTopology,
        quantizationHalfStep: Double,
        operatingDays: Double?,
        wallDays: Double?,
        usedWallClockFallback: Bool,
        spansResearchSession: Bool,
        spansInstrumentBoundary: Bool,
        refreshDeltas: (UInt64?, UInt64?, UInt64?, UInt64?),
        notes: [String],
        forcedStatus: LongBaselineResidualStatus? = nil,
        knownValues: (low: Double, best: Double, high: Double)? = nil,
        bandDeltas: (tlc: Double, pslc: Double)? = nil
    ) -> LongBaselineResidual {
        let tlcCapacity = Double(topology.tlcCapacityBytes ?? 0)
        let pslcCapacity = Double(topology.pslcWritableCapacityBytes ?? 0)
        let knownBest = tlcCapacity * tlcDelta + pslcCapacity * pslcDelta
        let knownLow = tlcCapacity * max(0, tlcDelta - quantizationHalfStep)
            + pslcCapacity * max(0, pslcDelta - quantizationHalfStep)
        let knownHigh = tlcCapacity * (tlcDelta + quantizationHalfStep)
            + pslcCapacity * (pslcDelta + quantizationHalfStep)
        let resolvedKnownLow = knownValues?.low ?? knownLow
        let resolvedKnownBest = knownValues?.best ?? knownBest
        let resolvedKnownHigh = knownValues?.high ?? knownHigh
        let residualLow = deltaNAND - resolvedKnownHigh
        let residualBest = deltaNAND - resolvedKnownBest
        let residualHigh = deltaNAND - resolvedKnownLow
        let calculatedStatus: LongBaselineResidualStatus = {
            guard [residualLow, residualBest, residualHigh].allSatisfy(\.isFinite) else { return .indeterminate }
            if knownValues == nil, tlcDelta < 2 && pslcDelta < 2 { return .insufficientProgress }
            if residualLow > 0 { return .resolvedPositive }
            if residualHigh < 0 { return .resolvedNegative }
            return .indeterminate
        }()
        let status = forcedStatus ?? calculatedStatus
        var resultNotes = notes
        if spansResearchSession { resultNotes.append("研究試験区間を跨いでいます。残差整合は維持し、日常レート学習とは分離しています。") }
        if spansInstrumentBoundary { resultNotes.append("計測器境界を跨いでいます。長基線の物理累積には含め、率学習の72時間除外は適用していません。") }
        if status == .resolvedPositive || status == .resolvedNegative {
            resultNotes.append("正規化値とequivalent pSLC bandを記述統計として表示できます。原因は自動確定しません。")
        } else if status == .indeterminate {
            resultNotes.append("量子化範囲が0を含むため、正規化値とequivalent pSLC bandは表示しません。")
        }
        return LongBaselineResidual(
            kind: kind,
            path: path,
            anchorSnapshotID: anchor?.id,
            endSnapshotID: end.id,
            anchorAt: anchor?.capturedAt,
            endAt: end.capturedAt,
            wallDays: wallDays,
            operatingDays: operatingDays,
            usedWallClockFallback: usedWallClockFallback,
            spansResearchSession: spansResearchSession,
            spansInstrumentBoundary: spansInstrumentBoundary,
            deltaHostBytes: deltaHost,
            deltaNANDBytes: deltaNAND,
            tlcPEDelta: tlcDelta,
            pslcPEDelta: pslcDelta,
            quantizationHalfStep: quantizationHalfStep,
            knownLowBytes: resolvedKnownLow,
            knownBestBytes: resolvedKnownBest,
            knownHighBytes: resolvedKnownHigh,
            residualLowBytes: residualLow,
            residualBestBytes: residualBest,
            residualHighBytes: residualHigh,
            status: status,
            residualPerHost: status.isResolved ? normalizedRange(low: residualLow, high: residualHigh, denominator: deltaHost) : nil,
            residualPerKnown: status.isResolved ? normalizedRange(low: residualLow, high: residualHigh, denominator: resolvedKnownBest) : nil,
            residualPerOperatingDay: status.isResolved ? normalizedRange(low: residualLow, high: residualHigh, denominator: operatingDays.map { $0 * 86_400 }) : nil,
            residualPerWallDay: status.isResolved ? normalizedRange(low: residualLow, high: residualHigh, denominator: wallDays.map { $0 * 86_400 }) : nil,
            equivalentPSLCBands: {
                guard status.isResolved, let bandBytes = topology.pslcBandBytes, bandBytes > 0 else { return nil }
                let value = residualBest / Double(bandBytes)
                return value.isFinite ? value : nil
            }(),
            tlcBandDelta: bandDeltas?.tlc,
            pslcBandDelta: bandDeltas?.pslc,
            ageRefreshDelta: refreshDeltas.0,
            backgroundRefreshDelta: refreshDeltas.1,
            bandsPaddedForAgeDelta: refreshDeltas.2,
            bandsRefreshedOnErrorDelta: refreshDeltas.3,
            notes: resultNotes
        )
    }

    private func makeBandCalibration(
        series: [ASPToolDiagnosticsSnapshot],
        excluding: [DateInterval]
    ) -> [BandCounterCalibration] {
        let valid = series.compactMap { sample -> (Date, Double, Double)? in
            guard let topology = sample.directTopology,
                  let tlcPE = finitePositive(sample.tlcAveragePE),
                  let pslcPE = finitePositive(sample.slcAveragePE),
                  let tlcCounter = sample.userBandsProgrammed,
                  let pslcCounter = sample.intermediateBandsProgrammed else { return nil }
            let tlcDenominator = Double(topology.tlcBandCount) * tlcPE
            let pslcDenominator = Double(topology.intermediateBandCount) * pslcPE
            guard tlcDenominator > 0, pslcDenominator > 0 else { return nil }
            let tlcRatio = Double(tlcCounter) / tlcDenominator
            let pslcRatio = Double(pslcCounter) / pslcDenominator
            guard tlcRatio.isFinite, pslcRatio.isFinite else { return nil }
            return (sample.capturedAt, tlcRatio, pslcRatio)
        }
        let tlcRatios = valid.map { $0.1 }
        let pslcRatios = valid.map { $0.2 }
        let cumulativeVerified = valid.count >= 3 &&
            tlcRatios.allSatisfy { (0.95...1.05).contains($0) } &&
            pslcRatios.allSatisfy { (0.95...1.05).contains($0) } &&
            spread(tlcRatios) <= 0.01 && spread(pslcRatios) <= 0.01

        let increments = bandCounterIncrementRatios(series: series, excluding: excluding)
        let incrementalVerified = incrementEvidenceIsVerified(increments.tlc) &&
            incrementEvidenceIsVerified(increments.pslc)
        let verified = cumulativeVerified || incrementalVerified
        let validationMethod = cumulativeVerified ? "累積比" : (incrementalVerified ? "増分比" : "未検証")
        let latest = series.last!
        let latestRatios = valid.last(where: { $0.0 == latest.capturedAt })
        let note: String
        if cumulativeVerified {
            note = "累積比: \(valid.count) snapshotで両domainのband/P/E比率が0.95〜1.05かつ変動1%以内。意味検証済み。"
        } else if incrementalVerified {
            note = "増分比: P/E上昇点間をdomain別に集約。TLC ΔPE \(formatPEDelta(increments.tlc.peDelta))、pSLC ΔPE \(formatPEDelta(increments.pslc.peDelta))。両domainの比率が0.95〜1.05かつΔPE 3以上。研究診断として検証済み。"
        } else if valid.isEmpty {
            note = "key 349/350、topology、平均P/Eの比較可能な組がありません。累積比・増分比とも未検証です。"
        } else {
            note = "\(valid.count) snapshotを確認。増分比はTLC ΔPE \(formatPEDelta(increments.tlc.peDelta))、pSLC ΔPE \(formatPEDelta(increments.pslc.peDelta))（各domainで3以上が必要）。比率条件またはP/E進行条件が未達です。自動倍率補正なし。"
        }
        return [BandCounterCalibration(
            capturedAt: latest.capturedAt,
            tlcRatio: latestRatios?.1,
            pslcRatio: latestRatios?.2,
            stableSnapshotCount: valid.count,
            incrementalTLC: increments.tlc,
            incrementalPSLC: increments.pslc,
            validationMethod: validationMethod,
            verified: verified,
            note: note
        )]
    }

    private func incrementEvidenceIsVerified(_ evidence: BandCounterIncrementEvidence) -> Bool {
        guard let peDelta = evidence.peDelta,
              peDelta >= Self.minimumBandCounterIncrementPEDelta,
              let ratio = evidence.ratio else { return false }
        return (0.95...1.05).contains(ratio)
    }

    private func formatPEDelta(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "未取得"
    }

    private func bandCounterIncrementRatios(
        series: [ASPToolDiagnosticsSnapshot],
        excluding: [DateInterval]
    ) -> (tlc: BandCounterIncrementEvidence, pslc: BandCounterIncrementEvidence) {
        let tlc = bandCounterIncrementEvidence(
            series: series,
            excluding: excluding,
            pE: { $0.tlcAveragePE },
            programmedBands: { $0.userBandsProgrammed },
            domainBandCount: { $0.tlcBandCount }
        )
        let pslc = bandCounterIncrementEvidence(
            series: series,
            excluding: excluding,
            pE: { $0.slcAveragePE },
            programmedBands: { $0.intermediateBandsProgrammed },
            domainBandCount: { $0.intermediateBandCount }
        )
        return (tlc, pslc)
    }

    private func bandCounterIncrementEvidence(
        series: [ASPToolDiagnosticsSnapshot],
        excluding: [DateInterval],
        pE: (ASPToolDiagnosticsSnapshot) -> Double?,
        programmedBands: (ASPToolDiagnosticsSnapshot) -> UInt64?,
        domainBandCount: (DirectFTLTopology) -> UInt64
    ) -> BandCounterIncrementEvidence {
        typealias Point = (snapshot: ASPToolDiagnosticsSnapshot, pE: Double, programmedBands: UInt64, bandCount: UInt64)

        var runs: [[Point]] = []
        var currentRun: [Point] = []

        func finishRun() {
            if !currentRun.isEmpty { runs.append(currentRun) }
            currentRun.removeAll(keepingCapacity: true)
        }

        for snapshot in series {
            guard let topology = snapshot.directTopology,
                  let pEValue = finiteNonnegative(pE(snapshot)),
                  let counter = programmedBands(snapshot) else {
                finishRun()
                continue
            }
            let bandCount = domainBandCount(topology)
            guard bandCount > 0 else {
                finishRun()
                continue
            }
            let point: Point = (snapshot, pEValue, counter, bandCount)

            guard let previous = currentRun.last else {
                currentRun = [point]
                continue
            }
            let intervalIsEligible: Bool
            if snapshot.capturedAt > previous.snapshot.capturedAt {
                let interval = DateInterval(start: previous.snapshot.capturedAt, end: snapshot.capturedAt)
                intervalIsEligible = !excluding.contains(where: { $0.intersects(interval) })
            } else {
                intervalIsEligible = false
            }
            let isContinuous = intervalIsEligible &&
                previous.snapshot.directTopology?.isEquivalentGeometry(to: topology) == true &&
                previous.bandCount == bandCount &&
                pEValue >= previous.pE &&
                counter >= previous.programmedBands

            if isContinuous {
                currentRun.append(point)
            } else {
                finishRun()
                currentRun = [point]
            }
        }
        finishRun()

        var totalProgrammed = 0.0
        var totalExpected = 0.0
        var totalPEDelta = 0.0
        var totalIntervals = 0
        var totalDays = 0.0
        var riseBoundaryCount = 0
        var largestObservedPEDelta: Double?
        var largestObservedRatio: Double?
        var largestObservedIntervals = 0
        var largestObservedDays = 0.0

        for run in runs where run.count >= 2 {
            let riseBoundaries = run.indices.dropFirst().filter { run[$0].pE > run[$0 - 1].pE }
            riseBoundaryCount += riseBoundaries.count
            guard let firstBoundary = riseBoundaries.first,
                  let lastBoundary = riseBoundaries.last,
                  firstBoundary < lastBoundary else { continue }

            let start = run[firstBoundary]
            let end = run[lastBoundary]
            let deltaPE = end.pE - start.pE
            let expectedPrograms = Double(start.bandCount) * deltaPE
            let programmedDelta = end.programmedBands >= start.programmedBands
                ? Double(end.programmedBands - start.programmedBands)
                : nil
            guard deltaPE > 0, deltaPE.isFinite,
                  expectedPrograms > 0, expectedPrograms.isFinite,
                  let programmedDelta else { continue }
            let spanRatio = programmedDelta / expectedPrograms
            guard spanRatio.isFinite else { continue }

            let spanIntervals = lastBoundary - firstBoundary
            let spanDays = end.snapshot.capturedAt.timeIntervalSince(start.snapshot.capturedAt) / 86_400
            if largestObservedPEDelta.map({ deltaPE > $0 }) ?? true {
                largestObservedPEDelta = deltaPE
                largestObservedRatio = spanRatio
                largestObservedIntervals = spanIntervals
                largestObservedDays = spanDays
            }

            // Integer average P/E counters can remain unchanged for days.
            // Measure only the span between observed rise boundaries and
            // require at least three P/E steps in each uninterrupted run.
            guard deltaPE >= Self.minimumBandCounterIncrementPEDelta else { continue }

            totalProgrammed += programmedDelta
            totalExpected += expectedPrograms
            totalPEDelta += deltaPE
            totalIntervals += spanIntervals
            totalDays += spanDays
        }

        let hasEligibleSpan = totalExpected > 0
        let ratio = hasEligibleSpan ? totalProgrammed / totalExpected : largestObservedRatio
        return BandCounterIncrementEvidence(
            ratio: ratio.flatMap { $0.isFinite ? $0 : nil },
            peDelta: hasEligibleSpan ? (totalPEDelta.isFinite ? totalPEDelta : nil) : largestObservedPEDelta,
            riseBoundaryCount: riseBoundaryCount,
            intervalCount: hasEligibleSpan ? totalIntervals : largestObservedIntervals,
            observationDays: hasEligibleSpan ? (totalDays.isFinite ? totalDays : 0) : largestObservedDays
        )
    }

    private func normalizationStability(baselines: [LongBaselineResidual]) -> [String: Double] {
        let segments = baselines.filter { if case .segment = $0.kind { return $0.status.isResolved }; return false }
        func bestValue(_ range: ClosedRange<Double>?) -> Double? {
            guard let range else { return nil }
            let value = (range.lowerBound + range.upperBound) / 2
            return value.isFinite ? value : nil
        }
        let values: [(String, [Double])] = [
            ("host", segments.compactMap { bestValue($0.residualPerHost) }),
            ("known", segments.compactMap { bestValue($0.residualPerKnown) }),
            ("operatingDay", segments.compactMap { bestValue($0.residualPerOperatingDay) }),
            ("wallDay", segments.compactMap { bestValue($0.residualPerWallDay) })
        ]
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, samples in
            let positive = samples.filter { $0.isFinite && $0 > 0 }
            guard positive.count >= 3 else { return nil }
            let mean = positive.reduce(0, +) / Double(positive.count)
            guard mean > 0 else { return nil }
            let variance = positive.reduce(0) { $0 + pow($1 - mean, 2) } / Double(positive.count)
            let cv = sqrt(variance) / mean
            return cv.isFinite ? (key, cv) : nil
        })
    }

    private func makeProjection(
        baselines: [LongBaselineResidual],
        series: [ASPToolDiagnosticsSnapshot]
    ) -> ResolutionProjection? {
        guard let lifetime = baselines.first(where: { $0.kind == .lifetime && $0.status == .resolvedPositive }),
              let topology = series.last?.directTopology,
              let ratio = lifetime.residualPerHost,
              ratio.lowerBound > 0 else { return nil }
        let recentRates = zip(series, series.dropFirst()).compactMap { start, end -> Double? in
            guard let hostStart = start.hostWrittenBytes, let hostEnd = end.hostWrittenBytes,
                  hostEnd > hostStart else { return nil }
            let days = end.capturedAt.timeIntervalSince(start.capturedAt) / 86_400
            guard days > 0, days.isFinite else { return nil }
            let rate = (hostEnd - hostStart) / days
            return rate.isFinite && rate > 0 ? rate : nil
        }
        guard let hostRate = recentRates.last ?? recentRates.first,
              let tlcProgress = series.compactMap(\.tlcAveragePE).first.map({ (series.last?.tlcAveragePE ?? 0) - $0 }),
              let width = topology.tlcCapacityBytes.flatMap({ tlc in topology.pslcWritableCapacityBytes.map { tlc + $0 } }),
              width.isFinite, width > 0 else { return nil }
        let lower = width / (ratio.upperBound * hostRate)
        let upper = width / (ratio.lowerBound * hostRate)
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower else { return nil }
        return ResolutionProjection(
            targetTLCProgress: 40,
            currentTLCProgress: tlcProgress.isFinite ? tlcProgress : nil,
            hostBytesPerDay: hostRate,
            estimatedDays: lower...upper,
            basis: "生涯残差のHost比を一定とする仮説。原因・故障時期・TBWを予測しません。"
        )
    }

    private func refreshDeltas(
        start: ASPToolDiagnosticsSnapshot,
        end: ASPToolDiagnosticsSnapshot
    ) -> (UInt64?, UInt64?, UInt64?, UInt64?) {
        (
            difference(start.researchTelemetry?.ageRefreshTotal, end.researchTelemetry?.ageRefreshTotal),
            difference(start.researchTelemetry?.backgroundRefreshMoves, end.researchTelemetry?.backgroundRefreshMoves),
            difference(start.researchTelemetry?.bandsPaddedForAge, end.researchTelemetry?.bandsPaddedForAge),
            difference(start.researchTelemetry?.bandsRefreshedOnError, end.researchTelemetry?.bandsRefreshedOnError)
        )
    }

    private func spanIsMonotonic(_ samples: [ASPToolDiagnosticsSnapshot]) -> Bool {
        guard !samples.isEmpty else { return false }
        for sample in samples {
            guard sample.hostWrittenBytes != nil,
                  sample.nandWrittenBytes != nil,
                  finiteNonnegative(sample.tlcAveragePE) != nil,
                  finiteNonnegative(sample.slcAveragePE) != nil else { return false }
        }
        for (before, after) in zip(samples, samples.dropFirst()) {
            guard let beforeHost = before.hostWrittenBytes,
                  let afterHost = after.hostWrittenBytes,
                  let beforeNAND = before.nandWrittenBytes,
                  let afterNAND = after.nandWrittenBytes,
                  let beforeTLC = finiteNonnegative(before.tlcAveragePE),
                  let afterTLC = finiteNonnegative(after.tlcAveragePE),
                  let beforePSLC = finiteNonnegative(before.slcAveragePE),
                  let afterPSLC = finiteNonnegative(after.slcAveragePE),
                  afterHost >= beforeHost,
                  afterNAND >= beforeNAND,
                  afterTLC >= beforeTLC,
                  afterPSLC >= beforePSLC else { return false }
            if let beforeHours = before.powerOnHours,
               let afterHours = after.powerOnHours,
               afterHours < beforeHours { return false }
        }
        return true
    }

    private func bandCountersAreMonotonic(_ samples: [ASPToolDiagnosticsSnapshot]) -> Bool {
        guard !samples.isEmpty else { return false }
        for (before, after) in zip(samples, samples.dropFirst()) {
            guard let beforeTLC = before.userBandsProgrammed,
                  let afterTLC = after.userBandsProgrammed,
                  let beforePSLC = before.intermediateBandsProgrammed,
                  let afterPSLC = after.intermediateBandsProgrammed,
                  afterTLC >= beforeTLC,
                  afterPSLC >= beforePSLC else { return false }
        }
        return samples.count == 1 || samples.dropFirst().allSatisfy {
            $0.userBandsProgrammed != nil && $0.intermediateBandsProgrammed != nil
        }
    }

    private func normalizedRange(low: Double, high: Double, denominator: Double?) -> ClosedRange<Double>? {
        guard let denominator, denominator.isFinite, denominator > 0,
              low.isFinite, high.isFinite else { return nil }
        return (low / denominator)...(high / denominator)
    }

    private func spread(_ values: [Double]) -> Double {
        guard !values.isEmpty, let min = values.min(), let max = values.max() else { return .infinity }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0, mean.isFinite else { return .infinity }
        return (max - min) / mean
    }

    private func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func difference(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after, after >= before else { return nil }
        return after - before
    }

    private func unique(_ notes: [String]) -> [String] {
        var result: [String] = []
        for note in notes where !note.isEmpty && !result.contains(note) { result.append(note) }
        return result
    }
}
