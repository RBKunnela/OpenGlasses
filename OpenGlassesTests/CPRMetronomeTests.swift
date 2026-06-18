import XCTest
@testable import OpenGlasses

/// Tests for the pure CPR pacing model (First-Aid / Emergency Assist): clock-injected 100–120 bpm
/// pacing with a 30:2 cycle and compression counting.
final class CPRMetronomeTests: XCTestCase {

    func testFirstTickFiresCompressionOne() {
        var m = CPRMetronome(rate: 110)
        XCTAssertEqual(m.tick(at: 0), [.compression(count: 1)])
        XCTAssertEqual(m.compressionCount, 1)
    }

    func testSecondBeatFiresAfterInterval() {
        var m = CPRMetronome(rate: 120)   // interval 0.5 s
        _ = m.tick(at: 0)
        XCTAssertEqual(m.tick(at: 0.5), [.compression(count: 2)])
    }

    func testNoBeatBeforeTheNextInterval() {
        var m = CPRMetronome(rate: 120)
        _ = m.tick(at: 0)
        XCTAssertEqual(m.tick(at: 0.4), [])   // < 0.5 s → no new beat
        XCTAssertEqual(m.compressionCount, 1)
    }

    func testRateClampedToGuidelineWindow() {
        XCTAssertEqual(CPRMetronome(rate: 200).clampedRate, 120)
        XCTAssertEqual(CPRMetronome(rate: 40).clampedRate, 100)
        XCTAssertEqual(CPRMetronome(rate: 110).clampedRate, 110)
    }

    func testBeatIntervalForRate() {
        XCTAssertEqual(CPRMetronome(rate: 120).beatInterval, 0.5, accuracy: 0.0001)
        XCTAssertEqual(CPRMetronome(rate: 100).beatInterval, 0.6, accuracy: 0.0001)
    }

    func testThirtyCompressionsTriggerBreathBreakAndResetCount() {
        var m = CPRMetronome(rate: 120)   // 0.5 s/beat
        var lastEvents: [CPRMetronome.Event] = []
        for beat in 0..<30 {
            lastEvents = m.tick(at: Double(beat) * 0.5)
        }
        XCTAssertTrue(lastEvents.contains(.breathBreak(cycle: 1)))
        XCTAssertEqual(m.cyclesCompleted, 1)
        XCTAssertEqual(m.compressionCount, 0)   // resets for the next cycle
    }

    func testSkippedBeatsAllFire() {
        var m = CPRMetronome(rate: 120)   // 0.5 s/beat
        _ = m.tick(at: 0)
        // Jump 1.6 s → beats expected: 1 + floor(1.6/0.5) = 1 + 3 = 4 → two new compressions (3rd, 4th)
        let events = m.tick(at: 1.6)
        XCTAssertEqual(events, [.compression(count: 2), .compression(count: 3), .compression(count: 4)])
    }

    func testResetReturnsToUnstarted() {
        var m = CPRMetronome(rate: 110)
        _ = m.tick(at: 5)
        m.reset()
        XCTAssertEqual(m.compressionCount, 0)
        XCTAssertEqual(m.cyclesCompleted, 0)
        XCTAssertEqual(m.tick(at: 100), [.compression(count: 1)])   // fresh start
    }
}
