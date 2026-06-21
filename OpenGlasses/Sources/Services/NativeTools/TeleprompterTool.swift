import Foundation

/// Drives the hands-free HUD teleprompter (`TeleprompterService`): start a script (provided
/// inline or by saved name), control playback (next/back/pause/resume/restart/stop), nudge
/// the pace (faster/slower), and manage saved scripts (list/save).
@MainActor
struct TeleprompterTool: NativeTool {
    let service: TeleprompterService

    let name = "teleprompter"
    let description = """
        Hands-free teleprompter on the in-lens HUD. Shows a script a window at a time and \
        (in audio-paced mode) auto-advances by listening to you read.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["start", "stop", "pause", "resume", "next", "back", "restart",
                         "faster", "slower", "list", "save"],
                "description": "What to do."
            ],
            "text": [
                "type": "string",
                "description": "Script text for action=start (prompt it now) or action=save (store it)."
            ],
            "script": [
                "type": "string",
                "description": "Name of a previously-saved script to start (action=start)."
            ],
            "title": [
                "type": "string",
                "description": "Optional title when saving or starting inline text."
            ],
            "mode": [
                "type": "string",
                "enum": ["audio_paced", "voice", "auto_scroll"],
                "description": "Pacing mode for action=start. Defaults to the saved preference."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String)?.lowercased() ?? ""
        let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptName = (args["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = parseMode(args["mode"] as? String)

        switch action {
        case "start":
            if let text, !text.isEmpty {
                let parsed = TeleprompterScript.parse(title: title ?? SavedScript.deriveTitle(from: text), text: text)
                service.start(parsed, mode: mode)
                return "Teleprompter started: \(parsed.title) (\(parsed.wordCount) words, \(service.mode.displayName))."
            }
            if let scriptName, let saved = service.store.script(named: scriptName) {
                service.start(savedID: saved.id, mode: mode)
                return "Teleprompter started: \(saved.title) (\(service.mode.displayName))."
            }
            if scriptName != nil {
                return "I couldn't find a saved script named \"\(scriptName!)\". Say \"list\" to see saved scripts."
            }
            return "Provide the script text, or a saved script name, to start the teleprompter."

        case "stop":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.stop()
            return "Teleprompter stopped."

        case "pause":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.pause()
            return "Paused."

        case "resume":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.resume()
            return "Resumed."

        case "next":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.advance()
            return "Next line."

        case "back":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.back()
            return "Back one line."

        case "restart":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.restart()
            return "Back to the top."

        case "faster":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.nudgeSpeed(faster: true)
            return "Faster."

        case "slower":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.nudgeSpeed(faster: false)
            return "Slower."

        case "list":
            let scripts = service.store.scripts
            guard !scripts.isEmpty else { return "No saved scripts yet. Save one with action=save." }
            let names = scripts.prefix(20).map { "• \($0.title)" }.joined(separator: "\n")
            return "Saved scripts:\n\(names)"

        case "save":
            guard let text, !text.isEmpty else { return "Provide the script text to save." }
            let saved = service.store.add(title: title ?? "", text: text)
            return "Saved teleprompter script \"\(saved.title)\"."

        default:
            return "Unknown action. Use start, stop, pause, resume, next, back, restart, faster, slower, list, or save."
        }
    }

    private func parseMode(_ raw: String?) -> PacingMode? {
        switch raw?.lowercased() {
        case "audio_paced", "audiopaced", "audio": return .audioPaced
        case "voice", "manual": return .voice
        case "auto_scroll", "autoscroll", "scroll": return .autoScroll
        default: return nil
        }
    }
}
