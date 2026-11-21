import XCTest
@testable import BCUCore

/// An agent's open of an app that isn't running. macOS asks the user before
/// some launches (an Intel app with no Rosetta, a downloaded app Gatekeeper
/// hasn't checked, a damaged one), in an alert on the user's screen that
/// they never asked for. The launch is to fail instead, and the agent is
/// told why.
final class LaunchPromptTests: XCTestCase {
    func testAnAgentsLaunchNeverAsksTheUser() {
        XCTAssertFalse(WindowManager.launchConfiguration().promptsUserIfNeeded)
    }

    func testAnAgentsLaunchStaysHiddenAndInactive() {
        let config = WindowManager.launchConfiguration()
        XCTAssertFalse(config.activates)
        XCTAssertTrue(config.hides)
        XCTAssertFalse(config.addsToRecentItems)
    }
}
