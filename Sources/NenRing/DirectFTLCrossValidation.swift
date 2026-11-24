import Foundation

/// Read-time validation, independent of the forecast's WAF and N/u budget.
struct DirectFTLPowerOnHoursCheck: Equatable, Sendable {
    var offsetHours: Double?
    var offsetChangeHours: Double?
    var toleranceHours: Double?
    var failure: String?
    var detail: String

    static func evaluate(ftl: ASPToolDiagnosticsSnapshot, smart: DriveSnapshot?,
                         previous: ASPToolDiagnosticsSnapshot?, smartHistory: [DriveSnapshot]) -> Self {
        guard let smart, smart.deviceID == ftl.deviceID,
              abs(smart.capturedAt.timeIntervalSince(ftl.capturedAt)) <= 86_400,
              let ftlHours = ftl.powerOnHours, let smartHours = smart.powerOnHours else {
            return Self(detail: "POH未取得、別device、またはSMART取得時刻が24時間以上離れています")
        }
        let offset = Double(ftlHours) - Double(smartHours)
        guard let previous, previous.deviceID == ftl.deviceID,
              previous.capturedAt < ftl.capturedAt,
              let oldFTLHours = previous.powerOnHours,
              let oldSMART = smartHistory.filter({ $0.deviceID == smart.deviceID && $0.powerOnHours != nil
                  && $0.capturedAt < smart.capturedAt
                  && abs($0.capturedAt.timeIntervalSince(previous.capturedAt)) <= 86_400 })
                .min(by: { abs($0.capturedAt.timeIntervalSince(previous.capturedAt))
                    < abs($1.capturedAt.timeIntervalSince(previous.capturedAt)) }),
              let oldSMARTHours = oldSMART.powerOnHours else {
            return Self(offsetHours: offset, detail: "初回POH差 \(format(offset)) h・比較基線なし")
        }
        guard ftlHours >= oldFTLHours, smartHours >= oldSMARTHours else {
            return Self(offsetHours: offset, failure: "FTL／SMARTのPower On Hoursが逆行しました",
                        detail: "POH逆行・保存前照合失敗")
        }
        let change = abs(offset - (Double(oldFTLHours) - Double(oldSMARTHours)))
        // Either read may precede/follow its reference. Allow sampling skew in
        // addition to the D6 two-hour integer/rounding allowance.
        let tolerance = 2 + (abs(smart.capturedAt.timeIntervalSince(ftl.capturedAt))
            + abs(oldSMART.capturedAt.timeIntervalSince(previous.capturedAt))) / 3_600
        return Self(offsetHours: offset, offsetChangeHours: change, toleranceHours: tolerance,
                    failure: change > tolerance ? "FTL−SMART POH差が急変しました（\(format(change)) h／許容 \(format(tolerance)) h）" : nil,
                    detail: "FTL−SMART \(format(offset)) h・差の変化 \(format(change)) h／許容 \(format(tolerance)) h")
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

struct DirectFTLCrossValidation: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }
    var rows: [Row] = []
    static let empty = Self()

    static func build(snapshots: [ASPToolDiagnosticsSnapshot], smartHistory: [DriveSnapshot],
                      forecast: NANDEnduranceV2, intervals: [FTLIntervalObservation]) -> Self {
        let ordered = snapshots.filter { $0.sourceArtifact == .directFTL }.sorted { $0.capturedAt < $1.capturedAt }
        guard let latest = ordered.last else { return Self(rows: [Row(title: "照合", detail: "Direct FTL未取得")]) }
        let smart = smartHistory.filter { $0.deviceID == latest.deviceID
            && abs($0.capturedAt.timeIntervalSince(latest.capturedAt)) <= 86_400 }
            .min { abs($0.capturedAt.timeIntervalSince(latest.capturedAt)) < abs($1.capturedAt.timeIntervalSince(latest.capturedAt)) }
        let poh = DirectFTLPowerOnHoursCheck.evaluate(ftl: latest, smart: smart,
            previous: ordered.dropLast().last, smartHistory: smartHistory)
        var rows = [Row(title: "照合入力", detail: "FTL \(date(latest.capturedAt)) ／ SMART \(smart.map { date($0.capturedAt) } ?? "未取得")")]
        let host = DirectFTLReadCrossCheck.evaluate(ftl: latest, smart: smart,
            previous: ordered.dropLast().last, smartHistory: smartHistory)
        switch host {
        case let .passed(ratio): rows.append(Row(title: "Host Writes", detail: String(format: "FTL／SMART %.6f・保存前照合の条件内", ratio)))
        case let .failed(reason), let .incomplete(reason), let .unavailable(reason): rows.append(Row(title: "Host Writes / POH", detail: reason))
        }
        rows.append(Row(title: "Power On Hours", detail: poh.detail))
        rows.append(Row(title: "Controller / SMART Used", detail: percentageComparison(latest.controllerPercentUsed,
            smart?.percentageUsed.map { Double($0) })))
        let normalizedPSLC: Double? = {
            guard let pe = latest.slcAveragePE, let eol = latest.slcEOLPE,
                  pe.isFinite, eol.isFinite, pe >= 0, eol > 0 else { return nil }
            return 100 * pe / eol
        }()
        rows.append(Row(title: "pSLC Used / P/E", detail: percentageComparison(latest.slcPercentUsed, normalizedPSLC)))
        rows.append(Row(title: "損耗率の扱い", detail: "差はpercentage point。丸め・定義の違いを観察する補助照合であり、保存停止や予測倍率には使いません"))
        rows.append(Row(title: "予測入力", detail: forecast.inputDate.map(date) ?? "検証済み入力なし"))
        if let residual = forecast.reconstructionDiagnostics {
            rows.append(Row(title: "生涯再構成残差", detail: "実測NAND − geometry×平均P/E = \(bytes(residual.signedResidualBytes))・未同定分を予算へ加算しません"))
        } else { rows.append(Row(title: "生涯再構成残差", detail: "検証済みtopology・geometry・NAND／P/E不足")) }
        if let boundary = forecast.instrumentBoundaries.last,
           let check = boundary.checks.first(where: { $0.kind == .d7LifetimeResidual }) {
            rows.append(Row(title: "D7 境界検査", detail: "\(check.available ? (check.passed ? "連続" : "非連続") : "比較待ち")・\(check.detail)"))
        } else { rows.append(Row(title: "D7 境界検査", detail: "比較する計測境界なし")) }
        // Never substitute an older interval when the latest interval has no
        // comparable residual, or mix a raw after-boundary read with this lane.
        if let interval = intervals.max(by: { $0.endAt < $1.endAt }), let residual = interval.intervalResidual {
            rows.append(Row(title: "直近区間残差", detail: "\(date(interval.startAt)) → \(date(interval.endAt))：\(bytes(residual.signedResidualBestBytes))（量子化範囲 \(bytes(residual.signedResidualLowBytes))〜\(bytes(residual.signedResidualHighBytes))）"))
            rows.append(Row(title: "区間の内部活動", detail: "Age refresh \(raw(residual.ageRefreshDelta)) ／ BG refresh \(raw(residual.backgroundRefreshDelta)) ／ error refresh \(raw(residual.bandsRefreshedOnErrorDelta))・原因や単位の同一性を断定しません"))
        } else { rows.append(Row(title: "直近区間残差", detail: "比較可能な検証済み区間なし")) }
        return Self(rows: rows)
    }

    private static func percentageComparison(_ lhs: Double?, _ rhs: Double?) -> String {
        guard let lhs, let rhs, lhs.isFinite, rhs.isFinite else { return "比較値未取得（0で補完しません）" }
        return String(format: "%.3f%% ／ %.3f%%・差 %+.3f pp（補助観測）", lhs, rhs, lhs - rhs)
    }
    private static func bytes(_ value: Double) -> String { String(format: "%+.3f GB", value / 1e9) }
    private static func raw(_ value: UInt64?) -> String { value.map(String.init) ?? "未取得" }
    private static func date(_ value: Date) -> String { value.formatted(date: .numeric, time: .shortened) }
}

/// Compares an `asptool_snapshot.log` the user produced and imported against
/// the Direct FTL reads around the same time. The log is evidence only: it is
/// never stored in the forecast lane. Cumulative counters are interpolated
/// between the Direct reads on both sides of the log when possible, because
/// the log and the scheduled reads rarely share a timestamp.
struct ASPToolLogComparison: Equatable, Sendable {
    typealias Row = DirectFTLCrossValidation.Row
    var rows: [Row] = []
    /// `nil` while no log or no comparable Direct read exists.
    var verdict: ASPToolLogVerdict?
    static let empty = Self()
    private static let maximumInterpolationSpan: TimeInterval = 48 * 3_600
    private static let maximumNearestDistance: TimeInterval = 24 * 3_600

    static func isASPToolText(_ artifact: ASPToolSourceArtifact) -> Bool {
        artifact == .importedFixture || artifact == .extractedASPTool
    }

    /// `logSource` is what the log's own sysdiagnose says about it; it only
    /// applies to the log it was read with.
    static func build(snapshots: [ASPToolDiagnosticsSnapshot],
                      acceptedDirectIDs: Set<UUID>? = nil,
                      logSource: ASPToolLogSourceIdentity? = nil) -> Self {
        guard let log = snapshots.filter({ isASPToolText($0.sourceArtifact) }).max(by: { $0.capturedAt < $1.capturedAt }) else {
            return Self(rows: [Row(title: "asptoolログ", detail: "未読込")])
        }
        let source = logSource.flatMap { $0.describes(log) ? $0 : nil }
        let direct = snapshots
            .filter { $0.sourceArtifact == .directFTL && (log.deviceID == nil || $0.deviceID == nil || $0.deviceID == log.deviceID) }
            .sorted { $0.capturedAt < $1.capturedAt }
        let before = direct.last { $0.capturedAt <= log.capturedAt }
        // An exact-time Direct read needs no interpolation or future sample.
        let after = before?.capturedAt == log.capturedAt ? nil : direct.first { $0.capturedAt > log.capturedAt }
        guard let nearest = [before, after].compactMap({ $0 })
            .min(by: { abs($0.capturedAt.timeIntervalSince(log.capturedAt)) < abs($1.capturedAt.timeIntervalSince(log.capturedAt)) }) else {
            return Self(rows: [
                Row(title: "asptoolログ", detail: date(log.capturedAt)),
                Row(title: "照合", detail: "比較するDirect FTLの取得がありません")
            ])
        }
        if let acceptedDirectIDs {
            guard [before, after].compactMap({ $0 }).allSatisfy({ acceptedDirectIDs.contains($0.id) }) else {
                return Self(rows: [
                    Row(title: "asptoolログ", detail: date(log.capturedAt)),
                    Row(title: "照合", detail: "Direct FTLの連続性を確認できません（逆行・系列変更・取得間隔）")
                ])
            }
        }
        if let before, let after {
            guard canInterpolate(from: before, to: after) else {
                return Self(rows: [
                    Row(title: "asptoolログ", detail: date(log.capturedAt)),
                    Row(title: "照合", detail: "Direct FTLの連続性を確認できません（逆行・系列変更・取得間隔）")
                ])
            }
        } else if abs(nearest.capturedAt.timeIntervalSince(log.capturedAt)) > maximumNearestDistance {
            return Self(rows: [
                Row(title: "asptoolログ", detail: date(log.capturedAt)),
                Row(title: "照合", detail: "近接するDirect FTL取得がありません")
            ])
        }

        var rows = [Row(title: "asptoolログ", detail: date(log.capturedAt)),
                    Row(title: "時刻の根拠", detail: source == nil
                        ? "ファイルの更新日時（コピーで変わることがあります）"
                        : "アーカイブに記録された出力時刻")]
        if let before, let after {
            rows.append(Row(title: "Direct FTL", detail: "\(date(before.capturedAt)) と \(date(after.capturedAt)) の間で補間"))
        } else {
            rows.append(Row(title: "Direct FTL", detail: "\(date(nearest.capturedAt))（時刻差 \(hours(nearest.capturedAt.timeIntervalSince(log.capturedAt)))）"))
        }
        func counter(_ value: (ASPToolDiagnosticsSnapshot) -> Double?) -> Double? {
            if let before, let after, let lhs = value(before), let rhs = value(after) {
                let span = after.capturedAt.timeIntervalSince(before.capturedAt)
                guard span > 0 else { return lhs }
                return lhs + (rhs - lhs) * log.capturedAt.timeIntervalSince(before.capturedAt) / span
            }
            return value(nearest)
        }
        rows.append(Row(title: "Host Writes", detail: relative(log.hostWrittenBytes, counter(\.hostWrittenBytes), unit: gigabytes)))
        rows.append(Row(title: "NAND Writes", detail: relative(log.nandWrittenBytes, counter(\.nandWrittenBytes), unit: gigabytes)))
        // Not `.map(Double.init)`: on UInt64 that resolves to Double(bitPattern:).
        rows.append(Row(title: "Power On Hours", detail: absolute(log.powerOnHours.map { Double($0) },
            counter { $0.powerOnHours.map { Double($0) } }, format: "%.0f h")))
        rows.append(Row(title: "TLC 平均P/E", detail: absolute(log.tlcAveragePE, nearest.tlcAveragePE, format: "%.1f")))
        rows.append(Row(title: "pSLC 平均P/E", detail: absolute(log.slcAveragePE, nearest.slcAveragePE, format: "%.1f")))
        rows.append(Row(title: "TLC EOL", detail: absolute(log.tlcEOLPE, nearest.tlcEOLPE, format: "%.0f")))
        rows.append(Row(title: "pSLC EOL", detail: absolute(log.slcEOLPE, nearest.slcEOLPE, format: "%.0f")))
        let verdict = ASPToolLogVerdict.evaluate(log: log, before: before, after: after, nearest: nearest,
                                                 source: source)
        rows.append(Row(title: "判定", detail: verdict.detail))
        rows.append(Row(title: "取得元", detail: verdict.sourceDetail))
        rows.append(Row(title: "判定基準", detail: ASPToolLogVerdict.criteria))
        rows.append(Row(title: "扱い", detail: "左がasptool、右がDirect FTL。照合のための表示で、寿命予測には使いません"))
        return Self(rows: rows, verdict: verdict)
    }

    private static func canInterpolate(from before: ASPToolDiagnosticsSnapshot,
                                       to after: ASPToolDiagnosticsSnapshot) -> Bool {
        let span = after.capturedAt.timeIntervalSince(before.capturedAt)
        guard span > 0, span <= maximumInterpolationSpan,
              before.deviceID != nil, before.deviceID == after.deviceID,
              before.sourceBuild == after.sourceBuild,
              before.contractBuild == after.contractBuild,
              before.resolvedCoreWearVersion == after.resolvedCoreWearVersion,
              before.firmwareEpoch == after.firmwareEpoch,
              before.directFormatVersion == after.directFormatVersion,
              before.directTopology == after.directTopology,
              before.tlcEOLPE == after.tlcEOLPE,
              before.slcEOLPE == after.slcEOLPE,
              before.hostWritesUnitState == after.hostWritesUnitState,
              before.nandWritesUnitState == after.nandWritesUnitState else { return false }

        func nondecreasing<T: Comparable>(_ earlier: T?, _ later: T?) -> Bool {
            guard let earlier, let later else { return earlier == nil && later == nil }
            return later >= earlier
        }
        return nondecreasing(before.hostWrites, after.hostWrites)
            && nondecreasing(before.nandWrites, after.nandWrites)
            && nondecreasing(before.powerOnHours, after.powerOnHours)
            && nondecreasing(before.tlcAveragePE, after.tlcAveragePE)
            && nondecreasing(before.slcAveragePE, after.slcAveragePE)
    }

    private static func gigabytes(_ value: Double) -> String { String(format: "%.2f GB", value / 1e9) }

    private static func relative(_ log: Double?, _ direct: Double?, unit: (Double) -> String) -> String {
        guard let log, let direct, log.isFinite, direct.isFinite else { return "比較値未取得" }
        guard direct != 0 else { return "\(unit(log)) ／ \(unit(direct))" }
        return "\(unit(log)) ／ \(unit(direct))・差 \(String(format: "%+.3f%%", 100 * (log - direct) / direct))"
    }

    private static func absolute(_ log: Double?, _ direct: Double?, format: String) -> String {
        guard let log, let direct, log.isFinite, direct.isFinite else { return "比較値未取得" }
        return "\(String(format: format, log)) ／ \(String(format: format, direct))・差 \(String(format: "%+.2f", log - direct))"
    }

    private static func hours(_ seconds: TimeInterval) -> String { String(format: "%+.1f時間", seconds / 3_600) }
    private static func date(_ value: Date) -> String { value.formatted(date: .numeric, time: .shortened) }
}

/// Pass/fail judgment of one imported asptool log against the Direct FTL reads
/// around it. It is shown and recorded locally only: it never enables
/// collection, changes the reviewed builds or feeds the forecast.
struct ASPToolLogVerdict: Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable { case passed, failed, inconclusive }
    /// Whether the log's own sysdiagnose names the same macOS major version
    /// and firmware lineage as the Direct FTL read. Kept apart from the
    /// numbers: close numbers alone do not show where a log came from.
    enum SourceCheck: String, Equatable, Sendable { case confirmed, unconfirmed, mismatched }
    let outcome: Outcome
    let reasons: [String]
    let logCapturedAt: Date
    /// macOS build and firmware of the Direct FTL read the log was compared with.
    let sourceBuild: String?
    let firmware: String?
    var sourceCheck: SourceCheck = .unconfirmed

    static let writesRelativeTolerance = 0.001
    static let powerOnHoursTolerance = 1.0
    /// Without Direct reads on both sides, only a read this close is judged.
    static let maximumSingleSideDistance: TimeInterval = 30 * 60
    static let criteria = "Host・NANDは差±0.1%以内、Power On Hoursは差±1 h以内、平均P/Eは前後のDirect FTLの範囲内、EOLは完全一致"

    /// Identifies this result for one log, build and firmware.
    var recordKey: String {
        [outcome.rawValue, sourceBuild ?? "", firmware ?? "",
         String(logCapturedAt.timeIntervalSince1970), sourceCheck.rawValue].joined(separator: "|")
    }

    var sourceDetail: String {
        switch sourceCheck {
        case .confirmed: return "sysdiagnoseのmacOSとSSDファームウェアが、Direct FTLとメジャーバージョン・ファームウェア系列で一致"
        case .unconfirmed: return "未確認（sysdiagnoseのアーカイブから読み込むと、sw_vers.txtとSPNVMeDataType.spxで確認します）"
        case .mismatched: return "不一致（sysdiagnoseのmacOSまたはSSDファームウェアがDirect FTLと異なります）"
        }
    }

    var detail: String {
        switch outcome {
        case .passed: return "基準内で一致"
        case .failed: return "不一致: " + reasons.joined(separator: " / ")
        case .inconclusive: return "判定できません: " + reasons.joined(separator: " / ")
        }
    }

    static func evaluate(log: ASPToolDiagnosticsSnapshot, before: ASPToolDiagnosticsSnapshot?,
                         after: ASPToolDiagnosticsSnapshot?, nearest: ASPToolDiagnosticsSnapshot,
                         source: ASPToolLogSourceIdentity? = nil) -> Self {
        let reference = before ?? nearest
        var sourceCheck = SourceCheck.unconfirmed
        func result(_ outcome: Outcome, _ reasons: [String]) -> Self {
            Self(outcome: outcome, reasons: reasons, logCapturedAt: log.capturedAt,
                 sourceBuild: reference.sourceBuild, firmware: reference.firmware, sourceCheck: sourceCheck)
        }
        guard reference.sourceBuild != nil, reference.firmware != nil else {
            return result(.inconclusive, ["Direct FTLのmacOS buildまたはファームウェアを取得できません"])
        }
        let describedSource = source.flatMap { $0.describes(log) ? $0 : nil }
        if let describedSource, let build = describedSource.macOSBuild, let firmware = describedSource.ssdFirmware {
            guard UpdateLineage.build(build) == UpdateLineage.build(reference.sourceBuild),
                  UpdateLineage.firmware(firmware) == UpdateLineage.firmware(reference.firmware) else {
                sourceCheck = .mismatched
                return result(.inconclusive, ["sysdiagnoseのmacOSまたはSSDファームウェアがDirect FTLと異なります"])
            }
            sourceCheck = .confirmed
        }
        if let build = log.sourceBuild, build != reference.sourceBuild {
            return result(.inconclusive, ["asptoolログとDirect FTLのmacOS buildが異なります"])
        }
        if let firmware = log.firmware, firmware != reference.firmware {
            return result(.inconclusive, ["asptoolログとDirect FTLのファームウェアが異なります"])
        }
        let bracketed = before != nil && after != nil
        // A file's modification time can change when it is copied, so only
        // the time recorded in the archive is trusted for a one-sided match.
        guard bracketed || describedSource != nil else {
            return result(.inconclusive, ["ファイルの更新日時で照合するため、前後のDirect FTL取得が必要です"])
        }
        guard bracketed || abs(nearest.capturedAt.timeIntervalSince(log.capturedAt)) <= maximumSingleSideDistance else {
            return result(.inconclusive, ["前後のDirect FTL取得、または30分以内の取得が必要です"])
        }
        let sides = [before, after].compactMap { $0 }
        func interpolated(_ value: (ASPToolDiagnosticsSnapshot) -> Double?) -> Double? {
            if let before, let after, let lhs = value(before), let rhs = value(after) {
                let span = after.capturedAt.timeIntervalSince(before.capturedAt)
                guard span > 0 else { return lhs }
                return lhs + (rhs - lhs) * log.capturedAt.timeIntervalSince(before.capturedAt) / span
            }
            return bracketed ? nil : value(nearest)
        }

        var failures: [String] = []
        var missing: [String] = []
        func checkWrites(_ title: String, _ value: (ASPToolDiagnosticsSnapshot) -> Double?) {
            guard let logValue = value(log), let direct = interpolated(value), direct > 0,
                  logValue.isFinite, direct.isFinite else { missing.append(title); return }
            let relative = (logValue - direct) / direct
            if abs(relative) > writesRelativeTolerance {
                failures.append("\(title) 差 \(String(format: "%+.3f%%", 100 * relative))（基準 ±0.1%）")
            }
        }
        checkWrites("Host Writes", \.hostWrittenBytes)
        checkWrites("NAND Writes", \.nandWrittenBytes)

        if let logHours = log.powerOnHours.map({ Double($0) }),
           let direct = interpolated({ $0.powerOnHours.map { Double($0) } }) {
            if abs(logHours - direct) > powerOnHoursTolerance {
                failures.append("Power On Hours 差 \(String(format: "%+.1f", logHours - direct)) h（基準 ±1 h）")
            }
        } else {
            missing.append("Power On Hours")
        }

        func checkRange(_ title: String, _ value: (ASPToolDiagnosticsSnapshot) -> Double?) {
            let directValues = sides.compactMap(value)
            guard let logValue = value(log), directValues.count == sides.count,
                  let lower = directValues.min(), let upper = directValues.max() else { missing.append(title); return }
            if logValue < lower || logValue > upper {
                let range = lower == upper ? String(format: "%.1f", lower)
                    : "\(String(format: "%.1f", lower))〜\(String(format: "%.1f", upper))"
                failures.append("\(title) \(String(format: "%.1f", logValue)) がDirect FTLの値（\(range)）と一致しません")
            }
        }
        checkRange("TLC 平均P/E", \.tlcAveragePE)
        checkRange("pSLC 平均P/E", \.slcAveragePE)

        func checkExact(_ title: String, _ value: (ASPToolDiagnosticsSnapshot) -> Double?) {
            guard let logValue = value(log), let direct = value(reference) else { missing.append(title); return }
            if logValue != direct {
                failures.append("\(title) \(String(format: "%.0f", logValue)) ／ \(String(format: "%.0f", direct))")
            }
        }
        checkExact("TLC EOL", \.tlcEOLPE)
        checkExact("pSLC EOL", \.slcEOLPE)

        if !failures.isEmpty { return result(.failed, failures) }
        if !missing.isEmpty { return result(.inconclusive, ["比較値がありません（\(missing.joined(separator: "・"))）"]) }
        return result(.passed, [])
    }
}
