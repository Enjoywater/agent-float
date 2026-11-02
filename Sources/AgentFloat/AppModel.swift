import AgentFloatCore
import AppKit
import Observation

@MainActor @Observable
final class AppModel {
    private(set) var sessions: [AgentSession] = []
    private(set) var groups: [SessionGroup] = []
    private(set) var summary = AppModel.emptySummary
    private(set) var unseen: Set<SessionKey> = []
    /// Sessions with send failures appear only in the needs-attention group (v1.2 design §4.7).
    private(set) var failedKeys: Set<SessionKey> = []
    private(set) var failedSessions: [AgentSession] = []
    var isExpanded = false

    /// Notify PanelController when content changes because window sizing lives outside SwiftUI.
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
    /// Keep schedules per app so an Automation denial does not stop other apps' probes.
    @ObservationIgnored private var focusWatchSchedules: [String: FocusWatchSchedule] = [:]
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var isNavigating = false
    @ObservationIgnored private var needsAnotherRefresh = false
    @ObservationIgnored private var issuedTickets = 0
    @ObservationIgnored private var appliedTicket = 0

    nonisolated static let emptySummary = PillSummary(waiting: 0, running: 0, done: 0, unknown: 0, ask: false, new: false)

    /// Polling catches process exits and stale transitions that file watching cannot detect (spec §4.9).
    private static let pollInterval: Duration = .seconds(5)
    /// Allow time to answer Ghostty's first Automation permission prompt (R23).
    private static let navigationTimeout: Duration = .seconds(30)
    /// Activation is asynchronous; allow the target app to reach the foreground before confirmation (R37).
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
                // Retry attaching watchers when a directory appears after installation.
                self.watcher?.rescan()
                self.requestRefresh()
            }
        }
        requestRefresh()
    }

    /// Read snapshots off-main and apply them on-main.
    func refresh() async {
        issuedTickets += 1
        let ticket = issuedTickets
        let now = Date()
        let fresh = await worker.snapshot(now: now)
        // Serialization does not guarantee resume order; prevent older results from overwriting newer ones.
        guard ticket > appliedTicket else { return }
        appliedTicket = ticket
        apply(fresh)
    }

    func canNavigate(_ session: AgentSession) -> Bool {
        navigators.canNavigate(session)
    }

    func activate(_ session: AgentSession) async {
        // Unlocatable rows have no hover affordance, so clicking them should not beep (spec §4.4).
        guard navigators.canNavigate(session) else { return }
        // Ignore repeated clicks until confirmation completes to avoid duplicate navigation and beeps.
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }
        // Discard a previous failed navigation's recorded app before confirming this click.
        if let pid = Self.sessionPid(of: session.locator) { _ = activator.takeFallbackChoice(forSession: pid) }
        do {
            try await navigators.navigate(to: session, timeout: Self.navigationTimeout)
        } catch {
            DebugLog.write("navigate failed session=\(session.key.sessionId) error=\(error)")
            // Keep NEW because the user did not reach the terminal (spec §4.6, clearing condition 1).
            NSSound.beep()
            return
        }
        // Successful navigation may indicate Automation permission was restored; resume its probe (R38).
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

    /// A successful command alone does not clear NEW unless the app reaches the foreground (R37).
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

    /// Only navigation that discovers its outer app at runtime records a choice by session PID.
    private static func sessionPid(of locator: TerminalLocator) -> Int32? {
        switch locator {
        case let .application(pid), let .tmux(_, _, pid): pid
        case .ghostty, .orca, .background, .appleTerminal, .iTerm, .none: nil
        }
    }

    /// Serialize overlapping watcher/poll snapshots and coalesce requests received while one is running (R20).
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

    /// Avoid assigning unchanged state: even equal assignments redraw and prevent zero idle CPU.
    private func apply(_ fresh: [AgentSession]) {
        guard fresh != sessions else { return }
        tracker.ingest(fresh)
        sessions = fresh

        regroup()
        publishSignals()

        DebugLog.write("refresh sessions=\(fresh.count) summary=w\(summary.waiting)/r\(summary.running)/d\(summary.done)/u\(summary.unknown) ask=\(summary.ask) new=\(summary.new)")
        onChange?()
    }

    /// Acknowledgment can clear NEW without changing sessions; refresh signals and window size directly.
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

    // MARK: Direct selection detection (spec §4.6, clearing condition 2)

    private func schedule(for probe: any FocusProbe) -> FocusWatchSchedule {
        focusWatchSchedules[probe.bundleIdentifier] ?? FocusWatchSchedule()
    }

    /// Unseen sessions matchable by a probe that has not been suspended.
    private func watchableSessions(for probe: any FocusProbe) -> [AgentSession] {
        guard !schedule(for: probe).isSuspended else { return [] }
        return sessions.filter { tracker.unseen.contains($0.key) && probe.canProbe($0) }
    }

    private var watchedProbes: [any FocusProbe] {
        focusProbes.filter { !watchableSessions(for: $0).isEmpty }
    }

    /// Poll only while matchable unseen sessions exist, keeping idle CPU at zero (spec §4.9).
    /// Exclude denied apps to avoid repeatedly launching osascript calls that must fail (R38).
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

    /// Wake at the shortest active schedule; only failing apps back off.
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
        // A selected tab is not visible to the user unless its app is frontmost.
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

/// Serialize provider snapshots because providers hold locks during slow file I/O (R20).
private actor SnapshotWorker {
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func snapshot(now: Date) -> [AgentSession] {
        store.snapshot(now: now)
    }
}
