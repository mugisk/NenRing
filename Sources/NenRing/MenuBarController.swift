import AppKit
import SwiftUI

/// Runs work on the main thread in the common run loop modes. While a menu
/// is open the main queue and main actor tasks wait until it closes; the
/// common modes keep running, so the open popup can still change.
enum MainRunLoop {
    static func perform(_ work: @escaping @Sendable () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(loop)
    }
}

/// The menu bar item and its popup. The popup is a real NSMenu with the
/// SwiftUI view as its only item, so macOS draws the same corners, edge and
/// shadow as its own menus. A MenuBarExtra panel had smaller corners and
/// showed a second corner on light backgrounds when it was rounded further.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static var shared: MenuBarController?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let item = NSMenuItem()
    private let popup: NSHostingView<MenuBarPopupRoot>
    private let label: SizeReportingHostingView<MenuBarLabelRoot>
    private lazy var popupAppearance = MenuBarPopupAppearance(menu: menu, content: popup, preferences: .standard)
    private var pendingAction: (@MainActor () -> Void)?

    /// Creates the menu bar item once. Window actions run after the menu has
    /// closed, as SwiftUI cannot present windows while a menu is tracking.
    static func install(model: DashboardModel, actions: MenuBarPopupActions) {
        guard shared == nil else { return }
        shared = MenuBarController(model: model, actions: actions)
    }

    private init(model: DashboardModel, actions: MenuBarPopupActions) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        label = SizeReportingHostingView(rootView: MenuBarLabelRoot(model: model))
        popup = NSHostingView(rootView: MenuBarPopupRoot(model: model, actions: MenuBarPopupActions()))
        super.init()
        popup.rootView = MenuBarPopupRoot(model: model, actions: closingMenu(actions),
                                          onSizeChange: { [weak self] in self?.fitPopup() })
        popup.sizingOptions = [.intrinsicContentSize]
        popup.frame.size = popup.fittingSize
        item.view = popup
        menu.addItem(item)
        menu.delegate = self
        statusItem.menu = menu
        applyPopupAppearance()

        label.sizingOptions = [.intrinsicContentSize]
        label.autoresizingMask = [.height]
        label.onSizeChange = { [weak self] in self?.fitLabel() }
        statusItem.button?.addSubview(label)
        fitLabel()
    }

    /// The button has no title or image of its own, so the item's length is
    /// set from the SwiftUI label; a variable length would stay empty.
    private func fitLabel() {
        guard let button = statusItem.button else { return }
        let size = label.fittingSize
        let length = ceil(size.width) + 2 * Self.labelInset
        if statusItem.length != length { statusItem.length = length }
        // Full height, so SwiftUI centres the label as the button resizes.
        label.frame = NSRect(x: Self.labelInset, y: 0, width: ceil(size.width), height: button.bounds.height)
    }

    /// The status bar already pads each item, so the label needs no inset;
    /// a fractional one blurred the label on a 1x display.
    private static let labelInset: CGFloat = 0

    private func closingMenu(_ actions: MenuBarPopupActions) -> MenuBarPopupActions {
        func close(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            { [weak self] in
                self?.pendingAction = action
                self?.menu.cancelTracking()
            }
        }
        return MenuBarPopupActions(showMainWindow: close(actions.showMainWindow),
                                   showSettings: close(actions.showSettings),
                                   showAbout: close(actions.showAbout),
                                   refresh: close(actions.refresh))
    }

    /// The menu keeps an item's first size; it follows the popup only when
    /// told that the item changed.
    private func fitPopup() {
        let size = popup.fittingSize
        guard size != popup.frame.size else { return }
        popup.frame.size = size
        menu.itemChanged(item)
    }

    private func applyPopupAppearance() {
        popupAppearance.preferenceDidChange(popupColorScheme)
    }

    private var popupColorScheme: ColorScheme? {
        let mode = UserDefaults.standard.string(forKey: "appearanceMode")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        return mode.colorScheme
    }

    /// Apply before AppKit lays out the menu, including a preference changed
    /// while it was closed. The status-bar label keeps its system appearance.
    func menuWillOpen(_ menu: NSMenu) {
        popup.rootView.model.realtimeIO.setPopupOpen(true)
        popupAppearance.willOpen(popupColorScheme)
        fitPopup()
    }

    func menuDidClose(_ menu: NSMenu) {
        popup.rootView.model.realtimeIO.setPopupOpen(false)
        popupAppearance.didClose(popupColorScheme)
        guard let action = pendingAction else { return }
        pendingAction = nil
        // Runs once the menu's tracking loop has returned.
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { action() } }
    }
}

/// Reports changes of its SwiftUI content size, including while the menu
/// is open.
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (@MainActor () -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard let onSizeChange else { return }
        MainRunLoop.perform { MainActor.assumeIsolated { onSizeChange() } }
    }
}

struct MenuBarPopupRoot: View {
    @ObservedObject var model: DashboardModel
    let actions: MenuBarPopupActions
    /// Read-only native-menu previews must not start collectors.
    var startsMonitoring = true
    var onSizeChange: @MainActor () -> Void = {}
    @AppStorage(UIString.preferenceKey) private var uiLanguage = "system"
    @AppStorage(TemperatureUnit.preferenceKey) private var temperatureUnit = TemperatureUnit.system.rawValue

    var body: some View {
        MenuBarMonitorView(model: model, startsMonitoring: startsMonitoring, windowActions: actions)
            .id(uiLanguage + "|" + temperatureUnit)
            .environment(\.locale, UIString.locale)
            // The hosting view did not report its new size while the menu
            // was open (the short-term totals were cut off), so the content
            // reports it from here.
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in
                let onSizeChange = onSizeChange
                MainRunLoop.perform { MainActor.assumeIsolated { onSizeChange() } }
            }
    }
}

struct MenuBarLabelRoot: View {
    @ObservedObject var model: DashboardModel
    @AppStorage(UIString.preferenceKey) private var uiLanguage = "system"
    @AppStorage(TemperatureUnit.preferenceKey) private var temperatureUnit = TemperatureUnit.system.rawValue

    var body: some View {
        MenuBarStatusItem(model: model)
            .id(uiLanguage + "|" + temperatureUnit)
    }
}
