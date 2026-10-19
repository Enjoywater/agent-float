import AgentFloatCore
import SwiftUI

/// 접힌 알약과 펼친 패널 머리에 같은 모양으로 쓰여, 펼침이 접힘의 확대판으로 읽힌다 (spec 4.10)
struct SummaryRow: View {
    let summary: PillSummary

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if summary.isEmpty {
                // 숨기면 앱이 꺼졌는지 헷갈리므로 흐리게라도 남긴다 (spec 4.5)
                item(color: Palette.gray, count: 0).opacity(0.5)
            } else {
                if summary.waiting > 0 {
                    item(color: Palette.waiting, count: summary.waiting)
                    if summary.ask { tag("ASK", color: Palette.askText) }
                }
                if summary.running > 0 {
                    item(color: Palette.running, count: summary.running)
                }
                if summary.done > 0 {
                    item(color: Palette.done, count: summary.done)
                    if summary.new { tag("NEW", color: Palette.newText) }
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

    /// 꼬리는 바로 앞 개수에 딸린 말이라 항목 사이 간격보다 붙여 둔다
    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.leading, -4)
    }
}
