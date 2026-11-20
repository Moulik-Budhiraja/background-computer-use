import XCTest
import BCUShared
@testable import BCUCore

/// A host app's sessions in the menu bar app: shown and controlled like its
/// own, and the host told when the user stops one there.
final class HostSessionTests: XCTestCase {
    /// Pause all reaches a subscribed host's session too, and the hub knows
    /// the host's process (for its icon) only while it's subscribed.
    func testMenuBarControlsAHostsSessions() {
        let hub = Hub()
        let e = hub.engine(for: "host-session", client: nil, label: "Pick Up O1 Media", host: "ping")
        let release = hub.claim(host: "ping", pid: 4242)
        XCTAssertTrue(hub.hostShowsItself(e))
        XCTAssertEqual(hub.hostPID("ping"), 4242)

        hub.setPausedAll(true)
        XCTAssertTrue(e.paused)
        hub.setPausedAll(false)
        XCTAssertFalse(e.paused)

        release()
        XCTAssertFalse(hub.hostShowsItself(e))
        XCTAssertNil(hub.hostPID("ping"))
    }

    /// Only the menu bar app's engine says it shows host apps' sessions.
    func testHelloSaysWhetherHostsAreShown() {
        let hub = Hub()
        XCTAssertEqual(HostServer(hub: hub, ownerName: "Background Computer Use", version: "1", showsHosts: true).engineInfo()["shows_hosts"] as? Bool, true)
        XCTAssertNil(HostServer(hub: hub, ownerName: "Ping", version: "1").engineInfo()["shows_hosts"])
    }

    /// The user stopping a host's session in the menu bar app reaches the
    /// host as a `stopped` event; the host's own `stop` isn't echoed back.
    func testUserStopTellsTheHost() throws {
        let hub = Hub()
        let server = HostServer(hub: hub, ownerName: "Background Computer Use", version: "1", showsHosts: true)
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        let connection = SocketConnection(fd: fds[0], id: 1)
        defer { connection.finish() }
        let e = hub.engine(for: "host-session", client: nil, label: "Pick Up O1 Media", host: "ping")
        XCTAssertEqual(server.handle("subscribe", ["op": "subscribe", "host": "ping"], connection)?["ok"] as? Bool, true)

        XCTAssertEqual(server.handle("stop", ["op": "stop", "session": "host-session"], connection)?["ok"] as? Bool, true)
        XCTAssertFalse(readEvents(fds[1], seconds: 0.5).contains { $0["event"] as? String == "stopped" })

        e.stopAll(byUser: true)
        let stopped = readEvents(fds[1], seconds: 3, until: { $0["event"] as? String == "stopped" })
            .first { $0["event"] as? String == "stopped" }
        XCTAssertEqual(stopped?["session"] as? String, "host-session")
    }

    /// Lines from the socket for up to `seconds`, or until one matches.
    private func readEvents(_ fd: Int32, seconds: Double, until done: (JSONObject) -> Bool = { _ in false }) -> [JSONObject] {
        var out: [JSONObject] = []
        var buffer = Data()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                if let o = try? JSONSerialization.jsonObject(with: line) as? JSONObject {
                    out.append(o)
                    if done(o) { return out }
                }
            }
        }
        return out
    }
}
