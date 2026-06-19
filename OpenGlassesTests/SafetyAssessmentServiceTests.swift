import XCTest
@testable import OpenGlasses

/// Tests the `SafetyAssessmentService` core (via the injectable `analyze` seam + a fresh `structuredVision`
/// presenter — no network, camera, or HUD), the summary text, and `safety_assessment` tool routing.
/// Uses fresh instances so it never drives the host app's real camera/Wearables HUD. Headless.
@MainActor
final class SafetyAssessmentServiceTests: XCTestCase {

    private let fixture: [String: Any] = [
        "summary": "Unshored trench beside a suspended load.",
        "assessments": [
            ["category": "excavation", "is_present": true, "has_direct_control": false,
             "has_indirect_control": true, "indirect_control": "tape"],
            ["category": "suspended_load", "is_present": true, "has_direct_control": true,
             "direct_control": "rigging"]
        ]
    ]

    private func tempStore() -> SafetyAssessmentStore {
        SafetyAssessmentStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("heca-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeService() -> (SafetyAssessmentService, StructuredVisionService) {
        let presenter = StructuredVisionService()     // fresh — no glassesDisplay
        let svc = SafetyAssessmentService()
        svc.structuredVision = presenter
        svc.store = tempStore()                       // isolated — don't write Application Support
        svc.analyze = { [fixture] _, _, _, _ in fixture }
        return (svc, presenter)
    }

    /// Point the shared service at fresh/isolated collaborators so tool tests don't drive the host HUD/store.
    private func isolateShared() {
        SafetyAssessmentService.shared.structuredVision = StructuredVisionService()
        SafetyAssessmentService.shared.store = tempStore()
        SafetyAssessmentService.shared.analyze = { [fixture] _, _, _, _ in fixture }
    }

    func testAssessDecodesReportAndPublishesCard() async throws {
        let (svc, presenter) = makeService()
        let report = try await svc.assess(imageData: Data())
        XCTAssertEqual(report.findings.count, 13)
        XCTAssertEqual(report.score ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(svc.latest?.score ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(presenter.latest?.kind, "safety_assessment")   // generic card published
        XCTAssertEqual(svc.store.history.count, 1)                    // persisted to history
    }

    func testAssessThrowsWhenAnalysisEmpty() async {
        let svc = SafetyAssessmentService()
        svc.structuredVision = StructuredVisionService()
        svc.analyze = { _, _, _, _ in nil }
        do { _ = try await svc.assess(imageData: Data()); XCTFail("expected analysisFailed") }
        catch StructuredVisionError.analysisFailed {} catch { XCTFail("wrong error: \(error)") }
    }

    func testSummaryTextHighlightsUncontrolled() throws {
        let report = try SafetyReport.from(json: fixture)
        let text = SafetyAssessmentService.summaryText(report)
        XCTAssertTrue(text.contains("HECA score 50%"))
        XCTAssertTrue(text.contains("indirect-only: Trench / Excavation"))
    }

    // MARK: - Tool

    func testToolMetadata() {
        let tool = SafetyAssessmentTool()
        XCTAssertEqual(tool.name, "safety_assessment")
        let props = tool.parametersSchema["properties"] as? [String: Any]
        XCTAssertNotNil(props?["action"])
    }

    func testToolLastReturnsLatestSummary() async throws {
        isolateShared()
        _ = try await SafetyAssessmentService.shared.assess(imageData: Data())
        let result = try await SafetyAssessmentTool().execute(args: ["action": "last"])
        XCTAssertTrue(result.contains("HECA score 50%"))
    }

    func testToolScoreReportsLatestScore() async throws {
        isolateShared()
        _ = try await SafetyAssessmentService.shared.assess(imageData: Data())
        let result = try await SafetyAssessmentTool().execute(args: ["action": "score"])
        XCTAssertTrue(result.contains("HECA score 50%"))
        XCTAssertTrue(result.contains("1 of 2"))
    }

    func testToolHistoryListsSavedAssessments() async throws {
        isolateShared()
        _ = try await SafetyAssessmentService.shared.assess(imageData: Data())
        let result = try await SafetyAssessmentTool().execute(args: ["action": "history"])
        XCTAssertTrue(result.contains("Recent safety assessments"))
        XCTAssertTrue(result.contains("HECA 50%"))
    }
}
