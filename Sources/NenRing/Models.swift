import Foundation

enum SmartMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case model
    case temperature
    case powerOnHours
    case powerCycles
    case unsafeShutdowns
    case percentageUsed
    case availableSpare
    case criticalWarning
    case mediaAndDataIntegrityErrors
    case dataUnitsRead
    case dataUnitsWritten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: return "モデル"
        case .temperature: return "温度"
        case .powerOnHours: return "Power On Hours"
        case .powerCycles: return "Power Cycles"
        case .unsafeShutdowns: return "Unsafe Shutdowns"
        case .percentageUsed: return "Percentage Used"
        case .availableSpare: return "Available Spare"
        case .criticalWarning: return "Critical Warning"
        case .mediaAndDataIntegrityErrors: return "Media / Data Errors"
        case .dataUnitsRead: return "Data Units Read"
        case .dataUnitsWritten: return "Data Units Written"
        }
    }
}

struct DriveSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    var deviceID: String
    var devicePath: String
    var logicalCapacityBytes: UInt64?
    var model: String?
    var serialNumber: String?
    let firmware: String?
    let smartctlVersion: String?
    let smartctlExitStatus: Int?
    /// Optional vendor/bridge-provided date. NVMe smartctl output commonly omits it.
    let usageStartDate: Date?
    var temperatureCelsius: Int?
    let powerOnHours: UInt64?
    let powerCycleCount: UInt64?
    let unsafeShutdowns: UInt64?
    let percentageUsed: UInt64?
    let availableSpare: UInt64?
    let availableSpareThreshold: UInt64?
    let criticalWarning: UInt64?
    let mediaAndDataIntegrityErrors: UInt64?
    let dataUnitsRead: UInt64?
    let dataUnitsWritten: UInt64?
    var filesystemTotalCapacityBytes: UInt64?
    /// Space not used by any file (purgeable files count as used).
    var filesystemFreeBytes: UInt64?
    /// Space available to the user, as Finder shows it, including
    /// purgeable files. Absent in records saved before it was added.
    var filesystemAvailableBytes: UInt64? = nil
    let smartPassed: Bool?
    let messages: [String]
    let parseWarnings: [String]
    /// The smartctl output, about 3 KB. Kept only for the latest reading;
    /// history stores the parsed values without it.
    var rawJSON: String
    /// Optional so pre-extension history remains readable without invented zeros.
    var additionalSMART: SMARTAdditionalCounters?
    var nvmeCapabilities: NVMeCapabilities?

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        deviceID: String,
        devicePath: String,
        logicalCapacityBytes: UInt64? = nil,
        model: String?,
        serialNumber: String?,
        firmware: String?,
        smartctlVersion: String?,
        smartctlExitStatus: Int?,
        usageStartDate: Date? = nil,
        temperatureCelsius: Int?,
        powerOnHours: UInt64?,
        powerCycleCount: UInt64?,
        unsafeShutdowns: UInt64?,
        percentageUsed: UInt64?,
        availableSpare: UInt64?,
        availableSpareThreshold: UInt64?,
        criticalWarning: UInt64?,
        mediaAndDataIntegrityErrors: UInt64?,
        dataUnitsRead: UInt64?,
        dataUnitsWritten: UInt64?,
        filesystemTotalCapacityBytes: UInt64? = nil,
        filesystemFreeBytes: UInt64? = nil,
        smartPassed: Bool?,
        messages: [String] = [],
        parseWarnings: [String] = [],
        rawJSON: String = "",
        additionalSMART: SMARTAdditionalCounters? = nil,
        nvmeCapabilities: NVMeCapabilities? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.deviceID = deviceID
        self.devicePath = devicePath
        self.logicalCapacityBytes = logicalCapacityBytes
        self.model = model
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.smartctlVersion = smartctlVersion
        self.smartctlExitStatus = smartctlExitStatus
        self.usageStartDate = usageStartDate
        self.temperatureCelsius = temperatureCelsius
        self.powerOnHours = powerOnHours
        self.powerCycleCount = powerCycleCount
        self.unsafeShutdowns = unsafeShutdowns
        self.percentageUsed = percentageUsed
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.criticalWarning = criticalWarning
        self.mediaAndDataIntegrityErrors = mediaAndDataIntegrityErrors
        self.dataUnitsRead = dataUnitsRead
        self.dataUnitsWritten = dataUnitsWritten
        self.filesystemTotalCapacityBytes = filesystemTotalCapacityBytes
        self.filesystemFreeBytes = filesystemFreeBytes
        self.smartPassed = smartPassed
        self.messages = messages
        self.parseWarnings = parseWarnings
        self.rawJSON = rawJSON
        self.additionalSMART = additionalSMART
        self.nvmeCapabilities = nvmeCapabilities
    }

    var availableMetricCount: Int {
        [
            model != nil,
            temperatureCelsius != nil,
            powerOnHours != nil,
            powerCycleCount != nil,
            unsafeShutdowns != nil,
            percentageUsed != nil,
            availableSpare != nil,
            criticalWarning != nil,
            mediaAndDataIntegrityErrors != nil,
            dataUnitsRead != nil,
            dataUnitsWritten != nil
        ].filter { $0 }.count
    }

    var healthMetricsMissing: [SmartMetric] {
        let fields: [UInt64?] = [
            percentageUsed,
            availableSpare,
            availableSpareThreshold,
            criticalWarning,
            mediaAndDataIntegrityErrors,
            dataUnitsRead,
            dataUnitsWritten
        ]
        var result: [SmartMetric] = []
        for (index, value) in fields.enumerated() where value == nil {
            let metric: SmartMetric?
            switch index {
            case 0: metric = .percentageUsed
            case 1, 2: metric = .availableSpare
            case 3: metric = .criticalWarning
            case 4: metric = .mediaAndDataIntegrityErrors
            case 5: metric = .dataUnitsRead
            case 6: metric = .dataUnitsWritten
            default: metric = nil
            }
            if let metric, !result.contains(metric) {
                result.append(metric)
            }
        }
        return result
    }

    var hasHealthLogValues: Bool {
        percentageUsed != nil || availableSpare != nil || criticalWarning != nil ||
            mediaAndDataIntegrityErrors != nil || dataUnitsRead != nil || dataUnitsWritten != nil
    }

    var dataUnitsReadBytes: Double? {
        guard let dataUnitsRead else { return nil }
        return Double(dataUnitsRead) * 512_000.0
    }

    var dataUnitsWrittenBytes: Double? {
        guard let dataUnitsWritten else { return nil }
        return Double(dataUnitsWritten) * 512_000.0
    }

    var filesystemFreeRatio: Double? {
        guard let total = filesystemTotalCapacityBytes,
              let free = filesystemFreeBytes,
              total > 0,
              free <= total
        else { return nil }
        return Double(free) / Double(total)
    }

    var filesystemAvailableRatio: Double? {
        guard let total = filesystemTotalCapacityBytes,
              let available = filesystemAvailableBytes,
              total > 0,
              available <= total
        else { return nil }
        return Double(available) / Double(total)
    }

    var evaluation: HealthEvaluation {
        if let criticalWarning, criticalWarning != 0 {
            return .warning("Critical Warning が 0x\(String(criticalWarning, radix: 16, uppercase: true)) です")
        }
        if let availableSpare, let threshold = availableSpareThreshold, availableSpare < threshold {
            return .warning("Available Spare が閾値を下回っています")
        }
        if let mediaAndDataIntegrityErrors, mediaAndDataIntegrityErrors > 0 {
            return .warning("Media / Data Errors が \(mediaAndDataIntegrityErrors) 件あります")
        }
        guard smartPassed != nil, hasHealthLogValues else {
            return .limited("health log または SMART 判定が取得できていません")
        }
        guard smartPassed == true else {
            return .warning("SMART 判定が PASSED ではありません")
        }
        return .normal
    }
}

enum UsageStartSource: String, Codable, Equatable, Sendable {
    case manual
    case reported
    case powerOnHours
    case firstObservation

    var title: String {
        switch self {
        case .manual: return "手動設定"
        case .reported: return "ドライブ報告値"
        case .powerOnHours: return "稼働時間から概算"
        case .firstObservation: return "初回観測から"
        }
    }
}

struct UsageSettings: Codable, Equatable, Sendable {
    var manualStartDate: Date?
    /// nil/automatic, lifetime, or a ResearchSession UUID. Optional for old JSON.
    var proxyWAFSelection: String?
    /// Research-only maximum average P/E assumptions; nil leaves that domain at its Controller EOL value.
    var proxyAllowableTLCPE: Double?
    var proxyAllowablePSLCPE: Double?
    /// Research retention-model inputs. Missing values intentionally resolve to the documented defaults.
    var retentionResearchProfileID: String?
    var retentionDays: Double?
    var retentionStorageTemperatureCelsius: Double?
    /// Whether the stored temperature is an intentional scenario override.
    /// Legacy 30 °C values represent the reference condition and resolve to automatic temperature.
    var retentionTemperatureOverrideEnabled: Bool?
    var retentionRBERThreshold: Double?
    var retentionActivationEnergyEV: Double?
    var retentionClientWAF: Double?
    /// Client WAF prior used for the current-workload normalization. The
    /// existing retentionClientWAF remains the explicit Client scenario.
    var retentionDailyWAFPrior: Double?
    /// Equivalent observed Host bytes used to blend the Retention Research
    /// daily WAF observation with its prior. Missing values default to 1 TB.
    var retentionDailyWAFPriorHostBytes: Double?
    /// Evidence scale for the central endurance Forecast WAF. This is
    /// intentionally independent from the Retention Research prior.
    var forecastWAFPriorEquivalentHostBytes: Double?
    var retentionClientWAFSelection: String?
    var retentionProgramCorrectionEnabled: Bool?
    /// Legacy name for the duration-only retention weight. New code should
    /// prefer retentionDaysWeight; retained so older settings remain readable.
    var retentionResearchWeight: Double?
    /// Weight applied only to the observed retention-duration contribution.
    /// When nil, the legacy retentionResearchWeight is used for compatibility,
    /// otherwise the documented default is 0.50.
    var retentionDaysWeight: Double?
    /// Weight applied to the temperature/model residual after the duration
    /// contribution is separated. Defaults to 0.20.
    var retentionEnvironmentWeight: Double?
    /// Optional domain-specific host bytes per P/E priors. These are never
    /// inferred from capacity or Controller EOL.
    var retentionTLCBytesPerPEPrior: Double?
    var retentionPSLCBytesPerPEPrior: Double?

    init(
        manualStartDate: Date? = nil,
        proxyAllowableTLCPE: Double? = nil,
        proxyAllowablePSLCPE: Double? = nil,
        retentionResearchProfileID: String? = nil,
        retentionDays: Double? = nil,
        retentionStorageTemperatureCelsius: Double? = nil,
        retentionTemperatureOverrideEnabled: Bool? = nil,
        retentionRBERThreshold: Double? = nil,
        retentionActivationEnergyEV: Double? = nil,
        retentionDailyWAFPrior: Double? = nil,
        retentionDailyWAFPriorHostBytes: Double? = nil,
        forecastWAFPriorEquivalentHostBytes: Double? = nil,
        retentionResearchWeight: Double? = nil,
        retentionDaysWeight: Double? = nil,
        retentionEnvironmentWeight: Double? = nil,
        retentionTLCBytesPerPEPrior: Double? = nil,
        retentionPSLCBytesPerPEPrior: Double? = nil
    ) {
        self.manualStartDate = manualStartDate
        self.proxyAllowableTLCPE = proxyAllowableTLCPE
        self.proxyAllowablePSLCPE = proxyAllowablePSLCPE
        self.retentionResearchProfileID = retentionResearchProfileID
        self.retentionDays = retentionDays
        self.retentionStorageTemperatureCelsius = retentionStorageTemperatureCelsius
        self.retentionTemperatureOverrideEnabled = retentionTemperatureOverrideEnabled
        self.retentionRBERThreshold = retentionRBERThreshold
        self.retentionActivationEnergyEV = retentionActivationEnergyEV
        self.retentionDailyWAFPrior = retentionDailyWAFPrior
        self.retentionDailyWAFPriorHostBytes = retentionDailyWAFPriorHostBytes
        self.forecastWAFPriorEquivalentHostBytes = forecastWAFPriorEquivalentHostBytes
        self.retentionResearchWeight = retentionResearchWeight
        self.retentionDaysWeight = retentionDaysWeight
        self.retentionEnvironmentWeight = retentionEnvironmentWeight
        self.retentionTLCBytesPerPEPrior = retentionTLCBytesPerPEPrior
        self.retentionPSLCBytesPerPEPrior = retentionPSLCBytesPerPEPrior
    }

    var isEmpty: Bool {
        manualStartDate == nil && proxyWAFSelection == nil
            && proxyAllowableTLCPE == nil && proxyAllowablePSLCPE == nil
            && retentionResearchProfileID == nil && retentionDays == nil
            && retentionStorageTemperatureCelsius == nil && retentionTemperatureOverrideEnabled == nil
            && retentionRBERThreshold == nil
            && retentionActivationEnergyEV == nil
            && retentionClientWAF == nil && retentionDailyWAFPrior == nil
            && retentionDailyWAFPriorHostBytes == nil
            && forecastWAFPriorEquivalentHostBytes == nil
            && retentionClientWAFSelection == nil && retentionResearchWeight == nil
            && retentionDaysWeight == nil && retentionEnvironmentWeight == nil
            && retentionTLCBytesPerPEPrior == nil && retentionPSLCBytesPerPEPrior == nil
            && retentionProgramCorrectionEnabled == nil
    }
}

extension UsageSettings {
    /// The 30 °C reference is not an observed storage temperature. Older
    /// settings stored it as a selected value, so treat that legacy value as
    /// automatic unless the user explicitly enabled a temperature override.
    var effectiveRetentionStorageTemperatureCelsius: Double? {
        guard let temperature = retentionStorageTemperatureCelsius else { return nil }
        if retentionTemperatureOverrideEnabled == true { return temperature }
        if retentionTemperatureOverrideEnabled == false { return nil }
        return abs(temperature - RetentionScenario.referenceTemperatureCelsius) < 0.001
            ? nil
            : temperature
    }

    var hasExplicitRetentionTemperatureOverride: Bool {
        effectiveRetentionStorageTemperatureCelsius != nil
    }

    /// Retention inputs from the settings form. Values the user left at
    /// their default stay unset, so they keep resolving to "default" and
    /// "automatic" rather than being stored as explicit choices.
    func withRetentionInputs(manualTemperatureCelsius: Double?, days: Double?) -> UsageSettings {
        var updated = self
        updated.retentionTemperatureOverrideEnabled = manualTemperatureCelsius != nil ? true : nil
        updated.retentionStorageTemperatureCelsius = manualTemperatureCelsius
        if days != (retentionDays ?? RetentionScenario.referenceDays) {
            updated.retentionDays = days
        }
        return updated
    }

    /// The settings window edits only the start date and average hours.
    /// Every other field (research priors and weights) is kept as stored.
    func withStartBasis(manualStartDate: Date?) -> UsageSettings {
        var updated = self
        updated.manualStartDate = manualStartDate
        return updated
    }
}

/// What a usage start date says about a drive. The SMART counters cover its
/// whole life, so these averages include the time before NenRing recorded.
struct UsageStartSummary: Equatable, Sendable {
    /// Earlier dates are input mistakes, such as a two-digit year.
    static let earliestStartDate = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01 UTC

    let elapsedDays: Double
    let averagePowerOnHoursPerDay: Double?
    let hostBytesPerDay: Double?

    init?(start: Date, snapshot: DriveSnapshot) {
        let days = snapshot.capturedAt.timeIntervalSince(start) / 86_400
        guard days.isFinite, days > 0 else { return nil }
        elapsedDays = days
        averagePowerOnHoursPerDay = snapshot.powerOnHours.map { Double($0) / days }
        hostBytesPerDay = snapshot.dataUnitsWrittenBytes.map { $0 / days }
    }

    /// A drive cannot have run longer than the time since its first use. One
    /// day of slack covers a date picked without a time of day.
    static func validationMessage(start: Date, snapshot: DriveSnapshot?, now: Date) -> String? {
        if start > now { return "使用開始日は今日以前の日付を指定してください。" }
        if start < earliestStartDate { return "使用開始日は2000年以降の日付を指定してください。" }
        if let snapshot, let powerOnHours = snapshot.powerOnHours,
           Double(powerOnHours) > (snapshot.capturedAt.timeIntervalSince(start) / 86_400 + 1) * 24 {
            return "使用開始日がSSDの稼働時間と矛盾します。以前の使用分も含む日付を指定してください。"
        }
        return nil
    }
}

/// How often SMART is read. Direct FTL, where available, is read in the
/// same cycle, so the Host (SMART) and NAND/pSLC (FTL) charts share their
/// points and the forecast is rebuilt once per cycle.
enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600

    /// Measured on the reference Mac: a cycle costs well under a second of
    /// CPU, and Host writes move within minutes, so ten minutes keeps the
    /// write charts fine without putting the app among the busy ones.
    static let defaultInterval: Self = .tenMinutes

    /// Reads a saved preference. Earlier builds also offered 1 and 3 minutes
    /// and 3 hours to 1 day; those are read as the nearest remaining option.
    init?(savedSeconds: Int) {
        if let interval = Self(rawValue: savedSeconds) {
            self = interval
        } else if savedSeconds > 0, savedSeconds < Self.fiveMinutes.rawValue {
            self = .fiveMinutes
        } else if savedSeconds > Self.oneHour.rawValue {
            self = .oneHour
        } else {
            return nil
        }
    }

    var id: Int { rawValue }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .fiveMinutes: return "5分"
        case .tenMinutes: return "10分"
        case .fifteenMinutes: return "15分"
        case .thirtyMinutes: return "30分"
        case .oneHour: return "1時間"
        }
    }
}

/// IORegistry provides slowly changing hardware context. Keep its separate,
/// user-configurable schedule independent from frequent SMART polling.
enum IORegistryCollectionInterval: Int, CaseIterable, Identifiable, Sendable {
    case launchOnly = 0
    case thirtyMinutes = 1800
    case oneHour = 3600
    case threeHours = 10800
    case sixHours = 21600
    case twelveHours = 43200
    case oneDay = 86400

    /// Explicit product default for a missing or invalid preference.
    static let defaultInterval: Self = .oneDay

    /// Reads a saved preference. Earlier builds also offered 3 days and
    /// 1 week; such values are read as 1 day.
    init?(savedSeconds: Int) {
        if let interval = Self(rawValue: savedSeconds) {
            self = interval
        } else if savedSeconds > Self.oneDay.rawValue {
            self = .oneDay
        } else {
            return nil
        }
    }

    var id: Int { rawValue }

    var isAutomatic: Bool { self != .launchOnly }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .launchOnly: return "起動時のみ"
        case .thirtyMinutes: return "30分"
        case .oneHour: return "1時間"
        case .threeHours: return "3時間"
        case .sixHours: return "6時間"
        case .twelveHours: return "12時間"
        case .oneDay: return "1日"
        }
    }

    var detail: String {
        switch self {
        case .launchOnly:
            return "起動時と手動取得時のみ、Appleのハードウェア情報を取得します。"
        default:
            return "SMARTとは別にAppleのハードウェア情報を更新します。未設定時は1日間隔です。起動時と復帰時にも再確認します。"
        }
    }
}

enum SleepMonitoringMode: String, CaseIterable, Identifiable, Sendable {
    case wakeOnly
    case bestEffort

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wakeOnly: return "復帰時のみ取得（推奨）"
        case .bestEffort: return "システム判断で低頻度取得（目安60分）"
        }
    }

    var detail: String {
        switch self {
        case .wakeOnly:
            return "スリープ中は停止し、復帰直後に1回のみ取得します。"
        case .bestEffort:
            return "macOSの電力判断で実行されるため、60分ごとの動作は保証されません。"
        }
    }
}

enum LoginItemStatus: String, Equatable, Sendable {
    case unknown
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var title: String {
        switch self {
        case .unknown: return "確認中"
        case .notRegistered: return "未登録"
        case .enabled: return "有効"
        case .requiresApproval: return "許可が必要"
        case .notFound: return "確認できません"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            return "ログイン項目の状態を確認しています。"
        case .notRegistered:
            return "ログイン時には起動しません。"
        case .enabled:
            return "ログイン時の起動が有効です。"
        case .requiresApproval:
            return "システム設定のログイン項目で許可が必要です。"
        case .notFound:
            return "ログイン項目を確認できません。アプリをApplicationsへ置いて再度お試しください。"
        }
    }
}

struct UsageStart: Equatable, Sendable {
    let date: Date
    let source: UsageStartSource
}

/// A deliberately rough projection derived from cumulative writes and wear.
/// It is supplementary to the Percentage Used slope estimate, not a failure date.
struct WriteBasedLifeProjection: Equatable, Sendable {
    let usageStart: UsageStart
    let elapsedDays: Double
    let observedWrittenBytes: Double
    let averageDailyWriteRateBytes: Double
    let estimatedTotalLifetimeBytes: Double
    let remainingBytes: Double
    let remainingPercent: Double
    let lowerDate: Date
    let upperDate: Date
    let confidence: LifeEstimate.Confidence
}

enum HealthEvaluation: Equatable, Sendable {
    case normal
    case warning(String)
    case limited(String)

    var title: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "警告"
        case .limited: return "部分取得"
        }
    }

    var detail: String {
        switch self {
        case .normal: return "smartctl が返した health 情報を確認済み"
        case let .warning(message), let .limited(message): return message
        }
    }
}

enum StorageDeviceLocation: String, Codable, Equatable, Sendable {
    case internalDevice
    case externalDevice
    case unknown

    var title: String {
        switch self {
        case .internalDevice: return "内蔵"
        case .externalDevice: return "外付け"
        case .unknown: return "接続位置未確認"
        }
    }
}

struct StorageDeviceCapabilities: Equatable, Sendable {
    let location: StorageDeviceLocation
    let appleDirectFTLEligible: Bool
    let usableCandidateCount: Int

    static let unknown = StorageDeviceCapabilities(
        location: .unknown,
        appleDirectFTLEligible: false,
        usableCandidateCount: 0
    )
}

struct DeviceCandidate: Equatable, Sendable, Identifiable {
    let path: String
    let type: String?
    let source: CandidateSource
    let location: StorageDeviceLocation

    init(path: String, type: String?, source: CandidateSource, location: StorageDeviceLocation = .unknown) {
        self.path = path
        self.type = type
        self.source = source
        self.location = location
    }

    var id: String { path }

    var isAppleANSControllerPath: Bool {
        path.localizedCaseInsensitiveContains("AppleANS")
    }
}

enum CandidateSource: String, Sendable {
    case smartctlScan
    case rawDiskFallback
}

struct SmartctlCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
}

struct SmartctlIdentity: Sendable {
    let model: String?
    let serialNumber: String?
    let logicalCapacityBytes: UInt64?
}

struct ProbeAttempt: Sendable, Identifiable {
    let candidate: DeviceCandidate
    let snapshot: DriveSnapshot?
    let errorMessage: String?

    var id: String { candidate.path }
}

struct ProbeReport: Sendable {
    let snapshot: DriveSnapshot
    let executablePath: String
    let attempts: [ProbeAttempt]
    let diagnostic: String?
    let appleStorageProfile: AppleNANDHardwareProfile?
    let deviceCapabilities: StorageDeviceCapabilities
    var storageTargetResolution: StorageTargetResolution? = nil
}

enum DashboardState: Equatable, Sendable {
    case idle
    case probing
    case ready
    case limited
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "待機中"
        case .probing: return "確認中"
        case .ready: return "接続済み"
        case .limited: return "部分取得"
        case .failed: return "取得不可"
        }
    }
}

enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case hour
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "時間"
        case .day: return "日"
        case .week: return "週"
        case .month: return "月"
        }
    }
}

struct WritePoint: Identifiable, Equatable, Sendable {
    let bucket: Date
    let bytes: Double
    let sampleCount: Int
    /// Approximate wall-clock coverage represented by observed, short gaps.
    /// Long gaps keep their bytes for total consistency but are marked partial.
    let coverageFraction: Double
    let containsSpanningDelta: Bool

    var id: Date { bucket }

    init(
        bucket: Date,
        bytes: Double,
        sampleCount: Int,
        coverageFraction: Double = 1,
        containsSpanningDelta: Bool = false
    ) {
        self.bucket = bucket
        self.bytes = bytes
        self.sampleCount = sampleCount
        self.coverageFraction = min(max(coverageFraction, 0), 1)
        self.containsSpanningDelta = containsSpanningDelta
    }

    var isPartial: Bool {
        containsSpanningDelta || coverageFraction < 0.5
    }
}

struct TemperaturePoint: Identifiable, Equatable, Sendable {
    let date: Date
    let celsius: Double

    var id: Date { date }

    /// Fewer points for drawing: the time span is split into equal buckets
    /// and each keeps its lowest and highest reading, in time order, so peaks
    /// stay visible. Input must be sorted by date. Stored data is unchanged.
    static func downsampled(_ points: [TemperaturePoint], maximumCount: Int) -> [TemperaturePoint] {
        guard maximumCount >= 2, points.count > maximumCount,
              let first = points.first?.date, let last = points.last?.date, last > first else { return points }
        let bucketCount = maximumCount / 2
        let span = last.timeIntervalSince(first)
        var result: [TemperaturePoint] = []
        result.reserveCapacity(maximumCount)
        var index = 0
        for bucket in 0..<bucketCount {
            let end = bucket == bucketCount - 1
                ? last
                : first.addingTimeInterval(span * Double(bucket + 1) / Double(bucketCount))
            var low: TemperaturePoint?
            var high: TemperaturePoint?
            while index < points.count, points[index].date <= end {
                let point = points[index]
                if low.map({ point.celsius < $0.celsius }) ?? true { low = point }
                if high.map({ point.celsius > $0.celsius }) ?? true { high = point }
                index += 1
            }
            guard let low, let high else { continue }
            if low.date == high.date {
                result.append(low)
            } else {
                result.append(contentsOf: low.date < high.date ? [low, high] : [high, low])
            }
        }
        return result
    }
}

/// One stretch of a temperature line that stays on one side of the warm
/// threshold. Where the line crosses it, a point on the threshold is added to
/// both neighbouring runs so the two colours meet exactly there.
struct TemperatureLineRun: Identifiable, Equatable, Sendable {
    static let warmThreshold = 50.0

    let id: Int
    let isWarm: Bool
    let points: [TemperaturePoint]

    /// Each section is a stretch of time-ordered readings without a gap.
    static func runs(sections: [[TemperaturePoint]], threshold: Double = warmThreshold) -> [TemperatureLineRun] {
        var result: [TemperatureLineRun] = []
        func close(_ points: [TemperaturePoint], isWarm: Bool) {
            guard points.count >= 2 else { return }
            result.append(TemperatureLineRun(id: result.count, isWarm: isWarm, points: points))
        }
        for section in sections {
            guard let first = section.first else { continue }
            var current = [first]
            var isWarm = first.celsius > threshold
            for point in section.dropFirst() {
                let pointIsWarm = point.celsius > threshold
                if pointIsWarm != isWarm, let previous = current.last {
                    let fraction = (threshold - previous.celsius) / (point.celsius - previous.celsius)
                    let date = previous.date.addingTimeInterval(point.date.timeIntervalSince(previous.date) * fraction)
                    let crossing = TemperaturePoint(date: date, celsius: threshold)
                    if crossing.date != previous.date { current.append(crossing) }
                    close(current, isWarm: isWarm)
                    current = [crossing.date == previous.date ? previous : crossing]
                    isWarm = pointIsWarm
                }
                if point.date != current.last?.date { current.append(point) }
            }
            close(current, isWarm: isWarm)
        }
        return result
    }
}

enum LifeEstimate: Equatable, Sendable {
    case unavailable(String)
    case collecting(String, dailyWriteRateBytes: Double?, writePerPowerHourBytes: Double?)
    case estimated(
        lowerDate: Date,
        upperDate: Date,
        confidence: Confidence,
        remainingPercent: Double,
        dailyWriteRateBytes: Double?,
        writePerPowerHourBytes: Double?
    )
    case reached(remainingPercent: Double)

    enum Confidence: String, Sendable {
        case veryLow
        case low
        case medium
        case high
        case veryHigh
    }
}

enum ForecastState: String, Codable, Equatable, Sendable {
    case unavailable
    case collecting
    case estimated
    case reached
}

enum ForecastConfidence: String, Codable, Equatable, Sendable {
    case veryLow
    case low
    case medium
    case high
    case veryHigh

    var title: String {
        switch self {
        case .veryLow: return "非常に低い"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .veryHigh: return "非常に高い"
        }
    }
}

struct WriteRateSummary: Codable, Equatable, Sendable {
    let oneDayBytesPerDay: Double?
    let sevenDayBytesPerDay: Double?
    let thirtyDayBytesPerDay: Double?
    let ninetyDayBytesPerDay: Double?
    let lifetimeBytesPerDay: Double?
    let recordedHistoryBytesPerDay: Double?
    let recordedHistoryObservedDays: Double?
    let bytesPerPowerOnHour: Double?
    /// Effective observed calendar days used for each rate. These may be
    /// shorter than the label's target window while history is still young;
    /// the UI marks those values as provisional rather than hiding them.
    let oneDayObservedDays: Double?
    let sevenDayObservedDays: Double?
    let thirtyDayObservedDays: Double?
    let ninetyDayObservedDays: Double?
    let lifetimeObservedDays: Double?
    /// Provenance for the long-term anchor.  Older history files do not have
    /// this field and decode as nil, which means the rate came from the
    /// retained continuous segment rather than a reported/manual start date.
    let lifetimeRateBasis: String?
    let lifetimeStartDate: Date?

    init(
        oneDayBytesPerDay: Double? = nil,
        sevenDayBytesPerDay: Double? = nil,
        thirtyDayBytesPerDay: Double? = nil,
        ninetyDayBytesPerDay: Double? = nil,
        lifetimeBytesPerDay: Double? = nil,
        recordedHistoryBytesPerDay: Double? = nil,
        recordedHistoryObservedDays: Double? = nil,
        bytesPerPowerOnHour: Double? = nil,
        oneDayObservedDays: Double? = nil,
        sevenDayObservedDays: Double? = nil,
        thirtyDayObservedDays: Double? = nil,
        ninetyDayObservedDays: Double? = nil,
        lifetimeObservedDays: Double? = nil,
        lifetimeRateBasis: String? = nil,
        lifetimeStartDate: Date? = nil
    ) {
        self.oneDayBytesPerDay = oneDayBytesPerDay
        self.sevenDayBytesPerDay = sevenDayBytesPerDay
        self.thirtyDayBytesPerDay = thirtyDayBytesPerDay
        self.ninetyDayBytesPerDay = ninetyDayBytesPerDay
        self.lifetimeBytesPerDay = lifetimeBytesPerDay
        self.recordedHistoryBytesPerDay = recordedHistoryBytesPerDay
        self.recordedHistoryObservedDays = recordedHistoryObservedDays
        self.bytesPerPowerOnHour = bytesPerPowerOnHour
        self.oneDayObservedDays = oneDayObservedDays
        self.sevenDayObservedDays = sevenDayObservedDays
        self.thirtyDayObservedDays = thirtyDayObservedDays
        self.ninetyDayObservedDays = ninetyDayObservedDays
        self.lifetimeObservedDays = lifetimeObservedDays
        self.lifetimeRateBasis = lifetimeRateBasis
        self.lifetimeStartDate = lifetimeStartDate
    }

    /// The recent workload used for the "Current workload" projection. A
    /// 30-day window is preferred because it smooths hourly sampling noise;
    /// shorter or longer windows are fallbacks when the history is young.
    var currentWorkloadBytesPerDay: Double? {
        thirtyDayBytesPerDay ?? sevenDayBytesPerDay ?? ninetyDayBytesPerDay ?? lifetimeBytesPerDay
    }

    /// The target window that supplied `currentWorkloadBytesPerDay`.
    /// `nil` means that only the lifetime rate was available.
    var currentWorkloadTargetDays: Double? {
        if thirtyDayBytesPerDay != nil { return 30 }
        if sevenDayBytesPerDay != nil { return 7 }
        if ninetyDayBytesPerDay != nil { return 90 }
        return nil
    }

    /// Effective observed days for the rate used as the current workload.
    var currentWorkloadObservedDays: Double? {
        if thirtyDayBytesPerDay != nil { return thirtyDayObservedDays }
        if sevenDayBytesPerDay != nil { return sevenDayObservedDays }
        if ninetyDayBytesPerDay != nil { return ninetyDayObservedDays }
        return lifetimeObservedDays
    }

    /// Whether the current workload is based on less than its nominal target
    /// window. This is a provenance flag, not a statistical confidence value.
    var currentWorkloadIsPartial: Bool {
        guard let target = currentWorkloadTargetDays,
              let observed = currentWorkloadObservedDays else { return false }
        return observed + 1e-9 < target
    }

    /// Fewer observed days than this make arrival times from the current
    /// pace provisional: a few light or heavy hours can move them by decades.
    static let settledCurrentWorkloadObservedDays = 7.0

    var currentWorkloadIsProvisional: Bool {
        guard let observed = currentWorkloadObservedDays else { return true }
        return observed < Self.settledCurrentWorkloadObservedDays
    }

    /// The same rule for the rate from the saved continuous history.
    var recordedHistoryIsProvisional: Bool {
        guard let observed = recordedHistoryObservedDays else { return true }
        return observed < Self.settledCurrentWorkloadObservedDays
    }

    /// A known start date stands in only until the saved history settles,
    /// because its average is dominated by the time before recording began.
    var usesUsageStartPace: Bool {
        lifetimeRateBasis != nil && lifetimeBytesPerDay != nil && recordedHistoryIsProvisional
    }

    /// The pace behind long-range arrival dates.
    var forecastPaceBytesPerDay: Double? {
        usesUsageStartPace ? lifetimeBytesPerDay : recordedHistoryBytesPerDay ?? lifetimeBytesPerDay
    }

    /// The slower-moving workload used for the "Typical workload" projection.
    /// Prefer 90 days, then the lifetime rate, and only then recent windows.
    var typicalWorkloadBytesPerDay: Double? {
        ninetyDayBytesPerDay ?? forecastPaceBytesPerDay ?? thirtyDayBytesPerDay ?? sevenDayBytesPerDay
    }

}

/// A capacity-scaled planning scenario for retention-aware budgeting.
///
/// This is deliberately separate from `EnduranceForecast`: it is not an
/// Apple/SSD vendor TBW rating, a SMART-reported limit, or a failure
/// prediction. The DWPD envelope is a product assumption used to make a
/// capacity-aware replacement plan when retention evidence is incomplete.
struct RetentionPlanningEstimate: Equatable, Sendable {
    /// These are planning assumptions, not an Apple endurance specification.
    /// They intentionally remain broad until device-specific retention data is
    /// available. A five-year horizon keeps the scenario comparable across
    /// capacities without presenting it as a lifetime guarantee.
    static let lowerPlanningDWPD = 0.3
    static let upperPlanningDWPD = 0.6
    static let planningYears = 5.0
    static let daysPerYear = 365.2425

    let currentHostWrittenBytes: Double
    let capacityBytes: Double
    let lowerPlanningDWPD: Double
    let upperPlanningDWPD: Double
    let planningYears: Double
    let thresholdLowerBytes: Double
    let thresholdUpperBytes: Double
    let remainingLowerBytes: Double
    let remainingUpperBytes: Double
    let lowerDate: Date?
    let upperDate: Date?
    let referenceDate: Date
    let rateBytesPerDay: Double
    let basis: String

    var thresholdAlreadyReached: Bool {
        currentHostWrittenBytes >= thresholdUpperBytes
    }

}

struct TemperatureSample: Codable, Equatable, Identifiable, Sendable {
    /// Statistics of the readings a day-level sample stands for. Older days
    /// are compacted to one sample whose `temperatureCelsius` is the rounded
    /// average; the raw readings are kept in the compaction archive.
    struct DailySummary: Codable, Equatable, Sendable {
        let minimumCelsius: Int
        let maximumCelsius: Int
        let averageCelsius: Double
        let sampleCount: Int
    }

    let id: UUID
    let capturedAt: Date
    let deviceID: String
    let temperatureCelsius: Int
    /// Present only on day-level samples produced by compaction.
    let dailySummary: DailySummary?
    /// Host reads and writes read at the same moment, so low load can be
    /// judged per minute instead of per SMART interval. Absent in older
    /// samples and when the block storage driver could not be identified.
    let blockIO: BlockIOCounters?

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        deviceID: String,
        temperatureCelsius: Int,
        dailySummary: DailySummary? = nil,
        blockIO: BlockIOCounters? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.deviceID = deviceID
        self.temperatureCelsius = temperatureCelsius
        self.dailySummary = dailySummary
        self.blockIO = blockIO
    }
}

struct TemperatureReading: Sendable {
    let capturedAt: Date
    let deviceID: String
    let temperatureCelsius: Int
    let criticalWarning: UInt64?

    init(capturedAt: Date, deviceID: String, temperatureCelsius: Int, criticalWarning: UInt64? = nil) {
        self.capturedAt = capturedAt
        self.deviceID = deviceID
        self.temperatureCelsius = temperatureCelsius
        self.criticalWarning = criticalWarning
    }
}

enum TemperatureMonitoringInterval: Int, CaseIterable, Identifiable, Sendable {
    case thirtySeconds = 30
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300

    var id: Int { rawValue }

    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .thirtySeconds: return "30秒"
        case .oneMinute: return "1分"
        case .threeMinutes: return "3分"
        case .fiveMinutes: return "5分"
        }
    }
}

struct WearTransition: Codable, Equatable, Identifiable, Sendable {
    let fromPercentage: UInt64
    let toPercentage: UInt64
    let previousTimestamp: Date
    let detectedTimestamp: Date
    let previousDataUnitsWritten: UInt64
    let detectedDataUnitsWritten: UInt64
    let previousPowerOnHours: UInt64?
    let detectedPowerOnHours: UInt64?
    let previousTemperatureCelsius: Int?
    let detectedTemperatureCelsius: Int?
    let firmwareVersion: String?
    let isLeftCensored: Bool

    var id: String {
        "\(detectedTimestamp.timeIntervalSince1970)-\(fromPercentage)-\(toPercentage)"
    }

    var percentageDelta: UInt64 {
        toPercentage >= fromPercentage ? toPercentage - fromPercentage : 0
    }

    var previousHostWrittenBytes: Double {
        Double(previousDataUnitsWritten) * 512_000.0
    }

    var detectedHostWrittenBytes: Double {
        Double(detectedDataUnitsWritten) * 512_000.0
    }

    var representativeHostWrittenBytes: Double {
        (previousHostWrittenBytes + detectedHostWrittenBytes) / 2
    }

    var hostWrittenBytesPerPercentage: Double? {
        guard percentageDelta > 0 else { return nil }
        return (detectedHostWrittenBytes - previousHostWrittenBytes) / Double(percentageDelta)
    }

}

struct EnduranceForecast: Equatable, Sendable {
    let state: ForecastState
    let message: String
    /// Set when the estimate rests on a retail reference TBW because
    /// Percentage Used has not moved yet.
    var referenceTBW: ReferenceTBWResolution?
    let currentPercentage: UInt64?
    let currentHostWrittenBytes: Double?
    let estimatedEnduranceBytes: Double?
    let enduranceRangeLowerBytes: Double?
    let enduranceRangeUpperBytes: Double?
    let remainingHostWriteBytes: Double?
    let remainingRangeLowerBytes: Double?
    let remainingRangeUpperBytes: Double?
    let lowerDate: Date?
    let upperDate: Date?
    let currentWorkloadLowerDate: Date?
    let currentWorkloadUpperDate: Date?
    let typicalWorkloadLowerDate: Date?
    let typicalWorkloadUpperDate: Date?
    let confidence: ForecastConfidence
    let confidenceScore: Int
    let transitionCount: Int
    let observationDays: Double
    let writeRates: WriteRateSummary
    let basis: String

    init(
        state: ForecastState,
        message: String,
        currentPercentage: UInt64? = nil,
        currentHostWrittenBytes: Double? = nil,
        estimatedEnduranceBytes: Double? = nil,
        enduranceRangeLowerBytes: Double? = nil,
        enduranceRangeUpperBytes: Double? = nil,
        remainingHostWriteBytes: Double? = nil,
        remainingRangeLowerBytes: Double? = nil,
        remainingRangeUpperBytes: Double? = nil,
        lowerDate: Date? = nil,
        upperDate: Date? = nil,
        currentWorkloadLowerDate: Date? = nil,
        currentWorkloadUpperDate: Date? = nil,
        typicalWorkloadLowerDate: Date? = nil,
        typicalWorkloadUpperDate: Date? = nil,
        confidence: ForecastConfidence = .veryLow,
        confidenceScore: Int = 0,
        transitionCount: Int = 0,
        observationDays: Double = 0,
        writeRates: WriteRateSummary = WriteRateSummary(),
        basis: String = ""
    ) {
        self.state = state
        self.message = message
        self.currentPercentage = currentPercentage
        self.currentHostWrittenBytes = currentHostWrittenBytes
        self.estimatedEnduranceBytes = estimatedEnduranceBytes
        self.enduranceRangeLowerBytes = enduranceRangeLowerBytes
        self.enduranceRangeUpperBytes = enduranceRangeUpperBytes
        self.remainingHostWriteBytes = remainingHostWriteBytes
        self.remainingRangeLowerBytes = remainingRangeLowerBytes
        self.remainingRangeUpperBytes = remainingRangeUpperBytes
        self.lowerDate = lowerDate
        self.upperDate = upperDate
        self.currentWorkloadLowerDate = currentWorkloadLowerDate
        self.currentWorkloadUpperDate = currentWorkloadUpperDate
        self.typicalWorkloadLowerDate = typicalWorkloadLowerDate
        self.typicalWorkloadUpperDate = typicalWorkloadUpperDate
        self.confidence = confidence
        self.confidenceScore = min(max(confidenceScore, 0), 100)
        self.transitionCount = transitionCount
        self.observationDays = max(0, observationDays)
        self.writeRates = writeRates
        self.basis = basis
    }
}

enum GeometryConfidence: String, Codable, Equatable, Sendable {
    case unknown
    case partial
    case consistent
    case inconsistent

    var title: String {
        switch self {
        case .unknown: return "不明"
        case .partial: return "部分整合"
        case .consistent: return "整合"
        case .inconsistent: return "不整合"
        }
    }
}

/// A privacy-preserving subset of Apple IORegistry storage metadata.
/// Undocumented geometry is diagnostic/cohort context by default; it is not a
/// confirmed remaining-life, WAF, P/E-cycle, pSLC-size, or spare-block input.
/// The retention research estimator may opt into a consistency-checked
/// geometry capacity as an explicitly labeled C_NAND_eff research proxy.
struct AppleNANDHardwareProfile: Codable, Equatable, Identifiable, Sendable {
    /// Selected SMART service's IOStorageFeatures.Unmap, not a TRIM activity log.
    var unmapSupported: Bool?
    /// Time at which this IORegistry profile was actually read.  A profile
    /// without a timestamp may still be useful as last-known geometry, but it
    /// must not be attached to a newer Direct FTL series as fresh identity.
    let capturedAt: Date?
    let modelNumber: String
    let logicalCapacityBytes: UInt64
    let nandVendor: String?
    let nandMarketingName: String?
    let defaultBitsPerCell: Int?
    let controllerClass: String?
    let chipID: String?
    let firmwareVersion: String?
    let mspVersion: String?
    let pageSize: UInt64?
    let pagesPerBlockNative: UInt64?
    let pagesPerBlockSLC: UInt64?
    let sectorsPerPage: UInt64?
    let blocksPerCAU: UInt64?
    let cauPerDie: UInt64?
    let numBus: Int?
    let diesPerBus: [Int]?
    let busToMSP: [Int]?
    let numDIP: Int?
    let sectorsPerFullBand: UInt64?
    let sectorsPerFullBandSLC: UInt64?
    let packageBlocksAtEOL: UInt64?
    let appleNANDStatus: String?
    let physicalInterconnect: String?
    let physicalInterconnectLocation: String?
    let profileVersion: Int

    init(
        capturedAt: Date? = nil,
        modelNumber: String = "",
        logicalCapacityBytes: UInt64 = 0,
        nandVendor: String? = nil,
        nandMarketingName: String? = nil,
        defaultBitsPerCell: Int? = nil,
        controllerClass: String? = nil,
        chipID: String? = nil,
        firmwareVersion: String? = nil,
        mspVersion: String? = nil,
        pageSize: UInt64? = nil,
        pagesPerBlockNative: UInt64? = nil,
        pagesPerBlockSLC: UInt64? = nil,
        sectorsPerPage: UInt64? = nil,
        blocksPerCAU: UInt64? = nil,
        cauPerDie: UInt64? = nil,
        numBus: Int? = nil,
        diesPerBus: [Int]? = nil,
        busToMSP: [Int]? = nil,
        numDIP: Int? = nil,
        sectorsPerFullBand: UInt64? = nil,
        sectorsPerFullBandSLC: UInt64? = nil,
        packageBlocksAtEOL: UInt64? = nil,
        appleNANDStatus: String? = nil,
        physicalInterconnect: String? = nil,
        physicalInterconnectLocation: String? = nil,
        profileVersion: Int = 1
    ) {
        self.capturedAt = capturedAt
        self.modelNumber = modelNumber
        self.logicalCapacityBytes = logicalCapacityBytes
        self.nandVendor = nandVendor
        self.nandMarketingName = nandMarketingName
        self.defaultBitsPerCell = defaultBitsPerCell
        self.controllerClass = controllerClass
        self.chipID = chipID
        self.firmwareVersion = firmwareVersion
        self.mspVersion = mspVersion
        self.pageSize = pageSize
        self.pagesPerBlockNative = pagesPerBlockNative
        self.pagesPerBlockSLC = pagesPerBlockSLC
        self.sectorsPerPage = sectorsPerPage
        self.blocksPerCAU = blocksPerCAU
        self.cauPerDie = cauPerDie
        self.numBus = numBus
        self.diesPerBus = diesPerBus
        self.busToMSP = busToMSP
        self.numDIP = numDIP
        self.sectorsPerFullBand = sectorsPerFullBand
        self.sectorsPerFullBandSLC = sectorsPerFullBandSLC
        self.packageBlocksAtEOL = packageBlocksAtEOL
        self.appleNANDStatus = appleNANDStatus
        self.physicalInterconnect = physicalInterconnect
        self.physicalInterconnectLocation = physicalInterconnectLocation
        self.profileVersion = profileVersion
    }

    var id: String {
        "\(modelNumber)|\(logicalCapacityBytes)|\(nandMarketingName ?? "unknown")|v\(profileVersion)"
    }

    var hasValues: Bool {
        logicalCapacityBytes > 0 || nandVendor != nil || nandMarketingName != nil || controllerClass != nil
    }

    var geometryIssues: [String] {
        var issues: [String] = []
        if let diesPerBus, let cauPerDie, let numDIP {
            let totalDies = diesPerBus.reduce(0, +)
            let product = totalDies >= 0
                ? UInt64(totalDies).multipliedReportingOverflow(by: cauPerDie)
                : (partialValue: UInt64.zero, overflow: true)
            if totalDies < 0 || numDIP < 0 || product.overflow || product.partialValue != UInt64(numDIP) {
                issues.append("dies-per-bus × cau-per-die と num-dip が一致しません")
            }
        }
        if let numDIP, let pagesPerBlockSLC, let sectorsPerPage, let sectorsPerFullBandSLC,
           numDIP >= 0 {
            let firstProduct = UInt64(numDIP).multipliedReportingOverflow(by: pagesPerBlockSLC)
            let secondProduct = firstProduct.partialValue.multipliedReportingOverflow(by: sectorsPerPage)
            if firstProduct.overflow || secondProduct.overflow || secondProduct.partialValue != sectorsPerFullBandSLC {
                issues.append("SLC full-band geometry が一致しません")
            }
        }
        if let numDIP, let pagesPerBlockNative, let sectorsPerPage, let sectorsPerFullBand,
           numDIP >= 0 {
            let firstProduct = UInt64(numDIP).multipliedReportingOverflow(by: pagesPerBlockNative)
            let secondProduct = firstProduct.partialValue.multipliedReportingOverflow(by: sectorsPerPage)
            if firstProduct.overflow || secondProduct.overflow || secondProduct.partialValue != sectorsPerFullBand {
                issues.append("native full-band geometry が一致しません")
            }
        }
        if logicalCapacityBytes > 0,
           let geometryCapacity = rawGeometryCapacityBytes,
           geometryCapacity < logicalCapacityBytes {
            issues.append("geometry容量が論理容量未満です")
        }
        if let pagesPerBlockNative, let pagesPerBlockSLC, let defaultBitsPerCell,
           pagesPerBlockSLC > 0 {
            let ratio = Double(pagesPerBlockNative) / Double(pagesPerBlockSLC)
            if abs(ratio - Double(defaultBitsPerCell)) > 0.01 {
                issues.append("native/SLC page 比率と bits-per-cell が一致しません")
            }
        }
        return issues
    }

    var geometryConfidence: GeometryConfidence {
        let geometryValues = [
            numBus != nil, diesPerBus != nil, cauPerDie != nil, numDIP != nil,
            blocksPerCAU != nil, pageSize != nil, pagesPerBlockSLC != nil,
            pagesPerBlockNative != nil, sectorsPerPage != nil,
            sectorsPerFullBandSLC != nil, sectorsPerFullBand != nil, defaultBitsPerCell != nil
        ].filter { $0 }.count
        if !geometryIssues.isEmpty { return .inconsistent }
        if geometryValues == 0 { return .unknown }
        if geometryValues < 12 { return .partial }
        return .consistent
    }

    /// Size of one geometry sector, derived from page-size / sec-per-page.
    /// This is distinct from NVMe SMART's 512,000-byte Data Unit and from
    /// the provisional 4 KiB Direct FTL counter unit.
    var geometrySectorSizeBytes: UInt64? {
        guard let pageSize, pageSize > 0,
              let sectorsPerPage, sectorsPerPage > 0,
              pageSize % sectorsPerPage == 0 else {
            return nil
        }
        let sectorSize = pageSize / sectorsPerPage
        return sectorSize > 0 ? sectorSize : nil
    }

    /// Number of physical dies represented by the allow-listed bus array.
    /// This is a topology display value, not an endurance multiplier.
    var dieCount: Int? {
        guard let diesPerBus, !diesPerBus.isEmpty, diesPerBus.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        return diesPerBus.reduce(0, +)
    }

    /// Apple’s `num-dip` is the closest available value for concurrent units.
    /// Keep the original terminology available to avoid implying a universal
    /// mapping across controller generations.
    var concurrentUnitCount: Int? {
        guard let numDIP, numDIP >= 0 else { return nil }
        return numDIP
    }

    /// Total package blocks implied by the observed topology. This is used
    /// only to explain the experimental EOL ratio shown in Advanced.
    var totalBlocks: UInt64? {
        guard let numDIP, numDIP >= 0, let blocksPerCAU else { return nil }
        let product = UInt64(numDIP).multipliedReportingOverflow(by: blocksPerCAU)
        return product.overflow ? nil : product.partialValue
    }

    /// `package_blocks_at_EOL / (num-dip × blocks-per-cau)`. The value is
    /// intentionally diagnostic: it is not used as a life or WAF multiplier.
    var eolGeometryRatio: Double? {
        guard let packageBlocksAtEOL, let totalBlocks, totalBlocks > 0,
              packageBlocksAtEOL <= totalBlocks else { return nil }
        return Double(packageBlocksAtEOL) / Double(totalBlocks)
    }

    var nativeToSLCPageRatio: Double? {
        guard let native = pagesPerBlockNative, let slc = pagesPerBlockSLC, slc > 0 else {
            return nil
        }
        return Double(native) / Double(slc)
    }

    /// A geometry-derived estimate of the NAND bytes represented by the
    /// allow-listed IORegistry properties. It is intentionally unavailable
    /// when the geometry invariants do not hold. General forecasts must not
    /// treat this as a life multiplier; the retention research estimator can
    /// use it only as a labeled, provisional capacity proxy.
    var geometryCapacityBytes: UInt64? {
        guard geometryIssues.isEmpty else { return nil }
        return rawGeometryCapacityBytes
    }

    /// The number of blocks between the observed geometry and the
    /// experimental EOL parameter. This is a design parameter, not a current
    /// spare-block count.
    var eolBlockAllowance: UInt64? {
        guard let totalBlocks, let packageBlocksAtEOL,
              packageBlocksAtEOL <= totalBlocks
        else { return nil }
        return totalBlocks - packageBlocksAtEOL
    }

    /// `eolBlockAllowance / totalBlocks`. Keep this separate from
    /// `eolGeometryRatio`, which is the package parameter divided by total
    /// geometry blocks.
    var eolAllowanceRatio: Double? {
        guard let allowance = eolBlockAllowance, let totalBlocks, totalBlocks > 0 else {
            return nil
        }
        return Double(allowance) / Double(totalBlocks)
    }

    private var rawGeometryCapacityBytes: UInt64? {
        guard let numDIP, numDIP > 0,
              let blocksPerCAU, blocksPerCAU > 0,
              let pagesPerBlockNative, pagesPerBlockNative > 0,
              let pageSize, pageSize > 0
        else { return nil }
        return product([
            UInt64(numDIP),
            blocksPerCAU,
            pagesPerBlockNative,
            pageSize
        ])
    }

    private func product(_ values: [UInt64]) -> UInt64? {
        guard !values.isEmpty, values.allSatisfy({ $0 > 0 }) else { return nil }
        var result: UInt64 = 1
        for value in values {
            let product = result.multipliedReportingOverflow(by: value)
            guard !product.overflow else { return nil }
            result = product.partialValue
        }
        return result
    }
}

enum HeadroomRating: String, Codable, Equatable, Sendable {
    case excellent
    case good
    case limited
    case critical
    case unknown

    var title: String {
        switch self {
        case .excellent: return "十分"
        case .good: return "良好"
        case .limited: return "少なめ"
        case .critical: return "不足"
        case .unknown: return "不明"
        }
    }

    var detail: String {
        switch self {
        case .excellent: return "予備領域・空き容量・損耗率から見て余裕があります"
        case .good: return "現時点では大きな懸念はありません"
        case .limited: return "空き容量または損耗率を確認してください"
        case .critical: return "Available SpareまたはMedia/Data Errorsを確認してください"
        case .unknown: return "判定に必要な値が不足しています"
        }
    }
}

/// Capacity and headroom are deliberately kept separate from the general
/// endurance forecast. Geometry is an estimate from undocumented IORegistry
/// metadata; host free space is a logical filesystem value and is never added
/// to the physical margin. The retention research estimator has a separate,
/// explicitly labeled opt-in use for a consistency-checked capacity proxy.
struct SSDCapacityProfile: Equatable, Sendable {
    let logicalCapacityBytes: UInt64?
    let filesystemTotalCapacityBytes: UInt64?
    let geometryCapacityBytes: UInt64?
    let hiddenPhysicalMarginBytes: UInt64?
    let hiddenPhysicalMarginRatio: Double?
    let totalGeometryBlocks: UInt64?
    let packageBlocksAtEOL: UInt64?
    let eolBlockAllowance: UInt64?
    let eolAllowanceRatio: Double?
    let filesystemFreeBytes: UInt64?
    let filesystemFreeRatio: Double?
    let filesystemAvailableBytes: UInt64?
    let filesystemAvailableRatio: Double?
    let availableSpare: UInt64?
    let availableSpareThreshold: UInt64?
    let percentageUsed: UInt64?
    let mediaAndDataIntegrityErrors: UInt64?
    let geometryConfidence: GeometryConfidence
    let headroomRating: HeadroomRating

    init(snapshot: DriveSnapshot, hardwareProfile: AppleNANDHardwareProfile?) {
        let profileLogicalCapacity = hardwareProfile.map(\.logicalCapacityBytes).flatMap {
            $0 > 0 ? $0 : nil
        }
        let logicalCapacity = snapshot.logicalCapacityBytes ?? profileLogicalCapacity
        let geometryCapacity = hardwareProfile?.geometryCapacityBytes
        let hiddenMargin: UInt64?
        let hiddenMarginRatio: Double?
        if let geometryCapacity, let logicalCapacity,
           geometryCapacity >= logicalCapacity,
           geometryCapacity > 0 {
            hiddenMargin = geometryCapacity - logicalCapacity
            hiddenMarginRatio = Double(hiddenMargin ?? 0) / Double(geometryCapacity)
        } else {
            hiddenMargin = nil
            hiddenMarginRatio = nil
        }

        self.logicalCapacityBytes = logicalCapacity
        self.filesystemTotalCapacityBytes = snapshot.filesystemTotalCapacityBytes
        self.geometryCapacityBytes = geometryCapacity
        self.hiddenPhysicalMarginBytes = hiddenMargin
        self.hiddenPhysicalMarginRatio = hiddenMarginRatio
        self.totalGeometryBlocks = hardwareProfile?.totalBlocks
        self.packageBlocksAtEOL = hardwareProfile?.packageBlocksAtEOL
        self.eolBlockAllowance = hardwareProfile?.eolBlockAllowance
        self.eolAllowanceRatio = hardwareProfile?.eolAllowanceRatio
        self.filesystemFreeBytes = snapshot.filesystemFreeBytes
        self.filesystemFreeRatio = snapshot.filesystemFreeRatio
        self.filesystemAvailableBytes = snapshot.filesystemAvailableBytes
        self.filesystemAvailableRatio = snapshot.filesystemAvailableRatio
        self.availableSpare = snapshot.availableSpare
        self.availableSpareThreshold = snapshot.availableSpareThreshold
        self.percentageUsed = snapshot.percentageUsed
        self.mediaAndDataIntegrityErrors = snapshot.mediaAndDataIntegrityErrors
        self.geometryConfidence = hardwareProfile?.geometryConfidence ?? .unknown
        // The rating follows the displayed free space (Finder's value), so
        // the label and the percentage beside it agree.
        self.headroomRating = Self.evaluateHeadroom(
            filesystemFreeRatio: snapshot.filesystemAvailableBytes != nil
                ? snapshot.filesystemAvailableRatio : snapshot.filesystemFreeRatio,
            availableSpare: snapshot.availableSpare,
            availableSpareThreshold: snapshot.availableSpareThreshold,
            percentageUsed: snapshot.percentageUsed,
            mediaAndDataIntegrityErrors: snapshot.mediaAndDataIntegrityErrors
        )
    }

    /// Free space as Finder shows it; older records only have the space
    /// not used by any file.
    var displayedFreeBytes: UInt64? { filesystemAvailableBytes ?? filesystemFreeBytes }
    var displayedFreeRatio: Double? { filesystemAvailableBytes != nil ? filesystemAvailableRatio : filesystemFreeRatio }

    /// Purgeable files macOS can free; they still occupy NAND.
    var purgeableBytes: UInt64? {
        guard let available = filesystemAvailableBytes, let free = filesystemFreeBytes, available >= free else {
            return nil
        }
        return available - free
    }

    var hasDisplayableValues: Bool {
        logicalCapacityBytes != nil || filesystemFreeBytes != nil ||
            geometryCapacityBytes != nil || availableSpare != nil || percentageUsed != nil
    }

    private static func evaluateHeadroom(
        filesystemFreeRatio: Double?,
        availableSpare: UInt64?,
        availableSpareThreshold: UInt64?,
        percentageUsed: UInt64?,
        mediaAndDataIntegrityErrors: UInt64?
    ) -> HeadroomRating {
        let hasInput = filesystemFreeRatio != nil || availableSpare != nil ||
            percentageUsed != nil || mediaAndDataIntegrityErrors != nil
        guard hasInput else { return .unknown }

        if let availableSpare, let availableSpareThreshold,
           availableSpare <= availableSpareThreshold {
            return .critical
        }
        if let mediaAndDataIntegrityErrors, mediaAndDataIntegrityErrors > 0 {
            return .critical
        }
        if let percentageUsed, percentageUsed >= 80 {
            return .limited
        }
        if let filesystemFreeRatio, filesystemFreeRatio < 0.15 {
            return .limited
        }
        if let availableSpare, availableSpare < 90 {
            return .good
        }
        if let filesystemFreeRatio, filesystemFreeRatio < 0.20 {
            return .good
        }
        if let availableSpare, let filesystemFreeRatio, let percentageUsed,
           availableSpare >= 95, filesystemFreeRatio >= 0.30, percentageUsed < 50 {
            return .excellent
        }
        return .good
    }
}

enum SmartctlServiceError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case noUsableDevice([String])
    case invalidJSON(String)
    case timedOut
    case outputLimitExceeded

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "smartctl が見つかりません。smartmontools を入れてください。"
        case let .noUsableDevice(messages):
            if messages.isEmpty {
                return "利用可能なストレージ候補を開けませんでした。"
            }
            return messages.joined(separator: "\n")
        case let .invalidJSON(message):
            return "smartctl の JSON を解釈できませんでした: \(message)"
        case .timedOut:
            return "smartctl の取得がタイムアウトしました"
        case .outputLimitExceeded:
            return "smartctl の出力が上限を超えたため取得を中止しました"
        }
    }
}
