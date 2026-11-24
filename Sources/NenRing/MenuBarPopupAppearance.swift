import AppKit
import Combine
import SwiftUI

/// Changes only the native menu's appearance. AppKit keeps ownership of its
/// material, corners and shadow; the hosted content has no painted background.
@MainActor
final class MenuBarPopupAppearance {
    private let menu: NSMenu
    private let content: NSView
    private let preferences: UserDefaults?
    private var isOpen = false
    private var appliedScheme: ColorScheme?
    private var preferenceObservation: AnyCancellable?

    init(menu: NSMenu, content: NSView, preferences: UserDefaults? = nil) {
        self.menu = menu
        self.content = content
        self.preferences = preferences
        if let preferences {
            preferenceObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification,
                                                                          object: preferences)
                .sink { [weak self] _ in
                    MainRunLoop.perform {
                        MainActor.assumeIsolated {
                            self?.applyCurrentPreference()
                        }
                    }
                }
            applyCurrentPreference()
        }
    }

    private func applyCurrentPreference() {
        let mode = preferences?.string(forKey: "appearanceMode")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        preferenceDidChange(mode.colorScheme)
    }

    func willOpen(_ scheme: ColorScheme?) {
        Self.apply(scheme, to: menu, content: content)
        appliedScheme = scheme
        isOpen = true
    }

    func preferenceDidChange(_ scheme: ColorScheme?) {
        guard !isOpen else {
            guard scheme != appliedScheme else { return }
            // AppKit can retain the old menu material while hosted text has
            // already changed. Close before changing either appearance.
            menu.cancelTracking()
            return
        }
        Self.apply(scheme, to: menu, content: content)
        appliedScheme = scheme
    }

    func didClose(_ scheme: ColorScheme?) {
        isOpen = false
        Self.apply(scheme, to: menu, content: content)
        appliedScheme = scheme
    }

    static func apply(_ scheme: ColorScheme?, to menu: NSMenu, content: NSView) {
        let appearance = scheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        if menu.appearance?.name != appearance?.name {
            menu.appearance = appearance
        }
        if content.appearance?.name != appearance?.name {
            content.appearance = appearance
        }
    }
}
