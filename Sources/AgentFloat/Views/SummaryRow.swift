import AgentFloatCore
import SwiftUI

/// Reuse the summary in pill and panel so expansion reads as an enlarged pill (spec §4.10).
struct SummaryRow: View {
    let summary: PillSummary

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.paintedGlassTone) private var paintedTone

    var body: some View {
        HStack(spacing: 10) {
            if summary.isEmpty {
                // Keep an empty pill dimly visible so users know the app is still running (spec §4.5).
                item(color: Palette.gray, count: 0).opacity(0.5)
            } else {
                // Interrupted deliveries need attention first, so place them ahead of other counts (v1.2 design §4.7).
                if summary.failed > 0 {
                    item(color: Palette.failed, count: summary.failed)
                    tag("FAIL", color: Palette.failText(on: paintedTone))
                }
                if summary.waiting > 0 {
                    item(color: Palette.waiting, count: summary.waiting)
                    if summary.ask { tag("ASK", color: Palette.askText(on: paintedTone)) }
                }
                if summary.running > 0 {
                    item(color: Palette.running, count: summary.running)
                }
                if summary.done > 0 {
                    item(color: Palette.done, count: summary.done)
                    if summary.new { tag("NEW", color: Palette.newText(on: paintedTone)) }
                }
                if summary.unknown > 0 {
                    item(color: Palette.gray, count: summary.unknown)
                }
            }
        }
        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        .animation(Motion.isReduced(systemReduceMotion) ? Motion.crossfade : Motion.spring, value: summary)
    }

    private func item(color: Color, count: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count)").contentTransition(.numericText(value: Double(count)))
        }
    }

    /// Keep the suffix close to its count rather than using inter-item spacing.
    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.leading, -4)
    }
}
