import AppIntents

/// QuickVision modes — each triggers a camera capture with a specialized prompt.
enum QuickVisionMode: String, AppEnum {
    case describe = "describe"
    case read = "read"
    case translate = "translate"
    case health = "health"
    case identify = "identify"
    case accessibility = "accessibility"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vision Mode")

    static var caseDisplayRepresentations: [QuickVisionMode: DisplayRepresentation] {
        [
            .describe: "Describe Scene",
            .read: "Read Text",
            .translate: "Translate Text",
            .health: "Analyze Food",
            .identify: "Identify Object",
            .accessibility: "Describe Environment",
        ]
    }

    var prompt: String {
        switch self {
        case .describe:
            return "Describe what you see in this image in detail."
        case .read:
            return "Read all visible text in this image. Transcribe it exactly as written, then provide a brief summary of the content."
        case .translate:
            return "Read any text visible in this image. Transcribe the original text, identify the language, then translate it to the user's language."
        case .health:
            return """
            Analyze the food in this image. For each food item visible, estimate:
            - Calories (kcal)
            - Protein (g)
            - Fat (g)
            - Carbs (g)
            Give a brief health assessment and any dietary suggestions. Keep it conversational for TTS.
            """
        case .identify:
            return "Identify the main object, product, landmark, or item in this image. Provide its name, brief description, and any notable facts. If it's a product, include brand and model if visible."
        case .accessibility:
            return "Describe the environment and surroundings for a visually impaired user. Focus on: obstacles, people, signage, doors, stairs, vehicles, and spatial layout. Be specific about distances and directions (left, right, ahead)."
        }
    }
}

/// Siri Intent: capture a photo with the glasses and analyze it in a specific mode.
struct QuickVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Vision"
    static var description = IntentDescription("Take a photo with the glasses and analyze it")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Mode", default: .describe)
    var mode: QuickVisionMode

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        await appState.capturePhotoAndSend(prompt: mode.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            AppBranding.appNotRunningLocalized
        }
    }
}

/// Shortcut: "Read this" — OCR + read aloud
struct ReadTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Text"
    static var description = IntentDescription("Read text visible through the glasses")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        await appState.capturePhotoAndSend(prompt: QuickVisionMode.read.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { AppBranding.appNotRunningShortLocalized }
    }
}

/// Shortcut: "Is this healthy?" — food nutrition analysis
struct AnalyzeFoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyze Food"
    static var description = IntentDescription("Analyze food nutrition from what the glasses see")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        await appState.capturePhotoAndSend(prompt: QuickVisionMode.health.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { AppBranding.appNotRunningShortLocalized }
    }
}

/// Shortcut: "Describe environment" — accessibility mode
struct DescribeEnvironmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Describe Environment"
    static var description = IntentDescription("Describe surroundings for accessibility")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        await appState.capturePhotoAndSend(prompt: QuickVisionMode.accessibility.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { AppBranding.appNotRunningShortLocalized }
    }
}
