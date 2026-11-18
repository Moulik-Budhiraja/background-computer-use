import XCTest
@testable import BCUCore

/// Which menu item `open_window` presses for a new window.
final class NewWindowMenuTests: XCTestCase {
    private func rank(_ title: String, _ key: String = "", _ mods: Int = 0) -> Int? {
        WindowManager.newWindowRank(title: title, key: key, modifiers: mods)
    }

    func testWindowItems() {
        XCTAssertEqual(rank("New Window", "N"), 0)
        XCTAssertEqual(rank("New Window", "N", 1), 0)      // Paper: shift+cmd+N
        XCTAssertEqual(rank("New Finder Window", "N"), 1)
        XCTAssertEqual(rank("New Viewer Window", "N", 2), 1) // Mail: option+cmd+N
        XCTAssertEqual(rank("Open Window", "N"), 1)
        XCTAssertEqual(rank("New", "N"), 2)                  // TextEdit
        XCTAssertEqual(rank("New Document", "N"), 2)
    }

    /// cmd+N items that act inside the window that has key, often the user's.
    func testItemsThatAreNotWindows() {
        for title in ["New Chat", "New Message", "New Note", "New Event", "New Reminder", "New Thread", "New Tab", "New File"] {
            XCTAssertNil(rank(title, "N"), title)
        }
        XCTAssertNil(rank("New Private Window", "N", 1))
        XCTAssertNil(rank("New Incognito Window", "N", 1))
        XCTAssertNil(rank("New", "N", 1))                    // shift+cmd+N "New" isn't the document one
    }
}
