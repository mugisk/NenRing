import Foundation

/// Research profile for the RBER retention fit published by Luo et al.
/// The paper identifies the characterization as single-vendor 3D MLC charge-trap
/// NAND; the vendor/process are intentionally not disclosed in the paper.
struct RetentionResearchProfile: Equatable, Sendable, Identifiable {
    let id: String
    let version: Int
    let title: String
    let sourceTitle: String
    let sourceURL: String
    let sourceSections: String
    let referenceTemperatureCelsius: Double
    let measuredMinimumRetentionSeconds: Double
    let measuredMaximumRetentionSeconds: Double
    let measuredMaximumPE: Double
    let msbRBER: RetentionRBERCoefficients
    let lsbRBER: RetentionRBERCoefficients
    let notes: [String]

    static let luo2018 = RetentionResearchProfile(
        id: "luo-ghose-cai-2018-3d-mlc",
        version: 1,
        title: "Luo et al. 2018 · 3D MLC retention fit",
        sourceTitle: "Improving 3D NAND Flash Memory Lifetime by Tolerating Early Retention Loss and Process Variation",
        sourceURL: "https://www.pdl.cmu.edu/PDL-FTP/NVM/18sigmetrics_3dflash.pdf",
        sourceSections: "§4.1, §4.3, §5.2, Table 2, §6.5",
        referenceTemperatureCelsius: 20,
        measuredMinimumRetentionSeconds: 7 * 60,
        measuredMaximumRetentionSeconds: 24 * 86_400,
        measuredMaximumPE: 10_000,
        msbRBER: RetentionRBERCoefficients(
            alpha: 5.49e-6, beta: 0.16, gamma: 1.33e-4, delta: -13.11, adjustedR2: 0.9717
        ),
        lsbRBER: RetentionRBERCoefficients(
            alpha: 7.92e-6, beta: 0.25, gamma: 3.28e-5, delta: -12.72, adjustedR2: 0.9005
        ),
        notes: [
            "72 pages from 11 randomly selected blocks; P/E characterization from 0 to 10,000 in 1,000-cycle steps.",
            "Retention data collected at 20°C from 7 minutes to 24 days; 0.5-second dwell time.",
            "The paper writes log() without naming its base or the time unit used in the fitted table. This implementation explicitly assumes natural logarithms and seconds.",
            "3×10⁻³ is the paper's assumed ECC limit in its system-level lifetime evaluation, not an Apple ECC specification."
        ]
    )
}

struct RetentionRBERCoefficients: Equatable, Sendable {
    let alpha: Double
    let beta: Double
    let gamma: Double
    let delta: Double
    let adjustedR2: Double

    func logRBER(pe: Double, retentionSeconds: Double) -> Double? {
        guard pe.isFinite, pe >= 0,
              retentionSeconds.isFinite, retentionSeconds > 0,
              [alpha, beta, gamma, delta].allSatisfy(\.isFinite) else { return nil }
        let value = (alpha * pe + beta) * log(retentionSeconds) + gamma * pe + delta
        return value.isFinite ? value : nil
    }

    func rber(pe: Double, retentionSeconds: Double) -> Double? {
        guard let value = logRBER(pe: pe, retentionSeconds: retentionSeconds), value < 709 else { return nil }
        let result = exp(value)
        return result.isFinite && result >= 0 ? result : nil
    }

    func allowablePE(rberThreshold: Double, retentionSeconds: Double) -> Double? {
        guard rberThreshold.isFinite, rberThreshold > 0, rberThreshold < 1,
              retentionSeconds.isFinite, retentionSeconds > 0 else { return nil }
        let logTime = log(retentionSeconds)
        let slope = alpha * logTime + gamma
        let intercept = beta * logTime + delta
        guard slope.isFinite, intercept.isFinite, slope > 0 else { return nil }
        let pe = (log(rberThreshold) - intercept) / slope
        guard pe.isFinite, pe >= 0 else { return nil }
        return pe
    }
}

struct RetentionModelAllowance: Equatable, Sendable {
    let profileID: String
    let profileVersion: Int
    let targetTemperatureCelsius: Double
    let targetRetentionDays: Double
    let equivalentRetentionSecondsAtReferenceTemperature: Double
    let equivalentRetentionDaysAtReferenceTemperature: Double
    let retentionTimeExtrapolationRatio: Double
    let referenceRBERThreshold: Double
    let activationEnergyEV: Double
    let allowableMSBPE: Double
    let allowableLSBPE: Double
    let allowableTLCPE: Double
    let limitingBitClass: String
    let peExtrapolationRatio: Double
    let assumptions: [String]
}

enum RetentionModelEvaluation: Equatable, Sendable {
    case available(RetentionModelAllowance)
    case unavailable(String)
}

/// A directly observed interval in which the Power On Hours counter advanced
/// less than the wall-clock interval. It is used as a measured no-power
/// equivalent for the retention scenario; no future usage or annualized value
/// is extrapolated from it.
struct ObservedUnpoweredPeriod: Equatable, Sendable {
    let start: Date
    let end: Date
    let durationDays: Double
    let powerOnHoursDelta: UInt64
}

struct RetentionDaysObservation: Equatable, Sendable {
    let longest: ObservedUnpoweredPeriod?
    let candidateCount: Int

    var days: Double? { longest?.durationDays }

    var source: String {
        guard longest != nil else { return "観測された無通電相当区間なし" }
        return "Power On Hours差分から観測（\(candidateCount)区間中の最長）"
    }
}

struct RetentionModelEvaluator: Sendable {
    static let referenceECCLimit = 3e-3
    static let referenceActivationEnergyEV = 1.1
    static let boltzmannEVPerKelvin = 8.617_333_262e-5

    /// Derives a retention duration only from stored SMART observations.
    /// Power On Hours is an integer-hour counter, so the measured equivalent
    /// unpowered time is wall-clock elapsed time minus the observed counter
    /// increase. Counter resets, firmware changes, reversed time, and research
    /// intervals are excluded rather than bridged.
    static func observedRetentionDays(
        smartHistory: [DriveSnapshot],
        deviceID: String,
        now: Date,
        excluding: [DateInterval] = []
    ) -> RetentionDaysObservation {
        let series = smartHistory
            .filter { $0.deviceID == deviceID && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
        var candidates: [ObservedUnpoweredPeriod] = []
        for (previous, current) in zip(series, series.dropFirst()) {
            guard previous.capturedAt < current.capturedAt,
                  previous.firmware == current.firmware,
                  let previousHours = previous.powerOnHours,
                  let currentHours = current.powerOnHours,
                  currentHours >= previousHours else { continue }
            let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
            guard !excluding.contains(where: { $0.intersects(interval) }) else { continue }
            let elapsed = interval.duration
            let powered = Double(currentHours - previousHours) * 3_600
            let unpowered = elapsed - powered
            guard elapsed.isFinite, elapsed > 0,
                  unpowered.isFinite, unpowered > 0 else { continue }
            candidates.append(ObservedUnpoweredPeriod(
                start: interval.start,
                end: interval.end,
                durationDays: unpowered / 86_400,
                powerOnHoursDelta: currentHours - previousHours
            ))
        }
        return RetentionDaysObservation(
            longest: candidates.max { $0.durationDays < $1.durationDays },
            candidateCount: candidates.count
        )
    }

    func evaluate(
        profile: RetentionResearchProfile,
        targetTemperatureCelsius: Double,
        targetRetentionDays: Double,
        rberThreshold: Double = Self.referenceECCLimit,
        activationEnergyEV: Double = Self.referenceActivationEnergyEV
    ) -> RetentionModelEvaluation {
        guard profile.version > 0,
              profile.measuredMaximumPE > 0,
              profile.measuredMaximumRetentionSeconds > 0,
              profile.referenceTemperatureCelsius.isFinite,
              targetTemperatureCelsius.isFinite,
              (-40...125).contains(targetTemperatureCelsius),
              targetRetentionDays.isFinite, targetRetentionDays > 0,
              targetRetentionDays <= 36_500,
              rberThreshold.isFinite, (1e-12...0.5).contains(rberThreshold),
              activationEnergyEV.isFinite, (0.1...3).contains(activationEnergyEV) else {
            return .unavailable("保持温度・期間・RBER閾値・活性化エネルギーの入力が範囲外です")
        }

        let targetKelvin = targetTemperatureCelsius + 273.15
        let referenceKelvin = profile.referenceTemperatureCelsius + 273.15
        let exponent = -activationEnergyEV / Self.boltzmannEVPerKelvin *
            (1 / targetKelvin - 1 / referenceKelvin)
        guard exponent.isFinite, abs(exponent) < 700 else {
            return .unavailable("Arrhenius温度換算が有限範囲を超えます")
        }
        let equivalentSeconds = targetRetentionDays * 86_400 * exp(exponent)
        guard equivalentSeconds.isFinite, equivalentSeconds > 0 else {
            return .unavailable("参照温度へ換算した保持時間を求められません")
        }

        guard let msbPE = profile.msbRBER.allowablePE(
            rberThreshold: rberThreshold, retentionSeconds: equivalentSeconds
        ), let lsbPE = profile.lsbRBER.allowablePE(
            rberThreshold: rberThreshold, retentionSeconds: equivalentSeconds
        ) else {
            return .unavailable("RBER曲線の適用区間で単調な非負P/E解がありません")
        }
        let isMSBLimiting = msbPE <= lsbPE
        let allowablePE = min(msbPE, lsbPE)
        guard allowablePE.isFinite, allowablePE >= 0 else {
            return .unavailable("許容P/Eが有限値になりません")
        }

        var assumptions = [
            "参照曲線は単一ベンダーの3D MLC NAND。AppleのTLCへ転用した研究シナリオです。",
            "pSLCは独立保持曲線なし。中央推定ではpSLC Controller EOLを保持係数1.0として使用します。",
            "Arrhenius換算はEa=\(String(format: "%.2f", activationEnergyEV)) eVの仮定です。",
            "RBER閾値は研究評価用で、Apple controllerのECC能力を示しません。",
            "logの底とTable 2の時間単位が原著に明記されていないため、自然対数・秒を実装仮定として採用しています。"
        ]
        if targetTemperatureCelsius != 30 || targetRetentionDays != 365 {
            assumptions.append("選択された保管条件での研究推計です。自動温度の場合は、通電中の観測から推定した保管温度proxyを使います。")
        }
        if rberThreshold != Self.referenceECCLimit {
            assumptions.append("RBER閾値は利用者が上書きした研究仮定です。")
        }
        if activationEnergyEV != Self.referenceActivationEnergyEV {
            assumptions.append("活性化エネルギーは利用者が上書きした研究仮定です。")
        }
        if allowablePE > profile.measuredMaximumPE {
            assumptions.append("許容P/E解は参照研究の最大 \(Int(profile.measuredMaximumPE)) P/Eを超える外挿です。")
        }
        if equivalentSeconds > profile.measuredMaximumRetentionSeconds {
            assumptions.append("参照温度換算後の保持時間は研究上限24日を超える外挿です。")
        }

        return .available(RetentionModelAllowance(
            profileID: profile.id,
            profileVersion: profile.version,
            targetTemperatureCelsius: targetTemperatureCelsius,
            targetRetentionDays: targetRetentionDays,
            equivalentRetentionSecondsAtReferenceTemperature: equivalentSeconds,
            equivalentRetentionDaysAtReferenceTemperature: equivalentSeconds / 86_400,
            retentionTimeExtrapolationRatio: equivalentSeconds / profile.measuredMaximumRetentionSeconds,
            referenceRBERThreshold: rberThreshold,
            activationEnergyEV: activationEnergyEV,
            allowableMSBPE: msbPE,
            allowableLSBPE: lsbPE,
            allowableTLCPE: allowablePE,
            limitingBitClass: isMSBLimiting ? "MSB" : "LSB",
            peExtrapolationRatio: allowablePE / profile.measuredMaximumPE,
            assumptions: assumptions
        ))
    }
}

/// Resolves the split retention weights while keeping settings written by the
/// previous single-weight UI usable. The old 0.20 was the former default, so
/// it is migrated to the new duration default rather than silently preserving
/// the old behavior. A different explicitly entered legacy value remains a
/// duration-weight override.
enum RetentionResearchWeightDefaults {
    static let legacyDefault = 0.20
    static let daysDefault = 0.50
    static let environmentDefault = 0.20

    static func daysWeight(from settings: UsageSettings) -> (value: Double, migratedLegacyDefault: Bool) {
        if let value = settings.retentionDaysWeight {
            return (value, false)
        }
        if let legacy = settings.retentionResearchWeight {
            if legacy.isFinite, abs(legacy - legacyDefault) < 1e-12 {
                return (daysDefault, true)
            }
            return (legacy, false)
        }
        return (daysDefault, false)
    }

    static func environmentWeight(from settings: UsageSettings) -> Double {
        settings.retentionEnvironmentWeight ?? environmentDefault
    }
}

enum RetentionPEBasis: String, Equatable, Sendable {
    case average
    case maximum

    var title: String { self == .average ? "平均P/E" : "最大P/E" }
}

enum RetentionWearInputSource: String, Equatable, Sendable {
    case dailyHistory
    case limitedDailyHistory
    case lifetimeAverage
    case manualPrior
    case capacityOnly
    case mixed

    var title: String {
        switch self {
        case .dailyHistory: "日常損耗履歴"
        case .limitedDailyHistory: "暫定・日常履歴（区間不足）"
        case .lifetimeAverage: "暫定・生涯Host Writes ÷ 現在P/E"
        case .manualPrior: "研究用domain傾き仮定"
        case .capacityOnly: "暫定・容量モデルのみ（損耗傾き未取得）"
        case .mixed: "domain別fallback混在"
        }
    }

    var isProvisional: Bool { self != .dailyHistory }

}

struct RetentionDomainEvidence: Equatable, Identifiable, Sendable {
    let domain: EnduranceWearDomain
    let currentPE: Double?
    let controllerEOLPE: Double?
    let allowablePE: Double?
    let hostBytesPerPE: Double?
    let inputSource: RetentionWearInputSource?
    let observedIntervals: Int
    let observationScore: Int
    let totalHostBytes: Double?
    let remainingHostBytes: Double?
    let reason: String?

    var id: String { domain.rawValue }
}

struct RetentionDomainHostEstimate: Equatable, Identifiable, Sendable {
    let domain: EnduranceWearDomain
    let currentPE: Double
    let controllerEOLPE: Double
    let allowablePE: Double
    let hostBytesPerPE: Double
    let observedIntervals: Int
    let totalHostBytes: Double
    let remainingHostBytes: Double
    let inputSource: RetentionWearInputSource
    let observationScore: Int

    var id: String { domain.rawValue }
}

struct RetentionRateProjection: Equatable, Sendable {
    let date: Date?
    let years: Double?
    let reached: Bool
}

enum RetentionPhysicalCapacitySource: String, Equatable, Sendable {
    case geometryResearchProxy
    case logicalCapacityProxy

    var title: String {
        switch self {
        case .geometryResearchProxy:
            return "IORegistry geometry由来（研究proxy）"
        case .logicalCapacityProxy:
            return "SMART論理容量由来（研究proxy）"
        }
    }
}

/// The capacity-based TBW estimate described in the overestimate guard
/// specification.  This is deliberately separate from the wear-slope
/// estimate: short, quantized P/E intervals must not become the lifetime
/// center value.  The capacity is still a research proxy because Apple does
/// not publish the effective NAND capacity or its spare-block allocation.
struct RetentionPhysicalTBWEstimate: Equatable, Sendable {
    let effectiveNANDCapacityBytes: Double
    let capacitySource: RetentionPhysicalCapacitySource
    let capacityIsProvisional: Bool
    let clientWAF: Double
    let currentWAF: Double
    let clientCorrectedPE: Double
    let currentCorrectedPE: Double
    let currentTLCPE: Double?
    let clientTotalHostBytes: Double
    let clientRemainingHostBytes: Double?
    let currentTotalHostBytes: Double
    let currentRemainingHostBytes: Double?
    let currentRateProjection: RetentionRateProjection
    let historicalRateProjection: RetentionRateProjection
    let notes: [String]
}

/// Host/P/E remains visible as an observation and calibration diagnostic, but
/// is no longer allowed to dominate the TBW center when ΔP/E is tiny.
struct RetentionHostPerPEDiagnostic: Equatable, Identifiable, Sendable {
    let domain: EnduranceWearDomain
    let observedHostBytesPerPE: Double?
    let priorHostBytesPerPE: Double?
    let blendedHostBytesPerPE: Double?
    let observationWeight: Double
    let observationScore: Int
    let observedIntervals: Int
    let inputSource: RetentionWearInputSource?
    let note: String?

    var id: String { domain.rawValue }
}

struct RetentionWearBasisEstimate: Equatable, Sendable {
    let peBasis: RetentionPEBasis
    let inputSource: RetentionWearInputSource
    let totalHostBytes: Double
    let remainingHostBytes: Double
    let limitingTotalDomain: EnduranceWearDomain
    let limitingRemainingDomain: EnduranceWearDomain
    let domains: [RetentionDomainHostEstimate]
    let intervalCounts: [EnduranceWearDomain: Int]
    let currentRateProjection: RetentionRateProjection
    let historicalRateProjection: RetentionRateProjection
    let notes: [String]
    var domainEvidence: [RetentionDomainEvidence] = []
}

struct EvidenceComponent: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let score: Int
    let weight: Double
    let note: String
}

struct EvidenceAssessment: Equatable, Sendable {
    let version: Int
    let observationScore: Int
    let wafScore: Int
    let thermalScore: Int
    let researchScore: Int
    let overallScore: Int
    let components: [EvidenceComponent]
    let notes: [String]
}

struct RetentionWearDomainRelationship: Equatable, Sendable {
    let tlcAverageCurrentPE: Double?
    let pslcAverageCurrentPE: Double?
    let tlcMaximumCurrentPE: Double?
    let pslcMaximumCurrentPE: Double?
    let tlcAverageWearFraction: Double?
    let pslcAverageWearFraction: Double?
    let pslcToTLCAverageWearRatio: Double?
    let tlcMaximumWearFraction: Double?
    let pslcMaximumWearFraction: Double?
    let pslcToTLCMaximumWearRatio: Double?
    let tlcAveragePEProgress: Double?
    let pslcAveragePEProgress: Double?
    let pslcToTLCAveragePEProgressRatio: Double?
    let averageProgressIntervalCount: Int
    let tlcMaximumPEProgress: Double?
    let pslcMaximumPEProgress: Double?
    let pslcToTLCMaximumPEProgressRatio: Double?
    let maximumProgressIntervalCount: Int
}

struct RetentionResearchEstimate: Equatable, Sendable {
    let profileID: String
    let profileVersion: Int
    let calculatedAt: Date
    let smartSnapshotID: UUID
    let smartCapturedAt: Date
    let ftlSnapshotID: UUID
    let ftlCapturedAt: Date
    let allowance: RetentionModelAllowance
    let tlcControllerEOLPE: Double
    let pslcControllerEOLPE: Double?
    let allowablePSLCPe: Double?
    let primaryPEBasis: RetentionPEBasis
    let primary: RetentionWearBasisEstimate
    let averagePEEstimate: RetentionWearBasisEstimate?
    let maximumPEEstimate: RetentionWearBasisEstimate?
    let domainPERelationship: RetentionWearDomainRelationship
    let unitState: ASPToolUnitState
    let notes: [String]
    var thermal: ThermalRetentionAssessment? = nil
    var waf: RetentionWAFAssessment? = nil
    var clientAllowance: RetentionModelAllowance? = nil
    var effectiveTLCPE: Double? = nil
    var clientEffectiveTLCPE: Double? = nil
    var clientTotalHostBytes: Double? = nil
    var clientRemainingHostBytes: Double? = nil
    var regularIntervalCount: Int = 0
    var provisionalIntervalCount: Int = 0
    /// Research ratio before the weak application weight is applied.
    var researchRetentionRatio: Double? = nil
    /// Backward-compatible name for the duration weight shown by older UI.
    var retentionResearchWeight: Double = 0.50
    var retentionDaysWeight: Double = 0.50
    var retentionEnvironmentWeight: Double = 0.20
    var retentionDaysSource: String = ""
    var observedLongestUnpoweredDays: Double? = nil
    var observedLongestUnpoweredStart: Date? = nil
    var observedLongestUnpoweredEnd: Date? = nil
    var retentionDaysRatio: Double? = nil
    var retentionEnvironmentRatio: Double? = nil
    var legacyEOLLimitedTLCPE: Double? = nil
    var legacyEOLLimitedClientPE: Double? = nil
    var clientDomains: [RetentionDomainHostEstimate] = []
    /// Main TBW model. Optional so old/incomplete histories can still load
    /// and show the underlying observations without inventing a capacity.
    var physicalModel: RetentionPhysicalTBWEstimate? = nil
    var hostPerPEDiagnostics: [RetentionHostPerPEDiagnostic] = []
    var evidence: EvidenceAssessment? = nil
}

enum RetentionResearchEstimateResult: Equatable, Sendable {
    case available(RetentionResearchEstimate)
    case unavailable(String)
}

private struct RetentionCapacitySelection: Equatable, Sendable {
    let bytes: Double
    let source: RetentionPhysicalCapacitySource
    let notes: [String]
}

struct RetentionResearchEstimator: Sendable {
    func estimate(
        latestSMART: DriveSnapshot?,
        latestDirectFTL: ASPToolDiagnosticsSnapshot?,
        wearHistory: ControllerWearHistorySummary,
        settings: UsageSettings,
        currentDailyWriteRate: Double?,
        historicalDailyWriteRate: Double?,
        now: Date,
        smartHistory: [DriveSnapshot] = [],
        temperatureHistory: [TemperatureSample] = [],
        ftlHistory: [ASPToolDiagnosticsSnapshot] = [],
        excluding: [DateInterval] = [],
        trials: [ProxyTrial] = [],
        provisionalHistory: ControllerWearHistorySummary? = nil,
        hardwareProfile: AppleNANDHardwareProfile? = nil,
        continuityLane suppliedLane: WearContinuityLane? = nil,
        observedStorageTemperature: IdleRetentionTemperature? = nil
    ) -> RetentionResearchEstimateResult {
        guard let smart = latestSMART,
              let ftl = latestDirectFTL,
              !smart.deviceID.isEmpty,
              ftl.deviceID == smart.deviceID,
              ftl.sourceArtifact == .directFTL,
              ftl.captureQuality == .explicit,
              ControllerWearSeriesIdentity(snapshot: ftl) == wearHistory.seriesIdentity else {
            return .unavailable("同一device・連続系列の最新SMART／Direct FTLが必要です")
        }
        let rejectedBoundaryAffectsCurrent = wearHistory.instrumentBoundaries.contains {
            $0.boundary.after <= ftl.capturedAt && !$0.continuity.isVerified
        }
        guard !rejectedBoundaryAffectsCurrent else {
            return .unavailable("最新Direct FTLは計測器境界の連続性検証待ちです")
        }
        guard let tlcEOL = finitePositive(ftl.tlcEOLPE) else {
            return .unavailable("TLC Controller EOL P/Eが取得できません")
        }
        guard let profile = selectedProfile(settings.retentionResearchProfileID) else {
            return .unavailable("保持参照モデルIDが不明です")
        }
        let daysObservation = RetentionModelEvaluator.observedRetentionDays(
            smartHistory: smartHistory.isEmpty ? [smart] : smartHistory,
            deviceID: smart.deviceID,
            now: now,
            excluding: excluding
        )
        // The required future OFF-retention condition is an input setting,
        // not an observed property of this Mac. Keep the longest observed
        // unpowered interval as diagnostics only; it must never silently
        // replace or annualize the requested retention requirement.
        let days = settings.retentionDays ?? 365
        let daysSource: String = settings.retentionDays.map {
            "利用者設定・必要保持条件 \(String(format: "%.1f", $0))日"
        } ?? "既定値・必要保持条件 365日"
        let rber = settings.retentionRBERThreshold ?? RetentionModelEvaluator.referenceECCLimit
        let activation = settings.retentionActivationEnergyEV ?? RetentionModelEvaluator.referenceActivationEnergyEV
        let clientWAF = settings.retentionClientWAF ?? 2.2
        guard clientWAF.isFinite, clientWAF > 0 else { return .unavailable("Client想定WAFは正の有限値が必要です") }
        let dailyWAFPrior = settings.retentionDailyWAFPrior ?? 2.2
        guard dailyWAFPrior.isFinite, dailyWAFPrior > 0 else { return .unavailable("日常WAF priorは正の有限値が必要です") }
        let daysWeightResolution = RetentionResearchWeightDefaults.daysWeight(from: settings)
        let daysWeight = daysWeightResolution.value
        let environmentWeight = RetentionResearchWeightDefaults.environmentWeight(from: settings)
        guard daysWeight.isFinite, (0...1).contains(daysWeight),
              environmentWeight.isFinite, (0...1).contains(environmentWeight) else {
            return .unavailable("保持日数重み・温度等の研究重みは0〜1の有限値が必要です")
        }
        let thermal = ThermalRetentionAnalyzer().assess(smartHistory: smartHistory.isEmpty ? [smart] : smartHistory,
            temperatureHistory: temperatureHistory, deviceID: smart.deviceID,
            storageTemperature: settings.effectiveRetentionStorageTemperatureCelsius, activationEnergy: activation,
            programCorrection: settings.retentionProgramCorrectionEnabled == true, now: now, excluding: excluding,
            ftlHistory: suppliedLane?.snapshots ?? ftlHistory,
            continuityLane: suppliedLane, observedStorage: observedStorageTemperature)
        let temperature = thermal.storageTemperature
        let allowance: RetentionModelAllowance
        switch RetentionModelEvaluator().evaluate(
            profile: profile,
            targetTemperatureCelsius: temperature,
            targetRetentionDays: days,
            rberThreshold: rber,
            activationEnergyEV: activation
        ) {
        case let .available(value): allowance = value
        case let .unavailable(reason): return .unavailable(reason)
        }

        let daysAllowance: RetentionModelAllowance
        switch RetentionModelEvaluator().evaluate(profile: profile, targetTemperatureCelsius: 30,
            targetRetentionDays: days, rberThreshold: rber, activationEnergyEV: activation) {
        case let .available(value): daysAllowance = value
        case let .unavailable(reason): return .unavailable("保持日数成分: \(reason)")
        }

        let slcEOL = finitePositive(ftl.slcEOLPE)
        let clientAllowance: RetentionModelAllowance
        switch RetentionModelEvaluator().evaluate(profile: profile, targetTemperatureCelsius: 30,
            targetRetentionDays: 365, rberThreshold: rber, activationEnergyEV: activation) {
        case let .available(value): clientAllowance = value
        case let .unavailable(reason): return .unavailable("Client参照条件: \(reason)")
        }
        let researchRatio = allowance.allowableTLCPE / clientAllowance.allowableTLCPE
        let daysRatio = daysAllowance.allowableTLCPE / clientAllowance.allowableTLCPE
        let environmentRatio = allowance.allowableTLCPE / daysAllowance.allowableTLCPE
        guard researchRatio.isFinite, researchRatio > 0,
              daysRatio.isFinite, daysRatio > 0,
              environmentRatio.isFinite, environmentRatio > 0 else {
            return .unavailable("保持研究モデルのClient比・保持日数比・温度等比を計算できません")
        }
        let retentionCorrection = pow(daysRatio, daysWeight) * pow(environmentRatio, environmentWeight)
        guard retentionCorrection.isFinite, retentionCorrection > 0 else {
            return .unavailable("保持補正が有限値になりません")
        }
        let effectiveTLCPE = tlcEOL * retentionCorrection * thermal.programFactor
        let clientPE = tlcEOL
        // Central v2.4 has no independent pSLC retention curve, so pSLC is
        // deliberately left at its retrieved Controller EOL. The old TLC
        // proportional transfer is retained only as a legacy diagnostic in
        // historical fields and is not used for the current estimate.
        let allowablePSLC = slcEOL
        var notes = allowance.assumptions
        notes.append("\(daysSource)。観測されたPower On Hours差分は診断用の実測OFF露出で、必要保持条件の代用にはしていません。")
        if daysWeightResolution.migratedLegacyDefault {
            notes.append("旧設定の研究重み0.20は、新しい保持日数重み0.50へ互換移行しました。")
        }
        notes.append("Controller EOLを絶対上限ではなく、Client条件の研究上の校正anchorとして使用しています。Appleの保持性能を確認した値ではありません。")
        notes.append("pSLCは独立保持曲線未取得のため中央推定では保持係数1.0（取得したpSLC Controller EOL）を使用します。旧TLC比例転用はlegacy診断です。")
        notes.append("保持補正は日数比 R日数 ^ \(String(format: "%.2f", daysWeight)) と温度等比 R環境 ^ \(String(format: "%.2f", environmentWeight)) に分離しました。RBER閾値は各比較で共通に保持しています。")
        if effectiveTLCPE > tlcEOL { notes.append("現在条件の研究補正はController EOLを超える仮定です。") }
        if abs(smart.capturedAt.distance(to: ftl.capturedAt)) > 60 {
            notes.append("SMARTとDirect FTLの取得時刻差が60秒を超えています。")
        }
        if ftl.hostWritesUnitState != .verified {
            notes.append("FTL Hostカウンタ単位は暫定です。P/EあたりHost書込量も暫定単位に依存します。")
        }
        if ftl.firmwareEpoch == nil || ftl.sourceBuild == nil || smart.firmware == nil {
            notes.append("系列情報に不足があります。取得元の同一性を完全には検証できません。")
        }
        if smart.logicalCapacityBytes == nil {
            notes.append("論理容量は保持推定式に使いませんが、SSD全体の適用範囲は未確認です。")
        }

        let dailyRate = usableRate(currentDailyWriteRate)
        let historicalRate = usableRate(historicalDailyWriteRate)
        let average = buildWearEstimate(
            basis: .average,
            ftl: ftl,
            lifetimeHostWritesBytes: smart.dataUnitsWrittenBytes,
            wearHistory: wearHistory,
            allowance: effectiveTLCPE,
            tlcEOL: tlcEOL,
            pslcEOL: slcEOL,
            allowablePSLC: allowablePSLC,
            dailyRate: dailyRate,
            historicalRate: historicalRate,
            now: now,
            provisionalHistory: provisionalHistory,
            manualTLCBytesPerPE: settings.retentionTLCBytesPerPEPrior,
            manualPSLCBytesPerPE: settings.retentionPSLCBytesPerPEPrior
        )
        let maximum = buildWearEstimate(
            basis: .maximum,
            ftl: ftl,
            lifetimeHostWritesBytes: smart.dataUnitsWrittenBytes,
            wearHistory: wearHistory,
            allowance: effectiveTLCPE,
            tlcEOL: tlcEOL,
            pslcEOL: slcEOL,
            allowablePSLC: allowablePSLC,
            dailyRate: dailyRate,
            historicalRate: historicalRate,
            now: now,
            provisionalHistory: provisionalHistory,
            manualTLCBytesPerPE: settings.retentionTLCBytesPerPEPrior,
            manualPSLCBytesPerPE: settings.retentionPSLCBytesPerPEPrior
        )
        let rawWAFHistory = ftlHistory
            .filter { $0.sourceArtifact.participatesInCoreWearLane && $0.deviceID == ftl.deviceID && $0.capturedAt <= ftl.capturedAt }
            .sorted { $0.capturedAt < $1.capturedAt }
        let wafLane: WearContinuityLane? = suppliedLane ?? {
            guard !rawWAFHistory.isEmpty else { return nil }
            return WearContinuityLaneBuilder.build(
                snapshots: rawWAFHistory,
                smart: smartHistory,
                latest: ftl
            )
        }()
        let wafSnapshots = wafLane?.snapshots ?? rawWAFHistory
        let wafLatest = wafSnapshots.last ?? ftl
        let wafExcluding = excluding + (wafLane?.rateLearningExclusions ?? [])
        let waf = RetentionWAFAnalyzer().assess(snapshots: wafSnapshots, latest: wafLatest, now: now,
            excluding: wafExcluding, client: clientWAF, prior: dailyWAFPrior,
            selection: settings.retentionClientWAFSelection, trials: trials,
            continuityLane: wafLane)
        var primaryBasis: RetentionPEBasis
        let primary: RetentionWearBasisEstimate
        let physicalModel: RetentionPhysicalTBWEstimate?
        if let selected = maximum ?? average {
            primary = selected
            primaryBasis = maximum == nil ? .average : .maximum
            physicalModel = makePhysicalTBWEstimate(
                smart: smart,
                ftl: ftl,
                hardwareProfile: hardwareProfile,
                clientPE: clientPE,
                currentPE: effectiveTLCPE,
                primaryPEBasis: primaryBasis,
                primary: selected,
                clientWAF: waf.client,
                currentWAF: waf.current,
                dailyRate: dailyRate,
                historicalRate: historicalRate,
                now: now
            )
        } else {
            guard let currentTLCPE = (ftl.tlcMaximumPE ?? ftl.tlcAveragePE).flatMap(finiteNonnegative),
                  let physical = makePhysicalTBWEstimate(
                      smart: smart,
                      ftl: ftl,
                      hardwareProfile: hardwareProfile,
                      clientPE: clientPE,
                      currentPE: effectiveTLCPE,
                      primaryPEBasis: ftl.tlcMaximumPE != nil ? .maximum : .average,
                      primary: nil,
                      clientWAF: waf.client,
                      currentWAF: waf.current,
                      dailyRate: dailyRate,
                      historicalRate: historicalRate,
                      now: now
                  ) else {
                if smart.dataUnitsWrittenBytes == nil {
                    return .unavailable("損耗傾き・容量・SMART Data Units Writtenのいずれも不足しているため暫定換算できません")
                }
                return .unavailable("現在P/EまたはController EOLが不足しているため保持推定を換算できません")
            }
            primaryBasis = ftl.tlcMaximumPE != nil ? .maximum : .average
            primary = capacityOnlyWearBasis(
                basis: primaryBasis,
                ftl: ftl,
                allowableTLCPE: effectiveTLCPE,
                allowablePSLC: allowablePSLC,
                currentTLCPE: currentTLCPE
            )
            physicalModel = physical
            notes.append("Host/P/E損耗傾きが不足しているため、容量・現在P/E・WAFのみの暫定主値を表示しています。傾き取得後に診断欄を更新します。")
        }
        if maximum == nil, average != nil {
            notes.append("最大P/E基準の必要値が不足しているため、平均P/E基準を主表示にしています。")
        }
        if primary.domains.count < 2, primary.inputSource != .capacityOnly {
            notes.append("片側domainのみの部分推計です。欠けたdomainを含むSSD全体の限界ではありません。")
        }
        let scale = waf.current / waf.client
        let clientDomains = primary.domains.map { domain -> RetentionDomainHostEstimate in
            let slope = domain.hostBytesPerPE * scale
            return RetentionDomainHostEstimate(
                domain: domain.domain,
                currentPE: domain.currentPE,
                controllerEOLPE: domain.controllerEOLPE,
                allowablePE: domain.controllerEOLPE,
                hostBytesPerPE: slope,
                observedIntervals: domain.observedIntervals,
                totalHostBytes: domain.controllerEOLPE * slope,
                remainingHostBytes: max(0, domain.controllerEOLPE - domain.currentPE) * slope,
                inputSource: domain.inputSource,
                observationScore: domain.observationScore
            )
        }
        let clientTotal = clientDomains.map(\.totalHostBytes).min()
        let clientRemaining = clientDomains.map(\.remainingHostBytes).min()
        if !clientDomains.isEmpty {
            guard clientTotal?.isFinite == true, clientRemaining?.isFinite == true else {
                return .unavailable("Client換算が数値範囲を超えました")
            }
        } else {
            notes.append("Host/P/E domain入力が未取得のため、domain別線形診断は未算出です。容量モデルの主値は独立して表示します。")
        }
        notes += waf.notes
        notes.append("Client条件は30°C・365日、Client想定WAFによる研究推計です。Client値は現在の保管温度・保持日数から独立しています。")
        if physicalModel == nil {
            notes.append("実効NAND容量が取得できないため、物理容量ベースの主TBWは未算出です。Host/P/E線形換算は診断値としてのみ保持します。")
        } else {
            notes.append("主TBWはTLCを主容量とする物理容量 × 補正P/E ÷ WAFで算出し、pSLC容量は二重計上していません。")
        }
        let hostPerPEDiagnostics = makeHostPerPEDiagnostics(
            primary: primary,
            wearHistory: wearHistory,
            provisionalHistory: provisionalHistory,
            effectiveCapacityBytes: physicalModel?.effectiveNANDCapacityBytes,
            currentWAF: waf.current
        )
        let observationScore = primary.domainEvidence.map(\.observationScore).min()
            ?? primary.domains.map(\.observationScore).min() ?? 0
        let researchScore = 20
        let overallScore = weightedEvidenceScore(
            observation: observationScore,
            waf: waf.confidenceScore,
            thermal: thermal.storageEvidenceScore,
            research: researchScore
        )
        let evidence = EvidenceAssessment(
            version: 1,
            observationScore: observationScore,
            wafScore: waf.confidenceScore,
            thermalScore: thermal.storageEvidenceScore,
            researchScore: researchScore,
            overallScore: overallScore,
            components: [
                EvidenceComponent(id: "observation", title: "domain損耗観測充実度", score: observationScore, weight: 0.40,
                    note: "観測日数・Host差分・P/E進行の最小値"),
                EvidenceComponent(id: "waf", title: "WAF観測充実度", score: waf.confidenceScore, weight: 0.25,
                    note: "priorと観測WAFの混合重み"),
                EvidenceComponent(id: "thermal", title: "温度推定の根拠", score: thermal.storageEvidenceScore, weight: 0.20,
                    note: thermal.storageSource),
                EvidenceComponent(id: "research", title: "研究モデル適合度", score: researchScore, weight: 0.15,
                    note: "参照NAND転用・長期外挿・pSLC保持曲線未取得")
            ],
            notes: ["スコアは予測誤差・保証確率ではなく、入力と仮定の根拠を示す研究用指標です。"]
        )
        let legacyTLCPE = min(allowance.allowableTLCPE * thermal.programFactor, tlcEOL)
        let legacyClientPE = min(clientAllowance.allowableTLCPE, tlcEOL)
        var result = RetentionResearchEstimate(
            profileID: profile.id,
            profileVersion: profile.version,
            calculatedAt: now,
            smartSnapshotID: smart.id,
            smartCapturedAt: smart.capturedAt,
            ftlSnapshotID: ftl.id,
            ftlCapturedAt: ftl.capturedAt,
            allowance: allowance,
            tlcControllerEOLPE: tlcEOL,
            pslcControllerEOLPE: slcEOL,
            allowablePSLCPe: allowablePSLC,
            primaryPEBasis: primaryBasis,
            primary: primary,
            averagePEEstimate: average,
            maximumPEEstimate: maximum,
            domainPERelationship: domainRelationship(ftl: ftl, history: wearHistory),
            unitState: ftl.hostWritesUnitState,
            notes: Array(Set(notes)).sorted()
        )
        result.thermal = thermal
        result.waf = waf
        result.clientAllowance = clientAllowance
        result.effectiveTLCPE = effectiveTLCPE
        result.clientEffectiveTLCPE = clientPE
        result.clientTotalHostBytes = physicalModel?.clientTotalHostBytes
        result.clientRemainingHostBytes = physicalModel?.clientRemainingHostBytes
        result.regularIntervalCount = wearHistory.intervalCount
        result.provisionalIntervalCount = provisionalHistory?.intervalCount ?? 0
        result.researchRetentionRatio = researchRatio
        result.retentionResearchWeight = daysWeight
        result.retentionDaysWeight = daysWeight
        result.retentionEnvironmentWeight = environmentWeight
        result.retentionDaysSource = daysSource
        result.observedLongestUnpoweredDays = daysObservation.longest?.durationDays
        result.observedLongestUnpoweredStart = daysObservation.longest?.start
        result.observedLongestUnpoweredEnd = daysObservation.longest?.end
        result.retentionDaysRatio = daysRatio
        result.retentionEnvironmentRatio = environmentRatio
        result.legacyEOLLimitedTLCPE = legacyTLCPE
        result.legacyEOLLimitedClientPE = legacyClientPE
        result.clientDomains = clientDomains
        result.physicalModel = physicalModel
        result.hostPerPEDiagnostics = hostPerPEDiagnostics
        result.evidence = evidence
        return .available(result)
    }

    private func makePhysicalTBWEstimate(
        smart: DriveSnapshot,
        ftl: ASPToolDiagnosticsSnapshot,
        hardwareProfile: AppleNANDHardwareProfile?,
        clientPE: Double,
        currentPE: Double,
        primaryPEBasis: RetentionPEBasis,
        primary: RetentionWearBasisEstimate?,
        clientWAF: Double,
        currentWAF: Double,
        dailyRate: Double?,
        historicalRate: Double?,
        now: Date
    ) -> RetentionPhysicalTBWEstimate? {
        guard let capacity = effectiveNANDCapacity(smart: smart, hardwareProfile: hardwareProfile),
              let clientPE = finitePositive(clientPE),
              let currentPE = finitePositive(currentPE),
              let clientWAF = finitePositive(clientWAF),
              let currentWAF = finitePositive(currentWAF) else {
            return nil
        }

        let currentTLCPE = primary?.domains.first(where: { $0.domain == .tlc })?.currentPE
            ?? (primaryPEBasis == .average ? ftl.tlcAveragePE : ftl.tlcMaximumPE).flatMap(finiteNonnegative)
        let clientRemaining = currentTLCPE.map { max(0, clientPE - $0) * capacity.bytes / clientWAF }
        let currentRemaining = currentTLCPE.map { max(0, currentPE - $0) * capacity.bytes / currentWAF }
        guard clientRemaining?.isFinite != false, currentRemaining?.isFinite != false else { return nil }

        // Both totals use the same scenario convention as the dashboard:
        // observed lifetime Host Writes + future Host Writes converted from
        // the remaining physical NAND budget. They are not fresh-device
        // counterfactuals and must not be compared as if the past had used
        // the Client WAF.
        let currentHost = finiteNonnegative(smart.dataUnitsWrittenBytes)
            ?? finiteNonnegative(ftl.hostWrittenBytes)
        let clientTotal = currentHost.map { $0 + (clientRemaining ?? 0) }
            ?? capacity.bytes * clientPE / clientWAF
        let currentTotal = currentHost.map { $0 + (currentRemaining ?? 0) }
            ?? capacity.bytes * currentPE / currentWAF
        guard clientTotal.isFinite, clientTotal > 0,
              currentTotal.isFinite, currentTotal > 0 else { return nil }

        var notes = capacity.notes
        notes.append("TLCを主データ領域として換算し、pSLCを独立NAND容量として加算していません。pSLC P/Eは内部負荷・損耗バランスの診断値です。")
        notes.append("Host/P/Eの短区間線形外挿は主TBWへ使わず、Raw／Physical prior／BlendとしてAdvancedへ表示します。")
        if currentHost == nil {
            notes.append("累積Host Writesが取得できないため、総量のみ、現在P/Eからのfresh-device換算を暫定表示しています。")
        }
        if currentPE > (finitePositive(ftl.tlcEOLPE) ?? currentPE) {
            notes.append("現在条件の補正P/EはController EOLを超える研究上の仮定です。")
        }
        let currentProjection = currentRemaining.map { projection(remaining: $0, rate: dailyRate, now: now) }
            ?? RetentionRateProjection(date: nil, years: nil, reached: false)
        let historicalProjection = currentRemaining.map { projection(remaining: $0, rate: historicalRate, now: now) }
            ?? RetentionRateProjection(date: nil, years: nil, reached: false)

        return RetentionPhysicalTBWEstimate(
            effectiveNANDCapacityBytes: capacity.bytes,
            capacitySource: capacity.source,
            capacityIsProvisional: true,
            clientWAF: clientWAF,
            currentWAF: currentWAF,
            clientCorrectedPE: clientPE,
            currentCorrectedPE: currentPE,
            currentTLCPE: currentTLCPE,
            clientTotalHostBytes: clientTotal,
            clientRemainingHostBytes: clientRemaining,
            currentTotalHostBytes: currentTotal,
            currentRemainingHostBytes: currentRemaining,
            currentRateProjection: currentProjection,
            historicalRateProjection: historicalProjection,
            notes: Array(Set(notes)).sorted()
        )
    }

    private func capacityOnlyWearBasis(
        basis: RetentionPEBasis,
        ftl: ASPToolDiagnosticsSnapshot,
        allowableTLCPE: Double,
        allowablePSLC: Double?,
        currentTLCPE: Double
    ) -> RetentionWearBasisEstimate {
        let currentPSLCPE = (basis == .average ? ftl.slcAveragePE : ftl.slcMaximumPE).flatMap(finiteNonnegative)
        let evidence = [
            RetentionDomainEvidence(
                domain: .tlc,
                currentPE: currentTLCPE,
                controllerEOLPE: finitePositive(ftl.tlcEOLPE),
                allowablePE: finitePositive(allowableTLCPE),
                hostBytesPerPE: nil,
                inputSource: nil,
                observedIntervals: 0,
                observationScore: 0,
                totalHostBytes: nil,
                remainingHostBytes: nil,
                reason: "Host/P/E傾き未取得。容量モデルの主値のみを暫定表示しています"
            ),
            RetentionDomainEvidence(
                domain: .pSLC,
                currentPE: currentPSLCPE,
                controllerEOLPE: finitePositive(ftl.slcEOLPE),
                allowablePE: allowablePSLC.flatMap(finitePositive),
                hostBytesPerPE: nil,
                inputSource: nil,
                observedIntervals: 0,
                observationScore: 0,
                totalHostBytes: nil,
                remainingHostBytes: nil,
                reason: "pSLCは主TBW容量へ加算せず、Host/P/E傾きが取得できた場合のみ診断します"
            )
        ]
        return RetentionWearBasisEstimate(
            peBasis: basis,
            inputSource: .capacityOnly,
            totalHostBytes: 0,
            remainingHostBytes: 0,
            limitingTotalDomain: .tlc,
            limitingRemainingDomain: .tlc,
            domains: [],
            intervalCounts: [:],
            currentRateProjection: RetentionRateProjection(date: nil, years: nil, reached: false),
            historicalRateProjection: RetentionRateProjection(date: nil, years: nil, reached: false),
            notes: ["Host/P/Eの観測傾きが不足しているため、容量・P/E・WAFのみで主値を算出しています。"],
            domainEvidence: evidence
        )
    }

    private func effectiveNANDCapacity(
        smart: DriveSnapshot,
        hardwareProfile: AppleNANDHardwareProfile?
    ) -> RetentionCapacitySelection? {
        let smartLogical = smart.logicalCapacityBytes.flatMap { $0 > 0 ? Double($0) : nil }
        let profileLogical = hardwareProfile.map(\.logicalCapacityBytes).flatMap { $0 > 0 ? Double($0) : nil }
        let logical = smartLogical ?? profileLogical

        if let geometry = hardwareProfile?.geometryCapacityBytes,
           hardwareProfile?.geometryConfidence == .consistent,
           geometry > 0,
           let geometryBytes = Double(exactly: geometry),
           geometryBytes.isFinite,
           geometryBytes > 0,
           (logical == nil || geometryBytes >= logical!) {
            return RetentionCapacitySelection(
                bytes: geometryBytes,
                source: .geometryResearchProxy,
                notes: [
                    "実効NAND容量は整合したIORegistry geometryからの研究proxyです。Appleの予約領域・容量割当の確認済み値ではありません。",
                    "geometryは一般の容量・寿命モデルでは診断情報として扱い、今回のみTBW研究proxyの入力に限定しています。"
                ]
            )
        }

        guard let logical, logical.isFinite, logical > 0 else { return nil }
        var notes = [
            "実効NAND容量はSMARTの論理容量から置いた研究proxyです。物理予約領域を含む実効値ではありません。"
        ]
        if hardwareProfile?.geometryCapacityBytes != nil {
            notes.append("geometryは未整合または論理容量未満のため、主TBW容量へ採用していません。")
        }
        return RetentionCapacitySelection(bytes: logical, source: .logicalCapacityProxy, notes: notes)
    }

    private func makeHostPerPEDiagnostics(
        primary: RetentionWearBasisEstimate,
        wearHistory: ControllerWearHistorySummary,
        provisionalHistory: ControllerWearHistorySummary?,
        effectiveCapacityBytes: Double?,
        currentWAF: Double
    ) -> [RetentionHostPerPEDiagnostic] {
        let prior: Double? = effectiveCapacityBytes.flatMap { capacity in
            guard capacity.isFinite, capacity > 0, currentWAF.isFinite, currentWAF > 0 else { return nil }
            let value = capacity / currentWAF
            return value.isFinite && value > 0 ? value : nil
        }
        return primary.domainEvidence.map { evidence in
            let observed: Double? = {
                guard evidence.inputSource == .dailyHistory || evidence.inputSource == .limitedDailyHistory else {
                    return nil
                }
                let regular: Double?
                let provisional: Double?
                switch (evidence.domain, primary.peBasis) {
                case (.tlc, .average):
                    regular = wearHistory.tlcHostBytesPerPE
                    provisional = provisionalHistory?.tlcHostBytesPerPE
                case (.pSLC, .average):
                    regular = wearHistory.slcHostBytesPerPE
                    provisional = provisionalHistory?.slcHostBytesPerPE
                case (.tlc, .maximum):
                    regular = wearHistory.tlcHostBytesPerMaximumPE
                    provisional = provisionalHistory?.tlcHostBytesPerMaximumPE
                case (.pSLC, .maximum):
                    regular = wearHistory.slcHostBytesPerMaximumPE
                    provisional = provisionalHistory?.slcHostBytesPerMaximumPE
                }
                let value = evidence.inputSource == .dailyHistory ? regular : (regular ?? provisional)
                guard let value, value.isFinite, value > 0 else { return nil }
                return value
            }()
            let score = max(0, min(100, evidence.observationScore))
            let weight = observed == nil ? 0 : Double(score) / 100
            let blended: Double? = {
                guard let prior, let observed, prior > 0, observed > 0 else { return prior }
                let value = exp((1 - weight) * log(prior) + weight * log(observed))
                return value.isFinite && value > 0 ? value : nil
            }()
            let note: String? = observed == nil
                ? "P/E区間観測がなく、線形診断のRaw値は未取得です。"
                : "q=\(String(format: "%.3f", weight))。このBlendは主TBWの中心値には使いません。"
            return RetentionHostPerPEDiagnostic(
                domain: evidence.domain,
                observedHostBytesPerPE: observed,
                priorHostBytesPerPE: prior,
                blendedHostBytesPerPE: blended,
                observationWeight: weight,
                observationScore: score,
                observedIntervals: evidence.observedIntervals,
                inputSource: evidence.inputSource,
                note: note
            )
        }
    }

    private func weightedEvidenceScore(observation: Int, waf: Int, thermal: Int, research: Int) -> Int {
        let values = [Double(max(0, observation)), Double(max(0, waf)), Double(max(0, thermal)), Double(max(0, research))]
        let weights = [0.40, 0.25, 0.20, 0.15]
        guard values.allSatisfy({ $0.isFinite }) else { return 0 }
        if values.contains(where: { $0 == 0 }) { return 0 }
        let score = zip(values, weights).reduce(0.0) { $0 + $1.1 * log($1.0) }
        return Int(min(100, max(0, exp(score))).rounded())
    }

    private func buildWearEstimate(
        basis: RetentionPEBasis,
        ftl: ASPToolDiagnosticsSnapshot,
        lifetimeHostWritesBytes: Double?,
        wearHistory: ControllerWearHistorySummary,
        allowance: Double,
        tlcEOL: Double,
        pslcEOL: Double?,
        allowablePSLC: Double?,
        dailyRate: Double?,
        historicalRate: Double?,
        now: Date,
        provisionalHistory: ControllerWearHistorySummary? = nil,
        manualTLCBytesPerPE: Double? = nil,
        manualPSLCBytesPerPE: Double? = nil
    ) -> RetentionWearBasisEstimate? {
        guard allowance.isFinite, allowance >= 0 else { return nil }
        let specifications: [(domain: EnduranceWearDomain, currentPE: Double?, eol: Double?, regularSlope: Double?, regularCount: Int, provisionalSlope: Double?, provisionalCount: Int, manualSlope: Double?)] = [
            (
                .tlc,
                basis == .average ? ftl.tlcAveragePE : ftl.tlcMaximumPE,
                tlcEOL,
                basis == .average ? wearHistory.tlcHostBytesPerPE : wearHistory.tlcHostBytesPerMaximumPE,
                basis == .average ? wearHistory.tlcIntervalCount : wearHistory.tlcMaximumIntervalCount,
                basis == .average ? provisionalHistory?.tlcHostBytesPerPE : provisionalHistory?.tlcHostBytesPerMaximumPE,
                basis == .average ? provisionalHistory?.tlcIntervalCount ?? 0 : provisionalHistory?.tlcMaximumIntervalCount ?? 0,
                manualTLCBytesPerPE
            ),
            (
                .pSLC,
                basis == .average ? ftl.slcAveragePE : ftl.slcMaximumPE,
                pslcEOL,
                basis == .average ? wearHistory.slcHostBytesPerPE : wearHistory.slcHostBytesPerMaximumPE,
                basis == .average ? wearHistory.slcIntervalCount : wearHistory.slcMaximumIntervalCount,
                basis == .average ? provisionalHistory?.slcHostBytesPerPE : provisionalHistory?.slcHostBytesPerMaximumPE,
                basis == .average ? provisionalHistory?.slcIntervalCount ?? 0 : provisionalHistory?.slcMaximumIntervalCount ?? 0,
                manualPSLCBytesPerPE
            )
        ]
        let lifetimeHost = finitePositive(lifetimeHostWritesBytes)
        var estimates: [RetentionDomainHostEstimate] = []
        var evidence: [RetentionDomainEvidence] = []
        var intervalCounts: [EnduranceWearDomain: Int] = [:]
        var notes: [String] = []
        var sources: [RetentionWearInputSource] = []

        for spec in specifications {
            let target: Double? = spec.domain == .tlc ? finiteNonnegative(allowance) : finiteNonnegative(allowablePSLC)
            guard let currentPE = finiteNonnegative(spec.currentPE), let eol = finitePositive(spec.eol), let target else {
                evidence.append(RetentionDomainEvidence(domain: spec.domain, currentPE: finiteNonnegative(spec.currentPE),
                    controllerEOLPE: finitePositive(spec.eol), allowablePE: target, hostBytesPerPE: nil,
                    inputSource: nil, observedIntervals: 0, observationScore: 0, totalHostBytes: nil,
                    remainingHostBytes: nil, reason: spec.domain == .pSLC ? "pSLCのP/EまたはController EOLが未取得です" : "TLCのP/EまたはController EOLが未取得です"))
                continue
            }
            let choice: (slope: Double?, source: RetentionWearInputSource?, count: Int, reason: String?)
            if spec.regularCount >= 2, let slope = finitePositive(spec.regularSlope) {
                choice = (slope, .dailyHistory, spec.regularCount, nil)
            } else if spec.regularCount == 1, let slope = finitePositive(spec.regularSlope) {
                choice = (slope, .limitedDailyHistory, 1, "同一系列の通常区間が1本のみのため暫定換算です")
            } else if spec.provisionalCount >= 1, let slope = finitePositive(spec.provisionalSlope) {
                choice = (slope, .limitedDailyHistory, spec.provisionalCount, "同一系列の暫定区間を採用しています")
            } else if let lifetimeHost, currentPE > 0 {
                choice = (lifetimeHost / currentPE, .lifetimeAverage, 0, "生涯Host Writesを当該domainの現在P/Eで按分しています")
            } else if let slope = finitePositive(spec.manualSlope) {
                choice = (slope, .manualPrior, 0, "利用者が設定した研究用Host bytes/P/E仮定です")
            } else {
                choice = (nil, nil, 0, "Host bytes/P/Eを計算できる入力がありません")
            }
            let score = domainObservationScore(source: choice.source, history: wearHistory, domain: spec.domain, basis: basis)
            evidence.append(RetentionDomainEvidence(domain: spec.domain, currentPE: currentPE, controllerEOLPE: eol,
                allowablePE: target, hostBytesPerPE: choice.slope, inputSource: choice.source,
                observedIntervals: choice.count, observationScore: score, totalHostBytes: choice.slope.map { target * $0 },
                remainingHostBytes: choice.slope.map { max(0, target - currentPE) * $0 }, reason: choice.reason))
            guard let perPE = choice.slope else { continue }
            let total = target * perPE
            let remaining = max(0, target - currentPE) * perPE
            guard total.isFinite, remaining.isFinite, total >= 0, remaining >= 0 else { continue }
            let selectedSource = choice.source ?? .mixed
            sources.append(selectedSource)
            intervalCounts[spec.domain] = choice.count
            estimates.append(RetentionDomainHostEstimate(domain: spec.domain, currentPE: currentPE,
                controllerEOLPE: eol, allowablePE: target, hostBytesPerPE: perPE,
                observedIntervals: choice.count, totalHostBytes: total, remainingHostBytes: remaining,
                inputSource: selectedSource, observationScore: score))
            if target > eol { notes.append("\(spec.domain.rawValue)の現在条件許容P/EはController EOLを超える研究上の仮定です。") }
            if let reason = choice.reason { notes.append("\(spec.domain.rawValue): \(reason)") }
        }
        guard !estimates.isEmpty else { return nil }
        let inputSource: RetentionWearInputSource
        let uniqueSources = Set(sources)
        if uniqueSources.count == 1 { inputSource = uniqueSources.first! } else { inputSource = .mixed }
        if inputSource == .limitedDailyHistory { notes.append("日常損耗履歴が少ないため暫定表示です。") }
        if inputSource == .lifetimeAverage { notes.append("日常損耗の有効区間がなく、生涯Host Writesをdomain別現在P/Eで按分した暫定表示です。") }
        if inputSource == .mixed { notes.append("TLC／pSLCはそれぞれ最も新しい利用可能な入力源を選択しています。") }
        if estimates.count < specifications.count { notes.append("片側domainまたは一部入力の部分推計です。") }
        let totalLimiter = estimates.min { $0.totalHostBytes < $1.totalHostBytes }!
        let remainingLimiter = estimates.min { $0.remainingHostBytes < $1.remainingHostBytes }!
        return RetentionWearBasisEstimate(
            peBasis: basis,
            inputSource: inputSource,
            totalHostBytes: totalLimiter.totalHostBytes,
            remainingHostBytes: remainingLimiter.remainingHostBytes,
            limitingTotalDomain: totalLimiter.domain,
            limitingRemainingDomain: remainingLimiter.domain,
            domains: estimates,
            intervalCounts: intervalCounts,
            currentRateProjection: projection(remaining: remainingLimiter.remainingHostBytes, rate: dailyRate, now: now),
            historicalRateProjection: projection(remaining: remainingLimiter.remainingHostBytes, rate: historicalRate, now: now),
            notes: Array(Set(notes)).sorted(),
            domainEvidence: evidence
        )
    }

    private func domainObservationScore(
        source: RetentionWearInputSource?,
        history: ControllerWearHistorySummary,
        domain: EnduranceWearDomain,
        basis: RetentionPEBasis
    ) -> Int {
        guard let source else { return 0 }
        switch source {
        case .dailyHistory:
            let progress: Double = {
                switch (domain, basis) {
                case (.tlc, .average): return history.tlcPEProgress ?? 0
                case (.pSLC, .average): return history.slcPEProgress ?? 0
                case (.tlc, .maximum): return history.tlcMaximumPEProgress ?? 0
                case (.pSLC, .maximum): return history.slcMaximumPEProgress ?? 0
                }
            }()
            let dayFactor = min(1, max(0, history.observationDays / 30))
            let hostFactor = min(1, max(0, history.hostBytesObserved / 1e12))
            let peFactor = min(1, max(0, progress / 1))
            return Int((min(dayFactor, min(hostFactor, peFactor)) * 100).rounded())
        case .limitedDailyHistory:
            return 25
        case .lifetimeAverage:
            return 10
        case .manualPrior:
            return 0
        case .capacityOnly:
            return 0
        case .mixed:
            return 0
        }
    }

    private func projection(remaining: Double, rate: Double?, now: Date) -> RetentionRateProjection {
        guard remaining.isFinite, remaining >= 0 else { return RetentionRateProjection(date: nil, years: nil, reached: false) }
        if remaining == 0 { return RetentionRateProjection(date: now, years: 0, reached: true) }
        guard let rate = usableRate(rate) else { return RetentionRateProjection(date: nil, years: nil, reached: false) }
        let days = remaining / rate
        let years = days / 365.25
        let seconds = days * 86_400
        let timestamp = now.timeIntervalSinceReferenceDate + seconds
        let date = timestamp.isFinite && timestamp < 252_423_993_599
            ? Date(timeIntervalSinceReferenceDate: timestamp)
            : nil
        return RetentionRateProjection(date: date, years: years.isFinite ? years : nil, reached: false)
    }

    private func domainRelationship(
        ftl: ASPToolDiagnosticsSnapshot,
        history: ControllerWearHistorySummary
    ) -> RetentionWearDomainRelationship {
        let tlcEOL = finitePositive(ftl.tlcEOLPE)
        let pslcEOL = finitePositive(ftl.slcEOLPE)
        let tlcAverage = finiteNonnegative(ftl.tlcAveragePE)
        let pslcAverage = finiteNonnegative(ftl.slcAveragePE)
        let tlcMaximum = finiteNonnegative(ftl.tlcMaximumPE)
        let pslcMaximum = finiteNonnegative(ftl.slcMaximumPE)
        let tlcAverageFraction = ratio(tlcAverage, tlcEOL)
        let pslcAverageFraction = ratio(pslcAverage, pslcEOL)
        let tlcMaximumFraction = ratio(tlcMaximum, tlcEOL)
        let pslcMaximumFraction = ratio(pslcMaximum, pslcEOL)
        return RetentionWearDomainRelationship(
            tlcAverageCurrentPE: tlcAverage,
            pslcAverageCurrentPE: pslcAverage,
            tlcMaximumCurrentPE: tlcMaximum,
            pslcMaximumCurrentPE: pslcMaximum,
            tlcAverageWearFraction: tlcAverageFraction,
            pslcAverageWearFraction: pslcAverageFraction,
            pslcToTLCAverageWearRatio: ratio(pslcAverageFraction, tlcAverageFraction),
            tlcMaximumWearFraction: tlcMaximumFraction,
            pslcMaximumWearFraction: pslcMaximumFraction,
            pslcToTLCMaximumWearRatio: ratio(pslcMaximumFraction, tlcMaximumFraction),
            tlcAveragePEProgress: history.coupledTlcAveragePEProgress,
            pslcAveragePEProgress: history.coupledSlcAveragePEProgress,
            pslcToTLCAveragePEProgressRatio: ratio(history.coupledSlcAveragePEProgress, history.coupledTlcAveragePEProgress),
            averageProgressIntervalCount: history.coupledAverageIntervalCount,
            tlcMaximumPEProgress: history.coupledTlcMaximumPEProgress,
            pslcMaximumPEProgress: history.coupledSlcMaximumPEProgress,
            pslcToTLCMaximumPEProgressRatio: ratio(history.coupledSlcMaximumPEProgress, history.coupledTlcMaximumPEProgress),
            maximumProgressIntervalCount: history.coupledMaximumIntervalCount
        )
    }

    private func ratio(_ numerator: Double?, _ denominator: Double?) -> Double? {
        guard let numerator = finiteNonnegative(numerator),
              let denominator = finitePositive(denominator) else { return nil }
        let value = numerator / denominator
        return value.isFinite ? value : nil
    }

    private func selectedProfile(_ id: String?) -> RetentionResearchProfile? {
        let profiles = [RetentionResearchProfile.luo2018]
        guard let id else { return RetentionResearchProfile.luo2018 }
        return profiles.first { $0.id == id }
    }

    private func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func usableRate(_ value: Double?) -> Double? {
        finitePositive(value)
    }
}
