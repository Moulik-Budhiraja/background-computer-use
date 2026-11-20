import XCTest
import CoreGraphics
@testable import BCUCore

final class KeyMapTests: XCTestCase {
    /// A modifier it doesn't know must fail the step, not press the bare key.
    func testUnknownModifierIsRejected() {
        XCTAssertThrowsError(try KeyMap.press(key: "w", modifiers: ["cmmd"])) { error in
            XCTAssertTrue("\(error)".contains("cmd, shift, option, ctrl, fn"))
        }
        XCTAssertThrowsError(try KeyMap.press(key: "w", modifiers: ["cmd", "hyper"]))
    }

    func testModifierNamesAndSymbols() throws {
        XCTAssertEqual(try KeyMap.press(key: "w", modifiers: ["Cmd "]).1, .maskCommand)
        XCTAssertEqual(try KeyMap.press(key: "w", modifiers: ["⌘", "⇧"]).1, [.maskCommand, .maskShift])
        XCTAssertEqual(try KeyMap.press(key: "w", modifiers: ["alt", "control"]).1, [.maskAlternate, .maskControl])
    }

    /// With other modifiers a letter's case doesn't matter; on its own an
    /// uppercase letter or a shifted character adds Shift.
    func testShiftFromTheKey() throws {
        XCTAssertEqual(try KeyMap.press(key: "A", modifiers: ["cmd"]).1, .maskCommand)
        XCTAssertEqual(try KeyMap.press(key: "A", modifiers: []).1, .maskShift)
        XCTAssertEqual(try KeyMap.press(key: "a", modifiers: []).1, [])
        XCTAssertEqual(try KeyMap.press(key: "?", modifiers: ["cmd"]).1, [.maskCommand, .maskShift])
        XCTAssertEqual(try KeyMap.press(key: "A", modifiers: ["cmd", "shift"]).1, [.maskCommand, .maskShift])
        XCTAssertEqual(try KeyMap.press(key: "A", modifiers: ["cmd"]).0, try KeyMap.press(key: "a", modifiers: ["cmd"]).0)
    }

    /// "\r\n" is a single Character in Swift; it still has to press Return.
    func testCRLFIsReturn() {
        let chars = Array("a\r\nb")
        XCTAssertEqual(chars.count, 3)
        XCTAssertTrue(Input.isReturn(chars[1]))
        XCTAssertTrue(Input.isReturn("\n"))
        XCTAssertTrue(Input.isReturn("\r"))
        XCTAssertFalse(Input.isReturn("\t"))
        XCTAssertFalse(Input.isReturn("a"))
    }
}
