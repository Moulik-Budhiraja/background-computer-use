import XCTest
@testable import BCUCore

/// Whether an agent's step answers a "Leave site?" that came up after it
/// began (a navigate, or a click on a link that leaves the page). The step
/// began at 10 000 ms.
final class LeaveDialogTests: XCTestCase {
    private let began = 10_000.0

    /// The user is in another app: the dialog is the agent's page asking.
    func testTheAgentsDialogIsAnsweredWhileTheUserIsElsewhere() {
        XCTAssertTrue(WindowManager.stepAnswersLeave(userInApp: false, userOpenInputMs: began + 50, stepStartMs: began))
    }

    /// The user is in the browser but hasn't clicked or pressed an opening
    /// key since the step began: nothing of theirs could have asked.
    func testTheAgentsDialogIsAnsweredWhenTheUserInTheBrowserDidNothingSince() {
        XCTAssertTrue(WindowManager.stepAnswersLeave(userInApp: true, userOpenInputMs: began - 1, stepStartMs: began))
    }

    /// The user clicked in the browser after the step began: the dialog
    /// may be about their own page, so it's left for them.
    func testADialogThatMayBeTheUsersIsLeftAlone() {
        XCTAssertFalse(WindowManager.stepAnswersLeave(userInApp: true, userOpenInputMs: began + 30, stepStartMs: began))
    }
}
