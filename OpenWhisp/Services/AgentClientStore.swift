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
    /// P2P config/history sync (MAK-51 WP0b): the paired iPhone reading and merging
    /// your vocabulary, profiles/modes, packs, and history over the LAN link. A
    /// per-scope grant so pairing a phone for sync never implies letting it drive
    /// your mic (`dictate`) or your LLM (`refine`). An old consent file that
    /// predates this scope simply has no decision recorded → first sync prompts.
    case sync
    /// Transcribe a local audio file the agent hands over (MAK-83): the agent
    /// gives OpenWhisp a path and gets the transcript, all on-device. A per-scope
    /// grant so approving file transcription never implies driving the mic
    /// (`dictate`), reading `history`, or running the LLM (`refine`). Not in
    /// ``legacyV1Scopes``, so a migrated always-allow client has NO decision here
    /// and prompts on first use.
    case transcribeFile

    /// The scopes that existed when consent was a single `policy` value (v1).
    /// FROZEN: the legacy-record migration maps the old blanket policy onto
    /// exactly this set, so every scope added later starts with NO decision and
    /// prompts. Never add a new case here — that would retroactively grant it
    /// to every migrated "always allow" client.
    public static let legacyV1Scopes: [AgentScope] = [.dictate, .history, .refine]

    /// A short human label for the consent window / settings pane.
    public var title: String {
        switch self {
        case .dictate: return "ask you to dictate"
        case .history: return "read your dictation history"
        case .refine:  return "rewrite text with your on-device AI"
        case .sync:    return "sync your vocabulary, modes, and history"
        case .transcribeFile: return "transcribe an audio file on your Mac"
        }
    }

    /// A one-word noun for terse UI (settings rows).
    public var noun: String {
        switch self {
        case .dictate: return "Dictate"
        case .history: return "History"
        case .refine:  return "Refine"
        case .sync:    return "Sync"
        case .transcribeFile: return "Transcribe"
        }
    }

    /// SF Symbol for the consent window's header.
    public var icon: String {
        switch self {
        case .dictate: return "mic.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .refine:  return "wand.and.stars"
        case .sync:    return "arrow.triangle.2.circlepath"
        case .transcribeFile: return "waveform.badge.magnifyingglass"
        }
    }

    /// The privacy-relevant sentence describing what granting THIS scope exposes.
    /// Load-bearing consent copy — kept here, next to the scope definition, so a
    /// new scope cannot ship without deciding its disclosure text.
    public var detail: String {
        switch self {
        case .dictate: return "It opens your voice overlay so you can speak an answer; the transcript goes back to the agent."
        case .history: return "It can read the text of your recent dictations and which apps they went to."
        case .refine:  return "It can send text to your configured AI model to rewrite it."
        case .sync:    return "It can read and merge your vocabulary, profiles, modes, packs, and dictation history with this paired device over your local network."
        case .transcribeFile: return "It can point OpenWhisp at an audio file on your Mac and get the transcript back. OpenWhisp only reads the file the agent names — this does not give the agent any new access to your files (it can already read what it points at)."
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
    /// Version-skewed `scopePolicies` entries this build can't interpret (unknown
    /// scope key, or unknown policy value from a newer build). Carried verbatim
    /// and re-encoded on save, so switching app versions never silently erases a
    /// decision the user made elsewhere — the quarantine idiom protects the FILE;
    /// this protects individual entries without nuking every client's consent.
    public var unknownScopeEntries: [String: String] = [:]
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
        // readable JSON object). Decode as [String: String] and bridge PER ENTRY:
        // an entry whose key or value this build can't interpret (a newer build's
        // scope or policy) is carried in `unknownScopeEntries` and re-encoded
        // verbatim — never dropped, and never allowed to throw (a throw here
        // would quarantine the WHOLE store, wiping every client's standing
        // denies over one version-skewed value).
        if let raw = try c.decodeIfPresent([String: String].self, forKey: .scopePolicies) {
            var typed: [AgentScope: AgentConsentPolicy] = [:]
            var unknown: [String: String] = [:]
            for (k, v) in raw {
                if let scope = AgentScope(rawValue: k), let policy = AgentConsentPolicy(rawValue: v) {
                    typed[scope] = policy
                } else {
                    unknown[k] = v
                }
            }
            self.scopePolicies = typed
            self.unknownScopeEntries = unknown
        } else if let legacy = try c.decodeIfPresent(AgentConsentPolicy.self, forKey: .policy) {
            // MIGRATION: a v1 record carried a single `policy` covering everything
            // THAT EXISTED AT v1. Apply it to exactly those scopes — never to
            // `allCases` — so a scope added later (e.g. `sync`) has no decision
            // recorded and prompts on first use. Mapping onto allCases would
            // silently widen every legacy "always allow" into a standing grant
            // for capabilities the user never saw a prompt for (with `sync`,
            // that's full-fidelity history to any old always-allowed client).
            self.scopePolicies = Dictionary(
                uniqueKeysWithValues: AgentScope.legacyV1Scopes.map { ($0, legacy) })
        } else {
            self.scopePolicies = [:]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientName, forKey: .clientName)
        // Scopes keyed by raw string (readable object), with any version-skewed
        // entries merged back verbatim so they survive a round trip.
        var raw = Dictionary(uniqueKeysWithValues: scopePolicies.map { ($0.key.rawValue, $0.value.rawValue) })
        raw.merge(unknownScopeEntries) { ours, _ in ours }
        try c.encode(raw, forKey: .scopePolicies)
        // Rollback bridge: when the record is still expressible in the v1 shape
        // (one policy uniformly covering every scope, nothing unknown), also write
        // the legacy `policy` key — a downgraded build then decodes this record
        // instead of quarantining the store. Never written for a heterogeneous
        // record: v1 would apply one scope's policy to all of them (widening).
        if unknownScopeEntries.isEmpty,
           Set(scopePolicies.keys) == Set(AgentScope.allCases),
           let uniform = scopePolicies.values.first,
           scopePolicies.values.allSatisfy({ $0 == uniform }) {
            try c.encode(uniform, forKey: .policy)
        }
        try c.encode(firstSeen, forKey: .firstSeen)
        try c.encodeIfPresent(lastCall, forKey: .lastCall)
        try c.encodeIfPresent(lastTool, forKey: .lastTool)
        try c.encodeIfPresent(signingID, forKey: .signingID)
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
            records[i].scopePolicies = records[i].scopePolicies
                .mapValues { $0 == .whileRunning ? .askEveryTime : $0 }
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
        JSONStore.load(from: fileURL, default: AgentClientStore(), label: "AgentClientStore") {
            var store = $0
            store.demoteRunScopedGrants()
            return store
        }
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        JSONStore.save(self, to: Self.fileURL, label: "AgentClientStore", encoder: encoder)
    }
}
