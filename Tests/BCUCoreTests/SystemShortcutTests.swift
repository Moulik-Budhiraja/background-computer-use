import XCTest
import CoreGraphics
@testable import BCUCore

/// Keys the guard lets through to macOS while it holds a stranded app's keys.
final class SystemShortcutTests: XCTestCase {
    func testAppSwitcherGoesThrough() {
        XCTAssertTrue(FocusGuard.systemShortcut(code: 48, flags: .maskCommand))
    }

    /// Spotlight, input source switching, Mission Control and Spaces. Held
    /// while an app stays stranded, they'd be dropped and never open.
    func testSpotlightAndMissionControlGoThrough() {
        XCTAssertTrue(FocusGuard.systemShortcut(code: 49, flags: .maskCommand))
        XCTAssertTrue(FocusGuard.systemShortcut(code: 49, flags: .maskControl))
        XCTAssertTrue(FocusGuard.systemShortcut(code: 126, flags: [.maskControl, .maskNumericPad, .maskSecondaryFn]))
        XCTAssertTrue(FocusGuard.systemShortcut(code: 123, flags: [.maskControl, .maskNumericPad, .maskSecondaryFn]))
        XCTAssertTrue(FocusGuard.systemShortcut(code: 160, flags: []))
        XCTAssertTrue(FocusGuard.systemShortcut(code: 53, flags: [.maskCommand, .maskAlternate]))
    }

    /// Typing and app shortcuts would reach the agent's window.
    func testAppKeysAreHeld() {
        XCTAssertFalse(FocusGuard.systemShortcut(code: 13, flags: .maskCommand))
        XCTAssertFalse(FocusGuard.systemShortcut(code: 0, flags: []))
        XCTAssertFalse(FocusGuard.systemShortcut(code: 49, flags: []))
        XCTAssertFalse(FocusGuard.systemShortcut(code: 126, flags: [.maskNumericPad, .maskSecondaryFn]))
        XCTAssertFalse(FocusGuard.systemShortcut(code: 53, flags: []))
    }
}
