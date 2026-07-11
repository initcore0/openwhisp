import Foundation

/// Pure, testable resolution of the **summarization** model for Meeting mode
/// (MAK-53), decoupled from the dictation-cleanup LLM.
///
/// Dictation cleanup favors a *tiny, fast* model (it runs on every final
/// transcript); a meeting summary runs only when you summarize and can afford a
/// *larger* model — e.g. a bigger local model behind your own server. So the
/// summarizer gets its own provider/model override, defaulting to "same as the
/// cleanup model" so existing installs behave exactly as before.
///
/// This type owns only the *decision*: given the override and the app's global
/// cleanup LLM settings, which provider / model / endpoint should the summarize
/// path use, and is that resolved provider local (privacy gate). It performs no
/// IO; the app coordinator threads the resolved values into the real LLM call.
///
/// Being Foundation-only it compiles into `OpenWhispCore` and is unit-tested.
public enum SummaryModelResolver {

    /// Sentinel `provider` value meaning "use whatever the dictation-cleanup LLM
    /// uses" — the default, so summaries follow the cleanup model unless the user
    /// deliberately picks a separate one.
    public static let sameAsCleanupID = "sameAsCleanup"

    /// The user's persisted summarization-model override.
    public struct Override: Equatable {
        /// Provider id: the `sameAsCleanupID` sentinel, or a real provider id
        /// (`bundled` / `local` / `openai` / `agentCLI`) mirroring `llmProvider`.
        public var provider: String
        /// Model name for the chosen provider. Empty means "the provider's
        /// default" (mirrors the cleanup convention: an empty model asks the
        /// provider/server for its own default).
        public var model: String
        /// Custom endpoint (server URL) — used ONLY when `provider == "local"`,
        /// mirroring the cleanup settings where only the self-hosted provider
        /// takes an editable endpoint. Ignored for every other provider (bundled
        /// loopback and OpenAI have fixed/derived endpoints).
        public var endpoint: String

        public init(provider: String = SummaryModelResolver.sameAsCleanupID,
                    model: String = "",
                    endpoint: String = "") {
            self.provider = provider
            self.model = model
            self.endpoint = endpoint
        }
    }

    /// The resolved summarization target the coordinator should call.
    public struct Resolved: Equatable {
        /// The provider id to call (never the sentinel — always a concrete id).
        public let provider: String
        /// The model to request (may be empty ⇒ provider default).
        public let model: String
        /// The custom endpoint for the resolved provider, when it takes one
        /// (only the `local` provider). Empty otherwise — the app derives the
        /// bundled loopback / OpenAI endpoint itself at call time.
        public let endpoint: String

        public init(provider: String, model: String, endpoint: String) {
            self.provider = provider
            self.model = model
            self.endpoint = endpoint
        }

        /// Whether the resolved provider keeps text on this machine (or the
        /// user's own LAN box). Reuses `ScreenContextGate.localRefineProviders`
        /// — the single source of truth — so summarize's privacy gate can never
        /// drift from the cleanup gate. `agentCLI` and `openai` are non-local.
        public var isLocal: Bool {
            ScreenContextGate.localRefineProviders.contains(provider)
        }
    }

    /// Resolve the summarization target.
    ///
    /// Rules:
    /// - **Sentinel** (`provider == sameAsCleanupID`): pass the cleanup globals
    ///   through verbatim — provider, model, and endpoint exactly as the
    ///   dictation-cleanup LLM uses them. Existing installs get today's behavior.
    /// - **Explicit provider**: use that provider. The override's `model` wins;
    ///   an empty override model falls back to the provider's default (which for
    ///   the SAME provider as cleanup means the cleanup model — otherwise empty,
    ///   letting the provider/server pick). The override's `endpoint` is used
    ///   only for the `local` provider; for any other provider the endpoint is
    ///   left empty so the app derives it (bundled loopback / OpenAI) at call time.
    ///
    /// - Parameters:
    ///   - override: the user's persisted summarization override.
    ///   - globalProvider: the cleanup `llmProvider` id.
    ///   - globalModel: the cleanup model (`llmModel`).
    ///   - globalEndpoint: the cleanup custom endpoint (the local server URL when
    ///     cleanup uses `local`; otherwise irrelevant/empty).
    public static func resolve(
        override: Override,
        globalProvider: String,
        globalModel: String,
        globalEndpoint: String
    ) -> Resolved {
        // Sentinel → cleanup globals verbatim.
        if override.provider == sameAsCleanupID {
            return Resolved(provider: globalProvider, model: globalModel, endpoint: globalEndpoint)
        }

        let provider = override.provider
        let trimmedModel = override.model.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty override model → provider default. When the override provider is
        // the SAME as cleanup, the sensible default is the cleanup model the user
        // already configured; otherwise empty (provider/server default).
        let model: String
        if !trimmedModel.isEmpty {
            model = trimmedModel
        } else if provider == globalProvider {
            model = globalModel
        } else {
            model = ""
        }

        // Endpoint only matters for the self-hosted `local` provider.
        let endpoint: String
        if provider == "local" {
            let trimmed = override.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            // Fall back to the cleanup endpoint when local is also the cleanup
            // provider and the override left the field blank.
            if !trimmed.isEmpty {
                endpoint = trimmed
            } else if globalProvider == "local" {
                endpoint = globalEndpoint
            } else {
                endpoint = ""
            }
        } else {
            endpoint = ""
        }

        return Resolved(provider: provider, model: model, endpoint: endpoint)
    }
}
