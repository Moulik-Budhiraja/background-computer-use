import XCTest
@testable import BCUCore

/// While the screen is locked (or the display sleeps and locks it), macOS
/// gives accessibility clients the app in place of each of its windows: no
/// window ids, no frames. open_window then left TextEdit's new window on
/// the user's screen and said TextEdit "may not support multiple windows",
/// and every step in a Helium window said Helium "isn't answering".
final class LockedScreenTests: XCTestCase {
    func testOpeningAWindowWhileLockedSaysTheScreenIsLocked() {
        let text = Engine.lockedRefusal(tool: "open_window", window: false, locked: true)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("locked") == true)
        XCTAssertFalse(text?.contains("borrow_window") == true)
    }

    func testStepsInAWindowWhileLockedSayTheScreenIsLocked() {
        for tool in ["get_window_state", "navigate", "click", "type_text", "release_window"] {
            XCTAssertTrue(Engine.lockedRefusal(tool: tool, window: true, locked: true)?.contains("locked") == true, tool)
        }
        XCTAssertNotNil(Engine.lockedRefusal(tool: "borrow_window", window: false, locked: true))
    }

    /// Tools that don't reach any window still answer.
    func testStatusAndListsStillWorkWhileLocked() {
        for tool in ["status", "list_apps", "list_windows"] {
            XCTAssertNil(Engine.lockedRefusal(tool: tool, window: false, locked: true), tool)
        }
    }

    func testNothingIsRefusedWhenUnlocked() {
        XCTAssertNil(Engine.lockedRefusal(tool: "open_window", window: false, locked: false))
        XCTAssertNil(Engine.lockedRefusal(tool: "click", window: true, locked: false))
    }
}
