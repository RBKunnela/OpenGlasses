import Foundation

/// Turns recent keyframes into a compact text block injected into the live
/// agent's instruction, giving it temporal scene awareness ("a kitchen 30 s ago
/// → now a laptop"). Pure: `now` is injected so the relative timestamps are
/// deterministic and testable without hardware.
enum VisualContextBuilder {

    /// Build a `# Recent Visual Context` block from `keyframes` (assumed
    /// chronological, oldest-first), labelling each with a relative timestamp
    /// derived from `now`. Returns "" when there's nothing described to show.
    ///
    /// - Parameters:
    ///   - keyframes: recent keyframes, oldest-first.
    ///   - now: reference time for the relative labels.
    ///   - maxInContext: cap on how many of the most recent keyframes to include.
    static func summaryText(_ keyframes: [Keyframe], now: Date, maxInContext: Int = 6) -> String {
        let described = keyframes.filter { !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !described.isEmpty, maxInContext > 0 else { return "" }

        let shown = described.suffix(maxInContext)
        var lines = [
            "# Recent Visual Context",
            "What you have recently seen through the glasses camera (oldest first, most recent last). " +
            "Use this to answer \"what was I just looking at?\" and to notice when the scene changes. " +
            "Only describe the live frame for the present; treat these as memory of the recent past."
        ]
        for frame in shown {
            lines.append("\(relativeLabel(from: frame.capturedAt, to: now)) \(frame.description)")
        }
        return lines.joined(separator: "\n")
    }

    /// A relative label like `[Now]`, `[T-30s]`, or `[T-2m]` for a capture time
    /// relative to `now`. Future or sub-second deltas read as `[Now]`.
    static func relativeLabel(from capturedAt: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(capturedAt).rounded())
        if seconds <= 0 { return "[Now]" }
        if seconds < 60 { return "[T-\(seconds)s]" }
        let minutes = seconds / 60
        return "[T-\(minutes)m]"
    }
}
