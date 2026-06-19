import SwiftUI

/// Renders any `AssessmentCard` (structured-vision plan, Phase 3) — tier chip, summary, instrument
/// readings, findings, recommended action, and "still needed". Generic over the schema: it knows
/// nothing about any vertical. AI attribution uses the coral accent.
struct AssessmentCardView: View {
    let card: AssessmentCard
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !card.summary.isEmpty {
                Text(card.summary).font(.subheadline).foregroundStyle(.primary)
            }

            if !card.readings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.readings) { reading in readingRow(reading) }
                }
            }

            if !card.findings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.findings) { finding in findingRow(finding) }
                }
            }

            if let action = card.recommendedAction, !action.isEmpty {
                Label(action, systemImage: "arrow.right.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tierColor)
            }

            if !card.stillNeeded.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(card.stillNeeded, id: \.self) { need in
                        Label(need, systemImage: "circle.dashed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            footer
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tierColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: card.tier.systemImage).foregroundStyle(tierColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.headline)
                Text("AI vision · \(card.tier.displayLabel)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppAccent.aiCoral)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    private func readingRow(_ reading: InstrumentReading) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(reading.quantity.capitalized).font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Self.fmt(reading.value)) \(reading.unit)")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                if let c = reading.canonical, let cu = reading.canonicalUnit, cu != reading.unit {
                    Text("\(Self.fmt(c)) \(cu)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func findingRow(_ finding: AssessmentFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color(for: finding.severity)).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.label).font(.subheadline)
                if let detail = finding.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Confidence \(Int((card.confidence * 100).rounded()))%")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let disclaimer = card.disclaimer, !disclaimer.isEmpty {
                Text(disclaimer).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Helpers

    private var tierColor: Color { color(for: card.tier) }

    private func color(for tier: AssessmentTier) -> Color {
        switch tier {
        case .ok: return .green
        case .caution: return .orange
        case .critical: return .red
        }
    }

    private static func fmt(_ value: Double) -> String { String(format: "%g", value) }
}

/// Overlay that presents the latest `AssessmentCard` over the main UI. Hosted by `RootView`.
struct AssessmentCardOverlay: View {
    @ObservedObject private var vision = StructuredVisionService.shared

    var body: some View {
        if let card = vision.latest {
            VStack {
                Spacer()
                AssessmentCardView(card: card) { vision.dismiss() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vision.latest)
        }
    }
}
