import Foundation

/// Decides when a batch of [[FailureSample]]s is worth analysing. Pure; time is injected.
///
/// Fires on **accumulation** (`count ≥ batchThreshold`) or a **burst** (failure rate within `window`
/// at or above `rateThreshold`, in failures/hour). Keeping the bar here — rather than evolving on every
/// failure — keeps the (LLM-backed, human-reviewed) loop rare and high-signal.
enum EvolutionTrigger {
    static func shouldEvolve(_ samples: [FailureSample],
                             now: Date,
                             batchThreshold: Int,
                             rateThreshold: Double,
                             window: TimeInterval) -> Bool {
        if samples.count >= batchThreshold { return true }
        guard window > 0, rateThreshold > 0 else { return false }
        let inWindow = samples.filter { sample in
            let age = now.timeIntervalSince(sample.at)
            return age >= 0 && age <= window
        }.count
        let perHour = Double(inWindow) / (window / 3600)
        return perHour >= rateThreshold
    }
}
