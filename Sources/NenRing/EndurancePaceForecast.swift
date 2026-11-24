import Foundation

/// Converts one remaining-host estimate into arrival dates at independently
/// observed write rates. A forecast row can therefore show a recent pace and
/// a long-term anchor without changing the underlying remaining budget.
enum EndurancePaceForecast {
    static func arrivalDate(
        remainingHostBytes: Double?,
        hostBytesPerDay: Double?,
        now: Date
    ) -> Date? {
        guard let remainingHostBytes, remainingHostBytes.isFinite, remainingHostBytes >= 0,
              let hostBytesPerDay, hostBytesPerDay.isFinite, hostBytesPerDay > 0 else { return nil }
        guard remainingHostBytes > 0 else { return now }

        let seconds = remainingHostBytes / hostBytesPerDay * 86_400
        guard seconds.isFinite, seconds > 0 else { return nil }
        let date = now.addingTimeInterval(seconds)
        return date > now ? date : nil
    }
}
