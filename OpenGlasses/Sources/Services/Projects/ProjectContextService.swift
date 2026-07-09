import Foundation

/// Supplies the active project's "Project Knowledge" prompt block to the system-
/// instruction builders (Plan AN), mirroring `FieldSessionService.shared.promptContext()`.
/// `@MainActor` to match the UI-tier stores it reads (`DocumentStore`) and the
/// builders that call it (`LLMService`, `GeminiLiveSessionManager`).
@MainActor
final class ProjectContextService {
    static let shared = ProjectContextService()

    /// Configured once by `AppState`.
    weak var documentStore: DocumentStore?
    /// Resolves the active project's namespace id and display name.
    var activeProjectId: (() -> String?)?
    var activeProjectName: (() -> String?)?

    private init() {}

    func configure(documentStore: DocumentStore,
                   activeProjectId: @escaping () -> String?,
                   activeProjectName: @escaping () -> String?) {
        self.documentStore = documentStore
        self.activeProjectId = activeProjectId
        self.activeProjectName = activeProjectName
    }

    /// The "Project Knowledge" block for injection, or `nil` when the active project
    /// has no documents (so the knowledge base isn't advertised over an empty scope).
    func promptContext() -> String? {
        guard let store = documentStore else { return nil }
        let namespace = activeProjectId?() ?? "global"
        let count = store.documentCount(namespace: namespace)
        let name = activeProjectName?() ?? "Global"
        return ProjectScope.knowledgeHint(projectName: name, documentCount: count)
    }
}
