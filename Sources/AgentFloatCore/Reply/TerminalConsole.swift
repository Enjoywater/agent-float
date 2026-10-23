import Foundation

/// 터미널에 보낼 수 있는 키 전부. Esc·Ctrl 조합·지우기 키는 질문을 거절하거나 세션을 끝낼 수 있어 아예 표현할 수 없게 둔다 (v1.2 설계 4.3)
public enum ConsoleKey: String, CaseIterable, Sendable {
    case enter, up, down, left, right, tab, space
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
