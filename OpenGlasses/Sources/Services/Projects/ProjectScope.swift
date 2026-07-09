import Foundation

/// Pure project-scoping decisions (Plan AN). A "Project" is a `Persona` plus a
/// document namespace keyed by its id (`"global"` for the unscoped default).
enum ProjectScope {

    /// Whether the document knowledge-base tool should be advertised for a project
    /// holding `documentCount` documents — only when it actually has ≥1, so the model
    /// never offers retrieval over an empty knowledge base.
    static func shouldAdvertiseKB(documentCount: Int) -> Bool {
        documentCount > 0
    }

    /// A compact "Project Knowledge" prompt block grounding the model in the active
    /// project's documents, or `nil` when the project has none (nothing to advertise).
    static func knowledgeHint(projectName: String, documentCount: Int) -> String? {
        guard shouldAdvertiseKB(documentCount: documentCount) else { return nil }
        let noun = documentCount == 1 ? "document" : "documents"
        return """
        # Project Knowledge
        The active project "\(projectName)" has \(documentCount) saved \(noun). When the user asks \
        about them, use the document_knowledge tool (action 'query') to retrieve passages and ground \
        your answer — cite the document, and don't answer document questions from memory.
        """
    }
}
