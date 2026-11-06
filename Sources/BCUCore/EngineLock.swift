import Foundation
import BCUShared

/// One engine per Mac. Two would fight: two focus guards putting different
/// apps back in front, two cursor fences, two sets of displays. Whoever
/// runs the engine (this app, or a host app's `bcu serve`) holds an flock
/// on `BCUPaths.lockPath` for as long as it runs, and everyone else uses
/// that engine through its socket. The lock goes with the process, so a
/// crash frees it.
public final class EngineLock {
    /// Who holds it, as written in the lock file.
    public struct Owner {
        public let pid: pid_t
        public let name: String
        public let version: String
    }

    private let fd: Int32
    public let owner: Owner

    private init(fd: Int32, owner: Owner) {
        self.fd = fd
        self.owner = owner
    }

    deinit { close(fd) }

    /// Take the lock, or nil if another engine holds it (`current()` says who).
    public static func acquire(name: String, version: String) -> EngineLock? {
        try? FileManager.default.createDirectory(at: BCUPaths.supportDirectory, withIntermediateDirectories: true)
        let fd = open(BCUPaths.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        // An engine from before the lock existed (0.1.15 and older) serves the
        // socket without it. Don't take the socket from under it.
        if let probe = try? SocketClient() {
            _ = probe
            flock(fd, LOCK_UN)
            close(fd)
            return nil
        }
        let owner = Owner(pid: getpid(), name: name, version: version)
        let line = "\(owner.pid)\n\(owner.name)\n\(owner.version)\n"
        ftruncate(fd, 0)
        _ = line.withCString { write(fd, $0, strlen($0)) }
        return EngineLock(fd: fd, owner: owner)
    }

    /// Whoever holds the lock now, if anyone. Nil also for an engine from
    /// before the lock existed.
    public static func current() -> Owner? {
        let fd = open(BCUPaths.lockPath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Free means no one holds it.
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard let text = try? String(contentsOfFile: BCUPaths.lockPath, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let pid = pid_t(parts[0]) else { return nil }
        return Owner(pid: pid, name: parts[1], version: parts[2])
    }
}
