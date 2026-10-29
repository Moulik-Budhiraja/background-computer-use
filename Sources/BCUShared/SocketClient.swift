import Foundation

/// Blocking line-based client for the app's unix socket.
public final class SocketClient {
    private let fd: Int32
    private var buffer = Data()
    private var nextID = 1

    public init(path: String = BCUPaths.socketPath) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.message("socket() failed") }
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

    public func call(tool: String, args: JSONObject) throws -> ToolResult {
        let id = nextID
        nextID += 1
        let line = WireCodec.encodeLine(["id": id, "tool": tool, "args": args])
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw SocketError.message("write failed") }
                offset += n
            }
        }
        let response = try readLine()
        guard let object = WireCodec.decode(response) else {
            throw SocketError.message("bad response from app")
        }
        return ToolResult(wire: object)
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
    case message(String)

    public var description: String {
        switch self {
        case .notRunning: return "Background Computer Use is not running"
        case .message(let m): return m
        }
    }
}
