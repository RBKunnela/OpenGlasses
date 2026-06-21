import AppIntents

/// Conversational Siri intent: speak a question and route it through the full
/// LLM/persona pipeline, then have Siri read the answer back.
///
/// This is the "Hey Siri" entry point that mirrors how third-party projects wake
/// the glasses workflow from Siri (e.g. a Siri Shortcut wrapping an App Intent).
/// Unlike `AskOpenGlassesIntent` — which only starts the microphone — this intent
/// carries the spoken text directly as a parameter, so the user never has to wait
/// for the in-app wake word:
///
///     "Hey Siri, ask OpenGlasses what's the weather"
///     "Hey Siri, ask OpenGlasses to summarize my last conversation"
///
/// If the question is omitted ("Hey Siri, ask OpenGlasses"), Siri prompts for it
/// via `requestValueDialog`. The answer flows back as a spoken dialog, so Siri —
/// not the app's internal TTS — reads it aloud (we pass `speakResponse: false`).
struct AskQuestionIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask OpenGlasses a Question"
    static var description = IntentDescription(
        "Ask OpenGlasses anything by voice and hear the answer, without the wake word"
    )

    // By default, run in the background so Siri can speak the answer without forcing
    // the app to the foreground (OpenGlasses normally stays running for wake words,
    // so `AppStateProvider.shared` is populated). Users who'd rather guarantee it
    // launches can flip "Open app for Siri questions" in Settings.
    static var openAppWhenRun: Bool { Config.siriAskOpensApp }
    static var isDiscoverable: Bool { true }

    @Parameter(
        title: "Question",
        description: "What you want to ask OpenGlasses",
        requestValueDialog: "What would you like to ask?"
    )
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.emptyQuestion
        }

        // Route through the same pipeline the wake word uses, but let Siri speak
        // the result instead of the in-app TTS engine.
        await appState.sendTextMessage(trimmed, speakResponse: false)

        let answer = appState.lastResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw IntentError.noResponse
        }

        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        case emptyQuestion
        case noResponse

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .appNotRunning:
                return "OpenGlasses is not running. Open the app first."
            case .emptyQuestion:
                return "I didn't catch a question."
            case .noResponse:
                return "Sorry, I couldn't get an answer."
            }
        }
    }
}
