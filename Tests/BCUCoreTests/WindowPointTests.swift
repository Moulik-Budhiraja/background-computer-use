import XCTest
@testable import BCUCore

/// Window coordinates from the agent in error messages.
final class WindowPointTests: XCTestCase {
    /// scroll with x 1e100 is out of the window. Converting it to Int to say
    /// so trapped and took the engine down.
    func testAHugeCoordinateIsFormattedWithoutTrapping() {
        XCTAssertEqual(Engine.windowPoint(1e100), "1e+100")
        XCTAssertEqual(Engine.windowPoint(-1e19), "-1e+19")
    }

    func testAnOrdinaryCoordinateIsAWholeNumber() {
        XCTAssertEqual(Engine.windowPoint(3000), "3000")
        XCTAssertEqual(Engine.windowPoint(-400.4), "-400")
    }
}
