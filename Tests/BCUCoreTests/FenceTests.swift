import XCTest
@testable import BCUCore

/// Which points the cursor fence keeps the user off.
final class FenceTests: XCTestCase {
    let agent = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testAPointOnTheAgentDisplayIsFenced() {
        let user = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(AgentDisplay.fenced(at: CGPoint(x: 2000, y: 500), agents: [agent], users: [user]), agent)
    }

    func testAPointOnTheUsersDisplayIsNot() {
        let user = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertNil(AgentDisplay.fenced(at: CGPoint(x: 700, y: 500), agents: [agent], users: [user]))
    }

    /// An agent display lying over one of the user's: where they overlap,
    /// the cursor, clicks and scrolls are on the user's screen. The tap and
    /// the cursor watch both go by this.
    func testWhereAUsersDisplayOverlapsTheAgentsItIsTheirs() {
        let user = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        XCTAssertNil(AgentDisplay.fenced(at: CGPoint(x: 2000, y: 500), agents: [agent], users: [user]))
        // Past the user's display, still on the agent's.
        XCTAssertEqual(AgentDisplay.fenced(at: CGPoint(x: 3000, y: 500), agents: [agent], users: [user]), agent)
        XCTAssertEqual(AgentDisplay.fenced(at: CGPoint(x: 2000, y: 1000), agents: [agent], users: [user]), agent)
    }
}
