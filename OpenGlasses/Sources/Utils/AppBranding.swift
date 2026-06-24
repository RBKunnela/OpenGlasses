import Foundation

/// iMetaClaw product branding — shared across views, prompts, and onboarding.
enum AppBranding {
    static let name = "iMetaClaw"
    static let tagline = "Óculos inteligentes para seu agente OpenClaw"
    static let taglineEN = "Smart glasses for your OpenClaw agent"
    static let defaultAgentName = "Maia"

    /// Brazilian wake phrase: "Oi {agentName}" (e.g. "Oi Maia").
    static func wakePhrase(for agentName: String) -> String {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "oi \(defaultAgentName.lowercased())" }
        return "oi \(trimmed.lowercased())"
    }

    /// Spoken preview for UI, title-cased agent name.
    static func wakePhraseDisplay(for agentName: String) -> String {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Oi \(defaultAgentName)" }
        return "Oi \(trimmed)"
    }
}