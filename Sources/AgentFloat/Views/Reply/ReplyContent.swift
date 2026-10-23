import AgentFloatCore
import SwiftUI

/// 답장 화면에서 띠·질문·선택지·입력 칸을 그리는 부분. 세 배치(패널 전환·줄 안·옆 카드)가 같이 쓴다 (설계 4.5)
struct ReplyContent: View {
    let center: ReplyCenter
    let session: AgentSession
    let actions: ReplyActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let strip = topStrip {
                strip
            }
            if showsEditor, let prompt = session.prompt, let editor = center.editor {
                editorContent(prompt: prompt, editor: editor)
                    .padding(.top, topStrip == nil ? 0 : ReplyLayout.navToContent)
                    .opacity(isSending ? 0.45 : 1)
                    .allowsHitTesting(!isSending && readOnly == nil)
            }
            if case let .sending(stage) = center.phase {
                DeliverySteps(current: stage).padding(.top, ReplyLayout.navToContent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 상태

    private var readOnly: ReadOnlyReason? {
        if case let .readOnly(reason)? = center.availability[session.key] { return reason }
        return nil
    }

    private var isSending: Bool {
        if case .sending = center.phase { return true }
        return false
    }

    /// 결과·실패 화면은 띠만 남긴다. 보내지 않은 결과와 편집 중에는 쓴 답을 그대로 보여 준다
    private var showsEditor: Bool {
        switch center.phase {
        case .editing, .sending: true
        case let .result(outcome):
            switch outcome {
            case .notSent(.alreadyAnswered), .notSent(.sessionEnded): false
            case .notSent: true
            case .delivered, .stopped, .mismatched: false
            }
        }
    }

    private var topStrip: ReplyStrip? {
        switch center.phase {
        case let .result(outcome):
            return strip(for: outcome)
        case .sending:
            return nil
        case .editing:
            if let notice = center.notice { return ReplyStrip(tone: .warn, strip: notice) }
            if let readOnly { return ReplyStrip(tone: readOnly == .permissionPrompt ? .warn : .info, strip: ReplyCopy.readOnly(readOnly)) }
            return nil
        }
    }

    private func strip(for outcome: DeliveryOutcome) -> ReplyStrip {
        switch outcome {
        case let .delivered(answer):
            return ReplyStrip(tone: .ok, strip: ReplyCopy.delivered(Self.describe(answer, prompt: session.prompt)))
        case let .notSent(reason):
            return notSentStrip(reason)
        case .stopped:
            return ReplyStrip(tone: .error, strip: ReplyCopy.stopped)
        case let .mismatched(sent, recorded?):
            return ReplyStrip(tone: .error, strip: ReplyCopy.mismatched, extra: [
                (ReplyCopy.sentAnswer, Self.describe(sent, prompt: session.prompt)),
                (ReplyCopy.recordedAnswer, Self.describe(recorded, prompt: session.prompt)),
            ])
        case .mismatched(_, nil):
            return ReplyStrip(tone: .error, strip: ReplyCopy.mismatchTimeout)
        }
    }

    private func notSentStrip(_ reason: NotSentReason) -> ReplyStrip {
        switch reason {
        case .alreadyAnswered: ReplyStrip(tone: .warn, strip: ReplyCopy.alreadyAnswered)
        case .questionChanged: ReplyStrip(tone: .warn, strip: ReplyCopy.questionChanged)
        case .sessionEnded: ReplyStrip(tone: .warn, strip: ReplyCopy.sessionEnded)
        case .terminalDraft: ReplyStrip(tone: .warn, strip: ReplyCopy.terminalDraft)
        case .unexpectedScreen: ReplyStrip(tone: .warn, strip: ReplyCopy.unexpectedScreen)
        case .unreadableScreen: ReplyStrip(tone: .warn, strip: ReplyCopy.unreadableScreen)
        case let .readOnly(readOnly): ReplyStrip(tone: .info, strip: ReplyCopy.readOnly(readOnly))
        }
    }

    /// 기록된 답을 사람이 읽는 한 줄로. 질문이 여럿이면 질문 순서대로 잇는다
    static func describe(_ answer: RecordedAnswer, prompt: PendingPrompt?) -> String {
        switch answer {
        case let .text(text):
            return text
        case let .choices(values):
            guard case let .choices(_, questions)? = prompt else { return values.values.sorted().joined(separator: " / ") }
            return questions.compactMap { values[$0.text] }.joined(separator: " / ")
        }
    }

    // MARK: 편집

    @ViewBuilder
    private func editorContent(prompt: PendingPrompt, editor: ReplyEditor) -> some View {
        switch prompt {
        case .choices:
            if editor.isReviewing {
                ReviewList(editor: editor, onEdit: actions.editQuestion)
            } else if let question = editor.currentQuestion {
                questionView(question, editor: editor)
            }
        case let .text(_, message):
            VStack(alignment: .leading, spacing: 0) {
                MessageTail(message: message)
                if readOnly == nil {
                    ReplyField(
                        placeholder: ReplyCopy.replyPlaceholder,
                        text: Binding(get: { editor.replyText }, set: { text in center.edit { $0.setReply(text) } }),
                        focusRequest: center.fieldFocusRequest
                    )
                    .padding(.top, ReplyLayout.optionsToField)
                    blockHint(editor.block)
                }
            }
        case let .permission(_, tool, summary):
            CommandBox(tool: tool, summary: summary)
        }
    }

    private func questionView(_ question: ChoiceQuestion, editor: ReplyEditor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let header = question.header, !header.isEmpty { HeaderChip(text: header) }
                Spacer(minLength: 0)
                if editor.questions.count > 1 { StepIndicator(step: editor.step, count: editor.questions.count) }
            }
            Text(question.text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, ReplyLayout.chipToQuestion)
            VStack(spacing: ReplyLayout.optionGap) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    OptionRow(
                        number: index + 1,
                        option: option,
                        isSelected: Self.isSelected(index, in: editor.answers[editor.step]),
                        multiSelect: question.multiSelect,
                        // 직접 입력을 시작하면 설명을 접어 칸이 위로 밀려 올라가지 않게 한다 (시안 2)
                        showsDescription: editor.otherText.isEmpty,
                        isEnabled: readOnly == nil,
                        onChoose: { center.choose(index) }
                    )
                }
            }
            .padding(.top, ReplyLayout.questionToOptions)
            if readOnly == nil, editor.acceptsOtherText {
                ReplyField(
                    placeholder: ReplyCopy.otherPlaceholder,
                    text: Binding(get: { editor.otherText }, set: { text in center.edit { $0.setOther(text) } }),
                    focusRequest: center.fieldFocusRequest
                )
                .padding(.top, ReplyLayout.optionsToField)
                blockHint(editor.block)
            }
        }
    }

    @ViewBuilder
    private func blockHint(_ block: TextBlock?) -> some View {
        if let block {
            Text(ReplyCopy.textBlock(block))
                .font(.system(size: 11))
                .foregroundStyle(Palette.askText)
                .padding(.top, 6)
                .padding(.horizontal, 2)
        }
    }

    private static func isSelected(_ index: Int, in answer: ChoiceAnswer?) -> Bool {
        switch answer {
        case let .option(chosen)?: chosen == index
        case let .options(chosen)?: chosen.contains(index)
        case .other?, nil: false
        }
    }
}

/// 질문 창의 머리표 칩 (10.5 Semibold, 주황 20%)
struct HeaderChip: View {
    let text: String

    @Environment(\.paintedGlassTone) private var paintedTone

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Palette.askText(on: paintedTone))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: ReplyLayout.chipHeight)
            .background(Palette.waiting.opacity(0.2), in: RoundedRectangle(cornerRadius: ReplyLayout.chipRadius))
    }
}

/// 질문이 여럿일 때 "1 / 2" + 진행 막대
struct StepIndicator: View {
    let step: Int
    let count: Int

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Text("\(min(step + 1, count)) / \(count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index <= step ? Palette.waiting : ReplyPalette.strongFill(scheme))
                        .frame(width: 14, height: 3)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("질문 \(min(step + 1, count)) / \(count)")
    }
}

/// 질문 여러 개의 확인 화면 "이렇게 보낼게요" (시안 4)
struct ReviewList: View {
    let editor: ReplyEditor
    let onEdit: (Int) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(ReplyCopy.review).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                StepIndicator(step: editor.questions.count - 1, count: editor.questions.count)
            }
            VStack(spacing: ReplyLayout.optionGap) {
                ForEach(Array(editor.questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            HeaderChip(text: question.header ?? "질문 \(index + 1)")
                            Spacer(minLength: 0)
                            Button(ReplyCopy.edit) { onEdit(index) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ReplyPalette.accent)
                        }
                        answerText(editor.answers[index], question: question)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReplyPalette.fill(scheme), in: RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
                }
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func answerText(_ answer: ChoiceAnswer?, question: ChoiceQuestion) -> some View {
        switch answer {
        case let .option(index)?:
            Text(question.options[index].displayLabel).font(.system(size: 13))
        case let .options(indices)?:
            Text(indices.sorted().map { question.options[$0].displayLabel }.joined(separator: ", ")).font(.system(size: 13))
        case let .other(text)?:
            Text("\(text)\(Text(" · \(ReplyCopy.fromOther)").font(.system(size: 11.5)).foregroundStyle(.secondary))")
                .font(.system(size: 13))
        case nil:
            EmptyView()
        }
    }
}

/// 본문 질문의 마지막 답변 끝부분. 묻는 말은 끝에 있으므로 위쪽을 흐리며 자른다 (시안 5)
struct MessageTail: View {
    let message: String

    @State private var showsAll = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tail = Self.tail(of: message)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ReplyCopy.lastMessage).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if tail.isTruncated, !showsAll {
                    Button(ReplyCopy.showAll) { showsAll = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ReplyPalette.accent)
                }
            }
            Text(Self.rendered(showsAll ? message : tail.text))
                .font(.system(size: 12.5))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: showsAll ? nil : ReplyLayout.messageMaxHeight, alignment: .bottom)
                .clipped()
                .padding(10)
                .background(ReplyPalette.fill(scheme), in: RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
                .overlay(alignment: .top) {
                    if tail.isTruncated, !showsAll {
                        LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: ReplyLayout.messageFade)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: ReplyLayout.innerRadius, topTrailingRadius: ReplyLayout.innerRadius))
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    static func tail(of message: String) -> (text: String, isTruncated: Bool) {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var truncated = false
        let lines = text.components(separatedBy: "\n")
        if lines.count > ReplyLayout.messageTailLines {
            text = lines.suffix(ReplyLayout.messageTailLines).joined(separator: "\n")
            truncated = true
        }
        if text.count > ReplyLayout.messageTailCharacters {
            text = "…" + String(text.suffix(ReplyLayout.messageTailCharacters))
            truncated = true
        }
        return (text, truncated)
    }

    /// 굵게·코드 정도만 살린다. 목록·제목 기호는 글자 그대로 둔다 (설계 6장 빌더 재량)
    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 승인 대기 세션이 실행하려는 명령 (시안 10의 승인 대기)
struct CommandBox: View {
    let tool: String
    let summary: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tool).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(2)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .background(ReplyPalette.well(scheme), in: RoundedRectangle(cornerRadius: ReplyLayout.innerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: ReplyLayout.innerRadius).strokeBorder(ReplyPalette.hairline(scheme), lineWidth: 0.5)
                    }
            }
        }
    }
}
