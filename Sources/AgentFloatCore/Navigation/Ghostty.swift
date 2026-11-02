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

    /// Each row is id<TAB>title<TAB>cwd.
    /// Create the separator outside tell: inside it, tab resolves to Ghostty's tab class instead of a tab character.
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

    /// Repeat enumeration by ID; return missing if the tab closed after listing.
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

    /// Return window-id, title, selected state, and surface count separated by tabs, or missing; only selected unsplit tabs are readable.
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

    /// Text input behaves like paste rather than interpreting characters as keys (sdef).
    public static func inputText(_ text: String, terminalId: String) -> String {
        onTerminal(terminalId, command: "input text \"\(escape(text))\" to s")
    }

    public static func sendKey(_ name: String, terminalId: String) -> String {
        onTerminal(terminalId, command: "send key \"\(escape(name))\" to s")
    }

    /// Send only to the target terminal without raising the app, including terminals in hidden windows.
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

    /// Escape backslashes first so quote-escaping backslashes are not escaped again.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum GhosttyMatcher {
    private static let claudeGlyphs: Set<Character> = ["◐", "◑", "✳"]

    /// Strip leading status glyphs and whitespace; stored session titles omit them.
    public static func strippedTitle(_ raw: String) -> String {
        let codexSpinner = raw.first?.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
        guard startsWithClaudeGlyph(raw) || codexSpinner else { return raw }
        return String(raw.dropFirst().drop(while: \.isWhitespace))
    }

    public static func parseList(_ output: String) -> [GhosttyTerminal] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let id = fields.first, !id.isEmpty, let cwd = fields.last else { return nil }
            // Preserve embedded title tabs by treating the first/last columns as fixed fields.
            let title = fields.dropFirst().dropLast().joined(separator: "\t")
            return GhosttyTerminal(id: String(id), title: title, cwd: String(cwd))
        }
    }

    public static func match(title: String?, cwd: String, in terminals: [GhosttyTerminal]) -> GhosttyTerminal? {
        if let title, !title.isEmpty {
            let candidates = terminals.filter { strippedTitle($0.title) == title }
            if let first = candidates.first {
                // For duplicate titles, prefer matching cwd; if still ambiguous, preserve list order.
                return candidates.first { $0.cwd == cwd } ?? first
            }
        }
        // Fallback only when exactly one agent tab shares cwd after title matching fails.
        let agentTabs = terminals.filter { $0.cwd == cwd && startsWithClaudeGlyph($0.title) }
        return agentTabs.count == 1 ? agentTabs[0] : nil
    }

    /// Sending requires a unique match to prevent typing into another tab; navigation may use a best match (v1.2 design §4.1).
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

    /// Normalize titles across Accessibility/AppleScript: progress glyphs vary and Korean Unicode forms may differ.
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

    /// Use the same matching as click navigation so manual-selection acknowledgment identifies the same tab.
    public func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey> {
        let candidates = sessions.compactMap { session -> (key: SessionKey, title: String?, cwd: String)? in
            guard case let .ghostty(title, cwd) = session.locator else { return nil }
            return (session.key, title, cwd)
        }
        // Skip osascript when no sessions can match during this polling tick.
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
        // Only ok proves focus; other output means a missing tab or unexpected script result.
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

    /// Session-sourced jobId is typed into a shell; accept only known-safe identifier forms.
    /// Require an alphanumeric first character so claude attach cannot parse it as an option.
    private static func isSafeJobId(_ jobId: String) -> Bool {
        guard let first = jobId.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return jobId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
