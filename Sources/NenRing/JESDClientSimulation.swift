import Foundation

/// A published or experimentally fitted NAND reference point that has already
/// been reduced to a P/E envelope satisfying the selected retention criterion.
/// The app never infers such an envelope from Controller EOL by itself.
struct RetentionReferenceProfile: Equatable, Sendable, Identifiable {
    let id: String
    let version: Int
    let modelName: String
    let nandVendor: String?
    let nandFamily: String?
    let bitsPerCell: Int?
    let powerOff: Bool
    let retentionTemperatureCelsius: Double
    let retentionDays: Double
    let peAllowanceByDomain: [EnduranceWearDomain: PELimitRange]
    let acceptanceCriterion: String
    let fitDescription: String
    let sourceTitle: String
    let sourceURL: String
    let sourceDetails: String
    let assumptions: [String]
    let applicability: RetentionProfileApplicability

    var isNumericallyUsable: Bool {
        version > 0 &&
            !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            retentionTemperatureCelsius.isFinite && retentionTemperatureCelsius >= 0 && retentionTemperatureCelsius <= 100 &&
            retentionDays.isFinite && retentionDays > 0 &&
            !acceptanceCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !fitDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !sourceDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            assumptions.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) &&
            !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            sourceURL.isHTTPURL &&
            !peAllowanceByDomain.isEmpty &&
            peAllowanceByDomain.values.allSatisfy(\.isValid)
    }
}

enum RetentionProfileApplicability: String, Equatable, Sendable {
    case matchingNAND
    case relatedNANDScenario
}

struct PELimitRange: Equatable, Sendable {
    let lower: Double
    let upper: Double

    var isValid: Bool {
        lower.isFinite && upper.isFinite && lower > 0 && upper >= lower
    }
}

/// Ratio of reference-workload WAF to the WAF actually observed on this drive.
/// It must come from an identified workload mapping; it is not guessed from
/// block-size labels or from controller EOL agreement.
struct ReferenceWorkloadProfile: Equatable, Sendable {
    let id: String
    let version: Int
    let standardVersion: String
    let observedWorkloadName: String
    let referenceWorkloadName: String
    let targetToObservedWAFRatio: PELimitRange
    let sourceTitle: String
    let sourceURL: String
    let mappingDetails: String

    var isNumericallyUsable: Bool {
        version > 0 &&
            targetToObservedWAFRatio.isValid &&
            targetToObservedWAFRatio.lower > 0 &&
            !standardVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !observedWorkloadName.isEmpty &&
            !referenceWorkloadName.isEmpty &&
            !mappingDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sourceURL.isHTTPURL
    }
}

struct AppleEnduranceSimulation: Equatable, Sendable {
    let estimatedTBWLowerBytes: Double
    let estimatedTBWUpperBytes: Double
    let remainingTBWLowerBytes: Double
    let remainingTBWUpperBytes: Double
    let dailyWorkloadEndDateRange: ClosedRange<Date>?
    let calculatedAt: Date
    let currentHostWrittenBytes: Double
    let currentObservedWAF: Double
    let referenceWAFRatio: PELimitRange
    let profileApplicability: RetentionProfileApplicability
    let retentionProfileID: String
    let workloadProfileID: String
    let validWearIntervals: Int
    let wearObservationDays: Double
    let wearUnitState: ASPToolUnitState
    let limitingDomain: EnduranceWearDomain
    let basis: [String]
}

enum AppleEnduranceSimulationResult: Equatable, Sendable {
    case available(AppleEnduranceSimulation)
    case unavailable(String)
}

struct AppleEnduranceSimulationInput: Sendable {
    let deviceID: String?
    let nandVendor: String?
    let nandFamily: String?
    let bitsPerCell: Int?
    let controllerWear: ControllerWearHistorySummary
    let latestFTL: ASPToolDiagnosticsSnapshot?
    let dailyHostWriteBytes: Double?
    let currentHostWrittenBytes: Double?
    let retentionProfile: RetentionReferenceProfile?
    let workloadProfile: ReferenceWorkloadProfile?
    let now: Date
}

struct AppleEnduranceSimulator: Sendable {
    func estimate(_ input: AppleEnduranceSimulationInput) -> AppleEnduranceSimulationResult {
        guard let retention = input.retentionProfile else {
            return .unavailable("保持限度をJEDEC Client条件へ対応付けた、出典付きNANDプロファイルがありません")
        }
        guard retention.isNumericallyUsable else {
            return .unavailable("保持参照プロファイルの出典・条件・P/E範囲が不完全です")
        }
        guard retention.powerOff,
              abs(retention.retentionTemperatureCelsius - 30) < 0.001,
              retention.retentionDays >= 365 else {
            return .unavailable("保持参照データがClient想定の電源OFF・30°C・1年条件を満たしません")
        }
        guard let workload = input.workloadProfile else {
            return .unavailable("観測負荷からJEDEC Client負荷へのWAF対応データがありません")
        }
        guard workload.isNumericallyUsable else {
            return .unavailable("基準ワークロード対応プロファイルが不完全です")
        }
        guard input.controllerWear.intervalCount >= 2,
              input.controllerWear.observationDays.isFinite,
              input.controllerWear.observationDays > 0 else {
            return .unavailable("同一系列の日常損耗区間が2本以上必要です")
        }
        guard input.controllerWear.hostUnitState.supportsIntervalComparison else {
            return .unavailable("FTL Host Writesの単位が比較可能ではありません")
        }
        guard input.workloadProfile?.referenceWorkloadName.localizedCaseInsensitiveContains("JESD219") == true else {
            return .unavailable("基準負荷プロファイルがJESD219 Client条件を明示していません")
        }
        guard let currentHost = input.currentHostWrittenBytes,
              currentHost.isFinite, currentHost >= 0,
              let observedWAF = input.controllerWear.medianWAF,
              observedWAF.isFinite, observedWAF > 0 else {
            return .unavailable("Host Writesまたは同一区間WAFが取得できません")
        }
        guard profileMatches(retention, input: input) else {
            return .unavailable("保持参照プロファイルはこのNAND構成に適合しません。近似シナリオとして選択した場合のみ計算できます")
        }
        guard let latest = input.latestFTL,
              latest.captureQuality == .explicit,
              let deviceID = input.deviceID,
              latest.deviceID == deviceID,
              input.controllerWear.seriesIdentity == ControllerWearSeriesIdentity(snapshot: latest),
              input.controllerWear.latestInstrumentIdentity == InstrumentIdentity.resolved(from: latest).identity,
              let tlcPE = finitePositive(latest.tlcAveragePE),
              let slcPE = finitePositive(latest.slcAveragePE),
              let tlcHostPerPE = finitePositive(input.controllerWear.tlcHostBytesPerPE),
              let slcHostPerPE = finitePositive(input.controllerWear.slcHostBytesPerPE) else {
            return .unavailable("TLC・pSLCの最新P/Eと日常Host/P/E傾向の両方が必要です")
        }
        guard !input.controllerWear.instrumentBoundaries.contains(where: {
            $0.boundary.after <= latest.capturedAt && !$0.continuity.isVerified
        }) else {
            return .unavailable("計測器境界の連続性検証待ちです")
        }
        guard let tlcLimit = retention.peAllowanceByDomain[.tlc], tlcLimit.isValid,
              let slcLimit = retention.peAllowanceByDomain[.pSLC], slcLimit.isValid else {
            return .unavailable("保持プロファイルにTLC・pSLC両domainの限度が必要です")
        }

        let ratio = workload.targetToObservedWAFRatio
        let tlcSlopeLow = 1 / tlcHostPerPE * ratio.lower
        let tlcSlopeHigh = 1 / tlcHostPerPE * ratio.upper
        let slcSlopeLow = 1 / slcHostPerPE * ratio.lower
        let slcSlopeHigh = 1 / slcHostPerPE * ratio.upper
        let domainEstimates: [(domain: EnduranceWearDomain, totalLow: Double, totalHigh: Double, remainingLow: Double, remainingHigh: Double)] = [
            (.tlc,
             tlcLimit.lower / tlcSlopeHigh,
             tlcLimit.upper / tlcSlopeLow,
             max(0, tlcLimit.lower - tlcPE) / tlcSlopeHigh,
             max(0, tlcLimit.upper - tlcPE) / tlcSlopeLow),
            (.pSLC,
             slcLimit.lower / slcSlopeHigh,
             slcLimit.upper / slcSlopeLow,
             max(0, slcLimit.lower - slcPE) / slcSlopeHigh,
             max(0, slcLimit.upper - slcPE) / slcSlopeLow)
        ]
        guard let limiting = domainEstimates.min(by: { $0.totalLow < $1.totalLow }),
              domainEstimates.allSatisfy({
                  [$0.totalLow, $0.totalHigh, $0.remainingLow, $0.remainingHigh]
                      .allSatisfy { $0.isFinite && $0 >= 0 }
              }) else {
            return .unavailable("推計値が有限範囲に収まりません")
        }

        let lowerEnd = domainEstimates.min { $0.totalLow < $1.totalLow }!
        let upperEnd = domainEstimates.min { $0.totalHigh < $1.totalHigh }!
        let remainingLow = domainEstimates.min { $0.remainingLow < $1.remainingLow }!
        let remainingHigh = domainEstimates.min { $0.remainingHigh < $1.remainingHigh }!
        let dateRange: ClosedRange<Date>?
        if let rate = input.dailyHostWriteBytes, rate.isFinite, rate > 0 {
            let lowerBytes = min(
                max(0, tlcLimit.lower - tlcPE) * tlcHostPerPE,
                max(0, slcLimit.lower - slcPE) * slcHostPerPE
            ) / rate
            let upperBytes = min(
                max(0, tlcLimit.upper - tlcPE) * tlcHostPerPE,
                max(0, slcLimit.upper - slcPE) * slcHostPerPE
            ) / rate
            if lowerBytes.isFinite, upperBytes.isFinite {
                let lowerDate = input.now.addingTimeInterval(lowerBytes * 86_400)
                let upperDate = input.now.addingTimeInterval(max(lowerBytes, upperBytes) * 86_400)
                dateRange = lowerDate...upperDate
            } else {
                dateRange = nil
            }
        } else {
            dateRange = nil
        }

        return .available(AppleEnduranceSimulation(
            estimatedTBWLowerBytes: lowerEnd.totalLow,
            estimatedTBWUpperBytes: upperEnd.totalHigh,
            remainingTBWLowerBytes: remainingLow.remainingLow,
            remainingTBWUpperBytes: remainingHigh.remainingHigh,
            dailyWorkloadEndDateRange: dateRange,
            calculatedAt: input.now,
            currentHostWrittenBytes: currentHost,
            currentObservedWAF: observedWAF,
            referenceWAFRatio: ratio,
            profileApplicability: retention.applicability,
            retentionProfileID: retention.id,
            workloadProfileID: workload.id,
            validWearIntervals: input.controllerWear.intervalCount,
            wearObservationDays: input.controllerWear.observationDays,
            wearUnitState: input.controllerWear.hostUnitState,
            limitingDomain: limiting.domain,
            basis: [
                "保持モデル: \(retention.modelName) v\(retention.version) · \(retention.sourceTitle) · \(retention.sourceDetails)",
                "条件: 電源OFF / 30°C / 1年以上 · 判定: \(retention.acceptanceCriterion)",
                "保持式: \(retention.fitDescription)",
                "基準負荷: \(workload.referenceWorkloadName) · JESD219 \(workload.standardVersion) · \(workload.mappingDetails)",
                "WAF: Apple日常実測 \(String(format: "%.2f", observedWAF)) · 基準/実測補正 \(String(format: "%.2f", ratio.lower))〜\(String(format: "%.2f", ratio.upper))",
                "保持プロファイル仮定: \(retention.assumptions.joined(separator: " / "))",
                "Apple個体: \(input.controllerWear.intervalCount)区間 / \(String(format: "%.1f", input.controllerWear.observationDays))日 / \(input.controllerWear.hostUnitState.title)",
                "律速domain: \(limiting.domain.rawValue)"
            ]
        ))
    }

    private func profileMatches(_ profile: RetentionReferenceProfile, input: AppleEnduranceSimulationInput) -> Bool {
        if profile.applicability == .relatedNANDScenario { return true }
        guard let profileVendor = profile.nandVendor?.normalizedKey,
              let deviceVendor = input.nandVendor?.normalizedKey,
              profileVendor == deviceVendor,
              let profileFamily = profile.nandFamily?.normalizedKey,
              let deviceFamily = input.nandFamily?.normalizedKey,
              profileFamily == deviceFamily,
              profile.bitsPerCell == input.bitsPerCell else { return false }
        return true
    }

    private func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

private extension String {
    var normalizedKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isHTTPURL: Bool {
        guard let components = URLComponents(string: self),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else { return false }
        return true
    }
}
