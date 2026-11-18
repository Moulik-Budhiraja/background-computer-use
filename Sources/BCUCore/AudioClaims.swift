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

    /// Every session's claims, to tell whose sound a claimed app plays.
    private static let all = NSHashTable<AudioClaims>.weakObjects()
    private static let allLock = NSLock()

    init() {
        Self.allLock.lock(); Self.all.add(self); Self.allLock.unlock()
    }

    /// Some session has this app claimed: it's muted, and the user hasn't
    /// used it since, so the sound it plays is an agent's.
    static func claimed(_ pid: pid_t) -> Bool {
        allLock.lock(); let sessions = all.allObjects; allLock.unlock()
        return sessions.contains { c in c.lock.lock(); defer { c.lock.unlock() }; return c.claims.values.contains { $0.pid == pid } }
    }

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
                guard let owner = Self.app(at: p) else { return }
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

    /// The app a click at `p` (global, top-left origin) goes to. Asked of
    /// accessibility, which skips windows clicks pass through: the window
    /// list puts the Dock's and Notification Center's full-screen ones on
    /// top of every app's.
    static func app(at p: CGPoint) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        var pid: pid_t = 0
        if AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &element) == .success,
           let element, AXUIElementGetPid(element, &pid) == .success, pid > 0 {
            return pid
        }
        return FocusGuard.windowOwner(at: p)
    }

    /// Silence each claim's sound with its element (accessibility only, so
    /// it doesn't touch the user's focus), then wait up to `settleMs` for
    /// the apps to go quiet: a press can succeed and do nothing (the page
    /// changed under the element), and the app is still muted meanwhile.
    /// Returns a note per claim, also kept for the agent's next call.
    func silence(_ hit: [Claim], why: String, settleMs: Double = 250,
                 playing: (pid_t) -> Bool = { pid in NSRunningApplication(processIdentifier: pid).map(SessionAudio.isPlaying) ?? false }) -> [String] {
        let pressed = hit.map { c in c.mute.map { AX.perform($0, "AXPress") } }
        let pids = Set(hit.map(\.pid))
        let deadline = nowMs() + settleMs
        var loud = pids.filter(playing)
        while !loud.isEmpty && nowMs() < deadline {
            usleep(20_000)
            loud = loud.filter(playing)
        }
        let notes = zip(hit, pressed).map { c, err -> String in
            let back = "The user \(why) \(c.appName), so it plays on their speakers again"
            guard let err else {
                return "\(back). You hadn't named an element to silence your sound with: if it's still playing in window \(c.window), stop it now."
            }
            if err != .success {
                return "\(back), but \(c.muteName) in window \(c.window) couldn't be pressed (\(AX.errorName(err))): if your sound is still playing there, stop it now."
            }
            if loud.contains(c.pid) {
                return "\(back). \(c.muteName.prefix(1).uppercased() + c.muteName.dropFirst()) in window \(c.window) was pressed, but \(c.appName) still seemed to make sound after it: make sure yours has stopped. \(Self.again)"
            }
            return "\(back), and your sound there was silenced with \(c.muteName) in window \(c.window). \(Self.again)"
        }
        lock.lock(); notes.forEach { self.notes.append($0) }; lock.unlock()
        return notes
    }

    /// How to play sound in the app again. Pausing first: a muted tab whose
    /// media still plays counts as sound (Safari), and the claim is refused.
    static let again = "To play sound in it again, pause yours, call capture_audio, then unmute and play."

    func clear() {
        lock.lock(); claims = [:]; lock.unlock()
    }
}
