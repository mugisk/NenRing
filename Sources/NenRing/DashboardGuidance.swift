import Foundation

/// What the dashboard should tell the user when SMART data is missing:
/// the cause, what to do, and an optional command to copy.
struct DashboardGuidance: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case error
        case info
    }

    struct Link: Equatable, Sendable {
        let title: String
        let url: URL
    }

    let severity: Severity
    let title: String
    let message: String
    /// Numbered steps shown below the message.
    var steps: [String] = []
    let command: String?
    var links: [Link] = []
    /// Look again when the user comes back to the app, for example after
    /// installing smartmontools in Terminal.
    var retriesWhenAppBecomesActive = false

    static let installSmartmontoolsCommand = "brew install smartmontools"
    static let homebrewURL = URL(string: "https://brew.sh")!
    /// The official page links a macOS installer (.dmg) with an arm64 and
    /// x86_64 build, for users without Homebrew.
    static let smartmontoolsDownloadURL = URL(string: "https://www.smartmontools.org/wiki/Download")!

    static func make(
        state: DashboardState,
        hasSnapshot: Bool,
        failure: SmartctlServiceError?
    ) -> DashboardGuidance? {
        guard case let .failed(rawMessage) = state else { return nil }
        // smartctl reports one line per candidate device; repeat lines add nothing.
        var seen = Set<String>()
        let message = rawMessage
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
        switch failure {
        case .executableNotFound:
            return DashboardGuidance(
                severity: .info,
                title: "smartmontools を入れてください",
                message: "SSDの状態（SMART）と温度は、無料のツール smartmontools で取得します。導入が必要なのは最初の1回のみです。",
                steps: [
                    "「ターミナルを開く」を押し、下のコマンドをコピーして貼り付け、returnキーを押します。",
                    "終わったらNenRingに戻ります。自動でもう一度探します。"
                ],
                command: installSmartmontoolsCommand,
                links: [
                    Link(title: "コマンドが見つからない場合：Homebrewを入れる", url: homebrewURL),
                    Link(title: "Homebrewを使わない場合：公式のインストーラ", url: smartmontoolsDownloadURL)
                ],
                retriesWhenAppBecomesActive: true
            )
        case .timedOut:
            return DashboardGuidance(
                severity: .error,
                title: "SMART の取得がタイムアウトしました",
                message: hasSnapshot
                    ? "前回取得した値を表示しています。しばらくしてから再試行してください。"
                    : "しばらくしてから再試行してください。続く場合は smartctl を単体で実行して応答を確認してください。",
                command: nil
            )
        case .noUsableDevice, .invalidJSON, .outputLimitExceeded, nil:
            return DashboardGuidance(
                severity: .error,
                title: "SSD の情報を取得できませんでした",
                message: hasSnapshot ? "前回取得した値を表示しています。\n\(message)" : message,
                command: nil
            )
        }
    }
}

/// Content of the SMART status card. Missing data is never shown as
/// healthy.
struct SmartStatusCardContent: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case positive
        case warning
        case unknown
    }

    let value: String
    let detail: String
    let icon: String
    let tone: Tone

    static func make(snapshot: DriveSnapshot?) -> Self {
        guard let snapshot else {
            return Self(value: "未取得", detail: "データなし", icon: "questionmark.circle", tone: .unknown)
        }
        if let reason = SMARTWarningReason.collect(from: snapshot).first {
            return Self(value: "要確認", detail: reason.title, icon: "exclamationmark.shield.fill", tone: .warning)
        }
        if snapshot.smartPassed == true {
            return Self(value: "正常", detail: "SMARTの警告なし", icon: "checkmark.shield.fill", tone: .positive)
        }
        return Self(value: "判定なし", detail: "判定データなし", icon: "questionmark.circle", tone: .unknown)
    }
}

/// Which evidence the endurance forecast rests on. A SMART-only estimate is
/// available on every Mac but is provisional; the FTL domain budget needs a
/// reviewed Direct FTL environment.
enum ForecastEvidence: Equatable, Sendable {
    case ftl
    case smartProvisional(lowerBytes: Double?, upperBytes: Double?, confidence: ForecastConfidence)
    /// Percentage Used has not moved yet; the total is a retail reference TBW.
    case referenceTBW(ReferenceTBWResolution)
    case unavailable

    static func resolve(ftlTotal: Double?, smart: EnduranceForecast) -> Self {
        if ftlTotal != nil { return .ftl }
        guard smart.estimatedEnduranceBytes != nil else { return .unavailable }
        if let reference = smart.referenceTBW { return .referenceTBW(reference) }
        return .smartProvisional(
            lowerBytes: smart.enduranceRangeLowerBytes,
            upperBytes: smart.enduranceRangeUpperBytes,
            confidence: smart.confidence
        )
    }

    var isSmartProvisional: Bool {
        switch self {
        case .smartProvisional, .referenceTBW: return true
        case .ftl, .unavailable: return false
        }
    }

    var rowTitle: String {
        switch self {
        case .smartProvisional: return "実使用（暫定・SMARTのみ）"
        case .referenceTBW: return "実使用（暫定・参考TBWから）"
        case .ftl, .unavailable: return "実使用"
        }
    }

    /// Explanation shown in place of the FTL-only comparison rows.
    var smartProvisionalNote: String? {
        if case let .referenceTBW(reference) = self {
            let switching = UIString.text("Percentage Usedが2%以上になるとSMART実測、FTL取得後はNAND実測の推定に切り替わります。")
            if let tendency = reference.appleTendencyBytes {
                return UIString.format(
                    "損耗の観測が少ないため、総量を幅で示します。市販品の定格 %@（%@）から、参照機1台からの外挿 %@（TLC書込/Host %@）までです。日付と残り期間は定格の側で計算します。Appleの保証値ではありません。%@",
                    ValueFormatter.bytes(reference.tbwBytes), reference.displayBasis,
                    ValueFormatter.bytes(tendency),
                    String(format: "%.2f", ReferenceTBW.appleObservedTLCWritesPerHostByte), switching)
            }
            return UIString.format("損耗の観測が少ないため、市販品の定格 %@（%@）を総量とした目安です。Appleの保証値ではありません。%@",
                                   ValueFormatter.bytes(reference.tbwBytes), reference.displayBasis, switching)
        }
        guard case let .smartProvisional(lower, upper, confidence) = self else { return nil }
        var range = ""
        if let lower, let upper {
            range = UIString.format("総量の範囲 %@〜%@・", ValueFormatter.bytes(lower), ValueFormatter.bytes(upper))
        }
        return UIString.format("FTL未取得・SMARTからの暫定推計（%@信頼度 %@）。クライアント負荷はFTL取得後、参考基準は論理容量が取得できた場合に表示します。", UIString.message(range), UIString.text(confidence.title))
    }
}

/// One-line answer at the top of the dashboard: is the SSD OK, how worn is
/// it, does the controller's own estimate agree with the NAND counters, and
/// roughly how long remains at the forecast pace.
struct DashboardHeadline: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case positive
        case warning
        case unknown
    }

    let tone: Tone
    let status: String
    let wear: String?
    let crossCheck: String?
    let remaining: String?

    /// Percentage Used is an integer, so a NAND-based wear within this many
    /// points of it counts as agreeing.
    static let agreementTolerancePoints = 1.5

    /// NAND wear compared with Percentage Used: the domain that runs out
    /// first. Falls back to TLC when there is no TLC/pSLC split.
    static func nandWearFraction(rows: [DomainForecastRow], estimates: [NANDDomainEstimate]) -> Double? {
        if let limiting = rows.min(by: { $0.remainingHostBytes < $1.remainingHostBytes }) {
            return limiting.wearFraction
        }
        guard let tlc = estimates.first(where: { $0.domain == .tlc }), tlc.eolPE > 0 else { return nil }
        return tlc.currentPE / tlc.eolPE
    }

    static func make(
        snapshot: DriveSnapshot?,
        nandWearFraction: Double?,
        hostWearFraction: Double? = nil,
        remainingHostBytes: Double?,
        remainingHostBytesUpper: Double? = nil,
        paceBytesPerDay: Double?,
        provisional: Bool,
        usesUsageStartPace: Bool = false,
        now: Date = Date()
    ) -> DashboardHeadline {
        guard let snapshot else {
            return DashboardHeadline(tone: .unknown, status: "未取得", wear: nil, crossCheck: nil, remaining: nil)
        }
        let warning = !SMARTWarningReason.collect(from: snapshot).isEmpty
        let tone: Tone = warning ? .warning : (snapshot.smartPassed == nil ? .unknown : .positive)
        let status = warning ? "要確認" : (snapshot.smartPassed == nil ? "判定なし" : "正常")

        // Not `.map(Double.init)`: on UInt64 that resolves to Double(bitPattern:).
        let pu = snapshot.percentageUsed.map { Double($0) }
        let nandPercent = nandWearFraction.map { $0 * 100 }
        let hostPercent = hostWearFraction.map { $0 * 100 }
        var wear: String?
        var crossCheck: String?
        switch (pu, nandPercent) {
        case let (pu?, nand?):
            wear = String(format: "損耗 %.2f%%", hostPercent ?? nand)
            crossCheck = abs(nand - pu) <= agreementTolerancePoints
                ? String(format: "コントローラの推定（PU %.0f%%）とNAND実測（%.2f%%）が一致", pu, nand)
                : String(format: "コントローラの推定（PU %.0f%%）とNAND実測（%.2f%%）に差があります", pu, nand)
        case let (pu?, nil):
            wear = hostPercent.map { String(format: "損耗 %.2f%%", $0) } ?? String(format: "損耗 %.0f%%（PU）", pu)
        case let (nil, nand?):
            wear = hostPercent.map { String(format: "損耗 %.2f%%", $0) } ?? String(format: "損耗 %.2f%%（NAND実測）", nand)
        case (nil, nil):
            wear = hostPercent.map { String(format: "損耗 %.2f%%", $0) }
        }

        let remaining = remainingText(remainingHostBytes: remainingHostBytes, upper: remainingHostBytesUpper,
                                      paceBytesPerDay: paceBytesPerDay, provisional: provisional,
                                      usesUsageStartPace: usesUsageStartPace, now: now)
        return DashboardHeadline(tone: tone, status: status, wear: wear, crossCheck: crossCheck, remaining: remaining)
    }

    /// Below one year the time is given in months, at zero as reached. With
    /// an upper amount (a reference TBW range) both ends are shown. The
    /// Japanese text is translated at display time by its pattern.
    static func remainingText(
        remainingHostBytes: Double?,
        upper: Double? = nil,
        paceBytesPerDay: Double?,
        provisional: Bool,
        usesUsageStartPace: Bool = false,
        now: Date
    ) -> String? {
        guard let remainingHostBytes, let paceBytesPerDay, remainingHostBytes.isFinite, remainingHostBytes >= 0,
              paceBytesPerDay.isFinite, paceBytesPerDay > 0 else { return nil }
        let prefix = provisional ? "暫定・" : ""
        let pace = usesUsageStartPace ? "使用開始からのペース" : "保存履歴のペース"
        let calendar = Calendar(identifier: .gregorian)
        func years(_ bytes: Double) -> Double { bytes / paceBytesPerDay / 365.25 }
        func date(_ bytes: Double) -> Date { now.addingTimeInterval(bytes / paceBytesPerDay * 86_400) }
        let lowerYears = years(remainingHostBytes)
        guard lowerYears.isFinite else { return nil }
        if remainingHostBytes == 0 { return "\(prefix)推定の総量に到達済み" }
        if lowerYears < 1 {
            let months = max(1, Int((lowerYears * 12).rounded()))
            let end = calendar.dateComponents([.year, .month], from: date(remainingHostBytes))
            return String(format: "%@%@で残り約%dか月（%d年%d月頃）", prefix, pace, months, end.year ?? 0, end.month ?? 0)
        }
        let lowerYear = calendar.component(.year, from: date(remainingHostBytes))
        if let upper, upper.isFinite, upper > remainingHostBytes {
            let upperYears = years(upper)
            if Int(upperYears.rounded()) > Int(lowerYears.rounded()) {
                return String(format: "%@%@で残り約%.0f〜%.0f年（%d〜%d年頃）", prefix, pace, lowerYears, upperYears,
                              lowerYear, calendar.component(.year, from: date(upper)))
            }
        }
        return String(format: "%@%@で残り約%.0f年（%d年頃）", prefix, pace, lowerYears, lowerYear)
    }
}
