import XCTest
@testable import BCUCore
import BCUShared

final class ArgsAndClientTests: XCTestCase {
    func testWindowIDsOutsideUInt32AreAToolErrorNotATrap() throws {
        XCTAssertEqual(try Args(["window_id": 42]).windowID("window_id"), 42)
        XCTAssertEqual(try Args(["window_id": "42"]).windowID("window_id"), 42)
        XCTAssertEqual(try Args(["window_id": 4_294_967_295]).requireWindowID("window_id"), 4_294_967_295)
        XCTAssertNil(try Args([:]).windowID("window_id"))
        XCTAssertNil(try Args(["window_id": NSNull()]).windowID("window_id"))
        for bad: Any in [-1, 4_294_967_296, Int.max, 1e300, Double.nan, "x"] {
            XCTAssertThrowsError(try Args(["window_id": bad]).windowID("window_id"), "\(bad)")
        }
        XCTAssertThrowsError(try Args([:]).requireWindowID("window_id"))
    }

    func testIntDoesNotTrapOnHugeDoubles() {
        XCTAssertNil(Args(["n": 1e300]).int("n"))
        XCTAssertNil(Args(["n": -Double.infinity]).int("n"))
        XCTAssertEqual(Args(["n": 3.0]).int("n"), 3)
    }

    /// A connection the app has closed is seen as closed before a call goes
    /// out on it, so `bcu mcp` reconnects instead of sending into it.
    func testClientSeesTheAppCloseItsConnection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString.prefix(8).description)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)

        let client = try SocketClient(path: path)
        let server = Darwin.accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(server, 0)
        XCTAssertTrue(client.isOpen)
        close(server)
        usleep(50_000)
        XCTAssertFalse(client.isOpen)
    }
}
