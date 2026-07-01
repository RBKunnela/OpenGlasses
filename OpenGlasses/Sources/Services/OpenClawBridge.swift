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
    /// Terminal state: reconnect attempts exhausted (see `maxReconnectAttempts`).
    /// Distinct from `.unreachable` (transient, still retrying) — no further
    /// automatic reconnect will be scheduled until an explicit reconnect.
    case error(String)
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
    var glassesDisplayService: GlassesDisplayService?

    /// Optional callback to speak text (for "speak" action from Maia).
    var onSpeak: ((String) -> Void)?

    /// Returns the list of actions this device currently supports, based on hardware (via official MWDAT SDK).
    /// Used for device.capabilities handshake and degradation logic on Maia.
    private func currentGlassesCapabilities() -> [String] {
        var caps: [String] = [
            "capture_photo",
            "record_audio", "stop_audio",
            "start_video", "stop_video",
            "translate", "stop_translation",
            "transcribe_start", "transcribe_stop",
            "status", "stop", "pare"
        ]

        // Display / lens HUD only if the connected glasses report support
        if let disp = glassesDisplayService, disp.deviceSupportsDisplay() {
            caps.append(contentsOf: ["display_show", "display_clear", "display_caption_start", "display_caption_stop"])
        }

        // Audio play/speak is always available via speakers (even if no "display")
        caps.append("speak")

        return caps
    }

    /// Bridge-level connection for inbound commands (node.invoke etc). WS handshake success.
    var isConnected: Bool {
        connectionState == .connected || webSocketReady || wsConnected
    }

    /// Strict ready for Maia/OpenClaw voice and node.invoke — requires live WS with recent activity.
    var isMaiaReady: Bool {
        connectionState == .connected &&
        webSocketReady &&
        Date().timeIntervalSince(lastSuccessfulSend) < 30
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
    private var reconnectTask: Task<Void, Never>?
    private var lastConnectionAttempt = Date.distantPast
    private var reconnectBackoffSeconds: TimeInterval = 2.0
    @Published private var lastSuccessfulSend = Date()
    private var shouldReconnect = true
    /// Consecutive WebSocket failures since the last successful connect.
    /// After a few in a row we drop the cached endpoint so the next resolve
    /// re-probes from scratch and never gets stuck on a bad candidate (B1).
    private var consecutiveWSFailures = 0
    private static let maxWSFailuresBeforeEndpointReset = 3
    /// Reconnect attempts since the last successful connect. Capped by
    /// `maxReconnectAttempts` so an accept-then-drop (e.g. a 401 that closes the
    /// socket right after opening) can't cause an infinite reconnect storm on the
    /// wearable. Reset to 0 on every successful connect. Matches the peers
    /// (`GeminiLiveService` / `OpenAIRealtimeService`).
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10

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
                        Self.redactToken(in: url.absoluteString),
                        style.label,
                        http.statusCode,
                        String(body.prefix(100))
                    )
                    if (200...299).contains(http.statusCode) {
                        return .success(workingBase: workingBase, lastURL: Self.redactToken(in: url.absoluteString))
                    }
                    lastHTTPDetail = "HTTP \(http.statusCode) (\(style.label)) em \(url.host ?? url.absoluteString)"
                    lastHTTPBase = workingBase
                }
            } catch {
                lastNetworkDetail = "\(url.host ?? Self.redactToken(in: url.absoluteString)): \(friendlyNetworkError(error))"
                NSLog("[OpenClaw] Health %@ (%@) failed: %@", Self.redactToken(in: url.absoluteString), style.label, error.localizedDescription)
            }
        }

        if gotHTTPResponse {
            return .serverResponded(
                detail: lastHTTPDetail,
                lastURL: Self.redactToken(in: requests.last?.url.absoluteString ?? endpoint),
                workingBase: lastHTTPBase
            )
        }

        let triedHosts = Set(GatewayEndpoint.candidateBases(from: endpoint)).joined(separator: ", ")
        let detail = lastNetworkDetail.isEmpty
            ? "Sem resposta do servidor. Tentou: \(triedHosts)"
            : "\(lastNetworkDetail). Tentou: \(triedHosts)"
        return .networkFailure(detail: detail, lastURL: Self.redactToken(in: requests.last?.url.absoluteString ?? endpoint))
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
        // In iMetaClaw exclusive mode prioritize one persistent socket.
        // Only allow a new check if we don't have a healthy live task.
        if isConnecting || (wsConnected && webSocketTask != nil && webSocketTask?.closeCode == .invalid) {
            return
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

    /// Redact any auth token from a URL before logging (H5). Strips/masks
    /// `token`/`access_token`/`key` query items so secrets never reach
    /// NSLog / console / crash logs.
    static func redactToken(in urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let items = components.queryItems, !items.isEmpty else { return urlString }
        let sensitive: Set<String> = ["token", "access_token", "auth", "key", "api_key"]
        components.queryItems = items.map { item in
            sensitive.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "***")
                : item
        }
        return components.url?.absoluteString ?? urlString
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
                "displayName": "iMetaClaw",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                "platform": "ios",
                "mode": "node"  // per contract for glasses node
            ] as [String: Any],
            "policy": [
                "tickIntervalMs": 15000
            ] as [String: Any],
            // device.capabilities for handshake per contract (Maia uses to degrade)
            "deviceCapabilities": ["capture_photo", "see", "record_audio", "stop_audio", "start_video", "stop_video", "start_translation", "stop_translation", "transcribe_start", "transcribe_stop", "status", "speak", "display_show", "display_clear", "display_caption_start", "display_caption_stop"] as [String],
            "auth": ["token": token],
            "locale": Locale.current.identifier,
            "userAgent": "iMetaClaw/ios"
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
        // Strong guard: if we have a live task that is not closed, trust it
        if let task = webSocketTask, task.closeCode == .invalid, wsConnected {
            return
        }
        if isConnecting { return }

        // Exponential-ish backoff to avoid reconnect storm (6s drops were causing rapid attempts)
        let sinceLast = Date().timeIntervalSince(lastConnectionAttempt)
        if sinceLast < reconnectBackoffSeconds {
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

        NSLog("[OpenClaw] WS connecting to %@", Self.redactToken(in: url.absoluteString))
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
        self.reconnectBackoffSeconds = 2.0  // reset after successful res
        self.shouldReconnect = true
        self.consecutiveWSFailures = 0  // healthy link — clear failure streak
        self.reconnectAttempts = 0  // healthy link — clear reconnect-attempt cap counter

        // Restore high-level state if it was marked unreachable due to previous drop
        if self.connectionState != .connected {
            self.connectionState = .connected
        }

        NSLog("[OpenClaw] WS connected as operator (chat.send ready)")

        // Push initial device.event for connection (per contract)
        sendDeviceEvent(type: "connection", payload: ["status": "connected", "ws_ready": true])

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
        // H4: do NOT reset reconnectBackoffSeconds here. The backoff base is owned
        // by the connect site (set to 2.0 on successful connect, ~line 628) and the
        // disconnect path (reset on teardown). Resetting it to 1.0 here clobbered
        // the 2.0 base set moments earlier at connect time, so the H4 precedence fix
        // never actually held.
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s official tick to match server policy and prevent 30s client close
                guard let self = self,
                      !Task.isCancelled,
                      let task = self.webSocketTask else { break }

                // Control frame ping
                task.sendPing { [weak self] error in
                    if let error = error {
                        NSLog("[OpenClaw] WS ping failed: %@", error.localizedDescription)
                    } else {
                        self?.lastSuccessfulSend = Date()
                    }
                }

                // Lightweight application-level activity to keep Caddy/Maia WS happy (proxies often ignore pure pings)
                if self.wsConnected {
                    let hb: [String: Any] = [
                        "type": "req",
                        "id": UUID().uuidString,
                        "method": "sessions.ping",
                        "params": ["t": Int(Date().timeIntervalSince1970)]
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: hb),
                       let str = String(data: data, encoding: .utf8) {
                        try? await task.send(.string(str))
                        self.lastSuccessfulSend = Date()
                    }
                }
            }
        }
    }

    /// Fire-and-forget device event push to Maia (per contract).
    /// Examples: gesture, battery, wear, connection change.
    func sendDeviceEvent(type: String, payload: [String: Any]) {
        guard wsConnected, let task = webSocketTask else { return }
        let eventMsg: [String: Any] = [
            "type": "event",
            "event": "device.event",
            "payload": [
                "type": type,
                "timestamp": Int(Date().timeIntervalSince1970),
                "data": payload
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: eventMsg),
           let str = String(data: data, encoding: .utf8) {
            Task {
                try? await task.send(.string(str))
                self.lastSuccessfulSend = Date()
                NSLog("[OpenClaw] Sent device.event type=\(type)")
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
        case .error(let reason):
            lines.append("HTTP /health: FALHOU (reconexões esgotadas) — \(reason)")
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

        // H5: never log the auth token. Serialize a redacted copy of the connect
        // message (auth object masked) for the diagnostic log instead of connectJSON.
        var redactedMsg = connectMsg
        if var params = redactedMsg["params"] as? [String: Any] {
            params["auth"] = ["token": "***"]
            redactedMsg["params"] = params
        }
        let redactedLog = (try? JSONSerialization.data(withJSONObject: redactedMsg))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"type\":\"req\",\"method\":\"connect\"}"
        NSLog("[OpenClawWS] Sending connect: %@", String(redactedLog.prefix(500)))
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
                            let isOk = response["ok"] as? Bool ?? false
                            var resMsg: [String: Any] = [
                                "type": "res",
                                "id": id,
                                "ok": isOk
                            ]
                            if isOk {
                                resMsg["payload"] = response["payload"] ?? [:]
                            } else {
                                // per contract, error at top level
                                let errPayload = response["payload"] as? [String: Any] ?? ["message": "unknown error"]
                                resMsg["error"] = errPayload["error"] ?? errPayload
                            }
                            if let data = try? JSONSerialization.data(withJSONObject: resMsg),
                               let str = String(data: data, encoding: .utf8) {
                                try? await self.webSocketTask?.send(.string(str))
                            }
                        }
                    }
                } catch {
                    NSLog("[OpenClaw] WS receive error/close: %@", error.localizedDescription)
                    // The server (or Caddy) closed us — common for idle ~6s or proxy timeouts.
                    // Force the task dead so next ensure creates a fresh one.
                    let wasTask = self.webSocketTask
                    self.webSocketTask = nil
                    self.wsConnected = false
                    self.webSocketReady = false

                    // Reflect that the live link for Maia is down
                    if self.connectionState == .connected {
                        self.connectionState = .unreachable("WebSocket dropped, reconnecting...")
                    }

                    await MainActor.run {
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

                    if self.shouldReconnect {
                        // H3: cap reconnect attempts (match the peers — Gemini/OpenAI use 10).
                        // An accept-then-drop (e.g. a 401 that closes the socket right after
                        // opening) would otherwise loop here forever, hammering the gateway and
                        // draining the wearable. When the cap is hit, stop auto-reconnecting and
                        // surface a terminal error state.
                        self.reconnectAttempts += 1
                        guard self.reconnectAttempts <= self.maxReconnectAttempts else {
                            NSLog("[OpenClaw] Max reconnect attempts (%d) reached — giving up", self.maxReconnectAttempts)
                            self.shouldReconnect = false
                            self.reconnectTask?.cancel()
                            self.connectionState = .error("Connection lost after \(self.maxReconnectAttempts) reconnect attempts")
                            continue
                        }

                        // VisionClaw style: exponential backoff 2s base, ×2, cap 30s
                        self.reconnectBackoffSeconds = min(30.0, self.reconnectBackoffSeconds * 2.0)

                        // B1: after repeated failures, drop the cached endpoint so the
                        // next resolve re-probes all candidates fresh instead of staying
                        // pinned to a bad base (e.g. a stale internal :3600 candidate).
                        self.consecutiveWSFailures += 1
                        if self.consecutiveWSFailures >= Self.maxWSFailuresBeforeEndpointReset {
                            NSLog("[OpenClaw] %d consecutive WS failures — clearing cached endpoint to force re-resolve", self.consecutiveWSFailures)
                            self.cachedEndpoint = nil
                            self.consecutiveWSFailures = 0
                        }

                        NSLog("[OpenClaw] Scheduling reconnect in %.1fs (backoff, VisionClaw style)", self.reconnectBackoffSeconds)

                        self.reconnectTask?.cancel()
                        self.reconnectTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: UInt64((self?.reconnectBackoffSeconds ?? 2) * 1_000_000_000))
                            guard let self = self, !Task.isCancelled else { return }
                            if self.shouldReconnect {
                                try? await self.ensureWebSocket()
                            }
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

        // Push device.event for disconnect
        sendDeviceEvent(type: "connection", payload: ["status": "disconnected"])
        connectChallengeWaiter = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        reconnectBackoffSeconds = 1.0
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
               a.contains("note") || a.contains("stop") || a.contains("pare") || a.contains("para") ||
               a == "device.capabilities" || a.contains("display") {
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
            case "capture_photo", "take_photo", "photo", "tira_uma_foto", "tira_foto", "o_que_voce_ve", "que_que_e_isso", "see":
                guard let cam = cameraService else {
                    return ["ok": false, "payload": ["error": "No camera service"]]
                }
                let imageData = try await cam.capturePhoto()
                let b64 = imageData.base64EncodedString()
                var width = 0
                var height = 0
                if let img = UIImage(data: imageData) {
                    width = Int(img.size.width)
                    height = Int(img.size.height)
                }
                // IMPORTANT: real frame only, per contract (no poison)
                return ["ok": true, "payload": ["imageBase64": b64, "width": width, "height": height, "mimeType": "image/jpeg"]]

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
                    // Local to iPhone only (Documents/Recordings) — not sent to Meta or VPS
                    return ["ok": true, "payload": ["status": "stopped", "location": "iPhone local (Files app)", "note": "Recording stays on iPhone as extension, not uploaded."]]
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
                    // Local to iPhone only — not to Meta
                    return ["ok": true, "payload": ["status": "stopped", "location": "iPhone Documents/Recordings (Files)", "note": "Long recording saved locally on iPhone."]]
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
                glassesDisplayService?.clear()
                return ["ok": true, "payload": ["status": "stopped_all_active_modes"]]

            // DISPLAY / LENS HUD (full use of in-lens overlay on supported Display glasses)
            case "show_text", "push_display", "display_text", "show_on_lens", "show_overlay":
                guard let disp = glassesDisplayService else {
                    return ["ok": false, "payload": ["error": "No display service (glasses may not support in-lens HUD)"]]
                }
                let text = payload["text"] as? String ?? payload["body"] as? String ?? payload["message"] as? String ?? ""
                let title = payload["title"] as? String
                let iconRaw = (payload["icon"] as? String ?? "info").lowercased()
                let icon: GlassesDisplayService.HUDIcon = {
                    switch iconRaw {
                    case "success", "check": return .success
                    case "warning", "warn": return .warning
                    case "error": return .error
                    case "navigation", "nav", "compass": return .navigation
                    case "hazard": return .hazard
                    case "calendar": return .calendar
                    case "location": return .location
                    case "reminder", "bell": return .reminder
                    case "message": return .message
                    default: return .info
                    }
                }()
                let duration = payload["duration"] as? TimeInterval ?? (payload["transient"] as? Bool == true ? 5 : 0)
                if duration > 0 {
                    disp.showNotification(title: title, body: text, icon: icon, duration: duration)
                } else {
                    disp.showText(text)  // or showNotification for title support
                    if let t = title { /* title is secondary in simple showText */ }
                }
                return ["ok": true, "payload": ["status": "display_updated", "text": text]]

            case "clear_display", "clear_lens", "clear_hud", "hide_overlay":
                glassesDisplayService?.clear()
                return ["ok": true, "payload": ["status": "display_cleared"]]

            case "show_notification":
                guard let disp = glassesDisplayService else { return ["ok": false, "payload": ["error": "No display service"]] }
                let title = payload["title"] as? String
                let body = payload["body"] as? String ?? payload["text"] as? String ?? ""
                let iconRaw = (payload["icon"] as? String ?? "info").lowercased()
                let icon: GlassesDisplayService.HUDIcon = iconRaw == "success" ? .success : (iconRaw == "warning" ? .warning : .info)
                let dur = payload["duration"] as? TimeInterval ?? 5
                disp.showNotification(title: title, body: body, icon: icon, duration: dur)
                return ["ok": true, "payload": ["status": "notification_shown"]]

            // SPEAK / PLAY AUDIO from agent (beyond normal response)
            case "speak", "play_audio", "say", "tts":
                let textToSpeak = payload["text"] as? String ?? payload["message"] as? String ?? ""
                if !textToSpeak.isEmpty {
                    NSLog("[OpenClaw] Maia speak proactive: %@", textToSpeak)
                    if let speak = onSpeak, !textToSpeak.isEmpty {
                        speak(textToSpeak)
                    }
                    return ["ok": true, "payload": ["spoken": true]]
                }
                return ["ok": false, "payload": ["error": "No text to speak"]]

            // ENHANCED STATUS (includes display, more states) per contract
            case "status", "quanto_de_bateria", "quanto_bateria", "estado", "get_status", "bateria", "get_glasses_status":
                UIDevice.current.isBatteryMonitoringEnabled = true
                var p: [String: Any] = [
                    "battery": UIDevice.current.batteryLevel >= 0 ? Int(UIDevice.current.batteryLevel * 100) : nil,
                    "recording": audioRecordingService?.isRecording ?? videoRecorder?.isRecording ?? false,
                    "translating": liveTranslationService?.isActive ?? false,
                    "transcribing": ambientCaptionService?.isActive ?? false,
                    "camera": (cameraService?.isStreaming ?? false) ? "ready" : "busy"
                ]
                if let disp = glassesDisplayService {
                    p["display"] = disp.hasDisplayCapability
                }
                return ["ok": true, "payload": p]

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

            // device.capabilities — report what this hardware actually supports (for Maia degradation logic)
            case "device.capabilities", "get_capabilities":
                let caps = currentGlassesCapabilities()
                var payload: [String: Any] = [
                    "actions": caps,
                    "model": "rayban_meta", // or detect better
                    "sdk_version": "0.7+",
                    "has_display": glassesDisplayService?.hasDisplayCapability ?? false,
                    "has_camera": true,
                    "has_mic": true,
                    "has_speakers": true
                ]
                return ["ok": true, "payload": payload]

            // Display actions per new contract (map to existing display service)
            case "display_show", "show_text", "push_display", "display_text", "show_on_lens", "show_overlay":
                guard let disp = glassesDisplayService, disp.deviceSupportsDisplay() else {
                    return ["ok": false, "payload": ["error": "Display not supported on this hardware", "degradation": "use speak or transcribe instead"]]
                }
                let text = payload["text"] as? String ?? payload["body"] as? String ?? ""
                let ttl = payload["ttl_s"] as? TimeInterval ?? 0
                if ttl > 0 {
                    disp.flash(text, duration: ttl)
                } else {
                    disp.showText(text)
                }
                return ["ok": true, "payload": ["status": "display_shown"]]

            case "display_clear", "clear_display", "clear_lens", "clear_hud":
                glassesDisplayService?.clear()
                return ["ok": true, "payload": ["status": "display_cleared"]]

            case "display_caption_start", "start_display_caption":
                guard let cap = ambientCaptionService else { return ["ok": false, "payload": ["error": "No caption service"]] }
                if !cap.isActive { cap.start() }
                // Captions will be pushed via sessions.send with context if Maia subscribes; reuse existing stream
                return ["ok": true, "payload": ["status": "display_caption_started"]]

            case "display_caption_stop", "stop_display_caption":
                ambientCaptionService?.stop()
                return ["ok": true, "payload": ["status": "display_caption_stopped"]]

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
