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

    func testASubagentIsStillThereWhileItsParentUsesItsWindows() {
        // The subagent's connection closed; its parent, still connected,
        // has been working in one of its windows.
        let attached = ["parent": 1]
        let usedBy = ["parent/agent-1": Set(["parent"])]
        XCTAssertTrue(Hub.present("parent/agent-1", attached: attached, usedBy: usedBy))
        XCTAssertFalse(Hub.present("parent/agent-2", attached: attached, usedBy: usedBy))
        // The parent goes too: the subagent's windows have nobody left.
        XCTAssertFalse(Hub.present("parent/agent-1", attached: [:], usedBy: usedBy))
        XCTAssertEqual(Hub.leftWithNobody(after: "parent", attached: [:], usedBy: usedBy), ["parent/agent-1"])
        // Not one that's still connected itself.
        XCTAssertEqual(Hub.leftWithNobody(after: "parent", attached: ["parent/agent-1": 1], usedBy: usedBy), [])
    }

    func testAPointerMoveDoesntWaitForABusyApp() {
        XCTAssertEqual(RemoteControl.appLockWait(.mouseMoved), 0)
        XCTAssertEqual(RemoteControl.appLockWait(.leftMouseDown), RemoteControl.appLockWaitS)
        XCTAssertEqual(RemoteControl.appLockWait(.keyDown), RemoteControl.appLockWaitS)
    }

    func testAConnectedParentStaysASubagentsUserWhenItsEngineIsForgotten() {
        // The parent only works in its subagent's windows, so its own
        // engine looks dormant, but it's still connected.
        let usedBy = ["parent/agent-1": Set(["parent", "other"])]
        let pruned = Hub.prunedUsers(usedBy, gone: ["parent", "other"], attached: ["parent": 1])
        XCTAssertEqual(pruned["parent/agent-1"], ["parent"])
    }

    func testASubagentLeftWithNobodyGetsAFreshGrace() {
        let times = Hub.departedTimes(["parent/agent-1": 1000, "x": 2000], left: ["parent/agent-1"], now: 9000)
        XCTAssertEqual(times["parent/agent-1"], 9000)
        XCTAssertEqual(times["x"], 2000)
    }

    func testASubagentsWindowsInUseByItsParentArentTakenOver() {
        let usedBy = ["parent/agent-1": Set(["parent"])]
        XCTAssertFalse(Hub.abandoned("parent/agent-1", attached: ["parent": 1], usedBy: usedBy))
        XCTAssertTrue(Hub.abandoned("parent/agent-1", attached: [:], usedBy: usedBy))
        XCTAssertFalse(Hub.abandoned("parent/agent-1", attached: ["parent/agent-1": 1], usedBy: [:]))
    }

    func testAReleaseQueuedForAnEarlierDepartureDoesntRun() {
        XCTAssertTrue(Engine.departureStillCurrent(3, latest: 3))
        // Left with nobody again later: that departure gets the whole grace.
        XCTAssertFalse(Engine.departureStillCurrent(2, latest: 3))
    }

    func testAHandedOffWindowStaysWhenItsAgentGoes() {
        XCTAssertEqual(Engine.abandonedFate(withUser: false, handedOff: false), .release)
        XCTAssertEqual(Engine.abandonedFate(withUser: true, handedOff: false), .leaveWithUser)
        // Waiting for the user, who hasn't opened it yet.
        XCTAssertEqual(Engine.abandonedFate(withUser: false, handedOff: true), .keepForUser)
    }

    func testASessionAViewerIsDrivingIsntTakenOver() {
        XCTAssertTrue(Hub.abandoned("parent/agent-1", attached: [:], usedBy: [:], userInControl: false))
        XCTAssertFalse(Hub.abandoned("parent/agent-1", attached: [:], usedBy: [:], userInControl: true))
    }
}
