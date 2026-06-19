import Foundation

/// The full contract for one structured-vision vertical (see docs/plans/structured-vision-assessment.md):
/// a JSON Schema (the forced tool `input_schema` / Gemini `responseSchema`), a system prompt, and an
/// adapter that maps the decoded payload onto a normalized `AssessmentCard`. Adding a vertical never
/// touches the renderer, the networking, or the tool — only a schema is registered.
///
/// Schemas are PURE (no MainActor, no network): `makeCard` is given an already-decoded JSON object.
protocol AssessmentSchema {
    /// Stable id used by the `vision_assess` tool's `kind` parameter.
    var kind: String { get }
    /// Human title for the card header.
    var title: String { get }
    /// The JSON Schema handed to the provider as a forced tool `input_schema` / `responseSchema`.
    var jsonSchema: [String: Any] { get }
    /// The system prompt for the assessment call. Implementations should include
    /// `AssessmentPrompt.instrumentFragment` so every vertical reads instruments for free.
    var systemPrompt: String { get }
    /// Findings/readings below this confidence are surfaced as a re-capture, not landed silently.
    var confidenceFloor: Double { get }

    /// Map the decoded model JSON onto a normalized card.
    func makeCard(from json: [String: Any], context: String?) throws -> AssessmentCard

    /// Deterministic guardrail run AFTER the model. May only ESCALATE tier / force an action —
    /// never downgrade. Default is identity.
    func backstop(_ card: AssessmentCard) -> AssessmentCard
}

extension AssessmentSchema {
    var confidenceFloor: Double { 0.4 }
    func backstop(_ card: AssessmentCard) -> AssessmentCard { card }

    /// Convenience: normalize readings, then push any reading below `confidenceFloor` into
    /// `stillNeeded` as a re-capture prompt. Schemas call this from `makeCard` before returning.
    func applyingReadingPolicy(to card: AssessmentCard) -> AssessmentCard {
        let normalized = card.normalizingReadings()
        let lowConfidence = normalized.readings.filter { $0.confidence < confidenceFloor }
        guard !lowConfidence.isEmpty else { return normalized }
        let recaptures = lowConfidence.map { "Re-capture the \($0.quantity) display (low confidence)." }
        return AssessmentCard(
            kind: normalized.kind, title: normalized.title, subtitle: normalized.subtitle,
            tier: normalized.tier, summary: normalized.summary, findings: normalized.findings,
            recommendedAction: normalized.recommendedAction,
            stillNeeded: normalized.stillNeeded + recaptures, readings: normalized.readings,
            confidence: normalized.confidence, disclaimer: normalized.disclaimer)
    }
}

/// Reusable system-prompt fragments shared across schemas.
enum AssessmentPrompt {
    /// The standing "read the instrument" instruction every schema should include, so instrument
    /// reading is picked up for free even by verticals not primarily about measurement.
    static let instrumentFragment = """
    Read any visible instrument, gauge, label, meter, thermometer, refractometer, or scale and report \
    each as a reading with its numeric value, the unit exactly as displayed, and a confidence 0.0–1.0. \
    Never guess an off-screen, blurry, or illegible value — lower the confidence instead of inventing a number.
    """
}

/// Errors a schema may throw while mapping model output.
enum AssessmentSchemaError: Error, LocalizedError {
    case unknownKind(String)
    case malformedPayload(String)

    var errorDescription: String? {
        switch self {
        case .unknownKind(let k): return "No assessment schema registered for kind '\(k)'."
        case .malformedPayload(let m): return "Assessment payload could not be mapped: \(m)"
        }
    }
}
