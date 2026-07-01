import Foundation

/// Normalizes OpenClaw gateway host strings for HTTP health checks and WebSocket URLs.
enum GatewayEndpoint {
    /// NOTE: This deployment uses Maia Command Center on :3600 behind Caddy.
    /// The old 18789 assumption no longer applies here. See SERVER-CONTRACT-FOR-GROK.md.
    private static let defaultGatewayPort = 3600

    /// Canonical Maia host on Hostinger KVM2 — iMetaClaw must use this, not Hermes/KVM4.
    static let defaultMaiaGatewayURL = AppBranding.defaultMaiaGatewayURL

    private static let hermesHostMarkers: [String] = [
        "aicontexteng.com",
        "hermes.aicontexteng.com",
        "srv659320.hstgr.cloud",
        "46.202.189.72",
    ]

    /// True when the endpoint points at Hermes / KVM4 infra (wrong stack for Maia glasses).
    static func isHermesHost(_ endpoint: String) -> Bool {
        let normalized = sanitize(endpoint).lowercased()
        guard !normalized.isEmpty else { return false }
        let host = URLComponents(string: normalized)?.host?.lowercased()
            ?? normalized.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .split(separator: "/").first.map(String.init)?
                .lowercased()
            ?? normalized
        return hermesHostMarkers.contains { marker in
            host == marker || host.hasSuffix(".\(marker)") || host.contains(marker)
        }
    }

    /// True when the endpoint targets the Maia KVM2 host.
    static func isMaiaHost(_ endpoint: String) -> Bool {
        let normalized = sanitize(endpoint).lowercased()
        guard !normalized.isEmpty else { return false }
        let host = URLComponents(string: normalized)?.host?.lowercased() ?? normalized
        return host == "srv753644.hstgr.cloud" || host == "46.202.188.144"
    }

    /// User-facing reason when a Hermes URL is rejected in Maia-only mode.
    static func hermesBlockReason(for endpoint: String) -> String? {
        guard isHermesHost(endpoint) else { return nil }
        return "Este endereço é o Hermes (KVM4). O app dos óculos deve usar Maia no KVM2: \(defaultMaiaGatewayURL)"
    }

    /// Rewrite a mistaken Hermes URL to the Maia default (token must still be Maia's).
    static func preferMaiaEndpoint(_ endpoint: String) -> String {
        isHermesHost(endpoint) ? defaultMaiaGatewayURL : sanitize(endpoint)
    }

    /// Clean user paste (strip `/ws`, trailing slashes, add scheme) → stable HTTP base.
    static func normalizedHTTPBase(_ endpoint: String) -> String {
        sanitize(endpoint)
    }

    /// Ordered base URLs to try when probing a remote VPS (handles missing `:18789`).
    static func candidateBases(from endpoint: String) -> [String] {
        let primary = sanitize(endpoint)
        guard !primary.isEmpty else { return [] }

        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ base: String) {
            let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            candidates.append(trimmed)
        }

        append(primary)

        guard var components = URLComponents(string: primary),
              let host = components.host else {
            return candidates
        }

        let isLAN = looksLikeLANHost(host)

        // Default gateway port (:3600) is the INTERNAL Maia port behind Caddy.
        // It is only reachable on LAN / plain-http deployments. On an external
        // `https://` host it is firewalled (Caddy terminates TLS on :443 and
        // reverse-proxies to 127.0.0.1:3600), so probing it from the device just
        // times out and falsely reports "Maia offline" (B1). Never append :3600
        // for https hosts — the no-port (:443) primary candidate already covers them.
        let allowDefaultPort = (components.scheme != "https")

        // Remote hostname without explicit port → also try default gateway port
        // (LAN / http only; the no-port :443 candidate stays first for https).
        if !isLAN, allowDefaultPort, components.port == nil {
            var withPort = components
            withPort.port = defaultGatewayPort
            if let url = withPort.url {
                append(url.absoluteString)
            }
        }

        // Remote `http://` often fails on iOS ATS — try `https://` too.
        if !isLAN, components.scheme == "http" {
            var https = components
            https.scheme = "https"
            if let url = https.url {
                append(url.absoluteString)
            }
            // Do NOT add :3600 to the https-upgraded candidate — same B1 reason as above.
        }

        return candidates
    }

    static func healthURL(from endpoint: String) -> URL? {
        let normalized = sanitize(endpoint)
        guard !normalized.isEmpty else { return nil }
        return URL(string: "\(normalized)/health")
    }

    static func healthURLCandidates(from endpoint: String) -> [URL] {
        candidateBases(from: endpoint).compactMap { healthURL(from: $0) }
    }

    /// Auth styles to try when probing `/health` (OpenClaw allows unauthenticated health checks).
    enum HealthAuthStyle: Equatable {
        case none
        case bearer
        case headerToken
        case queryToken

        var label: String {
            switch self {
            case .none: return "sem auth"
            case .bearer: return "Bearer"
            case .headerToken: return "x-openclaw-token"
            case .queryToken: return "?token="
            }
        }
    }

    static func healthProbeRequests(from endpoint: String, token: String) -> [(url: URL, style: HealthAuthStyle)] {
        var results: [(URL, HealthAuthStyle)] = []
        var seen = Set<String>()

        func append(_ url: URL, _ style: HealthAuthStyle) {
            let key = "\(url.absoluteString)|\(style.label)"
            guard seen.insert(key).inserted else { return }
            results.append((url, style))
        }

        for base in healthURLCandidates(from: endpoint) {
            append(base, .none)
            guard !token.isEmpty else { continue }
            // Header auth only (H5). The token must never appear in the URL query —
            // it leaks into server/proxy access logs and any URL logging on-device.
            append(base, .bearer)
            append(base, .headerToken)
        }
        return results
    }

    static func applyHealthAuth(_ style: HealthAuthStyle, token: String, to request: inout URLRequest) {
        switch style {
        case .none:
            break
        case .bearer:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .headerToken:
            request.setValue(token, forHTTPHeaderField: "x-openclaw-token")
        case .queryToken:
            break // token already in URL query
        }
    }

    /// WebSocket URL for the gateway. The auth token is NOT placed in the query
    /// string (H5) — it is sent via the `Authorization: Bearer` header by the
    /// bridge when opening the socket. `token` is kept in the signature for
    /// source compatibility but is intentionally ignored here.
    static func webSocketURL(from endpoint: String, token: String = "") -> URL? {
        _ = token
        let wsBase = sanitize(endpoint)
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard !wsBase.isEmpty else { return nil }
        let components = URLComponents(string: "\(wsBase)/ws")
        return components?.url
    }

    static func webSocketURLString(from endpoint: String, token: String = "") -> String {
        webSocketURL(from: endpoint, token: token)?.absoluteString
            ?? "\(sanitize(endpoint).replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://"))/ws"
    }

    /// VPS / tunnel hosts need a signed device identity (not plain LAN).
    static func isRemote(_ endpoint: String) -> Bool {
        let trimmed = sanitize(endpoint)
        guard let host = URLComponents(string: trimmed)?.host else {
            let hostOnly = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
            return !looksLikeLANHost(hostOnly)
        }
        return !looksLikeLANHost(host)
    }

    /// User-facing preview lines for gateway settings.
    static func previewLines(for endpoint: String) -> (health: String, webSocket: String) {
        let base = sanitize(endpoint)
        let health = base.isEmpty ? "—" : "\(base)/health"
        let ws = base.isEmpty ? "—" : "\(base.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://"))/ws"
        return (health, ws)
    }

    // MARK: - Sanitize

    static func sanitize(_ endpoint: String) -> String {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        for suffix in ["/ws", "/health", "/v1/chat/completions"] {
            while trimmed.lowercased().hasSuffix(suffix) {
                trimmed = String(trimmed.dropLast(suffix.count))
            }
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        if !trimmed.contains("://") {
            trimmed = (looksLikeLANHost(trimmed) ? "http://" : "https://") + trimmed
        }

        guard var components = URLComponents(string: trimmed) else {
            return trimmed
        }
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { return trimmed }
        var result = url.absoluteString
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func looksLikeLANHost(_ host: String) -> Bool {
        let hostPart = host.split(separator: ":").first.map(String.init) ?? host
        let lower = hostPart.lowercased()
        if lower.hasSuffix(".local") { return true }
        if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" { return true }
        if lower.hasPrefix("10.") || lower.hasPrefix("192.168.") { return true }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        if lower.hasSuffix(".ts.net") { return true }
        if host.contains(":\(defaultGatewayPort)") { return true }
        return false
    }
}