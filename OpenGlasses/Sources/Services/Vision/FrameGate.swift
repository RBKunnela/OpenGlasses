import Foundation

/// Content-aware gate that drops near-duplicate frames before they reach the LLM.
///
/// Sits *behind* `FrameThrottler`'s time gate: once the time check passes, the
/// throttler computes a `PerceptualHash.dhash` and asks the gate whether the
/// frame is worth sending. The gate is a pure value type — time is injected via
/// `now`, no `Date()` inside — so every branch is deterministic and headless-testable.
///
/// Two refinements keep a long static scene from going stale:
/// - **Adaptive threshold** — an EMA of recent inter-frame Hamming distances raises
///   the similarity bar in static scenes (drop more) and lowers it in busy scenes
///   (keep more).
/// - **Heartbeat** — after `heartbeat` seconds with nothing sent, force one frame
///   through so the model's visual context can't go stale.
struct FrameGate {

    enum Decision: Equatable { case send, drop }

    /// Base Hamming distance (of 64) at/below which two frames are "the same scene".
    private let baseThreshold: Int
    /// Seconds after the last send before a frame is forced through regardless of similarity.
    private let heartbeat: TimeInterval
    /// When `true`, the effective threshold is nudged by the EMA of recent change.
    private let adaptiveEnabled: Bool
    /// EMA smoothing factor (0…1); higher reacts faster to recent change.
    private let emaAlpha: Double

    private var lastSentHash: UInt64?
    private var lastSentTime: TimeInterval?
    /// EMA of recent inter-frame Hamming distances; `nil` until the second frame.
    private var changeEMA: Double?

    private(set) var evaluatedCount: Int = 0
    private(set) var droppedCount: Int = 0

    /// Why the most recent `.send` decision was made. `.distinct` marks a genuine
    /// scene change (a keyframe worth describing); `.firstFrame` the session's
    /// first send; `.heartbeat` a forced re-send of an unchanged scene. `nil`
    /// until the first `.send`. Consumers that only care about *new* scenes
    /// (e.g. Visual State Memory) should ignore `.heartbeat`.
    enum SendReason { case firstFrame, distinct, heartbeat }
    private(set) var lastSendReason: SendReason?

    /// - Parameters:
    ///   - hammingThreshold: base "same scene" distance (default 4 of 64).
    ///   - heartbeat: force-send deadline in seconds (default 12).
    ///   - adaptiveEnabled: scale the threshold by recent change (default true).
    ///   - emaAlpha: EMA smoothing factor (default 0.3).
    init(hammingThreshold: Int = 4,
         heartbeat: TimeInterval = 12,
         adaptiveEnabled: Bool = true,
         emaAlpha: Double = 0.3) {
        self.baseThreshold = max(0, hammingThreshold)
        self.heartbeat = max(0, heartbeat)
        self.adaptiveEnabled = adaptiveEnabled
        self.emaAlpha = min(max(emaAlpha, 0), 1)
    }

    /// Fraction of evaluated frames that were dropped (0 when nothing evaluated yet).
    var dedupRatio: Double {
        evaluatedCount == 0 ? 0 : Double(droppedCount) / Double(evaluatedCount)
    }

    /// Decide whether the frame with `hash` should be sent at time `now`.
    /// Mutates internal state (last-sent, EMA, counters) as a side effect.
    mutating func evaluate(hash: UInt64, now: TimeInterval) -> Decision {
        evaluatedCount += 1

        // First frame of the session always goes.
        guard let lastHash = lastSentHash else {
            recordSend(hash: hash, now: now, reason: .firstFrame)
            return .send
        }

        let distance = PerceptualHash.hamming(hash, lastHash)
        updateEMA(with: distance)

        // Heartbeat: if we've sent nothing for too long, force this one through
        // so the model's visual context stays fresh even in a static scene.
        if let last = lastSentTime, heartbeat > 0, now - last >= heartbeat {
            recordSend(hash: hash, now: now, reason: .heartbeat)
            return .send
        }

        if distance <= effectiveThreshold() {
            droppedCount += 1
            return .drop
        }

        recordSend(hash: hash, now: now, reason: .distinct)
        return .send
    }

    /// Clear all state (e.g. on session restart).
    mutating func reset() {
        lastSentHash = nil
        lastSentTime = nil
        changeEMA = nil
        evaluatedCount = 0
        droppedCount = 0
        lastSendReason = nil
    }

    // MARK: - Internals

    private mutating func recordSend(hash: UInt64, now: TimeInterval, reason: SendReason) {
        lastSentHash = hash
        lastSentTime = now
        lastSendReason = reason
    }

    private mutating func updateEMA(with distance: Int) {
        let d = Double(distance)
        if let ema = changeEMA {
            changeEMA = emaAlpha * d + (1 - emaAlpha) * ema
        } else {
            changeEMA = d
        }
    }

    /// The base threshold adjusted by recent change. In a static scene (low EMA)
    /// the bar rises so we drop more aggressively; in a busy scene (high EMA) it
    /// stays near the base so distinct frames keep flowing. Never below the base.
    private func effectiveThreshold() -> Int {
        guard adaptiveEnabled, let ema = changeEMA else { return baseThreshold }
        // Static scene → ema below base → widen the drop window by the slack.
        let slack = max(0.0, Double(baseThreshold) - ema)
        return baseThreshold + Int(slack.rounded())
    }
}
