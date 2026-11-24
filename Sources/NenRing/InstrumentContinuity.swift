import Foundation

private func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Updates are compared by lineage: the leading number of an SSD firmware
/// string ("591" in "591.40.3") and the macOS major version of a build. A
/// point update within a lineage keeps analyses continuous; its instrument
/// boundary is still verified against SMART. Reading the leading number as
/// the lineage is inferred from observed strings (561.100. → 591 →
/// 591.40.3), not from a published scheme, so any other form compares
/// exactly.
enum UpdateLineage {
    static func firmware(_ firmware: String?) -> String? {
        guard let firmware = trimmedNonEmpty(firmware) else { return nil }
        let digits = firmware.prefix { $0.isNumber }
        let rest = firmware.dropFirst(digits.count)
        guard !digits.isEmpty, rest.isEmpty || rest.first == "." else { return firmware }
        return String(digits)
    }

    /// A firmware epoch is "firmware|msp"; the MSP part compares exactly.
    static func firmwareEpoch(_ epoch: String?) -> String? {
        guard let epoch = trimmedNonEmpty(epoch) else { return nil }
        guard let bar = epoch.firstIndex(of: "|") else { return firmware(epoch) }
        return (firmware(String(epoch[..<bar])) ?? "") + epoch[bar...]
    }

    static func build(_ build: String?) -> String? {
        guard let build = trimmedNonEmpty(build) else { return nil }
        return DirectFTLContractRegistry.macOSMajorVersion(fromBuild: build).map { "macOS \($0)" } ?? build
    }
}

/// Provenance of the runtime build attached to a persisted Direct FTL record.
/// The value is deliberately analysis metadata: legacy raw snapshots are never
/// rewritten when an overlay is resolved.
enum BuildProvenance: String, Codable, Equatable, Sendable {
    case recorded
    case legacyFixedLabel
    case inferred
}

/// Identity of the physical device. How the counters were read is not part
/// of this identity; those changes are recorded as instrument boundaries.
struct DeviceSeriesIdentity: Codable, Equatable, Hashable, Sendable {
    let deviceID: String?

    init(deviceID: String?) {
        self.deviceID = deviceID
    }

    init(snapshot: ASPToolDiagnosticsSnapshot) {
        self.init(deviceID: snapshot.deviceID)
    }
}

/// Identity of the instrument conditions that can change the interpretation
/// of a Direct FTL observation. Extraction version and unit labels are
/// deliberately retained as provenance but do not split the identity.
struct InstrumentIdentity: Codable, Equatable, Hashable, Sendable {
    let sourceArtifact: ASPToolSourceArtifact?
    let runtimeBuild: String?
    let firmwareEpoch: String?
    let contractBuild: String?
    let keyContractVersion: String?
    let directFormatVersion: UInt32?
    let probeVersion: Int?
    let extractionVersion: Int?

    static func resolved(
        from snapshot: ASPToolDiagnosticsSnapshot,
        smartHistory: [DriveSnapshot] = []
    ) -> (identity: InstrumentIdentity, provenance: BuildProvenance) {
        resolved(from: snapshot) { nearestSmartFirmware(for: snapshot, history: smartHistory) }
    }

    /// `nearestFirmware` returns the firmware of the same device's SMART
    /// record nearest in time; it is asked only for snapshots that recorded
    /// no firmware of their own.
    static func resolved(
        from snapshot: ASPToolDiagnosticsSnapshot,
        nearestFirmware: () -> String?
    ) -> (identity: InstrumentIdentity, provenance: BuildProvenance) {
        let overlay = LegacyBuildOverlay.resolve(snapshot, nearestFirmware: nearestFirmware)
        let contractBuild = snapshot.contractBuild
            ?? (snapshot.directKeyContractVersion != nil || snapshot.semanticContractVersion != nil || overlay.build == DirectFTLResearchContract.reviewedBuild
                ? DirectFTLResearchContract.reviewedBuild : nil)
        let firmware = snapshot.firmware
            ?? snapshot.firmwareEpoch
            ?? nearestFirmware()
        return (
            InstrumentIdentity(
                sourceArtifact: snapshot.sourceArtifact,
                runtimeBuild: overlay.build,
                firmwareEpoch: firmware,
                contractBuild: contractBuild,
                // Research-key revisions (for example v2.4 -> v2.4.1) do
                // not change the Host/NAND/P-E wear meanings.  The instrument
                // boundary must follow the stable core-wear contract instead.
                keyContractVersion: snapshot.resolvedCoreWearVersion
                    ?? (overlay.build == DirectFTLResearchContract.reviewedBuild
                        ? DirectFTLResearchContract.reviewed25G83CoreV1 : nil),
                directFormatVersion: snapshot.directFormatVersion,
                probeVersion: snapshot.probeVersion,
                extractionVersion: snapshot.extractionVersion
            ),
            overlay.provenance
        )
    }

    private static func runtimeBuildsMatch(
        _ lhs: String?,
        _ rhs: String?,
        firmware: String?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        if lhs == rhs { return true }

        // Legacy snapshots recorded the firmware but not the runtime build.
        // Once a build is recorded for that same firmware, this overlay is a
        // compatible label rather than a second physical instrument.
        let prefix = "unrecorded-after-fw-"
        let lhsOverlay = lhs.hasPrefix(prefix) ? String(lhs.dropFirst(prefix.count)) : nil
        let rhsOverlay = rhs.hasPrefix(prefix) ? String(rhs.dropFirst(prefix.count)) : nil
        if lhsOverlay != nil || rhsOverlay != nil {
            let overlayFirmware = lhsOverlay ?? rhsOverlay
            return overlayFirmware == firmware
        }
        return false
    }

    static func == (lhs: InstrumentIdentity, rhs: InstrumentIdentity) -> Bool {
        lhs.sourceArtifact == rhs.sourceArtifact &&
            runtimeBuildsMatch(lhs.runtimeBuild, rhs.runtimeBuild, firmware: lhs.firmwareEpoch) &&
            lhs.firmwareEpoch == rhs.firmwareEpoch &&
            lhs.contractBuild == rhs.contractBuild &&
            lhs.keyContractVersion == rhs.keyContractVersion &&
            lhs.directFormatVersion == rhs.directFormatVersion
    }

    /// Missing build/firmware/core-contract metadata is not itself a changed
    /// instrument. Treat it as enrichment only when known values agree;
    /// conflicting labels and direct-format changes still create a boundary.
    func isCompatibleMetadata(with other: InstrumentIdentity) -> Bool {
        func compatible<Value: Equatable>(_ lhs: Value?, _ rhs: Value?) -> Bool {
            lhs == nil || rhs == nil || lhs == rhs
        }
        return sourceArtifact == other.sourceArtifact &&
            (Self.runtimeBuildsMatch(runtimeBuild, other.runtimeBuild, firmware: firmwareEpoch)
                || runtimeBuild == nil || other.runtimeBuild == nil) &&
            compatible(firmwareEpoch, other.firmwareEpoch) &&
            compatible(contractBuild, other.contractBuild) &&
            compatible(keyContractVersion, other.keyContractVersion) &&
            directFormatVersion == other.directFormatVersion
    }

    func hash(into hasher: inout Hasher) {
        // Hash only fields used by equality. Equality may bridge a legacy
        // overlay to a recorded build, so firmware is the shared hash key.
        hasher.combine(sourceArtifact)
        hasher.combine(firmwareEpoch)
        hasher.combine(contractBuild)
        hasher.combine(keyContractVersion)
        hasher.combine(directFormatVersion)
        // Probe version is provenance only: a probe release does not change
        // the measured instrument when OS build and firmware are unchanged.
    }

    private static func nearestSmartFirmware(
        for snapshot: ASPToolDiagnosticsSnapshot,
        history: [DriveSnapshot]
    ) -> String? {
        history
            .filter { snapshot.deviceID == nil || $0.deviceID == snapshot.deviceID }
            .min { lhs, rhs in
                abs(lhs.capturedAt.timeIntervalSince(snapshot.capturedAt))
                    < abs(rhs.capturedAt.timeIntervalSince(snapshot.capturedAt))
            }?.firmware.flatMap(trimmedNonEmpty)
    }
}

/// Analysis-only migration for snapshots produced before probes recorded the
/// runtime OS build.  The original JSON remains byte-for-byte untouched.
struct LegacyBuildOverlay: Equatable, Sendable {
    static func resolve(
        _ snapshot: ASPToolDiagnosticsSnapshot,
        smartHistory: [DriveSnapshot]
    ) -> (build: String?, provenance: BuildProvenance) {
        resolve(snapshot) {
            smartHistory
                .filter { snapshot.deviceID == nil || $0.deviceID == snapshot.deviceID }
                .min { lhs, rhs in
                    abs(lhs.capturedAt.timeIntervalSince(snapshot.capturedAt))
                        < abs(rhs.capturedAt.timeIntervalSince(snapshot.capturedAt))
                }?.firmware.flatMap(trimmedNonEmpty)
        }
    }

    static func resolve(
        _ snapshot: ASPToolDiagnosticsSnapshot,
        nearestFirmware: () -> String?
    ) -> (build: String?, provenance: BuildProvenance) {
        if snapshot.contractBuild != nil {
            return (snapshot.sourceBuild, .recorded)
        }

        let firmware = trimmedNonEmpty(snapshot.firmware)
            ?? snapshot.firmwareEpoch?.split(separator: "|", maxSplits: 1).first.map(String.init)
            ?? nearestFirmware()

        if let firmware {
            if firmware == "561.100" || firmware.hasPrefix("561") {
                return (DirectFTLResearchContract.reviewedBuild, .inferred)
            }
            return ("unrecorded-after-fw-\(firmware)", .inferred)
        }

        return (snapshot.sourceBuild, .legacyFixedLabel)
    }
}

enum ContinuityCheckKind: String, Codable, Equatable, Sendable, CaseIterable {
    case d1Geometry = "D1"
    case d2Topology = "D2"
    case d3EOL = "D3"
    case d4Monotonic = "D4"
    case d5SmartHostRatio = "D5"
    case d6PowerOnHours = "D6"
    case d7LifetimeResidual = "D7"
    case d8BoundaryWAF = "D8"
}

struct ContinuityCheckResult: Codable, Equatable, Sendable {
    let kind: ContinuityCheckKind
    let passed: Bool
    let available: Bool
    let detail: String
    let value: Double?
    let relativeChange: Double?

    init(
        kind: ContinuityCheckKind,
        passed: Bool,
        available: Bool,
        detail: String,
        value: Double? = nil,
        relativeChange: Double? = nil
    ) {
        self.kind = kind
        self.passed = passed
        self.available = available
        self.detail = detail
        self.value = value
        self.relativeChange = relativeChange
    }
}

struct InstrumentBoundary: Codable, Equatable, Sendable {
    let before: Date
    let after: Date
    let beforeIdentity: InstrumentIdentity
    let afterIdentity: InstrumentIdentity
    /// Only a firmware change can alter controller behaviour and carry a
    /// post-update write transient. OS-build-only, probe and format
    /// boundaries are audited but never receive a learning exclusion.
    let hasPhysicalTransient: Bool

    init(
        before: Date,
        after: Date,
        beforeIdentity: InstrumentIdentity,
        afterIdentity: InstrumentIdentity,
        hasPhysicalTransient: Bool = true
    ) {
        self.before = before
        self.after = after
        self.beforeIdentity = beforeIdentity
        self.afterIdentity = afterIdentity
        self.hasPhysicalTransient = hasPhysicalTransient
    }

    private enum CodingKeys: String, CodingKey {
        case before
        case after
        case beforeIdentity
        case afterIdentity
        case hasPhysicalTransient
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        before = try container.decode(Date.self, forKey: .before)
        after = try container.decode(Date.self, forKey: .after)
        beforeIdentity = try container.decode(InstrumentIdentity.self, forKey: .beforeIdentity)
        afterIdentity = try container.decode(InstrumentIdentity.self, forKey: .afterIdentity)
        hasPhysicalTransient = try container.decodeIfPresent(Bool.self, forKey: .hasPhysicalTransient) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(before, forKey: .before)
        try container.encode(after, forKey: .after)
        try container.encode(beforeIdentity, forKey: .beforeIdentity)
        try container.encode(afterIdentity, forKey: .afterIdentity)
        try container.encode(hasPhysicalTransient, forKey: .hasPhysicalTransient)
    }
}

enum InstrumentContinuity: Codable, Equatable, Sendable {
    case reviewed
    case sameInstrument
    case deviceChange(boundary: InstrumentBoundary)
    case pending(boundary: InstrumentBoundary)
    case verified(boundary: InstrumentBoundary, checks: [ContinuityCheckResult])
    case failed(boundary: InstrumentBoundary, checks: [ContinuityCheckResult])

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .reviewed: return "検証済み条件"
        case .sameInstrument: return "同一条件"
        case .deviceChange: return "デバイス境界"
        case .pending: return "SMART待ち・保留"
        case .verified: return "境界検証済み"
        case .failed: return "境界検証失敗"
        }
    }
}

struct InstrumentBoundaryRecord: Codable, Equatable, Sendable {
    let boundary: InstrumentBoundary
    let continuity: InstrumentContinuity
    let checks: [ContinuityCheckResult]
    let rateLearningExclusion: DateInterval?
    let note: String
    let oldBuildWasOverlayed: Bool
    /// First evaluation is retained when a pending boundary is re-evaluated.
    /// Raw snapshots remain the source of truth; this is an analytics summary.
    let initialEvaluation: InstrumentBoundaryEvaluation?
    let lastEvaluatedAt: Date?
    let beforeBuildProvenance: BuildProvenance?
    let afterBuildProvenance: BuildProvenance?

    init(
        boundary: InstrumentBoundary,
        continuity: InstrumentContinuity,
        checks: [ContinuityCheckResult],
        rateLearningExclusion: DateInterval?,
        note: String,
        oldBuildWasOverlayed: Bool,
        initialEvaluation: InstrumentBoundaryEvaluation? = nil,
        lastEvaluatedAt: Date? = nil,
        beforeBuildProvenance: BuildProvenance? = nil,
        afterBuildProvenance: BuildProvenance? = nil
    ) {
        self.boundary = boundary
        self.continuity = continuity
        self.checks = checks
        self.rateLearningExclusion = rateLearningExclusion
        self.note = note
        self.oldBuildWasOverlayed = oldBuildWasOverlayed
        self.initialEvaluation = initialEvaluation
        self.lastEvaluatedAt = lastEvaluatedAt
        self.beforeBuildProvenance = beforeBuildProvenance
        self.afterBuildProvenance = afterBuildProvenance
    }
}

struct InstrumentBoundaryEvaluation: Codable, Equatable, Sendable {
    let evaluatedAt: Date
    let continuity: InstrumentContinuity
    let checks: [ContinuityCheckResult]
    let note: String
}

/// A provenance-only version change that is retained for Advanced history but
/// deliberately does not split the physical-wear lane or create a chart
/// boundary (for example, probe 1 -> 2 on the same build and firmware).
struct InstrumentMetadataChangeRecord: Equatable, Sendable, Identifiable {
    let beforeAt: Date
    let afterAt: Date
    let beforeIdentity: InstrumentIdentity
    let afterIdentity: InstrumentIdentity
    let changedAttributes: [String]

    var id: String {
        "\(beforeAt.timeIntervalSince1970)-\(afterAt.timeIntervalSince1970)-\(changedAttributes.joined(separator: ","))"
    }
}

enum InstrumentBoundaryDisplayStatus: String, CaseIterable, Hashable, Sendable, Identifiable {
    case verified
    case settlingWait
    case evidencePending
    case failed
    case deviceChange
    case neutral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verified: return "検証済み"
        case .settlingWait: return "落ち着き待ち"
        case .evidencePending: return "資料待ち"
        case .failed: return "検証不一致"
        case .deviceChange: return "デバイス変更"
        case .neutral: return "確認済み条件"
        }
    }

    static func resolve(
        continuity: InstrumentContinuity,
        checks: [ContinuityCheckResult]
    ) -> InstrumentBoundaryDisplayStatus {
        switch continuity {
        case .verified:
            return .verified
        case .failed:
            return .failed
        case .deviceChange:
            return .deviceChange
        case .pending:
            let requiredKinds = ContinuityCheckKind.allCases.filter { $0 != .d8BoundaryWAF }
            let missingEvidence = requiredKinds.contains { kind in
                guard let check = checks.first(where: { $0.kind == kind }) else { return true }
                return !check.available
            }
            return missingEvidence ? .evidencePending : .settlingWait
        case .reviewed, .sameInstrument:
            return .neutral
        }
    }
}

struct InstrumentBoundaryLegendItem: Equatable, Identifiable, Sendable {
    let status: InstrumentBoundaryDisplayStatus
    var id: String { status.rawValue }
    var title: String { status.title }
}

enum InstrumentBoundaryPresentation {
    static func status(for record: InstrumentBoundaryRecord) -> InstrumentBoundaryDisplayStatus {
        .resolve(continuity: record.continuity, checks: record.checks)
    }

    static func kindTitle(for record: InstrumentBoundaryRecord) -> String {
        if case .deviceChange = record.continuity {
            return "デバイス境界"
        }

        let before = record.boundary.beforeIdentity
        let after = record.boundary.afterIdentity
        if before.sourceArtifact != after.sourceArtifact {
            return "取得経路境界"
        }

        let buildChanged = before.runtimeBuild != after.runtimeBuild
        let firmwareChanged = before.firmwareEpoch != after.firmwareEpoch
        switch (buildChanged, firmwareChanged) {
        case (true, true): return "OS / FW境界"
        case (true, false): return "OS build境界"
        case (false, true): return "FW境界"
        case (false, false): return "計測条件境界"
        }
    }

    static func rawDataViewerSummary(for record: InstrumentBoundaryRecord) -> String {
        let statusTitle = status(for: record).title
        let learningText: String

        switch status(for: record) {
        case .verified:
            if record.boundary.hasPhysicalTransient {
                learningText = record.rateLearningExclusion == nil
                    ? "FW更新あり・更新後WAF変化なし・学習除外なし"
                    : "FW更新後のWAF変化のため境界後72時間を学習除外"
            } else {
                learningText = record.rateLearningExclusion == nil
                    ? "物理更新なし・WAF学習除外なし"
                    : "物理更新なし・学習除外記録あり（要確認）"
            }
        case .settlingWait, .evidencePending:
            learningText = record.boundary.hasPhysicalTransient
                ? "検証待ち・後続系列を保留"
                : "検証待ち・物理更新なし"
        case .failed:
            learningText = "検証不一致・境界後はWAF学習対象外"
        case .deviceChange:
            learningText = "別デバイス系列"
        case .neutral:
            if record.rateLearningExclusion != nil {
                learningText = "WAF学習除外あり"
            } else {
                learningText = record.boundary.hasPhysicalTransient
                    ? "物理更新あり・学習除外未確定"
                    : "物理更新なし・WAF学習除外なし"
            }
        }

        return "\(kindTitle(for: record))・\(statusTitle)・\(learningText)"
    }

    static func visibleRecords(
        _ records: [InstrumentBoundaryRecord],
        in dates: [Date]
    ) -> [InstrumentBoundaryRecord] {
        guard let lower = dates.min(), let upper = dates.max() else { return [] }
        return records.filter { $0.boundary.after >= lower && $0.boundary.after <= upper }
    }

    static func legendItems(for records: [InstrumentBoundaryRecord]) -> [InstrumentBoundaryLegendItem] {
        let present = Set(records.map { status(for: $0) })
        return InstrumentBoundaryDisplayStatus.allCases
            .filter(present.contains)
            .map(InstrumentBoundaryLegendItem.init(status:))
    }

    static func changedAttributes(for record: InstrumentBoundaryRecord) -> [String] {
        let before = record.boundary.beforeIdentity
        let after = record.boundary.afterIdentity
        var changes: [String] = []

        appendChange("取得経路", before.sourceArtifact.map { sourceTitle($0) }, after.sourceArtifact.map { sourceTitle($0) }, to: &changes)
        appendChange("OS build", before.runtimeBuild, after.runtimeBuild, to: &changes)
        appendChange("Firmware", before.firmwareEpoch, after.firmwareEpoch, to: &changes)
        appendChange("対応表のbuild", before.contractBuild, after.contractBuild, to: &changes)
        appendChange("Core wearの対応表", before.keyContractVersion, after.keyContractVersion, to: &changes)
        appendChange("Direct形式", before.directFormatVersion.map(String.init), after.directFormatVersion.map(String.init), to: &changes)
        appendChange("probe版", before.probeVersion.map(String.init), after.probeVersion.map(String.init), to: &changes)
        appendChange("抽出版", before.extractionVersion.map(String.init), after.extractionVersion.map(String.init), to: &changes)

        if case .deviceChange = record.continuity {
            changes.append("物理デバイス識別子が変更（値は非表示）")
        }
        return changes.isEmpty ? ["表示可能な計測条件の変更なし"] : changes
    }

    static func tooltip(for record: InstrumentBoundaryRecord) -> String {
        var lines = [
            "計測器境界 · \(status(for: record).title)",
            "\(date(record.boundary.before)) → \(date(record.boundary.after))",
            "変更: \(changedAttributes(for: record).joined(separator: " / "))"
        ]
        if let before = record.beforeBuildProvenance, let after = record.afterBuildProvenance {
            lines.append("build provenance: \(provenanceTitle(before)) → \(provenanceTitle(after))")
        } else if record.oldBuildWasOverlayed {
            lines.append("build provenance: 旧snapshotのbuildを解析時に推定")
        }
        if let first = record.initialEvaluation {
            lines.append("初回 \(date(first.evaluatedAt)): \(InstrumentBoundaryDisplayStatus.resolve(continuity: first.continuity, checks: first.checks).title)")
        }
        if let last = record.lastEvaluatedAt {
            lines.append("最終判定 \(date(last))")
        }
        lines.append(contentsOf: checkLines(record.checks))
        if let exclusion = record.rateLearningExclusion {
            lines.append("率学習除外 \(date(exclusion.start)) → \(date(exclusion.end))（境界後72時間を含む）")
        } else {
            lines.append("率学習除外なし")
        }
        lines.append(record.note)
        return lines.joined(separator: "\n")
    }

    static func checkLines(_ checks: [ContinuityCheckResult]) -> [String] {
        ContinuityCheckKind.allCases.map { kind in
            guard let check = checks.first(where: { $0.kind == kind }) else {
                return "\(kind.rawValue): 未取得"
            }
            let outcome = check.available ? (check.passed ? "PASS" : "FAIL") : "資料待ち"
            return "\(kind.rawValue): \(outcome) · \(check.detail)"
        }
    }

    static func provenanceTitle(_ provenance: BuildProvenance) -> String {
        switch provenance {
        case .recorded: return "記録済み"
        case .legacyFixedLabel: return "旧形式・固定ラベル"
        case .inferred: return "推定"
        }
    }

    static func sourceTitle(_ source: ASPToolSourceArtifact) -> String {
        switch source {
        case .extractedASPTool: return "sysdiagnose / asptool"
        case .importedFixture: return "imported fixture"
        case .directBinary: return "Direct binary"
        case .directBinaryHeader: return "Direct binary header"
        case .directFTL: return "Direct FTL"
        case .directBandStats: return "Direct band stats"
        }
    }

    private static func appendChange(
        _ title: String,
        _ before: String?,
        _ after: String?,
        to changes: inout [String]
    ) {
        guard before != after else { return }
        changes.append("\(title) \(before ?? "未記録") → \(after ?? "未記録")")
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .numeric, time: .shortened)
    }
}

struct WearContinuityLane: Equatable, Sendable {
    let snapshots: [ASPToolDiagnosticsSnapshot]
    let boundaries: [InstrumentBoundaryRecord]
    let rateLearningExclusions: [DateInterval]
    /// Absorbed provenance changes are visible in Advanced but are not wear
    /// boundaries and do not produce learning exclusions or chart markers.
    var instrumentMetadataChanges: [InstrumentMetadataChangeRecord] = []
    /// Same-second duplicate captures collapsed for analytics. Persisted raw
    /// history remains unchanged.
    let collapsedSameSecondSnapshots: Int

    /// Returns a topology for analysis only when the lane itself contains a
    /// passing D1/D2 asptool-to-Direct bridge and all explicit topology samples
    /// agree. This does not modify or promote the underlying raw records.
    var verifiedCoreTopology: DirectFTLTopology? {
        let known = snapshots.compactMap(\.directTopology)
        guard let topology = known.last,
              known.allSatisfy({ $0.isEquivalentGeometry(to: topology) }) else { return nil }
        if snapshots.contains(where: { $0.directTopology == nil }) {
            let routeBridgeVerified = boundaries.contains { record in
                guard record.continuity.isVerified else { return false }
                let before = record.boundary.beforeIdentity.sourceArtifact
                let after = record.boundary.afterIdentity.sourceArtifact
                let crossesRoute = (before == .extractedASPTool && after == .directFTL)
                    || (before == .directFTL && after == .extractedASPTool)
                guard crossesRoute else { return false }
                return [.d1Geometry, .d2Topology].allSatisfy { kind in
                    record.checks.contains { $0.kind == kind && $0.available && $0.passed }
                }
            }
            guard routeBridgeVerified else { return nil }
        }
        return topology
    }

    var containsTopologylessASPTool: Bool {
        verifiedCoreTopology != nil && snapshots.contains {
            $0.sourceArtifact == .extractedASPTool && $0.directTopology == nil
        }
    }
}

/// Builds the core-wear lane without mutating the persisted raw history.
/// Firmware/build changes are recorded as boundaries.  Only a boundary that
/// passes the hard D1-D7 checks is allowed to reconnect rate learning.
enum WearContinuityLaneBuilder {
    /// Resolves each snapshot's instrument identity once per lane build.
    /// Resolving can search the whole SMART history, and the builder asks
    /// for the same snapshot several times; repeating that work was most of
    /// the time spent rebuilding the dashboard.
    private final class IdentityCache {
        private let firmware: NearestSmartFirmware
        private var resolved: [UUID: (identity: InstrumentIdentity, provenance: BuildProvenance)] = [:]

        init(smart: [DriveSnapshot]) {
            firmware = NearestSmartFirmware(history: smart)
        }

        func callAsFunction(
            _ snapshot: ASPToolDiagnosticsSnapshot
        ) -> (identity: InstrumentIdentity, provenance: BuildProvenance) {
            if let cached = resolved[snapshot.id] { return cached }
            let value = InstrumentIdentity.resolved(from: snapshot) {
                firmware.firmware(near: snapshot.capturedAt, deviceID: snapshot.deviceID)
            }
            resolved[snapshot.id] = value
            return value
        }
    }

    /// The SMART record nearest in time, found by binary search instead of
    /// a scan per snapshot. On a tie it picks the record that comes first in
    /// the original history, as the linear `min` does.
    struct NearestSmartFirmware {
        private struct Entry {
            let date: Date
            let offset: Int
            let firmware: String?
        }

        private let all: [Entry]
        private let byDevice: [String: [Entry]]

        init(history: [DriveSnapshot]) {
            let entries = history.enumerated().map { offset, snapshot in
                (snapshot.deviceID, Entry(date: snapshot.capturedAt, offset: offset, firmware: snapshot.firmware))
            }
            let ordered = entries.sorted {
                $0.1.date != $1.1.date ? $0.1.date < $1.1.date : $0.1.offset < $1.1.offset
            }
            all = ordered.map(\.1)
            byDevice = Dictionary(grouping: ordered, by: \.0).mapValues { $0.map(\.1) }
        }

        func firmware(near date: Date, deviceID: String?) -> String? {
            let entries = deviceID.map { byDevice[$0] ?? [] } ?? all
            guard !entries.isEmpty else { return nil }
            var low = 0, high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if entries[middle].date < date { low = middle + 1 } else { high = middle }
            }
            // Entries before `low` are earlier than `date`; `low` and after are not.
            var best: Entry?
            var bestDistance = TimeInterval.infinity
            func consider(_ entry: Entry) {
                let distance = abs(entry.date.timeIntervalSince(date))
                if distance < bestDistance || (distance == bestDistance && entry.offset < (best?.offset ?? .max)) {
                    best = entry
                    bestDistance = distance
                }
            }
            if low > 0 {
                // Every record sharing the nearest earlier time.
                let time = entries[low - 1].date
                var index = low - 1
                while index >= 0, entries[index].date == time { consider(entries[index]); index -= 1 }
            }
            if low < entries.count {
                let time = entries[low].date
                var index = low
                while index < entries.count, entries[index].date == time { consider(entries[index]); index += 1 }
            }
            return best?.firmware.flatMap(trimmedNonEmpty)
        }
    }

    static func build(
        snapshots: [ASPToolDiagnosticsSnapshot],
        smart: [DriveSnapshot],
        latest: ASPToolDiagnosticsSnapshot?
    ) -> WearContinuityLane {
        guard let latest else {
            return WearContinuityLane(snapshots: [], boundaries: [], rateLearningExclusions: [],
                collapsedSameSecondSnapshots: 0)
        }

        // Keep persisted order for captures sharing the same second. The
        // store appends in capture order, while UUID order is random and can
        // otherwise reverse two instrument epochs with second-level dates.
        let rawCandidates = snapshots
            .enumerated()
            .filter { _, snapshot in
                snapshot.sourceArtifact.participatesInCoreWearLane &&
                    snapshot.captureQuality != .unknown &&
                    snapshot.capturedAt <= latest.capturedAt
            }
            .sorted {
                if $0.element.capturedAt != $1.element.capturedAt {
                    return $0.element.capturedAt < $1.element.capturedAt
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
        let identities = IdentityCache(smart: smart)
        let normalized = collapseSameSecondDuplicates(rawCandidates, identities: identities)
        let candidates = normalized.snapshots
        let metadataChanges = absorbedMetadataChanges(in: candidates, identities: identities)
        guard let first = candidates.first else {
            return WearContinuityLane(snapshots: [], boundaries: [], rateLearningExclusions: [],
                instrumentMetadataChanges: metadataChanges,
                collapsedSameSecondSnapshots: normalized.collapsedCount)
        }

        var accepted = [first]
        var boundaries: [InstrumentBoundaryRecord] = []
        var exclusions: [DateInterval] = []
        var currentDevice = DeviceSeriesIdentity(snapshot: first)
        var lastAcceptedInstrument = identities(first)
        // A pending instrument is not accepted state.  Keep it separately so
        // that A(accepted) -> B(pending) -> C(new) compares C with A rather
        // than accidentally promoting B to the boundary origin.
        var pendingInstrument: InstrumentIdentity?
        var pendingBoundaryIndex: Int?
        var pendingSnapshots: [ASPToolDiagnosticsSnapshot] = []
        var blockedInstrument: InstrumentIdentity?
        var hasUnresolvedBoundary = false

        for sample in candidates.dropFirst() {
            let sampleDevice = DeviceSeriesIdentity(snapshot: sample)
            let sampleInstrument = identities(sample)

            if sampleDevice != currentDevice {
                let boundary = InstrumentBoundary(
                    before: accepted.last?.capturedAt ?? sample.capturedAt,
                    after: sample.capturedAt,
                    beforeIdentity: lastAcceptedInstrument.identity,
                    afterIdentity: sampleInstrument.identity,
                    hasPhysicalTransient: false
                )
                boundaries.append(InstrumentBoundaryRecord(
                    boundary: boundary,
                    continuity: .deviceChange(boundary: boundary),
                    checks: [],
                    rateLearningExclusion: nil,
                    note: "deviceIDが変化したため、別ドライブ系列として分離しました。",
                    oldBuildWasOverlayed: lastAcceptedInstrument.provenance != .recorded
                        || sampleInstrument.provenance != .recorded,
                    initialEvaluation: InstrumentBoundaryEvaluation(
                        evaluatedAt: sample.capturedAt,
                        continuity: .deviceChange(boundary: boundary),
                        checks: [],
                        note: "deviceIDが変化したため、別ドライブ系列として分離しました。"
                    ),
                    lastEvaluatedAt: sample.capturedAt,
                    beforeBuildProvenance: lastAcceptedInstrument.provenance,
                    afterBuildProvenance: sampleInstrument.provenance
                ))
                // A physical device change is the only condition that resets
                // the accepted lane. Geometry/topology/EOL changes are
                // audited at a measurement boundary instead.
                accepted = [sample]
                currentDevice = sampleDevice
                lastAcceptedInstrument = sampleInstrument
                pendingInstrument = nil
                pendingBoundaryIndex = nil
                pendingSnapshots = []
                blockedInstrument = nil
                hasUnresolvedBoundary = false
                continue
            }

            let structuralChange = structuralAttributesChanged(before: accepted.last, after: sample)
            if sampleInstrument.identity.isCompatibleMetadata(with: lastAcceptedInstrument.identity) && !structuralChange {
                // Do not re-enter the accepted series while another
                // instrument boundary is unresolved. A later retry can still
                // verify the pending instrument from the unchanged baseline.
                if !hasUnresolvedBoundary && blockedInstrument != sampleInstrument.identity {
                    accepted.append(sample)
                    lastAcceptedInstrument = sampleInstrument
                }
                continue
            }

            // A failed instrument is excluded until a genuinely different
            // instrument appears or the raw history is rebuilt with new
            // evidence.
            if blockedInstrument?.isCompatibleMetadata(with: sampleInstrument.identity) == true {
                continue
            }

            guard let before = accepted.last else {
                accepted = [sample]
                lastAcceptedInstrument = sampleInstrument
                pendingInstrument = nil
                pendingBoundaryIndex = nil
                pendingSnapshots = []
                blockedInstrument = nil
                hasUnresolvedBoundary = false
                continue
            }

            let retryingPendingBoundary = pendingInstrument?.isCompatibleMetadata(with: sampleInstrument.identity) == true
            // Preserve the record index before a verified retry clears the
            // pending state below. Otherwise the resolved evaluation is
            // appended as a duplicate boundary instead of replacing the
            // original pending record.
            let retryingPendingBoundaryIndex = retryingPendingBoundary ? pendingBoundaryIndex : nil
            let priorBoundaryRecord: InstrumentBoundaryRecord? = {
                guard let retryingPendingBoundaryIndex,
                      boundaries.indices.contains(retryingPendingBoundaryIndex) else { return nil }
                return boundaries[retryingPendingBoundaryIndex]
            }()
            let boundaryOrigin: Date = {
                guard let retryingPendingBoundaryIndex,
                      boundaries.indices.contains(retryingPendingBoundaryIndex) else {
                    return sample.capturedAt
                }
                return boundaries[retryingPendingBoundaryIndex].boundary.after
            }()
            let boundary = InstrumentBoundary(
                before: before.capturedAt,
                after: boundaryOrigin,
                beforeIdentity: lastAcceptedInstrument.identity,
                afterIdentity: sampleInstrument.identity,
                hasPhysicalTransient: hasPhysicalTransient(
                    before: lastAcceptedInstrument.identity,
                    after: sampleInstrument.identity
                )
            )
            let topologyEvidence = topologyEvidence(
                before: before,
                after: sample,
                history: candidates,
                identities: identities
            )
            let checks = continuityChecks(
                before: before,
                after: sample,
                history: candidates,
                smart: smart,
                topologyEvidence: topologyEvidence
            )
            let continuity = continuityStatus(
                boundary: boundary,
                checks: checks,
                evaluatedAt: sample.capturedAt
            )
            let beforeBuildProvenance = lastAcceptedInstrument.provenance
            let oldOverlay = beforeBuildProvenance != .recorded
                || sampleInstrument.provenance != .recorded
            let exclusion: DateInterval?
            switch continuity {
            case .verified:
                exclusion = boundary.hasPhysicalTransient
                    && postUpdateTransientSuspected(boundary: boundary, snapshots: candidates)
                    ? DateInterval(
                        start: boundary.before,
                        end: boundary.after.addingTimeInterval(72 * 3_600)
                    )
                    : nil
                let newlyAccepted = (pendingSnapshots + [sample]).sorted {
                    $0.capturedAt < $1.capturedAt
                }
                for candidate in newlyAccepted where candidate.capturedAt > (accepted.last?.capturedAt ?? .distantPast) {
                    accepted.append(candidate)
                }
                if let exclusion { exclusions.append(exclusion) }
                lastAcceptedInstrument = sampleInstrument
                pendingInstrument = nil
                pendingBoundaryIndex = nil
                pendingSnapshots = []
                blockedInstrument = nil
                hasUnresolvedBoundary = false
            case .pending:
                exclusion = nil
                // Keep the pre-boundary lane active. The raw post-boundary
                // snapshots are retained separately until a later audit.
                pendingInstrument = sampleInstrument.identity
                pendingSnapshots.append(sample)
                blockedInstrument = nil
                hasUnresolvedBoundary = true
            case .failed, .deviceChange, .reviewed, .sameInstrument:
                exclusion = nil
                blockedInstrument = sampleInstrument.identity
                pendingInstrument = nil
                pendingBoundaryIndex = nil
                pendingSnapshots = []
                hasUnresolvedBoundary = true
            }

            let note: String
            switch continuity {
            case .verified:
                note = !boundary.hasPhysicalTransient
                    ? "コアcounter連続性をD1〜D7で確認。firmwareが変わらない境界のため率学習除外はありません。"
                    : (exclusion != nil
                        ? "コアcounter連続性をD1〜D7で確認。firmware更新後のWAFが直前7日から25%超ずれた（または判定資料不足の）ため、境界前から72時間を率学習から除外します。表示・現在値・長基線には含めます。"
                        : "コアcounter連続性をD1〜D7で確認。firmware更新後72時間のWAFが直前7日と25%以内のため、率学習除外はありません。")
            case .pending:
                note = "SMART Host比／Power On Hoursの境界資料が不足。rawは保持し、後続のSMART取得後に再評価します。"
            case .failed:
                note = "D1〜D7のいずれかが不一致。rawは保持し、境界後の損耗率学習へは投入しません。"
            case .deviceChange:
                note = "deviceIDが変化したため、別ドライブ系列として分離しました。"
            default:
                note = "instrument identity boundary"
            }
            let evaluation = InstrumentBoundaryEvaluation(
                evaluatedAt: sample.capturedAt,
                continuity: continuity,
                checks: checks,
                note: note
            )
            let initialEvaluation = priorBoundaryRecord?.initialEvaluation
                ?? priorBoundaryRecord.map {
                    InstrumentBoundaryEvaluation(
                        evaluatedAt: $0.lastEvaluatedAt ?? $0.boundary.after,
                        continuity: $0.continuity,
                        checks: $0.checks,
                        note: $0.note
                    )
                }
                ?? evaluation
            let record = InstrumentBoundaryRecord(
                boundary: boundary,
                continuity: continuity,
                checks: checks,
                rateLearningExclusion: exclusion,
                note: note,
                oldBuildWasOverlayed: oldOverlay,
                initialEvaluation: initialEvaluation,
                lastEvaluatedAt: sample.capturedAt,
                beforeBuildProvenance: beforeBuildProvenance,
                afterBuildProvenance: sampleInstrument.provenance
            )
            if let retryingPendingBoundaryIndex,
               boundaries.indices.contains(retryingPendingBoundaryIndex) {
                boundaries[retryingPendingBoundaryIndex] = record
            } else {
                boundaries.append(record)
                if case .pending = continuity {
                    pendingBoundaryIndex = boundaries.count - 1
                }
            }
        }

        return WearContinuityLane(
            snapshots: accepted,
            boundaries: boundaries,
            rateLearningExclusions: exclusions,
            instrumentMetadataChanges: metadataChanges,
            collapsedSameSecondSnapshots: normalized.collapsedCount
        )
    }

    private static func absorbedMetadataChanges(
        in snapshots: [ASPToolDiagnosticsSnapshot],
        identities: IdentityCache
    ) -> [InstrumentMetadataChangeRecord] {
        zip(snapshots, snapshots.dropFirst()).compactMap { before, after in
            guard DeviceSeriesIdentity(snapshot: before) == DeviceSeriesIdentity(snapshot: after) else { return nil }
            let beforeIdentity = identities(before).identity
            let afterIdentity = identities(after).identity
            guard beforeIdentity == afterIdentity else { return nil }

            var changes: [String] = []
            if let old = beforeIdentity.probeVersion,
               let new = afterIdentity.probeVersion,
               old != new {
                changes.append("probe版 \(old) → \(new)")
            }
            if let old = beforeIdentity.extractionVersion,
               let new = afterIdentity.extractionVersion,
               old != new {
                changes.append("抽出版 \(old) → \(new)")
            }
            guard !changes.isEmpty else { return nil }
            return InstrumentMetadataChangeRecord(
                beforeAt: before.capturedAt,
                afterAt: after.capturedAt,
                beforeIdentity: beforeIdentity,
                afterIdentity: afterIdentity,
                changedAttributes: changes
            )
        }
    }

    /// Persisted timestamps have whole-second precision. If two captures from
    /// the same instrument have the same timestamp and identical wear state,
    /// keep the component-wise later Host/NAND counter as the lane sample.
    /// Counter-incomparable duplicates remain separate and therefore cannot
    /// be silently reconciled.
    private static func collapseSameSecondDuplicates(
        _ candidates: [ASPToolDiagnosticsSnapshot],
        identities: IdentityCache
    ) -> (snapshots: [ASPToolDiagnosticsSnapshot], collapsedCount: Int) {
        var normalized: [ASPToolDiagnosticsSnapshot] = []
        var collapsedCount = 0

        for sample in candidates {
            guard let previous = normalized.last,
                  previous.capturedAt == sample.capturedAt,
                  identities(previous).identity == identities(sample).identity,
                  previous.hostWritesUnitState == sample.hostWritesUnitState,
                  previous.nandWritesUnitState == sample.nandWritesUnitState,
                  previous.tlcAveragePE == sample.tlcAveragePE,
                  previous.tlcMaximumPE == sample.tlcMaximumPE,
                  previous.tlcEOLPE == sample.tlcEOLPE,
                  previous.slcAveragePE == sample.slcAveragePE,
                  previous.slcMaximumPE == sample.slcMaximumPE,
                  previous.slcEOLPE == sample.slcEOLPE,
                  previous.directTopology == sample.directTopology,
                  let previousHost = previous.hostWrites,
                  let previousNAND = previous.nandWrites,
                  let sampleHost = sample.hostWrites,
                  let sampleNAND = sample.nandWrites else {
                normalized.append(sample)
                continue
            }

            if sampleHost >= previousHost && sampleNAND >= previousNAND {
                if sampleHost > previousHost || sampleNAND > previousNAND
                    || captureCompleteness(sample) > captureCompleteness(previous) {
                    normalized[normalized.count - 1] = sample
                }
                collapsedCount += 1
            } else if previousHost >= sampleHost && previousNAND >= sampleNAND {
                collapsedCount += 1
            } else {
                normalized.append(sample)
            }
        }

        return (normalized, collapsedCount)
    }

    private static func captureCompleteness(_ snapshot: ASPToolDiagnosticsSnapshot) -> Int {
        [
            snapshot.powerOnHours != nil,
            snapshot.directTopology != nil,
            snapshot.researchTelemetry != nil,
            snapshot.tlcAveragePE != nil,
            snapshot.tlcMaximumPE != nil,
            snapshot.slcAveragePE != nil,
            snapshot.slcMaximumPE != nil
        ].filter { $0 }.count
    }

    private static func continuityStatus(
        boundary: InstrumentBoundary,
        checks: [ContinuityCheckResult],
        evaluatedAt: Date
    ) -> InstrumentContinuity {
        let d1ToD7 = checks.filter { $0.kind != .d8BoundaryWAF }
        let immediateFailureKinds: Set<ContinuityCheckKind> = [
            .d1Geometry, .d2Topology, .d3EOL, .d4Monotonic,
            .d5SmartHostRatio, .d6PowerOnHours
        ]
        if d1ToD7.contains(where: { immediateFailureKinds.contains($0.kind) && $0.available && !$0.passed }) {
            return .failed(boundary: boundary, checks: checks)
        }

        if let d7 = d1ToD7.first(where: { $0.kind == .d7LifetimeResidual }),
           d7.available, !d7.passed {
            let elapsed = evaluatedAt.timeIntervalSince(boundary.after)
            if boundary.hasPhysicalTransient && elapsed < 72 * 3_600 {
                return .pending(boundary: boundary)
            }
            return .failed(boundary: boundary, checks: checks)
        }

        // Missing evidence is pending, not failed. A later snapshot can
        // supply the missing D1-D7 material without rewriting raw history.
        if d1ToD7.contains(where: { !$0.available }) {
            return .pending(boundary: boundary)
        }
        return .verified(boundary: boundary, checks: checks)
    }

    private static func hasPhysicalTransient(
        before: InstrumentIdentity,
        after: InstrumentIdentity
    ) -> Bool {
        // Switching between an extracted asptool artifact and the Direct FTL
        // collector is an acquisition-route boundary, not a physical update.
        // It is audited by D1-D7 but must not create a post-update WAF window.
        guard before.sourceArtifact == after.sourceArtifact else { return false }
        // An OS update with unchanged SSD firmware keeps the same controller
        // behaviour; any host-side activity after it is real workload.
        return before.firmwareEpoch != after.firmwareEpoch
    }

    /// A firmware boundary is excluded from rate learning only when the data
    /// shows a post-update transient: the WAF over up to 72 hours after the
    /// boundary deviates from the preceding 7-day WAF by more than
    /// `postUpdateWAFTolerance`. Until enough post-boundary writes exist to
    /// judge, the boundary stays excluded.
    static let postUpdateWindow: TimeInterval = 72 * 3_600
    static let postUpdateBaselineWindow: TimeInterval = 7 * 86_400
    static let postUpdateWAFTolerance = 0.25
    static let postUpdateMinimumHostBytes = 1_000_000_000.0

    static func postUpdateTransientSuspected(
        boundary: InstrumentBoundary,
        snapshots: [ASPToolDiagnosticsSnapshot]
    ) -> Bool {
        func waf(from start: ASPToolDiagnosticsSnapshot, to end: ASPToolDiagnosticsSnapshot) -> (waf: Double, host: Double)? {
            guard let host0 = start.hostWrittenBytes, let host1 = end.hostWrittenBytes,
                  let nand0 = start.nandWrittenBytes, let nand1 = end.nandWrittenBytes,
                  host1 > host0, nand1 >= nand0 else { return nil }
            return ((nand1 - nand0) / (host1 - host0), host1 - host0)
        }
        let ordered = snapshots.sorted { $0.capturedAt < $1.capturedAt }
        guard let boundaryStart = ordered.last(where: { $0.capturedAt <= boundary.before }),
              let baselineStart = ordered.first(where: {
                  $0.capturedAt >= boundary.before.addingTimeInterval(-postUpdateBaselineWindow)
              }),
              let baseline = waf(from: baselineStart, to: boundaryStart),
              baseline.waf > 0,
              let postEnd = ordered.last(where: {
                  $0.capturedAt > boundary.after && $0.capturedAt <= boundary.after.addingTimeInterval(postUpdateWindow)
              }),
              let post = waf(from: boundaryStart, to: postEnd),
              post.host >= postUpdateMinimumHostBytes
        else { return true }
        return abs(post.waf / baseline.waf - 1) > postUpdateWAFTolerance
    }

    static func structuralAttributesChanged(
        before: ASPToolDiagnosticsSnapshot?,
        after: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        guard let before else { return false }
        if let lhs = before.directTopology, let rhs = after.directTopology,
           !lhs.isEquivalentGeometry(to: rhs) {
            return true
        }
        let eolPairs: [(Double?, Double?)] = [
            (before.tlcEOLPE, after.tlcEOLPE),
            (before.slcEOLPE, after.slcEOLPE)
        ]
        return eolPairs.contains { lhs, rhs in
            if let lhs, let rhs { return lhs != rhs }
            return false
        }
    }

    private static func continuityChecks(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        history: [ASPToolDiagnosticsSnapshot],
        smart: [DriveSnapshot],
        topologyEvidence: DirectFTLTopology?
    ) -> [ContinuityCheckResult] {
        [
            geometryCheck(before: before, after: after, topologyEvidence: topologyEvidence),
            topologyCheck(before: before, after: after, topologyEvidence: topologyEvidence),
            eolCheck(before: before, after: after),
            monotonicCheck(before: before, after: after),
            smartHostRatioCheck(before: before, after: after, smart: smart),
            powerOnHoursCheck(before: before, after: after, smart: smart),
            lifetimeResidualCheck(before: before, after: after, topologyEvidence: topologyEvidence),
            boundaryWAFCheck(before: before, after: after, history: history)
        ]
    }

    /// A Direct topology can arrive after the original instrument boundary
    /// (for example, an early FTL capture lacked the topology keys). Reuse it
    /// only as in-memory structural evidence for the same physical device and
    /// stable core-wear contract. Never copy it into persisted raw snapshots.
    private static func topologyEvidence(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        history: [ASPToolDiagnosticsSnapshot],
        identities: IdentityCache
    ) -> DirectFTLTopology? {
        guard before.directTopology == nil, after.directTopology == nil,
              let deviceID = after.deviceID, before.deviceID == deviceID else { return nil }

        let beforeIdentity = identities(before).identity
        let afterIdentity = identities(after).identity
        guard let coreVersion = beforeIdentity.keyContractVersion,
              coreVersion == afterIdentity.keyContractVersion else { return nil }

        let laterTopologies = history
            .filter {
                $0.deviceID == deviceID &&
                    $0.sourceArtifact == .directFTL &&
                    $0.captureQuality != .unknown &&
                    $0.capturedAt >= after.capturedAt &&
                    identities($0).identity.keyContractVersion == coreVersion
            }
            .compactMap(\.directTopology)
        guard let topology = laterTopologies.first,
              topology.topologyContractValidated,
              laterTopologies.allSatisfy({ $0.isEquivalentGeometry(to: topology) }) else { return nil }
        return topology
    }

    private static func geometryCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        topologyEvidence: DirectFTLTopology?
    ) -> ContinuityCheckResult {
        let lhs = before.directTopology ?? topologyEvidence
        let rhs = after.directTopology ?? topologyEvidence
        guard lhs != nil || rhs != nil else {
            return ContinuityCheckResult(kind: .d1Geometry, passed: false, available: false, detail: "geometry未取得")
        }
        // Geometry differs between SSD capacities and NAND generations, so a
        // boundary is continuous when the geometry is unchanged across it,
        // not when it matches one reviewed device.
        let known = [lhs, rhs].compactMap { $0 }
        let passed = known.allSatisfy(\.topologyContractValidated)
            && (lhs == nil || rhs == nil || lhs!.isEquivalentGeometry(to: rhs!))
        let reference = known[0]
        let structuralSource = before.directTopology == nil && after.directTopology == nil
            ? "同device・同じcoreの対応表の後続Direct geometryを解析時適用"
            : (lhs == nil || rhs == nil
                ? "片側でgeometryを確認（欠落側へ同一geometryを適用）"
                : "bytes/page \(reference.bytesPerPage)・native \(reference.pagesPerVirtualBlock)・SLC \(reference.pagesPerVirtualBlockSLC)（境界前後で一致）")
        let detail = passed
            ? structuralSource
            : "geometryが境界前後で不一致"
        return ContinuityCheckResult(kind: .d1Geometry, passed: passed, available: true,
            detail: detail)
    }

    private static func topologyCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        topologyEvidence: DirectFTLTopology?
    ) -> ContinuityCheckResult {
        let lhs = before.directTopology ?? topologyEvidence
        let rhs = after.directTopology ?? topologyEvidence
        guard lhs != nil || rhs != nil else {
            return ContinuityCheckResult(kind: .d2Topology, passed: false, available: false, detail: "topology未取得")
        }
        let known = [lhs, rhs].compactMap { $0 }
        let sameBoundaries: (DirectFTLTopology, DirectFTLTopology) -> Bool = {
            $0.numVirtualBlocks == $1.numVirtualBlocks &&
                $0.intermediatePartitionStart == $1.intermediatePartitionStart &&
                $0.userPartitionStart == $1.userPartitionStart
        }
        let passed = known.allSatisfy(\.topologyContractValidated)
            && (lhs == nil || rhs == nil || sameBoundaries(lhs!, rhs!))
        let reference = known[0]
        let structuralSource = before.directTopology == nil && after.directTopology == nil
            ? "同device・同じcoreの対応表の後続Direct topologyを解析時適用"
            : (lhs == nil || rhs == nil
                ? "片側でtopologyを確認（欠落側へ同一topologyを適用）"
                : "virtual \(reference.numVirtualBlocks)・intermediate \(reference.intermediatePartitionStart)・user \(reference.userPartitionStart)（境界前後で一致）")
        return ContinuityCheckResult(kind: .d2Topology, passed: passed, available: true,
            detail: passed
                ? structuralSource
                : "partition boundary不一致")
    }

    private static func eolCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot
    ) -> ContinuityCheckResult {
        let values = [before.tlcEOLPE, before.slcEOLPE, after.tlcEOLPE, after.slcEOLPE]
        guard values.allSatisfy({ $0?.isFinite == true }) else {
            return ContinuityCheckResult(kind: .d3EOL, passed: false, available: false, detail: "EOL未取得")
        }
        // EOL ratings are vendor/NAND specific; continuity only requires that
        // the controller reports the same ratings on both sides.
        let passed = values.allSatisfy { ($0 ?? 0) > 0 }
            && before.tlcEOLPE == after.tlcEOLPE
            && before.slcEOLPE == after.slcEOLPE
        let rating = "TLC \(Int(after.tlcEOLPE ?? 0)) / pSLC \(Int(after.slcEOLPE ?? 0))"
        return ContinuityCheckResult(kind: .d3EOL, passed: passed, available: true,
            detail: passed ? "\(rating)（境界前後で一致）" : "EOLが境界前後で不一致")
    }

    private static func monotonicCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot
    ) -> ContinuityCheckResult {
        let values: [(String, Double?, Double?)] = [
            ("Host", before.hostWrittenBytes, after.hostWrittenBytes),
            ("NAND", before.nandWrittenBytes, after.nandWrittenBytes),
            ("TLC avg PE", before.tlcAveragePE, after.tlcAveragePE),
            ("pSLC avg PE", before.slcAveragePE, after.slcAveragePE),
            ("TLC max PE", before.tlcMaximumPE, after.tlcMaximumPE),
            ("pSLC max PE", before.slcMaximumPE, after.slcMaximumPE),
            // `.map(Double.init)` on UInt64 picks Double(bitPattern:); convert by value.
            ("POH", before.powerOnHours.map { Double($0) }, after.powerOnHours.map { Double($0) })
        ]
        guard values.allSatisfy({ $0.1?.isFinite == true && $0.2?.isFinite == true }) else {
            return ContinuityCheckResult(kind: .d4Monotonic, passed: false, available: false, detail: "core counter不足")
        }
        let passed = values.allSatisfy { pair in pair.2! >= pair.1! }
        return ContinuityCheckResult(kind: .d4Monotonic, passed: passed, available: true,
            detail: passed ? "Host/NAND/P-E/POHは単調" : "core counterの逆行")
    }

    private static func smartHostRatioCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        smart: [DriveSnapshot]
    ) -> ContinuityCheckResult {
        guard let lhs = smartHostRatio(at: before.capturedAt, ftl: before, smart: smart),
              let rhs = smartHostRatio(at: after.capturedAt, ftl: after, smart: smart) else {
            return ContinuityCheckResult(kind: .d5SmartHostRatio, passed: false, available: false, detail: "近接SMART Host Writes不足")
        }
        // The specification defines the change relative to the pre-boundary
        // ratio r(B).  A zero baseline is not evidence that the counters are
        // compatible; it is an unavailable comparison instead.
        guard lhs > 0, rhs >= 0 else {
            return ContinuityCheckResult(
                kind: .d5SmartHostRatio,
                passed: false,
                available: false,
                detail: "SMART Host比の基準値が0または不正です"
            )
        }
        let relative = abs(rhs - lhs) / lhs
        // Once SMART history is thinned to one sample a day, interpolation can
        // be off by a few GB of writes; early in a drive's life that alone is
        // more than 0.5%, so the limit never drops below 5 GB.
        let smartBytes = smartHostBytes(at: before.capturedAt, ftl: before, smart: smart)
        let limit = max(0.005, smartBytes.map { 5e9 / $0 } ?? 0)
        let passed = relative.isFinite && relative <= limit
        return ContinuityCheckResult(kind: .d5SmartHostRatio, passed: passed, available: true,
            detail: "FTL Host / SMART Host比 \(String(format: "%.6f", rhs))（変化 \(String(format: "%.3f%%", relative * 100))）",
            value: rhs, relativeChange: relative)
    }

    private static func powerOnHoursCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        smart: [DriveSnapshot]
    ) -> ContinuityCheckResult {
        guard let lhsSample = matchedSmart(at: before.capturedAt, deviceID: before.deviceID, smart: smart),
              let rhsSample = matchedSmart(at: after.capturedAt, deviceID: after.deviceID, smart: smart),
              let lhs = lhsSample.powerOnHours, let rhs = rhsSample.powerOnHours,
              let ftlBefore = before.powerOnHours, let ftlAfter = after.powerOnHours else {
            return ContinuityCheckResult(kind: .d6PowerOnHours, passed: false, available: false, detail: "FTL／SMART POH不足")
        }
        let beforeResidual = Double(ftlBefore) - Double(lhs)
        let afterResidual = Double(ftlAfter) - Double(rhs)
        let change = abs(afterResidual - beforeResidual)
        // Same allowance as the per-read check: the drive can be powered for
        // at most the time between the FTL read and the SMART sample it is
        // compared with, which grows once SMART history is thinned.
        let tolerance = 2 + (abs(lhsSample.capturedAt.timeIntervalSince(before.capturedAt))
            + abs(rhsSample.capturedAt.timeIntervalSince(after.capturedAt))) / 3_600
        let passed = change.isFinite && change <= tolerance
        return ContinuityCheckResult(kind: .d6PowerOnHours, passed: passed, available: true,
            detail: "FTL−SMART POH差の変化 \(String(format: "%.2f", change)) h",
            value: afterResidual, relativeChange: change)
    }

    private static func lifetimeResidualCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        topologyEvidence: DirectFTLTopology?
    ) -> ContinuityCheckResult {
        let sharedTopology = after.directTopology ?? before.directTopology ?? topologyEvidence
        guard let lhs = residualInterval(for: before, topology: sharedTopology),
              let rhs = residualInterval(for: after, topology: sharedTopology) else {
            return ContinuityCheckResult(kind: .d7LifetimeResidual, passed: false, available: false, detail: "生涯残差の容量／P-E不足")
        }
        let intersects = max(lhs.lowerBound, rhs.lowerBound) <= min(lhs.upperBound, rhs.upperBound)
        let usesLaterEvidence = before.directTopology == nil && after.directTopology == nil && topologyEvidence != nil
        return ContinuityCheckResult(kind: .d7LifetimeResidual, passed: intersects, available: true,
            detail: intersects
                ? (usesLaterEvidence ? "同device・同じcoreの対応表の後続Direct topologyを解析時適用した生涯残差レンジが連続" : (before.directTopology == nil || after.directTopology == nil ? "片側の同一topologyを適用した生涯残差レンジが連続" : "生涯残差レンジが連続"))
                : "生涯残差レンジが非連続",
            value: rhs.center)
    }

    private static func boundaryWAFCheck(
        before: ASPToolDiagnosticsSnapshot,
        after: ASPToolDiagnosticsSnapshot,
        history: [ASPToolDiagnosticsSnapshot]
    ) -> ContinuityCheckResult {
        guard let prior = history
            .filter({ $0.capturedAt < before.capturedAt && ControllerWearSeriesIdentity(snapshot: $0) == ControllerWearSeriesIdentity(snapshot: before) })
            .sorted(by: { $0.capturedAt < $1.capturedAt }).last,
            let priorHost = prior.hostWrittenBytes, let priorNAND = prior.nandWrittenBytes,
            let beforeHost = before.hostWrittenBytes, let beforeNAND = before.nandWrittenBytes,
            let afterHost = after.hostWrittenBytes, let afterNAND = after.nandWrittenBytes else {
            return ContinuityCheckResult(kind: .d8BoundaryWAF, passed: true, available: false, detail: "境界前WAFの比較資料なし（ゲート外）")
        }
        guard beforeHost >= priorHost, beforeNAND >= priorNAND,
              afterHost >= beforeHost, afterNAND >= beforeNAND else {
            return ContinuityCheckResult(kind: .d8BoundaryWAF, passed: true, available: false, detail: "境界counter逆行のためWAFを算出しません（ゲート外）")
        }
        let priorHostDelta = beforeHost - priorHost
        let priorNANDDelta = beforeNAND - priorNAND
        let boundaryHostDelta = afterHost - beforeHost
        let boundaryNANDDelta = afterNAND - beforeNAND
        guard priorHostDelta > 0, priorNANDDelta >= 0, boundaryHostDelta > 0, boundaryNANDDelta >= 0 else {
            return ContinuityCheckResult(kind: .d8BoundaryWAF, passed: true, available: false, detail: "境界WAFの分母不足（ゲート外）")
        }
        let priorWAF = priorNANDDelta / priorHostDelta
        let boundaryWAF = boundaryNANDDelta / boundaryHostDelta
        let ratio = boundaryWAF / priorWAF
        let passed = ratio.isFinite && ratio >= 0.25 && ratio <= 4
        return ContinuityCheckResult(kind: .d8BoundaryWAF, passed: passed, available: true,
            detail: "境界WAF／直前WAF \(String(format: "%.3f", ratio))（注記のみ）", value: ratio)
    }

    private static func residualInterval(
        for snapshot: ASPToolDiagnosticsSnapshot,
        topology: DirectFTLTopology?
    ) -> (lowerBound: Double, upperBound: Double, center: Double)? {
        guard let topology = snapshot.directTopology ?? topology,
              let tlcCapacity = topology.tlcCapacityBytes,
              let pslcCapacity = topology.pslcWritableCapacityBytes,
              let nand = snapshot.nandWrittenBytes,
              let tlcPE = snapshot.tlcAveragePE,
              let pslcPE = snapshot.slcAveragePE,
              [tlcCapacity, pslcCapacity, nand, tlcPE, pslcPE].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let known = tlcCapacity * tlcPE + pslcCapacity * pslcPE
        let residual = nand - known
        let tolerance = 0.5 * (tlcCapacity + pslcCapacity)
        guard known.isFinite, residual.isFinite, tolerance.isFinite else { return nil }
        return (residual - tolerance, residual + tolerance, residual)
    }

    private static func smartHostRatio(
        at date: Date,
        ftl: ASPToolDiagnosticsSnapshot,
        smart: [DriveSnapshot]
    ) -> Double? {
        guard let hostWrites = ftl.hostWrites else { return nil }
        let hostBytes = Double(hostWrites) * 4_096
        guard hostBytes.isFinite, let smartBytes = smartHostBytes(at: date, ftl: ftl, smart: smart) else { return nil }
        return hostBytes / smartBytes
    }

    private static func smartHostBytes(
        at date: Date,
        ftl: ASPToolDiagnosticsSnapshot,
        smart: [DriveSnapshot]
    ) -> Double? {
        let matches = smart
            .filter { (ftl.deviceID == nil || $0.deviceID == ftl.deviceID) && $0.dataUnitsWritten != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let units = interpolated(
            at: date,
            samples: matches.compactMap { sample in sample.dataUnitsWritten.map { (sample.capturedAt, Double($0)) } }
        ) else { return nil }
        let smartBytes = units * 512_000
        guard smartBytes > 0, smartBytes.isFinite else { return nil }
        return smartBytes
    }

    private static func matchedSmart(
        at date: Date,
        deviceID: String?,
        smart: [DriveSnapshot]
    ) -> DriveSnapshot? {
        smart
            .filter { (deviceID == nil || $0.deviceID == deviceID) && abs($0.capturedAt.timeIntervalSince(date)) <= 86_400 }
            .min { abs($0.capturedAt.timeIntervalSince(date)) < abs($1.capturedAt.timeIntervalSince(date)) }
    }

    /// Returns an interpolated value only when both sides are within one day
    /// of the requested timestamp.  Keeping this helper internal lets the
    /// regression suite pin the no-long-gap rule without exposing it as app
    /// API.
    static func interpolated(
        at date: Date,
        samples: [(Date, Double)]
    ) -> Double? {
        guard !samples.isEmpty else { return nil }
        if let exact = samples.first(where: { $0.0 == date }) { return exact.1 }
        let before = samples.last(where: { $0.0 < date })
        let after = samples.first(where: { $0.0 > date })
        if let before, let after,
           after.0.timeIntervalSince(before.0) > 0,
           date.timeIntervalSince(before.0) <= 86_400,
           after.0.timeIntervalSince(date) <= 86_400 {
            let fraction = date.timeIntervalSince(before.0) / after.0.timeIntervalSince(before.0)
            let result = before.1 + (after.1 - before.1) * fraction
            return result.isFinite ? result : nil
        }
        let nearest = samples.min { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) }
        guard let nearest, abs(nearest.0.timeIntervalSince(date)) <= 86_400 else { return nil }
        return nearest.1
    }
}
