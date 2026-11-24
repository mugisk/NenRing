import Foundation

/// The unit temperatures are shown in. Readings are stored and computed in
/// degrees Celsius; only the user-facing pages convert. Research and
/// diagnostic text, reports and documents stay in Celsius.
enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case system
    case celsius
    case fahrenheit

    static let preferenceKey = "temperatureUnit"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "システムに合わせる"
        case .celsius: return "摂氏（°C）"
        case .fahrenheit: return "華氏（°F）"
        }
    }

    /// The stored preference; `system` until the user picks a unit.
    static var selected: TemperatureUnit {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(TemperatureUnit.init(rawValue:)) ?? .system
    }

    /// The unit to draw with: the preference, with `system` resolved from
    /// the region's measurement system.
    static var current: TemperatureUnit { selected.resolved() }

    func resolved(locale: Locale = .current) -> TemperatureUnit {
        guard self == .system else { return self }
        return locale.measurementSystem == .us ? .fahrenheit : .celsius
    }

    private var isFahrenheit: Bool { resolved() == .fahrenheit }

    var symbol: String { isFahrenheit ? "°F" : "°C" }

    /// A Celsius value in this unit.
    func value(_ celsius: Double) -> Double {
        isFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// A value typed in this unit, back in Celsius.
    func celsius(from value: Double) -> Double {
        isFahrenheit ? (value - 32) * 5 / 9 : value
    }

    func wholeNumber(_ celsius: Double) -> Int {
        Int(value(celsius).rounded())
    }

    /// "33.8°C" or "92.8°F".
    func text(_ celsius: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value(celsius)) + symbol
    }
}

enum ValueFormatter {

    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    static let shortDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    static func integer(_ value: UInt64?) -> String {
        guard let value else { return "未取得" }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    /// A temperature reading in the display unit the user chose.
    static func temperature(_ value: Int?, unit: TemperatureUnit = .current) -> String {
        guard let value else { return "未取得" }
        return "\(unit.wholeNumber(Double(value))) \(unit.symbol)"
    }

    static func percentage(_ value: UInt64?) -> String {
        guard let value else { return "未取得" }
        return "\(value)%"
    }

    static func bytes(_ value: Double?) -> String {
        bytes(value, zeroPadded: false)
    }

    /// `zeroPadded` keeps trailing zeros ("1.00 PB" rather than "1 PB") so
    /// values listed together in one card read at the same precision.
    static func bytes(_ value: Double?, zeroPadded: Bool) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未取得" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB, .usePB]
        formatter.countStyle = .decimal
        formatter.includesUnit = true
        formatter.allowsNonnumericFormatting = false
        formatter.zeroPadsFractionDigits = zeroPadded
        // Double(Int64.max) rounds up to 2^63, which Int64 cannot hold.
        return formatter.string(fromByteCount: Int64(exactly: value.rounded()) ?? Int64.max)
    }

    static func decimalCapacity(_ value: UInt64?) -> String {
        guard let value else { return "未取得" }
        return capacityText(Double(value), base: 1_000, labels: ["B", "KB", "MB", "GB", "TB", "PB"])
    }

    static func ratioPercent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未取得" }
        return String(format: "%.1f%%", value * 100)
    }

    private static func capacityText(_ value: Double, base: Double, labels: [String]) -> String {
        var scaled = value
        var index = 0
        while scaled >= base, index < labels.count - 1 {
            scaled /= base
            index += 1
        }
        if index == 0 {
            return String(format: "%.0f %@", scaled, labels[index])
        }
        return String(format: "%.1f %@", scaled, labels[index])
    }

    static func dataUnits(_ units: UInt64?, bytes: Double?) -> String {
        guard let units else { return "未取得" }
        let unitText = integer(units) + " DU"
        guard let bytes else { return unitText }
        return unitText + "  /  " + self.bytes(bytes)
    }

    static func shortDateTime(_ date: Date?) -> String {
        guard let date else { return "未取得" }
        return shortDateTimeFormatter.string(from: date)
    }

    /// Compact labels used on the overview charts.  The slash-separated form
    /// stays readable in a narrow plot, while a year is added only when the
    /// visible range crosses a year boundary.  Hourly charts normally show
    /// only `HH:mm`; the date is included when the visible range spans more
    /// than one calendar day so adjacent midnight buckets remain unambiguous.
    static func chartAxisDate(
        _ date: Date,
        period: HistoryPeriod,
        includeYear: Bool = false,
        includeDateForHour: Bool = false
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch period {
        case .hour:
            formatter.dateFormat = includeDateForHour
                ? (includeYear ? "yyyy/MM/dd HH:mm" : "MM/dd HH:mm")
                : "HH:mm"
        case .day, .week, .month:
            formatter.dateFormat = includeYear ? "yyyy/MM/dd" : "MM/dd"
        }
        return formatter.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

}
