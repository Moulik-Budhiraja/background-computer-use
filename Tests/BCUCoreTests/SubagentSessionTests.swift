import XCTest
@testable import BCUCore

/// Sessions side by side: a parent and its subagents, or several viewers.
final class SubagentSessionTests: XCTestCase {
    func testAParentAndItsSubagentRecordIntoDifferentRuns() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let parent = "0F8E6A3C-1B2D-4E5F-8A9B-0C1D2E3F4A5B"
        let child = parent + "/agent-1"
        XCTAssertNotEqual(SessionRecorder.runID(session: parent, date: date), SessionRecorder.runID(session: child, date: date))
        XCTAssertNotEqual(SessionRecorder.runID(session: child, date: date), SessionRecorder.runID(session: parent + "/agent-2", date: date))
        // The same session at the same moment names the same run.
        XCTAssertEqual(SessionRecorder.runID(session: child, date: date), SessionRecorder.runID(session: child, date: date))
        // Folder names still sort by when the run started, and hold no "/".
        let later = SessionRecorder.runID(session: parent, date: date.addingTimeInterval(0.5))
        XCTAssertLessThan(SessionRecorder.runID(session: child, date: date), later)
        XCTAssertFalse(SessionRecorder.runID(session: child, date: date).contains("/"))
    }

    func testTwoSessionsCantBothClaimAWindow() {
        let id: CGWindowID = 0xFFFF_FF01
        XCTAssertTrue(WindowManager.claim(id, pid: 1, for: "a"))
        XCTAssertTrue(WindowManager.claim(id, pid: 1, for: "a"))
        XCTAssertFalse(WindowManager.claim(id, pid: 1, for: "b"))
        XCTAssertTrue(WindowManager.isRegistered(id, byOtherThan: "b"))
    }

    func testClaimsAtOnceGoToOneSession() {
        let id: CGWindowID = 0xFFFF_FF02
        let won = NSLock()
        var winners: [Int] = []
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            if WindowManager.claim(id, pid: 1, for: "s\(i)") { won.lock(); winners.append(i); won.unlock() }
        }
        XCTAssertEqual(winners.count, 1)
    }

    func testTheAgentGetsItsDisplayBackOnlyWhenEveryViewerHasGivenItBack() {
        var n = 0
        n = Engine.controllers(n, taking: true)   // a host app's client
        n = Engine.controllers(n, taking: true)   // the menu bar viewer
        n = Engine.controllers(n, taking: false)
        XCTAssertGreaterThan(n, 0)
        n = Engine.controllers(n, taking: false)
        XCTAssertEqual(n, 0)
        // An extra give-back doesn't count against a later take-over.
        n = Engine.controllers(n, taking: false)
        XCTAssertEqual(Engine.controllers(n, taking: true), 1)
    }
}
