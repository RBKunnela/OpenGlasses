import SwiftUI
import UIKit
import AVFoundation
import CoreLocation
import MWDATCore
import Speech

/// Full-screen onboarding flow — Apple HIG compliant.
///
/// Pages (iMetaClaw):
///   Welcome → Agent name → AI strategy (device detect) → VPS gateway → Local model
///   → Cloud provider (optional) → API key (optional) → Services → Permissions → Glasses → Ready
///
/// Design: dark background, system typography, white/monochrome highlights.
/// Follows Apple Generative AI HIG — discloses AI use, sets expectations,
/// communicates that responses may contain errors.
struct OnboardingView: View {
    @Binding var isVisible: Bool
    @EnvironmentObject var appState: AppState

    @State private var page = 0
    @State private var selectedProvider: LLMProvider?
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var keyValid = false
    @State private var availableModels: [ModelFetcher.RemoteModel] = []
    @State private var selectedModelId: String?

    // Optional service keys
    @State private var elevenLabsKey = ""
    @State private var perplexityKey = ""

    // iMetaClaw agent name (drives "Oi {name}" wake phrase)
    @State private var agentNameInput = Config.agentName

    // Device AI strategy (local / VPS / cloud)
    @State private var capability = DeviceAICapability.assess()
    @State private var selectedStrategy: PhoneAIStrategy = DeviceAICapability.assess().recommendedStrategy
    @State private var gatewayTunnelURL = ""
    @State private var gatewayToken = ""
    @State private var selectedLocalModelId = ""
    @State private var isDownloadingLocal = false
    @State private var localDownloadError: String?

    // Permissions state
    @State private var micGranted = false
    @State private var locationGranted = false
    @State private var bluetoothConfigured = false
    @State private var speechGranted = false
    // Connect glasses state (page 5)
    @State private var cameraGranted = false
    @State private var metaRegistered = false
    @State private var registrationStatus = ""
    @State private var isRegistering = false
    @State private var permissionInfoMessage: String?

    private let totalPages = 11

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    if page > 0 {
                        Button {
                            goToPreviousPage(from: page)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Voltar")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Voltar para a etapa anterior")
                    } else {
                        Color.clear
                            .frame(width: 72, height: 32)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Page indicator
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.white : Color.white.opacity(0.2))
                            .frame(width: i == page ? 24 : 8, height: 4)
                            .animation(.easeInOut(duration: 0.25), value: page)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
                .accessibilityElement()
                .accessibilityLabel("Page \(page + 1) of \(totalPages)")

                // Content — uses conditional views instead of paged TabView
                // so text fields on the API key page respond to taps immediately
                // (paged TabView's swipe gestures steal focus from text fields)
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: agentPage
                    case 2: aiStrategyPage
                    case 3: gatewayPage
                    case 4: localModelPage
                    case 5: providerPage
                    case 6: apiKeyPage
                    case 7: servicesPage
                    case 8: permissionsPage
                    case 9: connectGlassesPage
                    case 10: readyPage
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.3), value: page)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                LogoIcon(size: 80)
                    .foregroundStyle(.white)

                Text(AppBranding.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)

                Text(AppBranding.tagline)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            // AI transparency disclosure (Apple Generative AI HIG)
            VStack(alignment: .leading, spacing: 12) {
                featureRow(
                    icon: "brain.head.profile",
                    title: "Powered by AI",
                    detail: "Conversations are processed by the AI provider you choose. Responses are generated by AI and may not always be accurate."
                )
                featureRow(
                    icon: "lock.shield",
                    title: "Your keys, your data",
                    detail: "Your access key connects directly to your provider. We never see or store your conversations."
                )
                featureRow(
                    icon: "mic.badge.xmark",
                    title: "Microphone access",
                    detail: "Voice input is processed on-device for wake word detection and sent to your provider for transcription."
                )
            }
            .padding(.horizontal, 28)

            Spacer()

            primaryButton("Get Started") {
                withAnimation { page = 1 }
            }
            if !Config.simpleMode {
                skipButton()
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: - Page 2: Your Agent

    private var agentPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Seu agente")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Como se chama seu bot OpenClaw?")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nome do agente")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))

                    TextField("Maia", text: $agentNameInput)
                        .font(.title2.weight(.semibold))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.green)
                        Text("Você vai dizer: \"\(AppBranding.wakePhraseDisplay(for: agentNameInput))\"")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            primaryButton("Continuar") {
                Config.setAgentName(agentNameInput)
                Config.ensurePrimaryAgentPersona()
                if Config.simpleMode {
                    selectedStrategy = .vpsOnly
                    Config.setPhoneAIStrategy(.vpsOnly)
                }
                goToNextPage(from: 1)
            }
            .disabled(agentNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(agentNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Page 3: AI Strategy

    private var aiStrategyPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Como alimentar a IA")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("\(AppBranding.name) detectou seu iPhone e recomenda uma configuração.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(capability.summaryLines, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                    Text("Escolha uma opção")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 4)

                    ForEach(PhoneAIStrategy.allCases) { strategy in
                        strategyCard(strategy)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            primaryButton("Continuar") {
                Config.setPhoneAIStrategy(selectedStrategy)
                goToNextPage(from: 2)
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            capability = DeviceAICapability.assess()
            if !PhoneAIStrategy.allCases.contains(selectedStrategy) {
                selectedStrategy = capability.recommendedStrategy
            }
            if selectedLocalModelId.isEmpty {
                selectedLocalModelId = capability.suggestedLocalModels.first?.id
                    ?? LocalLLMService.preferredDefaultModelId
            }
        }
    }

    private func strategyCard(_ strategy: PhoneAIStrategy) -> some View {
        let selected = selectedStrategy == strategy
        let recommended = strategy == capability.recommendedStrategy

        return Button {
            selectedStrategy = strategy
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: strategy.icon)
                    .font(.title3)
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(strategy.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if recommended {
                            Text("Recomendado")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green, in: Capsule())
                        }
                    }
                    Text(strategy.subtitle(agentName: agentNameInput))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.white.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page 4: OpenClaw VPS Gateway

    private var gatewayPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Conectar \(agentNameInput)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Obrigatório para \(agentNameInput) no VPS — URL e token do OpenClaw (mesmo agente do Telegram).")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    gatewayFieldCard(
                        title: "URL do gateway",
                        hint: "Copie no Safari → toque em Colar (não use Autofill)."
                    ) {
                        PasteableURLInput(
                            text: $gatewayTunnelURL,
                            placeholder: AppBranding.defaultMaiaGatewayURL,
                            style: .darkOnboarding
                        )
                    }

                    gatewayFieldCard(
                        title: "Token",
                        hint: nil
                    ) {
                        PasteableSecretInput(
                            text: $gatewayToken,
                            placeholder: "Token do OpenClaw",
                            style: .darkOnboarding,
                            fieldKind: .token
                        )
                    }

                    Text("Use o VPS da Maia (KVM2), não o Hermes (KVM4 / aicontexteng.com). Token = gateway OpenClaw da Maia, não o do Telegram.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            onboardingActionFooter(
                primaryLabel: "Continuar",
                primaryAction: {
                    saveGatewayFromOnboarding()
                    goToNextPage(from: 3)
                },
                secondaryLabel: Config.simpleMode ? nil : "Configurar depois",
                secondaryAction: Config.simpleMode ? nil : { goToNextPage(from: 3) }
            )
            .padding(.top, 8)
            .background(Color.black.opacity(0.94))
            .disabled(Config.simpleMode && !gatewayCredentialsComplete)
            .opacity(Config.simpleMode && !gatewayCredentialsComplete ? 0.4 : 1)
        }
        .onAppear {
            if Config.simpleMode, gatewayTunnelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                gatewayTunnelURL = AppBranding.defaultMaiaGatewayURL
            }
        }
    }

    private var gatewayCredentialsComplete: Bool {
        !gatewayTunnelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func gatewayFieldCard<Content: View>(
        title: String,
        hint: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.5))

            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Page 5: Local Model

    private var localModelPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Modelo leve no iPhone")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Opcional — só para comandos rápidos no iPhone. \(agentNameInput) no VPS faz o trabalho pesado.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(capability.suggestedLocalModels, id: \.id) { model in
                        localModelCard(model)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            if isDownloadingLocal {
                VStack(spacing: 6) {
                    ProgressView(value: appState.localLLMService.downloadProgress)
                        .tint(.white)
                        .padding(.horizontal, 28)
                    Text("Baixando \(Int(appState.localLLMService.downloadProgress * 100))% — use Wi‑Fi, pode levar alguns minutos.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .padding(.bottom, 8)
            }
            if let localDownloadError {
                Text(localDownloadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 28)
            }

            VStack(spacing: 10) {
                primaryButton(selectedLocalModelId.isEmpty ? "Pular — só VPS" : "Baixar e continuar") {
                    saveLocalModelFromOnboarding()
                    startLocalDownloadIfNeeded()
                    goToNextPage(from: 4)
                }
                if capability.canUseAppleIntelligence {
                    Text("Ou use Apple Intelligence (já no iPhone) nas Configurações.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            if selectedLocalModelId.isEmpty {
                selectedLocalModelId = capability.suggestedLocalModels.first?.id
                    ?? LocalLLMService.preferredDefaultModelId
            }
        }
    }

    private func localModelCard(_ model: RecommendedModel) -> some View {
        let selected = selectedLocalModelId == model.id
        return Button {
            selectedLocalModelId = model.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("\(model.estimatedSize) · \(model.notes)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page 6: Choose Provider (cloud — optional)

    private var providerPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("API na nuvem (opcional)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Só se quiser IA extra no iPhone. \(agentNameInput) no VPS já cobre o agente completo.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)
            .padding(.horizontal, 28)

            ScrollView {
                VStack(spacing: 12) {
                    providerCard(
                        provider: .anthropic,
                        name: "Anthropic",
                        model: "Claude",
                        detail: "Best for reasoning and conversation",
                        icon: "brain"
                    )
                    providerCard(
                        provider: .gemini,
                        name: "Google",
                        model: "Gemini",
                        detail: "Free tier available, vision capable",
                        icon: "sparkles"
                    )
                    providerCard(
                        provider: .openai,
                        name: "OpenAI",
                        model: "GPT-4o",
                        detail: "Realtime voice mode available",
                        icon: "waveform"
                    )
                    providerCard(
                        provider: .groq,
                        name: "Groq",
                        model: "Llama / Mixtral",
                        detail: "Ultra-fast inference, free tier",
                        icon: "bolt"
                    )
                    providerCard(
                        provider: .nvidia,
                        name: "NVIDIA NIM",
                        model: "Llama / Nemotron",
                        detail: "Bring your NVIDIA API key",
                        icon: "cpu"
                    )
                    providerCard(
                        provider: .qwen,
                        name: "Qwen",
                        model: "Qwen3.5 Plus",
                        detail: "Vision capable, bring your own key",
                        icon: "globe.asia.australia"
                    )
                    providerCard(
                        provider: .zai,
                        name: "Z.ai",
                        model: "GLM-4.5",
                        detail: "Bring your own key",
                        icon: "bolt.circle"
                    )

                    // Collapsed section for other providers
                    DisclosureGroup {
                        VStack(spacing: 12) {
                            providerCard(
                                provider: .xai,
                                name: "xAI",
                                model: "Grok",
                                detail: "Grok from x.com — subscription or API key",
                                icon: "sparkle"
                            )
                            providerCard(
                                provider: .openrouter,
                                name: "OpenRouter",
                                model: "500+ models",
                                detail: "Access many providers through one key",
                                icon: "arrow.triangle.branch"
                            )
                            providerCard(
                                provider: .minimax,
                                name: "MiniMax",
                                model: "MiniMax-M2",
                                detail: "Bring your own subscription token",
                                icon: "waveform.path"
                            )
                        }
                    } label: {
                        Text("More providers")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .tint(.white.opacity(0.4))
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }

            if selectedProvider != nil {
                primaryButton("Continue") {
                    configureDefaults()
                    goToNextPage(from: 5)
                }
                .padding(.bottom, 8)
            }

            if selectedStrategy != .cloudOnly {
                Button("Pular — \(agentNameInput) no VPS basta") {
                    goToNextPage(from: 5)
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Page 7: Access Key

    private var apiKeyPage: some View {
        let provider = selectedProvider ?? .anthropic
        let needsKey = provider.requiresAPIKey

        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(needsKey ? "Add your access key" : "You're all set")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                if needsKey {
                    Text("Paste your \(provider.displayName) access key below")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 28)

            ScrollView {
                Group {
                if needsKey {
                VStack(spacing: 16) {
                    // Access Key input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Access Key")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.5))

                        PasteableSecretInput(
                            text: $apiKey,
                            placeholder: "sk-...",
                            style: .darkOnboarding,
                            onTextChange: {
                                validationError = nil
                                keyValid = false
                                availableModels = []
                                selectedModelId = nil
                            }
                        )
                        .padding(14)
                        .contentShape(Rectangle())
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    validationError != nil ? Color.red.opacity(0.6) :
                                    keyValid ? Color.green.opacity(0.6) :
                                    Color.white.opacity(0.1),
                                    lineWidth: 1
                                )
                        )

                        if let error = validationError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        if keyValid {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(availableModels.isEmpty ? "Key valid" : "Key valid — \(availableModels.count) models available")
                                    .foregroundStyle(.green.opacity(0.8))
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal, 28)

                    // "Get API Key" deep link
                    if apiKey.isEmpty, let url = provider.consoleURL {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.right.square")
                                Text("Get your API key from \(url.host ?? provider.displayName)")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 28)
                    }

                    // Model picker (shown after successful validation)
                    if keyValid && !availableModels.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Select Model")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.5))

                            ScrollView {
                                VStack(spacing: 6) {
                                    ForEach(availableModels) { model in
                                        Button {
                                            selectedModelId = model.id
                                        } label: {
                                            HStack {
                                                Text(model.name)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                Spacer()
                                                if selectedModelId == model.id {
                                                    Image(systemName: "checkmark")
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(selectedModelId == model.id
                                                          ? Color.white.opacity(0.1)
                                                          : Color.white.opacity(0.05))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                        .padding(.horizontal, 28)
                    }

                    // Link to get a key
                    Button {
                        openAPIKeyURL(for: provider)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                            Text(apiKeyURLLabel(for: provider))
                                .font(.subheadline)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }
            } else {
                // Subscription providers — no key needed
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.green)
                    Text("\(provider.displayName) doesn't require an access key.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                }
                }
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            if needsKey {
                if keyValid {
                    primaryButton("Continue") {
                        saveModel()
                        goToNextPage(from: 6)
                    }
                } else {
                    primaryButton(isValidating ? "Validating..." : "Validate Key") {
                        validateKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                }

                Button {
                    if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                        saveModel()
                    }
                    goToNextPage(from: 6)
                } label: {
                    Text(keyValid ? "Skip model selection" : "Adicionar depois")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 4)
                .padding(.bottom, 20)
            } else {
                primaryButton("Continue") {
                    saveModel()
                    goToNextPage(from: 6)
                }
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Page 4: Services (Optional)

    private var servicesPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Voz e busca (opcional)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Pode pular tudo — \(agentNameInput) no VPS já responde. O iPhone só fala a resposta com a voz do sistema.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(.top, 8)
            .padding(.horizontal, 28)

            ScrollView {
            VStack(spacing: 20) {
                // ElevenLabs
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 24)
                        Text("ElevenLabs Voice")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }

                    PasteableSecretInput(text: $elevenLabsKey, placeholder: "ElevenLabs API Key", style: .darkOnboarding)
                        .padding(14)
                        .contentShape(Rectangle())
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(elevenLabsKey.isEmpty ? Color.white.opacity(0.1) : Color.green.opacity(0.6), lineWidth: 1)
                        )

                    if elevenLabsKey.isEmpty {
                        Link(destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                                Text("Get key from elevenlabs.io")
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        }
                    }

                    Text("Voz mais natural na saída de áudio do iPhone. Sem chave: a voz padrão do iOS fala as respostas de \(agentNameInput) nos óculos.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                }

                // Perplexity
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 24)
                        Text("Perplexity Search")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }

                    PasteableSecretInput(text: $perplexityKey, placeholder: "Perplexity API Key", style: .darkOnboarding)
                        .padding(14)
                        .contentShape(Rectangle())
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(perplexityKey.isEmpty ? Color.white.opacity(0.1) : Color.green.opacity(0.6), lineWidth: 1)
                        )

                    if perplexityKey.isEmpty {
                        Link(destination: URL(string: "https://www.perplexity.ai/settings/api")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                                Text("Get key from perplexity.ai")
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        }
                    }

                    Text("Busca na web pelo app no iPhone. Sem chave: DuckDuckGo (básico). \(agentNameInput) no VPS pode buscar na internet pelas ferramentas do OpenClaw.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                }

                // iOS Voice tip
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 24)
                        Text("Voz do iPhone (padrão)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }

                    if hasPremiumVoiceInstalled {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Voz premium do iOS detectada — será usada para falar")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .font(.caption)
                    } else {
                        Text("É assim que você ouve \(agentNameInput): voz do sistema iOS → alto-falante dos óculos. Opcional: Ajustes → Acessibilidade → Conteúdo Falado → Vozes.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            primaryButton("Continuar") {
                if !elevenLabsKey.isEmpty {
                    Config.setElevenLabsAPIKey(elevenLabsKey)
                }
                if !perplexityKey.isEmpty {
                    Config.setPerplexityAPIKey(perplexityKey)
                }
                goToNextPage(from: 7)
            }
            .padding(.bottom, 4)

            Button("Pular — usar voz do iPhone") {
                goToNextPage(from: 7)
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.bottom, 8)
        }
    }

    /// Check if any enhanced/premium quality voice is installed.
    private var hasPremiumVoiceInstalled: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { voice in
            voice.quality == .enhanced || voice.quality == .premium
        }
    }

    // MARK: - Page 5: Permissions

    private var requiredPermissionsGrantedCount: Int {
        [micGranted, speechGranted, bluetoothConfigured].filter { $0 }.count
    }

    private var permissionsPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Permissões")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Toque em Permitir em cada item. Microfone e fala são necessários para continuar.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(.top, 8)
            .padding(.horizontal, 28)

            permissionsProgressBanner
                .padding(.horizontal, 20)
                .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    permissionSectionHeader("Necessárias para o app")

                    VStack(spacing: 12) {
                        permissionRow(
                            icon: "mic.fill",
                            title: "Microfone",
                            detail: "Para ouvir \"\(AppBranding.wakePhraseDisplay(for: agentNameInput))\" e seus comandos de voz.",
                            info: "Sem microfone o app não ouve você. Usa o microfone do iPhone ou dos óculos.",
                            granted: micGranted
                        ) {
                            await requestMicPermission()
                        }

                        permissionRow(
                            icon: "waveform",
                            title: "Reconhecimento de fala",
                            detail: "Converte sua voz em texto no iPhone.",
                            info: "Usa o motor de ditado da Apple no aparelho.",
                            granted: speechGranted
                        ) {
                            await requestSpeechPermission()
                        }

                        permissionRow(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "Bluetooth",
                            detail: "Conecta áudio e câmera dos óculos Ray-Ban Meta.",
                            info: "Não troca \(agentNameInput) pela IA da Meta — é só conexão com o hardware.",
                            granted: bluetoothConfigured
                        ) {
                            configureWearablesSDK()
                        }
                    }

                    permissionSectionHeader("Opcional")

                    permissionRow(
                        icon: "location.fill",
                        title: "Localização",
                        detail: "Para clima e lugares próximos, só quando você pedir.",
                        info: "Pode pular — o app funciona sem isso.",
                        granted: locationGranted
                    ) {
                        requestLocationPermission()
                    }

                    upcomingMetaGlassesNote
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            primaryButton("Continuar") {
                goToNextPage(from: 8)
            }
            .opacity(micGranted && speechGranted ? 1 : 0.4)
            .disabled(!micGranted || !speechGranted)
            .padding(.bottom, 4)

            if !micGranted || !speechGranted {
                Text("Conceda microfone e reconhecimento de fala para continuar")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }
        }
        .alert("Detalhes da permissão", isPresented: Binding(
            get: { permissionInfoMessage != nil },
            set: { if !$0 { permissionInfoMessage = nil } }
        )) {
            Button("OK", role: .cancel) { permissionInfoMessage = nil }
        } message: {
            Text(permissionInfoMessage ?? "")
        }
        .onAppear { checkExistingPermissions() }
    }

    private var permissionsProgressBanner: some View {
        let total = 3
        let done = requiredPermissionsGrantedCount
        let complete = done == total

        return HStack(spacing: 12) {
            Image(systemName: complete ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.title3)
                .foregroundStyle(complete ? .green : .white.opacity(0.7))

            VStack(alignment: .leading, spacing: 4) {
                Text(complete ? "Tudo pronto" : "\(done) de \(total) necessárias concedidas")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(complete ? "Você pode continuar." : "Conceda microfone, fala e Bluetooth.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(complete ? Color.green.opacity(0.35) : Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func permissionSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.45))
            .tracking(0.6)
            .padding(.leading, 4)
    }

    /// Meta AI authorization is a separate onboarding step — not an iOS permission dialog.
    private var upcomingMetaGlassesNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eyeglasses")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("Próximo passo: óculos Meta")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Na tela seguinte (Conectar óculos) você aprova o \(AppBranding.name) no app Meta AI e concede a câmera dos óculos. Bluetooth aqui só prepara a conexão — ainda não autoriza a Meta.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        info: String? = nil,
        granted: Bool,
        statusMessage: String? = nil,
        isLoading: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(granted ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                        .frame(width: 48, height: 48)

                    Group {
                        if icon == AppBranding.logoIconName {
                            LogoIcon(size: 24)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 22, weight: .medium))
                        }
                    }
                    .foregroundStyle(granted ? .green : .white.opacity(0.85))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)

                        Spacer(minLength: 8)

                        if granted {
                            Label("OK", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        }
                    }

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)

                    if let info {
                        Button {
                            permissionInfoMessage = info
                        } label: {
                            Text("Saiba mais")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Saiba mais sobre \(title)")
                    }
                }
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.85)
                        .tint(.white)
                    Text(statusMessage ?? "Aguarde…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else if let statusMessage, !granted {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !granted {
                Button {
                    Task { await action() }
                } label: {
                    Text("Permitir")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(granted ? Color.green.opacity(0.35) : Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func checkExistingPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        let locStatus = CLLocationManager().authorizationStatus
        locationGranted = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    private func requestMicPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        micGranted = granted
    }

    private func requestSpeechPermission() async {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        speechGranted = status == .authorized
    }

    private func requestLocationPermission() {
        appState.locationService.startTracking()
        // Give time for the dialog to show and user to respond
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let status = CLLocationManager().authorizationStatus
            locationGranted = status == .authorizedWhenInUse || status == .authorizedAlways
        }
    }

    private func configureWearablesSDK() {
        guard !bluetoothConfigured else { return }
        do {
            try WearablesBootstrap.ensureConfigured()
            bluetoothConfigured = true
            NSLog("[Onboarding] Wearables SDK configured")
        } catch {
            let message = WearablesBootstrap.userFacingMessage(for: error)
            NSLog("[Onboarding] Wearables.configure() failed: %@", message.isEmpty ? error.localizedDescription : message)
            // Still mark as configured to avoid retry loop — user can reconnect in Settings
            bluetoothConfigured = true
        }
    }

    // MARK: - Page 6: Connect Glasses

    private var connectGlassesPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Conectar óculos")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Obrigatório para óculos Ray-Ban Meta. Não troca \(agentNameInput) pela IA da Meta.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(.top, 8)
            .padding(.horizontal, 28)

            if !bluetoothConfigured {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Volte à página Permissões e toque em Bluetooth (obrigatório).")
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.9))
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
            }

            ScrollView {
            VStack(spacing: 12) {
                permissionRow(
                    icon: "camera.fill",
                    title: "Câmera",
                    detail: "Para fotos e vídeo dos óculos que \(agentNameInput) analisa.",
                    info: "A análise é feita pelo seu modelo local ou pelo VPS.",
                    granted: cameraGranted
                ) {
                    await requestCameraPermission()
                }

                permissionRow(
                    icon: "iMetaClawLogo",
                    title: "Autorizar no Meta AI",
                    detail: "Aprove \(AppBranding.name) no app Meta AI com os óculos já pareados.",
                    info: "1) Pareados no Meta AI 2) Modo Desenvolvedor (Sobre → 5× na versão) 3) Toque Permitir 4) Aprove no Meta AI 5) Volte e toque de novo.",
                    granted: metaRegistered,
                    statusMessage: isRegistering
                        ? (registrationStatus.isEmpty ? "Registrando com Meta AI…" : registrationStatus)
                        : (metaRegistered ? nil : (registrationStatus.isEmpty ? nil : registrationStatus)),
                    isLoading: isRegistering
                ) {
                    await connectToMetaAI()
                }

                if !metaRegistered {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Como autorizar a Meta")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("1. Meta AI → óculos já pareados\n2. Meta AI → Ajustes → Sobre → toque 5× na versão → ative Modo Desenvolvedor\n3. Toque Permitir acima → aprove o iMetaClaw no Meta AI\n4. Volte ao iMetaClaw e toque Permitir de novo")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            }

            primaryButton(metaRegistered ? "Continuar" : "Continuar sem óculos") {
                goToNextPage(from: 9)
            }
            .padding(.bottom, 4)

            Button {
                goToNextPage(from: 9)
            } label: {
                Text("Pular — usar só o iPhone por agora")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .alert("Detalhes da permissão", isPresented: Binding(
            get: { permissionInfoMessage != nil },
            set: { if !$0 { permissionInfoMessage = nil } }
        )) {
            Button("OK", role: .cancel) { permissionInfoMessage = nil }
        } message: {
            Text(permissionInfoMessage ?? "")
        }
        .onAppear {
            cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            metaRegistered = bluetoothConfigured && Wearables.shared.registrationState.rawValue >= 3
        }
    }

    private func requestCameraPermission() async {
        cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
    }

    private func connectToMetaAI() async {
        guard bluetoothConfigured else {
            registrationStatus = "Conceda Bluetooth na página anterior (Permissões), depois toque aqui de novo."
            return
        }
        isRegistering = true
        registrationStatus = "Abrindo Meta AI para autorização…"

        let result = await appState.performMetaRegistrationFlow()
        metaRegistered = result.registered
        registrationStatus = result.message
        isRegistering = false
    }

    // MARK: - Page 7: Ready

    private var readyPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.green)
                        .padding(.top, 8)

                    Text("Tudo pronto")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)

                    Text("Diga \"\(AppBranding.wakePhraseDisplay(for: Config.agentName))\" ou toque no microfone para começar.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Text(onboardingReadySummary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if isDownloadingLocal {
                        HStack(spacing: 8) {
                            ProgressView(value: appState.localLLMService.downloadProgress)
                                .tint(.white)
                                .frame(width: 80)
                            Text("Modelo local: \(Int(appState.localLLMService.downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    if let localDownloadError {
                        Text("Download do modelo: \(localDownloadError)")
                            .font(.caption)
                            .foregroundStyle(.orange.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    if !metaRegistered && bluetoothConfigured {
                        Text("Óculos: ainda não autorizados — você pode conectar depois na aba Voz.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        tipRow(icon: "mic.fill", text: "Fale naturalmente — \(Config.agentName) responde pela voz dos óculos")
                        tipRow(icon: "camera.fill", text: "Mostre algo à câmera para o agente analisar")
                        tipRow(icon: "server.rack", text: "Tarefas pesadas vão para o OpenClaw no VPS")
                        tipRow(icon: "gearshape", text: "Ajustes → Gateways para URL/token do agente")
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)

                    Text("Respostas de IA podem conter erros. Confira informações importantes.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.vertical, 16)
            }

            primaryButton("Começar com \(AppBranding.name)") {
                completeOnboarding()
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Components

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 32, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func providerCard(
        provider: LLMProvider,
        name: String,
        model: String,
        detail: String,
        icon: String
    ) -> some View {
        let selected = selectedProvider == provider

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedProvider = provider
                modelName = model
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        selected ? Color.white.opacity(0.3) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) — \(detail)")
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: 340)
                .padding(.vertical, 16)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
    }

    private func onboardingActionFooter(
        primaryLabel: String,
        primaryAction: @escaping () -> Void,
        secondaryLabel: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            primaryButton(primaryLabel, action: primaryAction)

            if let secondaryLabel, let secondaryAction {
                Button(secondaryLabel, action: secondaryAction)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.bottom, 20)
    }

    private func skipButton() -> some View {
        Button {
            completeOnboarding()
        } label: {
            Text("Skip setup")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var onboardingReadySummary: String {
        switch selectedStrategy {
        case .hybridVPSLocal:
            return "Leve no iPhone + \(agentNameInput) no VPS para tarefas pesadas."
        case .vpsOnly:
            return "\(agentNameInput) no VPS faz o trabalho de IA."
        case .hybridLocalCloud:
            return "Modelo local + nuvem opcional no iPhone."
        case .cloudOnly:
            return "IA via API na nuvem no iPhone."
        }
    }

    // MARK: - Logic

    private func configureDefaults() {
        guard let provider = selectedProvider else { return }
        modelName = provider.defaultModel
    }

    private func validateKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let provider = selectedProvider else { return }

        // Basic format validation
        if provider == .anthropic && !trimmed.hasPrefix("sk-ant-") {
            validationError = "Anthropic keys start with sk-ant-"
            return
        }
        if provider == .openai && !trimmed.hasPrefix("sk-") {
            validationError = "OpenAI keys start with sk-"
            return
        }

        isValidating = true
        validationError = nil

        Task {
            let models = await ModelFetcher.fetchModels(
                provider: provider,
                apiKey: trimmed,
                baseURL: provider.defaultBaseURL
            )

            await MainActor.run {
                isValidating = false
                if models.isEmpty {
                    // Key may still be valid even if model listing fails — accept it
                    keyValid = true
                    availableModels = []
                    selectedModelId = provider.defaultModel
                } else {
                    keyValid = true
                    availableModels = models
                    // Pre-select the provider's default model if it's in the list
                    if models.contains(where: { $0.id == provider.defaultModel }) {
                        selectedModelId = provider.defaultModel
                    } else {
                        selectedModelId = models.first?.id
                    }
                }
            }
        }
    }

    private func saveModel() {
        guard let provider = selectedProvider else { return }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let chosenModel = selectedModelId ?? provider.defaultModel

        let model = ModelConfig(
            id: UUID().uuidString,
            name: provider.displayName,
            provider: provider.rawValue,
            apiKey: trimmedKey,
            model: chosenModel,
            baseURL: provider.defaultBaseURL
        )

        var models = Config.savedModels
        // Replace existing model for same provider, or append
        if let idx = models.firstIndex(where: { $0.provider == provider.rawValue }) {
            models[idx] = model
        } else {
            models.append(model)
        }
        Config.setSavedModels(models)
        Config.setActiveModelId(model.id)

        // Update the LLM service so the UI reflects the chosen model immediately
        appState.llmService.refreshActiveModel()

        // Ensure the default persona uses this model (so wake-word doesn't revert to a stale model)
        let personas = Config.savedPersonas
        if personas.count <= 1, let only = personas.first {
            Config.updatePersonaModelId(only.id, modelId: model.id)
        }
    }

    private func goToNextPage(from current: Int) {
        var next = current + 1
        while next < totalPages && shouldSkip(page: next) {
            next += 1
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            page = next
        }
    }

    private func goToPreviousPage(from current: Int) {
        var previous = current - 1
        while previous >= 0 && shouldSkip(page: previous) {
            previous -= 1
        }
        guard previous >= 0 else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            page = previous
        }
    }

    private func shouldSkip(page: Int) -> Bool {
        if Config.simpleMode {
            switch page {
            case 2, 4, 5, 6: return true
            default: break
            }
        }
        switch page {
        case 3: return !selectedStrategy.needsGatewaySetup
        case 4: return !selectedStrategy.needsLocalModelSetup || !capability.canDownloadMLX
        case 5, 6: return !selectedStrategy.needsCloudSetup
        default: return false
        }
    }

    private func saveGatewayFromOnboarding() {
        let trimmedURL = gatewayTunnelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedToken.isEmpty else { return }

        let host = GatewayEndpoint.preferMaiaEndpoint(trimmedURL)

        let gw = GatewayConfig(
            id: UUID().uuidString,
            name: "\(Config.agentName) VPS",
            provider: GatewayProvider.openclaw.rawValue,
            lanHost: "",
            port: GatewayProvider.openclaw.defaultPort,
            tunnelHost: host,
            token: trimmedToken,
            connectionMode: OpenClawConnectionMode.tunnel.rawValue,
            enabled: true,
            priority: 0
        )
        Config.setSavedGateways([gw])
        Config.setOpenClawEnabled(true)
        Config.setHeavyWorkOnVPS(true)
    }

    private func saveLocalModelFromOnboarding() {
        guard !selectedLocalModelId.isEmpty else { return }
        let display = capability.suggestedLocalModels.first(where: { $0.id == selectedLocalModelId })?.name ?? "Local"
        let model = ModelConfig(
            id: UUID().uuidString,
            name: display,
            provider: LLMProvider.local.rawValue,
            apiKey: "",
            model: selectedLocalModelId,
            baseURL: ""
        )
        var models = Config.savedModels.filter { $0.llmProvider != .local }
        models.append(model)
        Config.setSavedModels(models)
        Config.setActiveModelId(model.id)
        Config.setLocalTextModelId(selectedLocalModelId)
        appState.llmService.refreshActiveModel()

        let personas = Config.savedPersonas
        if personas.count <= 1, let only = personas.first {
            Config.updatePersonaModelId(only.id, modelId: model.id)
        }
    }

    private func activateAppleOnDeviceIfNeeded() {
        guard selectedStrategy == .vpsOnly, capability.canUseAppleIntelligence else { return }
        if let apple = Config.savedModels.first(where: { $0.llmProvider == .appleOnDevice }) {
            Config.setActiveModelId(apple.id)
            appState.llmService.refreshActiveModel()
        }
    }

    private func startLocalDownloadIfNeeded() {
        guard !selectedLocalModelId.isEmpty,
              let local = appState.llmService.localLLMService else { return }
        isDownloadingLocal = true
        localDownloadError = nil
        Task {
            do {
                try await local.downloadModel(selectedLocalModelId)
                await MainActor.run { isDownloadingLocal = false }
            } catch {
                await MainActor.run {
                    isDownloadingLocal = false
                    localDownloadError = error.localizedDescription
                }
            }
        }
    }

    private func completeOnboarding() {
        if Config.simpleMode {
            selectedStrategy = .vpsOnly
        }
        Config.setPhoneAIStrategy(selectedStrategy)
        Config.enforceTerminalMode()
        if selectedStrategy.needsGatewaySetup {
            saveGatewayFromOnboarding()
            Config.setHeavyWorkOnVPS(!gatewayToken.isEmpty)
        }
        if selectedStrategy.needsLocalModelSetup {
            saveLocalModelFromOnboarding()
        } else {
            activateAppleOnDeviceIfNeeded()
        }
        if selectedStrategy.needsCloudSetup, !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            saveModel()
        }

        Config.ensurePrimaryAgentPersona()
        Config.syncWakePhraseFromAgentName()
        Config.setHasCompletedOnboarding(true)

        // Ensure Wearables SDK is configured (may already be done from permissions page)
        if !bluetoothConfigured {
            configureWearablesSDK()
        }

        // Start all services that depend on Wearables.shared + permissions
        appState.startPermissionRequiringServices()

        withAnimation(.easeInOut(duration: 0.4)) {
            isVisible = false
        }
    }

    private func openAPIKeyURL(for provider: LLMProvider) {
        let urlString: String
        switch provider {
        case .anthropic: urlString = "https://console.anthropic.com/settings/keys"
        case .openai: urlString = "https://platform.openai.com/api-keys"
        case .gemini: urlString = "https://aistudio.google.com/apikey"
        case .groq: urlString = "https://console.groq.com/keys"
        case .nvidia: urlString = "https://build.nvidia.com/settings/api-keys"
        case .openrouter: urlString = "https://openrouter.ai/keys"
        case .qwen: urlString = "https://dashscope.console.aliyun.com/apiKey"
        case .zai: urlString = "https://open.bigmodel.cn/usercenter/apikeys"
        case .xai: urlString = "https://console.x.ai"
        case .minimax: urlString = "https://platform.minimaxi.com"
        default: urlString = ""
        }
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    private func apiKeyURLLabel(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return "Get a key at console.anthropic.com"
        case .openai: return "Get a key at platform.openai.com"
        case .gemini: return "Get a key at aistudio.google.com"
        case .groq: return "Get a key at console.groq.com"
        case .nvidia: return "Get a key at build.nvidia.com"
        case .openrouter: return "Get a key at openrouter.ai"
        case .qwen: return "Get a key at dashscope.console.aliyun.com"
        case .zai: return "Get a key at open.bigmodel.cn"
        case .xai: return "Get a key at console.x.ai (x.com / Grok)"
        case .minimax: return "Get a token at platform.minimaxi.com"
        default: return "Get an access key"
        }
    }
}