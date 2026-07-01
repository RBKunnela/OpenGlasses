import Foundation

/// Picks the best `SFSpeechRecognizer` locale for wake word + transcription.
enum SpeechRecognitionLocale {
    /// Brazilian Portuguese when the wake phrase is "Oi …" or the device prefers Portuguese.
    static var preferredIdentifier: String {
        let phrase = Config.wakePhrase.lowercased()
        if phrase.hasPrefix("oi ") || phrase.hasPrefix("oy ") {
            return "pt-BR"
        }
        if let code = Locale.preferredLanguages.first?.lowercased(),
           code.hasPrefix("pt") {
            return "pt-BR"
        }
        return "en-US"
    }

    static var locale: Locale {
        Locale(identifier: preferredIdentifier)
    }
}