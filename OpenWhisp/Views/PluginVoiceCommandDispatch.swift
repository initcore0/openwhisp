import AppKit

/// The app-side half of the v10 voice-command route: turn a `PluginVoiceCommandRouter`
/// match into an open plugin window seeded with the user's material.
///
/// Lives on `PluginHost` (not `AppState`) for the MAK-32 ratchet reason the host was
/// created for in the first place — AppState is at zero headroom, so the feature's
/// logic sits here and AppState keeps a single call. The DECISION (does this
/// instruction route, and to whom) is pure and already lives in
/// `PluginVoiceCommandRouter`; this file is only the side effect.
@MainActor
extension PluginHost {

    /// What the refine pipeline should do with an instruction, after consulting the
    /// plugins.
    enum VoiceCommandOutcome: Equatable {
        /// No plugin claimed it — run the NORMAL refine, byte-identical to v9.
        case notHandled
        /// A plugin took it. The refine LLM must not run and NOTHING may be inserted
        /// into the focused app: the plugin window is the output.
        /// `status` is the overlay acknowledgment.
        case handled(status: String)
        /// The command matched a plugin that is switched OFF. The instruction still
        /// runs as a normal refine; `hint` explains the missing window.
        case disabled(hint: String)

        /// The refine effect that ends a ROUTED session, or nil to keep refining.
        ///
        /// Reusing `RefineFlow.Effect.finishQuietly` rather than open-coding the
        /// teardown in AppState is deliberate twice over: it keeps the ratchet paid,
        /// and it means the routed path tears down through the exact sequence every
        /// other no-insert refine outcome already uses — one auditable place where a
        /// session ends without delivering text.
        var finishQuietlyEffect: RefineFlow.Effect? {
            guard case let .handled(status) = self else { return nil }
            return .finishQuietly(status: status)
        }

        /// A transient status line to show while STILL running the normal refine.
        var statusHint: String? {
            guard case let .disabled(hint) = self else { return nil }
            return hint
        }
    }

    /// Whether ANY enabled plugin declares voice triggers.
    ///
    /// The refine key uses this to decide whether a no-content tap is worth arming
    /// (CASE 2). Without a routable plugin there is genuinely nothing to do with an
    /// instruction that has no content, and arming would replace the honest "Nothing
    /// to refine yet" with a silent dead end — so a build with no such plugin keeps
    /// v9's behavior exactly.
    var armsWithoutContent: Bool {
        activePlugins.contains { !$0.manifest.normalizedVoiceTriggers.isEmpty }
    }

    /// The refine pipeline's single entry point.
    ///
    /// Consults the plugins and applies the only side effect that belongs to the
    /// CALLER's state — the disabled hint — returning the teardown effect when a
    /// plugin took the command, or nil to continue with a normal refine.
    ///
    /// Shaped this way so `AppState.deliverFinalText` carries one `if let`: the MAK-32
    /// ratchet is at zero headroom, and a feature that spends its budget on a switch
    /// statement in the god object is a feature that makes the next one harder.
    func routeVoiceCommand(
        instruction: String, content: String?, on appState: AppState
    ) -> RefineFlow.Effect? {
        let outcome = handleVoiceCommand(instruction: instruction, content: content)
        if let hint = outcome.statusHint { appState.statusMessage = hint }
        return outcome.finishQuietlyEffect
    }

    /// Offer a spoken refine instruction to the plugins.
    ///
    /// - Parameters:
    ///   - instruction: the spoken words (the trigger phrase plus any material).
    ///   - content: the refine CONTENT snapshot — the user's selection or prior
    ///     dictation. This is CASE 1's material: "create a meme based on that" carries
    ///     no description of its own, and `that` is the selection.
    /// - Returns: what the caller should do next.
    ///
    /// ## How the two flows converge
    ///
    /// Both end up calling the plugin with ONE string. The remainder (what the user
    /// said after the trigger) and the content (what they had selected) are joined
    /// when both exist, because they are both material: a user who selects a paragraph
    /// AND says "create a meme about the deadline" meant both to count. Remainder
    /// first — it is the more specific instruction.
    func handleVoiceCommand(instruction: String, content: String?) -> VoiceCommandOutcome {
        // Enabled AND runnable only: `activePlugins` is the same list the menu bar
        // and the window opener use, so a plugin the user switched off cannot claim a
        // dictation. This is the enablement gate (requirement 3).
        let enabled = activePlugins.map(\.manifest)
        guard let match = PluginVoiceCommandRouter.match(
            instruction: instruction, enabledPlugins: enabled)
        else {
            // Not claimed by an enabled plugin. Before falling through, check whether a
            // DISABLED one would have taken it — that, and only that, earns the hint.
            let all = discovered.map(\.manifest)
            if let offMatch = PluginVoiceCommandRouter.matchIgnoringEnablement(
                instruction: instruction, plugins: all),
               !isEnabled(offMatch.pluginID) {
                let name = all.first { $0.id == offMatch.pluginID }?.name ?? offMatch.pluginID
                MemeTrace.log("voice command matched but plugin disabled -> normal refine")
                return .disabled(hint: PluginVoiceCommandRouter.disabledHint(pluginName: name))
            }
            return .notHandled
        }

        let manifest = enabled.first { $0.id == match.pluginID }
        let name = manifest?.name ?? match.pluginID
        MemeTrace.log(
            "voice command MATCHED plugin=\(match.pluginID) trigger=\"\(match.trigger)\" "
            + "remainder=\"\(match.remainder)\" content=\(content?.count ?? 0) chars")

        // Material: what they said after the trigger, plus what they had selected.
        let selection = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let material = [match.remainder, selection]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // A SCRIPT plugin has no window and no command sink — its pipeline IS its
        // response, so it is dispatched here rather than through the window seams
        // below. Routed before the empty-material check because an empty input is a
        // legitimate run for a script plugin (a prompt with nothing to transform still
        // reaches the model), whereas for a window plugin it means "open and wait".
        if manifest?.entry == .script {
            runScriptPlugin(id: match.pluginID, material: material)
            MemeTrace.log(
                "voice command dispatched to SCRIPT plugin \(match.pluginID), "
                + "material=\(material.count) chars")
            return .handled(status: PluginVoiceCommandRouter.acknowledgment(pluginName: name))
        }

        guard !material.isEmpty else {
            // "create a meme" with nothing selected and nothing said after it. Opening
            // an empty window is still the right answer — the user asked for the meme
            // window — but say so rather than looking like a silent no-op.
            open(pluginID: match.pluginID)
            MemeTrace.log("voice command opened \(match.pluginID) with NO material")
            return .handled(status: "\(name) — say what the meme should be")
        }

        open(pluginID: match.pluginID)
        guard let sink = windowController(for: match.pluginID) as? PluginVoiceCommandSink else {
            // The window exists but doesn't take commands (or this build has no
            // plugins compiled in). Fail LOUDLY rather than eating the dictation: the
            // caller falls back to a normal refine, so the words are not lost.
            MemeTrace.log("voice command ABORTED: \(match.pluginID) has no command sink")
            return .notHandled
        }
        let context = invocationContext(for: manifest, material: material)
        sink.runVoiceCommand(context)
        MemeTrace.log(
            "voice command dispatched to \(match.pluginID), material=\"\(material)\", "
            + "clipboard=\(context.clipboard == nil ? "none" : "\(context.clipboard!.count) chars")")
        return .handled(status: PluginVoiceCommandRouter.acknowledgment(pluginName: name))
    }

    /// Build the invocation context for a plugin, reading the pasteboard ONLY if the
    /// manifest declared `clipboardAccess` (MAK-100).
    ///
    /// The read is guarded by `needsPasteboard` before it happens, so a plugin that
    /// never asked for the clipboard causes no `NSPasteboard` access at all — the gate
    /// is a real withholding, not a value discarded after the fact.
    ///
    /// A nil manifest (the plugin vanished between match and dispatch — possible, since
    /// discovery re-reads disk) is treated as declaring NOTHING. Failing closed is the
    /// only safe default for a capability check.
    func invocationContext(
        for manifest: PluginManifest?, material: String
    ) -> PluginInvocationContext {
        guard let manifest else { return PluginInvocationContext(material: material) }
        let pasteboard: String? = PluginInvocationContext.needsPasteboard(manifest)
            ? NSPasteboard.general.string(forType: .string)
            : nil
        return PluginInvocationContext.make(
            manifest: manifest, material: material, pasteboardString: pasteboard)
    }
}

/// A plugin window that can be driven by a spoken command.
///
/// The third plugin seam, alongside `PluginWindowLifecycle` and `PluginDictationSink`.
/// Distinct from the dictation sink on purpose: that one APPENDS text to whatever the
/// user is editing when the window is already key, whereas this one arrives from a
/// refine the user spoke into another app entirely, and means "start a new one from
/// this material."
@MainActor
protocol PluginVoiceCommandSink: AnyObject {
    /// Seed the plugin from `context` and run its primary action.
    ///
    /// Takes the whole `PluginInvocationContext` rather than a bare string so that
    /// adding a capability (clipboard today, more later) does not change this
    /// signature and every conforming plugin with it. The context is also the only
    /// way a plugin receives a declared capability — there is no second channel.
    func runVoiceCommand(_ context: PluginInvocationContext)
}
