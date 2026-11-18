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

    /// `shipsBCU(bundle, team)`: that app bundle has a `bcu` signed by that
    /// team. Asked only when nothing cheaper decided.
    public func decide(_ peer: PeerIdentity?, shipsBCU: (String, String) -> Bool) -> PeerDecision {
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
        if let theirs = peer.team, let app = peer.path.flatMap(Self.outermostApp), shipsBCU(app, theirs) {
            return .allow(.app(team: theirs))
        }
        return .deny("\(name) isn't part of an app that ships bcu, signed by the same developer")
    }

    /// A developer team ID: ten uppercase letters and digits.
    public static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
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

    public static func ownPolicy(trusted: [String] = []) -> PeerPolicy {
        var code: SecCode?
        let me = SecCodeCopySelf([], &code) == errSecSuccess ? code.map(identity(of:)) : nil
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let home = PeerPolicy.outermostApp(exe) ?? (exe as NSString).deletingLastPathComponent
        let resolved = trusted.map { PeerPolicy.isTeamID($0) ? $0 : URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return PeerPolicy(team: me?.team, cdhash: me?.cdhash, home: home, trusted: resolved)
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

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var shipping: Set<String> = []

    /// The app bundle has a `bcu` (see `PeerPolicy.bcuLocations`) signed by
    /// that team. Remembered once true.
    public static func shipsBCU(app: String, team: String) -> Bool {
        let key = "\(team) \(app)"
        cacheLock.lock()
        let known = shipping.contains(key)
        cacheLock.unlock()
        if known { return true }
        guard let req = requirement(team: team) else { return false }
        var candidates = PeerPolicy.bcuLocations.map { "\(app)/\($0)" }
        let resources = "\(app)/Contents/Resources"
        for sub in (try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? [] {
            candidates.append("\(resources)/\(sub)/bcu")
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { continue }
            if SecStaticCodeCheckValidity(code, [], req) == errSecSuccess {
                cacheLock.lock(); shipping.insert(key); cacheLock.unlock()
                return true
            }
        }
        return false
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
    public func admitCall(session: String, parent: String?, host: String?, _ trust: PeerTrust) -> String? {
        lock.lock(); defer { lock.unlock() }
        for s in [session, parent].compactMap({ $0 }) {
            if let o = sessions[s], !trust.mayUse(o) { return "Session \(s) belongs to another app." }
        }
        if let host, !host.isEmpty, let o = hosts[host], !trust.mayUse(o) { return "Host \(host) belongs to another app." }
        if sessions[session] == nil { sessions[session] = trust }
        if let host, !host.isEmpty, hosts[host] == nil, trust != .owner { hosts[host] = trust }
        return nil
    }

    /// A host op naming a host ID (`subscribe`, `recordings`): the first
    /// app to name it keeps it.
    public func claimHost(_ host: String, _ trust: PeerTrust) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let o = hosts[host] { return trust.mayUse(o) }
        if trust != .owner { hosts[host] = trust }
        return true
    }
}
