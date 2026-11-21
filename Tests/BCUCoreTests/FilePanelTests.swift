import XCTest
@testable import BCUCore

/// An open or save panel runs in a macOS service process, drawn into the
/// app's sheet from a window of the service's laid exactly over it. Keys and
/// clicks for the panel go to that window.
final class PanelMatchTests: XCTestCase {
    private let sheetFrame = CGRect(x: 3168, y: 1994, width: 1184, height: 448)
    private let app: pid_t = 74912
    private let service: pid_t = 74846

    private func window(_ id: CGWindowID, _ pid: pid_t, _ bounds: CGRect, layer: Int = 0) -> WindowInfo {
        WindowInfo(id: id, pid: pid, owner: "", title: "", bounds: bounds, layer: layer, onScreen: false, alpha: 1)
    }

    /// Helium's file picker (from the incident): sheet 127992, the service's window 127993 over it.
    func testThePanelServicesWindowOverTheSheetIsTheTarget() {
        let sheet = window(127992, app, sheetFrame)
        let candidates = [sheet, window(117402, service, CGRect(x: 0, y: 1692, width: 53, height: 48)), window(127993, service, sheetFrame)]
        XCTAssertEqual(Panel.match(sheet: sheet, appPid: app, candidates: candidates, isService: { $0 == self.service }),
                       Panel.Remote(pid: service, window: 127993, frame: sheetFrame))
    }

    /// Another app's window that happens to have the same frame isn't the panel.
    func testAWindowOfAnotherProcessThatIsntAPanelServiceIsIgnored() {
        let sheet = window(127992, app, sheetFrame)
        let candidates = [sheet, window(500, 999, sheetFrame)]
        XCTAssertNil(Panel.match(sheet: sheet, appPid: app, candidates: candidates, isService: { $0 == self.service }))
    }

    /// An alert sheet is drawn by the app itself: nothing of the service's over it.
    func testASheetTheAppDrawsItselfHasNoPanel() {
        let sheet = window(127992, app, sheetFrame)
        let candidates = [sheet, window(127993, service, sheetFrame.offsetBy(dx: 10, dy: 0))]
        XCTAssertNil(Panel.match(sheet: sheet, appPid: app, candidates: candidates, isService: { $0 == self.service }))
    }

    func testPathsAreResolved() {
        XCTAssertEqual(Panel.resolve("~/Library/../Library/x.png"), NSHomeDirectory() + "/Library/x.png")
        XCTAssertEqual(Panel.resolve("/tmp/./a/b/../c"), "/tmp/a/c")
    }
}

/// What an agent is told when keys or pixel clicks can't reach its window.
final class KeyRefusalTests: XCTestCase {
    /// An agent read "the app's key window is 102001" as the user typing in
    /// the app, and waited 75 s for them. No window ids, and say what it is.
    func testASheetRefusalSaysWhatItIsWithoutWindowIDs() {
        let text = KeyScope.refusal(sheet: true)
        XCTAssertTrue(text.contains("file picker"))
        XCTAssertTrue(text.contains("choose_file"))
        XCTAssertNil(text.range(of: #"\d{4,}"#, options: .regularExpression))
    }

    func testThePlainRefusalSaysItIsntTheUser() {
        let text = KeyScope.refusal(sheet: false)
        XCTAssertTrue(text.contains("not the user"))
        XCTAssertNil(text.range(of: #"\d{4,}"#, options: .regularExpression))
    }
}

/// What choose_file reads back of the panel's selection after Go to Folder.
final class PanelSelectionTests: XCTestCase {
    final class Node {
        let role: String
        var value: String?
        var kids: [Node]
        var selected: [String: [Node]] = [:]
        init(_ role: String, value: String? = nil, _ kids: [Node] = []) { self.role = role; self.value = value; self.kids = kids }
    }

    private let reader = Panel.Reader<Node>(role: { $0.role }, children: { $0.kids }, elements: { $0.selected[$1] ?? [] }, value: { $0.value })

    /// A row of a list: a cell, or a column view's item (an icon and the name).
    private func item(_ name: String, _ role: String = "AXGroup") -> Node {
        Node(role, [Node("AXImage"), Node("AXTextField", value: name)])
    }

    private func list(_ names: [String], selected: String, role: String = "AXList", attribute: String = "AXSelectedChildren", itemRole: String = "AXGroup") -> Node {
        let items = names.map { item($0, itemRole) }
        let l = Node(role, items)
        l.selected[attribute] = items.filter { $0.kids.last?.value == selected }
        return l
    }

    /// The open panel on macOS 27.3 after Go to Folder ~/Library/Caches/x.txt
    /// (read from the panel): the sidebar has the home folder selected, and
    /// the column view one list per column, the last with x.txt selected.
    /// choose_file said "the panel selected "admin" instead of "x.txt"".
    private func columnViewPanel() -> Node {
        let sidebar = list(["Recents", "Applications", "Desktop", "admin"], selected: "admin", role: "AXOutline", attribute: "AXSelectedRows", itemRole: "AXRow")
        let columns = [list(["Desktop", "Library", "Movies"], selected: "Library"),
                       list(["Accessibility", "Caches", "Containers"], selected: "Caches"),
                       list(["askpermissiond", "x.txt", "y.txt"], selected: "x.txt")]
        let browser = Node("AXBrowser", [Node("AXScrollArea", columns.map { Node("AXScrollArea", [$0, Node("AXScrollBar")]) })])
        return Node("AXSheet", [Node("AXSplitGroup", [Node("AXScrollArea", [sidebar]), Node("AXSplitGroup", [browser]),
                                                       Node("AXButton", value: nil)])])
    }

    func testTheFileSelectedInColumnViewIsRead() {
        XCTAssertTrue(Panel.selectedNames(columnViewPanel(), reader).contains("x.txt"))
    }

    /// The folders chosen in the columns before it aren't the selection.
    func testOnlyTheLastColumnsSelectionCounts() {
        let names = Panel.selectedNames(columnViewPanel(), reader)
        XCTAssertFalse(names.contains("Library"))
        XCTAssertFalse(names.contains("Caches"))
    }

    /// List view: the file list is an outline of rows.
    func testTheFileSelectedInListViewIsRead() {
        let files = list(["a.txt", "x.txt"], selected: "x.txt", role: "AXOutline", attribute: "AXSelectedRows", itemRole: "AXRow")
        let panel = Node("AXSheet", [Node("AXScrollArea", [files])])
        XCTAssertEqual(Panel.selectedNames(panel, reader), ["x.txt"])
    }
}
