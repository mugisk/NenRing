import Foundation

struct ProxyTrial: Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let protocolVersion: String
    let waf: Double?
    let intervalCount: Int
    let overwriteBytes: Double
    let reasons: [String]
    let basisNotes: [String]
    let invalidReason: String?
    var selectable: Bool { invalidReason == nil && waf != nil }
    var automatic: Bool { selectable && protocolVersion == "client-proxy-v2" && reasons.isEmpty }
}

struct ProxyDomain: Equatable, Sendable {
    let name: String
    let averagePE: Double
    let maximumPE: Double?
    let eolPE: Double
    var wear: Double { averagePE / eolPE }
    var guardRatio: Double? { maximumPE.map { $0 / averagePE } }
}

struct ProxyScenario: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let domains: [String]
    let wearFraction: Double
    let physicalBudget: Double
    let totalHostBytes: Double
    let remainingHostBytes: Double
}

struct ProxyProjection: Equatable, Sendable {
    let title: String
    let basis: String
    let date: Date?
    let years: Double?
    let reached: Bool
}

enum AllowablePEWearBasis: Equatable, Sendable {
    case dailyHistory
    case lifetimeAverage

    var title: String {
        switch self {
        case .dailyHistory: return "日常P/E履歴"
        case .lifetimeAverage: return "過去平均"
        }
    }
}

struct AllowablePEDomainEstimate: Equatable, Identifiable, Sendable {
    let name: String
    let currentAveragePE: Double
    let eolPE: Double
    let allowablePE: Double
    let hostBytesPerPE: Double
    let observedIntervalCount: Int
    let wearBasis: AllowablePEWearBasis

    var id: String { name }
    var totalHostBytes: Double { allowablePE * hostBytesPerPE }
    var remainingHostBytes: Double { max(0, allowablePE - currentAveragePE) * hostBytesPerPE }
}

struct AllowablePESensitivityScenario: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let fractionOfEOL: Double?
    let domains: [AllowablePEDomainEstimate]
    let totalHostBytes: Double
    let remainingHostBytes: Double
    let currentRateProjection: ProxyProjection
    let historicalRateProjection: ProxyProjection
    let notes: [String]
}

struct AllowablePESensitivityResult: Equatable, Sendable {
    static let empty = Self(scenarios: [], unavailableReason: "SMART・Direct FTLを待機中", wearBasis: nil)
    static let modelVersion = "allowable-pe-sensitivity-1"

    let scenarios: [AllowablePESensitivityScenario]
    let unavailableReason: String?
    let wearBasis: AllowablePEWearBasis?
    var observedIntervalCounts: [String: Int] = [:]
    var notes: [String] = []
    var smartCapturedAt: Date?
    var ftlCapturedAt: Date?
    var sourceFTLSnapshotID: UUID?
    var lifetimeHostWritesBytes: Double?
    var hostWritesUnitState: ASPToolUnitState?
}

struct AllowablePESensitivityInput: Sendable {
    let domains: [ProxyDomain]
    let lifetimeHostWritesBytes: Double
    let wearHistory: ControllerWearHistorySummary
    let latestSeriesIdentity: ControllerWearSeriesIdentity
    let dailyRate: Double?
    let historicalRate: Double?
    let customTLCPE: Double?
    let customPSLCPE: Double?
    let smartCapturedAt: Date?
    let ftlCapturedAt: Date
    let sourceFTLSnapshotID: UUID
    let hostWritesUnitState: ASPToolUnitState
    let now: Date
}

/// Converts assumed allowable average P/E limits to conditional host-write quantities.
/// No test WAF or retention-temperature coefficient is applied here.
struct AllowablePESensitivityCalculator: Sendable {
    private let defaultFractions: [Double] = [0.25, 0.50, 0.75, 1.0]

    func estimate(_ input: AllowablePESensitivityInput) -> AllowablePESensitivityResult {
        guard !input.domains.isEmpty else {
            return AllowablePESensitivityResult(scenarios: [], unavailableReason: "評価可能なTLC／pSLC P/Eがありません", wearBasis: nil)
        }
        guard input.lifetimeHostWritesBytes.isFinite, input.lifetimeHostWritesBytes > 0 else {
            return AllowablePESensitivityResult(scenarios: [], unavailableReason: "SMART生涯Host Writesがありません", wearBasis: nil)
        }

        let history = input.wearHistory
        // Core wear identity intentionally excludes runtime build and
        // firmware so the long-lived lane can be audited and bridged. A
        // pending/failed instrument boundary, however, must not silently
        // expose the pre-boundary slope to the post-boundary snapshot.
        let blockedByInstrumentBoundary = input.wearHistory.instrumentBoundaries.contains {
            $0.boundary.after <= input.ftlCapturedAt && !$0.continuity.isVerified
        }
        let sameSeries = history.seriesIdentity == input.latestSeriesIdentity && !blockedByInstrumentBoundary
        let domainCounts = Dictionary(uniqueKeysWithValues: input.domains.map { domain in
            (domain.name, domain.name == "TLC" ? history.tlcIntervalCount : history.slcIntervalCount)
        })
        func intervalCount(for name: String) -> Int {
            name == "TLC" ? history.tlcIntervalCount : history.slcIntervalCount
        }
        func historySlope(for name: String) -> Double? {
            name == "TLC" ? history.tlcHostBytesPerPE : history.slcHostBytesPerPE
        }
        let canUseHistory = sameSeries && input.domains.allSatisfy { domain in
            intervalCount(for: domain.name) >= 2
                && historySlope(for: domain.name).map { $0.isFinite && $0 > 0 } == true
        }
        let basis: AllowablePEWearBasis = canUseHistory ? .dailyHistory : .lifetimeAverage
        let domainBases: [AllowablePEDomainEstimate] = input.domains.compactMap { domain in
            guard domain.averagePE.isFinite, domain.averagePE > 0,
                  domain.eolPE.isFinite, domain.eolPE > 0 else { return nil }
            let observedCount = intervalCount(for: domain.name)
            let bytesPerPE: Double
            if canUseHistory, let slope = historySlope(for: domain.name) {
                bytesPerPE = slope
            } else {
                bytesPerPE = input.lifetimeHostWritesBytes / domain.averagePE
            }
            guard bytesPerPE.isFinite, bytesPerPE > 0 else { return nil }
            return AllowablePEDomainEstimate(
                name: domain.name,
                currentAveragePE: domain.averagePE,
                eolPE: domain.eolPE,
                allowablePE: domain.eolPE,
                hostBytesPerPE: bytesPerPE,
                observedIntervalCount: observedCount,
                wearBasis: basis
            )
        }
        guard !domainBases.isEmpty else {
            return AllowablePESensitivityResult(scenarios: [], unavailableReason: "許容P/Eを有限値へ換算できません", wearBasis: nil)
        }

        var notes: [String] = []
        if !sameSeries { notes.append("損耗履歴は最新FTLと同じ系列ではないため、過去平均を使用") }
        if !canUseHistory && sameSeries {
            let counts = domainBases.map { "\($0.name) \($0.observedIntervalCount)区間" }.joined(separator: "・")
            notes.append("各domainの有効区間が2本未満のため全domainで過去平均を使用（\(counts)）")
        }
        if domainBases.count < 2 { notes.append("片側domainのみの部分推計") }

        var scenarios = defaultFractions.compactMap { fraction in
            makeScenario(
                id: "eol-\(Int(fraction * 100))",
                title: "\(Int(fraction * 100))% EOL",
                fractionOfEOL: fraction,
                bases: domainBases,
                dailyRate: input.dailyRate,
                historicalRate: input.historicalRate,
                notes: [],
                now: input.now
            )
        }

        let customTLC = validCustomPE(input.customTLCPE)
        let customPSLC = validCustomPE(input.customPSLCPE)
        if input.customTLCPE != nil && customTLC == nil { notes.append("TLCカスタム許容P/Eが不正のため無視") }
        if input.customPSLCPE != nil && customPSLC == nil { notes.append("pSLCカスタム許容P/Eが不正のため無視") }
        if customTLC != nil || customPSLC != nil {
            let customBases = domainBases.map { domain in
                AllowablePEDomainEstimate(
                    name: domain.name,
                    currentAveragePE: domain.currentAveragePE,
                    eolPE: domain.eolPE,
                    allowablePE: domain.name == "TLC" ? (customTLC ?? domain.eolPE) : (customPSLC ?? domain.eolPE),
                    hostBytesPerPE: domain.hostBytesPerPE,
                    observedIntervalCount: domain.observedIntervalCount,
                    wearBasis: domain.wearBasis
                )
            }
            let missingDomainDefaults = [
                customTLC == nil && customPSLC != nil ? "TLCはEOL値" : nil,
                customPSLC == nil && customTLC != nil ? "pSLCはEOL値" : nil
            ].compactMap { $0 }
            let overEOL = customBases.filter { $0.allowablePE > $0.eolPE }.map(\.name)
            var customNotes = missingDomainDefaults.map { "カスタム未指定domain: \($0)" }
            if !overEOL.isEmpty { customNotes.append("EOL超の仮定: \(overEOL.joined(separator: "・"))") }
            if let custom = makeScenario(
                id: "custom",
                title: overEOL.isEmpty ? "カスタム" : "カスタム · EOL超",
                fractionOfEOL: nil,
                bases: customBases,
                dailyRate: input.dailyRate,
                historicalRate: input.historicalRate,
                notes: customNotes,
                now: input.now
            ) {
                scenarios.append(custom)
            }
        }
        guard !scenarios.isEmpty else {
            return AllowablePESensitivityResult(scenarios: [], unavailableReason: "許容P/E別の計算結果を作成できません", wearBasis: basis,
                observedIntervalCounts: domainCounts, notes: notes)
        }
        var result = AllowablePESensitivityResult(scenarios: scenarios, unavailableReason: nil, wearBasis: basis,
            observedIntervalCounts: domainCounts, notes: notes)
        result.smartCapturedAt = input.smartCapturedAt
        result.ftlCapturedAt = input.ftlCapturedAt
        result.sourceFTLSnapshotID = input.sourceFTLSnapshotID
        result.lifetimeHostWritesBytes = input.lifetimeHostWritesBytes
        result.hostWritesUnitState = input.hostWritesUnitState
        return result
    }

    private func makeScenario(
        id: String,
        title: String,
        fractionOfEOL: Double?,
        bases: [AllowablePEDomainEstimate],
        dailyRate: Double?,
        historicalRate: Double?,
        notes: [String],
        now: Date
    ) -> AllowablePESensitivityScenario? {
        let perDomain = bases.map { base -> AllowablePEDomainEstimate in
            let allowed = fractionOfEOL.map { base.eolPE * $0 } ?? base.allowablePE
            return AllowablePEDomainEstimate(
                name: base.name,
                currentAveragePE: base.currentAveragePE,
                eolPE: base.eolPE,
                allowablePE: allowed,
                hostBytesPerPE: base.hostBytesPerPE,
                observedIntervalCount: base.observedIntervalCount,
                wearBasis: base.wearBasis
            )
        }
        let totals = perDomain.map(\.totalHostBytes)
        let remaining = perDomain.map(\.remainingHostBytes)
        guard totals.allSatisfy({ $0.isFinite && $0 > 0 }),
              remaining.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let total = totals.min(), let remainder = remaining.min(),
              total.isFinite, total > 0, remainder.isFinite else { return nil }
        return AllowablePESensitivityScenario(
            id: id,
            title: title,
            fractionOfEOL: fractionOfEOL,
            domains: perDomain,
            totalHostBytes: total,
            remainingHostBytes: remainder,
            currentRateProjection: project(title: "現在の日常ペース", remaining: remainder, rate: dailyRate, now: now),
            historicalRateProjection: project(title: "長期ペースの概算", remaining: remainder, rate: historicalRate, now: now),
            notes: notes
        )
    }

    private func project(title: String, remaining: Double, rate: Double?, now: Date) -> ProxyProjection {
        if remaining <= 0 { return ProxyProjection(title: title, basis: "", date: nil, years: 0, reached: true) }
        guard let rate, rate.isFinite, rate > 0 else {
            return ProxyProjection(title: title, basis: "書込ペース未算出", date: nil, years: nil, reached: false)
        }
        let days = remaining / rate
        let seconds = days * 86_400
        let timestamp = now.timeIntervalSinceReferenceDate + seconds
        let years = days / 365.25
        let date = timestamp.isFinite && timestamp < 252_423_993_599
            ? Date(timeIntervalSinceReferenceDate: timestamp)
            : nil
        return ProxyProjection(title: title, basis: "", date: date, years: years.isFinite ? years : nil, reached: false)
    }

    private func validCustomPE(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

struct JESDLikeTBWProxyResult: Equatable, Sendable {
    static let empty = Self(unavailableReason: "SMART・Direct FTLを待機中")
    static let modelVersion = "controller-write-budget-2"
    var unavailableReason: String?
    var snapshotID: UUID?
    var snapshotDate: Date?
    var smartDate: Date?
    var deviceID: String?
    var firmware: String?
    var sourceBuild: String?
    var extractionVersion: Int?
    var unitState: ASPToolUnitState = .unavailable
    var selectedSessionID: UUID?
    var selectedWAF: Double?
    var lifetimeWAF: Double?
    var currentPhysicalWrites: Double?
    var wafBasis = "試験負荷補正なし"
    var domains: [ProxyDomain] = []
    var scenarios: [ProxyScenario] = []
    var allowablePESensitivity: AllowablePESensitivityResult = .empty
    var trials: [ProxyTrial] = []
    var projections: [ProxyProjection] = []
    var notes: [String] = []
    var assumptions = ["累積書込量とP/Eの比例外挿", "将来もTLC／pSLCの損耗配分が続く仮定", "JESD218の保持・UBER・FFR条件を含まないController write-budget検算", "保証TBW・故障日の推計ではありません"]
    var observedIntervals = 0
    var observationDays = 0.0
}

struct JESDLikeTBWProxyInput: Sendable {
    let smart: DriveSnapshot?
    let snapshots: [ASPToolDiagnosticsSnapshot]
    let sessions: [ResearchSession]
    let wearHistory: ControllerWearHistorySummary
    let selection: String?
    let dailyRate: Double?
    let historicalRate: Double?
    let now: Date
    var customTLCPE: Double? = nil
    var customPSLCPE: Double? = nil
}

/// A conditional reverse estimate, deliberately independent of retention profiles.
struct JESDLikeTBWProxyCalculator: Sendable {
    func estimate(_ input: JESDLikeTBWProxyInput) -> JESDLikeTBWProxyResult {
        var result = JESDLikeTBWProxyResult.empty
        guard let smart = input.smart else { return result }
        let ordered = input.snapshots.filter { $0.sourceArtifact == .directFTL && $0.deviceID == smart.deviceID }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let ftl = ordered.last else { return result }
        result.snapshotID = ftl.id
        result.snapshotDate = ftl.capturedAt
        result.smartDate = smart.capturedAt
        result.deviceID = smart.deviceID
        result.firmware = ftl.firmwareEpoch
        result.sourceBuild = ftl.sourceBuild
        result.extractionVersion = ftl.extractionVersion
        result.unitState = ftl.hostWritesUnitState
        func unavailable(_ reason: String) -> JESDLikeTBWProxyResult {
            var held = result; held.unavailableReason = reason; return held
        }
        guard !knownMismatch(smart.firmware, ftl.firmware),
              ftl.capturedAt <= input.now, smart.capturedAt <= input.now else {
            return unavailable("SMART／FTLの系列または取得時刻が一致しません")
        }
        guard let h = smart.dataUnitsWrittenBytes, positive(h),
              let host = ftl.hostWrittenBytes, positive(host),
              let nand = ftl.nandWrittenBytes, positive(nand),
              ftl.hostWritesUnitState == ftl.nandWritesUnitState else {
            return unavailable("Host／NANDカウンタの単位換算不能、または有効な書込量がありません")
        }
        if ordered.count >= 2 {
            let previous = ordered[ordered.count - 2]
            if ControllerWearSeriesIdentity(snapshot: previous) == ControllerWearSeriesIdentity(snapshot: ftl),
               snapshotRegressed(previous, ftl) {
                return unavailable("最新FTLでカウンタ／P/Eのresetを検出。現在値の対応を確認できません")
            }
        }
        let lifeWAF = nand / host
        let physical = h * lifeWAF
        guard positive(lifeWAF), positive(physical) else { return unavailable("逆算結果が有限値になりません") }
        result.lifetimeWAF = lifeWAF
        result.currentPhysicalWrites = physical
        if ftl.hostWritesUnitState != .verified { result.notes.append("単位暫定：Host／NANDは4 KiB仮定") }
        if ftl.firmwareEpoch == nil || ftl.sourceBuild == nil || smart.firmware == nil {
            result.notes.append("系列情報に不明項目あり")
        }
        if ftl.captureQuality != .explicit { result.notes.append("FTLの取得時刻は未確認") }
        if abs(ftl.capturedAt.timeIntervalSince(smart.capturedAt)) > 60 {
            result.notes.append("SMART／FTLの取得時刻差あり（60秒超）")
        }
        if abs(host - h) / h > 0.1 { result.notes.append("FTL／SMART累積Host差が10%超") }
        if !(0.5...10).contains(lifeWAF) { result.notes.append("累積WAFが研究上の目安外") }
        for (name, avg, maximum, eol) in [
            ("TLC", ftl.tlcAveragePE, ftl.tlcMaximumPE, ftl.tlcEOLPE),
            ("pSLC", ftl.slcAveragePE, ftl.slcMaximumPE, ftl.slcEOLPE)
        ] {
            if [avg, maximum, eol].compactMap({ $0 }).contains(where: { !$0.isFinite || $0 < 0 }) {
                return unavailable("\(name)：非有限値または負のP/E")
            }
            guard let avg, positive(avg), let eol, positive(eol) else {
                result.notes.append("\(name)：平均P/EまたはEOL不足・進行なし。未評価")
                continue
            }
            let usableMax = maximum.flatMap { $0.isFinite && $0 >= avg ? $0 : nil }
            if usableMax == nil { result.notes.append("\(name)：最大P/E補正未評価") }
            result.domains.append(ProxyDomain(name: name, averagePE: avg, maximumPE: usableMax, eolPE: eol))
        }
        guard let wear = result.domains.map(\.wear).max(), positive(wear) else {
            return unavailable("逆算できるdomainがありません（P/E停滞・欠測・EOL不明）")
        }
        if result.domains.count < 2 { result.notes.append("片側domainの部分推計：SSD全体は未評価") }
        if wear < 0.01 { result.notes.append("損耗率1%未満：量子化の影響が大きい参考値") }
        if let minimum = result.domains.map(\.wear).min(), (wear - minimum) / wear > 0.2 {
            result.notes.append("TLC／pSLCの損耗率差が20%超")
        }
        let rejectedInstrumentBoundaryCutoff = input.wearHistory.instrumentBoundaries
            .filter { !$0.continuity.isVerified && $0.boundary.after <= ftl.capturedAt }
            .map { $0.boundary.after }
        let resetCandidates = zip(ordered, ordered.dropFirst()).filter { a, b in
            let coreBoundary = ControllerWearSeriesIdentity(snapshot: a) != ControllerWearSeriesIdentity(snapshot: b)
            // A point update keeps earlier trials once its boundary is
            // verified; an unverified one still cuts them off below.
            let instrumentBoundary = lineageMismatch(a.sourceBuild, b.sourceBuild, UpdateLineage.build)
                || lineageMismatch(a.firmwareEpoch, b.firmwareEpoch, UpdateLineage.firmwareEpoch)
            return coreBoundary || instrumentBoundary || snapshotRegressed(a, b)
        }.map { $0.1.capturedAt }
        let resetCutoff = (resetCandidates + rejectedInstrumentBoundaryCutoff).max()
        result.trials = input.sessions.filter {
            $0.deviceID == smart.deviceID && ["client-proxy-v1", "client-proxy-v2"].contains($0.protocolVersion)
        }
            .map { evaluate($0, against: ftl, now: input.now, resetCutoff: resetCutoff) }
            .sorted { $0.date > $1.date }
        let selected: ProxyTrial?
        if let choice = input.selection, choice != "automatic", choice != "lifetime" {
            selected = result.trials.first { $0.id.uuidString == choice && $0.selectable }
            if selected == nil { result.notes.append("指定試験は利用不可。累積WAFを代用") }
        } else if input.selection == "lifetime" {
            selected = nil
        } else {
            selected = result.trials.first(where: \.automatic)
        }
        let waf = selected?.waf ?? lifeWAF
        result.selectedWAF = waf
        result.selectedSessionID = selected?.id
        result.wafBasis = selected == nil ? "試験負荷補正なし · 累積WAF代用" : "上書き試験WAF使用"
        result.notes += selected?.reasons ?? []
        func scenario(_ id: String, _ title: String, _ q: Double, _ domains: [String]) -> ProxyScenario? {
            let budget = physical / q
            let total = budget / waf
            let remaining = max(0, budget - physical) / waf
            guard positive(q), positive(budget), positive(total), remaining.isFinite else { return nil }
            return ProxyScenario(id: id, title: title, domains: domains, wearFraction: q,
                physicalBudget: budget, totalHostBytes: total, remainingHostBytes: remaining)
        }
        if let base = scenario("base", "基本proxy", wear, result.domains.map(\.name)) { result.scenarios.append(base) }
        let guarded = result.domains.filter { $0.maximumPE != nil }
        if let q = guarded.compactMap({ d in d.maximumPE.map { $0 / d.eolPE } }).max(),
           let paired = scenario("paired", "domain別偏り補正", q, guarded.map(\.name)) {
            result.scenarios.append(paired)
        }
        if let guardRatio = guarded.compactMap(\.guardRatio).max() {
            if !(1...2).contains(guardRatio) { result.notes.append("Max/Avgが研究上の目安外") }
            if let conservative = scenario("conservative", "追加保守シナリオ", wear * guardRatio, guarded.map(\.name)) {
                result.scenarios.append(conservative)
            }
        }
        guard !result.scenarios.isEmpty else { return unavailable("物理予算の逆算が有限値になりません") }
        result.unavailableReason = nil
        result.assumptions += ["偏り補正：EOLを最大P/Eへ適用する感度分析", "追加保守：別domainの最大損耗率と最大Max/Avgを組合せ"]
        let history = input.wearHistory
        let latestIdentity = ControllerWearSeriesIdentity(snapshot: ftl)
        let blockedByInstrumentBoundary = history.instrumentBoundaries.contains {
            $0.boundary.after <= ftl.capturedAt && !$0.continuity.isVerified
        }
        let sameHistory = history.seriesIdentity == latestIdentity && !blockedByInstrumentBoundary
        result.observedIntervals = sameHistory ? history.intervalCount : 0
        result.observationDays = sameHistory ? history.observationDays : 0
        result.allowablePESensitivity = AllowablePESensitivityCalculator().estimate(AllowablePESensitivityInput(
            domains: result.domains,
            lifetimeHostWritesBytes: h,
            wearHistory: history,
            latestSeriesIdentity: latestIdentity,
            dailyRate: input.dailyRate,
            historicalRate: input.historicalRate,
            customTLCPE: input.customTLCPE,
            customPSLCPE: input.customPSLCPE,
            smartCapturedAt: smart.capturedAt,
            ftlCapturedAt: ftl.capturedAt,
            sourceFTLSnapshotID: ftl.id,
            hostWritesUnitState: ftl.hostWritesUnitState,
            now: input.now
        ))
        if let fullEOL = result.allowablePESensitivity.scenarios.first(where: { $0.id == "eol-100" }) {
            let basis = result.allowablePESensitivity.wearBasis?.title ?? "過去平均"
            result.projections = [
                ProxyProjection(title: "現在の日常ペース", basis: basis, date: fullEOL.currentRateProjection.date,
                    years: fullEOL.currentRateProjection.years, reached: fullEOL.currentRateProjection.reached),
                ProxyProjection(title: "長期の概算ペース", basis: basis, date: fullEOL.historicalRateProjection.date,
                    years: fullEOL.historicalRateProjection.years, reached: fullEOL.historicalRateProjection.reached)
            ]
        }
        if let base = result.scenarios.first {
            result.projections.append(projection("試験負荷継続時", "Host書込ペースは現在と同じ・日常予測とは別", base.remainingHostBytes, input.dailyRate, input.now))
        }
        return result
    }

    func projection(_ title: String, _ basis: String, _ remaining: Double, _ rate: Double?, _ now: Date) -> ProxyProjection {
        if remaining <= 0 { return ProxyProjection(title: title, basis: basis, date: nil, years: 0, reached: true) }
        guard let rate, positive(rate) else { return ProxyProjection(title: title, basis: basis + " · 書込ペース未算出", date: nil, years: nil, reached: false) }
        let days = remaining / rate
        let seconds = days * 86_400
        let timestamp = now.timeIntervalSinceReferenceDate + seconds
        let years = days / 365.25
        // Keep extreme but finite year counts; Date formatting beyond year 9999 is not useful.
        let date = timestamp.isFinite && timestamp < 252_423_993_599 ? Date(timeIntervalSinceReferenceDate: timestamp) : nil
        return ProxyProjection(title: title, basis: basis, date: date, years: years.isFinite ? years : nil, reached: false)
    }

    func evaluate(_ session: ResearchSession, against ftl: ASPToolDiagnosticsSnapshot, now: Date, resetCutoff: Date? = nil) -> ProxyTrial {
        var notes: [String] = []
        var basisNotes: [String] = []
        let date = session.finishedAt ?? session.startedAt
        var invalid: String?
        var hostSum = 0.0, nandSum = 0.0, writtenSum = 0.0
        var count = 0
        if session.finishedAt == nil || session.state == .running { invalid = "未終了試験" }
        if date > now || date < session.startedAt { invalid = "試験時刻不正" }
        if let resetCutoff, session.startedAt < resetCutoff { invalid = "現在の連続系列より前の試験" }
        if session.state != .completed { notes.append("中止・部分試験") }
        if session.protocolVersion == "client-proxy-v1" {
            notes.append("旧v1は同一seedのpayloadを反復。手動参考のみで自動選択しません")
        }
        if now.timeIntervalSince(date) > 90 * 86_400 { notes.append("90日超の試験") }
        if session.logicalCapacityBytes == 0 { notes.append("論理容量不明") }
        if lineageMismatch(session.firmwareEpoch, ftl.firmwareEpoch, UpdateLineage.firmwareEpoch) { invalid = "試験のfirmware系列が不一致" }
        if session.logicalCapacityBytes > 0 && session.writtenBytes > session.logicalCapacityBytes / 10 { notes.append("0.1 DW超") }
        if date.timeIntervalSince(session.startedAt) > 31 * 60 { notes.append("試験時間上限超（終了後観測を含む）") }
        for observation in session.observations {
            if observation.deviceID != ftl.deviceID
                || lineageMismatch(observation.firmwareEpoch, ftl.firmwareEpoch, UpdateLineage.firmwareEpoch)
                || lineageMismatch(observation.sourceBuild, ftl.sourceBuild, UpdateLineage.build)
                || knownMismatch(observation.extractionVersion, Optional(ftl.extractionVersion))
                || knownMismatch(observation.tlcEOLPE, ftl.tlcEOLPE)
                || knownMismatch(observation.slcEOLPE, ftl.slcEOLPE)
                || observation.hostUnitState != ftl.hostWritesUnitState
                || observation.nandUnitState != ftl.nandWritesUnitState { invalid = "現在FTLと系列・単位・EOLが不一致" }
            if observation.firmwareEpoch == nil {
                basisNotes.append("試験時のfirmware値未取得（現時点で比較不能）")
            }
            if observation.sourceBuild == nil || observation.extractionVersion == nil
                || observation.tlcEOLPE == nil || observation.slcEOLPE == nil {
                notes.append("試験時のbuild・形式・EOLの一部未取得")
            }
            if observation.criticalWarning != 0 { notes.append("警告あり、または警告情報未取得") }
            if [observation.tlcAveragePE, observation.tlcMaximumPE, observation.slcAveragePE,
                observation.slcMaximumPE, observation.tlcEOLPE, observation.slcEOLPE]
                .compactMap({ $0 }).contains(where: { !$0.isFinite || $0 < 0 }) { invalid = "試験P/Eに不正値" }
            if observation.capturedAt < session.startedAt || observation.capturedAt > date { invalid = "観測が試験時刻範囲外" }
            if let smartAt = observation.smartCapturedAt, let ftlAt = observation.ftlCapturedAt,
               abs(smartAt.timeIntervalSince(ftlAt)) > 60 { notes.append("試験SMART／FTL取得時刻差60秒超") }
        }
        if let last = session.observations.last, last.capturedAt <= ftl.capturedAt,
           regressed(last.hostWrites, ftl.hostWrites) || regressed(last.nandWrites, ftl.nandWrites)
            || regressed(last.tlcAveragePE, ftl.tlcAveragePE) || regressed(last.slcAveragePE, ftl.slcAveragePE)
            || regressed(last.tlcMaximumPE, ftl.tlcMaximumPE) || regressed(last.slcMaximumPE, ftl.slcMaximumPE) {
            invalid = "試験後の現在カウンタ／P/Eが退行"
        }
        for (a, b) in zip(session.observations, session.observations.dropFirst()) {
            if b.capturedAt <= a.capturedAt
                || knownMismatch(a.firmwareEpoch, b.firmwareEpoch) || knownMismatch(a.sourceBuild, b.sourceBuild)
                || knownMismatch(a.extractionVersion, b.extractionVersion)
                || knownMismatch(a.tlcEOLPE, b.tlcEOLPE) || knownMismatch(a.slcEOLPE, b.slcEOLPE)
                || a.hostUnitState != b.hostUnitState || a.nandUnitState != b.nandUnitState
                || regressed(a.hostWrites, b.hostWrites) || regressed(a.nandWrites, b.nandWrites)
                || regressed(a.smartDataUnitsWritten, b.smartDataUnitsWritten)
                || regressed(a.tlcAveragePE, b.tlcAveragePE) || regressed(a.slcAveragePE, b.slcAveragePE)
                || regressed(a.tlcMaximumPE, b.tlcMaximumPE) || regressed(a.slcMaximumPE, b.slcMaximumPE) {
                invalid = "試験途中のreset・系列変更・時刻逆転"
            }
            for (t0, t1) in [(a.smartCapturedAt, b.smartCapturedAt), (a.ftlCapturedAt, b.ftlCapturedAt)] {
                if let t0, let t1, t1 <= t0 { invalid = "取得時刻の逆転" }
            }
            guard (a.phase == .populationComplete || a.phase == .overwriteSegment), b.phase == .overwriteSegment else { continue }
            guard let h0 = a.hostWrittenBytes, let h1 = b.hostWrittenBytes, h1 > h0,
                  let n0 = a.nandWrittenBytes, let n1 = b.nandWrittenBytes, n1 >= n0,
                  a.hostUnitState == a.nandUnitState, b.hostUnitState == b.nandUnitState else {
                invalid = "上書き区間のカウンタ欠測・単位不明・増加なし"; continue
            }
            let dh = h1 - h0, dn = n1 - n0
            hostSum += dh; nandSum += dn; count += 1
            if !(0.5...10).contains(dn / dh) { notes.append("区間WAFが研究上の目安外") }
            if let app = b.bytesWrittenInPhase, app > 0,
               let s0 = a.smartDataUnitsWritten, let s1 = b.smartDataUnitsWritten, s1 > s0 {
                let smartDelta = Double(s1 - s0) * HistoryAnalyzer.bytesPerNVMeDataUnit
                writtenSum += Double(app)
                if !(0.8...1.5).contains(smartDelta / Double(app)) { notes.append("上書き区間の外部I/O混入疑い") }
                if abs(dh - smartDelta) / smartDelta > 0.1 { notes.append("上書き区間のFTL／SMART差が10%超") }
            } else { notes.append("区間検証未実施（アプリ書込量／SMART不足）") }
            if a.smartCapturedAt == nil || b.smartCapturedAt == nil || a.ftlCapturedAt == nil || b.ftlCapturedAt == nil {
                notes.append("区間の個別取得時刻未確認")
            }
        }
        if session.logicalCapacityBytes > 0 && writtenSum < Double(session.logicalCapacityBytes) * 0.005 { notes.append("検証済み上書き量0.005 DW未満") }
        if count < 2 { notes.append("上書き区間2本未満") }
        let waf = hostSum > 0 ? nandSum / hostSum : nil
        if waf == nil || !positive(waf ?? 0) { invalid = "有効な上書きWAFなし" }
        return ProxyTrial(id: session.id, date: date, protocolVersion: session.protocolVersion,
            waf: waf, intervalCount: count, overwriteBytes: writtenSum,
            reasons: Array(Set(notes)).sorted(), basisNotes: Array(Set(basisNotes)).sorted(), invalidReason: invalid)
    }

    private func positive(_ value: Double) -> Bool { value.isFinite && value > 0 }
    private func knownMismatch<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
        guard let a, let b else { return false }; return a != b
    }
    private func lineageMismatch(_ a: String?, _ b: String?, _ lineage: (String?) -> String?) -> Bool {
        knownMismatch(lineage(a), lineage(b))
    }
    private func regressed<T: Comparable>(_ a: T?, _ b: T?) -> Bool {
        guard let a, let b else { return false }; return b < a
    }
    private func snapshotRegressed(_ a: ASPToolDiagnosticsSnapshot, _ b: ASPToolDiagnosticsSnapshot) -> Bool {
        regressed(a.hostWrites, b.hostWrites) || regressed(a.nandWrites, b.nandWrites)
            || regressed(a.tlcAveragePE, b.tlcAveragePE) || regressed(a.slcAveragePE, b.slcAveragePE)
            || regressed(a.tlcMaximumPE, b.tlcMaximumPE) || regressed(a.slcMaximumPE, b.slcMaximumPE)
    }
}
