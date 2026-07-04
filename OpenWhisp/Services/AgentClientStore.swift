import Foundation

/// The consent decision a stored policy yields for a given capability request.
public enum AgentConsentDecision: Equatable {
    /// Proceed without prompting.
    case allow
    /// Suspend the request and present the consent window.
    case prompt
    /// Refuse immediately (a stored "denied", so we don't re-prompt / spam).
    case deny
}

/// A distinct capability an agent client can be granted — consent is per-scope so
/// approving an agent to ask a question (`dictate`) does NOT also let it read your
/// dictation `history` or run text through your LLM (`refine`). Matches the plan's
/// §10 "do not ride history on a mic grant". Paste is deliberately absent: agent
/// dictate never pastes (it returns text to the caller), so there is no paste
/// scope to grant.
public enum AgentScope: String, Codable, Equatable, Sendable, CaseIterable {
    case dictate
    case history
    case refine

    /// A short human label for the consent window / settings pane.
    public var title: String {
        switch self {
        case .dictate: return "ask you to dictate"
        case .history: return "read your dictation history"
        case .refine:  return "rewrite text with your on-device AI"
        }
    }

    /// A one-word noun for terse UI (settings rows).
    public var noun: String {
        switch self {
        case .dictate: return "Dictate"
        case .history: return "History"
        case .refine:  return "Refine"
        }
    }
}

/// How OpenWhisp should treat future requests from a given agent client.
public enum AgentConsentPolicy: String, Codable, Equatable, Sendable {
    /// Prompt on every request (no standing grant).
    case askEveryTime
    /// Grant for the lifetime of this app run.
    case whileRunning
    /// Grant persistently.
    case always
    /// Refuse persistently (fail fast, no prompt).
    case denied

    /// The decision this policy yields. `whileRunning` grants only when the grant
    /// was made during the current app run (`grantedThisRun`).
    public func decision(grantedThisRun: Bool) -> AgentConsentDecision {
        switch self {
        case .always: return .allow
        case .denied: return .deny
        case .whileRunning: return grantedThisRun ? .allow : .prompt
        case .askEveryTime: return .prompt
        }
    }
}

/// A per-client consent record. Keyed by `clientName` today (all admitted clients
/// have already passed the socket's code-signature gate); `signingID` is recorded
/// for a future hardening that binds consent to the verified signing identity.
///
/// Consent is **per-scope**: `scopePolicies` maps each ``AgentScope`` to its own
/// policy, so a grant for one capability never rides along to another. A scope
/// absent from the map has no standing grant (→ prompt on first use).
public struct AgentClientRecord: Codable, Equatable, Sendable {
    public var clientName: String
    /// Per-scope consent policies. A missing scope means "no decision yet" (prompt).
    public var scopePolicies: [AgentScope: AgentConsentPolicy]
    public var firstSeen: Date
    public var lastCall: Date?
    public var lastTool: String?
    /// The verified signing identity at record time (Team ID / designated-
    /// requirement digest), for display and future identity-bound consent.
    public var signingID: String?

    public init(
        clientName: String, scopePolicies: [AgentScope: AgentConsentPolicy],
        firstSeen: Date, lastCall: Date? = nil, lastTool: String? = nil, signingID: String? = nil
    ) {
        self.clientName = clientName
        self.scopePolicies = scopePolicies
        self.firstSeen = firstSeen
        self.lastCall = lastCall
        self.lastTool = lastTool
        self.signingID = signingID
    }

    /// Convenience: build a record that applies one policy to every scope (used by
    /// migration and by tests).
    public init(
        clientName: String, allScopes policy: AgentConsentPolicy,
        firstSeen: Date, lastCall: Date? = nil, lastTool: String? = nil, signingID: String? = nil
    ) {
        self.init(
            clientName: clientName,
            scopePolicies: Dictionary(uniqueKeysWithValues: AgentScope.allCases.map { ($0, policy) }),
            firstSeen: firstSeen, lastCall: lastCall, lastTool: lastTool, signingID: signingID
        )
    }

    /// The stored policy for `scope`, or nil if none has been recorded.
    public func policy(for scope: AgentScope) -> AgentConsentPolicy? {
        scopePolicies[scope]
    }

    // MARK: - Codable (migration-aware)

    private enum CodingKeys: String, CodingKey {
        case clientName, scopePolicies, policy, firstSeen, lastCall, lastTool, signingID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.clientName = try c.decode(String.self, forKey: .clientName)
        self.firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        self.lastCall = try c.decodeIfPresent(Date.self, forKey: .lastCall)
        self.lastTool = try c.decodeIfPresent(String.self, forKey: .lastTool)
        self.signingID = try c.decodeIfPresent(String.self, forKey: .signingID)

        // On the wire `scopePolicies` is keyed by the scope's RAW STRING (a
        // readable JSON object). We bridge to the typed [AgentScope:...] here —
        // NOT by declaring the property `[AgentScope: ...]` directly, because
        // Swift encodes a dictionary with a non-String/Int key as a flat
        // [k,v,k,v] array, which would be neither readable nor stable.
        if let raw = try c.decodeIfPresent([String: AgentConsentPolicy].self, forKey: .scopePolicies) {
            self.scopePolicies = Self.typed(from: raw)
        } else if let legacy = try c.decodeIfPresent(AgentConsentPolicy.self, forKey: .policy) {
            // MIGRATION: a v1 record carried a single `policy` covering everything.
            // Apply it to ALL scopes so an existing grant stays byte-identical —
            // a client that was "always allowed" remains allowed for every scope,
            // a "denied" stays denied everywhere. (No security regression: nothing
            // widens, and the user can now narrow a scope in Settings.)
            self.scopePolicies = Dictionary(uniqueKeysWithValues: AgentScope.allCases.map { ($0, legacy) })
        } else {
            self.scopePolicies = [:]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientName, forKey: .clientName)
        // Encode scopes keyed by raw string (readable object); never the legacy
        // `policy` key — a re-saved record is always in the new shape.
        try c.encode(Self.raw(from: scopePolicies), forKey: .scopePolicies)
        try c.encode(firstSeen, forKey: .firstSeen)
        try c.encodeIfPresent(lastCall, forKey: .lastCall)
        try c.encodeIfPresent(lastTool, forKey: .lastTool)
        try c.encodeIfPresent(signingID, forKey: .signingID)
    }

    private static func typed(from raw: [String: AgentConsentPolicy]) -> [AgentScope: AgentConsentPolicy] {
        var out: [AgentScope: AgentConsentPolicy] = [:]
        for (k, v) in raw {
            if let scope = AgentScope(rawValue: k) { out[scope] = v } // unknown scope keys ignored
        }
        return out
    }
    private static func raw(from typed: [AgentScope: AgentConsentPolicy]) -> [String: AgentConsentPolicy] {
        Dictionary(uniqueKeysWithValues: typed.map { ($0.key.rawValue, $0.value) })
    }
}

/// Local, on-device store of agent-client consent records (JSON in Application
/// Support). Pure and Foundation-only, so the policy/lookup logic is unit-tested.
/// A corrupt/hand-edited file is quarantined (moved aside) rather than silently
/// overwritten — the same idiom TranscriptionHistoryStore uses.
public struct AgentClientStore: Codable, Equatable {
    public var records: [AgentClientRecord]

    public init(records: [AgentClientRecord] = []) {
        self.records = records
    }

    public func record(for clientName: String) -> AgentClientRecord? {
        records.first { $0.clientName == clientName }
    }

    /// Insert or replace a client's record (keyed by name).
    public mutating func upsert(_ record: AgentClientRecord) {
        if let i = records.firstIndex(where: { $0.clientName == record.clientName }) {
            records[i] = record
        } else {
            records.append(record)
        }
    }

    public mutating func remove(clientName: String) {
        records.removeAll { $0.clientName == clientName }
    }

    /// Demote every `.whileRunning` scope to `.askEveryTime`: that grant dies with
    /// the app run that made it, and a row loaded from disk would otherwise render
    /// in the settings pane as a standing grant that no longer exists. (The
    /// decision logic already treats the two identically once the run-set is
    /// empty — this keeps what the UI shows in agreement.) Applied on load.
    public mutating func demoteRunScopedGrants() {
        for i in records.indices {
            for scope in records[i].scopePolicies.keys where records[i].scopePolicies[scope] == .whileRunning {
                records[i].scopePolicies[scope] = .askEveryTime
            }
        }
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("agent-clients.json")
    }

    public static func load() -> AgentClientStore {
        guard let data = try? Data(contentsOf: fileURL) else { return AgentClientStore() }
        do {
            var store = try JSONDecoder().decode(AgentClientStore.self, from: data)
            store.demoteRunScopedGrants()
            return store
        } catch {
            // Corrupt / hand-edited / version-skewed: move aside so the next save
            // doesn't overwrite and make the loss permanent.
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            print("[AgentClientStore] load failed: \(error); moved file to \(backup.lastPathComponent)")
            return AgentClientStore()
        }
    }

    public func save() {
        do {
            let dir = Self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            print("[AgentClientStore] save failed: \(error.localizedDescription)")
        }
    }
}
