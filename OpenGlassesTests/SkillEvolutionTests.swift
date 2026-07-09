import XCTest
@testable import OpenGlasses

/// Headless tests for the Skill Self-Evolution loop: pure trigger / dedup / proposal-validation, the
/// EvolvedSkillStore lifecycle, and the service orchestration with a stub analyzer. No LLM, no UI.
final class SkillEvolutionTests: XCTestCase {

    private func sample(_ kind: FailureSample.Kind = .toolError, ageSeconds: TimeInterval, now: Date) -> FailureSample {
        FailureSample(kind: kind, prompt: "p", at: now.addingTimeInterval(-ageSeconds))
    }

    // MARK: - EvolutionTrigger

    func testTriggerFalseUnderThresholdAndLowRate() {
        let now = Date()
        let samples = [sample(ageSeconds: 10, now: now), sample(ageSeconds: 20, now: now)]
        XCTAssertFalse(EvolutionTrigger.shouldEvolve(samples, now: now, batchThreshold: 8,
                                                     rateThreshold: 100, window: 1800))
    }

    func testTriggerFiresAtBatchThreshold() {
        let now = Date()
        let samples = (0..<8).map { sample(ageSeconds: Double($0) * 1000, now: now) }   // spread out
        XCTAssertTrue(EvolutionTrigger.shouldEvolve(samples, now: now, batchThreshold: 8,
                                                    rateThreshold: 100, window: 60))
    }

    func testTriggerFiresOnBurstWithinWindow() {
        let now = Date()
        // 4 failures in the last 30 min → 8/hr ≥ rate 6, even though count (4) < batch (8).
        let samples = (0..<4).map { sample(ageSeconds: Double($0) * 60, now: now) }
        XCTAssertTrue(EvolutionTrigger.shouldEvolve(samples, now: now, batchThreshold: 8,
                                                    rateThreshold: 6, window: 1800))
    }

    func testTriggerIgnoresSamplesOutsideWindow() {
        let now = Date()
        // All older than the 30-min window → don't count toward the rate.
        let samples = (0..<5).map { sample(ageSeconds: 3600 + Double($0), now: now) }
        XCTAssertFalse(EvolutionTrigger.shouldEvolve(samples, now: now, batchThreshold: 8,
                                                     rateThreshold: 6, window: 1800))
    }

    // MARK: - SkillDeduplicator

    func testDedupCatchesNearIdenticalName() {
        let a = SkillDraft(name: "expense-tagging", trigger: "expense this", instruction: "tag a note EXPENSE")
        let b = SkillDraft(name: "expense-tagging", trigger: "expense this", instruction: "completely different body here")
        XCTAssertTrue(SkillDeduplicator.isDuplicate(a, against: [b]))
    }

    func testDedupCatchesNearIdenticalBody() {
        let a = SkillDraft(name: "alpha", trigger: "do alpha", instruction: "create a tagged note for the user when asked")
        let b = SkillDraft(name: "beta", trigger: "do beta", instruction: "create a tagged note for the user when asked please")
        XCTAssertTrue(SkillDeduplicator.isDuplicate(a, against: [b]))
    }

    func testDistinctSkillsNotDuplicate() {
        let a = SkillDraft(name: "weather-brief", trigger: "morning briefing", instruction: "summarize today's forecast")
        let b = SkillDraft(name: "expense-tagging", trigger: "expense this", instruction: "tag a note EXPENSE with the amount")
        XCTAssertFalse(SkillDeduplicator.isDuplicate(a, against: [b]))
    }

    // MARK: - SkillProposal.validate

    func testValidProposalParses() {
        let raw = "name: expense-tagging\ntrigger: expense this\ninstruction: create a note tagged EXPENSE"
        let draft = SkillProposal.validate(raw, existingNames: [])
        XCTAssertEqual(draft, SkillDraft(name: "expense-tagging", trigger: "expense this",
                                         instruction: "create a note tagged EXPENSE"))
    }

    func testNoneIsRejected() {
        XCTAssertNil(SkillProposal.validate("none", existingNames: []))
        XCTAssertNil(SkillProposal.validate("  None  ", existingNames: []))
    }

    func testMissingRequiredFieldsRejected() {
        XCTAssertNil(SkillProposal.validate("name: x\ntrigger: only trigger", existingNames: []))   // no instruction
        XCTAssertNil(SkillProposal.validate("instruction: only instruction", existingNames: []))    // no trigger
    }

    func testInvalidNameGetsAutoSlugAvoidingCollisions() {
        let raw = "name: Not A Slug!\ntrigger: do thing\ninstruction: the action"
        let draft = SkillProposal.validate(raw, existingNames: ["dyn-1", "dyn-2"])
        XCTAssertEqual(draft?.name, "dyn-3")
        XCTAssertEqual(draft?.trigger, "do thing")
    }

    func testMissingNameGetsAutoSlug() {
        let draft = SkillProposal.validate("trigger: do thing\ninstruction: act", existingNames: [])
        XCTAssertEqual(draft?.name, "dyn-1")
    }

    // MARK: - EvolvedSkillStore

    @MainActor
    private func makeStore() -> EvolvedSkillStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return EvolvedSkillStore(directory: dir)
    }

    @MainActor
    func testStoreEnqueueAndLifecycle() {
        let store = makeStore()
        let draft = SkillDraft(name: "alpha", trigger: "do alpha", instruction: "act")
        XCTAssertTrue(store.enqueue(draft))
        XCTAssertEqual(store.pending().count, 1)
        XCTAssertFalse(store.enqueue(draft), "same name never re-enqueued")

        let id = store.pending()[0].id
        store.approve(id: id)
        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertEqual(store.approved().count, 1)
        XCTAssertEqual(store.approved()[0].resolvedAt != nil, true)
    }

    @MainActor
    func testDismissedNameNotReProposed() {
        let store = makeStore()
        store.enqueue(SkillDraft(name: "alpha", trigger: "t", instruction: "i"))
        let id = store.pending()[0].id
        store.dismiss(id: id)
        XCTAssertTrue(store.pending().isEmpty)
        XCTAssertFalse(store.enqueue(SkillDraft(name: "alpha", trigger: "t2", instruction: "i2")),
                       "a dismissed name is blocked from re-proposal")
        XCTAssertFalse(store.activeDrafts().contains { $0.name == "alpha" })
    }

    // MARK: - SkillEvolutionService orchestration

    private struct StubAnalyzer: SkillEvolutionAnalyzer {
        let output: String?
        func analyze(_ samples: [FailureSample]) async -> String? { output }
    }

    @MainActor
    func testServiceGatedByAgentMode() async {
        let key = "agentModeEnabled"
        let prior = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }

        UserDefaults.standard.set(false, forKey: key)
        let service = SkillEvolutionService(store: makeStore())
        service.analyzer = StubAnalyzer(output: "name: a\ntrigger: t\ninstruction: i")
        for _ in 0..<10 { service.record(FailureSample(kind: .toolError, prompt: "x", at: Date())) }
        XCTAssertTrue(service.samples.isEmpty, "record() is a no-op when Agent Mode is off")
        let draft = await service.evolveIfNeeded()
        XCTAssertNil(draft)
    }

    @MainActor
    func testServiceProposesAndEnqueuesOnTrigger() async {
        let key = "agentModeEnabled"
        let prior = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)

        let store = makeStore()
        let service = SkillEvolutionService(store: store)
        service.batchThreshold = 3
        service.analyzer = StubAnalyzer(output: "name: expense-tagging\ntrigger: expense this\ninstruction: tag a note EXPENSE")
        for _ in 0..<3 { service.record(FailureSample(kind: .toolError, prompt: "expense", at: Date())) }

        let draft = await service.evolveIfNeeded()
        XCTAssertEqual(draft?.name, "expense-tagging")
        XCTAssertEqual(store.pending().count, 1)
        XCTAssertTrue(service.samples.isEmpty, "batch consumed after evolving")
    }

    @MainActor
    func testServiceRejectsDuplicateProposal() async {
        let key = "agentModeEnabled"
        let prior = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)

        let store = makeStore()
        store.enqueue(SkillDraft(name: "expense-tagging", trigger: "expense this", instruction: "tag a note EXPENSE"))
        let service = SkillEvolutionService(store: store)
        service.batchThreshold = 1
        service.analyzer = StubAnalyzer(output: "name: expense-tagging\ntrigger: expense this\ninstruction: tag a note EXPENSE")
        service.record(FailureSample(kind: .toolError, prompt: "expense", at: Date()))

        let draft = await service.evolveIfNeeded()
        XCTAssertNil(draft, "a duplicate of an existing proposal is not re-enqueued")
        XCTAssertEqual(store.pending().count, 1)
    }
}
