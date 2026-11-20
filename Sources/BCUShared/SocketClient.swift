import Foundation

/// Blocking line-based client for the app's unix socket.
public final class SocketClient {
    private let fd: Int32
    private var buffer = LineBuffer()
    private var nextID = 1

    public init(path: String = BCUPaths.socketPath) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.message("socket() failed") }
        // If the app restarted, writing to the old connection must fail with
        // an error (so the caller reconnects), not kill this process with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SocketError.message("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard result == 0 else {
            close(fd)
            throw SocketError.notRunning
        }
    }

    deinit { close(fd) }

    /// False once the app has closed this connection (it quit or restarted).
    /// Checked before a call, so a stale connection is replaced before the
    /// request goes out rather than after, when it may already have run.
    public var isOpen: Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) >= 0 else { return false }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
        guard p.revents & Int16(POLLIN) != 0 else { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
    }

    /// How long a tool call may take before the app counts as stuck. The
    /// longest legitimate wait (for a free display) is well under this.
    public static let callTimeout: TimeInterval = 300

    /// How long a call of this tool may take. `status` answers at once, so
    /// a stuck app shows within seconds.
    public static func timeout(for tool: String) -> TimeInterval {
        tool == "status" ? 10 : callTimeout
    }

    public func call(tool: String, args: JSONObject, timeout: TimeInterval? = nil) throws -> ToolResult {
        ToolResult(wire: try request(["tool": tool, "args": args], timeout: timeout ?? Self.timeout(for: tool)))
    }

    /// One request (a tool call, or a host `op`) and its reply. Not for a
    /// connection that has subscribed to events. After a timeout the
    /// connection is spent: make a new client.
    public func request(_ object: JSONObject, timeout: TimeInterval = SocketClient.callTimeout) throws -> JSONObject {
        let id = nextID
        nextID += 1
        var object = object
        object["id"] = id
        let line = WireCodec.encodeLine(object)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                // Without its newline the app can't have run any of it.
                if n <= 0 { throw SocketError.notSent }
                offset += n
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let response = try readLine(deadline: deadline, timeout: timeout)
            guard let reply = WireCodec.decode(response) else {
                throw SocketError.message("bad response from app")
            }
            // Ours, or the app's answer to a line it couldn't read (no id).
            // Anything else is a late reply to an earlier request.
            if let got = reply["id"] as? Int, got == id { return reply }
            if reply["id"] == nil || reply["id"] is NSNull, reply["event"] == nil { return reply }
        }
    }

    private func readLine(deadline: Date, timeout: TimeInterval) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let line = buffer.nextLine() { return line }
            let ms = Int(deadline.timeIntervalSinceNow * 1000)
            if ms <= 0 {
                shutdown(fd, SHUT_RDWR)
                throw SocketError.message("\(BCUPaths.appName) isn't answering (no reply in \(Int(timeout)) s)")
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(ms, Int(Int32.max))))
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { throw SocketError.message("app closed the connection") }
            if ready == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { throw SocketError.message("app closed the connection") }
            buffer.append(chunk, count: n)
        }
    }
}

/// Splits a byte stream into newline-terminated lines. Each byte is looked
/// at once, so a multi-megabyte line (a screenshot) arriving in 64 KB reads
/// costs linear time, not quadratic.
public struct LineBuffer {
    private var data = Data()
    /// Bytes before this offset hold no newline.
    private var scanned = 0

    public init() {}

    public var count: Int { data.count }

    public mutating func append(_ bytes: [UInt8], count: Int) {
        data.append(contentsOf: bytes[0..<count])
    }

    public mutating func append(_ bytes: Data) {
        data.append(bytes)
    }

    /// The next whole line, without its newline, or nil until one arrives.
    public mutating func nextLine() -> Data? {
        let start = data.startIndex
        guard let newline = data[(start + scanned)...].firstIndex(of: 0x0A) else {
            scanned = data.count
            return nil
        }
        let line = Data(data[start..<newline])
        // Keep only what follows (usually nothing); a fresh Data restarts at index 0.
        data = Data(data[(newline + 1)...])
        scanned = 0
        return line
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case notRunning
    /// The request never reached the app, so it's safe to send again.
    case notSent
    case message(String)

    public var description: String {
        switch self {
        case .notRunning: return "Background Computer Use is not running"
        case .notSent: return "couldn't send the request to the app"
        case .message(let m): return m
        }
    }
}
