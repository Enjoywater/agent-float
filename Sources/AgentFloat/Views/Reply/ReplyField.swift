import SwiftUI

/// 직접 입력·답장 칸. 5줄까지 늘고 그 뒤 스크롤한다.
/// ⏎·esc·숫자는 패널의 키 감시가 먼저 받아(`ReplyKeys`) 한글 조합 중인지 보고 처리하므로 여기서는 받지 않는다
struct ReplyField: View {
    let placeholder: String
    @Binding var text: String
    let focusRequest: Int

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...ReplyLayout.fieldMaxLines)
            .focused($isFocused)
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(ReplyPalette.well(scheme), in: RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ReplyLayout.innerRadius).strokeBorder(ReplyPalette.hairline(scheme), lineWidth: 0.5)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: ReplyLayout.innerRadius + 1.5)
                        .stroke(ReplyPalette.accent.opacity(0.45), lineWidth: 3)
                        .padding(-1.5)
                }
            }
            .onChange(of: focusRequest) { isFocused = true }
            .onAppear { if focusRequest > 0 { isFocused = true } }
    }
}
