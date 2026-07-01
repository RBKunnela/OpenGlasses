import Foundation
import MWDATCore

/// Service for connecting to Ray-Ban Meta smart glasses
///
/// IMPORTANT (official limits):
/// - Pairing and full registration require the official Meta AI companion app
///   (Developer Mode must be enabled there).
/// - registrationState must reach 3 for camera/mic capabilities.
/// - Your app is always the middleman; no direct glasses-to-cloud without the phone.
/// - See CameraService.swift for full SDK boundary notes.
///
/// Uses Meta Wearables Device Access Toolkit (MWDAT)
@MainActor
class GlassesConnectionService: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var connectionStatus: String = "Not connected"
    @Published var deviceName: String?
    @Published var batteryLevel: Int?

    private var devicesListenerToken: (any AnyListenerToken)?
    private var connectedDeviceId: DeviceIdentifier?

    init() {
        // Don't call observeDevices() here — Wearables.configure() may not
        // have been called yet (deferred until after onboarding).
        // Call startObserving() explicitly after Wearables is configured.
        if Config.hasCompletedOnboarding {
            observeDevices()
        }
    }

    /// Begin observing connected devices. Call after Wearables.configure().
    func startObserving() {
        guard devicesListenerToken == nil else { return }
        observeDevices()
    }

    private func observeDevices() {
        devicesListenerToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
            Task { @MainActor in
                self?.handleDevicesChanged(deviceIds)
            }
        }
    }

    private func handleDevicesChanged(_ deviceIds: [DeviceIdentifier]) {
        if let firstId = deviceIds.first {
            let device = Wearables.shared.deviceForIdentifier(firstId)
            connectedDeviceId = firstId
            isConnected = true
            deviceName = device?.name
            connectionStatus = "Connected to \(device?.nameOrId() ?? "glasses")"
            // Push device.event for Maia (fire-and-forget)
            // Note: in full app, this would call openClawBridge.sendDeviceEvent if available
            print("[Glasses] device connected event (would push to Maia)")
        } else {
            connectedDeviceId = nil
            isConnected = false
            deviceName = nil
            batteryLevel = nil
            connectionStatus = "Disconnected"
            print("[Glasses] device disconnected event (would push to Maia)")
        }
    }

    func connect() async {
        connectionStatus = "Registering..."
        let stateBefore = Wearables.shared.registrationState
        print("📋 Registration state before: \(stateBefore)")

        do {
            try await Wearables.shared.startRegistration()

            // Poll registration state — user must approve in Meta AI; callback may take ~25s
            var stateAfter = Wearables.shared.registrationState
            let deadline = ContinuousClock.now + .seconds(25)
            while stateAfter.rawValue < 3, ContinuousClock.now < deadline {
                connectionStatus = "Aguardando aprovação no Meta AI… (estado \(stateAfter.rawValue))"
                try? await Task.sleep(nanoseconds: 500_000_000)
                stateAfter = Wearables.shared.registrationState
            }

            if stateAfter.rawValue >= 3 {
                print("✅ Meta registration complete, state: \(stateAfter)")
                connectionStatus = "Waiting for device..."

                // Use full official capabilities now that registered (camera for vision, display for lens HUD, etc.)
                Task {
                    do {
                        // Request main capabilities for "full" use of the registered wearable app (official dev kit)
                        // Camera for vision, display for lens if supported. Audio handled via app engine + Bluetooth.
                        let camStatus = try await Wearables.shared.checkPermissionStatus(.camera)
                        if camStatus != .granted {
                            _ = try await Wearables.shared.requestPermission(.camera)
                        }
                        // Note: additional capabilities (display, sensors) are activated via addStream/addDisplay when hardware supports.
                        // iOS + SDK prompt per type after Meta registration. Single flow in onboarding.
                        // .display etc may not be in this SDK version's Permission enum; camera is the main one for vision.
                        print("[Glasses] Full dev kit capabilities requested post-registration")
                    } catch {
                        print("[Glasses] Additional permission request note: \(error)")
                    }
                }
            } else {
                print("⏳ startRegistration() opened Meta AI; awaiting user approval, state: \(stateAfter)")
                connectionStatus = "Aprove o iMetaClaw no Meta AI e volte ao app"
            }
        } catch {
            print("❌ startRegistration() failed: \(error)")
            connectionStatus = "Connection failed: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        connectedDeviceId = nil
        isConnected = false
        deviceName = nil
        batteryLevel = nil
        connectionStatus = "Disconnected"
    }
}

// MARK: - Errors
enum GlassesError: LocalizedError {
    case connectionFailed(String)
    case notConnected
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .notConnected: return "Glasses not connected"
        case .streamingFailed(let msg): return "Streaming failed: \(msg)"
        }
    }
}
