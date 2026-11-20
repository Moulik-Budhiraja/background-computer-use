import Carbon
import XCTest
@testable import BCUCore

/// Key codes read from keyboard layouts that ship with macOS. Reads the
/// layouts' data only; the Mac's own input source isn't changed.
final class KeyLayoutTests: XCTestCase {
    private func table(_ id: String, command: Bool = false) throws -> LayoutKeys.Table {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first, let data = LayoutKeys.layoutData(source) else {
            throw XCTSkip("\(id) isn't installed")
        }
        return KeyMap.layoutTable(data, command: command)
    }

    private func XCTAssertKey(_ t: LayoutKeys.Table, _ ch: Character, _ code: CGKeyCode, shift: Bool, line: UInt = #line) {
        XCTAssertEqual(t[ch]?.0, code, "code for \(ch)", line: line)
        XCTAssertEqual(t[ch]?.1, shift, "shift for \(ch)", line: line)
    }

    func testTheUSLayoutMatchesTheBuiltInTable() throws {
        let us = try table("com.apple.keylayout.US")
        for (ch, code) in KeyMap.chars { XCTAssertKey(us, ch, code, shift: false) }
        for (ch, base) in KeyMap.shifted { XCTAssertKey(us, ch, KeyMap.chars[base]!, shift: true) }
        XCTAssertKey(us, "A", 0, shift: true)
        // Digits come from the number row, not the keypad.
        XCTAssertKey(us, "1", 18, shift: false)
        XCTAssertNil(us["\r"])
        XCTAssertNil(us[" "])
    }

    func testAZERTYPutsAAndQWhereTheyAre() throws {
        let fr = try table("com.apple.keylayout.French")
        XCTAssertKey(fr, "a", 12, shift: false)
        XCTAssertKey(fr, "q", 0, shift: false)
        XCTAssertKey(fr, "z", 13, shift: false)
        XCTAssertKey(fr, "w", 6, shift: false)
    }

    func testDvorakPutsSWhereItIs() throws {
        let dv = try table("com.apple.keylayout.Dvorak")
        XCTAssertKey(dv, "s", 41, shift: false)
        XCTAssertKey(dv, "o", 1, shift: false)
        // Dvorak - QWERTY ⌘ types Dvorak but takes shortcuts by QWERTY keys.
        let qc = try table("com.apple.keylayout.DVORAK-QWERTYCMD", command: true)
        XCTAssertKey(qc, "s", 1, shift: false)
    }

    func testRussianHasNoLatinLetters() throws {
        let ru = try table("com.apple.keylayout.Russian")
        XCTAssertNil(ru["c"])
        XCTAssertKey(ru, "с", 8, shift: false)
    }
}
