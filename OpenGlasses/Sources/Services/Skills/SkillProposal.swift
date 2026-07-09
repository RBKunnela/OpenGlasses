import Foundation

/// Parses and **validates** the LLM's proposed skill, so malformed or empty output never reaches the
/// review inbox. Pure. Expects three `key: value` lines (name/trigger/instruction); a literal `none`
/// (or a missing trigger/instruction) yields nil. An invalid/missing name is auto-assigned `dyn-NNN`
/// (not colliding with `existingNames`).
enum SkillProposal {
    private static let slugPattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9-]+$")
    private static let maxName = 40, maxTrigger = 120, maxInstruction = 600

    static func validate(_ raw: String, existingNames: Set<String>) -> SkillDraft? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }

        let fields = parseFields(trimmed)
        guard let trigger = fields["trigger"].map(clip(maxTrigger)), !trigger.isEmpty,
              let instruction = fields["instruction"].map(clip(maxInstruction)), !instruction.isEmpty
        else { return nil }   // required fields missing → reject

        let name = resolveName(fields["name"], existingNames: existingNames)
        return SkillDraft(name: name, trigger: trigger, instruction: instruction)
    }

    // MARK: - Helpers

    private static func parseFields(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if ["name", "trigger", "instruction"].contains(key), out[key] == nil, !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    /// A valid proposed slug, else an auto `dyn-NNN` that doesn't collide with `existingNames`.
    private static func resolveName(_ proposed: String?, existingNames: Set<String>) -> String {
        if let p = proposed?.lowercased(), p.count <= maxName, isValidSlug(p), !existingNames.contains(p) {
            return p
        }
        var n = 1
        while existingNames.contains("dyn-\(n)") { n += 1 }
        return "dyn-\(n)"
    }

    private static func isValidSlug(_ s: String) -> Bool {
        slugPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func clip(_ max: Int) -> (String) -> String {
        { String($0.prefix(max)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
