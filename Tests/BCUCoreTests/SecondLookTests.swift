import XCTest
@testable import BCUCore

/// An agent's app that came forward during its step and was put down to a
/// click of the user's gets a second look. Times are milliseconds, `now` is 10 000.
final class SecondLookTests: XCTestCase {
    private let now = 10_000.0

    private func facts(step: Attribution.Step?, mouseDown: Double = -1e9, switchKey: Double = -1e9,
                       arrivedElsewhere: Double = -1e9) -> Attribution.Facts {
        Attribution.Facts(nowMs: now, step: step, restoredAwayMs: nil, lastMouseDownMs: mouseDown, lastSwitchKeyMs: switchKey,
                          lastOpenKeyMs: -1e9, arrivedElsewhereMs: arrivedElsewhere)
    }

    private var running: Attribution.Step { Attribution.Step(running: 1, settleUntilMs: .infinity, strict: false) }

    // MARK: When to look again

    /// The incident: the user clicked in Proactive Agent 381 ms before Helium
    /// came forward during an agent's open_window. The click made it the
    /// user's, so nothing put Proactive Agent back.
    func testAnAppCreditedToAClickDuringAStepGetsASecondLook() {
        XCTAssertFalse(Attribution.agentCaused(facts(step: running, mouseDown: now - 381)))
        XCTAssertTrue(SecondLook.wanted(facts(step: running, mouseDown: now - 381)))
    }

    /// cmd+Tab is a switch the user asked for: no second look.
    func testCmdTabIsntLookedAtAgain() {
        XCTAssertFalse(SecondLook.wanted(facts(step: running, mouseDown: now - 300, switchKey: now - 100)))
    }

    /// With no step on the app, the user came to it: nothing to look at.
    func testNoStepNoSecondLook() {
        XCTAssertFalse(SecondLook.wanted(facts(step: nil, mouseDown: now - 100)))
    }

    /// Already put down to the agent: the guard put the user's app back at once.
    func testAnAgentsActivationNeedsNoSecondLook() {
        XCTAssertFalse(SecondLook.wanted(facts(step: running)))
    }

    /// The user's own clicks drive the agent's window (the expanded view).
    func testStrictStepsArentLookedAtAgain() {
        let strict = Attribution.Step(running: 1, settleUntilMs: .infinity, strict: true)
        XCTAssertFalse(SecondLook.wanted(facts(step: strict, mouseDown: now - 100)))
    }

    // MARK: What the second look decides

    private func look(stillFront: Bool = true, clickInPrevious: Bool = true, inputSince: Bool = false, openedForUser: Bool = false) -> SecondLook.Facts {
        SecondLook.Facts(stillFront: stillFront, clickInPrevious: clickInPrevious, inputSince: inputSince, openedForUser: openedForUser)
    }

    func testAClickInTheirAppThatOpenedNothingPutsTheirAppBack() {
        XCTAssertTrue(SecondLook.restore(look()))
    }

    /// A link they clicked in their app opened in the browser: that's theirs.
    func testALinkThatOpenedInTheAppStays() {
        XCTAssertFalse(SecondLook.restore(look(openedForUser: true)))
    }

    /// They clicked the app's window or its Dock icon.
    func testAClickOnTheAppItselfStays() {
        XCTAssertFalse(SecondLook.restore(look(clickInPrevious: false)))
    }

    /// They've started using it.
    func testInputSinceStays() {
        XCTAssertFalse(SecondLook.restore(look(inputSince: true)))
    }

    /// Something else is in front by now.
    func testGoneFromTheFrontIsLeftAlone() {
        XCTAssertFalse(SecondLook.restore(look(stillFront: false)))
    }

    func testOpenedSeesNewWindowsAndNewTitles() {
        let before: [CGWindowID: String] = [1: "Home / X", 2: "Inbox"]
        XCTAssertFalse(SecondLook.opened(before: before, now: [1: "Home / X"]))
        XCTAssertTrue(SecondLook.opened(before: before, now: [1: "A page they opened"]))
        XCTAssertTrue(SecondLook.opened(before: before, now: [1: "Home / X", 3: "New window"]))
    }
}

/// Dock bounces from apps agents work in.
final class BounceTests: XCTestCase {
    /// Helium's file picker opening in the agent's window asks for attention.
    func testARequestRightAfterAnAgentsStepIsCancelled() {
        XCTAssertTrue(Bounce.quiet(userInApp: false, agentApp: true, sinceStepMs: 300, userWindows: 2))
    }

    /// The user is in the app: it's theirs to see.
    func testNotWhileTheUserIsInTheApp() {
        XCTAssertFalse(Bounce.quiet(userInApp: true, agentApp: true, sinceStepMs: 300, userWindows: 2))
    }

    /// Long after the agent's last step, in an app the user has windows in
    /// (a download of theirs finished): left alone.
    func testALateRequestInAnAppWithTheUsersWindowsIsLeftAlone() {
        XCTAssertFalse(Bounce.quiet(userInApp: false, agentApp: true, sinceStepMs: 60_000, userWindows: 2))
        XCTAssertFalse(Bounce.quiet(userInApp: false, agentApp: true, sinceStepMs: nil, userWindows: 1))
    }

    /// With no window of the user's, there's nothing in it for them.
    func testAnAppWithOnlyAgentWindowsIsAlwaysQuiet() {
        XCTAssertTrue(Bounce.quiet(userInApp: false, agentApp: true, sinceStepMs: nil, userWindows: 0))
    }

    func testAppsNoAgentWorksInAreLeftAlone() {
        XCTAssertFalse(Bounce.quiet(userInApp: false, agentApp: false, sinceStepMs: 100, userWindows: 0))
    }
}
