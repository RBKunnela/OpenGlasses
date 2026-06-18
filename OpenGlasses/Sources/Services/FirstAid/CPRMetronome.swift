import Foundation

/// Pure CPR pacing model (First-Aid / Emergency Assist) — no audio, no timers. Given an injected clock
/// it answers when a compression beat should fire and when a **30:2 cycle** reaches its rescue-breath
/// break. The service plays a click per `.compression` and speaks a cue on `.breathBreak`; this model is
/// the testable heart of it.
///
/// The rate is clamped to the AHA guideline window of **100–120 compressions/min**.
struct CPRMetronome: Equatable {

    /// An event emitted by `tick(at:)`.
    enum Event: Equatable {
        /// A compression beat fired; `count` is its position within the current cycle (1...30).
        case compression(count: Int)
        /// 30 compressions done — prompt two rescue breaths; `cycle` is how many cycles are complete.
        case breathBreak(cycle: Int)
    }

    /// Requested rate in bpm. Effective pacing uses `clampedRate`.
    var rate: Int
    /// Compressions per cycle before a rescue-breath break (CPR standard: 30).
    let compressionsPerCycle: Int

    private(set) var compressionCount = 0      // position within the current cycle (0...30)
    private(set) var cyclesCompleted = 0
    private var totalBeats = 0
    private var startTime: TimeInterval?

    init(rate: Int = 110, compressionsPerCycle: Int = 30) {
        self.rate = rate
        self.compressionsPerCycle = compressionsPerCycle
    }

    /// Effective rate, clamped to 100–120 bpm.
    var clampedRate: Int { min(max(rate, 100), 120) }

    /// Seconds between compressions at the effective rate.
    var beatInterval: TimeInterval { 60.0 / Double(clampedRate) }

    /// Advance the metronome to absolute time `now` and return the events since the last tick. The
    /// first tick starts the clock and fires beat 1 immediately; later ticks fire every `beatInterval`,
    /// emitting a `.breathBreak` after each 30th compression (and resetting the per-cycle count).
    mutating func tick(at now: TimeInterval) -> [Event] {
        guard let start = startTime else {
            startTime = now
            return registerBeat()
        }
        // Total beats that should have fired by `now` (beat 1 fired at t = start, so +1).
        let expected = Int((now - start) / beatInterval) + 1
        var events: [Event] = []
        while totalBeats < expected {
            events.append(contentsOf: registerBeat())
        }
        return events
    }

    /// Reset to the un-started state (e.g. when restarting pacing).
    mutating func reset() {
        compressionCount = 0
        cyclesCompleted = 0
        totalBeats = 0
        startTime = nil
    }

    private mutating func registerBeat() -> [Event] {
        totalBeats += 1
        compressionCount += 1
        var events: [Event] = [.compression(count: compressionCount)]
        if compressionCount >= compressionsPerCycle {
            cyclesCompleted += 1
            compressionCount = 0
            events.append(.breathBreak(cycle: cyclesCompleted))
        }
        return events
    }
}
