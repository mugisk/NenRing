import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "システム"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppColor {
    // System colours keep the utility legible in both appearances and when
    // the window becomes inactive. Status colors remain distinct from neutral
    // comparison tones and are paired with labels or icons.
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceRaised = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let textPrimary = Color(nsColor: .labelColor)
    // In the light appearance the system's secondary and tertiary grays read
    // faint on the white cards, so they are drawn closer to black there. The
    // dark appearance keeps the system colours.
    static let textSecondary = Color(nsColor: lightAdjusted(.secondaryLabelColor, light: NSColor.black.withAlphaComponent(0.66)))
    // Muted notes sit one step below the secondary text; the system tertiary
    // gray read too faint for the small notes, notably in the dark appearance.
    static let textMuted = Color(nsColor: NSColor(name: "NenRingTextMuted") { appearance in
        if appearance.name.rawValue.contains("HighContrast") { return .tertiaryLabelColor }
        return isDark(appearance) ? NSColor.white.withAlphaComponent(0.42) : NSColor.black.withAlphaComponent(0.54)
    })
    /// The unfilled part of bars, rings and sliders, a little stronger than
    /// the separator colour in both appearances.
    static let gaugeTrack = Color(nsColor: NSColor(name: "NenRingGaugeTrack") { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)
    })
    /// The selected sidebar item: a darker patch in the light appearance and
    /// a lighter one in the dark, without the accent colour.
    static let sidebarSelection = Color(nsColor: NSColor(name: "NenRingSidebarSelection") { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.09)
    })
    static let accent = Color(nsColor: .systemBlue)
    static let good = Color(nsColor: .systemBlue)
    static let positive = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    /// Neutral comparison/reference tone; it is intentionally distinct from
    /// the green health status color.
    static let teal = dataColor(light: 0x5EC2BB, dark: 0x7CD0C8)
    static let blue = Color(nsColor: .systemBlue)
    /// NAND/FTL values use a separate hue from Host Writes.  Keeping this
    /// distinct from `accent` makes the two counters readable at a glance in
    /// the history summary, including in dark mode and when the window is
    /// inactive.
    static let nand = dataColor(light: 0xC97EB3, dark: 0xD29CC5)
    /// Host Reads have their own cool tone so the read counter does not blend
    /// into either Host Writes or the NAND-derived series.
    static let read = tlcText
    /// NAND domains, used wherever TLC and pSLC appear (wear chart, write
    /// breakdown, forecast bars) so each domain keeps one colour.
    /// The light appearance draws rings and charts in a lighter tone; the
    /// `…Text` colours keep values written in these hues legible on white.
    static let tlc = dataColor(light: 0x5F8CD4, dark: 0x7FA3E6)
    static let tlcText = dataColor(light: 0x2C68C7, dark: 0x7FA3E6)
    static let pslc = dataColor(light: 0x5EC2BB, dark: 0x7CD0C8)
    static let pslcText = dataColor(light: 0x2BAFA5, dark: 0x7CD0C8)
    /// Overall remaining budget. Its hue sits a little toward cyan so that it
    /// stays distinct from the TLC blue beside it.
    static let overall = dataColor(light: 0x4EA5D6, dark: 0x66B8E6)
    static let overallText = dataColor(light: 0x1689C9, dark: 0x66B8E6)
    static let hostWrite = overall
    static let hostWriteText = overallText
    /// Temperature is a quiet cool tone; readings above
    /// `TemperatureLineRun.warmThreshold` are drawn warm.
    static let temperature = dataColor(light: 0x6E9DBE, dark: 0x9BBAD3)
    static let temperatureText = dataColor(light: 0x3F739B, dark: 0x9BBAD3)
    static let temperatureWarm = dataColor(light: 0xE3945E, dark: 0xEFB088)
    static let temperatureWarmText = dataColor(light: 0xC8702F, dark: 0xEFB088)
    /// The forecast scenarios below the real-use row: soft blues, lighter
    /// down the list, and clear of the pSLC teal and the free-space status colours.
    static let retentionScenario = dataColor(light: 0x8BA6D8, dark: 0xA8BCE2)
    static let clientScenario = dataColor(light: 0x92BCE0, dark: 0xADCDE8)
    /// Retail reference rows are comparisons, not measurements, and are the
    /// lightest of the forecast scenarios.
    static let reference = dataColor(light: 0xB4D3E8, dark: 0xC7DEEE)
    /// Status colours for gauges and bars, in the same tone as the chart
    /// colours. Status text and icons keep the system colours above.
    static let positiveFill = dataColor(light: 0x57BE76, dark: 0x7ACB93)
    static let amberFill = dataColor(light: 0xEDA35D, dark: 0xF1B47F)
    static let redFill = dataColor(light: 0xEB655E, dark: 0xF08680)

    /// A chart colour with its own sRGB value for each appearance.
    private static func dataColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = isDark(appearance) ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255,
                           alpha: 1)
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                    .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                    .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark].contains($0) } ?? false
    }

    /// `light` in the standard light appearance; the system colour in the
    /// dark and high-contrast appearances, which are already legible.
    private static func lightAdjusted(_ system: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .vibrantLight])
            let highContrast = appearance.name.rawValue.contains("HighContrast")
            return match != nil && !isDark(appearance) && !highContrast ? light : system
        }
    }
}

/// Visual language for an instrument boundary. The marker is deliberately
/// independent from the health palette: a verified boundary is not a health
/// improvement, and a pending boundary is not itself a drive fault.
func instrumentBoundaryColor(_ record: InstrumentBoundaryRecord) -> Color {
    switch InstrumentBoundaryPresentation.status(for: record) {
    case .verified:
        return AppColor.blue
    case .settlingWait, .evidencePending:
        return AppColor.amber
    case .failed:
        return AppColor.red
    case .deviceChange:
        return AppColor.textMuted
    case .neutral:
        return AppColor.textMuted
    }
}

func instrumentBoundaryDash(_ record: InstrumentBoundaryRecord) -> [CGFloat] {
    switch InstrumentBoundaryPresentation.status(for: record) {
    case .verified:
        return [2, 3]
    case .evidencePending:
        return [5, 3]
    case .settlingWait:
        return [2, 2, 6, 2]
    case .failed:
        return [8, 3]
    case .deviceChange:
        return [1, 3]
    case .neutral:
        return [3, 3]
    }
}

struct InstrumentBoundaryLegendView: View {
    let records: [InstrumentBoundaryRecord]

    var body: some View {
        let items = InstrumentBoundaryPresentation.legendItems(for: records)
        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 3))
                            path.addLine(to: CGPoint(x: 20, y: 3))
                        }
                        .stroke(
                            color(for: item.status),
                            style: StrokeStyle(lineWidth: 1.5, dash: dash(for: item.status))
                        )
                        .frame(width: 20, height: 6)
                        .accessibilityHidden(true)

                        localizedText(item.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityLabel(UIString.text("表示範囲内の計測器境界"))
        }
    }

    private func color(for status: InstrumentBoundaryDisplayStatus) -> Color {
        switch status {
        case .verified: return AppColor.blue
        case .settlingWait, .evidencePending: return AppColor.amber
        case .failed: return AppColor.red
        case .deviceChange, .neutral: return AppColor.textMuted
        }
    }

    private func dash(for status: InstrumentBoundaryDisplayStatus) -> [CGFloat] {
        switch status {
        case .verified: return [2, 3]
        case .evidencePending: return [5, 3]
        case .settlingWait: return [2, 2, 6, 2]
        case .failed: return [8, 3]
        case .deviceChange: return [1, 3]
        case .neutral: return [3, 3]
        }
    }
}

extension Color {
    init(hex: UInt64, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            localizedText(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
            if let subtitle {
                Text(verbatim: "· " + UIString.text(subtitle))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AppColor.textMuted)
            }
            Spacer()
        }
    }
}
