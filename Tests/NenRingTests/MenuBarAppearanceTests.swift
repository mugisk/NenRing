import AppKit
import SwiftUI
import XCTest
@testable import NenRing

final class MenuBarAppearanceTests: XCTestCase {
    @MainActor
    func testOpenMenuClosesBeforeChangingColorsAndIgnoresAlreadyAppliedPreference() {
        let menu = CancellationRecordingMenu()
        let content = NSView()
        let appearance = MenuBarPopupAppearance(menu: menu, content: content)
        appearance.willOpen(.light)
        appearance.preferenceDidChange(.light)
        XCTAssertEqual(menu.cancellationCount, 0)
        appearance.preferenceDidChange(.dark)
        XCTAssertEqual(menu.cancellationCount, 1)
        XCTAssertEqual(menu.appearance?.name, .aqua, "Retain both old appearances until tracking ends")
        XCTAssertEqual(content.appearance?.name, .aqua)
        appearance.didClose(.dark)
        XCTAssertEqual(menu.appearance?.name, .darkAqua)
        XCTAssertEqual(content.appearance?.name, .darkAqua)
        appearance.preferenceDidChange(nil)
        XCTAssertEqual(menu.cancellationCount, 1)
        XCTAssertNil(menu.appearance)
        XCTAssertNil(content.appearance)
    }

    @MainActor
    func testHostedSwiftUIAndNativeMenuChangeTogetherAndReturnToInheritedAppearance() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let content = NSHostingView(rootView: AppearanceProbe())
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = content
        menu.addItem(item)
        // Adding a custom item detaches its view. Attach after that so this
        // offscreen inheritance check has a real parent (not a menu window).
        window.contentView = content

        for scheme in [ColorScheme.dark, .light, .dark] {
            MenuBarPopupAppearance.apply(scheme, to: menu, content: content)
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let expected: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            XCTAssertEqual(menu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
            XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
            XCTAssertEqual(try XCTUnwrap(findProbe(in: content)).stringValue, scheme == .dark ? "dark" : "light")
            XCTAssertNil(content.layer?.mask, "AppKit owns the menu outline")
            XCTAssertEqual(content.layer?.cornerRadius ?? 0, 0)
            XCTAssertTrue(window.hasShadow)
        }

        MenuBarPopupAppearance.apply(nil, to: menu, content: content)
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(menu.appearance)
        XCTAssertNil(content.appearance)
        XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(try XCTUnwrap(findProbe(in: content)).stringValue, "light")
        window.appearance = NSAppearance(named: .darkAqua)
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(content.window === window, "The test host must still belong to its parent window")
        XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(try XCTUnwrap(findProbe(in: content)).stringValue, "dark",
                       "System mode must keep following inherited appearance without reopening")
    }

    /// Captures a real NSMenu over a plain test window. View-cache images
    /// cannot verify AppKit's corners, material or shadow.
    @MainActor
    func testOptInNativeMenuPreviews() throws {
        guard let output = ProcessInfo.processInfo.environment["NENRING_MENU_APPEARANCE_PREVIEW_ROOT"] else {
            throw XCTSkip("Native menu preview requires an explicit output directory")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NenRing-menu-appearance-preview-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 80, width: 680, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "NenRing — native menu appearance preview"
        defer { window.close() }
        let menu = NSMenu()
        let item = NSMenuItem()
        let reference = MenuPreviewHostReference()
        let previewState = MenuPreviewState()
        let root = MenuBarPopupRoot(model: model, actions: MenuBarPopupActions(), startsMonitoring: false,
            onSizeChange: {
                guard let host = reference.content else { return }
                host.frame.size = host.fittingSize
                menu.itemChanged(item)
            })
        let preview = MenuPreviewContent(root: root, state: previewState) {
            guard let host = reference.content else { return }
            host.frame.size = host.fittingSize
            menu.itemChanged(item)
        }
        let content = NSHostingView(rootView: AnyView(preview.defaultAppStorage(preferences)))
        reference.content = content
        content.sizingOptions = [.intrinsicContentSize]
        item.view = content
        menu.addItem(item)
        let lifecycle = MenuBarPopupAppearance(menu: menu, content: content, preferences: preferences)
        let delegate = MenuAppearancePreviewDelegate(appearance: lifecycle, preferences: preferences)
        menu.delegate = delegate
        NSApp.activate(ignoringOtherApps: true)

        for background in ["white", "black"] {
            window.backgroundColor = background == "white" ? .white : .black
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                preferences.set(name, forKey: "appearanceMode")
                let frame = window.frame
                let screen = try XCTUnwrap(window.screen)
                let rect = "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
                var heights: [CGFloat] = []
                for stage in 0...2 {
                    previewState.extraHeight = stage == 1 ? 80 : 0
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    content.frame.size = content.fittingSize
                    menu.itemChanged(item)
                    var captured = false
                    let closedBefore = delegate.closeCount
                    let step: @MainActor @Sendable () -> Void = {
                        content.layoutSubtreeIfNeeded()
                        content.frame.size = content.fittingSize
                        menu.itemChanged(item)
                        heights.append(content.frame.height)
                        let expected: NSAppearance.Name = (stage == 1 ? scheme != .dark : scheme == .dark) ? .darkAqua : .aqua
                        XCTAssertEqual(menu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
                        XCTAssertEqual(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-R", rect,
                            directory.appendingPathComponent("menu-\(name)-on-\(background)-\(stage).png").path]
                        do {
                            try capture.run()
                            capture.waitUntilExit()
                            XCTAssertEqual(capture.terminationStatus, 0)
                            captured = capture.terminationStatus == 0
                        } catch { XCTFail("Menu capture failed: \(error)") }
                        guard stage < 2 else { menu.cancelTracking(); return }
                        preferences.set(stage == 0 ? (name == "dark" ? "light" : "dark") : name,
                                        forKey: "appearanceMode")
                    }
                    let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                        MainActor.assumeIsolated { step() }
                    }
                    let failIfStillOpen: @MainActor @Sendable () -> Void = {
                        XCTFail("An appearance change must close the menu before hosted colors change")
                        menu.cancelTracking()
                    }
                    let watchdog = Timer(timeInterval: 2.5, repeats: false) { _ in
                        MainActor.assumeIsolated { failIfStillOpen() }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    RunLoop.main.add(watchdog, forMode: .common)
                    menu.popUp(positioning: nil, at: NSPoint(x: 180, y: 740), in: window.contentView)
                    timer.invalidate()
                    watchdog.invalidate()
                    XCTAssertTrue(captured)
                    XCTAssertEqual(delegate.closeCount, closedBefore + 1)
                }
                XCTAssertEqual(heights.count, 3)
                if heights.count == 3 {
                    XCTAssertGreaterThan(heights[1], heights[0])
                    XCTAssertEqual(heights[2], heights[0], accuracy: 1)
                }
            }
        }
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.history.isEmpty)
    }

    @MainActor
    private func findProbe(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == "appearance-probe" { return field }
        return view.subviews.lazy.compactMap { self.findProbe(in: $0) }.first
    }

}

private final class CancellationRecordingMenu: NSMenu {
    var cancellationCount = 0
    override func cancelTracking() { cancellationCount += 1 }
}

@MainActor
private final class MenuPreviewHostReference {
    weak var content: NSHostingView<AnyView>?
}

@MainActor
private final class MenuAppearancePreviewDelegate: NSObject, NSMenuDelegate {
    let appearance: MenuBarPopupAppearance
    let preferences: UserDefaults
    var closeCount = 0
    init(appearance: MenuBarPopupAppearance, preferences: UserDefaults) {
        self.appearance = appearance
        self.preferences = preferences
    }
    private var scheme: ColorScheme? {
        (preferences.string(forKey: "appearanceMode").flatMap(AppearanceMode.init(rawValue:)) ?? .system).colorScheme
    }
    func menuWillOpen(_ menu: NSMenu) { appearance.willOpen(scheme) }
    func menuDidClose(_ menu: NSMenu) {
        closeCount += 1
        appearance.didClose(scheme)
    }
}

@MainActor
private final class MenuPreviewState: ObservableObject {
    @Published var extraHeight: CGFloat = 0
}

private struct MenuPreviewContent: View {
    let root: MenuBarPopupRoot
    @ObservedObject var state: MenuPreviewState
    var onSizeChange: @MainActor () -> Void
    var body: some View {
        root.padding(.bottom, state.extraHeight)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in
                let onSizeChange = onSizeChange
                MainRunLoop.perform { MainActor.assumeIsolated { onSizeChange() } }
            }
    }
}

private struct AppearanceProbe: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.identifier = NSUserInterfaceItemIdentifier("appearance-probe")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = scheme == .dark ? "dark" : "light"
    }
}
