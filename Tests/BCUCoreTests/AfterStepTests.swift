import XCTest
@testable import BCUCore

/// What becomes of key after an agent's step in an app the user isn't in.
final class AfterStepTests: XCTestCase {
    /// With nothing open in the agent's window, key goes to the user's window:
    /// a browser sends links opened from other apps to the window that last
    /// had key, and the user's link would land in the agent's hidden window.
    func testKeyGoesToTheUsersWindowWithNothingOpen() {
        XCTAssertEqual(KeyScope.afterStep(popupOpen: false, userWindow: 7), .handTo(7))
    }

    /// A menu, dropdown or suggestion list closes when its window loses key,
    /// and the agent's next step would find it gone.
    func testKeyStaysWithAPopupOpen() {
        XCTAssertEqual(KeyScope.afterStep(popupOpen: true, userWindow: 7), .park)
    }

    /// No window of the user's in the app: nothing to give key to.
    func testKeyStaysWithNoWindowOfTheUsers() {
        XCTAssertEqual(KeyScope.afterStep(popupOpen: false, userWindow: nil), .park)
    }
}
