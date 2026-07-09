import Foundation

/// A single visually-distinct moment the live agent saw through the camera.
///
/// The image itself is *referenced* (`thumbnailRef`), not inlined, so the rolling
/// `VisualStateMemory` buffer stays light — descriptions are what the agent reads;
/// thumbnails are fetched only when a turn opts into sending them.
struct Keyframe: Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    let description: String
    let thumbnailRef: URL?

    init(id: UUID = UUID(), capturedAt: Date, description: String, thumbnailRef: URL? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.description = description
        self.thumbnailRef = thumbnailRef
    }
}
