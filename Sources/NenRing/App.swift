import AppKit
import Darwin
import SwiftUI

private final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1
    private(set) var isOwner = false

    init() {
        let fileManager = FileManager.default
        let directoryURL = AppDataLocation.directoryURL
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = directoryURL.appendingPathComponent("instance.lock")

        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
        }
        guard descriptor >= 0 else { return }

        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            Darwin.close(descriptor)
            return
        }

        fileDescriptor = descriptor
        isOwner = true
    }

    deinit {
        guard isOwner, fileDescriptor >= 0 else { return }
        var unlock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = Darwin.fcntl(fileDescriptor, F_SETLK, &unlock)
        Darwin.close(fileDescriptor)
    }
}

@MainActor
enum AppInstanceCoordinator {
    private static let lock = SingleInstanceLock()

    static var isPrimary: Bool {
        guard lock.isOwner, !AppDataLocation.isLegacyAppRunning else { return false }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.mugisk.NenRing"
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let hasOtherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentProcessID }
        return !hasOtherInstance
    }

    static func activateExistingInstance() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.mugisk.NenRing"
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentProcessID }
            ?? AppDataLocation.legacyBundleIdentifiers.lazy
                .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
                .first
        existing?.activate(options: [.activateAllWindows])
    }
}

@MainActor
enum DockVisibilityController {
    static let preferenceKey = "dockIconVisible"
    static let migrationVersionKey = "dockPresentationMigrationVersion"
    static let currentMigrationVersion = 1

    /// Moves existing installations to the stable menu-bar-first launch mode
    /// once. Later choices are preserved and applied on the next launch.
    static func migrateToMenuBarDefaultIfNeeded(preferences: UserDefaults) {
        guard preferences.integer(forKey: migrationVersionKey) < currentMigrationVersion else {
            return
        }

        preferences.set(false, forKey: preferenceKey)
        preferences.set(currentMigrationVersion, forKey: migrationVersionKey)
    }

    static func preferredDockVisibility(preferences: UserDefaults) -> Bool {
        preferences.object(forKey: preferenceKey) as? Bool ?? false
    }

    /// Activation policy is deliberately selected only during launch. Changing
    /// it while SwiftUI owns Window, Settings, and MenuBarExtra scenes can tear
    /// down or duplicate those scenes.
    static func applyLaunchPreference(preferences: UserDefaults) {
        let isVisible = preferredDockVisibility(preferences: preferences)
        let targetPolicy: NSApplication.ActivationPolicy = isVisible ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            _ = NSApp.setActivationPolicy(targetPolicy)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard AppInstanceCoordinator.isPrimary else {
            AppInstanceCoordinator.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        DockVisibilityController.migrateToMenuBarDefaultIfNeeded(preferences: .standard)
        DockVisibilityController.applyLaunchPreference(preferences: .standard)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconController.applyCurrentPreference()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
enum MainWindowCoordinator {
    static let identifier = NSUserInterfaceItemIdentifier("io.github.mugisk.NenRing.main")

    static func register(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = identifier
    }

    static func bringToFront(retries: Int = 6) {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.identifier == identifier }) else {
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bringToFront(retries: retries - 1)
            }
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the dashboard, settings and about windows. The menu bar
    /// item's panel cannot become main, so it is left alone.
    static func closeAllWindows() {
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.performClose(nil)
        }
    }
}

@MainActor
enum SettingsWindowCoordinator {
    static let identifier = NSUserInterfaceItemIdentifier("io.github.mugisk.NenRing.settings")

    static func register(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = identifier
        // The Settings scene creates a fixed-size window; allow resizing.
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        enlargeOnceIfNeeded(window)
    }

    nonisolated static let defaultContentSize = NSSize(width: 680, height: 800)
    private static let enlargedOnceKey = "settingsWindowEnlargedToDefaultSize"

    /// macOS restores the frame saved by earlier versions, when the window had
    /// a fixed 460 or 560 point width. Grow such a window to the new default
    /// size once; afterwards the size the user chooses is kept.
    private static func enlargeOnceIfNeeded(_ window: NSWindow, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: enlargedOnceKey) else { return }
        defaults.set(true, forKey: enlargedOnceKey)
        // Run after the saved frame has been restored.
        DispatchQueue.main.async {
            let current = window.contentRect(forFrameRect: window.frame).size
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
                  let target = enlargedContentSize(current: current, visible: visible.size) else { return }
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
            // Keep the top-left corner, then pull the window back on screen.
            var origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
            window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: false)
        }
    }

    /// The size to grow to, or nil when the window is already large enough.
    /// Each side grows to the default but never past the visible screen.
    nonisolated static func enlargedContentSize(current: NSSize, visible: NSSize) -> NSSize? {
        let target = NSSize(width: max(current.width, min(defaultContentSize.width, visible.width - 40)),
                            height: max(current.height, min(defaultContentSize.height, visible.height - 80)))
        return target == current ? nil : target
    }

    static func bringToFront(retries: Int = 6) {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.identifier == identifier }) else {
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bringToFront(retries: retries - 1)
            }
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTagView {
        WindowTagView()
    }

    func updateNSView(_ nsView: WindowTagView, context: Context) {
        SettingsWindowCoordinator.register(nsView.window)
    }

    final class WindowTagView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            SettingsWindowCoordinator.register(window)
        }
    }
}

@main
struct NenRingApp: App {
    @AppStorage(UIString.preferenceKey) private var uiLanguage = "system"
    @AppStorage(TemperatureUnit.preferenceKey) private var temperatureUnit = TemperatureUnit.system.rawValue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: DashboardModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init() {
        // Must run before anything reads preferences or opens a store.
        AppDataLocation.prepareAtLaunch()
        let model = DashboardModel()
        _model = StateObject(wrappedValue: model)
        // Start before either the main window or the menu is opened so a
        // launched app can collect history in the background immediately.
        Task { @MainActor in
            guard AppInstanceCoordinator.isPrimary else { return }
            await model.start()
        }
    }

    var body: some Scene {
        let _ = installMenuBar()
        Window("NenRing", id: "main") {
            DashboardView(model: model)
                .id(uiLanguage + "|" + temperatureUnit)
                .environment(\.locale, UIString.locale)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .commands {
            CommandGroup(replacing: .appInfo) {
                Button(UIString.text("NenRingについて")) {
                    openWindow(id: "about")
                }
            }

            // ⌘Q closes the windows but keeps the menu bar item monitoring;
            // a full quit stays available here and in the menu bar item.
            CommandGroup(replacing: .appTermination) {
                Button(UIString.text("ウィンドウを閉じる（監視は続ける）")) {
                    MainWindowCoordinator.closeAllWindows()
                }
                .keyboardShortcut("q", modifiers: [.command])

                Button(UIString.text("NenRingを完全に終了")) {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command, .option])
            }

            CommandMenu(UIString.text("操作")) {
                Button(UIString.text("更新")) {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isRefreshing)

            }
        }

        Window(UIString.text("NenRingについて"), id: "about") {
            AboutView()
                .id(uiLanguage)
                .environment(\.locale, UIString.locale)
        }
        .defaultSize(width: 420, height: 260)
        .windowResizability(.contentSize)

        Settings {
            MonitorSettingsView(model: model)
                .environment(\.locale, UIString.locale)
                .background(SettingsWindowAccessor())
        }
        .windowResizability(.contentMinSize)
    }

    /// The menu bar item is an NSMenu outside the SwiftUI scenes; the
    /// scenes' window actions are handed to it from here.
    private func installMenuBar() {
        let openWindow = openWindow
        let openSettings = openSettings
        let model = model
        DispatchQueue.main.async {
            guard AppInstanceCoordinator.isPrimary else { return }
            MenuBarController.install(model: model, actions: MenuBarPopupActions(
                showMainWindow: {
                    openWindow(id: "main")
                    MainWindowCoordinator.bringToFront()
                },
                showSettings: {
                    openSettings()
                    SettingsWindowCoordinator.bringToFront()
                },
                showAbout: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "about")
                },
                refresh: {
                    Task { await model.refresh() }
                }))
        }
    }
}
