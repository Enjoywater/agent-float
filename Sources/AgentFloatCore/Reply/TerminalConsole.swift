import Foundation

/// Represent only permitted terminal keys; omit Escape/Ctrl combinations that could reject questions or terminate sessions (v1.2 design §4.3).
/// Deletion may undo only the console's own just-inserted probe character (R78).
public enum ConsoleKey: String, CaseIterable, Sendable {
    case enter, up, down, left, right, tab, space, backspace
}

public enum ConsoleInput: Equatable, Sendable {
    case text(String)
    case key(ConsoleKey)
}

/// Rendered terminal text; faint SGR 2 is the only cue distinguishing hints from existing drafts (R57).
public struct ConsoleScreen: Equatable, Sendable {
    public let lines: [String]
    /// Per-line faint Character offsets; nil when styling is unavailable.
    public let faint: [Set<Int>]?
    /// Text from a separate external composer such as Orca's.
    public let composerDraft: String?

    public init(lines: [String], faint: [Set<Int>]?, composerDraft: String?) {
        self.lines = lines
        self.faint = faint
        self.composerDraft = composerDraft
    }

    /// Extract text and faint offsets from SGR output such as tmux capture-pane -e; faint state persists across lines.
    public static func ansi(_ text: String, composerDraft: String? = nil) -> ConsoleScreen {
        let characters = Array(text)
        var lines: [String] = []
        var faint: [Set<Int>] = []
        var line = ""
        var lineFaint: Set<Int> = []
        var column = 0
        var isFaint = false
        var index = 0

        func endLine() {
            lines.append(line)
            faint.append(lineFaint)
            line = ""
            lineFaint = []
            column = 0
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\u{1b}" {
                index = skipEscape(characters, from: index, faint: &isFaint)
                continue
            }
            if character == "\n" || character == "\r\n" {
                endLine()
            } else if character != "\r" {
                if isFaint { lineFaint.insert(column) }
                line.append(character)
                column += 1
            }
            index += 1
        }
        endLine()
        return ConsoleScreen(lines: lines, faint: faint, composerDraft: composerDraft)
    }

    /// Skip one escape sequence; only SGR m changes faint state.
    private static func skipEscape(_ characters: [Character], from start: Int, faint: inout Bool) -> Int {
        let next = start + 1
        guard next < characters.count else { return characters.count }
        switch characters[next] {
        case "[":
            var end = next + 1
            var parameters = ""
            while end < characters.count, let ascii = characters[end].asciiValue, !(0x40...0x7E).contains(ascii) {
                parameters.append(characters[end])
                end += 1
            }
            guard end < characters.count else { return characters.count }
            if characters[end] == "m" { applySGR(parameters, faint: &faint) }
            return end + 1
        case "]":
            // OSC terminates with BEL or ESC followed by a backslash.
            var end = next + 1
            while end < characters.count {
                if characters[end] == "\u{7}" { return end + 1 }
                if characters[end] == "\u{1b}", end + 1 < characters.count, characters[end + 1] == "\\" { return end + 2 }
                end += 1
            }
            return characters.count
        default:
            return next + 1
        }
    }

    /// Skip extended color parameters (38/48/58) so RGB component 2 is not mistaken for faint.
    private static func applySGR(_ parameters: String, faint: inout Bool) {
        let values = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < values.count {
            switch values[index] {
            case 0, 22: faint = false
            case 2: faint = true
            case 38, 48, 58:
                let mode = index + 1 < values.count ? values[index + 1] : 0
                switch mode {
                case 5: index += 2
                case 2: index += 4
                default: index += 1
                }
            default: break
            }
            index += 1
        }
    }
}

/// Explain read-only status before users type, rather than blocking afterward (v1.2 design §4.4 G0).
public enum ReadOnlyReason: Equatable, Sendable {
    /// Unsupported terminal; associated value is the display app name.
    case unsupportedTerminal(String?)
    case hiddenTab
    /// No matching session tab even across Spaces, possibly renamed or closed.
    case tabNotFound
    case accessibilityNeeded
    case ambiguousTab
    case splitTab
    case previewQuestion
    case permissionPrompt
}

/// When composer emptiness can be established for text questions (R57, R78).
public enum PromptCheck: Equatable, Sendable {
    /// Before typing, using faint styling (tmux) or separate actual composer text (Orca draft).
    case beforeTyping
    /// After a character probe when hints look like text; erase and stop if appended to an existing draft (Ghostty).
    case afterTyping
}

public enum ConsoleAvailability: Equatable, Sendable {
    case ready
    case readOnly(ReadOnlyReason)
}

/// One input/screen transport per TerminalLocator kind.
public protocol TerminalConsole: Sendable {
    var promptCheck: PromptCheck { get }
    func handles(_ session: AgentSession) -> Bool
    func availability(of session: AgentSession) async -> ConsoleAvailability
    func readScreen(of session: AgentSession) async throws -> ConsoleScreen
    func send(_ input: ConsoleInput, to session: AgentSession) async throws
}

extension TerminalConsole {
    /// Control characters perform actions instead of inserting text; this is a second check beyond UI validation.
    func requireSafeText(_ input: ConsoleInput) throws {
        guard case let .text(text) = input else { return }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw NavigationError.commandFailed("unsafe text")
        }
    }
}

public struct ConsoleRegistry: Sendable {
    private let consoles: [any TerminalConsole]

    public init(_ consoles: [any TerminalConsole]) {
        self.consoles = consoles
    }

    public func console(for session: AgentSession) -> (any TerminalConsole)? {
        consoles.first { $0.handles(session) }
    }

    /// Assess prompt restrictions first: they need no terminal access and apply even to supported transports.
    public func availability(of session: AgentSession) async -> ConsoleAvailability {
        switch session.prompt {
        case .permission?:
            return .readOnly(.permissionPrompt)
        case let .choices(_, questions)? where questions.contains(where: \.hasPreview):
            return .readOnly(.previewQuestion)
        default:
            break
        }
        guard let console = console(for: session) else {
            return .readOnly(.unsupportedTerminal(Self.appName(session.terminalApp)))
        }
        return await console.availability(of: session)
    }

    static func appName(_ app: TerminalApp) -> String? {
        switch app {
        case .ghostty: "Ghostty"
        case .orca: "Orca"
        case .other("Apple_Terminal"): "Terminal"
        case .other("iTerm.app"): "iTerm2"
        case let .other(name): name
        // Unknown app names remain semantic absence for the presentation layer.
        case .unknown: nil
        }
    }
}
