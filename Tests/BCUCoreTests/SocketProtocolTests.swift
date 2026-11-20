import XCTest
@testable import BCUCore
import BCUShared

/// The socket's line protocol, over a real unix socket in a temp folder.
/// Nothing here needs any permission.
final class SocketProtocolTests: XCTestCase {
    func testLineBufferSplitsLinesAcrossChunks() {
        var buffer = LineBuffer()
        buffer.append(Data("ab".utf8))
        XCTAssertNil(buffer.nextLine())
        buffer.append(Data("c\nde\n\nf".utf8))
        XCTAssertEqual(buffer.nextLine(), Data("abc".utf8))
        XCTAssertEqual(buffer.nextLine(), Data("de".utf8))
        XCTAssertEqual(buffer.nextLine(), Data())
        XCTAssertNil(buffer.nextLine())
        XCTAssertEqual(buffer.count, 1)
        buffer.append(Data("g\n".utf8))
        XCTAssertEqual(buffer.nextLine(), Data("fg".utf8))
        XCTAssertEqual(buffer.count, 0)
    }

    func testLineBufferBigLineInSmallChunks() {
        var buffer = LineBuffer()
        let chunk = [UInt8](repeating: 0x61, count: 65536)
        for _ in 0..<64 {
            buffer.append(chunk, count: chunk.count)
            XCTAssertNil(buffer.nextLine())
        }
        buffer.append([0x0A], count: 1)
        XCTAssertEqual(buffer.nextLine()?.count, 64 * 65536)
    }

    /// `status` answers at once, so a stuck app shows within seconds
    /// (`bcu status`, `bcu call status`). Other tools keep the long wait.
    func testStatusTimesOutSoonOtherToolsWaitLonger() {
        XCTAssertLessThanOrEqual(SocketClient.timeout(for: "status"), 15)
        XCTAssertEqual(SocketClient.timeout(for: "type_text"), SocketClient.callTimeout)
    }

    private var path = ""
    private var server: SocketServer!

    override func setUp() {
        // Short: a unix socket path has to fit in 104 bytes.
        path = "/tmp/bcu-test-\(getpid())-\(Int.random(in: 0..<1_000_000)).sock"
        server = SocketServer(path: path) { tool, args in
            if tool == "slow" { usleep(300_000) }
            return ToolResult(text: "\(tool) \(args["n"] as? Int ?? 0)")
        }
        XCTAssertNoThrow(try server.start())
    }

    override func tearDown() {
        server?.stop()
    }

    func testRepliesMatchTheirRequests() throws {
        let client = try SocketClient(path: path)
        for n in 1...3 {
            let result = try client.call(tool: "echo", args: ["n": n])
            XCTAssertEqual(result.text, "echo \(n)")
        }
    }

    func testTimeoutFailsInsteadOfHanging() throws {
        let client = try SocketClient(path: path)
        XCTAssertThrowsError(try client.call(tool: "slow", args: [:], timeout: 0.05))
    }

    func testMalformedLineGetsAnError() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let line = Array("not json\n".utf8)
        XCTAssertEqual(write(fd, line, line.count), line.count)
        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var reply: Data?
        while reply == nil {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return XCTFail("no reply") }
            buffer.append(chunk, count: n)
            reply = buffer.nextLine()
        }
        let object = try XCTUnwrap(WireCodec.decode(reply!))
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue(object["id"] is NSNull)
    }
}

/// `status` has a short timeout, so it can't wait behind a session's
/// long call (a batch of waits, slow typing).
final class StatusOffQueueTests: XCTestCase {
    func testStatusSkipsTheSessionQueue() {
        XCTAssertTrue(Engine.answersOffQueue("status"))
        XCTAssertFalse(Engine.answersOffQueue("type_text"))
        XCTAssertFalse(Engine.answersOffQueue("get_window_state"))
    }

    /// An agent that only polls status is still alive: its session isn't
    /// forgotten as dormant.
    func testStatusOffQueueCountsAsACall() {
        var touched = 0
        let result = Engine.answerOffQueue("status", touch: { touched += 1 }, run: { ToolResult(text: "ok") })
        XCTAssertEqual(result?.text, "ok")
        XCTAssertEqual(touched, 1)
        XCTAssertNil(Engine.answerOffQueue("click", touch: { touched += 1 }, run: { ToolResult(text: "no") }))
        XCTAssertEqual(touched, 1)
    }
}
