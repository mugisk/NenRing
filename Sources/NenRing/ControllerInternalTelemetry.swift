import Foundation

struct WearSpreadObservation: Equatable, Sendable {
    let averagePEStart: Double
    let averagePEEnd: Double
    let maximumPEStart: Double
    let maximumPEEnd: Double

    var absoluteSpreadStart: Double { maximumPEStart - averagePEStart }
    var absoluteSpreadEnd: Double { maximumPEEnd - averagePEEnd }
    var absoluteSpreadChange: Double { absoluteSpreadEnd - absoluteSpreadStart }
}

/// Same-series deltas for raw controller statistics. The ASP counters remain
/// raw: this type deliberately does not infer bytes or a refresh mechanism.
struct ControllerInternalTelemetrySummary: Equatable, Sendable {
    let startCapturedAt: Date?
    let endCapturedAt: Date?
    let observationDays: Double?
    let hostAutoWritesRawDelta: UInt64?
    let hostAutoWritesRawPerDay: Double?
    let hostWritesRawDelta: UInt64?
    let hostWritesUnitState: ASPToolUnitState
    let grownBadBlocksDelta: Int64?
    let factoryBadBlocksDelta: Int64?
    let dieFailuresDelta: Int64?
    let spareAvailablePercentChange: Double?
    let oslcTransitionsDelta: Int64?
    let oslcBaseAveragePEStart: Double?
    let oslcBaseAveragePEEnd: Double?
    let tlcWearSpread: WearSpreadObservation?
    let pslcWearSpread: WearSpreadObservation?
    let notes: [String]

    static let unavailable = ControllerInternalTelemetrySummary(
        startCapturedAt: nil, endCapturedAt: nil, observationDays: nil,
        hostAutoWritesRawDelta: nil, hostAutoWritesRawPerDay: nil,
        hostWritesRawDelta: nil, hostWritesUnitState: .unavailable,
        grownBadBlocksDelta: nil, factoryBadBlocksDelta: nil,
        dieFailuresDelta: nil, spareAvailablePercentChange: nil,
        oslcTransitionsDelta: nil, oslcBaseAveragePEStart: nil,
        oslcBaseAveragePEEnd: nil, tlcWearSpread: nil, pslcWearSpread: nil,
        notes: ["同一系列のDirect FTL時系列がありません"]
    )

    static func unavailableWithReason(_ reason: String) -> ControllerInternalTelemetrySummary {
        ControllerInternalTelemetrySummary(
            startCapturedAt: nil, endCapturedAt: nil, observationDays: nil,
            hostAutoWritesRawDelta: nil, hostAutoWritesRawPerDay: nil,
            hostWritesRawDelta: nil, hostWritesUnitState: .unavailable,
            grownBadBlocksDelta: nil, factoryBadBlocksDelta: nil,
            dieFailuresDelta: nil, spareAvailablePercentChange: nil,
            oslcTransitionsDelta: nil, oslcBaseAveragePEStart: nil,
            oslcBaseAveragePEEnd: nil, tlcWearSpread: nil, pslcWearSpread: nil,
            notes: [reason]
        )
    }
}

struct ControllerInternalTelemetryAnalyzer: Sendable {
    func summarize(
        snapshots: [ASPToolDiagnosticsSnapshot],
        deviceID: String?,
        excluding: [DateInterval] = [],
        smartHistory: [DriveSnapshot] = [],
        continuityLane suppliedLane: WearContinuityLane? = nil
    ) -> ControllerInternalTelemetrySummary {
        let rawOrdered = snapshots
            .filter { $0.sourceArtifact == .directFTL && (deviceID == nil || $0.deviceID == deviceID) }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let latest = rawOrdered.last else { return .unavailable }
        guard DirectFTLResearchContract.researchTelemetryIsEligible(latest) else {
            let runtime = latest.sourceBuild ?? "不明"
            let contract = DirectFTLResearchContract.contractBuild(for: latest) ?? "不明"
            return .unavailableWithReason("研究用keyの対応表が未確認（実行build \(runtime)／対応表のbuild \(contract)）。raw値は保存し、内部counter差分は保留しています。")
        }
        let lane = suppliedLane ?? WearContinuityLaneBuilder.build(
            snapshots: rawOrdered,
            smart: smartHistory,
            latest: latest
        )
        guard lane.snapshots.contains(where: { $0.id == latest.id }) else {
            return .unavailableWithReason("Direct FTLは取得済みですが、コア系列の境界が未検証のため内部counter差分を保留しています。")
        }
        let ordered = lane.snapshots.filter { $0.sourceArtifact == .directFTL }
        let effectiveExcluding = excluding + lane.rateLearningExclusions

        let eligible = zip(ordered, ordered.dropFirst()).compactMap { start, end
            -> (ASPToolDiagnosticsSnapshot, ASPToolDiagnosticsSnapshot, Double)? in
            guard start.captureQuality == .explicit,
                  end.captureQuality == .explicit,
                  DirectFTLResearchContract.researchTelemetryPairIsComparable(start, end),
                  let id = start.deviceID, !id.isEmpty,
                  end.deviceID == id,
                  ControllerWearSeriesIdentity(snapshot: start) == ControllerWearSeriesIdentity(snapshot: end),
                  end.capturedAt > start.capturedAt else { return nil }
            let interval = DateInterval(start: start.capturedAt, end: end.capturedAt)
            guard !effectiveExcluding.contains(where: { $0.intersects(interval) }) else { return nil }
            return (start, end, interval.duration / 86_400)
        }

        guard let (start, end, days) = eligible.last, days > 0, days.isFinite else {
            return .unavailable
        }

        var notes: [String] = []
        func unsignedDelta(_ first: UInt64?, _ last: UInt64?, label: String, notes: inout [String]) -> UInt64? {
            guard let first, let last else { return nil }
            guard last >= first else {
                notes.append("\(label)カウンタが減少したため区間差分を除外しました")
                return nil
            }
            return last - first
        }
        func signedDelta(_ first: UInt64?, _ last: UInt64?, label: String, notes: inout [String]) -> Int64? {
            guard let first, let last else { return nil }
            guard last >= first, last - first <= UInt64(Int64.max) else {
                notes.append("\(label)カウンタが減少または範囲外のため区間差分を除外しました")
                return nil
            }
            return Int64(last - first)
        }
        func finitePE(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        func spread(_ avg0: Double?, _ avg1: Double?, _ max0: Double?, _ max1: Double?, name: String) -> WearSpreadObservation? {
            guard let avg0 = finitePE(avg0), let avg1 = finitePE(avg1),
                  let max0 = finitePE(max0), let max1 = finitePE(max1),
                  max0 >= avg0, max1 >= avg1,
                  avg1 >= avg0, max1 >= max0 else {
                notes.append("\(name) P/Eが欠測・不正・退行のため損耗幅比較を除外しました")
                return nil
            }
            return WearSpreadObservation(
                averagePEStart: avg0, averagePEEnd: avg1,
                maximumPEStart: max0, maximumPEEnd: max1
            )
        }

        let hostAutoDelta = unsignedDelta(start.hostAutoWrites, end.hostAutoWrites, label: "hostAutoWrites", notes: &notes)
        if start.hostAutoWrites == nil || end.hostAutoWrites == nil {
            notes.append("hostAutoWritesが両時点で揃っていません")
        }
        notes.append("hostAutoWritesは単位未確認のraw値です。GB換算やrefresh判定には使いません。")
        let oslcPEStart = finitePE(start.oslcBaseAveragePE)
        let oslcPEEnd = finitePE(end.oslcBaseAveragePE)
        let oslcPEPair: (Double?, Double?)
        if let oslcPEStart, let oslcPEEnd, oslcPEEnd >= oslcPEStart {
            oslcPEPair = (oslcPEStart, oslcPEEnd)
        } else {
            oslcPEPair = (nil, nil)
            if oslcPEStart != nil || oslcPEEnd != nil {
                notes.append("oSLC base average P/Eが欠測・不正・退行のため比較を除外しました")
            }
        }
        return ControllerInternalTelemetrySummary(
            startCapturedAt: start.capturedAt,
            endCapturedAt: end.capturedAt,
            observationDays: days,
            hostAutoWritesRawDelta: hostAutoDelta,
            hostAutoWritesRawPerDay: hostAutoDelta.map { Double($0) / days },
            hostWritesRawDelta: unsignedDelta(start.hostWrites, end.hostWrites, label: "Host Writes", notes: &notes),
            hostWritesUnitState: start.hostWritesUnitState,
            grownBadBlocksDelta: signedDelta(start.grownBadBlocks, end.grownBadBlocks, label: "Grown Bad Blocks", notes: &notes),
            factoryBadBlocksDelta: signedDelta(start.factoryBadBlocks, end.factoryBadBlocks, label: "Factory Bad Blocks", notes: &notes),
            dieFailuresDelta: signedDelta(start.numDieFailures, end.numDieFailures, label: "Die failures", notes: &notes),
            spareAvailablePercentChange: finiteDifference(start.spareAvailablePercent, end.spareAvailablePercent),
            oslcTransitionsDelta: signedDelta(start.oslcTransitions, end.oslcTransitions, label: "oSLC transitions", notes: &notes),
            oslcBaseAveragePEStart: oslcPEPair.0,
            oslcBaseAveragePEEnd: oslcPEPair.1,
            tlcWearSpread: spread(start.tlcAveragePE, end.tlcAveragePE, start.tlcMaximumPE, end.tlcMaximumPE, name: "TLC"),
            pslcWearSpread: spread(start.slcAveragePE, end.slcAveragePE, start.slcMaximumPE, end.slcMaximumPE, name: "pSLC"),
            notes: Array(Set(notes)).sorted()
        )
    }

    private func finiteDifference(_ first: Double?, _ last: Double?) -> Double? {
        guard let first, let last, first.isFinite, last.isFinite else { return nil }
        return last - first
    }
}
