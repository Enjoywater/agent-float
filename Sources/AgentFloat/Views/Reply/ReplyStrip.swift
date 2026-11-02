import AgentFloatCore
import SwiftUI

/// Result, warning, and read-only strip: title plus explanation (design §4.6).
struct ReplyStrip: View {
    enum Tone {
        case ok, warn, error, info
    }

    let tone: Tone
    let strip: ReplyStrings.Strip
    var extra: [(String, String)] = []

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(strip.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !strip.detail.isEmpty {
                    Text(strip.detail)
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(extra, id: \.0) { label, value in
                    Text("\(Text(label).foregroundStyle(.secondary))  \(value)")
                        .font(.system(size: 11.5))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint, in: RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .ok: Palette.done
        case .warn: Palette.waiting
        case .error: ReplyPalette.failed
        case .info: Palette.gray
        }
    }

    private var tint: Color {
        tone == .info ? ReplyPalette.fill(scheme) : color.opacity(scheme == .dark ? 0.16 : 0.15)
    }

    private var icon: some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay {
                switch tone {
                case .ok: Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                case .warn, .error: Text("!").font(.system(size: 10.5, weight: .heavy))
                case .info: Text("i").font(.system(size: 10.5, weight: .heavy))
                }
            }
            .foregroundStyle(.white)
            .padding(.top, 1)
    }
}

/// Check G1–G4 in order while sending so users can see verification progress (design §4.6 #6).
struct DeliverySteps: View {
    let current: DeliveryStage

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(DeliveryStage.allCases, id: \.rawValue) { stage in
                HStack(spacing: 8) {
                    marker(for: stage).frame(width: 14, height: 14)
                    Text(LanguageSettings.shared.strings.reply.stages[stage.rawValue])
                        .font(.system(size: 12))
                        .foregroundStyle(style(for: stage))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(ReplyPalette.fill(scheme), in: RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LanguageSettings.shared.strings.reply.stages[current.rawValue])
    }

    private func style(for stage: DeliveryStage) -> HierarchicalShapeStyle {
        if stage.rawValue < current.rawValue { return .secondary }
        return stage == current ? .primary : .tertiary
    }

    @ViewBuilder
    private func marker(for stage: DeliveryStage) -> some View {
        if stage.rawValue < current.rawValue {
            Circle().fill(Palette.done).overlay {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
            }
        } else if stage == current {
            ProgressView().controlSize(.mini)
        } else {
            Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 10, height: 10)
        }
    }
}
