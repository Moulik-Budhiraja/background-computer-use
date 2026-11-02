import AppKit
import BCUShared
import CPrivate

/// Test only (`admin_chaos`): things that happen to a key swap from outside,
/// timed to land in the middle of one. Another app takes the front for a
/// moment and the app comes back (a system alert does that), or the app's
/// main thread stalls. Only for test fixtures: `front` switches to this app
/// (which has no windows) and back, `stall` stops and continues one process.
final class Chaos {
    static let shared = Chaos()

    private let lock = NSLock()
    private var running = false
    private var stopping = false
    private var epoch = 0.0
    private var log: [(t: Double, what: String)] = []
    private var _flipping = false

    /// This app is in front because of a `front` op.
    var flipping: Bool {
        lock.lock(); defer { lock.unlock() }
        return _flipping
    }

    private func note(_ s: String) {
        lock.lock(); log.append((nowMs() - epoch, s)); lock.unlock()
    }

    /// `ops`, in order:
    /// - `{"op": "on_swap", "pid": P, "delay_ms": D, "jitter_ms": J, "times": N, "do": {op}}`:
    ///   N times, wait for a key swap in P to begin, wait D (+ up to J) ms, run `do`, wait for the swap to end
    /// - `{"op": "front", "ms": M, "back_pid": P}`: put this app in front for M ms, then P
    /// - `{"op": "stall", "pid": P, "ms": M}`: stop P for M ms
    /// - `{"op": "pause", "ms": M}`
    func start(_ ops: [JSONObject], guard focusGuard: FocusGuard) -> ToolResult {
        lock.lock()
        if running { lock.unlock(); return .error("already running") }
        running = true
        stopping = false
        epoch = nowMs()
        log = []
        lock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            for op in ops { if !self.run(op, focusGuard) { break } }
            self.note("end")
            self.lock.lock(); self.running = false; self.lock.unlock()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        return ToolResult(text: "started")
    }

    func stop() -> ToolResult {
        lock.lock(); stopping = true; lock.unlock()
        return ToolResult(text: "stopping")
    }

    func status() -> ToolResult {
        lock.lock(); defer { lock.unlock() }
        let obj: JSONObject = ["running": running, "log": log.map { ["t": $0.t, "what": $0.what] as JSONObject }]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        return ToolResult(text: "chaos \(running ? "running" : "done")\n" + (String(data: data, encoding: .utf8) ?? "{}"))
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    /// False to stop.
    private func run(_ op: JSONObject, _ focusGuard: FocusGuard) -> Bool {
        let a = Args(op)
        switch a.string("op") ?? "" {
        case "pause":
            sleepMs(a.double("ms") ?? 100)
        case "on_swap":
            let pid = pid_t(a.int("pid") ?? 0)
            let inner = (op["do"] as? JSONObject) ?? [:]
            for i in 0..<(a.int("times") ?? 1) {
                while !focusGuard.isSwapping(pid) {
                    if shouldStop { return false }
                    usleep(500)
                }
                let d = (a.double("delay_ms") ?? 20) + Double.random(in: 0...max(0, a.double("jitter_ms") ?? 0))
                sleepMs(d)
                note("swap \(i + 1) in \(pid): \(focusGuard.isSwapping(pid) ? "still" : "no longer") swapping after \(Int(d)) ms")
                if !run(inner, focusGuard) { return false }
                while focusGuard.isSwapping(pid) {
                    if shouldStop { return false }
                    usleep(500)
                }
            }
        case "front":
            let back = pid_t(a.int("back_pid") ?? 0)
            let ms = a.double("ms") ?? 100
            // Between two of the simulated user's events: it posts nothing
            // until the app is back (a real user's keys meanwhile would go
            // to whatever took the front, which isn't what's tested here).
            UserSim.shared.postLock.lock()
            lock.lock(); _flipping = true; lock.unlock()
            let t0 = nowMs()
            _ = BCUSetFrontProcess(getpid(), 0, 0x200)
            while BCUFrontProcessPID() != getpid() && nowMs() - t0 < 200 { usleep(1000) }
            let away = nowMs() - t0
            sleepMs(ms - away)
            _ = BCUSetFrontProcess(back, 0, 0x200)
            let t1 = nowMs()
            while BCUFrontProcessPID() != back && nowMs() - t1 < 300 { usleep(1000) }
            lock.lock(); _flipping = false; lock.unlock()
            UserSim.shared.postLock.unlock()
            note("front: this app for \(Int(nowMs() - t0)) ms (in front after \(Int(away)) ms), then \(back) (\(BCUFrontProcessPID() == back ? "back" : "NOT back") after \(Int(nowMs() - t1)) ms)")
        case "stall":
            let pid = pid_t(a.int("pid") ?? 0)
            guard pid > 0, pid != getpid() else { note("stall: bad pid"); return true }
            let ms = min(a.double("ms") ?? 300, 3000)
            kill(pid, SIGSTOP)
            sleepMs(ms)
            kill(pid, SIGCONT)
            note("stall: stopped \(pid) for \(Int(ms)) ms")
        default:
            note("unknown op \(a.string("op") ?? "")")
        }
        return true
    }
}
