# Agent Float v1.2 — 플로팅에서 바로 답하기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 펼친 패널의 대기 줄에서 질문 내용을 보고, 터미널에 들어가지 않고 그 자리에서 답을 보낸다. 의도와 다른 답은 절대 보내지 않는다.

**Architecture:** provider가 transcript 꼬리에서 질문(`PendingPrompt`)을 읽어 세션에 붙인다. 보내기는 터미널별 콘솔(`TerminalConsole`: tmux·Orca·Ghostty)이 화면 읽기와 키 입력을 맡고, `ReplyDelivery`가 G1 같은 질문 → G2 화면 → G3 한 단계씩 입력·화면 재확인 → G4 기록 대조를 돌린다. 키 순서는 고정 목록이 아니라 "지금 화면을 읽고 다음 키 하나를 정하는" `ReplyDriver`가 정하고, 그 화면 판독 규칙은 Task 1 실측 표가 기준이다. 앱 쪽은 `ReplyCenter`가 답장 화면 상태·쓰다 만 답·실패 표시를 들고, 패널은 배치(C 기본, A, B)에 따라 같은 답장 내용 뷰를 담는다.

**Tech Stack:** Swift 6, SwiftUI + AppKit(`NSPanel`, `NSTextView`), Swift Testing, AppleScript(`osascript`), Accessibility API(`AXUIElement`), tmux CLI, Orca CLI

**Spec:** `docs/specs/2026-10-23-agent-float-v1.2-reply-design.md` (이하 "설계"). 바탕은 `docs/specs/2026-10-16-agent-float-design.md`(이하 "v1 설계"). 시안: `docs/specs/2026-10-23-agent-float-v1.2-reply-mockups/reply-flow-c.html`

## Global Constraints

- macOS 26 이상, Swift 6 언어 모드, 외부 패키지 의존 없음
- 공통 타입 이름에 `claude`를 쓰지 않음. Claude Code 고유 판독만 `Claude*` 이름
- 주석은 why만. 자명한 주석·주석 처리된 코드 금지. 중첩 삼항 금지. TODO는 `// TODO(@Enjoywater): 사유` 형식만
- **회사·개인 정보 절대 금지 (설계 3장)**: 코드·테스트·fixture·문서·커밋 메시지·인증서 이름에 회사 이름, 사람 이름·이메일·계정명, 실제 세션 제목·폴더명, 실제 transcript 문장을 넣지 않음. 경로는 `/Users/me`, id는 `00000000-…`, 예시 내용은 시안과 같은 가상 주제(캐시 만료 정책·검색 색인·동기화 재시도). 매 커밋 전에 `scripts/privacy-check.sh`(Task 1) 0건
- 커밋 공동 작성자는 저장소 루트 `AGENTS.md`에 따라 실제 기여한 에이전트로 기록한다 (세션 링크 줄 없음).
- 터미널에 보내는 키는 `ConsoleKey`(enter·up·down·left·right·tab·space)와 검사를 통과한 글자뿐. **Esc·Ctrl 조합·지우기 키는 타입으로 막는다** (설계 4.3)
- 셸·AppleScript에 들어가는 외부 값(handle, pane id, 소켓 경로, terminal id, 보낼 글)은 형식 검사·이스케이프 뒤에만 쓴다 (R25 원칙)
- 하나라도 확인 못 하면 보내지 않는다. 판정이 애매하면 "보내지 않음" 쪽으로 (설계 4.4)
- 시험 세션: haiku, 이미 신뢰한 폴더, 끝나면 `/exit`, `env -i`로 이 세션의 `CLAUDE_CODE_*` 환경을 비운 셸, tmux는 전용 소켓 `-L agent-float-spike`. **사용자의 실제 세션에는 보내지 않음**
- 화면 수치·문구는 설계 4.6·4.8 표의 값을 그대로 쓴다 (아래 Task의 `ReplyLayout` 상수와 `ReplyCopy`)

## Review Focus

1. 패널이 보내는 도중 사용자가 그 터미널에 직접 타이핑함 → 다음 단계 화면 재확인에서 예상과 달라 그 자리에서 멈추고 "보내다 멈췄어요" (Task 5 `typingInTerminalMidwayStops`)
2. 답장 화면을 열어 둔 사이 터미널에서 이미 답함 → 보내기를 눌러도 키 0개, "터미널에서 이미 답했어요" (Task 5 `answeredMeanwhileSendsNothing`)
3. 한글 조합 중 ⏎ → 조합만 확정되고 보내지 않음 (Task 7 `returnDuringCompositionOnlyCommits`)
4. 본문 질문 답이 `/`·`!`·`#`로 시작(슬래시 명령·셸 모드·메모로 읽힘)하거나 줄바꿈·제어 문자를 포함 → 보내기 버튼 비활성 + 이유 문구 (Task 7 `commandLikeTextIsBlocked`)
5. 좁은 터미널에서 질문 문장이 여러 줄로 감김 → 화면 판독이 감긴 줄을 이어 붙여 같은 질문으로 알아봄 (Task 3 `wrappedQuestionIsRecognized`)

---

## File Structure

| 파일 | 할 일 |
|---|---|
| `scripts/create-signing-identity.sh` (새) | 로컬 전용 자체 서명 코드 서명 인증서 `Agent Float Local Signing` 생성 |
| `scripts/privacy-check.sh` (새) | 저장소 밖 단어 목록(`.git/info/privacy-words`)으로 추적 파일 grep |
| `Makefile` | 인증서 있으면 그것으로, 없으면 ad-hoc + 경고 |
| `Sources/AgentFloatCore/Model/PendingPrompt.swift` (새) | 질문 모델 |
| `Sources/AgentFloatCore/Model/AgentSession.swift` | `prompt` 필드 |
| `Sources/AgentFloatCore/Claude/TranscriptReader.swift` | 열린 질문·도구, 마지막 답변 uuid, 기록된 답 읽기 |
| `Sources/AgentFloatCore/Claude/ClaudeStatusDeriver.swift` | 대기 사유 → `PendingPrompt` |
| `Sources/AgentFloatCore/Claude/ClaudeCodeProvider.swift` | `prompt` 채우기, `AnswerRecordReading` |
| `Sources/AgentFloatCore/Provider/SessionStore.swift` | 기록된 답 조회를 provider로 전달 |
| `Sources/AgentFloatCore/Reply/TerminalConsole.swift` (새) | 콘솔 프로토콜·입력·화면·가능 여부·registry |
| `Sources/AgentFloatCore/Reply/ClaudeScreen.swift` (새) | 화면 글자 → 질문 창·확인 화면·프롬프트 판독 |
| `Sources/AgentFloatCore/Reply/ReplyDriver.swift` (새) | 답 초안·다음 입력 결정·기대 기록 |
| `Sources/AgentFloatCore/Reply/ReplyDelivery.swift` (새) | G1~G4 |
| `Sources/AgentFloatCore/Reply/TmuxConsole.swift`, `OrcaConsole.swift`, `GhosttyConsole.swift` (새) | 터미널별 콘솔 |
| `Sources/AgentFloatCore/Reply/ReplyEditor.swift` (새) | 답장 화면 편집 상태·키 해석·글 검사 |
| `Sources/AgentFloatCore/Window/ReplyPlacement.swift` (새) | 배치 설정 |
| `Sources/AgentFloatCore/Signals/SignalTracker.swift`, `SessionGrouping.swift` | `FAIL` 개수, "확인 필요" 묶음 |
| `Sources/AgentFloat/Reply/ReplyCenter.swift` (새) | 앱 쪽 답장 상태 |
| `Sources/AgentFloat/Reply/AXGhosttyScreenReader.swift` (새) | 손쉬운 사용 API로 Ghostty 화면 읽기 |
| `Sources/AgentFloat/Reply/FakeConsole.swift` (새) | 화면 확인용 가짜 콘솔 |
| `Sources/AgentFloat/Views/Reply/*.swift` (새) | 답장 화면 뷰 |
| `Sources/AgentFloat/FloatingPanel.swift`, `PanelController.swift`, `Views/FloatRootView.swift`, `Views/ExpandedPanelView.swift`, `Views/SessionRow.swift`, `Views/SummaryRow.swift`, `Views/Palette.swift`, `MenuBarController.swift`, `AppDelegate.swift`, `AppModel.swift`, `FakeProvider.swift` | 연결 |
| `Tests/AgentFloatCoreTests/Fixtures/screens/*` (새) | 실측 형식을 따른 **가상 내용** 화면 fixture |

---

### Task 1: 서명 준비와 실측 S1·S2

**Files:**
- Create: `scripts/create-signing-identity.sh`, `scripts/privacy-check.sh`, `Tests/AgentFloatCoreTests/Fixtures/screens/` 아래 fixture
- Modify: `Makefile`, `docs/plans/2026-10-16-agent-float-rulings.md` (`## v1.2 답장 (2026-10-23~)` 섹션)

**Interfaces:**
- Produces:
  - 키·화면 표 (rulings 섹션): 질문 창의 기본 배치에서 ① 포커스 줄 표시 모양 ② 위·아래 키가 포커스를 옮기는지 ③ Enter로 고르는지 ④ "Type something." 줄에 포커스가 가면 곧바로 글자를 받는지(아니면 Enter가 먼저 필요한지)와 그 칸의 화면 모양 ⑤ 여러 개 고르기에서 켜고 끄는 키(space 또는 enter)와 체크 표시 모양, 다 고른 뒤 넘어가는 방법 ⑥ 질문 여러 개에서 답한 뒤 다음 질문으로 넘어가는 모양과 확인 화면("Ready to submit your answers?")의 기본 포커스 ⑦ `toolUseResult.answers`에 여러 개 고르기 답이 기록되는 형식 ⑧ 직접 쓰기 칸·프롬프트가 붙여넣은 줄바꿈을 받는지 ⑨ 빈 프롬프트에 안내 문구가 보이는지(보이면 그 문구 전체) ⑩ 붙여넣은 글이 `/`·`!`·`#`로 시작하거나 `@`를 포함할 때 Enter가 자동 완성을 고르는지 ⑪ `tool_use`가 창이 뜬 순간 이미 transcript에 있는지 ⑫ Orca `terminal send`로 화살표(ESC 시퀀스 글자)·Enter가 들어가는지, `terminal read --screen --json`의 JSON 모양과 `draft` 의미
  - fixture (모두 가상 내용, 실측의 줄 모양·기호·여백만 따름): `choice-single-focus0.txt`, `choice-single-focus1.txt`, `choice-other-focused-empty.txt`, `choice-other-typed.txt`, `choice-multiselect-checked.txt`, `choice-two-questions-q1.txt`, `choice-two-questions-q2.txt`, `choice-review.txt`, `choice-wrapped.txt`(40열에서 감긴 질문), `prompt-empty.txt`, `prompt-draft.txt`, `prompt-busy.txt`, `orca-read-screen.json`
  - `make bundle`이 `Agent Float Local Signing`으로 서명

- [ ] **Step 1: 비공개 단어 목록과 검사 스크립트** — 단어 목록 `.git/info/privacy-words`(추적 안 됨, 계획 작성 때 이미 만들어 둠: 회사 이름·사람 이름·계정명·이메일·인증서 팀 id·실제 업무 폴더명·실제 세션 제목)은 그대로 쓰고, 없으면 사용자에게 받는다. 저장소에 이미 쓰는 GitHub 계정명(TODO 형식·번들 id)은 목록에 넣지 않음. `scripts/privacy-check.sh`: 목록이 없으면 실패, 있으면 `git ls-files -z | xargs -0 grep -n -i -F -f .git/info/privacy-words`와 `git diff --cached` 내용을 함께 검사해 0건이면 종료 코드 0. 스크립트 자체에는 어떤 단어도 넣지 않음
- [ ] **Step 2: 확인** — `scripts/privacy-check.sh` → 0건, 종료 코드 0. 일부러 목록 단어 하나를 넣은 임시 파일을 `git add` 했을 때 1건으로 실패하는지 확인 후 되돌림
- [ ] **Step 3: 인증서 스크립트** — `scripts/create-signing-identity.sh`: 이미 `security find-identity -p codesigning`에 있으면 아무것도 안 함. 없으면 임시 폴더에서 `openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -subj "/CN=Agent Float Local Signing" -config <임시 설정> -extensions ext`(macOS 기본 LibreSSL에서도 되도록 확장은 설정 파일의 `[ext]` 절: `keyUsage=critical,digitalSignature`, `extendedKeyUsage=critical,codeSigning`, `basicConstraints=critical,CA:false`) → p12 → `security import … -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign` → `security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem`(이때 macOS 암호 창 → 사용자가 직접 허용). 임시 파일은 끝나면 지움. CN 외 필드 없음
- [ ] **Step 4: Makefile** — `SIGN_IDENTITY ?= Agent Float Local Signing`. `bundle`의 서명 줄: 인증서가 있으면 `codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"`, 없으면 `codesign --force --sign - "$(APP)"` + `echo "경고: $(SIGN_IDENTITY) 인증서가 없어 ad-hoc 서명합니다. 다시 빌드하면 손쉬운 사용·자동화 권한이 풀립니다 (scripts/create-signing-identity.sh)" >&2`
- [ ] **Step 5: 확인** — 스크립트 실행(사용자에게 암호 창이 뜬다고 먼저 알림) → `make bundle` → `codesign -dv "build/Agent Float.app" 2>&1 | grep Authority` 가 `Authority=Agent Float Local Signing`. 두 번 빌드해 `codesign -d -r- ` 지정 요구사항이 같은지 확인
- [ ] **Step 6: S1 tmux 실측** — `env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm-256color LANG=ko_KR.UTF-8 tmux -L agent-float-spike new-session -d -s spike -x 100 -y 40`, 신뢰한 폴더에서 `claude --model haiku`. haiku에게 가상 주제로 질문 창을 띄우게 함(하나 고르기 3선택지, 여러 개 고르기, 질문 2개). 각 상태에서 `tmux -L agent-float-spike capture-pane -p -t spike`와 `capture-pane -p -e`(스타일 포함)를 저장하고, `send-keys`로 Up/Down/Enter/Space/Tab과 `send-keys -l -- '<글>'`를 보내며 표 ①~⑪을 채운다. 같은 세션의 transcript를 `tail -c`로 지켜보며 ⑦·⑪ 확인. `-x 40`으로 다시 띄워 감긴 질문 하나를 캡처. 끝나면 `/exit` + `tmux -L agent-float-spike kill-server`
- [ ] **Step 7: S2 Orca 실측** — `orca terminal --help`로 시험용 터미널을 새로 만드는 명령이 있는지 확인. 있으면 새 터미널에서 같은 방식으로 haiku 질문 창을 띄워 표 ⑫를 채움. 없으면 사용자에게 "Orca에 시험용 터미널 하나를 열어 주세요"라고 요청하고 그 터미널에서만 함. 사용자의 기존 Orca 터미널에는 `send`하지 않음
- [ ] **Step 8: 표와 fixture 기록** — rulings에 표 ①~⑫와 실측 버전(Claude Code·tmux·Orca), "결과가 안 좋을 때"(설계 6장)에 해당하는 유형이 있으면 그 결정(R57부터). 캡처를 그대로 커밋하지 않고, 같은 줄 모양으로 질문·선택지·글을 가상 내용으로 바꿔 fixture를 손으로 만든다. 설계 5장의 ❓ 행(⑪)을 ✅/❌로 갱신
- [ ] **Step 9: 검사·커밋** — `scripts/privacy-check.sh` 0건, `swift test` 통과 → `git commit -m "chore: sign with a local identity and record reply spike results"`

---

### Task 2: 질문 모델과 transcript 판독

**Files:**
- Create: `Sources/AgentFloatCore/Model/PendingPrompt.swift`
- Modify: `Sources/AgentFloatCore/Model/AgentSession.swift`, `Sources/AgentFloatCore/Claude/TranscriptReader.swift`, `Sources/AgentFloatCore/Claude/ClaudeStatusDeriver.swift`, `Sources/AgentFloatCore/Claude/ClaudeCodeProvider.swift`, `Sources/AgentFloatCore/Provider/SessionStore.swift`
- Test: `Tests/AgentFloatCoreTests/PendingPromptTests.swift` (새), `TranscriptReaderTests.swift`, `ClaudeStatusDeriverTests.swift`, `ClaudeCodeProviderTests.swift`, `SessionStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct ChoiceOption: Equatable, Sendable { let label: String; let description: String?; let hasPreview: Bool; var displayLabel: String; var isRecommended: Bool }` — `displayLabel`은 끝의 `" (Recommended)"`를 뗀 값, `isRecommended`는 그 접미사가 있었는지
  - `struct ChoiceQuestion: Equatable, Sendable { let text: String; let header: String?; let multiSelect: Bool; let options: [ChoiceOption]; var hasPreview: Bool }`
  - `enum PendingPrompt: Equatable, Sendable { case choices(id: String, questions: [ChoiceQuestion]); case text(id: String, message: String); case permission(id: String, tool: String, summary: String); var id: String }`
  - `AgentSession.prompt: PendingPrompt?` — init 끝에 `prompt: PendingPrompt? = nil` (기존 호출부 그대로 컴파일)
  - `TranscriptTail`에 `var openQuestion: PendingPrompt? = nil`(`.choices`만), `var openToolUse: OpenToolUse? = nil`, `var lastAssistantId: String? = nil`; `struct OpenToolUse: Equatable, Sendable { let id: String; let name: String; let summary: String }`
  - `enum RecordedAnswer: Equatable, Sendable { case choices([String: String]); case text(String) }`
  - `TranscriptReader.recordedAnswer(to promptId: String, url: URL) throws -> RecordedAnswer?` — 꼬리 창(`tailBytes`)만 읽음
  - `ClaudeStatusDeriver.prompt(for reason: WaitReason?, tail: TranscriptTail?) -> PendingPrompt?`
  - `protocol AnswerRecordReading: Sendable { func recordedAnswer(sessionId: String, promptId: String) -> RecordedAnswer? }` — `ClaudeCodeProvider`가 따름
  - `SessionStore.recordedAnswer(for key: SessionKey, promptId: String) -> RecordedAnswer?` — `providerId`가 같은 provider 중 `AnswerRecordReading`인 것에 물음

- [ ] **Step 1: 실패하는 테스트** (줄 fixture는 테스트 안 문자열, 모두 가상 내용)

```swift
// PendingPromptTests
@Test func recommendedSuffixBecomesBadge()
    // ChoiceOption(label: "읽은 때부터 다시 세기 (Recommended)", …) → displayLabel == "읽은 때부터 다시 세기", isRecommended
@Test func plainLabelIsUnchanged() // "고정 10분 유지" → displayLabel 같음, !isRecommended

// TranscriptReaderTests
@Test func openAskQuestionIsParsed()
    // assistant tool_use {id:"toolu_01", name:"AskUserQuestion", input:{questions:[{question:"만료 방식을 어떻게 할까요?", header:"만료 방식", multiSelect:false, options:[{label:"읽은 때부터 다시 세기 (Recommended)", description:"…"},{label:"고정 10분 유지"}]}]}}
    → tail.openQuestion == .choices(id: "toolu_01", questions: [ChoiceQuestion(text: "만료 방식을 어떻게 할까요?", header: "만료 방식", multiSelect: false, options: [...])])
@Test func answeredAskQuestionIsNotOpen()   // 뒤에 user tool_result{tool_use_id:"toolu_01"} → openQuestion == nil
@Test func newPromptClosesOpenToolUses()    // 결과 없이 사용자 입력(문자열)이 오면 openQuestion == nil, openToolUse == nil
@Test func openBashToolSummarizesCommand()  // tool_use Bash {command:"swift test"} 결과 없음 → openToolUse == OpenToolUse(id:"toolu_02", name:"Bash", summary:"swift test")
@Test func lastAssistantIdFollowsLastText() // assistant uuid "a-1" 텍스트, 이어서 uuid "a-2" 텍스트 → lastAssistantId == "a-2"
@Test func optionWithPreviewIsMarked()      // options[0].preview 있음 → hasPreview, question.hasPreview
@Test func recordedChoiceAnswerIsRead()
    // tool_result 레코드의 toolUseResult.answers {"만료 방식을 어떻게 할까요?":"고정 10분 유지"} → .choices(["만료 방식을 어떻게 할까요?": "고정 10분 유지"])
@Test func recordedTextAnswerIsFirstPromptAfterAssistant()
    // assistant uuid "a-2" 뒤 user 문자열 "응, 진행해 줘" → recordedAnswer(to: "a-2") == .text("응, 진행해 줘"); 다른 id → nil
@Test func metaAndToolResultsAreNotTextAnswers() // isMeta·<task-notification>·tool_result 는 건너뜀

// ClaudeStatusDeriverTests
@Test func questionReasonUsesOpenQuestion()     // prompt(for: .question, tail: openQuestion 있음) == openQuestion
@Test func bodyQuestionUsesLastAssistantText()  // .bodyQuestion → .text(id: lastAssistantId, message: lastAssistantText); id 없으면 nil
@Test func permissionUsesOpenToolUse()          // .permission → .permission(id:, tool:, summary:)
@Test func otherReasonsHaveNoPrompt()           // .worker, nil → nil

// ClaudeCodeProviderTests
@Test func waitingSessionCarriesPrompt()        // 세션 파일 waiting/input needed + transcript 열린 질문 → session.prompt?.id == "toolu_01"
@Test func providerReadsRecordedAnswer()        // recordedAnswer(sessionId:, promptId:) 가 transcript 에서 읽음

// SessionStoreTests
@Test func recordedAnswerIsRoutedByProviderId() // providerId 다른 provider 에는 묻지 않음
```

- [ ] **Step 2: 실패 확인** — `swift test 2>&1 | grep -E "error:|✘" | head` → 없는 타입으로 컴파일 실패
- [ ] **Step 3: 구현** — `Scan`에 열린 `tool_use`를 id 순서대로 기억하고 `tool_result`의 `tool_use_id`로 지움. 사용자 입력(`isPrompt`)이 오면 모두 지움. `openQuestion`은 열린 것 중 마지막 `AskUserQuestion`, `openToolUse`는 열린 것 중 마지막. 요약은 `command` → `file_path` → `path` → `url` 순서로 첫 문자열, 없으면 빈 문자열. 질문 입력 파싱은 필드별로 관대하게(모르는 필드 무시, `questions`가 없거나 비면 nil). `recordedAnswer`는 별도의 작은 스캔
- [ ] **Step 4: 통과 확인** — `swift test 2>&1 | grep -E "Test run with|✘"` → 전부 통과
- [ ] **Step 5: 커밋** — `git commit -m "feat: read pending questions and recorded answers from transcripts"`

---

### Task 3: 화면 판독과 다음 입력 결정

**Files:**
- Create: `Sources/AgentFloatCore/Reply/ClaudeScreen.swift`, `Sources/AgentFloatCore/Reply/ReplyDriver.swift`, `Sources/AgentFloatCore/Reply/TerminalConsole.swift` (이 Task에서는 값 타입만: `ConsoleKey`, `ConsoleInput`, `ConsoleScreen`)
- Test: `Tests/AgentFloatCoreTests/ClaudeScreenTests.swift`, `Tests/AgentFloatCoreTests/ReplyDriverTests.swift` (새)

**Interfaces:**
- Consumes: Task 1 fixture와 표, Task 2 `PendingPrompt`·`ChoiceQuestion`·`RecordedAnswer`
- Produces:
  - `enum ConsoleKey: String, CaseIterable, Sendable { case enter, up, down, left, right, tab, space }`
  - `enum ConsoleInput: Equatable, Sendable { case text(String); case key(ConsoleKey) }`
  - `struct ConsoleScreen: Equatable, Sendable { let lines: [String]; let composerDraft: String? }` — `composerDraft`는 Orca 자체 입력창 글(다른 콘솔은 nil)
  - `struct ChoiceRow: Equatable, Sendable { let label: String; let isFocused: Bool; let isChecked: Bool; let kind: Kind; enum Kind { case option, other, chat, submit } }`
  - `struct ChoiceDialog: Equatable, Sendable { let questionText: String; let rows: [ChoiceRow]; let otherDraft: String; var focusedIndex: Int? }` — `questionText`는 감긴 줄을 공백 하나로 이은 값
  - `enum ScreenState: Equatable, Sendable { case choiceDialog(ChoiceDialog); case review(focusedOnSubmit: Bool); case prompt(draft: String); case busy; case unrecognized }`
  - `ClaudeScreen.interpret(_ screen: ConsoleScreen) -> ScreenState`
  - `ClaudeScreen.matches(_ dialog: ChoiceDialog, question: ChoiceQuestion) -> Bool` — 질문 문장 앞 24자(공백 정규화)와 선택지 `displayLabel`이 아니라 **원래 `label`** 순서가 화면과 같을 때만
  - `enum ChoiceAnswer: Equatable, Sendable { case option(Int); case options(Set<Int>); case other(String) }` (선택지 0부터)
  - `enum ReplyDraft: Equatable, Sendable { case choices([ChoiceAnswer]); case text(String) }`
  - `struct ReplyProgress: Equatable, Sendable { var question = 0; var typedText = false; var pressedSubmit = false }`
  - `enum ReplyMove: Equatable, Sendable { case send(ConsoleInput); case finished; case stuck(String) }`
  - `ReplyDriver.startCheck(prompt: PendingPrompt, screen: ScreenState) -> StartCheck` — `enum StartCheck: Equatable { case ready, terminalDraft, unexpected }` (G2)
  - `ReplyDriver.nextMove(prompt: PendingPrompt, draft: ReplyDraft, progress: inout ReplyProgress, screen: ScreenState) -> ReplyMove` (G3 한 걸음)
  - `ReplyDriver.expectedRecord(prompt: PendingPrompt, draft: ReplyDraft) -> RecordedAnswer` (G4)

- [ ] **Step 1: 실패하는 테스트**

```swift
// ClaudeScreenTests — fixture 를 읽어 ConsoleScreen(lines:composerDraft:nil) 로
@Test func singleChoiceDialogIsRead()        // choice-single-focus0 → .choiceDialog, rows 의 option 3개 + other + chat, focusedIndex == 0, otherDraft == ""
@Test func focusMovesAreRead()               // choice-single-focus1 → focusedIndex == 1
@Test func otherDraftIsRead()                // choice-other-typed → otherDraft == "잠시 대기"
@Test func checkedRowsAreRead()              // choice-multiselect-checked → 체크된 줄 isChecked
@Test func reviewScreenIsRead()              // choice-review → .review(focusedOnSubmit: 표 ⑥의 값)
@Test func emptyPromptIsEmptyDraft()         // prompt-empty → .prompt(draft: "") (표 ⑨ 의 안내 문구가 있으면 그것도 "")
@Test func promptDraftIsRead()               // prompt-draft → .prompt(draft: "쓰다 만 글")
@Test func busyScreenIsBusy()                // prompt-busy → .busy
@Test func unknownTextIsUnrecognized()       // ["hello"] → .unrecognized
@Test func wrappedQuestionIsRecognized()     // choice-wrapped: matches(dialog, question: 원래 질문) == true  (Review Focus 5)
@Test func differentLabelsDoNotMatch()       // 선택지 하나만 다른 질문 → matches == false

// ReplyDriverTests — 화면 상태는 fixture 판독 결과를 쓰고, 키 종류는 표 ②~⑥ 대로
@Test func startRequiresFirstQuestionAndEmptyFields()
    // choice-single-focus0 → .ready, choice-other-typed → .terminalDraft, prompt-draft(본문 질문) → .terminalDraft, choice-two-questions-q2 → .unexpected
@Test func movesFocusThenSelects()           // .option(2), 포커스 0 → .send(.key(.down)), 포커스 2 → .send(.key(.enter))
@Test func movesUpWhenTargetIsAbove()        // .option(0), 포커스 2 → .send(.key(.up))
@Test func otherAnswerTypesOnceThenConfirms()
    // .other("잠시 대기"), 포커스 other·빈 칸 → .send(.text("잠시 대기")), progress.typedText = true; 칸 == "잠시 대기" → .send(.key(.enter))
@Test func otherFieldWithForeignTextIsStuck() // 칸 == "다른 글" → .stuck
@Test func multiSelectTogglesOnlyDifference() // .options([0,2]), 0 체크됨·2 안 됨 → 2로 이동 후 표 ⑤ 의 토글 키, 그 뒤 표 ⑤ 의 넘어가기
@Test func secondQuestionFollowsFirst()      // 질문 2개: q1 화면에서 답 → q2 화면이 오면 progress.question == 1
@Test func reviewSubmits()                   // .review(focusedOnSubmit: true) → .send(.key(.enter)), pressedSubmit
@Test func promptReplyTypesThenSubmits()     // .text: prompt "" → .text, prompt == 글 → .enter, 그 뒤 .busy 또는 prompt "" → .finished
@Test func dialogGoneMeansFinished()         // 질문 창 답 뒤 .busy → .finished
@Test func unrecognizedScreenIsStuck()       // → .stuck
@Test func tenthOptionIsReachable()          // 선택지 10개, .option(9), 포커스 0 → 아래 9번 뒤 enter
@Test func expectedRecordForChoices()        // .choices([.option(1)]) → .choices([질문: 원래 라벨]); .other("x") → .choices([질문: "x"]); .options 는 표 ⑦ 의 형식
@Test func expectedRecordForText()           // .text("응") → .text("응")
@Test func noMoveEverSendsBareEscape()       // 모든 테스트에서 나온 ConsoleInput 에 "\u{1b}" 단독·C0 제어 문자가 없음
```

- [ ] **Step 2: 실패 확인** — 컴파일 실패
- [ ] **Step 3: 구현** — `interpret`는 표 ①·④·⑤·⑥·⑨의 모양 규칙만 씀(포커스 기호·번호 형식·체크 기호·확인 화면 문구·프롬프트 테두리). 프롬프트 줄은 표 ⑨의 안내 문구와 **정확히 같을 때만** 빈 것으로 보고, 그 밖에 공백 아닌 글자가 하나라도 있으면 draft(설계 4.4 "애매하면 비어 있지 않은 것"). `nextMove`는 한 번에 키 하나만 정하고, 질문 번호는 화면의 질문 문장을 `prompt`의 질문들과 `matches`로 대조해 정한다(순서를 가정하지 않음). 진행할 수 없는 모든 경우는 `.stuck(이유)`
- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 커밋** — `git commit -m "feat: interpret question screens and plan the next key"`

---

### Task 4: 콘솔 — tmux · Orca

**Files:**
- Modify: `Sources/AgentFloatCore/Reply/TerminalConsole.swift`, `Sources/AgentFloatCore/Navigation/Orca.swift` (화면 JSON 파싱)
- Create: `Sources/AgentFloatCore/Reply/TmuxConsole.swift`, `Sources/AgentFloatCore/Reply/OrcaConsole.swift`
- Test: `Tests/AgentFloatCoreTests/TerminalConsoleTests.swift` (새)

**Interfaces:**
- Consumes: Task 3의 값 타입, v1 `CommandRunning`·`TmuxCLI`·`OrcaCLI`
- Produces:
  - `enum ReadOnlyReason: Equatable, Sendable { case unsupportedTerminal(String); case hiddenTab; case accessibilityNeeded; case ambiguousTab; case splitTab; case previewQuestion; case permissionPrompt }`
  - `enum ConsoleAvailability: Equatable, Sendable { case ready; case readOnly(ReadOnlyReason) }`
  - `protocol TerminalConsole: Sendable { func handles(_ session: AgentSession) -> Bool; func availability(of session: AgentSession) async -> ConsoleAvailability; func readScreen(of session: AgentSession) async throws -> ConsoleScreen; func send(_ input: ConsoleInput, to session: AgentSession) async throws }`
  - `struct ConsoleRegistry: Sendable { init(_ consoles: [any TerminalConsole]); func console(for session: AgentSession) -> (any TerminalConsole)?; func availability(of session: AgentSession) async -> ConsoleAvailability }` — 질문 쪽 이유가 먼저(답장 화면은 `prompt`가 있는 세션만 열리므로 nil은 오지 않음): `.permission` → `.permissionPrompt`, 질문 중 `hasPreview` → `.previewQuestion`, 담당 콘솔 없음 → `.unsupportedTerminal(앱 이름)`(`TerminalApp`의 표시 이름: `other("Apple_Terminal")` → "Terminal", `other("iTerm.app")` → "iTerm2", 그 밖 `other(x)` → x, `unknown` → "이"), 그다음 콘솔의 판정
  - `TmuxConsole(runner:executable:)`, `OrcaConsole(runner:)`
  - `OrcaCLI.parseScreen(_ json: Data) throws -> ConsoleScreen` — 표 ⑫의 JSON 모양

- [ ] **Step 1: 실패하는 테스트**

```swift
@Test func tmuxSendsLiteralText()       // .text("잠시 대기") → [exe, "-S", sock, "send-keys", "-t", "%7", "-l", "--", "잠시 대기"]
@Test func tmuxSendsNamedKeys()         // enter/up/down/left/right/tab/space → "Enter","Up","Down","Left","Right","Tab","Space"
@Test func tmuxReadsPane()              // readScreen → [exe, "-S", sock, "capture-pane", "-p", "-t", "%7"] 출력 줄 → lines
@Test func tmuxRejectsUnsafeLocator()   // 소켓에 공백·pane "7" → availability .readOnly(.unsupportedTerminal("tmux")), send 는 terminalNotFound, 명령 0회
@Test func orcaSendsTextAndEnter()      // .text → ["terminal","send","--terminal",h,"--text",t]; .enter → 표 ⑫ 의 인자
@Test func orcaSendsArrowsAsSequences() // .up → 표 ⑫ 의 형태 (예: "--text", "\u{1b}[A")
@Test func orcaReadsScreenAndDraft()    // orca-read-screen.json → lines, composerDraft
@Test func orcaWithoutHandleIsReadOnly()// .orca(handle: nil) → .readOnly(.unsupportedTerminal("Orca"))
@Test func registryPrefersPromptReasons()// permission 세션 → .permissionPrompt (콘솔 호출 0회), preview 질문 → .previewQuestion
@Test func orcaTeamTmuxSessionUsesTmux()// terminalApp .orca, locator .tmux → TmuxConsole 이 담당
@Test func unsupportedTerminalNamesApp()// locator .appleTerminal → .unsupportedTerminal("Terminal"), .application + other("Cursor") → "Cursor"
```

- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현** — tmux는 v1 `TmuxCLI.isSafeSocketPath`·`isPaneId` 검사 뒤에만 실행. 보낼 글은 Task 7 `ReplyText` 검사를 통과한 것만 들어온다는 전제지만, 콘솔도 C0 제어 문자가 있으면 `NavigationError.commandFailed("unsafe text")`로 거절(두 겹 방어)
- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 실측** — Task 1의 tmux 시험 세션을 다시 띄워 `swift test`가 아닌 임시 실행(커밋 안 함)으로 `TmuxConsole.readScreen`·`send(.key(.down))`가 표와 같게 동작하는지 확인. Orca도 S2 터미널에서 같은 확인
- [ ] **Step 6: 커밋** — `git commit -m "feat: type into and read tmux and Orca terminals"`

---

### Task 5: 전달기 — G1~G4

**Files:**
- Create: `Sources/AgentFloatCore/Reply/ReplyDelivery.swift`
- Test: `Tests/AgentFloatCoreTests/ReplyDeliveryTests.swift` (새, 가짜 콘솔·가짜 기록)

**Interfaces:**
- Consumes: Task 2 `AnswerRecordReading`, Task 3 `ReplyDriver`·`ClaudeScreen`, Task 4 `ConsoleRegistry`
- Produces:
  - `enum DeliveryStage: Int, CaseIterable, Sendable { case sameQuestion, screen, typing, record }` — 시안 6의 네 줄 순서
  - `enum NotSentReason: Equatable, Sendable { case alreadyAnswered, questionChanged, sessionEnded, terminalDraft, unexpectedScreen, unreadableScreen; case readOnly(ReadOnlyReason) }`
  - `enum DeliveryOutcome: Equatable, Sendable { case delivered(RecordedAnswer); case notSent(NotSentReason); case stopped(stage: String); case mismatched(sent: RecordedAnswer, recorded: RecordedAnswer?) }` — `recorded == nil`은 시간 초과
  - `struct DeliveryTiming: Sendable { var stepTimeout: Duration = .milliseconds(1500); var pollInterval: Duration = .milliseconds(100); var recordTimeout: Duration = .seconds(5); var maxMoves = 60; static let standard = DeliveryTiming() }`
  - `struct ReplyDelivery: Sendable { init(currentSessions: @escaping @Sendable () async -> [AgentSession], consoles: ConsoleRegistry, answers: @escaping @Sendable (SessionKey, String) -> RecordedAnswer?, timing: DeliveryTiming = .standard); func deliver(_ draft: ReplyDraft, prompt: PendingPrompt, session: AgentSession, onStage: @escaping @Sendable (DeliveryStage) -> Void) async -> DeliveryOutcome }`

- [ ] **Step 1: 실패하는 테스트** — `ScriptedConsole`(화면을 차례로 돌려주고 보낸 입력을 기록)

```swift
@Test func deliversSingleChoice()            // 화면: focus0 → focus1 → busy, 기록 맞음 → .delivered, 보낸 입력 [.down, .enter], onStage 순서 [sameQuestion, screen, typing, record]
@Test func answeredMeanwhileSendsNothing()   // currentSessions 의 그 세션이 .running → .notSent(.alreadyAnswered), sent.isEmpty  (Review Focus 2)
@Test func changedQuestionSendsNothing()     // prompt.id 다름 → .notSent(.questionChanged), sent.isEmpty
@Test func endedSessionSendsNothing()        // 목록에 없음 → .notSent(.sessionEnded)
@Test func terminalDraftSendsNothing()       // 첫 화면 choice-other-typed → .notSent(.terminalDraft), sent.isEmpty
@Test func orcaComposerDraftSendsNothing()   // composerDraft "x" → .notSent(.terminalDraft)
@Test func unreadableScreenSendsNothing()    // readScreen throws → .notSent(.unreadableScreen)
@Test func readOnlySendsNothing()            // availability .readOnly(.hiddenTab) → .notSent(.readOnly(.hiddenTab))
@Test func typingInTerminalMidwayStops()     // down 뒤 화면이 choice-other-typed(사용자 입력) → .stopped, 그 뒤 추가 입력 없음 (Review Focus 1)
@Test func unchangedScreenAfterKeyStops()    // 키 뒤 stepTimeout 동안 화면 그대로 → .stopped
@Test func wrongRecordIsMismatch()           // 기록 "고정 10분 유지" ≠ 보낸 라벨 → .mismatched(sent:, recorded:)
@Test func missingRecordTimesOut()           // recordTimeout 동안 nil → .mismatched(sent:, recorded: nil)
@Test func moveLimitStops()                  // 화면이 매번 바뀌지만 끝나지 않음 → maxMoves 에서 .stopped
@Test func neverRetriesAfterStop()           // .stopped 뒤 deliver 가 반환될 때까지 send 호출 수 고정
```
타이밍은 테스트에서 `DeliveryTiming(stepTimeout: .milliseconds(50), pollInterval: .milliseconds(5), recordTimeout: .milliseconds(100))`

- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현** — G1은 `currentSessions()`에서 같은 키를 찾아 `status == .waiting`, `waitReason`·`prompt?.id`가 같은지. G2는 `availability` → `readScreen` → `composerDraft`가 공백 아닌 글이면 `.terminalDraft` → `ReplyDriver.startCheck`. G3는 `nextMove` → `send` → `pollInterval`마다 다시 읽어 화면이 바뀔 때까지(최대 `stepTimeout`) → 다음 `nextMove`. `.finished`면 G4: `recordTimeout` 동안 `answers` 조회, `ReplyDriver.expectedRecord`와 같으면 delivered
- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 커밋** — `git commit -m "feat: deliver replies through four safety gates"`

---

### Task 6: Ghostty 콘솔과 실측 S3

**Files:**
- Create: `Sources/AgentFloatCore/Reply/GhosttyConsole.swift`, `Sources/AgentFloat/Reply/AXGhosttyScreenReader.swift`
- Modify: `Sources/AgentFloatCore/Navigation/Ghostty.swift` (스크립트 추가, 엄격한 짝짓기)
- Test: `Tests/AgentFloatCoreTests/GhosttyConsoleTests.swift` (새), `GhosttyTests.swift`

**Interfaces:**
- Consumes: Task 4 `TerminalConsole`, v1 `GhosttyScripts`·`GhosttyMatcher`
- Produces:
  - `GhosttyMatcher.uniqueMatch(title: String?, cwd: String, in: [GhosttyTerminal]) -> GhosttyTerminal?` — 제목이 같은 것이 하나면 그것, 둘 이상이면 그중 cwd 같은 것이 정확히 하나일 때만, 제목 짝이 없으면 v1과 같은 cwd 규칙. 그 밖은 nil (설계 4.1 "이동보다 엄격")
  - `GhosttyScripts.terminalPlacement(terminalId:) -> String` — 출력 `<window id>\t<window name>\t<tab selected true|false>\t<terminal count in tab>` 또는 `missing`
  - `GhosttyScripts.inputText(_ text: String, terminalId: String) -> String`, `GhosttyScripts.sendKey(_ name: String, terminalId: String) -> String` — 출력 `ok`/`missing`
  - `GhosttyKeyNames.name(for: ConsoleKey) -> String` — S3에서 확인한 이름
  - `protocol GhosttyScreenReading: Sendable { var isTrusted: Bool { get }; func screen(windowTitle: String) throws -> [String] }` — 같은 제목의 Ghostty 창이 둘 이상이면 `throws`
  - `GhosttyConsole(runner:screenReader:)`
  - 앱 타깃 `AXGhosttyScreenReader: GhosttyScreenReading` — `AXIsProcessTrusted()`, Ghostty pid의 `kAXWindowsAttribute`에서 `kAXTitleAttribute`가 같은 창이 정확히 하나, 그 아래 역할 `AXTextArea`가 정확히 하나일 때 `kAXValueAttribute`를 줄로 나눔. 그 밖은 throw

- [ ] **Step 1: 실패하는 테스트**

```swift
@Test func uniqueMatchRefusesTitleTwins()   // 같은 제목·같은 cwd 둘 → nil (v1 match 는 첫 번째를 줌)
@Test func uniqueMatchUsesCwdToBreakTies()  // 같은 제목, cwd 다름 → cwd 같은 것
@Test func hiddenTabIsReadOnly()            // placement 출력 "...\tfalse\t1" → .readOnly(.hiddenTab)
@Test func splitTabIsReadOnly()             // "...\ttrue\t2" → .readOnly(.splitTab)
@Test func untrustedIsAccessibilityNeeded() // isTrusted false → .readOnly(.accessibilityNeeded)
@Test func twinTitlesAreAmbiguous()         // uniqueMatch nil → .readOnly(.ambiguousTab)
@Test func readsScreenOfThatWindow()        // screen(windowTitle: placement 의 window name) 결과 → lines
@Test func inputTextEscapesQuotes()         // 글 `say "hi" \ ok` → 스크립트 안 문자열이 \" 와 \\ 로 이스케이프
@Test func sendKeyUsesMappedName()          // .enter → send key "<표의 이름>"
@Test func missingTerminalFails()           // 스크립트 출력 "missing" → NavigationError.terminalNotFound
```

- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현** — availability 순서: 목록 → `uniqueMatch` → `terminalPlacement` → `isTrusted`. `readScreen`도 매번 같은 순서로 다시 확인(그 사이 탭이 바뀌었을 수 있음)
- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: S3 실측** — `make bundle`(Task 1 서명) 후 실행, 사용자에게 손쉬운 사용 허용을 요청(시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용). 새 Ghostty 창(`env -i` 셸, haiku)에서 질문 창을 띄우고: ① 앱 자신의 권한으로 화면이 읽히는지 ② `send key` 이름(enter·up·down·left·right·tab·space) ③ 그 탭이 **가려진 상태**에서 `input text`·`send key`가 그 탭에 들어가는지 ④ `select tab`이 Ghostty를 앞으로 올리지 않고 창 안 탭만 바꾸는지 ⑤ 분할 탭에서 텍스트 영역이 몇 개인지. 결과를 rulings 표에 추가
- [ ] **Step 6: (S3 ③·④가 모두 통과했을 때만) 가려진 탭 처리** — 보내기 직전에 `select tab`으로 그 탭을 보이게 하고, 끝나면(성공·실패 모두) 원래 선택 탭으로 되돌림. 그 동안 Ghostty 맨 앞 여부가 바뀌지 않았는지 `NSWorkspace.frontmostApplication`으로 확인해 바뀌었으면 `.stopped`. availability의 `.hiddenTab`은 이 경우 `.ready`로. 테스트 `hiddenTabIsSelectedAndRestored`(스크립트 호출 순서: select → input → restore) 추가. 하나라도 실패했으면 이 Step을 건너뛰고 rulings에 "가려진 탭은 보기만" 기록
- [ ] **Step 7: 통과 확인 후 커밋** — `git commit -m "feat: type into and read Ghostty terminals"`

---

### Task 7: 답장 편집 상태·글 검사·실패 신호

**Files:**
- Create: `Sources/AgentFloatCore/Reply/ReplyEditor.swift`, `Sources/AgentFloatCore/Window/ReplyPlacement.swift`
- Modify: `Sources/AgentFloatCore/Signals/SignalTracker.swift`, `Sources/AgentFloatCore/Signals/SessionGrouping.swift`
- Test: `Tests/AgentFloatCoreTests/ReplyEditorTests.swift` (새), `SignalTrackerTests.swift`, `SessionGroupingTests.swift`

**Interfaces:**
- Consumes: Task 2·3 모델
- Produces:
  - `struct ReplyEditor: Equatable, Sendable` — `init(prompt: PendingPrompt)`; `step: Int`; `answers: [ChoiceAnswer?]`; `otherText: String`; `replyText: String`; `mutating func choose(option: Int)`(하나 고르기는 바꾸고, 여러 개는 켜고 끔. 그 질문의 직접 입력을 비움); `mutating func setOther(_:)`(비어 있지 않으면 그 질문 답을 `.other`로, 고른 것은 풀림); `mutating func setReply(_:)`; `var isReviewing: Bool`(질문 2개 이상이고 `step == questions.count`); `mutating func advance()`; `mutating func edit(question:)`; `var primary: PrimaryAction`(`enum PrimaryAction { case send, next, disabled }`); `var draft: ReplyDraft?`(보낼 수 있을 때만); `var block: TextBlock?`
  - `enum TextBlock: Equatable, Sendable { case commandLike, multiline, controlCharacter }`
  - `enum ReplyText { static func block(_ text: String, inPrompt: Bool) -> TextBlock? }` — 줄바꿈 → `.multiline`(Task 1 ⑧이 허용하면 그 맥락만 풀기), C0·DEL → `.controlCharacter`, `inPrompt`이고 앞 공백 뒤 첫 글자가 `/`·`!`·`#` → `.commandLike`(⑩ 결과로 `@` 규칙 추가 가능)
  - `enum ReplyKeyInput: Equatable { case digit(Int), returnKey, escape, other }`, `enum ReplyKeyAction: Equatable { case select(Int), primary, commitComposition, leaveField, back, passThrough }`, `ReplyKeys.action(for:fieldFocused:hasMarkedText:) -> ReplyKeyAction`
  - `enum ReplyPlacement: String, CaseIterable, Sendable { case panel, inline, card; static func resolve(override: String?, saved: String?) -> ReplyPlacement }` — 기본 `.panel`
  - `PillSummary.failed: Int`(init 마지막 `failed: Int = 0`), `attention`에 `failed > 0` 포함. `SignalTracker.summary(of:failed:)` — `failed` 키의 세션은 대기·진행·완료 개수에서 빼고 `failed`로 셈
  - `SessionGrouping.groups(_:excluding:)`, `SessionGrouping.failed(_:among:) -> [AgentSession]`(최근 변경 순)

- [ ] **Step 1: 실패하는 테스트**

```swift
@Test func singleQuestionSendsWhenChosen()       // choose(1) → primary == .send, draft == .choices([.option(1)])
@Test func nothingChosenIsDisabled()             // primary == .disabled, draft == nil
@Test func otherTextReplacesChoice()             // choose(0); setOther("잠시 대기") → answers[0] == .other("잠시 대기")
@Test func choosingClearsOtherText()             // setOther("x"); choose(2) → otherText == "", .option(2)
@Test func multiSelectToggles()                  // multiSelect 질문: choose(0), choose(2), choose(0) → .options([2])
@Test func twoQuestionsGoThroughReview()         // q1 답 → primary .next → advance → q2 답 → .next → advance → isReviewing, primary .send
@Test func editFromReviewReturnsToQuestion()     // edit(question: 0) → step 0, 답 유지
@Test func whitespaceOtherIsNotAnAnswer()        // setOther("   ") → primary .disabled
@Test func commandLikeTextIsBlocked()            // 본문 질문 setReply("/compact") → block == .commandLike, primary .disabled; "  !ls" 도; "응, 진행해 줘" → nil  (Review Focus 4)
@Test func multilineAndControlAreBlocked()       // "a\nb" → .multiline, "a\u{1b}b" → .controlCharacter
@Test func returnDuringCompositionOnlyCommits()  // action(.returnKey, fieldFocused: true, hasMarkedText: true) == .commitComposition  (Review Focus 3)
@Test func returnSends()                         // (.returnKey, true, false) → .primary, (.returnKey, false, false) → .primary
@Test func digitsSelectOnlyOutsideField()        // (.digit(2), false, false) → .select(1); (.digit(2), true, false) → .passThrough
@Test func escapeLeavesFieldThenGoesBack()       // (.escape, true, _) → .leaveField; (.escape, false, _) → .back
@Test func placementDefaultsToPanel()            // resolve(override: nil, saved: nil) == .panel; override "inline" > saved "card"
@Test func failedSessionsLeaveStatusCounts()     // waiting 2 중 1개 failed → waiting 1, failed 1, attention
@Test func failedGroupIsSeparate()               // groups(excluding:) 에 failed 키 없음, failed(_:among:) 에 있음
```

- [ ] **Step 2: 실패 확인**
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인**
- [ ] **Step 5: 커밋** — `git commit -m "feat: model the reply editor, text rules and failure signals"`

---

### Task 8: 답장 화면(C)과 패널 키 입력, 실측 S4

**Files:**
- Create: `Sources/AgentFloat/Reply/ReplyCenter.swift`, `Sources/AgentFloat/Views/Reply/ReplyLayout.swift`, `ReplyScreen.swift`, `ReplyContent.swift`, `OptionRow.swift`, `ReplyField.swift`, `ReplyStrip.swift`, `DeliverySteps.swift`, `ReplyFooter.swift`, `MessageTail.swift`
- Modify: `Sources/AgentFloat/FloatingPanel.swift`, `Sources/AgentFloat/PanelController.swift`, `Sources/AgentFloat/Views/FloatRootView.swift`, `Sources/AgentFloat/Views/ExpandedPanelView.swift`, `Sources/AgentFloat/Views/SessionRow.swift`, `Sources/AgentFloat/Views/Palette.swift`, `Sources/AgentFloat/AppDelegate.swift`, `Sources/AgentFloat/FakeProvider.swift`
- Create: `Sources/AgentFloat/Reply/FakeConsole.swift`

**Interfaces:**
- Consumes: Task 5 `ReplyDelivery`, Task 7 `ReplyEditor`·`ReplyKeys`·`ReplyText`
- Produces:
  - `ReplyCenter` (`@MainActor @Observable`): `openKey: SessionKey?`; `editors: [String: ReplyEditor]`(질문 id별, 앱 끄면 사라짐); `availability: [SessionKey: ConsoleAvailability]`; `phase: ReplyPhase`(`enum ReplyPhase { case editing; case sending(DeliveryStage); case result(DeliveryOutcome) }` — 키가 들어갔는지는 결과가 `.notSent`가 아닌지로 앎); `failures: [SessionKey: DeliveryOutcome]`; `func open(_ session:)`; `func close()`; `func send()`; `func acknowledgeFailure(_ key:)`; `func sync(with sessions: [AgentSession])`
  - `FloatingPanel.acceptsKeyInput: Bool` — `canBecomeKey`가 이 값을 돌려줌(기본 false)
  - `enum ReplyLayout` — 설계 4.8 값: `width = 320`, `innerRadius = 12`, `buttonHeight = 28`, `buttonRadius = 14`, `keycapSize = 18`, `keycapRadius = 5`, `chipHeight = 18`, `chipRadius = 9`, `backSize = 24`, `titleLeading = 34`, `contentInset = 10`, `navToContent = 12`, `chipToQuestion = 8`, `questionToOptions = 12`, `optionGap = 6`, `optionsToField = 6`, `contentToFooter = 12`, `bottomPadding = 10`, `fieldMaxLines = 5`, `slideOffset = 12`, `autoReturn = 1.2`
  - `enum ReplyCopy` — 설계 4.6 문구 표의 제목·설명 그대로(키: `delivered`, `alreadyAnswered`, `questionChanged`, `terminalDraft`, `unexpectedScreen`, `unreadableScreen`, `sessionEnded`, `stopped`, `mismatched`, `mismatchTimeout`, `readOnlyHidden`, `readOnlyUnsupported(app:)`, `readOnlyAccessibility`, `readOnlyAmbiguous`, `permission`) + Task 7의 `commandLike` 문구 "명령으로 읽힐 수 있어 여기서 보낼 수 없어요"와 미리보기 "미리보기가 있는 질문은 터미널에서 답해 주세요", 분할 탭 "Ghostty 탭이 나뉘어 있어 어느 화면인지 확실하지 않아요"

- [ ] **Step 1: 패널 키 입력** — `FloatingPanel.canBecomeKey`를 `acceptsKeyInput`으로. `PanelController`: 답장 화면을 열 때 지금 맨 앞 앱을 기억 → `acceptsKeyInput = true` → `panel.makeKey()`. 닫을 때(보냄 성공 뒤 목록·‹·esc) `panel.resignKey()` → `acceptsKeyInput = false` → 기억한 앱이 맨 앞이 아니면 `NSRunningApplication.activate()`. 목록·알약·hover·끌기 경로는 손대지 않음
- [ ] **Step 2: S4 실측** — 디버그 실행(`AGENT_FLOAT_DEBUG=1`, 가짜 세션)에서 다른 앱에 입력하던 중 답장 화면을 열고: ① 영문·한글(2벌식) 입력과 조합 표시 ② 조합 중 ⏎가 조합만 확정 ③ esc·‹ 뒤 원래 앱으로 다시 타이핑되는지 ④ Agent Float가 `frontmostApplication`이 되었는지 로그. 합성 입력(`cliclick`)으로 확인 가능한 것은 직접, 한글 조합은 사용자 확인 체크리스트로 넘김. ③이 안 되면 설계 6장 S4 대체안(그 동안만 활성화)을 적용하고 rulings에 기록
- [ ] **Step 3: 화면 구성** — 시안 1·2·3·4·5·10과 설계 4.8 표대로: 내비 줄(‹ 24×24, 제목 13 Semibold, 시간 11 tertiary), 2행(34에서 시작), 칩(10.5 Semibold, 주황 20% 채움), 질문(13 / 줄 18.5), 선택지(번호 키 18×18 반경 5 → 고르면 파랑 원 체크 / 여러 개 고르기는 체크 상자 모양, 라벨 13 Medium, 추천 배지 9.5 Bold 파랑 18%, 설명 11.5 / 15.5 secondary, 고른 줄 파랑 20% + 1pt 테두리, 반경 12), 입력 칸(`ReplyField` = `NSTextView` 래퍼: 오목 채움 + 0.5pt 선, 포커스 시 파랑 3pt 바깥 링, 5줄까지 늘고 스크롤, `hasMarkedText()`를 `ReplyKeys`에 넘김, 줄바꿈 입력 막음), 버튼 줄("터미널에서 열기" 12 Medium secondary · 주요 버튼 높이 28 반경 14 + `⏎` 11 72%). 직접 입력을 시작하면 선택지 설명을 접음(시안 2). 본문 질문은 "마지막 답변" + 끝부분(마지막 12줄 또는 600자, 위쪽 34pt 흐림, "전체 보기") + 입력 칸에 바로 커서(시안 5). 여러 개 질문은 "1 / 2" + 막대 14×3, 확인 화면 "이렇게 보낼게요"(시안 3·4). 보기만은 회색 띠 + 번호·입력 칸 없이 70% + "터미널에서 열기"만(시안 10). 손쉬운 사용 권한이 없을 때는 버튼 줄 왼쪽에 "설정 열기"(`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`). Tab 순서는 선택지 → 입력 칸 → 버튼. 선택지 VoiceOver 문구 "<n>번, <라벨>, 추천, 선택됨"(해당하는 말만)
- [ ] **Step 4: 패널 연결** — `PanelController`: 답장 화면이면 폭 `ReplyLayout.width`, 높이는 `ReplyMeasure`로 미리 잰 값(상한 화면 70%, 넘치면 내용만 스크롤, 버튼 줄 고정). 열 때 유리는 v1 spring으로 폭·높이 morph, 내용은 옆에서 12pt 밀려 들어옴(‹는 반대), 동작 줄이기면 교차 페이드. 답장 화면이 열린 동안 hover 이탈로 접지 않음. `NSWindow.didResignKeyNotification` 뒤 마우스가 밖이면 평소 지연으로 접고, 다음 펼침은 목록. 목록에서 `prompt`가 있는 대기 줄 클릭 = `ReplyCenter.open`(질문을 못 읽은 대기 줄과 다른 상태의 줄은 v1처럼 이동, 설계 4.2), ⌘+클릭 = v1 `activate`. 쓰다 만 답이 있으면 `SessionRow` 2행 사유 자리에 파랑 "작성 중"
- [ ] **Step 5: 가짜 콘솔과 디버그 열기** — `AGENT_FLOAT_FAKE_SESSIONS`일 때 `FakeProvider`의 대기 세션 4개에 가상 질문(시안과 같은 내용: 하나 고르기 3선택지·추천 1, 본문 질문, 질문 2개, 승인 대기)을 붙임. `FakeConsole`: `AGENT_FLOAT_FAKE_REPLY`(`ready`·`hidden`·`delivered`·`draft`·`stopped`·`mismatch`)로 가능 여부·결과를 정하고 `AGENT_FLOAT_FAKE_REPLY_STAGE_DELAY`(초)만큼 각 단계에 머묾. `AGENT_FLOAT_OPEN_REPLY=<n>`이면 `debugExpand`(SIGUSR1)가 n번째 대기 세션의 답장 화면까지 엶
- [ ] **Step 6: 시안 대조** — 다크·라이트(`AGENT_FLOAT_APPEARANCE`)로 시안 1·2·3·4·5·10·12를 `screencapture`해 `reply-flow-c.html`과 나란히 비교: 폭 320, 간격 12/8/12/6/6/12/10, 반경, 글자 크기·굵기, 색 사용 범위. 어긋나면 고치고 다시 캡처
- [ ] **Step 7: 확인·커밋** — `swift test` 통과, `make bundle` 경고 0, `scripts/privacy-check.sh` 0건 → `git commit -m "feat: show the reply screen in the panel"`

---

### Task 9: 보내기 연결·상태 화면·실패 표시

**Files:**
- Modify: `Sources/AgentFloat/Reply/ReplyCenter.swift`, `Sources/AgentFloat/Views/Reply/*`, `Sources/AgentFloat/Views/SummaryRow.swift`, `Sources/AgentFloat/Views/ExpandedPanelView.swift`, `Sources/AgentFloat/Views/SessionRow.swift`, `Sources/AgentFloat/Views/Palette.swift`, `Sources/AgentFloat/AppModel.swift`, `Sources/AgentFloat/AppDelegate.swift`

**Interfaces:**
- Consumes: Task 5·6·7·8
- Produces: `AppModel.failures`(→ `SignalTracker.summary(of:failed:)`, `SessionGrouping`), `Palette.failed`(`systemRed`)·`Palette.failText(on:)`(라이트 진한 빨강 #D70015, 다크 `systemRed`, 칠한 톤 고정은 `askText(on:)`과 같은 방식)

- [ ] **Step 1: 보내기** — `ReplyCenter.send()`: `ReplyEditor.draft`가 있고 `phase == .editing`일 때만(보내는 중 두 번째 ⏎·클릭은 버림), `ReplyDelivery.deliver`를 Task로 돌리고 `onStage`로 `phase = .sending(stage)`. 보내는 동안 내용 45% + 잠금, ‹·이동 막힘(시안 6, 네 줄: "같은 질문을 기다리는지 확인" · "터미널 화면 확인" · "입력하는 중" · "기록된 답 확인"). `AppDelegate`에서 `ConsoleRegistry([TmuxConsole, OrcaConsole, GhosttyConsole(screenReader: AXGhosttyScreenReader())])`, `currentSessions`는 `SnapshotWorker`의 새 snapshot, `answers`는 `SessionStore.recordedAnswer`. Ghostty 세션의 답장 화면을 처음 열 때 권한이 없으면 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`를 앱 실행당 한 번만 부름(설계 4.9)
- [ ] **Step 2: 결과 화면** — `delivered`: 초록 띠 "보냈어요" + `"<답>"이 그대로 기록된 것까지 확인했어요`, 1.2초 뒤 목록 + 포커스 반환(시안 7). `notSent`: 주황 띠(사유별 문구), 쓴 답 유지, "다시 확인"(availability 다시 판정) · "터미널에서 열기"(시안 8). `stopped`·`mismatched`: 빨간 띠, 저절로 닫지 않음, "닫기" · "터미널에서 열기", 기록이 다르면 "보낸 답 / 기록된 답" 두 줄(시안 9). `alreadyAnswered`·`sessionEnded`는 1.2초 뒤 목록. 저절로 닫는 규칙은 `phase`가 `.editing`이거나 `.result(.notSent)`일 때만 적용 — 키가 들어간 뒤(`stopped`·`mismatched`)에는 세션이 대기를 벗어나도 실패 화면이 남음(설계 4.7)
- [ ] **Step 3: 열린 동안의 변화** — `AppModel.apply` 뒤 `ReplyCenter.sync(with:)`: 편집 중 세션이 대기를 벗어남 → "터미널에서 이미 답했어요" + 1.2초 뒤 목록, 쓴 답 버림. 세션 사라짐 → "세션이 끝났어요". `prompt.id` 바뀜 → 주황 띠 "질문이 바뀌었어요" + 새 질문 + 선택 초기화. availability가 바뀌면 띠·버튼만 바꾸고 쓴 답 유지. 보내는 중이면 아무것도 바꾸지 않음
- [ ] **Step 4: 실패 표시** — `stopped`·`mismatched`면 `failures[key]` 기록. 알약: 맨 앞 빨간 점 + 개수 + 빨간 `FAIL` 꼬리(`ASK`와 같은 크기·간격), 테두리 빛은 `attention`. 목록: 맨 위 "확인 필요 N"(머리 빨강) 묶음, 그 줄은 실제 상태 색 점 + 2행 사유 자리에 빨간 "보내기 실패", 누르면 실패 화면. 실패 화면의 "닫기"·"터미널에서 열기" 또는 그 줄 ⌘+클릭 이동이 `acknowledgeFailure`. 세션이 목록에서 빠지면 같이 지움
- [ ] **Step 5: 실측 (tmux)** — Task 1 방식의 tmux 시험 세션 두 개(질문 창 하나, 본문 질문 하나)로 실제 앱에서: 선택지 보내기, 직접 쓰기 보내기, 본문 질문 보내기 → 모두 "보냈어요" 후 세션이 진행으로 바뀜. 일부러 시험 터미널에 글을 써 둔 뒤 보내기 → "쓰던 글" 띠, 키 0개(시험 pane 캡처로 확인). 보내는 중 시험 터미널에 글자를 끼워 넣기 → "보내다 멈췄어요" + `FAIL`. 결과를 rulings에
- [ ] **Step 6: 실측 (Orca·Ghostty)** — S2 터미널과 S3 Ghostty 창에서 선택지 하나·직접 쓰기 하나씩. Ghostty 가려진 탭은 Task 6 결과대로(보기만 또는 탭 전환 뒤 복원)
- [ ] **Step 7: 확인·커밋** — 가짜 결과(`AGENT_FLOAT_FAKE_REPLY`)로 시안 6·7·8·9와 실패 알약·"확인 필요" 묶음을 다크·라이트 캡처해 대조. `swift test`, `make bundle` 경고 0, `scripts/privacy-check.sh` 0건 → `git commit -m "feat: send replies from the panel and surface failed deliveries"`

---

### Task 10: A 배치(줄 안에서 펼침)와 배치 설정

**Files:**
- Create: `Sources/AgentFloat/Views/Reply/InlineReplyRow.swift`
- Modify: `Sources/AgentFloat/Views/ExpandedPanelView.swift`, `Sources/AgentFloat/PanelController.swift`, `Sources/AgentFloat/MenuBarController.swift`, `Sources/AgentFloat/AppDelegate.swift`

**Interfaces:**
- Consumes: Task 7 `ReplyPlacement`, Task 8 `ReplyContent`
- Produces: `PanelController.replyPlacement`·`setReplyPlacement(_:)`(UserDefaults 키 `replyPlacement`, 환경 변수 `AGENT_FLOAT_REPLY_PLACEMENT`가 앞섬), 메뉴 "답장 화면" ▸ "패널 전환" / "줄 안에서 펼침" / "옆에 카드"(지금 값에 체크)

- [ ] **Step 1: 메뉴** — `MenuBarController`에 가장자리 대비와 같은 방식의 하위 메뉴. 고르면 열린 답장 화면은 닫고(쓴 답 유지) 다음 열기부터 적용
- [ ] **Step 2: A 배치** — 설계 4.8 A 행 그대로: 머리 줄은 접힌 줄과 픽셀 단위로 같은 자리(위 7·좌우 10), 답장 내용은 제목 첫 글자 26에서 시작·오른쪽 10, 머리 → 칩 10 · 칩 → 질문 6 · 질문 → 선택지 10 · 선택지 사이 6 · 입력 칸 앞 6 · 버튼 줄 앞 12 · 아래 10, 질문 12.5 / 줄 18, 열린 줄 배경 주황 11%, 한 번에 한 줄만 열림(다른 줄을 열면 앞 줄은 접히고 쓴 답 유지), 나머지 줄 55%. 열린 동안 패널 폭 320
- [ ] **Step 3: 간격 확인** — `AGENT_FLOAT_REPLY_PLACEMENT=inline` + 가짜 세션으로 열고 접은 상태와 펼친 상태를 같은 자리에서 캡처해, 머리 줄의 제목·점·시간이 1px도 움직이지 않는지(두 캡처 차이 비교), 내용 왼쪽이 제목 첫 글자와 같은 x인지 확인. 시안 11과 대조
- [ ] **Step 4: 확인·커밋** — `git commit -m "feat: add inline reply placement and the placement menu"`

---

### Task 11: B 배치(옆에 답장 카드)

**Files:**
- Create: `Sources/AgentFloat/Reply/ReplyCardController.swift`, `Sources/AgentFloat/Views/Reply/ReplyCard.swift`
- Modify: `Sources/AgentFloat/PanelController.swift`, `Sources/AgentFloatCore/Window/PanelGeometry.swift`
- Test: `Tests/AgentFloatCoreTests/PanelGeometryTests.swift`

**Interfaces:**
- Produces: `PanelGeometry.cardFrame(panel: CGRect, rowTop: CGFloat, size: CGSize, trailing: Bool, visible: CGRect, gap: CGFloat = 8) -> CGRect` — 패널이 붙은 가장자리의 반대쪽, 위쪽은 고른 줄 위치, 화면 안으로 밀어 넣음

- [ ] **Step 1: 실패하는 테스트**

```swift
@Test func cardOpensAwayFromAnchoredEdge()  // trailing 패널 → card.maxX == panel.minX - 8
@Test func cardOpensRightOfLeadingPanel()   // leading 패널 → card.minX == panel.maxX + 8
@Test func cardAlignsToRowTop()             // card.maxY == rowTop
@Test func cardIsPushedOnScreen()           // 화면 아래로 넘치면 card.minY == visible.minY
```

- [ ] **Step 2: 실패 확인 → Step 3: 구현** — 두 번째 `FloatingPanel`(같은 레벨·Space 동작)에 폭 320 유리 카드. 고른 줄은 진한 주황 26% + 주황 1pt 테두리. 나타날 때 0.96→1 크기 + 페이드 0.22초(동작 줄이기면 페이드만). 패널과 카드 사이 틈을 지나는 동안 접지 않음(두 창 프레임과 그 사이 8pt를 합친 영역으로 hover 판정). 키 입력은 카드가 받음(Task 8의 규칙 그대로)
- [ ] **Step 4: 통과 확인·시안 대조** — `reply-placement.html` B와 캡처 대조
- [ ] **Step 5: 커밋** — `git commit -m "feat: add side card reply placement"`

---

### Task 12: 마무리 — 문서·체크리스트·최종 검사

**Files:**
- Modify: `docs/specs/2026-10-16-agent-float-design.md` (2장 비목표 첫 줄, 4.7 줄 클릭, 4.8 키 입력 예외, 7장 로드맵 행 → v1.2 설계로 옮김), `docs/specs/2026-10-23-agent-float-v1.2-reply-design.md` (5장 검증 표 갱신, 상태 줄), `docs/plans/2026-10-16-agent-float-rulings.md` (v1.2 섹션 마무리), `docs/checklists/2026-10-16-agent-float-v1-user-check.md` (`### v1.2 답장` 항목), `README.md` (답하기 절)

- [ ] **Step 1: 사용자 확인 체크리스트** — 41. 한글 조합 중 ⏎가 보내지 않음 42. 손쉬운 사용 승인 창과 거절 시 "설정 열기" 43. 실제 마우스로 답장 화면 열기·접힘 느낌 44. A·B 배치 느낌 45. 실패 알약·"확인 필요" 해제 흐름. 각 항목에 기대·실패 모습
- [ ] **Step 2: 문서 갱신** — 실측 결과로 설계 5장 ❓·"사전 확인" 행을 ✅/❌ + 근거. README에 지원 터미널 표(보내기 / 보기만)
- [ ] **Step 3: 최종 검사** — `scripts/privacy-check.sh` 0건, `swift test` 통과, `make bundle` 경고 0, 서명 Authority 확인
- [ ] **Step 4: 커밋** — `git commit -m "docs: record v1.2 reply results and user checks"`
- [ ] **Step 5: 전체 브랜치 리뷰** — 가장 성능 좋은 모델의 새 리뷰어 1회(v1.1과 같은 방식). 지적은 rulings "최종 리뷰"에 기록하고 고친 뒤 다시 Step 3
