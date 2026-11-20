import XCTest
@testable import BCUCore

/// Whether `navigate` answers a "Leave site?" that came up while it loaded a
/// URL. The URL was sent at 10 000 ms.
final class NavigateLeaveTests: XCTestCase {
    private let sent = 10_000.0

    /// The user is in another app: the dialog is the agent's page asking.
    func testTheAgentsDialogIsAnsweredWhileTheUserIsElsewhere() {
        XCTAssertTrue(WindowManager.navigateAnswersLeave(userInApp: false, userOpenInputMs: sent + 50, sentMs: sent))
    }

    /// The user is in the browser but hasn't clicked or pressed an opening
    /// key since the URL was sent: nothing of theirs could have asked.
    func testTheAgentsDialogIsAnsweredWhenTheUserInTheBrowserDidNothingSince() {
        XCTAssertTrue(WindowManager.navigateAnswersLeave(userInApp: true, userOpenInputMs: sent - 1, sentMs: sent))
    }

    /// The user clicked in the browser after the URL was sent: the dialog
    /// may be about their own page, so it's left for them.
    func testADialogThatMayBeTheUsersIsLeftAlone() {
        XCTAssertFalse(WindowManager.navigateAnswersLeave(userInApp: true, userOpenInputMs: sent + 30, sentMs: sent))
    }
}
