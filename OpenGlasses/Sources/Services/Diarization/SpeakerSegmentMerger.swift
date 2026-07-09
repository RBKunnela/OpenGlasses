import Foundation

/// Coalesces diarized output into readable, per-speaker turns. Pure — no I/O.
///
/// Two entry points, one for each Deepgram path:
/// - `mergeFinals` collapses a stream of **final** segments (live captions) so that consecutive
///   segments from the same speaker read as one turn.
/// - `groupWords` turns a flat list of batch words into turns, splitting whenever the speaker
///   changes.
enum SpeakerSegmentMerger {

    /// Collapse consecutive same-speaker **final** segments into turns. Non-final (interim)
    /// segments are ignored — they're superseded by their finals. A `nil`-speaker segment only
    /// merges with an adjacent `nil`-speaker one.
    static func mergeFinals(_ segments: [DiarizedSegment]) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for segment in segments where segment.isFinal {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let last = turns.last, last.speaker == segment.speaker {
                turns[turns.count - 1] = SpeakerTurn(
                    speaker: last.speaker,
                    text: last.text + " " + text,
                    start: last.start,
                    end: segment.end ?? last.end
                )
            } else {
                turns.append(SpeakerTurn(
                    speaker: segment.speaker,
                    text: text,
                    start: segment.start,
                    end: segment.end
                ))
            }
        }
        return turns
    }

    /// Group ordered batch words into turns, starting a new turn each time the speaker changes.
    static func groupWords(_ words: [DiarizedWord]) -> [SpeakerTurn] {
        guard let first = words.first else { return [] }

        var turns: [SpeakerTurn] = []
        var speaker = first.speaker
        var pending = [first]

        func flush() {
            turns.append(SpeakerTurn(
                speaker: speaker,
                text: pending.map(\.word).joined(separator: " "),
                start: pending.first?.start,
                end: pending.last?.end
            ))
        }

        for word in words.dropFirst() {
            if word.speaker == speaker {
                pending.append(word)
            } else {
                flush()
                speaker = word.speaker
                pending = [word]
            }
        }
        flush()
        return turns
    }
}
