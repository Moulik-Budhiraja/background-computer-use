import AppKit
import XCTest
@testable import BCUCore

/// A key or button that's down isn't always one that's held: while typing a
/// key is down about 40% of the time. Only a hold stops a step at the cap.
final class QuietTests: XCTestCase {
    private func snapshot(_ change: (inout UserActivity.Snapshot) -> Void) -> UserActivity.Snapshot {
        var s = UserActivity.Snapshot()
        change(&s)
        return s
    }

    func testKeyDownMidKeystrokeIsNotHeld() {
        let s = snapshot { $0.keysDown = [0]; $0.keyDownAtMs = [0: 1000] }
        XCTAssertFalse(QuietWait.holding(s, now: 1060))
        // It still counts as "not quiet yet", so a step waits for it to come up.
        XCTAssertNotNil(QuietWait.focusSensitive(s, menuOpen: false))
    }

    func testKeyDownForLongIsHeld() {
        let s = snapshot { $0.keysDown = [0]; $0.keyDownAtMs = [0: 1000] }
        XCTAssertTrue(QuietWait.holding(s, now: 1000 + QuietRules.heldMs + 1))
    }

    func testModifierKeptDownIsHeld() {
        let s = snapshot { $0.modifiersDown = true; $0.modifiersDownAtMs = 1000 }
        XCTAssertFalse(QuietWait.holding(s, now: 1100))
        XCTAssertTrue(QuietWait.holding(s, now: 2000))
    }

    func testClickIsNotHeldButDragIs() {
        let s = snapshot { $0.buttonsDown = 1; $0.buttonsDownAtMs = 1000 }
        XCTAssertFalse(QuietWait.holding(s, now: 1070))
        XCTAssertTrue(QuietWait.holding(s, now: 1600))
    }

    func testNothingDownIsNotHeld() {
        XCTAssertFalse(QuietWait.holding(UserActivity.Snapshot(), now: 5000))
    }
}

/// The user's typing goes first: a step that takes key focus in their app
/// doesn't start while they type, whatever the caps say.
/// Keys going down every `everyMs` for `forMs`, as the event tap would report them.
private func type(into activity: UserActivity, forMs: Double, everyMs: Double = 80) {
    DispatchQueue.global().async {
        let end = nowMs() + forMs
        while nowMs() < end {
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                activity.note(.keyDown, down)
                sleepMs(30)
                activity.note(.keyUp, up)
            }
            sleepMs(everyMs - 30)
        }
    }
}

final class TypingFirstTests: XCTestCase {
    override func setUp() { QuietRules.safeTyping = true }

    func testAStepWaitsForTypingToStopPastBothCaps() {
        let activity = UserActivity()
        type(into: activity, forMs: 900)
        sleepMs(50)
        let r = QuietWait.wait(activity, pid: 0, softMs: 100, hardMs: 200)
        XCTAssertEqual(r.outcome, .quiet)
        // Typing ended about 850 ms in; quiet is `typingMs` after the last key.
        XCTAssertGreaterThan(r.waitedMs, 700 + QuietRules.typingMs)
        XCTAssertEqual(r.reason, QuietWait.typingReason)
        // None of it counts against the session's budget for waiting.
        XCTAssertLessThan(r.countedMs, 100)
    }

    func testAStepFailsRatherThanCutInWhenTypingOutlastsItsPatience() {
        let activity = UserActivity()
        type(into: activity, forMs: 1500)
        sleepMs(50)
        let start = nowMs()
        let r = QuietWait.wait(activity, pid: 0, softMs: 100, hardMs: 200, giveUpAtMs: start + 400)
        XCTAssertEqual(r.outcome, .typing)
        XCTAssertGreaterThan(r.waitedMs, 380)
        XCTAssertLessThan(r.waitedMs, 700)
    }

    func testAStepThatCannotWaitStillWaitsForTyping() {
        let activity = UserActivity()
        type(into: activity, forMs: 300)
        sleepMs(50)
        let r = QuietWait.wait(activity, pid: 0, softMs: 0, hardMs: 0, typingOnly: true)
        XCTAssertEqual(r.outcome, .quiet)
        XCTAssertGreaterThan(r.waitedMs, 150 + QuietRules.typingMs)
    }

    func testAStepThatCannotWaitDoesNotWaitForAClick() {
        let activity = UserActivity()
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left) {
            activity.note(.leftMouseUp, up)
        }
        let r = QuietWait.wait(activity, pid: 0, softMs: 5000, hardMs: 5000, typingOnly: true)
        XCTAssertEqual(r.outcome, .quiet)
        XCTAssertLessThan(r.waitedMs, 50)
    }

    func testTypingIsOverOnlyAfterTheGapsInsideTyping() {
        var s = UserActivity.Snapshot()
        s.lastKeyDownMs = 10_000
        // 20 words a minute is a key every 600 ms: still typing.
        XCTAssertTrue(QuietWait.typing(s, now: 10_600))
        XCTAssertFalse(QuietWait.typing(s, now: 10_000 + QuietRules.typingMs + 1))
    }
}

/// "Safe typing" turned off in Settings: typing is waited for like any other
/// input, up to the caps, and the step then goes in between two keystrokes.
final class SafeTypingOffTests: XCTestCase {
    override func setUp() { QuietRules.safeTyping = false }
    override func tearDown() { QuietRules.safeTyping = true }

    func testAStepGoesInAtTheCapWhileTheUserStillTypes() {
        let activity = UserActivity()
        type(into: activity, forMs: 1500)
        sleepMs(50)
        let start = nowMs()
        // Patience is for the typing-first rule: here it changes nothing.
        let r = QuietWait.wait(activity, pid: 0, softMs: 300, hardMs: 400, giveUpAtMs: start + 100)
        XCTAssertEqual(r.outcome, .cap)
        XCTAssertGreaterThan(r.waitedMs, 380)
        XCTAssertLessThan(r.waitedMs, 800)
        XCTAssertEqual(r.reason, QuietWait.typingReason)
        // And the wait counts against the session's budget, as a click's does.
        XCTAssertGreaterThan(r.countedMs, 380)
    }

    func testAStepThatCannotWaitRunsAtOnce() {
        let activity = UserActivity()
        type(into: activity, forMs: 600)
        sleepMs(50)
        let r = QuietWait.wait(activity, pid: 0, softMs: 5000, hardMs: 5000, typingOnly: true)
        XCTAssertEqual(r.outcome, .quiet)
        XCTAssertLessThan(r.waitedMs, 50)
    }

    func testAShortPauseIsEnoughToStartIn() {
        var s = UserActivity.Snapshot()
        s.lastKeyDownMs = 10_000
        XCTAssertTrue(QuietWait.typing(s, now: 10_300))
        XCTAssertFalse(QuietWait.typing(s, now: 10_600))
    }

    func testTurningItOffEndsAWaitForTyping() {
        QuietRules.safeTyping = true
        let activity = UserActivity()
        type(into: activity, forMs: 2000)
        sleepMs(50)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { QuietRules.safeTyping = false }
        let r = QuietWait.wait(activity, pid: 0, softMs: 100, hardMs: 200)
        // Off at 300 ms; the caps then count from there.
        XCTAssertEqual(r.outcome, .cap)
        XCTAssertGreaterThan(r.waitedMs, 450)
        XCTAssertLessThan(r.waitedMs, 1000)
    }
}

/// The gate must tell its own list of permitted apps from someone else's
/// (a kiosk or exam app's), which it never touches.
final class FrontGateTests: XCTestCase {
    private func apps(_ ids: [Int]) -> [CFTypeRef] { ids.map { NSNumber(value: $0) } }

    func testSameListIsOurs() {
        XCTAssertTrue(FrontGate.isOurs(apps([1, 2, 3, 4]), set: apps([1, 2, 3, 4])))
    }

    func testListWithoutAppsThatQuitIsStillOurs() {
        XCTAssertTrue(FrontGate.isOurs(apps([1, 2, 4]), set: apps([1, 2, 3, 4])))
    }

    func testListNamingAnAppWeDidNotIsSomeoneElses() {
        XCTAssertFalse(FrontGate.isOurs(apps([1, 2, 9]), set: apps([1, 2, 3, 4])))
    }

    func testSmallPartOfOurListIsSomeoneElses() {
        // A kiosk app allowing one or two apps, which happen to be ones we allowed too.
        XCTAssertFalse(FrontGate.isOurs(apps([1]), set: apps(Array(1...60))))
    }

    /// A drag can last any time, and what it's let go on may come forward
    /// (a file on a Dock icon): open for as long as the button is down.
    func testTheGateStaysOpenWhileAMouseButtonIsDown() {
        let gate = FrontGate()
        XCTAssertFalse(gate.isLifted)
        gate.pointer(down: true, ms: 20)
        sleepMs(60)
        XCTAssertTrue(gate.isLifted)
        gate.pointer(down: false, ms: 20)
        XCTAssertTrue(gate.isLifted)
        sleepMs(60)
        XCTAssertFalse(gate.isLifted)
    }

    /// macOS 26.7 answers -10663 (attribute not settable) to setting the
    /// list. The gate has to give up there, not ask again every 5 ms.
    func testAMacOSThatRefusesTheListTurnsTheGateOff() throws {
        try XCTSkipUnless(FrontGate.available, "no LaunchServices calls here")
        let others = ["com.apple.finder", "com.apple.dock"].compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        }
        try XCTSkipUnless(others.count == 2, "needs Finder and the Dock running")
        var asked = 0
        FrontGate.setListForTests = { list in
            // (Clearing a list that isn't there is asked for too; count the real ones.)
            if !list.isEmpty { asked += 1 }
            return -10663
        }
        defer { FrontGate.setListForTests = nil }
        let gate = FrontGate()
        gate.targets = { FrontGate.Targets(pids: Set(others)) }
        gate.tapWorking = { true }
        var passes = 0
        while gate.passForTests() && passes < 20 { passes += 1 }
        try XCTSkipIf(asked == 0, "another app keeps a list of its own on this Mac")
        XCTAssertEqual(asked, 3)
        XCTAssertLessThan(passes, 20, "the gate's thread never ended")
        XCTAssertFalse(gate.isOn)
        XCTAssertFalse(gate.passForTests())
        XCTAssertEqual(asked, 3)
    }
}
