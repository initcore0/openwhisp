import XCTest
@testable import OpenWhispCore

/// The always-compiled pure parts of the instrumentation helper. The signpost /
/// logging body is gated behind OPENWHISP_INSTRUMENTATION (a developer build flag),
/// so `swift test` exercises the no-op path: isEnabled is false and the measure
/// wrappers must still run the block and return its value.
final class InstrumentationTests: XCTestCase {

    func testDisabledInTestBuild() {
        // Tests run without the OPENWHISP_INSTRUMENTATION flag.
        XCTAssertFalse(Instrumentation.isEnabled)
    }

    func testFormatMilliseconds() {
        XCTAssertEqual(Instrumentation.format(seconds: 0), "0ms")
        XCTAssertEqual(Instrumentation.format(seconds: 4.231), "4231ms")
        XCTAssertEqual(Instrumentation.format(seconds: 0.0004), "0ms")   // rounds down
        XCTAssertEqual(Instrumentation.format(seconds: 0.0006), "1ms")   // rounds up
        XCTAssertEqual(Instrumentation.format(seconds: 1.2345), "1235ms")
    }

    func testMeasureSyncReturnsValueWhenDisabled() {
        let result = Instrumentation.measure("test.sync") { 1 + 2 }
        XCTAssertEqual(result, 3)
    }

    func testMeasureSyncPropagatesThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(try Instrumentation.measure("test.throw") { throw Boom() })
    }

    func testMeasureAsyncReturnsValueWhenDisabled() async throws {
        let result = try await Instrumentation.measure("test.async") {
            try await Task.sleep(nanoseconds: 1_000)
            return "ok"
        }
        XCTAssertEqual(result, "ok")
    }

    func testManualSpanIsNoOpButSafeWhenDisabled() {
        // begin/end must be safe to call even with instrumentation compiled out.
        let span = Instrumentation.begin("test.manual")
        Instrumentation.end(span)
    }
}
