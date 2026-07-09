import Foundation

/// Decides whether a failed tool result is worth feeding the [[SkillEvolutionService]]. Pure.
///
/// Only **genuine execution errors** are a skill-gap signal. Timeouts are infra/transient, and
/// safety blocks / user declines / "unknown tool" are intentional outcomes, not mistakes — recording
/// them would pollute the proposal bank. (Safety/decline results don't reach the execution path this
/// filters anyway; the timeout guard is the one that matters here.)
enum ToolFailureFilter {
    static func shouldRecord(_ message: String) -> Bool {
        let m = message.lowercased()
        if m.contains("timed out") { return false }
        if m.contains("was blocked") || m.contains("did not approve") || m.contains("unknown tool") { return false }
        return m.contains("tool error")
    }
}
