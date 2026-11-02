import AgentFloatCore
import Foundation
import Observation

enum ReplyPhase: Equatable {
    case editing
    case sending(DeliveryStage)
    case result(DeliveryOutcome)

    /// Once any key is sent, keep the result visible even if the session stops waiting (design §4.7).
    var sentKeys: Bool {
        switch self {
        case .editing: false
        case .sending: true
        case let .result(outcome):
            if case .notSent = outcome { false } else { true }
        }
    }
}

/// Inject availability and delivery functions so fake rendering checks exercise the same UI path.
struct ReplyBackend: Sendable {
    typealias Deliver = @Sendable (ReplyDraft, PendingPrompt, AgentSession, @escaping @Sendable (DeliveryStage) -> Void) async -> DeliveryOutcome

    let availability: @Sendable (AgentSession) async -> ConsoleAvailability
    let deliver: Deliver
}

/// Reply-view state; keep drafts in memory by question ID and discard them when the app exits (design §4.7).
@MainActor @Observable
final class ReplyCenter {
    private(set) var openSession: AgentSession?
    private(set) var editors: [String: ReplyEditor] = [:]
    private(set) var availability: [SessionKey: ConsoleAvailability] = [:]
    private(set) var phase: ReplyPhase = .editing
    /// Retain interrupted or mismatched deliveries until the user acknowledges them.
    private(set) var failures: [SessionKey: DeliveryOutcome] = [:]
    /// Show changes occurring while open, such as a replaced question, in a strip.
    private enum Notice { case questionChanged, sessionEnded, alreadyAnswered }
    private var noticeKind: Notice?
    var notice: ReplyStrings.Strip? {
        switch noticeKind {
        case .questionChanged: LanguageSettings.shared.strings.reply.questionChanged
        case .sessionEnded: LanguageSettings.shared.strings.reply.sessionEnded
        case .alreadyAnswered: LanguageSettings.shared.strings.reply.alreadyAnswered
        case nil: nil
        }
    }
    /// Reset focus by prompt type on every open: text prompts focus input; dialogs keep number keys for options.
    private(set) var fieldFocus = FieldFocus()

    /// Notify when content height requires remeasuring the window.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Notify automatic returns to the list; the panel restores width and keyboard ownership.
    @ObservationIgnored var onAutoClose: (() -> Void)?
    @ObservationIgnored var onFailuresChange: ((Set<SessionKey>) -> Void)?

    @ObservationIgnored private let backend: ReplyBackend
    @ObservationIgnored private var autoReturnTask: Task<Void, Never>?
    /// Delivery survives closing the view; reopening shows its current stage and prevents duplicate sends (design §4.4).
    @ObservationIgnored private var inFlight: [SessionKey: DeliveryStage] = [:]

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

    // MARK: Opening and closing

    /// Open failure results even if the original question has disappeared.
    func open(_ session: AgentSession) {
        let failure = failures[session.key]
        guard session.prompt != nil || failure != nil else { return }
        autoReturnTask?.cancel()
        openSession = session
        if let prompt = session.prompt, editors[prompt.id] == nil { editors[prompt.id] = ReplyEditor(prompt: prompt) }
        if let stage = inFlight[session.key] {
            phase = .sending(stage)
        } else {
            phase = failure.map(ReplyPhase.result) ?? .editing
        }
        noticeKind = nil
        refreshAvailability()
        fieldFocus.set(phase == .editing && Self.isBodyQuestion(session.prompt))
    }

    func close() {
        autoReturnTask?.cancel()
        openSession = nil
        phase = .editing
        noticeKind = nil
        fieldFocus.set(false)
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

    /// Recheck returns unsent results to editing and reassesses availability.
    func recheck() {
        guard case let .result(outcome) = phase, case .notSent = outcome else { return }
        phase = .editing
        refreshAvailability()
        onChange?()
    }

    func requestFieldFocus() {
        fieldFocus.set(true)
    }

    /// Clear focus requests on Tab/Escape or a redrawn field would reclaim the cursor.
    func releaseFieldFocus() {
        fieldFocus.set(false)
    }

    private static func isBodyQuestion(_ prompt: PendingPrompt?) -> Bool {
        if case .text? = prompt { true } else { false }
    }

    // MARK: Editing

    func edit(_ change: (inout ReplyEditor) -> Void) {
        guard phase == .editing, let id = openSession?.prompt?.id, var editor = editors[id] else { return }
        let step = editor.step
        change(&editor)
        editors[id] = editor
        // Do not carry field focus into the next question, where number keys should select options.
        if editor.step != step { fieldFocus.set(false) }
        onChange?()
    }

    func choose(_ option: Int) {
        edit { $0.choose(option: option) }
    }

    /// Return/primary action advances multi-question prompts to the next question or confirmation; otherwise send.
    func primary() {
        guard phase == .editing, let editor else { return }
        switch editor.primary {
        case .next: edit { $0.advance() }
        case .send: send()
        case .disabled: break
        }
    }

    // MARK: Sending

    func send() {
        // Block only confirmed read-only states while availability is pending; delivery G2 checks again.
        guard phase == .editing, let session = openSession, let prompt = session.prompt, let draft = editor?.draft,
              inFlight[session.key] == nil, availability[session.key].map({ $0 == .ready }) ?? true else { return }
        inFlight[session.key] = .sameQuestion
        phase = .sending(.sameQuestion)
        onChange?()
        let backend = backend
        // This object survives for the app lifetime; strong capture avoids weak references crossing nested Sendable closures.
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
        guard inFlight[key] != nil else { return }
        inFlight[key] = stage
        guard openKey == key, case .sending = phase else { return }
        phase = .sending(stage)
    }

    private func finish(_ outcome: DeliveryOutcome, session: AgentSession, prompt: PendingPrompt) {
        DebugLog.write("reply outcome session=\(session.key.sessionId) outcome=\(outcome)")
        inFlight[session.key] = nil
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
            noticeKind = .questionChanged
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

    /// Clear failures only on explicit close, terminal opening, or navigation to that session.
    func acknowledgeFailure(_ key: SessionKey) {
        guard failures.removeValue(forKey: key) != nil else { return }
        onFailuresChange?(Set(failures.keys))
        if openKey == key, case .result = phase { phase = .editing }
    }

    // MARK: Changes while open

    func sync(with sessions: [AgentSession]) {
        let byKey = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        let pendingIds = Set(sessions.compactMap { $0.status == .waiting ? $0.prompt?.id : nil })
        let openPromptId = openSession?.prompt?.id
        // Discard drafts when the question changes or the session stops waiting.
        editors = editors.filter { pendingIds.contains($0.key) || ($0.key == openPromptId && phase.sentKeys) }
        let before = failures.count
        failures = failures.filter { byKey[$0.key] != nil }
        if failures.count != before { onFailuresChange?(Set(failures.keys)) }

        guard let open = openSession else { return }
        // Preserve sending views and results after any key was sent.
        if phase.sentKeys { return }
        guard let current = byKey[open.key] else {
            noticeKind = .sessionEnded
            replaceNotSentReason(with: .sessionEnded)
            scheduleAutoReturn()
            onChange?()
            return
        }
        if current.status != .waiting {
            noticeKind = .alreadyAnswered
            replaceNotSentReason(with: .alreadyAnswered)
            scheduleAutoReturn()
            onChange?()
            return
        }
        if let prompt = current.prompt, prompt.id != open.prompt?.id {
            openSession = current
            editors[prompt.id] = ReplyEditor(prompt: prompt)
            phase = .editing
            noticeKind = .questionChanged
            fieldFocus.set(Self.isBodyQuestion(prompt))
            refreshAvailability()
            onChange?()
            return
        }
        if current != open { openSession = current }
        refreshAvailability()
    }

    /// Unsent results explain why rather than showing strips; refresh the reason when answered elsewhere or ended.
    private func replaceNotSentReason(with reason: NotSentReason) {
        guard case .result(.notSent) = phase else { return }
        phase = .result(.notSent(reason))
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

/// A changed serial updates existing fields; newly rendered fields use wanted on appearance.
/// A cursor inherited from another question turns number-key choices into text and can send the wrong answer (final review C1).
struct FieldFocus: Equatable {
    private(set) var serial = 0
    private(set) var wanted = false

    mutating func set(_ wanted: Bool) {
        serial += 1
        self.wanted = wanted
    }
}
