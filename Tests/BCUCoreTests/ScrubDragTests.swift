import XCTest
@testable import BCUCore

/// Pure arithmetic only.
final class ScrubDragTests: XCTestCase {
    func testADragFollowsThePointer() {
        let drag = ScrubDrag(pointerX: 100, windowX: 500, scroll: 1000)
        XCTAssertEqual(drag.distance(pointerX: 150, windowX: 500), 50)
        XCTAssertEqual(drag.scroll(pointerX: 150, windowX: 500), 950)
    }

    /// A lane more, with the panel at its height limit, narrows the panel and
    /// re-centers it: the track moves 28 points right under a still pointer.
    func testThePanelMovingUnderAStillPointerIsntADrag() {
        let drag = ScrubDrag(pointerX: 100, windowX: 500, scroll: 1000)
        XCTAssertEqual(drag.distance(pointerX: 72, windowX: 528), 0)
        XCTAssertEqual(drag.scroll(pointerX: 72, windowX: 528), 1000)
    }
}
