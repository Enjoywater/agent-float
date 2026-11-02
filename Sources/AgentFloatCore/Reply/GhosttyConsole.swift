import Foundation

/// Ghostty exposes no screen text through AppleScript; read the window's Accessibility text area.
/// Each window exposes only its selected tab; other-Space/minimized windows may be absent (measurement S3).
public protocol GhosttyScreenReading: Sendable {
    var isTrusted: Bool { get }
    /// Read only when exactly one window matches the title.
    func screen(windowTitle: String) throws -> [String]
}

public struct GhosttyConsole: TerminalConsole {
    /// Accessibility exposes neither faint styling nor cursor position (measurement S6, 2–3).
    public let promptCheck = PromptCheck.afterTyping

    private let runner: any CommandRunning
    private let screenReader: any GhosttyScreenReading

    public init(runner: any CommandRunning, screenReader: any GhosttyScreenReading) {
        self.runner = runner
        self.screenReader = screenReader
    }

    public func handles(_ session: AgentSession) -> Bool {
        if case .ghostty = session.locator { return true }
        return false
    }

    public func availability(of session: AgentSession) async -> ConsoleAvailability {
        switch await locate(session) {
        case let .failure(reason): return .readOnly(reason)
        case .success: return .ready
        }
    }

    /// Revalidate placement on every read because the user may have switched tabs.
    public func readScreen(of session: AgentSession) async throws -> ConsoleScreen {
        guard case let .success(lines) = await locate(session) else { throw NavigationError.terminalNotFound }
        return ConsoleScreen(lines: lines, faint: nil, composerDraft: nil)
    }

    public func send(_ input: ConsoleInput, to session: AgentSession) async throws {
        try requireSafeText(input)
        guard let terminal = try await target(of: session) else { throw NavigationError.terminalNotFound }
        let script = switch input {
        case let .text(text): GhosttyScripts.inputText(text, terminalId: terminal.id)
        case let .key(key): GhosttyScripts.sendKey(GhosttyKeyNames.name(for: key), terminalId: terminal.id)
        }
        let outcome = try await runner.run(GhosttyScripts.osascript, ["-e", script])
        guard outcome.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw NavigationError.terminalNotFound }
    }

    private enum Located {
        case success([String])
        case failure(ReadOnlyReason)
    }

    /// Check matching, placement, permission, then readability; later checks are irrelevant after an earlier failure.
    private func locate(_ session: AgentSession) async -> Located {
        let terminals: [GhosttyTerminal]
        do {
            terminals = GhosttyMatcher.parseList(try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.listTerminals]))
        } catch {
            return .failure(.unsupportedTerminal("Ghostty"))
        }
        guard case let .ghostty(title, cwd) = session.locator else { return .failure(.unsupportedTerminal("Ghostty")) }
        guard let terminal = GhosttyMatcher.uniqueMatch(title: title, cwd: cwd, in: terminals) else {
            // Lists include other Spaces: no candidates means missing, while non-unique candidates mean duplicate titles.
            let lenient = GhosttyMatcher.match(title: title, cwd: cwd, in: terminals)
            return .failure(lenient == nil ? .tabNotFound : .ambiguousTab)
        }
        guard let placement = try? await placement(of: terminal) else { return .failure(.hiddenTab) }
        guard placement.terminalCount == 1 else { return .failure(.splitTab) }
        guard placement.isSelected else { return .failure(.hiddenTab) }
        guard screenReader.isTrusted else { return .failure(.accessibilityNeeded) }
        guard let lines = try? screenReader.screen(windowTitle: placement.windowName) else { return .failure(.hiddenTab) }
        return .success(lines)
    }

    private func target(of session: AgentSession) async throws -> GhosttyTerminal? {
        guard case let .ghostty(title, cwd) = session.locator else { return nil }
        let listing = try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.listTerminals])
        return GhosttyMatcher.uniqueMatch(title: title, cwd: cwd, in: GhosttyMatcher.parseList(listing))
    }

    private struct Placement {
        let windowName: String
        let isSelected: Bool
        let terminalCount: Int
    }

    private func placement(of terminal: GhosttyTerminal) async throws -> Placement? {
        let output = try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.terminalPlacement(terminalId: terminal.id)])
        let fields = output.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
        // Preserve title tabs by parsing fixed first/last fields and joining the middle.
        guard fields.count >= 4, let count = Int(fields[fields.count - 1]) else { return nil }
        let name = fields.dropFirst().dropLast(2).joined(separator: "\t")
        return Placement(windowName: name, isSelected: fields[fields.count - 2] == "true", terminalCount: count)
    }
}

/// Ghostty send key accepts camel-case arrow names; arrow_down/down fail (1.3.1).
public enum GhosttyKeyNames {
    public static func name(for key: ConsoleKey) -> String {
        switch key {
        case .enter: "enter"
        case .up: "arrowUp"
        case .down: "arrowDown"
        case .left: "arrowLeft"
        case .right: "arrowRight"
        case .tab: "tab"
        case .space: "space"
        // Delete one character at a time, including a Korean syllable (measurement S6, 7).
        case .backspace: "backspace"
        }
    }
}
