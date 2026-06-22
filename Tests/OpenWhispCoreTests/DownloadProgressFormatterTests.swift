import XCTest
@testable import OpenWhispCore

final class DownloadProgressFormatterTests: XCTestCase {

    private let mb: Int64 = 1_000_000 // ByteCountFormatter .file uses 1000-based units

    // MARK: - fraction

    func testNormalFraction() {
        // 50 MB of 147 MB ≈ 0.34
        let frac = DownloadProgressFormatter.fraction(written: 50 * mb, totalExpected: 147 * mb)
        XCTAssertNotNil(frac)
        XCTAssertEqual(frac!, 0.34, accuracy: 0.005)
    }

    func testZeroBytes() {
        let frac = DownloadProgressFormatter.fraction(written: 0, totalExpected: 147 * mb)
        XCTAssertEqual(frac, 0.0)
    }

    func testComplete() {
        let frac = DownloadProgressFormatter.fraction(written: 147 * mb, totalExpected: 147 * mb)
        XCTAssertEqual(frac, 1.0)
    }

    func testOverReportedClampsToOne() {
        // A server reporting more written than expected should still clamp to 1.0.
        let frac = DownloadProgressFormatter.fraction(written: 200 * mb, totalExpected: 147 * mb)
        XCTAssertEqual(frac, 1.0)
    }

    func testUnknownTotalReturnsNil() {
        XCTAssertNil(DownloadProgressFormatter.fraction(written: 50 * mb, totalExpected: 0))
        XCTAssertNil(DownloadProgressFormatter.fraction(written: 50 * mb, totalExpected: -1))
    }

    // MARK: - byteLabel

    func testByteLabelFormatsMB() {
        XCTAssertEqual(DownloadProgressFormatter.byteLabel(147 * mb), "147 MB")
    }

    func testByteLabelNegativeClampsToZero() {
        // Should not crash or produce a negative byte label.
        let label = DownloadProgressFormatter.byteLabel(-5)
        XCTAssertEqual(label, DownloadProgressFormatter.byteLabel(0))
    }

    // MARK: - make (full snapshot)

    func testMakeNormalSnapshot() {
        let p = DownloadProgressFormatter.make(written: 62 * mb, totalExpected: 147 * mb)
        XCTAssertNotNil(p.fraction)
        XCTAssertFalse(p.isIndeterminate)
        // 62/147 ≈ 0.4217 -> 42%
        XCTAssertTrue(p.label.contains("42%"), "label was \(p.label)")
        XCTAssertTrue(p.label.contains("62 MB"), "label was \(p.label)")
        XCTAssertTrue(p.label.contains("147 MB"), "label was \(p.label)")
    }

    func testMakeZeroSnapshot() {
        let p = DownloadProgressFormatter.make(written: 0, totalExpected: 147 * mb)
        XCTAssertEqual(p.fraction, 0.0)
        XCTAssertTrue(p.label.contains("0%"), "label was \(p.label)")
    }

    func testMakeCompleteSnapshot() {
        let p = DownloadProgressFormatter.make(written: 147 * mb, totalExpected: 147 * mb)
        XCTAssertEqual(p.fraction, 1.0)
        XCTAssertTrue(p.label.contains("100%"), "label was \(p.label)")
    }

    func testMakeUnknownTotalSnapshot() {
        let p = DownloadProgressFormatter.make(written: 62 * mb, totalExpected: 0)
        XCTAssertNil(p.fraction)
        XCTAssertTrue(p.isIndeterminate)
        // No percentage, but still shows what's downloaded.
        XCTAssertFalse(p.label.contains("%"), "label was \(p.label)")
        XCTAssertTrue(p.label.contains("62 MB"), "label was \(p.label)")
    }
}
