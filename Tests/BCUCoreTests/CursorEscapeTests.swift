import XCTest
import CoreGraphics
@testable import BCUCore

/// Where the guard puts a cursor it takes off the agent display. The agent
/// display sits at the bottom-right corner of the user's, so a cursor pushed
/// into that corner crosses onto it. Put back on the corner's last pixel, the
/// arrow is drawn past the screen's edge and the user can't find it.
final class CursorEscapeTests: XCTestCase {
    let user = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let agent = CGRect(x: 1512, y: 982, width: 1440, height: 900)

    func testACursorTakenOffTheAgentDisplayLandsInsideTheScreen() {
        let q = FocusGuard.nearestUserPoint(CGPoint(x: 1520, y: 990), agent: agent, users: [user], fenced: [agent])
        XCTAssertTrue(user.contains(q))
        XCTAssertLessThanOrEqual(q.x, user.maxX - 24, "x \(q.x) is at the right edge")
        XCTAssertLessThanOrEqual(q.y, user.maxY - 24, "y \(q.y) is at the bottom edge")
        XCTAssertGreaterThanOrEqual(q.x, user.maxX - 64, "x \(q.x) is too far in")
        XCTAssertGreaterThanOrEqual(q.y, user.maxY - 64, "y \(q.y) is too far in")
    }

    func testOnlyTheEdgeItCrossedMoves() {
        // An agent display to the right: the cursor keeps its height.
        let right = CGRect(x: 1512, y: 0, width: 1440, height: 900)
        let q = FocusGuard.nearestUserPoint(CGPoint(x: 1600, y: 400), agent: right, users: [user], fenced: [right])
        XCTAssertEqual(q.y, 400)
        XCTAssertLessThanOrEqual(q.x, user.maxX - 24)
        XCTAssertGreaterThanOrEqual(q.x, user.maxX - 64)
    }

    func testACursorOffEveryDisplayLandsInsideTheScreen() {
        let q = FocusGuard.nearestUserPoint(CGPoint(x: -50, y: 600), agent: .null, users: [user], fenced: [agent])
        XCTAssertEqual(q.y, 600)
        XCTAssertGreaterThanOrEqual(q.x, 24)
        XCTAssertLessThanOrEqual(q.x, 64)
    }

    func testATinyDisplayGetsItsMiddleAtMost() {
        let small = CGRect(x: 0, y: 0, width: 40, height: 30)
        let next = CGRect(x: 40, y: 30, width: 100, height: 100)
        let q = FocusGuard.nearestUserPoint(CGPoint(x: 60, y: 60), agent: next, users: [small], fenced: [next])
        XCTAssertTrue(small.contains(q))
        XCTAssertGreaterThanOrEqual(q.x, small.midX - 1)
        XCTAssertGreaterThanOrEqual(q.y, small.midY - 1)
    }

    // The user pushing their own mouse into the corner the agent display
    // touches: it stops in the corner, as on any screen's edge.
    func testTheUsersOwnMoveIntoTheCornerStaysInTheCorner() {
        let q = FocusGuard.returnPoint(CGPoint(x: 1513, y: 983), agent: agent, users: [user], fenced: [agent], msSinceUserMove: 0)
        XCTAssertEqual(q, CGPoint(x: user.maxX - 1, y: user.maxY - 1))
    }

    // The cursor watch can see the cursor over there a moment before the
    // tap moves it back: a move the user just made is still theirs.
    func testACursorFoundThereRightAfterAUserMoveStaysInTheCorner() {
        let q = FocusGuard.returnPoint(CGPoint(x: 1520, y: 990), agent: agent, users: [user], fenced: [agent], msSinceUserMove: 5)
        XCTAssertEqual(q, CGPoint(x: user.maxX - 1, y: user.maxY - 1))
    }

    // Put there by something else (a warp, the tap off) with the mouse still:
    // it comes back inside the screen, where the user can see it.
    func testACursorFoundThereWithoutAUserMoveComesBackInside() {
        let q = FocusGuard.returnPoint(CGPoint(x: 1520, y: 990), agent: agent, users: [user], fenced: [agent], msSinceUserMove: 2000)
        XCTAssertEqual(q, CGPoint(x: user.maxX - 1 - FocusGuard.escapeInset, y: user.maxY - 1 - FocusGuard.escapeInset))
    }
}

/// The cursor after the last agent display goes: macOS can leave it just
/// past the corner the display touched, off every display, where the user
/// can't see it. With no agent display left, nothing is fenced, and the
/// watch must still bring it back.
final class CursorAfterRemovalTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testACursorLeftOffEveryDisplayByTheLastRemovalComesBack() {
        let fix = FocusGuard.cursorFix(CGPoint(x: 1920, y: 1080), fenced: [], users: [main], msSinceUserMove: 5000)
        XCTAssertNotNil(fix)
        guard let fix else { return }
        XCTAssertNil(fix.agent)
        XCTAssertTrue(main.insetBy(dx: 24, dy: 24).contains(fix.to), "\(fix.to)")
    }

    func testACursorOnTheUsersScreenIsLeftAloneWithNoAgentDisplay() {
        XCTAssertNil(FocusGuard.cursorFix(CGPoint(x: 700, y: 500), fenced: [], users: [main], msSinceUserMove: 5000))
        XCTAssertNil(FocusGuard.cursorFix(CGPoint(x: 1919, y: 1079), fenced: [], users: [main], msSinceUserMove: 5000))
    }
}
