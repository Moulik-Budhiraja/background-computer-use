import XCTest
@testable import BCUCore

/// Pure rules only: nothing here reads or touches the Mac it runs on.
final class PopoverFixTests: XCTestCase {
    private func session(sinceCall: Double, windows: Bool, handedOff: Bool = false, control: Bool = false) -> UpdateGate.Session {
        UpdateGate.Session(msSinceLastCall: sinceCall, hasWindows: windows, handedOff: handedOff, userInControl: control)
    }

    func testAnUpdateWaitsForSessionsWithWindowsToGoQuiet() {
        XCTAssertTrue(UpdateGate.canInstall([], setupOpen: false))
        XCTAssertTrue(UpdateGate.canInstall([session(sinceCall: 10_000, windows: false)], setupOpen: false))
        // Windows open and a recent call: the agent may still be at work.
        XCTAssertFalse(UpdateGate.canInstall([session(sinceCall: 60_000, windows: true)], setupOpen: false))
        // Windows open but no call for a long while: it doesn't wait forever.
        XCTAssertTrue(UpdateGate.canInstall([session(sinceCall: UpdateGate.quietMs, windows: true)], setupOpen: false))
        XCTAssertTrue(UpdateGate.canInstall([session(sinceCall: .infinity, windows: true)], setupOpen: false))
        // A call running or just finished.
        XCTAssertFalse(UpdateGate.canInstall([session(sinceCall: 0, windows: false)], setupOpen: false))
    }

    func testAnUpdateNeverRelaunchesOnTheUser() {
        let quiet = session(sinceCall: .infinity, windows: false)
        XCTAssertFalse(UpdateGate.canInstall([quiet], setupOpen: true))
        XCTAssertFalse(UpdateGate.canInstall([quiet, session(sinceCall: .infinity, windows: true, handedOff: true)], setupOpen: false))
        XCTAssertFalse(UpdateGate.canInstall([session(sinceCall: .infinity, windows: true, control: true)], setupOpen: false))
    }

    func testTheMailboxKeepsOnlyTheNewestValue() {
        let box = Mailbox<Int>()
        XCTAssertTrue(box.put(1))
        // One is already waiting to be taken: no second drain is scheduled.
        XCTAssertFalse(box.put(2))
        XCTAssertFalse(box.put(3))
        XCTAssertEqual(box.take(), 3)
        XCTAssertNil(box.take())
        XCTAssertTrue(box.put(4))
    }
}

/// Pure rules only, like the ones above.
final class StopAndMenuSurfaceTests: XCTestCase {
    func testStopAsksAboutEveryWindowItWouldClose() {
        // The watchdog's catches (an agent's second window) close on Stop too.
        XCTAssertTrue(AgentWindow.Kind.opened.closesOnStop)
        XCTAssertTrue(AgentWindow.Kind.caught.closesOnStop)
        XCTAssertFalse(AgentWindow.Kind.borrowed.closesOnStop)
    }

    func testThePopoverAndThePanelNeverShowTogether() {
        XCTAssertEqual(MenuSurface.toClose(before: .popover, showing: [.panel]), [.panel])
        XCTAssertEqual(MenuSurface.toClose(before: .panel, showing: [.popover]), [.popover])
        XCTAssertEqual(MenuSurface.toClose(before: .popover, showing: [.popover]), [])
        XCTAssertEqual(MenuSurface.toClose(before: .panel, showing: []), [])
    }
}

/// Pure rules only, like the ones above.
final class HandBackTests: XCTestCase {
    /// Done after a long handoff: the agent gets its chance to resume first.
    func testAnUpdateWaitsAfterTheUserHandsWindowsBack() {
        let returned = UpdateGate.Session(msSinceLastCall: .infinity, hasWindows: true, handedOff: false, userInControl: false,
                                          msSinceUserReturned: 1000)
        XCTAssertFalse(UpdateGate.canInstall([returned], setupOpen: false))
        let longAgo = UpdateGate.Session(msSinceLastCall: .infinity, hasWindows: true, handedOff: false, userInControl: false,
                                         msSinceUserReturned: UpdateGate.quietMs)
        XCTAssertTrue(UpdateGate.canInstall([longAgo], setupOpen: false))
    }

    /// Done while paused: the paused call still tells the agent.
    func testARefusedCallCarriesTheUsersNotes() {
        let note = "\n[user] The user pressed Done on window 7 (Safari)."
        XCTAssertEqual(Engine.refusal(tool: "click", userInControl: false, paused: true, notes: { note })?.hasSuffix(note), true)
        XCTAssertEqual(Engine.refusal(tool: "take_back", userInControl: true, paused: false, notes: { note })?.hasSuffix(note), true)
        // A call that runs leaves the notes for its own result.
        XCTAssertNil(Engine.refusal(tool: "click", userInControl: false, paused: false, notes: { XCTFail("taken"); return note }))
        XCTAssertNil(Engine.refusal(tool: "screenshot", userInControl: false, paused: true, notes: { XCTFail("taken"); return note }))
    }
}
