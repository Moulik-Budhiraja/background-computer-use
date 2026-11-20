import XCTest
@testable import BCUCore
import BCUShared

/// Pure rules only: nothing here reads or touches the Mac it runs on.
final class SnapshotAndDocsTests: XCTestCase {
    func testScrollingKeepsNumbersAndAnotherPageRestartsThem() {
        // Scrolled a page down: everything listed is new, but what the last
        // read numbered is still there, out of view.
        XCTAssertFalse(AXSnapshot.renumbers(listed: 40, listedKnown: 0, known: 40, stillThere: 40))
        // Another page: new elements, and the old ones are gone.
        XCTAssertTrue(AXSnapshot.renumbers(listed: 40, listedKnown: 2, known: 40, stillThere: 2))
        // Mostly the same elements.
        XCTAssertFalse(AXSnapshot.renumbers(listed: 40, listedKnown: 35, known: 40, stillThere: 38))
        // Nothing numbered last time.
        XCTAssertTrue(AXSnapshot.renumbers(listed: 10, listedKnown: 0, known: 0, stillThere: 0))
        // Nothing in the window at all.
        XCTAssertTrue(AXSnapshot.renumbers(listed: 0, listedKnown: 0, known: 10, stillThere: 0))
        // Everything scrolled out of view: still there, numbers kept.
        XCTAssertFalse(AXSnapshot.renumbers(listed: 0, listedKnown: 0, known: 10, stillThere: 10))
    }

    func testNavigateCompletesBareHostsAndRefusesSearchWords() {
        XCTAssertEqual(BrowserAutomation.loadableURL("https://example.com/a?b=1"), "https://example.com/a?b=1")
        XCTAssertEqual(BrowserAutomation.loadableURL("  example.com "), "https://example.com")
        XCTAssertEqual(BrowserAutomation.loadableURL("www.example.co.uk/path#x"), "https://www.example.co.uk/path#x")
        XCTAssertEqual(BrowserAutomation.loadableURL("example.com:8443/x"), "https://example.com:8443/x")
        XCTAssertEqual(BrowserAutomation.loadableURL("localhost:3000/app"), "http://localhost:3000/app")
        XCTAssertEqual(BrowserAutomation.loadableURL("localhost"), "http://localhost")
        XCTAssertEqual(BrowserAutomation.loadableURL("192.168.1.1"), "http://192.168.1.1")
        XCTAssertEqual(BrowserAutomation.loadableURL("[::1]:8080/"), "http://[::1]:8080/")
        XCTAssertEqual(BrowserAutomation.loadableURL("about:blank"), "about:blank")
        XCTAssertEqual(BrowserAutomation.loadableURL("chrome://settings"), "chrome://settings")
        XCTAssertEqual(BrowserAutomation.loadableURL("file:///tmp/a.html"), "file:///tmp/a.html")
        XCTAssertNil(BrowserAutomation.loadableURL("weather today"))
        XCTAssertNil(BrowserAutomation.loadableURL("weather"))
        XCTAssertNil(BrowserAutomation.loadableURL(""))
        XCTAssertNil(BrowserAutomation.loadableURL("foo:bar"))
        XCTAssertNil(BrowserAutomation.loadableURL("me@example.com"))
    }

    /// A URL with a scheme goes as given, spaces in it included: Chromium
    /// takes them in a data: page.
    func testNavigateKeepsSchemedURLsWithSpaces() {
        XCTAssertEqual(BrowserAutomation.loadableURL("data:text/html,<h1>Hello world</h1>"), "data:text/html,<h1>Hello world</h1>")
        XCTAssertEqual(BrowserAutomation.loadableURL("javascript:alert(1 + 1)"), "javascript:alert(1 + 1)")
        XCTAssertNil(BrowserAutomation.loadableURL("example.com is down"))
    }

    func testBatchDocsListEveryBatchableTool() throws {
        let batch = try XCTUnwrap(ToolCatalog.tools.first { $0["name"] as? String == "batch" })
        let description = try XCTUnwrap(batch["description"] as? String)
        let allowed = try XCTUnwrap(description.range(of: "Allowed tools: ")).upperBound
        let listed = Set(description[allowed...].prefix { $0 != "." }.components(separatedBy: ", "))
        XCTAssertEqual(listed, Engine.batchable)
    }
}
