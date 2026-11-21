import XCTest
@testable import BCUCore

/// The user has an app's window full screen and is in it. With macOS's
/// default tab preference ("Prefer tabs when opening documents: In Full
/// Screen") the app opens any new window as a tab in that window, on the
/// user's screen, and the agent's typing shows there.
final class FullScreenTabTests: XCTestCase {
    func testANewWindowIsATabInTheFullScreenWindowByDefault() {
        XCTAssertTrue(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: nil))
        XCTAssertTrue(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: "fullscreen"))
        XCTAssertTrue(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: "always"))
    }

    /// "Never": the new window is a window of its own.
    func testWithTabsOffItIsntATab() {
        XCTAssertFalse(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: "manual"))
    }

    func testWithNoFullScreenWindowItIsntATab() {
        XCTAssertFalse(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: false, tabbingMode: nil))
        XCTAssertFalse(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: false, tabbingMode: "fullscreen"))
    }
}
