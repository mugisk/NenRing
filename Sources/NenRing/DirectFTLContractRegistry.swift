import Foundation

enum DirectFTLContractReviewStatus: String, Codable, Equatable, Sendable {
    case reviewed
    case provisional
}

struct DirectFTLContractDescriptor: Equatable, Sendable {
    let contractBuild: String
    /// macOS major versions whose private FTL interface was reviewed. Layout
    /// changes are expected at major releases, so minor builds of a reviewed
    /// major version are accepted and every read is cross-checked instead.
    let reviewedMacOSMajorVersions: Set<Int>
    /// IORegistry `chip-id` values whose key layout was reviewed. `chip-id`
    /// names the MSP die inside the NAND package, not the SoC: S5E appears on
    /// M1-family Macs (and the A18 Pro MacBook Neo), S6E on M5. A reviewed
    /// chip-id plus the per-read SMART cross-check guards other SoCs.
    let reviewedControllerChipIDs: Set<String>
    let serviceName: String
    let pluginUUID: String
    let interfaceUUID: String
    let allVtableOffset: UInt32
    let permVtableOffset: UInt32
    let payloadShapeVersion: String
    let keySemanticsVersion: String
    let semanticContractVersion: String
    let legacySemanticContractVersions: Set<String>
    let coreWearContractVersion: String
    let researchTelemetryContractVersion: String
    let topologySchemaVersion: String
    let maximumHistogramBins: Int
    let maximumTierValues: Int
    let fixtureIdentity: String
    let reviewStatus: DirectFTLContractReviewStatus

    func expectedVtableOffset(kindRawValue: String) -> UInt32? {
        switch kindRawValue {
        case "all": return allVtableOffset
        case "perm": return permVtableOffset
        default: return nil
        }
    }

    func matchesInterface(
        service: String,
        pluginUUID: String,
        interfaceUUID: String,
        kindRawValue: String,
        vtableOffset: UInt32
    ) -> Bool {
        guard service == serviceName,
              pluginUUID.caseInsensitiveCompare(self.pluginUUID) == .orderedSame,
              interfaceUUID.caseInsensitiveCompare(self.interfaceUUID) == .orderedSame,
              let expectedOffset = expectedVtableOffset(kindRawValue: kindRawValue)
        else { return false }
        return expectedOffset == vtableOffset
    }

    func isReviewedHardware(chipID: String?) -> Bool {
        guard let chipID = chipID?.trimmingCharacters(in: .whitespacesAndNewlines), !chipID.isEmpty else {
            return false
        }
        return reviewedControllerChipIDs.contains(chipID)
    }

    func isReviewedRuntime(_ build: String?) -> Bool {
        guard let major = DirectFTLContractRegistry.macOSMajorVersion(fromBuild: build) else { return false }
        return reviewedMacOSMajorVersions.contains(major)
    }

}

/// Build-scoped private FTL contracts. Adding support for a new macOS build or
/// Apple Silicon generation should add a descriptor here rather than branching
/// parser arithmetic throughout the codebase.
enum DirectFTLContractRegistry {
    /// Trial collection is not a reviewed ABI/key contract. Keep the set
    /// explicit: macOS skipped from 15 to 26; future majors are not opted in.
    static let compatibilityTrialMacOSMajorVersions: Set<Int> = [14, 15]

    static var isAppleSiliconHost: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Maps a build such as "26A434" to its macOS major version. The leading
    /// number is the Darwin major: Darwin 25+ is macOS 26+ (Darwin + 1);
    /// earlier releases were macOS 11–15 (Darwin − 9).
    static func macOSMajorVersion(fromBuild build: String?) -> Int? {
        guard let build else { return nil }
        let digits = build.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < build.count, let darwin = Int(digits) else { return nil }
        return darwin >= 25 ? darwin + 1 : darwin - 9
    }

    static let reviewed25G83 = DirectFTLContractDescriptor(
        contractBuild: "25G83",
        // macOS 26 (25G83) and macOS 27 (26A434): the system diagnostic tool
        // selects vtable 0x108 (all) / 0x110 (perm) on the same NVMe SMART
        // interface, and the 26A428 -> 26A434 boundary passes D1-D8 on live
        // data. See docs/DATA_ACQUISITION.md and
        // docs/INSTRUMENT_BOUNDARY_CONTINUITY.md.
        reviewedMacOSMajorVersions: [26, 27],
        // Reviewed on one M1 MacBook Air (APPLE SSD AP0256Q, Hynix V6 TLC).
        reviewedControllerChipIDs: ["S5E"],
        serviceName: "GetNVMeSMARTInterface",
        pluginUUID: "AA0FA6F9-C2D6-457F-B10B-59A13253292F",
        interfaceUUID: "CCD1DB19-FD9A-4DAF-BF95-12454B230AB6",
        allVtableOffset: 0x108,
        permVtableOffset: 0x110,
        payloadShapeVersion: "ftl-key-count-u64-table-v1",
        keySemanticsVersion: "25G83-key-map-v2.4.1",
        semanticContractVersion: "25G83-ftl-all-research-v2.4.1",
        legacySemanticContractVersions: ["25G83-ftl-all-research-v2.4"],
        coreWearContractVersion: "25G83-core-v1",
        researchTelemetryContractVersion: "25G83-research-v2.4.1",
        topologySchemaVersion: "direct-topology-v1",
        maximumHistogramBins: 1_024,
        maximumTierValues: 64,
        fixtureIdentity: "25G83-reviewed-direct-ftl-fixture",
        reviewStatus: .reviewed
    )

    static let descriptors: [DirectFTLContractDescriptor] = [
        reviewed25G83
    ]

    static func descriptor(contractBuild: String?) -> DirectFTLContractDescriptor? {
        guard let contractBuild else { return nil }
        return descriptors.first { $0.contractBuild == contractBuild }
    }

    static func descriptor(runtimeBuild: String?) -> DirectFTLContractDescriptor? {
        guard let runtimeBuild else { return nil }
        return descriptors.first { $0.isReviewedRuntime(runtimeBuild) }
    }
}

/// Whether the private FTL interface may be called automatically on this Mac.
/// macOS 14/15 are explicitly allowed compatibility trials, not reviewed
/// contracts. Other unreviewed environments require a manual/local opt-in.
enum DirectFTLExecutionReview: Equatable, Sendable {
    case reviewed
    /// Collection may be attempted with the reviewed interface contract;
    /// this OS's ABI and private-key meanings have not been reviewed.
    case compatibilityTrial(macOSMajor: Int)
    /// Not reviewed by the project, but a read on this macOS major
    /// version passed the SMART cross-check on this Mac.
    case locallyVerified(macOSMajor: Int)
    case unreviewedBuild(String?)

    var isReviewed: Bool { self == .reviewed }

    var allowsAutomaticCollection: Bool {
        switch self {
        case .reviewed, .compatibilityTrial, .locallyVerified: return true
        case .unreviewedBuild: return false
        }
    }

    var detail: String {
        switch self {
        case .reviewed:
            return "確認済みのmacOSです"
        case let .compatibilityTrial(major):
            return UIString.format("macOS %d は互換性を想定した取得対象です（読み解き方は未確認）", major)
        case let .locallyVerified(major):
            return "macOS \(major) はこのMacでSMARTと照合済みです"
        case let .unreviewedBuild(build):
            return "macOS build \(build ?? "不明") はまだ確認していません"
        }
    }
}

extension DirectFTLContractRegistry {
    /// Whether scheduled collection may call the private interface.
    /// - A reviewed macOS major version is enough; the SSD controller is not
    ///   gated, because every read is cross-checked against SMART before it
    ///   is stored. This detects inconsistencies, not every semantic change.
    /// - macOS 14/15 may try FTL all under normal rights without a prior
    ///   manual read. They remain unreviewed; per-read and boundary gates apply.
    /// - Any other macOS major version becomes eligible on this Mac once a
    ///   manual read on it has passed the cross-check (`locallyVerifiedMajors`).
    ///   Releases outside the explicit trial set require user initiation.
    static func executionReview(
        runtimeBuild: String?,
        locallyVerifiedMajors: Set<Int> = []
    ) -> DirectFTLExecutionReview {
        if descriptor(runtimeBuild: runtimeBuild) != nil { return .reviewed }
        if let major = macOSMajorVersion(fromBuild: runtimeBuild), locallyVerifiedMajors.contains(major) {
            return .locallyVerified(macOSMajor: major)
        }
        if let major = macOSMajorVersion(fromBuild: runtimeBuild), compatibilityTrialMacOSMajorVersions.contains(major) {
            return .compatibilityTrial(macOSMajor: major)
        }
        return .unreviewedBuild(runtimeBuild)
    }
}

/// Per-read plausibility check against independent SMART counters. It detects
/// host/unit mismatches and POH offset changes, not every private-key semantic
/// change. Boundary continuity still gates forecast inputs separately. Missing
/// required Host/P-E inputs prevent persistence; optional POH has a pending state.
enum DirectFTLReadCrossCheck: Equatable, Sendable {
    case passed(hostRatio: Double)
    case failed(String)
    /// The FTL read lacks a required value, which suggests a changed layout.
    case incomplete(String)
    /// SMART can't be compared right now. This can clear by itself, so it is
    /// not held against the read and does not count toward stopping collection.
    case unavailable(String)

    /// Allowed gap between FTL and SMART host writes: 1% or 5 GB, whichever
    /// is larger (the two counters are read minutes apart).
    static let relativeTolerance = 0.01
    static let absoluteToleranceBytes = 5_000_000_000.0
    /// Scheduled reads follow SMART within seconds. Beyond this gap the writes
    /// made in between can explain a difference, so it doesn't prove a mismatch.
    static let maximumComparableSMARTGap: TimeInterval = 120

    static func evaluate(ftl: ASPToolDiagnosticsSnapshot, smart: DriveSnapshot?,
                         previous: ASPToolDiagnosticsSnapshot? = nil,
                         smartHistory: [DriveSnapshot] = []) -> Self {
        guard let tlcEOL = ftl.tlcEOLPE, let slcEOL = ftl.slcEOLPE else {
            return .incomplete("FTLのEOL P/Eがありません")
        }
        guard tlcEOL.isFinite && slcEOL.isFinite && tlcEOL > 0 && slcEOL > 0 else {
            return .failed("EOL P/Eが正の値ではありません")
        }
        guard ftl.tlcAveragePE != nil, ftl.tlcMaximumPE != nil,
              ftl.slcAveragePE != nil, ftl.slcMaximumPE != nil else {
            return .incomplete("FTLの平均・最大P/Eがありません")
        }
        for (average, maximum, name) in [(ftl.tlcAveragePE, ftl.tlcMaximumPE, "TLC"), (ftl.slcAveragePE, ftl.slcMaximumPE, "pSLC")] {
            if let average, let maximum, !average.isFinite || !maximum.isFinite || average > maximum || average < 0 {
                return .failed("\(name)の平均P/Eが最大P/Eと矛盾します")
            }
        }
        guard let ftlHost = ftl.hostWrittenBytes, ftlHost > 0 else {
            return .incomplete("FTLのHost Writesがありません")
        }
        guard let smartHost = smart?.dataUnitsWrittenBytes, smartHost > 0 else {
            return .unavailable("照合用のSMART Host Writesがありません")
        }
        guard let smart, smart.deviceID == ftl.deviceID,
              abs(smart.capturedAt.timeIntervalSince(ftl.capturedAt)) <= 86_400 else {
            return .unavailable("同device・24時間以内のSMARTがありません")
        }
        let tolerance = max(smartHost * relativeTolerance, absoluteToleranceBytes)
        guard abs(ftlHost - smartHost) <= tolerance else {
            guard abs(smart.capturedAt.timeIntervalSince(ftl.capturedAt)) <= maximumComparableSMARTGap else {
                return .unavailable("SMARTが古いためHost Writesを比較できません。SMARTを更新してから再度取得してください")
            }
            return .failed(String(format: "FTLとSMARTのHost Writesが一致しません（比 %.3f）", ftlHost / smartHost))
        }
        if let failure = nandPlausibilityFailure(ftl: ftl, hostBytes: ftlHost) { return .failed(failure) }
        if let failure = DirectFTLPowerOnHoursCheck.evaluate(ftl: ftl, smart: smart,
            previous: previous, smartHistory: smartHistory).failure { return .failed(failure) }
        return .passed(hostRatio: ftlHost / smartHost)
    }

    /// NAND writes read in the wrong unit (for example sectors instead of
    /// 4 KiB pages) would pass the host check unnoticed. On the reference
    /// Mac NAND / Host is about 1.6 and NAND / (capacity × average P/E) about
    /// 1.01. The limits are far wider, so they catch only a unit-sized error
    /// and do not stop collection on a Mac that simply wears differently.
    static let minimumNANDPerHost = 0.5
    static let nandReconstructionRange = 0.5...2.0
    /// Below this the average P/E is too coarse to compare.
    static let minimumReconstructedBytes = 1e12

    static func nandPlausibilityFailure(ftl: ASPToolDiagnosticsSnapshot, hostBytes: Double) -> String? {
        guard let nand = ftl.nandWrittenBytes, nand.isFinite, nand >= 0 else { return nil }
        if nand < hostBytes * minimumNANDPerHost {
            return String(format: "NAND WritesがHost Writesより大幅に少なく、単位が合いません（NAND/Host %.2f）", nand / hostBytes)
        }
        guard let topology = ftl.directTopology,
              let tlcCapacity = topology.tlcCapacityBytes, let pslcCapacity = topology.pslcWritableCapacityBytes,
              let tlcPE = ftl.tlcAveragePE, let pslcPE = ftl.slcAveragePE else { return nil }
        let reconstructed = tlcCapacity * tlcPE + pslcCapacity * pslcPE
        guard reconstructed.isFinite, reconstructed >= minimumReconstructedBytes else { return nil }
        let ratio = nand / reconstructed
        guard nandReconstructionRange.contains(ratio) else {
            return String(format: "NAND Writesが容量×平均P/Eと合いません（比 %.2f）", ratio)
        }
        return nil
    }
}
