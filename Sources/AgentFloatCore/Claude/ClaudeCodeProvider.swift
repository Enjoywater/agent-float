import Foundation
import Synchronization

/// 세션 파일이 아는 것(상태·pid)과 모르는 것(제목·터미널 위치)을 transcript 와 프로세스 환경으로 채운다.
/// 폴링마다 불리므로 transcript 판독과 환경변수 조회(호출당 약 1MiB 할당)는 바뀔 때만 다시 한다
public final class ClaudeCodeProvider: AgentProvider, Sendable {
    public let id = "claude-code"

    public var watchedDirectories: [URL] { [sessionsDirectory] }

    private let sessionsDirectory: URL
    private let projectsDirectory: URL
    private let homeDirectory: String
    private let inspector: any ProcessInspecting
    // snapshot 전체를 한 번에 잠근다. 호출이 겹쳐도 직렬화되어야 캐시 정리가 다른 호출의 사용분을 지우지 않는다
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
        // 처음 설치한 머신에서는 디렉터리가 아직 없는 것이 정상이라 오류로 보지 않는다
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let files = try FileManager.default
            .contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            // 열거 순서가 호출마다 달라지면 내용이 같아도 목록이 바뀐 것으로 보이므로 이름순으로 고정한다
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

    // MARK: 세션 파일

    /// Claude 가 파일을 쓰는 도중에 읽으면 JSON 이 잘려 있으므로, 파싱에 실패하면 직전 정상 값을 쓴다.
    /// 프로세스가 이미 죽었다면 호출 쪽의 생존 검사가 걸러낸다
    private func sessionFile(at url: URL, state: inout Caches) -> ClaudeSessionFile? {
        if let data = try? Data(contentsOf: url), let parsed = ClaudeSessionFile.parse(data) {
            state.lastGoodFiles[url.path] = parsed
            return parsed
        }
        return state.lastGoodFiles[url.path]
    }

    /// 같은 sessionId 가 살아 있는 파일 둘 이상에 있으면 화면에서 같은 줄이 겹치므로 가장 최근 상태 갱신 하나만 남긴다.
    /// 시각이 같거나 없으면 pid 가 큰 쪽이 나중에 뜬 프로세스일 가능성이 높다
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

    // MARK: 세션 조립

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
            title: tail?.aiTitle ?? Self.nonEmpty(file.name) ?? "이름 없는 세션",
            cwd: cwd,
            status: derived.status,
            waitReason: derived.waitReason,
            statusSince: statusSince,
            isStale: derived.isStale,
            lastActivityAt: tail?.modifiedAt,
            terminalApp: placement.app,
            locator: placement.locator
        )
    }

    /// 상태 갱신 시각이 없는 파일에 매번 `now` 를 쓰면 폴링마다 세션 값이 달라져 바뀐 것 없이 화면을 다시 그린다.
    /// 그래서 그 상태를 처음 본 시각을 기억하고, 상태가 바뀌면 그때부터 다시 잰다
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

    // MARK: 터미널 앱·위치

    private func placement(
        of file: ClaudeSessionFile,
        aiTitle: String?,
        cwd: String,
        state: inout Caches,
        touched: inout Touched
    ) -> (app: TerminalApp, locator: TerminalLocator) {
        // 백그라운드 세션은 붙어 있는 터미널이 없어 환경변수를 읽을 필요가 없다
        if file.kind == "bg", let jobId = file.jobId {
            return (.unknown, .background(jobId: jobId))
        }

        let processKey = ProcessKey(pid: file.pid, procStart: file.procStart)
        touched.processes.insert(processKey)
        let context = terminalContext(for: processKey, state: &state)
        let fallback = TerminalLocator.application(pid: file.pid)
        // tmux 안에서는 TERM_PROGRAM 이 바깥 터미널 대신 tmux 로 덮이므로 tmux 환경을 먼저 본다
        if let tmux = Self.tmuxLocator(environment: context.tmux, pane: context.tmuxPane, pid: file.pid) {
            return (.other("tmux"), tmux)
        }
        switch context.program {
        case "ghostty":
            return (.ghostty, .ghostty(title: aiTitle, cwd: cwd))
        case "Orca":
            // 탭을 특정할 수 없어도 앱은 Orca 이므로 아이콘은 유지하고 앱만 앞으로 올리는 폴백을 쓴다
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
        let context = TerminalContext(
            program: Self.nonEmpty(environment["TERM_PROGRAM"]),
            paneKey: Self.nonEmpty(environment["ORCA_PANE_KEY"]),
            orcaHandle: Self.nonEmpty(environment["ORCA_TERMINAL_HANDLE"]),
            tty: inspector.tty(pid: key.pid),
            tmux: Self.nonEmpty(environment["TMUX"]),
            tmuxPane: Self.nonEmpty(environment["TMUX_PANE"])
        )
        // 조회 실패와 빈 환경을 구분할 수 없어, 비어 있으면 캐시하지 않고 다음 주기에 다시 읽는다
        if !environment.isEmpty { state.terminals[key] = context }
        return context
    }

    /// `TMUX` 는 `<소켓 경로>,<서버 pid>,<세션 번호>`. 경로에 쉼표가 들어가도 뒤의 두 값만 떼어 낸다 (tmux 3.6 실측)
    private static func tmuxLocator(environment tmux: String?, pane: String?, pid: Int32) -> TerminalLocator? {
        guard let tmux, let pane, TmuxCLI.isPaneId(pane) else { return nil }
        let parts = tmux.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let socket = parts.dropLast(2).joined(separator: ",")
        guard socket.hasPrefix("/") else { return nil }
        return .tmux(socket: socket, paneId: pane, pid: pid)
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

        // `--resume` 직후에는 transcript 가 그대로라 파일 표식만 보면 앞 프로세스 기준 판독을 그대로 돌려주게 된다
        if let cached = state.transcripts[location.path], cached.stamp == location.stamp, cached.since == since {
            return ReadTranscript(path: location.path, tail: cached.tail)
        }
        let knownTitle = state.titles[sessionId]
        // URL 인스턴스는 resourceValues 를 캐시해 재사용하면 옛 수정 시각을 돌려주므로 매번 새로 만든다
        let url = URL(fileURLWithPath: location.path)
        guard var tail = try? TranscriptReader.read(url: url, scanHeadForTitle: knownTitle == nil, since: since) else {
            // 읽기 실패로 대기 상태가 완료로 깜빡이지 않도록 직전 판독을 유지한다
            return state.transcripts[location.path].map { ReadTranscript(path: location.path, tail: $0.tail) }
        }
        // 제목 기록이 꼬리 창 밖으로 밀려나도 앞서 알아낸 제목을 유지한다
        tail.aiTitle = tail.aiTitle ?? knownTitle
        if let title = tail.aiTitle { state.titles[sessionId] = title }
        state.transcripts[location.path] = CachedTail(stamp: location.stamp, since: since, tail: tail)
        return ReadTranscript(path: location.path, tail: tail)
    }

    /// 부모 세션은 서브에이전트가 일하는 동안 transcript 에 아무것도 쓰지 않아 멈춘 것으로 오인된다.
    /// 그래서 서브에이전트 파일의 최근 수정 시각을 마지막 활동으로 친다. 상태 도출기는 이 사실을 몰라도 되도록 여기서 덮어쓴다.
    /// 오래된 busy 세션만 확인해 평소 폴링 경로에는 폴더 순회가 끼지 않는다
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

    /// 실측 배치는 `subagents/agent-*.jsonl` 과 `subagents/workflows/<wf>/agent-*.jsonl` 이라 파일이 세 단계 아래까지 있다.
    /// 그 아래는 보지 않아 폴더가 크게 자란 세션에서도 순회 비용이 묶인다
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

    /// 같은 sessionId 가 여러 프로젝트 폴더에 있으면 수정 시각이 가장 최근인 쪽이 현재 세션이다 (resume 으로 복사된 경우).
    /// 못 찾은 결과는 캐시하지 않는다. 새 세션은 첫 턴이 끝나야 파일이 생긴다
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

// MARK: 캐시 타입

private struct ProcessKey: Hashable {
    let pid: Int32
    // pid 는 재사용되므로 시작 시각까지 같아야 같은 프로세스다
    let procStart: String?
}

private struct TerminalContext {
    let program: String?
    let paneKey: String?
    let orcaHandle: String?
    let tty: String?
    let tmux: String?
    let tmuxPane: String?
}

private struct FileStamp: Equatable {
    let modifiedAt: Date
    let size: Int

    static func of(path: String) -> FileStamp? {
        // URL.resourceValues 는 인스턴스에 값을 캐시하므로 경로로 직접 읽는다
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

/// 이번 snapshot 에서 쓰인 키. 끝난 세션의 캐시가 상시 실행 앱에 계속 쌓이지 않게 정리하는 기준이다
private struct Touched {
    var filePaths: Set<String>
    var sessionIds: Set<String> = []
    var transcriptPaths: Set<String> = []
    var processes: Set<ProcessKey> = []
    // transcript 가 아직 없는 세션도 담아야 해서 sessionIds 와 따로 센다
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

/// 세션마다 프로젝트 폴더를 다시 열거하지 않도록 snapshot 한 번에 한 번만 목록을 만든다
private struct ProjectDirectories {
    private let root: URL
    private var listed: [URL]?

    init(root: URL) {
        self.root = root
    }

    mutating func all() -> [URL] {
        if let listed { return listed }
        // 수정 시각이 같은 중복 사본 사이에서도 결과가 매번 같도록 이름순으로 고정한다
        let found = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }
        listed = found
        return found
    }
}
