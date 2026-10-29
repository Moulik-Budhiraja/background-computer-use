import Foundation
import BCUShared

/// Line-delimited JSON over a unix socket (mode 0600). One thread per client.
public final class SocketServer {
    private let path: String
    private let handler: (String, JSONObject) -> ToolResult
    private var listenFD: Int32 = -1

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
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "bcu.socket.client"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = WireCodec.decode(line) else { continue }
                let id = request["id"] ?? 0
                let tool = request["tool"] as? String ?? ""
                let args = request["args"] as? JSONObject ?? [:]
                let result = handler(tool, args)
                let out = WireCodec.encodeLine(result.wire(id: id))
                let ok = out.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < raw.count {
                        let w = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if w <= 0 { return false }
                        offset += w
                    }
                    return true
                }
                if !ok { return }
            }
        }
    }
}
