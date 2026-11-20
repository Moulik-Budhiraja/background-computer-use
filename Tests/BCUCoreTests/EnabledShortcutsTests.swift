import XCTest
import CoreGraphics
@testable import BCUCore

/// Which system shortcuts skip the hold, by the user's Keyboard Shortcuts.
final class EnabledShortcutsTests: XCTestCase {
    let ctrlLeft: CGEventFlags = [.maskControl, .maskNumericPad, .maskSecondaryFn]

    /// With "Move left a space" turned off, ctrl+left goes to the app, so
    /// it must be held like any other key.
    func testATurnedOffShortcutIsHeld() {
        let enabled = FocusGuard.enabledShortcuts(["79": ["enabled": false]])
        XCTAssertFalse(FocusGuard.systemShortcut(code: 123, flags: ctrlLeft, enabled: enabled))
        XCTAssertTrue(FocusGuard.systemShortcut(code: 124, flags: ctrlLeft, enabled: enabled))
    }

    /// Mission Control moved to ctrl+cmd+up: that chord goes to macOS, and
    /// ctrl+up to the app.
    func testAChangedShortcutGoesByItsNewChord() {
        let ctrlCmd = CGEventFlags([.maskControl, .maskCommand]).rawValue
        let entry: [String: Any] = ["enabled": true, "value": ["type": "standard", "parameters": [65535, 126, ctrlCmd | CGEventFlags.maskSecondaryFn.rawValue]]]
        let enabled = FocusGuard.enabledShortcuts(["32": entry])
        XCTAssertTrue(FocusGuard.systemShortcut(code: 126, flags: [.maskControl, .maskCommand, .maskSecondaryFn], enabled: enabled))
        XCTAssertFalse(FocusGuard.systemShortcut(code: 126, flags: [.maskControl, .maskSecondaryFn], enabled: enabled))
    }

    func testNeverChangedMeansTheDefaults() {
        let enabled = FocusGuard.enabledShortcuts(nil)
        XCTAssertTrue(FocusGuard.systemShortcut(code: 49, flags: .maskCommand, enabled: enabled))
        XCTAssertTrue(FocusGuard.systemShortcut(code: 123, flags: ctrlLeft, enabled: enabled))
    }
}
