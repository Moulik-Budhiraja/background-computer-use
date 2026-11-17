import XCTest
@testable import BCUCore

/// What the copy over the user's window waits for when the window's content
/// changes on its own (a video): never the content, or it would wait out its
/// whole timeout with the video frozen under it.
final class LiveChromeTests: XCTestCase {
    let size = CGSize(width: 1200, height: 800)
    let content = CGRect(x: 1, y: 80, width: 1198, height: 719)

    /// No traffic lights found: the strip above the content (title bar and toolbar).
    func testWithNoChromeFoundTheStripAboveTheContent() {
        XCTAssertEqual(ScreenFreeze.liveChrome(nil, content: content, size: size), [CGRect(x: 0, y: 0, width: 1200, height: 80)])
    }

    /// The focus ring of something in the content changes with it: only the
    /// chrome outside the content counts.
    func testChromeInsideTheContentIsLeftOut() {
        let lights = CGRect(x: 8, y: 8, width: 60, height: 16)
        let focusBand = CGRect(x: 300, y: 300, width: 400, height: 6)
        XCTAssertEqual(ScreenFreeze.liveChrome([lights, focusBand], content: content, size: size), [lights])
    }

    /// Content filling the window (a video in full screen): nothing to wait for.
    func testContentFillingTheWindowLeavesNothing() {
        let full = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertEqual(ScreenFreeze.liveChrome(nil, content: full, size: size), [])
    }
}
