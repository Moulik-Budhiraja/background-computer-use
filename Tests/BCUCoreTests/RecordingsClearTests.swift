import XCTest
@testable import BCUCore

/// Clear History in Settings: everything but a live run goes, and History hears of it.
final class RecordingsClearTests: XCTestCase {
    func testDeleteAllRemovesRecordingsAndTellsHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcu-clear-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["run-a", "run-b"] {
            let d = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: d.appendingPathComponent("chunk-1.mp4"))
        }
        let store = Recordings(directory: dir)
        let posted = expectation(forNotification: Recordings.changed, object: store)
        store.deleteAll()
        wait(for: [posted], timeout: 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, [])
        XCTAssertEqual(store.usedBytes(), 0)
    }
}
