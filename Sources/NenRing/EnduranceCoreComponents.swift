import Foundation

struct ForecastWAFEstimate: Equatable, Sendable {
    let longTermWAF: Double?
    let recentWAF: Double?
    let observedHostBytes: Double
    let priorEquivalentHostBytes: Double
    let recentWeight: Double
    let forecastWAF: Double?
}

enum ForecastWAFEstimator {
    static let defaultPriorEquivalentHostBytes = 1e12

    static func estimate(
        longTermWAF: Double?,
        recentWAF: Double?,
        observedHostBytes: Double,
        priorEquivalentHostBytes suppliedPrior: Double?
    ) -> ForecastWAFEstimate {
        let prior = suppliedPrior.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        } ?? defaultPriorEquivalentHostBytes
        let observedHost = observedHostBytes.isFinite && observedHostBytes > 0 ? observedHostBytes : 0
        let q = observedHost > 0 ? min(1, observedHost / (observedHost + prior)) : 0

        let long = longTermWAF.flatMap { value in value.isFinite && value > 0 ? value : nil }
        let recent = recentWAF.flatMap { value in value.isFinite && value > 0 ? value : nil }
        let forecast: Double?
        if let long {
            let observed = recent ?? long
            let value = exp((1 - q) * log(long) + q * log(observed))
            forecast = value.isFinite && value > 0 ? value : nil
        } else {
            forecast = nil
        }

        return ForecastWAFEstimate(
            longTermWAF: long,
            recentWAF: recent,
            observedHostBytes: observedHost,
            priorEquivalentHostBytes: prior,
            recentWeight: q,
            forecastWAF: forecast
        )
    }
}

enum CumulativeHostSource: String, Equatable, Sendable {
    case matchedSMART
    case ftlFallback
    case unavailable

    var title: String {
        switch self {
        case .matchedSMART: return "SMART Data Units Written"
        case .ftlFallback: return "FTL Host counter（暫定）"
        case .unavailable: return "未取得"
        }
    }
}

struct CumulativeHostResolution: Equatable, Sendable {
    let hostBytes: Double?
    let source: CumulativeHostSource
    let matchedSMART: DriveSnapshot?
    let note: String?
}

enum CumulativeHostResolver {
    static let maximumTimeDelta: TimeInterval = 86_400
    static let maximumRelativeDifference = 0.10

    static func resolve(
        acceptedFTL: ASPToolDiagnosticsSnapshot,
        smartHistory: [DriveSnapshot],
        latestPermittedSMARTAt: Date? = nil
    ) -> CumulativeHostResolution {
        let ftlHost = acceptedFTL.hostWrittenBytes.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        guard let deviceID = acceptedFTL.deviceID, !deviceID.isEmpty else {
            return CumulativeHostResolution(
                hostBytes: ftlHost,
                source: ftlHost == nil ? .unavailable : .ftlFallback,
                matchedSMART: nil,
                note: "accepted FTL snapshotにdevice identityがないため、累積HostはFTL counterを使用します。"
            )
        }

        let candidates = smartHistory.filter { snapshot in
            if let latestPermittedSMARTAt, snapshot.capturedAt > latestPermittedSMARTAt {
                return false
            }
            guard snapshot.deviceID == deviceID,
                  let host = snapshot.dataUnitsWrittenBytes,
                  host.isFinite, host >= 0,
                  abs(snapshot.capturedAt.timeIntervalSince(acceptedFTL.capturedAt)) <= maximumTimeDelta
            else { return false }

            if let ftlFirmware = acceptedFTL.firmware, !ftlFirmware.isEmpty,
               let smartFirmware = snapshot.firmware, !smartFirmware.isEmpty,
               ftlFirmware != smartFirmware {
                return false
            }
            return true
        }
        let matched = candidates.min {
            abs($0.capturedAt.timeIntervalSince(acceptedFTL.capturedAt)) <
                abs($1.capturedAt.timeIntervalSince(acceptedFTL.capturedAt))
        }

        guard let matched, let smartHost = matched.dataUnitsWrittenBytes else {
            return CumulativeHostResolution(
                hostBytes: ftlHost,
                source: ftlHost == nil ? .unavailable : .ftlFallback,
                matchedSMART: nil,
                note: "accepted FTL snapshotの±24時間・同一device/firmwareに対応するSMART Hostがないため、累積HostはFTL counterを使用します。"
            )
        }

        if let ftlHost {
            // The documented tolerance is relative to the accepted FTL
            // counter. Using the SMART value as denominator can accept a
            // sample that is >10% above the FTL baseline.
            let denominator = max(ftlHost, 1)
            let difference = abs(ftlHost - smartHost) / denominator
            guard difference <= maximumRelativeDifference else {
                return CumulativeHostResolution(
                    hostBytes: ftlHost,
                    source: .ftlFallback,
                    matchedSMART: matched,
                    note: "SMARTとFTL Host累積値が10%以上相違するため、標準SMART累積Hostへの切替を保留しました。"
                )
            }
        }

        return CumulativeHostResolution(
            hostBytes: smartHost,
            source: .matchedSMART,
            matchedSMART: matched,
            note: nil
        )
    }
}

struct RetentionDeratingResult: Equatable, Sendable {
    let rawFactor: Double?
    let appliedFactor: Double
    let suppressed: Bool
}

enum RetentionDeratingPolicy {
    static func evaluate(
        daysRatio: Double?,
        environmentRatio: Double?,
        daysWeight: Double,
        environmentWeight: Double
    ) -> RetentionDeratingResult {
        guard let daysRatio, daysRatio.isFinite, daysRatio > 0,
              let environmentRatio, environmentRatio.isFinite, environmentRatio > 0,
              daysWeight.isFinite, (0...1).contains(daysWeight),
              environmentWeight.isFinite, (0...1).contains(environmentWeight)
        else {
            return RetentionDeratingResult(rawFactor: nil, appliedFactor: 1, suppressed: true)
        }
        let raw = pow(daysRatio, daysWeight) * pow(environmentRatio, environmentWeight)
        guard raw.isFinite, raw > 0 else {
            return RetentionDeratingResult(rawFactor: nil, appliedFactor: 1, suppressed: true)
        }
        return RetentionDeratingResult(rawFactor: raw, appliedFactor: min(1, raw), suppressed: false)
    }
}

struct DirectDomainBudgetCalculation: Equatable, Sendable {
    let estimates: [NANDDomainEstimate]
    let baselineEstimates: [NANDDomainEstimate]
    let baselineBudgetBytes: Double
    let adjustedBudgetBytes: Double
    let usedBytes: Double
    let adjustedRemainingBytes: Double
    let baselineRemainingBytes: Double
    let pslcPhysicalFootprintBytes: Double
}

enum DirectDomainBudgetCalculator {
    static func calculate(
        latest: ASPToolDiagnosticsSnapshot,
        topology: DirectFTLTopology,
        retentionFactor: Double
    ) -> DirectDomainBudgetCalculation? {
        guard let tlcPE = finiteNonnegative(latest.tlcAveragePE),
              let tlcEOL = finitePositive(latest.tlcEOLPE),
              let pslcPE = finiteNonnegative(latest.slcAveragePE),
              let pslcEOL = finitePositive(latest.slcEOLPE),
              let tlcCapacity = topology.tlcCapacityBytes,
              let pslcCapacity = topology.pslcWritableCapacityBytes,
              let pslcFootprint = topology.pslcPhysicalFootprintBytes,
              tlcCapacity.isFinite, tlcCapacity > 0,
              pslcCapacity.isFinite, pslcCapacity > 0,
              pslcFootprint.isFinite, pslcFootprint > 0
        else { return nil }

        let factor = retentionFactor.isFinite && retentionFactor > 0 ? min(1, retentionFactor) : 1
        func make(_ domain: NANDDomain, capacity: Double, footprint: Double?, currentPE: Double,
                  eolPE: Double, targetPE: Double) -> NANDDomainEstimate {
            NANDDomainEstimate(
                domain: domain,
                capacityBytes: capacity,
                physicalFootprintBytes: footprint,
                currentPE: currentPE,
                eolPE: eolPE,
                targetPE: targetPE,
                baselineBudgetBytes: capacity * eolPE,
                totalBudgetBytes: capacity * targetPE,
                usedBytes: capacity * currentPE,
                remainingBytes: capacity * max(0, targetPE - currentPE)
            )
        }

        let adjusted = [
            make(.tlc, capacity: tlcCapacity, footprint: tlcCapacity, currentPE: tlcPE,
                 eolPE: tlcEOL, targetPE: tlcEOL * factor),
            make(.pslc, capacity: pslcCapacity, footprint: pslcFootprint, currentPE: pslcPE,
                 eolPE: pslcEOL, targetPE: pslcEOL)
        ]
        let baseline = [
            make(.tlc, capacity: tlcCapacity, footprint: tlcCapacity, currentPE: tlcPE,
                 eolPE: tlcEOL, targetPE: tlcEOL),
            make(.pslc, capacity: pslcCapacity, footprint: pslcFootprint, currentPE: pslcPE,
                 eolPE: pslcEOL, targetPE: pslcEOL)
        ]

        let allValues = (adjusted + baseline).flatMap {
            [$0.baselineBudgetBytes, $0.totalBudgetBytes, $0.usedBytes, $0.remainingBytes]
        }
        guard allValues.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

        return DirectDomainBudgetCalculation(
            estimates: adjusted,
            baselineEstimates: baseline,
            baselineBudgetBytes: baseline.reduce(0) { $0 + $1.baselineBudgetBytes },
            adjustedBudgetBytes: adjusted.reduce(0) { $0 + $1.totalBudgetBytes },
            usedBytes: adjusted.reduce(0) { $0 + $1.usedBytes },
            adjustedRemainingBytes: adjusted.reduce(0) { $0 + $1.remainingBytes },
            baselineRemainingBytes: baseline.reduce(0) { $0 + $1.remainingBytes },
            pslcPhysicalFootprintBytes: pslcFootprint
        )
    }

    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

struct NANDReconciliationResult: Equatable, Sendable {
    let currentError: Double?
    let budgetError: Double?
    let diagnostics: NANDReconstructionDiagnostics?
}

enum NANDReconciliationDiagnosticsBuilder {
    static func build(
        topology: DirectFTLTopology,
        latest: ASPToolDiagnosticsSnapshot,
        measuredNAND: Double?,
        knownUsed: Double?,
        domainBaselineBudget: Double?,
        nominalBudget: Double?
    ) -> NANDReconciliationResult {
        let currentError: Double? = {
            guard let measuredNAND, measuredNAND.isFinite, measuredNAND > 0,
                  let knownUsed, knownUsed.isFinite else { return nil }
            return abs(knownUsed - measuredNAND) / measuredNAND
        }()
        let budgetError: Double? = {
            guard let nominalBudget, nominalBudget.isFinite, nominalBudget > 0,
                  let domainBaselineBudget, domainBaselineBudget.isFinite else { return nil }
            return abs(domainBaselineBudget - nominalBudget) / nominalBudget
        }()
        let rawEquivalentPSLCBands: Double? = {
            guard let measuredNAND, measuredNAND.isFinite,
                  let tlcCapacity = topology.tlcCapacityBytes,
                  let pslcBandBytes = topology.pslcBandBytes,
                  let tlcPE = latest.tlcAveragePE, tlcPE.isFinite,
                  let pslcPE = latest.slcAveragePE, pslcPE.isFinite, pslcPE > 0
            else { return nil }
            let denominator = Double(pslcBandBytes) * pslcPE
            let allTLC = tlcCapacity * tlcPE
            guard denominator.isFinite, denominator > 0, allTLC.isFinite else { return nil }
            let raw = (measuredNAND - allTLC) / denominator
            return raw.isFinite ? raw : nil
        }()
        let diagnostics: NANDReconstructionDiagnostics? = {
            guard let measuredNAND, let knownUsed else { return nil }
            let residual = measuredNAND - knownUsed
            guard residual.isFinite else { return nil }
            return NANDReconstructionDiagnostics(
                knownDomainUsedBytes: knownUsed,
                measuredNANDBytes: measuredNAND,
                signedResidualBytes: residual,
                rawEquivalentPSLCBands: rawEquivalentPSLCBands,
                residualEquivalentPSLCBands: rawEquivalentPSLCBands.map {
                    $0 - Double(topology.intermediateBandCount)
                },
                currentReconstructionError: currentError,
                eolBudgetReconciliationError: budgetError,
                topologyContractValidated: topology.topologyContractValidated,
                physicalCapacityAllocationVerified: false
            )
        }()
        return NANDReconciliationResult(
            currentError: currentError,
            budgetError: budgetError,
            diagnostics: diagnostics
        )
    }
}

enum EnduranceProjectionBuilder {
    static func projection(
        title: String,
        budget: Double?,
        host: Double?,
        nand: Double?,
        waf: Double?,
        currentPhysicalBytes: Double? = nil,
        note: String
    ) -> NANDEnduranceV2.Projection {
        guard let budget, budget.isFinite, budget > 0,
              let host, host.isFinite, host >= 0,
              let currentPhysical = currentPhysicalBytes ?? nand,
              currentPhysical.isFinite, currentPhysical >= 0,
              let waf, waf.isFinite, waf > 0
        else {
            return NANDEnduranceV2.Projection(title: title, total: nil, remaining: nil, note: note)
        }
        let remaining = max(0, budget - currentPhysical) / waf
        guard remaining.isFinite, (host + remaining).isFinite else {
            return NANDEnduranceV2.Projection(title: title, total: nil, remaining: nil, note: "計算範囲外")
        }
        return NANDEnduranceV2.Projection(title: title, total: host + remaining, remaining: remaining, note: note)
    }
}

/// How host writes split between the TLC and pSLC domains. pSLC behaves as
/// a large write cache and only longer-lived data is folded into TLC, so
/// each domain wears at its own rate per host byte.
struct DomainWriteShare: Equatable, Sendable {
    /// Fraction of NAND writes that land in TLC (0...1).
    let tlcShare: Double
    let lifetimeTLCShare: Double
    let recentTLCShare: Double?

    /// P/E counters are integers, so the lifetime split needs at least this
    /// much TLC P/E before a one-cycle step stops moving it by 10% or more.
    static let minimumRecentTLCPEDelta = 10.0
    /// The recent split rests on pSLC P/E, which advances about a dozen
    /// cycles a day on the reference Mac; 50 cycles keep its one-cycle step
    /// within about 2%.
    static let minimumRecentPSLCPEDelta = 50.0

    static func estimate(
        estimates: [NANDDomainEstimate],
        series: [ASPToolDiagnosticsSnapshot],
        topology: DirectFTLTopology,
        windowDays: Int?,
        recentWeight: Double,
        excluding: [DateInterval]
    ) -> DomainWriteShare? {
        // With TLC P/E still below 10, a one-cycle step moves the lifetime
        // split by 10% or more, so the forecast stays on the combined
        // estimate until then.
        guard let tlc = estimates.first(where: { $0.domain == .tlc }),
              let pslc = estimates.first(where: { $0.domain == .pslc }),
              tlc.currentPE >= minimumRecentTLCPEDelta,
              tlc.usedBytes + pslc.usedBytes > 0 else { return nil }
        let lifetime = tlc.usedBytes / (tlc.usedBytes + pslc.usedBytes)
        guard lifetime > 0, lifetime < 1 else { return nil }

        let recent = windowDays.flatMap { days in
            recentShare(series: series, topology: topology, windowDays: days, excluding: excluding)
        }

        let q = recentWeight.isFinite ? min(1, max(0, recentWeight)) : 0
        let blended = recent.map { exp((1 - q) * log(lifetime) + q * log($0)) } ?? lifetime
        return DomainWriteShare(tlcShare: blended, lifetimeTLCShare: lifetime, recentTLCShare: recent)
    }

    /// TLC's share of recent NAND writes, taken as NAND writes less the pSLC
    /// writes implied by pSLC P/E. TLC P/E advances a cycle only every few
    /// days, so a split from TLC P/E jumps by tens of percent over short
    /// windows; the NAND counter and pSLC P/E move steadily. On the reference
    /// Mac both give the same mean over 7- and 14-day windows, this one with
    /// half the spread or less. Pairs of reads that overlap an excluded
    /// interval are skipped instead of discarding the whole window.
    static func recentShare(
        series: [ASPToolDiagnosticsSnapshot],
        topology: DirectFTLTopology,
        windowDays: Int,
        excluding: [DateInterval]
    ) -> Double? {
        guard let pslcCapacity = topology.pslcWritableCapacityBytes, pslcCapacity > 0,
              let last = series.last else { return nil }
        let start = last.capturedAt.addingTimeInterval(-Double(windowDays) * 86_400)
        let window = series.filter { $0.capturedAt >= start }
        var nandBytes = 0.0
        var pslcPE = 0.0
        for (a, b) in zip(window, window.dropFirst()) {
            guard b.capturedAt > a.capturedAt,
                  a.nandWritesUnitState.supportsIntervalComparison,
                  b.nandWritesUnitState.supportsIntervalComparison,
                  let n0 = a.nandWrittenBytes, let n1 = b.nandWrittenBytes, n1 >= n0,
                  let s0 = a.slcAveragePE, let s1 = b.slcAveragePE, s1 >= s0,
                  !excluding.contains(where: { $0.intersects(DateInterval(start: a.capturedAt, end: b.capturedAt)) })
            else { continue }
            nandBytes += n1 - n0
            pslcPE += s1 - s0
        }
        let pslcBytes = pslcPE * pslcCapacity
        guard pslcPE >= minimumRecentPSLCPEDelta, nandBytes > pslcBytes else { return nil }
        let share = (nandBytes - pslcBytes) / nandBytes
        return share.isFinite && share > 0 && share < 1 ? share : nil
    }
}

/// One domain's share of the central forecast: its own wear and NAND writes
/// (used and remaining), and the host writes that would use them up. Both
/// domains are shown so a near tie between TLC and pSLC stays visible.
struct DomainForecastRow: Equatable, Sendable {
    let domain: NANDDomain
    /// Current P/E over the P/E target (0...).
    let wearFraction: Double
    let usedNANDBytes: Double
    let remainingNANDBytes: Double
    /// NAND bytes written to this domain per host byte.
    let nandBytesPerHostByte: Double
    let remainingHostBytes: Double

    /// TLC first, then pSLC; nil unless both domains can be evaluated.
    static func rows(
        estimates: [NANDDomainEstimate],
        waf: Double,
        share: DomainWriteShare
    ) -> [DomainForecastRow]? {
        guard waf.isFinite, waf > 0 else { return nil }
        let perHost: [NANDDomain: Double] = [.tlc: waf * share.tlcShare, .pslc: waf * (1 - share.tlcShare)]
        let rows = [NANDDomain.tlc, .pslc].compactMap { domain -> DomainForecastRow? in
            guard let estimate = estimates.first(where: { $0.domain == domain }),
                  let rate = perHost[domain], rate > 0,
                  estimate.targetPE > 0 else { return nil }
            let remainingHost = estimate.remainingBytes / rate
            guard remainingHost.isFinite, remainingHost >= 0 else { return nil }
            return DomainForecastRow(domain: domain, wearFraction: max(0, estimate.currentPE / estimate.targetPE),
                                     usedNANDBytes: estimate.usedBytes,
                                     remainingNANDBytes: estimate.remainingBytes,
                                     nandBytesPerHostByte: rate, remainingHostBytes: remainingHost)
        }
        return rows.count == 2 ? rows : nil
    }
}

/// Remaining host writes until the first domain reaches its P/E target.
struct DomainBottleneckRemaining: Equatable, Sendable {
    let remainingHostBytes: Double
    let limitingDomain: NANDDomain
    /// NAND bytes written to the limiting domain per host byte.
    let limitingDomainBytesPerHostByte: Double

    static func evaluate(
        estimates: [NANDDomainEstimate],
        waf: Double,
        share: DomainWriteShare
    ) -> DomainBottleneckRemaining? {
        guard let rows = DomainForecastRow.rows(estimates: estimates, waf: waf, share: share),
              let first = rows.min(by: { $0.remainingHostBytes < $1.remainingHostBytes }) else { return nil }
        return DomainBottleneckRemaining(remainingHostBytes: first.remainingHostBytes, limitingDomain: first.domain,
                                         limitingDomainBytesPerHostByte: first.nandBytesPerHostByte)
    }
}

/// Cumulative NAND writes per domain, estimated as average P/E × capacity,
/// with the ratio to host writes. Shown beside the Host and NAND totals.
struct DomainWriteBreakdown: Equatable, Sendable {
    let domain: NANDDomain
    let bytes: Double
    let perHostByte: Double?

    static func make(estimates: [NANDDomainEstimate], hostBytes: Double?) -> [DomainWriteBreakdown] {
        [NANDDomain.tlc, .pslc].compactMap { domain in
            guard let estimate = estimates.first(where: { $0.domain == domain }),
                  estimate.usedBytes.isFinite, estimate.usedBytes >= 0 else { return nil }
            let ratio = hostBytes.flatMap { $0 > 0 ? estimate.usedBytes / $0 : nil }
            return DomainWriteBreakdown(domain: domain, bytes: estimate.usedBytes, perHostByte: ratio)
        }
    }
}
