import XCTest
@testable import BCUCore

/// Pure rules only: nothing here reads or touches the Mac it runs on.
final class DiscardOnQuitTests: XCTestCase {
    func testRecoveryClosesTheLastRunsWindowsWhereverTheyAre() {
        // Its display went with the crash, so it's on the user's screen now:
        // still the agent's, so it's closed.
        XCTAssertTrue(WindowManager.recoveryCloses(kind: "opened"))
        XCTAssertTrue(WindowManager.recoveryCloses(kind: "caught"))
        // A borrowed window is the user's: it's put back, never closed.
        XCTAssertFalse(WindowManager.recoveryCloses(kind: "borrowed"))
        XCTAssertFalse(WindowManager.recoveryCloses(kind: nil))
    }

    func testARecordNamesOnlyAWindowOfAnAppAlreadyRunningWhenItWasWritten() {
        let written = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(WindowManager.recordStillNames(appLaunched: written.addingTimeInterval(-60), recordWritten: written))
        // The app started after the record was written (a restart, or the
        // pid reused): its window with the same id isn't the agent's.
        XCTAssertFalse(WindowManager.recordStillNames(appLaunched: written.addingTimeInterval(5), recordWritten: written))
        // Can't tell: left alone.
        XCTAssertFalse(WindowManager.recordStillNames(appLaunched: nil, recordWritten: written))
        XCTAssertFalse(WindowManager.recordStillNames(appLaunched: written, recordWritten: nil))
    }

    func testTheSaveSheetIsAnsweredWithTheButtonThatThrowsChangesAway() {
        XCTAssertEqual(WindowManager.discardButton(["Don’t Save", "Cancel", "Save"]), "Don’t Save")
        XCTAssertEqual(WindowManager.discardButton(["Don't Save", "Cancel", "Save…"]), "Don't Save")
        // A new document that was never saved: "keep this new document?"
        XCTAssertEqual(WindowManager.discardButton(["Delete", "Cancel", "Save"]), "Delete")
        // Not a sheet about unsaved changes: nothing is pressed.
        XCTAssertNil(WindowManager.discardButton(["Delete", "Cancel"]))
        XCTAssertNil(WindowManager.discardButton(["Leave", "Cancel"]))
        XCTAssertNil(WindowManager.discardButton(["OK"]))
    }
}
