import XCTest
@testable import OpenGlasses

final class VisualStateMemoryTests: XCTestCase {

    private func frame(_ desc: String, at offset: TimeInterval, base: Date = Date(timeIntervalSinceReferenceDate: 1000)) -> Keyframe {
        Keyframe(capturedAt: base.addingTimeInterval(offset), description: desc)
    }

    // MARK: - VisualStateMemory

    func testAddAndCount() {
        let mem = VisualStateMemory(maxKeyframes: 5)
        XCTAssertEqual(mem.count, 0)
        mem.add(frame("a", at: 0))
        mem.add(frame("b", at: 1))
        XCTAssertEqual(mem.count, 2)
        XCTAssertEqual(mem.latestDescription, "b")
    }

    func testCapacityEvictsOldest() {
        let mem = VisualStateMemory(maxKeyframes: 3)
        for (i, d) in ["a", "b", "c", "d", "e"].enumerated() {
            mem.add(frame(d, at: TimeInterval(i)))
        }
        XCTAssertEqual(mem.count, 3)
        // Oldest ("a","b") evicted; "c","d","e" remain in order.
        XCTAssertEqual(mem.recent(10).map(\.description), ["c", "d", "e"])
        XCTAssertEqual(mem.latestDescription, "e")
    }

    func testRecentReturnsLastNInOrder() {
        let mem = VisualStateMemory(maxKeyframes: 10)
        for (i, d) in ["a", "b", "c", "d"].enumerated() {
            mem.add(frame(d, at: TimeInterval(i)))
        }
        XCTAssertEqual(mem.recent(2).map(\.description), ["c", "d"])
        XCTAssertEqual(mem.recent(0), [])
        XCTAssertEqual(mem.recent(-1), [])
        // Asking for more than held returns all.
        XCTAssertEqual(mem.recent(99).map(\.description), ["a", "b", "c", "d"])
    }

    func testResetClears() {
        let mem = VisualStateMemory(maxKeyframes: 3)
        mem.add(frame("a", at: 0))
        mem.reset()
        XCTAssertEqual(mem.count, 0)
        XCTAssertNil(mem.latestDescription)
        XCTAssertEqual(mem.recent(5), [])
    }

    func testMaxKeyframesFlooredToOne() {
        let mem = VisualStateMemory(maxKeyframes: 0)
        XCTAssertEqual(mem.maxKeyframes, 1)
        mem.add(frame("a", at: 0))
        mem.add(frame("b", at: 1))
        XCTAssertEqual(mem.recent(5).map(\.description), ["b"])
    }

    func testSeparateInstancesAreIsolated() {
        let a = VisualStateMemory(maxKeyframes: 3)
        let b = VisualStateMemory(maxKeyframes: 3)
        a.add(frame("a", at: 0))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 0)
    }

    // MARK: - VisualContextBuilder

    func testSummaryEmptyWhenNoKeyframes() {
        let now = Date(timeIntervalSinceReferenceDate: 2000)
        XCTAssertEqual(VisualContextBuilder.summaryText([], now: now), "")
    }

    func testSummaryEmptyWhenAllDescriptionsBlank() {
        let now = Date(timeIntervalSinceReferenceDate: 2000)
        let blanks = [frame("", at: 0), frame("   ", at: 1)]
        XCTAssertEqual(VisualContextBuilder.summaryText(blanks, now: now), "")
    }

    func testSummaryIncludesRelativeLabelsAndHeader() {
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        let now = base.addingTimeInterval(90)
        let frames = [
            frame("a kitchen counter", at: 0, base: base),   // 90s ago → minutes
            frame("a laptop", at: 60, base: base),           // 30s ago
            frame("a person's face", at: 90, base: base)     // now
        ]
        let text = VisualContextBuilder.summaryText(frames, now: now)
        XCTAssertTrue(text.hasPrefix("# Recent Visual Context"))
        XCTAssertTrue(text.contains("[T-1m] a kitchen counter"), text)
        XCTAssertTrue(text.contains("[T-30s] a laptop"), text)
        XCTAssertTrue(text.contains("[Now] a person's face"), text)
    }

    func testSummaryRespectsMaxInContextCap() {
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        let now = base.addingTimeInterval(100)
        let frames = (0..<10).map { frame("frame\($0)", at: TimeInterval($0), base: base) }
        let text = VisualContextBuilder.summaryText(frames, now: now, maxInContext: 3)
        // Only the last 3 described frames appear.
        XCTAssertFalse(text.contains("frame6"), text)
        XCTAssertTrue(text.contains("frame7"))
        XCTAssertTrue(text.contains("frame8"))
        XCTAssertTrue(text.contains("frame9"))
    }

    func testSummaryFiltersBlankAmongDescribed() {
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        let now = base.addingTimeInterval(10)
        let frames = [frame("seen", at: 0, base: base), frame("", at: 5, base: base)]
        let text = VisualContextBuilder.summaryText(frames, now: now)
        XCTAssertTrue(text.contains("seen"))
        // The blank one contributes no line.
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count, 1)
    }

    func testRelativeLabelBoundaries() {
        let t0 = Date(timeIntervalSinceReferenceDate: 5000)
        XCTAssertEqual(VisualContextBuilder.relativeLabel(from: t0, to: t0), "[Now]")
        XCTAssertEqual(VisualContextBuilder.relativeLabel(from: t0, to: t0.addingTimeInterval(45)), "[T-45s]")
        XCTAssertEqual(VisualContextBuilder.relativeLabel(from: t0, to: t0.addingTimeInterval(60)), "[T-1m]")
        XCTAssertEqual(VisualContextBuilder.relativeLabel(from: t0, to: t0.addingTimeInterval(150)), "[T-2m]")
        // Future capture reads as Now.
        XCTAssertEqual(VisualContextBuilder.relativeLabel(from: t0.addingTimeInterval(10), to: t0), "[Now]")
    }
}
