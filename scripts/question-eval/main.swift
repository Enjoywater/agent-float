import Foundation

// Compiled together with the real QuestionHeuristic.swift so the numbers come from shipping code, not a re-implementation.
while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["text"] as? String else {
        print("E")
        continue
    }
    print(QuestionHeuristic.endsWithQuestion(text) ? "1" : "0")
}
