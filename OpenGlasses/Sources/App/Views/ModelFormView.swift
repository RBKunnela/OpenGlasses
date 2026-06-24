import SwiftUI
import AuthenticationServices

/// Shared form content for adding and editing AI model configurations.
/// Used by both `AddModelView` and `ModelEditorView` to eliminate duplication.
struct ModelFormView: View {
    @Binding var name: String
    @Binding var selectedProvider: LLMProvider
    @Binding var apiKey: String
    @Binding var model: String
    @Binding var baseURL: String
    @Binding var supportsVision: Bool

    // Model fetching state
    @Binding var availableModels: [ModelFetcher.RemoteModel]
    @Binding var isFetchingModels: Bool
    @Binding var fetchError: String?
    @Binding var keyValidated: Bool

    /// When true, changing provider also resets the model ID to the new provider's default.
    var resetModelOnProviderChange: Bool = true

    // Connection-test state (siri-and-local-server plan)
    @State private var isTestingConnection = false
    @State private var connectionStatus: String?
    @State private var connectionOK = false

    // OAuth login state
    @State private var isOAuthSessionActive = false
    @State private var oauthError: String?

    var body: some View {
        Section {
            TextField("e.g. Claude Sonnet, GPT-4o", text: $name)
                .autocorrectionDisabled()
        } header: {
            Text("Display Name")
        }

        Section {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .onChange(of: selectedProvider) { _, newProvider in
                baseURL = newProvider.defaultBaseURL
                if resetModelOnProviderChange {
                    model = newProvider.defaultModel
                } else if model.isEmpty || LLMProvider.allCases.contains(where: { $0.defaultModel == model }) {
                    model = newProvider.defaultModel
                }
                supportsVision = ModelConfig.inferredSupportsVision(
                    provider: newProvider,
                    model: model,
                    baseURL: baseURL
                )
                if name.isEmpty {
                    name = newProvider.displayName
                }
                resetModelList()
            }
        } header: {
            Text("Provider")
        }

        if selectedProvider == .local {
            // MARK: Local model section
            Section {
                let downloaded = localDownloadedModels

                if downloaded.isEmpty {
                    Label("No models downloaded yet", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(downloaded, id: \.self) { modelId in
                            Text(localDisplayName(modelId))
                                .tag(modelId)
                        }
                    }
                }

                NavigationLink {
                    LocalModelManagerView()
                } label: {
                    Label("Download & Manage Models", systemImage: "arrow.down.circle")
                }

                Toggle("Vision (Image Input)", isOn: $supportsVision)
            } header: {
                Text("Local Model")
            } footer: {
                if localDownloadedModels.isEmpty {
                    Text("Download a model first, then select it here. No internet needed after download.")
                } else {
                    Text("Select a downloaded model. Runs entirely on-device — no internet needed.")
                }
            }
        } else {
            // MARK: Cloud API key / subscription token section
            Section {
                // OAuth sign-in button (e.g. Claude subscription via claude.ai)
                if selectedProvider.isOAuthProvider {
                    Button {
                        startOAuthSession()
                    } label: {
                        HStack {
                            if isOAuthSessionActive {
                                ProgressView().scaleEffect(0.8)
                                Text("Opening browser…")
                            } else if !apiKey.isEmpty {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Signed in · tap to re-authenticate")
                            } else {
                                Image(systemName: "person.badge.key")
                                Text(selectedProvider.oauthButtonLabel)
                            }
                        }
                    }
                    .disabled(isOAuthSessionActive)

                    if let oauthError {
                        Label(oauthError, systemImage: "xmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                // Manual token / API key field (always shown so user can paste if OAuth fails)
                TextField(
                    selectedProvider == .custom
                        ? "API Key (optional for local servers)"
                        : selectedProvider.isOAuthProvider ? "Token (auto-filled after sign-in)"
                        : selectedProvider.isSubscriptionBased ? "Subscription Token" : "API Key",
                    text: $apiKey
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textContentType(.oneTimeCode)
                .onChange(of: apiKey) { _, _ in resetModelList() }

                if let url = selectedProvider.consoleURL {
                    Link(destination: url) {
                        HStack {
                            Label(
                                selectedProvider.isSubscriptionBased ? "Manage Subscription" : "Get API Key",
                                systemImage: selectedProvider.isSubscriptionBased ? "creditcard" : "arrow.up.right.square"
                            )
                            Spacer()
                            Text(url.host ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if selectedProvider.showBaseURL {
                    Menu {
                        ForEach(LocalServerPreset.allCases) { preset in
                            Button(preset.displayName) {
                                baseURL = preset.baseURL
                                resetModelList()
                                connectionStatus = nil
                            }
                        }
                    } label: {
                        Label("Local server preset", systemImage: "server.rack")
                    }

                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: baseURL) { _, _ in resetModelList(); connectionStatus = nil }
                }

                Button {
                    Task { await fetchModels() }
                } label: {
                    HStack {
                        if isFetchingModels {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Validating…")
                        } else if keyValidated {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key valid · \(availableModels.count) models")
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(selectedProvider == .custom ? "Fetch models" : "Validate key & fetch models")
                        }
                    }
                }
                .disabled((apiKey.isEmpty && selectedProvider != .custom) || isFetchingModels)

                if let error = fetchError {
                    Label(error, systemImage: "xmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if selectedProvider.showBaseURL {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView().scaleEffect(0.8)
                                Text("Testing…")
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                                Text("Test Connection")
                            }
                        }
                    }
                    .disabled(baseURL.isEmpty || isTestingConnection)

                    if let connectionStatus {
                        Label(connectionStatus, systemImage: connectionOK ? "checkmark.circle.fill" : "xmark.circle")
                            .font(.footnote)
                            .foregroundStyle(connectionOK ? .green : .red)
                    }
                }
            } header: {
                Text(selectedProvider.isSubscriptionBased ? "Subscription Token" : "API Key")
            } footer: {
                Text(providerHelpText)
            }

            Section {
                if !availableModels.isEmpty {
                    Picker("Select Model", selection: $model) {
                        ForEach(availableModels) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                TextField("Model ID", text: $model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Toggle("Vision (Image Input)", isOn: $supportsVision)
            } header: {
                Text("Model")
            } footer: {
                if !availableModels.isEmpty {
                    Text("Pick from the list or type a model ID. Turn on Vision to send photos from your glasses to the AI.")
                } else {
                    Text("Turn on Vision to send photos from your glasses to the AI. Leave it off for text-only models.")
                }
            }
        }
    }

    // MARK: - Private

    private func resetModelList() {
        availableModels = []
        keyValidated = false
        fetchError = nil
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionStatus = nil
        defer { isTestingConnection = false }
        let result = await ModelFetcher.testConnection(provider: selectedProvider, apiKey: apiKey, baseURL: baseURL)
        connectionOK = result.isSuccess
        switch result {
        case .ok(let latencyMs, let count):
            connectionStatus = "Reachable — \(latencyMs) ms, \(count) model\(count == 1 ? "" : "s")"
        case .httpError(let code):
            connectionStatus = "Server returned HTTP \(code)"
        case .insecure:
            connectionStatus = "Blocked by App Transport Security — use https, or allow this host in Info.plist"
        case .unreachable(let why):
            connectionStatus = "Unreachable — \(why)"
        }
    }

    private func fetchModels() async {
        isFetchingModels = true
        fetchError = nil
        let models = await ModelFetcher.fetchModels(
            provider: selectedProvider,
            apiKey: apiKey,
            baseURL: baseURL
        )
        isFetchingModels = false
        if models.isEmpty {
            fetchError = "Couldn't find any models. Double-check your API key and try again."
            keyValidated = false
        } else {
            availableModels = models
            keyValidated = true
            if !models.contains(where: { $0.id == model }) {
                model = models.first(where: { $0.id == selectedProvider.defaultModel })?.id
                    ?? models.first?.id ?? model
            }
        }
    }

    // MARK: - OAuth

    /// Opens ASWebAuthenticationSession for providers that use browser-based OAuth login.
    /// The session redirects back to clawglasses://oauth/callback?token=...
    /// and the token is extracted and stored in apiKey.
    private func startOAuthSession() {
        guard let authURL = selectedProvider.oauthAuthURL else { return }
        isOAuthSessionActive = true
        oauthError = nil

        let callbackScheme = "clawglasses"

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            isOAuthSessionActive = false

            if let error {
                // User cancelled is not a real error
                if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    oauthError = error.localizedDescription
                }
                return
            }

            guard let callbackURL else {
                oauthError = "No callback URL received."
                return
            }

            // Extract token from callback URL query params:
            // clawglasses://oauth/callback?token=sk-ant-...
            // or from the URL fragment: #token=sk-ant-...
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            if let token = components?.queryItems?.first(where: { $0.name == "token" })?.value,
               !token.isEmpty {
                apiKey = token
                resetModelList()
            } else if let fragment = components?.fragment,
                      let tokenRange = fragment.range(of: "token=") {
                let token = String(fragment[tokenRange.upperBound...])
                    .components(separatedBy: "&").first ?? ""
                if !token.isEmpty {
                    apiKey = token
                    resetModelList()
                }
            } else {
                // Fallback: if the callback URL itself contains the session token
                // (some providers put it in the path), surface the full URL for manual copy.
                oauthError = "Sign-in completed but no token was found in the callback URL. Please copy your API key manually from console.anthropic.com."
            }
        }

        // ASWebAuthenticationSession requires a presentation anchor on iOS 13+
        // We use the key window's scene as the anchor.
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            session.presentationContextProvider = WindowSceneAnchor(scene: windowScene)
        }

        session.prefersEphemeralWebBrowserSession = false  // keep cookies so user stays logged in
        session.start()
    }

    private var providerHelpText: String {
        switch selectedProvider {
        case .anthropic: return "Tap \"Sign in with Claude\" to log in with your claude.ai subscription. Your session token is stored automatically. Alternatively, paste an API key from console.anthropic.com."
        case .openai: return "Get your API key at platform.openai.com"
        case .gemini: return "Get your API key at aistudio.google.com"
        case .groq: return "Get your API key at console.groq.com"
        case .xai: return "xAI Grok subscription — paste your API key from console.x.ai. Works with Grok 3, Grok 3 Mini, and Grok 2 Vision."
        case .zai: return "Z.ai GLM subscription — paste your token from z.ai. Uses GLM-4.5 and other GLM models via the coding endpoint."
        case .qwen: return "Qwen subscription — paste your token from the Alibaba Cloud DashScope console. Uses the international coding endpoint."
        case .minimax: return "MiniMax subscription — paste your token from platform.minimaxi.com. Uses MiniMax-M2.7 and other MiniMax models."
        case .openrouter: return "500+ models with one API key — openrouter.ai/keys"
        case .custom: return "Any OpenAI-compatible endpoint — a cloud API or a self-hosted Ollama / llama.cpp / LM Studio / vLLM / LocalAI server. For a local server, set the Base URL to e.g. http://your-mac.local:11434/v1 and leave the API Key blank. Use the host's .local name or a Tailscale address — a raw 192.168.x.x IP over http may be blocked by App Transport Security."
        case .local: return "On-device inference — no internet needed"
        case .appleOnDevice: return "Apple Intelligence — built-in, no download, no API key"
        }
    }

    // MARK: - Local Model Helpers

    /// List of downloaded local model IDs.
    private var localDownloadedModels: [String] {
        LocalLLMService().downloadedModelIds()
    }

    /// Convert "mlx-community/Qwen2.5-3B-Instruct-4bit" → "Qwen2.5 3B Instruct 4bit"
    private func localDisplayName(_ modelId: String) -> String {
        guard let name = modelId.split(separator: "/").last else { return modelId }
        return String(name)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - ASWebAuthenticationSession presentation anchor

/// Provides the UIWindowScene as the presentation anchor for ASWebAuthenticationSession.
private final class WindowSceneAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    let scene: UIWindowScene
    init(scene: UIWindowScene) { self.scene = scene }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first ?? ASPresentationAnchor()
    }
}
