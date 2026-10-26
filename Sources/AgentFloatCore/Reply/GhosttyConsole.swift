import Foundation

/// Ghostty 는 AppleScript 로 화면 글자를 주지 않아, 손쉬운 사용 API 로 창의 텍스트 영역을 읽는다.
/// 그 영역은 창마다 하나이고 지금 선택된 탭만 보여 주며, 화면에 보이지 않는 창(다른 데스크탑·최소화)은 목록에 없다 (실측 S3)
public protocol GhosttyScreenReading: Sendable {
    var isTrusted: Bool { get }
    /// 제목이 같은 창이 정확히 하나일 때만 그 창의 글자를 준다
    func screen(windowTitle: String) throws -> [String]
}

public struct GhosttyConsole: TerminalConsole {
    /// 손쉬운 사용 API 의 값에는 흐림도 입력 커서도 없다 (실측 S6 ②·③)
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

    /// 읽을 때마다 위치를 다시 확인한다. 그 사이 사용자가 탭을 바꿨다면 다른 탭의 화면을 읽게 된다
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

    /// 짝 찾기 → 탭 위치 → 권한 → 실제로 읽히는지 순서. 앞 단계가 안 되면 뒤 단계는 볼 필요가 없다
    private func locate(_ session: AgentSession) async -> Located {
        let terminals: [GhosttyTerminal]
        do {
            terminals = GhosttyMatcher.parseList(try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.listTerminals]))
        } catch {
            return .failure(.unsupportedTerminal("Ghostty"))
        }
        guard case let .ghostty(title, cwd) = session.locator else { return .failure(.unsupportedTerminal("Ghostty")) }
        guard let terminal = GhosttyMatcher.uniqueMatch(title: title, cwd: cwd, in: terminals) else {
            // 목록은 다른 데스크탑의 창까지 담는다. 짝이 아예 없으면 탭을 못 찾은 것이고, 있는데 하나로 못 정하면 같은 이름이 여럿인 것이다
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
        // 창 제목에 탭이 섞여도 앞뒤 필드는 고정이므로 가운데를 모두 제목으로 본다
        guard fields.count >= 4, let count = Int(fields[fields.count - 1]) else { return nil }
        let name = fields.dropFirst().dropLast(2).joined(separator: "\t")
        return Placement(windowName: name, isSelected: fields[fields.count - 2] == "true", terminalCount: count)
    }
}

/// `send key` 가 받는 이름. 화살표는 카멜 표기만 받는다 (Ghostty 1.3.1 실측: `arrow_down`·`down` 은 Unknown key name)
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
        // 한 번에 한 글자(한글 음절 포함)를 지운다 (실측 S6 ⑦)
        case .backspace: "backspace"
        }
    }
}
