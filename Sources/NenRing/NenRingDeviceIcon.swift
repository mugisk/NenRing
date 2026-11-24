import AppKit
import SwiftUI

struct NenRingDeviceIcon: View {
    let size: CGFloat
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppIconController.preferenceKey) private var appIconAppearanceRaw = AppIconAppearance.system.rawValue

    var body: some View {
        Group {
            if let image = deviceImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "internaldrive.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(size * 0.20)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var deviceImage: NSImage? {
        let preference = AppIconAppearance(rawValue: appIconAppearanceRaw) ?? .system
        let resolved: AppIconAppearance
        switch preference {
        case .light, .dark:
            resolved = preference
        case .system:
            resolved = colorScheme == .dark ? .dark : .light
        }

        let appearance = resolved == .dark ? "dark" : "light"
        // Artist-rendered PNGs preserve the ring masks and color transition.
        // Use the small-size artwork for compact UI, not a resized full icon.
        let name = compact ? "icon_32x32@2x"
            : (size <= 64 ? "icon_128x128" : "icon_128x128@2x")
        return Self.image(named: name, appearance: appearance)
    }

    /// Decoding the PNG on every redraw showed up in profiles, so each
    /// artwork is loaded once. The bundle's images never change while the
    /// app runs.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func image(named name: String, appearance: String) -> NSImage? {
        let key = "\(appearance)/\(name)"
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "NenRingIcons/AppIcon-\(appearance).iconset"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache[key] = image
        return image
    }
}
