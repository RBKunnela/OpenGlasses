import Foundation

/// Persists HECA reports and exposes recent history (docs/plans/safety-assessment.md). A single JSON
/// file under Application Support, newest-first, capped at `maxHistory`. Directory + FileManager are
/// injectable for tests.
@MainActor
final class SafetyAssessmentStore: ObservableObject {
    static let shared = SafetyAssessmentStore()

    @Published private(set) var history: [SafetyReport] = []

    private let directory: URL
    private let fileManager: FileManager
    private let maxHistory: Int

    init(directory: URL? = nil, fileManager: FileManager = .default, maxHistory: Int = 50) {
        self.fileManager = fileManager
        self.maxHistory = maxHistory
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        load()
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SafetyAssessments", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    /// Save a report at the head of history (newest first), trimmed to `maxHistory`, and persist.
    func save(_ report: SafetyReport) {
        history.removeAll { $0.id == report.id }
        history.insert(report, at: 0)
        if history.count > maxHistory { history = Array(history.prefix(maxHistory)) }
        persist()
    }

    func clear() {
        history = []
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let reports = try? JSONDecoder().decode([SafetyReport].self, from: data) else { return }
        history = reports
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[SafetyAssessmentStore] persist failed: %@", error.localizedDescription)
        }
    }
}
