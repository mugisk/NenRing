import Foundation

/// Rated endurance of retail client SSDs associated with an Apple NAND profile.
/// Generation mappings retain their documented or unverified status.
/// Used by the dashboard comparison and by provisional SMART
/// forecasts, never as an Apple rating. Sources: docs/REFERENCE_TBW.md.
struct ReferenceTBWEntry: Equatable, Sendable {
    let name: String
    /// Lower-cased substrings matched against IORegistry `vendor-name`.
    let vendors: [String]
    /// Lower-cased prefixes matched against IORegistry `nand-marketing-name`.
    let marketingPrefixes: [String]
    /// (retail capacity in bytes, rated TBW per TB of capacity).
    let ratings: [(capacityBytes: Double, tbwPerTB: Double)]
    var generationMappingUnverified = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }

    func tbwPerTB(forCapacity capacity: Double) -> Double {
        // Pick the retail capacity closest on a log scale; smaller drives
        // carry a higher TBW per TB, so this keeps the ratio for similar sizes.
        ratings.min {
            abs(log($0.capacityBytes / capacity)) < abs(log($1.capacityBytes / capacity))
        }!.tbwPerTB
    }
}

struct ReferenceTBWResolution: Equatable, Sendable {
    let tbwBytes: Double
    let tbwPerTB: Double
    /// nil when the NAND is unknown and the default applies.
    let entryName: String?
    var generationMappingUnverified = false
    /// Apple internal SSDs only: capacity × 3000 P/E ÷ the TLC writes per
    /// host byte measured on one reference Mac. Transferring this observation
    /// to another device is a model assumption, not a validated retention
    /// rating or a lower bound on Apple endurance.
    var appleTendencyBytes: Double? = nil

    var summary: String {
        let basis = entryName.map {
            generationMappingUnverified ? "\($0)・世代対応未確認の市販品参考値" : "\($0)と同世代NANDの市販品"
        } ?? "NAND未特定・既定の比較基準"
        return "参考TBW \(ValueFormatter.bytes(tbwBytes))（\(Int(tbwPerTB)) TBW/TB・\(basis)）"
    }

    /// Where the rating comes from, translated for display.
    var displayBasis: String {
        var basis = entryName.map { UIString.text($0) } ?? UIString.text("NAND未特定・既定の比較基準")
        if generationMappingUnverified {
            basis += " · " + UIString.text("世代対応未確認の市販品参考値")
        }
        return UIString.format("%@ · %.0f TBW/TB", basis, tbwPerTB)
    }

    var displaySummary: String {
        var basis = entryName.map { UIString.text($0) } ?? UIString.text("NAND未特定・既定の比較基準")
        if generationMappingUnverified {
            basis += " · " + UIString.text("世代対応未確認の市販品参考値")
        }
        return UIString.format("%@ · %.0f TBW/TB · 容量比例の参考値。Appleの保証値ではありません。", basis, tbwPerTB)
    }
}

enum ReferenceTBW {
    /// Common client rating (for example 1 TB drives rated 600 TBW).
    static let defaultTBWPerTB = 600.0

    /// Reference Mac (M1, 256 GB, Hynix V6): lifetime TLC NAND writes per
    /// host byte. One device so far; diagnostic reports will refine it.
    static let appleObservedTLCWritesPerHostByte = 0.66
    static let ratedTLCPECycles = 3_000.0

    static func appleTendencyBytes(capacityBytes: UInt64) -> Double {
        Double(capacityBytes) * ratedTLCPECycles / appleObservedTLCWritesPerHostByte
    }

    static let entries: [ReferenceTBWEntry] = [
        ReferenceTBWEntry(
            name: "SK hynix 128層TLC（V6）",
            vendors: ["hynix"],
            marketingPrefixes: ["tlc_3d_v6"],
            ratings: [(500e9, 1_000), (1e12, 750), (2e12, 600)]  // Gold P31
        ),
        ReferenceTBWEntry(
            name: "SK hynix 176層TLC（V7）",
            vendors: ["hynix"],
            marketingPrefixes: ["tlc_3d_v7"],
            ratings: [(500e9, 1_000), (1e12, 750), (2e12, 600)]  // Platinum P41
        ),
        ReferenceTBWEntry(
            name: "Kioxia/SanDisk BiCS4（96層）",
            vendors: ["toshiba", "kioxia", "sandisk"],
            marketingPrefixes: ["tlc_3d_g4", "itlc_3d_g4"],
            ratings: [(1e12, 600)]  // WD Blue SN550 1 TB
        ),
        ReferenceTBWEntry(
            name: "Kioxia/SanDisk BiCS5（112層）",
            vendors: ["toshiba", "kioxia", "sandisk"],
            marketingPrefixes: ["tlc_3d_g5", "itlc_3d_g5"],
            ratings: [(1e12, 600)]  // WD Black SN770 1 TB
        ),
        ReferenceTBWEntry(
            name: "Kioxia BiCS8（218層）",
            vendors: ["toshiba", "kioxia", "sandisk"],
            marketingPrefixes: ["tlc_3d_g8"],
            ratings: [(1e12, 600)]  // Kioxia EXCERIA PRO G2 (M5 MacBook Air 1 TB)
        ),
        ReferenceTBWEntry(
            name: "Samsung V-NAND TLC（g7）",
            vendors: ["samsung"],
            marketingPrefixes: ["tlc_3d_g7"],
            ratings: [(1e12, 600)],  // Samsung 990 PRO
            generationMappingUnverified: true
        )
    ]

    static func resolve(profile: AppleNANDHardwareProfile?, capacityBytes: UInt64?, appleInternal: Bool = false) -> ReferenceTBWResolution? {
        guard let capacityBytes, capacityBytes > 0 else { return nil }
        let capacity = Double(capacityBytes)
        let vendor = profile?.nandVendor?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let marketing = profile?.nandMarketingName?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let entry = entries.first { entry in
            entry.vendors.contains { vendor.contains($0) } &&
                entry.marketingPrefixes.contains { marketing.hasPrefix($0) }
        }
        let perTB = entry?.tbwPerTB(forCapacity: capacity) ?? defaultTBWPerTB
        return ReferenceTBWResolution(
            tbwBytes: perTB * capacity,
            tbwPerTB: perTB,
            entryName: entry?.name,
            generationMappingUnverified: entry?.generationMappingUnverified ?? false,
            appleTendencyBytes: appleInternal ? appleTendencyBytes(capacityBytes: capacityBytes) : nil
        )
    }
}
