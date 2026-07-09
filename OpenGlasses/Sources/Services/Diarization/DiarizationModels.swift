import Foundation

// MARK: - Value types

/// One transcribed segment, optionally attributed to a diarized speaker.
///
/// `speaker == nil` means "no diarization" — either a single-speaker provider
/// (`SFSpeechRecognizer`) or a Deepgram response that carried no speaker labels. Consumers
/// must treat `nil` as "unlabeled" and never render a speaker chip for it.
struct DiarizedSegment: Equatable {
    let text: String
    let speaker: Int?
    let isFinal: Bool
    let start: Double?
    let end: Double?
    let confidence: Double
}

/// One diarized word from a Deepgram prerecorded/batch response.
struct DiarizedWord: Equatable {
    let word: String
    let start: Double
    let end: Double
    let speaker: Int
    let confidence: Double?
}

/// A run of consecutive same-speaker text, coalesced for a transcript/summary view.
struct SpeakerTurn: Equatable {
    let speaker: Int?
    let text: String
    let start: Double?
    let end: Double?
}

// MARK: - Deepgram response parsing (pure)

/// Turns Deepgram JSON (streaming "Results" messages and prerecorded/batch responses) into the
/// value types above. Pure and SDK-free — every method takes an already-decoded dictionary so
/// it can be exhaustively unit-tested with no network. This is the diarization "brain".
enum DeepgramResponseParser {

    /// Parse one Deepgram **streaming** `Results` message into a segment, or `nil` if it carries
    /// no usable transcript (empty/metadata-only messages are common and must be ignored).
    ///
    /// The speaker is the **majority speaker across the alternative's words**, so a segment in
    /// which the speaker changes mid-utterance is attributed to whoever spoke most of it rather
    /// than to whichever word happened to be first. Missing `speaker` fields are tolerated
    /// (the segment comes back with `speaker == nil`).
    static func parseStreaming(_ json: [String: Any]) -> DiarizedSegment? {
        guard let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let first = alternatives.first else {
            return nil
        }

        let transcript = (first["transcript"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }

        let confidence = first["confidence"] as? Double ?? 0
        let isFinal = json["is_final"] as? Bool ?? false

        let start = json["start"] as? Double
        let end: Double? = {
            guard let start, let duration = json["duration"] as? Double else { return nil }
            return start + duration
        }()

        let words = first["words"] as? [[String: Any]] ?? []
        let speaker = majoritySpeaker(in: words)

        return DiarizedSegment(
            text: transcript,
            speaker: speaker,
            isFinal: isFinal,
            start: start,
            end: end,
            confidence: confidence
        )
    }

    /// Parse a Deepgram **prerecorded/batch** response into its diarized words, in order. Words
    /// without a `speaker` field are skipped (a non-diarized response yields no words).
    static func parseBatchWords(_ json: [String: Any]) -> [DiarizedWord] {
        guard let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternatives = channels.first?["alternatives"] as? [[String: Any]],
              let words = alternatives.first?["words"] as? [[String: Any]] else {
            return []
        }

        return words.compactMap { w in
            guard let speaker = w["speaker"] as? Int else { return nil }
            let text = (w["punctuated_word"] as? String) ?? (w["word"] as? String) ?? ""
            guard !text.isEmpty else { return nil }
            return DiarizedWord(
                word: text,
                start: w["start"] as? Double ?? 0,
                end: w["end"] as? Double ?? 0,
                speaker: speaker,
                confidence: w["confidence"] as? Double
            )
        }
    }

    /// The speaker who owns the most words in `words`, or `nil` if none carry a speaker label.
    /// Ties resolve to the lowest speaker id for determinism.
    static func majoritySpeaker(in words: [[String: Any]]) -> Int? {
        var counts: [Int: Int] = [:]
        for w in words {
            if let s = w["speaker"] as? Int { counts[s, default: 0] += 1 }
        }
        guard !counts.isEmpty else { return nil }
        // Highest count wins; lowest id breaks ties.
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key
    }
}
