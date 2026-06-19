import XCTest
@testable import OpenGlasses

/// Tests for `VisionAssessTool` routing (structured-vision Phase 3): missing/unknown `kind` guidance
/// (no camera needed) and the speakable `summarize` output. The camera happy path is integration-only.
@MainActor
final class VisionAssessToolTests: XCTestCase {

    private let tool = VisionAssessTool()

    override func setUp() {
        super.setUp()
        // Ensure at least the built-in kind is discoverable via the shared registry.
        AssessmentSchemaRegistry.shared.register(InstrumentReadingSchema())
    }

    func testMissingKindReturnsGuidance() async throws {
        let result = try await tool.execute(args: [:])
        XCTAssertTrue(result.localizedCaseInsensitiveContains("specify"))
        XCTAssertTrue(result.contains("instrument_reading"))
    }

    func testUnknownKindIsRejected() async throws {
        let result = try await tool.execute(args: ["kind": "bogus"])
        XCTAssertTrue(result.contains("Unknown assessment kind 'bogus'"))
        XCTAssertTrue(result.contains("instrument_reading"))
    }

    func testToolMetadata() {
        XCTAssertEqual(tool.name, "vision_assess")
        XCTAssertTrue(tool.description.contains("instrument_reading"))
        let props = tool.parametersSchema["properties"] as? [String: Any]
        XCTAssertNotNil(props?["kind"])
        XCTAssertEqual(tool.parametersSchema["required"] as? [String], ["kind"])
    }

    func testSummarizeIncludesReadingsAndAction() {
        let card = AssessmentCard(
            kind: "instrument_reading", title: "Instrument Reading", tier: .ok,
            summary: "Read 1 value.",
            recommendedAction: "log it",
            stillNeeded: ["wipe the lens"],
            readings: [InstrumentReading(quantity: "pressure", value: 100, unit: "psi",
                                         canonical: 689.4757, canonicalUnit: "kPa")])
        let s = VisionAssessTool.summarize(card)
        XCTAssertTrue(s.contains("Read 1 value."))
        XCTAssertTrue(s.contains("pressure: 100 psi"))
        XCTAssertTrue(s.contains("kPa"))
        XCTAssertTrue(s.contains("Recommended: log it"))
        XCTAssertTrue(s.contains("Still needed: wipe the lens"))
    }
}
