import Foundation

/// iMetaClaw product branding — shared across views, prompts, and onboarding.
enum AppBranding {
    static let name = "iMetaClaw"
    static let tagline = "Óculos inteligentes para seu agente OpenClaw"
    static let taglineEN = "Smart glasses for your OpenClaw agent"
    static let defaultAgentName = "Maia"
    /// Default OpenClaw gateway for Maia on Hostinger KVM2 (not Hermes on KVM4).
    static let defaultMaiaGatewayURL = "https://srv753644.hstgr.cloud"
    /// Asset catalog name for the in-app logo (template image).
    static let logoIconName = "iMetaClawLogo"

    static var appNotRunningMessage: String {
        "\(name) não está em execução. Abra o app primeiro."
    }

    static var appNotRunningMessageEN: String {
        "\(name) is not running. Open the app first."
    }

    static var appNotRunningLocalized: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: appNotRunningMessageEN)
    }

    static var appNotRunningShortLocalized: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: "\(name) is not running.")
    }

    static var aboutBlurb: String {
        "\(name) conecta seus óculos Ray-Ban Meta ao agente OpenClaw no seu VPS."
    }

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