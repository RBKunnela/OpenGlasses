import Foundation

/// A structured "is this safe for me?" question (Plan AB).
struct HealthSafetyQuery: Equatable {
    enum Kind: Equatable { case canITake, canIEat }
    let kind: Kind
    /// The substance ("ibuprofen") or food ("aged cheese") in question.
    let subject: String
    /// Optional OCR'd label text (a captured medication/food label) to enrich matching.
    let capturedLabel: String?

    init(kind: Kind, subject: String, capturedLabel: String? = nil) {
        self.kind = kind
        self.subject = subject
        self.capturedLabel = capturedLabel
    }

    /// The full text to classify: spoken subject plus any captured label.
    var matchText: String {
        [subject, capturedLabel].compactMap { $0 }.joined(separator: " ")
    }
}

/// The vault entries selected as relevant to a query — grounds both the LLM prompt
/// and the deterministic rubric (Plan AB). Pure value type.
struct GroundingContext: Equatable {
    /// Current medications parsed from the vault, classified into drug classes.
    let medications: [Substance]
    /// Condition tags parsed from the vault (CKD, ulcer, gout, …).
    let conditions: Set<ConditionTag>
    /// Allergy entries (raw text, lowercased) — always included for safety.
    let allergies: [String]
    /// The raw vault lines selected to ground the prompt (for citation + the LLM).
    let citedLines: [String]

    var drugClassesInUse: Set<DrugClass> {
        medications.reduce(into: Set<DrugClass>()) { $0.formUnion($1.classes) }
    }
}
