import Foundation

/// Translates a standard JSON Schema (the same `input_schema` Anthropic/OpenAI forced-tool calls use)
/// into Gemini's `responseSchema` shape, so the structured-vision call gets **enforced** JSON from
/// Gemini too — not just `responseMimeType: application/json` with the shape conveyed only by prose.
///
/// Gemini's schema is an OpenAPI-3 subset: `type` is an UPPERCASE enum, and only a handful of keywords
/// are honoured. We map the structural ones (`type`, `description`, `enum`, `properties`, `items`,
/// `required`, `nullable`) recursively and drop everything Gemini ignores (e.g. `additionalProperties`,
/// `$schema`, numeric bounds), so a generic schema round-trips cleanly. Pure and unit-tested.
enum GeminiSchemaTranslator {

    static func translate(_ schema: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]

        if let type = schema["type"] as? String {
            out["type"] = geminiType(type)
        }
        if let description = schema["description"] as? String {
            out["description"] = description
        }
        if let nullable = schema["nullable"] as? Bool {
            out["nullable"] = nullable
        }
        if let enumValues = schema["enum"] as? [Any] {
            out["enum"] = enumValues.compactMap { $0 as? String }
        }
        if let properties = schema["properties"] as? [String: Any] {
            var translated: [String: Any] = [:]
            for (key, value) in properties {
                if let object = value as? [String: Any] { translated[key] = translate(object) }
            }
            out["properties"] = translated
        }
        if let items = schema["items"] as? [String: Any] {
            out["items"] = translate(items)
        }
        if let required = schema["required"] as? [Any] {
            out["required"] = required.compactMap { $0 as? String }
        }
        return out
    }

    /// JSON Schema's lowercase `type` → Gemini's uppercase `Type` enum.
    private static func geminiType(_ type: String) -> String {
        switch type.lowercased() {
        case "object":  return "OBJECT"
        case "array":   return "ARRAY"
        case "string":  return "STRING"
        case "number":  return "NUMBER"
        case "integer": return "INTEGER"
        case "boolean": return "BOOLEAN"
        default:        return type.uppercased()
        }
    }
}
