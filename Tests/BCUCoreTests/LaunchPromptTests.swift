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

/// A downloaded app the user has never opened: Gatekeeper asks them first
/// ("downloaded from the Internet", or "Not Opened" when it can't check
/// it), and an option to the launch doesn't stop it. Once they've opened
/// it, its quarantine mark says so (flag 0x40) and it opens without asking.
final class FirstLaunchTests: XCTestCase {
    func testADownloadedAppNeverOpenedAsks() {
        XCTAssertTrue(WindowManager.asksBeforeFirstLaunch(quarantine: "0081;6543a1b2;Safari;"))
        XCTAssertTrue(WindowManager.asksBeforeFirstLaunch(quarantine: "0083;6543a1b2;Safari;5D2F1A9E-0000-0000-0000-000000000000"))
    }

    func testAnAppTheUserHasOpenedDoesntAsk() {
        XCTAssertFalse(WindowManager.asksBeforeFirstLaunch(quarantine: "00c1;6543a1b2;Safari;"))
        XCTAssertFalse(WindowManager.asksBeforeFirstLaunch(quarantine: "01c3;6543a1b2;Safari;"))
    }

    func testAnAppWithNoQuarantineMarkDoesntAsk() {
        XCTAssertFalse(WindowManager.asksBeforeFirstLaunch(quarantine: nil))
    }

    /// A mark that can't be read is taken as one that asks.
    func testAnUnreadableMarkAsks() {
        XCTAssertTrue(WindowManager.asksBeforeFirstLaunch(quarantine: "zz;6543a1b2"))
        XCTAssertTrue(WindowManager.asksBeforeFirstLaunch(quarantine: ""))
    }
}
