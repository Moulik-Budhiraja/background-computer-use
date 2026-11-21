import XCTest
import CoreGraphics
@testable import BCUCore

/// A window the user tiled (Window > Move & Resize > Top) and then zoomed
/// back to full size keeps its tile in WindowManager on macOS 26 and later,
/// and WindowManager puts it back in the top half at every display change.
/// Return to Previous Size dropped the tile but also shrank the window to
/// its size from before the tile. Fill gives it the tile of the frame it has.
final class StaleTileTests: XCTestCase {
    let visible = CGRect(x: 0, y: 30, width: 1920, height: 960)
    let pid: pid_t = 10
    let id: CGWindowID = 5

    func fix(_ want: CGRect, margins: Bool = false, front: pid_t = 10, main: CGWindowID? = 5, untileEnabled: Bool = true) -> AgentDisplay.TileFix {
        AgentDisplay.tileFix(want: want, visible: visible, margins: margins, front: front, pid: pid,
                             mainWindow: main, id: id, untileEnabled: untileEnabled)
    }

    func testAFullHeightWindowGetsFillAndKeepsItsSize() {
        XCTAssertEqual(fix(visible), .fill)
        // On 27.3 the app doesn't know about the tile (Return to Previous Size is off).
        XCTAssertEqual(fix(visible, untileEnabled: false), .fill)
        // The window list can be a point off.
        XCTAssertEqual(fix(CGRect(x: 0, y: 30, width: 1920, height: 959)), .fill)
    }

    func testAWindowThatDoesntFillItsScreenIsNeverReturnedToAnOldSize() {
        XCTAssertEqual(fix(CGRect(x: 199, y: 120, width: 1001, height: 701)), .nothing)
        // With margins, Fill would make the window smaller.
        XCTAssertEqual(fix(visible, margins: true), .nothing)
    }

    func testOnlyTheUsersMainWindowInTheAppInFront() {
        XCTAssertEqual(fix(visible, front: 11), .later)
        XCTAssertEqual(fix(visible, main: 6), .later)
    }
}
