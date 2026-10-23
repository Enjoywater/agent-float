import Foundation

public struct TranscriptTail: Equatable, Sendable {
    public var aiTitle: String?
    public var lastAssistantText: String?
    public var userPromptAfterLastAssistant: Bool
    public var pendingBackgroundTaskIds: Set<String>
    public var pendingWake: Bool
    /// 살아 있는 cron 이 모두 만료되는 시각. 만료는 시간이 흐르며 생기므로 꼬리 내용만으로 판정하지 않고 시각으로 남겨 판정 쪽이 `now` 와 비교한다
    public var cronLiveUntil: Date?
    public var modifiedAt: Date
    /// 아직 답이 기록되지 않은 마지막 질문 창. 질문 입력을 온전히 읽지 못했으면 nil
    public var openQuestion: PendingPrompt? = nil
    /// 결과가 기록되지 않은 마지막 도구 호출. 승인 창이 무엇을 묻는지 보여 줄 때 쓴다
    public var openToolUse: OpenToolUse? = nil
    /// `lastAssistantText` 가 들어 있던 레코드의 uuid. 본문 질문의 식별자다
    public var lastAssistantId: String? = nil

    public func hasLiveCron(at now: Date) -> Bool {
        cronLiveUntil.map { $0 > now } ?? false
    }
}

public struct OpenToolUse: Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String

    public init(id: String, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }
}

public enum TranscriptReader {
    public static let tailBytes = 262_144
    public static let titleScanLimit = 8_388_608
    /// CronCreate 결과 문구의 "Auto-expires after 7 days" (2.1.302 실측)
    public static let recurringCronLifetime: TimeInterval = 7 * 24 * 3600

    /// 제목을 이미 아는 호출자는 `scanHeadForTitle: false` 로 최대 8MB 앞부분 재탐색을 피한다.
    /// 제목 기록은 한 번 쓰이면 거의 안 바뀌는데 꼬리 창은 파일이 자랄 때마다 밀려, 큰 transcript 는 매번 헛수고가 된다.
    /// `since` 는 지금 프로세스의 시작 시각이다. `--resume` 한 세션은 앞 프로세스가 벌여 둔 백그라운드 작업·ScheduleWakeup 을 이어받지 않아
    /// 그 시작 기록을 남은 일로 세면 끝 알림이 영영 오지 않아 진행 중으로 굳는다. cron 은 resume 하면 되살아나 다시 울리고(2.1.302 실측),
    /// 질문 판정은 앞 프로세스의 마지막 답변도 봐야 해서 둘 다 제한하지 않는다
    public static func read(url: URL, scanHeadForTitle: Bool = true, since: Date? = nil) throws -> TranscriptTail {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let (lines, offset) = try tailLines(of: handle)
        let modifiedAt = try url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate ?? .distantPast
        var tail = parse(lines: lines, modifiedAt: modifiedAt, since: since)

        if scanHeadForTitle, tail.aiTitle == nil, offset > 0 {
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: titleScanLimit) ?? Data()
            tail.aiTitle = lastTitle(inHead: head)
        }
        return tail
    }

    /// 보낸 답이 기록됐는지 보는 용도라 방금 쓰인 꼬리 창만 읽는다
    public static func recordedAnswer(to promptId: String, url: URL) throws -> RecordedAnswer? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return recordedAnswer(to: promptId, lines: try tailLines(of: handle).lines)
    }

    private static func tailLines(of handle: FileHandle) throws -> (lines: [Substring], offset: UInt64) {
        let size = try handle.seekToEnd()
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try handle.seek(toOffset: offset)
        let chunk = try handle.readToEnd() ?? Data()

        // 창 시작이 줄 중간일 수 있어 첫 줄은 온전하다고 볼 수 없다
        var lines = splitLines(chunk)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return (lines, offset)
    }

    static func parse(lines: [Substring], modifiedAt: Date, since: Date? = nil) -> TranscriptTail {
        var scan = Scan(since: since)
        for line in lines {
            guard let record = jsonObject(Data(line.utf8)) else { continue }
            scan.consume(record)
        }
        return TranscriptTail(
            aiTitle: scan.aiTitle,
            lastAssistantText: scan.lastAssistantText,
            userPromptAfterLastAssistant: scan.promptAfterAssistant,
            pendingBackgroundTaskIds: scan.startedTaskIds.subtracting(scan.finishedTaskIds),
            pendingWake: scan.wakeAfterPrompt,
            cronLiveUntil: scan.cronJobs.values.map(\.expiresAt).max(),
            modifiedAt: modifiedAt,
            openQuestion: scan.openTools.last { $0.name == "AskUserQuestion" }.flatMap(question(from:)),
            openToolUse: scan.openTools.last.map { OpenToolUse(id: $0.id, name: $0.name, summary: summary(of: $0.input)) },
            lastAssistantId: scan.lastAssistantId
        )
    }

    /// 질문 창은 `tool_result`(+ `toolUseResult.answers`), 본문 질문은 그 답변 뒤 첫 사용자 입력이 답이다
    static func recordedAnswer(to promptId: String, lines: [Substring]) -> RecordedAnswer? {
        var afterPrompt = false
        for line in lines {
            guard let record = jsonObject(Data(line.utf8)) else { continue }
            switch record["type"] as? String {
            case "assistant":
                if record["uuid"] as? String == promptId { afterPrompt = true }
            case "user":
                let content = (record["message"] as? [String: Any])?["content"]
                if let blocks = content as? [[String: Any]] {
                    let answersThis = blocks.contains {
                        $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == promptId
                    }
                    if answersThis, let answers = (record["toolUseResult"] as? [String: Any])?["answers"] as? [String: Any] {
                        return .choices(answers.compactMapValues { $0 as? String })
                    }
                } else if afterPrompt, let text = content as? String, record["isMeta"] as? Bool != true,
                          !injectedPrefixes.contains(where: text.hasPrefix) {
                    return .text(text)
                }
            default:
                break
            }
        }
        return nil
    }

    /// 사용자가 쓰지 않았는데 사용자 레코드로 들어오는 글. 답으로 세면 보낸 답과 다르다는 잘못된 경고가 난다
    private static let injectedPrefixes = ["<task-notification>", "<local-command", "<command-name>", "<system-reminder>"]

    /// 질문 하나라도 읽지 못하면 화면의 질문 창과 짝이 맞지 않으므로 질문 전체를 읽지 못한 것으로 본다
    private static func question(from tool: Scan.OpenTool) -> PendingPrompt? {
        guard let entries = tool.input["questions"] as? [[String: Any]], !entries.isEmpty else { return nil }
        var questions: [ChoiceQuestion] = []
        for entry in entries {
            guard let text = entry["question"] as? String, !text.isEmpty,
                  let rawOptions = entry["options"] as? [[String: Any]], !rawOptions.isEmpty
            else { return nil }
            var options: [ChoiceOption] = []
            for raw in rawOptions {
                guard let label = raw["label"] as? String, !label.isEmpty else { return nil }
                let preview = raw["preview"] as? String
                options.append(ChoiceOption(
                    label: label,
                    description: raw["description"] as? String,
                    hasPreview: preview.map { !$0.isEmpty } ?? false
                ))
            }
            questions.append(ChoiceQuestion(
                text: text,
                header: entry["header"] as? String,
                multiSelect: entry["multiSelect"] as? Bool ?? false,
                options: options
            ))
        }
        return .choices(id: tool.id, questions: questions)
    }

    /// 승인 창이 무엇을 실행하려는지 한 줄로 보여 줄 값
    private static func summary(of input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func splitLines(_ data: Data) -> [Substring] {
        // 잘린 멀티바이트 문자가 청크 전체를 nil로 만들지 않도록 lossy 디코딩
        let text = String(decoding: data, as: UTF8.self)
        return text.utf8.split(separator: UInt8(ascii: "\n")).map { Substring($0) }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 앞쪽 8MB 에서 제목 줄만 골라 읽는다. 뒤에서부터 찾으므로 한도에서 잘린 마지막 줄은 파싱 실패로 건너뛴다
    private static func lastTitle(inHead head: Data) -> String? {
        let marker = Data(#""ai-title""#.utf8)
        let newline = UInt8(ascii: "\n")
        var searchEnd = head.endIndex
        while let hit = head.range(of: marker, options: .backwards, in: head.startIndex..<searchEnd) {
            let lineStart = head[..<hit.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? head.startIndex
            let lineEnd = head[hit.upperBound...].firstIndex(of: newline) ?? head.endIndex
            if let record = jsonObject(Data(head[lineStart..<lineEnd])), let title = title(of: record) {
                return title
            }
            searchEnd = hit.lowerBound
        }
        return nil
    }

    private static func title(of record: [String: Any]) -> String? {
        guard record["type"] as? String == "ai-title",
              let title = record["aiTitle"] as? String, !title.isEmpty else { return nil }
        return title
    }

    // 실측 기록은 "2026-10-16T04:12:12.221Z" 처럼 밀리초가 붙지만, 형식이 바뀌어도 시각을 잃지 않도록 초 단위도 받는다
    private static let fractionalTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondTimestamp = Date.ISO8601FormatStyle()

    private static func timestamp(of record: [String: Any]) -> Date? {
        guard let text = record["timestamp"] as? String else { return nil }
        return (try? fractionalTimestamp.parse(text)) ?? (try? wholeSecondTimestamp.parse(text))
    }

    private static func text(of toolResult: [String: Any]) -> String? {
        if let string = toolResult["content"] as? String { return string }
        guard let blocks = toolResult["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private struct CronJob {
        let isRecurring: Bool
        let expiresAt: Date
    }

    private struct Scan {
        struct OpenTool {
            let id: String
            let name: String
            let input: [String: Any]
        }

        var aiTitle: String?
        var lastAssistantText: String?
        var lastAssistantId: String?
        /// 결과가 아직 없는 도구 호출을 호출 순서대로
        var openTools: [OpenTool] = []
        var promptAfterAssistant = false
        var wakeAfterPrompt = false
        // 하나만 지워도 나머지는 계속 울리므로 하나의 참·거짓이 아니라 id 별로 둔다
        var cronJobs: [String: CronJob] = [:]
        // /effort 같은 로컬 명령은 `<command-name>` 이 먼저 기록되고 stdout 이 뒤따라야 로컬 명령임을 알 수 있어, 입력으로 센 효과를 되돌릴 기준점을 둔다
        private var beforeCommandName: (promptAfterAssistant: Bool, wakeAfterPrompt: Bool)?
        var startedTaskIds: Set<String> = []
        var finishedTaskIds: Set<String> = []
        private let since: Date?

        init(since: Date?) {
            self.since = since
        }

        /// 시각이 없거나 읽히지 않는 기록은 지금 프로세스 것으로 본다. 형식이 한 번 바뀌었다고 남은 일을 통째로 놓치지 않기 위함
        private func isBeforeSince(_ record: [String: Any]) -> Bool {
            guard let since, let recordedAt = TranscriptReader.timestamp(of: record) else { return false }
            return recordedAt < since
        }

        mutating func consume(_ record: [String: Any]) {
            switch record["type"] as? String {
            case "ai-title":
                aiTitle = TranscriptReader.title(of: record) ?? aiTitle
            case "assistant":
                consumeAssistant(record)
            case "user":
                consumeUser(record)
            case "queue-operation":
                if let content = record["content"] as? String { collectFinished(in: content) }
            case "attachment":
                if let prompt = (record["attachment"] as? [String: Any])?["prompt"] as? String {
                    collectFinished(in: prompt)
                }
            case "system":
                // 한 번짜리 cron 은 울린 뒤 CronDelete 기록 없이 저절로 지워진다
                if record["subtype"] as? String == "scheduled_task_fire",
                   let id = record["taskId"] as? String, cronJobs[id]?.isRecurring == false {
                    cronJobs[id] = nil
                }
            default:
                break
            }
        }

        private mutating func consumeAssistant(_ record: [String: Any]) {
            guard let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            var lastText: String?
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.allSatisfy(\.isWhitespace) { lastText = text }
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        openTools.append(OpenTool(id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
                    }
                    if block["name"] as? String == "CronDelete" {
                        if let id = (block["input"] as? [String: Any])?["id"] as? String { cronJobs[id] = nil }
                    } else if !isBeforeSince(record) {
                        consumeToolUse(block)
                    }
                default:
                    break
                }
            }
            if let lastText {
                lastAssistantText = lastText
                lastAssistantId = record["uuid"] as? String
                promptAfterAssistant = false
            }
        }

        private mutating func consumeToolUse(_ block: [String: Any]) {
            guard block["name"] as? String == "ScheduleWakeup" else { return }
            let stop = (block["input"] as? [String: Any])?["stop"] as? Bool
            wakeAfterPrompt = stop != true
        }

        private mutating func consumeUser(_ record: [String: Any]) {
            let content = (record["message"] as? [String: Any])?["content"]
            var isPrompt = record["isMeta"] as? Bool != true
            let pending = beforeCommandName
            beforeCommandName = nil

            if let string = content as? String {
                collectFinished(in: string)
                if string.hasPrefix("<task-notification>") || string.hasPrefix("<local-command") { isPrompt = false }
                if string.hasPrefix("<local-command-stdout>"), let pending {
                    promptAfterAssistant = pending.promptAfterAssistant
                    wakeAfterPrompt = pending.wakeAfterPrompt
                }
                if isPrompt, string.hasPrefix("<command-name>") {
                    beforeCommandName = (promptAfterAssistant, wakeAfterPrompt)
                }
            } else if let blocks = content as? [[String: Any]] {
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                let answered = Set(results.compactMap { $0["tool_use_id"] as? String })
                openTools.removeAll { answered.contains($0.id) }
                let beforeSince = isBeforeSince(record)
                for result in results {
                    guard let text = TranscriptReader.text(of: result) else { continue }
                    collectCron(in: text, scheduledAt: TranscriptReader.timestamp(of: record))
                    if !beforeSince { collectStarted(in: text) }
                }
                if !results.isEmpty { isPrompt = false }
            } else {
                isPrompt = false
            }

            if isPrompt {
                promptAfterAssistant = true
                wakeAfterPrompt = false
                // 사용자가 새로 입력했다면 그 전에 떠 있던 질문·승인 창은 더 이상 답을 기다리지 않는다
                openTools.removeAll()
            }
        }

        // 도구 출력 본문이 이 문구를 단순 인용한 경우(파일 읽기 결과 등)를 거르려 시작 위치에 고정한다
        private mutating func collectStarted(in text: String) {
            if let match = text.firstMatch(of: /^\s*Command running in background with ID: ([A-Za-z0-9_-]+)/) {
                startedTaskIds.insert(String(match.output.1))
            }
            if let match = text.firstMatch(of: /^\s*Async agent launched successfully[\s\S]*?agentId: ([A-Za-z0-9]+)/) {
                startedTaskIds.insert(String(match.output.1))
            }
        }

        /// CronCreate 호출이 아니라 결과 문구로 등록을 센다. id 와 반복 여부가 한 줄에 있고, 실패한 호출은 이 문구를 남기지 않는다.
        /// 시각을 모르는 기록은 만료를 셀 수 없어 끝나지 않는 것으로 둔다
        private mutating func collectCron(in text: String, scheduledAt: Date?) {
            guard let match = text.firstMatch(of: /^\s*Scheduled (recurring job|one-shot task) ([A-Za-z0-9_-]+)/) else { return }
            let isRecurring = match.output.1 == "recurring job"
            var expiresAt = Date.distantFuture
            if isRecurring, let scheduledAt {
                expiresAt = scheduledAt.addingTimeInterval(TranscriptReader.recurringCronLifetime)
            }
            cronJobs[String(match.output.2)] = CronJob(isRecurring: isRecurring, expiresAt: expiresAt)
        }

        private mutating func collectFinished(in text: String) {
            for piece in text.components(separatedBy: "<task-notification>").dropFirst() {
                guard let id = piece.firstMatch(of: /<task-id>\s*([^<\s]+)\s*<\/task-id>/),
                      piece.firstMatch(of: /<status>\s*(?:completed|failed|killed|stopped)\s*<\/status>/) != nil
                else { continue }
                finishedTaskIds.insert(String(id.output.1))
            }
        }
    }
}
