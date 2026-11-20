import XCTest
import BCUShared
@testable import BCUCore

/// A test run never shares the installed app's state folder. The gate's
/// tests write and delete its record of WindowServer's permitted-front list
/// there, and a running engine that finds its record gone forgets entries
/// that stay on the list: every app launched after that is refused the front,
/// the user's own clicks included, until they log out.
final class TestHomeTests: XCTestCase {
    func testATestRunHasItsOwnStateFolder() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BCU_HOME"] != nil, "BCU_HOME picks the folder")
        let installed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundComputerUse", isDirectory: true)
        XCTAssertNotEqual(BCUPaths.supportDirectory.standardizedFileURL.path, installed.standardizedFileURL.path)
    }
}
