import Foundation

/// The reviewed 25G83 `FTL all` record contract.  This identifies a semantic
/// interpretation of a private buffer; it is deliberately separate from the
/// opaque buffer format version and is not a claim about other macOS builds.
enum DirectFTLResearchContract {
    private static let reviewedDescriptor = DirectFTLContractRegistry.reviewed25G83

    static let reviewedBuild = reviewedDescriptor.contractBuild
    /// Semantic mapping version. The compatibility symbols remain stable, but
    /// their canonical values now come from the contract registry.
    static let reviewed25G83V241 = reviewedDescriptor.semanticContractVersion
    static let legacy25G83V24 = reviewedDescriptor.legacySemanticContractVersions.first
        ?? "25G83-ftl-all-research-v2.4"
    static let latest = reviewedDescriptor.semanticContractVersion
    static let maximumHistogramBins = reviewedDescriptor.maximumHistogramBins
    static let maximumTierValues = reviewedDescriptor.maximumTierValues

    /// Wear inputs and research telemetry evolve at different rates.  The
    /// wear contract covers Host/NAND/P-E/EOL/topology meanings; a research
    /// contract may change when an opaque histogram or reliability key is
    /// reinterpreted.  Keeping these namespaces separate prevents a research
    /// review from resetting months of wear history.
    static let reviewed25G83CoreV1 = reviewedDescriptor.coreWearContractVersion
    static let reviewed25G83ResearchV24 = "25G83-research-v2.4"
    static let reviewed25G83ResearchV241 = reviewedDescriptor.researchTelemetryContractVersion

    static func rawDirectContract(for snapshot: ASPToolDiagnosticsSnapshot) -> String? {
        snapshot.directKeyContractVersion ?? snapshot.semanticContractVersion
    }

    /// The key contract is tied to the reviewed private interface, while
    /// `sourceBuild` records the OS that actually ran the probe.  A later OS
    /// may still emit the reviewed contract and must be audited by the
    /// continuity lane rather than rejected at parse time.
    static func contractBuild(for snapshot: ASPToolDiagnosticsSnapshot) -> String? {
        if let explicit = snapshot.contractBuild
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .flatMap({ $0.isEmpty ? nil : $0 }) {
            return explicit
        }
        // Legacy captures carried the reviewed build in `sourceBuild` and
        // had no separate metadata. This is a compatibility resolution only;
        // LegacyBuildOverlay records that the runtime build was not measured.
        if snapshot.sourceBuild == reviewedBuild {
            return reviewedBuild
        }
        return nil
    }

    static func isReviewedContract(for snapshot: ASPToolDiagnosticsSnapshot) -> Bool {
        contractBuild(for: snapshot) == reviewedBuild
    }

    /// Resolves the stable wear contract for both current captures and
    /// historical JSON written before the two-contract fields existed.
    static func coreWearVersion(for snapshot: ASPToolDiagnosticsSnapshot) -> String? {
        if let explicit = snapshot.coreWearContractVersion,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        guard let raw = rawDirectContract(for: snapshot) else {
            // Pre-contract history recorded the runtime build as sourceBuild.
            // The reviewed 25G83 core wear keys were already in use then;
            // absence of a later-added metadata label is not a new wear
            // contract boundary.
            return contractBuild(for: snapshot) == reviewedBuild ? reviewed25G83CoreV1 : nil
        }
        if isReviewedContract(for: snapshot) {
            switch raw {
            case latest, legacy25G83V24:
                return reviewed25G83CoreV1
            default:
                // Unknown contracts remain their own boundary.  We only
                // bridge the two reviewed 25G83 research revisions.
                return raw
            }
        }
        return raw
    }

    /// Resolves the research-only contract.  This is intentionally allowed to
    /// differ across v2.4/v2.4.1 so histogram and reliability deltas are not
    /// computed across an interpretation change.
    static func researchTelemetryVersion(for snapshot: ASPToolDiagnosticsSnapshot) -> String? {
        // Research-key interpretation is not bridged across a runtime build
        // change. It is retained as raw data, but semantic deltas are
        // save-only until that build is reviewed.
        if let contractBuild = snapshot.contractBuild,
           let runtimeBuild = snapshot.sourceBuild,
           contractBuild != runtimeBuild {
            return nil
        }
        if let explicit = snapshot.researchTelemetryContractVersion,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        guard let raw = rawDirectContract(for: snapshot) else { return nil }
        guard isReviewedContract(for: snapshot) else { return raw }
        switch raw {
        case legacy25G83V24:
            return reviewed25G83ResearchV24
        case latest:
            return reviewed25G83ResearchV241
        default:
            return raw
        }
    }

    /// Private research keys are analyzed only when the runtime build is the
    /// build for which their meanings were reviewed. Core wear counters use a
    /// separate continuity lane and are not gated by this check.
    static func researchTelemetryIsEligible(_ snapshot: ASPToolDiagnosticsSnapshot) -> Bool {
        guard snapshot.sourceArtifact == .directFTL,
              let runtimeBuild = snapshot.sourceBuild,
              let contractBuild = contractBuild(for: snapshot),
              runtimeBuild == contractBuild,
              researchTelemetryVersion(for: snapshot) != nil,
              snapshot.researchTelemetry != nil else { return false }
        return true
    }

    static func researchTelemetryPairIsComparable(
        _ lhs: ASPToolDiagnosticsSnapshot,
        _ rhs: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        researchTelemetryIsEligible(lhs) && researchTelemetryIsEligible(rhs) &&
            lhs.deviceID != nil && lhs.deviceID == rhs.deviceID &&
            lhs.sourceBuild == rhs.sourceBuild &&
            lhs.resolvedResearchTelemetryVersion == rhs.resolvedResearchTelemetryVersion
    }

    /// Scalar reliability counters may use the reviewed mapping provisionally.
    /// Histograms and other research metrics retain the strict runtime gate.
    static func reliabilityVersion(for snapshot: ASPToolDiagnosticsSnapshot) -> String? {
        guard snapshot.sourceArtifact == .directFTL,
              snapshot.sourceBuild?.isEmpty == false,
              isReviewedContract(for: snapshot),
              coreWearVersion(for: snapshot) == reviewed25G83CoreV1,
              let raw = rawDirectContract(for: snapshot),
              raw == latest || raw == legacy25G83V24,
              snapshot.researchTelemetry != nil else { return nil }
        let version = snapshot.researchTelemetryContractVersion
            ?? (raw == latest ? reviewed25G83ResearchV241 : reviewed25G83ResearchV24)
        return [reviewed25G83ResearchV241, reviewed25G83ResearchV24].contains(version) ? version : nil
    }

    static func reliabilityPairIsComparable(_ lhs: ASPToolDiagnosticsSnapshot, _ rhs: ASPToolDiagnosticsSnapshot) -> Bool {
        guard let version = reliabilityVersion(for: lhs) else { return false }
        return version == reliabilityVersion(for: rhs) && lhs.deviceID != nil && lhs.deviceID == rhs.deviceID
            && lhs.directFormatVersion == rhs.directFormatVersion
    }

    static func status(for snapshot: ASPToolDiagnosticsSnapshot?) -> DirectFTLContractStatus {
        guard let snapshot else { return .noSnapshot }
        guard let contractBuild = contractBuild(for: snapshot), contractBuild == reviewedBuild else {
            return .unsupportedBuild(expected: reviewedBuild, actual: snapshot.sourceBuild)
        }
        guard let contract = rawDirectContract(for: snapshot) else {
            return .contractUnavailable(build: reviewedBuild)
        }
        guard coreWearVersion(for: snapshot) == reviewed25G83CoreV1,
              contract == latest || contract == legacy25G83V24 else {
            return .contractMismatch(expected: latest, actual: contract)
        }
        return .validated(
            build: snapshot.sourceBuild ?? reviewedBuild,
            contract: contract,
            topologyAvailable: snapshot.directTopology != nil,
            telemetryAvailable: researchTelemetryVersion(for: snapshot) == reviewed25G83ResearchV241 &&
                snapshot.researchTelemetry?.hasValues == true,
            hardwareReviewed: snapshot.chipID == nil
                || DirectFTLContractRegistry.reviewed25G83.isReviewedHardware(chipID: snapshot.chipID)
        )
    }
}

/// The denominator used for per-day FTL rates.  Power On Hours is preferred
/// because a long wall-clock interval containing sleep or power-off time would
/// otherwise understate refresh/event rates.  Wall-clock fallback is retained
/// for legacy snapshots that do not have the counter, and is always surfaced
/// as a different basis.
enum FTLDurationBasis: String, Codable, Equatable, Sendable {
    case operatingHours
    case wallClockFallback
    case unavailable

    var title: String {
        switch self {
        case .operatingHours: return "稼働時間基準"
        case .wallClockFallback: return "暦時間fallback"
        case .unavailable: return "未算出"
        }
    }
}

struct FTLDurationMeasurement: Equatable, Sendable {
    let durationDays: Double
    let wallDurationDays: Double
    let operatingHoursDelta: Double?
    let basis: FTLDurationBasis

    static func between(
        _ start: ASPToolDiagnosticsSnapshot,
        _ end: ASPToolDiagnosticsSnapshot
    ) -> Self {
        let wallSeconds = end.capturedAt.timeIntervalSince(start.capturedAt)
        let wallDays = wallSeconds.isFinite && wallSeconds > 0 ? wallSeconds / 86_400 : 0
        let operatingHoursDelta: Double? = {
            guard let before = start.powerOnHours, let after = end.powerOnHours,
                  after >= before else { return nil }
            let delta = Double(after - before)
            return delta.isFinite ? delta : nil
        }()

        if let operatingHoursDelta, operatingHoursDelta > 0 {
            let operatingDays = operatingHoursDelta / 24
            if operatingDays.isFinite, operatingDays > 0 {
                return Self(
                    durationDays: operatingDays,
                    wallDurationDays: wallDays,
                    operatingHoursDelta: operatingHoursDelta,
                    basis: .operatingHours
                )
            }
        }
        if wallDays.isFinite, wallDays > 0 {
            return Self(
                durationDays: wallDays,
                wallDurationDays: wallDays,
                operatingHoursDelta: operatingHoursDelta,
                basis: .wallClockFallback
            )
        }
        return Self(
            durationDays: 0,
            wallDurationDays: max(0, wallDays),
            operatingHoursDelta: operatingHoursDelta,
            basis: .unavailable
        )
    }
}

/// State shown to the user when the private Direct FTL semantic contract is
/// unavailable.  A build mismatch is expected after an OS update; it is not a
/// health failure and must not be represented as a blank Advanced panel.
enum DirectFTLContractStatus: Equatable, Sendable {
    case noSnapshot
    /// `hardwareReviewed` is false only when the snapshot names an SSD
    /// controller outside the reviewed set; legacy snapshots without a chip ID
    /// predate multi-device support and are not reclassified.
    case validated(build: String, contract: String, topologyAvailable: Bool, telemetryAvailable: Bool,
                   hardwareReviewed: Bool = true)
    case unsupportedBuild(expected: String, actual: String?)
    case contractUnavailable(build: String)
    case contractMismatch(expected: String, actual: String)

    var isValidated: Bool {
        if case .validated = self { return true }
        return false
    }

    /// A reviewed semantic contract can still be running on a newer OS build.
    /// That state is expected after an OS update and is distinct from an
    /// unsupported contract; it must remain visible without blocking the
    /// raw/core-wear path.
    var runsOnReviewedBuild: Bool {
        guard case let .validated(build, _, _, _, hardwareReviewed) = self else { return false }
        return hardwareReviewed && DirectFTLContractRegistry.reviewed25G83.isReviewedRuntime(build)
    }

    var title: String {
        switch self {
        case .noSnapshot: return "未取得"
        case let .validated(build, _, topologyAvailable, telemetryAvailable, hardwareReviewed):
            if !DirectFTLContractRegistry.reviewed25G83.isReviewedRuntime(build) {
                return "対応済み・実行buildは未確認"
            }
            if !hardwareReviewed {
                return "対応済み・SSDコントローラは未確認"
            }
            switch (topologyAvailable, telemetryAvailable) {
            case (true, true): return "対応済み・取得あり"
            case (true, false), (false, true): return "対応済み・部分取得"
            case (false, false): return "対応済み・項目未取得"
            }
        case .unsupportedBuild: return "build未検証"
        case .contractUnavailable: return "keyの対応表なし"
        case .contractMismatch: return "対応表が不一致"
        }
    }

    var detail: String {
        switch self {
        case .noSnapshot:
            return "Direct FTL snapshotがありません。SMART監視は継続しています。"
        case let .validated(build, contract, topologyAvailable, telemetryAvailable, hardwareReviewed):
            let topology = topologyAvailable ? "topologyあり" : "topology未取得"
            let telemetry = telemetryAvailable ? "reliabilityあり" : "reliability未取得"
            let runtime = DirectFTLContractRegistry.reviewed25G83.isReviewedRuntime(build)
                ? "実行build \(build) 検証済み"
                : "実行build \(build)（対応表のbuild \(DirectFTLResearchContract.reviewedBuild)・未確認）"
            let hardware = hardwareReviewed ? "" : " · SSDコントローラ未検証（キーの意味が異なる可能性）"
            return "\(runtime) / \(contract) · \(topology) · \(telemetry)\(hardware)"
        case let .unsupportedBuild(expected, actual):
            return "現在のbuild \(actual ?? "不明") は未検証です。\(expected)専用のkey意味付け・損耗予測・reliability比較を停止しています。手動の構造再検証が必要です。"
        case let .contractUnavailable(build):
            return "build \(build) ですがkeyの対応表を取得できません。private bufferは保存しても意味付け・予測へ投入しません。"
        case let .contractMismatch(expected, actual):
            return "keyの対応表 \(actual) は未確認です。想定する対応表は \(expected) で、意味付け・予測へ投入しません。"
        }
    }
}

/// One daily point derived from already retained Direct FTL snapshots.  It is
/// a wear observation only; it never changes a TBW multiplier by itself.
struct WearBalanceObservation: Equatable, Sendable, Identifiable {
    let capturedAt: Date
    let tlcWear: Double
    let pslcWear: Double
    let ratio: Double
    let divergence: Double
    /// Change from the preceding retained UTC-day point.  This is a
    /// descriptive delta and is not a forecast or a wear multiplier.
    let tlcWearDelta: Double?
    let pslcWearDelta: Double?

    init(
        capturedAt: Date,
        tlcWear: Double,
        pslcWear: Double,
        ratio: Double,
        divergence: Double,
        tlcWearDelta: Double? = nil,
        pslcWearDelta: Double? = nil
    ) {
        self.capturedAt = capturedAt
        self.tlcWear = tlcWear
        self.pslcWear = pslcWear
        self.ratio = ratio
        self.divergence = divergence
        self.tlcWearDelta = tlcWearDelta
        self.pslcWearDelta = pslcWearDelta
    }

    var id: TimeInterval { capturedAt.timeIntervalSinceReferenceDate }
}

struct WearBalanceTrend: Equatable, Sendable {
    static let empty = WearBalanceTrend(
        observations: [], observationDays: nil, firstRatio: nil, latestRatio: nil,
        minimumRatio: nil, maximumRatio: nil, changePerDay: nil,
        tlcWearChangePerDay: nil, pslcWearChangePerDay: nil,
        observedCrossingAt: nil, note: "wearBalanceの比較履歴がありません。"
    )

    let observations: [WearBalanceObservation]
    let observationDays: Double?
    let firstRatio: Double?
    let latestRatio: Double?
    let minimumRatio: Double?
    let maximumRatio: Double?
    let changePerDay: Double?
    let tlcWearChangePerDay: Double?
    let pslcWearChangePerDay: Double?
    /// Crossing observed between two retained samples. This is not a future
    /// extrapolation and is intentionally nil until the crossing is observed.
    let observedCrossingAt: Date?
    let note: String
}

/// Partition boundaries and per-virtual-block geometry decoded from the
/// reviewed Direct FTL buffer.  `topologyContractValidated` means that the
/// keys and shapes matched the 25G83 contract.  It does *not* verify the
/// physical allocation of NAND packages or make the resulting capacity a
/// universal hardware fact.
struct DirectFTLTopology: Codable, Equatable, Sendable {
    var contractVersion: String
    let topologyContractValidated: Bool
    let numVirtualBlocks: UInt64
    let intermediatePartitionStart: UInt64
    let userPartitionStart: UInt64
    let bytesPerPage: UInt64
    let pagesPerVirtualBlock: UInt64
    let pagesPerVirtualBlockSLC: UInt64

    private enum CodingKeys: String, CodingKey {
        case contractVersion, topologyContractValidated, numVirtualBlocks
        case intermediatePartitionStart, userPartitionStart, bytesPerPage
        case pagesPerVirtualBlock, pagesPerVirtualBlockSLC
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(String.self, forKey: .contractVersion)
        let validated = try values.decode(Bool.self, forKey: .topologyContractValidated)
        let virtualBlocks = try values.decode(UInt64.self, forKey: .numVirtualBlocks)
        let intermediateStart = try values.decode(UInt64.self, forKey: .intermediatePartitionStart)
        let userStart = try values.decode(UInt64.self, forKey: .userPartitionStart)
        let pageBytes = try values.decode(UInt64.self, forKey: .bytesPerPage)
        let pages = try values.decode(UInt64.self, forKey: .pagesPerVirtualBlock)
        let slcPages = try values.decode(UInt64.self, forKey: .pagesPerVirtualBlockSLC)
        guard validated,
              let topology = Self(
                contractVersion: version,
                numVirtualBlocks: virtualBlocks,
                intermediatePartitionStart: intermediateStart,
                userPartitionStart: userStart,
                bytesPerPage: pageBytes,
                pagesPerVirtualBlock: pages,
                pagesPerVirtualBlockSLC: slcPages
              ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .numVirtualBlocks, in: values,
                debugDescription: "Invalid Direct FTL topology boundaries or geometry"
            )
        }
        self = topology
    }

    init?(
        contractVersion: String,
        numVirtualBlocks: UInt64,
        intermediatePartitionStart: UInt64,
        userPartitionStart: UInt64,
        bytesPerPage: UInt64,
        pagesPerVirtualBlock: UInt64,
        pagesPerVirtualBlockSLC: UInt64
    ) {
        guard !contractVersion.isEmpty,
              numVirtualBlocks > userPartitionStart,
              userPartitionStart > intermediatePartitionStart,
              bytesPerPage > 0,
              pagesPerVirtualBlock > 0,
              pagesPerVirtualBlockSLC > 0,
              Self.product(bytesPerPage, pagesPerVirtualBlock) != nil,
              Self.product(bytesPerPage, pagesPerVirtualBlockSLC) != nil
        else { return nil }
        self.contractVersion = contractVersion
        self.topologyContractValidated = true
        self.numVirtualBlocks = numVirtualBlocks
        self.intermediatePartitionStart = intermediatePartitionStart
        self.userPartitionStart = userPartitionStart
        self.bytesPerPage = bytesPerPage
        self.pagesPerVirtualBlock = pagesPerVirtualBlock
        self.pagesPerVirtualBlockSLC = pagesPerVirtualBlockSLC
    }

    var intermediateBandCount: UInt64 { userPartitionStart - intermediatePartitionStart }
    var tlcBandCount: UInt64 { numVirtualBlocks - userPartitionStart }

    var tlcBandBytes: UInt64? { Self.product(bytesPerPage, pagesPerVirtualBlock) }
    var pslcBandBytes: UInt64? { Self.product(bytesPerPage, pagesPerVirtualBlockSLC) }

    /// pSLC uses the TLC-mode physical space for the same virtual band.  It is
    /// intentionally separate from `pslcBandBytes`, which is the pSLC
    /// write-capacity basis used by the endurance calculation.
    var pslcPhysicalFootprintPerBandBytes: UInt64? { tlcBandBytes }

    var tlcCapacityBytes: Double? {
        Self.doubleProduct(tlcBandCount, tlcBandBytes)
    }

    var pslcWritableCapacityBytes: Double? {
        Self.doubleProduct(intermediateBandCount, pslcBandBytes)
    }

    var pslcPhysicalFootprintBytes: Double? {
        Self.doubleProduct(intermediateBandCount, pslcPhysicalFootprintPerBandBytes)
    }

    /// Returns whether the physical topology is comparable even when the
    /// research contract changed.  A contract revision may change how
    /// histogram/reliability keys are interpreted without changing the
    /// partition boundaries or page geometry used by wear calculations.
    func isEquivalentGeometry(to other: DirectFTLTopology?) -> Bool {
        guard let other else { return false }
        return topologyContractValidated == other.topologyContractValidated &&
            numVirtualBlocks == other.numVirtualBlocks &&
            intermediatePartitionStart == other.intermediatePartitionStart &&
            userPartitionStart == other.userPartitionStart &&
            bytesPerPage == other.bytesPerPage &&
            pagesPerVirtualBlock == other.pagesPerVirtualBlock &&
            pagesPerVirtualBlockSLC == other.pagesPerVirtualBlockSLC
    }

    func geometryMatches(_ profile: AppleNANDHardwareProfile) -> Bool? {
        if profile.geometryConfidence == .inconsistent { return false }
        guard profile.geometryConfidence == .consistent,
              let expectedTLC = profile.sectorsPerFullBand,
              let expectedPSLC = profile.sectorsPerFullBandSLC,
              let sectorBytes = profile.geometrySectorSizeBytes,
              let actualTLC = tlcBandBytes,
              let actualPSLC = pslcBandBytes
        else {
            // Geometry unavailable is not a mismatch.  The caller may still
            // use the Direct topology and label the ioreg comparison missing.
            return nil
        }

        let tlc = Self.product(expectedTLC, sectorBytes)
        let pslc = Self.product(expectedPSLC, sectorBytes)
        guard let tlc, let pslc else { return false }
        return tlc == actualTLC && pslc == actualPSLC
    }

    private static func product(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let product = lhs.multipliedReportingOverflow(by: rhs)
        return product.overflow ? nil : product.partialValue
    }

    private static func doubleProduct(_ lhs: UInt64, _ rhs: UInt64?) -> Double? {
        guard let rhs, let product = product(lhs, rhs) else { return nil }
        let value = Double(product)
        return value.isFinite ? value : nil
    }
}

/// Selected values from the reviewed Direct FTL private buffer.  The values
/// remain raw unless a unit is explicitly noted by the field's UI.  They are
/// reliability/research evidence and never a TBW multiplier.
/// Counts kept at the narrowest width that holds every value: histogram
/// bins and refresh tiers fit in 32 bits today (16 for some), so this uses
/// a quarter to half of `[UInt64]`. Values and equality are those of the
/// `[UInt64]` they came from; the stored history is encoded unchanged.
struct CompactCounts: Equatable, Sendable {
    private enum Storage: Sendable {
        case narrow([UInt16])
        case medium([UInt32])
        case wide([UInt64])
    }

    private let storage: Storage

    init(_ values: [UInt64]) {
        let maximum = values.max() ?? 0
        if maximum <= UInt64(UInt16.max) {
            storage = .narrow(values.map { UInt16($0) })
        } else if maximum <= UInt64(UInt32.max) {
            storage = .medium(values.map { UInt32($0) })
        } else {
            storage = .wide(values.map { $0 })
        }
    }

    var values: [UInt64] {
        switch storage {
        case let .narrow(values): return values.map { UInt64($0) }
        case let .medium(values): return values.map { UInt64($0) }
        case let .wide(values): return values
        }
    }

    static func == (lhs: CompactCounts, rhs: CompactCounts) -> Bool {
        lhs.values == rhs.values
    }
}

struct FTLResearchTelemetrySnapshot: Codable, Equatable, Sendable {
    let nandReads: UInt64?
    private var ageRefreshCounts: CompactCounts?
    var ageRefreshPerTier: [UInt64]? {
        get { ageRefreshCounts?.values }
        set { ageRefreshCounts = newValue.map(CompactCounts.init) }
    }
    let backgroundRefreshMoves: UInt64?
    let bandsPaddedForAge: UInt64?
    let crossTemperatureUECC: UInt64?
    let utilityUECCReads: UInt64?
    let ueccReads: UInt64?
    let readVerifyNative: UInt64?
    let reducedReadVerifyNative: UInt64?
    let readVerifySLC: UInt64?
    let directToTLCBands: UInt64?
    let directToTLCSectors: UInt64?
    let fallbackToWaterfall: UInt64?
    let nonProportionalDirectToTLCSectors: UInt64?
    let raidVerificationReads: UInt64?
    let crossTemperatureRaidUECC: UInt64?
    let hostSLCReadVerifyFailures: UInt64?
    let hostTLCReadVerifyFailures: UInt64?
    let gcSLCToTLCReadVerifyFailures: UInt64?
    let gcTLCToTLCReadVerifyFailures: UInt64?
    /// Keys 327...331 are opaque bins. They are not converted to Celsius.
    private var maxTempCounts: CompactCounts?
    var bandsMaxTempHistogram: [UInt64]? {
        get { maxTempCounts?.values }
        set { maxTempCounts = newValue.map(CompactCounts.init) }
    }
    private var minTempCounts: CompactCounts?
    var bandsMinTempHistogram: [UInt64]? {
        get { minTempCounts?.values }
        set { minTempCounts = newValue.map(CompactCounts.init) }
    }
    private var lifetimeTempCounts: CompactCounts?
    var bandsLifetimeTempHistogram: [UInt64]? {
        get { lifetimeTempCounts?.values }
        set { lifetimeTempCounts = newValue.map(CompactCounts.init) }
    }
    private var deltaTempCounts: CompactCounts?
    var bandsDeltaTempHistogram: [UInt64]? {
        get { deltaTempCounts?.values }
        set { deltaTempCounts = newValue.map(CompactCounts.init) }
    }
    private var crossTempCounts: CompactCounts?
    var bandsCrossTempHistogram: [UInt64]? {
        get { crossTempCounts?.values }
        set { crossTempCounts = newValue.map(CompactCounts.init) }
    }

    /// Future hard reliability guards. No 25G83 key mapping is asserted yet;
    /// nil means "not mapped", not zero.
    let numPfail: UInt64?
    let numEfail: UInt64?
    let bandsRefreshedOnError: UInt64?
    let openBandReadFail: UInt64?
    let offlineBlocksCnt: UInt64?

    private enum CodingKeys: String, CodingKey {
        case nandReads, ageRefreshPerTier, backgroundRefreshMoves, bandsPaddedForAge
        case crossTemperatureUECC, utilityUECCReads, ueccReads, readVerifyNative
        case reducedReadVerifyNative, readVerifySLC, directToTLCBands, directToTLCSectors
        case fallbackToWaterfall, nonProportionalDirectToTLCSectors, raidVerificationReads
        case crossTemperatureRaidUECC, hostSLCReadVerifyFailures, hostTLCReadVerifyFailures
        case gcSLCToTLCReadVerifyFailures, gcTLCToTLCReadVerifyFailures
        case bandsMaxTempHistogram, bandsMinTempHistogram, bandsLifetimeTempHistogram
        case bandsDeltaTempHistogram, bandsCrossTempHistogram
        case readTemperatureHistogram, programTemperatureHistogram, readCountHistogram
        case nativeReadRetryHistogram, slcReadRetryHistogram
        case numPfail, numEfail, bandsRefreshedOnError, openBandReadFail, offlineBlocksCnt
    }

    init(
        nandReads: UInt64? = nil,
        ageRefreshPerTier: [UInt64]? = nil,
        backgroundRefreshMoves: UInt64? = nil,
        bandsPaddedForAge: UInt64? = nil,
        crossTemperatureUECC: UInt64? = nil,
        utilityUECCReads: UInt64? = nil,
        ueccReads: UInt64? = nil,
        readVerifyNative: UInt64? = nil,
        reducedReadVerifyNative: UInt64? = nil,
        readVerifySLC: UInt64? = nil,
        directToTLCBands: UInt64? = nil,
        directToTLCSectors: UInt64? = nil,
        fallbackToWaterfall: UInt64? = nil,
        nonProportionalDirectToTLCSectors: UInt64? = nil,
        raidVerificationReads: UInt64? = nil,
        crossTemperatureRaidUECC: UInt64? = nil,
        hostSLCReadVerifyFailures: UInt64? = nil,
        hostTLCReadVerifyFailures: UInt64? = nil,
        gcSLCToTLCReadVerifyFailures: UInt64? = nil,
        gcTLCToTLCReadVerifyFailures: UInt64? = nil,
        bandsMaxTempHistogram: [UInt64]? = nil,
        bandsMinTempHistogram: [UInt64]? = nil,
        bandsLifetimeTempHistogram: [UInt64]? = nil,
        bandsDeltaTempHistogram: [UInt64]? = nil,
        bandsCrossTempHistogram: [UInt64]? = nil,
        numPfail: UInt64? = nil,
        numEfail: UInt64? = nil,
        bandsRefreshedOnError: UInt64? = nil,
        openBandReadFail: UInt64? = nil,
        offlineBlocksCnt: UInt64? = nil,
        // Legacy argument labels are accepted so old fixtures and callers
        // continue to compile. They map only to the corresponding corrected
        // key and are not encoded under the old semantic names.
        readTemperatureHistogram: [UInt64]? = nil,
        programTemperatureHistogram: [UInt64]? = nil,
        readCountHistogram: [UInt64]? = nil,
        nativeReadRetryHistogram: [UInt64]? = nil,
        slcReadRetryHistogram: [UInt64]? = nil
    ) {
        self.nandReads = nandReads
        self.ageRefreshCounts = ageRefreshPerTier.map(CompactCounts.init)
        self.backgroundRefreshMoves = backgroundRefreshMoves
        self.bandsPaddedForAge = bandsPaddedForAge
        self.crossTemperatureUECC = crossTemperatureUECC
        self.utilityUECCReads = utilityUECCReads
        self.ueccReads = ueccReads
        self.readVerifyNative = readVerifyNative
        self.reducedReadVerifyNative = reducedReadVerifyNative
        self.readVerifySLC = readVerifySLC
        self.directToTLCBands = directToTLCBands
        self.directToTLCSectors = directToTLCSectors
        self.fallbackToWaterfall = fallbackToWaterfall
        self.nonProportionalDirectToTLCSectors = nonProportionalDirectToTLCSectors
        self.raidVerificationReads = raidVerificationReads
        self.crossTemperatureRaidUECC = crossTemperatureRaidUECC
        self.hostSLCReadVerifyFailures = hostSLCReadVerifyFailures
        self.hostTLCReadVerifyFailures = hostTLCReadVerifyFailures
        self.gcSLCToTLCReadVerifyFailures = gcSLCToTLCReadVerifyFailures
        self.gcTLCToTLCReadVerifyFailures = gcTLCToTLCReadVerifyFailures
        self.maxTempCounts = (bandsMaxTempHistogram ?? readTemperatureHistogram).map(CompactCounts.init)
        self.minTempCounts = (bandsMinTempHistogram ?? programTemperatureHistogram).map(CompactCounts.init)
        self.lifetimeTempCounts = (bandsLifetimeTempHistogram ?? readCountHistogram).map(CompactCounts.init)
        self.deltaTempCounts = (bandsDeltaTempHistogram ?? nativeReadRetryHistogram).map(CompactCounts.init)
        self.crossTempCounts = (bandsCrossTempHistogram ?? slcReadRetryHistogram).map(CompactCounts.init)
        self.numPfail = numPfail
        self.numEfail = numEfail
        self.bandsRefreshedOnError = bandsRefreshedOnError
        self.openBandReadFail = openBandReadFail
        self.offlineBlocksCnt = offlineBlocksCnt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        nandReads = decode(.nandReads)
        let ageRefreshValues: [UInt64]? = decode(.ageRefreshPerTier)
        ageRefreshCounts = ageRefreshValues.map(CompactCounts.init)
        backgroundRefreshMoves = decode(.backgroundRefreshMoves)
        bandsPaddedForAge = decode(.bandsPaddedForAge)
        crossTemperatureUECC = decode(.crossTemperatureUECC)
        utilityUECCReads = decode(.utilityUECCReads)
        ueccReads = decode(.ueccReads)
        readVerifyNative = decode(.readVerifyNative)
        reducedReadVerifyNative = decode(.reducedReadVerifyNative)
        readVerifySLC = decode(.readVerifySLC)
        directToTLCBands = decode(.directToTLCBands)
        directToTLCSectors = decode(.directToTLCSectors)
        fallbackToWaterfall = decode(.fallbackToWaterfall)
        nonProportionalDirectToTLCSectors = decode(.nonProportionalDirectToTLCSectors)
        raidVerificationReads = decode(.raidVerificationReads)
        crossTemperatureRaidUECC = decode(.crossTemperatureRaidUECC)
        hostSLCReadVerifyFailures = decode(.hostSLCReadVerifyFailures)
        hostTLCReadVerifyFailures = decode(.hostTLCReadVerifyFailures)
        gcSLCToTLCReadVerifyFailures = decode(.gcSLCToTLCReadVerifyFailures)
        gcTLCToTLCReadVerifyFailures = decode(.gcTLCToTLCReadVerifyFailures)
        let maxTempCountsValues: [UInt64]? = decode(.bandsMaxTempHistogram) ?? decode(.readTemperatureHistogram)
        maxTempCounts = maxTempCountsValues.map(CompactCounts.init)
        let minTempCountsValues: [UInt64]? = decode(.bandsMinTempHistogram) ?? decode(.programTemperatureHistogram)
        minTempCounts = minTempCountsValues.map(CompactCounts.init)
        let lifetimeTempCountsValues: [UInt64]? = decode(.bandsLifetimeTempHistogram) ?? decode(.readCountHistogram)
        lifetimeTempCounts = lifetimeTempCountsValues.map(CompactCounts.init)
        let deltaTempCountsValues: [UInt64]? = decode(.bandsDeltaTempHistogram) ?? decode(.nativeReadRetryHistogram)
        deltaTempCounts = deltaTempCountsValues.map(CompactCounts.init)
        let crossTempCountsValues: [UInt64]? = decode(.bandsCrossTempHistogram) ?? decode(.slcReadRetryHistogram)
        crossTempCounts = crossTempCountsValues.map(CompactCounts.init)
        numPfail = decode(.numPfail)
        numEfail = decode(.numEfail)
        bandsRefreshedOnError = decode(.bandsRefreshedOnError)
        openBandReadFail = decode(.openBandReadFail)
        offlineBlocksCnt = decode(.offlineBlocksCnt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(nandReads, forKey: .nandReads)
        try c.encodeIfPresent(ageRefreshPerTier, forKey: .ageRefreshPerTier)
        try c.encodeIfPresent(backgroundRefreshMoves, forKey: .backgroundRefreshMoves)
        try c.encodeIfPresent(bandsPaddedForAge, forKey: .bandsPaddedForAge)
        try c.encodeIfPresent(crossTemperatureUECC, forKey: .crossTemperatureUECC)
        try c.encodeIfPresent(utilityUECCReads, forKey: .utilityUECCReads)
        try c.encodeIfPresent(ueccReads, forKey: .ueccReads)
        try c.encodeIfPresent(readVerifyNative, forKey: .readVerifyNative)
        try c.encodeIfPresent(reducedReadVerifyNative, forKey: .reducedReadVerifyNative)
        try c.encodeIfPresent(readVerifySLC, forKey: .readVerifySLC)
        try c.encodeIfPresent(directToTLCBands, forKey: .directToTLCBands)
        try c.encodeIfPresent(directToTLCSectors, forKey: .directToTLCSectors)
        try c.encodeIfPresent(fallbackToWaterfall, forKey: .fallbackToWaterfall)
        try c.encodeIfPresent(nonProportionalDirectToTLCSectors, forKey: .nonProportionalDirectToTLCSectors)
        try c.encodeIfPresent(raidVerificationReads, forKey: .raidVerificationReads)
        try c.encodeIfPresent(crossTemperatureRaidUECC, forKey: .crossTemperatureRaidUECC)
        try c.encodeIfPresent(hostSLCReadVerifyFailures, forKey: .hostSLCReadVerifyFailures)
        try c.encodeIfPresent(hostTLCReadVerifyFailures, forKey: .hostTLCReadVerifyFailures)
        try c.encodeIfPresent(gcSLCToTLCReadVerifyFailures, forKey: .gcSLCToTLCReadVerifyFailures)
        try c.encodeIfPresent(gcTLCToTLCReadVerifyFailures, forKey: .gcTLCToTLCReadVerifyFailures)
        try c.encodeIfPresent(bandsMaxTempHistogram, forKey: .bandsMaxTempHistogram)
        try c.encodeIfPresent(bandsMinTempHistogram, forKey: .bandsMinTempHistogram)
        try c.encodeIfPresent(bandsLifetimeTempHistogram, forKey: .bandsLifetimeTempHistogram)
        try c.encodeIfPresent(bandsDeltaTempHistogram, forKey: .bandsDeltaTempHistogram)
        try c.encodeIfPresent(bandsCrossTempHistogram, forKey: .bandsCrossTempHistogram)
        try c.encodeIfPresent(numPfail, forKey: .numPfail)
        try c.encodeIfPresent(numEfail, forKey: .numEfail)
        try c.encodeIfPresent(bandsRefreshedOnError, forKey: .bandsRefreshedOnError)
        try c.encodeIfPresent(openBandReadFail, forKey: .openBandReadFail)
        try c.encodeIfPresent(offlineBlocksCnt, forKey: .offlineBlocksCnt)
    }

    @available(*, deprecated, message: "Use bandsMaxTempHistogram")
    var readTemperatureHistogram: [UInt64]? { bandsMaxTempHistogram }
    @available(*, deprecated, message: "Use bandsMinTempHistogram")
    var programTemperatureHistogram: [UInt64]? { bandsMinTempHistogram }
    @available(*, deprecated, message: "Use bandsLifetimeTempHistogram")
    var readCountHistogram: [UInt64]? { bandsLifetimeTempHistogram }
    @available(*, deprecated, message: "Use bandsDeltaTempHistogram")
    var nativeReadRetryHistogram: [UInt64]? { bandsDeltaTempHistogram }
    @available(*, deprecated, message: "Use bandsCrossTempHistogram")
    var slcReadRetryHistogram: [UInt64]? { bandsCrossTempHistogram }

    var hasValues: Bool {
        nandReads != nil || ageRefreshPerTier != nil || backgroundRefreshMoves != nil ||
            bandsPaddedForAge != nil || crossTemperatureUECC != nil || utilityUECCReads != nil ||
            ueccReads != nil || readVerifyNative != nil || reducedReadVerifyNative != nil ||
            readVerifySLC != nil || directToTLCBands != nil || directToTLCSectors != nil ||
            fallbackToWaterfall != nil || nonProportionalDirectToTLCSectors != nil ||
            raidVerificationReads != nil || crossTemperatureRaidUECC != nil ||
            hostSLCReadVerifyFailures != nil || hostTLCReadVerifyFailures != nil ||
            gcSLCToTLCReadVerifyFailures != nil || gcTLCToTLCReadVerifyFailures != nil ||
            bandsMaxTempHistogram != nil || bandsMinTempHistogram != nil ||
            bandsLifetimeTempHistogram != nil || bandsDeltaTempHistogram != nil ||
            bandsCrossTempHistogram != nil || numPfail != nil || numEfail != nil ||
            bandsRefreshedOnError != nil || openBandReadFail != nil || offlineBlocksCnt != nil
    }

    var ageRefreshTotal: UInt64? {
        Self.sum(ageRefreshPerTier)
    }

    func histogram(named name: FTLResearchHistogram) -> [UInt64]? {
        switch name {
        case .bandsMaxTemp: return bandsMaxTempHistogram
        case .bandsMinTemp: return bandsMinTempHistogram
        case .bandsLifetimeTemp: return bandsLifetimeTempHistogram
        case .bandsDeltaTemp: return bandsDeltaTempHistogram
        case .bandsCrossTemp: return bandsCrossTempHistogram
        }
    }

    private static func sum(_ values: [UInt64]?) -> UInt64? {
        guard let values else { return nil }
        var result: UInt64 = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }
}

enum FTLResearchHistogram: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case bandsMaxTemp
    case bandsMinTemp
    case bandsLifetimeTemp
    case bandsDeltaTemp
    case bandsCrossTemp

    // Source-compatible alias for previously compiled UI/test code.
    static let programTemperature = Self.bandsMinTemp

    var title: String {
        switch self {
        case .bandsMaxTemp: return "Bands max-temperature histogram"
        case .bandsMinTemp: return "Bands min-temperature histogram"
        case .bandsLifetimeTemp: return "Bands lifetime-temperature histogram"
        case .bandsDeltaTemp: return "Bands delta-temperature histogram"
        case .bandsCrossTemp: return "Bands cross-temperature histogram"
        }
    }
}

struct FTLHistogramSummary: Equatable, Sendable {
    let binCount: Int
    let totalCount: UInt64?
    let meanBin: Double?
    let p50Bin: Int?
    let p90Bin: Int?
    let p99Bin: Int?
    let finalNonZeroBin: Int?
    let allBinsZero: Bool

    static func summarize(_ bins: [UInt64]) -> Self {
        var total: UInt64 = 0
        var weighted = 0.0
        var overflow = false
        var final: Int?
        for (index, count) in bins.enumerated() {
            let next = total.addingReportingOverflow(count)
            overflow = overflow || next.overflow
            total = next.partialValue
            weighted += Double(index) * Double(count)
            if count > 0 { final = index }
        }
        guard !overflow, total > 0, weighted.isFinite else {
            return Self(binCount: bins.count, totalCount: overflow ? nil : total,
                        meanBin: nil, p50Bin: nil, p90Bin: nil, p99Bin: nil,
                        finalNonZeroBin: final, allBinsZero: final == nil)
        }
        func quantile(_ fraction: Double) -> Int? {
            let threshold = max(1, UInt64((Double(total) * fraction).rounded(.up)))
            var cumulative: UInt64 = 0
            for (index, count) in bins.enumerated() {
                let next = cumulative.addingReportingOverflow(count)
                guard !next.overflow else { return nil }
                cumulative = next.partialValue
                if cumulative >= threshold { return index }
            }
            return nil
        }
        return Self(binCount: bins.count, totalCount: total,
                    meanBin: weighted / Double(total), p50Bin: quantile(0.50),
                    p90Bin: quantile(0.90), p99Bin: quantile(0.99),
                    finalNonZeroBin: final, allBinsZero: false)
    }

    static func tailFraction(_ bins: [UInt64], from startBin: Int) -> Double? {
        guard startBin >= 0, startBin < bins.count else { return nil }
        guard let total = FTLResearchTelemetrySnapshot.sumForResearch(bins), total > 0 else { return nil }
        let tail = FTLResearchTelemetrySnapshot.sumForResearch(Array(bins[startBin...]))
        guard let tail else { return nil }
        let value = Double(tail) / Double(total)
        return value.isFinite ? value : nil
    }
}

private extension FTLResearchTelemetrySnapshot {
    static func sumForResearch(_ values: [UInt64]) -> UInt64? {
        var result: UInt64 = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }
}

/// Domain use reconstructed from the directly reported topology.  Any
/// residual remains a diagnostic value and is never assigned to a capacity or
/// added to the endurance budget.
struct NANDReconstructionDiagnostics: Equatable, Sendable {
    let knownDomainUsedBytes: Double
    let measuredNANDBytes: Double
    let signedResidualBytes: Double
    let rawEquivalentPSLCBands: Double?
    let residualEquivalentPSLCBands: Double?
    let currentReconstructionError: Double?
    let eolBudgetReconciliationError: Double?
    let topologyContractValidated: Bool
    let physicalCapacityAllocationVerified: Bool
}

/// WAF component reconstruction values.  They describe the input definitions
/// only and are deliberately not fed back into `forecastWAF`.
struct FTLWAFComponentDecomposition: Equatable, Sendable {
    let total: Double?
    let native: Double?
    let intermediate: Double?
    let residual: Double?
    let isConsistent: Bool?
    let note: String
}

enum FTLReliabilityState: String, Codable, Equatable, Sendable {
    case noComparableHistory
    case researchContractUnreviewed
    case coreContinuityUnverified
    case comparisonInvalid
    case noNewObservedEvent
    case recoveryActivityObserved
    case reliabilityEventObserved

    var title: String {
        switch self {
        case .noComparableHistory: return "比較履歴なし"
        case .researchContractUnreviewed: return "研究用keyの対応表が未確認"
        case .coreContinuityUnverified: return "コア系列境界を確認中"
        case .comparisonInvalid: return "比較区間が不整合"
        case .noNewObservedEvent: return "取得範囲で新規イベントなし"
        case .recoveryActivityObserved: return "保持処理を観測"
        case .reliabilityEventObserved: return "内部エラー増加"
        }
    }
}

struct FTLReliabilityCounterDelta: Equatable, Sendable, Identifiable {
    let name: String
    let delta: UInt64
    let perDay: Double?
    let perNANDRead: Double?
    let isReliabilityEvent: Bool

    var id: String { name }
}

enum HostWriteCompositionComparison: Equatable, Sendable {
    case snapshot
    case delta

    var title: String {
        switch self {
        case .snapshot: return "snapshot合計"
        case .delta: return "同一系列のdelta合計"
        }
    }
}

enum HostWriteCompositionAuditStatus: Equatable, Sendable {
    case unavailable
    case exactMatch
    case mismatch

    var title: String {
        switch self {
        case .unavailable: return "比較不能"
        case .exactMatch: return "合計一致"
        case .mismatch: return "合計不一致"
        }
    }
}

/// A diagnostic check for the proposed raw keys 5/6/27. A matching sum is
/// evidence for a candidate invariant only; it is intentionally not a
/// semantic key mapping and never changes Host Writes, WAF, or TBW.
struct HostWriteCompositionAudit: Equatable, Sendable {
    let comparison: HostWriteCompositionComparison
    let candidateValues: [UInt64]
    let hostWrites: UInt64?
    let candidateSum: UInt64?
    let absoluteDifference: UInt64?
    let relativeError: Double?
    let status: HostWriteCompositionAuditStatus
    let note: String
}

struct HostWriteCompositionAuditor: Sendable {
    func assess(
        baseline: ASPToolDiagnosticsSnapshot?,
        latest: ASPToolDiagnosticsSnapshot?
    ) -> HostWriteCompositionAudit? {
        guard let latest else { return nil }
        let currentCandidates = [
            latest.hostWriteCompositionCandidateKey5,
            latest.hostWriteCompositionCandidateKey6,
            latest.hostWriteCompositionCandidateKey27
        ]
        guard currentCandidates.contains(where: { $0 != nil }) else { return nil }

        var comparison: HostWriteCompositionComparison = .snapshot
        var values = currentCandidates.compactMap { $0 }
        var hostWrites = latest.hostWrites
        var note = "現在snapshotのraw key 5 / 6 / 27を表示しています。意味付けは未確定です。"

        if let baseline,
           isComparable(baseline, latest),
           baseline.capturedAt < latest.capturedAt,
           let before5 = baseline.hostWriteCompositionCandidateKey5,
           let before6 = baseline.hostWriteCompositionCandidateKey6,
           let before27 = baseline.hostWriteCompositionCandidateKey27,
           let beforeHost = baseline.hostWrites,
           let after5 = latest.hostWriteCompositionCandidateKey5,
           let after6 = latest.hostWriteCompositionCandidateKey6,
           let after27 = latest.hostWriteCompositionCandidateKey27,
           let afterHost = latest.hostWrites,
           after5 >= before5, after6 >= before6, after27 >= before27, afterHost >= beforeHost {
            comparison = .delta
            values = [after5 - before5, after6 - before6, after27 - before27]
            hostWrites = afterHost - beforeHost
            note = "同一device・build・firmware epoch・keyの対応表のdelta合計です。semantic mappingへは昇格していません。"
        } else if baseline != nil {
            note = "比較可能なcomposition基準点がないため、現在snapshotのraw合計のみを表示しています。reset・系列不一致・欠測は意味付けへ使いません。"
        }

        var candidateSum: UInt64?
        if values.count == 3 {
            var sum: UInt64 = 0
            var overflow = false
            for value in values {
                let next = sum.addingReportingOverflow(value)
                if next.overflow { overflow = true; break }
                sum = next.partialValue
            }
            candidateSum = overflow ? nil : sum
        }

        let difference: UInt64?
        let relativeError: Double?
        if let hostWrites, let candidateSum {
            difference = hostWrites >= candidateSum ? hostWrites - candidateSum : candidateSum - hostWrites
            if hostWrites == 0 {
                relativeError = candidateSum == 0 ? 0 : nil
            } else {
                let value = Double(difference!) / Double(hostWrites)
                relativeError = value.isFinite ? value : nil
            }
        } else {
            difference = nil
            relativeError = nil
        }

        let status: HostWriteCompositionAuditStatus
        if let hostWrites, let candidateSum {
            status = hostWrites == candidateSum ? .exactMatch : .mismatch
        } else {
            status = .unavailable
        }
        return HostWriteCompositionAudit(
            comparison: comparison,
            candidateValues: values,
            hostWrites: hostWrites,
            candidateSum: candidateSum,
            absoluteDifference: difference,
            relativeError: relativeError,
            status: status,
            note: note
        )
    }

    private func isComparable(
        _ lhs: ASPToolDiagnosticsSnapshot,
        _ rhs: ASPToolDiagnosticsSnapshot
    ) -> Bool {
        DirectFTLResearchContract.researchTelemetryPairIsComparable(lhs, rhs)
    }
}

struct FTLReliabilityEvidence: Equatable, Sendable {
    let baselineCapturedAt: Date?
    let comparedAt: Date?
    let durationDays: Double?
    /// Wall-clock span is retained for context; `durationDays` is the rate
    /// denominator and uses Power On Hours when both snapshots provide it.
    let wallDurationDays: Double?
    let operatingHoursDelta: Double?
    let durationBasis: FTLDurationBasis
    let researchSessionOverlap: Bool
    let state: FTLReliabilityState
    let reason: String
    let counters: [FTLReliabilityCounterDelta]
    /// Counters which existed in both snapshots but could not be differenced
    /// safely (for example because the individual counter decreased or an
    /// array changed shape).  This does not invalidate unrelated counters.
    let unavailableCounters: [String]
    let unmappedItems: [String]
    let latestTelemetry: FTLResearchTelemetrySnapshot?
    let hostWriteCompositionAudit: HostWriteCompositionAudit?
    var provisionalInterpretation: Bool = false
}

enum FTLReliabilityCardState: Equatable, Sendable {
    case comparisonPending
    case noAnomalyObserved
    case eventPresent

    var title: String {
        switch self {
        case .comparisonPending: return "比較待ち"
        case .noAnomalyObserved: return "取得範囲で異常なし"
        case .eventPresent: return "eventあり"
        }
    }
}

struct FTLReliabilityCardPresentation: Equatable, Sendable {
    let state: FTLReliabilityCardState
    let detail: String
    /// The hover text. The card has two short lines, so a long reason goes
    /// here and the card shows its state instead.
    var explanation: String?

    static func make(
        evidence: FTLReliabilityEvidence?,
        events: [FTLTimeSeriesReliabilityEvent]
    ) -> FTLReliabilityCardPresentation {
        if evidence?.provisionalInterpretation == true {
            var reviewedPresentation = evidence!
            reviewedPresentation.provisionalInterpretation = false
            let base = make(evidence: reviewedPresentation, events: events)
            return .init(state: base.state,
                         detail: base.detail.contains(UIString.text("暫定比較")) ? base.detail : base.detail + " · " + UIString.text("暫定比較"),
                         explanation: evidence?.reason)
        }
        if let event = events.max(by: { $0.intervalEnd < $1.intervalEnd }) {
            return FTLReliabilityCardPresentation(
                state: .eventPresent,
                detail: "\(event.type.title) +\(event.delta)" + (event.provisionalInterpretation == true ? " · " + UIString.text("暫定比較") : ""),
                explanation: event.provisionalInterpretation == true ? UIString.text("研究用keyは互換性を仮定した暫定比較です。") : nil
            )
        }
        guard let evidence else {
            return FTLReliabilityCardPresentation(
                state: .comparisonPending,
                detail: "比較可能なFTL履歴を待機中"
            )
        }
        if evidence.state == .reliabilityEventObserved {
            let event = evidence.counters.first { $0.isReliabilityEvent && $0.delta > 0 }
            return FTLReliabilityCardPresentation(
                state: .eventPresent,
                detail: event.map { "\($0.name) +\($0.delta)" } ?? "比較区間でイベント増加"
            )
        }
        switch evidence.state {
        case .noComparableHistory, .researchContractUnreviewed, .coreContinuityUnverified, .comparisonInvalid:
            return FTLReliabilityCardPresentation(
                state: .comparisonPending,
                detail: evidence.state.title,
                explanation: evidence.reason
            )
        case .noNewObservedEvent, .recoveryActivityObserved:
            guard evidence.counters.contains(where: \.isReliabilityEvent) else {
                return FTLReliabilityCardPresentation(
                    state: .comparisonPending,
                    detail: "異常判定用counterの比較待ち"
                )
            }
            let detail = evidence.state == .recoveryActivityObserved
                ? "異常counterの増加なし · 保持処理あり"
                : "異常判定用counterを比較済み"
            return FTLReliabilityCardPresentation(state: .noAnomalyObserved, detail: detail)
        case .reliabilityEventObserved:
            return FTLReliabilityCardPresentation(state: .eventPresent, detail: "比較区間でイベント増加")
        }
    }
}

struct FTLReliabilityEvidenceAnalyzer: Sendable {
    private static let unmappedItems = [
        "Hard guard（numPfail / numEfail / bandsRefreshedOnError / openBandReadFail / offlineBlocksCnt）: key番号とasptool named fieldの対照未完了・監視保留",
        "Host書込み内訳: 25G83 key未照合",
        "Host書込みcomposition key 5 / 6 / 27: scalar観測と合計検算のみ。paired captureのdelta不変量確認待ち",
        "RAID内訳: aggregate以外のkey未照合"
    ]

    func assess(
        snapshots: [ASPToolDiagnosticsSnapshot],
        latest: ASPToolDiagnosticsSnapshot?,
        researchIntervals: [DateInterval],
        continuityLane suppliedLane: WearContinuityLane? = nil
    ) -> FTLReliabilityEvidence? {
        guard let latest, let telemetry = latest.researchTelemetry else { return nil }
        let coreSnapshots = snapshots.filter {
            $0.sourceArtifact.participatesInCoreWearLane && $0.capturedAt <= latest.capturedAt
        }
        let lane = suppliedLane ?? WearContinuityLaneBuilder.build(
            snapshots: coreSnapshots,
            smart: [],
            latest: latest
        )
        guard DirectFTLResearchContract.reliabilityVersion(for: latest) != nil else {
            let runtime = latest.sourceBuild ?? "不明"
            let contract = DirectFTLResearchContract.contractBuild(for: latest) ?? "不明"
            return unavailableEvidence(
                latest: latest,
                telemetry: telemetry,
                intervals: researchIntervals,
                state: .researchContractUnreviewed,
                reason: "実行build \(runtime) と研究用keyの対応表のbuild \(contract) の組み合わせは未確認です。raw値は保持し、reliabilityの差分・相関・イベント判定を保留しています。研究用keyの対応表は、損耗の計算に使うkeyとは別のものです。"
            )
        }
        guard lane.snapshots.contains(where: { $0.id == latest.id }) else {
            let boundary = lane.boundaries.last(where: { $0.boundary.after <= latest.capturedAt })
            let reason = boundary?.continuity.isPending == true
                ? "コア系列の計測器境界がSMART資料待ちです。研究keyのraw値は保持し、境界を跨ぐ差分は作成しません。"
                : "コア系列の計測器境界が未検証または不一致です。研究keyのraw値は保持し、境界後の比較を保留しています。"
            return unavailableEvidence(
                latest: latest,
                telemetry: telemetry,
                intervals: researchIntervals,
                state: .coreContinuityUnverified,
                reason: reason
            )
        }
        let comparable = lane.snapshots
            .filter { $0.capturedAt < latest.capturedAt && isComparable($0, latest) && $0.researchTelemetry != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let baseline = comparable.last, let earlier = baseline.researchTelemetry else {
            return unavailableEvidence(
                latest: latest,
                telemetry: telemetry,
                intervals: researchIntervals,
                state: .noComparableHistory,
                reason: "同じdevice・互換性のあるscalar対応表の比較可能な直前snapshotがありません。取得raw値は保存済みです。"
            )
        }
        let elapsed = latest.capturedAt.timeIntervalSince(baseline.capturedAt)
        guard elapsed > 0 else {
            return FTLReliabilityEvidence(
                baselineCapturedAt: baseline.capturedAt, comparedAt: latest.capturedAt, durationDays: nil,
                wallDurationDays: nil, operatingHoursDelta: nil, durationBasis: .unavailable,
                researchSessionOverlap: false, state: .comparisonInvalid,
                reason: "同秒重複または時刻逆転のため比較を作成しません。",
                counters: [], unavailableCounters: [], unmappedItems: Self.unmappedItems, latestTelemetry: telemetry,
                hostWriteCompositionAudit: HostWriteCompositionAuditor().assess(baseline: baseline, latest: latest)
            )
        }
        let hasSeriesReset = seriesCountersWentBackwards(from: baseline, to: latest)
        let duration = FTLDurationMeasurement.between(baseline, latest)
        guard !hasSeriesReset else {
            return FTLReliabilityEvidence(
                baselineCapturedAt: baseline.capturedAt, comparedAt: latest.capturedAt,
                durationDays: duration.durationDays, wallDurationDays: duration.wallDurationDays,
                operatingHoursDelta: duration.operatingHoursDelta, durationBasis: duration.basis,
                researchSessionOverlap: intervalOverlapsResearch(baseline, latest, researchIntervals),
                state: .comparisonInvalid,
                reason: "Host／NAND書込みまたはPower On Hours counterの減少を検出。reset後の新系列として比較を作成しません。",
                counters: [], unavailableCounters: [], unmappedItems: Self.unmappedItems, latestTelemetry: telemetry,
                hostWriteCompositionAudit: HostWriteCompositionAuditor().assess(baseline: baseline, latest: latest)
            )
        }
        let nandReadDelta = difference(earlier.nandReads, telemetry.nandReads)
        let days = duration.durationDays
        let provisional = !DirectFTLResearchContract.researchTelemetryIsEligible(latest)
            || !DirectFTLResearchContract.researchTelemetryIsEligible(baseline)
        let all: [(String, UInt64?, UInt64?, Bool)] = [
            ("Age refresh", earlier.ageRefreshTotal, telemetry.ageRefreshTotal, false),
            ("Background refresh moves", earlier.backgroundRefreshMoves, telemetry.backgroundRefreshMoves, false),
            ("Bands padded for age", earlier.bandsPaddedForAge, telemetry.bandsPaddedForAge, false),
            ("Read verify native", earlier.readVerifyNative, telemetry.readVerifyNative, false),
            ("Reduced read verify native", earlier.reducedReadVerifyNative, telemetry.reducedReadVerifyNative, false),
            ("Read verify pSLC", earlier.readVerifySLC, telemetry.readVerifySLC, false),
            ("Cross-temperature UECC", earlier.crossTemperatureUECC, telemetry.crossTemperatureUECC, true),
            ("Cross-temperature RAID UECC", earlier.crossTemperatureRaidUECC, telemetry.crossTemperatureRaidUECC, true),
            ("Utility UECC reads", earlier.utilityUECCReads, telemetry.utilityUECCReads, true),
            ("UECC reads", earlier.ueccReads, telemetry.ueccReads, true),
            ("Host pSLC read verify failures", earlier.hostSLCReadVerifyFailures, telemetry.hostSLCReadVerifyFailures, true),
            ("Host TLC read verify failures", earlier.hostTLCReadVerifyFailures, telemetry.hostTLCReadVerifyFailures, true),
            ("GC pSLC→TLC read verify failures", earlier.gcSLCToTLCReadVerifyFailures, telemetry.gcSLCToTLCReadVerifyFailures, true),
            ("GC TLC→TLC read verify failures", earlier.gcTLCToTLCReadVerifyFailures, telemetry.gcTLCToTLCReadVerifyFailures, true),
            ("Grown bad blocks", baseline.grownBadBlocks, latest.grownBadBlocks, true),
            ("Die failures", baseline.numDieFailures, latest.numDieFailures, true)
        ]
        var unavailable = [String]()
        for (name, before, after, isEvent) in all where !provisional || isEvent {
            if before == nil || after == nil { unavailable.append("\(name)（未取得）") }
        }
        var skippedNames = Set<String>()
        if let before = earlier.ageRefreshPerTier,
           let after = telemetry.ageRefreshPerTier,
           before.count != after.count {
            skippedNames.insert("Age refresh")
            unavailable.append("Age refresh（配列形状変更）")
        }
        if earlier.nandReads != nil, telemetry.nandReads != nil, nandReadDelta == nil {
            unavailable.append("nandReads counter（counter減少、ΔnandReadsあたりrate未算出）")
        }
        for (name, before, after, _) in all where before != nil && after != nil && difference(before, after) == nil {
            skippedNames.insert(name)
            unavailable.append("\(name)（counter減少）")
        }
        let counters = all.compactMap { name, before, after, isEvent -> FTLReliabilityCounterDelta? in
            guard !skippedNames.contains(name), !provisional || isEvent else { return nil }
            guard let delta = difference(before, after) else { return nil }
            let perDay = days > 0 ? Double(delta) / days : nil
            let perRead: Double?
            if let nandReadDelta, nandReadDelta > 0 {
                perRead = Double(delta) / Double(nandReadDelta)
            } else {
                perRead = nil
            }
            return FTLReliabilityCounterDelta(name: name, delta: delta, perDay: perDay,
                                              perNANDRead: perRead, isReliabilityEvent: isEvent)
        }
        let eventIncreased = counters.contains { $0.isReliabilityEvent && $0.delta > 0 }
        let recoveryIncreased = counters.contains { !$0.isReliabilityEvent && $0.delta > 0 }
        let state: FTLReliabilityState = eventIncreased ? .reliabilityEventObserved
            : recoveryIncreased ? .recoveryActivityObserved : .noNewObservedEvent
        var reason: String
        switch state {
        case .reliabilityEventObserved:
            reason = "比較可能な取得区間で、UECC／RV failure／bad block／die failureの少なくとも1件が増加しました。"
        case .recoveryActivityObserved:
            reason = "比較範囲ではhard failure増加はなく、refreshまたはread-recovery系の活動が増加しました。"
        case .noNewObservedEvent:
            reason = "取得できた比較counterでは新規イベント増加がありません。未取得項目を含む全項目正常を意味しません。"
        default:
            reason = "比較状態を判定できません。"
        }
        if provisional {
            reason += " " + UIString.text("研究用keyは互換性を仮定した暫定比較です。")
                + UIString.format(" 実行build %@ / 対応表build %@。", latest.sourceBuild ?? "unknown", DirectFTLResearchContract.contractBuild(for: latest) ?? "unknown")
        }
        if !unavailable.isEmpty {
            reason += " 個別counterの比較除外：\(unavailable.joined(separator: "、"))。"
        }
        if duration.basis == .wallClockFallback {
            reason += " Power On Hours差分が使えないため暦時間をfallbackにしています。"
        } else if duration.basis == .operatingHours {
            reason += " per-day rateはPower On Hours差分を分母にしています。"
        }
        return FTLReliabilityEvidence(
            baselineCapturedAt: baseline.capturedAt, comparedAt: latest.capturedAt,
            durationDays: days, wallDurationDays: duration.wallDurationDays,
            operatingHoursDelta: duration.operatingHoursDelta, durationBasis: duration.basis,
            researchSessionOverlap: intervalOverlapsResearch(baseline, latest, researchIntervals),
            state: state, reason: reason, counters: counters,
            unavailableCounters: unavailable, unmappedItems: Self.unmappedItems, latestTelemetry: telemetry,
            hostWriteCompositionAudit: HostWriteCompositionAuditor().assess(baseline: baseline, latest: latest),
            provisionalInterpretation: provisional
        )
    }

    private func isComparable(_ lhs: ASPToolDiagnosticsSnapshot, _ rhs: ASPToolDiagnosticsSnapshot) -> Bool {
        DirectFTLResearchContract.reliabilityPairIsComparable(lhs, rhs)
    }

    private func unavailableEvidence(
        latest: ASPToolDiagnosticsSnapshot,
        telemetry: FTLResearchTelemetrySnapshot,
        intervals: [DateInterval],
        state: FTLReliabilityState,
        reason: String
    ) -> FTLReliabilityEvidence {
        FTLReliabilityEvidence(
            baselineCapturedAt: nil,
            comparedAt: latest.capturedAt,
            durationDays: nil,
            wallDurationDays: nil,
            operatingHoursDelta: nil,
            durationBasis: .unavailable,
            researchSessionOverlap: pointIsInsideResearch(latest, intervals),
            state: state,
            reason: reason,
            counters: [],
            unavailableCounters: [],
            unmappedItems: Self.unmappedItems,
            latestTelemetry: telemetry,
            hostWriteCompositionAudit: HostWriteCompositionAuditor().assess(baseline: nil, latest: latest)
        )
    }

    /// A Host/NAND write counter reset changes the accounting series itself and
    /// invalidates the whole interval.  Other private event counters are
    /// independent observations: if one decreases, only that row is omitted.
    private func seriesCountersWentBackwards(from lhs: ASPToolDiagnosticsSnapshot, to rhs: ASPToolDiagnosticsSnapshot) -> Bool {
        func decreased(_ before: UInt64?, _ after: UInt64?) -> Bool {
            guard let before, let after else { return false }
            return after < before
        }
        return decreased(lhs.hostWrites, rhs.hostWrites) || decreased(lhs.nandWrites, rhs.nandWrites) ||
            decreased(lhs.powerOnHours, rhs.powerOnHours)
    }

    private func difference(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after, after >= before else { return nil }
        return after - before
    }

    private func intervalOverlapsResearch(
        _ start: ASPToolDiagnosticsSnapshot,
        _ end: ASPToolDiagnosticsSnapshot,
        _ intervals: [DateInterval]
    ) -> Bool {
        let interval = DateInterval(start: start.capturedAt, end: end.capturedAt)
        return intervals.contains { $0.intersects(interval) }
    }

    private func pointIsInsideResearch(_ snapshot: ASPToolDiagnosticsSnapshot, _ intervals: [DateInterval]) -> Bool {
        intervals.contains { $0.contains(snapshot.capturedAt) }
    }
}
