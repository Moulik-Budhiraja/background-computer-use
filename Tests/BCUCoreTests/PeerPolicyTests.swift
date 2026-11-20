import CoreGraphics
import XCTest
@testable import BCUCore

/// Who may connect to the engine's socket, and what each connection sees.
final class PeerPolicyTests: XCTestCase {
    private let ours = "AAAAAAAAAA"
    private let theirs = "BBBBBBBBBB"
    private let appHome = "/Applications/Background Computer Use.app"
    private let hostApp = "/Applications/Host.app"

    private func peer(_ path: String?, team: String? = nil, valid: Bool = true, cdhash: Data? = nil) -> PeerIdentity {
        PeerIdentity(path: path, valid: valid, team: team, cdhash: cdhash)
    }

    private func signed(trusted: [String] = []) -> PeerPolicy {
        PeerPolicy(team: ours, cdhash: Data([1]), home: appHome, trusted: trusted)
    }

    private func adHoc(trusted: [String] = []) -> PeerPolicy {
        PeerPolicy(team: nil, cdhash: Data([1]), home: "/Users/me/bcu/build/Background Computer Use.app", trusted: trusted)
    }

    private let hostShipsBCU: (String, PeerIdentity) -> Bool = { app, peer in app == "/Applications/Host.app" && peer.team == "BBBBBBBBBB" }
    private let noneShip: (String, PeerIdentity) -> Bool = { _, _ in false }

    private func isDenied(_ d: PeerDecision) -> Bool {
        if case .deny = d { return true }
        return false
    }

    func testSameTeamIsOwner() {
        let d = signed().decide(peer("\(appHome)/Contents/MacOS/bcu", team: ours), shipsBCU: noneShip)
        XCTAssertEqual(d, .allow(.owner))
    }

    func testSameBinaryIsOwnerEvenAdHoc() {
        let d = adHoc().decide(peer("/Users/me/bcu/.build/debug/bcu", cdhash: Data([1])), shipsBCU: noneShip)
        XCTAssertEqual(d, .allow(.owner))
    }

    func testUnsignedOrUnreadablePeersAreRefused() {
        XCTAssertTrue(isDenied(signed().decide(nil, shipsBCU: noneShip)))
        XCTAssertTrue(isDenied(signed().decide(peer("/tmp/evil", valid: false), shipsBCU: noneShip)))
        // A broken signature doesn't get in on a matching cdhash or team either.
        XCTAssertTrue(isDenied(signed().decide(peer("/tmp/evil", team: ours, valid: false, cdhash: Data([1])), shipsBCU: noneShip)))
    }

    func testPlatformAndOtherSignedProgramsAreRefused() {
        // Apple's own binaries have no team; another developer's that doesn't ship bcu.
        XCTAssertTrue(isDenied(signed().decide(peer("/usr/bin/python3"), shipsBCU: noneShip)))
        XCTAssertTrue(isDenied(signed().decide(peer("/opt/homebrew/Cellar/node/22/bin/node", team: "CCCCCCCCCC"), shipsBCU: noneShip)))
    }

    func testAnotherAppThatShipsBCUGetsItsOwnScope() {
        let ui = peer("\(hostApp)/Contents/Frameworks/Host Helper.app", team: theirs)
        XCTAssertEqual(signed().decide(ui, shipsBCU: hostShipsBCU), .allow(.app(team: theirs)))
        let bcu = peer("\(hostApp)/Contents/Resources/bcu", team: theirs)
        XCTAssertEqual(signed().decide(bcu, shipsBCU: hostShipsBCU), .allow(.app(team: theirs)))
        // The same works for an ad hoc engine (a development build of the app).
        XCTAssertEqual(adHoc().decide(ui, shipsBCU: hostShipsBCU), .allow(.app(team: theirs)))
        // The bcu has to be signed by the same team as the peer.
        let impostor = peer("\(hostApp)/Contents/MacOS/Host", team: "CCCCCCCCCC")
        XCTAssertTrue(isDenied(signed().decide(impostor, shipsBCU: hostShipsBCU)))
        // A program outside any app can't ship anything.
        XCTAssertTrue(isDenied(signed().decide(peer("/usr/local/bin/tool", team: theirs), shipsBCU: { _, _ in true })))
    }

    func testAdHocEngineTrustsItsOwnApp() {
        let p = adHoc()
        XCTAssertEqual(p.decide(peer("\(p.home!)/Contents/MacOS/bcu"), shipsBCU: noneShip), .allow(.owner))
        XCTAssertTrue(isDenied(p.decide(peer("\(p.home!) copy/Contents/MacOS/bcu"), shipsBCU: noneShip)))
        XCTAssertTrue(isDenied(p.decide(peer("/tmp/evil"), shipsBCU: noneShip)))
    }

    func testSignedEngineDoesntTrustUnsignedCodeInItsApp() {
        // With a team to go by, the path alone isn't enough.
        XCTAssertTrue(isDenied(signed().decide(peer("\(appHome)/Contents/MacOS/dropped"), shipsBCU: noneShip)))
    }

    func testTrustClientByPathOrTeam() {
        let node = "/opt/homebrew/Cellar/node/22/bin/node"
        XCTAssertEqual(adHoc(trusted: [node]).decide(peer(node, team: "CCCCCCCCCC"), shipsBCU: noneShip), .allow(.owner))
        XCTAssertEqual(signed(trusted: ["/Users/me/host/node_modules/electron/dist"])
            .decide(peer("/Users/me/host/node_modules/electron/dist/Electron.app"), shipsBCU: noneShip), .allow(.owner))
        XCTAssertEqual(signed(trusted: ["CCCCCCCCCC"]).decide(peer("/x/y", team: "CCCCCCCCCC"), shipsBCU: noneShip), .allow(.owner))
        // A folder isn't a prefix of a sibling with a longer name.
        XCTAssertTrue(isDenied(signed(trusted: ["/opt/node"]).decide(peer("/opt/node-evil/bin/node"), shipsBCU: noneShip)))
    }

    func testPaths() {
        XCTAssertEqual(PeerPolicy.outermostApp("/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B"), "/Applications/A.app")
        XCTAssertNil(PeerPolicy.outermostApp("/usr/bin/python3"))
        XCTAssertTrue(PeerPolicy.path("/a/b/c", isInside: "/a/b/"))
        XCTAssertTrue(PeerPolicy.path("/a/b", isInside: "/a/b"))
        XCTAssertFalse(PeerPolicy.path("/a/bc", isInside: "/a/b"))
        XCTAssertFalse(PeerPolicy.path("/a", isInside: ""))
        XCTAssertTrue(PeerPolicy.isTeamID("ABCDE12345"))
        XCTAssertFalse(PeerPolicy.isTeamID("abcde12345"))
        XCTAssertFalse(PeerPolicy.isTeamID("X\" or true"))
    }

    // MARK: Scope

    func testHostAppSeesOnlyItsOwnSessions() {
        let scope = PeerScope()
        let host = PeerTrust.app(team: theirs)
        let other = PeerTrust.app(team: "CCCCCCCCCC")
        XCTAssertNil(scope.admitCall(session: "claude-1", parent: nil, host: nil, .owner))
        XCTAssertNil(scope.admitCall(session: "helper-1", parent: nil, host: "host", host))
        XCTAssertTrue(scope.mayUse(session: "helper-1", host))
        XCTAssertTrue(scope.mayUse(session: "helper-1", .owner))
        XCTAssertFalse(scope.mayUse(session: "claude-1", host))
        XCTAssertFalse(scope.mayUse(session: "helper-1", other))
        // Sessions no one has called for yet are the engine's own.
        XCTAssertFalse(scope.mayUse(session: "restored", host))
        XCTAssertTrue(scope.mayUse(session: "restored", .owner))
    }

    func testCallsCantTakeAnotherAppsSessionOrHost() {
        let scope = PeerScope()
        let host = PeerTrust.app(team: theirs)
        let other = PeerTrust.app(team: "CCCCCCCCCC")
        XCTAssertNil(scope.admitCall(session: "helper-1", parent: nil, host: "host", host))
        XCTAssertNotNil(scope.admitCall(session: "helper-1", parent: nil, host: nil, other))
        XCTAssertNotNil(scope.admitCall(session: "x", parent: nil, host: "host", other))
        XCTAssertNotNil(scope.admitCall(session: "x/sub", parent: "helper-1", host: nil, other))
        XCTAssertNil(scope.admitCall(session: "helper-1/sub", parent: "helper-1", host: "host", host))
        // The engine's own code may use them; it doesn't take them over.
        XCTAssertNil(scope.admitCall(session: "helper-1", parent: nil, host: "host", .owner))
        XCTAssertEqual(scope.owner(ofSession: "helper-1"), host)
        XCTAssertFalse(scope.claimHost("host", other))
        XCTAssertTrue(scope.claimHost("host", host))
        XCTAssertTrue(scope.claimHost("host", .owner))
        XCTAssertTrue(scope.claimHost("fresh", other))
        XCTAssertFalse(scope.claimHost("fresh", host))
    }

    // MARK: Host apps on disk

    /// Code on a pretend disk.
    private final class FakeDisk: CodeOnDisk {
        var sealedApps: [String: String] = [:]   // app path: team
        var signed: [String: String] = [:]       // code path: team
        var hashes: [String: Data] = [:]
        func isSealedApp(_ path: String, team: String) -> Bool { sealedApps[path] == team }
        func isSigned(_ path: String, team: String) -> Bool { signed[path] == team }
        func cdhashes(_ path: String) -> Set<Data> { hashes[path].map { [$0] } ?? [] }
        func isExecutable(_ path: String) -> Bool { signed[path] != nil }
        func subfolders(_ path: String) -> [String] { [] }
    }

    /// Another developer's signed program (an interpreter, say) copied to
    /// Fake.app/Contents/Resources/bcu: no signed app ships it.
    func testAFileNamedBCUInAFolderNamedAppDoesntVouch() {
        let disk = FakeDisk()
        let exe = "/tmp/Fake.app/Contents/Resources/bcu"
        disk.signed[exe] = theirs
        disk.hashes[exe] = Data([7])
        let interpreter = PeerIdentity(path: exe, valid: true, team: theirs, cdhash: Data([7]))
        XCTAssertFalse(HostCheck.vouches(app: "/tmp/Fake.app", peer: interpreter, disk: disk))
        // The same layout in an app signed and sealed by that team does.
        disk.sealedApps["/tmp/Fake.app"] = theirs
        XCTAssertTrue(HostCheck.vouches(app: "/tmp/Fake.app", peer: interpreter, disk: disk))
    }

    /// The peer has to be the code that's in the signed app now: one that
    /// was started from another file there doesn't count.
    func testThePeerIsTheCodeInTheSignedApp() {
        let disk = FakeDisk()
        disk.sealedApps[hostApp] = theirs
        disk.signed["\(hostApp)/Contents/Resources/bcu"] = theirs
        disk.hashes["\(hostApp)/Contents/MacOS/Host"] = Data([1])
        let host = PeerIdentity(path: "\(hostApp)/Contents/MacOS/Host", valid: true, team: theirs, cdhash: Data([1]))
        XCTAssertTrue(HostCheck.vouches(app: hostApp, peer: host, disk: disk))
        let swapped = PeerIdentity(path: "\(hostApp)/Contents/MacOS/Host", valid: true, team: theirs, cdhash: Data([2]))
        XCTAssertFalse(HostCheck.vouches(app: hostApp, peer: swapped, disk: disk))
        let outside = PeerIdentity(path: "/tmp/other", valid: true, team: theirs, cdhash: Data([1]))
        XCTAssertFalse(HostCheck.vouches(app: hostApp, peer: outside, disk: disk))
    }

    // MARK: Windows and families

    /// A frame stream shows the session's own windows only.
    func testFrameStreamWindowMustBeTheSessions() {
        let owns: (CGWindowID) -> Bool = { $0 == 42 }
        XCTAssertEqual(try HostServer.streamWindow(Args(["window": 42]), owns: owns), 42)
        XCTAssertEqual(try HostServer.streamWindow(Args(["window": 0]), owns: owns), 0)
        XCTAssertNil(try HostServer.streamWindow(Args([:]), owns: owns))
        XCTAssertThrowsError(try HostServer.streamWindow(Args(["window": 77]), owns: owns))
    }

    /// Naming a window of another app's session (one whose agent went away,
    /// say) doesn't get a call into it.
    func testCallsCantNameAnotherAppsWindows() {
        let scope = PeerScope()
        let host = PeerTrust.app(team: theirs)
        let other = PeerTrust.app(team: "CCCCCCCCCC")
        XCTAssertNil(scope.admitCall(session: "victim", parent: nil, host: nil, host))
        XCTAssertNotNil(scope.admitCall(session: "fresh", parent: nil, host: nil, windowOwners: ["victim"], other))
        XCTAssertNil(scope.owner(ofSession: "fresh"), "a refused call claims nothing")
        // A session no app has called for yet is the engine's own.
        XCTAssertNotNil(scope.admitCall(session: "fresh", parent: nil, host: nil, windowOwners: ["restored"], other))
        // The same app may (its agent came back after a restart), and so may the engine's own code.
        XCTAssertNil(scope.admitCall(session: "back", parent: nil, host: nil, windowOwners: ["victim"], host))
        XCTAssertNil(scope.admitCall(session: "mine", parent: nil, host: nil, windowOwners: ["victim"], .owner))
    }

    /// A subagent's first call claims its parent too, so another app can't
    /// claim the parent and reach the subagent through it.
    func testFirstChildCallClaimsItsParent() {
        let scope = PeerScope()
        let host = PeerTrust.app(team: theirs)
        let other = PeerTrust.app(team: "CCCCCCCCCC")
        XCTAssertNil(scope.admitCall(session: "p/sub", parent: "p", host: nil, host))
        XCTAssertEqual(scope.owner(ofSession: "p"), host)
        XCTAssertNotNil(scope.admitCall(session: "p", parent: nil, host: nil, other))
        XCTAssertNil(scope.admitCall(session: "p", parent: nil, host: nil, host))
    }

    /// `trustClients: [process.execPath]` names Electron's executable, and a
    /// peer running it shows up as its app.
    func testTrustedMainExecutableMeansItsApp() {
        let app = "/Users/me/host/node_modules/electron/dist/Electron.app"
        let exe = "\(app)/Contents/MacOS/Electron"
        let mainOf: (String) -> String? = { $0 == app ? exe : nil }
        let trusted = PeerPolicy.trustedPath(exe, bundleExecutable: mainOf)
        XCTAssertEqual(trusted, app)
        XCTAssertEqual(signed(trusted: [trusted]).decide(peer(app, team: "CCCCCCCCCC"), shipsBCU: noneShip), .allow(.owner))
        // Another program in the app stays itself; so do bare programs and folders.
        XCTAssertEqual(PeerPolicy.trustedPath("\(app)/Contents/MacOS/other", bundleExecutable: mainOf), "\(app)/Contents/MacOS/other")
        XCTAssertEqual(PeerPolicy.trustedPath("/opt/node/bin/node", bundleExecutable: mainOf), "/opt/node/bin/node")
        XCTAssertEqual(PeerPolicy.trustedPath("/opt/node", bundleExecutable: mainOf), "/opt/node")
    }

    /// A host running its own engine names its host ID from clients the
    /// engine trusts as its own. Another app can't claim that ID after
    /// (and so set where its sessions are recorded).
    func testOwnersHostIDIsReservedToo() {
        let scope = PeerScope()
        let other = PeerTrust.app(team: "CCCCCCCCCC")
        XCTAssertTrue(scope.claimHost("own-host", .owner))
        XCTAssertFalse(scope.claimHost("own-host", other))
        XCTAssertNil(scope.admitCall(session: "agent", parent: nil, host: "called-host", .owner))
        XCTAssertFalse(scope.claimHost("called-host", other))
        XCTAssertNotNil(scope.admitCall(session: "x", parent: nil, host: "called-host", other))
    }

    /// A stream showing one window stops showing it once the window leaves
    /// the session (released, then borrowed by another app's agent).
    func testStreamStopsShowingAWindowThatLeftTheSession() {
        XCTAssertEqual(FrameStream.target(window: 42, excluded: 0, owns: { $0 == 42 }), .window(42))
        XCTAssertEqual(FrameStream.target(window: 42, excluded: 0, owns: { _ in false }), .nothing)
        XCTAssertEqual(FrameStream.target(window: 0, excluded: 7, owns: { _ in false }), .display(excluding: 7))
    }

    /// Keys go to the window the user last clicked only while it's still on
    /// the session's display. One the session gave back (and another app's
    /// agent may have borrowed since) doesn't get them.
    func testKeysDontFollowAWindowOffTheDisplay() {
        func w(_ id: CGWindowID, layer: Int = 0) -> WindowInfo {
            WindowInfo(id: id, pid: 1, owner: "", title: "", bounds: .zero, layer: layer, onScreen: true, alpha: 1)
        }
        XCTAssertEqual(RemoteControl.keyWindow(cached: w(5), onDisplay: [w(9, layer: 3), w(5), w(6)])?.id, 5)
        XCTAssertEqual(RemoteControl.keyWindow(cached: w(5), onDisplay: [w(9, layer: 3), w(6)])?.id, 6)
        XCTAssertNil(RemoteControl.keyWindow(cached: w(5), onDisplay: []))
    }

    /// The session a call without `_session` lands in is `bcu call`'s, the
    /// engine's own. Another app can't take it, explicitly or as a parent.
    func testAnotherAppCantClaimTheDefaultSession() {
        let scope = PeerScope()
        let host = PeerTrust.app(team: theirs)
        XCTAssertNotNil(scope.admitCall(session: Hub.defaultSession, parent: nil, host: nil, host))
        XCTAssertNotNil(scope.admitCall(session: "x/sub", parent: Hub.defaultSession, host: nil, host))
        XCTAssertNil(scope.owner(ofSession: Hub.defaultSession))
        XCTAssertNil(scope.admitCall(session: Hub.defaultSession, parent: nil, host: nil, .owner))
        XCTAssertFalse(scope.mayUse(session: Hub.defaultSession, host))
    }

    /// A drag started before the session gave its window back doesn't go on
    /// moving it once it's left the display (and maybe been borrowed by
    /// another app's agent).
    func testDragStopsWhenItsWindowLeavesTheDisplay() {
        func w(_ id: CGWindowID) -> WindowInfo {
            WindowInfo(id: id, pid: 1, owner: "", title: "", bounds: .zero, layer: 0, onScreen: true, alpha: 1)
        }
        XCTAssertTrue(RemoteControl.pressStillHere(5, onDisplay: [w(6), w(5)]))
        XCTAssertFalse(RemoteControl.pressStillHere(5, onDisplay: [w(6)]))
        XCTAssertFalse(RemoteControl.pressStillHere(5, onDisplay: []))
    }
}
