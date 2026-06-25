import Foundation
import UIKit

// MARK: - Connection Types

enum OpenClawConnectionMode: String, CaseIterable {
    case lan = "lan"
    case tunnel = "tunnel"
    case auto = "auto"

    var displayName: String {
        switch self {
        case .lan: return "LAN (Local Network)"
        case .tunnel: return "Tunnel (Remote)"
        case .auto: return "Auto (try LAN first)"
        }
    }
}

enum OpenClawConnectionState: Equatable {
    case notConfigured
    case checking
    case connected
    case unreachable(String)
}

enum ResolvedConnection: Equatable {
    case lan
    case tunnel

    var label: String {
        switch self {
        case .lan: return "LAN"
        case .tunnel: return "Tunnel"
        }
    }
}

// MARK: - OpenClaw Bridge

/// Client for the OpenClaw gateway. Uses /health for status checks and
/// WebSocket protocol v3/v4 (`chat.send` + `agent.wait`) for chat / task delegation.
@MainActor
class OpenClawBridge: ObservableObject {
    @Published var lastToolCallStatus: ToolCallStatus = .idle
    @Published var connectionState: OpenClawConnectionState = .notConfigured
    /// True only after a successful WebSocket handshake (what voice/chat actually needs).
    @Published var webSocketReady = false
    @Published var resolvedConnection: ResolvedConnection?
    /// Which gateway we're currently connected to (nil = legacy single config).
    @Published var activeGatewayName: String?
    /// Tools currently available on the connected gateway (populated at connect time).
    @Published var availableGatewayTools: [[String: String]] = []
    /// Whether session compaction has occurred (gateway trimmed context).
    @Published var sessionCompacted: Bool = false
    /// Last `/health` URL probed — shown in Settings when the gateway looks offline.
    @Published var lastCheckedURL: String?
    /// Human-readable result from the last full connection probe.
    @Published var lastProbeSummary: String = ""
    /// Detail from the last connection attempt (WebSocket / pairing / token errors).
    @Published var lastConnectionDetail: String = ""

    // Injected for inbound node.invoke handling (glasses control from server)
    var cameraService: CameraService?
    var audioRecordingService: AudioRecordingService?
    var videoRecorder: VideoRecordingService?
    var liveTranslationService: LiveTranslationService?
    var ambientCaptionService: AmbientCaptionService?

    /// Bridge-level connection for inbound commands (node.invoke etc). WS handshake success.
    var isConnected: Bool {
        connectionState == .connected || webSocketReady || wsConnected
    }

    private let pingSession: URLSession
    private let lanPingSession: URLSession
    private var sessionKey: String

    /// Cached resolved endpoint for the session
    private var cachedEndpoint: String?
    /// The gateway config that resolved to the cached endpoint
    private var activeGateway: GatewayConfig?

    private var isConnecting = false
    private var keepaliveTask: Task<Void, Never>?
    private var lastConnectionAttempt = Date.distantPast

    /// WebSocket for chat (`chat.send`)
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var wsConnected = false
    private var receiveLoopRunning = false
    private var pendingResponses: [String: CheckedContinuation<String, Error>] = [:]
    /// Accumulated assistant text per chat.run while waiting for completion.
    private var pendingRunText: [String: String] = [:]
    private var pendingRunCompletions: [String: CheckedContinuation<String, Error>] = [:]
    private var connectChallengeReceived = false
    private var connectChallengeNonce: String?
    private var connectChallengeWaiter: CheckedContinuation<Void, Error>?

    /// Callback for streaming partial content chunks from long gateway tasks.
    /// Called on main actor with each text chunk as it arrives.
    var onStreamChunk: ((String) -> Void)?
    var onGatewayConnected: (() -> Void)?

    init() {
        let pingConfig = URLSessionConfiguration.default
        pingConfig.timeoutIntervalForRequest = 10
        self.pingSession = URLSession(configuration: pingConfig)

        let lanPingConfig = URLSessionConfiguration.default
        lanPingConfig.timeoutIntervalForRequest = 2
        self.lanPingSession = URLSession(configuration: lanPingConfig)

        self.sessionKey = OpenClawBridge.newSessionKey()
    }

    // MARK: - Endpoint Resolution (Multi-Gateway)

    func resolveEndpoint() async -> String {
        if let cached = cachedEndpoint {
            return cached
        }

        // Try multi-gateway configs first (in priority order)
        let gateways = Config.enabledGateways
        if !gateways.isEmpty {
            for gateway in gateways {
                if let endpoint = await resolveGateway(gateway) {
                    cachedEndpoint = endpoint
                    activeGateway = gateway
                    activeGatewayName = gateway.name
                    NSLog("[Gateway] Resolved %@ (%@) → %@", gateway.name, gateway.gatewayProvider.displayName, endpoint)
                    return endpoint
                }
            }
            // None reachable — use first gateway's best guess
            let first = gateways[0]
            let fallback = !first.tunnelURL.isEmpty ? first.tunnelURL : first.lanURL
            cachedEndpoint = fallback
            activeGateway = first
            activeGatewayName = first.name
            NSLog("[Gateway] None reachable, falling back to %@ → %@", first.name, fallback)
            return fallback
        }

        // Legacy single-gateway config
        return await resolveLegacyEndpoint()
    }

    /// Resolve a single gateway config — try LAN then tunnel based on its connection mode.
    private func resolveGateway(_ gateway: GatewayConfig) async -> String? {
        let lanURL = gateway.lanURL
        let tunnelURL = gateway.tunnelURL

        switch gateway.connectionModeEnum {
        case .lan:
            guard !lanURL.isEmpty else { return nil }
            resolvedConnection = .lan
            return lanURL
        case .tunnel:
            guard !tunnelURL.isEmpty else { return nil }
            resolvedConnection = .tunnel
            return tunnelURL
        case .auto:
            if !lanURL.isEmpty, await isReachable(baseURL: lanURL, token: gateway.token, session: lanPingSession) {
                resolvedConnection = .lan
                return lanURL
            }
            if !tunnelURL.isEmpty, await isReachable(baseURL: tunnelURL, token: gateway.token, session: pingSession) {
                resolvedConnection = .tunnel
                return tunnelURL
            }
            return nil  // This gateway isn't reachable — try next one
        }
    }

    /// Legacy: resolve from the single Config.openClaw* properties.
    private func resolveLegacyEndpoint() async -> String {
        let mode = Config.openClawConnectionMode
        let lanHost = Config.openClawLanHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let lanURL = GatewayEndpoint.sanitize(lanHost.contains("://") ? lanHost : "\(lanHost):\(Config.openClawPort)")
        let tunnelURL = GatewayEndpoint.sanitize(Config.openClawTunnelHost)

        switch mode {
        case .lan:
            cachedEndpoint = lanURL
            resolvedConnection = .lan
            return lanURL
        case .tunnel:
            cachedEndpoint = tunnelURL
            resolvedConnection = .tunnel
            return tunnelURL
        case .auto:
            if await isReachable(baseURL: lanURL, token: Config.openClawGatewayToken, session: lanPingSession) {
                cachedEndpoint = lanURL
                resolvedConnection = .lan
                return lanURL
            }
            if !tunnelURL.isEmpty, await isReachable(baseURL: tunnelURL, token: Config.openClawGatewayToken, session: pingSession) {
                cachedEndpoint = tunnelURL
                resolvedConnection = .tunnel
                return tunnelURL
            }
            let fallback = !tunnelURL.isEmpty ? tunnelURL : lanURL
            cachedEndpoint = fallback
            resolvedConnection = !tunnelURL.isEmpty ? .tunnel : .lan
            return fallback
        }
    }

    private func alternateEndpoint() -> String? {
        // Multi-gateway: try the next gateway in priority order
        if let current = activeGateway {
            let gateways = Config.enabledGateways
            if let idx = gateways.firstIndex(where: { $0.id == current.id }),
               idx + 1 < gateways.count {
                let next = gateways[idx + 1]
                let url = !next.tunnelURL.isEmpty ? next.tunnelURL : next.lanURL
                NSLog("[Gateway] Failing over from %@ to %@", current.name, next.name)
                return url
            }
        }

        // Legacy fallback
        guard Config.openClawConnectionMode == .auto else { return nil }
        let lanHost = Config.openClawLanHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let lanURL = GatewayEndpoint.sanitize(lanHost.contains("://") ? lanHost : "\(lanHost):\(Config.openClawPort)")
        let tunnelURL = GatewayEndpoint.sanitize(Config.openClawTunnelHost)
        if cachedEndpoint == lanURL, !tunnelURL.isEmpty { return tunnelURL }
        if cachedEndpoint == tunnelURL { return lanURL }
        return nil
    }

    func clearCachedEndpoint() {
        cachedEndpoint = nil
        activeGateway = nil
        activeGatewayName = nil
        resolvedConnection = nil
        disconnectWebSocket()
    }

    /// The active gateway's token, or the legacy token.
    var activeToken: String {
        activeGateway?.token ?? Config.openClawGatewayToken
    }

    /// Check reachability using /health endpoint (tries multiple URL variants and auth styles).
    private func isReachable(baseURL: String, token: String? = nil, session: URLSession) async -> Bool {
        let authToken = token ?? activeToken
        let probe = await performHealthProbe(endpoint: baseURL, token: authToken, session: session)
        if case .success = probe { return true }
        return false
    }

    private enum HealthProbeResult {
        case success(workingBase: String, lastURL: String)
        /// Server answered (wrong path/token/nginx) — not a pure network failure.
        case serverResponded(detail: String, lastURL: String, workingBase: String?)
        case networkFailure(detail: String, lastURL: String)
    }

    private func performHealthProbe(
        endpoint: String,
        token: String,
        session: URLSession = URLSession.shared
    ) async -> HealthProbeResult {
        let requests = GatewayEndpoint.healthProbeRequests(from: endpoint, token: token)
        guard !requests.isEmpty else {
            return .networkFailure(detail: "URL inválida", lastURL: endpoint)
        }

        var lastHTTPDetail = ""
        var lastNetworkDetail = ""
        var lastHTTPBase: String?
        var gotHTTPResponse = false

        for (url, style) in requests {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            GatewayEndpoint.applyHealthAuth(style, token: token, to: &request)
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    gotHTTPResponse = true
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let workingBase = url.deletingLastPathComponent().absoluteString
                    NSLog(
                        "[OpenClaw] Health %@ (%@) → HTTP %d (%@)",
                        url.absoluteString,
                        style.label,
                        http.statusCode,
                        String(body.prefix(100))
                    )
                    if (200...299).contains(http.statusCode) {
                        return .success(workingBase: workingBase, lastURL: url.absoluteString)
                    }
                    lastHTTPDetail = "HTTP \(http.statusCode) (\(style.label)) em \(url.host ?? url.absoluteString)"
                    lastHTTPBase = workingBase
                }
            } catch {
                lastNetworkDetail = "\(url.host ?? url.absoluteString): \(friendlyNetworkError(error))"
                NSLog("[OpenClaw] Health %@ (%@) failed: %@", url.absoluteString, style.label, error.localizedDescription)
            }
        }

        if gotHTTPResponse {
            return .serverResponded(
                detail: lastHTTPDetail,
                lastURL: requests.last?.url.absoluteString ?? endpoint,
                workingBase: lastHTTPBase
            )
        }

        let triedHosts = Set(GatewayEndpoint.candidateBases(from: endpoint)).joined(separator: ", ")
        let detail = lastNetworkDetail.isEmpty
            ? "Sem resposta do servidor. Tentou: \(triedHosts)"
            : "\(lastNetworkDetail). Tentou: \(triedHosts)"
        return .networkFailure(detail: detail, lastURL: requests.last?.url.absoluteString ?? endpoint)
    }

    private func friendlyNetworkError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost: return "host não encontrado"
            case NSURLErrorCannotConnectToHost: return "conexão recusada — gateway provavelmente só em 127.0.0.1 no VPS"
            case NSURLErrorTimedOut: return "timeout — firewall ou porta 18789 fechada"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "falha TLS/SSL — certificado inválido ou HTTPS em porta errada"
            case NSURLErrorNotConnectedToInternet: return "iPhone sem internet"
            default: break
            }
        }
        return error.localizedDescription
    }

    private func probeHealth(endpoint: String, token: String) async -> HealthProbeResult {
        await performHealthProbe(endpoint: endpoint, token: token, session: pingSession)
    }

    // MARK: - Connection Check

    func checkConnection() async {
        guard Config.isAnyGatewayConfigured else {
            connectionState = .notConfigured
            lastCheckedURL = nil
            return
        }
        if isConnecting || (wsConnected && webSocketTask != nil) {
            return // already good or connecting
        }
        connectionState = .checking
        let endpoint = await resolveEndpoint()
        let probe = await probeHealth(endpoint: endpoint, token: activeToken)
        switch probe {
        case .success(let workingBase, let lastURL):
            lastCheckedURL = lastURL
            cachedEndpoint = workingBase
            await finishHTTPConnected(endpoint: endpoint, workingBase: workingBase)
        case .serverResponded(let detail, let lastURL, let workingBase):
            lastCheckedURL = lastURL
            webSocketReady = false
            if let workingBase {
                cachedEndpoint = workingBase
                connectionState = .connected
                lastConnectionDetail = Self.authFailureHint(detail: detail)
                NSLog("[OpenClaw] HTTP reachable but health rejected: %@", detail)
            } else {
                connectionState = .unreachable(Self.offlineHint(endpoint: endpoint, detail: detail))
                lastConnectionDetail = detail
            }
        case .networkFailure(let detail, let lastURL):
            lastCheckedURL = lastURL
            webSocketReady = false
            lastConnectionDetail = detail
            connectionState = .unreachable(Self.offlineHint(endpoint: endpoint, detail: detail))
        }
    }

    private func finishHTTPConnected(endpoint: String, workingBase: String) async {
        NSLog("[OpenClaw] HTTP health OK via %@ (%@)", workingBase, resolvedConnection?.label ?? "unknown")
        connectionState = .connected
        do {
            try await ensureWebSocket()
            webSocketReady = true
            lastConnectionDetail = ""
            NSLog("[OpenClaw] WebSocket handshake OK — pronto para voz")
        } catch {
            webSocketReady = false
            lastConnectionDetail = Self.webSocketFailureHint(endpoint: workingBase, error: error)
            NSLog("[OpenClaw] HTTP OK but WebSocket failed: %@", lastConnectionDetail)
        }
    }

    private static func webSocketFailureHint(endpoint: String, error: Error) -> String {
        let raw = error.localizedDescription
        var lines = [raw]
        if GatewayEndpoint.isMaiaHost(endpoint) {
            lines.append("""
            Maia (KVM2) connection issue.
            See the current server contract: /opt/openclaw/SERVER-CONTRACT-FOR-GROK.md
            - Token comes from OPENCLAW_TOKEN in /opt/maia/.env (not openclaw CLI)
            - Caddy must proxy to 127.0.0.1:3600 (Maia Command Center), NOT 18789
            - Test the exact WS URL the app uses.
            """)
        } else if raw.localizedCaseInsensitiveContains("403")
            || raw.localizedCaseInsensitiveContains("401")
            || raw.localizedCaseInsensitiveContains("rejected") {
            lines.append("Verifique token do gateway e se Caddy expõe /ws com WebSocket upgrade.")
        }
        return lines.joined(separator: "\n\n")
    }

    private static func authFailureHint(detail: String) -> String {
        """
        Servidor alcançado, mas /health falhou: \(detail)

        • Use the correct OPENCLAW_TOKEN from /opt/maia/.env (see SERVER-CONTRACT-FOR-GROK.md)
        • Caddy on this deployment proxies to :3600 (Maia Command Center)
        """
    }

    /// Drop cached routing and stale WebSocket before a voice/chat turn.
    func refreshConnectionForChat() async {
        // In persistent iMetaClaw mode we avoid forced disconnects.
        // Only refresh if we are not connected.
        if connectionState != .connected || !webSocketReady {
            clearCachedEndpoint()
            await checkConnection()
        }
    }

    private static func offlineHint(endpoint: String, detail: String) -> String {
        """
        \(detail)

        URL configurada: \(endpoint)

        IMPORTANT: This deployment does NOT use a standard openclaw binary on :18789.
        Current working path (per SERVER-CONTRACT-FOR-GROK.md):
        - Caddy :443 → Maia Command Center on 127.0.0.1:3600
        - Token = OPENCLAW_TOKEN from /opt/maia/.env
        - Read /opt/openclaw/SERVER-CONTRACT-FOR-GROK.md for the exact contract.
        """
    }

    // MARK: - Session Management

    func resetSession() {
        sessionKey = OpenClawBridge.newSessionKey()
        NSLog("[OpenClaw] New session: %@", sessionKey)
    }

    /// Stable glasses session — shares the main agent session (same Maia as Telegram).
    private static func newSessionKey() -> String {
        let storageKey = "openClawGlassesSessionKey"
        if let existing = UserDefaults.standard.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let key = "agent:main:main"
        UserDefaults.standard.set(key, forKey: storageKey)
        return key
    }

    private static func connectParams(token: String, challengeNonce: String?) -> [String: Any] {
        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 4,
            "role": "operator",
            "scopes": ["operator.read", "operator.write"],
            "caps": [] as [String],
            "commands": [] as [String],
            "permissions": [:] as [String: Any],
            "client": [
                "id": "cli",
                "displayName": "OpenGlasses",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                "platform": "ios",
                "mode": "ui"
            ] as [String: Any],
            "auth": ["token": token],
            "locale": Locale.current.identifier,
            "userAgent": "OpenGlasses/ios"
        ]
        if let nonce = challengeNonce, !nonce.isEmpty,
           let device = OpenClawDeviceIdentity.connectDevice(token: token, nonce: nonce) {
            params["device"] = device
            NSLog("[OpenClaw] Connect includes device identity %@", OpenClawDeviceIdentity.loadOrCreate().deviceId)
        }
        return params
    }

    // MARK: - WebSocket Chat

    /// Ensure WebSocket is connected and authenticated
    private func ensureWebSocket() async throws {
        if wsConnected, webSocketTask != nil { return }
        if isConnecting { return }

        // Simple backoff to avoid storm of reconnects
        if Date().timeIntervalSince(lastConnectionAttempt) < 3 {
            return
        }
        lastConnectionAttempt = Date()

        isConnecting = true
        defer { isConnecting = false }

        if webSocketTask != nil {
            disconnectWebSocket()
        }

        let endpoint = await resolveEndpoint()
        let token = activeToken

        guard let url = GatewayEndpoint.webSocketURL(from: endpoint, token: token) else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL WebSocket inválida — verifique o host do gateway."])
        }

        NSLog("[OpenClaw] WS connecting to %@", url.absoluteString)
        connectChallengeReceived = false
        connectChallengeNonce = nil
        connectChallengeWaiter = nil

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // longer for persistent WS
        wsSession = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        webSocketTask = wsSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        startReceiveLoop()

        try await waitForConnectChallenge(endpoint: endpoint)
        if GatewayEndpoint.isRemote(endpoint),
           connectChallengeNonce == nil || connectChallengeNonce?.isEmpty == true {
            disconnectWebSocket()
            throw NSError(
                domain: "OpenClaw",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "O iPhone não alcançou o WebSocket do VPS em \(endpoint). Veja o contrato atual em /opt/openclaw/SERVER-CONTRACT-FOR-GROK.md — Caddy deve apontar para o Maia Command Center em :3600."]
            )
        }
        let connectResponse = try await performConnectHandshake(token: token)
        guard connectResponse["ok"] as? Bool == true else {
            let message = Self.formatGatewayError(from: connectResponse)
            NSLog("[OpenClaw] WS connect failed: %@", message)
            disconnectWebSocket()
            throw NSError(domain: "OpenClaw", code: -2, userInfo: [NSLocalizedDescriptionKey: message])
        }

        wsConnected = true
        webSocketReady = true
        sessionCompacted = false
        storeDeviceTokenIfPresent(from: connectResponse)
        NSLog("[OpenClaw] WS connected as operator (chat.send ready)")

        do {
            let sub = try await sendRequest(method: "sessions.messages.subscribe", params: ["key": sessionKey])
            if sub["ok"] as? Bool != true {
                NSLog("[OpenClaw] sessions.messages.subscribe failed: %@", String(describing: sub))
            }
        } catch {
            NSLog("[OpenClaw] sessions.messages.subscribe error: %@", error.localizedDescription)
        }

        // For iMetaClaw / persistent connection to support inbound node.invoke,
        // skip auto tools query (can cause extra activity) and start keepalive.
        if !Config.isOpenClawExclusive {
            Task { await queryAvailableTools() }
        }
        startKeepalive()
        onGatewayConnected?()
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
                guard let self = self,
                      !Task.isCancelled,
                      self.wsConnected,
                      let task = self.webSocketTask else { break }
                task.sendPing { error in
                    if let error = error {
                        NSLog("[OpenClaw] WS ping failed: %@", error.localizedDescription)
                    }
                }
            }
        }
    }

    private func waitForConnectChallenge(endpoint: String, timeoutSeconds: UInt64 = 20) async throws {
        if connectChallengeReceived, connectChallengeNonce != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectChallengeWaiter = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard let waiter = self.connectChallengeWaiter else { return }
                self.connectChallengeWaiter = nil
                if GatewayEndpoint.isRemote(endpoint), self.connectChallengeNonce == nil {
                    waiter.resume(throwing: NSError(
                        domain: "OpenClaw",
                        code: -8,
                        userInfo: [NSLocalizedDescriptionKey: "Timeout: VPS não respondeu ao WebSocket em \(endpoint)."]
                    ))
                    return
                }
                // Older LAN gateways may skip the challenge.
                waiter.resume()
            }
        }
    }

    /// Full diagnostic: HTTP health + WebSocket handshake + device identity.
    func probeConnection() async -> String {
        clearCachedEndpoint()
        disconnectWebSocket()
        let deviceId = OpenClawDeviceIdentity.loadOrCreate().deviceId
        var lines: [String] = [
            "Device ID do iPhone: \(deviceId)",
            "(deve aparecer em `openclaw devices list` no VPS após este teste)"
        ]
        await checkConnection()
        if let health = lastCheckedURL {
            lines.append("Health URL: \(health)")
        }
        switch connectionState {
        case .connected:
            lines.append("HTTP /health: OK")
        case .unreachable(let reason):
            lines.append("HTTP /health: FALHOU — \(reason)")
        case .checking:
            lines.append("HTTP /health: testando…")
        case .notConfigured:
            lines.append("Gateway não configurado no app.")
            lastProbeSummary = lines.joined(separator: "\n")
            return lastProbeSummary
        }

        do {
            try await ensureWebSocket()
            lines.append("WebSocket + handshake: OK — Maia pode receber mensagens dos óculos.")
            lines.append("Check the server contract at /opt/openclaw/SERVER-CONTRACT-FOR-GROK.md (this deployment does not use openclaw CLI devices commands).")
        } catch {
            lines.append("WebSocket: FALHOU — \(error.localizedDescription)")
            lines.append("Enquanto isso falhar, a Maia NÃO recebe nada pelos óculos (Telegram continua separado).")
        }

        lastProbeSummary = lines.joined(separator: "\n")
        return lastProbeSummary
    }

    private func performConnectHandshake(token: String) async throws -> [String: Any] {
        guard let task = webSocketTask else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebSocket não iniciou — o servidor pode ter recusado a conexão."])
        }

        let connectId = UUID().uuidString
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": Self.connectParams(token: token, challengeNonce: connectChallengeNonce)
        ]
        let connectData = try JSONSerialization.data(withJSONObject: connectMsg)
        guard let connectJSON = String(data: connectData, encoding: .utf8) else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "Falha ao codificar handshake"])
        }

        NSLog("[OpenClawWS] Sending connect: %@", String(connectJSON.prefix(500)))
        let responseText: String = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[connectId] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let cont = self.pendingResponses.removeValue(forKey: connectId) {
                    cont.resume(throwing: NSError(
                        domain: "OpenClaw",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Handshake com o gateway expirou."]
                    ))
                }
            }
            Task {
                do {
                    try await task.send(.string(connectJSON))
                } catch {
                    await MainActor.run {
                        if let cont = self.pendingResponses.removeValue(forKey: connectId) {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        }

        guard let responseData = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NSError(domain: "OpenClaw", code: -4, userInfo: [NSLocalizedDescriptionKey: "Resposta inválida do gateway no handshake."])
        }
        return json
    }

    /// Background receive loop — routes responses to pending continuations.
    /// Runs during handshake (`wsConnected == false`) and after auth.
    private func startReceiveLoop() {
        guard !receiveLoopRunning else { return }
        receiveLoopRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.receiveLoopRunning = false }
            while let task = self.webSocketTask {
                do {
                    let msg = try await task.receive()
                    let text: String
                    switch msg {
                    case .string(let t): text = t
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: continue
                    }

                    guard let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    let type = json["type"] as? String ?? ""

                    if type == "res", let id = json["id"] as? String {
                        // Route to pending request
                        await MainActor.run {
                            if let cont = self.pendingResponses.removeValue(forKey: id) {
                                cont.resume(returning: text)
                            }
                        }
                    } else if type == "event" {
                        let event = json["event"] as? String ?? ""
                        let payload = json["payload"] as? [String: Any] ?? [:]

                        if event == "connect.challenge" {
                            await MainActor.run {
                                self.connectChallengeNonce = payload["nonce"] as? String
                                self.connectChallengeReceived = true
                                self.connectChallengeWaiter?.resume()
                                self.connectChallengeWaiter = nil
                            }
                        }

                        switch event {
                        case "session.compacted", "session.truncated":
                            await MainActor.run {
                                self.sessionCompacted = true
                                NSLog("[OpenClaw] Session compacted by gateway")
                            }
                        case "session.chunk", "stream.chunk", "chat", "agent", "session.message":
                            await MainActor.run {
                                self.handleStreamingChatPayload(event: event, payload: payload)
                            }
                        case "tick", "heartbeat", "keepalive":
                            // Server tick every 4s - just keep the socket alive, do not treat as fatal
                            break
                        default:
                            NSLog("[OpenClaw] Unhandled event: \(event)")
                            break // Other events handled by OpenClawEventClient
                        }
                    } else if type == "req", let id = json["id"] as? String, let method = json["method"] as? String {
                        let params = json["params"] as? [String: Any] ?? [:]
                        Task {
                            let response = await self.handleIncomingRequest(method: method, params: params)
                            // Follow the contract: res with ok + payload
                            let resMsg: [String: Any] = [
                                "type": "res",
                                "id": id,
                                "ok": response["ok"] as? Bool ?? false,
                                "payload": response["payload"] ?? [:]
                            ]
                            if let data = try? JSONSerialization.data(withJSONObject: resMsg),
                               let str = String(data: data, encoding: .utf8) {
                                try? await self.webSocketTask?.send(.string(str))
                            }
                        }
                    }
                } catch {
                    NSLog("[OpenClaw] WS receive error: %@", error.localizedDescription)
                    // Do not immediately kill the connection on transient receive errors.
                    // Let upper layers / next ensure decide.
                    // Only clear pending if we are truly disconnected.
                    await MainActor.run {
                        if !self.wsConnected || self.webSocketTask == nil {
                            for (_, cont) in self.pendingResponses {
                                cont.resume(throwing: error)
                            }
                            self.pendingResponses.removeAll()
                            for (_, cont) in self.pendingRunCompletions {
                                cont.resume(throwing: error)
                            }
                            self.pendingRunCompletions.removeAll()
                            self.pendingRunText.removeAll()
                        }
                    }
                    // For persistent connection: on receive error, wait a bit and let ensure reconnect if needed.
                    // Do not break if we can recover.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if self.webSocketTask == nil {
                        // attempt to re-establish
                        Task { [weak self] in
                            try? await self?.ensureWebSocket()
                        }
                    }
                    continue
                }
            }
        }
    }

    /// Send a WebSocket request and wait for the matching response
    /// Public entry point for the Remote Agent Harness (Plan N) to issue `agent.*` requests over the
    /// same WebSocket transport. A thin pass-through to `sendRequest` so the harness adapter doesn't
    /// reach into the bridge's internals.
    func agentRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await sendRequest(method: method, params: params)
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await ensureWebSocket()
        guard let task = webSocketTask else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "No WebSocket"])
        }

        let reqId = UUID().uuidString
        let msg: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: msg)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenClaw", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid request encoding"])
        }
        try await task.send(.string(payload))

        // Wait for response with timeout
        let responseText: String = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[reqId] = continuation

            // Timeout after 120s
            Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await MainActor.run {
                    if let cont = self.pendingResponses.removeValue(forKey: reqId) {
                        cont.resume(throwing: NSError(domain: "OpenClaw", code: -3, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
                    }
                }
            }
        }

        guard let responseData = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NSError(domain: "OpenClaw", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        if let ok = json["ok"] as? Bool, !ok {
            let message = Self.formatGatewayError(from: json)
            throw NSError(domain: "OpenClaw", code: -7, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return json
    }

    func disconnectWebSocket() {
        wsConnected = false
        webSocketReady = false
        receiveLoopRunning = false
        connectChallengeReceived = false
        connectChallengeNonce = nil
        connectChallengeWaiter?.resume(throwing: NSError(domain: "OpenClaw", code: -5, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        connectChallengeWaiter = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        let disconnectError = NSError(domain: "OpenClaw", code: -5, userInfo: [NSLocalizedDescriptionKey: "Disconnected"])
        for (_, cont) in pendingResponses {
            cont.resume(throwing: disconnectError)
        }
        pendingResponses.removeAll()
        for (_, cont) in pendingRunCompletions {
            cont.resume(throwing: disconnectError)
        }
        pendingRunCompletions.removeAll()
        pendingRunText.removeAll()
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Tool Visibility

    /// Query available tools from the gateway at connect time.
    /// Populates `availableGatewayTools` so the system prompt only references live capabilities.
    private func queryAvailableTools() async {
        guard Config.agentModeEnabled else { return }
        guard !Config.isOpenClawExclusive else { return }  // iMetaClaw doesn't need client-side tools list
        do {
            let response = try await sendRequest(method: "tools.available", params: [:])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let tools = payload["tools"] as? [[String: String]] {
                availableGatewayTools = tools
                NSLog("[OpenClaw] Gateway has %d tools available", tools.count)
            } else {
                // Gateway may not support tools.available — not an error
                NSLog("[OpenClaw] tools.available not supported or empty")
            }
        } catch {
            NSLog("[OpenClaw] tools.available query failed: %@", error.localizedDescription)
        }
    }

    /// Names of tools currently available on the gateway.
    var availableToolNames: [String] {
        availableGatewayTools.compactMap { $0["name"] }
    }

    // MARK: - Cron Job Management

    /// Create a cron job on the gateway. Requires agentModeEnabled.
    func createCronJob(expression: String, task: String, context: String? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        var params: [String: Any] = [
            "expression": expression,
            "task": task
        ]
        if let context { params["context"] = context }
        do {
            let response = try await sendRequest(method: "cron.create", params: params)
            if let ok = response["ok"] as? Bool, ok {
                let payload = response["payload"] as? [String: Any]
                let id = payload?["id"] as? String ?? "unknown"
                NSLog("[OpenClaw] Cron job created: %@", id)
                return .success("Cron job created (id: \(id))")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Cron create failed: \(msg)")
        } catch {
            return .failure("Cron create error: \(error.localizedDescription)")
        }
    }

    /// Update an existing cron job on the gateway.
    func updateCronJob(id: String, expression: String? = nil, task: String? = nil, enabled: Bool? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        var params: [String: Any] = ["id": id]
        if let expression { params["expression"] = expression }
        if let task { params["task"] = task }
        if let enabled { params["enabled"] = enabled }
        do {
            let response = try await sendRequest(method: "cron.update", params: params)
            if let ok = response["ok"] as? Bool, ok {
                return .success("Cron job updated")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Cron update failed: \(msg)")
        } catch {
            return .failure("Cron update error: \(error.localizedDescription)")
        }
    }

    /// Delete a cron job on the gateway.
    func deleteCronJob(id: String) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "cron.delete", params: ["id": id])
            if let ok = response["ok"] as? Bool, ok {
                return .success("Cron job deleted")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Cron delete failed: \(msg)")
        } catch {
            return .failure("Cron delete error: \(error.localizedDescription)")
        }
    }

    /// List cron jobs on the gateway.
    func listCronJobs() async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "cron.list", params: [:])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let jobs = payload["jobs"] as? [[String: Any]] {
                let descriptions = jobs.map { job -> String in
                    let id = job["id"] as? String ?? "?"
                    let expr = job["expression"] as? String ?? "?"
                    let task = job["task"] as? String ?? "?"
                    let enabled = job["enabled"] as? Bool ?? true
                    return "\(enabled ? "+" : "-") [\(id)] \(expr): \(task)"
                }
                return .success(descriptions.joined(separator: "\n"))
            }
            return .success("No cron jobs")
        } catch {
            return .failure("Cron list error: \(error.localizedDescription)")
        }
    }

    // MARK: - Gateway Memory (Embeddings)

    /// Query the gateway's long-term memory via embeddings.
    func queryMemory(query: String, limit: Int = 5) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "memory.query", params: [
                "query": query,
                "limit": limit
            ])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let results = payload["results"] as? [[String: Any]] {
                let texts = results.compactMap { $0["content"] as? String }
                return .success(texts.joined(separator: "\n---\n"))
            }
            return .success("No memory results")
        } catch {
            return .failure("Memory query error: \(error.localizedDescription)")
        }
    }

    /// Store a memory in the gateway's embedding store.
    func storeMemory(content: String, metadata: [String: String]? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        var params: [String: Any] = ["content": content]
        if let metadata { params["metadata"] = metadata }
        do {
            let response = try await sendRequest(method: "memory.store", params: params)
            if let ok = response["ok"] as? Bool, ok {
                return .success("Memory stored")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Memory store failed: \(msg)")
        } catch {
            return .failure("Memory store error: \(error.localizedDescription)")
        }
    }

    // MARK: - Message Routing via Gateway

    /// Route a message through the gateway's channel abstraction.
    func routeMessage(channel: String, recipient: String, message: String) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "channels.send", params: [
                "channel": channel,
                "recipient": recipient,
                "message": message
            ])
            if let ok = response["ok"] as? Bool, ok {
                return .success("Message sent via \(channel)")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Message routing failed: \(msg)")
        } catch {
            return .failure("Message routing error: \(error.localizedDescription)")
        }
    }

    /// List available messaging channels on the gateway.
    func listChannels() async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "channels.list", params: [:])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let channels = payload["channels"] as? [[String: Any]] {
                let names = channels.compactMap { $0["name"] as? String }
                return .success("Available channels: \(names.joined(separator: ", "))")
            }
            return .success("No channels available")
        } catch {
            return .failure("Channel list error: \(error.localizedDescription)")
        }
    }

    // MARK: - Task Delegation

    /// Send a user message to the OpenClaw gateway via WebSocket `chat.send`
    /// (same path as WebChat / Telegram). Optionally attaches a glasses camera JPEG.
    func delegateTask(
        task: String,
        toolName: String = "execute",
        imageData: Data? = nil
    ) async -> ToolResult {
        lastToolCallStatus = .executing(toolName)
        NSLog("[OpenClaw] → Maia session=%@ (%d chars): %@", sessionKey, task.count, String(task.prefix(120)))

        do {
            var attachments: [[String: Any]] = []
            var imageBase64: String?
            if let imageData, Self.isValidVisionImageData(imageData) {
                let b64 = imageData.base64EncodedString()
                imageBase64 = b64
                attachments = [[
                    "type": "image",
                    "mimeType": "image/jpeg",
                    "fileName": "glasses.jpg",
                    "content": b64
                ]]
            }

            var response: [String: Any]
            do {
                response = try await sendAgentMessage(task: task, attachments: attachments, imageBase64: imageBase64)
            } catch {
                NSLog("[OpenClaw] agent RPC error: %@ — trying chat.send", error.localizedDescription)
                response = try await sendChatMessage(task: task, attachments: attachments, imageBase64: imageBase64)
            }
            var ok = response["ok"] as? Bool ?? false
            if !ok {
                NSLog("[OpenClaw] agent RPC failed — trying chat.send")
                response = try await sendChatMessage(task: task, attachments: attachments, imageBase64: imageBase64)
                ok = response["ok"] as? Bool ?? false
            }
            guard ok else {
                let message = Self.formatGatewayError(from: response)
                NSLog("[OpenClaw] gateway send failed: %@", message)
                lastToolCallStatus = .failed(toolName, message)
                return .failure(message)
            }

            let payload = response["payload"] as? [String: Any] ?? [:]
            if let inline = Self.extractAssistantText(from: payload), !inline.isEmpty {
                NSLog("[OpenClaw] chat.send inline result: %@", String(inline.prefix(200)))
                lastToolCallStatus = .completed(toolName)
                return .success(inline)
            }

            guard let runId = payload["runId"] as? String, !runId.isEmpty else {
                lastToolCallStatus = .failed(toolName, "No run id")
                return .failure("Gateway accepted the message but did not start a run.")
            }

            NSLog("[OpenClaw] chat.send dispatched, runId: %@", runId)
            let content = try await waitForRunCompletion(runId: runId)
            NSLog("[OpenClaw] Run complete (%d chars): %@", content.count, String(content.prefix(200)))
            lastToolCallStatus = .completed(toolName)
            return .success(content)
        } catch {
            NSLog("[OpenClaw] Task error: %@", error.localizedDescription)
            disconnectWebSocket()
            lastToolCallStatus = .failed(toolName, error.localizedDescription)
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Chat streaming + completion

    private func waitForRunCompletion(runId: String, timeoutSeconds: UInt64 = 120) async throws -> String {
        if let existing = pendingRunText[runId], !existing.isEmpty {
            pendingRunText.removeValue(forKey: runId)
            return existing
        }

        let text: String = try await withCheckedThrowingContinuation { continuation in
            pendingRunCompletions[runId] = continuation

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard let cont = self.pendingRunCompletions.removeValue(forKey: runId) else { return }

                do {
                    let fallback = try await self.fetchRunResultViaAgentWait(runId: runId)
                    if !fallback.isEmpty {
                        cont.resume(returning: fallback)
                        return
                    }
                    let history = try await self.fetchLastAssistantMessage()
                    if !history.isEmpty {
                        cont.resume(returning: history)
                        return
                    }
                } catch {
                    NSLog("[OpenClaw] Run fallback failed: %@", error.localizedDescription)
                }

                let partial = self.pendingRunText.removeValue(forKey: runId) ?? ""
                if !partial.isEmpty {
                    cont.resume(returning: partial)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "OpenClaw",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(Config.agentName) to respond."]
                    ))
                }
            }
        }
        pendingRunText.removeValue(forKey: runId)
        return text
    }

    private func fetchRunResultViaAgentWait(runId: String) async throws -> String {
        let response = try await sendRequest(method: "agent.wait", params: [
            "runId": runId,
            "timeoutMs": 5_000
        ])
        guard response["ok"] as? Bool == true else { return "" }
        let payload = response["payload"] as? [String: Any] ?? [:]
        return Self.extractAssistantText(from: payload) ?? pendingRunText[runId] ?? ""
    }

    private func fetchLastAssistantMessage() async throws -> String {
        let response = try await sendRequest(method: "chat.history", params: [
            "sessionKey": sessionKey,
            "limit": 8
        ])
        guard response["ok"] as? Bool == true,
              let payload = response["payload"] as? [String: Any],
              let messages = payload["messages"] as? [[String: Any]] else {
            return ""
        }
        for message in messages.reversed() {
            guard (message["role"] as? String) == "assistant" else { continue }
            if let text = Self.extractAssistantText(from: message), !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private func handleStreamingChatPayload(event: String, payload: [String: Any]) {
        if event == "session.message" {
            guard (payload["role"] as? String) == "assistant" else { return }
            if let text = Self.extractAssistantText(from: payload), !text.isEmpty {
                let runId = payload["runId"] as? String ?? "session"
                appendStreamDelta(runId: runId, delta: text)
                if let cont = pendingRunCompletions[runId] {
                    completeRun(runId: runId, text: pendingRunText[runId] ?? text)
                }
            }
            return
        }

        if event == "agent" {
            if let stream = payload["stream"] as? String, stream == "assistant",
               let data = payload["data"] as? [String: Any] {
                if let delta = data["delta"] as? String, !delta.isEmpty {
                    appendStreamDelta(runId: payload["runId"] as? String, delta: delta)
                } else if let text = data["text"] as? String, !text.isEmpty {
                    appendStreamDelta(runId: payload["runId"] as? String, delta: text)
                }
            }
            return
        }

        guard let runId = payload["runId"] as? String else { return }
        let state = payload["state"] as? String ?? ""

        switch state {
        case "delta":
            if let delta = payload["deltaText"] as? String, !delta.isEmpty {
                appendStreamDelta(runId: runId, delta: delta)
            } else if let message = payload["message"] as? [String: Any],
                      let text = Self.extractAssistantText(from: message) {
                appendStreamDelta(runId: runId, delta: text)
            }
        case "final":
            let text = Self.extractAssistantText(from: payload["message"] as? [String: Any])
                ?? pendingRunText[runId]
                ?? ""
            completeRun(runId: runId, text: text)
        case "aborted":
            let text = pendingRunText[runId] ?? Self.extractAssistantText(from: payload["message"] as? [String: Any]) ?? ""
            completeRun(runId: runId, text: text)
        case "error":
            let message = payload["errorMessage"] as? String ?? "Agent run failed"
            failRun(runId: runId, message: message)
        default:
            if let chunk = payload["text"] as? String ?? payload["content"] as? String {
                appendStreamDelta(runId: runId, delta: chunk)
            }
        }
    }

    private func appendStreamDelta(runId: String?, delta: String) {
        guard !delta.isEmpty else { return }
        if let runId {
            pendingRunText[runId, default: ""] += delta
        }
        onStreamChunk?(delta)
    }

    private func completeRun(runId: String, text: String) {
        pendingRunText[runId] = text
        if let cont = pendingRunCompletions.removeValue(forKey: runId) {
            cont.resume(returning: text)
        }
    }

    private func failRun(runId: String, message: String) {
        pendingRunText.removeValue(forKey: runId)
        if let cont = pendingRunCompletions.removeValue(forKey: runId) {
            cont.resume(throwing: NSError(
                domain: "OpenClaw",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }

    private static func extractAssistantText(from value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let dict as [String: Any]:
            return extractAssistantText(from: dict)
        case let array as [Any]:
            let parts = array.compactMap { extractAssistantText(from: $0) }
            let joined = parts.joined()
            return joined.isEmpty ? nil : joined
        default:
            return nil
        }
    }

    private static func extractAssistantText(from payload: [String: Any]) -> String? {
        if let content = payload["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let text = payload["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let message = payload["message"] {
            return extractAssistantText(from: message)
        }
        if let contentBlocks = payload["content"] as? [[String: Any]] {
            let parts = contentBlocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = parts.joined()
            return joined.isEmpty ? nil : joined
        }
        if let result = payload["result"] {
            return extractAssistantText(from: result)
        }
        return nil
    }

    private func sendChatMessage(task: String, attachments: [[String: Any]], imageBase64: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [
            "sessionKey": sessionKey,
            "message": task,
            "thinking": "off",
            "timeoutMs": 120_000,
            "idempotencyKey": UUID().uuidString
        ]
        if let b64 = imageBase64 {
            params["imageBase64"] = b64
        }
        if !attachments.isEmpty {
            params["attachments"] = attachments
        }
        return try await sendRequest(method: "sessions.send", params: params)
    }

    private func storeDeviceTokenIfPresent(from connectResponse: [String: Any]) {
        let auth = (connectResponse["payload"] as? [String: Any])?["auth"] as? [String: Any]
            ?? connectResponse["auth"] as? [String: Any]
        guard let token = auth?["deviceToken"] as? String, !token.isEmpty else { return }
        KeychainService.setString(token, for: "openClawDeviceToken")
        NSLog("[OpenClaw] Stored device token for future handshakes")
    }

    private func sendAgentMessage(task: String, attachments: [[String: Any]], imageBase64: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [
            "message": task,
            "sessionKey": sessionKey,
            "deliver": true,
            "timeout": 120,
            "idempotencyKey": UUID().uuidString
        ]
        if let b64 = imageBase64 {
            params["imageBase64"] = b64
        }
        if !attachments.isEmpty {
            params["attachments"] = attachments
        }
        return try await sendRequest(method: "agent", params: params)
    }

    /// Lightweight guard against degenerate images (1x1 placeholders etc.) that can be
    /// produced when the glasses camera stream is not yet delivering real frames.
    /// Sending these causes Anthropic 400 errors and poisons the agent's context.
    static func isValidVisionImageData(_ data: Data?) -> Bool {
        guard let data = data, data.count > 4_000 else { return false }
        guard let img = UIImage(data: data) else { return false }
        return img.size.width >= 80 && img.size.height >= 80
    }

    /// Handle inbound req from the gateway (for bidirectional glasses control from Maia).
    /// Supports node.invoke so Maia on VPS can initiate actions on the glasses (take photo, record, translate etc).
    private func handleIncomingRequest(method: String, params: [String: Any]) async -> [String: Any] {
        NSLog("[OpenClaw] Inbound req: %@ params: %@", method, String(describing: params))

        if method == "node.invoke" {
            let node = params["node"] as? String ?? ""
            let action = params["action"] as? String ?? params["command"] as? String ?? ""
            let payload = params["payload"] as? [String: Any] ?? params

            // Broad match so Maia can drive any glasses action (capture, record, translate, transcribe, status, stop/pare)
            let a = action.lowercased()
            if node == "glasses" || node.isEmpty ||
               a.contains("photo") || a.contains("record") || a.contains("video") ||
               a.contains("translate") || a.contains("transcribe") || a.contains("status") ||
               a.contains("note") || a.contains("stop") || a.contains("pare") || a.contains("para") {
                return await handleGlassesAction(action: action, payload: payload)
            }
            return ["ok": false, "payload": ["error": "Unknown node: \(node)"]]
        }

        return ["ok": false, "payload": ["error": "Unsupported inbound method: \(method)"]]
    }

    private func handleGlassesAction(action: String, payload: [String: Any]) async -> [String: Any] {
        let a = action.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        do {
            switch a {
            // PHOTO / VISION (already works end-to-end)
            case "capture_photo", "take_photo", "photo", "tira_uma_foto", "tira_foto", "o_que_voce_ve", "que_que_e_isso":
                guard let cam = cameraService else {
                    return ["ok": false, "payload": ["error": "No camera service"]]
                }
                let imageData = try await cam.capturePhoto()
                let b64 = imageData.base64EncodedString()
                // IMPORTANT: return imageBase64 so Maia can see (and validate server-side)
                return ["ok": true, "payload": ["imageBase64": b64, "mimeType": "image/jpeg", "size": imageData.count]]

            // AUDIO RECORD (grava áudio / anota isso) + transcript on stop
            case "start_recording", "record_audio", "start_audio", "grava_um_audio", "grava_audio", "anota_isso", "grava_nota":
                guard let rec = audioRecordingService else {
                    return ["ok": false, "payload": ["error": "No audio service"]]
                }
                try rec.startRecording()
                return ["ok": true, "payload": ["status": "recording_started"]]

            case "stop_recording", "stop_audio", "para_de_gravar", "para_audio", "para_gravacao", "stop_audio":
                guard let rec = audioRecordingService else {
                    return ["ok": false, "payload": ["error": "No audio service"]]
                }
                if let url = await rec.stopRecording() {
                    return ["ok": true, "payload": ["status": "stopped", "url": url.absoluteString, "transcript": rec.recordingTranscript]]
                }
                return ["ok": true, "payload": ["status": "stopped"]]

            // VIDEO RECORD (grava vídeo) — no hard time limit, muxes audio+video
            case "start_video", "record_video", "grava_um_video", "grava_video", "comeca_a_gravar", "inicia_video", "comeca_gravar":
                guard let vid = videoRecorder, let cam = cameraService else {
                    return ["ok": false, "payload": ["error": "No video or camera service"]]
                }
                if !cam.isStreaming {
                    try await cam.startStreaming()
                }
                let frameSize = cam.latestFrame?.size ?? CGSize(width: 720, height: 1280)
                let bitrate = 1_500_000
                try vid.startRecording(from: cam.framePublisher, bitrate: bitrate, outputSize: frameSize)
                return ["ok": true, "payload": ["status": "video_recording_started", "note": "No time limit until stop. Includes audio."]]

            case "stop_video", "para_o_video", "para_video", "stop_recording_video":
                guard let vid = videoRecorder else {
                    return ["ok": false, "payload": ["error": "No video service"]]
                }
                if let url = await vid.stopRecording() {
                    return ["ok": true, "payload": ["status": "stopped", "url": url.absoluteString]]
                }
                return ["ok": true, "payload": ["status": "stopped"]]

            // LIVE TRANSLATION (modo tradução) — speaks translations via on-device + TTS
            case "translate", "translate_live", "start_translation", "modo_traducao", "traduz_pro_ingles", "traduz", "traduzir":
                guard let lt = liveTranslationService else {
                    return ["ok": false, "payload": ["error": "No live translation service"]]
                }
                let source = payload["source"] as? String ?? payload["from"] as? String ?? "auto"
                let target = payload["target"] as? String ?? payload["to"] as? String ?? "en"
                lt.start(from: source, to: target)
                return ["ok": true, "payload": ["status": "translation_started", "source": source, "target": target]]

            case "stop_translation", "stop_translate", "para_traducao", "para_traduzir", "para_tradução":
                if let lt = liveTranslationService, lt.isActive {
                    lt.stop()
                }
                return ["ok": true, "payload": ["status": "translation_stopped"]]

            // TRANSCRIBE / MEETING / CONSULTA (transcreve reunião, transcreve consulta)
            // Starts ambient live captions (no file save by default; transcript collected)
            case "start_transcribe", "transcribe_start", "modo_reuniao", "transcreve_isso", "transcreve_reuniao", "transcreve_consulta", "start_meeting", "start_consulta", "transcreve":
                guard let cap = ambientCaptionService else {
                    return ["ok": false, "payload": ["error": "No ambient caption service"]]
                }
                if !cap.isActive {
                    cap.start()
                }
                let mode = a.contains("consulta") ? "consulta" : (a.contains("reuniao") ? "reuniao" : "transcribe")
                return ["ok": true, "payload": ["status": "transcribing_started", "mode": mode]]

            case "stop_transcribe", "transcribe_stop", "encerra_reuniao", "encerra_consulta", "encerra", "para_transcricao", "para_transcreve", "stop_meeting":
                if let cap = ambientCaptionService, cap.isActive {
                    cap.stop()
                }
                return ["ok": true, "payload": ["status": "transcribing_stopped"]]

            // STATUS / BATTERY (quanto de bateria?)
            case "status", "quanto_de_bateria", "quanto_bateria", "estado", "get_status", "bateria":
                UIDevice.current.isBatteryMonitoringEnabled = true
                var p: [String: Any] = [
                    "connected": isConnected,
                    "ws_ready": webSocketReady,
                    "audio_recording": audioRecordingService?.isRecording ?? false,
                    "video_recording": videoRecorder?.isRecording ?? false,
                    "translation_active": liveTranslationService?.isActive ?? false,
                    "caption_active": ambientCaptionService?.isActive ?? false,
                    "glasses_streaming": cameraService?.isStreaming ?? false
                ]
                let bat = UIDevice.current.batteryLevel
                if bat >= 0 {
                    p["battery_level"] = Int(bat * 100)
                    p["battery_unit"] = "% (iPhone)"
                } else {
                    p["battery_level"] = "unknown"
                }
                p["note"] = "Glasses battery not directly readable here — check Meta View app. Use 'pare' to stop any active mode."
                return ["ok": true, "payload": p]

            // GENERIC STOP / PARE (the pattern you described: "pare", "para xxx", "quando acabar fala pare")
            case "stop", "pare", "para", "para_tudo", "stop_all", "encerra_tudo", "para_xxx":
                await stopAllActive()
                return ["ok": true, "payload": ["status": "stopped_all_active_modes"]]

            // NOTES (from Maia or for later)
            case "add_note", "save_note":
                let note = payload["note"] as? String ?? payload["text"] as? String ?? ""
                NSLog("[OpenClaw] Note from Maia: %@", note)
                return ["ok": true, "payload": ["status": "note_received", "length": note.count]]

            case "get_transcript", "get_notes":
                let fromCaptions = ambientCaptionService?.captionHistory.map(\.text).joined(separator: " ") ?? ""
                let fromAudio = audioRecordingService?.recordingTranscript ?? ""
                let tx = fromCaptions.isEmpty ? fromAudio : fromCaptions
                return ["ok": true, "payload": ["transcript": tx, "source": fromCaptions.isEmpty ? "audio" : "captions"]]

            default:
                return ["ok": false, "payload": ["error": "Unknown glasses action: \(action)"]]
            }
        } catch {
            return ["ok": false, "payload": ["error": error.localizedDescription]]
        }
    }

    private func stopAllActive() async {
        if let rec = audioRecordingService, rec.isRecording {
            _ = await rec.stopRecording()
        }
        if let vid = videoRecorder, vid.isRecording {
            _ = await vid.stopRecording()
        }
        if let lt = liveTranslationService, lt.isActive {
            lt.stop()
        }
        if let cap = ambientCaptionService, cap.isActive {
            cap.stop()
        }
        // Note: transcriptionService if separately started can be added here too
    }

    private static func formatGatewayError(from response: [String: Any]) -> String {
        let error = response["error"] as? [String: Any]
        let code = error?["code"]
        let message = (error?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Unknown gateway error"
        let codeText: String = {
            switch code {
            case let number as Int: return "\(number)"
            case let text as String: return text
            default: return ""
            }
        }()

        let lower = message.lowercased()
        if lower.contains("pairing") || lower.contains("device identity") || lower.contains("device required") {
            return "iPhone precisa de aprovação no VPS. Verifique o contrato e tokens em /opt/maia/.env"
        }
        if lower.contains("missing scope") || lower.contains("operator.write") || lower.contains("scope") {
            return "Sem permissão. Verifique o contrato do node.invoke"
        }
        if lower.contains("unauthorized") || lower.contains("invalid token") {
            return "Token do gateway inválido. Use OPENCLAW_TOKEN de /opt/maia/.env"
        }
        if !codeText.isEmpty {
            return "\(message) (código \(codeText))"
        }
        return message
    }
}
