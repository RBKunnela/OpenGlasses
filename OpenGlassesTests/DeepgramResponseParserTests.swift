import XCTest
@testable import OpenGlasses

/// The diarization "brain": Deepgram JSON → `DiarizedSegment` / `DiarizedWord`. JSON is parsed
/// via `JSONSerialization` (not Swift literals) so the `NSNumber` bridging matches production.
final class DeepgramResponseParserTests: XCTestCase {

    private func json(_ string: String) -> [String: Any] {
        let data = string.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - Streaming

    func testSingleWordFinalSegment() {
        let segment = DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"Hello","confidence":0.97,
          "words":[{"word":"hello","speaker":0}]}]},
         "is_final":true,"start":1.0,"duration":0.5}
        """))
        XCTAssertEqual(segment?.text, "Hello")
        XCTAssertEqual(segment?.speaker, 0)
        XCTAssertEqual(segment?.isFinal, true)
        XCTAssertEqual(segment?.start, 1.0)
        XCTAssertEqual(segment?.end, 1.5)
        XCTAssertEqual(segment?.confidence ?? 0, 0.97, accuracy: 0.0001)
    }

    func testMajoritySpeakerAcrossWords() {
        let segment = DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"a b c",
          "words":[{"word":"a","speaker":0},{"word":"b","speaker":0},{"word":"c","speaker":1}]}]},
         "is_final":true}
        """))
        XCTAssertEqual(segment?.speaker, 0, "majority of words are speaker 0")
    }

    func testMidSegmentSpeakerSwitchAttributesToMajority() {
        let segment = DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"a b c",
          "words":[{"word":"a","speaker":0},{"word":"b","speaker":1},{"word":"c","speaker":1}]}]},
         "is_final":true}
        """))
        XCTAssertEqual(segment?.speaker, 1)
    }

    func testSpeakerTieResolvesToLowestId() {
        let segment = DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"a b",
          "words":[{"word":"a","speaker":1},{"word":"b","speaker":0}]}]},
         "is_final":true}
        """))
        XCTAssertEqual(segment?.speaker, 0)
    }

    func testInterimResultIsNotFinal() {
        let segment = DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"partial",
          "words":[{"word":"partial","speaker":0}]}]},"is_final":false}
        """))
        XCTAssertEqual(segment?.isFinal, false)
    }

    func testMissingSpeakerFieldYieldsNilSpeaker() {
        let segment = DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"no labels",
          "words":[{"word":"no"},{"word":"labels"}]}]},"is_final":true}
        """))
        XCTAssertNotNil(segment)
        XCTAssertNil(segment?.speaker)
    }

    func testEmptyTranscriptReturnsNil() {
        XCTAssertNil(DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"   ","words":[]}]},"is_final":true}
        """)))
    }

    func testMetadataOnlyMessageReturnsNil() {
        XCTAssertNil(DeepgramResponseParser.parseStreaming(json("""
        {"type":"Metadata","duration":1.0}
        """)))
    }

    func testSmartFormatPunctuationPreserved() {
        let segment = DeepgramResponseParser.parseStreaming(json("""
        {"channel":{"alternatives":[{"transcript":"Hello, world!",
          "words":[{"word":"hello","speaker":0},{"word":"world","speaker":0}]}]},
         "is_final":true}
        """))
        XCTAssertEqual(segment?.text, "Hello, world!")
    }

    // MARK: - Batch

    func testParseBatchWordsPrefersPunctuatedAndSkipsUnlabeled() {
        let words = DeepgramResponseParser.parseBatchWords(json("""
        {"results":{"channels":[{"alternatives":[{"words":[
          {"word":"hi","punctuated_word":"Hi,","start":0.0,"end":0.2,"speaker":0,"confidence":0.9},
          {"word":"there","start":0.2,"end":0.4,"speaker":1},
          {"word":"orphan","start":0.4,"end":0.5}
        ]}]}]}}
        """))
        XCTAssertEqual(words.count, 2, "the speaker-less word is skipped")
        XCTAssertEqual(words[0].word, "Hi,")
        XCTAssertEqual(words[0].speaker, 0)
        XCTAssertEqual(words[1].word, "there")
        XCTAssertEqual(words[1].speaker, 1)
    }

    func testParseBatchWordsEmptyForNonDiarized() {
        XCTAssertTrue(DeepgramResponseParser.parseBatchWords(json("{}")).isEmpty)
    }
}
