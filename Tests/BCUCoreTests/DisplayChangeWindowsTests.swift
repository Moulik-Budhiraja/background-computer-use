import XCTest
import CoreGraphics
@testable import BCUCore

/// On macOS 27, AppKit moves a window that another process last moved
/// through accessibility back to its frame from before that move, once, at
/// the next display change. Putting it back through accessibility set that
/// up again, so the window jumped at every agent display add and removal.
/// A window macOS moves at a display change is left where macOS put it;
/// one that fills its screen still gets its stale tile replaced.
final class DisplayChangeWindowsTests: XCTestCase {
    final class Windows: AgentDisplay.UserWindowAccess {
        var frames: [CGWindowID: CGRect]
        /// After this many looks at a window, macOS moves it here.
        var moves: [CGWindowID: (afterLooks: Int, to: CGRect)] = [:]
        var looks: [CGWindowID: Int] = [:]
        var tilesFixed: [(id: CGWindowID, frame: CGRect)] = []
        init(_ frames: [CGWindowID: CGRect]) { self.frames = frames }

        func frame(_ id: CGWindowID) -> CGRect? {
            looks[id, default: 0] += 1
            if let m = moves[id], looks[id] == m.afterLooks { frames[id] = m.to }
            return frames[id]
        }
        func setFrame(pid: pid_t, id: CGWindowID, _ frame: CGRect) -> Bool {
            frames[id] = frame
            return true
        }
        var userDisplays: Set<CGDirectDisplayID> { [1] }
        var dragPointer: CGPoint? { nil }
        func isAgents(_ id: CGWindowID) -> Bool { false }
        func fixTile(pid: pid_t, id: CGWindowID, frame: CGRect) -> Bool {
            tilesFixed.append((id, frame))
            return true
        }
        func fixTileLater(pid: pid_t, id: CGWindowID, frame: CGRect, now: CGRect) {}
    }

    func watch(_ w: Windows) {
        let before = AgentDisplay.UserWindows(frames: w.frames.map { (id: $0.key, pid: 10, bounds: $0.value) }, displays: [1])
        AgentDisplay.watchUserWindows(before, quietMs: 100, access: w)
    }

    func testAWindowMacOSMovesIsLeftWhereMacOSPutIt() {
        let placed = CGRect(x: 500, y: 300, width: 800, height: 450)
        let reverted = CGRect(x: 300, y: 200, width: 700, height: 500)
        let w = Windows([7: placed, 8: CGRect(x: 1100, y: 500, width: 600, height: 400)])
        w.moves[7] = (3, reverted)
        watch(w)
        XCTAssertEqual(w.frames[7], reverted)
        XCTAssertEqual(w.frames[8], CGRect(x: 1100, y: 500, width: 600, height: 400))
    }

    func testAFullHeightWindowDroppedToItsTileStillGetsTheTileFix() {
        let full = CGRect(x: 0, y: 30, width: 1920, height: 960)
        let w = Windows([7: full])
        w.moves[7] = (2, CGRect(x: 0, y: 30, width: 1920, height: 480))
        watch(w)
        XCTAssertEqual(w.tilesFixed.map(\.id), [7])
        XCTAssertEqual(w.tilesFixed.first?.frame, full)
    }

    func testAWindowNothingMovedIsLeftAlone() {
        let w = Windows([7: CGRect(x: 300, y: 200, width: 700, height: 500)])
        watch(w)
        XCTAssertEqual(w.frames[7], CGRect(x: 300, y: 200, width: 700, height: 500))
        XCTAssertTrue(w.tilesFixed.isEmpty)
    }
}
