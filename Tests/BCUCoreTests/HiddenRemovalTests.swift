import XCTest
@testable import BCUCore

/// Removals of elements the last read kept numbers for without listing them.
final class HiddenRemovalTests: XCTestCase {
    private func read(_ lines: [Int: String], scrolledOut: Set<Int> = [], hidden: [Int: String] = [:]) -> AXSnapshotResult {
        AXSnapshotResult(windowID: 1, nodes: [:], text: "", visited: 0, header: "Window 1", footer: [],
                         lines: lines, indexByElement: [:], unlisted: [], scrolledOut: scrolledOut,
                         hiddenLines: hidden, nextIndex: 10, renumbered: false)
    }

    /// Row 3 scrolled out of an inner list, then was deleted before it came
    /// back: the agent still holds number 3 and must be told it's gone.
    func testAScrolledOutElementThatGoesIsReportedRemoved() throws {
        let scrolled = read([1: "[1] Button \"Top\""], scrolledOut: [3], hidden: [3: "  [3] Link \"Row 3\""])
        let deleted = read([1: "[1] Button \"Top\""])
        let diff = try XCTUnwrap(AXSnapshot.diff(from: scrolled, to: deleted))
        XCTAssertTrue(diff.contains("- [3] Link \"Row 3\""), diff)
    }

    func testAScrolledOutElementStillThereIsNotReported() throws {
        let scrolled = read([1: "[1] Button \"Top\""], scrolledOut: [3], hidden: [3: "  [3] Link \"Row 3\""])
        let still = read([1: "[1] Button \"Top\""], scrolledOut: [3], hidden: [3: "  [3] Link \"Row 3\""])
        let diff = try XCTUnwrap(AXSnapshot.diff(from: scrolled, to: still))
        XCTAssertFalse(diff.contains("Row 3"), diff)
    }
}
