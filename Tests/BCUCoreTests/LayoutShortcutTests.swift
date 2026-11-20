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

/// The take-over never sends cmd+Q, whatever layout the host typed it on.
final class HostQuitBlockTests: XCTestCase {
    /// A US host's cmd+Q (code KeyQ, key 12) with French selected here,
    /// where Q is key 0: its text is still "q", and the app quits on it.
    func testCommandQFromAnotherLayoutIsBlocked() {
        XCTAssertTrue(HostInput.quitBlocked(command: true, keyCode: 12, key: "q", quitCode: 0))
        XCTAssertTrue(HostInput.quitBlocked(command: true, keyCode: 12, key: "Q", quitCode: 0))
    }

    func testCommandQOnThisLayoutIsBlocked() {
        XCTAssertTrue(HostInput.quitBlocked(command: true, keyCode: 0, key: "", quitCode: 0))
    }

    func testOtherKeysGoThrough() {
        // cmd+A typed on a French host: key 12 here, text "a".
        XCTAssertFalse(HostInput.quitBlocked(command: true, keyCode: 12, key: "a", quitCode: 0))
        XCTAssertFalse(HostInput.quitBlocked(command: false, keyCode: 0, key: "q", quitCode: 0))
    }
}

/// press_key's key and flags, by the user's layout.
final class PressLayoutTests: XCTestCase {
    /// On Dvorak - QWERTY ⌘, s is key 41 on its own and key 1 with cmd:
    /// press_key cmd+s must send key 1 (Save), not Cmd+;.
    func testPressLooksUpTheKeyWithCommand() throws {
        let dvorakQwertyCmd: (String, Bool) throws -> (CGKeyCode, Bool) = { _, command in (command ? 1 : 41, false) }
        let (code, flags) = try KeyMap.press(key: "s", modifiers: ["cmd"], lookup: dvorakQwertyCmd)
        XCTAssertEqual(code, 1)
        XCTAssertEqual(flags, .maskCommand)
        XCTAssertEqual(try KeyMap.press(key: "s", modifiers: [], lookup: dvorakQwertyCmd).0, 41)
    }
}

/// A host on another layout than this Mac's sends keys by its own layout.
final class HostQuitBlockOtherKeysTests: XCTestCase {
    /// A US host's cmd+A (code KeyA, key 0) with French selected here,
    /// where key 0 types Q: the event's text is "a", so it's Select All.
    func testCommandAFromAnotherLayoutGoesThrough() {
        XCTAssertFalse(HostInput.quitBlocked(command: true, keyCode: 0, key: "a", quitCode: 0))
    }
}

/// A host on a non-Latin layout sends its own letter as the key's text.
final class HostQuitBlockNonLatinTests: XCTestCase {
    /// A Russian host's cmd+Q: code KeyQ, text "й". macOS matches the
    /// shortcut by its key, so it's still Quit.
    func testCommandQFromANonLatinLayoutIsBlocked() {
        XCTAssertTrue(HostInput.quitBlocked(command: true, keyCode: 12, key: "й", quitCode: 12))
        XCTAssertFalse(HostInput.quitBlocked(command: true, keyCode: 0, key: "ф", quitCode: 12))
    }
}

/// Reading the layout tables needs the main thread, which is busy while
/// BCU quits.
final class LayoutRefillQuitTests: XCTestCase {
    /// A key pressed as BCU quits waited on the main thread, which was
    /// waiting on the tool: shutdown timed out before agent windows were
    /// released. The lookup must fail instead.
    func testARefillWhileQuittingFailsInsteadOfWaiting() {
        let saved = LayoutKeys.runOnMain
        defer { LayoutKeys.runOnMain = saved }
        LayoutKeys.runOnMain = { _ in false }
        LayoutKeys.forget()
        // A thread of its own: a sync onto a global queue runs on the caller's
        // thread, which here is the main one, and that reads the tables directly.
        var threw = false
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do { _ = try LayoutKeys.code(for: "a", command: false) } catch { threw = true }
            done.signal()
        }
        done.wait()
        XCTAssertTrue(threw)
    }
}
