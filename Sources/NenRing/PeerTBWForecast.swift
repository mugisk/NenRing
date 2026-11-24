import Foundation

/// Reference product specifications are evidence for a planning assumption,
/// not a claim that Apple uses the same SSD or guarantees the same TBW.
struct PeerTBWForecast: Equatable, Sendable {
    let thresholdBytes: Double
    let remainingBytes: Double
    let measuredDate: Date?
    let historicalDate: Date?
    let measuredRate: Double?
    let historicalRate: Double?
    let referenceDate: Date
    let capacityBytes: UInt64
    let reached: Bool
    let writtenBytes: Double
    var reference: ReferenceTBWResolution? = nil
    static let sourceURL = "https://ssd.skhynix.com/gold_p31/"

    var conservativeComparison: PeerTBWForecast {
        let threshold = floor((1_200_000_000_000_000 * Double(capacityBytes) / 2_000_000_000_000) / 5_000_000_000_000) * 5_000_000_000_000
        let written = writtenBytes
        let remaining = max(0, threshold - written)
        func date(_ rate: Double?) -> Date? {
            guard remaining > 0, let rate else { return nil }
            return referenceDate.addingTimeInterval(remaining / rate * 86_400)
        }
        return PeerTBWForecast(thresholdBytes: threshold, remainingBytes: remaining,
            measuredDate: date(measuredRate), historicalDate: date(historicalRate),
            measuredRate: measuredRate, historicalRate: historicalRate,
            referenceDate: referenceDate, capacityBytes: capacityBytes, reached: written >= threshold,
            writtenBytes: written)
    }

    static func threshold(profile: AppleNANDHardwareProfile?, capacity: UInt64) -> Double? {
        ReferenceTBW.resolve(profile: profile, capacityBytes: capacity)?.tbwBytes
    }

    static func make(profile: AppleNANDHardwareProfile?, capacity: UInt64,
                     written: Double?, measuredRate: Double?, historicalRate: Double?,
                     now: Date) -> PeerTBWForecast? {
        guard let threshold = threshold(profile: profile, capacity: capacity),
              let written, written.isFinite, written >= 0 else { return nil }
        let remaining = max(0, threshold - written)
        func validRate(_ rate: Double?) -> Double? {
            guard let rate, rate.isFinite, rate > 0 else { return nil }
            return rate
        }
        let measured = validRate(measuredRate)
        let historical = validRate(historicalRate)
        func date(_ rate: Double?) -> Date? {
            guard remaining > 0, let rate else { return nil }
            let seconds = remaining / rate * 86_400
            guard seconds.isFinite else { return nil }
            return now.addingTimeInterval(seconds)
        }
        return PeerTBWForecast(thresholdBytes: threshold, remainingBytes: remaining,
            measuredDate: date(measured), historicalDate: date(historical),
            measuredRate: measured, historicalRate: historical, referenceDate: now,
            capacityBytes: capacity, reached: written >= threshold, writtenBytes: written,
            reference: ReferenceTBW.resolve(profile: profile, capacityBytes: capacity))
    }
}
