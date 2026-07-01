import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Ed25519 device identity for remote OpenClaw gateway handshakes.
/// Without this, token-only connects get zero scopes and `chat.send` never reaches the agent.
enum OpenClawDeviceIdentity {
    private static let privateKeyKeychainKey = "openClawDeviceEd25519PrivateKey"

    struct Identity {
        let deviceId: String
        let publicKeyBase64URL: String
        let privateKey: Curve25519.Signing.PrivateKey
    }

    static func loadOrCreate() -> Identity {
        if let stored = KeychainService.data(for: privateKeyKeychainKey),
           stored.count == 32,
           let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) {
            let publicKey = privateKey.publicKey
            let rawPublic = publicKey.rawRepresentation
            return Identity(
                deviceId: sha256Hex(rawPublic),
                publicKeyBase64URL: base64URLEncode(rawPublic),
                privateKey: privateKey
            )
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        _ = KeychainService.setData(privateKey.rawRepresentation, for: privateKeyKeychainKey)
        let rawPublic = privateKey.publicKey.rawRepresentation
        return Identity(
            deviceId: sha256Hex(rawPublic),
            publicKeyBase64URL: base64URLEncode(rawPublic),
            privateKey: privateKey
        )
    }

    /// Build the `device` object for a `connect` request (required for remote VPS gateways).
    static func connectDevice(
        token: String,
        nonce: String,
        clientId: String = "cli",
        clientMode: String = "ui",
        role: String = "operator",
        scopes: [String] = ["operator.read", "operator.write"]
    ) -> [String: Any]? {
        let identity = loadOrCreate()
        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let payload = buildPayloadV3(
            deviceId: identity.deviceId,
            clientId: clientId,
            clientMode: clientMode,
            role: role,
            scopes: scopes,
            signedAtMs: signedAtMs,
            token: token,
            nonce: nonce
        )
        guard let signature = try? identity.privateKey.signature(for: Data(payload.utf8)) else {
            return nil
        }
        return [
            "id": identity.deviceId,
            "publicKey": identity.publicKeyBase64URL,
            "signature": base64URLEncode(signature),
            "signedAt": signedAtMs,
            "nonce": nonce
        ]
    }

    private static func buildPayloadV3(
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String,
        nonce: String
    ) -> String {
        let platform = normalizeMetadata("ios")
        let deviceFamily = normalizeMetadata(deviceFamilyLabel())
        return [
            "v3",
            deviceId,
            clientId,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token,
            nonce,
            platform,
            deviceFamily
        ].joined(separator: "|")
    }

    private static func normalizeMetadata(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func deviceFamilyLabel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        return "iphone"
        #endif
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}