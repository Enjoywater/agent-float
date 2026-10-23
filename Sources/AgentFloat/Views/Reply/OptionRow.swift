import AgentFloatCore
import SwiftUI

/// 선택지 한 줄. 번호 키 → 고르면 채운 원 체크(여러 개 고르기는 체크 상자 모양), 라벨, 추천 배지, 설명 (설계 4.8, 시안 1)
struct OptionRow: View {
    let number: Int
    let option: ChoiceOption
    let isSelected: Bool
    let multiSelect: Bool
    let showsDescription: Bool
    let isEnabled: Bool
    let onChoose: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if isEnabled { marker }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.displayLabel)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if option.isRecommended { badge }
                }
                if showsDescription, let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 0.5)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(background, in: RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: ReplyLayout.innerRadius)
                    .strokeBorder(ReplyPalette.accent.opacity(0.85), lineWidth: 1)
            }
        }
        .opacity(isEnabled ? 1 : 0.7)
        .contentShape(RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
        .onHover { isHovered = $0 && isEnabled }
        .onTapGesture { if isEnabled { onChoose() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var marker: some View {
        if isSelected {
            let shape = multiSelect ? AnyShape(RoundedRectangle(cornerRadius: ReplyLayout.keycapRadius)) : AnyShape(Circle())
            shape
                .fill(ReplyPalette.accent)
                .frame(width: ReplyLayout.keycapSize, height: ReplyLayout.keycapSize)
                .overlay {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
        } else {
            Text(number <= 9 ? "\(number)" : "")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: ReplyLayout.keycapSize, height: ReplyLayout.keycapSize)
                .background(ReplyPalette.strongFill(scheme), in: RoundedRectangle(cornerRadius: ReplyLayout.keycapRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: ReplyLayout.keycapRadius).strokeBorder(ReplyPalette.hairline(scheme), lineWidth: 0.5)
                }
        }
    }

    private var badge: some View {
        Text(ReplyCopy.recommended)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(ReplyPalette.accent)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 6)
            .background(ReplyPalette.accent.opacity(0.18), in: Capsule())
            .fixedSize()
    }

    private var background: Color {
        if isSelected { return ReplyPalette.accent.opacity(0.2) }
        return isHovered ? ReplyPalette.strongFill(scheme) : ReplyPalette.fill(scheme)
    }

    private var accessibilityText: String {
        var parts = ["\(number)번", option.displayLabel]
        if option.isRecommended { parts.append(ReplyCopy.recommended) }
        if isSelected { parts.append("선택됨") }
        return parts.joined(separator: ", ")
    }
}
