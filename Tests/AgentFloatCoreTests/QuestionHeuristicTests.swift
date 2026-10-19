import Testing
@testable import AgentFloatCore

@Test(arguments: [
    "이런 게 있었으면 좋겠다고 가장 최근에 느낀 순간에 어떤 터미널들을 오가며 뭘 확인하려 했는지 들려줄 수 있나?",
    "앱을 어떤 기술로 만들지 직접 정하고 싶은지, 아니면 맡길지 궁금함. 맡기면 내가 고르고 이유를 설계에 적어 둠.",
    "시안을 보고 어느 쪽이 끌리는지 알려줘. 브라우저에서 클릭해 고르기만 해도 됨.",
    "## 정리\n- 항목\n\n틀리거나 빠진 부분이 있으면 알려줘.",
    "이 방향이 원한 Apple스러움에 맞는지 알려줘.\n\nSources:\n- [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)",
    "Which approach should we use?",
    "**`ASK`는 실제로 답할 때까지 남겨 두는 게 맞는지** 궁금함.",
]) func detectsQuestions(_ text: String) { #expect(QuestionHeuristic.endsWithQuestion(text)) }

@Test(arguments: [
    "A안을 설계 문서 4.6절·4.10절에 반영함. 시안 서버는 종료했고, 이제 구현 계획 작성으로 넘어감.",
    "왜 실패했나? 원인은 경로 오타였음.\n\n수정 후 테스트 42개 통과.",
    "변경 파일: `Sources/AgentFloatCore/Model/Labels.swift` — 테스트 통과.",
    "",
]) func ignoresStatements(_ text: String) { #expect(!QuestionHeuristic.endsWithQuestion(text)) }

@Test(arguments: [
    "어떤 방식으로 진행할지 정해 주세요.",
    "제출 전에 입력 값을 한 번 더 확인 부탁드립니다.",
    "다른 방식이 낫다면 말해달라.",
    "실행해 보고 결과를 알려달라.",
    "이 값은 새 필드인가요, 기존 설정인가요",
    "확인해 주시면 다음 단계로 진행하겠습니다.",
    "방향이 정해지면 알려주면 바로 이어서 작업함.",
    "범위를 줄여 해 주면 좋겠다는 쪽으로 정리함.",
    "먼저 검토해주면 이어서 반영하겠습니다.",
    "어느 쪽이 나은지 알려줘 :)",
    "이 방식이 맞는지 궁금합니다~",
    "이 순서가 괜찮은지 알려줘 🙏",
    "이 방식이 맞는지 알려줘.\r\n\r\nSources:\r\n- [Guide](https://example.com/guide)",
    "이 방식이 맞는지 알려줘.\n\nSources\n\n- [Guide](https://example.com/guide)",
    "이 방식이 맞는지 알려줘.\n\n출처: https://example.com/guide",
    "참고로 이 방식이 맞는지 알려줘.",
    "참고: 이 방식이 맞는지 알려줘.",
    "Is this right？",
]) func detectsQuestionVariants(_ text: String) { #expect(QuestionHeuristic.endsWithQuestion(text)) }

@Test(arguments: [
    "Done. All tests pass.",
    "두 값이 서로 달라.",
    "검토를 마쳤고 다음 단계로 진행하겠습니다.",
    "참고로 빌드는 통과함.",
    "이 방식이 맞는지 알려줘.\n\n마지막 문단은 결과 보고뿐임.",
    "Sources:\n- [Guide](https://example.com/guide)",
    "출처\n\n- [Guide](https://example.com/guide)",
    "   \n\n  ",
]) func ignoresStatementVariants(_ text: String) { #expect(!QuestionHeuristic.endsWithQuestion(text)) }
