import Foundation

/// PURE selection of the Health Vault entries relevant to a query (Plan AB), so the
/// prompt is grounded + small and the rubric has structured inputs. Operates on the
/// raw vault file text (the `@MainActor` advisor reads `VaultStore`; this stays pure
/// and headless-testable).
struct VaultGrounding {

    /// Build a `GroundingContext` from the relevant vault files.
    ///
    /// - Medications: every line that names a recognised drug is parsed into a
    ///   `Substance` (so the rubric sees the user's drug classes), plus the query's
    ///   own substance if it matches a med the user takes.
    /// - Conditions: tagged from the conditions file.
    /// - Allergies: **always** included (a query about an allergen must never be
    ///   dropped just because it's unrelated to the user's meds).
    func relevantEntries(for query: HealthSafetyQuery,
                         medicationsText: String,
                         conditionsText: String,
                         allergiesText: String) -> GroundingContext {
        let medLines = lines(in: medicationsText)
        let medications = medLines.compactMap { line -> Substance? in
            let s = SubstanceCatalog.substance(from: line)
            return s.isClassified ? s : nil
        }

        let conditions = SubstanceCatalog.conditionTags(in: conditionsText)

        let allergyLines = lines(in: allergiesText)

        // Cite: medication lines that share a drug class with the query (the directly
        // relevant ones), all condition lines, and all allergy lines.
        let querySubstance = SubstanceCatalog.substance(from: query.matchText)
        let relevantMedLines = medLines.filter { line in
            let s = SubstanceCatalog.substance(from: line)
            return !s.classes.isDisjoint(with: querySubstance.classes) || lineMentionsQuery(line, query: query)
        }
        let conditionLines = lines(in: conditionsText)
        let cited = (relevantMedLines + conditionLines + allergyLines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return GroundingContext(
            medications: medications,
            conditions: conditions,
            allergies: allergyLines.map { $0.lowercased() },
            citedLines: cited
        )
    }

    // MARK: - Helpers

    /// Content lines, dropping markdown headings, bullets-to-text, and blanks.
    private func lines(in text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                var l = line
                for prefix in ["- ", "* ", "• "] where l.hasPrefix(prefix) {
                    l = String(l.dropFirst(prefix.count))
                }
                return l
            }
    }

    private func lineMentionsQuery(_ line: String, query: HealthSafetyQuery) -> Bool {
        let subject = query.subject.lowercased().trimmingCharacters(in: .whitespaces)
        guard subject.count >= 3 else { return false }
        return line.lowercased().contains(subject)
    }
}
