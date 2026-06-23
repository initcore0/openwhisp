import XCTest
@testable import OpenWhispCore

/// Exercises the `SecretStore` contract via the in-memory implementation. The
/// macOS Keychain backend (KeychainStore) can't be unit-tested without a login
/// keychain, but it conforms to the same protocol and shares this contract.
final class SecretStoreTests: XCTestCase {
    func testReadReturnsNilForUnknownKey() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.read(key: "missing"))
    }

    func testSaveThenReadRoundTrips() {
        let store = InMemorySecretStore()
        store.save("sk-secret", key: "openAIAPIKey")
        XCTAssertEqual(store.read(key: "openAIAPIKey"), "sk-secret")
    }

    func testSaveOverwritesExistingValue() {
        let store = InMemorySecretStore()
        store.save("old", key: "k")
        store.save("new", key: "k")
        XCTAssertEqual(store.read(key: "k"), "new")
    }

    func testSavingEmptyStringDeletesEntry() {
        let store = InMemorySecretStore(seed: ["k": "value"])
        XCTAssertEqual(store.read(key: "k"), "value")
        store.save("", key: "k")
        XCTAssertNil(store.read(key: "k"))
    }

    func testKeysAreIndependent() {
        let store = InMemorySecretStore()
        store.save("a", key: "first")
        store.save("b", key: "second")
        XCTAssertEqual(store.read(key: "first"), "a")
        XCTAssertEqual(store.read(key: "second"), "b")
        store.save("", key: "first")
        XCTAssertNil(store.read(key: "first"))
        XCTAssertEqual(store.read(key: "second"), "b")
    }

    func testSeedInitialization() {
        let store = InMemorySecretStore(seed: ["preloaded": "x"])
        XCTAssertEqual(store.read(key: "preloaded"), "x")
    }
}
