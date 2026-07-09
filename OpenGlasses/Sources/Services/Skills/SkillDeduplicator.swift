import Foundation

/// Rejects a proposed skill that's too close to one we already have, so the suggestion inbox doesn't
/// fill with near-duplicates. Pure: name+trigger **Jaccard** and instruction-body **overlap**, each
/// above a threshold, against any existing draft. See [[SkillProposal]].
enum SkillDeduplicator {
    static func isDuplicate(_ candidate: SkillDraft,
                            against existing: [SkillDraft],
                            nameJaccard: Double = 0.6,
                            bodyOverlap: Double = 0.5) -> Bool {
        let cName = candidate.nameTokens
        let cBody = candidate.bodyTokens
        for other in existing {
            if jaccard(cName, other.nameTokens) >= nameJaccard { return true }
            if overlap(cBody, other.bodyTokens) >= bodyOverlap { return true }
        }
        return false
    }

    /// |A ∩ B| / |A ∪ B|.
    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    /// |A ∩ B| / min(|A|, |B|) — "is one body largely contained in the other".
    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let denom = min(a.count, b.count)
        guard denom > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(denom)
    }
}
