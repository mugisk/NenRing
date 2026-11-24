import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private enum DirectFTLStoreResult {
    case stored
    /// Not stored for a reason that can clear by itself. Not a failed read.
    case deferred(String)
    case rejected(String)
}

private enum ASPDirectFTLCollectionError: LocalizedError {
    case unsupportedArtifact
    case missingSnapshot
    case administratorRequired
    /// The read was not stored; the reason was already worded for display.
    case notStored(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArtifact:
            return "FTL allの正規化対象ではないASP artifactでした"
        case .missingSnapshot:
            return "FTL allの取得時刻がないため、履歴へ保存できません"
        case .administratorRequired:
            return "FTL allは通常権限で取得できないため、自動取得を停止しました。手動取得では管理者認証で再試行できます"
        case let .notStored(reason):
            return reason
        }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var state: DashboardState = .idle
    @Published private(set) var snapshot: DriveSnapshot? {
        didSet { updateRealtimeIO() }
    }
    let realtimeIO: RealtimeIOMonitor

    func updateRealtimeIO() {
        realtimeIO.configure(deviceID: storageTargetResolution.recordsSMARTHistory ? snapshot?.deviceID : nil,
                             path: snapshot?.devicePath,
                             active: hasStarted && backgroundMonitoringEnabled && !isSystemSleeping)
    }
    @Published private(set) var appleStorageProfile: AppleNANDHardwareProfile?
    @Published private(set) var deviceCapabilities = StorageDeviceCapabilities.unknown
    @Published private(set) var storageTargetResolution = StorageTargetResolution.unavailable {
        didSet { updateRealtimeIO() }
    }
    @Published private(set) var history: [DriveSnapshot] = []
    /// The last 30 days (plus a day) of temperature samples, for the chart.
    /// The full history stays in `temperatureHistoryStore` alone, so the
    /// per-minute append there does not copy it; analytics read it on demand.
    private var recentTemperatures: [TemperatureSample] = []
    private var hasTemperatureHistory = false
    private var olderTemperaturePoints: [TemperaturePoint] = []
    @Published private(set) var smartHistoryDecodeDiagnostics = JSONLDecodeDiagnostics.clean
    @Published private(set) var temperatureHistoryDecodeDiagnostics = JSONLDecodeDiagnostics.clean
    @Published private(set) var asptoolSnapshots: [ASPToolDiagnosticsSnapshot] = []
    @Published private(set) var researchSessions: [ResearchSession] = []
    @Published private(set) var researchWrittenBytes: UInt64 = 0
    @Published private(set) var researchStatusMessage: String?
    @Published private(set) var attempts: [ProbeAttempt] = []
    @Published private(set) var executablePath: String?
    @Published private(set) var diagnostic: String?
    /// Errors outside SMART collection (loading or saving history, FTL,
    /// settings). A SMART failure is shown by `state` instead. Kept until
    /// the user dismisses it, so a launch-time error is not wiped by the
    /// next successful refresh.
    @Published private(set) var lastErrorMessage: String?

    func dismissLastErrorMessage() {
        lastErrorMessage = nil
    }
    /// Typed cause of the last failed SMART refresh, used for guidance.
    @Published private(set) var lastSmartctlFailure: SmartctlServiceError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isBackgroundRefreshing = false
    @Published private(set) var lastSuccessfulRefreshAt: Date?
    @Published private(set) var usageSettings = UsageSettings()
    @Published private(set) var analytics = DashboardAnalyticsSnapshot.empty

    /// Only the most recent successful IORegistry read is allowed to provide
    /// identity to a new Direct FTL capture.  `appleStorageProfile` remains
    /// last-known UI/geometry context and is intentionally not used here.
    var freshIdentityContext: CurrentDeviceContext?

    /// Context from the current identity/IORegistry read. It is captured
    /// before a detached artifact parse so Direct FTL history can be compared
    /// by device and firmware epoch instead of receiving nil metadata.
    private var currentDeviceContext: CurrentDeviceContext {
        guard let freshIdentityContext else {
            return CurrentDeviceContext(deviceID: snapshot?.deviceID, targetBinding: storageTargetResolution.binding)
        }
        return CurrentDeviceContext(
            capturedAt: freshIdentityContext.capturedAt,
            deviceID: snapshot?.deviceID ?? freshIdentityContext.deviceID,
            controllerID: freshIdentityContext.controllerID,
            firmware: freshIdentityContext.firmware,
            mspVersion: freshIdentityContext.mspVersion,
            chipID: freshIdentityContext.chipID,
            sourceBuild: freshIdentityContext.sourceBuild,
            hardwareGeneration: freshIdentityContext.hardwareGeneration,
            targetBinding: storageTargetResolution.binding
        )
    }
    @Published var selectedPeriod: HistoryPeriod = .day {
        didSet {
            guard selectedPeriod != oldValue else { return }
            Task { [weak self] in
                await self?.rebuildAnalytics()
            }
        }
    }
    @Published var backgroundMonitoringEnabled: Bool {
        didSet {
            preferences.set(backgroundMonitoringEnabled, forKey: Self.backgroundMonitoringKey)
            updateRealtimeIO()
            guard hasStarted else { return }
            if backgroundMonitoringEnabled {
                if isSystemSleeping {
                    updateSleepActivity()
                } else {
                    scheduleRefresh()
                    scheduleTemperatureRefresh()
                    scheduleIORegistryCollection()
                }
            } else {
                stopRefreshSchedule()
                stopTemperatureSchedule()
                stopIORegistrySchedule()
                stopIORegistryRetry()
                stopSleepActivity()
            }
        }
    }
    @Published var refreshInterval: RefreshInterval {
        didSet {
            preferences.set(refreshInterval.rawValue, forKey: Self.refreshIntervalKey)
            if hasStarted, backgroundMonitoringEnabled, !isSystemSleeping {
                scheduleRefresh()
            }
        }
    }
    @Published var temperatureMonitoringInterval: TemperatureMonitoringInterval {
        didSet {
            preferences.set(temperatureMonitoringInterval.rawValue, forKey: Self.temperatureMonitoringIntervalKey)
            if hasStarted, backgroundMonitoringEnabled, !isSystemSleeping {
                scheduleTemperatureRefresh()
            }
        }
    }
    @Published var ioRegistryCollectionInterval: IORegistryCollectionInterval {
        didSet {
            preferences.set(ioRegistryCollectionInterval.rawValue, forKey: Self.ioRegistryCollectionIntervalKey)
            if hasStarted, backgroundMonitoringEnabled, !isSystemSleeping {
                scheduleIORegistryCollection()
            }
        }
    }
    /// Whether Direct FTL is read automatically, in the same cycle as SMART.
    /// A failed cross-check, repeated failures or a refused read turn it off.
    @Published var aspDirectFTLAutomaticCollection: Bool {
        didSet {
            preferences.set(aspDirectFTLAutomaticCollection, forKey: Self.aspDirectFTLAutomaticCollectionKey)
            // Turning it back on is a fresh start; the old streak would stop
            // it again after a single further failure.
            if aspDirectFTLAutomaticCollection, !oldValue {
                aspDirectFTLConsecutiveFailures = 0
                preferences.set(0, forKey: Self.aspDirectFTLConsecutiveFailuresKey)
            }
        }
    }
    @Published var sleepMonitoringMode: SleepMonitoringMode {
        didSet {
            preferences.set(sleepMonitoringMode.rawValue, forKey: Self.sleepMonitoringModeKey)
            guard hasStarted, isSystemSleeping else { return }
            updateSleepActivity()
        }
    }
    @Published var menuBarShowsTemperature: Bool {
        didSet {
            preferences.set(menuBarShowsTemperature, forKey: Self.menuBarShowsTemperatureKey)
        }
    }
    @Published var menuBarShowsWear: Bool {
        didSet { preferences.set(menuBarShowsWear, forKey: Self.menuBarShowsWearKey) }
    }
    @Published var menuBarShowsRemainingYears: Bool {
        didSet { preferences.set(menuBarShowsRemainingYears, forKey: Self.menuBarShowsRemainingYearsKey) }
    }
    @Published var menuBarShowsTodayWrites: Bool {
        didSet { preferences.set(menuBarShowsTodayWrites, forKey: Self.menuBarShowsTodayWritesKey) }
    }
    /// The light check compares results already analysed; turning it on asks
    /// for notification permission and runs it once.
    @Published var reliabilityCheckSchedule: ReliabilityCheckSchedule {
        didSet {
            guard reliabilityCheckSchedule != oldValue else { return }
            preferences.set(reliabilityCheckSchedule.rawValue, forKey: Self.reliabilityCheckScheduleKey)
            guard reliabilityCheckSchedule != .off else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    self.reliabilityCheckNotificationsAllowed = try await self.reliabilityCheckNotifier.requestAuthorization()
                } catch {
                    self.lastErrorMessage = "通知の許可を確認できませんでした: \(error.localizedDescription)"
                }
                await self.runReliabilityCheckIfDue()
            }
        }
    }
    @Published private(set) var lastReliabilityCheck: ReliabilityCheckRecord?
    @Published private(set) var reliabilityCheckNotificationsAllowed: Bool?
    private let reliabilityCheckNotifier = ReliabilityCheckNotifier()

    var menuBarLabelOptions: MenuBarLabelText.Options {
        MenuBarLabelText.Options(
            temperature: menuBarShowsTemperature,
            wear: menuBarShowsWear,
            remainingYears: menuBarShowsRemainingYears,
            todayWrites: menuBarShowsTodayWrites
        )
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet {
            preferences.set(launchAtLoginEnabled, forKey: Self.launchAtLoginKey)
            guard hasStarted else { return }
            synchronizeLoginItem()
        }
    }
    @Published var dockIconVisible: Bool {
        didSet {
            preferences.set(dockIconVisible, forKey: Self.dockIconVisibleKey)
            dockVisibilityRequiresRestart = dockIconVisible != dockIconVisibleAtLaunch
        }
    }
    @Published private(set) var dockVisibilityRequiresRestart = false
    @Published var isSystemSleeping = false {
        didSet { updateRealtimeIO() }
    }
    @Published var loginItemStatus: LoginItemStatus = .unknown
    @Published var loginItemErrorMessage: String?
    @Published private(set) var isIORegistryRefreshing = false
    @Published private(set) var ioRegistryLastAttemptAt: Date?
    @Published private(set) var ioRegistryLastSuccessAt: Date?
    @Published private(set) var ioRegistryConsecutiveFailures = 0
    @Published private(set) var ioRegistryStatusMessage: String?
    @Published private(set) var isASPToolRefreshing = false
    @Published private(set) var isASPToolExtracting = false
    @Published private(set) var asptoolLastAttemptAt: Date?
    @Published private(set) var asptoolLastSuccessAt: Date?
    @Published private(set) var asptoolConsecutiveFailures = 0
    @Published private(set) var asptoolStatusMessage: String?
    @Published private(set) var asptoolLastCollectionAt: Date?
    /// Optional v0.1 compatibility path for importing an already generated log.
    @Published private(set) var asptoolSourceURL: URL?
    /// Builds and firmware on which an imported asptool log matched Direct FTL.
    /// Display only; collection and the forecast do not read it.
    @Published private(set) var asptoolVerifiedEnvironments: [ASPToolVerifiedEnvironment] = []
    /// Set while NenRing waits for a sysdiagnose started from Terminal.
    @Published private(set) var sysdiagnoseWaitStartedAt: Date?
    private var sysdiagnoseWaitTask: Task<Void, Never>?
    private var asptoolExtractionCancellation: SysdiagnoseASPToolLocator.Cancellation?
    /// The direct probe inspection remains visible in Settings. A normalized
    /// FTL `all` result is also persisted into the bounded ASP history; the
    /// older opaque snapshot/tunnel artifacts remain diagnostic-only.
    @Published private(set) var aspDirectInspection: ASPDirectArtifactInspection?
    @Published private(set) var aspDirectFTLInspection: ASPToolDirectFTLParseResult?
    @Published private(set) var aspBandStatsInspection: ASPBandStatsParseResult?
    @Published private(set) var aspDirectOpaqueInspection: ASPDirectOpaqueInspection?
    @Published private(set) var aspDirectArtifactPath: String?
    @Published private(set) var aspDirectStatusMessage: String?
    @Published var aspDirectProbeRequest: ASPDirectProbeRequest {
        didSet {
            preferences.set(aspDirectProbeRequest.rawValue, forKey: Self.aspDirectProbeRequestKey)
        }
    }
    @Published private(set) var isASPDirectGenerating = false
    @Published private(set) var aspDirectGenerationStatusMessage: String?
    @Published private(set) var isASPDirectInspecting = false
    @Published private(set) var isASPDirectFTLRefreshing = false
    @Published private(set) var aspDirectFTLLastAttemptAt: Date?
    @Published private(set) var aspDirectFTLLastSuccessAt: Date?
    @Published private(set) var aspDirectFTLConsecutiveFailures = 0
    @Published private(set) var aspDirectFTLStatusMessage: String?

    let analyzer: HistoryAnalyzer
    private let service: SmartctlService
    private let blockIOStatistics: BlockIOStatisticsProviding
    private let historyStore: HistoryStore
    private let temperatureHistoryStore: TemperatureHistoryStore
    private let asptoolSnapshotStore: ASPToolSnapshotStore
    private let reliabilityEventJournal: FTLReliabilityEventJournal
    private let researchSessionStore: ResearchSessionStore
    private let asptoolCollector: ASPToolSnapshotCollector
    private let aspDirectProbeGenerator: ASPDirectProbeGenerator
    private let usageSettingsStore: UsageSettingsStore
    let preferences: UserDefaults
    private let dockIconVisibleAtLaunch: Bool
    var refreshTimer: Timer?
    var temperatureTimer: Timer?
    var ioRegistryTimer: Timer?
    var ioRegistryRetryTimer: Timer?
    private var isTemperatureRefreshing = false
    var sleepActivity: NSBackgroundActivityScheduler?
    var sleepObserver: NSObjectProtocol?
    var wakeObserver: NSObjectProtocol?
    var hasStarted = false
    private var analyticsGeneration = 0
    private var smartHistoryLoadError: String?
    private var asptoolLoadError: String?

    private var researchWorkspaceRoot: URL {
        AppDataLocation.directoryURL
            .appendingPathComponent("research-workspaces", isDirectory: true)
    }

    private static let refreshIntervalKey = "refreshIntervalSeconds"
    private static let temperatureMonitoringIntervalKey = "temperatureMonitoringIntervalSeconds"
    private static let ioRegistryCollectionIntervalKey = "ioRegistryCollectionIntervalSeconds"
    /// Earlier builds stored a separate FTL interval; 0 meant manual only.
    private static let legacyASPDirectFTLCollectionIntervalKey = "aspDirectFTLCollectionIntervalSeconds"
    private static let aspDirectFTLAutomaticCollectionKey = "aspDirectFTLAutomaticCollection"
    private static let asptoolSourcePathKey = "asptoolSourcePath"
    private static let asptoolLastAttemptAtKey = "asptoolLastAttemptAt"
    private static let asptoolLastSuccessAtKey = "asptoolLastSuccessAt"
    private static let asptoolConsecutiveFailuresKey = "asptoolConsecutiveFailures"
    private static let asptoolLastCollectionAtKey = "asptoolLastCollectionAt"
    private static let asptoolLastSourceSignatureKey = "asptoolLastSourceSignature"
    private static let asptoolVerifiedEnvironmentsKey = "asptoolVerifiedEnvironments"
    /// The verdict last applied to the records, so a record the user deleted
    /// is not added back until another log or result is judged.
    private static let asptoolLastAppliedVerdictKey = "asptoolLastAppliedVerdict"
    /// sysdiagnose usually finishes in a few minutes; stop waiting after this.
    static let sysdiagnoseMaximumWait: TimeInterval = 30 * 60
    private static let aspDirectFTLLastAttemptAtKey = "aspDirectFTLLastAttemptAt"
    private static let aspDirectFTLLastSuccessAtKey = "aspDirectFTLLastSuccessAt"
    private static let aspDirectFTLConsecutiveFailuresKey = "aspDirectFTLConsecutiveFailures"
    private static let aspDirectFTLLocallyVerifiedMajorsKey = "aspDirectFTLLocallyVerifiedMacOSMajors"
    /// Scheduled Direct FTL collection stops after this many failures in a row.
    static let aspDirectFTLMaximumScheduledFailures = 3
    private static let ioRegistryLastAttemptAtKey = "ioRegistryLastAttemptAt"
    private static let ioRegistryLastSuccessAtKey = "ioRegistryLastSuccessAt"
    private static let ioRegistryConsecutiveFailuresKey = "ioRegistryConsecutiveFailures"
    private static let aspDirectProbeRequestKey = "aspDirectProbeRequest"
    private static let backgroundMonitoringKey = "backgroundMonitoringEnabled"
    private static let sleepMonitoringModeKey = "sleepMonitoringMode"
    private static let menuBarShowsTemperatureKey = "menuBarShowsTemperature"
    private static let menuBarShowsWearKey = "menuBarShowsWear"
    private static let menuBarShowsRemainingYearsKey = "menuBarShowsRemainingYears"
    private static let menuBarShowsTodayWritesKey = "menuBarShowsTodayWrites"
    private static let reliabilityCheckScheduleKey = "reliabilityCheckSchedule"
    private static let lastReliabilityCheckKey = "lastReliabilityCheck"
    private static let launchAtLoginKey = "launchAtLoginEnabled"
    private static let dockIconVisibleKey = "dockIconVisible"
    static let sleepActivityIdentifier = "io.github.mugisk.NenRing.sleep-monitoring"
    static let sleepActivityInterval: TimeInterval = 60 * 60
    static let sleepActivityTolerance: TimeInterval = 30 * 60
    /// A failed optional ioreg read gets one short retry. Further attempts are
    /// left to the daily timer, next launch, or next wake so a transient
    /// failure cannot turn into a frequent background probe.
    static let ioRegistryRetryDelay: TimeInterval = 15 * 60

    /// Explicit product default. Collection intervals have their own typed
    /// defaults in Models.swift; this controls whether those schedules start.
    static let defaultBackgroundMonitoringEnabled = true

    init(
        service: SmartctlService = SmartctlService(),
        historyStore: HistoryStore = HistoryStore(),
        temperatureHistoryStore: TemperatureHistoryStore = TemperatureHistoryStore(),
        asptoolSnapshotStore: ASPToolSnapshotStore = ASPToolSnapshotStore(),
        reliabilityEventJournal: FTLReliabilityEventJournal = FTLReliabilityEventJournal(),
        researchSessionStore: ResearchSessionStore = ResearchSessionStore(),
        asptoolCollector: ASPToolSnapshotCollector = ASPToolSnapshotCollector(),
        aspDirectProbeGenerator: ASPDirectProbeGenerator = ASPDirectProbeGenerator(),
        analyzer: HistoryAnalyzer = HistoryAnalyzer(),
        usageSettingsStore: UsageSettingsStore = UsageSettingsStore(),
        blockIOStatistics: BlockIOStatisticsProviding = IOKitBlockIOStatisticsProvider(),
        preferences: UserDefaults = .standard,
        initialAnalytics: DashboardAnalyticsSnapshot = .empty
    ) {
        self.service = service
        self.blockIOStatistics = blockIOStatistics
        self.historyStore = historyStore
        self.temperatureHistoryStore = temperatureHistoryStore
        self.asptoolSnapshotStore = asptoolSnapshotStore
        self.reliabilityEventJournal = reliabilityEventJournal
        self.researchSessionStore = researchSessionStore
        self.asptoolCollector = asptoolCollector
        self.aspDirectProbeGenerator = aspDirectProbeGenerator
        self.analyzer = analyzer
        self.usageSettingsStore = usageSettingsStore
        self.preferences = preferences
        DockVisibilityController.migrateToMenuBarDefaultIfNeeded(preferences: preferences)
        let savedDockIconVisible = DockVisibilityController.preferredDockVisibility(preferences: preferences)
        self.dockIconVisibleAtLaunch = savedDockIconVisible
        let savedInterval = preferences.integer(forKey: Self.refreshIntervalKey)
        self.backgroundMonitoringEnabled = preferences.object(forKey: Self.backgroundMonitoringKey) as? Bool
            ?? Self.defaultBackgroundMonitoringEnabled
        self.refreshInterval = RefreshInterval(savedSeconds: savedInterval) ?? .defaultInterval
        let savedTemperatureInterval = preferences.integer(forKey: Self.temperatureMonitoringIntervalKey)
        self.temperatureMonitoringInterval = TemperatureMonitoringInterval(rawValue: savedTemperatureInterval) ?? .oneMinute
        let savedIORegistryInterval = preferences.object(forKey: Self.ioRegistryCollectionIntervalKey) as? Int
        self.ioRegistryCollectionInterval = savedIORegistryInterval
            .flatMap(IORegistryCollectionInterval.init(savedSeconds:))
            ?? IORegistryCollectionInterval.defaultInterval
        self.aspDirectFTLAutomaticCollection = preferences.object(forKey: Self.aspDirectFTLAutomaticCollectionKey) as? Bool
            ?? (preferences.object(forKey: Self.legacyASPDirectFTLCollectionIntervalKey) as? Int).map { $0 != 0 }
            ?? true
        self.aspDirectProbeRequest = ASPDirectProbeRequest(
            rawValue: preferences.string(forKey: Self.aspDirectProbeRequestKey) ?? ""
        ) ?? .ftlAll
        self.sleepMonitoringMode = SleepMonitoringMode(
            rawValue: preferences.string(forKey: Self.sleepMonitoringModeKey) ?? ""
        ) ?? .wakeOnly
        self.menuBarShowsTemperature = preferences.object(forKey: Self.menuBarShowsTemperatureKey) as? Bool ?? false
        self.menuBarShowsWear = preferences.object(forKey: Self.menuBarShowsWearKey) as? Bool ?? false
        self.menuBarShowsRemainingYears = preferences.object(forKey: Self.menuBarShowsRemainingYearsKey) as? Bool ?? false
        self.menuBarShowsTodayWrites = preferences.object(forKey: Self.menuBarShowsTodayWritesKey) as? Bool ?? false
        self.reliabilityCheckSchedule = ReliabilityCheckSchedule(
            rawValue: preferences.string(forKey: Self.reliabilityCheckScheduleKey) ?? ""
        ) ?? .defaultSchedule
        // An unreadable record only means the next check starts a new
        // comparison; the measured history is not involved.
        self.lastReliabilityCheck = preferences.data(forKey: Self.lastReliabilityCheckKey).flatMap {
            try? Self.reliabilityCheckDecoder.decode(ReliabilityCheckRecord.self, from: $0)
        }
        self.realtimeIO = RealtimeIOMonitor(preferences: preferences)
        if let savedLaunchAtLogin = preferences.object(forKey: Self.launchAtLoginKey) as? Bool {
            self.launchAtLoginEnabled = savedLaunchAtLogin
        } else {
            let status = SMAppService.mainApp.status
            self.launchAtLoginEnabled = status == .enabled || status == .requiresApproval
        }
        self.dockIconVisible = savedDockIconVisible
        if let sourcePath = preferences.string(forKey: Self.asptoolSourcePathKey), !sourcePath.isEmpty {
            self.asptoolSourceURL = URL(fileURLWithPath: sourcePath)
        } else {
            self.asptoolSourceURL = nil
        }
        if let data = preferences.data(forKey: Self.asptoolVerifiedEnvironmentsKey),
           let records = try? JSONDecoder().decode([ASPToolVerifiedEnvironment].self, from: data) {
            self.asptoolVerifiedEnvironments = ASPToolVerifiedEnvironment.deduplicated(records)
        }
        let savedCollectionAt = preferences.double(forKey: Self.asptoolLastCollectionAtKey)
        self.asptoolLastCollectionAt = savedCollectionAt > 0 ? Date(timeIntervalSince1970: savedCollectionAt) : nil
        let savedAttemptAt = preferences.double(forKey: Self.asptoolLastAttemptAtKey)
        self.asptoolLastAttemptAt = savedAttemptAt > 0 ? Date(timeIntervalSince1970: savedAttemptAt) : nil
        let savedSuccessAt = preferences.double(forKey: Self.asptoolLastSuccessAtKey)
        let restoredSuccessAt = savedSuccessAt > 0
            ? Date(timeIntervalSince1970: savedSuccessAt)
            : self.asptoolLastCollectionAt
        self.asptoolLastSuccessAt = restoredSuccessAt
        self.asptoolConsecutiveFailures = max(
            0,
            preferences.integer(forKey: Self.asptoolConsecutiveFailuresKey)
        )
        let savedASPDirectFTLAttemptAt = preferences.double(forKey: Self.aspDirectFTLLastAttemptAtKey)
        self.aspDirectFTLLastAttemptAt = savedASPDirectFTLAttemptAt > 0
            ? Date(timeIntervalSince1970: savedASPDirectFTLAttemptAt)
            : nil
        let savedASPDirectFTLSuccessAt = preferences.double(forKey: Self.aspDirectFTLLastSuccessAtKey)
        self.aspDirectFTLLastSuccessAt = savedASPDirectFTLSuccessAt > 0
            ? Date(timeIntervalSince1970: savedASPDirectFTLSuccessAt)
            : nil
        self.aspDirectFTLConsecutiveFailures = max(
            0,
            preferences.integer(forKey: Self.aspDirectFTLConsecutiveFailuresKey)
        )
        let savedIORegistryAttemptAt = preferences.double(forKey: Self.ioRegistryLastAttemptAtKey)
        self.ioRegistryLastAttemptAt = savedIORegistryAttemptAt > 0
            ? Date(timeIntervalSince1970: savedIORegistryAttemptAt)
            : nil
        let savedIORegistrySuccessAt = preferences.double(forKey: Self.ioRegistryLastSuccessAtKey)
        self.ioRegistryLastSuccessAt = savedIORegistrySuccessAt > 0
            ? Date(timeIntervalSince1970: savedIORegistrySuccessAt)
            : nil
        self.ioRegistryConsecutiveFailures = max(
            0,
            preferences.integer(forKey: Self.ioRegistryConsecutiveFailuresKey)
        )
        self.ioRegistryStatusMessage = nil
        self.analytics = initialAnalytics
    }

    var asptoolSourceName: String {
        asptoolSourceURL?.lastPathComponent ?? "未設定"
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        updateRealtimeIO()
        refreshLoginItemStatus()
        if launchAtLoginEnabled {
            synchronizeLoginItem()
        }
        installPowerObservers()
        await reloadSMARTHistory()
        // Only bounded, already extracted diagnostics are loaded here.
        // A generated source is created later on its own slow schedule.
        await reloadASPToolSnapshots()
        do {
            // FTL snapshot times split the temperature table, so they load first.
            try await temperatureHistoryStore.prepareIntervals(boundaries: TemperatureIntervalTable.boundaries(of: asptoolSnapshots))
            _ = try await temperatureHistoryStore.olderChartPoints(deviceID: nil, before: Self.temperatureChartCutoff())
            try await reloadRecentTemperatures()
        } catch {
            lastErrorMessage = "温度履歴を読み込めませんでした: \(error.localizedDescription)"
        }
        await refreshHistoryDecodeDiagnostics()
        await restoreResearchSessions()
        await rebuildAnalytics()
        await refresh(trigger: .initial)
        if backgroundMonitoringEnabled, !isSystemSleeping {
            scheduleRefresh()
            scheduleTemperatureRefresh()
            scheduleIORegistryCollection()
        }
    }

    /// A failed read keeps what is on screen and is remembered, because the
    /// forecast must not treat an unreadable history as an empty one.
    private func reloadSMARTHistory() async {
        do {
            history = try await historyStore.records()
            smartHistoryLoadError = nil
        } catch {
            smartHistoryLoadError = error.localizedDescription
            lastErrorMessage = "履歴を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func reloadASPToolSnapshots() async {
        do {
            asptoolSnapshots = try await asptoolSnapshotStore.records()
            asptoolLoadError = nil
        } catch {
            asptoolLoadError = error.localizedDescription
            lastErrorMessage = "Controller診断スナップショットを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func refreshHistoryDecodeDiagnostics() async {
        smartHistoryDecodeDiagnostics = await historyStore.decodeDiagnostics()
        temperatureHistoryDecodeDiagnostics = await temperatureHistoryStore.decodeDiagnostics()
    }

    func refresh() async {
        await refresh(allowDuringSleep: false, trigger: .manual)
    }

    private func finishResearchSession(
        _ id: UUID,
        state: ResearchSessionState,
        reason: String?,
        writtenBytes: UInt64? = nil,
        stopReasonCode: ResearchStopReasonCode? = nil,
        partialPhase: ResearchObservationPhase? = nil,
        partialPhaseBytes: UInt64? = nil,
        workingSetBytes: UInt64? = nil,
        populationWriteBytes: UInt64? = nil,
        overwriteWriteBytes: UInt64? = nil
    ) async {
        guard var session = researchSessions.first(where: { $0.id == id }) else { return }
        session.finishedAt = Date()
        session.state = state
        session.wearAssessment = session.evaluatedWearAssessment
        session.stopReason = reason
        session.stopReasonCode = stopReasonCode
        session.availableBytesAtFinish = currentResearchAvailableBytes()
        session.partialPhase = partialPhase
        session.partialPhaseBytes = partialPhaseBytes
        if let workingSetBytes { session.workingSetBytes = workingSetBytes }
        let measuredPopulation = session.clientProxyPreparationBytes
        let measuredOverwrite = session.clientProxyOverwriteBytes
        session.populationWriteBytes = populationWriteBytes ?? (measuredPopulation > 0 ? measuredPopulation : session.populationWriteBytes)
        session.overwriteWriteBytes = overwriteWriteBytes ?? (measuredOverwrite > 0 ? measuredOverwrite : session.overwriteWriteBytes)
        if let writtenBytes { session.writtenBytes = writtenBytes }
        session.cleanupSucceeded = !FileManager.default.fileExists(
            atPath: researchWorkspaceRoot.appendingPathComponent("session-\(id.uuidString)").path
        )
        try? await researchSessionStore.upsert(session)
        researchSessions = (try? await researchSessionStore.sessions()) ?? researchSessions
        researchStatusMessage = "\(state.title) · \(ValueFormatter.bytes(Double(session.writtenBytes))) · \(reason ?? "完了")"
    }

    private func restoreResearchSessions() async {
        do {
            researchSessions = try await researchSessionStore.sessions()
        } catch {
            researchStatusMessage = "研究セッション履歴を読み込めません: \(error.localizedDescription)"
            return
        }
        for index in researchSessions.indices where researchSessions[index].state == .running {
            let id = researchSessions[index].id
            let folder = researchWorkspaceRoot.appendingPathComponent("session-\(id.uuidString)", isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                try? FileManager.default.removeItem(at: folder)
            }
            await finishResearchSession(
                id, state: .interrupted,
                reason: "前回の異常終了後に未完了ファイルを清掃",
                stopReasonCode: .appInterrupted
            )
        }
    }

    private func currentResearchAvailableBytes() -> UInt64? {
        guard let available = try? researchWorkspaceRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
              available >= 0 else { return nil }
        return UInt64(available)
    }


    func refresh(
        allowDuringSleep: Bool = false,
        trigger: RefreshTrigger
    ) async {
        guard allowDuringSleep || !isSystemSleeping else { return }
        guard !isRefreshing, !isTemperatureRefreshing else { return }
        isRefreshing = true
        isBackgroundRefreshing = trigger.isBackground
        if trigger.updatesInteractiveState {
            state = .probing
        }
        defer {
            isRefreshing = false
            isBackgroundRefreshing = false
        }

        do {
            let includeIORegistry = trigger.includesIORegistry
            if includeIORegistry {
                recordIORegistryAttempt()
            }
            let report = try await service.probe(
                includeIORegistry: includeIORegistry,
                forceIORegistryRefresh: trigger.forceIORegistryRefresh
            )
            let previousDeviceID = snapshot?.deviceID
            let deviceChanged = previousDeviceID != nil && previousDeviceID != report.snapshot.deviceID
            if deviceChanged {
                freshIdentityContext = nil
                appleStorageProfile = nil
            }

            snapshot = report.snapshot
            deviceCapabilities = report.deviceCapabilities
            let previousBinding = storageTargetResolution.binding
            storageTargetResolution = report.storageTargetResolution ?? .unavailable
            if previousBinding != storageTargetResolution.binding {
                freshIdentityContext = nil
                appleStorageProfile = nil
            }

            // A cached profile is display/geometry context, not a new identity
            // observation. Routine SMART reports can restore it after a binding
            // failure without waiting for tomorrow's IORegistry acquisition.
            if !includeIORegistry, let profile = report.appleStorageProfile {
                appleStorageProfile = profile
            }
            if includeIORegistry {
                if !report.deviceCapabilities.appleDirectFTLEligible {
                    freshIdentityContext = nil
                    appleStorageProfile = nil
                } else if let profile = report.appleStorageProfile {
                    appleStorageProfile = profile
                    freshIdentityContext = CurrentDeviceContext(
                        capturedAt: profile.capturedAt,
                        deviceID: report.snapshot.deviceID,
                        controllerID: profile.controllerClass,
                        firmware: profile.firmwareVersion ?? report.snapshot.firmware,
                        mspVersion: profile.mspVersion,
                        chipID: profile.chipID
                    )
                    recordIORegistrySuccess()
                } else {
                    freshIdentityContext = nil
                    recordIORegistryFailure("ioregの取得結果が空でした。次回の起動・復帰・日次取得で再試行します")
                    scheduleIORegistryRetryIfNeeded()
                }
            }
            if !includeIORegistry, report.deviceCapabilities.appleDirectFTLEligible,
               appleStorageProfile == nil,
               deviceChanged || previousBinding != storageTargetResolution.binding {
                // Recover missing context on the bounded retry path, including
                // a temporary target-resolution failure during a SMART poll.
                scheduleIORegistryRetryIfNeeded()
            }
            attempts = report.attempts
            executablePath = report.executablePath
            diagnostic = report.diagnostic
            lastSmartctlFailure = nil
            lastSuccessfulRefreshAt = report.snapshot.capturedAt
            usageSettings = (try? await usageSettingsStore.settings(for: report.snapshot)) ?? UsageSettings()
            // Only an ambiguous disk identity stops SMART history; an unclear
            // FTL scope withholds the FTL association but keeps SMART history.
            let identityIsUnambiguous = storageTargetResolution.recordsSMARTHistory
            if identityIsUnambiguous {
                // A failed save is reported on its own; the reading itself
                // succeeded and stays on screen.
                do {
                    _ = try await historyStore.appendIfNew(report.snapshot)
                } catch {
                    lastErrorMessage = "履歴を保存できませんでした: \(error.localizedDescription)"
                }
            } else {
                diagnostic = storageTargetResolution.reason
            }
            if identityIsUnambiguous, let temperature = report.snapshot.temperatureCelsius {
                let sample = TemperatureSample(
                    capturedAt: report.snapshot.capturedAt,
                    deviceID: report.snapshot.deviceID,
                    temperatureCelsius: temperature,
                    blockIO: blockIOStatistics.counters(devicePath: report.snapshot.devicePath)
                )
                do {
                    _ = try await temperatureHistoryStore.appendIfNew(sample)
                } catch {
                    lastErrorMessage = "温度履歴を保存できませんでした: \(error.localizedDescription)"
                }
            }
            await reloadSMARTHistory()
            try? await reloadRecentTemperatures()
            // Direct FTL is read right after SMART, which its cross-check
            // needs, and both feed one analytics rebuild.
            await collectASPDirectFTLSnapshot(force: false, rebuildsAnalytics: false)
            await rebuildAnalytics()

            switch report.snapshot.evaluation {
            case .limited:
                state = .limited
            case .normal, .warning:
                state = .ready
            }
        } catch {
            let message: String
            if let serviceError = error as? SmartctlServiceError {
                message = serviceError.localizedDescription
                lastSmartctlFailure = serviceError
            } else {
                message = error.localizedDescription
                lastSmartctlFailure = nil
            }
            if trigger.includesIORegistry {
                // The combined probe can fail before it returns its optional
                // IORegistry profile (for example when SMART collection
                // fails first). Keep this as a failed ioreg attempt rather
                // than silently losing the retry path; the retry is still
                // bounded to one attempt before the next daily/wake cycle.
                freshIdentityContext = nil
                recordIORegistryFailure("ioregを含む起動・復帰取得が完了しませんでした。15分後に1回のみ再試行し、その後は日次・復帰時に再確認します")
                scheduleIORegistryRetryIfNeeded()
            }
            // Background reads do not enter .probing, but their failures must
            // still report that the displayed snapshot is the last good one.
            state = .failed(message)
        }
    }

    func refreshTemperature() async {
        guard
            backgroundMonitoringEnabled,
            !isSystemSleeping,
            snapshot != nil,
            !isRefreshing,
            !isTemperatureRefreshing
        else { return }

        isTemperatureRefreshing = true
        defer { isTemperatureRefreshing = false }

        guard let reading = try? await service.probeTemperature() else {
            // Preserve the last known health state when only a thermal sample
            // fails. The next full probe can rediscover the device path.
            return
        }

        // Same rule as the full refresh: record only for the disk whose
        // identity is unambiguous, and only for the disk on screen.
        if storageTargetResolution.recordsSMARTHistory, reading.deviceID == snapshot?.deviceID {
            let sample = TemperatureSample(
                capturedAt: reading.capturedAt,
                deviceID: reading.deviceID,
                temperatureCelsius: reading.temperatureCelsius,
                blockIO: snapshot.map { blockIOStatistics.counters(devicePath: $0.devicePath) } ?? nil
            )
            do {
                _ = try await temperatureHistoryStore.appendIfNew(sample)
            } catch {
                lastErrorMessage = "温度履歴を保存できませんでした: \(error.localizedDescription)"
            }
        }
        let recent = try? await temperatureHistoryStore.recentRecords(since: Self.temperatureChartCutoff())
        let older = try? await temperatureHistoryStore.olderChartPoints(deviceID: snapshot?.deviceID, before: Self.temperatureChartCutoff())

        // Publish everything after the last suspension point, so one sample
        // redraws the dashboard and menu bar once rather than once per change.
        if var current = snapshot, current.deviceID == reading.deviceID {
            current.temperatureCelsius = reading.temperatureCelsius
            snapshot = current
        }
        if let recent {
            recentTemperatures = recent.records
            hasTemperatureHistory = recent.hasAny
        }
        if let older {
            olderTemperaturePoints = older
        }
        updateTemperatureChart()
    }

    /// The FTL snapshot is already stored; a failure here only means the
    /// temperature table is not updated, and the analysis then computes the
    /// newest range's event temperature from the samples in memory.
    private func addTemperatureBoundary(for snapshot: ASPToolDiagnosticsSnapshot) async {
        guard let deviceID = snapshot.deviceID else { return }
        do {
            try await temperatureHistoryStore.addIntervalBoundary(deviceID: deviceID, at: snapshot.capturedAt)
        } catch {
            lastErrorMessage = "温度の区間の表を更新できませんでした: \(error.localizedDescription)"
        }
    }

    private static func temperatureChartCutoff(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now.addingTimeInterval(-30 * 86_400))
    }

    private func reloadRecentTemperatures() async throws {
        let recent = try await temperatureHistoryStore.recentRecords(since: Self.temperatureChartCutoff())
        recentTemperatures = recent.records
        hasTemperatureHistory = recent.hasAny
        olderTemperaturePoints = try await temperatureHistoryStore.olderChartPoints(deviceID: snapshot?.deviceID, before: Self.temperatureChartCutoff())
    }

    /// Thermal polling only updates the current reading and its chart. Wear
    /// continuity, WAF, retention and journal analysis run on full input updates.
    /// The collected temperatures still participate in the next full analysis.
    private func updateTemperatureChart() {
        analytics.updateTemperatureChart(
            analyzer: analyzer, history: history,
            temperatureHistory: recentTemperatures, hasTemperatureHistory: hasTemperatureHistory,
            deviceID: snapshot?.deviceID
        )
        analytics.temperaturePoints = olderTemperaturePoints + analytics.temperaturePoints
    }

    /// A Direct FTL read is stored only when it came from the selected disk's
    /// current binding. A missing binding refuses rather than skipping the check.
    nonisolated static func readMatchesBinding(smartServiceID: UInt64?, controllerID: UInt64?,
                                               wholeMediaID: UInt64?, binding: StorageTargetBinding?) -> Bool {
        guard let binding else { return false }
        return smartServiceID == binding.smartServiceID
            && controllerID == binding.controllerEntryID
            && wholeMediaID == binding.wholeMediaID
    }

    var writePoints: [WritePoint] {
        analytics.writePoints
    }

    var temperaturePoints: [TemperaturePoint] {
        analytics.temperaturePoints
    }

    var isInteractiveRefreshing: Bool {
        isRefreshing && !isBackgroundRefreshing
    }

    var writeRateSummary: WriteRateSummary {
        analytics.writeRateSummary
    }

    /// Freshness describes the data, even when repeated failures have stopped
    /// scheduled collection or the user has selected manual collection.
    var forecastInputIsStale: Bool {
        analytics.nandEndurance.isInputStale(now: Date())
    }

    /// Direct FTL is read on the schedule only while background monitoring
    /// and automatic collection are both on.
    var automaticDirectFTLCollectionRuns: Bool {
        backgroundMonitoringEnabled && aspDirectFTLAutomaticCollection
    }

    var retentionPlanningEstimate: RetentionPlanningEstimate? {
        analytics.retentionPlanningEstimate
    }

    var lifeEstimate: LifeEstimate {
        analytics.lifeEstimate
    }

    var enduranceForecast: EnduranceForecast {
        analytics.enduranceForecast
    }

    var capacityProfile: SSDCapacityProfile? {
        guard let snapshot else { return nil }
        return SSDCapacityProfile(snapshot: snapshot, hardwareProfile: appleStorageProfile)
    }

    /// Capacity used by the compact device identity UI. Only a logical-capacity
    /// field is accepted here. Filesystem volume size and geometry-derived
    /// NAND capacity describe different things and must not be presented as
    /// the drive's logical capacity.
    var displayCapacityBytes: UInt64? {
        if let value = snapshot?.logicalCapacityBytes, value > 0 {
            return value
        }
        if let value = historicalLogicalCapacityBytes {
            return value
        }
        if let value = appleStorageProfile?.logicalCapacityBytes, value > 0 {
            return value
        }
        return nil
    }

    var displayCapacitySummary: String {
        guard let bytes = displayCapacityBytes else { return "容量未取得" }
        return ValueFormatter.decimalCapacity(bytes)
    }

    private var historicalLogicalCapacityBytes: UInt64? {
        guard let currentDeviceID = snapshot?.deviceID else { return nil }
        return history.last { item in
            item.deviceID == currentDeviceID && (item.logicalCapacityBytes ?? 0) > 0
        }?.logicalCapacityBytes
    }

    var writeBasedLifeProjection: WriteBasedLifeProjection? {
        analytics.writeBasedLifeProjection
    }

    var controllerForecast: ControllerEOLForecast {
        analytics.controllerForecast
    }

    var latestASPToolSnapshot: ASPToolDiagnosticsSnapshot? {
        let currentDeviceID = snapshot?.deviceID
        return asptoolSnapshots
            .filter { currentDeviceID == nil || $0.deviceID == nil || $0.deviceID == currentDeviceID }
            .max { $0.capturedAt < $1.capturedAt }
    }

    /// Injectable so tests can simulate other macOS builds.
    var runtimeOSBuild: () -> String? = { DiagnosticHostEnvironment.current().osBuild }

    func makeDiagnosticReport(now: Date = Date()) -> DiagnosticReport {
        DiagnosticReportBuilder.make(
            host: .current(),
            app: DiagnosticReport.App(
                version: AppVersion.shortVersion,
                build: AppVersion.buildNumber,
                sourceRevision: AppVersion.sourceRevision
            ),
            smart: snapshot,
            capabilities: deviceCapabilities,
            profile: appleStorageProfile,
            ftlSnapshots: asptoolSnapshots,
            smartHistory: history,
            locallyVerifiedMacOSMajors: aspDirectFTLLocallyVerifiedMacOSMajors,
            targetResolution: storageTargetResolution,
            asptoolVerifiedEnvironments: asptoolVerifiedEnvironments,
            now: now
        )
    }

    /// Writes a contributor diagnostic report only to a user-chosen file and
    /// returns where it was saved, or nil when the user cancelled. Nothing is
    /// uploaded; the user decides whether and where to share it.
    func saveDiagnosticReport(_ report: DiagnosticReport) throws -> URL? {
        let data = try DiagnosticReportBuilder.encode(report)
        let panel = NSSavePanel()
        panel.title = UIString.text("診断レポートを保存")
        panel.message = UIString.text("シリアル番号・デバイスパスは含みません。共有前に内容を確認してください")
        panel.prompt = UIString.text("保存")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = DiagnosticReportSharing.fileName(for: report)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Select an already generated log as a v0.1 compatibility / research
    /// import. Normal monitoring uses `asptool` generation instead.
    func chooseASPToolSource() async {
        let panel = NSOpenPanel()
        panel.title = UIString.text("asptoolログを読み込む")
        panel.message = UIString.text("自分で取得したasptool_snapshot.log、sysdiagnoseのtar.gz、または展開したフォルダを選びます。Direct FTLとの照合のみに使います")
        panel.prompt = UIString.text("選択")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SysdiagnoseASPToolLocator.defaultDirectory
        panel.allowedContentTypes = [
            UTType(filenameExtension: "log") ?? .data,
            .plainText,
            .gzip,
            .folder,
            .data
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await importASPToolSource(url)
    }

    /// Accepts the log itself, a sysdiagnose archive or an expanded sysdiagnose
    /// folder. Only `asptool_snapshot.log` is copied out of an archive.
    func importASPToolSource(_ url: URL) async {
        let logURL: URL
        do {
            if SysdiagnoseASPToolLocator.isArchive(url) {
                guard !isASPToolExtracting else { return }
                let destination = Self.asptoolImportDirectory
                let cancellation = SysdiagnoseASPToolLocator.Cancellation()
                asptoolExtractionCancellation = cancellation
                isASPToolExtracting = true
                defer {
                    isASPToolExtracting = false
                    asptoolExtractionCancellation = nil
                }
                let extraction = Task.detached(priority: .utility) {
                    try SysdiagnoseASPToolLocator.extractLog(from: url, into: destination,
                                                             cancellation: cancellation)
                }
                // Cancelling this task stops tar as well, not only the wait.
                logURL = try await withTaskCancellationHandler {
                    try await extraction.value
                } onCancel: {
                    cancellation.cancel()
                }
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let found = SysdiagnoseASPToolLocator.logInDirectory(url) else {
                    throw SysdiagnoseASPToolLocator.LocatorError.logNotFound
                }
                logURL = found
            } else {
                logURL = url
            }
        } catch {
            asptoolStatusMessage = error.localizedDescription
            lastErrorMessage = "asptoolログの解析に失敗しました: \(error.localizedDescription)"
            return
        }

        asptoolSourceURL = logURL
        preferences.set(logURL.path, forKey: Self.asptoolSourcePathKey)
        preferences.removeObject(forKey: Self.asptoolLastSourceSignatureKey)
        await importASPToolSnapshot(from: logURL, force: true)
    }

    /// Where logs copied out of a sysdiagnose archive are kept for re-analysis.
    static var asptoolImportDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.mugisk.NenRing", isDirectory: true)
            .appendingPathComponent("asptool-imports", isDirectory: true)
    }

    /// Opens Terminal with `sudo sysdiagnose`. The user authenticates there;
    /// NenRing then waits for the new archive and imports its asptool log.
    func runSysdiagnoseInTerminal() {
        let script: URL
        do {
            script = try SysdiagnoseTerminalLauncher.writeScript(
                into: Self.asptoolImportDirectory, language: UIString.selectedLanguage)
        } catch {
            asptoolStatusMessage = error.localizedDescription
            return
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: SysdiagnoseTerminalLauncher.terminalBundleIdentifier) else {
            asptoolStatusMessage = "ターミナルが見つかりません"
            return
        }
        let startedAt = Date()
        NSWorkspace.shared.open([script], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.cancelSysdiagnoseWait()
                self?.asptoolStatusMessage = error.localizedDescription
            }
        }
        waitForSysdiagnose(startedAt: startedAt)
    }

    /// Stops a running sysdiagnose extraction; tar is terminated and the
    /// partly extracted files are removed.
    func cancelASPToolExtraction() {
        asptoolExtractionCancellation?.cancel()
    }

    func cancelSysdiagnoseWait() {
        sysdiagnoseWaitTask?.cancel()
        sysdiagnoseWaitTask = nil
        sysdiagnoseWaitStartedAt = nil
    }

    /// Imports the newest finished sysdiagnose in /private/var/tmp.
    func importLatestSysdiagnose() async {
        guard !SysdiagnoseASPToolLocator.isInProgress() else {
            asptoolStatusMessage = "sysdiagnoseはまだ実行中です"
            return
        }
        guard let archive = SysdiagnoseASPToolLocator.latestArchive() else {
            asptoolStatusMessage = "/private/var/tmp にsysdiagnoseが見つかりません"
            return
        }
        await importASPToolSource(archive)
    }

    private func waitForSysdiagnose(startedAt: Date) {
        sysdiagnoseWaitTask?.cancel()
        sysdiagnoseWaitStartedAt = startedAt
        asptoolStatusMessage = "sysdiagnoseの完了を待機中…"
        sysdiagnoseWaitTask = Task { [weak self] in
            var lastSize: Int?
            while !Task.isCancelled, Date().timeIntervalSince(startedAt) < Self.sysdiagnoseMaximumWait {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                // The archive must be finished and no longer growing.
                guard !SysdiagnoseASPToolLocator.isInProgress(),
                      let archive = SysdiagnoseASPToolLocator.latestArchive(notBefore: startedAt) else {
                    lastSize = nil
                    continue
                }
                let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                guard let size, size == lastSize else {
                    lastSize = size
                    continue
                }
                guard let self else { return }
                self.sysdiagnoseWaitTask = nil
                self.sysdiagnoseWaitStartedAt = nil
                await self.importASPToolSource(archive)
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.sysdiagnoseWaitTask = nil
            self.sysdiagnoseWaitStartedAt = nil
            self.asptoolStatusMessage = "sysdiagnoseの完了を確認できませんでした。完了後に「最新のsysdiagnoseから読み込む」を押してください"
        }
    }

    func removeASPToolVerifiedEnvironment(id: ASPToolVerifiedEnvironment.ID) {
        let updated = asptoolVerifiedEnvironments.filter { $0.id != id }
        guard updated != asptoolVerifiedEnvironments else { return }
        saveASPToolVerifiedEnvironments(updated)
    }

    private func saveASPToolVerifiedEnvironments(_ records: [ASPToolVerifiedEnvironment]) {
        asptoolVerifiedEnvironments = records
        if let data = try? JSONEncoder().encode(records) {
            preferences.set(data, forKey: Self.asptoolVerifiedEnvironmentsKey)
        }
    }

    private func updateASPToolVerifiedEnvironments(with verdict: ASPToolLogVerdict?) {
        guard let verdict else { return }
        let verdictKey = verdict.recordKey
        guard preferences.string(forKey: Self.asptoolLastAppliedVerdictKey) != verdictKey else { return }
        preferences.set(verdictKey, forKey: Self.asptoolLastAppliedVerdictKey)
        let build = runtimeOSBuild()
        let version: String? = verdict.sourceBuild != nil && verdict.sourceBuild == build
            ? Self.currentMacOSVersion : nil
        let updated = ASPToolVerifiedEnvironment.applying(
            verdict, to: asptoolVerifiedEnvironments, macOSVersion: version, now: Date())
        guard updated != asptoolVerifiedEnvironments else { return }
        saveASPToolVerifiedEnvironments(updated)
    }

    private static var currentMacOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Opens one private run directory produced by an ASP probe. This remains
    /// deliberately manual; background monitoring never elevates.
    func chooseASPDirectArtifact() async {
        let panel = NSOpenPanel()
        panel.title = UIString.text("ASP直接取得の検証データを選択")
        panel.message = UIString.text("metadata.txtとprobe payload（0x16/0x91、FTL all/perm、過去に取得したtunnel 0x106/0x129/0x12b）を含むrun directoryを選択します。失敗時はmetadataのみでも確認できます")
        panel.prompt = UIString.text("検証")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await inspectASPDirectArtifact(at: url)
    }

    /// Executes the selected fixed probe from the app bundle, retains its
    /// private run directory under Application Support, and immediately sends
    /// that directory through the same parser used by the manual import path.
    /// A non-zero probe exit is still inspectable when metadata was written.
    /// Manual FTL `all` may request one administrator retry after the normal
    /// user attempt reports the known privilege/resource failure. Scheduled
    /// collection deliberately leaves that retry disabled.
    func generateASPDirectNow() async {
        guard !isASPDirectGenerating, !isASPDirectInspecting, !isASPDirectFTLRefreshing else { return }
        // The probes call private controller methods; never aim them at a
        // drive that is not Apple's internal storage.
        guard deviceCapabilities.appleDirectFTLEligible else {
            aspDirectGenerationStatusMessage = "Direct probeはApple内蔵ストレージでのみ実行します"
            aspDirectStatusMessage = aspDirectGenerationStatusMessage
            return
        }

        let request = aspDirectProbeRequest
        guard let path = snapshot?.devicePath,
              let binding = await service.resolveStorageTarget(devicePath: path).binding,
              binding == storageTargetResolution.binding else {
            aspDirectStatusMessage = "取得先の対応を再確認してください。SMART更新後に再試行できます"
            return
        }
        if request == .snapshotHeader || request == .snapshotPayload {
            guard binding.appleSMARTServiceCount == 1 else {
                aspDirectStatusMessage = "複数の取得先があるため、この研究用probeは実行しません"
                return
            }
        }
        isASPDirectGenerating = true
        aspDirectGenerationStatusMessage = "\(request.title)を生成・取得中…"
        aspDirectStatusMessage = "probe実行中…"
        defer { isASPDirectGenerating = false }

        do {
            let generator = aspDirectProbeGenerator
            let generated = try await Task.detached(priority: .utility) {
                // A manual research probe is an explicit user action, so it may
                // read an unreviewed environment; the result is labelled unverified.
                try generator.generate(
                    request: request,
                    allowAdministratorFallback: request == .ftlAll,
                    allowUnreviewedBuild: true,
                    targetBinding: binding
                )
            }.value
            aspDirectArtifactPath = generated.runDirectoryURL.standardizedFileURL.path
            let privilegeSuffix = generated.privilege == .administrator
                ? "（管理者認証）"
                : ""
            if generated.processSucceeded {
                aspDirectGenerationStatusMessage = "\(request.title)\(privilegeSuffix)の取得完了。解析中…"
            } else {
                aspDirectGenerationStatusMessage = "\(request.title)\(privilegeSuffix)は終了コード\(generated.exitStatus)。metadataを解析中…"
            }
            await inspectASPDirectArtifact(at: generated.runDirectoryURL)
            aspDirectGenerationStatusMessage = generated.processSucceeded
                ? "\(request.title)\(privilegeSuffix)の取得・解析完了"
                : "\(request.title)\(privilegeSuffix)の取得は終了コード\(generated.exitStatus)。metadata解析完了"
        } catch {
            aspDirectGenerationStatusMessage = "\(request.title)の実行に失敗しました"
            aspDirectStatusMessage = error.localizedDescription
        }
    }

    /// Re-runs the bounded parser against the current direct-probe directory
    /// without executing the private probe again.
    func analyzeCurrentASPDirectArtifact() async {
        guard !isASPDirectGenerating, !isASPDirectInspecting, !isASPDirectFTLRefreshing else { return }
        guard let path = aspDirectArtifactPath, !path.isEmpty else {
            aspDirectStatusMessage = "解析するASP probeのrun directoryがありません"
            return
        }
        await inspectASPDirectArtifact(at: URL(fileURLWithPath: path))
    }

    func inspectASPDirectArtifact(at directoryURL: URL) async {
        guard !isASPDirectInspecting, !isASPDirectFTLRefreshing else { return }
        isASPDirectInspecting = true
        aspDirectArtifactPath = directoryURL.standardizedFileURL.path
        aspDirectStatusMessage = "検証中…"
        aspDirectInspection = nil
        aspDirectFTLInspection = nil
        aspBandStatsInspection = nil
        aspDirectOpaqueInspection = nil
        defer { isASPDirectInspecting = false }

        do {
            let router = ASPDirectArtifactRouter()
            let deviceID = snapshot?.deviceID
            let deviceContext = currentDeviceContext
            let inspection = try await Task.detached(priority: .utility) {
                try router.inspect(directoryURL: directoryURL, deviceID: deviceID, deviceContext: deviceContext)
            }.value
            switch inspection {
            case let .legacy(inspection):
                aspDirectInspection = inspection
                aspDirectStatusMessage = "\(inspection.statusTitle) · \(inspection.measurement.opcode.title)"
            case let .ftl(inspection):
                aspDirectFTLInspection = inspection
                aspDirectStatusMessage = "FTL all · \(inspection.records.count) records"
                await persistDirectFTLSnapshot(inspection)
            case let .bandStats(inspection):
                aspBandStatsInspection = inspection
                aspDirectStatusMessage = "0x106 \(inspection.measurement.opcode.title) · \(inspection.bandCount) bands"
            case let .opaque(inspection):
                aspDirectOpaqueInspection = inspection
                switch inspection {
                case let .ftl(ftl):
                    aspDirectStatusMessage = "FTL \(ftl.measurement.kind.rawValue) · 形式未確認"
                case let .tunnel(tunnel):
                    if let failureResultTitle = tunnel.measurement.failureResultTitle {
                        aspDirectStatusMessage = "0x\(String(format: "%03x", tunnel.measurement.opcode.rawValue)) · \(failureResultTitle)"
                    } else {
                        aspDirectStatusMessage = "0x\(String(format: "%03x", tunnel.measurement.opcode.rawValue)) · 形式未確認"
                    }
                }
            }
        } catch {
            aspDirectInspection = nil
            aspDirectFTLInspection = nil
            aspBandStatsInspection = nil
            aspDirectOpaqueInspection = nil
            aspDirectStatusMessage = error.localizedDescription
        }
    }

    /// Stores only the normalized, timestamped FTL `all` snapshot. Failed or
    /// opaque probe families never enter the forecast history, and a parsing
    /// timestamp is never substituted for the private read timestamp.
    @discardableResult
    private func persistDirectFTLSnapshot(
        _ inspection: ASPToolDirectFTLParseResult,
        rebuildsAnalytics: Bool = true
    ) async -> DirectFTLStoreResult {
        guard deviceCapabilities.appleDirectFTLEligible else {
            let reason = "Direct FTLはApple内蔵ストレージの系列にのみ保存します"
            aspDirectStatusMessage = reason
            return .rejected(reason)
        }
        guard let snapshot = inspection.snapshot else {
            return .rejected(ASPDirectFTLCollectionError.missingSnapshot.localizedDescription)
        }
        guard Self.readMatchesBinding(smartServiceID: inspection.measurement.smartServiceEntryID,
                                      controllerID: inspection.measurement.controllerEntryID,
                                      wholeMediaID: inspection.measurement.wholeMediaEntryID,
                                      binding: storageTargetResolution.binding) else {
            guard storageTargetResolution.binding != nil else {
                let reason = "FTL取得先と選択中のディスクの対応を確認できません。保存を保留しました"
                aspDirectFTLStatusMessage = reason
                return .deferred(reason)
            }
            let reason = "FTL取得先と選択中のディスクの対応が一致しません。保存を保留しました"
            aspDirectFTLStatusMessage = reason
            return .rejected(reason)
        }
        // Host writes and changes in the POH offset provide independent checks;
        // they cannot prove the meaning of every private key. Boundary lanes
        // separately gate the forecast's current values and rate learning.
        let previous = asptoolSnapshots.filter { $0.sourceArtifact == .directFTL
            && $0.deviceID == snapshot.deviceID && $0.capturedAt < snapshot.capturedAt }
            .max { $0.capturedAt < $1.capturedAt }
        switch DirectFTLReadCrossCheck.evaluate(ftl: snapshot, smart: self.snapshot,
            previous: previous, smartHistory: history) {
        case let .failed(reason):
            revokeLocalDirectFTLVerification()
            aspDirectFTLAutomaticCollection = false
            aspDirectFTLStatusMessage = "SMARTとの照合に失敗したため保存せず、自動取得を停止しました: \(reason)"
            aspDirectStatusMessage = aspDirectFTLStatusMessage
            return .rejected(reason)
        case let .incomplete(reason):
            let message = "FTLの値が足りないため保存しませんでした: \(reason)"
            aspDirectFTLStatusMessage = message
            aspDirectStatusMessage = message
            return .rejected(message)
        case let .unavailable(reason):
            // SMART can be missing or old for a while (smartctl not answering),
            // so collection keeps its schedule, but the read is not stored.
            let message = "SMARTと照合できないため保存しませんでした: \(reason)"
            aspDirectFTLStatusMessage = message
            aspDirectStatusMessage = message
            return .deferred(message)
        case .passed:
            recordLocalDirectFTLVerificationIfNeeded()
        }
        do {
            if try await asptoolSnapshotStore.appendIfNew(snapshot) {
                await addTemperatureBoundary(for: snapshot)
            }
            await reloadASPToolSnapshots()
            if rebuildsAnalytics {
                await rebuildAnalytics()
            }
            asptoolStatusMessage = "直接取得したFTL統計をメイン表示へ反映しました"
            return .stored
        } catch {
            let message = "直接取得したFTL統計を保存できませんでした: \(error.localizedDescription)"
            lastErrorMessage = message
            return .rejected(message)
        }
    }

    func clearASPDirectInspection() {
        aspDirectInspection = nil
        aspDirectFTLInspection = nil
        aspBandStatsInspection = nil
        aspDirectOpaqueInspection = nil
        aspDirectArtifactPath = nil
        aspDirectStatusMessage = nil
        aspDirectGenerationStatusMessage = nil
    }

    /// Backward-compatible entry point for the previous manual import action.
    func importASPToolSnapshot() async {
        await chooseASPToolSource()
    }

    func clearASPToolSource() {
        asptoolSourceURL = nil
        preferences.removeObject(forKey: Self.asptoolSourcePathKey)
        preferences.removeObject(forKey: Self.asptoolLastCollectionAtKey)
        preferences.removeObject(forKey: Self.asptoolLastSourceSignatureKey)
        asptoolLastCollectionAt = nil
        asptoolLastSuccessAt = nil
    }

    func refreshIORegistryNow() async {
        await collectIORegistryProfile(force: true)
    }

    func reimportASPToolNow() async {
        guard let sourceURL = asptoolSourceURL else { return }
        await importASPToolSnapshot(from: sourceURL, force: true)
    }

    var currentEvaluation: HealthEvaluation? {
        snapshot?.evaluation
    }

    @discardableResult
    func updateUsageSettings(_ settings: UsageSettings) async -> Bool {
        guard let deviceID = snapshot?.deviceID else { return false }
        do {
            try await usageSettingsStore.save(settings, for: deviceID)
            usageSettings = settings
            await rebuildAnalytics()
            return true
        } catch {
            lastErrorMessage = "寿命予測の設定を保存できませんでした: \(error.localizedDescription)"
            return false
        }
    }

    private func rebuildAnalytics() async {
        analyticsGeneration &+= 1
        let generation = analyticsGeneration
        if let issue = smartHistoryLoadError ?? asptoolLoadError {
            // Same rule as temperature below: keep the last estimate.
            lastErrorMessage = "計測履歴を読み込めないため、寿命予測の再計算を保留しました: \(issue)"
            return
        }
        var idleCandidates: [IdleTemperatureCandidate] = []
        do { idleCandidates = try await temperatureHistoryStore.idleEvidence() }
        catch { lastErrorMessage = "アイドル温度の観測根拠を読み込めませんでした: \(error.localizedDescription)" }
        // Read on demand: holding the full history here would make every
        // per-minute append in the store copy it. Samples older than the
        // window leave memory once a day; their event temperatures come
        // from the interval table.
        do {
            try await temperatureHistoryStore.trimToWindow(now: Date())
        } catch {
            guard generation == analyticsGeneration else { return }
            lastErrorMessage = "温度履歴の整理に失敗しました: \(error.localizedDescription)"
        }
        let temperatureInput: (samples: [TemperatureSample], table: TemperatureIntervalTable?)
        do {
            temperatureInput = try await temperatureHistoryStore.analysisInput()
        } catch {
            guard generation == analyticsGeneration else { return }
            // Keep the last estimate rather than silently treating an unreadable
            // temperature history as an observation of no temperatures.
            lastErrorMessage = "温度履歴を読み込めないため、寿命予測の再計算を保留しました: \(error.localizedDescription)"
            return
        }
        let outcome = await DashboardAnalyticsCoordinator(
            analyzer: analyzer,
            reliabilityEventJournal: reliabilityEventJournal
        ).rebuild(
            history: history,
            temperatureHistory: temperatureInput.samples,
            deviceID: snapshot?.deviceID,
            period: selectedPeriod,
            profile: appleStorageProfile,
            settings: usageSettings,
            now: Date(),
            asptoolSnapshots: asptoolSnapshots,
            asptoolLogSource: SysdiagnoseASPToolLocator.sourceIdentity(forLog: asptoolSourceURL),
            researchSessions: researchSessions,
            idleTemperatureCandidates: idleCandidates,
            temperatureTable: temperatureInput.table
        )

        guard generation == analyticsGeneration else { return }
        analytics = outcome.snapshot
        // The snapshot only holds the recent temperature window. Add the older
        // points before the next await so the chart never shows it without them.
        // A thermal poll may also have completed while the full analysis was in
        // flight; never replace its newer chart with the older input snapshot.
        updateTemperatureChart()
        updateASPToolVerifiedEnvironments(with: outcome.snapshot.asptoolLogComparison.verdict)
        if let deviceID = snapshot?.deviceID,
           let idle = outcome.snapshot.nandEndurance.idleRetentionTemperature {
            // Older candidates came from the evidence store and are already
            // saved. Only recent intervals can have been newly derived.
            let recentCutoff = Date().addingTimeInterval(-30 * 86_400)
            do { try await temperatureHistoryStore.saveIdleEvidence(idle.candidates.filter { $0.end >= recentCutoff }, deviceID: deviceID) }
            catch { lastErrorMessage = "アイドル温度の観測根拠を保存できませんでした: \(error.localizedDescription)" }
        }
        guard generation == analyticsGeneration else { return }
        if let issue = outcome.journalIssues.last { lastErrorMessage = issue }

        // Persist events only after this analytics generation is confirmed to
        // still be current. Older overlapping rebuilds may finish later, but
        // must not permanently append stale evidence to the journal.
        let eventRecords = outcome.snapshot.reliabilityEventsForJournal
        if !eventRecords.isEmpty {
            do {
                _ = try await reliabilityEventJournal.appendIfNewReportingOutcome(eventRecords)
            } catch {
                lastErrorMessage = "Reliability Event Journalを保存できませんでした: \(error.localizedDescription)"
            }
        }
        guard generation == analyticsGeneration else { return }
        await runReliabilityCheckIfDue()
    }

    /// Compares the current analysis with the previous check and notifies
    /// only findings that check had not reported. Nothing is collected here.
    func runReliabilityCheckIfDue(now: Date = Date()) async {
        let latestFTL = asptoolSnapshots
            .filter { $0.sourceArtifact == .directFTL && $0.deviceID == snapshot?.deviceID }
            .map(\.capturedAt).max()
        guard ReliabilityCheck.isDue(schedule: reliabilityCheckSchedule, previous: lastReliabilityCheck,
                                     latestFTLCapturedAt: latestFTL, now: now) else { return }
        let previous = lastReliabilityCheck
        let record = ReliabilityCheck.run(
            smart: snapshot,
            events: analytics.ftlTimeSeries.reliabilityEvents,
            pace: analytics.recoveryActivityPace,
            latestFTLCapturedAt: latestFTL,
            previous: previous,
            now: now)
        lastReliabilityCheck = record
        do {
            preferences.set(try Self.reliabilityCheckEncoder.encode(record), forKey: Self.lastReliabilityCheckKey)
        } catch {
            lastErrorMessage = "簡易チェックの結果を保存できませんでした: \(error.localizedDescription)"
        }
        let fresh = ReliabilityCheck.newFindings(record, previous: previous)
        guard !fresh.isEmpty else { return }
        do {
            reliabilityCheckNotificationsAllowed = try await reliabilityCheckNotifier.post(fresh)
        } catch {
            lastErrorMessage = "簡易チェックの通知を送れませんでした: \(error.localizedDescription)"
        }
    }

    private static let reliabilityCheckEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let reliabilityCheckDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func collectIORegistryProfile(
        force: Bool
    ) async {
        guard
            backgroundMonitoringEnabled || force,
            !isSystemSleeping,
            let modelNumber = snapshot?.model,
            !isIORegistryRefreshing
        else { return }

        guard deviceCapabilities.appleDirectFTLEligible else {
            freshIdentityContext = nil
            appleStorageProfile = nil
            return
        }

        isIORegistryRefreshing = true
        defer { isIORegistryRefreshing = false }

        recordIORegistryAttempt()
        guard let path = snapshot?.devicePath,
              let binding = await service.resolveStorageTarget(devicePath: path).binding,
              binding == storageTargetResolution.binding else {
            freshIdentityContext = nil
            appleStorageProfile = nil
            recordIORegistryFailure("ioregの取得先を確認できませんでした。15分後に1回のみ再試行します")
            scheduleIORegistryRetryIfNeeded()
            return
        }
        let capturedDeviceID = snapshot?.deviceID
        let profile = await service.probeIORegistry(modelNumber: modelNumber, binding: binding)
        guard snapshot?.deviceID == capturedDeviceID,
              storageTargetResolution.binding == binding else { return }
        guard let profile else {
            // Last-known geometry remains available through
            // `appleStorageProfile`; only the fresh identity used for a new
            // Direct FTL series is invalidated.
            freshIdentityContext = nil
            recordIORegistryFailure("ioregの取得結果が空でした。15分後に1回のみ再試行し、その後は日次・復帰時に再確認します")
            scheduleIORegistryRetryIfNeeded()
            return
        }
        appleStorageProfile = profile
        freshIdentityContext = CurrentDeviceContext(
            capturedAt: profile.capturedAt,
            deviceID: snapshot?.deviceID,
            controllerID: profile.controllerClass,
            firmware: profile.firmwareVersion ?? snapshot?.firmware,
            mspVersion: profile.mspVersion,
            chipID: profile.chipID
        )
        recordIORegistrySuccess()
        await rebuildAnalytics()
    }

    /// Runs the lightweight direct FTL `all` path immediately. This is kept
    /// separate from the full asptool action so a user can verify the direct
    /// collector even when the asptool executable is unavailable.
    func refreshASPDirectFTLNow() async {
        await collectASPDirectFTLSnapshot(force: true)
    }

    @discardableResult
    private func collectASPDirectFTLSnapshot(
        force: Bool,
        rebuildsAnalytics: Bool = true
    ) async -> ASPToolDiagnosticsSnapshot? {
        guard !isSystemSleeping else { return nil }
        guard deviceCapabilities.appleDirectFTLEligible else {
            if force {
                aspDirectFTLStatusMessage = "Direct FTLはApple内蔵ストレージを確認できた場合のみ取得します"
            }
            return nil
        }
        guard !isASPDirectFTLRefreshing, !isASPDirectGenerating, !isASPDirectInspecting else { return nil }
        guard force || automaticDirectFTLCollectionRuns else {
            return nil
        }
        // Reviewed releases and macOS 14/15 compatibility trials may collect
        // automatically. Other releases require a passing local manual read.
        // Every read is cross-checked; trial eligibility does not validate keys.
        let executionReview = DirectFTLContractRegistry.executionReview(
            runtimeBuild: runtimeOSBuild(),
            locallyVerifiedMajors: aspDirectFTLLocallyVerifiedMacOSMajors
        )
        if !force, !executionReview.allowsAutomaticCollection {
            aspDirectFTLStatusMessage = "\(executionReview.detail)。設定から手動で1回取得し、SMARTと照合できれば自動取得を始めます"
            return nil
        }
        if !force,
           !Self.isDirectFTLAttemptDue(lastAttemptAt: aspDirectFTLLastAttemptAt,
                                     interval: Self.directFTLDueInterval(for: refreshInterval),
                                     now: Date()) {
            return nil
        }
        // Re-resolve the target only once a read is actually due, so an idle
        // schedule neither walks the registry nor overwrites the status text.
        guard let path = snapshot?.devicePath,
              let binding = await service.resolveStorageTarget(devicePath: path).binding,
              binding == storageTargetResolution.binding else {
            aspDirectFTLStatusMessage = "取得先の対応を再確認してください。SMART更新後に再試行できます"
            return nil
        }

        isASPDirectFTLRefreshing = true
        aspDirectFTLStatusMessage = "FTL allを定期取得中…"
        recordASPDirectFTLAttempt()
        defer { isASPDirectFTLRefreshing = false }

        let generator = aspDirectProbeGenerator
        let router = ASPDirectArtifactRouter()
        let deviceID = snapshot?.deviceID
        let deviceContext = currentDeviceContext

        do {
            let allowUnreviewedBuild = force || !executionReview.isReviewed
            let generated = try await Task.detached(priority: .utility) {
                try generator.generate(
                    request: .ftlAll,
                    allowAdministratorFallback: false,
                    allowUnreviewedBuild: allowUnreviewedBuild,
                    targetBinding: binding
                )
            }.value
            if !force,
               generated.exitStatus != 0,
               ASPDirectProbeGenerator.shouldRetryWithAdministrator(generated.execution) {
                aspDirectFTLAutomaticCollection = false
                throw ASPDirectFTLCollectionError.administratorRequired
            }
            aspDirectArtifactPath = generated.runDirectoryURL.standardizedFileURL.path

            let inspectionResult = try await Task.detached(priority: .utility) {
                try router.inspect(
                    directoryURL: generated.runDirectoryURL,
                    deviceID: deviceID,
                    deviceContext: deviceContext,
                    parsedAt: Date()
                )
            }.value
            guard case let .ftl(inspection) = inspectionResult else {
                throw ASPDirectFTLCollectionError.unsupportedArtifact
            }
            guard let normalizedSnapshot = inspection.snapshot else {
                throw ASPDirectFTLCollectionError.missingSnapshot
            }

            aspDirectFTLInspection = inspection
            aspDirectStatusMessage = "FTL all（定期取得） · \(inspection.records.count) records"
            switch await persistDirectFTLSnapshot(inspection, rebuildsAnalytics: rebuildsAnalytics) {
            case .stored:
                break
            case let .rejected(reason):
                throw ASPDirectFTLCollectionError.notStored(reason)
            case .deferred:
                // The read itself worked and retries next cycle. Leaving its
                // run directory would add one per cycle until SMART returns.
                if (try? generator.cleanup(generated)) != nil {
                    aspDirectArtifactPath = nil
                }
                return nil
            }
            recordASPDirectFTLSuccess()

            do {
                try generator.cleanup(generated)
                aspDirectArtifactPath = nil
                let review = DirectFTLContractRegistry.executionReview(
                    runtimeBuild: runtimeOSBuild(),
                    locallyVerifiedMajors: aspDirectFTLLocallyVerifiedMacOSMajors)
                let provenance = review.isReviewed ? "" : " · \(review.detail)"
                aspDirectFTLStatusMessage = "最終成功: \(ValueFormatter.shortDateTime(aspDirectFTLLastSuccessAt))\(provenance)"
            } catch {
                // A successful normalized snapshot is more important than
                // cleanup. Keep the run directory available for inspection.
                aspDirectFTLStatusMessage = "取得成功（一時データを保持）: \(error.localizedDescription)"
            }
            return normalizedSnapshot
        } catch {
            recordASPDirectFTLFailure(error)
            aspDirectFTLStatusMessage = error.localizedDescription
            aspDirectStatusMessage = "FTL allの定期取得に失敗しました: \(error.localizedDescription)"
            // Keep a failed run directory, when one exists, for manual
            // inspection from Settings. Successful runs are cleaned above.
            // A failure that repeats would otherwise retry on every tick and
            // leave a run directory each time, so stop scheduled collection.
            if !force,
               aspDirectFTLConsecutiveFailures >= Self.aspDirectFTLMaximumScheduledFailures,
               aspDirectFTLAutomaticCollection {
                aspDirectFTLAutomaticCollection = false
                aspDirectFTLStatusMessage = "\(Self.aspDirectFTLMaximumScheduledFailures)回続けて失敗したため自動取得を停止しました（設定から再開できます）: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// FTL is read in the SMART cycle once this much time has passed since
    /// the last attempt. The slack keeps timer jitter from skipping every
    /// other cycle.
    static func directFTLDueInterval(for interval: RefreshInterval) -> TimeInterval {
        interval.seconds - min(60, interval.seconds * 0.2)
    }

    /// Failed/missing-evidence reads wait for the configured interval too.
    /// Manual requests bypass this gate; saved manual-only choices stay intact.
    static func isDirectFTLAttemptDue(lastAttemptAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let lastAttemptAt else { return true }
        let elapsed = now.timeIntervalSince(lastAttemptAt)
        // A recorded attempt in the future means the clock was set back; treat
        // it as due instead of waiting until the clock catches up.
        return elapsed < 0 || elapsed >= interval
    }

    private func importASPToolSnapshot(from sourceURL: URL, force: Bool) async {
        guard deviceCapabilities.appleDirectFTLEligible else {
            if force {
                asptoolStatusMessage = "asptoolログはApple内蔵ストレージの系列にのみ関連付けます"
            }
            return
        }
        guard !isASPToolRefreshing else { return }
        isASPToolRefreshing = true
        defer { isASPToolRefreshing = false }

        recordASPToolAttempt()
        do {
            let resourceValues = try sourceURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey
            ])
            let modificationTime = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0
            let fileSize = resourceValues.fileSize ?? -1
            let signature = "\(modificationTime):\(fileSize)"
            if !force,
               preferences.string(forKey: Self.asptoolLastSourceSignatureKey) == signature {
                recordASPToolSuccess(signature: signature)
                return
            }

            let collector = asptoolCollector
            let deviceID = snapshot?.deviceID
            let importTask = Task.detached(priority: .utility) {
                try collector.collect(
                    from: sourceURL,
                    deviceID: deviceID,
                    sourceArtifact: .importedFixture
                )
            }
            let result = try await withTaskCancellationHandler {
                try await importTask.value
            } onCancel: {
                importTask.cancel()
            }
            if try await asptoolSnapshotStore.appendIfNew(result.snapshot) {
                await addTemperatureBoundary(for: result.snapshot)
            }
            await reloadASPToolSnapshots()
            recordASPToolSuccess(signature: signature)
            // A recent log is judged against a Direct read taken now, so the
            // comparison does not wait for the next scheduled read.
            if force, abs(result.snapshot.capturedAt.timeIntervalSinceNow) <= ASPToolLogVerdict.maximumSingleSideDistance {
                await collectASPDirectFTLSnapshot(force: true, rebuildsAnalytics: false)
            }
            await rebuildAnalytics()
        } catch is CancellationError {
            return
        } catch {
            recordASPToolFailure(error)
            if force {
                lastErrorMessage = "asptoolログの解析に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func recordASPToolAttempt() {
        let now = Date()
        asptoolLastAttemptAt = now
        preferences.set(now.timeIntervalSince1970, forKey: Self.asptoolLastAttemptAtKey)
    }

    private func recordASPToolSuccess(signature: String?) {
        let now = Date()
        asptoolLastSuccessAt = now
        asptoolLastCollectionAt = now
        asptoolConsecutiveFailures = 0
        asptoolStatusMessage = "最終成功: \(ValueFormatter.shortDateTime(now))"
        preferences.set(now.timeIntervalSince1970, forKey: Self.asptoolLastSuccessAtKey)
        preferences.set(now.timeIntervalSince1970, forKey: Self.asptoolLastCollectionAtKey)
        preferences.set(0, forKey: Self.asptoolConsecutiveFailuresKey)
        if let signature {
            preferences.set(signature, forKey: Self.asptoolLastSourceSignatureKey)
        } else {
            preferences.removeObject(forKey: Self.asptoolLastSourceSignatureKey)
        }
    }

    private func recordASPToolFailure(_ error: Error) {
        asptoolConsecutiveFailures += 1
        asptoolStatusMessage = error.localizedDescription
        preferences.set(asptoolConsecutiveFailures, forKey: Self.asptoolConsecutiveFailuresKey)
    }

    private func recordASPDirectFTLAttempt() {
        let now = Date()
        aspDirectFTLLastAttemptAt = now
        preferences.set(now.timeIntervalSince1970, forKey: Self.aspDirectFTLLastAttemptAtKey)
    }

    private func recordASPDirectFTLSuccess() {
        let now = Date()
        aspDirectFTLLastSuccessAt = now
        aspDirectFTLConsecutiveFailures = 0
        preferences.set(now.timeIntervalSince1970, forKey: Self.aspDirectFTLLastSuccessAtKey)
        preferences.set(0, forKey: Self.aspDirectFTLConsecutiveFailuresKey)
    }

    /// macOS major versions on which a Direct FTL read passed the SMART
    /// cross-check on this Mac. Scheduled collection is allowed on them even
    /// when the project has not reviewed the release.
    var aspDirectFTLLocallyVerifiedMacOSMajors: Set<Int> {
        Set(preferences.array(forKey: Self.aspDirectFTLLocallyVerifiedMajorsKey) as? [Int] ?? [])
    }

    func recordLocalDirectFTLVerificationIfNeeded() {
        let build = runtimeOSBuild()
        guard DirectFTLContractRegistry.descriptor(runtimeBuild: build) == nil,
              let major = DirectFTLContractRegistry.macOSMajorVersion(fromBuild: build) else { return }
        var majors = aspDirectFTLLocallyVerifiedMacOSMajors
        guard majors.insert(major).inserted else { return }
        preferences.set(majors.sorted(), forKey: Self.aspDirectFTLLocallyVerifiedMajorsKey)
        aspDirectFTLStatusMessage = "macOS \(major) でのDirect FTLの取得値がSMARTと一致しました。このMacでは自動取得を有効にします"
    }

    func revokeLocalDirectFTLVerification() {
        guard let major = DirectFTLContractRegistry.macOSMajorVersion(fromBuild: runtimeOSBuild()) else { return }
        var majors = aspDirectFTLLocallyVerifiedMacOSMajors
        guard majors.remove(major) != nil else { return }
        preferences.set(majors.sorted(), forKey: Self.aspDirectFTLLocallyVerifiedMajorsKey)
    }

    private func recordASPDirectFTLFailure(_ error: Error) {
        aspDirectFTLConsecutiveFailures += 1
        preferences.set(aspDirectFTLConsecutiveFailures, forKey: Self.aspDirectFTLConsecutiveFailuresKey)
        aspDirectFTLStatusMessage = error.localizedDescription
    }

    private func recordIORegistryAttempt() {
        let now = Date()
        ioRegistryLastAttemptAt = now
        preferences.set(now.timeIntervalSince1970, forKey: Self.ioRegistryLastAttemptAtKey)
    }

    private func recordIORegistrySuccess() {
        let now = Date()
        ioRegistryLastSuccessAt = now
        ioRegistryConsecutiveFailures = 0
        ioRegistryStatusMessage = "最終成功: \(ValueFormatter.shortDateTime(now))"
        preferences.set(now.timeIntervalSince1970, forKey: Self.ioRegistryLastSuccessAtKey)
        preferences.set(0, forKey: Self.ioRegistryConsecutiveFailuresKey)
        stopIORegistryRetry()
    }

    private func recordIORegistryFailure(_ message: String) {
        ioRegistryConsecutiveFailures += 1
        ioRegistryStatusMessage = message
        preferences.set(ioRegistryConsecutiveFailures, forKey: Self.ioRegistryConsecutiveFailuresKey)
    }

    enum RefreshTrigger {
        case initial
        case manual
        case background
        case wake
        case sleepBestEffort

        var isBackground: Bool {
            switch self {
            case .background, .sleepBestEffort: return true
            case .initial, .manual, .wake: return false
            }
        }

        var updatesInteractiveState: Bool {
            !isBackground
        }

        var includesIORegistry: Bool {
            switch self {
            case .initial, .wake: return true
            case .manual, .background, .sleepBestEffort: return false
            }
        }

        var forceIORegistryRefresh: Bool {
            switch self {
            case .initial, .wake: return true
            case .manual, .background, .sleepBestEffort: return false
            }
        }
    }

}
