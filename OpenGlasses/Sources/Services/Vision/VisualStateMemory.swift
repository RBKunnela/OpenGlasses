import Foundation

/// Session-scoped, fixed-capacity ring buffer of `Keyframe`s — the live agent's
/// short visual memory of what it has recently seen. Pure data structure: no
/// timers, no I/O, no `Date()` inside. Oldest keyframes are evicted once capacity
/// is reached.
final class VisualStateMemory {

    /// Maximum keyframes retained; adding beyond this evicts the oldest.
    let maxKeyframes: Int

    private var buffer: [Keyframe] = []

    init(maxKeyframes: Int) {
        self.maxKeyframes = max(1, maxKeyframes)
    }

    /// Number of keyframes currently held.
    var count: Int { buffer.count }

    /// Append a keyframe, evicting the oldest if at capacity.
    func add(_ keyframe: Keyframe) {
        buffer.append(keyframe)
        if buffer.count > maxKeyframes {
            buffer.removeFirst(buffer.count - maxKeyframes)
        }
    }

    /// The most recent `n` keyframes in chronological (oldest-first) order.
    /// Returns fewer than `n` if the buffer holds fewer; empty for `n <= 0`.
    func recent(_ n: Int) -> [Keyframe] {
        guard n > 0 else { return [] }
        return Array(buffer.suffix(n))
    }

    /// Description of the most recently added keyframe, if any.
    var latestDescription: String? { buffer.last?.description }

    /// Clear all keyframes (e.g. on session restart).
    func reset() { buffer.removeAll() }
}
