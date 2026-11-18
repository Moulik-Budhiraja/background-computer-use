import AppKit
import XCTest
@testable import BCUCore

/// Who gets an app's sound back when the user starts using it.
final class AudioClaimTests: XCTestCase {
    private func claim(_ window: CGWindowID, pid: pid_t, mute: AXUIElement? = nil) -> AudioClaims.Claim {
        AudioClaims.Claim(window: window, pid: pid, appName: "App\(pid)", mute: mute, muteName: mute == nil ? "" : "element 1")
    }

    /// What `userInput` releases for this input, or nil if nothing within
    /// `wait` seconds (short when nothing is expected).
    private func released(by input: FocusGuard.UserInput, in claims: AudioClaims, wait: Double = 5) -> [AudioClaims.Claim]? {
        let done = DispatchSemaphore(value: 0)
        var got: [AudioClaims.Claim]?
        claims.userInput(input) { hit, _ in got = hit; done.signal() }
        return done.wait(timeout: .now() + wait) == .success ? got : nil
    }

    /// A key in the app ends its claims only.
    func testKeyInTheAppEndsItsClaims() {
        let c = AudioClaims()
        c.add(claim(1, pid: 100)); c.add(claim(2, pid: 100)); c.add(claim(3, pid: 200))
        let hit = released(by: .key(front: 100), in: c) ?? []
        XCTAssertEqual(Set(hit.map(\.window)), [1, 2])
        // Still muted while their sound is silenced, then not.
        XCTAssertEqual(c.pids(open: [1, 2, 3]), [100, 200])
        XCTAssertFalse(c.isIdle)
        c.finish(hit)
        XCTAssertEqual(c.pids(open: [1, 2, 3]), [200])
    }

    /// A key in another app leaves the claims alone.
    func testKeyElsewhereKeepsClaims() {
        let c = AudioClaims()
        c.add(claim(1, pid: 100))
        XCTAssertNil(released(by: .key(front: 300), in: c, wait: 0.3))
        XCTAssertEqual(c.pids(open: [1]), [100])
    }

    /// A media key goes to whichever app last played: every claim ends.
    func testMediaKeyEndsEveryClaim() {
        let c = AudioClaims()
        c.add(claim(1, pid: 100)); c.add(claim(3, pid: 200))
        let hit = released(by: .mediaKey, in: c) ?? []
        XCTAssertEqual(Set(hit.map(\.window)), [1, 3])
        XCTAssertTrue(c.isEmpty)
        XCTAssertFalse(c.isIdle)
        c.finish(hit)
        XCTAssertTrue(c.isIdle)
    }

    /// With no claims, input does nothing (and costs nothing on the tap).
    func testNoClaimsNoRelease() {
        XCTAssertNil(released(by: .mediaKey, in: AudioClaims(), wait: 0.3))
    }

    /// A claim on a window that's gone is dropped.
    func testClosedWindowDropsItsClaim() {
        let c = AudioClaims()
        c.add(claim(1, pid: 100)); c.add(claim(2, pid: 200))
        XCTAssertEqual(c.pids(open: [2]), [200])
        XCTAssertFalse(c.has(1))
    }

    /// Renewing a claim (to name the element) replaces it.
    func testRenewReplaces() {
        let c = AudioClaims()
        c.add(claim(1, pid: 100))
        c.add(claim(1, pid: 100, mute: AXUIElementCreateApplication(1)))
        XCTAssertEqual(c.pids(open: [1]), [100])
        XCTAssertTrue(c.has(1))
    }

    /// The agent hears about it on its next call, once.
    func testNotesSayWhatHappened() {
        let c = AudioClaims()
        let quiet: (pid_t) -> Bool = { _ in false }
        let loud: (pid_t) -> Bool = { _ in true }
        let noElement = c.silence([claim(1, pid: 100)], why: "started using", settleMs: 50, outputRunning: loud, playing: loud)
        XCTAssertTrue(noElement[0].contains("stop it now"), noElement[0])
        // An element that can't be pressed (no such process).
        let dead = c.silence([claim(2, pid: 100, mute: AXUIElementCreateApplication(999_999))], why: "started using", settleMs: 50, outputRunning: loud, playing: loud)
        XCTAssertTrue(dead[0].contains("couldn't be pressed"), dead[0])
        // No element and already quiet.
        let quietNoElement = c.silence([claim(4, pid: 100)], why: "started using", outputRunning: quiet, playing: quiet)
        XCTAssertTrue(quietNoElement[0].contains("had already stopped. "), quietNoElement[0])
        // Already quiet: nothing is pressed (a toggle would play it again).
        let stopped = c.silence([claim(3, pid: 100, mute: AXUIElementCreateApplication(999_999))], why: "started using", outputRunning: quiet, playing: quiet)
        // Silent for a moment but its output still running (a gap in a
        // video): the element is pressed.
        let gap = c.silence([claim(5, pid: 100, mute: AXUIElementCreateApplication(999_999))], why: "started using", outputRunning: loud, playing: quiet)
        XCTAssertTrue(gap[0].contains("couldn't be pressed"), gap[0])
        XCTAssertTrue(stopped[0].contains("already stopped"), stopped[0])
        XCTAssertEqual(c.takeNotes().count, 5)
        XCTAssertTrue(c.takeNotes().isEmpty)
    }

    /// Silencing waits for the app to go quiet, but not for long: the
    /// user's own sound may have started too.
    func testSilenceWaitsBrieflyForQuiet() {
        let c = AudioClaims()
        var calls = 0
        let start = nowMs()
        _ = c.silence([claim(1, pid: 100)], why: "started using", settleMs: 1000, outputRunning: { _ in true }) { _ in calls += 1; return calls < 4 }
        XCTAssertLessThan(nowMs() - start, 600)          // quiet after a few polls, well before the limit
        let loudStart = nowMs()
        _ = c.silence([claim(2, pid: 100)], why: "started using", settleMs: 300, outputRunning: { _ in true }) { _ in true }
        XCTAssertGreaterThanOrEqual(nowMs() - loudStart, 300)
        XCTAssertLessThan(nowMs() - loudStart, 1500)
    }

    /// Play, next, previous, fast-forward and rewind going down count;
    /// their release, volume and brightness keys don't.
    func testMediaKeys() {
        func event(_ code: Int, down: Bool) -> CGEvent {
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                      timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)!.cgEvent!
        }
        for code in 16...20 { XCTAssertTrue(FocusGuard.isMediaKeyDown(event(code, down: true)), "\(code)") }
        XCTAssertFalse(FocusGuard.isMediaKeyDown(event(16, down: false)))
        XCTAssertFalse(FocusGuard.isMediaKeyDown(event(0, down: true)))   // volume up
        XCTAssertFalse(FocusGuard.isMediaKeyDown(event(7, down: true)))   // mute
        XCTAssertFalse(FocusGuard.isMediaKeyDown(event(2, down: true)))   // brightness up
    }

    /// A claimed app's sound is an agent's, whichever session claimed it.
    func testClaimedAcrossSessions() {
        let a = AudioClaims(), b = AudioClaims()
        a.add(claim(1, pid: 4242))
        XCTAssertTrue(AudioClaims.claimed(4242))
        XCTAssertFalse(AudioClaims.claimed(4343))
        b.add(claim(2, pid: 4343))
        XCTAssertTrue(AudioClaims.claimed(4343))
        a.clear()
        XCTAssertFalse(AudioClaims.claimed(4242))
    }
}
