import AgentFloatCore
import AppKit
import Observation

@MainActor @Observable
final class AppModel {
    private(set) var sessions: [AgentSession] = []
    private(set) var groups: [SessionGroup] = []
    private(set) var summary = AppModel.emptySummary
    private(set) var unseen: Set<SessionKey> = []
    /// 보내기 실패 표시가 켜진 세션. 상태 묶음에서 빠져 "확인 필요" 묶음에만 나온다 (v1.2 설계 4.7)
    private(set) var failedKeys: Set<SessionKey> = []
    private(set) var failedSessions: [AgentSession] = []
    var isExpanded = false

    /// 창 크기는 SwiftUI 바깥(`PanelController`)이 정하므로, 표시 내용이 바뀐 순간을 따로 알려준다
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let navigators: NavigatorRegistry
    @ObservationIgnored private let focusProbes: [any FocusProbe]
    @ObservationIgnored private let activator: AppActivator
    @ObservationIgnored private let worker: SnapshotWorker
    @ObservationIgnored private var tracker = SignalTracker()
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var focusWatchTask: Task<Void, Never>?
    /// 앱별로 둔다. 한 앱의 자동화 권한이 거부돼도 다른 앱의 감시는 계속돼야 한다
    @ObservationIgnored private var focusWatchSchedules: [String: FocusWatchSchedule] = [:]
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

    init(store: SessionStore, navigators: NavigatorRegistry, focusProbes: [any FocusProbe], activator: AppActivator) {
        self.store = store
        self.navigators = navigators
        self.focusProbes = focusProbes
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
        // 지난 클릭이 바깥 앱을 기록한 뒤 실패했으면 그 기록이 남아, 이번 클릭이 엉뚱한 앱을 기다리게 된다
        if let pid = Self.sessionPid(of: session.locator) { _ = activator.takeFallbackChoice(forSession: pid) }
        do {
            try await navigators.navigate(to: session, timeout: Self.navigationTimeout)
        } catch {
            DebugLog.write("navigate failed session=\(session.key.sessionId) error=\(error)")
            // 그 터미널을 보지 못했으므로 NEW 는 그대로 둔다 (spec 4.6 해제 조건 1)
            NSSound.beep()
            return
        }
        // 자동화 권한이 다시 허용됐을 수 있는 시점이라 그 앱의 멈춰 둔 감시를 다시 시도한다 (R38)
        resumeFocusWatch(after: session)
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
        let activatedPid = Self.sessionPid(of: session.locator).flatMap { activator.takeFallbackChoice(forSession: $0) }
        guard let expected = ExpectedFrontmost.expected(for: session.locator, activatedPid: activatedPid) else { return false }
        let deadline = ContinuousClock.now + Self.arrivalWindow
        while true {
            let front = NSWorkspace.shared.frontmostApplication
            if expected.isReached(byBundle: front?.bundleIdentifier, pid: front?.processIdentifier) { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: Self.arrivalPollInterval)
        }
    }

    /// 바깥 앱을 실행해 봐야 고를 수 있는 이동만 그 선택을 세션 pid 로 기록한다
    private static func sessionPid(of locator: TerminalLocator) -> Int32? {
        switch locator {
        case let .application(pid), let .tmux(_, _, pid): pid
        case .ghostty, .orca, .background, .appleTerminal, .iTerm, .none: nil
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

        regroup()
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

    func setFailures(_ keys: Set<SessionKey>) {
        guard keys != failedKeys else { return }
        failedKeys = keys
        regroup()
        publishSignals()
        onChange?()
    }

    private func regroup() {
        let freshGroups = SessionGrouping.groups(sessions, excluding: failedKeys)
        if freshGroups != groups { groups = freshGroups }
        let freshFailed = SessionGrouping.failed(failedKeys, among: sessions)
        if freshFailed != failedSessions { failedSessions = freshFailed }
    }

    private func publishSignals() {
        let freshSummary = tracker.summary(of: sessions, failed: failedKeys)
        if freshSummary != summary { summary = freshSummary }
        if tracker.unseen != unseen { unseen = tracker.unseen }
        updateFocusWatch()
    }

    // MARK: 직접 선택 감지 (spec 4.6 해제 조건 2)

    private func schedule(for probe: any FocusProbe) -> FocusWatchSchedule {
        focusWatchSchedules[probe.bundleIdentifier] ?? FocusWatchSchedule()
    }

    /// 감시를 멈추지 않은 probe 가 짝지을 수 있는 미확인 세션
    private func watchableSessions(for probe: any FocusProbe) -> [AgentSession] {
        guard !schedule(for: probe).isSuspended else { return [] }
        return sessions.filter { tracker.unseen.contains($0.key) && probe.canProbe($0) }
    }

    private var watchedProbes: [any FocusProbe] {
        focusProbes.filter { !watchableSessions(for: $0).isEmpty }
    }

    /// 짝지을 수 있는 미확인 세션이 있을 때만 주기를 돌린다. 없을 때 깨어나지 않아야 유휴 CPU 가 0 에 머문다 (spec 4.9).
    /// 자동화 권한이 거부된 앱은 매번 실패할 osascript 를 띄우지 않도록 빼 둔다 (R38)
    private func updateFocusWatch() {
        let watched = watchedProbes
        guard !watched.isEmpty else {
            guard let task = focusWatchTask else { return }
            task.cancel()
            focusWatchTask = nil
            let suspended = focusWatchSchedules.filter(\.value.isSuspended).keys.sorted()
            DebugLog.write("focus watch off suspended=\(suspended)")
            return
        }
        guard focusWatchTask == nil else { return }
        DebugLog.write("focus watch on bundles=\(watched.map(\.bundleIdentifier))")
        focusWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.nextFocusInterval else { return }
                try? await Task.sleep(for: interval, tolerance: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                await self.checkFocus()
            }
        }
    }

    /// 실패가 이어진 앱만 간격이 늘어나므로, 감시 중인 앱 중 가장 짧은 간격으로 깨어난다
    private var nextFocusInterval: Duration {
        watchedProbes.map { schedule(for: $0).interval }.min() ?? FocusWatchSchedule.baseInterval
    }

    private func resumeFocusWatch(after session: AgentSession) {
        for probe in focusProbes where probe.canProbe(session) && schedule(for: probe).isSuspended {
            focusWatchSchedules[probe.bundleIdentifier]?.resume()
            DebugLog.write("focus watch resumed bundle=\(probe.bundleIdentifier)")
        }
        updateFocusWatch()
    }

    private func checkFocus() async {
        // 맨 앞 앱이 아니면 선택된 탭이 있어도 사용자가 보고 있는 화면이 아니다
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let probe = focusProbes.first(where: { $0.bundleIdentifier == front }) else { return }
        let candidates = watchableSessions(for: probe)
        guard !candidates.isEmpty else { return }
        let bundle = probe.bundleIdentifier
        var schedule = schedule(for: probe)
        do {
            let shown = try await probe.focusedSessions(among: candidates)
            schedule.recordSuccess()
            focusWatchSchedules[bundle] = schedule
            DebugLog.write("focus watch checked bundle=\(bundle) candidates=\(candidates.count) shown=\(shown.count)")
            markSeen(shown)
        } catch {
            schedule.recordFailure(error)
            focusWatchSchedules[bundle] = schedule
            DebugLog.write("focus watch failed bundle=\(bundle) error=\(error) next=\(schedule.interval) suspended=\(schedule.isSuspended)")
            if schedule.isSuspended { updateFocusWatch() }
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
