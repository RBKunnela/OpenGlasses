import SwiftUI

/// iMetaClaw agent identity — bot name drives the "Oi {name}" wake phrase.
struct AgentSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var agentName: String = Config.agentName
    @State private var saved = false

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
                Text("Configure a URL e o token do gateway OpenClaw no seu VPS (Hostinger ou outro).")
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(saved ? "Salvo" : "Salvar", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Agente")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            agentName = Config.agentName
        }
    }

    private func save() {
        Config.setAgentName(agentName)
        saved = true
        Task {
            await appState.openClawBridge.checkConnection()
        }
    }
}