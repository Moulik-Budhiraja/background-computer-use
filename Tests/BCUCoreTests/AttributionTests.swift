import XCTest
@testable import BCUCore

/// Who brought an app forward. Times are milliseconds, `now` is 10 000.
final class AttributionTests: XCTestCase {
    private let now = 10_000.0

    private func facts(step: Attribution.Step?, restoredAway: Double? = nil, mouseDown: Double = -1e9, switchKey: Double = -1e9,
                       openKey: Double = -1e9, arrivedElsewhere: Double = -1e9) -> Attribution.Facts {
        Attribution.Facts(nowMs: now, step: step, restoredAwayMs: restoredAway, lastMouseDownMs: mouseDown, lastSwitchKeyMs: switchKey,
                          lastOpenKeyMs: openKey, arrivedElsewhereMs: arrivedElsewhere)
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

    private func cause(userInApp: Bool, userInput: Double = -1e9, agentBegan: Double? = nil, settling: Bool = false) -> NewWindow.Cause {
        NewWindow.cause(NewWindow.Facts(firstSeenMs: seen, userInApp: userInApp, userOpenInputMs: userInput, agentBeganMs: agentBegan,
                                        stepSettling: settling))
    }

    // MARK: What an agent's step opened is the agent's

    /// An agent pressed a button 181 ms before a sign-in window came up
    /// beside its own. The user is in another app.
    func testAWindowAnAgentsStepOpenedIsTheAgents() {
        XCTAssertEqual(cause(userInApp: false, agentBegan: seen - 181, settling: true), .agent)
    }

    /// The same while the guard takes the user to be in that app, and they
    /// pressed Return 459 ms before, which was before the agent's step.
    func testAWindowAnAgentsStepOpenedIsntTheUsersForAKeyFromBeforeTheStep() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 459, agentBegan: seen - 181, settling: true), .agent)
    }

    /// The user is reading in the same browser and hasn't touched it for 20 s.
    func testAWindowAnAgentsStepOpenedIsTheAgentsWhileTheUserReadsInTheSameApp() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 20_000, agentBegan: seen - 200, settling: true), .agent)
    }

    /// The user pressed a shortcut in the same app between the agent's
    /// press and the window: either could have opened it, so it stays put.
    func testAWindowEitherCouldHaveOpenedStaysWhereItIs() {
        XCTAssertEqual(cause(userInApp: true, userInput: seen - 50, agentBegan: seen - 181, settling: true), .unclear)
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
