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
