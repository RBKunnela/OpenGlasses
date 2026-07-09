import XCTest
@testable import OpenGlasses

/// Tests the pure "single owner" arbitration for the shared `AVAudioSession`. The decisive
/// property is stale-release suppression: a preempted owner releasing must NOT deactivate the
/// session a newer owner now holds.
final class AudioSessionLedgerTests: XCTestCase {

    private let tokenA = UUID()
    private let tokenB = UUID()

    func testAcquireOnFreeSessionHasNoPreemptedLease() {
        var ledger = AudioSessionLedger()
        let result = ledger.acquire(.wakeWord, token: tokenA)
        XCTAssertNil(result.preempted)
        XCTAssertEqual(result.lease.owner, .wakeWord)
        XCTAssertEqual(result.lease.generation, 1)
        XCTAssertEqual(ledger.current, result.lease)
    }

    func testSecondAcquirePreemptsFirstAndBumpsGeneration() {
        var ledger = AudioSessionLedger()
        let first = ledger.acquire(.wakeWord, token: tokenA).lease
        let second = ledger.acquire(.geminiLive, token: tokenB)
        XCTAssertEqual(second.preempted, first)
        XCTAssertEqual(second.lease.owner, .geminiLive)
        XCTAssertGreaterThan(second.lease.generation, first.generation)
        XCTAssertEqual(ledger.current, second.lease)
    }

    func testReleasingCurrentLeaseDeactivatesAndFreesSession() {
        var ledger = AudioSessionLedger()
        let lease = ledger.acquire(.geminiLive, token: tokenA).lease
        XCTAssertEqual(ledger.release(lease), .deactivate)
        XCTAssertNil(ledger.current)
    }

    func testStaleReleaseAfterPreemptionIsSuppressed() {
        var ledger = AudioSessionLedger()
        let old = ledger.acquire(.geminiLive, token: tokenA).lease
        let new = ledger.acquire(.openAIRealtime, token: tokenB).lease
        // The preempted owner's late teardown must not deactivate the new owner's session.
        XCTAssertEqual(ledger.release(old), .superseded(by: .openAIRealtime))
        XCTAssertEqual(ledger.current, new, "the newer lease must still own the session")
    }

    func testReleaseWhenNobodyHoldsIsAlreadyReleased() {
        var ledger = AudioSessionLedger()
        let lease = ledger.acquire(.wakeWord, token: tokenA).lease
        _ = ledger.release(lease)
        XCTAssertEqual(ledger.release(lease), .alreadyReleased)
    }

    func testDoubleReleaseOfSameLeaseDeactivatesOnceThenIsNoOp() {
        var ledger = AudioSessionLedger()
        let lease = ledger.acquire(.geminiLive, token: tokenA).lease
        XCTAssertEqual(ledger.release(lease), .deactivate)
        XCTAssertEqual(ledger.release(lease), .alreadyReleased)
    }

    func testGenerationIsMonotonicAcrossAcquires() {
        var ledger = AudioSessionLedger()
        let g1 = ledger.acquire(.wakeWord, token: UUID()).lease.generation
        let g2 = ledger.acquire(.wakeWord, token: UUID()).lease.generation
        let g3 = ledger.acquire(.geminiLive, token: UUID()).lease.generation
        XCTAssertEqual([g1, g2, g3], [1, 2, 3])
    }

    /// The real handoff this enables: the always-on wake-word baseline is preempted by a live
    /// session, the live session's release deactivates, and wake word re-assumes ownership.
    func testWakeWordToLiveSessionHandoff() {
        var ledger = AudioSessionLedger()
        // Wake word is the baseline owner.
        let wake1 = ledger.acquire(.wakeWord, token: UUID()).lease
        // A live session starts, preempting wake word.
        let gemini = ledger.acquire(.geminiLive, token: UUID())
        XCTAssertEqual(gemini.preempted, wake1)
        // Wake word's stale teardown (if any) must not deactivate the live session.
        XCTAssertEqual(ledger.release(wake1), .superseded(by: .geminiLive))
        XCTAssertEqual(ledger.current, gemini.lease)
        // Live session ends → deactivate; then wake word re-assumes the baseline.
        XCTAssertEqual(ledger.release(gemini.lease), .deactivate)
        XCTAssertNil(ledger.current)
        let wake2 = ledger.acquire(.wakeWord, token: UUID()).lease
        XCTAssertEqual(ledger.current, wake2)
    }

    // MARK: - Coexisting (non-exclusive) holds

    func testCoexistingHoldDoesNotChangeExclusiveOwner() {
        var ledger = AudioSessionLedger()
        let wake = ledger.acquire(.wakeWord, token: tokenA).lease
        ledger.beginCoexisting(.liveTranslation, token: tokenB)
        XCTAssertEqual(ledger.current, wake, "a coexisting rider must not preempt the owner")
        XCTAssertEqual(ledger.coexistingOwners, [.liveTranslation])
    }

    func testEndingCoexistingHoldDoesNotDeactivate() {
        var ledger = AudioSessionLedger()
        let wake = ledger.acquire(.wakeWord, token: tokenA).lease
        ledger.beginCoexisting(.textToSpeech, token: tokenB)
        ledger.endCoexisting(token: tokenB)
        XCTAssertEqual(ledger.coexistingOwners, [])
        XCTAssertEqual(ledger.current, wake, "ending a rider leaves the owner intact")
    }

    func testCoexistingOwnersAreDeduplicatedAndOrdered() {
        var ledger = AudioSessionLedger()
        ledger.beginCoexisting(.textToSpeech, token: UUID())
        ledger.beginCoexisting(.liveTranslation, token: UUID())
        ledger.beginCoexisting(.textToSpeech, token: UUID())  // a second TTS hold
        // Deduplicated, and in AudioSessionOwner.allCases order (liveTranslation before textToSpeech).
        XCTAssertEqual(ledger.coexistingOwners, [.liveTranslation, .textToSpeech])
    }

    func testReleasingExclusiveOwnerStillDeactivatesWithCoexistingRidersPresent() {
        var ledger = AudioSessionLedger()
        let wake = ledger.acquire(.wakeWord, token: tokenA).lease
        ledger.beginCoexisting(.textToSpeech, token: tokenB)
        // Coexisting holds are advisory bookkeeping — they don't block the owner's deactivation.
        XCTAssertEqual(ledger.release(wake), .deactivate)
    }

    func testReacquireBySameOwnerSupersedesItsOwnEarlierLease() {
        var ledger = AudioSessionLedger()
        let first = ledger.acquire(.geminiLive, token: tokenA).lease
        let second = ledger.acquire(.geminiLive, token: tokenB).lease
        // The first lease (e.g. before an interruption reset) is now stale even for the same owner.
        XCTAssertEqual(ledger.release(first), .superseded(by: .geminiLive))
        XCTAssertEqual(ledger.current, second)
        XCTAssertEqual(ledger.release(second), .deactivate)
    }
}
