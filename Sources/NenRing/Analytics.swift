import Foundation

struct HistoryAnalyzer: Sendable {
    func peerTBWForecast(from samples: [DriveSnapshot], deviceID: String?,
                         profile: AppleNANDHardwareProfile?, historicalRate: Double?,
                         now: Date, excluding: [DateInterval] = []) -> PeerTBWForecast? {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        guard !writtenCounterWentBackwards(in: series), let latest = series.last else { return nil }
        let capacity = latest.logicalCapacityBytes ?? profile?.logicalCapacityBytes ?? 0
        return PeerTBWForecast.make(profile: profile, capacity: capacity,
            written: latest.dataUnitsWrittenBytes,
            measuredRate: writeRateSummary(from: series, deviceID: deviceID, excluding: excluding).currentWorkloadBytesPerDay,
            historicalRate: historicalRate, now: now)
    }
    static let bytesPerNVMeDataUnit = 512_000.0
    static let lifetimeWindowDays = 90.0
    static let minimumLifetimeObservationDays = 30.0
    /// Gaps longer than this are apportioned for total consistency but marked
    /// as spanning/partial because their exact per-hour placement is unknown.
    static let maximumAttributionGap: TimeInterval = 90 * 60

    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func writePoints(
        from samples: [DriveSnapshot],
        deviceID: String?,
        period: HistoryPeriod,
        now: Date = Date()
    ) -> [WritePoint] {
        let deltas = writeDeltas(from: samples, deviceID: deviceID)
        var grouped: [Date: WriteBucketAccumulator] = [:]
        for delta in deltas {
            let duration = delta.endDate.timeIntervalSince(delta.startDate)
            guard duration > 0 else { continue }
            let isSpanning = duration > Self.maximumAttributionGap
            var cursor = delta.startDate

            while cursor < delta.endDate {
                guard let interval = bucketInterval(for: cursor, period: period) else { break }
                let overlapStart = max(cursor, interval.start)
                let overlapEnd = min(delta.endDate, interval.end)
                let overlap = overlapEnd.timeIntervalSince(overlapStart)
                guard overlap > 0 else {
                    cursor = interval.end > cursor
                        ? interval.end
                        : cursor.addingTimeInterval(1)
                    continue
                }

                let fraction = min(max(overlap / duration, 0), 1)
                var accumulator = grouped[interval.start, default: WriteBucketAccumulator()]
                accumulator.bytes += delta.bytes * fraction
                accumulator.sampleCount += 1
                accumulator.containsSpanningDelta = accumulator.containsSpanningDelta || isSpanning
                // A long gap is still apportioned so that graph totals remain
                // consistent, but its interior is not treated as observed.
                if !isSpanning {
                    accumulator.observedSeconds += overlap
                }
                grouped[interval.start] = accumulator
                cursor = interval.end > cursor
                    ? interval.end
                    : cursor.addingTimeInterval(1)
            }
        }

        let points = grouped.map { bucket, value in
            let duration = bucketInterval(for: bucket, period: period)?.duration ?? 3_600
            return WritePoint(
                bucket: bucket,
                bytes: value.bytes,
                sampleCount: value.sampleCount,
                coverageFraction: value.observedSeconds / max(duration, 1),
                containsSpanningDelta: value.containsSpanningDelta
            )
        }
        let sorted = points.sorted { $0.bucket < $1.bucket }
        return sorted
    }

    /// Returns calendar-aware write-rate windows. A boundary-crossing delta is
    /// apportioned by elapsed time for rate estimation; a counter reset is
    /// never turned into a positive write. Young windows are intentionally
    /// returned as provisional estimates and carry their effective observed
    /// days in WriteRateSummary.
    func writeRateSummary(
        from samples: [DriveSnapshot],
        deviceID: String?,
        excluding: [DateInterval] = [],
        usageStartDate: Date? = nil
    ) -> WriteRateSummary {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        let latestSegment = lastContinuousSegment(from: series)
        let recordedHistoryRate = ratePerDay(in: latestSegment, windowDays: nil, excluding: excluding)
        let declaredStartDate = usageStartDate ?? series.reversed().compactMap(\.usageStartDate).first
        let lifetimeRate: RateWindowResult
        let lifetimeBasis: String?
        if let declaredStartDate,
           let reportedRate = reportedLifetimeRate(in: series, startDate: declaredStartDate) {
            lifetimeRate = reportedRate
            lifetimeBasis = usageStartDate != nil ? "使用開始設定から累積Host / 暦日" : "SMART報告の使用開始から累積Host / 暦日"
        } else {
            lifetimeRate = recordedHistoryRate
            lifetimeBasis = nil
        }
        let oneDayRate = ratePerDay(in: latestSegment, windowDays: 1, excluding: excluding)
        let sevenDayRate = ratePerDay(in: latestSegment, windowDays: 7, excluding: excluding)
        let thirtyDayRate = ratePerDay(in: latestSegment, windowDays: 30, excluding: excluding)
        let ninetyDayRate = ratePerDay(in: latestSegment, windowDays: 90, excluding: excluding)

        return WriteRateSummary(
            oneDayBytesPerDay: oneDayRate.ratePerDay,
            sevenDayBytesPerDay: sevenDayRate.ratePerDay,
            thirtyDayBytesPerDay: thirtyDayRate.ratePerDay,
            ninetyDayBytesPerDay: ninetyDayRate.ratePerDay,
            lifetimeBytesPerDay: lifetimeRate.ratePerDay,
            recordedHistoryBytesPerDay: recordedHistoryRate.ratePerDay,
            recordedHistoryObservedDays: recordedHistoryRate.observedDays,
            bytesPerPowerOnHour: powerHourRate(in: latestSegment, excluding: excluding),
            oneDayObservedDays: oneDayRate.observedDays,
            sevenDayObservedDays: sevenDayRate.observedDays,
            thirtyDayObservedDays: thirtyDayRate.observedDays,
            ninetyDayObservedDays: ninetyDayRate.observedDays,
            lifetimeObservedDays: lifetimeRate.observedDays,
            lifetimeRateBasis: lifetimeBasis,
            lifetimeStartDate: lifetimeBasis == nil ? nil : declaredStartDate
        )
    }

    /// Estimates a capacity-scaled DWPD planning envelope. This is
    /// intentionally based only on the observed host-write counter, the
    /// logical capacity, and the measured calendar write rate; Apple NAND
    /// geometry and ioreg metadata are not inputs to this estimate.
    func retentionPlanningEstimate(
        from samples: [DriveSnapshot],
        deviceID: String?,
        fallbackRateBytesPerDay: Double? = nil,
        now: Date? = nil,
        excluding: [DateInterval] = []
    ) -> RetentionPlanningEstimate? {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        guard !hasCounterReset(in: series) else { return nil }
        let latestSegment = lastContinuousSegment(from: series)
        guard let latest = latestSegment.last,
              let dataUnitsWritten = latest.dataUnitsWritten
        else { return nil }

        let rates = writeRateSummary(from: latestSegment, deviceID: latest.deviceID, excluding: excluding)
        let measuredRate = rates.currentWorkloadBytesPerDay
        let fallbackRate = fallbackRateBytesPerDay.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        guard let rate = measuredRate ?? fallbackRate else { return nil }

        guard let capacity = series.reversed().compactMap(\.logicalCapacityBytes).first,
              capacity > 0
        else { return nil }

        let currentBytes = Double(dataUnitsWritten) * Self.bytesPerNVMeDataUnit
        let capacityBytes = Double(capacity)
        let lowerDWPD = RetentionPlanningEstimate.lowerPlanningDWPD
        let upperDWPD = RetentionPlanningEstimate.upperPlanningDWPD
        let planningYears = RetentionPlanningEstimate.planningYears
        let planningDays = planningYears * RetentionPlanningEstimate.daysPerYear
        let lowerThreshold = capacityBytes * lowerDWPD * planningDays
        let upperThreshold = capacityBytes * upperDWPD * planningDays
        let remainingLower = max(0, lowerThreshold - currentBytes)
        let remainingUpper = max(remainingLower, upperThreshold - currentBytes)
        let fasterRate = max(rate * 1.25, 1)
        let slowerRate = max(rate * 0.75, 1)
        let referenceDate = now ?? latest.capturedAt

        return RetentionPlanningEstimate(
            currentHostWrittenBytes: currentBytes,
            capacityBytes: capacityBytes,
            lowerPlanningDWPD: lowerDWPD,
            upperPlanningDWPD: upperDWPD,
            planningYears: planningYears,
            thresholdLowerBytes: lowerThreshold,
            thresholdUpperBytes: upperThreshold,
            remainingLowerBytes: remainingLower,
            remainingUpperBytes: remainingUpper,
            lowerDate: referenceDate.addingTimeInterval(remainingLower / fasterRate * 86_400),
            upperDate: referenceDate.addingTimeInterval(remainingUpper / slowerRate * 86_400),
            referenceDate: referenceDate,
            rateBytesPerDay: rate,
            basis: measuredRate != nil
                ? "Logical Capacity × \(lowerDWPD)–\(upperDWPD) DWPD × \(planningYears)年 / Current workload"
                : "Logical Capacity × \(lowerDWPD)–\(upperDWPD) DWPD × \(planningYears)年 / Usage-start average"
        )
    }

    func wearTransitions(
        from samples: [DriveSnapshot],
        deviceID: String?,
        excluding: [DateInterval] = []
    ) -> [WearTransition] {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        var transitions: [WearTransition] = []
        var previousSnapshot: DriveSnapshot?
        var leftCensored = true

        for current in series {
            guard current.percentageUsed != nil, current.dataUnitsWritten != nil else {
                continue
            }

            guard let previous = previousSnapshot else {
                previousSnapshot = current
                continue
            }

            guard current.capturedAt > previous.capturedAt else {
                continue
            }

            let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
            if excluding.contains(where: { $0.intersects(interval) }) {
                previousSnapshot = current
                leftCensored = true
                continue
            }

            guard current.deviceID == previous.deviceID else {
                // A nil deviceID filter can intentionally inspect a mixed
                // history. Never turn the last sample of one drive into a
                // wear transition for another drive.
                previousSnapshot = current
                leftCensored = true
                continue
            }

            guard let previousUnits = previous.dataUnitsWritten,
                  let currentUnits = current.dataUnitsWritten,
                  let previousPercentage = previous.percentageUsed,
                  let currentPercentage = current.percentageUsed
            else {
                previousSnapshot = current
                continue
            }

            // A decrease is a new counter segment. The first transition in
            // that segment is left-censored because its plateau began before
            // the reset was observed.
            if currentUnits < previousUnits || countersWentBackwards(current, previous) ||
                currentPercentage < previousPercentage {
                previousSnapshot = current
                leftCensored = true
                continue
            }

            if currentPercentage > previousPercentage {
                transitions.append(WearTransition(
                    fromPercentage: previousPercentage,
                    toPercentage: currentPercentage,
                    previousTimestamp: previous.capturedAt,
                    detectedTimestamp: current.capturedAt,
                    previousDataUnitsWritten: previousUnits,
                    detectedDataUnitsWritten: currentUnits,
                    previousPowerOnHours: previous.powerOnHours,
                    detectedPowerOnHours: current.powerOnHours,
                    previousTemperatureCelsius: previous.temperatureCelsius,
                    detectedTemperatureCelsius: current.temperatureCelsius,
                    firmwareVersion: current.firmware,
                    isLeftCensored: leftCensored
                ))
                leftCensored = false
            }
            previousSnapshot = current
        }
        return transitions
    }

    func enduranceForecast(
        from samples: [DriveSnapshot],
        deviceID: String?,
        profile: AppleNANDHardwareProfile? = nil,
        now: Date = Date(),
        excluding: [DateInterval] = []
    ) -> EnduranceForecast {
        let fullSeries = normalizedSeries(from: samples, deviceID: deviceID)
        let series = seriesSinceLastCounterReset(fullSeries)
        guard let latest = series.last,
              let currentPercentage = latest.percentageUsed,
              let currentUnits = latest.dataUnitsWritten
        else {
            return EnduranceForecast(
                state: .unavailable,
                message: "Percentage Used と Data Units Written を取得できていません"
            )
        }

        let rates = writeRateSummary(from: series, deviceID: deviceID, excluding: excluding)
        let currentBytes = Double(currentUnits) * Self.bytesPerNVMeDataUnit
        let observedBytes = observedWriteBytes(in: lastContinuousSegment(from: series))
        let observationDays = series.first.map {
            max(0, latest.capturedAt.timeIntervalSince($0.capturedAt) / 86_400)
        } ?? 0
        let transitions = wearTransitions(from: series, deviceID: deviceID, excluding: excluding)
        // Wait for a second reading after a reset before measuring again.
        let resetDetected = series.count < fullSeries.count && series.count < 2
        // Only transitions measured after the reset remain usable then.
        let writesReset = writtenCounterWentBackwards(in: fullSeries)
        // A point update within a firmware lineage is not a new drive behaviour.
        let firmwareChanged = Set(series.compactMap { UpdateLineage.firmware($0.firmware) }).count > 1
        let identities = Set(series.map(\.deviceID))
        let serials = Set(series.compactMap(\.serialNumber))
        let stableIdentity = identities.count == 1 &&
            series.allSatisfy { $0.serialNumber != nil } && serials.count == 1

        if currentPercentage >= 100 {
            return EnduranceForecast(
                state: .reached,
                message: "推定耐久度100%に到達済み。直ちに故障を意味しません",
                currentPercentage: currentPercentage,
                currentHostWrittenBytes: currentBytes,
                estimatedEnduranceBytes: currentBytes,
                enduranceRangeLowerBytes: currentBytes,
                enduranceRangeUpperBytes: currentBytes,
                remainingHostWriteBytes: 0,
                remainingRangeLowerBytes: 0,
                remainingRangeUpperBytes: 0,
                confidence: .veryLow,
                confidenceScore: 0,
                transitionCount: transitions.count,
                observationDays: observationDays,
                writeRates: rates,
                basis: "Percentage Used ≥ 100"
            )
        }

        let counterResetForecast = {
            EnduranceForecast(
                state: .collecting,
                message: "Data Units Written または Power On Hours のリセットを検出。新しい連続履歴を収集中",
                currentPercentage: currentPercentage,
                currentHostWrittenBytes: currentBytes,
                confidence: .veryLow,
                confidenceScore: 0,
                transitionCount: transitions.count,
                observationDays: observationDays,
                writeRates: rates,
                basis: "counter reset"
            )
        }
        if resetDetected { return counterResetForecast() }

        if currentPercentage <= 1, !writesReset, transitions.filter({ !$0.isLeftCensored }).isEmpty {
            // Percentage Used moves in whole percent, so a new Mac shows no
            // measured wear for a long time. Fall back to the rated endurance
            // of retail SSDs with the same NAND so a number appears at once.
            if let reference = ReferenceTBW.resolve(
                profile: profile,
                capacityBytes: latest.logicalCapacityBytes ?? profile?.logicalCapacityBytes,
                appleInternal: profile != nil || latest.model?.uppercased().hasPrefix("APPLE SSD") == true
            ), reference.tbwBytes > currentBytes {
                // Apple SSDs: a range from the retail rating up to the tendency
                // extrapolated from one reference Mac. The single value used for
                // dates is the retail rating, the conservative end. Others:
                // 400/600 rating spread.
                var forecast = makeForecast(
                    currentPercentage: currentPercentage,
                    currentBytes: currentBytes,
                    lowerEndurance: reference.appleTendencyBytes == nil ? reference.tbwBytes * 2 / 3 : reference.tbwBytes,
                    centralEndurance: reference.tbwBytes,
                    upperEndurance: reference.appleTendencyBytes ?? reference.tbwBytes,
                    rates: rates,
                    now: latest.capturedAt,
                    observedBytes: observedBytes,
                    transitions: transitions,
                    observationDays: observationDays,
                    profile: profile,
                    firmwareChanged: firmwareChanged,
                    stableIdentity: stableIdentity,
                    basis: reference.summary
                )
                forecast.referenceTBW = reference
                return forecast
            }
            return EnduranceForecast(
                state: .collecting,
                message: "Percentage Used の変化を観測するまで推定年月を表示しません",
                currentPercentage: currentPercentage,
                currentHostWrittenBytes: currentBytes,
                confidence: .veryLow,
                confidenceScore: 0,
                transitionCount: transitions.count,
                observationDays: observationDays,
                writeRates: rates,
                basis: "PU 0–1 without observed transition"
            )
        }

        let usableTransitions = transitions.filter {
            !$0.isLeftCensored && $0.hostWrittenBytesPerPercentage != nil
        }

        if usableTransitions.count >= 2 {
            let slopes = usableTransitions.compactMap(\.hostWrittenBytesPerPercentage)
            let slope = median(slopes)
            let intercepts = usableTransitions.map { transition in
                transition.representativeHostWrittenBytes - slope * Double(transition.toPercentage)
            }
            let intercept = median(intercepts)
            let centralEndurance = max(currentBytes, intercept + slope * 100)
            let thresholdProjections = usableTransitions.map { transition in
                transition.representativeHostWrittenBytes +
                    (slope * Double(max(0, 100 - transition.toPercentage)))
            }
            let spread = max(
                max(
                    thresholdProjections.max()! - thresholdProjections.min()!,
                    mad(slopes, center: slope) * 100
                ),
                centralEndurance * (usableTransitions.count == 2 ? 0.40 : 0.25)
            )
            let lowerEndurance = max(currentBytes, centralEndurance - spread / 2)
            let upperEndurance = max(lowerEndurance, centralEndurance + spread / 2)
            let forecast = makeForecast(
                currentPercentage: currentPercentage,
                currentBytes: currentBytes,
                lowerEndurance: lowerEndurance,
                centralEndurance: centralEndurance,
                upperEndurance: upperEndurance,
                rates: rates,
                now: latest.capturedAt,
                observedBytes: observedBytes,
                transitions: transitions,
                observationDays: observationDays,
                profile: profile,
                firmwareChanged: firmwareChanged,
                stableIdentity: stableIdentity,
                basis: "\(usableTransitions.count)件の非打ち切りWearTransition（median + MAD）"
            )
            return forecast
        }

        // The fallbacks below need lifetime writes, which a reset discarded.
        if writesReset { return counterResetForecast() }

        guard currentPercentage >= 2, currentUnits > 0, stableIdentity else {
            return EnduranceForecast(
                state: .collecting,
                message: stableIdentity
                    ? "個体の損耗遷移が不足しています。履歴を収集中"
                    : "シリアル番号が無いため生涯書込量の概算を保留しています",
                currentPercentage: currentPercentage,
                currentHostWrittenBytes: currentBytes,
                confidence: .veryLow,
                confidenceScore: 0,
                transitionCount: transitions.count,
                observationDays: observationDays,
                writeRates: rates,
                basis: "insufficient transitions"
            )
        }

        // PU/100 is a deliberately low-confidence fallback. The reported PU
        // is quantized, so expose a broad interval instead of a point.
        let lowerEndurance = currentBytes * 100 / Double(currentPercentage + 1)
        let upperEndurance = currentBytes * 100 / Double(currentPercentage)
        let centralEndurance = (lowerEndurance + upperEndurance) / 2
        return makeForecast(
            currentPercentage: currentPercentage,
            currentBytes: currentBytes,
            lowerEndurance: lowerEndurance,
            centralEndurance: centralEndurance,
            upperEndurance: upperEndurance,
            rates: rates,
            now: latest.capturedAt,
            observedBytes: observedBytes,
            transitions: transitions,
            observationDays: observationDays,
            profile: profile,
            firmwareChanged: firmwareChanged,
            stableIdentity: stableIdentity,
            basis: "生涯Host Writes / Percentage Used（履歴不足の低信頼フォールバック）"
        )
    }

    func temperaturePoints(
        from samples: [DriveSnapshot],
        deviceID: String?,
        now: Date = Date()
    ) -> [TemperaturePoint] {
        let cutoff = calendar.startOfDay(for: now.addingTimeInterval(-30 * 24 * 60 * 60))
        return samples
            .filter { snapshot in
                (deviceID == nil || snapshot.deviceID == deviceID) &&
                    snapshot.temperatureCelsius != nil && snapshot.capturedAt >= cutoff
            }
            .sorted { $0.capturedAt < $1.capturedAt }
            .map { TemperaturePoint(date: $0.capturedAt, celsius: Double($0.temperatureCelsius ?? 0)) }
    }

    func temperaturePoints(
        from samples: [TemperatureSample],
        deviceID: String?,
        now: Date = Date()
    ) -> [TemperaturePoint] {
        let cutoff = calendar.startOfDay(for: now.addingTimeInterval(-30 * 24 * 60 * 60))
        // Runs every minute. Only the recent end of the history is visited.
        return Self.recentSuffix(of: samples, since: cutoff, capturedAt: \.capturedAt)
            .filter { sample in
                (deviceID == nil || sample.deviceID == deviceID) && sample.capturedAt >= cutoff
            }
            .sorted { $0.capturedAt < $1.capturedAt }
            .map { TemperaturePoint(date: $0.capturedAt, celsius: Double($0.temperatureCelsius)) }
    }

    /// The records at the end of a history from one day before `cutoff`
    /// on. Stores keep histories in capture order; a SMART reading and a
    /// thermal poll can be seconds apart in either order, so a one-day
    /// margin keeps every record at or after `cutoff`. Callers still filter
    /// by `cutoff`.
    static func recentSuffix<Record>(
        of records: [Record],
        since cutoff: Date,
        capturedAt: (Record) -> Date
    ) -> ArraySlice<Record> {
        let stop = cutoff.addingTimeInterval(-86_400)
        var index = records.endIndex
        while index > records.startIndex, capturedAt(records[records.index(before: index)]) >= stop {
            index = records.index(before: index)
        }
        return records[index...]
    }

    func rates(
        from samples: [DriveSnapshot],
        deviceID: String?,
        excluding: [DateInterval] = []
    ) -> (dailyBytes: Double?, perPowerHourBytes: Double?) {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        let writeSeries: [(Date, UInt64)] = series.compactMap { snapshot in
            guard let units = snapshot.dataUnitsWritten else { return nil }
            return (snapshot.capturedAt, units)
        }
        let powerSeries: [(Date, UInt64)] = series.compactMap { snapshot in
            guard let hours = snapshot.powerOnHours else { return nil }
            return (snapshot.capturedAt, hours)
        }
        let writeRates = positiveRates(writeSeries) { previous, current in
            Double(current - previous) * Self.bytesPerNVMeDataUnit
        }.filter { rate in
            !excluding.contains { $0.contains(rate.date) }
        }
        let powerRates = positiveRates(powerSeries) { previous, current in
            Double(current - previous)
        }

        let dailyBytes = writeRates.map { $0.ratePerDay }.nilIfEmpty.map(median)
        let bytesPerPowerHour: Double?
        if powerRates.isEmpty {
            bytesPerPowerHour = nil
        } else {
            let paired = zip(series.dropFirst(), series).compactMap { current, previous -> Double? in
                guard
                    let currentUnits = current.dataUnitsWritten,
                    let previousUnits = previous.dataUnitsWritten,
                    let currentPower = current.powerOnHours,
                    let previousPower = previous.powerOnHours,
                    current.deviceID == previous.deviceID,
                    currentUnits >= previousUnits,
                    currentPower > previousPower
                else { return nil }
                let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
                guard !excluding.contains(where: { $0.intersects(interval) }) else { return nil }
                return Double(currentUnits - previousUnits) * Self.bytesPerNVMeDataUnit /
                    Double(currentPower - previousPower)
            }
            bytesPerPowerHour = paired.nilIfEmpty.map(median)
        }
        return (dailyBytes, bytesPerPowerHour)
    }

    /// Estimates the remaining wear from the cumulative write counter and an
    /// approximate start date. This is intentionally separate from the recent
    /// Percentage Used slope: it can produce a useful long-horizon baseline
    /// even before two wear-level steps have been observed locally.
    func writeBasedLifeProjection(
        from samples: [DriveSnapshot],
        deviceID: String?,
        settings: UsageSettings = UsageSettings(),
        researchSessions: [ResearchSession] = []
    ) -> WriteBasedLifeProjection? {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        guard
            let latest = series.last,
            latest.percentageUsed != nil,
            latest.dataUnitsWritten != nil
        else { return nil }

        let usageStart: UsageStart
        let baselineUnits: UInt64

        if let manualStartDate = settings.manualStartDate, manualStartDate < latest.capturedAt {
            usageStart = UsageStart(date: manualStartDate, source: .manual)
            baselineUnits = 0
        } else if let reportedStartDate = series.reversed().compactMap(\.usageStartDate).first,
                  reportedStartDate < latest.capturedAt {
            usageStart = UsageStart(date: reportedStartDate, source: .reported)
            baselineUnits = 0
        } else if let powerOnHours = latest.powerOnHours, powerOnHours > 0 {
            let inferredDays = Double(powerOnHours) / 24
            let inferredDate = latest.capturedAt.addingTimeInterval(-inferredDays * 86_400)
            guard inferredDate > Date(timeIntervalSince1970: 0), inferredDate < latest.capturedAt else {
                return firstObservationProjectionStart(in: series, latest: latest, researchSessions: researchSessions)
            }
            usageStart = UsageStart(date: inferredDate, source: .powerOnHours)
            baselineUnits = 0
        } else if let first = series.first,
                  let firstUnits = first.dataUnitsWritten,
                  first.capturedAt < latest.capturedAt {
            usageStart = UsageStart(date: first.capturedAt, source: .firstObservation)
            baselineUnits = firstUnits
        } else {
            return nil
        }

        return makeWriteBasedProjection(
            latest: latest,
            usageStart: usageStart,
            baselineUnits: baselineUnits,
            researchSessions: researchSessions
        )
    }

    func lifeEstimate(
        from samples: [DriveSnapshot],
        deviceID: String?,
        now: Date = Date(),
        excluding: [DateInterval] = []
    ) -> LifeEstimate {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        guard let latest = series.last, let latestPercentage = latest.percentageUsed else {
            return .unavailable("Percentage Used が取得できていません")
        }

        let writeRates = writeRateSummary(from: series, deviceID: deviceID, excluding: excluding)
        let dailyBytes = writeRates.currentWorkloadBytesPerDay
        let powerHourBytes = writeRates.bytesPerPowerOnHour
        if latestPercentage >= 100 {
            return .reached(remainingPercent: 0)
        }

        let percentageSeries = series.filter { $0.percentageUsed != nil }
        guard let first = percentageSeries.first else {
            return .unavailable("Percentage Used の履歴がありません")
        }
        let observationDays = max(0, latest.capturedAt.timeIntervalSince(first.capturedAt) / 86_400)
        let percentageRates = positivePercentageRates(percentageSeries, excluding: excluding)
        let distinctLevels = Set(percentageSeries.compactMap(\.percentageUsed)).count

        guard observationDays >= Self.minimumLifetimeObservationDays else {
            return .collecting(
                "少なくとも30日分の変化を観測します（現在 \(Int(observationDays.rounded(.down)))日）",
                dailyWriteRateBytes: dailyBytes,
                writePerPowerHourBytes: powerHourBytes
            )
        }
        guard distinctLevels >= 2, !percentageRates.isEmpty else {
            return .collecting(
                "Percentage Used の階段変化を2段以上観測するまで推定しません",
                dailyWriteRateBytes: dailyBytes,
                writePerPowerHourBytes: powerHourBytes
            )
        }
        guard dailyBytes != nil, powerHourBytes != nil else {
            return .collecting(
                "書き込み量と稼働時間の履歴が揃うまで推定しません",
                dailyWriteRateBytes: dailyBytes,
                writePerPowerHourBytes: powerHourBytes
            )
        }

        let positiveRates = percentageRates.map(\.ratePerDay)
        guard let slowest = positiveRates.min(), let fastest = positiveRates.max(), slowest > 0 else {
            return .collecting(
                "Percentage Used の変化率を計算できません",
                dailyWriteRateBytes: dailyBytes,
                writePerPowerHourBytes: powerHourBytes
            )
        }

        let remainingPercent = max(0, 100 - Double(latestPercentage))
        // Even a stable observed slope is not a promise about future workload.
        // Add a modest uncertainty band instead of presenting identical dates.
        let slopeSpread = fastest / slowest
        let conservativeFastest = slopeSpread < 1.15 ? fastest * 1.25 : fastest
        let conservativeSlowest = slopeSpread < 1.15 ? slowest * 0.75 : slowest
        let lowerDays = max(1, remainingPercent / conservativeFastest)
        let upperDays = max(lowerDays * 1.05, remainingPercent / conservativeSlowest)
        let lowerDate = latest.capturedAt.addingTimeInterval(lowerDays * 86_400)
        let upperDate = latest.capturedAt.addingTimeInterval(upperDays * 86_400)
        let confidence: LifeEstimate.Confidence = percentageRates.count >= 3 && observationDays >= 60
            ? .medium
            : .low

        return .estimated(
            lowerDate: lowerDate,
            upperDate: upperDate,
            confidence: confidence,
            remainingPercent: remainingPercent,
            dailyWriteRateBytes: dailyBytes,
            writePerPowerHourBytes: powerHourBytes
        )
    }

    private func firstObservationProjectionStart(
        in series: [DriveSnapshot],
        latest: DriveSnapshot,
        researchSessions: [ResearchSession]
    ) -> WriteBasedLifeProjection? {
        guard let first = series.first,
              let firstUnits = first.dataUnitsWritten,
              first.capturedAt < latest.capturedAt
        else { return nil }

        return makeWriteBasedProjection(
            latest: latest,
            usageStart: UsageStart(date: first.capturedAt, source: .firstObservation),
            baselineUnits: firstUnits,
            researchSessions: researchSessions
        )
    }

    private func makeWriteBasedProjection(
        latest: DriveSnapshot,
        usageStart: UsageStart,
        baselineUnits: UInt64,
        researchSessions: [ResearchSession]
    ) -> WriteBasedLifeProjection? {
        guard
            let percentage = latest.percentageUsed,
            let latestUnits = latest.dataUnitsWritten,
            usageStart.date < latest.capturedAt,
            latestUnits >= baselineUnits
        else { return nil }

        let elapsedDays = latest.capturedAt.timeIntervalSince(usageStart.date) / 86_400
        guard elapsedDays >= 1 else { return nil }

        let usedPercent = min(100.0, Double(percentage))
        guard usedPercent > 0 else { return nil }

        let observedWrittenBytes = Double(latestUnits - baselineUnits) * Self.bytesPerNVMeDataUnit
        let coveredSessions = researchSessions.filter {
            $0.deviceID == latest.deviceID && $0.startedAt >= usageStart.date && $0.startedAt <= latest.capturedAt
        }
        guard coveredSessions.allSatisfy({
            $0.writtenBytes == 0 || $0.observedSmartHostWriteDeltaBytes != nil
        }) else { return nil }
        let excludedSeconds = coveredSessions.reduce(0.0) { result, session in
            let end = min(session.finishedAt ?? latest.capturedAt, latest.capturedAt)
            let start = max(session.startedAt, usageStart.date)
            return result + max(0, end.timeIntervalSince(start))
        }
        let researchWrittenBytes = coveredSessions.compactMap(\.observedSmartHostWriteDeltaBytes).reduce(0, +)
        let workloadDays = elapsedDays - excludedSeconds / 86_400
        let workloadWrittenBytes = max(0, observedWrittenBytes - researchWrittenBytes)
        guard workloadDays >= 1 else { return nil }
        let averageDailyWriteRateBytes = workloadWrittenBytes / workloadDays
        guard observedWrittenBytes > 0, averageDailyWriteRateBytes.isFinite, averageDailyWriteRateBytes > 0 else {
            return nil
        }

        let estimatedTotalLifetimeBytes = observedWrittenBytes / (usedPercent / 100.0)
        let remainingPercent = max(0, 100 - usedPercent)
        let remainingBytes = max(0, estimatedTotalLifetimeBytes - observedWrittenBytes)
        let lowerDate: Date
        let upperDate: Date
        if remainingBytes == 0 {
            lowerDate = latest.capturedAt
            upperDate = latest.capturedAt
        } else {
            let fasterRate = averageDailyWriteRateBytes * 1.25
            let slowerRate = averageDailyWriteRateBytes * 0.75
            lowerDate = latest.capturedAt.addingTimeInterval(
                max(1, remainingBytes / fasterRate) * 86_400
            )
            upperDate = latest.capturedAt.addingTimeInterval(
                max(1, remainingBytes / slowerRate) * 86_400
            )
        }

        return WriteBasedLifeProjection(
            usageStart: usageStart,
            elapsedDays: elapsedDays,
            observedWrittenBytes: observedWrittenBytes,
            averageDailyWriteRateBytes: averageDailyWriteRateBytes,
            estimatedTotalLifetimeBytes: estimatedTotalLifetimeBytes,
            remainingBytes: remainingBytes,
            remainingPercent: remainingPercent,
            lowerDate: lowerDate,
            upperDate: upperDate,
            confidence: elapsedDays >= 180 ? .medium : .low
        )
    }

    private func makeForecast(
        currentPercentage: UInt64,
        currentBytes: Double,
        lowerEndurance: Double,
        centralEndurance: Double,
        upperEndurance: Double,
        rates: WriteRateSummary,
        now: Date,
        observedBytes: Double,
        transitions: [WearTransition],
        observationDays: Double,
        profile: AppleNANDHardwareProfile?,
        firmwareChanged: Bool,
        stableIdentity: Bool,
        basis: String
    ) -> EnduranceForecast {
        let safeLowerEndurance = max(currentBytes, lowerEndurance)
        let safeCentralEndurance = max(currentBytes, centralEndurance)
        let safeUpperEndurance = max(safeLowerEndurance, upperEndurance)
        let remaining = max(0, safeCentralEndurance - currentBytes)
        let remainingLower = max(0, safeLowerEndurance - currentBytes)
        let remainingUpper = max(remainingLower, safeUpperEndurance - currentBytes)

        func projectionDates(rate: Double?) -> (lower: Date?, upper: Date?) {
            guard let rate, rate.isFinite, rate > 0 else { return (nil, nil) }
            let fasterRate = max(rate * 1.25, 1)
            let slowerRate = max(rate * 0.75, 1)
            return (
                now.addingTimeInterval(remainingLower / fasterRate * 86_400),
                now.addingTimeInterval(remainingUpper / slowerRate * 86_400)
            )
        }

        let currentProjection = projectionDates(rate: rates.currentWorkloadBytesPerDay)
        let typicalProjection = projectionDates(rate: rates.typicalWorkloadBytesPerDay)
        let lowerDate = currentProjection.lower ?? typicalProjection.lower
        let upperDate = currentProjection.upper ?? typicalProjection.upper

        var score = 0
        let usableTransitionCount = transitions.count(where: { !$0.isLeftCensored })
        if usableTransitionCount >= 5 {
            score += 40
        } else if usableTransitionCount >= 2 {
            score += 20
        }
        if observationDays >= 90 { score += 15 }
        if observedBytes >= 10e12 {
            score += 10
        }
        // Hardware metadata is never allowed to raise confidence. An
        // inconsistent profile may lower it because it invalidates a useful
        // diagnostic context, but a matching profile is not proof of life.
        if profile?.geometryConfidence == .inconsistent { score -= 10 }
        if !firmwareChanged, transitions.contains(where: { $0.firmwareVersion != nil }) { score += 5 }
        if firmwareChanged { score -= 20 }
        if !stableIdentity { score -= 20 }

        let slopes = transitions.compactMap(\.hostWrittenBytesPerPercentage)
        if slopes.count >= 3 {
            let slopeMedian = median(slopes)
            if slopeMedian > 0, mad(slopes, center: slopeMedian) / slopeMedian > 0.25 {
                score -= 10
            }
        }
        score = min(max(score, 0), 100)

        let confidence: ForecastConfidence
        switch score {
        case 85...: confidence = .veryHigh
        case 70..<85: confidence = .high
        case 50..<70: confidence = .medium
        case 30..<50: confidence = .low
        default: confidence = .veryLow
        }

        var message = "現在の書き込み傾向が続く場合の推定耐久度100%到達"
        if lowerDate == nil {
            message += "（書込ペースがまだ不足しているため年月は未算出）"
        }
        return EnduranceForecast(
            state: .estimated,
            message: message,
            currentPercentage: currentPercentage,
            currentHostWrittenBytes: currentBytes,
            estimatedEnduranceBytes: safeCentralEndurance,
            enduranceRangeLowerBytes: safeLowerEndurance,
            enduranceRangeUpperBytes: safeUpperEndurance,
            remainingHostWriteBytes: remaining,
            remainingRangeLowerBytes: remainingLower,
            remainingRangeUpperBytes: remainingUpper,
            lowerDate: lowerDate,
            upperDate: upperDate,
            currentWorkloadLowerDate: currentProjection.lower,
            currentWorkloadUpperDate: currentProjection.upper,
            typicalWorkloadLowerDate: typicalProjection.lower,
            typicalWorkloadUpperDate: typicalProjection.upper,
            confidence: confidence,
            confidenceScore: score,
            transitionCount: usableTransitionCount,
            observationDays: observationDays,
            writeRates: rates,
            basis: basis
        )
    }

    private func writeDeltas(from samples: [DriveSnapshot], deviceID: String?) -> [WriteDelta] {
        let series = normalizedSeries(from: samples, deviceID: deviceID)
        return zip(series.dropFirst(), series).compactMap { current, previous in
            guard
                current.deviceID == previous.deviceID,
                let currentUnits = current.dataUnitsWritten,
                let previousUnits = previous.dataUnitsWritten,
                currentUnits >= previousUnits,
                current.capturedAt > previous.capturedAt
            else { return nil }
            let delta = Double(currentUnits - previousUnits) * Self.bytesPerNVMeDataUnit
            guard delta > 0 else { return nil }
            return WriteDelta(startDate: previous.capturedAt, endDate: current.capturedAt, bytes: delta)
        }
    }

    private func normalizedSeries(from samples: [DriveSnapshot], deviceID: String?) -> [DriveSnapshot] {
        let sorted = samples
            .filter { deviceID == nil || $0.deviceID == deviceID }
            .sorted { $0.capturedAt < $1.capturedAt }
        var result: [DriveSnapshot] = []
        for snapshot in sorted {
            if let last = result.last, last.capturedAt == snapshot.capturedAt {
                // HistoryStore already suppresses close duplicates. This also
                // keeps hand-written/imported history from splitting a model.
                if last.deviceID == snapshot.deviceID {
                    result[result.count - 1] = snapshot
                } else {
                    result.append(snapshot)
                }
            } else {
                result.append(snapshot)
            }
        }
        // A single read below its neighbours, followed by values that carry
        // on from before it, is a misread rather than a reset. Kept, it would
        // split the series and count the rebound as a burst of writes.
        return result.indices.compactMap { index in
            guard index > 0, index < result.count - 1 else { return result[index] }
            let previous = result[index - 1], current = result[index], next = result[index + 1]
            let isolatedMisread = previous.deviceID == current.deviceID && next.deviceID == current.deviceID &&
                countersWentBackwards(current, previous) && !countersWentBackwards(next, previous)
            return isolatedMisread ? nil : current
        }
    }

    private func bucketInterval(for date: Date, period: HistoryPeriod) -> DateInterval? {
        switch period {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)
        case .day:
            return calendar.dateInterval(of: .day, for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)
        }
    }

    private func lastContinuousSegment(from series: [DriveSnapshot]) -> [DriveSnapshot] {
        var segment: [DriveSnapshot] = []
        for snapshot in series {
            guard let previous = segment.last else {
                segment = [snapshot]
                continue
            }
            if snapshot.deviceID != previous.deviceID ||
                snapshot.capturedAt <= previous.capturedAt ||
                countersWentBackwards(snapshot, previous) {
                segment = [snapshot]
            } else {
                segment.append(snapshot)
            }
        }
        return segment
    }

    /// The readings after the last time a counter went backwards. Forecasts
    /// start again from there instead of staying unavailable for good.
    private func seriesSinceLastCounterReset(_ series: [DriveSnapshot]) -> [DriveSnapshot] {
        guard let index = series.indices.dropFirst().last(where: { index in
            let current = series[index], previous = series[index - 1]
            return current.deviceID == previous.deviceID &&
                current.capturedAt > previous.capturedAt && countersWentBackwards(current, previous)
        }) else { return series }
        return Array(series[index...])
    }

    /// Data Units Written going backwards means it no longer holds lifetime
    /// writes. Power-on hours stepping back alone leaves it intact.
    private func writtenCounterWentBackwards(in series: [DriveSnapshot]) -> Bool {
        zip(series.dropFirst(), series).contains { current, previous in
            guard current.deviceID == previous.deviceID, current.capturedAt > previous.capturedAt,
                  let now = current.dataUnitsWritten, let before = previous.dataUnitsWritten else { return false }
            return now < before
        }
    }

    private func hasCounterReset(in series: [DriveSnapshot]) -> Bool {
        zip(series.dropFirst(), series).contains { current, previous in
            current.deviceID == previous.deviceID &&
                current.capturedAt > previous.capturedAt && countersWentBackwards(current, previous)
        }
    }

    private func countersWentBackwards(_ current: DriveSnapshot, _ previous: DriveSnapshot) -> Bool {
        (current.dataUnitsWritten != nil && previous.dataUnitsWritten != nil &&
            current.dataUnitsWritten! < previous.dataUnitsWritten!) ||
            (current.powerOnHours != nil && previous.powerOnHours != nil &&
                current.powerOnHours! < previous.powerOnHours!)
    }

    private struct RateWindowResult {
        let ratePerDay: Double?
        let observedDays: Double?
    }

    /// Uses the cumulative SMART Host Writes counter with a declared device
    /// start date.  This is deliberately separate from the latest continuous
    /// observation segment: a short recent history must not masquerade as the
    /// device's lifetime anchor after a compaction or firmware boundary.
    private func reportedLifetimeRate(
        in series: [DriveSnapshot],
        startDate: Date
    ) -> RateWindowResult? {
        guard !hasCounterReset(in: series),
              let latest = series.last,
              let units = latest.dataUnitsWritten,
              startDate < latest.capturedAt else { return nil }
        let elapsedDays = latest.capturedAt.timeIntervalSince(startDate) / 86_400
        guard elapsedDays.isFinite, elapsedDays > 0 else { return nil }
        let bytes = Double(units) * Self.bytesPerNVMeDataUnit
        let rate = bytes / elapsedDays
        guard bytes.isFinite, rate.isFinite, rate > 0 else { return nil }
        return RateWindowResult(ratePerDay: rate, observedDays: elapsedDays)
    }

    private func ratePerDay(
        in series: [DriveSnapshot],
        windowDays: Double?,
        excluding: [DateInterval]
    ) -> RateWindowResult {
        guard let latest = series.last else { return RateWindowResult(ratePerDay: nil, observedDays: nil) }
        let boundary = windowDays.map { latest.capturedAt.addingTimeInterval(-$0 * 86_400) }
        let firstDate = series.first?.capturedAt ?? latest.capturedAt
        let startDate = boundary.map { max(firstDate, $0) } ?? firstDate
        let elapsedSeconds = latest.capturedAt.timeIntervalSince(startDate) - excludedDuration(
            from: startDate, to: latest.capturedAt, intervals: excluding
        )
        let elapsed = elapsedSeconds / 86_400
        guard elapsed > 0, elapsed.isFinite else {
            return RateWindowResult(ratePerDay: nil, observedDays: elapsed.isFinite ? max(elapsed, 0) : nil)
        }

        var totalBytes = 0.0
        var hasDelta = false
        for (current, previous) in zip(series.dropFirst(), series) {
            guard let currentUnits = current.dataUnitsWritten,
                  let previousUnits = previous.dataUnitsWritten,
                  current.deviceID == previous.deviceID,
                  current.capturedAt > previous.capturedAt,
                  currentUnits >= previousUnits
            else { continue }
            let intervalDuration = current.capturedAt.timeIntervalSince(previous.capturedAt)
            let overlapStart = max(previous.capturedAt, startDate)
            let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
            guard intervalDuration > 0,
                  !excluding.contains(where: { $0.intersects(interval) }) else { continue }
            let overlap = current.capturedAt.timeIntervalSince(overlapStart)
            guard overlap > 0 else { continue }
            let fraction = min(max(overlap / intervalDuration, 0), 1)
            totalBytes += Double(currentUnits - previousUnits) * Self.bytesPerNVMeDataUnit * fraction
            hasDelta = true
        }
        guard hasDelta, totalBytes.isFinite else {
            return RateWindowResult(ratePerDay: nil, observedDays: elapsed)
        }
        return RateWindowResult(
            ratePerDay: totalBytes / max(elapsed, 1 / 24),
            observedDays: elapsed
        )
    }

    private func powerHourRate(in series: [DriveSnapshot], excluding: [DateInterval]) -> Double? {
        let values = zip(series.dropFirst(), series).compactMap { current, previous -> Double? in
            let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
            guard !excluding.contains(where: { $0.intersects(interval) }) else { return nil }
            guard let currentUnits = current.dataUnitsWritten,
                  let previousUnits = previous.dataUnitsWritten,
                  let currentHours = current.powerOnHours,
                  let previousHours = previous.powerOnHours,
                  current.capturedAt > previous.capturedAt,
                  currentUnits >= previousUnits,
                  currentHours > previousHours
            else { return nil }
            return Double(currentUnits - previousUnits) * Self.bytesPerNVMeDataUnit /
                Double(currentHours - previousHours)
        }
        return values.nilIfEmpty.map(median)
    }

    private func observedWriteBytes(in series: [DriveSnapshot]) -> Double {
        writeDeltas(from: series, deviceID: nil).reduce(0) { $0 + $1.bytes }
    }

    private func positivePercentageRates(
        _ series: [DriveSnapshot],
        excluding: [DateInterval]
    ) -> [(ratePerDay: Double, date: Date)] {
        let cutoff = (series.last?.capturedAt ?? Date()).addingTimeInterval(-Self.lifetimeWindowDays * 86_400)
        return zip(series.dropFirst(), series).compactMap { current, previous in
            let interval = DateInterval(start: previous.capturedAt, end: current.capturedAt)
            guard !excluding.contains(where: { $0.intersects(interval) }) else { return nil }
            guard
                current.capturedAt >= cutoff,
                let currentPercentage = current.percentageUsed,
                let previousPercentage = previous.percentageUsed,
                currentPercentage > previousPercentage,
                current.capturedAt > previous.capturedAt
            else { return nil }
            let days = current.capturedAt.timeIntervalSince(previous.capturedAt) / 86_400
            guard days > 0 else { return nil }
            return (Double(currentPercentage - previousPercentage) / days, current.capturedAt)
        }
    }

    private func excludedDuration(from start: Date, to end: Date, intervals: [DateInterval]) -> TimeInterval {
        guard end > start else { return 0 }
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let lower = max(start, interval.start)
            let upper = min(end, interval.end)
            return upper > lower ? DateInterval(start: lower, end: upper) : nil
        }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var mergedStart: Date?
        var mergedEnd: Date?
        for interval in clipped {
            guard let currentStart = mergedStart, let currentEnd = mergedEnd else {
                mergedStart = interval.start
                mergedEnd = interval.end
                continue
            }
            if interval.start <= currentEnd {
                mergedEnd = max(currentEnd, interval.end)
            } else {
                total += currentEnd.timeIntervalSince(currentStart)
                mergedStart = interval.start
                mergedEnd = interval.end
            }
        }
        if let currentStart = mergedStart, let currentEnd = mergedEnd {
            total += currentEnd.timeIntervalSince(currentStart)
        }
        return total
    }

    private func positiveRates<T: BinaryInteger>(
        _ values: [(Date, T)],
        delta: (T, T) -> Double
    ) -> [(ratePerDay: Double, date: Date)] {
        zip(values.dropFirst(), values).compactMap { current, previous in
            guard current.0 > previous.0, current.1 >= previous.1 else { return nil }
            let days = current.0.timeIntervalSince(previous.0) / 86_400
            guard days > 0 else { return nil }
            return (delta(previous.1, current.1) / days, current.0)
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    private func mad(_ values: [Double], center: Double) -> Double {
        median(values.map { abs($0 - center) })
    }
}

private struct WriteDelta {
    let startDate: Date
    let endDate: Date
    let bytes: Double
}

private struct WriteBucketAccumulator {
    var bytes: Double = 0
    var sampleCount: Int = 0
    var observedSeconds: TimeInterval = 0
    var containsSpanningDelta = false
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
