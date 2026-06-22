import XCTest
@testable import OpenWhispCore

final class SecureFieldPolicyTests: XCTestCase {

    // MARK: Secure (must refuse)

    func testSecureSubroleIsSecure() {
        XCTAssertTrue(SecureFieldPolicy.isSecure(subrole: "AXSecureTextField"))
    }

    func testSecureSubroleWithTextFieldRoleIsSecure() {
        // A password field reports role "AXTextField" + subrole "AXSecureTextField".
        XCTAssertTrue(SecureFieldPolicy.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
    }

    func testSecureSubroleWithSurroundingWhitespaceIsSecure() {
        XCTAssertTrue(SecureFieldPolicy.isSecure(subrole: "  AXSecureTextField  "))
    }

    func testConstantMatchesAppKitSubrole() {
        XCTAssertEqual(SecureFieldPolicy.secureTextFieldSubrole, "AXSecureTextField")
    }

    // MARK: Not secure (must allow / fail-open)

    func testNilSubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: nil))
    }

    func testEmptySubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: ""))
    }

    func testWhitespaceOnlySubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: "   "))
    }

    func testNormalTextFieldSubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: "AXTextField"))
    }

    func testTextAreaSubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: "AXTextArea"))
    }

    func testUnknownSubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: "AXSearchField"))
    }

    // MARK: Case sensitivity (AX identifiers are exact)

    func testLowercasedSubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: "axsecuretextfield"))
    }

    func testWrongCaseSubroleIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(subrole: "AXSECURETEXTFIELD"))
    }

    // MARK: Role/subrole combined entry point

    func testRoleIgnoredWhenSubroleNotSecure() {
        // Role alone never marks a field secure; only the secure subrole does.
        XCTAssertFalse(SecureFieldPolicy.isSecure(role: "AXSecureTextField", subrole: "AXTextField"))
    }

    func testBothNilIsNotSecure() {
        XCTAssertFalse(SecureFieldPolicy.isSecure(role: nil, subrole: nil))
    }
}
