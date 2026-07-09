import XCTest
@testable import OpenGlasses

/// Integration tests for routing `SemanticMemoryStore` through the `Embedder` seam with a version
/// stamp: memories/diary are stamped on write, and an invalidated (model-changed) stamp is re-embedded
/// and re-stamped on the next search (lazy self-heal). Skipped when no on-device embedding model.
@MainActor
final class SemanticMemoryEmbeddingMigrationTests: XCTestCase {

    private func makeStore() -> SemanticMemoryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SemanticMemoryStore(directory: dir)
    }

    private func requireModel() throws {
        try XCTSkipUnless(Embedder().isAvailable, "No on-device embedding model on this host")
    }

    func testRememberStampsEmbedding() throws {
        try requireModel()
        let store = makeStore()
        store.remember("favourite city", value: "Berlin in the spring")
        store.remember("project status", value: "the data migration is nearly finished")
        XCTAssertEqual(store.outdatedMemoryCount, 0, "freshly-stored memories carry the current stamp")
    }

    func testInvalidateThenSearchReEmbedsAndReStamps() throws {
        try requireModel()
        let store = makeStore()
        store.remember("favourite city", value: "Berlin in the spring")
        store.remember("project status", value: "the data migration is nearly finished")
        XCTAssertEqual(store.outdatedMemoryCount, 0)

        store.invalidateEmbeddings()                             // simulate a model change
        XCTAssertGreaterThan(store.outdatedMemoryCount, 0, "clearing stamps marks memories outdated")

        // Search still works (lazy re-embed), and the touched memories are re-stamped to current.
        let results = store.semanticSearch(query: "project status data migration", limit: 5)
        XCTAssertFalse(results.isEmpty, "search self-heals outdated memories instead of returning nothing")
        XCTAssertEqual(store.outdatedMemoryCount, 0, "searched memories were re-embedded and re-stamped")
    }

    func testDiaryReEmbedsAfterInvalidate() throws {
        try requireModel()
        let store = makeStore()
        store.writeDiary("Met Alice at the conference to discuss the refrigeration contract.")
        store.writeDiary("Picked up groceries and cooked pasta for dinner.")

        store.invalidateEmbeddings()
        // relevantDiary must still rank the on-topic entry first after invalidation (re-embed path).
        let hits = store.relevantDiary(for: "refrigeration contract meeting", limit: 1)
        XCTAssertEqual(hits.first?.text.contains("refrigeration") ?? false, true)
    }
}
