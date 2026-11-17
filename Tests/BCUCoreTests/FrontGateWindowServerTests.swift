import XCTest
@testable import BCUCore

/// The gate on a macOS whose LaunchServices refuses the permitted-front list
/// (27.2 answers -10663), where WindowServer's own list is changed one app
/// at a time instead. Everything the gate reads or changes is made up here.
final class FrontGateWindowServerTests: XCTestCase {
    /// The user's app, an agent's app and one more, by pid.
    let user: pid_t = 101, agent: pid_t = 202, other: pid_t = 303

    /// WindowServer's list as the fake keeps it (serial numbers).
    var list: Set<UInt64> = []
    var calls = 0
    var lsAsked = 0

    func psn(_ pid: pid_t) -> UInt64 { 0x1_0000_0000 + UInt64(pid) }

    override func setUp() {
        super.setUp()
        list = []
        calls = 0
        lsAsked = 0
        let apps = [user, agent, other].map { FrontGate.App(asn: "\($0)" as CFString, pid: $0, bundleID: "test.app.\($0)") }
        var system = FrontGate.System()
        system.runningApps = { apps }
        system.appListSeed = { 1 }
        system.currentList = { nil }
        system.setList = { [unowned self] _ in lsAsked += 1; return -10663 }
        system.frontPid = { [unowned self] in user }
        system.windowServerListAvailable = { true }
        system.processSerialNumber = { [unowned self] in psn($0) }
        system.updateWindowServerList = { [unowned self] p, add in
            calls += 1
            if add { list.insert(p) } else { list.remove(p) }
            return 0
        }
        FrontGate.system = system
    }

    override func tearDown() {
        FrontGate.system = FrontGate.System()
        super.tearDown()
    }

    func makeGate() -> FrontGate {
        let gate = FrontGate()
        gate.targets = { [unowned self] in FrontGate.Targets(pids: [agent]) }
        gate.tapWorking = { true }
        return gate
    }

    /// Every app but the agent's is on WindowServer's list, so the agent's
    /// app can't bring itself to the front.
    func testTheAgentsAppIsKeptOffWindowServersList() {
        let gate = makeGate()
        for _ in 0..<5 { XCTAssertTrue(gate.passForTests()) }
        XCTAssertEqual(list, [psn(user), psn(other)])
        XCTAssertTrue(gate.blocks(agent))
        gate.stop()
    }

    /// A click (or any key that could switch apps) puts the agent's app on
    /// the list at once, before the event goes on, so the user can go to it.
    func testTheUsersClickLetsTheAgentsAppThrough() {
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        let before = calls
        gate.pointer(down: true, ms: 30)
        XCTAssertTrue(list.contains(psn(agent)))
        XCTAssertFalse(gate.blocks(agent))
        XCTAssertLessThanOrEqual(calls - before, 1, "opening for the user takes one call per app kept back")
        // Let go, and once the moment passes the agent's app is kept back again.
        gate.pointer(down: false, ms: 30)
        sleepMs(60)
        _ = gate.passForTests()
        XCTAssertEqual(list, [psn(user), psn(other)])
        gate.stop()
    }

    /// Nothing of the gate's is left on the list once it stops.
    func testNothingIsLeftOnTheList() {
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        XCTAssertFalse(list.isEmpty)
        gate.stop()
        XCTAssertEqual(list, [])
    }

    /// On 27.2 LaunchServices reads WindowServer's list back (it only refuses
    /// to set it). The gate's own entries, read that way, aren't another
    /// app's list: it keeps the agent's app back, and still opens for a click.
    func testItsOwnEntriesReadBackArentAnotherAppsList() {
        let apps = [user, agent, other]
        FrontGate.system.currentList = { [unowned self] in
            let on = apps.filter { list.contains(psn($0)) }
            return on.isEmpty ? nil : on.map { "\($0)" as CFString }
        }
        let gate = makeGate()
        for _ in 0..<5 { XCTAssertTrue(gate.passForTests()) }
        XCTAssertEqual(list, [psn(user), psn(other)])
        XCTAssertTrue(gate.blocks(agent))
        gate.pointer(down: true, ms: 30)
        XCTAssertTrue(list.contains(psn(agent)))
        gate.stop()
        XCTAssertEqual(list, [])
    }

    /// Background-only processes never come to the front: each entry is a
    /// call to WindowServer, so they stay off.
    func testBackgroundOnlyProcessesStayOff() {
        FrontGate.system.canComeForward = { [unowned self] in $0 != other }
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        XCTAssertEqual(list, [psn(user)])
        XCTAssertTrue(gate.blocks(agent))
        gate.stop()
    }

    /// The agent's app getting to the front anyway (the guard puts the
    /// user's app back) doesn't take the list down: each entry taken off
    /// one at a time leaves the apps already off refused until the rest are.
    func testTheAgentsAppInFrontDoesntTakeTheListDown() {
        var front = user
        FrontGate.system.frontPid = { front }
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        let before = calls
        front = agent
        for _ in 0..<3 { _ = gate.passForTests() }
        XCTAssertTrue(list.isSuperset(of: [psn(user), psn(other)]))
        XCTAssertLessThanOrEqual(calls - before, 1)
        front = user
        for _ in 0..<3 { _ = gate.passForTests() }
        XCTAssertEqual(list, [psn(user), psn(other)])
        gate.stop()
    }

    /// When agents stop needing an app kept back, everyone is let through at
    /// once, and the list itself goes only after a while.
    func testWithNothingToKeepBackTheListGoesLater() {
        FrontGate.windowServerIdleClearMs = 80
        defer { FrontGate.windowServerIdleClearMs = 30_000 }
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        gate.targets = { FrontGate.Targets() }
        _ = gate.passForTests()
        XCTAssertEqual(list, [psn(user), psn(agent), psn(other)])
        XCTAssertFalse(gate.blocks(agent))
        sleepMs(120)
        _ = gate.passForTests()
        XCTAssertEqual(list, [])
        gate.stop()
    }

    /// Return or a shortcut while an agent's step runs in its app doesn't let
    /// that app through: what comes forward then is almost always the agent's
    /// doing. A click still does (it may be on that app's window).
    func testAKeyDoesntLetThroughTheAppAnAgentIsSteppingIn() {
        let gate = FrontGate()
        gate.targets = { [unowned self] in FrontGate.Targets(pids: [agent], stepping: [agent]) }
        gate.tapWorking = { true }
        for _ in 0..<3 { _ = gate.passForTests() }
        gate.liftForKey(ms: 2000)
        XCTAssertFalse(list.contains(psn(agent)))
        _ = gate.passForTests()
        XCTAssertFalse(list.contains(psn(agent)))
        XCTAssertTrue(gate.blocks(agent))
        gate.pointer(down: true, ms: 30)
        XCTAssertTrue(list.contains(psn(agent)))
        gate.stop()
    }

    /// Between steps a key lets the agent's app through, as before (Return
    /// on a link the user opens in that browser).
    func testAKeyLetsTheAgentsAppThroughBetweenSteps() {
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        gate.liftForKey(ms: 2000)
        XCTAssertTrue(list.contains(psn(agent)))
        _ = gate.passForTests()
        XCTAssertTrue(list.contains(psn(agent)))
        gate.stop()
    }

    /// Entries outlive the process, so none goes on unless the record that
    /// lets the watchdog or the next launch take it off was written.
    func testNothingGoesOnWithoutARecord() {
        FrontGate.system.writeFile = { _, _ in false }
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        XCTAssertEqual(list, [])
        XCTAssertFalse(gate.blocks(agent))
        gate.stop()
    }

    /// The watchdog's cleanup (after a stall) can't run in the middle of an
    /// update: a resumed update would put back a record of entries the
    /// watchdog took off, and the gate would count them on for good. Once
    /// the update is done it runs, and the next pass sees it.
    func testTheWatchdogWaitsForAnUpdateInProgress() {
        var midUpdate: Bool?
        let update = FrontGate.system.updateWindowServerList
        FrontGate.system.updateWindowServerList = { p, add in
            let r = update(p, add)
            if add && midUpdate == nil { midUpdate = FrontGate.watchdogClear() }
            return r
        }
        let gate = makeGate()
        _ = gate.passForTests()
        XCTAssertEqual(midUpdate, false)
        XCTAssertEqual(list, [psn(user), psn(other)])
        XCTAssertTrue(FrontGate.watchdogClear())
        XCTAssertEqual(list, [])
        _ = gate.passForTests()
        XCTAssertEqual(list, [psn(user), psn(other)])
        gate.stop()
    }

    /// An entry the watchdog couldn't take off (its app still running) stays
    /// recorded, and the next try takes it off.
    func testTheWatchdogKeepsWhatItCouldntTakeOff() {
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        var failOnce = true
        let update = FrontGate.system.updateWindowServerList
        FrontGate.system.updateWindowServerList = { [unowned self] p, add in
            if !add && p == psn(other) && failOnce { failOnce = false; return -1 }
            return update(p, add)
        }
        XCTAssertFalse(FrontGate.watchdogClear())
        XCTAssertEqual(list, [psn(other)])
        XCTAssertTrue(FrontGate.watchdogClear())
        XCTAssertEqual(list, [])
        gate.stop()
    }

    /// After the watchdog took some entries off (after a stall), the engine
    /// sees it on its next pass and puts them back, though one wouldn't come off.
    func testTheEngineSeesAPartialCleanup() {
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        let update = FrontGate.system.updateWindowServerList
        FrontGate.system.updateWindowServerList = { [unowned self] p, add in
            !add && p == psn(other) ? -1 : update(p, add)
        }
        XCTAssertFalse(FrontGate.watchdogClear())
        XCTAssertEqual(list, [psn(other)])
        FrontGate.system.updateWindowServerList = update
        _ = gate.passForTests()
        XCTAssertEqual(list, [psn(user), psn(other)])
        gate.stop()
        XCTAssertEqual(list, [])
    }

    /// The same at the next launch.
    func testTheNextLaunchKeepsWhatItCouldntTakeOff() {
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        var failOnce = true
        let update = FrontGate.system.updateWindowServerList
        FrontGate.system.updateWindowServerList = { [unowned self] p, add in
            if !add && p == psn(other) && failOnce { failOnce = false; return -1 }
            return update(p, add)
        }
        FrontGate.clearLeftoversForTests()
        XCTAssertEqual(list, [psn(other)])
        FrontGate.clearLeftoversForTests()
        XCTAssertEqual(list, [])
        gate.stop()
    }

    /// The app kept back can't be put on for the user's click: the whole
    /// list comes down, so the click still gets them there.
    func testAFailedAddForAClickTakesTheListDown() {
        let update = FrontGate.system.updateWindowServerList
        FrontGate.system.updateWindowServerList = { [unowned self] p, add in
            add && p == psn(agent) ? -1 : update(p, add)
        }
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        XCTAssertEqual(list, [psn(user), psn(other)])
        gate.pointer(down: true, ms: 30)
        XCTAssertEqual(list, [])
        XCTAssertFalse(gate.blocks(agent))
        gate.stop()
    }

    /// A process that died with entries on the list (they outlive it) leaves
    /// a record; the next one takes those entries off before anything else.
    func testAnEarlierRunsEntriesAreTakenOff() {
        let gate = makeGate()
        for _ in 0..<3 { _ = gate.passForTests() }
        let left = list
        XCTAssertFalse(left.isEmpty)
        // As if the process died here: its record stays, the list stays.
        FrontGate.clearLeftoversForTests()
        XCTAssertEqual(list, [])
        XCTAssertTrue(calls >= left.count)
    }
}
