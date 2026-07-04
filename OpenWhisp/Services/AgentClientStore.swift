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
public struct AgentClientRecord: Codable, Equatable, Sendable {
    public var clientName: String
    public var policy: AgentConsentPolicy
    public var firstSeen: Date
    public var lastCall: Date?
    public var lastTool: String?
    /// The verified signing identity at record time (Team ID / designated-
    /// requirement digest), for display and future identity-bound consent.
    public var signingID: String?

    public init(
        clientName: String, policy: AgentConsentPolicy, firstSeen: Date,
        lastCall: Date? = nil, lastTool: String? = nil, signingID: String? = nil
    ) {
        self.clientName = clientName
        self.policy = policy
        self.firstSeen = firstSeen
        self.lastCall = lastCall
        self.lastTool = lastTool
        self.signingID = signingID
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
            return try JSONDecoder().decode(AgentClientStore.self, from: data)
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
