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
}
