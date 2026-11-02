import SwiftUI

/// Direct-input/reply field grows to five lines, then scrolls.
/// ReplyKeys handles Return/Escape/numbers first, checking IME composition; do not intercept them here.
struct ReplyField: View {
    let placeholder: String
    @Binding var text: String
    let focus: FieldFocus

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
            // Honor focus removal so reused fields do not retain another session's cursor.
            .onChange(of: focus) { isFocused = focus.wanted }
            .onAppear { isFocused = focus.wanted }
    }
}
