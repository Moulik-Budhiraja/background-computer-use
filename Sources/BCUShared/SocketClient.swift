import Foundation

/// Blocking line-based client for the app's unix socket.
public final class SocketClient {
    private let fd: Int32
    private var buffer = Data()
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

    public func call(tool: String, args: JSONObject) throws -> ToolResult {
        ToolResult(wire: try request(["tool": tool, "args": args]))
    }

    /// One request (a tool call, or a host `op`) and its reply. Not for a
    /// connection that has subscribed to events.
    public func request(_ object: JSONObject) throws -> JSONObject {
        let id = nextID
        nextID += 1
        var object = object
        object["id"] = id
        let line = WireCodec.encodeLine(object)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 {
                    // The engine may have refused this connection and said why.
                    if let line = try? readLine(), let o = WireCodec.decode(line), o["ok"] as? Bool == false {
                        throw SocketError.refused(o["error"] as? String ?? "the engine refused this connection")
                    }
                    // Without its newline the app can't have run any of it.
                    throw SocketError.notSent
                }
                offset += n
            }
        }
        let response = try readLine()
        guard let object = WireCodec.decode(response) else {
            throw SocketError.message("bad response from app")
        }
        return object
    }

    private func readLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw SocketError.message("app closed the connection") }
            buffer.append(chunk, count: n)
        }
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case notRunning
    /// The request never reached the app, so it's safe to send again.
    case notSent
    /// The engine refused this connection (its code signature check), with why.
    case refused(String)
    case message(String)

    public var description: String {
        switch self {
        case .notRunning: return "Background Computer Use is not running"
        case .notSent: return "couldn't send the request to the app"
        case .refused(let why): return why
        case .message(let m): return m
        }
    }
}
