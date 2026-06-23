import XCTest
@testable import OpenWhispCore

/// Covers the debounced press/release edge detection that every macOS hotkey
/// handler (CGEvent/NSEvent × fn/control-space) now shares. This logic was
/// duplicated four times and untested; the protocol extraction made it a pure,
/// testable unit.
final class HotkeyGestureTests: XCTestCase {
    func testBecomingActiveFromReleasedIsDown() {
        XCTAssertEqual(HotkeyGesture.resolve(isActive: true, wasPressed: false), .down)
    }

    func testBecomingInactiveFromPressedIsUp() {
        XCTAssertEqual(HotkeyGesture.resolve(isActive: false, wasPressed: true), .up)
    }

    func testStillActiveWhileHeldIsNone() {
        // Held down — must NOT re-fire onHotkeyDown (push-to-talk would re-trigger).
        XCTAssertEqual(HotkeyGesture.resolve(isActive: true, wasPressed: true), .none)
    }

    func testStillInactiveIsNone() {
        // Unrelated/repeat release event while not pressed — no-op.
        XCTAssertEqual(HotkeyGesture.resolve(isActive: false, wasPressed: false), .none)
    }

    /// A press→hold→release cycle yields exactly one down and one up, with the
    /// debounced state threaded the way the monitor threads `isPressed`.
    func testFullCycleFiresOneDownOneUp() {
        var pressed = false
        var events: [HotkeyGesture] = []

        func step(_ active: Bool) {
            let g = HotkeyGesture.resolve(isActive: active, wasPressed: pressed)
            switch g {
            case .down: pressed = true
            case .up: pressed = false
            case .none: break
            }
            events.append(g)
        }

        step(true)   // press
        step(true)   // hold (flagsChanged repeat)
        step(true)   // hold
        step(false)  // release
        step(false)  // stray release

        XCTAssertEqual(events, [.down, .none, .none, .up, .none])
        XCTAssertFalse(pressed)
    }
}
