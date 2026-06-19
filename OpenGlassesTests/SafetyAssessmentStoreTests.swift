import XCTest
@testable import OpenGlasses

/// Tests `SafetyAssessmentStore` persistence (docs/plans/safety-assessment.md): newest-first ordering,
/// dedup by id, trim-to-max, clear, and reload-from-disk. Uses a temp directory. Headless.
@MainActor
final class SafetyAssessmentStoreTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("heca-\(UUID().uuidString)", isDirectory: true)
    }

    private func report(_ id: String) -> SafetyReport {
        SafetyReport(id: id, createdAt: Date(), summary: "s",
                     findings: [HazardFinding(hazard: .fire, isPresent: true, hasDirectControl: true)])
    }

    func testSaveNewestFirstAndPersists() {
        let dir = tempDir()
        let store = SafetyAssessmentStore(directory: dir)
        store.save(report("a"))
        store.save(report("b"))
        XCTAssertEqual(store.history.map(\.id), ["b", "a"])
        // A fresh instance reads the persisted history.
        XCTAssertEqual(SafetyAssessmentStore(directory: dir).history.map(\.id), ["b", "a"])
    }

    func testDedupById() {
        let store = SafetyAssessmentStore(directory: tempDir())
        store.save(report("a"))
        store.save(report("a"))
        XCTAssertEqual(store.history.count, 1)
    }

    func testTrimsToMax() {
        let store = SafetyAssessmentStore(directory: tempDir(), maxHistory: 3)
        for i in 0..<5 { store.save(report("r\(i)")) }
        XCTAssertEqual(store.history.count, 3)
        XCTAssertEqual(store.history.first?.id, "r4")
    }

    func testClear() {
        let store = SafetyAssessmentStore(directory: tempDir())
        store.save(report("a"))
        store.clear()
        XCTAssertTrue(store.history.isEmpty)
    }
}
