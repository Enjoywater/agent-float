import Foundation

public struct TranscriptTail: Equatable, Sendable {
    public var aiTitle: String?
    public var lastAssistantText: String?
    public var userPromptAfterLastAssistant: Bool
    public var pendingBackgroundTaskIds: Set<String>
    public var pendingWake: Bool
    /// Store when all live cron jobs expire; derive expiry against now rather than frozen tail contents.
    public var cronLiveUntil: Date?
    public var modifiedAt: Date
    /// The latest unanswered dialog; nil if its complete question input could not be parsed.
    public var openQuestion: PendingPrompt? = nil
    /// The last tool call without a result, used to explain pending approval.
    public var openToolUse: OpenToolUse? = nil
    /// UUID of the record containing lastAssistantText, identifying the text question.
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
    /// CronCreate result marker: Auto-expires after 7 days (2.1.302).
    public static let recurringCronLifetime: TimeInterval = 7 * 24 * 3600

    /// Callers with a known title disable scanHeadForTitle to avoid rescanning up to 8 MB.
    /// Titles rarely change, while the moving tail window would otherwise trigger redundant head scans of large transcripts.
    /// Since is the current process start; resumed sessions do not inherit previous background jobs or ScheduleWakeup calls.
    /// Counting old jobs would leave sessions running forever. Cron jobs do revive on resume (2.1.302),
    /// and questions must consider the previous process's final reply, so neither is restricted by since.
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

    /// Read only the recent tail when verifying recorded delivery.
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

        // The window may start mid-line, so the first line is not necessarily complete.
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

    /// Dialogs answer via tool_result/toolUseResult.answers; text questions use the first subsequent real user input.
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

    /// These user records are not typed replies; counting them would produce false delivery-mismatch warnings.
    private static let injectedPrefixes = ["<task-notification>", "<local-command", "<command-name>", "<system-reminder>"]

    /// Reject the whole dialog if any question is unreadable, preventing partial screen matching.
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

    /// One-line explanation of the command awaiting approval.
    private static func summary(of input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func splitLines(_ data: Data) -> [Substring] {
        // Decode lossily so a split multibyte character does not discard the entire chunk.
        let text = String(decoding: data, as: UTF8.self)
        return text.utf8.split(separator: UInt8(ascii: "\n")).map { Substring($0) }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Scan only title records in the first 8 MB, backward; skip a truncated final line on parse failure.
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

    // Accept timestamps with or without milliseconds to tolerate transcript-format changes.
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
        /// Unresolved tool calls in invocation order.
        var openTools: [OpenTool] = []
        var promptAfterAssistant = false
        var wakeAfterPrompt = false
        // Track cron jobs by ID: deleting one does not stop the others.
        var cronJobs: [String: CronJob] = [:]
        // Local commands such as /effort are identified only after their stdout follows command-name; retain a rollback point.
        private var beforeCommandName: (promptAfterAssistant: Bool, wakeAfterPrompt: Bool)?
        var startedTaskIds: Set<String> = []
        var finishedTaskIds: Set<String> = []
        private let since: Date?

        init(since: Date?) {
            self.since = since
        }

        /// Treat missing/unreadable timestamps as current-process records to avoid losing all pending work after format changes.
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
                // One-shot cron jobs expire after firing without an explicit CronDelete record.
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
                // New user input resolves earlier pending question/approval dialogs.
                openTools.removeAll()
            }
        }

        // Anchor at the start to reject tool output merely quoting this marker, such as file-read results.
        private mutating func collectStarted(in text: String) {
            if let match = text.firstMatch(of: /^\s*Command running in background with ID: ([A-Za-z0-9_-]+)/) {
                startedTaskIds.insert(String(match.output.1))
            }
            if let match = text.firstMatch(of: /^\s*Async agent launched successfully[\s\S]*?agentId: ([A-Za-z0-9]+)/) {
                startedTaskIds.insert(String(match.output.1))
            }
        }

        /// Count successful CronCreate results rather than calls: the result carries ID/repeat state and excludes failures.
        /// Unknown timestamps cannot establish expiry, so keep those jobs pending.
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
