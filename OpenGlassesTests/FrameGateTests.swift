import XCTest
import UIKit
@testable import OpenGlasses

final class FrameGateTests: XCTestCase {

    // MARK: - PerceptualHash

    /// Render a solid-color square image at native size for hashing.
    private func solidImage(_ color: UIColor, size: CGFloat = 32) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(rect)
        }
    }

    /// A vertical split: left half `left`, right half `right`.
    private func splitImage(left: UIColor, right: UIColor, size: CGFloat = 32) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { ctx in
            left.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
            right.setFill()
            ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        }
    }

    func testHammingIsSymmetricAndEqualsPopcountXor() {
        let a: UInt64 = 0xF0F0_F0F0_F0F0_F0F0
        let b: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
        XCTAssertEqual(PerceptualHash.hamming(a, b), PerceptualHash.hamming(b, a))
        XCTAssertEqual(PerceptualHash.hamming(a, b), (a ^ b).nonzeroBitCount)
        XCTAssertEqual(PerceptualHash.hamming(a, a), 0)
    }

    func testIdenticalImagesHashEqual() {
        guard let h1 = PerceptualHash.dhash(splitImage(left: .black, right: .white)),
              let h2 = PerceptualHash.dhash(splitImage(left: .black, right: .white)) else {
            return XCTFail("dhash returned nil")
        }
        XCTAssertEqual(h1, h2)
    }

    func testSimilarImagesAreCloserThanDistinct() {
        // Same structure, slightly different right shade → near-identical hash.
        let base = splitImage(left: .black, right: .white)
        let nudged = splitImage(left: .black, right: UIColor(white: 0.95, alpha: 1))
        // Opposite gradient (white|black) flips the boundary bit in every row.
        let mirrored = splitImage(left: .white, right: .black)
        guard let hBase = PerceptualHash.dhash(base),
              let hNudged = PerceptualHash.dhash(nudged),
              let hMirror = PerceptualHash.dhash(mirrored) else {
            return XCTFail("dhash returned nil")
        }
        let similar = PerceptualHash.hamming(hBase, hNudged)
        let distinct = PerceptualHash.hamming(hBase, hMirror)
        XCTAssertLessThanOrEqual(similar, 2)
        XCTAssertGreaterThanOrEqual(distinct, 4)
        XCTAssertGreaterThan(distinct, similar)
    }

    func testDhashNilOnEmptyImage() {
        XCTAssertNil(PerceptualHash.dhash(UIImage()))
    }

    // MARK: - FrameGate

    func testFirstFrameAlwaysSends() {
        var gate = FrameGate(hammingThreshold: 4, heartbeat: 12)
        XCTAssertEqual(gate.evaluate(hash: 0xABCD, now: 0), .send)
    }

    func testNearDuplicateIsDropped() {
        var gate = FrameGate(hammingThreshold: 4, heartbeat: 100, adaptiveEnabled: false)
        XCTAssertEqual(gate.evaluate(hash: 0x0000_0000_0000_0000, now: 0), .send)
        // One bit different → Hamming 1 ≤ threshold 4 → drop.
        XCTAssertEqual(gate.evaluate(hash: 0x0000_0000_0000_0001, now: 1), .drop)
    }

    func testDistinctFrameIsSent() {
        var gate = FrameGate(hammingThreshold: 4, heartbeat: 100, adaptiveEnabled: false)
        XCTAssertEqual(gate.evaluate(hash: 0x0000_0000_0000_0000, now: 0), .send)
        // Many bits different → Hamming > threshold → send.
        XCTAssertEqual(gate.evaluate(hash: 0xFFFF_FFFF_FFFF_FFFF, now: 1), .send)
    }

    func testHeartbeatForcesSendEvenWhenDuplicate() {
        var gate = FrameGate(hammingThreshold: 4, heartbeat: 10, adaptiveEnabled: false)
        XCTAssertEqual(gate.evaluate(hash: 0x00, now: 0), .send)
        // Identical hash before deadline → drop.
        XCTAssertEqual(gate.evaluate(hash: 0x00, now: 5), .drop)
        // Identical hash at/after deadline → forced send.
        XCTAssertEqual(gate.evaluate(hash: 0x00, now: 10), .send)
    }

    func testAdaptiveWidensDropWindowInStaticScene() {
        // Distance of 6 is above the base threshold of 4 → would send without adaptation.
        let staticHash: UInt64 = 0x00
        let sixBits: UInt64 = 0b0011_1111  // 6 set bits → Hamming 6 vs 0

        var fixed = FrameGate(hammingThreshold: 4, heartbeat: 1000, adaptiveEnabled: false)
        XCTAssertEqual(fixed.evaluate(hash: staticHash, now: 0), .send)

        var adaptive = FrameGate(hammingThreshold: 4, heartbeat: 1000, adaptiveEnabled: true)
        XCTAssertEqual(adaptive.evaluate(hash: staticHash, now: 0), .send)
        // Feed several tiny-change frames to drive the EMA low, widening the window.
        for t in 1...6 { _ = adaptive.evaluate(hash: 0x01, now: TimeInterval(t)) }
        // With a low EMA the effective threshold rises above 6, so a 6-bit change drops…
        XCTAssertEqual(adaptive.evaluate(hash: sixBits, now: 100), .drop)
        // …whereas the non-adaptive gate sends the same 6-bit change.
        XCTAssertEqual(fixed.evaluate(hash: sixBits, now: 100), .send)
    }

    func testDedupRatioReflectsDrops() {
        var gate = FrameGate(hammingThreshold: 4, heartbeat: 1000, adaptiveEnabled: false)
        XCTAssertEqual(gate.dedupRatio, 0, accuracy: 0.0001)
        _ = gate.evaluate(hash: 0x00, now: 0)   // send
        _ = gate.evaluate(hash: 0x00, now: 1)   // drop
        _ = gate.evaluate(hash: 0x00, now: 2)   // drop
        _ = gate.evaluate(hash: 0xFFFF, now: 3) // send
        // 2 dropped of 4 evaluated.
        XCTAssertEqual(gate.dedupRatio, 0.5, accuracy: 0.0001)
    }

    func testResetClearsState() {
        var gate = FrameGate(hammingThreshold: 4, heartbeat: 1000, adaptiveEnabled: false)
        _ = gate.evaluate(hash: 0x00, now: 0)
        _ = gate.evaluate(hash: 0x00, now: 1)   // drop
        XCTAssertGreaterThan(gate.dedupRatio, 0)
        gate.reset()
        XCTAssertEqual(gate.dedupRatio, 0, accuracy: 0.0001)
        XCTAssertEqual(gate.evaluatedCount, 0)
        XCTAssertEqual(gate.droppedCount, 0)
        // After reset the next frame is treated as the first again → send.
        XCTAssertEqual(gate.evaluate(hash: 0x00, now: 2), .send)
    }
}
