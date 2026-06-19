import XCTest
@testable import OpenGlasses

/// Tests for the built-in `InstrumentReadingSchema` ("read the instrument") adapter (structured-vision
/// Phase 3): mapping model JSON → typed, unit-normalized `InstrumentReading`s, the empty-readings case,
/// and the low-confidence → re-capture policy. Headless.
@MainActor
final class InstrumentReadingSchemaTests: XCTestCase {

    private let schema = InstrumentReadingSchema()

    func testMapsAndNormalizesReadings() throws {
        let json: [String: Any] = [
            "readings": [
                ["quantity": "temperature", "value": 212.0, "unit": "°F", "confidence": 0.9],
                ["quantity": "pressure", "value": 100.0, "unit": "psi", "confidence": 0.8]
            ],
            "summary": "Two gauges read.",
            "confidence": 0.85
        ]
        let card = try schema.makeCard(from: json, context: nil)
        XCTAssertEqual(card.kind, "instrument_reading")
        XCTAssertEqual(card.tier, .ok)
        XCTAssertEqual(card.readings.count, 2)
        let temp = card.readings.first { $0.quantity == "temperature" }
        XCTAssertEqual(temp?.canonical ?? -1, 100, accuracy: 0.001)   // 212°F → 100°C
        XCTAssertEqual(temp?.canonicalUnit, "°C")
        let psi = card.readings.first { $0.quantity == "pressure" }
        XCTAssertEqual(psi?.canonicalUnit, "kPa")
        XCTAssertTrue(card.stillNeeded.isEmpty)
    }

    func testEmptyReadingsAsksToReposition() throws {
        let card = try schema.makeCard(from: ["readings": [], "summary": ""], context: nil)
        XCTAssertEqual(card.tier, .caution)
        XCTAssertTrue(card.readings.isEmpty)
        XCTAssertTrue(card.stillNeeded.contains { $0.localizedCaseInsensitiveContains("point the camera") })
    }

    func testLowConfidenceTriggersRecapture() throws {
        let json: [String: Any] = [
            "readings": [["quantity": "brix", "value": 12.0, "unit": "°Bx", "confidence": 0.2]],
            "summary": "Refractometer, blurry."
        ]
        let card = try schema.makeCard(from: json, context: nil)
        XCTAssertTrue(card.stillNeeded.contains { $0.localizedCaseInsensitiveContains("brix") })
    }
}
