import Foundation

/// Codex 저장 기록에서 미응답 질문과 보낸 답을 연결한다.
struct CodexTranscript: Sendable {
    var pendingChoice: PendingPrompt?
    var lastMessage: (id: String, text: String)?
    var records: [String: RecordedAnswer] = [:]
    var latestUserText: String?
    var latestTool: (id: String, name: String, summary: String)?

    static func read(path: String, sessionID: String) throws -> CodexTranscript {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > 2 * 1024 * 1024 ? size - 2 * 1024 * 1024 : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        return parse(data, sessionID: sessionID, dropFirstLine: start != 0)
    }

    static func parse(_ data: Data, sessionID: String, dropFirstLine: Bool = false) -> CodexTranscript {
        var result = CodexTranscript()
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if dropFirstLine, !lines.isEmpty { lines.removeFirst() }
        // 기록 중인 마지막 줄은 정상 레코드로 취급하지 않는다.
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        for line in lines {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = row["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String
            let timestamp = row["timestamp"] as? String ?? ""
            let rawID = payload["id"] as? String ?? payload["call_id"] as? String ?? timestamp
            let id = "codex:\(sessionID):\(rawID)"
            if row["type"] as? String == "event_msg", type == "task_started" {
                result.pendingChoice = nil
                result.latestUserText = nil
            }
            guard row["type"] as? String == "response_item" else { continue }
            switch type {
            case "message":
                let content = payload["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if payload["role"] as? String == "assistant", payload["phase"] as? String != "commentary", !text.isEmpty {
                    result.lastMessage = (id, text)
                } else if payload["role"] as? String == "user", !text.isEmpty {
                    if let message = result.lastMessage { result.records[message.id] = .text(text) }
                    result.latestUserText = text
                    result.lastMessage = nil
                }
            case "function_call", "custom_tool_call":
                let name = payload["name"] as? String ?? ""
                let callID = payload["call_id"] as? String ?? rawID
                let promptID = "codex:\(sessionID):\(callID)"
                let input = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
                result.latestTool = (promptID, name, String(input.prefix(1000)))
                if name.split(separator: ".").last == "request_user_input",
                   let args = try? JSONDecoder().decode(UserInputRequest.self, from: Data(input.utf8)) {
                    result.pendingChoice = .choices(id: promptID, questions: args.questions.map { q in
                        ChoiceQuestion(text: q.question, header: q.header, multiSelect: false, options: (q.options ?? []).map {
                            ChoiceOption(label: $0.label, description: $0.description, hasPreview: false)
                        })
                    })
                }
            case "function_call_output", "custom_tool_call_output":
                guard let callID = payload["call_id"] as? String else { continue }
                let promptID = "codex:\(sessionID):\(callID)"
                let output: String
                if let text = payload["output"] as? String { output = text }
                else {
                    let parts = payload["output"] as? [[String: Any]] ?? []
                    output = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                if case let .choices(id, questions)? = result.pendingChoice, id == promptID,
                   let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                   let answers = object["answers"] as? [String: [String: [String]]] {
                    // 요청 ID로 질문 본문과 답을 연결한다. 사전 순서에 의존하지 않는다.
                    if let request = findRequest(lines: lines, callID: callID), request.questions.count == questions.count {
                        var record: [String: String] = [:]
                        for question in request.questions {
                            if let answer = answers[question.id]?["answers"] { record[question.question] = Self.normalizedAnswer(answer) }
                        }
                        result.records[promptID] = .choices(record)
                    }
                    result.pendingChoice = nil
                }
            default: break
            }
        }
        return result
    }

    private static func normalizedAnswer(_ answer: [String]) -> String {
        if answer.first == "None of the above", let note = answer.first(where: { $0.hasPrefix("user_note: ") }) {
            return String(note.dropFirst("user_note: ".count))
        }
        return answer.joined(separator: ", ")
    }

    private static func findRequest(lines: [Data.SubSequence], callID: String) -> UserInputRequest? {
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let p = object["payload"] as? [String: Any], p["call_id"] as? String == callID,
                  let args = p["arguments"] as? String else { continue }
            if let request = try? JSONDecoder().decode(UserInputRequest.self, from: Data(args.utf8)) { return request }
        }
        return nil
    }

    private struct UserInputRequest: Decodable {
        let questions: [Question]
        struct Question: Decodable {
            let id: String
            let header: String?
            let question: String
            let options: [Option]?
        }
        struct Option: Decodable { let label: String; let description: String? }
    }
}
