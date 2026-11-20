import XCTest
import CoreGraphics
@testable import BCUCore

/// Shortcuts by the user's layout outside press_key, and the layout cache.
final class LayoutShortcutTests: XCTestCase {
    /// On Dvorak - QWERTY ⌘, s is key 41 on its own and key 1 with cmd. A
    /// cmd+s from the user simulator or the remote key hook must look it up
    /// with cmd held.
    func testShortcutLooksUpTheKeyWithCommand() throws {
        let dvorakQwertyCmd: (String, Bool) throws -> (CGKeyCode, Bool) = { _, command in (command ? 1 : 41, false) }
        let (code, flags) = try KeyMap.shortcut("s", modifiers: ["cmd"], lookup: dvorakQwertyCmd)
        XCTAssertEqual(code, 1)
        XCTAssertEqual(flags, .maskCommand)
        XCTAssertEqual(try KeyMap.shortcut("s", modifiers: [], lookup: dvorakQwertyCmd).0, 41)
    }

    /// The user switched layouts while the tables were being read: the old
    /// tables must not be kept.
    func testAValueReadBeforeAnInvalidationIsNotKept() {
        let cache = Invalidated<Int>()
        let (_, generation) = cache.read()
        cache.invalidate()
        cache.publish(1, readAt: generation)
        XCTAssertNil(cache.read().0)
    }

    func testAValueReadSinceIsKept() {
        let cache = Invalidated<Int>()
        let (_, generation) = cache.read()
        cache.publish(1, readAt: generation)
        XCTAssertEqual(cache.read().0, 1)
    }
}

/// The take-over's keys from a host, by DOM key when the code is unknown.
final class HostKeyFallbackTests: XCTestCase {
    /// On Dvorak - QWERTY ⌘, q is key 7 on its own and key 12 with cmd. A
    /// host's cmd+q with no code must come out as key 12, which the
    /// take-over blocks so it can't quit the user's app.
    func testCommandQWithNoCodeIsLookedUpWithCommand() {
        let dvorakQwertyCmd: (String, Bool) throws -> (CGKeyCode, Bool) = { _, command in (command ? 12 : 7, false) }
        XCTAssertEqual(HostInput.keyCode(code: "", key: "q", command: true, lookup: dvorakQwertyCmd), 12)
        XCTAssertEqual(HostInput.keyCode(code: "", key: "q", command: false, lookup: dvorakQwertyCmd), 7)
    }
}
