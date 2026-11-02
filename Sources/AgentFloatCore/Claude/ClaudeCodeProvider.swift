import Foundation
import Synchronization

/// Enrich session-file state/PID with transcript titles and process terminal placement.
/// Polling is frequent; reread transcripts and process environments (about 1 MiB per call) only when changed.
public final class ClaudeCodeProvider: AgentProvider, AnswerRecordReading, Sendable {
    public let id = "claude-code"

    public var watchedDirectories: [URL] { [sessionsDirectory] }

    private let sessionsDirectory: URL
    private let projectsDirectory: URL
    private let homeDirectory: String
    private let inspector: any ProcessInspecting
    // Lock the whole snapshot so overlapping calls cannot prune another call's cache entries.
    private let caches = Mutex(Caches())

    public init(claudeHome: URL, homeDirectory: String, inspector: any ProcessInspecting) {
        sessionsDirectory = claudeHome.appendingPathComponent("sessions", isDirectory: true)
        projectsDirectory = claudeHome.appendingPathComponent("projects", isDirectory: true)
        self.homeDirectory = homeDirectory
        self.inspector = inspector
    }

    public static func live() -> ClaudeCodeProvider {
        let home = NSHomeDirectory()
        return ClaudeCodeProvider(
            claudeHome: URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude", isDirectory: true),
            homeDirectory: home,
            inspector: DarwinProcessInspector()
        )
    }

    public func snapshot(now: Date) throws -> [AgentSession] {
        // A missing sessions directory is normal on first installation.
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let files = try FileManager.default
            .contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            // Sort filenames so filesystem enumeration order cannot create apparent list changes.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return caches.withLock { state in
            var projects = ProjectDirectories(root: projectsDirectory)
            var touched = Touched(filePaths: Set(files.map(\.path)))

            let live = files.compactMap { url -> ClaudeSessionFile? in
                guard let file = sessionFile(at: url, state: &state),
                      inspector.isAlive(pid: file.pid, procStart: file.procStart)
                else { return nil }
                return file
            }
            let sessions = Self.droppingDuplicates(live).map {
                makeSession(from: $0, now: now, state: &state, projects: &projects, touched: &touched)
            }

            state.prune(keeping: touched)
            return sessions
        }
    }

    /// Check recorded replies only on demand, using the cached transcript location or resolving it again.
    public func recordedAnswer(sessionId: String, promptId: String) -> RecordedAnswer? {
        let location = caches.withLock { state -> TranscriptLocation? in
            var projects = ProjectDirectories(root: projectsDirectory)
            return locateTranscript(sessionId: sessionId, state: &state, projects: &projects)
        }
        guard let location else { return nil }
        return try? TranscriptReader.recordedAnswer(to: promptId, url: URL(fileURLWithPath: location.path))
    }

    // MARK: Session files

    /// Concurrent Claude writes can truncate JSON; retain the last successfully parsed file.
    /// The caller's liveness check excludes processes that have already exited.
    private func sessionFile(at url: URL, state: inout Caches) -> ClaudeSessionFile? {
        if let data = try? Data(contentsOf: url), let parsed = ClaudeSessionFile.parse(data) {
            state.lastGoodFiles[url.path] = parsed
            return parsed
        }
        return state.lastGoodFiles[url.path]
    }

    /// Deduplicate live files by sessionId, keeping the newest status update.
    /// If timestamps tie or are absent, prefer the larger PID as the likely later process.
    private static func droppingDuplicates(_ files: [ClaudeSessionFile]) -> [ClaudeSessionFile] {
        var winners: [String: Int] = [:]
        for (index, file) in files.enumerated() {
            if let current = winners[file.sessionId], !outranks(file, files[current]) { continue }
            winners[file.sessionId] = index
        }
        return files.enumerated().filter { winners[$0.element.sessionId] == $0.offset }.map(\.element)
    }

    private static func outranks(_ candidate: ClaudeSessionFile, _ current: ClaudeSessionFile) -> Bool {
        let candidateTime = candidate.statusUpdatedAt ?? -.infinity
        let currentTime = current.statusUpdatedAt ?? -.infinity
        if candidateTime != currentTime { return candidateTime > currentTime }
        return candidate.pid > current.pid
    }

    // MARK: Session assembly

    private func makeSession(
        from file: ClaudeSessionFile,
        now: Date,
        state: inout Caches,
        projects: inout ProjectDirectories,
        touched: inout Touched
    ) -> AgentSession {
        let since = file.procStart.flatMap(ProcStart.parse)
        let transcript = transcriptTail(for: file.sessionId, since: since, state: &state, projects: &projects, touched: &touched)
        let tail = transcript.map { withSubagentActivity($0, of: file, now: now) }
        let derived = ClaudeStatusDeriver.derive(file: file, tail: tail, now: now)
        let cwd = Self.nonEmpty(file.cwd) ?? homeDirectory
        let placement = placement(of: file, aiTitle: tail?.aiTitle, cwd: cwd, state: &state, touched: &touched)
        let statusSince = statusSince(of: file, status: derived.status, now: now, state: &state, touched: &touched)

        return AgentSession(
            key: SessionKey(providerId: id, sessionId: file.sessionId),
            agentName: "Claude",
            title: tail?.aiTitle ?? Self.nonEmpty(file.name) ?? "",
            cwd: cwd,
            status: derived.status,
            waitReason: derived.waitReason,
            statusSince: statusSince,
            isStale: derived.isStale,
            lastActivityAt: tail?.modifiedAt,
            terminalApp: placement.app,
            locator: placement.locator,
            prompt: derived.status == .waiting ? ClaudeStatusDeriver.prompt(for: derived.waitReason, tail: tail) : nil
        )
    }

    /// Using now for missing timestamps changes every snapshot and redraws unchanged sessions.
    /// Remember the first observation time, resetting only when status changes.
    private func statusSince(
        of file: ClaudeSessionFile,
        status: AgentStatus,
        now: Date,
        state: inout Caches,
        touched: inout Touched
    ) -> Date {
        if let updatedAt = file.statusUpdatedAt { return Date(timeIntervalSince1970: updatedAt / 1000) }
        touched.statusSessionIds.insert(file.sessionId)
        if let seen = state.statusFirstSeen[file.sessionId], seen.status == status { return seen.since }
        state.statusFirstSeen[file.sessionId] = StatusFirstSeen(status: status, since: now)
        return now
    }

    // MARK: Terminal app and placement

    private func placement(
        of file: ClaudeSessionFile,
        aiTitle: String?,
        cwd: String,
        state: inout Caches,
        touched: inout Touched
    ) -> (app: TerminalApp, locator: TerminalLocator) {
        // Background sessions have no attached terminal, so skip environment inspection.
        if file.kind == "bg", let jobId = file.jobId {
            return (.unknown, .background(jobId: jobId))
        }

        let processKey = ProcessKey(pid: file.pid, procStart: file.procStart)
        touched.processes.insert(processKey)
        let context = terminalContext(for: processKey, state: &state)
        let fallback = TerminalLocator.application(pid: file.pid)
        // Inspect tmux first because it overrides the outer terminal's TERM_PROGRAM.
        if let tmux = context.tmux {
            return (.other("tmux"), .tmux(socket: tmux.socket, paneId: tmux.paneId, pid: file.pid))
        }
        switch context.program {
        case "ghostty":
            return (.ghostty, .ghostty(title: aiTitle, cwd: cwd))
        case "Orca":
            // Preserve Orca's icon when exact tab mapping fails, falling back to raising the app.
            return (.orca, Self.orcaLocator(paneKey: context.paneKey, handle: context.orcaHandle) ?? fallback)
        case "Apple_Terminal":
            return (.other("Apple_Terminal"), context.tty.map { .appleTerminal(tty: $0) } ?? fallback)
        case "iTerm.app":
            return (.other("iTerm.app"), context.tty.map { .iTerm(tty: $0) } ?? fallback)
        case let program?:
            return (.other(program), fallback)
        case nil:
            return (.unknown, fallback)
        }
    }

    private func terminalContext(for key: ProcessKey, state: inout Caches) -> TerminalContext {
        if let cached = state.terminals[key] { return cached }
        let environment = inspector.environment(pid: key.pid)
        let ancestors = ProcessAncestry.chain(from: key.pid, inspector: inspector)
        let context = TerminalContext(
            program: Self.nonEmpty(environment["TERM_PROGRAM"]),
            paneKey: Self.nonEmpty(environment["ORCA_PANE_KEY"]),
            orcaHandle: Self.nonEmpty(environment["ORCA_TERMINAL_HANDLE"]),
            tty: outermostTty(along: ancestors),
            tmux: Self.tmuxPane(environment: environment["TMUX"], pane: environment["TMUX_PANE"], ancestors: ancestors)
        )
        // An empty environment may mean inspection failure; do not cache it, so the next poll retries.
        if !environment.isEmpty { state.terminals[key] = context }
        return context
    }

    /// TMUX is socket-path,server-pid,session-number; split only the last two fields to allow commas in paths (tmux 3.6).
    /// GUI apps may inherit tmux variables; require the server to be an actual ancestor.
    private static func tmuxPane(environment tmux: String?, pane: String?, ancestors: [Int32]) -> TmuxPane? {
        guard let tmux, let pane, TmuxCLI.isPaneId(pane) else { return nil }
        let parts = tmux.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3, let serverPid = Int32(parts[parts.count - 2]), ancestors.contains(serverPid) else { return nil }
        let socket = parts.dropLast(2).joined(separator: ",")
        guard socket.hasPrefix("/") else { return nil }
        return TmuxPane(socket: socket, paneId: pane)
    }

    /// Nested ptys from nvim :terminal or screen can differ from the tab's tty.
    /// Use the outermost contiguous tty ancestor (the tab shell), stopping at the tty-less terminal app.
    private func outermostTty(along ancestors: [Int32]) -> String? {
        var outermost: String?
        for pid in ancestors {
            guard let tty = inspector.tty(pid: pid) else { break }
            outermost = tty
        }
        // Non-pty devices such as /dev/console cannot match tabs; use app fallback instead of repeatedly beeping.
        return outermost.flatMap { TtyFormat.isDevicePath($0) ? $0 : nil }
    }

    private static func orcaLocator(paneKey: String?, handle: String?) -> TerminalLocator? {
        guard let paneKey else { return nil }
        let parts = paneKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return .orca(tabId: String(parts[0]), leafId: String(parts[1]), handle: handle)
    }

    // MARK: transcript

    private func transcriptTail(
        for sessionId: String,
        since: Date?,
        state: inout Caches,
        projects: inout ProjectDirectories,
        touched: inout Touched
    ) -> ReadTranscript? {
        guard let location = locateTranscript(sessionId: sessionId, state: &state, projects: &projects) else {
            return nil
        }
        touched.sessionIds.insert(sessionId)
        touched.transcriptPaths.insert(location.path)

        // After --resume, unchanged transcript markers can otherwise reuse the previous process's cached interpretation.
        if let cached = state.transcripts[location.path], cached.stamp == location.stamp, cached.since == since {
            return ReadTranscript(path: location.path, tail: cached.tail)
        }
        let knownTitle = state.titles[sessionId]
        // URL caches resourceValues; create a fresh instance to avoid stale modification timestamps.
        let url = URL(fileURLWithPath: location.path)
        guard var tail = try? TranscriptReader.read(url: url, scanHeadForTitle: knownTitle == nil, since: since) else {
            // Preserve the previous reading on I/O failure to avoid flickering from waiting to done.
            return state.transcripts[location.path].map { ReadTranscript(path: location.path, tail: $0.tail) }
        }
        // Retain known titles after title records slide outside the tail window.
        tail.aiTitle = tail.aiTitle ?? knownTitle
        if let title = tail.aiTitle { state.titles[sessionId] = title }
        state.transcripts[location.path] = CachedTail(stamp: location.stamp, since: since, tail: tail)
        return ReadTranscript(path: location.path, tail: tail)
    }

    /// Parent transcripts can remain silent while subagents work, falsely suggesting a stall.
    /// Count the latest subagent mtime as activity here so status derivation remains independent of transcript layout.
    /// Inspect only stale busy sessions, keeping directory traversal off the normal polling path.
    private func withSubagentActivity(_ transcript: ReadTranscript, of file: ClaudeSessionFile, now: Date) -> TranscriptTail {
        let tail = transcript.tail
        guard file.status == "busy", now.timeIntervalSince(tail.modifiedAt) > ClaudeStatusDeriver.staleAfter else {
            return tail
        }
        let directory = URL(fileURLWithPath: transcript.path)
            .deletingLastPathComponent()
            .appendingPathComponent(file.sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        guard let newest = Self.newestModification(under: directory), newest > tail.modifiedAt else { return tail }
        var adjusted = tail
        adjusted.modifiedAt = newest
        return adjusted
    }

    /// Observed layouts include subagents/agent-*.jsonl and subagents/workflows/<wf>/agent-*.jsonl.
    /// Bound traversal to three levels so large session trees cannot grow scan cost indefinitely.
    private static func newestModification(under directory: URL) -> Date? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: Date?
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if enumerator.level >= maxSubagentDepth { enumerator.skipDescendants() }
                continue
            }
            guard let modified = values.contentModificationDate else { continue }
            if let current = newest, current >= modified { continue }
            newest = modified
        }
        return newest
    }

    private static let maxSubagentDepth = 3

    /// Among resumed copies sharing a sessionId, the most recently modified project transcript is current.
    /// Do not cache misses: new transcripts may appear only after the first turn.
    private func locateTranscript(
        sessionId: String,
        state: inout Caches,
        projects: inout ProjectDirectories
    ) -> TranscriptLocation? {
        if let path = state.transcriptPaths[sessionId], let stamp = FileStamp.of(path: path) {
            return TranscriptLocation(path: path, stamp: stamp)
        }
        state.transcriptPaths[sessionId] = nil

        var best: TranscriptLocation?
        for directory in projects.all() {
            let path = directory.appendingPathComponent("\(sessionId).jsonl").path
            guard let stamp = FileStamp.of(path: path) else { continue }
            if let current = best, current.stamp.modifiedAt >= stamp.modifiedAt { continue }
            best = TranscriptLocation(path: path, stamp: stamp)
        }
        if let best { state.transcriptPaths[sessionId] = best.path }
        return best
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: Cache types

private struct ProcessKey: Hashable {
    let pid: Int32
    // PIDs are reused; matching start times establish process identity.
    let procStart: String?
}

private struct TerminalContext {
    let program: String?
    let paneKey: String?
    let orcaHandle: String?
    let tty: String?
    let tmux: TmuxPane?
}

private struct TmuxPane {
    let socket: String
    let paneId: String
}

private struct FileStamp: Equatable {
    let modifiedAt: Date
    let size: Int

    static func of(path: String) -> FileStamp? {
        // Read by path because URL.resourceValues caches values on the instance.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return FileStamp(modifiedAt: modifiedAt, size: size.intValue)
    }
}

private struct TranscriptLocation {
    let path: String
    let stamp: FileStamp
}

private struct CachedTail {
    let stamp: FileStamp
    let since: Date?
    let tail: TranscriptTail
}

private struct StatusFirstSeen {
    let status: AgentStatus
    let since: Date
}

private struct ReadTranscript {
    let path: String
    let tail: TranscriptTail
}

/// Keys used by this snapshot determine pruning so finished-session caches do not accumulate forever.
private struct Touched {
    var filePaths: Set<String>
    var sessionIds: Set<String> = []
    var transcriptPaths: Set<String> = []
    var processes: Set<ProcessKey> = []
    // Count processes separately from sessionIds because some sessions have no transcript yet.
    var statusSessionIds: Set<String> = []
}

private struct Caches {
    var lastGoodFiles: [String: ClaudeSessionFile] = [:]
    var transcriptPaths: [String: String] = [:]
    var transcripts: [String: CachedTail] = [:]
    var titles: [String: String] = [:]
    var terminals: [ProcessKey: TerminalContext] = [:]
    var statusFirstSeen: [String: StatusFirstSeen] = [:]

    mutating func prune(keeping touched: Touched) {
        lastGoodFiles = lastGoodFiles.filter { touched.filePaths.contains($0.key) }
        transcriptPaths = transcriptPaths.filter { touched.sessionIds.contains($0.key) }
        transcripts = transcripts.filter { touched.transcriptPaths.contains($0.key) }
        titles = titles.filter { touched.sessionIds.contains($0.key) }
        terminals = terminals.filter { touched.processes.contains($0.key) }
        statusFirstSeen = statusFirstSeen.filter { touched.statusSessionIds.contains($0.key) }
    }
}

/// Enumerate project directories once per snapshot rather than once per session.
private struct ProjectDirectories {
    private let root: URL
    private var listed: [URL]?

    init(root: URL) {
        self.root = root
    }

    mutating func all() -> [URL] {
        if let listed { return listed }
        // Sort names for deterministic selection when duplicate copies share an mtime.
        let found = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }
        listed = found
        return found
    }
}
