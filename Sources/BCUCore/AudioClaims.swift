import AppKit
import ApplicationServices

/// Apps the user also has windows in whose sound an agent asked to keep off
/// the speakers before playing some (`capture_audio`). Sound comes from the
/// app as a whole, so muting it mutes the user's windows of it too: that's
/// only done while the app is quiet, and given back the moment the user
/// presses a key or clicks in it (or presses a media key), since they may be
/// about to play something. Before giving it back, the agent's own sound is
/// silenced with the element it named (a mute or pause button in its
/// window), and the agent is told on its next call.
final class AudioClaims {
    struct Claim {
        let window: CGWindowID
        let pid: pid_t
        let appName: String
        /// Silences the agent's sound when pressed: nil until the agent names
        /// one (a tab's mute button shows only once it plays).
        let mute: AXUIElement?
        let muteName: String
    }

    private let lock = NSLock()
    private var claims: [CGWindowID: Claim] = [:]
    private var notes: [String] = []
    /// Off the input tap's thread: finding the window under a click and
    /// pressing the mute element take milliseconds.
    private let queue = DispatchQueue(label: "bcu.audio.claims", qos: .userInteractive)

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return claims.isEmpty }

    func add(_ claim: Claim) {
        lock.lock(); claims[claim.window] = claim; lock.unlock()
    }

    func has(_ window: CGWindowID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return claims[window] != nil
    }

    /// The claimed apps, dropping claims on windows that are gone.
    func pids(open: Set<CGWindowID>) -> Set<pid_t> {
        lock.lock(); defer { lock.unlock() }
        claims = claims.filter { open.contains($0.key) }
        return Set(claims.values.map(\.pid))
    }

    /// What happened since the agent's last call, for its next result.
    func takeNotes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let n = notes
        notes = []
        return n
    }

    /// Tap thread: must return at once. `release` silences and un-mutes;
    /// it runs on `queue` with the claims the user's input touched and what
    /// the user did ("started using", for "The user started using Helium").
    func userInput(_ input: FocusGuard.UserInput, release: @escaping ([Claim], String) -> Void) {
        guard !isEmpty else { return }
        queue.async {
            // nil: every claimed app (a media key goes to whichever app
            // last played).
            let pid: pid_t?
            switch input {
            case .key(let front): pid = front
            case .click(let p):
                guard let owner = FocusGuard.windowOwner(at: p) else { return }
                pid = owner
            case .mediaKey: pid = nil
            }
            self.lock.lock()
            let hit = self.claims.values.filter { pid == nil || $0.pid == pid }
            if !hit.isEmpty { Log.info("audio: user input \(input) in pid \(pid.map(String.init) ?? "any") ends \(hit.count) claim(s)") }
            for c in hit { self.claims[c.window] = nil }
            self.lock.unlock()
            if !hit.isEmpty { release(hit, pid == nil ? "pressed a media key, which can play sound in" : "started using") }
        }
    }

    /// Silence each claim's sound with its element (accessibility only, so
    /// it doesn't touch the user's focus). Returns a note per claim.
    func silence(_ hit: [Claim], why: String) -> [String] {
        hit.map { c in
            let n: String
            guard let mute = c.mute else {
                n = "The user \(why) \(c.appName), so it plays on their speakers again. You hadn't named an element to silence your sound with: if it's still playing in window \(c.window), stop it now."
                lock.lock(); notes.append(n); lock.unlock()
                return n
            }
            let err = AX.perform(mute, "AXPress")
            if err == .success {
                n = "The user \(why) \(c.appName), so your sound there was silenced with \(c.muteName) in window \(c.window), and \(c.appName) plays on their speakers again. To play sound in it again, call capture_audio again, then unmute."
            } else {
                n = "The user \(why) \(c.appName), so it plays on their speakers again, but \(c.muteName) in window \(c.window) couldn't be pressed (\(AX.errorName(err))): if your sound is still playing there, stop it now."
            }
            lock.lock(); notes.append(n); lock.unlock()
            return n
        }
    }

    func clear() {
        lock.lock(); claims = [:]; lock.unlock()
    }
}
