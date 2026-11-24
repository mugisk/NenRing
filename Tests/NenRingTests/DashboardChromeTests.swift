import AppKit
import SwiftUI
import XCTest
@testable import NenRing

final class DashboardChromeTests: XCTestCase {
    @MainActor
    func testSidebarFitsMinimumWindowWithoutNestedScrollCoordinates() {
        let content = ReferenceSidebarContent(selection: .constant(.overview),
                                              researchSelection: .constant(.topology))
            .frame(width: 248, height: 642)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 248, height: 642),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> Int {
            (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollViews(in: $1) }
        }
        XCTAssertEqual(scrollViews(in: hosting), 0,
                       "The sidebar must not reintroduce the title-bar inset/hit-test mismatch")
    }

    @MainActor
    func testChromeKeepsNativeControlsAndUsesSemanticSurface() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        DashboardWindowChrome.apply(to: window)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(window.backgroundColor, .controlBackgroundColor)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        DashboardWindowChrome.apply(to: nil)
    }

    /// A real, titled AppKit window (not a painted mock-up). Monitoring is
    /// disabled and a separate preferences domain leaves the installed app alone.
    @MainActor
    func testOptInLightAndDarkWindowPreviews() throws {
        guard let output = ProcessInfo.processInfo.environment["NENRING_CHROME_PREVIEW_ROOT"] else {
            throw XCTSkip("Window preview requires an explicit output directory")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NenRing-chrome-preview-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1040),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = UIString.text(DashboardDestination.overview.title)
            window.titleVisibility = .hidden
            window.toolbarStyle = .unifiedCompact
            window.appearance = NSAppearance(named: appearance)
            let root = DashboardShellView(model: model, startsMonitoring: false)
                .defaultAppStorage(preferences)
                .environment(\.locale, UIString.locale)
            let hosting = NSHostingView(rootView: root)
            window.contentView = hosting
            DashboardWindowChrome.apply(to: window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // SwiftUI installs the split view and toolbar on the next run-loop turn.
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            hosting.layoutSubtreeIfNeeded()
            // View-cache rendering cannot capture behind-window materials.
            // Capture only this preview window through the window server.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                 directory.appendingPathComponent("window-\(name).png").path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            window.close()
        }
    }
}
