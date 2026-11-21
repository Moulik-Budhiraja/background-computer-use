import XCTest
@testable import BCUCore

/// With a password field (secure input) in the app the user is in, macOS
/// shows BCU none of their keys. A step that takes key there would hold the
/// keys it saw while key was away and replay them after key is back, while
/// the ones typed after key came back go straight to the field ahead of
/// them. So such a step waits, as it does for typing it can see.
final class SecureInputWaitTests: XCTestCase {
    override func setUp() { QuietRules.safeTyping = true }
    override func tearDown() { QuietRules.safeTyping = true }

    func testAStepWaitsWhileAPasswordFieldHasTheKeyboard() {
        let start = nowMs()
        let r = QuietWait.wait(UserActivity(), pid: 0, softMs: 0, hardMs: 0, giveUpAtMs: start + 300,
                               secureInput: { true })
        XCTAssertEqual(r.outcome, .typing)
        XCTAssertEqual(r.reason, QuietWait.secureReason)
        XCTAssertGreaterThan(r.waitedMs, 280)
    }

    func testAStepThatCannotWaitStillWaitsForAPasswordField() {
        let start = nowMs()
        let r = QuietWait.wait(UserActivity(), pid: 0, softMs: 0, hardMs: 0, typingOnly: true, giveUpAtMs: start + 200,
                               secureInput: { true })
        XCTAssertEqual(r.outcome, .typing)
    }

    func testSafeTypingOffStillWaitsForAPasswordField() {
        QuietRules.safeTyping = false
        let start = nowMs()
        let r = QuietWait.wait(UserActivity(), pid: 0, softMs: 0, hardMs: 0, giveUpAtMs: start + 200,
                               secureInput: { true })
        XCTAssertEqual(r.outcome, .typing)
    }

    func testTheStepGoesOnceThePasswordFieldLetsGo() {
        let start = nowMs()
        let r = QuietWait.wait(UserActivity(), pid: 0, softMs: 100, hardMs: 200, giveUpAtMs: start + 5000,
                               secureInput: { nowMs() - start < 300 })
        XCTAssertEqual(r.outcome, .quiet)
        XCTAssertGreaterThan(r.waitedMs, 280)
        XCTAssertLessThan(r.waitedMs, 1500)
        // Like typing, it doesn't count against the session's budget for waiting.
        XCTAssertLessThan(r.countedMs, 100)
    }

    func testNoPasswordFieldNoWait() {
        let r = QuietWait.wait(UserActivity(), pid: 0, softMs: 100, hardMs: 200, secureInput: { false })
        XCTAssertEqual(r.outcome, .quiet)
        XCTAssertLessThan(r.waitedMs, 100)
    }
}
