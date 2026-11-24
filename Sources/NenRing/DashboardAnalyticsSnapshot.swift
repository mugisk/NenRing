import Foundation

/// Immutable derived data consumed by SwiftUI.
///
/// Building this snapshot may scan the retained history several times, so the
/// dashboard rebuilds it only when an input changes. View body evaluation then
/// performs constant-time field reads instead of re-analysing the full series.
struct DashboardAnalyticsSnapshot: Equatable, Sendable {
    static let empty = DashboardAnalyticsSnapshot(
        writePoints: [],
        temperaturePoints: [],
        writeRateSummary: WriteRateSummary(),
        retentionPlanningEstimate: nil,
        lifeEstimate: .unavailable("履歴を読み込み中"),
        enduranceForecast: EnduranceForecast(
            state: .unavailable,
            message: "履歴を読み込み中"
        ),
        writeBasedLifeProjection: nil,
        controllerForecast: ControllerEOLForecast(),
        controllerWearHistory: ControllerWearHistorySummary(
            intervalCount: 0, tlcIntervalCount: 0, slcIntervalCount: 0,
            tlcMaximumIntervalCount: 0, slcMaximumIntervalCount: 0, observationDays: 0,
            tlcPEProgress: nil, slcPEProgress: nil,
            tlcMaximumPEProgress: nil, slcMaximumPEProgress: nil,
            coupledAverageIntervalCount: 0,
            coupledTlcAveragePEProgress: nil, coupledSlcAveragePEProgress: nil,
            coupledMaximumIntervalCount: 0,
            coupledTlcMaximumPEProgress: nil, coupledSlcMaximumPEProgress: nil,
            hostUnitState: .unavailable, tlcHostBytesPerPE: nil, slcHostBytesPerPE: nil,
            tlcHostBytesPerMaximumPE: nil, slcHostBytesPerMaximumPE: nil,
            medianWAF: nil, tlcSlopeCoefficientOfVariation: nil, slcSlopeCoefficientOfVariation: nil,
            seriesIdentity: nil,
            latestInstrumentIdentity: nil,
            unavailableReason: "履歴を読み込み中", hostBytesObserved: 0, instrumentBoundaries: []
        ),
        jesdClientSimulation: .unavailable("履歴を読み込み中"),
        retentionResearchEstimate: .unavailable("履歴を読み込み中"),
        controllerInternalTelemetry: .unavailable
    )

    let writePoints: [WritePoint]
    /// The period `writePoints` was bucketed for. The snapshot is rebuilt
    /// asynchronously after the period changes, so a chart can briefly hold
    /// the old buckets. Nil when unknown.
    var writePointsPeriod: HistoryPeriod? = nil
    var temperaturePoints: [TemperaturePoint]
    let writeRateSummary: WriteRateSummary
    let retentionPlanningEstimate: RetentionPlanningEstimate?
    let lifeEstimate: LifeEstimate
    let enduranceForecast: EnduranceForecast
    let writeBasedLifeProjection: WriteBasedLifeProjection?
    let controllerForecast: ControllerEOLForecast
    let controllerWearHistory: ControllerWearHistorySummary
    let jesdClientSimulation: AppleEnduranceSimulationResult
    let retentionResearchEstimate: RetentionResearchEstimateResult
    let controllerInternalTelemetry: ControllerInternalTelemetrySummary
    var peerTBWForecast: PeerTBWForecast? = nil
    var jesdLikeProxy: JESDLikeTBWProxyResult = .empty
    var allowablePESensitivity: AllowablePESensitivityResult = .empty
    var nandEndurance: NANDEnduranceV2 = .empty
    /// Derived Direct FTL time-series analytics. Raw snapshots remain in the
    /// bounded store and this value is rebuilt only when inputs change.
    var ftlTimeSeries: FTLTimeSeriesAnalytics = .empty
    /// Unadjusted interval events. The journal alone removes already stored
    /// increments; the display's merged events must never be saved as inputs.
    var reliabilityEventsForJournal: [FTLReliabilityEventRecord] = []
    var directFTLCrossValidation: DirectFTLCrossValidation = .empty
    var asptoolLogComparison: ASPToolLogComparison = .empty
    var smartCounterInterval: SMARTCounterInterval = .empty
    /// Recent recovery activity against the drive's own longer history.
    var recoveryActivityPace: RecoveryActivityPace = .empty
    /// Lifetime write counter readings for the cumulative Writes chart, the
    /// last of each hour, so the view need not scan the full history.
    var hostWriteCounterSamples: [ReferenceCounterSample] = []
    var nandWriteCounterSamples: [ReferenceCounterSample] = []

    mutating func updateTemperatureChart(
        analyzer: HistoryAnalyzer,
        history: [DriveSnapshot],
        temperatureHistory: [TemperatureSample],
        hasTemperatureHistory: Bool? = nil,
        deviceID: String?,
        now: Date = Date()
    ) {
        // `temperatureHistory` may be only the recent window; the SMART
        // fallback applies when no temperature sample exists at all.
        temperaturePoints = !(hasTemperatureHistory ?? !temperatureHistory.isEmpty)
            ? analyzer.temperaturePoints(from: history, deviceID: deviceID, now: now)
            : analyzer.temperaturePoints(from: temperatureHistory, deviceID: deviceID, now: now)
    }

    /// `writePoints` only when they were bucketed for `period`.
    func writePoints(for period: HistoryPeriod) -> [WritePoint] {
        guard let writePointsPeriod, writePointsPeriod != period else { return writePoints }
        return []
    }

    static func build(
        analyzer: HistoryAnalyzer,
        history: [DriveSnapshot],
        temperatureHistory: [TemperatureSample] = [],
        deviceID: String?,
        period: HistoryPeriod,
        profile: AppleNANDHardwareProfile?,
        settings: UsageSettings,
        now: Date,
        asptoolSnapshots: [ASPToolDiagnosticsSnapshot] = [],
        asptoolLogSource: ASPToolLogSourceIdentity? = nil,
        researchSessions: [ResearchSession] = [],
        archivedReliabilityEvents: [FTLReliabilityEventRecord] = [],
        idleTemperatureCandidates: [IdleTemperatureCandidate] = [],
        temperatureTable: TemperatureIntervalTable? = nil
    ) -> DashboardAnalyticsSnapshot {
        // Keep this boundary defensive as well as filtering at the journal
        // reader. Callers that already have a journal dump must not be able
        // to mix reliability events from another device into this dashboard.
        let matchingArchivedReliabilityEvents = archivedReliabilityEvents.filter { record in
            guard let deviceID else { return false }
            return record.deviceID == deviceID
        }
        let matchingResearchSessions = researchSessions.filter { deviceID == nil || $0.deviceID == deviceID }
        let excludedIntervals = matchingResearchSessions.compactMap(\.analysisExcludedInterval)
        let writeBasedProjection = analyzer.writeBasedLifeProjection(
            from: history,
            deviceID: deviceID,
            settings: settings,
            researchSessions: matchingResearchSessions
        )
        let matchingHistory = history.filter { deviceID == nil || $0.deviceID == deviceID }
        let effectiveUsageStartDate = settings.manualStartDate
            ?? matchingHistory.reversed().compactMap(\.usageStartDate).first
        let rates = analyzer.writeRateSummary(
            from: history,
            deviceID: deviceID,
            excluding: excludedIntervals,
            usageStartDate: effectiveUsageStartDate
        )
        let matchingASPSnapshots = asptoolSnapshots.filter { deviceID == nil || $0.deviceID == deviceID }
        let directSnapshots = matchingASPSnapshots.filter { $0.sourceArtifact == .directFTL }
        let wearHistorySnapshots = matchingASPSnapshots.filter {
            $0.sourceArtifact.participatesInCoreWearLane && $0.captureQuality != .unknown
        }
        let latestCoreWearSnapshot = wearHistorySnapshots.max { $0.capturedAt < $1.capturedAt }
        let coreWearLane: WearContinuityLane? = latestCoreWearSnapshot.map { latest in
            WearContinuityLaneBuilder.build(
                snapshots: wearHistorySnapshots,
                smart: matchingHistory,
                latest: latest
            )
        }
        let latestLaneDirectFTL = coreWearLane?.snapshots.last(where: { $0.sourceArtifact == .directFTL })
        let latestSMART = history
            .filter { deviceID == nil || $0.deviceID == deviceID }
            .max { $0.capturedAt < $1.capturedAt }
        let controllerWearHistory = ControllerWearHistoryAnalyzer().summarize(
            snapshots: wearHistorySnapshots,
            deviceID: deviceID,
            excluding: excludedIntervals,
            smartHistory: matchingHistory,
            continuityLane: coreWearLane
        )
        let jesdLikeProxy = JESDLikeTBWProxyCalculator().estimate(JESDLikeTBWProxyInput(
            smart: latestSMART, snapshots: coreWearLane?.snapshots ?? [], sessions: matchingResearchSessions,
            wearHistory: controllerWearHistory, selection: settings.proxyWAFSelection,
            dailyRate: rates.currentWorkloadBytesPerDay,
            historicalRate: rates.forecastPaceBytesPerDay, now: now,
            customTLCPE: settings.proxyAllowableTLCPE,
            customPSLCPE: settings.proxyAllowablePSLCPE
        ))
        let aggregatedWearEvidence = ControllerWearHistoryAnalyzer().summarize(snapshots: wearHistorySnapshots,
            deviceID: deviceID, excluding: excludedIntervals, aggregateSlopes: true,
            smartHistory: matchingHistory, continuityLane: coreWearLane)
        let matchingTemperatureHistory = temperatureHistory.filter { sample in
            deviceID == nil || sample.deviceID == deviceID
        }
        // Event temperatures older than the in-memory samples come from the table.
        let rawFTLTimeSeries = FTLTimeSeriesAnalyzer(temperatureTable: temperatureTable).analyze(
            snapshots: wearHistorySnapshots,
            excluding: excludedIntervals,
            temperatureHistory: matchingTemperatureHistory,
            smartHistory: matchingHistory,
            continuityLane: coreWearLane
        )
        let ftlTimeSeries = rawFTLTimeSeries.merging(journalRecords: matchingArchivedReliabilityEvents)
        let controllerInternalTelemetry = ControllerInternalTelemetryAnalyzer().summarize(
            snapshots: directSnapshots,
            deviceID: deviceID,
            excluding: excludedIntervals,
            smartHistory: matchingHistory,
            continuityLane: coreWearLane
        )

        let nandEndurance = NANDEnduranceV2.build(smart: latestSMART, snapshots: wearHistorySnapshots,
            history: history, temperatures: temperatureHistory, settings: settings, rates: rates,
            historicalRate: rates.forecastPaceBytesPerDay, excluding: excludedIntervals, now: now,
            hardwareProfile: profile, continuityLane: coreWearLane,
            idleTemperatureCandidates: idleTemperatureCandidates, wearEvidence: aggregatedWearEvidence)
        let retentionResearchEstimate = RetentionResearchEstimator().estimate(
            latestSMART: latestSMART,
            latestDirectFTL: latestLaneDirectFTL,
            wearHistory: aggregatedWearEvidence,
            settings: settings,
            currentDailyWriteRate: rates.currentWorkloadBytesPerDay,
            historicalDailyWriteRate: rates.forecastPaceBytesPerDay,
            now: now,
            smartHistory: history,
            temperatureHistory: temperatureHistory,
            ftlHistory: wearHistorySnapshots,
            excluding: excludedIntervals,
            trials: jesdLikeProxy.trials,
            provisionalHistory: ControllerWearHistoryAnalyzer().summarize(snapshots: wearHistorySnapshots,
                deviceID: deviceID, excluding: excludedIntervals, provisional: true, aggregateSlopes: true,
                smartHistory: matchingHistory, continuityLane: coreWearLane),
            hardwareProfile: profile,
            continuityLane: coreWearLane,
            observedStorageTemperature: nandEndurance.idleRetentionTemperature
        )
        let crossValidation = DirectFTLCrossValidation.build(snapshots: directSnapshots,
            smartHistory: matchingHistory, forecast: nandEndurance, intervals: ftlTimeSeries.intervals)

        return DashboardAnalyticsSnapshot(
            writePoints: analyzer.writePoints(
                from: history,
                deviceID: deviceID,
                period: period,
                now: now
            ),
            writePointsPeriod: period,
            temperaturePoints: matchingTemperatureHistory.isEmpty
                ? analyzer.temperaturePoints(
                    from: history,
                    deviceID: deviceID,
                    now: now
                )
                : analyzer.temperaturePoints(
                    from: matchingTemperatureHistory,
                    deviceID: deviceID,
                    now: now
                ),
            writeRateSummary: rates,
            retentionPlanningEstimate: analyzer.retentionPlanningEstimate(
                from: history,
                deviceID: deviceID,
                fallbackRateBytesPerDay: writeBasedProjection?.averageDailyWriteRateBytes,
                now: now,
                excluding: excludedIntervals
            ),
            lifeEstimate: analyzer.lifeEstimate(
                from: history,
                deviceID: deviceID,
                now: now,
                excluding: excludedIntervals
            ),
            enduranceForecast: analyzer.enduranceForecast(
                from: history,
                deviceID: deviceID,
                profile: profile,
                now: now,
                excluding: excludedIntervals
            ),
            writeBasedLifeProjection: writeBasedProjection,
            controllerForecast: ControllerEOLAnalyzer().forecast(
                from: coreWearLane?.snapshots ?? [],
                deviceID: deviceID,
                now: now,
                excluding: excludedIntervals,
                continuityLane: coreWearLane
            ),
            controllerWearHistory: controllerWearHistory,
            jesdClientSimulation: AppleEnduranceSimulator().estimate(
                AppleEnduranceSimulationInput(
                    deviceID: deviceID,
                    nandVendor: profile?.nandVendor,
                    nandFamily: profile?.nandMarketingName,
                    bitsPerCell: profile?.defaultBitsPerCell,
                    controllerWear: controllerWearHistory,
                    latestFTL: latestLaneDirectFTL,
                    dailyHostWriteBytes: rates.currentWorkloadBytesPerDay,
                    currentHostWrittenBytes: latestSMART?.dataUnitsWrittenBytes,
                    retentionProfile: nil,
                    workloadProfile: nil,
                    now: now
                )
            ),
            retentionResearchEstimate: retentionResearchEstimate,
            controllerInternalTelemetry: controllerInternalTelemetry,
            peerTBWForecast: analyzer.peerTBWForecast(from: history, deviceID: deviceID,
                profile: profile, historicalRate: rates.forecastPaceBytesPerDay,
                now: now, excluding: excludedIntervals),
            jesdLikeProxy: jesdLikeProxy,
            allowablePESensitivity: jesdLikeProxy.allowablePESensitivity,
            nandEndurance: nandEndurance,
            ftlTimeSeries: ftlTimeSeries,
            reliabilityEventsForJournal: rawFTLTimeSeries.reliabilityEvents.map {
                FTLReliabilityEventRecord(event: $0, semanticContractVersion: rawFTLTimeSeries.semanticContractVersion)
            },
            directFTLCrossValidation: crossValidation,
            asptoolLogComparison: ASPToolLogComparison.build(
                snapshots: matchingASPSnapshots,
                acceptedDirectIDs: Set(coreWearLane?.snapshots.map(\.id) ?? []),
                logSource: asptoolLogSource),
            smartCounterInterval: SMARTCounterInterval.make(history: matchingHistory, deviceID: deviceID),
            recoveryActivityPace: RecoveryActivityPaceAnalyzer().assess(snapshots: directSnapshots, excluding: excludedIntervals),
            hostWriteCounterSamples: ReferenceCumulativeWriteSeries.hourlyReadings(
                matchingHistory.compactMap { snapshot in
                    snapshot.dataUnitsWrittenBytes.map { ReferenceCounterSample(at: snapshot.capturedAt, bytes: $0) }
                }),
            // The same readings the NAND total is taken from.
            nandWriteCounterSamples: ReferenceCumulativeWriteSeries.hourlyReadings(
                wearHistorySnapshots.compactMap { snapshot in
                    snapshot.nandWrittenBytes.map { ReferenceCounterSample(at: snapshot.capturedAt, bytes: $0) }
                })
        )
    }
}
