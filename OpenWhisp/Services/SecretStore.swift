import Foundation

/// Platform-agnostic secret storage seam (Phase 2.5 core extraction).
///
/// AppState talks to this protocol instead of a concrete keychain so the
/// secret-handling logic is testable (inject an in-memory store) and a future
/// non-macOS port can supply its own backend (Windows Credential Manager /
/// DPAPI, libsecret, etc.) without touching call sites.
///
/// Contract: `save` with an empty string deletes the entry; `read` returns nil
/// when no value is stored.
protocol SecretStore: AnyObject {
    func read(key: String) -> String?
    func save(_ value: String, key: String)
}

/// A non-persistent `SecretStore` used by tests and as a safe fallback. Pure
/// Foundation, so it lives in OpenWhispCore and is exercised by `swift test`.
final class InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]

    init(seed: [String: String] = [:]) {
        storage = seed
    }

    func read(key: String) -> String? {
        storage[key]
    }

    func save(_ value: String, key: String) {
        if value.isEmpty {
            storage.removeValue(forKey: key)
        } else {
            storage[key] = value
        }
    }
}
