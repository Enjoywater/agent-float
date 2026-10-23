import AgentFloatCore
import Foundation
import Observation

enum ReplyPhase: Equatable {
    case editing
    case sending(DeliveryStage)
    case result(DeliveryOutcome)

    /// 키가 한 번이라도 들어갔는지. 들어간 뒤에는 세션이 대기를 벗어나도 결과 화면을 저절로 닫지 않는다 (설계 4.7)
    var sentKeys: Bool {
        switch self {
        case .editing: false
        case .sending: true
        case let .result(outcome):
            if case .notSent = outcome { false } else { true }
        }
    }
}

/// 가능 여부 판정과 보내기를 함수로 받는다. 화면 확인용 가짜 동작이 실제와 같은 경로로 들어오게 하려는 것이다
struct ReplyBackend: Sendable {
    typealias Deliver = @Sendable (ReplyDraft, PendingPrompt, AgentSession, @escaping @Sendable (DeliveryStage) -> Void) async -> DeliveryOutcome

    let availability: @Sendable (AgentSession) async -> ConsoleAvailability
    let deliver: Deliver
}

/// 답장 화면의 상태. 쓰다 만 답은 질문 id 별로 메모리에만 두어 앱을 끄면 사라진다 (설계 4.7)
@MainActor @Observable
final class ReplyCenter {
    private(set) var openSession: AgentSession?
    private(set) var editors: [String: ReplyEditor] = [:]
    private(set) var availability: [SessionKey: ConsoleAvailability] = [:]
    private(set) var phase: ReplyPhase = .editing
    /// 보내다 멈췄거나 기록이 달랐던 세션. 사용자가 확인할 때까지 남는다
    private(set) var failures: [SessionKey: DeliveryOutcome] = [:]
    /// 열려 있는 동안 생긴 변화(질문 바뀜 등)를 띠로 알린다
    private(set) var notice: ReplyCopy.Strip?
    /// 값이 바뀔 때마다 입력 칸에 커서를 둔다. 본문 질문은 열자마자 쓸 수 있어야 한다
    private(set) var fieldFocusRequest = 0

    /// 내용 높이가 바뀌어 창 크기를 다시 재야 할 때
    @ObservationIgnored var onChange: (() -> Void)?
    /// 저절로 목록으로 돌아갈 때. 창 폭과 키 입력을 되돌리는 일은 패널이 한다
    @ObservationIgnored var onAutoClose: (() -> Void)?
    @ObservationIgnored var onFailuresChange: ((Set<SessionKey>) -> Void)?

    @ObservationIgnored private let backend: ReplyBackend
    @ObservationIgnored private var autoReturnTask: Task<Void, Never>?

    init(backend: ReplyBackend) {
        self.backend = backend
    }

    var openKey: SessionKey? { openSession?.key }

    var editor: ReplyEditor? {
        openSession?.prompt.flatMap { editors[$0.id] }
    }

    func hasDraft(for session: AgentSession) -> Bool {
        guard let id = session.prompt?.id, let editor = editors[id] else { return false }
        return editor.answers.contains { $0 != nil } || !editor.replyText.isEmpty
    }

    // MARK: 열기·닫기

    /// 실패 표시가 켜진 세션은 질문이 이미 사라졌어도 실패 화면을 연다
    func open(_ session: AgentSession) {
        let failure = failures[session.key]
        guard session.prompt != nil || failure != nil else { return }
        autoReturnTask?.cancel()
        openSession = session
        if let prompt = session.prompt, editors[prompt.id] == nil { editors[prompt.id] = ReplyEditor(prompt: prompt) }
        phase = failure.map(ReplyPhase.result) ?? .editing
        notice = nil
        refreshAvailability()
        if case .text? = session.prompt, failure == nil { fieldFocusRequest += 1 }
    }

    func close() {
        autoReturnTask?.cancel()
        openSession = nil
        phase = .editing
        notice = nil
    }

    func refreshAvailability() {
        guard let session = openSession else { return }
        let backend = backend
        Task { [weak self] in
            let verdict = await backend.availability(session)
            guard let self, self.openKey == session.key else { return }
            if self.availability[session.key] != verdict { DebugLog.write("reply availability session=\(session.key.sessionId) \(verdict)") }
            self.availability[session.key] = verdict
            self.onChange?()
        }
    }

    /// "다시 확인": 보내지 않은 결과에서 편집으로 돌아가며 가능 여부를 다시 본다
    func recheck() {
        guard case let .result(outcome) = phase, case .notSent = outcome else { return }
        phase = .editing
        refreshAvailability()
        onChange?()
    }

    func requestFieldFocus() {
        fieldFocusRequest += 1
    }

    // MARK: 편집

    func edit(_ change: (inout ReplyEditor) -> Void) {
        guard phase == .editing, let id = openSession?.prompt?.id, var editor = editors[id] else { return }
        change(&editor)
        editors[id] = editor
        onChange?()
    }

    func choose(_ option: Int) {
        edit { $0.choose(option: option) }
    }

    /// ⏎ 와 주요 버튼. 질문이 여럿이면 다음 질문·확인 화면으로, 아니면 보낸다
    func primary() {
        guard phase == .editing, let editor else { return }
        switch editor.primary {
        case .next: edit { $0.advance() }
        case .send: send()
        case .disabled: break
        }
    }

    // MARK: 보내기

    func send() {
        // 가능 여부는 비동기로 판정되어 아직 모를 수 있다. 보기만으로 확정된 경우만 막고, 나머지는 전달기의 G2 가 다시 확인한다
        guard phase == .editing, let session = openSession, let prompt = session.prompt, let draft = editor?.draft,
              availability[session.key].map({ $0 == .ready }) ?? true else { return }
        phase = .sending(.sameQuestion)
        onChange?()
        let backend = backend
        // 앱이 끝날 때까지 살아 있는 객체라 강하게 잡아도 된다. 약한 참조를 중첩 클로저로 넘기면 Sendable 경계를 넘지 못한다
        let center = self
        let key = session.key
        Task {
            let outcome = await backend.deliver(draft, prompt, session) { stage in
                Task { @MainActor in center.reached(stage, for: key) }
            }
            center.finish(outcome, session: session, prompt: prompt)
        }
    }

    private func reached(_ stage: DeliveryStage, for key: SessionKey) {
        guard openKey == key, case .sending = phase else { return }
        phase = .sending(stage)
    }

    private func finish(_ outcome: DeliveryOutcome, session: AgentSession, prompt: PendingPrompt) {
        DebugLog.write("reply outcome session=\(session.key.sessionId) outcome=\(outcome)")
        switch outcome {
        case .delivered, .notSent(.alreadyAnswered), .notSent(.sessionEnded):
            editors[prompt.id] = nil
        case .stopped, .mismatched:
            failures[session.key] = outcome
            onFailuresChange?(Set(failures.keys))
        case .notSent:
            break
        }
        guard openKey == session.key else { return }
        if case .notSent(.questionChanged) = outcome {
            phase = .editing
            notice = ReplyCopy.questionChanged
        } else {
            phase = .result(outcome)
        }
        onChange?()
        switch outcome {
        case .delivered, .notSent(.alreadyAnswered), .notSent(.sessionEnded):
            scheduleAutoReturn()
        default:
            break
        }
    }

    /// 실패 화면의 "닫기"·"터미널에서 열기" 또는 그 줄로 이동했을 때만 실패 표시를 끈다
    func acknowledgeFailure(_ key: SessionKey) {
        guard failures.removeValue(forKey: key) != nil else { return }
        onFailuresChange?(Set(failures.keys))
        if openKey == key, case .result = phase { phase = .editing }
    }

    // MARK: 열려 있는 동안의 변화

    func sync(with sessions: [AgentSession]) {
        let byKey = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        let pendingIds = Set(sessions.compactMap { $0.status == .waiting ? $0.prompt?.id : nil })
        let openPromptId = openSession?.prompt?.id
        // 질문이 바뀌었거나 대기를 벗어난 세션의 쓰다 만 답은 버린다
        editors = editors.filter { pendingIds.contains($0.key) || ($0.key == openPromptId && phase.sentKeys) }
        let before = failures.count
        failures = failures.filter { byKey[$0.key] != nil }
        if failures.count != before { onFailuresChange?(Set(failures.keys)) }

        guard let open = openSession else { return }
        // 보내는 중이거나 키가 들어간 결과 화면은 그대로 둔다
        if phase.sentKeys { return }
        guard let current = byKey[open.key] else {
            notice = ReplyCopy.sessionEnded
            scheduleAutoReturn()
            onChange?()
            return
        }
        if current.status != .waiting {
            notice = ReplyCopy.alreadyAnswered
            scheduleAutoReturn()
            onChange?()
            return
        }
        if let prompt = current.prompt, prompt.id != open.prompt?.id {
            openSession = current
            editors[prompt.id] = ReplyEditor(prompt: prompt)
            phase = .editing
            notice = ReplyCopy.questionChanged
            refreshAvailability()
            onChange?()
            return
        }
        if current != open { openSession = current }
        refreshAvailability()
    }

    private func scheduleAutoReturn() {
        autoReturnTask?.cancel()
        autoReturnTask = Task { [weak self] in
            try? await Task.sleep(for: ReplyLayout.autoReturn)
            guard !Task.isCancelled, let self else { return }
            self.close()
            self.onAutoClose?()
        }
    }
}
