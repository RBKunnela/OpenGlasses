import SwiftUI

/// iMetaClaw agent identity — bot name drives the "Oi {name}" wake phrase.
struct AgentSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var agentName: String = Config.agentName
    @State private var saved = false
    @State private var showResetConfirmation = false

    private var wakePreview: String {
        AppBranding.wakePhraseDisplay(for: agentName)
    }

    var body: some View {
        Form {
            Section {
                TextField("Nome do agente", text: $agentName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .onChange(of: agentName) { _, _ in saved = false }

                LabeledContent("Frase de ativação") {
                    Text(wakePreview)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("Seu agente")
            } footer: {
                Text("Diga \"\(wakePreview)\" para falar com seu agente OpenClaw nos óculos. O nome pode ser qualquer um — Maia, Jarvis, Naia, etc.")
            }

            Section {
                NavigationLink {
                    GatewaySettingsView(appState: appState)
                } label: {
                    HStack {
                        Label("Servidor OpenClaw", systemImage: "server.rack")
                        Spacer()
                        if Config.isAnyGatewayConfigured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                if let name = appState.openClawBridge.activeGatewayName {
                    LabeledContent("Conectado") {
                        Text(name)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await appState.openClawBridge.checkConnection() }
                } label: {
                    Label("Testar conexão", systemImage: "antenna.radiowaves.left.and.right")
                }
            } header: {
                Text("Conexão")
            } footer: {
                Text("Maia no KVM2: \(AppBranding.defaultMaiaGatewayURL). Não use Hermes / aicontexteng.com (KVM4).")
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(saved ? "Salvo" : "Salvar", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reiniciar configuração inicial", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Mostra o assistente de boas-vindas novamente e faz o agente perguntar seu nome e preferências. Suas chaves de API e gateway são mantidos.")
            }
        }
        .navigationTitle("Agente")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            agentName = Config.agentName
        }
        .confirmationDialog(
            "Reiniciar configuração?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reiniciar", role: .destructive) {
                Config.resetOnboardingForFreshStart()
                agentName = Config.agentName
                saved = false
                NotificationCenter.default.post(name: .onboardingReset, object: nil)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O assistente de configuração vai aparecer de novo na tela principal.")
        }
    }

    private func save() {
        Config.setAgentName(agentName)
        Config.ensurePrimaryAgentPersona()
        saved = true
        Task {
            await appState.openClawBridge.checkConnection()
        }
    }
}