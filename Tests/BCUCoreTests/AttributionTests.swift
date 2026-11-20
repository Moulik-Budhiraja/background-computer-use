import XCTest
@testable import BCUCore

/// Who brought an app forward. Times are milliseconds, `now` is 10 000.
final class AttributionTests: XCTestCase {
    private let now = 10_000.0

    private func facts(step: Attribution.Step?, restoredAway: Double? = nil, mouseDown: Double = -1e9, switchKey: Double = -1e9,
                       openKey: Double = -1e9, arrivedElsewhere: Double = -1e9, clickOnApp: Bool = true) -> Attribution.Facts {
        Attribution.Facts(nowMs: now, step: step, restoredAwayMs: restoredAway, lastMouseDownMs: mouseDown, lastSwitchKeyMs: switchKey,
                          lastOpenKeyMs: openKey, arrivedElsewhereMs: arrivedElsewhere, clickOnApp: clickOnApp)
    }

    private var running: Attribution.Step { Attribution.Step(running: 1, settleUntilMs: .infinity, strict: false) }
    private func settling(left ms: Double) -> Attribution.Step { Attribution.Step(running: 0, settleUntilMs: now + ms, strict: false) }

    // MARK: One switch explains one front change

    /// The user pressed cmd+Tab 315 ms ago and arrived in their editor 246 ms
    /// ago. The browser an agent's step is loading a page in comes forward
    /// now: the cmd+Tab was already answered, so this is the agent's.
    func testAnAppComingForwardAfterTheUsersSwitchWasAnsweredIsTheAgents() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: running, switchKey: now - 315, openKey: now - 315, arrivedElsewhere: now - 246)))
    }

    /// The same with a click: they clicked their editor's window, arrived
    /// there, and then the agent's app came forward.
    func testAnAppComingForwardAfterTheUsersClickWasAnsweredIsTheAgents() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: running, mouseDown: now - 300, arrivedElsewhere: now - 270)))
    }

    /// And when the guard had just put their app back in front of it.
    func testAnAppComingForwardAgainAfterTheUsersSwitchWasAnsweredIsTheAgents() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: nil, restoredAway: now - 200, switchKey: now - 350, arrivedElsewhere: now - 290)))
    }

    // MARK: Keys that could open an app aren't evidence

    /// An agent pressed a button 81 ms ago (its step is over, 619 ms of its
    /// settle time left) and the page opened a sign-in window, so the
    /// browser comes forward. The user pressed Return in their own app
    /// 367 ms ago. That Return doesn't make it theirs.
    func testAReturnInTheUsersOwnAppDoesntExplainTheAgentsAppComingForward() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: settling(left: 619), restoredAway: now - 5237, mouseDown: now - 68_396, openKey: now - 367)))
    }

    /// The browser's second try at the front, 650 ms after the step, while
    /// the user is using shortcuts in their own app.
    func testAShortcutDoesntExplainTheAgentsAppComingForwardLate() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: settling(left: 50), openKey: now - 120)))
    }

    // MARK: Only a click on the app explains it

    /// The user clicked in their editor 205 ms before the browser came
    /// forward during an agent's open_window. The click was in the editor,
    /// so it says nothing about the browser: it goes back.
    func testAClickInTheUsersOwnAppDoesntExplainTheAgentsAppComingForward() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: running, mouseDown: now - 205, clickOnApp: false)))
    }

    /// A click in the app that started the agent, 236 ms before its page
    /// load brought the browser forward.
    func testAClickInTheAppThatStartedTheAgentDoesntExplainIt() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: running, mouseDown: now - 236, clickOnApp: false)))
    }

    /// The same just after the guard had put their app back once.
    func testAClickElsewhereDoesntExplainTheAppComingForwardAgain() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: nil, restoredAway: now - 300, mouseDown: now - 150, clickOnApp: false)))
    }

    /// cmd+Tab is still a switch they asked for, wherever they last clicked.
    func testCmdTabIsTheirsWhereverTheyLastClicked() {
        XCTAssertFalse(Attribution.agentCaused(facts(step: running, mouseDown: now - 200, switchKey: now - 50, clickOnApp: false)))
    }

    func testWhereAClickLandedSaysWhichAppItExplains() {
        XCTAssertTrue(ClickTarget.app(42).explains(42))
        XCTAssertFalse(ClickTarget.app(7).explains(42))
        XCTAssertFalse(ClickTarget.app(nil).explains(42))
        XCTAssertTrue(ClickTarget.dock(42).explains(42))
        XCTAssertFalse(ClickTarget.dock(7).explains(42))
        XCTAssertFalse(ClickTarget.dock(0).explains(42))
        // A Dock icon accessibility couldn't name may have been the app's.
        XCTAssertTrue(ClickTarget.dock(nil).explains(42))
        // Not known yet: the old rule.
        XCTAssertTrue(ClickTarget.pending.explains(42))
    }

    func testWhatWasClickedIsALinkWhenAnythingAroundItIsOne() {
        XCTAssertEqual(ClickElement.classify(roles: ["AXStaticText", "AXLink", "AXGroup"], url: false), .link)
        XCTAssertEqual(ClickElement.classify(roles: ["AXStaticText", "AXGroup"], url: true), .link)
        XCTAssertEqual(ClickElement.classify(roles: ["AXButton", "AXGroup"], url: false), .other("AXButton"))
        XCTAssertEqual(ClickElement.classify(roles: ["AXGroup", "AXWindow"], url: false), .unknown)
        XCTAssertEqual(ClickElement.classify(roles: [], url: false), .unknown)
    }

    // MARK: What was right before stays right

    func testTheUsersCmdTabToTheAgentsAppIsTheirs() {
        XCTAssertFalse(Attribution.agentCaused(facts(step: running, switchKey: now - 60, openKey: now - 60, arrivedElsewhere: now - 9000)))
    }

    func testTheUsersClickOnTheAgentsAppIsTheirs() {
        XCTAssertFalse(Attribution.agentCaused(facts(step: running, mouseDown: now - 100, arrivedElsewhere: now - 9000)))
    }

    /// They arrive somewhere and at once switch again, to the agent's app:
    /// the second cmd+Tab came after the arrival, so it's unanswered.
    func testASecondSwitchRightAfterArrivingIsTheirs() {
        XCTAssertFalse(Attribution.agentCaused(facts(step: running, switchKey: now - 60, arrivedElsewhere: now - 300)))
    }

    func testTheUsersClickJustAfterTheGuardPutTheirAppBackIsTheirs() {
        XCTAssertFalse(Attribution.agentCaused(facts(step: nil, restoredAway: now - 150, mouseDown: now - 40)))
    }

    func testWithNothingFromTheUserAStepsAppComingForwardIsTheAgents() {
        XCTAssertTrue(Attribution.agentCaused(facts(step: running)))
        XCTAssertTrue(Attribution.agentCaused(facts(step: settling(left: 500))))
        XCTAssertTrue(Attribution.agentCaused(facts(step: nil, restoredAway: now - 500)))
    }

    func testAnAppNoAgentIsActingOnIsNeverTheAgents() {
        XCTAssertFalse(Attribution.agentCaused(facts(step: nil)))
        XCTAssertFalse(Attribution.agentCaused(facts(step: settling(left: -1))))
        XCTAssertFalse(Attribution.agentCaused(facts(step: nil, restoredAway: now - 1500)))
    }

    /// The user drives the agent's window from the expanded view: their
    /// clicks are the step, and say nothing.
    func testAClickDuringTheUsersOwnStepInTheExpandedViewSaysNothing() {
        let strict = Attribution.Step(running: 1, settleUntilMs: .infinity, strict: true)
        XCTAssertTrue(Attribution.agentCaused(facts(step: strict, mouseDown: now - 50)))
        XCTAssertFalse(Attribution.agentCaused(facts(step: strict, switchKey: now - 50)))
    }
}

/// Whose a window is that came up on an agent display unasked. Times are
/// milliseconds, the window was first seen at 10 000.
final class NewWindowTests: XCTestCase {
    private let seen = 10_000.0

    private func cause(userInApp: Bool, userInput: Double = -1e9, agentBegan: Double? = nil) -> NewWindow.Cause {
        NewWindow.cause(NewWindow.Facts(firstSeenMs: seen, userInApp: userInApp, userOpenInputMs: userInput, agentBeganMs: agentBegan))
    }

    // MARK: What an agent's step opened is the agent's

    /// An agent pressed a button 181 ms before a sign-in window came up
    /// beside its own. The user is in another app.
    func testAWindowAnAgentsStepOpenedIsTheAgents() {
        XCTAssertEqual(cause(userInApp: false, agentBegan: seen - 181), .agent)
    }

    /// The same while the guard takes the user to be in that app, and they
    /// pressed Return 459 ms before, which was before the agent's step.
    func testAWindowAnAgentsStepOpenedIsntTheUsersForAKeyFromBeforeTheStep() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 459, agentBegan: seen - 181), .agent)
    }

    /// The user is reading in the same browser and hasn't touched it for 20 s.
    func testAWindowAnAgentsStepOpenedIsTheAgentsWhileTheUserReadsInTheSameApp() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 20_000, agentBegan: seen - 200), .agent)
    }

    /// The user pressed a shortcut in the same app between the agent's
    /// press and the window: either could have opened it. It goes to the
    /// user. A window of theirs left on the agent display can't be seen,
    /// and what they type next goes into it. Waiting for the step to end
    /// says nothing new, and a long step would leave it there for good.
    func testAWindowEitherCouldHaveOpenedGoesToTheUser() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 50, agentBegan: seen - 181), .user)
    }

    // MARK: What the user opened is still theirs

    /// The agent typed in its document 3 s ago; the user presses cmd+N.
    func testAWindowTheUserOpensAfterAnAgentsStepIsOverIsTheirs() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 200, agentBegan: seen - 3000), .user)
    }

    /// A document that takes 2.5 s to open after their click.
    func testAWindowThatOpensSlowlyAfterTheUsersClickIsTheirs() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 2500, agentBegan: seen - 3000), .user)
    }

    func testAWindowInTheUsersAppWithNoAgentStepIsTheirs() {
        XCTAssertEqual(cause(userInApp: true), .user)
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 200), .user)
    }

    /// The step was long ago, or the window was there first.
    func testAnOldStepExplainsNothing() {
        XCTAssertEqual(cause(userInApp: true, agentBegan: seen - 10_001), .user)
        XCTAssertEqual(cause(userInApp: true, agentBegan: seen + 5), .user)
        XCTAssertEqual(cause(userInApp: false, agentBegan: seen - 10_001), .unclear)
    }

    func testAWindowNobodyExplainsStaysWhereItIs() {
        XCTAssertEqual(cause(userInApp: false), .unclear)
        XCTAssertEqual(cause(userInApp: false, userInput: seen - 100), .unclear)
    }
}

/// Whose a window is that came up on the user's screen, in an app the
/// session acted on. `.agent` moves it to the agent display. Times are
/// milliseconds, the window was first seen at 10 000.
final class NewWindowOnUserScreenTests: XCTestCase {
    private let seen = 10_000.0

    private func verdict(userInApp: Bool, userInput: Double = -1e9, agentBegan: Double?, age: Double = 0) -> NewWindow.Cause? {
        NewWindow.fromUserScreen(NewWindow.Facts(firstSeenMs: seen, userInApp: userInApp, userOpenInputMs: userInput, agentBeganMs: agentBegan),
                               nowMs: seen + age)
    }

    /// An agent pressed Save in a browser's print preview. The press took
    /// 6 ms, and the Save panel came up about a second later, after the
    /// step's grace period, on the user's screen. The user is in another
    /// app and hasn't touched anything since.
    func testASavePanelThatComesUpAfterTheStepEndedIsTheAgents() {
        XCTAssertEqual(verdict(userInApp: false, agentBegan: seen - 1200), .agent)
    }

    /// The same while the user reads in that browser, with no click or
    /// opening key since the agent's step began.
    func testAWindowAnAgentsStepOpenedLeavesTheUsersScreenWhileTheyReadInThatApp() {
        XCTAssertEqual(verdict(userInApp: true, userInput: seen - 20_000, agentBegan: seen - 1200), .agent)
    }

    /// The user clicked in another app 100 ms before the window came up:
    /// the click may have opened it (a link), and the guard learns a moment
    /// later whether it brought them to the app. Until then it waits.
    func testItWaitsForTheGuardAfterAFreshClick() {
        XCTAssertNil(verdict(userInApp: false, userInput: seen - 100, agentBegan: seen - 1200))
        XCTAssertEqual(verdict(userInApp: false, userInput: seen - 100, agentBegan: seen - 1200, age: 300), .agent)
    }

    /// A click from 2 s ago, though after the step began, has already
    /// shown up in where the guard takes the user to be.
    func testAnOlderClickElsewhereDoesntHoldItBack() {
        XCTAssertEqual(verdict(userInApp: false, userInput: seen - 2000, agentBegan: seen - 3000), .agent)
    }

    /// The user is in the app and clicked or pressed a shortcut there since
    /// the step began: either could have opened it, so it stays with them.
    func testAWindowEitherCouldHaveOpenedStaysWithTheUser() {
        XCTAssertEqual(verdict(userInApp: true, userInput: seen - 500, agentBegan: seen - 1200), .user)
    }

    /// No step of the session's on the app, a step long ago, or a window
    /// that was there before the step.
    func testNoStepToExplainItLeavesItAlone() {
        XCTAssertNotEqual(verdict(userInApp: false, agentBegan: nil), .agent)
        XCTAssertNotEqual(verdict(userInApp: false, agentBegan: seen - 10_001), .agent)
        XCTAssertNotEqual(verdict(userInApp: false, agentBegan: seen + 5), .agent)
        XCTAssertEqual(verdict(userInApp: true, agentBegan: nil), .user)
    }
}
