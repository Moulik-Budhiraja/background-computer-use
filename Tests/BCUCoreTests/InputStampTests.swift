import XCTest
import CoreGraphics
@testable import BCUCore

final class InputStampTests: XCTestCase {
    private func stamped(_ type: CGEventType, at point: CGPoint, origin: CGPoint) throws -> CGEvent {
        let e = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
        Input.stampMouse(e, pid: 1, windowID: 7, phase: 3, clickState: 1, button: 0, at: point, origin: origin)
        return e
    }

    /// A click with a timestamp from long ago is dropped by apps that order
    /// input by time, so every mouse event carries the time it was posted.
    func testMouseEventsCarryTheTimeNow() throws {
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged] {
            let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let e = try stamped(type, at: CGPoint(x: 500, y: 400), origin: CGPoint(x: 300, y: 100))
            let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            XCTAssertGreaterThanOrEqual(e.timestamp, before)
            XCTAssertLessThanOrEqual(e.timestamp, after)
        }
    }

    /// The app reads the event's place from the point inside the window, so
    /// it must be the global point less the window's origin.
    func testEventCarriesThePointInsideTheWindow() throws {
        typealias Getter = @convention(c) (CGEvent) -> CGPoint
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventGetWindowLocation") else {
            throw XCTSkip("CGEventGetWindowLocation isn't there on this macOS")
        }
        let windowLocation = unsafeBitCast(symbol, to: Getter.self)
        // A window on a display below and right of the main one, like the agent's.
        let e = try stamped(.leftMouseDown, at: CGPoint(x: 3182, y: 1926), origin: CGPoint(x: 3032, y: 1746))
        XCTAssertEqual(windowLocation(e), CGPoint(x: 150, y: 180))
        XCTAssertEqual(e.location, CGPoint(x: 3182, y: 1926))
    }
}
