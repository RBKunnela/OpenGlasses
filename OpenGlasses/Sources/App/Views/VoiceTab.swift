import SwiftUI
import PhotosUI

/// Voice tab — the primary interaction screen.
///
/// Layout (top to bottom):
///   1. Two status pills (Glasses + OpenClaw) at top
///   2. StatusIndicator (center, with quick actions)
///   3. Transcript overlay
///   4. Chat input bar (text + image attach) or hero capsule
///   5. Hero capsule + floating action buttons (bottom)
struct VoiceTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showPreview = false
    @State private var showModelPicker = false
    @State private var showGatewaySettings = false
    @State private var showPersonaPicker = false
    @State private var showChatInput = false

    private var session: GeminiLiveSessionManager { appState.geminiLiveSession }
    private var openAISession: OpenAIRealtimeSessionManager { appState.openAIRealtimeSession }

    private var isRealtime: Bool { appState.currentMode.isRealtime }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Recording indicator
                if appState.videoRecorder.isRecording {
                    recordingBadge
                        .padding(.top, 8)
                }

                // Status pills row
                StatusPillsRow(
                    openClawBridge: appState.openClawBridge
                )
                .padding(.top, 8)

                VoiceRoutingBanner(openClawBridge: appState.openClawBridge)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                // Status card
                StatusIndicator(session: session, openAISession: openAISession)
                    .padding(.top, 12)

                Spacer()

                // Ambient captions
                if appState.ambientCaptions.isActive {
                    AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                        .padding(.bottom, 8)
                }

                // Transcript
                TranscriptOverlay(session: session, openAISession: openAISession)
                    .padding(.bottom, 8)

                // Load the on-device model on demand — only shown when the active
                // model is local, so it's not lazy-loaded (slowly) on first query.
                if !Config.isOpenClawExclusive,
                   let local = appState.llmService.localLLMService {
                    LocalModelBar(service: local)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                // Quick actions (above hero capsule)
                if !showChatInput {
                    QuickActionsGrid()
                }

                // Chat input bar (when active) or voice controls
                if showChatInput && !isRealtime {
                    ChatInputBar(showChatInput: $showChatInput)
                } else {
                    VoiceTabControls(
                        session: session,
                        openAISession: openAISession,
                        showPreview: $showPreview,
                        showModelPicker: $showModelPicker,
                        showGatewaySettings: $showGatewaySettings,
                        showChatInput: $showChatInput
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showPreview) {
            LivePreviewView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(appState: appState)
        }
        .sheet(isPresented: $showGatewaySettings) {
            NavigationStack {
                GatewaySettingsView(appState: appState)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showGatewaySettings = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPersonaPicker) {
            PersonaPickerSheet(appState: appState)
        }
        .sheet(item: $appState.pendingShareItem) { item in
            ShareSheet(items: item.items)
        }
    }

    // MARK: - Recording Badge

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("REC \(appState.videoRecorder.formattedDuration)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.red.opacity(0.3)))
        .accessibilityLabel("Recording: \(appState.videoRecorder.formattedDuration)")
    }
}

// MARK: - Local Model Bar (home-screen load/unload)

/// Home-screen control to load/unload the on-device model on demand. Shown only when
/// the active model is a local (MLX) model, so the user isn't waiting on a lazy load
/// at first query — and can free memory when done.
private struct LocalModelBar: View {
    @ObservedObject var service: LocalLLMService
    @Environment(\.appAccent) private var accent
    @State private var actionError: String?

    var body: some View {
        if let active = Config.activeModel, active.llmProvider == .local {
            content(active)
        }
    }

    @ViewBuilder
    private func content(_ active: ModelConfig) -> some View {
        let modelId = active.model
        let isLoaded = service.isModelLoaded && service.loadedModelId == modelId
        let isDownloaded = service.isModelDownloaded(modelId)
        let ramBlocked = !service.canLoadModel(modelId)
        let ramMessage = service.ramRequirementMessage(for: modelId)

        VStack(spacing: 6) {
        if service.isDownloading && service.downloadingModelId == modelId {
            HStack(spacing: 8) {
                ProgressView(value: service.downloadProgress).controlSize(.small)
                Text("Baixando \(active.name)…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(Int(service.downloadProgress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: Capsule())
        } else if service.isLoadingModel {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Carregando \(active.name) (opcional)…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: Capsule())
        } else if isLoaded {
            Button { service.unloadModel() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(active.name) pronto")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color(.label))
                    Text("· Liberar memória").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.green.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(active.name) carregado. Toque para liberar memória.")
        } else if !isDownloaded {
            Button { downloadModel(modelId) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle")
                    Text("Baixar \(active.name)")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(ramBlocked)
            .accessibilityLabel("Baixar modelo \(active.name)")
        } else if ramBlocked {
            HStack(spacing: 8) {
                Image(systemName: "memorychip").foregroundStyle(.orange)
                Text(ramMessage ?? "Modelo grande demais para este iPhone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.orange.opacity(0.12), in: Capsule())
        } else if Config.isOpenClawExclusive {
            HStack(spacing: 8) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text("Só \(Config.agentName) no VPS responde — sem Qwen nem API no iPhone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.35), in: Capsule())
        } else {
            Button { loadModel(modelId) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "cpu")
                    Text("Carregar \(active.name)")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Carregar modelo \(active.name) na memória")
        }

        if let error = actionError ?? service.lastLoadError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        } // VStack
    }

    private func loadModel(_ modelId: String) {
        actionError = nil
        Task {
            do {
                try await service.loadModel(modelId)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func downloadModel(_ modelId: String) {
        actionError = nil
        Task {
            do {
                try await service.downloadModel(modelId)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Voice Tab Controls (hero capsule + secondary buttons)

/// Bottom controls for the Voice tab — reuses the original BottomControlBar patterns.
private struct VoiceTabControls: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    @Binding var showPreview: Bool
    @Binding var showModelPicker: Bool
    @Binding var showGatewaySettings: Bool
    @Binding var showChatInput: Bool

    var body: some View {
        BottomControlBar(
            session: session,
            openAISession: openAISession,
            showSettings: .constant(false),
            showModelPicker: $showModelPicker,
            showGatewaySettings: $showGatewaySettings,
            showPreview: $showPreview,
            showChatInput: $showChatInput
        )
    }
}

// MARK: - Voice Routing Banner

/// Shows where voice queries actually go (VPS agent vs cloud API vs fallback).
struct VoiceRoutingBanner: View {
    @ObservedObject var openClawBridge: OpenClawBridge

    private struct RoutingStatus {
        let icon: String
        let text: String
        let color: Color
    }

    private var status: RoutingStatus? {
        let gatewayReady = openClawBridge.webSocketReady
            && openClawBridge.connectionState == .connected

        if gatewayReady,
           Config.phoneAIStrategy == .hybridVPSLocal || Config.phoneAIStrategy == .vpsOnly {
            return RoutingStatus(
                icon: "server.rack",
                text: "Voz via \(Config.agentName) no VPS",
                color: .green
            )
        }

        if let active = Config.activeModel, active.isUsableCloudAPI,
           Config.phoneAIStrategy == .cloudOnly || Config.phoneAIStrategy == .hybridLocalCloud {
            return RoutingStatus(
                icon: "cloud.fill",
                text: "Voz via \(active.name) (API na nuvem)",
                color: .blue
            )
        }

        switch Config.phoneAIStrategy {
        case .cloudOnly, .hybridLocalCloud:
            if let cloud = Config.usableCloudModel() {
                return RoutingStatus(icon: "cloud.fill", text: "Voz via \(cloud.name)", color: .blue)
            }
            return RoutingStatus(
                icon: "exclamationmark.triangle",
                text: "Configure uma API na nuvem em Settings → AI Models",
                color: .orange
            )
        case .hybridVPSLocal, .vpsOnly:
            let gatewayReady = openClawBridge.webSocketReady
                && openClawBridge.connectionState == .connected
            if gatewayReady {
                return RoutingStatus(
                    icon: "server.rack",
                    text: "Voz só via \(Config.agentName) no VPS (OpenClaw)",
                    color: .green
                )
            }
            let host = Config.enabledGateways.first?.tunnelURL
                ?? GatewayEndpoint.sanitize(Config.openClawTunnelHost)
            let hostLine = host.isEmpty ? "" : " (\(host))"
            let wsHint = GatewayEndpoint.isHermesHost(host)
                ? " — URL errada (Hermes/KVM4); use \(AppBranding.defaultMaiaGatewayURL)"
                : host.isEmpty ? "" : " — /ws issue (see SERVER-CONTRACT-FOR-GROK.md on VPS)"
            return RoutingStatus(
                icon: "exclamationmark.triangle",
                text: "\(Config.agentName) offline\(hostLine)\(wsHint)",
                color: .red
            )
        }
    }

    var body: some View {
        if let status {
            HStack(spacing: 8) {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(status.color.opacity(0.1), in: Capsule())
        }
    }
}

// MARK: - Status Pills Row

struct StatusPillsRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var openClawBridge: OpenClawBridge

    var body: some View {
        HStack {
            glassesPill
            Spacer()
            if Config.isOpenClawConfigured {
                openClawPill
            }
        }
        .padding(.horizontal, 16)
    }

    @State private var showDisconnectConfirm = false

    private var glassesPill: some View {
        let connected = appState.isConnected
        let color: Color = connected ? .green : .red.opacity(0.7)
        let label = connected ? (appState.glassesService.deviceName ?? "Glasses") : "Disconnected"

        return Button {
            if connected {
                showDisconnectConfirm = true
            } else {
                Task { await appState.connectAndListen() }
            }
        } label: {
            HStack(spacing: 6) {
                LogoIcon(size: 15)
                    .foregroundStyle(color)
                if connected {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .buttonStyle(.plain)
        .confirmationDialog("Disconnect Glasses", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                appState.disconnectGlasses()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stop mic, camera, and TTS. Gateway tasks keep running.")
        }
        .accessibilityLabel("Glasses: \(label)")
    }

    @State private var showGatewayDiagnostic = false

    private var openClawPill: some View {
        let (color, label): (Color, String) = {
            switch openClawBridge.connectionState {
            case .connected:
                return openClawBridge.webSocketReady
                    ? (.green, "\(Config.agentName) pronta")
                    : (.orange, "HTTP só — WS pendente")
            case .checking: return (.orange, "Verificando…")
            case .unreachable: return (.red, "Offline")
            case .notConfigured: return (.gray, "Não configurado")
            }
        }()

        return Button {
            showGatewayDiagnostic = true
            Task { await openClawBridge.checkConnection() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("OpenClaw")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(.label))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("OpenClaw: \(label)")
        .alert("OpenClaw / \(Config.agentName)", isPresented: $showGatewayDiagnostic) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(gatewayDiagnosticMessage)
        }
    }

    private var gatewayDiagnosticMessage: String {
        switch openClawBridge.connectionState {
        case .connected where openClawBridge.webSocketReady:
            return "\(Config.agentName) conectada — voz pode usar o VPS."
        case .connected:
            var msg = """
            HTTP OK (pill laranja), mas WebSocket falhou — por isso \(Config.agentName) aparece offline.
            Reinstalar o app não resolve: o VPS precisa liberar /ws na porta 443.
            """
            if !openClawBridge.lastConnectionDetail.isEmpty {
                msg += "\n\n\(openClawBridge.lastConnectionDetail)"
            }
            msg += "\n\nDepois de conectado: veja o contrato em /opt/openclaw/SERVER-CONTRACT-FOR-GROK.md"
            return msg
        case .unreachable(let reason):
            return """
            \(reason)

            Modo OpenClaw: o iPhone não usa Qwen nem NVIDIA quando \(Config.agentName) está offline.
            Corrija o gateway para a voz funcionar.
            """
        case .checking:
            return "Testando conexão…"
        case .notConfigured:
            return "Configure o gateway em Settings → Gateways."
        }
    }
}

// MARK: - Chat Input Bar

/// Text + image input bar — replaces the hero capsule when active.
/// Lets users type messages and attach photos from library or glasses camera.
struct ChatInputBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @Binding var showChatInput: Bool

    @State private var messageText = ""
    @State private var attachedImage: UIImage?
    @State private var attachedImageData: Data?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @FocusState private var isTextFieldFocused: Bool

    private var visionEnabled: Bool {
        Config.activeModel?.visionEnabled ?? false
    }

    var body: some View {
        VStack(spacing: 8) {
            // Attached image preview
            if let image = attachedImage {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            Button {
                                attachedImage = nil
                                attachedImageData = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                            }
                            .accessibilityLabel("Remove attached photo")
                            .offset(x: 8, y: -8),
                            alignment: .topTrailing
                        )
                    Spacer()
                }
                .padding(.horizontal, 16)
            }

            // Input row
            HStack(spacing: 10) {
                // Keyboard dismiss — only while editing. Lives in the bar (not the keyboard
                // toolbar, which overlays the Send button) and sits leading so it never
                // collides with the trailing Send control.
                if isTextFieldFocused {
                    Button {
                        isTextFieldFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(.label))
                            .frame(width: 36, height: 36)
                            .glassEffect(in: .circle)
                    }
                    .accessibilityLabel("Dismiss keyboard")
                    .transition(.opacity)
                }

                // Close button
                Button {
                    showChatInput = false
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(.label))
                        .frame(width: 36, height: 36)
                        .glassEffect(in: .circle)
                }
                .accessibilityLabel("Switch to voice input")

                // Photo attach (only for vision-capable models)
                if visionEnabled {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(.label))
                            .frame(width: 36, height: 36)
                            .glassEffect(in: .circle)
                    }
                    .accessibilityLabel("Attach photo")
                    .onChange(of: selectedPhotoItem) { _, item in
                        Task {
                            guard let item else { return }
                            if let data = try? await item.loadTransferable(type: Data.self) {
                                attachedImageData = data
                                attachedImage = UIImage(data: data)
                            }
                            selectedPhotoItem = nil
                        }
                    }
                }

                // Text field
                TextField("Type a message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isTextFieldFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(in: .rect(cornerRadius: 20))
                    .onSubmit { sendMessage() }

                // Send button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? accent : Color(.tertiaryLabel))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onAppear { isTextFieldFocused = true }
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appState.isProcessing
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let image = attachedImageData
        messageText = ""
        attachedImage = nil
        attachedImageData = nil
        Task {
            await appState.sendTextMessage(text, imageData: image)
        }
    }
}

