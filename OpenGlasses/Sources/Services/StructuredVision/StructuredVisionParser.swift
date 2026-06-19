import Foundation

/// Pure, per-provider extraction of the structured-vision JSON object from a raw HTTP response body
/// (see docs/plans/structured-vision-assessment.md, Phase 2). No network — unit-tested with recorded
/// response bodies. Each parser prefers the provider's structured channel (forced tool call /
/// function call) and falls back to tolerant parsing of any returned text, so a model that answers
/// with prose JSON instead of a tool call still yields a result.
enum StructuredVisionParser {

    /// Anthropic Messages API: a forced `tool_use` block's `input`, else any `text` block parsed
    /// tolerantly. `toolName` empty matches any tool.
    static func anthropic(_ data: Data, toolName: String = "") -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        for block in content where block["type"] as? String == "tool_use" {
            if toolName.isEmpty || block["name"] as? String == toolName,
               let input = block["input"] as? [String: Any] {
                return input
            }
        }
        for block in content {
            if let text = block["text"] as? String, let obj = AssessmentJSON.object(fromText: text) {
                return obj
            }
        }
        return nil
    }

    /// OpenAI-compatible chat completions: `choices[0].message.tool_calls[0].function.arguments`
    /// (a JSON string), else `message.content` parsed tolerantly.
    static func openAI(_ data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let function = toolCalls.first?["function"] as? [String: Any],
           let args = function["arguments"] as? String,
           let obj = AssessmentJSON.object(fromText: args) {
            return obj
        }
        if let text = message["content"] as? String { return AssessmentJSON.object(fromText: text) }
        return nil
    }

    /// Gemini generateContent: a `functionCall.args` part, else the first text part (which is a JSON
    /// object when `responseMimeType` is `application/json`) parsed tolerantly.
    static func gemini(_ data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        for part in parts {
            if let call = part["functionCall"] as? [String: Any],
               let args = call["args"] as? [String: Any] {
                return args
            }
        }
        for part in parts {
            if let text = part["text"] as? String, let obj = AssessmentJSON.object(fromText: text) {
                return obj
            }
        }
        return nil
    }
}
