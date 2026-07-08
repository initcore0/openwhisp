import SwiftUI
import Cocoa

/// Agent Bridge: expose OpenWhisp as a local MCP server / CLI to coding agents
/// (Claude Code, Cursor, Hermes, OpenClaw). Default-off; when on, a local
/// UNIX-domain socket lets approved, code-signed clients dictate on your behalf,
/// refine text with your on-device LLM, and read your dictation history —
/// everything staying on this Mac.
struct AgentBridgePane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            enableSection
            if appState.agentBridgeEnabled {
                setupSection
                if !appState.agentBridgeAllowCloudAI && appState.llmProvider == "openai" {
                    cloudWarningSection
                }
                behaviorSection
                securitySection
                clientsSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Enable

    private var enableSection: some View {
        Section {
            SubtitledToggle(
                "Enable Agent Bridge",
                subtitle: "Let approved coding agents on this Mac dictate, refine text with your on-device AI, and read your dictation history. Off by default — nothing listens until you turn it on.",
                isOn: $appState.agentBridgeEnabled
            )
        } header: {
            Text("Agent Bridge")
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            Text("Register OpenWhisp with an agent by running its setup, then let the agent connect. The bundled `openwhisp` command lives inside the app.")
                .font(.callout)
                .foregroundColor(.secondary)

            HStack {
                Text("Command-line tool")
                Spacer()
                Button("Copy install command") {
                    copyToClipboard("sudo ln -sf \"\(cliPath)\" /usr/local/bin/openwhisp")
                }
            }
            HStack {
                Text("Claude Code")
                Spacer()
                Button("Copy `claude mcp add`") {
                    copyToClipboard("claude mcp add openwhisp -- \"\(cliPath)\" mcp")
                }
            }
        } header: {
            Text("Setup")
        } footer: {
            SettingsFootnote("Or run `openwhisp setup <agent>` for per-agent registration steps (claude-code, cursor, hermes, openclaw). See docs/AGENT_BRIDGE.md.")
        }
    }

    private var cloudWarningSection: some View {
        Section {
            SettingsCallout(
                .warning,
                "Your AI provider is OpenAI (cloud). Agent-initiated AI refinement is blocked so an agent can't send text off your Mac. Turn on \"Allow agents to use cloud AI\" below to permit it, or switch to a local provider in Cleanup."
            )
        }
    }

    // MARK: Behavior

    private var behaviorSection: some View {
        Section {
            SubtitledToggle(
                "Stop listening on silence",
                subtitle: "End an agent-requested dictation automatically once you stop talking, instead of waiting for the time limit. Only applies to agent requests — your own dictation hotkey is unaffected.",
                isOn: $appState.agentBridgeSilenceAutoStop
            )
            SubtitledToggle(
                "Chime when an agent asks",
                subtitle: "Play a short sound when an agent opens a dictation, so you notice it even when you're not looking at the overlay.",
                isOn: $appState.agentBridgeChimeEnabled
            )
            SubtitledToggle(
                "Read the question aloud",
                subtitle: "Speak the agent's question using your Mac's built-in voice (nothing leaves the device), so you can answer without reading the overlay. Long questions are shortened to the first sentence.",
                isOn: $appState.agentBridgeSpeakQuestionEnabled
            )
        } header: {
            Text("Behavior")
        }
    }

    // MARK: Security

    private var securitySection: some View {
        Section {
            SubtitledToggle(
                "Allow agents to use cloud AI",
                subtitle: "Permit agent-initiated refinement to use the OpenAI provider. Off by default — this is the one path by which an agent could send your text off the device.",
                isOn: $appState.agentBridgeAllowCloudAI
            )
            SubtitledToggle(
                "Allow unsigned / third-party clients",
                subtitle: "By default only OpenWhisp's own code-signed CLI and adapter may connect. Enable this to write your own client. Same-user only.",
                isOn: $appState.agentBridgeAllowUnsignedClients
            )
        } header: {
            Text("Security")
        }
    }

    // MARK: Clients

    @ViewBuilder
    private var clientsSection: some View {
        Section {
            if appState.agentClients.records.isEmpty {
                Text("No agents have connected yet.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(appState.agentClients.records, id: \.clientName) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.clientName).font(.body)
                                if let last = lastCallSuffix(record) {
                                    Text(last).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button("Revoke") { appState.revokeAgentClient(record.clientName) }
                                .foregroundColor(.red)
                        }
                        // Per-scope posture: each capability is granted separately.
                        HStack(spacing: 6) {
                            ForEach(AgentScope.allCases, id: \.self) { scope in
                                scopeChip(scope.noun, record.policy(for: scope))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Connected agents")
        } footer: {
            SettingsFootnote("Each capability is granted separately — approving an agent to ask you a question doesn't let it read your history or use your AI. Revoke clears all of them. Even an always-allowed agent is rate-limited so it can't hold the mic continuously.")
        }
    }

    /// A compact per-scope status chip. A nil policy means the scope hasn't been
    /// decided yet (the agent will be prompted on first use).
    private func scopeChip(_ label: String, _ policy: AgentConsentPolicy?) -> some View {
        let (text, color): (String, Color) = {
            switch policy {
            case .always:       return ("✓ always", .green)
            case .whileRunning: return ("✓ this run", .green)
            case .askEveryTime: return ("asks", .secondary)
            case .denied:       return ("✗ denied", .red)
            case nil:           return ("—", .secondary)
            }
        }()
        return Text("\(label): \(text)")
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: Helpers

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/openwhisp").path
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    /// "Last: 3 min ago · dictate", or nil if the client has never made a call.
    private func lastCallSuffix(_ record: AgentClientRecord) -> String? {
        guard let last = record.lastCall else { return nil }
        let tool = record.lastTool.map { " · \($0)" } ?? ""
        return "Last: \(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))\(tool)"
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
