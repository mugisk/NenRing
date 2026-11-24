import Foundation

struct DashboardAnalyticsRebuildOutcome: Sendable {
    let snapshot: DashboardAnalyticsSnapshot
    let journalIssues: [String]
}

/// Owns expensive history analysis and journal reads. Journal writes are
/// committed by `DashboardModel` only after it accepts the current generation.
struct DashboardAnalyticsCoordinator: Sendable {
    let analyzer: HistoryAnalyzer
    let reliabilityEventJournal: FTLReliabilityEventJournal

    func rebuild(
        history: [DriveSnapshot],
        temperatureHistory: [TemperatureSample],
        deviceID: String?,
        period: HistoryPeriod,
        profile: AppleNANDHardwareProfile?,
        settings: UsageSettings,
        now: Date,
        asptoolSnapshots: [ASPToolDiagnosticsSnapshot],
        asptoolLogSource: ASPToolLogSourceIdentity? = nil,
        researchSessions: [ResearchSession],
        idleTemperatureCandidates: [IdleTemperatureCandidate] = [],
        temperatureTable: TemperatureIntervalTable? = nil
    ) async -> DashboardAnalyticsRebuildOutcome {
        var archivedEvents: [FTLReliabilityEventRecord] = []
        var issues: [String] = []
        do {
            archivedEvents = try await reliabilityEventJournal.records(for: deviceID)
        } catch {
            issues.append("Reliability Event Journalを読み込めませんでした: \(error.localizedDescription)")
        }

        let snapshot = await Task.detached(priority: .utility) {
            DashboardAnalyticsSnapshot.build(
                analyzer: analyzer,
                history: history,
                temperatureHistory: temperatureHistory,
                deviceID: deviceID,
                period: period,
                profile: profile,
                settings: settings,
                now: now,
                asptoolSnapshots: asptoolSnapshots,
                asptoolLogSource: asptoolLogSource,
                researchSessions: researchSessions,
                archivedReliabilityEvents: archivedEvents,
                idleTemperatureCandidates: idleTemperatureCandidates,
                temperatureTable: temperatureTable
            )
        }.value

        return DashboardAnalyticsRebuildOutcome(snapshot: snapshot, journalIssues: issues)
    }
}
