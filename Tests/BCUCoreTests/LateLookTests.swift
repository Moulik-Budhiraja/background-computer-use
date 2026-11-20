import XCTest
@testable import BCUCore

/// An agent's app the guard put back though the user had just clicked
/// elsewhere, in case the click opened something in it.
final class LateLookTests: XCTestCase {
    private func facts(front: Bool = false, inputSince: Bool = false, opened: CGWindowID? = 7) -> LateLook.Facts {
        LateLook.Facts(front: front, inputSince: inputSince, opened: opened)
    }

    /// A link they clicked in their chat app opened in the browser: it comes forward with that window.
    func testALinkThatOpenedInTheAppBringsItForward() {
        XCTAssertEqual(LateLook.bringForward(facts()), 7)
    }

    /// The click opened nothing there.
    func testNothingOpenedLeavesItBack() {
        XCTAssertNil(LateLook.bringForward(facts(opened: nil)))
    }

    /// They've clicked or typed since: they moved on.
    func testInputSinceLeavesItBack() {
        XCTAssertNil(LateLook.bringForward(facts(inputSince: true)))
    }

    /// It's in front already (they went to it).
    func testAlreadyInFrontIsLeftAlone() {
        XCTAssertNil(LateLook.bringForward(facts(front: true)))
    }

    /// They clicked a link at 1000 and went on typing in their app at 1080;
    /// the browser came forward and was put back at 1150. They've moved
    /// on: bringing the browser forward now would take their typing.
    func testTypingSinceTheClickCountsEvenBeforeThePutBack() {
        XCTAssertTrue(LateLook.inputSince(clickMs: 1000, putBackMs: 1150, mouseDownMs: 1000, keyMs: 1080))
        XCTAssertTrue(LateLook.inputSince(clickMs: 1000, putBackMs: 1150, mouseDownMs: 1200, keyMs: 0))
        XCTAssertFalse(LateLook.inputSince(clickMs: 1000, putBackMs: 1150, mouseDownMs: 1000, keyMs: 900))
    }

    func testOnlyClicksThatCouldOpenSomethingAreLookedAt() {
        XCTAssertTrue(LateLook.wanted(.link))
        XCTAssertTrue(LateLook.wanted(.unknown))
        XCTAssertTrue(LateLook.wanted(nil))
        XCTAssertFalse(LateLook.wanted(.other("AXButton")))
    }

    func testOpenedSeesNewWindowsAndNewTitles() {
        let before: [CGWindowID: String] = [1: "Home / X", 2: "Inbox"]
        XCTAssertNil(LateLook.opened(before: before, now: [1: "Home / X"]))
        XCTAssertEqual(LateLook.opened(before: before, now: [1: "A page they opened"]), 1)
        XCTAssertEqual(LateLook.opened(before: before, now: [1: "Home / X", 3: "New window"]), 3)
    }

    /// No look from before the click: nothing is brought forward on a guess.
    func testWithNoLookFromBeforeNothingCountsAsOpened() {
        XCTAssertNil(LateLook.opened(before: nil, now: [1: "Home / X"]))
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
