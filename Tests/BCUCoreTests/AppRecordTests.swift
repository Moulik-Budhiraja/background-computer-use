import XCTest
import BCUShared
@testable import BCUCore

/// The app's record of where it's installed (app.json), read by `bcu` and
/// by host apps' `bcu serve` to find and start the app.
final class AppRecordTests: XCTestCase {
    private var mounted: URL?
    private var scratch: URL?

    private func record(_ path: String) -> AppRecord {
        AppRecord(path: path, version: "1.0", protocolVersion: HostServer.protocolVersion,
                  accessibility: true, screenRecording: true)
    }

    override func setUp() {
        try? FileManager.default.removeItem(atPath: BCUPaths.appRecordPath)
    }

    override func tearDown() {
        if let mounted { _ = Self.run("/usr/bin/hdiutil", ["detach", mounted.path, "-force"]) }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A disk image with an app folder in it, mounted read only the way a
    /// downloaded one is.
    private func mountImage() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcu-dmg-\(UUID().uuidString)")
        scratch = dir
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Background Computer Use.app/Contents"), withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("t.dmg")
        XCTAssertEqual(Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", src.path, "-format", "UDZO", "-volname", "BCU Test", image.path]), 0)
        let mount = dir.appendingPathComponent("mnt")
        XCTAssertEqual(Self.run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mount.path, image.path]), 0)
        mounted = mount
        return mount.appendingPathComponent("Background Computer Use.app")
    }

    /// A set-up user opened the copy inside the disk image: the record
    /// pointed at /Volumes from then on, gone once the image was ejected.
    func testTheCopyInADiskImageLeavesTheInstalledRecord() throws {
        let installed = record("/Applications/Background Computer Use.app")
        installed.write()
        let copy = try mountImage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(AppRecord.keep(record(copy.path), from: copy))
        XCTAssertEqual(AppRecord.read(), installed)
    }

    /// Opened where it was downloaded, macOS runs it from a translocated copy.
    func testATranslocatedCopyLeavesTheInstalledRecord() {
        let installed = record("/Applications/Background Computer Use.app")
        installed.write()
        let copy = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Background Computer Use.app")
        XCTAssertFalse(AppRecord.keep(record(copy.path), from: copy))
        XCTAssertEqual(AppRecord.read(), installed)
    }

    func testAnInstalledCopyIsRecorded() {
        record("/Applications/Old.app").write()
        let app = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Background Computer Use.app")
        XCTAssertTrue(AppRecord.keep(record(app.path), from: app))
        XCTAssertEqual(AppRecord.read()?.path, app.path)
    }
}
