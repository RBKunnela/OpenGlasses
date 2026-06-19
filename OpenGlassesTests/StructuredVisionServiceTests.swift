import XCTest
@testable import OpenGlasses

/// Tests for `StructuredVisionService` core (structured-vision Phase 3) via the injectable `analyze`
/// seam and a fresh registry — no network, no camera. Covers the happy path (decode + publish),
/// unknown kind, and an empty analysis result.
@MainActor
final class StructuredVisionServiceTests: XCTestCase {

    private func makeService(analyze: @escaping (String, String, Data, [String: Any], String) async -> [String: Any]?) -> StructuredVisionService {
        let svc = StructuredVisionService()
        let registry = AssessmentSchemaRegistry()
        registry.register(InstrumentReadingSchema())
        svc.registry = registry
        svc.analyze = analyze
        return svc
    }

    func testAssessHappyPathDecodesAndPublishes() async throws {
        let svc = makeService { _, _, _, _, _ in
            ["readings": [["quantity": "temperature", "value": 212.0, "unit": "°F", "confidence": 0.9]],
             "summary": "Reads 212°F.", "confidence": 0.9]
        }
        let card = try await svc.assess(kind: "instrument_reading", imageData: Data(), note: nil)
        XCTAssertEqual(card.readings.first?.canonicalUnit, "°C")
        XCTAssertEqual(card.readings.first?.canonical ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(svc.latest, card)            // published for the card view
        XCTAssertFalse(svc.isAnalyzing)             // reset after completion
    }

    func testUnknownKindThrows() async {
        let svc = makeService { _, _, _, _, _ in [:] }
        do {
            _ = try await svc.assess(kind: "nope", imageData: Data(), note: nil)
            XCTFail("expected unknownKind")
        } catch StructuredVisionError.unknownKind(let k) {
            XCTAssertEqual(k, "nope")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNilAnalysisThrows() async {
        let svc = makeService { _, _, _, _, _ in nil }
        do {
            _ = try await svc.assess(kind: "instrument_reading", imageData: Data(), note: nil)
            XCTFail("expected analysisFailed")
        } catch StructuredVisionError.analysisFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testContextNoteIsPassedToAnalyze() async throws {
        var seenUserText = ""
        let svc = makeService { _, userText, _, _, _ in
            seenUserText = userText
            return ["readings": [], "summary": "none"]
        }
        _ = try await svc.assess(kind: "instrument_reading", imageData: Data(), note: "suction line")
        XCTAssertTrue(seenUserText.contains("suction line"))
    }
}
