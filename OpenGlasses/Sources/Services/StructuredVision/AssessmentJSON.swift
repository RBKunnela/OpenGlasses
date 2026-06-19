import Foundation

/// Tolerant JSON helpers for structured vision (see docs/plans/structured-vision-assessment.md).
///
/// The forced tool-use / responseSchema paths (Phase 2) return a clean JSON object, but the
/// local / on-device fallback only gets free text. `object(fromText:)` recovers a JSON object from
/// a bare object, a ```json fenced block, a ``` fenced block, or a first-`{`…last-`}` slice.
/// Pure and headless.
enum AssessmentJSON {

    /// Best-effort extraction of a JSON object from arbitrary model text. Returns `nil` if no
    /// candidate parses to a dictionary.
    static func object(fromText text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in candidates(in: trimmed) {
            if let dict = parse(candidate) { return dict }
        }
        return nil
    }

    /// Decode a `Decodable` from a `[String: Any]` JSON object (the shape schemas receive in
    /// `makeCard`). Round-trips through `JSONSerialization` so snake_case `CodingKeys` apply.
    static func decode<T: Decodable>(_ type: T.Type, from json: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Internals

    private static func candidates(in trimmed: String) -> [String] {
        var out: [String] = []
        if trimmed.hasPrefix("{") { out.append(trimmed) }
        if let fenced = slice(in: trimmed, after: "```json") { out.append(fenced) }
        if let fenced = slice(in: trimmed, after: "```") { out.append(fenced) }
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last {
            out.append(String(trimmed[first...last]))
        }
        return out
    }

    /// The text between the first occurrence of `marker` and the next ``` fence after it.
    private static func slice(in text: String, after marker: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        guard let end = text.range(of: "```", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
