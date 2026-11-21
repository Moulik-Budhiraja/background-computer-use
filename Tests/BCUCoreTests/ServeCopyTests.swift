import XCTest
@testable import BCUShared

/// Builds stand-in app folders in a temporary directory; reads nothing else.
final class ServeCopyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("serve-copy-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `<name>.app` with the bundle id given and a `bcu` in Contents/MacOS.
    private func bcu(inApp name: String, bundleID: String) throws -> URL {
        let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let exe = contents.appendingPathComponent("MacOS/bcu")
        FileManager.default.createFile(atPath: exe.path, contents: Data())
        return exe
    }

    func testTheMenuBarAppsOwnBcuRefusesServe() throws {
        let own = try bcu(inApp: "Background Computer Use", bundleID: BCUPaths.bundleID)
        let refusal = try XCTUnwrap(BCUCopy.serveRefusal(own))
        XCTAssertTrue(refusal.contains("serve"))
        XCTAssertFalse(refusal.contains("\n"))
    }

    func testAHostAppsBcuServes() throws {
        let host = try bcu(inApp: "Some Host", bundleID: "com.example.host")
        XCTAssertNil(BCUCopy.serveRefusal(host))
        // Its own name doesn't matter, only the bundle id.
        let renamed = try bcu(inApp: "Background Computer Use Copy", bundleID: "com.example.other")
        XCTAssertNil(BCUCopy.serveRefusal(renamed))
    }

    func testABcuInNoAppServes() {
        // A development build (.build/debug/bcu), as the protocol tests run it.
        XCTAssertNil(BCUCopy.serveRefusal(root.appendingPathComponent(".build/debug/bcu")))
    }
}
