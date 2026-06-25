import Foundation
import MWDATCore

/// Safe, idempotent entry point for `Wearables.configure()`.
/// The SDK throws `WearablesError.alreadyConfigured` (raw value 1) if called twice in one session.
enum WearablesBootstrap {
    private static var configuredThisSession = false

    static func ensureConfigured() throws {
        if configuredThisSession { return }
        do {
            try Wearables.configure()
            configuredThisSession = true
        } catch let error as WearablesError {
            switch error {
            case .alreadyConfigured:
                configuredThisSession = true
            case .configurationError:
                throw error
            case .internalError:
                throw error
            }
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if let wearablesError = error as? WearablesError {
            switch wearablesError {
            case .alreadyConfigured:
                return ""
            case .configurationError:
                return """
                Configuração Meta inválida. Confira wearables.developer.meta.com: \
                Bundle com.clawglasses.app, Team VF88UK56C3, AppLink clawglasses://.
                """
            case .internalError:
                return "Erro interno do SDK Meta Wearables. Feche e abra o app e tente de novo."
            }
        }
        return error.localizedDescription
    }
}