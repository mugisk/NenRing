import AppKit
import Foundation

enum AppIconAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "自動"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }
}

enum AppIconController {
    static let preferenceKey = "appIconAppearance"

    @MainActor
    static func applyCurrentPreference(preferences: UserDefaults = .standard) {
        let rawValue = preferences.string(forKey: preferenceKey)
        let preference = rawValue.flatMap(AppIconAppearance.init(rawValue:)) ?? .system
        apply(preference)
    }

    @MainActor
    static func apply(_ preference: AppIconAppearance) {
        let resolved = resolvedAppearance(for: preference)
        guard let image = loadIcon(for: resolved) else { return }
        NSApp.applicationIconImage = image
    }

    @MainActor
    private static func resolvedAppearance(for preference: AppIconAppearance) -> AppIconAppearance {
        guard preference == .system else { return preference }
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }

    @MainActor
    private static func loadIcon(for appearance: AppIconAppearance) -> NSImage? {
        let name: String
        switch appearance {
        case .dark:
            name = "NenRingIconDark"
        case .system, .light:
            name = "NenRingIconLight"
        }

        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
