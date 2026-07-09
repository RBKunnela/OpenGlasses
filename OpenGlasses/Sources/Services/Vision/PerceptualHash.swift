import Foundation
import UIKit

/// Perceptual hashing for cheap, content-aware frame comparison.
///
/// `dhash` produces a 64-bit difference hash: the image is downscaled to 9×8
/// grayscale and one bit is set per adjacent horizontal-pixel gradient (is the
/// left pixel brighter than its right neighbour?). Two visually similar frames
/// produce hashes with a small Hamming distance; distinct frames produce a
/// large one. Pure function of the image's pixels — no `Date`/randomness — so
/// it is fully headless-testable.
enum PerceptualHash {

    /// 64-bit dHash of a frame's luma. Returns `nil` if the image can't be read.
    static func dhash(_ image: UIImage) -> UInt64? {
        // dHash compares each pixel to its right neighbour, so we need one extra
        // column: a 9×8 grayscale buffer yields 8×8 = 64 gradient comparisons.
        let width = 9
        let height = 8
        guard let luma = grayscaleBytes(image, width: width, height: height) else { return nil }

        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<height {
            let rowStart = row * width
            for col in 0..<(width - 1) {
                let left = luma[rowStart + col]
                let right = luma[rowStart + col + 1]
                if left > right {
                    hash |= (UInt64(1) << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    /// Hamming distance between two hashes: the number of differing bits.
    /// Symmetric, and equal to `popcount(a ^ b)`.
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Render `image` into a tightly-packed `width`×`height` 8-bit grayscale
    /// buffer. Returns `nil` if a CoreGraphics context can't be created or the
    /// image has no backing `CGImage`/`CIImage`.
    private static func grayscaleBytes(_ image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var buffer = [UInt8](repeating: 0, count: width * height)
        let success: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cg = cgImage(from: image) {
                context.draw(cg, in: rect)
                return true
            }
            return false
        }
        return success ? buffer : nil
    }

    /// Resolve a `CGImage` from a `UIImage` backed by either a `CGImage` or a
    /// `CIImage` (e.g. frames produced from a pixel buffer).
    private static func cgImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        if let ci = image.ciImage {
            return CIContext().createCGImage(ci, from: ci.extent)
        }
        return nil
    }
}
