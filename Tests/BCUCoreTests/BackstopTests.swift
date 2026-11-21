import XCTest
import CoreGraphics
@testable import BCUCore

/// Every display macOS removes while it's still enabled leaves a Window
/// Server "Backstop" window behind for good (one more per agent session).
/// Disabled first, then let go of, it leaves none of its own: the next
/// display takes over the one backstop there is.
final class BackstopTests: XCTestCase {
    func testADisplayIsDisabledBeforeItIsLetGoOf() {
        var steps: [String] = []
        AgentDisplay.remove(77, disable: { steps.append("disable \($0)") }, release: { steps.append("release") })
        XCTAssertEqual(steps, ["disable 77", "release"])
    }
}
