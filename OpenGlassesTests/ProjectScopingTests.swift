import XCTest
@testable import OpenGlasses

final class ProjectScopingTests: XCTestCase {

    // MARK: - ProjectScope (pure)

    func testShouldAdvertiseKB() {
        XCTAssertFalse(ProjectScope.shouldAdvertiseKB(documentCount: 0))
        XCTAssertTrue(ProjectScope.shouldAdvertiseKB(documentCount: 1))
        XCTAssertTrue(ProjectScope.shouldAdvertiseKB(documentCount: 9))
    }

    func testKnowledgeHintNilWhenEmpty() {
        XCTAssertNil(ProjectScope.knowledgeHint(projectName: "Spanish Tutor", documentCount: 0))
    }

    func testKnowledgeHintMentionsProjectAndCount() throws {
        let hint = try XCTUnwrap(ProjectScope.knowledgeHint(projectName: "Spanish Tutor", documentCount: 3))
        XCTAssertTrue(hint.contains("Spanish Tutor"))
        XCTAssertTrue(hint.contains("3 saved documents"))
        // Singular grammar at one document.
        let one = ProjectScope.knowledgeHint(projectName: "X", documentCount: 1)
        XCTAssertTrue(one?.contains("1 saved document.") ?? false)
    }

    // MARK: - ConversationThread tagging + legacy decode

    func testThreadEncodesPersonaId() throws {
        var thread = ConversationThread(mode: "voice", personaId: "proj-1")
        thread.title = "Tagged"
        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(ConversationThread.self, from: data)
        XCTAssertEqual(decoded.personaId, "proj-1")
    }

    func testLegacyThreadJSONWithoutPersonaIdDecodesToNil() throws {
        // A thread persisted before Plan AN has no `personaId` key.
        let legacy = """
        {
            "id": "abc",
            "title": "Old chat",
            "messages": [],
            "createdAt": 0,
            "updatedAt": 0,
            "mode": "voice"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConversationThread.self, from: legacy)
        XCTAssertNil(decoded.personaId)
        XCTAssertEqual(decoded.mode, "voice")
    }

    // MARK: - ConversationStore.threads(forPersona:)

    @MainActor
    func testThreadsForPersonaFilters() {
        let store = ConversationStore()
        var a = ConversationThread(mode: "voice", personaId: "A")
        a.title = "a"
        var b = ConversationThread(mode: "voice", personaId: "B")
        b.title = "b"
        let legacy = ConversationThread(mode: "voice")   // personaId == nil
        store.threads = [a, b, legacy]

        XCTAssertEqual(store.threads(forPersona: "A").map(\.personaId), ["A"])
        XCTAssertEqual(store.threads(forPersona: "B").count, 1)
        XCTAssertEqual(store.threads(forPersona: "missing").count, 0)
        // nil ⇒ all threads (the "All" view).
        XCTAssertEqual(store.threads(forPersona: nil).count, 3)
    }

    // MARK: - DocumentStore namespace isolation

    @MainActor
    private func makeStore() -> DocumentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    private let body = """
    To reset the thermostat, hold the power button for ten seconds until the screen blinks.
    The unit will then restart and return to factory defaults. For Wi-Fi setup, open the app.
    """

    @MainActor
    func testDocumentsAreIsolatedByNamespace() async throws {
        let store = makeStore()
        _ = await store.ingest(name: "ProjA Doc", text: body, namespace: "projA")
        _ = await store.ingest(name: "Global Doc", text: body, namespace: "global")
        _ = await store.ingest(name: "ProjA Doc 2", text: body, namespace: "projA")

        XCTAssertEqual(store.documentCount(namespace: "projA"), 2)
        XCTAssertEqual(store.documentCount(namespace: "global"), 1)
        XCTAssertEqual(store.documentCount(namespace: "projB"), 0)

        XCTAssertEqual(Set(store.list(namespace: "projA").map(\.name)), ["ProjA Doc", "ProjA Doc 2"])
        XCTAssertEqual(store.list(namespace: "global").map(\.name), ["Global Doc"])
        XCTAssertTrue(store.list(namespace: "projB").isEmpty)
        // Unscoped list still sees everything.
        XCTAssertEqual(store.list().count, 3)
    }

    @MainActor
    func testQueryIsScopedToNamespace() async throws {
        try XCTSkipUnless(Embedder().isAvailable, "No NLEmbedding model available in this environment")
        let store = makeStore()
        _ = await store.ingest(name: "ProjA Manual", text: body, namespace: "projA")
        _ = await store.ingest(name: "Global Manual", text: body, namespace: "global")

        let projA = store.query("how do I reset the thermostat", limit: 3, namespace: "projA")
        XCTAssertFalse(projA.isEmpty)
        XCTAssertTrue(projA.allSatisfy { $0.documentName == "ProjA Manual" })

        let projB = store.query("how do I reset the thermostat", limit: 3, namespace: "projB")
        XCTAssertTrue(projB.isEmpty, "An empty namespace returns no passages")
    }
}
