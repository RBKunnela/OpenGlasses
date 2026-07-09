import XCTest
@testable import OpenGlasses

final class CaptureFlowBuilderTests: XCTestCase {

    private func step(_ field: String, type: BindingType = .voice, options: String = "", unit: String = "") -> CaptureFlowBuilder.StepDraft {
        var s = CaptureFlowBuilder.StepDraft()
        s.field = field; s.prompt = "Enter \(field)"; s.type = type; s.optionsCSV = options; s.unit = unit
        return s
    }

    // MARK: - Validation

    func testBuildsValidFlowAndRoundTripsThroughLibraryDecode() throws {
        let result = CaptureFlowBuilder.build(
            id: "fridge_inspection", title: "Fridge Inspection",
            steps: [step("suction_psig", type: .voiceNumber, unit: "psig"),
                    step("condition", type: .enumChoice, options: "ok, worn, failed"),
                    step("nameplate", type: .photo)])
        guard case let .success(flow) = result else { return XCTFail("expected success: \(result)") }
        XCTAssertEqual(flow.id, "fridge_inspection")
        XCTAssertEqual(flow.steps.count, 3)
        XCTAssertEqual(flow.steps[0].binding.unit, "psig")
        XCTAssertEqual(flow.steps[1].binding.options, ["ok", "worn", "failed"])

        // The exported JSON must load back through the library's own decoder.
        let data = try CaptureFlowBuilder.encode(flow)
        let decoded = try XCTUnwrap(CaptureFlowLibrary.decode(data))
        XCTAssertEqual(decoded, flow)
    }

    func testRejectsEmptyIdTitleSteps() {
        XCTAssertEqual(CaptureFlowBuilder.build(id: " ", title: "T", steps: [step("a")]).failure, .emptyId)
        XCTAssertEqual(CaptureFlowBuilder.build(id: "x", title: "  ", steps: [step("a")]).failure, .emptyTitle)
        XCTAssertEqual(CaptureFlowBuilder.build(id: "x", title: "T", steps: []).failure, .noSteps)
    }

    func testRejectsBadAndDuplicateFields() {
        XCTAssertEqual(CaptureFlowBuilder.build(id: "x", title: "T", steps: [step("Bad Field")]).failure, .invalidField("Bad Field"))
        XCTAssertEqual(CaptureFlowBuilder.build(id: "x", title: "T", steps: [step("a"), step("a")]).failure, .duplicateField("a"))
    }

    func testEnumRequiresOptions() {
        XCTAssertEqual(
            CaptureFlowBuilder.build(id: "x", title: "T", steps: [step("c", type: .enumChoice, options: "only_one")]).failure,
            .enumWithoutOptions("c"))
    }

    func testUnitOnlyKeptForNumberSteps() {
        // A unit on a non-number step is dropped.
        guard case let .success(flow) = CaptureFlowBuilder.build(
            id: "x", title: "T", steps: [step("a", type: .voice, unit: "psig")]) else { return XCTFail() }
        XCTAssertNil(flow.steps[0].binding.unit)
    }

    // MARK: - isSlug

    func testSlug() {
        XCTAssertTrue(CaptureFlowBuilder.isSlug("suction_psig"))
        XCTAssertTrue(CaptureFlowBuilder.isSlug("a1"))
        XCTAssertFalse(CaptureFlowBuilder.isSlug("1a"))     // can't start with a digit
        XCTAssertFalse(CaptureFlowBuilder.isSlug("Cap"))    // no uppercase
        XCTAssertFalse(CaptureFlowBuilder.isSlug("has space"))
        XCTAssertFalse(CaptureFlowBuilder.isSlug(""))
    }
}

private extension Result where Failure == CaptureFlowBuilder.BuildError {
    /// The error if this is a failure, for terse assertions.
    var failure: CaptureFlowBuilder.BuildError? {
        if case let .failure(e) = self { return e }
        return nil
    }
}
