import Foundation

/// Research-only integer band allocation inferred from the current NAND
/// counter and the observed P/E values. This is deliberately not a verified
/// physical partition. v2.4 retains it exclusively for reconciliation; the
/// central domain budget uses `DirectFTLTopology` partition boundaries.
struct NANDBandAllocationProxy: Equatable, Sendable {
    let totalBands: Int
    let tlcBands: Int
    /// The unrounded pSLC-band estimate before integer allocation.
    let rawPSLCBands: Double
    let pslcBands: Int
    let sectorSizeBytes: UInt64
    let tlcBandBytes: Double
    let pslcBandBytes: Double
    let tlcCapacityBytes: Double
    let pslcCapacityBytes: Double
    /// pSLC bands occupy TLC-mode physical space, while pslcCapacityBytes is
    /// the writable pSLC capacity used by the endurance calculation.
    let pslcPhysicalFootprintBytes: Double
    let modeledNANDBytes: Double
    let measuredNANDBytes: Double
    let relativeError: Double
    let capacityAllocationVerified: Bool
    let notes: [String]
}

enum NANDDomain: String, Equatable, Sendable {
    case tlc
    case pslc

    var title: String {
        switch self {
        case .tlc: return "TLC"
        case .pslc: return "pSLC"
        }
    }
}

struct NANDDomainEstimate: Equatable, Sendable {
    let domain: NANDDomain
    let capacityBytes: Double
    let physicalFootprintBytes: Double?
    let currentPE: Double
    let eolPE: Double
    let targetPE: Double
    let baselineBudgetBytes: Double
    let totalBudgetBytes: Double
    let usedBytes: Double
    let remainingBytes: Double
}

struct NANDBottleneckEstimate: Equatable, Sendable {
    let intervalCount: Int
    let tlcShare: Double
    let pslcShare: Double
    let tlcEquivalentRemainingBytes: Double?
    let pslcEquivalentRemainingBytes: Double?
    let limitingDomain: NANDDomain?
    let distributionError: Double
    let note: String
}

/// A firmware change can be a recording boundary without being a wear-series
/// reset.  This is deliberately an explicit, conservative bridge: it never
/// changes the ControllerWearSeriesIdentity used for P/E forecasts.
enum FirmwareWearBoundaryStatus: String, Codable, Equatable, Sendable {
    case pending
    case verified
    case failed
}

struct FirmwareWearBoundaryBridge: Equatable, Sendable {
    let before: Date
    let after: Date
    let wafLearningExclusion: DateInterval
    let note: String
    let status: FirmwareWearBoundaryStatus
    let checks: [ContinuityCheckResult]

    init(
        before: Date,
        after: Date,
        wafLearningExclusion: DateInterval,
        note: String,
        status: FirmwareWearBoundaryStatus = .verified,
        checks: [ContinuityCheckResult] = []
    ) {
        self.before = before
        self.after = after
        self.wafLearningExclusion = wafLearningExclusion
        self.note = note
        self.status = status
        self.checks = checks
    }
}

/// NAND-domain budget. Historical Host writes are never re-priced at future WAF.
struct NANDEnduranceV2: Equatable, Sendable {
    /// The central Dashboard Client scenario.  Retention Research keeps its
    /// own configurable WAF, but the normal forecast and its summary card
    /// deliberately use this fixed comparison workload.
    static let clientWorkloadWAF = 3.5
    static let clientWorkloadWAFLower = 3.0
    static let clientWorkloadWAFUpper = 4.0

    struct Projection: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case real, client, peerReference
        }

        let title: String
        let total: Double?
        let remaining: Double?
        let note: String
        var kind: Kind = .real
    }

    /// Looks a row up by what it is, not by its display title.
    func projection(_ kind: Projection.Kind) -> Projection? {
        projections.first { $0.kind == kind }
    }

    /// Cumulative Host writes over the projected total Host writes.
    var realHostWearFraction: Double? {
        guard let host, let total = projection(.real)?.total, total > 0 else { return nil }
        let fraction = host / total
        return fraction.isFinite ? min(1, max(0, fraction)) : nil
    }
    static let empty = NANDEnduranceV2()
    var projections: [Projection] = []
    /// Cumulative Host amount used for total-Host projections. Prefer a SMART
    /// Data Units Written value matched to the accepted FTL snapshot.
    var host: Double?
    /// FTL Host counter retained separately for same-instrument WAF ratios.
    var ftlHost: Double?
    var cumulativeHostSource: CumulativeHostSource = .unavailable
    var nand: Double?
    var tlcWear: Double?
    var pslcWear: Double?
    var tlcPE: Double?
    var tlcEOL: Double?
    var pslcPE: Double?
    var pslcEOL: Double?
    var normalizedWear: Double?
    var wearDivergence: Double?
    /// pSLC wear divided by TLC wear. This is a current wear-balance
    /// observation; it is not treated as a capacity allocation.
    var wearBalance: Double?
    /// Daily observations reconstructed from retained, contract-validated FTL
    /// snapshots. This is descriptive history and does not alter TBW.
    var wearBalanceTrend: WearBalanceTrend = .empty
    var wearCombination: String = ""
    /// Total-NAND budget at the Controller EOL P/E anchor. Both the measured
    /// NAND counter and the normalized wear rate describe the same aggregate
    /// domain, so capacity terms cancel here.
    var nominalBudget: Double?
    /// Total-NAND budget after the retained research/program corrections for
    /// the current-condition projection.
    var actualBudget: Double?
    /// The old capacity-derived TLC budget is retained for reconciliation and
    /// fallback diagnostics. The domain budget is preferred when available.
    var capacityDiagnosticBudget: Double?
    /// The capacity-derived current TLC consumption used by the reconciliation
    /// gate. The primary path uses `nand` instead.
    var effectiveNANDCapacityBytes: Double?
    var capacitySource: RetentionPhysicalCapacitySource?
    var currentPhysicalBytes: Double?
    var capacityModelDivergence: Double?
    var capacityModelConsistent: Bool?
    /// The allocation is intentionally false: integer band fitting is a
    /// research proxy, not an independently verified physical map.
    var capacityAllocationVerified: Bool = false
    /// Direct FTL partition topology, retained separately from the inferred
    /// 80-band proxy. A validated key contract is not physical-capacity proof.
    var directContractStatus: DirectFTLContractStatus = .noSnapshot
    var directTopology: DirectFTLTopology?
    var topologyMatchesIORegistryGeometry: Bool?
    var bandAllocationProxy: NANDBandAllocationProxy?
    /// Direct-topology-derived domain budgets. These are still a provisional
    /// research model and never claim independently verified NAND allocation.
    var domainEstimates: [NANDDomainEstimate] = []
    /// Per-domain budget without retention derating (Kret = 1). The central
    /// forecast uses these; retention is a separate hypothetical scenario.
    var domainBaselineEstimates: [NANDDomainEstimate] = []
    /// Window (days) behind the recent forecast WAF, reused for the TLC split.
    var forecastWAFWindowDays: Int?
    var domainWriteShare: DomainWriteShare?
    /// Central forecast limit: the domain that runs out first.
    var domainBottleneckRemaining: DomainBottleneckRemaining?
    /// TLC and pSLC rows behind the central forecast, shown side by side.
    var domainForecastRows: [DomainForecastRow] = []
    /// Hypothetical power-off retention scenario (TLC only).
    var retentionScenario: RetentionScenario?
    var idleRetentionTemperature: IdleRetentionTemperature?
    var observationEvidence = ForecastObservationEvidence()
    var domainModelAvailable = false
    var domainBaselineBudget: Double?
    var domainActualBudget: Double?
    var domainUsedBytes: Double?
    var domainRemainingBytes: Double?
    var baselineDomainRemainingBytes: Double?
    var retentionAdjustedDomainRemainingBytes: Double?
    var retentionDeltaRemainingBytes: Double?
    var domainClientRemainingBytes: Double?
    var domainReconstructionError: Double?
    var domainBudgetReconciliationError: Double?
    var reconstructionDiagnostics: NANDReconstructionDiagnostics?
    var wafComponents: FTLWAFComponentDecomposition?
    var reliabilityEvidence: FTLReliabilityEvidence?
    /// Independent 30°C／365日 reference retained for Advanced comparison.
    /// It is intentionally not the normal Client row's remaining NAND.
    var fixedReferenceRemainingBytes: Double?
    var domainModelNote: String = ""
    var domainBottleneckNote: String = ""
    var domainBottleneck: NANDBottleneckEstimate?
    var longWAF: Double?
    var recentWAF: Double?
    var forecastWAF: Double?
    /// Windowed WAF values from the same firmware-bridge-aware assessment used
    /// by the forecast. Keeping these in the analytics result prevents the
    /// dashboard card from re-scanning raw intervals with a different cutoff
    /// or without the post-update learning exclusion.
    var wafWindows: [RetentionWAFWindow] = []
    var recentWeight: Double = 0
    var wafObservedHostBytes: Double?
    var wafPriorEquivalentHostBytes: Double?
    var wafObservationDays: Double?
    /// Firmware boundaries retained for chart/Advanced provenance.  The
    /// post-update interval is excluded from WAF learning, but its counters
    /// remain part of the current wear state.
    var firmwareBoundaryBridges: [FirmwareWearBoundaryBridge] = []
    var instrumentBoundaries: [InstrumentBoundaryRecord] = []
    /// Probe/parser version changes absorbed as provenance-only updates.
    var instrumentMetadataChanges: [InstrumentMetadataChangeRecord] = []
    var retentionFactor: Double = 1
    /// Required future OFF-retention condition used by the TLC derating.
    /// This is deliberately separate from observed unpowered exposure.
    var requiredRetentionDays: Double?
    var requiredRetentionDaysSource: String = ""
    var observedLongestUnpoweredDays: Double?
    var observedLongestUnpoweredStart: Date?
    var observedLongestUnpoweredEnd: Date?
    var retentionDaysWeight: Double = RetentionResearchWeightDefaults.daysDefault
    var retentionEnvironmentWeight: Double = RetentionResearchWeightDefaults.environmentDefault
    var retentionCorrectionSuppressed = false
    var retentionExtrapolationRatio: Double?
    var programFactor: Double = 1
    var clientLow: Double?
    var clientHigh: Double?
    var currentPaceBytesPerDay: Double?
    var longTermPaceBytesPerDay: Double?
    var longTermPaceBasis: String = ""
    var date: Date = .distantPast
    /// The newest raw FTL observation is retained for provenance and gauges,
    /// while the forecast inputs below may intentionally stop at the last
    /// accepted continuity-lane sample.
    var latestRawInputDate: Date?
    var latestRawHost: Double?
    var latestRawNAND: Double?
    var latestRawTLCPE: Double?
    var latestRawPSLCPE: Double?
    var inputDate: Date?
    /// Host bytes SMART recorded after `inputDate`. The projections stay at
    /// the input, so the totals still add up, but arrival dates count from
    /// now and account for these writes in each workload's units. Nil when there is no central
    /// FTL projection or no SMART sample to measure it with.
    var hostWrittenSinceInput: Double?
    var currentValueSource: String = ""
    var thermal: ThermalRetentionAssessment?
    var notes: [String] = []

    /// With collection at most a day apart, no Direct FTL read for longer
    /// than this means collection has stopped.
    static let staleInputAge: TimeInterval = 2 * 86_400

    /// Date-only extrapolation between FTL reads. Actual writes consume NAND
    /// at the forecast WAF; Client remaining Host bytes use the Client WAF.
    /// This assumes the forecast domain split continues until the next read.
    func remainingNow(_ remaining: Double?, workload: Projection.Kind) -> Double? {
        guard let remaining = Self.nonnegative(remaining) else { return nil }
        guard let since = Self.nonnegative(hostWrittenSinceInput) else { return remaining }
        let consumed: Double
        switch workload {
        case .real, .peerReference:
            consumed = since
        case .client:
            guard let waf = Self.positive(forecastWAF) else { return remaining }
            consumed = since * waf / Self.clientWorkloadWAF
        }
        guard consumed.isFinite else { return remaining }
        return max(0, remaining - consumed)
    }

    /// True when no Direct FTL read has been saved for `staleInputAge`. It
    /// uses the newest raw read, so a forecast held at a pending boundary
    /// while reads continue is not reported as stale.
    func isInputStale(now: Date) -> Bool {
        guard let date = latestRawInputDate ?? inputDate else { return false }
        return now.timeIntervalSince(date) > Self.staleInputAge
    }

    /// SMART host writes between `inputDate` and the newest SMART sample of
    /// the same device. SMART at the input is interpolated, within one day.
    static func hostWritten(since inputDate: Date, deviceID: String, smart: [DriveSnapshot]) -> Double? {
        let samples = smart
            .filter { $0.deviceID == deviceID }
            .compactMap { sample in sample.dataUnitsWrittenBytes.map { (sample.capturedAt, $0) } }
            .sorted { $0.0 < $1.0 }
        guard let latest = samples.last, latest.0 > inputDate,
              let atInput = WearContinuityLaneBuilder.interpolated(at: inputDate, samples: samples) else { return nil }
        let written = latest.1 - atInput
        return written.isFinite && written >= 0 ? written : nil
    }

    static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func projection(title: String, budget: Double?, host: Double?, nand: Double?,
                           waf: Double?, currentPhysicalBytes: Double? = nil,
                           note: String) -> Projection {
        EnduranceProjectionBuilder.projection(
            title: title,
            budget: budget,
            host: host,
            nand: nand,
            waf: waf,
            currentPhysicalBytes: currentPhysicalBytes,
            note: note
        )
    }

    static func build(smart: DriveSnapshot?, snapshots: [ASPToolDiagnosticsSnapshot],
                      history: [DriveSnapshot], temperatures: [TemperatureSample],
                      settings: UsageSettings, rates: WriteRateSummary, historicalRate: Double?,
                      excluding: [DateInterval], now: Date,
                      hardwareProfile: AppleNANDHardwareProfile? = nil,
                      continuityLane suppliedLane: WearContinuityLane? = nil,
                      idleTemperatureCandidates: [IdleTemperatureCandidate] = [],
                      wearEvidence suppliedWearEvidence: ControllerWearHistorySummary? = nil) -> Self {
        var result = Self()
        // Set when the latest series is held (counter reset or a SMART/FTL
        // firmware mismatch). Every host projection is then withheld, not
        // just the central one.
        var forecastHeld = false
        result.date = now
        result.currentPaceBytesPerDay = rates.currentWorkloadBytesPerDay
        result.longTermPaceBytesPerDay = historicalRate ?? rates.forecastPaceBytesPerDay
        result.longTermPaceBasis = rates.usesUsageStartPace ? "使用開始から" : "保存履歴平均"
        result.notes.append("到達日は同じ残Host予算を現在ペースと保存履歴ペースで独立換算し、旧50/35/15混合ペースは使用しません。")
        let rawDirect = snapshots.filter {
            $0.sourceArtifact == .directFTL && $0.capturedAt <= now &&
                (smart?.deviceID == nil || $0.deviceID == smart?.deviceID)
        }.sorted { $0.capturedAt < $1.capturedAt }
        let latestDirect = rawDirect.last
        let rawOrdered = snapshots.filter {
            $0.sourceArtifact.participatesInCoreWearLane && $0.captureQuality != .unknown &&
                $0.capturedAt <= (latestDirect?.capturedAt ?? now) &&
                (smart?.deviceID == nil || $0.deviceID == smart?.deviceID)
        }.sorted { $0.capturedAt < $1.capturedAt }
        // Persisted ISO8601 timestamps have second precision. Multiple successful
        // captures within one second are not evidence of a counter reset.
        var ordered: [ASPToolDiagnosticsSnapshot] = []
        for sample in rawOrdered {
            if let prior = ordered.last, prior.capturedAt == sample.capturedAt,
               prior.sourceArtifact == sample.sourceArtifact,
               ControllerWearSeriesIdentity(snapshot: prior) == ControllerWearSeriesIdentity(snapshot: sample),
               prior.tlcAveragePE == sample.tlcAveragePE, prior.slcAveragePE == sample.slcAveragePE,
               let h0 = prior.hostWrittenBytes, let n0 = prior.nandWrittenBytes,
               let h1 = sample.hostWrittenBytes, let n1 = sample.nandWrittenBytes {
                if h1 >= h0 && n1 >= n0 { ordered[ordered.count - 1] = sample; continue }
                if h0 >= h1 && n0 >= n1 { continue }
            }
            ordered.append(sample)
        }
        if ordered.count < rawOrdered.count {
            result.notes.append("秒単位の同時刻記録は、両カウンタが大きい方を解析用に採用。元履歴は保持しています。")
        }
        var latestFTL: ASPToolDiagnosticsSnapshot?
        var latestSeries: [ASPToolDiagnosticsSnapshot] = []
        var semanticFTLHistory: [ASPToolDiagnosticsSnapshot] = []
        var continuityLane: WearContinuityLane?
        if let latest = latestDirect {
            result.directContractStatus = DirectFTLResearchContract.status(for: latest)
            result.latestRawInputDate = latest.capturedAt
            result.latestRawHost = nonnegative(latest.hostWrittenBytes)
            result.latestRawNAND = nonnegative(latest.nandWrittenBytes)
            result.latestRawTLCPE = latest.tlcAveragePE
            result.latestRawPSLCPE = latest.slcAveragePE
        }
        if let latest = latestDirect, result.directContractStatus.isValidated {
            // Always use one continuity lane.  An empty SMART history leaves
            // a build/firmware boundary pending, rather than falling back to
            // the former unverified firmware bridge.
            continuityLane = suppliedLane ?? WearContinuityLaneBuilder.build(
                snapshots: ordered,
                smart: history,
                latest: latest
            )
            // The last accepted lane sample is the sole source for forecast
            // state.  If a boundary is pending or failed, the builder leaves
            // the post-boundary raw segment out of this lane, so the primary
            // budget, remaining amount, arrival date, and wear gauges all
            // remain on the last verified value instead of silently mixing
            // an unverified current snapshot with verified rates.
            guard let current = continuityLane?.snapshots.last else {
                result.currentValueSource = "連続性laneに採用されたsnapshotなし"
                result.notes.append("最新rawは取得値として保持していますが、連続性laneに採用されたFTL snapshotがないため、予測・残量・到達日は未算出です。")
                return result
            }
            let blockingBoundary = continuityLane?.boundaries.last(where: {
                !$0.continuity.isVerified && $0.boundary.after > current.capturedAt
            })
            latestFTL = current
            result.inputDate = current.capturedAt
            result.ftlHost = nonnegative(current.hostWrittenBytes)
            result.nand = nonnegative(current.nandWrittenBytes)
            var hostHistory = history
            if let smart, !hostHistory.contains(where: { $0.id == smart.id }) {
                hostHistory.append(smart)
            }
            let hostResolution = CumulativeHostResolver.resolve(
                acceptedFTL: current,
                smartHistory: hostHistory,
                latestPermittedSMARTAt: blockingBoundary == nil ? nil : current.capturedAt
            )
            result.host = hostResolution.hostBytes ?? result.ftlHost
            result.cumulativeHostSource = hostResolution.source
            if blockingBoundary != nil {
                result.notes.append("境界未解決のため、累積HostのSMART照合も検証済みFTL時刻以前に制限しています。")
            }
            if let note = hostResolution.note {
                result.notes.append(note)
            }
            let isRawLatest = current.capturedAt == latest.capturedAt
                && current.hostWrittenBytes == latest.hostWrittenBytes
                && current.nandWrittenBytes == latest.nandWrittenBytes
            if let blockingBoundary {
                result.currentValueSource = "\(blockingBoundary.continuity.title)・境界前の検証済みsnapshot"
                result.notes.append("主予測の現在値は境界前 \(ValueFormatter.shortDateTime(current.capturedAt)) の検証済みlane末尾を使用。最新raw \(ValueFormatter.shortDateTime(latest.capturedAt)) は取得値として保持し、境界検証完了まで予測へ投入しません。")
            } else if isRawLatest {
                if result.directContractStatus.runsOnReviewedBuild {
                    result.currentValueSource = "最新snapshot（連続性lane受理済み）"
                } else {
                    result.currentValueSource = "最新snapshot（build未検証・lane受理）"
                    result.notes.append("実行buildは対応表のbuildと異なり未確認です。FWに基づく旧build未記録系列との同一計測器扱いで連続性laneに受理されています。OS build固有のkey意味は未検証として表示します。")
                }
            } else {
                result.currentValueSource = "連続性lane末尾（検証済み）"
                result.notes.append("主予測の現在値は連続性lane末尾 \(ValueFormatter.shortDateTime(current.capturedAt)) を使用しています。")
            }
            let identity = ControllerWearSeriesIdentity(snapshot: current)
            let series = continuityLane?.snapshots ?? [current]
            latestSeries = series
            semanticFTLHistory = series
            let bridges = continuityLane?.boundaries.map(Self.makeBoundaryBridge) ?? []
            result.instrumentBoundaries = continuityLane?.boundaries ?? []
            result.instrumentMetadataChanges = continuityLane?.instrumentMetadataChanges ?? []
            result.firmwareBoundaryBridges = bridges
            if let collapsed = continuityLane?.collapsedSameSecondSnapshots, collapsed > 0 {
                result.notes.append("同秒に保存されたFTL重複snapshot (collapsed)件は解析レーン上で統合。元履歴は変更していません。")
            }
            // The bridge model uses a zero-duration DateInterval as a UI
            // placeholder for route changes with no learning exclusion.
            // `DateInterval.intersects` still treats its endpoint as overlap,
            // which can discard an entire long asptool→Direct baseline
            // interval. The lane's exclusion list contains only real,
            // positive-duration physical-transient windows.
            let wafExclusions = excluding + (continuityLane?.rateLearningExclusions ?? [])
            if !bridges.isEmpty {
                for bridge in bridges {
                    switch bridge.status {
                    case .verified:
                        if bridge.wafLearningExclusion.duration > 0 {
                            let hours = Int(bridge.wafLearningExclusion.duration / 3_600)
                            result.notes.append("計測器境界 \(ValueFormatter.shortDateTime(bridge.after)) はD1〜D7検証済み。直後\(hours)時間をWAF学習から除外し、損耗累積には含めます。")
                        } else {
                            result.notes.append("取得経路境界 \(ValueFormatter.shortDateTime(bridge.after)) はD1〜D7検証済み。物理更新を伴わないため、WAF学習除外はありません。")
                        }
                    case .pending:
                        result.notes.append("計測器境界 \(ValueFormatter.shortDateTime(bridge.after)) はSMART資料待ち。rawを保持し、WAF学習へは投入していません。")
                    case .failed:
                        result.notes.append("計測器境界 \(ValueFormatter.shortDateTime(bridge.after)) はD1〜D7不一致。境界後をWAF学習へは投入していません。")
                    }
                }
            }
            result.wearBalanceTrend = Self.makeWearBalanceTrend(series: series, excluding: wafExclusions)
            let reset = zip(series, series.dropFirst()).contains { a, b in
                (b.hostWrittenBytes ?? .infinity) < (a.hostWrittenBytes ?? 0)
                    || (b.nandWrittenBytes ?? .infinity) < (a.nandWrittenBytes ?? 0)
                    || (b.tlcAveragePE ?? .infinity) < (a.tlcAveragePE ?? 0)
                    || (b.slcAveragePE ?? .infinity) < (a.slcAveragePE ?? 0)
                    || b.capturedAt <= a.capturedAt
            }
            if current.hostWritesUnitState != .verified || current.nandWritesUnitState != .verified {
                result.notes.append("FTLカウンタのbyte換算は暫定。予算も同じ単位仮定に依存します。")
            }
            if identity.firmwareEpoch == nil || identity.sourceBuild == nil {
                result.notes.append("firmware／OS系列情報の一部が未取得です。")
            }
            if let h = result.ftlHost, let n = result.nand { result.longWAF = positive(n / h) }
            let wafPrior = settings.retentionDailyWAFPrior ?? 2.2
            let retentionWAFPriorHostBytes = settings.retentionDailyWAFPriorHostBytes ?? 1e12
            let wafLatest = series.last ?? current
            let waf = RetentionWAFAnalyzer().assess(snapshots: series, latest: wafLatest, now: now,
                excluding: wafExclusions, client: Self.clientWorkloadWAF, prior: wafPrior, selection: nil, trials: [],
                priorEquivalentHostBytes: retentionWAFPriorHostBytes,
                continuityLane: continuityLane,
                filesystemHistory: history)
            result.wafWindows = waf.windows
            let window = waf.windows.first { $0.days == 30 && $0.value != nil }
                ?? waf.windows.first { $0.days == 90 && $0.value != nil }
                ?? waf.windows.first { $0.days == 7 && $0.value != nil }
            result.recentWAF = window?.value ?? waf.lifetime
            result.forecastWAFWindowDays = window?.days
            result.wafObservedHostBytes = waf.observedHostBytes > 0 ? waf.observedHostBytes : nil
            let forecastWAF = ForecastWAFEstimator.estimate(
                longTermWAF: result.longWAF,
                recentWAF: result.recentWAF,
                observedHostBytes: waf.observedHostBytes,
                priorEquivalentHostBytes: settings.forecastWAFPriorEquivalentHostBytes
            )
            result.recentWeight = forecastWAF.recentWeight
            result.wafPriorEquivalentHostBytes = forecastWAF.priorEquivalentHostBytes
            result.forecastWAF = forecastWAF.forecastWAF
            result.wafObservationDays = window?.observationDays
            // Stability is measured on UTC day bins, never on polling-count variance.
            let stability = dailyStability(series: series, excluding: wafExclusions, now: now,
                                           days: window?.days ?? 30)
            if let window {
                // q is determined only by the observed Host amount and the
                // configured prior-equivalent Host amount. WAF ratios are
                // unitless; unit/series/stability remain evidence, not q
                // penalties.
                result.notes.append("最近WAF：\(window.days)日窓の実観測\(String(format: "%.2f", window.observationDays))日、Host \(ValueFormatter.bytes(window.hostBytes))、\(window.count)区間。Forecast q=\(String(format: "%.3f", result.recentWeight))。Retention Research priorとは独立し、安定度は\(stability.days)日バケットで別表示。")
                if stability.factor < 1 || waf.unitScore < 1 || waf.seriesScore < 1 {
                    result.notes.append("WAFの安定度・単位・系列情報はqを減らさず、観測根拠として別に保持しています。")
                }
            }
            func wear(_ pe: Double?, _ eol: Double?) -> Double? {
                guard let pe = positive(pe), let eol = positive(eol) else { return nil }
                return positive(pe / eol)
            }
            result.tlcWear = wear(current.tlcAveragePE, current.tlcEOLPE)
            result.pslcWear = wear(current.slcAveragePE, current.slcEOLPE)
            result.tlcPE = current.tlcAveragePE
            result.tlcEOL = current.tlcEOLPE
            result.pslcPE = current.slcAveragePE
            result.pslcEOL = current.slcEOLPE
            result.notes.append("P/E入力：TLC \(current.tlcAveragePE.map { String($0) } ?? "未取得") / EOL \(current.tlcEOLPE.map { String($0) } ?? "未取得")、pSLC \(current.slcAveragePE.map { String($0) } ?? "未取得") / EOL \(current.slcEOLPE.map { String($0) } ?? "未取得")。")
            if let tlcWear = result.tlcWear, let pslcWear = result.pslcWear {
                let smaller = min(tlcWear, pslcWear)
                let divergence = smaller > 0 ? abs(tlcWear - pslcWear) / smaller : nil
                result.wearDivergence = divergence
                result.wearBalance = tlcWear > 0 ? pslcWear / tlcWear : nil
                if let divergence, divergence > 0.05 {
                    // N/u is valid only while both wear domains track closely.
                    // The fitted allocation is not independently verified, so a
                    // divergent pair uses the conservative domain.
                    result.normalizedWear = max(tlcWear, pslcWear)
                    result.wearCombination = "保守側max（乖離あり）"
                    result.notes.append("TLC／pSLCの損耗率が\(String(format: "%.1f", divergence * 100))%乖離。容量配分が未検証のため、保守側maxで総NAND予算を暫定計算しています。")
                } else {
                    result.normalizedWear = (tlcWear + pslcWear) / 2
                    result.wearCombination = "等重み平均"
                }
            } else if let wear = [result.tlcWear, result.pslcWear].compactMap({ $0 }).first {
                result.normalizedWear = wear
                result.wearCombination = "片側のみ"
                result.notes.append("片側P/Eのみの部分推計です。欠測側を評価済みとはしません。")
            }
            if reset {
                result.notes.append("最新系列内でカウンタ／P/Eのresetまたは重複時刻を検出。WAF予測と総NAND予算は保留します。")
                result.normalizedWear = nil
                result.forecastWAF = nil
                forecastHeld = true
            }
            let selectedSmart = hostResolution.matchedSMART ?? history
                .filter { current.deviceID == nil || $0.deviceID == current.deviceID }
                .min { abs($0.capturedAt.timeIntervalSince(current.capturedAt)) < abs($1.capturedAt.timeIntervalSince(current.capturedAt)) }
            if let capacity = physicalCapacity(smart: selectedSmart ?? smart, hardwareProfile: hardwareProfile),
               let tlcEOL = positive(current.tlcEOLPE),
               let currentTLCPE = positive(current.tlcAveragePE) {
                result.effectiveNANDCapacityBytes = capacity.bytes
                result.capacitySource = capacity.source
                result.capacityDiagnosticBudget = positive(capacity.bytes * tlcEOL)
                result.currentPhysicalBytes = nonnegative(capacity.bytes * currentTLCPE)
                if let nand = result.nand {
                    let consistent = Self.capacityModelIsConsistent(
                        physicalConsumed: result.currentPhysicalBytes, nand: nand
                    )
                    result.capacityModelConsistent = consistent
                    if let physical = result.currentPhysicalBytes, nand > 0 {
                        result.capacityModelDivergence = abs(physical - nand) / nand
                    }
                    if consistent {
                        result.notes.append("容量基準のTLC消費と累積NAND Writesは10%以内で整合します。容量基準は検算用として保持します。")
                    } else {
                        let difference = result.capacityModelDivergence.map { String(format: "%.1f%%", $0 * 100) } ?? "不明"
                        result.notes.append("容量基準の物理消費（\(ValueFormatter.bytes(result.currentPhysicalBytes)))が累積NAND書込（\(ValueFormatter.bytes(result.nand)))と\(difference)差分です。容量モデルが全wear domainを網羅していないため、主予算には使用しません。")
                    }
                }
                result.notes.append("容量基準予算は\(capacity.source.title)の実効容量 × TLC Controller EOL P/Eによる旧経路の比較値です。geometry domainが作れない場合のみ累積NAND / 正規化損耗率へfallbackします。")
                result.notes.append(contentsOf: capacity.notes)
            } else {
                result.notes.append("物理容量またはTLC P/Eが不足しているため、容量基準の検算値は未算出です。主予算は総NAND / 正規化損耗率で独立に計算します。")
            }
            if let nand = result.nand, let wear = result.normalizedWear {
                result.nominalBudget = positive(nand / wear)
                result.actualBudget = result.nominalBudget
                result.notes.append("従来N/u物理NAND予算：累積NAND Writes ÷ 正規化損耗率。geometry domainの主計算と比較するため保持します。")
            } else {
                result.notes.append("累積NANDまたは正規化損耗率が不足しているため、従来N/u比較値は未算出です。")
            }
            if current.captureQuality == .fileMetadata {
                result.notes.append("FTL内部記録時刻は未確認。単一snapshotとしての暫定推計です。")
            }
            // A lane rollback intentionally pairs an older, verified FTL
            // sample with the latest SMART record from the newer segment.
            // Do not call that expected boundary separation a firmware
            // mismatch; only compare the two sources when the selected FTL
            // value is itself the raw latest sample.
            if isRawLatest, let currentFirmware = smart?.firmware, let ftlFirmware = current.firmware,
               !currentFirmware.isEmpty, !ftlFirmware.isEmpty, currentFirmware != ftlFirmware {
                result.nominalBudget = nil
                result.actualBudget = nil
                result.capacityDiagnosticBudget = nil
                result.currentPhysicalBytes = nil
                result.capacityModelDivergence = nil
                result.capacityModelConsistent = nil
                result.bandAllocationProxy = nil
                result.directTopology = nil
                result.topologyMatchesIORegistryGeometry = nil
                result.effectiveNANDCapacityBytes = nil
                result.capacitySource = nil
                result.forecastWAF = nil
                forecastHeld = true
                result.notes.append("SMARTとDirect FTLのfirmwareが不一致。異なる系列の現在値を混在させず保留します。")
            }
            if let smartH = selectedSmart?.dataUnitsWrittenBytes, smartH > 0, let h = result.ftlHost,
               abs(h - smartH) / smartH > 0.1 {
                result.notes.append("SMARTとFTL Host累積値が10%以上相違。WAFは同一FTL counter pairを維持し、累積HostもFTL fallbackのままです。")
            }
            if let selectedSmart, abs(selectedSmart.capturedAt.timeIntervalSince(current.capturedAt)) > 86_400 {
                result.notes.append("SMARTとFTLの取得時刻差が1日以上。SMART100%比較は非同時観測です。")
            }
        } else if let latest = latestDirect {
            // Keep the raw counters visible, but do not use private P/E,
            // topology, WAF or reliability fields from an unvalidated build.
            result.inputDate = latest.capturedAt
            result.host = nonnegative(latest.hostWrittenBytes)
            result.nand = nonnegative(latest.nandWrittenBytes)
            result.currentValueSource = "最新raw（Direct FTLの対応表が未確認・予測未使用）"
            result.notes.append(result.directContractStatus.detail)
        } else {
            result.host = nonnegative(smart?.dataUnitsWrittenBytes)
            result.notes.append("Direct FTLが未取得のためNAND予算を算出できません。")
        }
        // Use observed low-I/O temperature as a stated scenario condition.
        // It is not a powered-off temperature reading; without a usable
        // observation/manual setting it falls back to 30 °C. The same value
        // feeds the thermal model below, so the screen shows one storage
        // temperature.
        let idle = IdleRetentionTemperatureAnalyzer.assess(
            smart: history + (smart.map { [$0] } ?? []), temperatures: temperatures,
            deviceID: smart?.deviceID ?? latestSeries.last?.deviceID ?? "",
            manual: settings.effectiveRetentionStorageTemperatureCelsius, now: now,
            excluding: excluding + (continuityLane?.rateLearningExclusions ?? []),
            previous: idleTemperatureCandidates)
        if let deviceID = smart?.deviceID {
            result.idleRetentionTemperature = idle
            let thermal = ThermalRetentionAnalyzer().assess(smartHistory: history,
                temperatureHistory: temperatures, deviceID: deviceID,
                storageTemperature: settings.effectiveRetentionStorageTemperatureCelsius,
                activationEnergy: settings.retentionActivationEnergyEV ?? 1.1,
                programCorrection: settings.retentionProgramCorrectionEnabled ?? false,
                now: now, excluding: excluding, ftlHistory: semanticFTLHistory,
                continuityLane: continuityLane, observedStorage: idle)
            result.thermal = thermal
            result.programFactor = thermal.programFactor
            let evaluator = RetentionModelEvaluator()
            let baseline = evaluator.evaluate(profile: .luo2018, targetTemperatureCelsius: 30,
                targetRetentionDays: 365, rberThreshold: settings.retentionRBERThreshold ?? 3e-3,
                activationEnergyEV: settings.retentionActivationEnergyEV ?? 1.1)
            let daysObservation = RetentionModelEvaluator.observedRetentionDays(
                smartHistory: history, deviceID: deviceID, now: now, excluding: excluding
            )
            let retentionDays = settings.retentionDays ?? 365
            result.requiredRetentionDays = retentionDays
            result.requiredRetentionDaysSource = settings.retentionDays.map {
                "利用者設定・必要保持条件 \(String(format: "%.1f", $0))日"
            } ?? "既定値・必要保持条件 365日"
            result.observedLongestUnpoweredDays = daysObservation.longest?.durationDays
            result.observedLongestUnpoweredStart = daysObservation.longest?.start
            result.observedLongestUnpoweredEnd = daysObservation.longest?.end
            let retentionDaysSource = result.requiredRetentionDaysSource
            let daysAllowance = evaluator.evaluate(profile: .luo2018, targetTemperatureCelsius: 30,
                targetRetentionDays: retentionDays, rberThreshold: settings.retentionRBERThreshold ?? 3e-3,
                activationEnergyEV: settings.retentionActivationEnergyEV ?? 1.1)
            let current = evaluator.evaluate(profile: .luo2018,
                targetTemperatureCelsius: thermal.storageTemperature,
                targetRetentionDays: retentionDays,
                rberThreshold: settings.retentionRBERThreshold ?? 3e-3,
                activationEnergyEV: settings.retentionActivationEnergyEV ?? 1.1)
            let daysWeightResolution = RetentionResearchWeightDefaults.daysWeight(from: settings)
            let daysWeight = daysWeightResolution.value
            let environmentWeight = RetentionResearchWeightDefaults.environmentWeight(from: settings)
            result.retentionDaysWeight = daysWeight
            result.retentionEnvironmentWeight = environmentWeight
            if case let .available(base) = baseline, case let .available(day) = daysAllowance,
               case let .available(actual) = current,
               daysWeight.isFinite, (0...1).contains(daysWeight),
               environmentWeight.isFinite, (0...1).contains(environmentWeight),
               let daysRatio = positive(day.allowableTLCPE / base.allowableTLCPE),
               let environmentRatio = positive(actual.allowableTLCPE / day.allowableTLCPE) {
                let extrapolationRatio = max(base.peExtrapolationRatio,
                                              day.peExtrapolationRatio,
                                              actual.peExtrapolationRatio)
                result.retentionExtrapolationRatio = positive(extrapolationRatio)
                // Keep the baseline Kret=1 branch available beside the
                // research-adjusted branch. The policy may only reduce the
                // TLC target; it never increases Controller EOL.
                let derating = RetentionDeratingPolicy.evaluate(
                    daysRatio: daysRatio,
                    environmentRatio: environmentRatio,
                    daysWeight: daysWeight,
                    environmentWeight: environmentWeight
                )
                result.retentionFactor = derating.appliedFactor
                result.retentionCorrectionSuppressed = derating.suppressed
                if let rawRetentionFactor = derating.rawFactor, rawRetentionFactor > 1 {
                    result.notes.append("保持条件による増額方向の係数 \(String(format: "%.4f", rawRetentionFactor)) は1へ制限しました。")
                }
                if derating.suppressed {
                    result.notes.append("保持条件の比率が非有限または不正のため、TLC保持補正を評価せず基準係数1を使用します。")
                }
                if extrapolationRatio > 1 {
                    result.notes.append("参照研究の許容P/Eは測定範囲外へ外挿（最大×\(String(format: "%.2f", extrapolationRatio))）。減額方向の係数のみを暫定採用し、Apple個体の保持保証値とは扱いません。")
                }
                result.notes.append("保持条件：日数比 \(String(format: "%.4f", daysRatio)) ^ \(String(format: "%.2f", daysWeight)) × 温度等比 \(String(format: "%.4f", environmentRatio)) ^ \(String(format: "%.2f", environmentWeight))。\(retentionDaysSource)、現在条件 \(thermal.storageTemperature)°C。")
                if let observedDays = result.observedLongestUnpoweredDays {
                    result.notes.append("観測された最長無通電相当は\(String(format: "%.3f", observedDays))日で、必要保持条件の代用にはしていません。")
                }
                if daysWeightResolution.migratedLegacyDefault {
                    result.notes.append("旧設定の研究重み0.20は、新しい保持日数重み0.50へ互換移行しました。")
                }
                result.notes += actual.assumptions
                // The aggregate fallback cannot apply a TLC-only correction to
                // the whole NAND counter. Keep its baseline value and let the
                // geometry domain path apply retention to TLC only.
            } else {
                result.notes.append("保持設定／研究モデルが計算不能。係数1の基準推計を維持し、必要保持条件を観測OFF期間で補いません。")
            }
        }
        if let latestFTL {
            result.directTopology = latestFTL.directTopology
            result.wafComponents = Self.makeWAFComponents(latestFTL)
            result.reliabilityEvidence = FTLReliabilityEvidenceAnalyzer().assess(
                snapshots: ordered, latest: latestDirect ?? latestFTL, researchIntervals: excluding,
                continuityLane: continuityLane
            )
            result.bandAllocationProxy = Self.makeBandAllocationProxy(
                profile: hardwareProfile, latest: latestFTL, nand: result.nand
            )
            if let topology = result.directTopology {
                result.topologyMatchesIORegistryGeometry = hardwareProfile.flatMap { topology.geometryMatches($0) }
                if result.topologyMatchesIORegistryGeometry == false {
                    result.domainModelNote = "Direct topologyと同時期IORegistry geometryが不一致のため、domain別主予算を保留します。従来N/u概算を表示します。"
                    result.domainBottleneckNote = "geometry不一致のためbottleneck比較は保留しています。"
                } else {
                    result.applyDomainBudget(latest: latestFTL, topology: topology)
                    result.domainBottleneck = Self.makeDomainBottleneck(
                        series: latestSeries,
                        topology: topology,
                        estimates: result.domainEstimates,
                        excluding: excluding + (continuityLane?.rateLearningExclusions ?? []),
                        topologyFallback: continuityLane?.verifiedCoreTopology
                    )
                    if result.domainBottleneck == nil {
                        result.domainBottleneckNote = "bottleneck比較は、同一Direct topologyで24時間以上、Host 1 TB以上、TLC／pSLC双方のP/E進行がある区間を2本以上必要とします。条件不足時は主計算を切り替えません。"
                    }
                }
            } else {
                result.domainModelNote = "Direct topologyが未取得・未確認のため、domain配分未取得・累積損耗によるN/u概算を表示します。80-band当てはめは詳細比較のみです。"
                result.domainBottleneckNote = "bottleneck比較はDirect topology由来のTLC／pSLC配分が必要です。"
            }
        } else {
            result.domainModelNote = "Direct FTLが未取得のため、domain配分未取得・累積損耗によるN/u概算を表示します。"
            result.domainBottleneckNote = "bottleneck比較はDirect topology由来のTLC／pSLC配分が必要です。"
        }
        // Central forecast: TLC and pSLC each wear at their own rate per host
        // byte (pSLC is a write cache, only longer-lived data folds into
        // TLC). The remaining host writes are set by the domain that runs out
        // first, using the budget without retention derating.
        if !forecastHeld, result.domainModelAvailable,
           let topology = result.directTopology ?? continuityLane?.verifiedCoreTopology,
           let share = DomainWriteShare.estimate(
               estimates: result.domainBaselineEstimates,
               series: latestSeries,
               topology: topology,
               windowDays: result.forecastWAFWindowDays,
               recentWeight: result.recentWeight,
               excluding: excluding + (continuityLane?.rateLearningExclusions ?? [])
           ) {
            result.domainWriteShare = share
            if let waf = result.forecastWAF {
                result.domainBottleneckRemaining = DomainBottleneckRemaining.evaluate(
                    estimates: result.domainBaselineEstimates, waf: waf, share: share
                )
                result.domainForecastRows = DomainForecastRow.rows(
                    estimates: result.domainBaselineEstimates, waf: waf, share: share
                ) ?? []
                if let tlc = result.domainBaselineEstimates.first(where: { $0.domain == .tlc }),
                   let pslc = result.domainBaselineEstimates.first(where: { $0.domain == .pslc }) {
                    let pslcRate = waf * (1 - share.tlcShare)
                    result.idleRetentionTemperature = idle
                    result.retentionScenario = RetentionScenario.evaluate(
                        tlc: tlc,
                        tlcMaximumPE: latestSeries.last?.tlcMaximumPE,
                        tlcWritesPerHostByte: waf * share.tlcShare,
                        pslcRemainingHostBytes: pslcRate > 0 ? pslc.remainingBytes / pslcRate : nil,
                        storageTemperatureCelsius: idle.temperature,
                        storageTemperatureSource: idle.sourceTitle,
                        powerOffDays: settings.retentionDays ?? RetentionScenario.referenceDays
                    )
                }
            }
        }
        func clientProjection(waf: Double) -> (total: Double?, remaining: Double?) {
            guard !forecastHeld else { return (nil, nil) }
            if let share = result.domainWriteShare,
               let bottleneck = DomainBottleneckRemaining.evaluate(
                   estimates: result.domainBaselineEstimates, waf: waf, share: share
               ) {
                let remaining = bottleneck.remainingHostBytes
                let total = result.host.map { $0 + remaining }
                return (total?.isFinite == true ? total : nil, remaining)
            }
            let remainingNAND: Double?
            if result.domainModelAvailable {
                // No TLC/pSLC split yet: pool the budgets, but keep the
                // central rule of no retention derating (Kret = 1).
                remainingNAND = Self.nonnegative(result.baselineDomainRemainingBytes)
            } else if let budget = Self.positive(result.nominalBudget),
                      let currentNAND = Self.nonnegative(result.nand) {
                remainingNAND = max(0, budget - currentNAND)
            } else {
                remainingNAND = nil
            }
            guard let remainingNAND,
                  waf.isFinite, waf > 0 else {
                return (nil, nil)
            }
            let remaining = remainingNAND / waf
            guard remaining.isFinite else { return (nil, nil) }
            // The total is intentionally the observed lifetime Host plus the
            // future Client-converted remainder. It is not a fresh-device
            // Client-only counterfactual beside a current-life remainder.
            let total = result.host.map { $0 + remaining }
            return (total?.isFinite == true ? total : nil, remaining)
        }
        let clientLowProjection = clientProjection(waf: Self.clientWorkloadWAFUpper)
        let clientHighProjection = clientProjection(waf: Self.clientWorkloadWAFLower)
        result.clientLow = clientLowProjection.total
        result.clientHigh = clientHighProjection.total
        let clientProjection = clientProjection(waf: Self.clientWorkloadWAF)
        let peerReference = ReferenceTBW.resolve(
            profile: hardwareProfile,
            capacityBytes: smart?.logicalCapacityBytes ?? hardwareProfile?.logicalCapacityBytes
        )
        let peerThreshold = peerReference?.tbwBytes
        if (result.domainActualBudget ?? result.nominalBudget) != nil, clientProjection.total == nil {
            result.notes.append("Client総量は累積Hostが取得できないため表示を保留。残量はClient条件の参考値です。")
        }
        let centralProjection: Projection = {
            if let bottleneck = result.domainBottleneckRemaining, let host = result.host {
                let remaining = bottleneck.remainingHostBytes
                return .init(title: "実使用", total: host + remaining, remaining: remaining,
                             note: "\(bottleneck.limitingDomain.title)律速・\(bottleneck.limitingDomain.title)書込/Host \(String(format: "%.2f", bottleneck.limitingDomainBytesPerHostByte))・保持補正なし")
            }
            // Fallback without a TLC/pSLC split: pooled budget, still Kret = 1.
            return projection(title: "実使用", budget: result.domainBaselineBudget ?? result.actualBudget, host: result.host,
                              nand: result.domainUsedBytes ?? result.nand, waf: result.forecastWAF,
                              note: result.domainModelAvailable
                                  ? "geometry由来のTLC／pSLC残NAND ÷ 観測量ベース予測WAF"
                                  : "domain配分未取得・累積損耗による概算")
        }()
        result.projections = [
            centralProjection,
            .init(title: "クライアント負荷", total: clientProjection.total,
                  remaining: clientProjection.remaining, note: result.domainWriteShare == nil
                      ? "TLC／pSLC合算・保持補正なし・今後Client WAF 3.5（比較3〜4）／Hostペースは共通"
                      : "先に尽きるdomainで判定・保持補正なし・今後Client WAF 3.5（比較3〜4）／Hostペースは共通",
                  kind: .client),
            .init(title: "参考基準", total: peerThreshold,
                  remaining: peerThreshold.flatMap { threshold in result.host.map { max(0, threshold - $0) } },
                  note: peerReference?.summary ?? "論理容量未取得・参考基準を算出できません",
                  kind: .peerReference)
        ]
        result.notes += ["TLC／pSLCの正規化損耗率は従来N/u比較と損耗診断に使用し、domain主予算では各容量と平均P/Eを個別に計算します。",
            "Controller EOLを30°C・365日の基準点と置く研究仮定です。保持保証・JEDEC認証値ではありません。",
            "クライアント負荷のWAF 3〜4は研究用の比較範囲です。Apple個体の測定値やJEDECの規定値ではありません。",
            "Vendor WriteAmp、試験WAF、cross-temperatureは診断用。主計算へ追加乗算しません。",
            "Forecast WAFはdomain残量のHost換算のみに適用し、過去Host Writesを再評価しません。"]
        if centralProjection.remaining != nil, let inputDate = result.inputDate,
           let deviceID = latestFTL?.deviceID {
            var smartHistory = history
            if let smart, !smartHistory.contains(where: { $0.id == smart.id }) {
                smartHistory.append(smart)
            }
            result.hostWrittenSinceInput = hostWritten(since: inputDate, deviceID: deviceID, smart: smartHistory)
        }
        let wearEvidence = suppliedWearEvidence ?? ControllerWearHistoryAnalyzer().summarize(
            snapshots: snapshots, deviceID: smart?.deviceID, excluding: excluding,
            aggregateSlopes: true, smartHistory: history, continuityLane: continuityLane)
        result.observationEvidence = ForecastObservationEvidence.assess(
            wear: wearEvidence, wafDays: result.wafObservationDays ?? 0,
            wafHost: result.wafObservedHostBytes ?? 0,
            paceDays: rates.currentWorkloadObservedDays ?? 0,
            hasDomains: result.domainBaselineEstimates.count == 2, held: forecastHeld)
        return result
    }

    private static func makeBoundaryBridge(_ record: InstrumentBoundaryRecord) -> FirmwareWearBoundaryBridge {
        let status: FirmwareWearBoundaryStatus
        switch record.continuity {
        case .verified:
            status = .verified
        case .pending:
            status = .pending
        case .failed:
            status = .failed
        case .deviceChange:
            status = .failed
        case .reviewed, .sameInstrument:
            status = .verified
        }
        let boundaryDate = record.boundary.after
        return FirmwareWearBoundaryBridge(
            before: record.boundary.before,
            after: boundaryDate,
            wafLearningExclusion: record.rateLearningExclusion
                ?? DateInterval(start: boundaryDate, end: boundaryDate),
            note: record.note,
            status: status,
            checks: record.checks
        )
    }

    /// Reconstruct a daily wear-balance series from existing FTL snapshots.
    /// This intentionally requires the reviewed semantic contract and never
    /// extrapolates a future crossing or changes a prediction multiplier.
    static func makeWearBalanceTrend(
        series: [ASPToolDiagnosticsSnapshot],
        excluding: [DateInterval]
    ) -> WearBalanceTrend {
        let raw = series.compactMap { snapshot -> WearBalanceObservation? in
            guard DirectFTLResearchContract.isReviewedContract(for: snapshot),
                  snapshot.resolvedCoreWearVersion == DirectFTLResearchContract.reviewed25G83CoreV1,
                  !excluding.contains(where: { $0.contains(snapshot.capturedAt) }),
                  let tlcPE = nonnegative(snapshot.tlcAveragePE),
                  let tlcEOL = positive(snapshot.tlcEOLPE),
                  let pslcPE = nonnegative(snapshot.slcAveragePE),
                  let pslcEOL = positive(snapshot.slcEOLPE) else {
                return nil
            }
            let tlcWear = tlcPE / tlcEOL
            let pslcWear = pslcPE / pslcEOL
            guard tlcWear.isFinite, pslcWear.isFinite, tlcWear > 0, pslcWear >= 0 else {
                return nil
            }
            let ratio = pslcWear / tlcWear
            let divergence = abs(tlcWear - pslcWear) / min(tlcWear, pslcWear > 0 ? pslcWear : tlcWear)
            guard ratio.isFinite, divergence.isFinite else { return nil }
            return WearBalanceObservation(
                capturedAt: snapshot.capturedAt,
                tlcWear: tlcWear,
                pslcWear: pslcWear,
                ratio: ratio,
                divergence: divergence
            )
        }.sorted { $0.capturedAt < $1.capturedAt }

        guard !raw.isEmpty else {
            return .empty
        }

        // One point per UTC day prevents a higher polling frequency from
        // visually dominating the trend. Keep the last point in each day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var daily: [Date: WearBalanceObservation] = [:]
        for point in raw {
            let day = calendar.startOfDay(for: point.capturedAt)
            if let existing = daily[day], existing.capturedAt >= point.capturedAt {
                continue
            }
            daily[day] = point
        }
        let allPoints = daily.values.sorted { $0.capturedAt < $1.capturedAt }
        let points = Array(allPoints.suffix(180))
        guard let first = points.first, let last = points.last else { return .empty }

        let enrichedPoints = points.enumerated().map { index, point in
            guard index > 0 else { return point }
            let previous = points[index - 1]
            let tlcDelta = point.tlcWear - previous.tlcWear
            let pslcDelta = point.pslcWear - previous.pslcWear
            return WearBalanceObservation(
                capturedAt: point.capturedAt,
                tlcWear: point.tlcWear,
                pslcWear: point.pslcWear,
                ratio: point.ratio,
                divergence: point.divergence,
                tlcWearDelta: tlcDelta.isFinite ? tlcDelta : nil,
                pslcWearDelta: pslcDelta.isFinite ? pslcDelta : nil
            )
        }

        let observationDays = points.count > 1
            ? last.capturedAt.timeIntervalSince(first.capturedAt) / 86_400
            : nil
        let ratios = enrichedPoints.map(\.ratio)
        let slope: Double? = {
            guard points.count >= 2 else { return nil }
            let origin = first.capturedAt
            let xs = enrichedPoints.map { $0.capturedAt.timeIntervalSince(origin) / 86_400 }
            let meanX = xs.reduce(0, +) / Double(xs.count)
            let meanY = ratios.reduce(0, +) / Double(ratios.count)
            let numerator = zip(xs, ratios).reduce(0) { partial, pair in
                partial + (pair.0 - meanX) * (pair.1 - meanY)
            }
            let denominator = xs.reduce(0) { partial, value in
                partial + (value - meanX) * (value - meanX)
            }
            guard denominator > 0 else { return nil }
            let result = numerator / denominator
            return result.isFinite ? result : nil
        }()

        var crossing: Date?
        for (before, after) in zip(enrichedPoints, enrichedPoints.dropFirst()) {
            if before.ratio == 1 {
                crossing = before.capturedAt
                break
            }
            if after.ratio == 1 {
                crossing = after.capturedAt
                break
            }
            let crossedUp = before.ratio < 1 && after.ratio > 1
            let crossedDown = before.ratio > 1 && after.ratio < 1
            guard crossedUp || crossedDown else { continue }
            let denominator = after.ratio - before.ratio
            let fraction = (1 - before.ratio) / denominator
            guard fraction.isFinite else { continue }
            let clamped = min(1, max(0, fraction))
            crossing = before.capturedAt.addingTimeInterval(
                after.capturedAt.timeIntervalSince(before.capturedAt) * clamped
            )
            break
        }

        let note: String
        if points.count < 2 {
            note = "同一UTC日内の取得をまとめた比較点が\(points.count)点です。日別の傾向はまだ算出しません。"
        } else if allPoints.count > points.count {
            note = "UTC日別\(points.count)点（直近180点）。取得頻度ではなく観測日数で傾向を表示します。"
        } else {
            note = "UTC日別\(points.count)点。将来の1.00到達日は外挿せず、実測区間内の横切りのみを表示します。"
        }
        func regressionSlope(_ values: [Double]) -> Double? {
            guard enrichedPoints.count >= 2, values.count == enrichedPoints.count else { return nil }
            let origin = enrichedPoints[0].capturedAt
            let xs = enrichedPoints.map { $0.capturedAt.timeIntervalSince(origin) / 86_400 }
            let meanX = xs.reduce(0, +) / Double(xs.count)
            let meanY = values.reduce(0, +) / Double(values.count)
            let numerator = zip(xs, values).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
            let denominator = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
            guard denominator > 0 else { return nil }
            let value = numerator / denominator
            return value.isFinite ? value : nil
        }
        let tlcSlope = regressionSlope(enrichedPoints.map(\.tlcWear))
        let pslcSlope = regressionSlope(enrichedPoints.map(\.pslcWear))

        return WearBalanceTrend(
            observations: enrichedPoints,
            observationDays: observationDays,
            firstRatio: enrichedPoints.first?.ratio,
            latestRatio: enrichedPoints.last?.ratio,
            minimumRatio: ratios.min(),
            maximumRatio: ratios.max(),
            changePerDay: slope,
            tlcWearChangePerDay: tlcSlope,
            pslcWearChangePerDay: pslcSlope,
            observedCrossingAt: crossing,
            note: note
        )
    }

    /// Capacity-derived TLC consumption can only stand in for the aggregate
    /// NAND counter when the two cover the same wear domains. Keep the gate
    /// public to the module so the regression tests can pin the boundary.
    static func capacityModelIsConsistent(physicalConsumed: Double?, nand: Double?) -> Bool {
        guard let consumed = nonnegative(physicalConsumed),
              let measured = positive(nand) else { return false }
        let relativeDifference = abs(consumed - measured) / measured
        return relativeDifference.isFinite && relativeDifference <= 0.10
    }

    /// Build the central TLC/pSLC budget from directly reported partition
    /// boundaries. The pSLC writable capacity is used for endurance; its
    /// TLC-mode physical footprint stays an explanatory value only.
    private mutating func applyDomainBudget(
        latest: ASPToolDiagnosticsSnapshot,
        topology: DirectFTLTopology
    ) {
        guard let calculation = DirectDomainBudgetCalculator.calculate(
            latest: latest,
            topology: topology,
            retentionFactor: retentionFactor
        ) else {
            domainModelNote = "Direct topologyまたはTLC／pSLCの平均P/E・EOLから有限なdomain予算を構成できません。"
            return
        }

        domainEstimates = calculation.estimates
        domainBaselineEstimates = calculation.baselineEstimates
        domainModelAvailable = true
        domainBaselineBudget = calculation.baselineBudgetBytes
        domainActualBudget = calculation.adjustedBudgetBytes
        domainUsedBytes = calculation.usedBytes
        domainRemainingBytes = calculation.adjustedRemainingBytes
        baselineDomainRemainingBytes = calculation.baselineRemainingBytes
        retentionAdjustedDomainRemainingBytes = calculation.adjustedRemainingBytes
        retentionDeltaRemainingBytes = calculation.adjustedRemainingBytes - calculation.baselineRemainingBytes
        domainClientRemainingBytes = calculation.adjustedRemainingBytes
        fixedReferenceRemainingBytes = calculation.baselineRemainingBytes

        let reconciliation = NANDReconciliationDiagnosticsBuilder.build(
            topology: topology,
            latest: latest,
            measuredNAND: Self.nonnegative(nand),
            knownUsed: domainUsedBytes,
            domainBaselineBudget: domainBaselineBudget,
            nominalBudget: nominalBudget
        )
        domainReconstructionError = reconciliation.currentError
        domainBudgetReconciliationError = reconciliation.budgetError
        reconstructionDiagnostics = reconciliation.diagnostics

        domainModelNote = "Direct FTLの区画境界からの暫定研究推計。topologyのkeyの対応表は確認済みですが、物理NAND配分は未検証です。中央予測は保持補正なし。研究値ではTLCのみ保持補正し、pSLCの保持係数は1.0です。"
        if calculation.estimates.count >= 2 {
            notes.append("Direct topology主予算：TLC \(ValueFormatter.bytes(calculation.estimates[0].totalBudgetBytes))、pSLC \(ValueFormatter.bytes(calculation.estimates[1].totalBudgetBytes))。未同定残差は予算へ加算しません。")
        }
        notes.append("保持補正なし残NAND \(ValueFormatter.bytes(calculation.baselineRemainingBytes)) → 研究保持補正後 \(ValueFormatter.bytes(calculation.adjustedRemainingBytes))。差分を独立診断として保持します。")
        notes.append("pSLC物理占有量 \(ValueFormatter.bytes(calculation.pslcPhysicalFootprintBytes)) と書込可能容量 \(ValueFormatter.bytes(calculation.estimates.first { $0.domain == .pslc }?.capacityBytes)) を分離して表示します。")
        if let error = domainReconstructionError {
            notes.append("既知domain使用量と累積NANDの再構成誤差：\(String(format: "%.2f", error * 100))%。この誤差は容量検証ではありません。")
        }
        if let error = domainBudgetReconciliationError {
            notes.append("Direct topology予算と従来N/u予算の比較誤差：\(String(format: "%.2f", error * 100))%。別経路の比較値です。")
        }
    }

    private static func makeDomainBottleneck(
        series: [ASPToolDiagnosticsSnapshot],
        topology: DirectFTLTopology?,
        estimates: [NANDDomainEstimate],
        excluding: [DateInterval],
        topologyFallback: DirectFTLTopology?
    ) -> NANDBottleneckEstimate? {
        guard let topology,
              let tlc = estimates.first(where: { $0.domain == .tlc }),
              let pslc = estimates.first(where: { $0.domain == .pslc }),
              let tlcCapacity = topology.tlcCapacityBytes,
              let pslcCapacity = topology.pslcWritableCapacityBytes,
              tlcCapacity > 0, pslcCapacity > 0 else {
            return nil
        }
        var tlcConsumed = 0.0
        var pslcConsumed = 0.0
        var nandConsumed = 0.0
        var intervalCount = 0
        // Keep a cumulative anchor instead of requiring every adjacent poll
        // to contain a P/E transition. Direct FTL P/E values are quantized;
        // holding the anchor lets several quiet polls form one meaningful
        // interval without treating a repartition or reset as wear.
        var anchor: ASPToolDiagnosticsSnapshot?
        let analysisSeries = series.map { sample in
            if sample.sourceArtifact == .extractedASPTool,
               sample.directTopology == nil,
               let topologyFallback {
                return sample.analysisCopy(overridingTopology: topologyFallback)
            }
            return sample
        }
        for current in analysisSeries.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            guard current.captureQuality != .unknown,
                  current.sourceArtifact.participatesInCoreWearLane,
                  current.directTopology?.isEquivalentGeometry(to: topology) == true,
                  let currentHost = current.hostWrittenBytes,
                  let currentNAND = current.nandWrittenBytes,
                  let currentTLCPE = current.tlcAveragePE,
                  let currentPSLCPE = current.slcAveragePE,
                  [currentHost, currentNAND, currentTLCPE, currentPSLCPE]
                    .allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                anchor = nil
                continue
            }

            guard let start = anchor else {
                anchor = current
                continue
            }

            let interval = DateInterval(start: start.capturedAt, end: current.capturedAt)
            let sameSeries = ControllerWearSeriesIdentity(snapshot: start) == ControllerWearSeriesIdentity(snapshot: current)
                && start.deviceID == current.deviceID
            guard interval.duration > 0, sameSeries else {
                anchor = current
                continue
            }
            guard !excluding.contains(where: { $0.intersects(interval) }) else {
                anchor = current
                continue
            }

            guard let h0 = start.hostWrittenBytes,
                  let n0 = start.nandWrittenBytes,
                  let t0 = start.tlcAveragePE,
                  let s0 = start.slcAveragePE,
                  currentHost >= h0,
                  currentNAND >= n0,
                  currentTLCPE >= t0,
                  currentPSLCPE >= s0 else {
                // A counter/P/E decrease is a reset boundary. Do not bridge
                // it with a cumulative interval.
                anchor = current
                continue
            }

            let hostDelta = currentHost - h0
            guard interval.duration >= 86_400,
                  hostDelta >= 1e12,
                  currentNAND > n0,
                  currentTLCPE > t0,
                  currentPSLCPE > s0 else {
                // Keep the same anchor so quantized P/E can accumulate over
                // later samples. A valid zero-progress poll is not a reset.
                continue
            }

            let deltaNAND = currentNAND - n0
            let deltaTLC = tlcCapacity * (currentTLCPE - t0)
            let deltaPSLC = pslcCapacity * (currentPSLCPE - s0)
            guard [deltaNAND, deltaTLC, deltaPSLC].allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
            nandConsumed += deltaNAND
            tlcConsumed += deltaTLC
            pslcConsumed += deltaPSLC
            intervalCount += 1
            anchor = current
        }
        guard intervalCount >= 2, nandConsumed > 0 else { return nil }
        let tlcShare = tlcConsumed / nandConsumed
        let pslcShare = pslcConsumed / nandConsumed
        guard [tlcShare, pslcShare].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let tlcEquivalent = tlc.remainingBytes / tlcShare
        let pslcEquivalent = pslc.remainingBytes / pslcShare
        let limitingDomain: NANDDomain?
        if tlcEquivalent < pslcEquivalent {
            limitingDomain = .tlc
        } else {
            limitingDomain = .pslc
        }
        return NANDBottleneckEstimate(
            intervalCount: intervalCount,
            tlcShare: tlcShare,
            pslcShare: pslcShare,
            tlcEquivalentRemainingBytes: tlcEquivalent.isFinite ? tlcEquivalent : nil,
            pslcEquivalentRemainingBytes: pslcEquivalent.isFinite ? pslcEquivalent : nil,
            limitingDomain: limitingDomain,
            distributionError: abs(tlcShare + pslcShare - 1),
            note: "同一topologyの累積anchor区間を使用し、各区間の始点容量を固定。P/E量子化を跨いで集約しています。分担率は自動正規化せず、domain主値を自動切替しない比較値です。"
        )
    }

    /// Infer an integer TLC/pSLC band split from the current aggregate NAND
    /// counter. This is an explanatory research proxy only. The counter is
    /// one of the fitted inputs, so the result is explicitly not an
    /// independent validation of the counter or of the physical partition.
    private static func makeBandAllocationProxy(
        profile: AppleNANDHardwareProfile?,
        latest: ASPToolDiagnosticsSnapshot,
        nand: Double?
    ) -> NANDBandAllocationProxy? {
        guard let profile,
              profile.geometryConfidence == .consistent,
              let blocksPerCAU = profile.blocksPerCAU,
              blocksPerCAU > 0,
              let nativeSectors = profile.sectorsPerFullBand,
              nativeSectors > 0,
              let slcSectors = profile.sectorsPerFullBandSLC,
              slcSectors > 0,
              let sectorSizeBytes = profile.geometrySectorSizeBytes,
              sectorSizeBytes > 0,
              let tlcPE = positive(latest.tlcAveragePE),
              let slcPE = positive(latest.slcAveragePE),
              let measuredNAND = positive(nand),
              let totalBands = Int(exactly: blocksPerCAU) else {
            return nil
        }
        // The full-band fields are counts of geometry sectors. Derive the
        // sector size from page-size / sec-per-page; this Mac reports
        // 16 KiB / 4 = 4,096 B. Do not confuse it with NVMe SMART Data
        // Units (512,000 B) or the separate FTL counter unit.
        let tlcBandBytes = Double(nativeSectors) * Double(sectorSizeBytes)
        let pslcBandBytes = Double(slcSectors) * Double(sectorSizeBytes)
        let denominator = pslcBandBytes * slcPE - tlcBandBytes * tlcPE
        guard [tlcBandBytes, pslcBandBytes, denominator].allSatisfy({ $0.isFinite }),
              abs(denominator) > 0 else { return nil }

        let allTLCNAND = Double(totalBands) * tlcBandBytes * tlcPE
        let rawPSLCBands = (measuredNAND - allTLCNAND) / denominator
        guard rawPSLCBands.isFinite else { return nil }
        let pslcBands = Int(rawPSLCBands.rounded())
        guard (0...totalBands).contains(pslcBands) else { return nil }
        let tlcBands = totalBands - pslcBands
        let tlcCapacity = Double(tlcBands) * tlcBandBytes
        let pslcCapacity = Double(pslcBands) * pslcBandBytes
        let modeledNAND = tlcCapacity * tlcPE + pslcCapacity * slcPE
        guard modeledNAND.isFinite, modeledNAND > 0 else { return nil }
        let relativeError = abs(modeledNAND - measuredNAND) / measuredNAND
        guard relativeError.isFinite else { return nil }

        var notes = [
            "642 TLC bands / 80 pSLC bandsのような整数band解を、現在のNAND counterへの当てはめから得た研究proxyです。",
            "band容量はgeometryのfull-band sector数 × \(sectorSizeBytes) B sectorから導出しています。",
            "NAND counterを入力に使うため、独立検証ではありません。capacityAllocationVerified=falseを維持します。",
            "逆算band proxyはAdvancedの整合比較のみに使います。主NAND予算・残Host・到達日はDirect topology、欠測時は累積損耗N/u概算です。"
        ]
        if latest.oslcTransitions != nil || latest.oslcBaseAveragePE != nil {
            notes.append("oslcTransitions／oslcBaseAveragePEが取得されているため、bandの動的再配分可能性を残し、固定配分とは扱いません。")
        }
        if relativeError > 0.002 {
            notes.append("整数band当てはめの誤差は\(String(format: "%.2f", relativeError * 100))%です。独立検証済みとは扱いません。")
        }
        return NANDBandAllocationProxy(
            totalBands: totalBands,
            tlcBands: tlcBands,
            rawPSLCBands: rawPSLCBands,
            pslcBands: pslcBands,
            sectorSizeBytes: sectorSizeBytes,
            tlcBandBytes: tlcBandBytes,
            pslcBandBytes: pslcBandBytes,
            tlcCapacityBytes: tlcCapacity,
            pslcCapacityBytes: pslcCapacity,
            pslcPhysicalFootprintBytes: Double(pslcBands) * tlcBandBytes,
            modeledNANDBytes: modeledNAND,
            measuredNANDBytes: measuredNAND,
            relativeError: relativeError,
            capacityAllocationVerified: false,
            notes: notes
        )
    }

    private static func physicalCapacity(
        smart: DriveSnapshot?,
        hardwareProfile: AppleNANDHardwareProfile?
    ) -> (bytes: Double, source: RetentionPhysicalCapacitySource, notes: [String])? {
        let smartLogical = smart?.logicalCapacityBytes.flatMap { $0 > 0 ? Double($0) : nil }
        let profileLogical = hardwareProfile.map(\.logicalCapacityBytes).flatMap { $0 > 0 ? Double($0) : nil }
        let logical = smartLogical ?? profileLogical

        if let geometry = hardwareProfile?.geometryCapacityBytes,
           hardwareProfile?.geometryConfidence == .consistent,
           geometry > 0,
           let geometryBytes = Double(exactly: geometry),
           geometryBytes.isFinite,
           geometryBytes > 0,
           logical == nil || geometryBytes >= logical! {
            return (
                geometryBytes,
                .geometryResearchProxy,
                ["geometry容量は整合したIORegistry値からの研究proxyで、Appleの実効NAND容量の確認済み値ではありません。"]
            )
        }

        guard let logical, logical.isFinite, logical > 0 else { return nil }
        var notes = ["geometryが未確認または論理容量未満のため、SMART／profile論理容量を研究proxyとして使用します。"]
        if hardwareProfile?.geometryCapacityBytes != nil {
            notes.append("geometryの不整合は寿命倍率へ変換していません。")
        }
        return (logical, .logicalCapacityProxy, notes)
    }

    private static func makeWAFComponents(
        _ snapshot: ASPToolDiagnosticsSnapshot
    ) -> FTLWAFComponentDecomposition? {
        let total = positive(snapshot.writeAmplification)
        let native = nonnegative(snapshot.writeAmp)
        let intermediate = nonnegative(snapshot.intermediateWriteAmp)
        guard total != nil || native != nil || intermediate != nil else { return nil }
        guard let total, let native, let intermediate else {
            return FTLWAFComponentDecomposition(
                total: total, native: native, intermediate: intermediate,
                residual: nil, isConsistent: nil,
                note: "全体WAFまたはerase/geometry再構成成分が不足しているため、残差は未算出です。"
            )
        }
        let rawResidual = total - native - intermediate
        let captureTolerance = max(total * 0.005, 1e-12)
        let withinCaptureTolerance = rawResidual < 0 && abs(rawResidual) <= captureTolerance
        var residual = rawResidual
        if abs(residual) < 1e-12 || withinCaptureTolerance { residual = 0 }
        return FTLWAFComponentDecomposition(
            total: total, native: native, intermediate: intermediate,
            residual: residual, isConsistent: residual >= 0,
            note: withinCaptureTolerance
                ? "全体WAF − Native成分 − Intermediate成分の負残差は0.5%以内の丸め／取得時差として0へ表示。成分は未校正で、Forecast WAFへ代入しません。"
                : residual >= 0
                    ? "全体WAF − Native成分 − Intermediate成分。成分の定義・取得時刻差は未校正で、Forecast WAFへ代入しません。"
                    : "全体WAF − Native成分 − Intermediate成分が0.5%を超えて負です。不整合として保持し、Forecast WAFへ代入しません."
        )
    }

    static func dailyStability(series: [ASPToolDiagnosticsSnapshot], excluding: [DateInterval],
                               now: Date, days: Int) -> (days: Int, factor: Double, coveredDays: Double) {
        var bins: [Int: (Double, Double)] = [:]
        var coveredSeconds = 0.0
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        // A daily timer is not an exact 24-hour metronome: tolerance,
        // wake-up latency and sleep routinely make it longer. Derive the
        // normal cadence from the series and allow 1.5× it, while still
        // rejecting multi-day holes when the normal cadence is daily.
        let positiveIntervals = zip(series, series.dropFirst()).compactMap { left, right -> Double? in
            let value = right.capturedAt.timeIntervalSince(left.capturedAt)
            return value > 0 && value.isFinite ? value : nil
        }.sorted()
        let expectedInterval = positiveIntervals.isEmpty
            ? 86_400
            : positiveIntervals[positiveIntervals.count / 2]
        let gapCap = max(86_400 * 1.5, expectedInterval * 1.5)
        for (a, b) in zip(series, series.dropFirst()) {
            guard a.capturedAt >= cutoff, b.capturedAt > a.capturedAt,
                  a.captureQuality == .explicit, b.captureQuality == .explicit,
                  let h0 = a.hostWrittenBytes, let h1 = b.hostWrittenBytes,
                  let n0 = a.nandWrittenBytes, let n1 = b.nandWrittenBytes,
                  h1 >= h0, n1 >= n0 else { continue }
            let interval = DateInterval(start: a.capturedAt, end: b.capturedAt)
            guard interval.duration <= gapCap,
                  !excluding.contains(where: { $0.intersects(interval) }) else { continue }
            coveredSeconds += interval.duration
            var start = a.capturedAt.timeIntervalSince1970
            let end = b.capturedAt.timeIntervalSince1970
            while start < end {
                let day = Int(floor(start / 86_400))
                let stop = min(end, Double(day + 1) * 86_400)
                let fraction = (stop - start) / interval.duration
                let previous = bins[day] ?? (0, 0)
                bins[day] = (previous.0 + (h1 - h0) * fraction, previous.1 + (n1 - n0) * fraction)
                start = stop
            }
        }
        let weightedBins = bins.values.filter { h, n in h > 0 && n > 0 && (n / h).isFinite }
        let totalHost = weightedBins.reduce(0) { $0 + $1.0 }
        guard totalHost > 0, totalHost.isFinite else { return (0, 0, 0) }
        // A day with 300 GB of host traffic constrains the aggregate WAF more
        // than a day with 1 GB of background traffic. Use host bytes as the
        // weight for both the mean and the variance; the mean is exactly
        // ΣΔN/ΣΔH for the selected daily bins.
        let mean = weightedBins.reduce(0) { sum, bin in
            sum + bin.1
        } / totalHost
        guard mean > 0, mean.isFinite else { return (0, 0, 0) }
        let variance = weightedBins.reduce(0) { sum, bin in
            let ratio = bin.1 / bin.0
            return sum + (bin.0 / totalHost) * pow(ratio - mean, 2)
        }
        let cv = sqrt(max(0, variance)) / mean
        return (weightedBins.count, 1 / (1 + cv * cv), coveredSeconds / 86_400)
    }
}
