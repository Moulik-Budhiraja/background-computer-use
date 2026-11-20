import XCTest
@testable import BCUCore

final class AppNameMatchTests: XCTestCase {
    func testOnlyATrailingAppIsStripped() {
        XCTAssertEqual(AppNameMatch.stripped("com.apple.Notes"), "com.apple.Notes")
        XCTAssertEqual(AppNameMatch.stripped(" Notes.app "), "Notes")
        XCTAssertEqual(AppNameMatch.stripped("Safari.APP"), "Safari")
        XCTAssertEqual(AppNameMatch.stripped("com.apple.Safari.app"), "com.apple.Safari")
        XCTAssertEqual(AppNameMatch.stripped(".app"), ".app")
    }

    func testBundleIDsMatchWhateverTheCase() {
        XCTAssertTrue(AppNameMatch.sameBundleID("com.apple.Notes", "com.apple.notes"))
        XCTAssertTrue(AppNameMatch.sameBundleID("com.apple.Notes", "COM.APPLE.NOTES"))
        XCTAssertFalse(AppNameMatch.sameBundleID("com.apple.Notes", "comle.notes"))
        XCTAssertFalse(AppNameMatch.sameBundleID(nil, "com.apple.Notes"))
    }

    func testRanks() {
        XCTAssertEqual(AppNameMatch.rank("notes", name: "Notes"), .exact)
        XCTAssertEqual(AppNameMatch.rank("Notes.app", name: "Notes"), .exact)
        XCTAssertEqual(AppNameMatch.rank("Visual Studio", name: "Visual Studio Code"), .leadingWords)
        XCTAssertEqual(AppNameMatch.rank("Chrome", name: "Google Chrome"), .word)
        XCTAssertEqual(AppNameMatch.rank("Code", name: "Visual Studio Code"), .word)
        XCTAssertEqual(AppNameMatch.rank("Chrom", name: "Chromium"), .prefix)
        XCTAssertEqual(AppNameMatch.rank("Code", name: "Xcode"), .substring)
        XCTAssertNil(AppNameMatch.rank("Safari", name: "Xcode"))
        XCTAssertNil(AppNameMatch.rank("  ", name: "Xcode"))
    }

    func testChromeIsGoogleChrome() {
        XCTAssertEqual(AppNameMatch.best("Chrome", among: ["Chromium", "Google Chrome", "Safari"]), .one("Google Chrome"))
    }

    func testCodePrefersAWholeWordOverASubstring() {
        XCTAssertEqual(AppNameMatch.best("Code", among: ["Xcode", "Visual Studio Code", "CodeRunner"]), .one("Visual Studio Code"))
    }

    func testExactBeatsEverything() {
        XCTAssertEqual(AppNameMatch.best("Notes", among: ["Sticky Notes", "Notes", "Notes Helper"]), .one("Notes"))
    }

    func testEqualMatchesAreAmbiguous() {
        XCTAssertEqual(AppNameMatch.best("Code", among: ["Xcode", "Barcode Maker"]), .ambiguous(["Barcode Maker", "Xcode"]))
        XCTAssertEqual(AppNameMatch.best("Microsoft", among: ["Microsoft Word", "Microsoft Excel"]), .ambiguous(["Microsoft Excel", "Microsoft Word"]))
    }

    func testSameNameInDifferentCaseCountsOnce() {
        XCTAssertEqual(AppNameMatch.best("chrome", among: ["Google Chrome", "google chrome"]), .one("Google Chrome"))
    }

    func testNoMatch() {
        XCTAssertEqual(AppNameMatch.best("Figma", among: ["Safari", "Notes"]), .none)
    }

    func testALaunchBorrowsTheStartupWindowOnlyWhenTheUserIsntInTheApp() {
        XCTAssertTrue(WindowManager.mayBorrowStartupWindow(startupWindows: 1, pid: 50, front: 60))
        // The user went to the app while the open waited its turn.
        XCTAssertFalse(WindowManager.mayBorrowStartupWindow(startupWindows: 1, pid: 50, front: 50))
        XCTAssertFalse(WindowManager.mayBorrowStartupWindow(startupWindows: 2, pid: 50, front: 60))
        XCTAssertFalse(WindowManager.mayBorrowStartupWindow(startupWindows: 0, pid: 50, front: 60))
    }
}
