import XCTest
@testable import BCUCore

/// Pure rules only: nothing here reads or touches the Mac it runs on.
final class ReviewFixTests: XCTestCase {
    func testRecoveryAnswersOnlyADialogThatCameUpAfterItsClose() {
        // A "Leave site?" the user already had up is theirs.
        XCTAssertFalse(WindowManager.isNewDialog(41, before: [41], closed: [7]))
        // One that appeared after the close is the closed page's.
        XCTAssertTrue(WindowManager.isNewDialog(42, before: [41], closed: [7]))
        // A window recovery closed is never taken for a dialog.
        XCTAssertFalse(WindowManager.isNewDialog(7, before: [41], closed: [7]))
    }

    func testTheWatchdogClearsOnlyThisEnginesList() {
        XCTAssertTrue(FrontGate.watchdogMayClear(markerExists: true, listExists: true))
        // Another app's list (no marker of ours): left alone.
        XCTAssertFalse(FrontGate.watchdogMayClear(markerExists: false, listExists: true))
        XCTAssertFalse(FrontGate.watchdogMayClear(markerExists: true, listExists: false))
    }

    func testReturnToPreviousSizeIsPressedOnlyForTheUsersMainWindowInFront() {
        XCTAssertTrue(AgentDisplay.mayUntile(front: 10, pid: 10, mainWindow: 5, id: 5, itemEnabled: true))
        // In the background macOS disables the item: not pressed.
        XCTAssertFalse(AgentDisplay.mayUntile(front: 11, pid: 10, mainWindow: 5, id: 5, itemEnabled: false))
        XCTAssertFalse(AgentDisplay.mayUntile(front: 11, pid: 10, mainWindow: 5, id: 5, itemEnabled: true))
        // The item acts on the main window: another window being main would untile that one.
        XCTAssertFalse(AgentDisplay.mayUntile(front: 10, pid: 10, mainWindow: 6, id: 5, itemEnabled: true))
        // Not tiled, as far as the app knows.
        XCTAssertFalse(AgentDisplay.mayUntile(front: 10, pid: 10, mainWindow: 5, id: 5, itemEnabled: false))
    }

    func testASessionBackAfterARestartIsFoundByEitherId() {
        // Kept under the new connection's id "new"; it still calls itself "old".
        let byID = ["new": "old", "other": "other"]
        XCTAssertEqual(Hub.lookup("new", in: byID, sessionID: { $0 }), "old")
        XCTAssertEqual(Hub.lookup("old", in: byID, sessionID: { $0 }), "old")
        XCTAssertNil(Hub.lookup("gone", in: byID, sessionID: { $0 }))
    }

    func testOnlyAnAgentsOwnLeftoverIsClosed() {
        XCTAssertEqual(WindowManager.leftoverFate(1, agentMade: true, kept: []), .close)
        // Kept open by its agent: the user's now.
        XCTAssertEqual(WindowManager.leftoverFate(2, agentMade: true, kept: [2]), .giveToUser)
        // Never an agent's (an app's own, or one macOS moved there): the user's.
        XCTAssertEqual(WindowManager.leftoverFate(3, agentMade: false, kept: []), .giveToUser)
    }

    func testRecoveryClosesOnlyWhatsStillOnALeftoverDisplay() {
        let stray = CGRect(x: 3000, y: 0, width: 1400, height: 900)
        let there = CGRect(x: 3100, y: 100, width: 800, height: 600)
        let onUsers = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(WindowManager.recoveryCloses(kind: "opened", bounds: there, agentDisplays: [stray]))
        XCTAssertTrue(WindowManager.recoveryCloses(kind: "caught", bounds: there, agentDisplays: [stray]))
        // Its display went with the crash: on the user's screen, maybe in use.
        XCTAssertFalse(WindowManager.recoveryCloses(kind: "opened", bounds: onUsers, agentDisplays: [stray]))
        XCTAssertFalse(WindowManager.recoveryCloses(kind: "opened", bounds: there, agentDisplays: []))
        XCTAssertFalse(WindowManager.recoveryCloses(kind: "borrowed", bounds: there, agentDisplays: [stray]))
    }

    func testTheCatcherMovesOnlyTheWindowItCaught() {
        XCTAssertTrue(WindowCatcher.mayMove(5, caught: nil))
        XCTAssertTrue(WindowCatcher.mayMove(5, caught: 5))
        // A second new window while the first settles: not the catcher's.
        XCTAssertFalse(WindowCatcher.mayMove(6, caught: 5))
    }

    func testTheSweepLeavesAWindowReleasedSinceItsCopyOfTheRegistry() {
        XCTAssertTrue(WindowManager.sweepStillOwns(registeredNow: true, kept: false))
        // Released with keep_open while the sweep ran: on the user's screen now.
        XCTAssertFalse(WindowManager.sweepStillOwns(registeredNow: false, kept: true))
        // Released and closing.
        XCTAssertFalse(WindowManager.sweepStillOwns(registeredNow: false, kept: false))
    }

    func testAStrayDisplaysWindowOnARealScreenIsLeftWhereItIs() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let stranded = CGRect(x: 2000, y: 100, width: 800, height: 600)
        XCTAssertTrue(WindowManager.strandedOnStray(stranded, userDisplays: [main]))
        // A stray macOS left on top of the user's display: the window is visible.
        let visible = CGRect(x: 300, y: 200, width: 800, height: 600)
        XCTAssertFalse(WindowManager.strandedOnStray(visible, userDisplays: [main]))
    }

    func testAKeptWindowBorrowedAgainIsntKeptAnyMore() {
        let id: CGWindowID = 0xFFFF_FE01
        WindowManager.keep(id)
        XCTAssertTrue(WindowManager.isKept(id))
        // Borrowed again: the session's sweep has to look after it.
        WindowManager.ownedAgain(id)
        XCTAssertFalse(WindowManager.isKept(id))
    }
}
