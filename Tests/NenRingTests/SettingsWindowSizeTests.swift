import AppKit
import XCTest
@testable import NenRing

final class SettingsWindowSizeTests: XCTestCase {
    private let screen = NSSize(width: 2048, height: 1249)

    func testGrowsAnOldSmallWindowToTheDefaultSize() {
        XCTAssertEqual(SettingsWindowCoordinator.enlargedContentSize(
            current: NSSize(width: 560, height: 520), visible: screen), NSSize(width: 680, height: 800))
    }

    func testKeepsAWindowThatIsAlreadyLargeEnough() {
        XCTAssertNil(SettingsWindowCoordinator.enlargedContentSize(
            current: NSSize(width: 900, height: 1000), visible: screen))
        // Only the smaller side grows.
        XCTAssertEqual(SettingsWindowCoordinator.enlargedContentSize(
            current: NSSize(width: 900, height: 520), visible: screen), NSSize(width: 900, height: 800))
    }

    func testNeverGrowsPastASmallScreen() {
        XCTAssertEqual(SettingsWindowCoordinator.enlargedContentSize(
            current: NSSize(width: 560, height: 520), visible: NSSize(width: 1280, height: 720)),
            NSSize(width: 680, height: 640))
    }
}
