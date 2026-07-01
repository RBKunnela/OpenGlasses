import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How the iPhone powers light AI vs heavy work (OpenClaw VPS / cloud).
enum PhoneAIStrategy: String, CaseIterable, Codable, Identifiable {
    /// Local small model on phone + OpenClaw agent on VPS (recommended for iMetaClaw).
    case hybridVPSLocal
    /// VPS only — phone uses Apple Intelligence or minimal routing when available.
    case vpsOnly
    /// Local model + optional cloud API on phone (no VPS).
    case hybridLocalCloud
    /// Cloud API on phone only (traditional).
    case cloudOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybridVPSLocal: return "Híbrido — local + VPS"
        case .vpsOnly: return "Só VPS (OpenClaw)"
        case .hybridLocalCloud: return "Híbrido — local + nuvem"
        case .cloudOnly: return "Só nuvem (API)"
        }
    }

    var icon: String {
        switch self {
        case .hybridVPSLocal: return "iphone.and.arrow.forward"
        case .vpsOnly: return "server.rack"
        case .hybridLocalCloud: return "cpu"
        case .cloudOnly: return "cloud"
        }
    }

    /// iPhone is a terminal — no local/cloud LLM answers; intelligence only via OpenClaw gateway.
    var isOpenClawExclusive: Bool {
        switch self {
        case .hybridVPSLocal, .vpsOnly: return true
        case .hybridLocalCloud, .cloudOnly: return false
        }
    }

    func subtitle(agentName: String) -> String {
        switch self {
        case .hybridVPSLocal:
            return "Só \(agentName) no VPS responde (como no Telegram). O iPhone não usa Qwen nem API na nuvem — se o gateway falhar, a voz para."
        case .vpsOnly:
            return "Só \(agentName) no VPS. O iPhone é terminal (mic + óculos). Sem fallback local ou nuvem."
        case .hybridLocalCloud:
            return "Modelo local para comandos rápidos; API na nuvem para tarefas complexas."
        case .cloudOnly:
            return "API direta no iPhone (Anthropic, Grok, etc.) — sem VPS."
        }
    }

    var needsGatewaySetup: Bool {
        switch self {
        case .hybridVPSLocal, .vpsOnly, .hybridLocalCloud: return true
        case .cloudOnly: return false
        }
    }

    var needsLocalModelSetup: Bool {
        switch self {
        case .hybridVPSLocal, .hybridLocalCloud: return true
        case .vpsOnly, .cloudOnly: return false
        }
    }

    var needsCloudSetup: Bool {
        switch self {
        case .cloudOnly, .hybridLocalCloud: return true
        case .hybridVPSLocal, .vpsOnly: return false
        }
    }
}

/// On-device hardware assessment for onboarding recommendations.
struct DeviceAICapability {
    enum DeviceTier: String {
        case low       // < 4 GB RAM
        case medium    // 4–7 GB
        case high      // 8+ GB
    }

    let ramGB: Double
    let tier: DeviceTier
    let canDownloadMLX: Bool
    let canUseAppleIntelligence: Bool
    let recommendedStrategy: PhoneAIStrategy
    let suggestedLocalModels: [RecommendedModel]

    static func assess() -> DeviceAICapability {
        let ram = LocalLLMService.deviceRAMGB
        let tier: DeviceTier
        if ram < 4 { tier = .low }
        else if ram < 8 { tier = .medium }
        else { tier = .high }

        let canMLX = ram >= 4
        let canApple = appleIntelligenceAvailable()

        let models = LocalLLMService.recommendedModels.filter(\.isCompatibleWithDevice)
        let tierFiltered = models.filter { model in
            switch tier {
            case .high: return true
            case .medium: return model.minimumRAMGB <= 6
            case .low: return model.minimumRAMGB <= 4
            }
        }
        let suggested = tierFiltered
            .sorted { $0.minimumRAMGB > $1.minimumRAMGB }
            .prefix(4)
            .map { $0 }

        // ClawGlasses / Maia: phone is a terminal — OpenClaw on the VPS is the only brain.
        let strategy: PhoneAIStrategy = .vpsOnly

        return DeviceAICapability(
            ramGB: ram,
            tier: tier,
            canDownloadMLX: canMLX,
            canUseAppleIntelligence: canApple,
            recommendedStrategy: strategy,
            suggestedLocalModels: suggested
        )
    }

    private static func appleIntelligenceAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    var tierLabel: String {
        switch tier {
        case .low: return "Limitado"
        case .medium: return "Bom"
        case .high: return "Forte"
        }
    }

    var summaryLines: [String] {
        var lines: [String] = [
            String(format: "RAM: %.1f GB (%@)", ramGB, tierLabel),
        ]
        if canDownloadMLX {
            lines.append("Pode baixar modelos MLX gratuitos no iPhone")
        } else {
            lines.append("Modelos MLX grandes não recomendados neste aparelho")
        }
        if canUseAppleIntelligence {
            lines.append("Apple Intelligence disponível")
        }
        lines.append("OpenClaw no VPS: transcrições longas, gravações e agente completo")
        return lines
    }
}