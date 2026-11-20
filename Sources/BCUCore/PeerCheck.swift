import Foundation
import Security
import BCUShared

// Who may use the engine's socket. Mode 0600 keeps other users out, but any
// process of this user could connect, call tools, take sessions over and
// send input with the Accessibility and Screen Recording this app has been
// granted. So `SocketServer` asks for the peer's code signature first
// (`PeerInspector`) and lets it in only if `PeerPolicy` says so.

/// What a connection may see and drive.
public enum PeerTrust: Equatable {
    /// The engine's own code: its developer team, its own app, or what
    /// `bcu serve --trust-client` names. Sees every session.
    case owner
    /// Another developer's app that ships `bcu` (a host, or the menu bar
    /// app talking to a host's engine). Sees only its team's sessions.
    case app(team: String)

    /// Whether this connection may use what `other` started.
    public func mayUse(_ other: PeerTrust) -> Bool {
        self == .owner || self == other
    }
}

/// The peer's code signature, as `PeerInspector` read it.
public struct PeerIdentity: Equatable {
    /// Its code on disk, symlinks resolved: a bundle, or a bare executable.
    public var path: String?
    /// The signature is intact (ad hoc counts).
    public var valid: Bool
    /// The developer team, only when an Apple-issued certificate vouches for it.
    public var team: String?
    public var cdhash: Data?

    public init(path: String?, valid: Bool, team: String?, cdhash: Data?) {
        self.path = path
        self.valid = valid
        self.team = team
        self.cdhash = cdhash
    }
}

public enum PeerDecision: Equatable {
    case allow(PeerTrust)
    case deny(String)
}

/// The engine's own signature and what else it trusts. Pure: `decide` is
/// the whole policy.
public struct PeerPolicy: Equatable {
    /// Our team, when a Developer ID certificate vouches for it; nil for an
    /// ad hoc or unsigned build.
    public var team: String?
    public var cdhash: Data?
    /// The outermost app bundle we run from, or our executable's folder.
    public var home: String?
    /// `--trust-client`: team IDs, or paths (a binary, a bundle or a folder).
    public var trusted: [String]

    public init(team: String?, cdhash: Data?, home: String?, trusted: [String] = []) {
        self.team = team
        self.cdhash = cdhash
        self.home = home
        self.trusted = trusted
    }

    /// `shipsBCU(bundle, peer)`: that app bundle has a `bcu` signed by the
    /// peer's team (`HostCheck.vouches`). Asked only when nothing cheaper decided.
    public func decide(_ peer: PeerIdentity?, shipsBCU: (String, PeerIdentity) -> Bool) -> PeerDecision {
        guard let peer else { return .deny("the connecting process went away or its code signature couldn't be read") }
        let name = peer.path ?? "the connecting process"
        for t in trusted {
            if Self.isTeamID(t) {
                if peer.team == t { return .allow(.owner) }
            } else if let path = peer.path, Self.path(path, isInside: t) {
                return .allow(.owner)
            }
        }
        guard peer.valid else { return .deny("\(name) isn't validly signed") }
        // The same binary as this one: `bcu mcp` talking to `bcu serve`.
        if let mine = cdhash, peer.cdhash == mine { return .allow(.owner) }
        if let mine = team {
            if peer.team == mine { return .allow(.owner) }
        } else if let home, let path = peer.path, Self.path(path, isInside: home) {
            // An ad hoc build has no team to go by: trust what's in its own app.
            return .allow(.owner)
        }
        // Another developer's app that ships bcu, signed by that developer.
        if let theirs = peer.team, let app = peer.path.flatMap(Self.outermostApp), shipsBCU(app, peer) {
            return .allow(.app(team: theirs))
        }
        return .deny("\(name) isn't part of an app that ships bcu, signed by the same developer")
    }

    /// `decide`, with `later()` for names added to `trusted` while the
    /// engine runs.
    public func decide(_ peer: PeerIdentity?, later: () -> [String], shipsBCU: (String, PeerIdentity) -> Bool) -> PeerDecision {
        decide(peer, shipsBCU: shipsBCU)
    }

    /// A developer team ID: ten uppercase letters and digits.
    public static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// A `--trust-client` path as the policy compares it with peers' paths.
    /// A peer running an app's main executable has the app's path, so that
    /// executable (`process.execPath` in Electron) stands for its app.
    public static func trustedPath(_ path: String, bundleExecutable: (String) -> String?) -> String {
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards),
              !path[range.upperBound...].contains("/") else { return path }
        let app = String(path[..<range.lowerBound]) + ".app"
        return bundleExecutable(app) == path ? app : path
    }

    public static func path(_ path: String, isInside dir: String) -> Bool {
        let d = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return !d.isEmpty && (path == d || path.hasPrefix(d + "/"))
    }

    /// The outermost `.app` in a path: an Electron helper app's path gives
    /// the app it's inside.
    public static func outermostApp(_ path: String) -> String? {
        var prefix = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + part
            if part.hasSuffix(".app") { return prefix }
        }
        return nil
    }

    /// Where an app may keep its `bcu`, relative to its bundle. Folders
    /// under Resources are searched one level deep (`Resources/bin/bcu`).
    public static let bcuLocations = ["Contents/MacOS/bcu", "Contents/Helpers/bcu", "Contents/Resources/bcu"]
}

/// Reads code signatures: the peer's, through its audit token, and our own.
public enum PeerInspector {
    /// The peer of a connected unix socket.
    public static func identity(fd: Int32) -> PeerIdentity? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return nil }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: data] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        return identity(of: code)
    }

    /// This process's executable, symlinks resolved.
    /// The kernel's path for it (`Bundle.main`); argv[0] is only a fallback,
    /// since it's a bare name when the engine was started through PATH and
    /// would resolve against the working folder.
    static func ownExecutable(argv0: String, mainExecutable: String?) -> String {
        URL(fileURLWithPath: mainExecutable ?? argv0).resolvingSymlinksInPath().path
    }

    public static func ownPolicy(trusted: [String] = []) -> PeerPolicy {
        var code: SecCode?
        let me = SecCodeCopySelf([], &code) == errSecSuccess ? code.map(identity(of:)) : nil
        let exe = ownExecutable(argv0: CommandLine.arguments[0], mainExecutable: Bundle.main.executableURL?.path)
        let home = PeerPolicy.outermostApp(exe) ?? (exe as NSString).deletingLastPathComponent
        return PeerPolicy(team: me?.team, cdhash: me?.cdhash, home: home, trusted: resolve(trusted: trusted))
    }

    /// Trusted names as the policy compares them: team IDs as they are,
    /// paths with symlinks resolved and a main executable as its app.
    public static func resolve(trusted: [String]) -> [String] {
        trusted.map { t -> String in
            if PeerPolicy.isTeamID(t) { return t }
            return PeerPolicy.trustedPath(URL(fileURLWithPath: t).resolvingSymlinksInPath().path) {
                Bundle(path: $0)?.executableURL?.resolvingSymlinksInPath().path
            }
        }
    }

    private static func identity(of code: SecCode) -> PeerIdentity {
        let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return PeerIdentity(path: nil, valid: false, team: nil, cdhash: nil)
        }
        var url: CFURL?
        let path = SecCodeCopyPath(staticCode, [], &url) == errSecSuccess
            ? (url as URL?)?.resolvingSymlinksInPath().path : nil
        var info: CFDictionary?
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        let cdhash = dict[kSecCodeInfoUnique as String] as? Data
        // The team ID in a signature is only a claim until a certificate
        // chain to Apple backs it.
        var team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if let t = team, !(valid && SecCodeCheckValidity(code, [], requirement(team: t)) == errSecSuccess) { team = nil }
        return PeerIdentity(path: path, valid: valid, team: team, cdhash: cdhash)
    }

    /// Signed by that team, through an Apple-issued certificate.
    static func requirement(team: String) -> SecRequirement? {
        guard PeerPolicy.isTeamID(team) else { return nil }
        var req: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        return SecRequirementCreateWithString(text, [], &req) == errSecSuccess ? req : nil
    }

    private static let vouched = VouchCache()

    /// `HostCheck.vouches` on the real disk. Remembered once true, for that
    /// code (its cdhash) in that app.
    public static func shipsBCU(app: String, peer: PeerIdentity) -> Bool {
        let key = "\(peer.team ?? "") \(peer.cdhash?.map { String(format: "%02x", $0) }.joined() ?? "") \(app)"
        return vouched.check(key, fingerprint: { bundleFingerprint(app) }) {
            HostCheck.vouches(app: app, peer: peer, disk: RealDisk())
        }
    }

    /// Every file and folder in the bundle, by inode, change time and size.
    /// The change time is the kernel's: no one can set it back, so a file
    /// replaced or rewritten since gives another fingerprint.
    static func bundleFingerprint(_ app: String) -> Int? {
        var hasher = Hasher()
        func add(_ path: String) -> Bool {
            var st = stat()
            guard lstat(path, &st) == 0 else { return false }
            hasher.combine(path)
            hasher.combine(st.st_dev); hasher.combine(st.st_ino); hasher.combine(st.st_mode); hasher.combine(st.st_size)
            hasher.combine(st.st_ctimespec.tv_sec); hasher.combine(st.st_ctimespec.tv_nsec)
            return true
        }
        guard add(app), let items = FileManager.default.enumerator(atPath: app) else { return nil }
        while let item = items.nextObject() as? String {
            guard add("\(app)/\(item)") else { return nil }
        }
        return hasher.finalize()
    }

    /// Code on disk, read through the Security framework.
    struct RealDisk: CodeOnDisk {
        func isSealedApp(_ path: String, team: String) -> Bool {
            guard let req = PeerInspector.requirement(team: team), let code = staticCode(path) else { return false }
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), req) == errSecSuccess
        }

        func isSigned(_ path: String, team: String) -> Bool {
            guard let req = PeerInspector.requirement(team: team), let code = staticCode(path) else { return false }
            return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }

        func cdhashes(_ path: String) -> Set<Data> {
            // Each slice of a universal binary has its own; a process under
            // Rosetta runs the Intel one.
            var hashes: Set<Data> = []
            for arch in [nil, "arm64", "x86_64"] as [String?] {
                var code: SecStaticCode?
                let attrs = (arch.map { [kSecCodeAttributeArchitecture: $0] } ?? [:]) as CFDictionary
                guard SecStaticCodeCreateWithPathAndAttributes(URL(fileURLWithPath: path) as CFURL, [], attrs, &code) == errSecSuccess,
                      let code else { continue }
                var info: CFDictionary?
                SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                if let h = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data { hashes.insert(h) }
            }
            return hashes
        }

        func isExecutable(_ path: String) -> Bool {
            FileManager.default.isExecutableFile(atPath: path)
        }

        func subfolders(_ path: String) -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }

        private func staticCode(_ path: String) -> SecStaticCode? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess else { return nil }
            return code
        }
    }
}

/// `HostCheck.vouches` results that passed, so a host's next connection
/// doesn't check its whole bundle again.
final class VouchCache {
    private let lock = NSLock()
    private var passed: [String: Int] = [:]

    /// `verify`'s answer for `key`, or a remembered pass. `fingerprint`
    /// describes what the answer depends on (nil: can't tell).
    func check(_ key: String, fingerprint: () -> Int?, verify: () -> Bool) -> Bool {
        // Taken before checking: a change during the check shows next time.
        let now = fingerprint()
        lock.lock()
        let known = now != nil && passed[key] == now
        lock.unlock()
        if known { return true }
        let ok = verify()
        lock.lock(); passed[key] = ok ? now : nil; lock.unlock()
        return ok
    }
}

/// What `HostCheck` reads from disk: real signatures in the engine
/// (`PeerInspector.RealDisk`), a fake in tests.
public protocol CodeOnDisk {
    /// The app bundle's signature and resource seal are intact, and an
    /// Apple-issued certificate for `team` signed it.
    func isSealedApp(_ path: String, team: String) -> Bool
    /// The code at `path` is validly signed by `team` through an Apple-issued certificate.
    func isSigned(_ path: String, team: String) -> Bool
    /// The code directory hashes of the code at `path` (of a bundle's main
    /// executable, for a bundle), one per architecture.
    func cdhashes(_ path: String) -> Set<Data>
    func isExecutable(_ path: String) -> Bool
    func subfolders(_ path: String) -> [String]
}

/// Whether another developer's app vouches for a process in it.
public enum HostCheck {
    /// The app at `app` ships a `bcu` (see `PeerPolicy.bcuLocations`) signed
    /// by the peer's team, and the app itself is signed by that team with
    /// its seal intact. A file named bcu in a folder named .app proves
    /// nothing: anyone can copy a signed program there.
    public static func vouches(app: String, peer: PeerIdentity, disk: CodeOnDisk) -> Bool {
        guard let team = peer.team else { return false }
        // The peer is code in that app as it is on disk now: the seal below
        // vouches for what's there, not for whatever the peer was started from.
        guard let path = peer.path, PeerPolicy.path(path, isInside: app),
              let cdhash = peer.cdhash, disk.cdhashes(path).contains(cdhash) else { return false }
        var candidates = PeerPolicy.bcuLocations.map { "\(app)/\($0)" }
        let resources = "\(app)/Contents/Resources"
        for sub in disk.subfolders(resources) { candidates.append("\(resources)/\(sub)/bcu") }
        guard candidates.contains(where: { disk.isExecutable($0) && disk.isSigned($0, team: team) }) else { return false }
        return disk.isSealedApp(app, team: team)
    }
}

/// Which app started each session and owns each host ID, so one host's
/// client can't see or drive another's. Sessions and host IDs go to the
/// first connection that names them; the engine's own code may use them all.
public final class PeerScope {
    private let lock = NSLock()
    private var sessions: [String: PeerTrust] = [:]
    private var hosts: [String: PeerTrust] = [:]

    public init() {}

    /// Who started the session, if anyone has called for it yet.
    public func owner(ofSession id: String) -> PeerTrust? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    /// May `trust` see and drive this session? One no one has called for
    /// yet (restored after a restart, say) is the engine's own.
    public func mayUse(session id: String, _ trust: PeerTrust) -> Bool {
        trust.mayUse(owner(ofSession: id) ?? .owner)
    }

    /// A tool call: claims its session (and host ID) for the caller, or
    /// says why it can't have them.
    /// `windowOwners`: the sessions that have the windows the call names.
    public func admitCall(session: String, parent: String?, host: String?, windowOwners: [String] = [],
                          _ trust: PeerTrust) -> String? {
        lock.lock(); defer { lock.unlock() }
        // A call without `_session` lands in the default session, `bcu
        // call`'s, which is the engine's own: another app names its own.
        if trust != .owner, session == Hub.defaultSession || parent == Hub.defaultSession {
            return "Name a session with _session: the default session belongs to the engine's own app."
        }
        for s in [session, parent].compactMap({ $0 }) {
            if let o = sessions[s], !trust.mayUse(o) { return "Session \(s) belongs to another app." }
        }
        if let host, !host.isEmpty, let o = hosts[host], !trust.mayUse(o) { return "Host \(host) belongs to another app." }
        // A window of another app's session: the hub would send the call to
        // that session, or hand its windows over if its agent went away.
        for s in windowOwners where !trust.mayUse(sessions[s] ?? .owner) { return "That window belongs to another app." }
        if sessions[session] == nil { sessions[session] = trust }
        // A subagent's family is its parent's: claim the parent with it, or
        // another app could claim it and reach the subagent through it.
        if let parent, sessions[parent] == nil { sessions[parent] = trust }
        if let host, !host.isEmpty, hosts[host] == nil { hosts[host] = trust }
        return nil
    }

    /// A host op naming a host ID (`subscribe`, `recordings`): the first
    /// app to name it keeps it, the engine's own code included (a host
    /// running its own engine), so no other app can set its recordings.
    public func claimHost(_ host: String, _ trust: PeerTrust) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let o = hosts[host] { return trust.mayUse(o) }
        hosts[host] = trust
        return true
    }
}
