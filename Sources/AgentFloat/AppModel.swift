import AgentFloatCore
import AppKit
import Observation

@MainActor @Observable
final class AppModel {
    private(set) var sessions: [AgentSession] = []
    private(set) var groups: [SessionGroup] = []
    private(set) var summary = AppModel.emptySummary
    private(set) var unseen: Set<SessionKey> = []
    var isExpanded = false

    /// 창 크기는 SwiftUI 바깥(`PanelController`)이 정하므로, 표시 내용이 바뀐 순간을 따로 알려준다
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let navigators: NavigatorRegistry
    @ObservationIgnored private let focusProbe: GhosttyFocusProbe
    @ObservationIgnored private let activator: AppActivator
    @ObservationIgnored private let worker: SnapshotWorker
    @ObservationIgnored private var tracker = SignalTracker()
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var ghosttyWatchTask: Task<Void, Never>?
    @ObservationIgnored private var ghosttyWatchSchedule = GhosttyWatchSchedule()
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var isNavigating = false
    @ObservationIgnored private var needsAnotherRefresh = false
    @ObservationIgnored private var issuedTickets = 0
    @ObservationIgnored private var appliedTicket = 0

    nonisolated static let emptySummary = PillSummary(waiting: 0, running: 0, done: 0, unknown: 0, ask: false, new: false)

    /// 파일 감시가 놓치는 변화(프로세스 종료, 오래 조용한 세션의 stale 전환)를 잡는 보조 주기 (spec 4.9)
    private static let pollInterval: Duration = .seconds(5)
    /// 첫 클릭은 Ghostty 자동화 승인 창에 답할 때까지 끝나지 않으므로 그 시간을 넉넉히 둔다 (R23)
    private static let navigationTimeout: Duration = .seconds(30)
    /// 활성화 요청은 비동기로 처리되므로 대상 앱이 앞에 오기를 이만큼 기다린 뒤에 판정한다 (R37)
    private static let arrivalWindow: Duration = .seconds(1)
    private static let arrivalPollInterval: Duration = .milliseconds(50)

    init(store: SessionStore, navigators: NavigatorRegistry, focusProbe: GhosttyFocusProbe, activator: AppActivator) {
        self.store = store
        self.navigators = navigators
        self.focusProbe = focusProbe
        self.activator = activator
        worker = SnapshotWorker(store: store)
    }

    func start() {
        guard pollTask == nil else { return }
        let watcher = DirectoryWatcher(directories: store.watchedDirectories) { [weak self] in
            self?.requestRefresh()
        }
        self.watcher = watcher
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval, tolerance: .seconds(1))
                guard let self else { return }
                // 처음 설치한 머신처럼 감시할 디렉터리가 나중에 생기는 경우를 주기마다 다시 붙인다
                self.watcher?.rescan()
                self.requestRefresh()
            }
        }
        requestRefresh()
    }

    /// snapshot 은 메인 밖에서, 반영은 메인에서 한다
    func refresh() async {
        issuedTickets += 1
        let ticket = issuedTickets
        let now = Date()
        let fresh = await worker.snapshot(now: now)
        // 직렬화돼 있어도 재개 순서까지 보장되지는 않아, 늦게 도착한 옛 결과가 새 결과를 덮지 않게 한다
        guard ticket > appliedTicket else { return }
        appliedTicket = ticket
        apply(fresh)
    }

    func canNavigate(_ session: AgentSession) -> Bool {
        navigators.canNavigate(session)
    }

    func activate(_ session: AgentSession) async {
        // 갈 곳을 모르는 줄은 hover 강조도 없어 누를 대상으로 보이지 않으므로 경고음도 내지 않는다 (spec 4.4)
        guard navigators.canNavigate(session) else { return }
        // 빠른 두 번 클릭이 이동과 경고음을 두 번씩 내지 않도록, 첫 이동의 판정이 끝날 때까지 다음 클릭은 버린다
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }
        do {
            try await navigators.navigate(to: session, timeout: Self.navigationTimeout)
        } catch {
            DebugLog.write("navigate failed session=\(session.key.sessionId) error=\(error)")
            // 그 터미널을 보지 못했으므로 NEW 는 그대로 둔다 (spec 4.6 해제 조건 1)
            NSSound.beep()
            return
        }
        // 자동화 권한이 다시 허용됐을 수 있는 시점이라 멈춰 둔 감시를 다시 시도한다 (R38)
        resumeGhosttyWatch()
        guard await targetCameForward(for: session) else {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            DebugLog.write("navigate unconfirmed session=\(session.key.sessionId) front=\(front)")
            NSSound.beep()
            return
        }
        DebugLog.write("navigate ok session=\(session.key.sessionId)")
        markSeen([session.key])
    }

    /// 명령이 성공해도 앱이 앞에 오지 않았다면 사용자는 아무것도 못 봤으므로 NEW 를 끄지 않는다 (R37)
    private func targetCameForward(for session: AgentSession) async -> Bool {
        var activatedPid: Int32?
        if case let .application(pid) = session.locator {
            activatedPid = activator.takeFallbackChoice(forSession: pid)
        }
        guard let expected = ExpectedFrontmost.expected(for: session.locator, activatedPid: activatedPid) else { return false }
        let deadline = ContinuousClock.now + Self.arrivalWindow
        while true {
            let front = NSWorkspace.shared.frontmostApplication
            if expected.isReached(byBundle: front?.bundleIdentifier, pid: front?.processIdentifier) { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: Self.arrivalPollInterval)
        }
    }

    /// 파일 감시와 주기 갱신이 겹쳐도 snapshot 은 한 번에 하나만 돌고, 그동안 들어온 요청은 한 번으로 합친다 (R20)
    private func requestRefresh() {
        guard !isRefreshing else {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherRefresh = false
                await self.refresh()
            } while self.needsAnotherRefresh
            self.isRefreshing = false
        }
    }

    /// 바뀐 것이 없으면 상태에 대입하지 않는다. 같은 값이라도 대입하면 화면이 다시 그려져 유휴 CPU가 0이 되지 않는다
    private func apply(_ fresh: [AgentSession]) {
        guard fresh != sessions else { return }
        tracker.ingest(fresh)
        sessions = fresh

        let freshGroups = SessionGrouping.groups(fresh)
        if freshGroups != groups { groups = freshGroups }
        publishSignals()

        DebugLog.write("refresh sessions=\(fresh.count) summary=w\(summary.waiting)/r\(summary.running)/d\(summary.done)/u\(summary.unknown) ask=\(summary.ask) new=\(summary.new)")
        onChange?()
    }

    /// 세션 목록이 그대로여도 확인만으로 NEW 가 꺼질 수 있어, `apply` 를 거치지 않고 신호와 창 크기를 바로 맞춘다
    private func markSeen(_ keys: Set<SessionKey>) {
        let before = tracker.unseen
        for key in keys { tracker.markSeen(key) }
        guard tracker.unseen != before else { return }
        publishSignals()
        DebugLog.write("marked seen count=\(before.count - tracker.unseen.count) new=\(summary.new)")
        onChange?()
    }

    private func publishSignals() {
        let freshSummary = tracker.summary(of: sessions)
        if freshSummary != summary { summary = freshSummary }
        if tracker.unseen != unseen { unseen = tracker.unseen }
        updateGhosttyWatch()
    }

    // MARK: Ghostty 직접 선택 감지 (spec 4.6 해제 조건 2)

    private var unseenGhosttySessions: [AgentSession] {
        sessions.filter { session in
            guard tracker.unseen.contains(session.key), case .ghostty = session.locator else { return false }
            return true
        }
    }

    /// 미확인 Ghostty 세션이 있을 때만 주기를 돌린다. 없을 때 깨어나지 않아야 유휴 CPU 가 0 에 머문다 (spec 4.9).
    /// 자동화 권한이 거부된 동안에는 매번 실패할 osascript 를 띄우지 않도록 멈춰 둔다 (R38)
    private func updateGhosttyWatch() {
        guard !unseenGhosttySessions.isEmpty, !ghosttyWatchSchedule.isSuspended else {
            guard let task = ghosttyWatchTask else { return }
            task.cancel()
            ghosttyWatchTask = nil
            DebugLog.write("ghostty watch off suspended=\(ghosttyWatchSchedule.isSuspended)")
            return
        }
        guard ghosttyWatchTask == nil else { return }
        DebugLog.write("ghostty watch on")
        ghosttyWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.ghosttyWatchSchedule.interval else { return }
                try? await Task.sleep(for: interval, tolerance: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                await self.checkGhosttyFocus()
            }
        }
    }

    private func resumeGhosttyWatch() {
        guard ghosttyWatchSchedule.isSuspended else { return }
        ghosttyWatchSchedule.resume()
        DebugLog.write("ghostty watch resumed")
        updateGhosttyWatch()
    }

    private func checkGhosttyFocus() async {
        // Ghostty 가 맨 앞이 아니면 선택된 탭이 있어도 사용자가 보고 있는 화면이 아니다
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front == TerminalBundle.ghostty else { return }
        let candidates = unseenGhosttySessions
        guard !candidates.isEmpty else { return }
        do {
            let shown = try await focusProbe.focusedSessions(among: candidates)
            ghosttyWatchSchedule.recordSuccess()
            DebugLog.write("ghostty watch checked candidates=\(candidates.count) shown=\(shown.count)")
            markSeen(shown)
        } catch {
            ghosttyWatchSchedule.recordFailure(error)
            DebugLog.write("ghostty watch failed error=\(error) next=\(ghosttyWatchSchedule.interval) suspended=\(ghosttyWatchSchedule.isSuspended)")
            if ghosttyWatchSchedule.isSuspended { updateGhosttyWatch() }
        }
    }
}

/// provider 가 느린 파일 I/O 동안 잠금을 쥐므로 snapshot 호출이 겹치지 않도록 한 줄로 세운다 (R20)
private actor SnapshotWorker {
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func snapshot(now: Date) -> [AgentSession] {
        store.snapshot(now: now)
    }
}
