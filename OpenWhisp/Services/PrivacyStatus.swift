import Foundation

/// Pure decision for the "where does my text go" privacy indicator, so it can be
/// unit-tested independently of the SwiftUI/AppState layer.
///
/// Transcription is always on-device. The only way dictated text leaves the
/// machine is AI post-processing with the cloud (OpenAI) provider; the local
/// provider stays on machine/LAN. One-time model downloads are not dictated text
/// and are not considered here.
enum PrivacyStatus {
    /// True only when AI cleanup is on AND the provider is the cloud one.
    static func sendsTextToCloud(enhancementEnabled: Bool, provider: String) -> Bool {
        enhancementEnabled && provider == "openai"
    }

    /// Short, user-facing statement for the current configuration.
    static func statusText(enhancementEnabled: Bool, provider: String) -> String {
        if sendsTextToCloud(enhancementEnabled: enhancementEnabled, provider: provider) {
            return "Sends final text to OpenAI for cleanup"
        }
        if enhancementEnabled && provider == "bundled" {
            return "Fully on-device — built-in AI, nothing leaves your Mac"
        }
        if enhancementEnabled && provider == "local" {
            return "On-device + your local LLM — nothing goes to the cloud"
        }
        if enhancementEnabled && provider == "agentCLI" {
            // The agent CLI makes its own connection with its own auth; where the
            // text goes depends on which CLI the user configured (a cloud coding
            // agent, or a fully local model), so we can't claim on-device.
            return "Refined by your local agent CLI, using its own connection"
        }
        return "Fully on-device — no network used"
    }
}
