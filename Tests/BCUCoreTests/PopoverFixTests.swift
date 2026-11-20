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
