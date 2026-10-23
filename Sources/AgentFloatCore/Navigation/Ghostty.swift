import Foundation

public struct GhosttyTerminal: Equatable, Sendable {
    public let id: String
    public let title: String
    public let cwd: String

    public init(id: String, title: String, cwd: String) {
        self.id = id
        self.title = title
        self.cwd = cwd
    }
}

public enum GhosttyScripts {
    static let osascript = "/usr/bin/osascript"

    /// 줄마다 `id<TAB>title<TAB>cwd`.
    /// tell 블록 안의 `tab` 은 Ghostty 사전의 tab 클래스로 해석되어 구분자가 빈 문자열이 되므로 블록 밖에서 탭 문자를 만든다
    public static let listTerminals = """
    set sep to character id 9
    tell application "Ghostty"
      set out to ""
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in terminals of t
            set out to out & (id of s) & sep & (name of s) & sep & (working directory of s) & linefeed
          end repeat
        end repeat
      end repeat
      return out
    end tell
    """

    public static let focusedTerminalId = """
    tell application "Ghostty" to get id of focused terminal of selected tab of front window
    """

    /// 목록과 같은 순회로 id 를 다시 찾는다. 목록을 읽은 사이 탭이 닫혔을 수 있어 못 찾으면 "missing" 을 돌려준다
    public static func focus(terminalId: String) -> String {
        """
        tell application "Ghostty"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in terminals of t
                if (id of s) is "\(escape(terminalId))" then
                  focus s
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "missing"
        end tell
        """
    }

    /// `<창 id>\t<창 제목>\t<탭 선택 여부>\t<탭 안 터미널 수>` 또는 "missing". 화면은 그 탭이 선택돼 있고 나뉘지 않았을 때만 읽을 수 있다
    public static func terminalPlacement(terminalId: String) -> String {
        """
        set sep to character id 9
        tell application "Ghostty"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in terminals of t
                if (id of s) is "\(escape(terminalId))" then
                  return (id of w) & sep & (name of w) & sep & ((selected of t) as text) & sep & ((count of terminals of t) as text)
                end if
              end repeat
            end repeat
          end repeat
          return "missing"
        end tell
        """
    }

    /// 붙여넣기처럼 들어가므로 글자가 키로 해석되지 않는다 (sdef)
    public static func inputText(_ text: String, terminalId: String) -> String {
        onTerminal(terminalId, command: "input text \"\(escape(text))\" to s")
    }

    public static func sendKey(_ name: String, terminalId: String) -> String {
        onTerminal(terminalId, command: "send key \"\(escape(name))\" to s")
    }

    /// 앱을 앞으로 올리지 않고 그 터미널에만 보낸다. 보이지 않는 창의 터미널에도 들어간다(실측)
    private static func onTerminal(_ terminalId: String, command: String) -> String {
        """
        tell application "Ghostty"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in terminals of t
                if (id of s) is "\(escape(terminalId))" then
                  \(command)
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "missing"
        end tell
        """
    }

    public static func newTab(initialInput: String) -> String {
        """
        tell application "Ghostty"
          set cfg to new surface configuration
          set initial input of cfg to "\(escape(initialInput))" & return
          if (count of windows) is 0 then
            new window with configuration cfg
          else
            new tab in front window with configuration cfg
          end if
          activate
        end tell
        """
    }

    /// 역슬래시를 먼저 바꿔야 따옴표 앞에 붙인 역슬래시가 다시 이스케이프되지 않는다
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum GhosttyMatcher {
    private static let claudeGlyphs: Set<Character> = ["◐", "◑", "✳"]

    /// 제목 앞에 붙는 상태 기호와 그 뒤 공백을 걷어 낸다. 세션 제목은 기호 없이 저장되어 있다
    public static func strippedTitle(_ raw: String) -> String {
        guard startsWithClaudeGlyph(raw) else { return raw }
        return String(raw.dropFirst().drop(while: \.isWhitespace))
    }

    public static func parseList(_ output: String) -> [GhosttyTerminal] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let id = fields.first, !id.isEmpty, let cwd = fields.last else { return nil }
            // 제목에 탭이 섞여도 앞뒤 필드는 고정이므로 가운데를 모두 제목으로 본다
            let title = fields.dropFirst().dropLast().joined(separator: "\t")
            return GhosttyTerminal(id: String(id), title: title, cwd: String(cwd))
        }
    }

    public static func match(title: String?, cwd: String, in terminals: [GhosttyTerminal]) -> GhosttyTerminal? {
        if let title, !title.isEmpty {
            let candidates = terminals.filter { strippedTitle($0.title) == title }
            if let first = candidates.first {
                // 제목이 겹치면 같은 작업 디렉터리를 우선하고, 그래도 가를 수 없으면 목록 순서를 따른다
                return candidates.first { $0.cwd == cwd } ?? first
            }
        }
        // 제목이 없거나 바뀌어 짝이 없을 때의 마지막 수단. 같은 디렉터리의 에이전트 탭이 하나뿐일 때만 확신할 수 있다
        let agentTabs = terminals.filter { $0.cwd == cwd && startsWithClaudeGlyph($0.title) }
        return agentTabs.count == 1 ? agentTabs[0] : nil
    }

    /// 보내기용. 이동은 가장 그럴듯한 탭으로 가도 되지만, 보내기는 엉뚱한 탭에 키가 들어가면 안 되므로 정확히 하나일 때만 고른다 (v1.2 설계 4.1)
    public static func uniqueMatch(title: String?, cwd: String, in terminals: [GhosttyTerminal]) -> GhosttyTerminal? {
        if let title, !title.isEmpty {
            let candidates = terminals.filter { strippedTitle($0.title) == title }
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 {
                let sameDirectory = candidates.filter { $0.cwd == cwd }
                return sameDirectory.count == 1 ? sameDirectory[0] : nil
            }
        }
        let agentTabs = terminals.filter { $0.cwd == cwd && startsWithClaudeGlyph($0.title) }
        return agentTabs.count == 1 ? agentTabs[0] : nil
    }

    /// 창 제목을 손쉬운 사용 API 쪽 제목과 견줄 열쇠. 진행 기호는 수시로 바뀌고, 한글은 두 API 가 다른 정규화로 줄 수 있다(실측)
    public static func windowKey(_ title: String) -> String {
        strippedTitle(title).precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
    }

    private static func startsWithClaudeGlyph(_ title: String) -> Bool {
        title.first.map(claudeGlyphs.contains) ?? false
    }
}

public struct GhosttyFocusProbe: FocusProbe {
    public let bundleIdentifier = TerminalBundle.ghostty
    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func canProbe(_ session: AgentSession) -> Bool {
        if case .ghostty = session.locator { return true }
        return false
    }

    /// 클릭 이동과 같은 짝짓기를 써야, 줄을 눌러 가게 되는 탭과 직접 골랐다고 보는 탭이 어긋나지 않는다
    public func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey> {
        let candidates = sessions.compactMap { session -> (key: SessionKey, title: String?, cwd: String)? in
            guard case let .ghostty(title, cwd) = session.locator else { return nil }
            return (session.key, title, cwd)
        }
        // 감시 주기마다 불리므로 짝지을 세션이 없으면 osascript 를 띄우지 않는다
        guard !candidates.isEmpty else { return [] }
        let focused = try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.focusedTerminalId])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !focused.isEmpty else { return [] }
        let terminals = GhosttyMatcher.parseList(try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.listTerminals]))
        let shown = candidates.filter { GhosttyMatcher.match(title: $0.title, cwd: $0.cwd, in: terminals)?.id == focused }
        return Set(shown.map(\.key))
    }
}

public struct GhosttyNavigator: TerminalNavigator {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        switch session.locator {
        case .ghostty: true
        case let .background(jobId): Self.isSafeJobId(jobId)
        case .orca, .appleTerminal, .iTerm, .tmux, .application, .none: false
        }
    }

    public func navigate(to session: AgentSession) async throws {
        switch session.locator {
        case let .ghostty(title, cwd):
            try await focusTerminal(title: title, cwd: cwd)
        case let .background(jobId) where Self.isSafeJobId(jobId):
            try await openAttachTab(jobId: jobId)
        case .background, .orca, .appleTerminal, .iTerm, .tmux, .application, .none:
            throw NavigationError.terminalNotFound
        }
    }

    private func focusTerminal(title: String?, cwd: String) async throws {
        let listing = try await runScript(GhosttyScripts.listTerminals)
        guard let target = GhosttyMatcher.match(title: title, cwd: cwd, in: GhosttyMatcher.parseList(listing)) else {
            throw NavigationError.terminalNotFound
        }
        let outcome = try await runScript(GhosttyScripts.focus(terminalId: target.id))
        // "ok" 외의 출력은 탭이 사라졌거나 스크립트가 기대와 다르게 끝난 것이라 성공으로 치지 않는다
        guard outcome.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw NavigationError.terminalNotFound
        }
    }

    private func openAttachTab(jobId: String) async throws {
        _ = try await runScript(GhosttyScripts.newTab(initialInput: "claude attach \(jobId)"))
    }

    private func runScript(_ script: String) async throws -> String {
        try await runner.run(GhosttyScripts.osascript, ["-e", script])
    }

    /// jobId 는 세션 파일에서 오고 셸에 그대로 입력되므로, 알려진 id 형태가 아니면 실행하지 않는다.
    /// `-` 로 시작하면 `claude attach` 가 옵션으로 읽으므로 첫 글자는 영숫자여야 한다
    private static func isSafeJobId(_ jobId: String) -> Bool {
        guard let first = jobId.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return jobId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
