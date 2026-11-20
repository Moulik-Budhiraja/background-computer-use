import XCTest
import ApplicationServices
@testable import BCUCore

/// Whether type_text with an element may type after focusing it.
final class FocusTookTests: XCTestCase {
    /// A static text in a web page takes the AXFocused write without an
    /// error but can't have focus: keys would go to the field that has it.
    func testAnElementThatCantTakeFocusFails() {
        XCTAssertFalse(Engine.focusTook(write: .success, settable: false, focused: false))
        XCTAssertFalse(Engine.focusTook(write: .success, settable: false, focused: nil))
    }

    func testAFieldThatTakesFocusPasses() {
        XCTAssertTrue(Engine.focusTook(write: .success, settable: true, focused: true))
        XCTAssertTrue(Engine.focusTook(write: .success, settable: true, focused: nil))
    }

    /// Some elements refuse the write but have focus anyway.
    func testRefusedWriteWithFocusPasses() {
        XCTAssertTrue(Engine.focusTook(write: .failure, settable: false, focused: true))
        XCTAssertFalse(Engine.focusTook(write: .failure, settable: true, focused: false))
    }
}
