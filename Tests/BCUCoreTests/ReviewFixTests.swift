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

    func testAWindowReleasedWithKeepOpenIsNotALeftover() {
        XCTAssertEqual(WindowManager.leftovers([1, 2, 3], kept: [2]), [1, 3])
        XCTAssertEqual(WindowManager.leftovers([2], kept: [2]), [])
    }
}
