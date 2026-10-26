import Foundation

/// 터미널에 보낼 수 있는 키 전부. Esc·Ctrl 조합은 질문을 거절하거나 세션을 끝낼 수 있어 아예 표현할 수 없게 둔다 (v1.2 설계 4.3).
/// 지우기는 넣어 보고 확인하는 콘솔이 자기가 방금 넣은 글자 하나를 되돌릴 때만 쓴다 (R78)
public enum ConsoleKey: String, CaseIterable, Sendable {
    case enter, up, down, left, right, tab, space, backspace
}

public enum ConsoleInput: Equatable, Sendable {
    case text(String)
    case key(ConsoleKey)
}

/// 터미널에 지금 그려진 글자. 흐림(SGR 2)은 빈 입력 칸에 뜨는 안내·제안 문구를 쓰다 만 글과 가르는 유일한 단서다 (R57)
public struct ConsoleScreen: Equatable, Sendable {
    public let lines: [String]
    /// 줄마다 흐리게 그려진 글자의 위치(Character 오프셋). 스타일을 읽지 못하는 콘솔은 nil
    public let faint: [Set<Int>]?
    /// Orca 처럼 터미널 밖에 따로 있는 입력창의 글
    public let composerDraft: String?

    public init(lines: [String], faint: [Set<Int>]?, composerDraft: String?) {
        self.lines = lines
        self.faint = faint
        self.composerDraft = composerDraft
    }

    /// `tmux capture-pane -e` 처럼 SGR 이 섞인 글에서 글자와 흐림 위치를 뽑는다. 흐림은 실제 터미널처럼 줄을 넘어 이어진다
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

    /// ESC 로 시작하는 시퀀스 하나를 건너뛰고 다음 위치를 돌려준다. SGR(`m`)만 흐림 상태를 바꾼다
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
            // OSC 는 BEL 이나 ESC \ 로 끝난다
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

    /// 색 지정(38·48·58)은 뒤따르는 값에 2 가 들어갈 수 있어(`38;2;r;g;b`) 그 값들을 흐림으로 읽지 않게 건너뛴다
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

/// 답장 화면을 처음부터 "보기만"으로 여는 이유. 쓰고 나서 막히지 않게 쓰기 전에 알려 준다 (v1.2 설계 4.4 G0)
public enum ReadOnlyReason: Equatable, Sendable {
    /// 보낼 수 없는 터미널. 값은 화면에 쓸 앱 이름
    case unsupportedTerminal(String)
    case hiddenTab
    /// 다른 데스크탑까지 찾아도 이 세션의 탭이 없음(제목이 바뀌었거나 탭이 닫힘)
    case tabNotFound
    case accessibilityNeeded
    case ambiguousTab
    case splitTab
    case previewQuestion
    case permissionPrompt
}

/// 본문 질문에서 입력 칸이 비었는지 언제 알 수 있는지 (R57·R78)
public enum PromptCheck: Equatable, Sendable {
    /// 넣기 전에 화면만 보고 안다. 흐림(tmux)이나 입력 칸의 실제 글(Orca `draft`)을 따로 읽는다
    case beforeTyping
    /// 안내 문구가 글로 읽혀 첫 글자를 넣어 본 뒤에야 안다. 쓰던 글 뒤에 붙었으면 그 글자를 지우고 멈춘다 (Ghostty)
    case afterTyping
}

public enum ConsoleAvailability: Equatable, Sendable {
    case ready
    case readOnly(ReadOnlyReason)
}

/// 터미널 하나에 키를 보내고 화면을 읽는 담당. 위치 정보(`TerminalLocator`) 종류마다 하나다
public protocol TerminalConsole: Sendable {
    var promptCheck: PromptCheck { get }
    func handles(_ session: AgentSession) -> Bool
    func availability(of session: AgentSession) async -> ConsoleAvailability
    func readScreen(of session: AgentSession) async throws -> ConsoleScreen
    func send(_ input: ConsoleInput, to session: AgentSession) async throws
}

extension TerminalConsole {
    /// 제어 문자는 키로 해석되어 글과 다른 동작을 일으킨다. 화면 쪽 검사와 겹치는 두 번째 방어선이다
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

    /// 질문 쪽 이유를 먼저 본다. 터미널을 건드리지 않고 정할 수 있고, 터미널이 되더라도 답할 수 없는 질문이기 때문이다
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

    static func appName(_ app: TerminalApp) -> String {
        switch app {
        case .ghostty: "Ghostty"
        case .orca: "Orca"
        case .other("Apple_Terminal"): "Terminal"
        case .other("iTerm.app"): "iTerm2"
        case let .other(name): name
        // "이 터미널에는 …" 문장에 그대로 들어간다
        case .unknown: "이"
        }
    }
}
