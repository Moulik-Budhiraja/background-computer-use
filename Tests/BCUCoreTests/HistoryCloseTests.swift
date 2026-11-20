import XCTest
@testable import BCUCore

/// Pure rules and a temp-folder run only: nothing here reads the Mac it runs on.
final class HistoryCloseTests: XCTestCase {
    /// History calls this on the main thread when it closes, while a frame
    /// may still be decoding.
    func testReleasingDecodersDoesntWaitForADecodeInFlight() {
        let run = RecordedRun(id: "r", dir: FileManager.default.temporaryDirectory, session: "s", label: "Agent", start: 0, size: .zero)
        let held = expectation(description: "decode lock held")
        let finished = expectation(description: "decode finished")
        DispatchQueue.global().async {
            run.decodeLock.lock()
            held.fulfill()
            Thread.sleep(forTimeInterval: 1)
            run.decodeLock.unlock()
            finished.fulfill()
        }
        wait(for: [held], timeout: 2)
        let start = Date()
        run.releaseDecoders()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        wait(for: [finished], timeout: 3)
    }

    func testSetupCarriesOnAfterQuitAndReopen() {
        // Run again from the ⋯ menu after it was finished once.
        XCTAssertTrue(SetupGate.shouldShow(done: true, reopened: true) { true })
        XCTAssertFalse(SetupGate.shouldShow(done: true, reopened: false) { false })
        XCTAssertTrue(SetupGate.shouldShow(done: false, reopened: true) { true })
        XCTAssertTrue(SetupGate.shouldShow(done: false, reopened: false) { false })
        XCTAssertFalse(SetupGate.shouldShow(done: false, reopened: false) { true })
    }
}
