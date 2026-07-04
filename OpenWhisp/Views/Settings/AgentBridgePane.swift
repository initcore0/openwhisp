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
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.clientName).font(.body)
                            Text(policyLabel(record.policy) + lastCallSuffix(record))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { appState.revokeAgentClient(record.clientName) }
                            .foregroundColor(.red)
                    }
                }
            }
        } header: {
            Text("Connected agents")
        }
    }

    // MARK: Helpers

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/openwhisp").path
    }

    private func policyLabel(_ policy: AgentConsentPolicy) -> String {
        switch policy {
        case .always: return "Always allowed"
        case .denied: return "Denied"
        case .askEveryTime: return "Asks every time"
        case .whileRunning: return "Allowed while running"
        }
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()

    private func lastCallSuffix(_ record: AgentClientRecord) -> String {
        guard let last = record.lastCall else { return "" }
        let tool = record.lastTool.map { " · \($0)" } ?? ""
        return " · \(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))\(tool)"
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
