import AVFoundation
import Foundation

/// Source-agnostic seam for "speech in → labeled segments out", so the caption/recording paths
/// don't care whether labels come from Deepgram (diarized) or the on-device recognizer
/// (single-speaker, `speaker == nil`). Pluggable, like the teleprompter's pacer.
///
/// `@MainActor`: providers drive `@Published` UI state (captions) and are created/consumed on
/// the main actor, so the whole seam is main-actor-isolated.
@MainActor
protocol DiarizationProvider: AnyObject {
    /// Emitted for each interim/final segment as it arrives.
    var onSegment: ((DiarizedSegment) -> Void)? { get set }
    func start()
    func stop()
    /// Feed a captured audio buffer from the shared engine.
    func sendAudio(_ buffer: AVAudioPCMBuffer)
}

/// The fallback contract: when diarization is off/unconfigured, transcripts become **unlabeled**
/// segments (`speaker == nil`) so downstream code behaves exactly as it does today. The live
/// `SFSpeechRecognizer` wiring lives in `AmbientCaptionService`; this captures the invariant in
/// a pure, testable form.
enum SingleSpeakerAdapter {
    static func segment(forTranscript transcript: String,
                        isFinal: Bool,
                        confidence: Double = 1) -> DiarizedSegment? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return DiarizedSegment(
            text: text,
            speaker: nil,
            isFinal: isFinal,
            start: nil,
            end: nil,
            confidence: confidence
        )
    }
}
