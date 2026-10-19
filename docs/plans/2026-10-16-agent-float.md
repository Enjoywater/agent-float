# Agent Float Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ghostty·Orca에서 도는 AI 에이전트(v1: Claude Code) 세션의 상태(대기/진행/완료)를 Liquid Glass 플로팅 알약으로 보여주고, 클릭하면 그 터미널 탭으로 이동하는 macOS 앱을 만든다.

**Architecture:** 순수 로직 라이브러리 `AgentFloatCore`(모델·Claude provider·transcript 판독·신호 규칙·터미널 매칭)와 얇은 AppKit/SwiftUI 실행 타깃 `AgentFloat`(NSPanel·뷰·감시·연결)로 나눈다. Core는 전부 단위 테스트하고, 앱 타깃은 실제 세션을 띄워 수동 검증한다. 상태 수집은 `AgentProvider`, 이동은 `TerminalNavigator` 프로토콜 뒤에 둬서 다른 에이전트·터미널을 등록만으로 붙인다.

**Tech Stack:** Swift 6.3 (언어 모드 6), SwiftPM + Makefile 번들 조립, SwiftUI(`glassEffect`, `GlassEffectContainer`), AppKit(`NSPanel`, `NSStatusItem`), Swift Testing, Darwin(`proc_pidinfo`, `sysctl KERN_PROCARGS2`), `/usr/bin/osascript`, `/usr/local/bin/orca`.

**Spec:** `docs/specs/2026-10-16-agent-float-design.md` (시안: 같은 폴더 `2026-10-16-agent-float-mockups/`)

## Global Constraints

- 플랫폼: `.macOS(.v26)`, `swift-tools-version: 6.0`, Swift 언어 모드 6 (strict concurrency)
- 서드파티 의존성 0개
- 이름: 앱·번들·모듈·공통 타입에 `claude` 금지. Claude 고유 구현만 `ClaudeCode*`/`Claude*` 접두 (spec 4.0)
- 번들 ID `dev.enjoywater.agent-float`, 표시 이름 `Agent Float`, `LSUIElement = true`, `LSMinimumSystemVersion = 26.0`
- 세션 쪽 설치물 0개. hook은 Task 11 실측에서 필요가 확인될 때만 (spec 4.2 hook 폴백 조건)
- `claude agents --json`을 주기 실행하지 않음 (spec 4.9)
- UI 문구는 한국어, spec에 적힌 문구 그대로
- 색은 시스템 색. 테두리 빛은 `Color.primary`(다크 흰빛 / 라이트 먹색) (spec 4.6, 4.10)
- 주석은 why만. 자명한 주석·주석 처리된 코드 금지 (사용자 전역 규칙, PreToolUse hook이 검사함)
- 커밋은 각 Task 마지막 단계에서 `git add -A && git commit -m "<메시지>"`, 메시지 끝에 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

1. **세션 파일을 Claude가 쓰는 도중에 읽음**(잘린 JSON) → 그 세션이 사라지거나 회색으로 깜빡이면 안 됨. 직전 정상 값 유지 — Task 6 테스트 `partialWriteKeepsLastGoodState`
2. **세션이 많음**(15개 이상) → 펼친 패널이 화면 밖으로 넘치면 안 됨. 높이 상한 + 스크롤 — Task 10 수동 검증 단계(가짜 세션 15개)
3. **저장된 위치가 화면 밖**(외부 모니터 분리 후) → 보이는 화면 안으로 복귀 — Task 9 테스트 `offscreenOriginFallsBackToTopRight`
4. **Ghostty 탭 제목 중복·부재**(같은 제목 둘, ai-title 생기기 전 새 세션) → 결정적으로 하나를 고르거나 nil — Task 8 테스트 `duplicateTitlesTieBreakByCwd`, `missingTitleMatchesUniqueClaudeTabInCwd`
5. **클릭한 세션이 이미 사라짐 / 탭을 못 찾음** → 크래시 없이 경고음, NEW 유지 — Task 8 테스트 `navigateThrowsWhenNoTerminalMatches`, Task 11 수동 단계

---

## File Structure

```
agent-float/
├── Package.swift
├── Makefile
├── .gitignore
├── Resources/Info.plist
├── Sources/
│   ├── AgentFloatCore/
│   │   ├── Model/AgentSession.swift          # SessionKey, AgentStatus, WaitReason, TerminalApp, TerminalLocator, AgentSession
│   │   ├── Model/Labels.swift                # 경과시간·폴더·대기 사유·무활동 문구
│   │   ├── Provider/AgentProvider.swift      # AgentProvider 프로토콜
│   │   ├── Provider/SessionStore.swift       # provider 합치기, 실패 격리
│   │   ├── Claude/TranscriptReader.swift     # transcript 끝부분 판독 → TranscriptTail
│   │   ├── Claude/QuestionHeuristic.swift    # 평문 질문 판정
│   │   ├── Claude/ClaudeSessionFile.swift    # ~/.claude/sessions/<pid>.json 파싱
│   │   ├── Claude/ClaudeStatusDeriver.swift  # 파일+transcript → 표시 상태
│   │   ├── Claude/ClaudeCodeProvider.swift   # 위를 조립한 provider
│   │   ├── System/ProcessInspector.swift     # 생존·시작시각·환경변수
│   │   ├── Signals/SignalTracker.swift       # NEW 추적, PillSummary
│   │   ├── Signals/SessionGrouping.swift     # 묶음 순서·정렬
│   │   ├── Navigation/CommandRunner.swift    # 외부 명령 실행 프로토콜 + Process 구현
│   │   ├── Navigation/Ghostty.swift          # 스크립트·목록 파싱·매칭·GhosttyNavigator
│   │   ├── Navigation/Orca.swift             # JSON 파싱·매칭·OrcaNavigator
│   │   ├── Navigation/AppActivationNavigator.swift  # 기타 터미널 폴백: 부모 프로세스의 앱을 앞으로
│   │   ├── Navigation/NavigatorRegistry.swift
│   │   └── Window/PanelGeometry.swift        # 위치 복원·펼침 프레임 계산 (CGRect만 사용)
│   └── AgentFloat/
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── FloatingPanel.swift
│       ├── PanelController.swift             # 패널 프레임·hover·펼침 전환
│       ├── MenuBarController.swift
│       ├── AppModel.swift                    # @Observable 상태, 갱신 루프, 이동·확인 처리
│       ├── DirectoryWatcher.swift
│       ├── FakeProvider.swift                # AGENT_FLOAT_FAKE_SESSIONS 시각 검증용
│       └── Views/{FloatRootView,SummaryRow,ExpandedPanelView,SessionRow,BorderSweep,Palette,AppIcons}.swift
└── Tests/AgentFloatCoreTests/
    ├── Fixtures/                              # 세션 JSON·transcript JSONL 표본
    └── *Tests.swift
```

---

### Task 1: 패키지 골격 + 공통 모델 + 문구

**Files:**
- Create: `Package.swift`, `Makefile`, `Sources/AgentFloatCore/Model/AgentSession.swift`, `Sources/AgentFloatCore/Model/Labels.swift`
- Test: `Tests/AgentFloatCoreTests/LabelsTests.swift`

**Interfaces:**
- Produces:
```swift
public struct SessionKey: Hashable, Sendable { public let providerId: String; public let sessionId: String }
public enum AgentStatus: String, Sendable, CaseIterable { case waiting, running, done, unknown } // 선언 순서 = 묶음 순서
public enum WaitReason: Equatable, Sendable { case question, bodyQuestion, permission, worker, sandbox, dialog, other(String) }
public enum TerminalApp: Equatable, Sendable { case ghostty, orca, other(String), unknown }
public enum TerminalLocator: Equatable, Sendable { case ghostty(title: String?, cwd: String), orca(tabId: String, leafId: String), background(jobId: String), application(pid: Int32), none }
// application(pid:) = 정확한 탭은 모르고 세션 프로세스만 앎 → 부모를 따라 터미널 앱을 앞으로 올리는 폴백 대상
public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: SessionKey { key }
    public let key: SessionKey; public let agentName: String; public let title: String; public let cwd: String
    public let status: AgentStatus; public let waitReason: WaitReason?; public let statusSince: Date
    public let isStale: Bool; public let lastActivityAt: Date?
    public let terminalApp: TerminalApp; public let locator: TerminalLocator
}
public enum Labels {
    public static func elapsed(_ interval: TimeInterval) -> String
    public static func folder(cwd: String, home: String) -> String
    public static func waitReason(_ reason: WaitReason) -> String
    public static func inactivity(since: Date, now: Date) -> String
}
```

- [ ] **Step 1: 저장소와 패키지 만들기**
  - 저장소(`git init`, 로컬 작성자 `me@example.com`)와 `.gitignore`는 이미 있음. 원격 `Enjoywater/agent-float`(Private) — 회사 쪽 원격·이메일을 절대 쓰지 말 것
  - `Package.swift`: 라이브러리 `AgentFloatCore`, 실행 `AgentFloat`(Core 의존, Task 9에서 소스 추가 — 지금은 `main.swift`에 빈 `import AgentFloatCore`만), 테스트 `AgentFloatCoreTests`(Core 의존, `resources: [.copy("Fixtures")]`). `platforms: [.macOS(.v26)]`
  - `Makefile`: `build`(`swift build -c release`), `test`(`swift test`), `clean`. `bundle`·`run`은 Task 9

- [ ] **Step 2: 실패하는 테스트 작성** — `LabelsTests.swift` (Swift Testing)

```swift
@Test func elapsedShortForms() {
    #expect(Labels.elapsed(-5) == "<1m"); #expect(Labels.elapsed(59) == "<1m")
    #expect(Labels.elapsed(60) == "1m");  #expect(Labels.elapsed(3_599) == "59m")
    #expect(Labels.elapsed(3_600) == "1h"); #expect(Labels.elapsed(86_399) == "23h")
    #expect(Labels.elapsed(86_400) == "1d")
}
@Test func folderLabel() {
    #expect(Labels.folder(cwd: "/Users/me", home: "/Users/me") == "~")
    #expect(Labels.folder(cwd: "", home: "/Users/me") == "~")
    #expect(Labels.folder(cwd: "/Users/me/orca/workspaces/sample-app/", home: "/Users/me") == "sample-app")
}
@Test func waitReasonCopy() {
    #expect(Labels.waitReason(.question) == "질문 답변 대기")
    #expect(Labels.waitReason(.bodyQuestion) == "질문(본문)")
    #expect(Labels.waitReason(.permission) == "승인 대기")
    #expect(Labels.waitReason(.worker) == "워커 요청 대기")
    #expect(Labels.waitReason(.sandbox) == "샌드박스 승인 대기")
    #expect(Labels.waitReason(.dialog) == "창 열림")
    #expect(Labels.waitReason(.other("custom thing")) == "custom thing")
}
@Test func inactivityCopy() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(Labels.inactivity(since: now.addingTimeInterval(-14 * 60 - 5), now: now) == "14분째 활동 없음")
}
```

- [ ] **Step 3: 실패 확인** — `swift test --filter LabelsTests` → 컴파일 실패(`Labels` 없음)
- [ ] **Step 4: 모델과 `Labels` 구현** — 분 단위는 버림(`Int(interval / 60)`)
- [ ] **Step 5: 통과 확인** — `swift test --filter LabelsTests` → PASS
- [ ] **Step 6: 커밋** — `chore: scaffold package with core session model and labels`

---

### Task 2: transcript 끝부분 판독 (`TranscriptReader`)

spec 4.2·4.3의 제목·평문 질문·자동 재개 판정에 필요한 원재료를 한 번의 끝부분 읽기로 뽑는다.

**Files:**
- Create: `Sources/AgentFloatCore/Claude/TranscriptReader.swift`
- Create: `Tests/AgentFloatCoreTests/Fixtures/transcript-*.jsonl` (아래 레코드 형식으로 손수 구성)
- Test: `Tests/AgentFloatCoreTests/TranscriptReaderTests.swift`

**Interfaces:**
- Produces:
```swift
public struct TranscriptTail: Equatable, Sendable {
    public var aiTitle: String?
    public var lastAssistantText: String?
    public var userPromptAfterLastAssistant: Bool
    public var pendingBackgroundTaskIds: Set<String>
    public var pendingWake: Bool
    public var modifiedAt: Date
}
public enum TranscriptReader {
    public static let tailBytes = 262_144
    public static let titleScanLimit = 8_388_608
    public static func read(url: URL) throws -> TranscriptTail
    static func parse(lines: [Substring], modifiedAt: Date) -> TranscriptTail   // @testable
}
```

실측한 레코드 형식 (2.1.301, 이 세션 transcript):
- 제목: `{"type":"ai-title","aiTitle":"…","sessionId":"…"}` (자주 반복 기록됨)
- assistant: `{"type":"assistant","message":{"content":[{"type":"text","text":"…"},{"type":"tool_use","name":"ScheduleWakeup","input":{…}}]}}`
- 사용자 입력: `{"type":"user","message":{"content":"…문자열…"}}` (`isMeta: true`면 사용자 입력 아님). 도구 결과는 `content`가 `[{"type":"tool_result",…}]`
- 백그라운드 시작(도구 결과 텍스트): `Command running in background with ID: bpt6oenrd.` / `Async agent launched successfully. … agentId: acf1dcf882625c809 (…`
- 완료 알림: `user` 문자열 content, `queue-operation`의 `content`, `attachment.prompt` 중 어디든 `<task-notification>\n<task-id>ID</task-id>…<status>completed|failed|killed|stopped</status>`

판정 규칙:
- 끝부분 청크의 첫 줄은 잘렸을 수 있으므로 파일 처음부터 읽은 경우가 아니면 버림. JSON이 아닌 줄은 무시
- `aiTitle`: 마지막 `ai-title`. 끝부분에 없으면 파일 앞에서부터 `titleScanLimit`까지만 훑어 마지막 값
- `lastAssistantText`: `text` 블록이 있는 마지막 assistant 레코드의 마지막 `text`
- 사용자 입력 레코드 = `type=="user"`, `isMeta != true`, content가 문자열이면서 `<task-notification>`·`<local-command`로 시작하지 않음, 또는 배열인데 `tool_result`가 하나도 없음 (`/effort` 같은 로컬 명령은 Claude가 응답하는 턴이 아니라 제외. 스킬 슬래시 명령의 `<command-name>`은 입력으로 셈)
- `userPromptAfterLastAssistant`: 위 assistant 레코드 뒤에 사용자 입력 레코드가 있음
- `pendingBackgroundTaskIds`: 시작 ID 집합 − 완료 알림 ID 집합
- `pendingWake`: 마지막 사용자 입력 레코드 이후에 `ScheduleWakeup` tool_use(`input.stop != true`)가 있음, 또는 `CronCreate` 뒤에 `CronDelete`가 없음 (형식 실측은 Task 11)

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
@Test func titleIsLastAITitle()            // 두 ai-title 중 마지막 → "새 제목"
@Test func titleFoundBeyondTailWindow()    // 앞쪽에만 ai-title, 뒤를 300KB 잡음으로 채운 임시 파일 → read(url:)가 제목 찾음
@Test func titleScanIsBounded()            // 잡음 8.5MB → ai-title → 잡음 300KB인 임시 파일: 앞쪽 훑기 한도와 끝부분 창 모두 밖 → nil
@Test func lastAssistantTextAndNoPromptAfter() // assistant 텍스트 "알려줘." 뒤에 system 레코드만 → userPromptAfterLastAssistant == false
@Test func metaAndToolResultAreNotPrompts()    // assistant 뒤 isMeta user + tool_result user + "<local-command-caveat>…" user → false
@Test func realPromptAfterAssistant()          // assistant 뒤 user 문자열 "A안 채택" → true
@Test func backgroundBashPendingUntilNotified() // 시작 "…with ID: bpt6oenrd." → pending == ["bpt6oenrd"]; queue-operation 완료 알림 추가 → []
@Test func asyncAgentPendingUntilNotified()     // "agentId: acf1dcf882625c809" → pending; user 문자열 <task-notification> completed → []
@Test func scheduleWakeupAfterLastPromptIsPending() // user 입력 → assistant ScheduleWakeup → true; 그 뒤 user 입력 → false; stop:true → false
@Test func truncatedFirstLineIsIgnored()        // 청크 시작이 JSON 중간 → 크래시 없이 나머지 판독
```

- [ ] **Step 2: 실패 확인** — `swift test --filter TranscriptReaderTests` → 컴파일 실패
- [ ] **Step 3: `TranscriptReader` 구현** — `FileHandle`로 끝에서 `tailBytes` 읽고 `JSONSerialization`으로 줄 단위 파싱(필드가 들쭉날쭉해 `Codable`보다 관대함), 정규식은 Swift `Regex`
- [ ] **Step 4: 통과 확인** — `swift test --filter TranscriptReaderTests` → PASS
- [ ] **Step 5: 커밋** — `feat(core): read transcript tail for title, last reply, pending work`

---

### Task 3: 평문 질문 판정 (`QuestionHeuristic`)

**Files:**
- Create: `Sources/AgentFloatCore/Claude/QuestionHeuristic.swift`
- Test: `Tests/AgentFloatCoreTests/QuestionHeuristicTests.swift`

**Interfaces:**
- Produces: `public enum QuestionHeuristic { public static func endsWithQuestion(_ markdown: String) -> Bool }`

규칙 (사용자가 오탐을 감수함 — 놓침보다 오탐이 낫다):
1. 빈 줄로 문단을 나눔. 끝에서부터 "출처 문단"을 건너뜀: 첫 줄이 `Sources:`·`출처:`·`참고:`(콜론 선택)이거나, 모든 줄이 `](http`를 포함한 목록 항목인 문단
2. 남은 마지막 문단에서 `**`, `` ` ``를 지우고 `.`, `!`, `?`, `？`, `。`, 줄바꿈 기준으로 문장을 나눔
3. 그 문단의 문장 중 하나라도 `?`/`？`로 끝나거나, 끝 문장부호를 뗀 뒤 다음 중 하나로 끝나면 질문:
   `까`, `까요`, `나요`, `있나`, `없나`, `되나`, `는지`, `인지`, `을지`, `할지`, `될지`, `궁금함`, `궁금해`, `궁금합니다`, `알려줘`, `알려 줘`, `알려주세요`, `알려줄래`, `말해줘`, `골라줘`, `정해줘`, `선택해줘`, `확인해줘`, `어때`, `어떤가`, `할래`, `줄래`

- [ ] **Step 1: 실패하는 테스트 작성** — 이 대화에서 실제로 보낸 문장 사용

```swift
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
```

- [ ] **Step 2: 실패 확인** — `swift test --filter QuestionHeuristicTests` → 컴파일 실패
- [ ] **Step 3: 규칙대로 구현**
- [ ] **Step 4: 통과 확인** — PASS
- [ ] **Step 5: 실물 대조** — `~/.claude/projects/-Users-me/<sessionId>.jsonl`에서 사용자 입력 직전 assistant 마지막 텍스트를 모두 뽑아(임시 스크립트, 커밋 안 함) 판정 결과를 훑고, 명백한 놓침이 있으면 그 문장을 `detectsQuestions`에 추가한 뒤 규칙 보강
- [ ] **Step 6: 커밋** — `feat(core): detect replies that end by asking the user`

---

### Task 4: 세션 파일 파싱 + 상태 도출

**Files:**
- Create: `Sources/AgentFloatCore/Claude/ClaudeSessionFile.swift`, `Sources/AgentFloatCore/Claude/ClaudeStatusDeriver.swift`
- Create: `Tests/AgentFloatCoreTests/Fixtures/session-{busy,idle,waiting,bg,unknown-status}.json` (실제 파일 형식, 아래 필드)
- Test: `Tests/AgentFloatCoreTests/ClaudeStatusDeriverTests.swift`

**Interfaces:**
- Consumes: `TranscriptTail` (Task 2), `QuestionHeuristic` (Task 3)
- Produces:
```swift
struct ClaudeSessionFile: Decodable, Equatable, Sendable {
    let pid: Int32; let sessionId: String
    let cwd: String?; let kind: String?; let status: String?; let waitingFor: String?
    let name: String?; let statusUpdatedAt: Double?; let procStart: String?; let jobId: String?
    static func parse(_ data: Data) -> ClaudeSessionFile?   // pid·sessionId 없거나 JSON 아니면 nil, 모르는 필드 무시
}
struct DerivedStatus: Equatable, Sendable { let status: AgentStatus; let waitReason: WaitReason?; let isStale: Bool }
enum ClaudeStatusDeriver {
    static let staleAfter: TimeInterval = 600
    static func derive(file: ClaudeSessionFile, tail: TranscriptTail?, now: Date) -> DerivedStatus
    static func waitReason(from waitingFor: String?) -> WaitReason
}
```

도출 순서 (spec 4.2 — 대기를 놓치는 쪽이 최악이라 질문 판정을 자동 재개보다 먼저):
| `status` | 조건 | 결과 |
|---|---|---|
| `waiting` | — | `.waiting`, `waitReason(from: waitingFor)` |
| `busy` | `tail.modifiedAt`이 `staleAfter`보다 오래됨 | `.running`, stale |
| `busy` | 그 외 | `.running` |
| `idle` | `lastAssistantText`가 질문 && 이후 사용자 입력 없음 | `.waiting`, `.bodyQuestion` |
| `idle` | `pendingBackgroundTaskIds` 비어있지 않음 또는 `pendingWake` | `.running` (stale 아님) |
| `idle` | 그 외(또는 tail 없음) | `.done` |
| 그 외·nil | — | `.unknown` |

`waitReason(from:)`: `"input needed"`→`.question`, 소문자에 `permission` 포함→`.permission`, `"worker request"`→`.worker`, `"sandbox request"`→`.sandbox`, `"dialog open"`→`.dialog`, nil·빈값→`.other("대기")`, 나머지→`.other(원문)`

- [ ] **Step 1: 실패하는 테스트 작성** — 위 표의 각 행을 하나씩(`@Test(arguments:)`), 그리고:

```swift
@Test func parsesRealBusyFile()      // fixture: {"pid":4242,"sessionId":"00000000-…-0000000000a1","cwd":"/Users/me","kind":"interactive","status":"busy","statusUpdatedAt":1792124258017,"procStart":"Fri Oct 16 04:12:10 2026","peerFeatures":["notify_idle"],…}
@Test func parsesBackgroundFile()    // kind "bg", jobId "fe50860d"
@Test func rejectsGarbage()          // "{\"pid\": 12" 와 "[]" → nil
@Test func unknownStatusIsGrayNotRunning() // status "thinking" → .unknown
@Test func questionBeatsPendingWork()      // idle + 질문 텍스트 + pending ID → .waiting/.bodyQuestion
```

- [ ] **Step 2: 실패 확인** — `swift test --filter ClaudeStatusDeriverTests` → 컴파일 실패
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — PASS
- [ ] **Step 5: 커밋** — `feat(core): parse Claude session files and derive display status`

---

### Task 5: 프로세스 생존·환경변수 (`ProcessInspector`)

`ps`를 띄우지 않고 커널 API로 읽는다 (상시 앱이라 프로세스 생성 비용을 피함).

**Files:**
- Create: `Sources/AgentFloatCore/System/ProcessInspector.swift`
- Test: `Tests/AgentFloatCoreTests/ProcessInspectorTests.swift`

**Interfaces:**
- Produces:
```swift
public protocol ProcessInspecting: Sendable {
    func isAlive(pid: Int32, procStart: String?) -> Bool
    func environment(pid: Int32) -> [String: String]
    func parentPid(of pid: Int32) -> Int32?      // pbi_ppid. 1(launchd) 이하·실패 → nil
}
public struct DarwinProcessInspector: ProcessInspecting { public init() }
enum ProcArgs { static func parseEnvironment(_ buffer: [UInt8]) -> [String: String] }
enum ProcStart { static func parse(_ text: String) -> Date? }
```
- `isAlive`: `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` 성공 + `procStart`가 파싱되면 `pbi_start_tvsec`와 차이 ≤ 1초 (pid 재사용 방지)
- `environment`: `sysctl([CTL_KERN, KERN_PROCARGS2, pid])` 버퍼를 `ProcArgs.parseEnvironment`로. 실패 시 `[:]`
- `ProcStart.parse`: UTC, `en_US_POSIX`, 연속 공백을 하나로 줄인 뒤 `EEE MMM d HH:mm:ss yyyy`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
@Test func parsesProcArgs2Layout() {
    // argc(Int32 LE)=2, exec path "/bin/claude\0\0\0", argv "claude\0--resume\0", env "TERM_PROGRAM=ghostty\0ORCA_PANE_KEY=t1:l1\0\0"
    #expect(ProcArgs.parseEnvironment(buffer) == ["TERM_PROGRAM": "ghostty", "ORCA_PANE_KEY": "t1:l1"])
}
@Test func parsesProcStart() {
    #expect(ProcStart.parse("Fri Oct 16 04:12:10 2026") == Date(timeIntervalSince1970: 1_792_123_930))
    #expect(ProcStart.parse("Thu Oct  1 09:05:03 2026") == Date(timeIntervalSince1970: 1_790_845_503))
    #expect(ProcStart.parse("nonsense") == nil)
}
@Test func liveSelfInspection() {
    let i = DarwinProcessInspector()
    #expect(i.isAlive(pid: getpid(), procStart: nil))
    #expect(i.environment(pid: getpid())["PATH"] != nil)
    #expect(!i.isAlive(pid: 999_999, procStart: nil))
    #expect(!i.isAlive(pid: getpid(), procStart: "Thu Jan  1 00:00:00 2015"))
    #expect(i.parentPid(of: getpid()) == getppid())
    #expect(i.parentPid(of: 1) == nil)
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter ProcessInspectorTests` → 컴파일 실패
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — PASS
- [ ] **Step 5: 커밋** — `feat(core): inspect process liveness and environment via kernel APIs`

---

### Task 6: `ClaudeCodeProvider` + `SessionStore`

**Files:**
- Create: `Sources/AgentFloatCore/Provider/AgentProvider.swift`, `Sources/AgentFloatCore/Provider/SessionStore.swift`, `Sources/AgentFloatCore/Claude/ClaudeCodeProvider.swift`
- Test: `Tests/AgentFloatCoreTests/ClaudeCodeProviderTests.swift`, `Tests/AgentFloatCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: Task 1~5 전부
- Produces:
```swift
public protocol AgentProvider: Sendable {
    var id: String { get }
    var watchedDirectories: [URL] { get }
    func snapshot(now: Date) throws -> [AgentSession]
}
public final class ClaudeCodeProvider: AgentProvider, @unchecked Sendable {   // 캐시는 Synchronization.Mutex로 보호
    public init(claudeHome: URL, homeDirectory: String, inspector: any ProcessInspecting)
    public static func live() -> ClaudeCodeProvider   // ~/.claude, NSHomeDirectory(), DarwinProcessInspector()
}
public final class SessionStore: @unchecked Sendable {
    public init(providers: [any AgentProvider])
    public var watchedDirectories: [URL] { get }
    public func snapshot(now: Date) -> [AgentSession]
}
```
- `id = "claude-code"`, `agentName = "Claude"`, `watchedDirectories = [claudeHome/sessions]`
- 세션마다: 파일 파싱 → `isAlive` 아니면 제외 → transcript 위치 `claudeHome/projects/*/<sessionId>.jsonl` (sessionId별 캐시, 여러 폴더에서 찾히면 mtime이 가장 최근인 것) → `TranscriptReader.read`(파일 mtime·크기가 같으면 캐시 재사용) → `ClaudeStatusDeriver` → 환경변수(pid+procStart별 캐시)로 앱·위치 결정
- 위치 결정: `kind=="bg"` && `jobId` → `.background(jobId)`, 앱 `.unknown` / `TERM_PROGRAM=="ghostty"` → `.ghostty(title: aiTitle, cwd:)` / `TERM_PROGRAM=="Orca"` && `ORCA_PANE_KEY`가 `tab:leaf` → `.orca(tabId:leafId:)` / 그 외 → 앱 `.other(TERM_PROGRAM)` 또는 `.unknown`, 위치 `.application(pid: file.pid)` (폴백: 앱만 앞으로)
- 제목: `aiTitle ?? name ?? "이름 없는 세션"`. `statusSince`: `statusUpdatedAt`(ms) ?? now. `lastActivityAt`: `tail.modifiedAt`
- 파싱 실패한 파일은 같은 경로의 직전 정상 값을 쓰되, 그 pid가 살아 있을 때만 (Review Focus 1)
- `SessionStore`: provider별로 호출, 던지면 그 provider의 직전 결과 유지. 결과는 이어붙이기만 (정렬은 Task 7)

- [ ] **Step 1: 실패하는 테스트 작성** — 임시 디렉터리에 `sessions/`·`projects/<encoded>/` 구성, 가짜 `ProcessInspecting`(pid별 생존·env 지정)

```swift
@Test func ghosttySessionGetsTitleAndLocator()   // env TERM_PROGRAM=ghostty, transcript ai-title "플로팅 위젯" → title, .ghostty(title:"플로팅 위젯", cwd:)
@Test func orcaSessionParsesPaneKey()            // ORCA_PANE_KEY "11111111-…:22222222-…" → .orca(tabId:"11111111-…", leafId:"22222222-…")
@Test func backgroundSessionUsesJobId()          // kind bg, jobId fe50860d → .background(jobId:"fe50860d")
@Test func otherTerminalFallsBackToApplication() // TERM_PROGRAM "Apple_Terminal" → 앱 .other("Apple_Terminal"), 위치 .application(pid:)
@Test func deadPidIsDropped()
@Test func missingTranscriptFallsBackToName()    // name "sample-df" → title, idle → .done
@Test func transcriptLookupPrefersNewestWhenDuplicated() // 같은 sessionId.jsonl이 두 project 폴더에 → 최근 mtime 쪽 ai-title 사용
@Test func partialWriteKeepsLastGoodState()      // 정상 → snapshot → "{\"pid\": 12"로 덮음 → snapshot에 같은 세션·같은 상태 유지
@Test func storeIsolatesFailingProvider()        // SessionStoreTests: 던지는 가짜 provider + 정상 provider → 정상 쪽 세션 유지, 실패 쪽은 직전 결과
```

- [ ] **Step 2: 실패 확인** — `swift test --filter "ClaudeCodeProviderTests|SessionStoreTests"` → 컴파일 실패
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — PASS
- [ ] **Step 5: 실물 확인** — 임시 테스트(또는 `swift run` 디버그 출력)로 `ClaudeCodeProvider.live().snapshot(now: .now)`를 찍어 지금 떠 있는 세션 수·제목·앱이 실제와 맞는지 확인 (커밋하지 않는 확인용)
- [ ] **Step 6: 커밋** — `feat(core): Claude Code provider and multi-provider session store`

---

### Task 7: 신호 추적 + 묶음

**Files:**
- Create: `Sources/AgentFloatCore/Signals/SignalTracker.swift`, `Sources/AgentFloatCore/Signals/SessionGrouping.swift`
- Test: `Tests/AgentFloatCoreTests/SignalTrackerTests.swift`, `Tests/AgentFloatCoreTests/SessionGroupingTests.swift`

**Interfaces:**
- Produces:
```swift
public struct PillSummary: Equatable, Sendable {
    public let waiting: Int, running: Int, done: Int, unknown: Int
    public let ask: Bool, new: Bool
    public var attention: Bool { ask || new }
    public var isEmpty: Bool { waiting + running + done + unknown == 0 }
}
public struct SignalTracker: Sendable {
    public private(set) var unseen: Set<SessionKey>
    public init()
    public mutating func ingest(_ sessions: [AgentSession])
    public mutating func markSeen(_ key: SessionKey)
    public func summary(of sessions: [AgentSession]) -> PillSummary
}
public struct SessionGroup: Equatable, Sendable { public let status: AgentStatus; public let sessions: [AgentSession] }
public enum SessionGrouping { public static func groups(_ sessions: [AgentSession]) -> [SessionGroup] }
```
- `ingest`: 첫 호출은 상태만 기억(NEW 없음, spec 4.6 [판단]). 이후 직전 `.running`/`.waiting` → `.done`이면 추가, `.running`/`.waiting`이 되면 제거, 목록에서 사라지면 제거
- `summary`: `ask = waiting > 0`, `new = unseen ∩ (done 세션 키) ≠ ∅`
- `groups`: `AgentStatus` 선언 순서(대기·진행·완료·알 수 없음), 빈 묶음 생략. 대기는 `statusSince` 오래된 순, 나머지는 최근 순, 동률은 `title`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
@Test func firstIngestMarksNothingNew()
@Test func runningToDoneBecomesNew()
@Test func waitingToDoneBecomesNew()
@Test func doneToRunningClearsNew()          // spec 4.6 해제 조건 3
@Test func markSeenClearsOnlyThatSession()   // 미확인 2개 중 1개 → new 여전히 true, 둘 다 → false
@Test func vanishedSessionIsForgotten()
@Test func askIsTrueWhileAnyWaiting()
@Test func groupsOrderAndSorting()           // 대기 2(오래된 것 먼저), 진행 1, 완료 2(최근 먼저), unknown 1 → 4묶음 순서
```

- [ ] **Step 2: 실패 확인** → 컴파일 실패
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — PASS
- [ ] **Step 5: 커밋** — `feat(core): track unseen completions and group sessions by status`

---

### Task 8: 터미널 이동 코어 (Ghostty·Orca)

**Files:**
- Create: `Sources/AgentFloatCore/Navigation/CommandRunner.swift`, `Navigation/Ghostty.swift`, `Navigation/Orca.swift`, `Navigation/AppActivationNavigator.swift`, `Navigation/NavigatorRegistry.swift`
- Test: `Tests/AgentFloatCoreTests/GhosttyTests.swift`, `OrcaTests.swift`, `NavigatorTests.swift`

**Interfaces:**
- Produces:
```swift
public protocol CommandRunning: Sendable { func run(_ executable: String, _ arguments: [String]) async throws -> String }
public struct ProcessCommandRunner: CommandRunning { public init() }        // 0이 아닌 종료 코드 → NavigationError.commandFailed(stderr)
public enum NavigationError: Error, Equatable { case terminalNotFound, commandFailed(String) }
public protocol TerminalNavigator: Sendable {
    func canNavigate(_ session: AgentSession) -> Bool
    func navigate(to session: AgentSession) async throws
}
public struct GhosttyTerminal: Equatable, Sendable { public let id: String, title: String, cwd: String }
public enum GhosttyScripts {
    public static let listTerminals: String          // 줄마다 "id\ttitle\tcwd"
    public static let focusedTerminalId: String
    public static func focus(terminalId: String) -> String
    public static func newTab(initialInput: String) -> String
}
public enum GhosttyMatcher {
    public static func strippedTitle(_ raw: String) -> String
    public static func parseList(_ output: String) -> [GhosttyTerminal]
    public static func match(title: String?, cwd: String, in terminals: [GhosttyTerminal]) -> GhosttyTerminal?
}
public struct GhosttyNavigator: TerminalNavigator { public init(runner: any CommandRunning) }   // .ghostty, .background 담당
public struct OrcaTerminal: Equatable, Sendable { public let handle: String, tabId: String, leafId: String }
public enum OrcaCLI {
    public static let executable = "/usr/local/bin/orca"
    public static func parseTerminalList(_ json: Data) throws -> [OrcaTerminal]   // {"result":{"terminals":[{handle,tabId,leafId,…}]}}
    public static func match(tabId: String, leafId: String, in terminals: [OrcaTerminal]) -> OrcaTerminal?
}
public struct OrcaNavigator: TerminalNavigator { public init(runner: any CommandRunning, activateOrca: @escaping @Sendable () -> Void) }
public struct AppActivationNavigator: TerminalNavigator {   // .application(pid:) 담당 — 정확한 탭이 아닌 앱 단위 폴백
    public init(inspector: any ProcessInspecting, activateFirstApp: @escaping @Sendable ([Int32]) -> Bool)
}
public struct NavigatorRegistry: Sendable {
    public init(_ navigators: [any TerminalNavigator])
    public func canNavigate(_ session: AgentSession) -> Bool
    public func navigate(to session: AgentSession) async throws   // 담당자 없으면 terminalNotFound
}
```
- AppleScript는 `/usr/bin/osascript -e <script>`로 실행(메인 스레드를 막지 않음, TCC 승인 주체는 우리 앱)
- `strippedTitle`: 앞의 `◐`·`◑`·`✳` 한 글자 + 공백 제거
- `match`: ①정리된 제목 == title인 후보가 1개면 그것 ②여러 개면 cwd가 같은 첫 번째, 없으면 후보의 첫 번째 ③후보 0개(또는 title nil)면 cwd가 같고 원래 제목이 Claude 기호로 시작하는 터미널이 정확히 1개일 때 그것 ④그 외 nil
- 문자열 삽입 시 `\`와 `"` 이스케이프
- Ghostty 스크립트 본문 (실측된 문법: `windows → tabs → terminals`, `focus`, `new tab in … with configuration`, `new surface configuration`):

```applescript
-- listTerminals
tell application "Ghostty"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in terminals of t
        set out to out & (id of s) & tab & (name of s) & tab & (working directory of s) & linefeed
      end repeat
    end repeat
  end repeat
  return out
end tell
-- focus(terminalId:) — 같은 3중 반복에서 id가 일치하면 `focus s` 후 `activate`, return "ok"; 끝까지 없으면 return "missing"
-- focusedTerminalId
tell application "Ghostty" to get id of focused terminal of selected tab of front window
-- newTab(initialInput:)
tell application "Ghostty"
  set cfg to new surface configuration
  set initial input of cfg to "<escaped>" & return
  if (count of windows) is 0 then
    new window with configuration cfg
  else
    new tab in front window with configuration cfg
  end if
  activate
end tell
```

- 백그라운드 세션: `newTab(initialInput: "claude attach <jobId>")`
- Orca: `orca terminal list --json` → 매칭 → `orca terminal switch --terminal <handle>` → `activateOrca()`
- 폴백: 세션 pid부터 `parentPid`를 따라 올라간 조상 목록(세션 pid 포함, 최대 32단계)을 `activateFirstApp`에 넘김. false면 `terminalNotFound`. GUI 앱 판별·활성화는 AppKit이 필요해 앱 타깃이 클로저로 주입 (Task 11)
- 등록 순서: Ghostty, Orca, 폴백 (폴백은 `.application`만 받으므로 순서와 무관하지만 의도를 드러내려고 마지막)

- [ ] **Step 1: 실패하는 테스트 작성** — 가짜 `CommandRunning`(실행 기록 + 미리 정한 출력)

```swift
@Test func stripsClaudeGlyphs()  // "◐ 플로팅 위젯"→"플로팅 위젯", "✳ Slack"→"Slack", "plain"→"plain"
@Test func parsesListOutput()    // "A\t◑ 제목\t/Users/me\nB\t~\t/tmp\n" → 2개
@Test func duplicateTitlesTieBreakByCwd()
@Test func missingTitleMatchesUniqueClaudeTabInCwd()   // title nil, 같은 cwd에 "✳ …" 1개 + 일반 셸 1개 → ✳ 쪽; ✳ 2개면 nil
@Test func escapesQuotesInScripts()                    // focus(terminalId: "a\"b") 본문에 a\"b
@Test func ghosttyNavigateRunsListThenFocus()          // 실행 기록: osascript(list) → osascript(focus id)
@Test func navigateThrowsWhenNoTerminalMatches()       // list에 일치 없음 → .terminalNotFound, focus 실행 안 됨
@Test func backgroundOpensAttachTab()                  // .background("fe50860d") → newTab 스크립트에 "claude attach fe50860d"
@Test func parsesOrcaTerminalList()                    // 실측 형식 JSON 표본 → handle/tabId/leafId
@Test func orcaNavigateSwitchesAndActivates()          // 기록: orca terminal list --json → orca terminal switch --terminal term_… ; activate 호출됨
@Test func registryRoutesByLocator()                   // .orca → Orca, .ghostty → Ghostty, .application → 폴백, .none → canNavigate false, navigate throws
@Test func appActivationWalksAncestors()               // 가짜 조상 100→90→80→nil: 클로저가 [100,90,80]을 받음, true면 성공
@Test func appActivationThrowsWhenNoAppFound()         // 클로저 false → .terminalNotFound
```

- [ ] **Step 2: 실패 확인** → 컴파일 실패
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — PASS
- [ ] **Step 5: 실물 확인** — 임시 실행으로 `GhosttyScripts.listTerminals`를 osascript에 넣어 지금 탭 목록이 나오고, `match`가 현재 세션들을 올바른 탭에 짝짓는지 확인 (커밋 안 함)
- [ ] **Step 6: 커밋** — `feat(core): match sessions to Ghostty and Orca terminals and navigate`

---

### Task 9: 앱 껍데기 — 패널·메뉴바·번들 + 유리 렌더링 확인

**Files:**
- Create: `Sources/AgentFloatCore/Window/PanelGeometry.swift`, `Tests/AgentFloatCoreTests/PanelGeometryTests.swift`
- Create: `Sources/AgentFloat/{AppDelegate,FloatingPanel,MenuBarController}.swift`, `Resources/Info.plist`
- Modify: `Sources/AgentFloat/main.swift` (Task 1의 빈 진입점)
- Modify: `Makefile` (`bundle`, `run`)

**Interfaces:**
- Produces:
```swift
public enum PanelGeometry {
    public static let margin: CGFloat = 16
    public static func restoredOrigin(saved: CGPoint?, size: CGSize, visibleFrames: [CGRect]) -> CGPoint
    public static func expandedFrame(collapsed: CGRect, expandedSize: CGSize, visible: CGRect) -> CGRect
}
final class FloatingPanel: NSPanel   // init(contentRect: NSRect)
@MainActor final class MenuBarController { init(onResetPosition: @escaping () -> Void) }
```
- `restoredOrigin`: 저장 위치의 사각형이 어떤 visibleFrame 안에 완전히 들어가면 그대로, 아니면 첫 번째 frame의 오른쪽 위에서 `margin`만큼 안쪽
- `expandedFrame`: 위쪽 가장자리 고정. 접힌 사각형 중심이 화면 가운데보다 오른쪽이면 오른쪽 가장자리 고정, 아니면 왼쪽. 결과를 `visible` 안으로 밀어 넣음
- `FloatingPanel`: styleMask `[.borderless, .nonactivatingPanel]`, `isFloatingPanel`, level `.floating`, collectionBehavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `isMovableByWindowBackground = false`, `hidesOnDeactivate = false`, `canBecomeKey`/`canBecomeMain` → false (포커스를 뺏지 않음, spec 2 실패 조건)
- **끌기 [사용자 요구, spec 4.8]**: 창 배경 끌기는 SwiftUI 내용이 마우스 누름을 가로채면 동작하지 않으므로 쓰지 않음. 끄는 손잡이(접힌 알약 전체, 펼친 패널의 요약 줄)에 SwiftUI `WindowDragGesture()`를 붙임. 세션 줄은 손잡이가 아님(클릭 = 이동)
- 위치는 `NSWindow.didMoveNotification`을 받아 0.3초 디바운스 후 `UserDefaults` 키 `panelOrigin`에 저장. 저장하는 값은 항상 "접힌 알약" 기준 위치
- 메뉴바: SF Symbol 아이콘(빌더 선택), 항목 `위치 초기화`, `로그인 시 실행`(체크 표시, `SMAppService.mainApp` 등록/해제), 구분선, `Agent Float 종료`
- `Info.plist`: Global Constraints의 키 + `NSAppleEventsUsageDescription` = `세션이 열린 Ghostty 탭으로 이동하려면 Ghostty 제어 권한이 필요합니다.`
- `make bundle`: 릴리스 빌드 → `build/Agent Float.app/Contents/{MacOS/AgentFloat, Info.plist}` → `codesign --force --sign - "build/Agent Float.app"`. `make run`: bundle 후 `open "build/Agent Float.app"`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
@Test func savedOriginInsideScreenIsKept()
@Test func offscreenOriginFallsBackToTopRight()   // 저장 (5000, 5000), 화면 (0,0,1512,945) 크기 (148,32) → (1512-16-148, 945-16-32)
@Test func expandAnchorsRightEdgeOnRightHalf()
@Test func expandAnchorsLeftEdgeOnLeftHalf()
@Test func expandedFrameIsPushedInsideScreen()
```

- [ ] **Step 2: 실패 확인** — `swift test --filter PanelGeometryTests` → 컴파일 실패
- [ ] **Step 3: `PanelGeometry` 구현 → 통과 확인** — PASS
- [ ] **Step 4: 앱 껍데기 구현** — `main.swift`에서 `.accessory` 정책, `AppDelegate`가 패널·메뉴바 생성. 패널 내용은 임시로 `Text("Agent Float").padding().glassEffect().gesture(WindowDragGesture())`를 `NSHostingView`로
- [ ] **Step 5: 유리 렌더링 확인 (스파이크)** — `make run` 후 패널을 텍스트가 많은 다른 앱 창 위로 끌어다 놓고 뒤 내용이 흐리게 비치는지 확인
  - 비치면: SwiftUI `glassEffect` 유지
  - 안 비치면(단색 회색 등): 콘텐츠를 `NSGlassEffectView`(AppKit, macOS 26) 안에 넣는 방식으로 바꾸고, 결과를 spec 5장 표에 한 줄로 기록. 이 경우 Task 10의 `GlassEffectContainer`·`glassEffectID` morph는 빼고 크기 전환만 spring으로 함
- [ ] **Step 6: 동작 확인** — Dock 아이콘 없음, 다른 앱에서 타이핑 중 패널 클릭해도 그 앱 포커스 유지, 끌어 옮긴 뒤 재실행하면 위치 복원, `위치 초기화` 동작
- [ ] **Step 6-1: 모든 데스크탑 고정 확인 [사용자 요구, spec 4.8]** — 패널의 `collectionBehavior`에 `.canJoinAllSpaces`·`.stationary`·`.fullScreenAuxiliary`가 모두 들어 있는지 실행 중 값으로 확인(디버그 로그 한 줄 또는 `AGENT_FLOAT_DEBUG=1`일 때 출력). 실제 데스크탑 전환(Ctrl+←/→)·전체화면 앱 위 표시는 사용자 확인 체크리스트로 넘김 (R5)
- [ ] **Step 7: 커밋** — `feat(app): floating non-activating panel, menu bar item, app bundle`

---

### Task 10: 화면 — 알약·펼친 패널·테두리 빛 + 실시간 갱신

**Files:**
- Create: `Sources/AgentFloat/{AppModel,PanelController,DirectoryWatcher,FakeProvider}.swift`
- Create: `Sources/AgentFloat/Views/{FloatRootView,SummaryRow,ExpandedPanelView,SessionRow,BorderSweep,Palette,AppIcons}.swift`
- Modify: `Sources/AgentFloat/AppDelegate.swift` (임시 내용 → `FloatRootView`)

**Interfaces:**
- Consumes: `SessionStore`, `ClaudeCodeProvider.live()`, `SignalTracker`, `SessionGrouping`, `PillSummary`, `Labels`, `PanelGeometry`
- Produces:
```swift
@MainActor @Observable final class AppModel {
    private(set) var sessions: [AgentSession]
    private(set) var groups: [SessionGroup]
    private(set) var summary: PillSummary
    private(set) var unseen: Set<SessionKey>
    var isExpanded: Bool
    init(store: SessionStore, navigators: NavigatorRegistry)
    func start()                        // 감시 + 5초 주기 갱신 시작
    func refresh() async                // snapshot은 메인 밖에서, 반영은 메인에서
    func activate(_ session: AgentSession) async   // Task 11에서 채움 (지금은 빈 구현)
}
```
- 갱신: `DirectoryWatcher`(DispatchSource, `store.watchedDirectories`, 0.2초 디바운스) + 5초 타이머. 변화 없으면 상태 대입하지 않음(불필요한 다시 그리기 방지, CPU 0 목표)
- `AGENT_FLOAT_FAKE_SESSIONS=<n>` 환경변수가 있으면 `FakeProvider`로 n개(긴 한·영 혼합 제목, 네 상태 골고루) 생성
- 화면 값 (spec 4.10, 시안 `apple-style.html`·`light-border.html` A안):
  - `GlassEffectContainer` 안에서 접힘 = `SummaryRow` + `.glassEffect(.regular, in: .capsule)`, 펼침 = `VStack { SummaryRow; 묶음들 }` + `.glassEffect(.regular, in: .rect(cornerRadius: 22))`, 둘 다 `.glassEffectID("float", in: ns)`
  - `SummaryRow`: 대기(`ASK`)·진행·완료(`NEW`)·알 수 없음(회색) 순, 0개 생략. 전부 0이면 회색 점 + `0`을 불투명도 0.5로. 개수 12.5pt Semibold 고정폭 + `.contentTransition(.numericText())`, 점 7pt, 꼬리 10pt Bold
  - `Palette`: 진행 `systemBlue`, 대기 `systemOrange`, 완료 `systemGreen`, 회색 `systemGray`. `ASK` 글자 라이트 `#C93400`/다크 `systemOrange`, `NEW` 글자 라이트 `#248A3D`/다크 `systemGreen` (동적 `NSColor`)
  - 펼친 패널: 폭 280, 안쪽 여백 6, 묶음 소제목 11pt Semibold `secondary`(`내 응답 대기`·`진행 중`·`완료`·`상태 확인 불가`), 높이는 내용에 맞추되 화면 visible 높이의 70% 상한, 넘치면 `ScrollView`
  - `SessionRow`: 반경 16 둥근 배경, 여백 세로 7·가로 10. 1행 제목 13pt Medium 한 줄 말줄임(미확인 완료면 Semibold + `NEW` 캡슐 배지), 2행 11pt `secondary`: `[앱 아이콘 12pt] 폴더 · 대기 사유` 또는 stale이면 `· N분째 활동 없음`. 오른쪽 경과시간 11pt `tertiary` 고정폭. 대기 줄 배경 주황 12%(다크 14%), hover 배경 `primary` 6%(다크 9%), 확인한 완료 줄 불투명도 0.62. stale이면 점 회색
  - `BorderSweep`: 바깥 모양과 같은 `Capsule`/`RoundedRectangle(22)`에 `strokeBorder(AngularGradient(…), lineWidth: 1.5)`, 색 정지점 `clear 0…0.66`, `primary 35% @0.80`, `primary @0.86`, `clear @0.96`, 2.6초 선형 무한 회전. `summary.attention`일 때만. `accessibilityReduceMotion`이면 회전 없이 `primary 70%` 정지 테두리
  - `AppIcons`: 번들 ID `com.mitchellh.ghostty`·`com.stablyai.orca` → `NSWorkspace` 아이콘, 캐시
- 펼침 전환 (`PanelController`, spec 4.8 "자연스럽고 부드럽게" [사용자]):
  - 수치는 한 곳(`enum Motion`)에 상수로: 펼침 지연 0.15초, 접힘 지연 0.4초, `.spring(response: 0.42, dampingFraction: 0.86)`, 목록 페이드인 지연 0.08초, 접힘 시 목록 페이드아웃 0.12초
  - 창 크기는 애니메이션하지 않음(`setFrame(_, display:, animate: false)`). 펼칠 때 창을 먼저 목표 크기(`PanelGeometry.expandedFrame`)로 키우고 SwiftUI 안에서만 morph. 접을 때는 morph가 끝난 뒤 창을 줄임 — 창이 내용보다 먼저 작아져 잘리는 것을 막기 위함
  - SwiftUI 내용은 창 안에서 고정 모서리(`expandedFrame`이 고른 쪽: 오른쪽 위 또는 왼쪽 위)에 정렬 — 창이 커지는 순간에도 알약이 화면상 제자리
  - 펼치기 전에 목록의 목표 높이를 계산(70% 상한 적용)해 창과 유리를 한 번에 그 높이로. 펼친 동안 세션 수가 바뀌면 같은 spring으로 높이만 조정
  - 순서: 펼침 = 유리 morph 시작 → 0.08초 뒤 목록 페이드인(아래로 4pt 미끄러지며) / 접힘 = 목록 0.12초 페이드아웃 → 유리 morph
  - 끄는 중(`WindowDragGesture` 진행 중)에는 펼침·접힘 예약을 취소하고 줄 클릭을 무시. 펼친 상태에서 끌어 옮기면 접힐 때 `restoredOrigin` 기준 위치를 새 자리로 갱신
  - 동작 줄이기(또는 `AGENT_FLOAT_REDUCE_MOTION=1`)면 morph 대신 0.15초 크로스페이드

- [ ] **Step 1: 구현** — 위 값대로 모델·뷰·감시 작성, `AppDelegate`에서 `AppModel(store: SessionStore(providers: [ClaudeCodeProvider.live()]), navigators: NavigatorRegistry([]))` 연결
- [ ] **Step 2: 실세션 확인** — `make run`. 지금 떠 있는 Claude 세션 수·상태가 알약에 맞게 나오는지. 이 계획을 실행 중인 세션에서 AskUserQuestion이 뜨면 1초 안에 `ASK`와 테두리 회전이 생기고, 답하면 사라지는지
- [ ] **Step 3: 시안 대조** — 라이트·다크 각각 스크린샷을 `apple-style.html`과 나란히 비교 (유리 질감, 동심 모서리, 글자 굵기, 라이트 모드 먹색 테두리)
- [ ] **Step 4: 넘침·말줄임 확인 (Review Focus 2·3)** — `AGENT_FLOAT_FAKE_SESSIONS=15 "build/Agent Float.app/Contents/MacOS/AgentFloat"` (바이너리 직접 실행 — `open`은 호출한 셸의 환경변수를 넘기지 않음): 패널이 화면 70%에서 멈추고 스크롤됨, 긴 제목이 한 줄 말줄임, 패널 폭 고정
- [ ] **Step 5: 접근성 확인** — 시스템 설정 손쉬운 사용에서 동작 줄이기 켬 → 테두리가 돌지 않고 정지 테두리. 투명도 줄이기 켬 → 글자 읽힘 (깨지면 불투명 재질로 대체하고 spec 5장에 기록)
- [ ] **Step 6: 유휴 CPU 확인** — 세션 변화 없이 1분 둔 뒤 `top -l 5 -pid $(pgrep -x AgentFloat) -stats cpu` → 테두리 회전 없을 때 평균 1% 미만
- [ ] **Step 7: 커밋** — `feat(app): liquid glass pill and expanded panel with live session updates`

---

### Task 11: 이동·확인 처리 연결 + 남은 실측

**Files:**
- Modify: `Sources/AgentFloat/AppModel.swift` (`activate`, Ghostty 포커스 감시), `Sources/AgentFloat/AppDelegate.swift` (navigator 등록)
- Modify (실측 결과에 따라): `Sources/AgentFloatCore/Claude/TranscriptReader.swift` + 해당 테스트, `docs/specs/2026-10-16-agent-float-design.md` 5장

**Interfaces:**
- Consumes: `NavigatorRegistry`, `GhosttyNavigator`, `OrcaNavigator`, `ProcessCommandRunner`, `GhosttyScripts.focusedTerminalId`, `GhosttyMatcher`, `SignalTracker.markSeen`
- 등록: `NavigatorRegistry([GhosttyNavigator(runner:), OrcaNavigator(runner:, activateOrca: { NSRunningApplication(번들 com.stablyai.orca)?.activate() }), AppActivationNavigator(inspector: DarwinProcessInspector(), activateFirstApp: { pids in … })])`
- `activateFirstApp`: 목록 순서대로 `NSRunningApplication(processIdentifier:)`가 있고 `activationPolicy == .regular`인 첫 앱을 `activate()` 후 true, 없으면 false (메인 액터에서 실행)
- `activate(_:)`: `navigate` 성공 시 `markSeen(session.key)`, 실패 시 `NSSound.beep()` + NEW 유지 (spec 4.6 해제 조건 1, Review Focus 5). `canNavigate`가 false인 줄(`.none`)만 hover 강조 없음
- Ghostty 직접 선택 감지: `unseen`이 비어 있지 않고 맨 앞 앱이 `com.mitchellh.ghostty`일 때만 3초마다 `focusedTerminalId` + `listTerminals` → 미확인 Ghostty 세션과 `GhosttyMatcher.match`로 짝지어 일치하면 `markSeen` (spec 4.6 해제 조건 2)

- [ ] **Step 1: 연결 구현**
- [ ] **Step 2: Ghostty 이동 확인** — 다른 앱이 앞에 있을 때 Ghostty 세션 줄 클릭 → Ghostty가 앞으로 오고 그 탭 선택. 첫 실행 시 TCC 승인 창(`NSAppleEventsUsageDescription` 문구) 확인 후 허용
- [ ] **Step 3: Orca 이동 확인** — Orca 세션 줄 클릭 → Orca가 앞으로 오고 그 탭이 보임. 탭만 바뀌고 앱이 안 올라오면 `activateOrca`가 처리하는지 확인
- [ ] **Step 3-1: 폴백 확인** — Terminal.app에서 `claude` 실행 → 다른 앱이 앞일 때 그 줄 클릭 → Terminal.app이 앞으로 옴. Cursor 내장 터미널에서도 같은 확인 → Cursor가 앞으로 옴
- [ ] **Step 4: 백그라운드 attach 확인** — `claude --bg`로 세션 하나를 띄우고 그 줄 클릭 → Ghostty 새 탭에서 `claude attach <jobId>` 실행. `initial input` 문법이 안 먹으면 `command` 속성으로 바꾸고 `backgroundOpensAttachTab` 테스트 갱신
- [ ] **Step 5: NEW 해제 확인** — 세션 하나를 끝나게 함 → `NEW` + 테두리 회전. 펼치기만 → 유지. Ghostty에서 그 탭을 직접 클릭 → 3초 안에 해제. 다른 세션은 플로팅 클릭으로 해제
- [ ] **Step 6: 자동 재개 실측** — 세션에서 `/loop` 또는 `ScheduleWakeup`이 걸린 상태로 턴을 끝냄 → 알약에 진행으로 남고 `NEW`가 안 켜지는지. transcript의 실제 레코드 형식이 Task 2 규칙과 다르면 표본 fixture를 추가하고 규칙 수정
- [ ] **Step 7: 권한 대기 실측** — `--dangerously-skip-permissions` 없이 세션을 띄워 권한 창을 띄우고 `~/.claude/sessions/<pid>.json`의 `status`·`waitingFor` 확인. `waiting`이 찍히면 `waitReason(from:)` 매핑에 실제 문자열 반영. 안 찍히면 hook 폴백 필요 사실만 spec 5장에 기록하고 멈춤 (hook 구현은 별도 계획)
- [ ] **Step 8: spec 5장 갱신** — Step 2~7 결과로 ❓ 행을 ✅/❌ + 근거로 바꿈
- [ ] **Step 9: 전체 테스트** — `swift test` → 전부 PASS
- [ ] **Step 10: 커밋** — `feat(app): navigate to session terminals and clear NEW on visit`
