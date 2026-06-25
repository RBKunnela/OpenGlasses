import UIKit

/// Bounds an outgoing image so it stays within cloud vision-model limits before it is
/// base64-encoded into a request.
///
/// Anthropic's Messages API rejects an inline image larger than **5 MB** with a 400
/// (`image exceeds 5 MB maximum`) and downsamples anything over ~1568 px on the long edge
/// anyway. Ray-Ban glasses frames arrive small (the DAT stream is already downscaled), so
/// this never bites on the glasses path — but the iPhone-camera fallback
/// (`PhoneCameraSource`) and the photo tools capture at full sensor resolution, where a
/// 12 MP JPEG can clear 5 MB and fail the request on *exactly* the no-glasses path we rely
/// on for hardware-free development. This shrinks such images first; already-small images
/// pass through untouched, so the common glasses path pays nothing.
///
/// **Degenerate-frame guard (added Jun 2026):**
/// The glasses DAT stream occasionally emits a 1×1 single-component placeholder JPEG
/// (160 bytes) before the camera has a real frame. Anthropic returns 400
/// "Could not process image" for such frames, and because the message is added to the
/// conversation history *before* the API call, the corrupt content block becomes stuck —
/// every subsequent turn (even text-only) replays it and 400s, silencing the glasses
/// until the session is reset. `prepared(_:)` now returns `nil` for any image whose
/// decoded dimensions fall below `minDimension` on either axis, so callers can skip
/// the API call entirely rather than poisoning the context.
///
/// (Lesson cribbed from the `glassbridge` project's LEARNINGS.md, which hit this 400 with
/// native iPhone JPEGs, and from a Jun-2026 live incident on srv753644.hstgr.cloud.)
enum LLMImagePreparer {
    /// Longest edge (in pixels) we allow before downscaling — Anthropic's recommended ceiling.
    static let maxLongEdge: CGFloat = 1568
    /// Byte ceiling for the encoded JPEG, kept comfortably under Anthropic's 5 MB hard limit.
    static let maxBytes = 4_500_000
    /// Minimum pixel dimension on either axis. Images smaller than this are degenerate
    /// placeholders (e.g. 1×1 initialisation frames) and must not be sent to any vision API.
    static let minDimension = 32

    /// Returns JPEG `Data` within `maxLongEdge` / `maxBytes` where possible, or `nil` if
    /// the image is degenerate (too small, undecodable, or zero-dimension).
    ///
    /// Callers **must** treat a `nil` return as "skip the image" — do not fall back to
    /// sending the raw bytes, as that is what causes context poisoning.
    static func prepared(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), let cg = image.cgImage else {
            // Completely undecodable — drop it.
            return nil
        }

        // Degenerate-frame guard: reject 1×1 placeholders and any sub-threshold frame.
        guard cg.width >= minDimension, cg.height >= minDimension else {
            NSLog("[LLMImagePreparer] Dropping degenerate frame (%dx%d, %d bytes)",
                  cg.width, cg.height, data.count)
            return nil
        }

        let pxLongEdge = CGFloat(max(cg.width, cg.height))

        // Fast path: small enough in both dimensions and bytes — leave it exactly as-is.
        if data.count <= maxBytes && pxLongEdge <= maxLongEdge { return data }

        let resized = pxLongEdge > maxLongEdge ? downscale(cg, toLongEdge: maxLongEdge) : image

        // Step the JPEG quality down until the payload fits under the byte cap.
        for quality in [CGFloat(0.8), 0.65, 0.5, 0.35, 0.25] {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                return jpeg
            }
        }
        // Last resort: hardest compression even if still over (better than a guaranteed 400).
        return resized.jpegData(compressionQuality: 0.2) ?? data
    }

    private static func downscale(_ cg: CGImage, toLongEdge longEdge: CGFloat) -> UIImage {
        let pxLongEdge = CGFloat(max(cg.width, cg.height))
        let scale = longEdge / pxLongEdge
        let target = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // `target` is already in pixels; don't let Retina multiply it back up
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let source = UIImage(cgImage: cg)
        return renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
