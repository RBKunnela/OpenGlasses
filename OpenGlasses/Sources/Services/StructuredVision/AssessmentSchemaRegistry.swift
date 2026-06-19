import Foundation

/// Central registry of structured-vision schemas keyed by `kind`
/// (see docs/plans/structured-vision-assessment.md). Verticals register a schema at startup; the
/// `vision_assess` tool and `StructuredVisionService` look one up by the `kind` parameter.
///
/// Registration happens once during app setup (single-threaded), after which the registry is read-only
/// on the main actor — so a plain dictionary is sufficient. Tests construct fresh instances.
final class AssessmentSchemaRegistry {
    static let shared = AssessmentSchemaRegistry()

    private var schemas: [String: AssessmentSchema] = [:]

    init() {}

    /// Register (or replace) a schema. Last registration for a `kind` wins.
    func register(_ schema: AssessmentSchema) {
        schemas[schema.kind] = schema
    }

    /// Look up a schema by `kind`, or `nil` if none is registered.
    func schema(for kind: String) -> AssessmentSchema? {
        schemas[kind]
    }

    /// All registered kinds, sorted — for tool descriptions and diagnostics.
    var kinds: [String] {
        schemas.keys.sorted()
    }

    /// Whether any schema is registered for `kind`.
    func contains(_ kind: String) -> Bool {
        schemas[kind] != nil
    }
}
