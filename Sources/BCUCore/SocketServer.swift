import Foundation
import BCUShared

/// One client of the socket. Replies and pushed events (see `HostServer`)
/// go out through its own writer queue, so a slow client never holds up
/// the engine.
public final class SocketConnection {
    let fd: Int32
    public let id: Int
    private let writer: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var queued = 0
    private var closeHandlers: [() -> Void] = []

    init(fd: Int32, id: Int) {
        self.fd = fd
        self.id = id
        writer = DispatchQueue(label: "bcu.socket.write.\(id)")
    }

    /// Lines waiting to be written. Frame streams skip a frame while this is high.
    public var backlog: Int {
        lock.lock(); defer { lock.unlock() }
        return queued
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Queue one line of JSON. Any thread.
    public func send(_ object: JSONObject) {
        send(WireCodec.encodeLine(object))
    }

    func send(_ line: Data) {
        lock.lock()
        if closed { lock.unlock(); return }
        queued += 1
        lock.unlock()
        writer.async {
            let ok = line.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let w = write(self.fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { return false }
                    offset += w
                }
                return true
            }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
            if !ok { shutdown(self.fd, SHUT_RDWR) }
        }
    }

    /// Runs once when the client goes away (or right away if it has).
    public func onClose(_ f: @escaping () -> Void) {
        lock.lock()
        if closed { lock.unlock(); f(); return }
        closeHandlers.append(f)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        closed = true
        let handlers = closeHandlers
        closeHandlers = []
        lock.unlock()
        for h in handlers { h() }
        // After queued writes, so a last reply still goes out.
        writer.async { close(self.fd) }
    }
}

/// Line-delimited JSON over a unix socket (mode 0600). One thread per client.
///
/// A line with `tool` is a tool call (see `Wire.swift`). A line with `op`
/// is for host apps and goes to `hostHandler` (see `HostServer`).
public final class SocketServer {
    private let path: String
    private let handler: (String, JSONObject) -> ToolResult
    /// Answers an `op` request; nil for no reply.
    public var hostHandler: ((String, JSONObject, SocketConnection) -> JSONObject?)?
    private var listenFD: Int32 = -1
    private var nextID = 0
    private let idLock = NSLock()

    public init(path: String = BCUPaths.socketPath, handler: @escaping (String, JSONObject) -> ToolResult) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ToolError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ToolError("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else { throw ToolError("bind(\(path)) failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(listenFD, 16) == 0 else { throw ToolError("listen failed") }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "bcu.socket.accept"
        thread.start()
        Log.info("listening on \(path)")
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // A client that went away mid-reply must not kill the engine with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            idLock.lock(); nextID += 1; let id = nextID; idLock.unlock()
            let connection = SocketConnection(fd: client, id: id)
            let thread = Thread { [weak self] in
                self?.serve(connection)
                connection.finish()
            }
            thread.name = "bcu.socket.client"
            thread.start()
        }
    }

    private func serve(_ connection: SocketConnection) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(connection.fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = WireCodec.decode(line) else { continue }
                let id = request["id"] ?? 0
                if let op = request["op"] as? String {
                    let reply = hostHandler?(op, request, connection)
                        ?? (hostHandler == nil ? ["ok": false, "error": "this engine doesn't serve host requests"] : nil)
                    if var reply {
                        reply["id"] = id
                        connection.send(reply)
                    }
                    continue
                }
                let tool = request["tool"] as? String ?? ""
                let args = request["args"] as? JSONObject ?? [:]
                let result = handler(tool, args)
                connection.send(result.wire(id: id))
            }
        }
    }
}
