import Foundation
import UIKit

/// Live glue for Visual State Memory (Plan AV): owns the rolling `VisualStateMemory`,
/// runs a cheap, hard-rate-limited one-line describe on each genuine scene-change
/// keyframe from the frame gate, and hands a compact "Recent Visual Context" block
/// to the live session's instruction builder.
///
/// This is the only place that touches the camera/LLM; the testable logic lives in
/// the pure `VisualStateMemory` + `VisualContextBuilder`. With
/// `Config.visualStateMemoryEnabled == false` every entry point is a no-op, so the
/// session instruction is built exactly as before. Keyframes are rare (gate-driven)
/// and the describe is rate-limited, so the LLM cost stays small and bounded.
final class VisualStateService: ObservableObject {
    static let shared = VisualStateService()

    /// Injected by AppState. The describe needs a configured vision LLM; when nil,
    /// keyframes are ignored (no describe, no memory growth).
    var llm: LLMService?

    private let memory: VisualStateMemory
    private let lock = NSLock()
    private var lastDescribeAt: Date = .distantPast
    private var describing = false

    private init() {
        memory = VisualStateMemory(maxKeyframes: Config.visualStateMaxKeyframes)
    }

    private static let describeSystemPrompt = """
    You label what a person is looking at through smart-glasses, for short-term visual memory. \
    Reply with ONE short noun phrase (max ~8 words) naming the main scene or object. No sentence, \
    no preamble, no markdown. Example: "a kitchen counter with a kettle".
    """
    private static let describeUserText = "In one short phrase, what is the user looking at?"

    /// Called with a genuine scene-change keyframe (gate first-frame/distinct, never
    /// a heartbeat). Runs a rate-limited describe and appends a `Keyframe`. No-op
    /// when disabled, when a describe is already in flight, or before the min interval.
    func considerKeyframe(_ image: UIImage) {
        guard Config.visualStateMemoryEnabled, let llm else { return }

        let now = Date()
        let proceed: Bool = lock.locked {
            guard !describing,
                  now.timeIntervalSince(lastDescribeAt) >= Config.visualStateDescribeMinInterval else { return false }
            describing = true
            lastDescribeAt = now
            return true
        }
        guard proceed else { return }

        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            lock.locked { describing = false }
            return
        }
        let thumbnailRef = Config.visualStateInjectThumbnails ? Self.persistThumbnail(imageData) : nil

        Task { [weak self] in
            let raw = await llm.analyzeFrame(
                systemPrompt: Self.describeSystemPrompt,
                userText: Self.describeUserText,
                imageData: imageData,
                maxTokens: 40
            )
            guard let self else { return }
            let description = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.lock.locked {
                self.describing = false
                if !description.isEmpty {
                    self.memory.add(Keyframe(capturedAt: now, description: description, thumbnailRef: thumbnailRef))
                }
            }
        }
    }

    /// The "Recent Visual Context" block to inject into the live instruction, or
    /// nil when disabled / nothing seen yet.
    func promptContext(now: Date = Date()) -> String? {
        guard Config.visualStateMemoryEnabled else { return nil }
        let recent = lock.locked { memory.recent(Config.visualStateMaxKeyframes) }
        let text = VisualContextBuilder.summaryText(recent, now: now)
        return text.isEmpty ? nil : text
    }

    /// Clear the buffer and describe throttle (e.g. on session start/stop).
    func reset() {
        lock.locked {
            memory.reset()
            lastDescribeAt = .distantPast
            describing = false
        }
    }

    /// Persist a keyframe thumbnail to a temp file so the buffer stays light
    /// (image referenced, not inlined). Best-effort; nil on failure.
    private static func persistThumbnail(_ data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("visual-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
