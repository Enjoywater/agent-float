# Agent Float v1.1 — Terminal.app · iTerm2 · tmux 정확 이동 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ghostty·Orca처럼 Terminal.app·iTerm2 세션은 그 탭으로, tmux 안의 세션은 그 pane으로 정확히 이동하고, Terminal.app·iTerm2에서 탭을 직접 고르면 `NEW`가 꺼지게 한다.

**Architecture:** provider가 세션 프로세스의 tty와 tmux 환경 변수를 읽어 위치 정보(`TerminalLocator`)에 새 경우 3개를 만든다. 지금 구조대로 터미널마다 `TerminalNavigator`를 하나씩 더하고, Ghostty 전용이던 직접 선택 감시를 앱별 probe로 일반화한다. tmux는 pane으로 옮긴 뒤 바깥 터미널을 tty로 찾아 같은 navigator로 그 탭까지 간다.

**Tech Stack:** Swift 6, SwiftPM, Swift Testing, AppleScript(`osascript`), tmux CLI, Darwin `proc_pidinfo`

**Spec:** `docs/specs/2026-10-16-agent-float-design.md` (4.4 이동, 4.6 신호, 7 로드맵). 이 계획이 4.4에 Terminal.app·iTerm2·tmux 항목을 더하고 7장의 해당 행을 옮긴다

## Global Constraints

- macOS 26 이상, Swift 6 언어 모드, 외부 패키지 의존 없음
- 이름에 `claude`를 고정하지 않음(다른 에이전트 추가 전제). 새 타입은 터미널 이름으로 짓는다
- 주석은 why만. 자명한 주석·주석 처리된 코드 금지. 중첩 삼항 금지. TODO는 `// TODO(@Enjoywater): 사유` 형식만
- 문서·테스트·fixture에 회사 명칭, 실제 로컬 경로, 실제 세션·탭 id, 개인 이메일을 넣지 않음. 경로는 `/Users/me`, id는 `00000000-…` 같은 가짜 값
- 커밋 메시지 끝 줄은 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`만 (세션 링크 줄 없음)
- `NEW` 해제는 이동 뒤 1초 안에 기대한 앱이 실제로 맨 앞에 왔을 때만 (R37). 이동 실패면 경고음 + `NEW` 유지
- 셸이나 AppleScript 문자열에 들어가는 외부 값(tty, tmux 소켓 경로, pane id)은 형식을 검사한 뒤에만 쓴다 (R25와 같은 원칙)
- 앱별 자동화 권한이 거부되면 그 앱의 직접 선택 감시만 멈추고 다른 앱 감시는 계속한다 (R38 일반화)

## Review Focus

1. tty를 못 구한 Terminal.app·iTerm2 세션(권한·좀비 등) → 지금처럼 앱만 올리는 폴백 `.application(pid:)`로 내려가야 함 (Task 1 `terminalSessionWithoutTtyFallsBack`)
2. tmux 클라이언트가 여럿 붙은 세션 → 그 pane의 세션을 보고 있는 클라이언트를 먼저, 없으면 활동이 가장 최근인 클라이언트를 고름 (Task 3 `prefersClientOnPaneSession`)
3. tmux 서버가 이미 죽었거나 pane이 닫힌 세션 → 명령 실패를 `terminalNotFound`로 올려 경고음 (Task 3 `missingPaneIsNotFound`)
4. 소켓 경로나 pane id에 따옴표·공백이 들어간 값 → 새 탭에 입력하지 않고 실패 (Task 3 `unsafeAttachInputIsRejected`)
5. 세션 파일을 읽은 뒤 클릭하기 전에 그 탭이 닫힘 → 스크립트가 `missing`을 돌려주고 경고음 + `NEW` 유지 (Task 2 `missingTabIsNotFound`)

---

## File Structure

| 파일 | 할 일 |
|---|---|
| `Sources/AgentFloatCore/System/ProcessInspector.swift` | `tty(pid:)` 추가 |
| `Sources/AgentFloatCore/Model/AgentSession.swift` | `TerminalLocator`에 `appleTerminal(tty:)`·`iTerm(tty:)`·`tmux(socket:paneId:pid:)` |
| `Sources/AgentFloatCore/Claude/ClaudeCodeProvider.swift` | 환경·tty로 새 위치 정보 생성 |
| `Sources/AgentFloatCore/Navigation/TtyTerminals.swift` (새) | Terminal.app·iTerm2 스크립트, `TtyFormat`, 두 navigator, 두 focus probe |
| `Sources/AgentFloatCore/Navigation/Tmux.swift` (새) | tmux 출력 파싱, 클라이언트 고르기, `TmuxNavigator` |
| `Sources/AgentFloatCore/Navigation/NavigationConfirmation.swift` | 번들 id 추가, `ExpectedFrontmost` 확장, `GhosttyWatchSchedule` → `FocusWatchSchedule` 이름 변경 |
| `Sources/AgentFloatCore/Navigation/Ghostty.swift` | 새 경우 처리, `GhosttyFocusProbe`가 공통 `FocusProbe` 규약을 따름 |
| `Sources/AgentFloat/AppModel.swift` | 직접 선택 감시를 앱별 probe·schedule로 일반화, tmux 도착 확인 |
| `Sources/AgentFloat/AppDelegate.swift`, `AppActivator.swift`, `Views/AppIcons.swift`, `Resources/Info.plist` | 등록·앱 고르기·아이콘·승인 창 문구 |

---

### Task 1: tty 조회와 새 위치 정보

**Files:**
- Modify: `Sources/AgentFloatCore/System/ProcessInspector.swift`, `Sources/AgentFloatCore/Model/AgentSession.swift`, `Sources/AgentFloatCore/Claude/ClaudeCodeProvider.swift`, `Sources/AgentFloatCore/Navigation/Ghostty.swift`(새 경우를 `false`·`terminalNotFound`로), `Sources/AgentFloatCore/Navigation/NavigationConfirmation.swift`
- Test: `Tests/AgentFloatCoreTests/ClaudeCodeProviderTests.swift`, `Tests/AgentFloatCoreTests/NavigationConfirmationTests.swift`, `Tests/AgentFloatCoreTests/ProcessInspectorTests.swift`(있으면 거기, 없으면 새로)

**Interfaces:**
- Produces:
  - `ProcessInspecting.tty(pid: Int32) -> String?` — `/dev/ttys003` 형태, 없으면 nil. 프로토콜 확장으로 기본 구현 `nil`을 두어 테스트 가짜 객체가 깨지지 않게 함
  - `TerminalLocator.appleTerminal(tty: String)`, `.iTerm(tty: String)`, `.tmux(socket: String, paneId: String, pid: Int32)`
  - `TerminalBundle.iTerm = "com.googlecode.iterm2"`
  - `ExpectedFrontmost.expected(for:activatedPid:)`: `.appleTerminal` → `.bundle(appleTerminal)`, `.iTerm` → `.bundle(iTerm)`, `.tmux` → `activatedPid`가 있으면 `.process(pid)`, 없으면 `.bundle(ghostty)`(분리된 세션은 Ghostty 새 탭으로 붙음)

- [ ] **Step 1: 실패하는 테스트**

```swift
// ClaudeCodeProviderTests — FakeInspector 에 ttys: [Int32: String] 를 더한다
@Test func appleTerminalSessionUsesTty() // env ["TERM_PROGRAM": "Apple_Terminal"], tty "/dev/ttys004"
    → found.terminalApp == .other("Apple_Terminal"), found.locator == .appleTerminal(tty: "/dev/ttys004")
@Test func iTermSessionUsesTty()         // "iTerm.app", "/dev/ttys005" → .other("iTerm.app"), .iTerm(tty: "/dev/ttys005")
@Test func terminalSessionWithoutTtyFallsBack() // "Apple_Terminal", tty 없음 → .application(pid: 4012)
@Test func tmuxSessionUsesPaneFromEnvironment()
    // env ["TERM_PROGRAM": "tmux", "TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%7"]
    → found.terminalApp == .other("tmux"), found.locator == .tmux(socket: "/private/tmp/tmux-501/default", paneId: "%7", pid: 4013)
@Test func tmuxWithMalformedEnvironmentFallsBack() // "TMUX": "", 또는 "TMUX_PANE": "7" → .application(pid:)

// NavigationConfirmationTests
#expect(ExpectedFrontmost.expected(for: .appleTerminal(tty: "/dev/ttys004"), activatedPid: nil) == .bundle(TerminalBundle.appleTerminal))
#expect(ExpectedFrontmost.expected(for: .iTerm(tty: "/dev/ttys005"), activatedPid: nil) == .bundle(TerminalBundle.iTerm))
#expect(ExpectedFrontmost.expected(for: .tmux(socket: "/s", paneId: "%1", pid: 9), activatedPid: 77) == .process(77))
#expect(ExpectedFrontmost.expected(for: .tmux(socket: "/s", paneId: "%1", pid: 9), activatedPid: nil) == .bundle(TerminalBundle.ghostty))

// ProcessInspectorTests
@Test func ttyOfMissingProcessIsNil() // tty(pid: 0) == nil, tty(pid: Int32.max) == nil
@Test func ttyOfCurrentProcessMatchesTtyname() // ttyname(STDIN_FILENO) 가 경로를 주면 tty(pid: getpid()) 와 같음, nil 이면 nil
```

- [ ] **Step 2: 실행해 실패 확인** — `swift test 2>&1 | grep -E "error:|✘" | head` → 없는 멤버로 컴파일 실패

- [ ] **Step 3: 구현**
  - `DarwinProcessInspector.tty`: `proc_bsdinfo.e_tdev`가 `NODEV`(`UInt32.max`)거나 조회 실패면 nil, 아니면 `devname(dev_t(e_tdev), S_IFCHR)` 앞에 `/dev/` (같은 사용자 프로세스라 `PROC_PIDTBSDINFO`로 충분)
  - `TerminalContext`에 `tty: String?`, `tmux: String?`(TMUX), `tmuxPane: String?` 추가. 프로세스가 살아 있는 동안 바뀌지 않으므로 기존 캐시에 같이 둠
  - `placement`의 판정 순서: `TMUX`와 `TMUX_PANE`이 둘 다 형식에 맞으면 `.tmux` (tmux 안에서는 `TERM_PROGRAM`이 `tmux`로 덮임) → `ghostty` → `Orca` → `Apple_Terminal`(tty 있으면 `.appleTerminal`) → `iTerm.app`(tty 있으면 `.iTerm`) → 나머지 폴백
  - `TMUX` 형식: 쉼표로 나눈 첫 값이 소켓 경로(`/`로 시작). `TMUX_PANE` 형식: `%` + 숫자
  - Ghostty·Orca·AppActivation navigator의 `switch`에 새 경우를 넣음 (자기 담당이 아니면 `false`·`terminalNotFound`)

- [ ] **Step 4: 통과 확인** — `swift test 2>&1 | grep -E "Test run with|✘"` → 전부 통과

- [ ] **Step 5: 커밋** — `git commit -m "feat: locate Terminal.app, iTerm2 and tmux sessions by tty and pane"`

---

### Task 2: Terminal.app · iTerm2 이동과 직접 선택 probe

**Files:**
- Create: `Sources/AgentFloatCore/Navigation/TtyTerminals.swift`
- Modify: `Sources/AgentFloatCore/Navigation/Ghostty.swift` (`GhosttyFocusProbe`가 `FocusProbe`를 따르게)
- Test: `Tests/AgentFloatCoreTests/TtyTerminalsTests.swift` (새)

**Interfaces:**
- Consumes: Task 1의 `.appleTerminal(tty:)`·`.iTerm(tty:)`, `TerminalBundle.iTerm`
- Produces:
  - `TtyFormat.isDevicePath(_ tty: String) -> Bool` — `^/dev/ttys[0-9]+$`만 참
  - `AppleTerminalScripts.select(tty: String) -> String`, `AppleTerminalScripts.selectedTty: String`
  - `ITermScripts.select(tty: String) -> String`, `ITermScripts.selectedTty: String`
  - `AppleTerminalNavigator(runner:)`, `ITermNavigator(runner:)`: `TerminalNavigator`. 그리고 `func selectTab(tty: String) async throws` — Task 3이 tmux 바깥 터미널에 씀
  - `protocol FocusProbe: Sendable { var bundleIdentifier: String { get }; func canProbe(_ session: AgentSession) -> Bool; func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey> }` — `canProbe`는 그 앱의 위치 정보(`.ghostty`·`.appleTerminal`·`.iTerm`)일 때만 참. Task 4가 감시를 켤지 정할 때 씀
  - `AppleTerminalFocusProbe(runner:)`, `ITermFocusProbe(runner:)`; `GhosttyFocusProbe`도 `bundleIdentifier = TerminalBundle.ghostty`로 따름

- [ ] **Step 1: 실패하는 테스트**

```swift
@Test func ttyFormatAcceptsOnlyDevicePaths()
    // 참: "/dev/ttys0", "/dev/ttys012"  거짓: "", "/dev/ttys", "ttys003", "/dev/ttys003\"", "/dev/ttys003 x", "/dev/tty.usb"
@Test func appleTerminalSelectsTabByTty() async throws
    // FakeCommandRunner 가 "ok" 를 돌려줌 → 호출 1회, 실행 파일 "/usr/bin/osascript", 스크립트에 "/dev/ttys004" 와 "set selected of" 와 "set frontmost of" 와 "activate" 포함
@Test func iTermSelectsSessionByTty() async throws
    // 스크립트에 `tell application id "com.googlecode.iterm2"`, "/dev/ttys005", "select" 포함
@Test func missingTabIsNotFound() async   // 출력 "missing" → NavigationError.terminalNotFound (두 navigator 모두)
@Test func invalidTtyIsRejectedWithoutRunning() async // .appleTerminal(tty: "/dev/ttys1\" & x") → terminalNotFound, runner 호출 0회
@Test func ttyNavigatorsHandleOnlyTheirLocators()
    // AppleTerminalNavigator: .appleTerminal 만 true, .iTerm·.ghostty·.tmux·.application·.none 은 false (ITermNavigator 도 대칭)
@Test func appleTerminalProbeMatchesSelectedTty() async throws
    // selectedTty 출력 "/dev/ttys004\n", 후보 [.appleTerminal("/dev/ttys004") key A, .appleTerminal("/dev/ttys009") key B] → [A]
@Test func probeSkipsWhenNoCandidates() async throws // .ghostty 세션만 → [] , runner 호출 0회
@Test func canProbeOnlyOwnLocators() // AppleTerminalFocusProbe: .appleTerminal 만 true. .orca·.tmux·.application 은 모든 probe 에서 false
```

- [ ] **Step 2: 실행해 실패 확인** — 없는 타입으로 컴파일 실패

- [ ] **Step 3: 구현**
  - 스크립트는 `tell application id "<bundle>"`로 쓴다 (앱 이름이 `iTerm`·`iTerm2`로 달라도 맞게)
  - Terminal.app 선택: 창 → 탭을 돌며 `tty of t`가 같으면 `set selected of t to true`, `set frontmost of w to true`, `activate`, `"ok"`. 끝까지 없으면 `"missing"`
  - iTerm2 선택: 창 → 탭 → 세션을 돌며 `tty of s`가 같으면 `select w`, `tell t to select`, `tell s to select`, `activate`, `"ok"` (세션 `select`만으로는 탭·창이 안 바뀜 — iTerm2 스크립팅 문서). 정확한 명령은 Task 6에서 설치본 `sdef`로 확인하고 틀리면 고침
  - 선택된 탭의 tty: Terminal.app `tty of selected tab of front window`, iTerm2 `tty of current session of current window`
  - 출력 `"ok"`가 아니면 `terminalNotFound` (Ghostty와 같은 규칙)
  - tty는 `TtyFormat.isDevicePath`를 통과한 값만 스크립트에 넣음. 실패하면 명령을 띄우지 않고 `terminalNotFound`

- [ ] **Step 4: 통과 확인** — 전체 테스트 통과

- [ ] **Step 5: 커밋** — `git commit -m "feat: navigate to Terminal.app and iTerm2 tabs by tty"`

---

### Task 3: tmux 이동

**Files:**
- Create: `Sources/AgentFloatCore/Navigation/Tmux.swift`
- Test: `Tests/AgentFloatCoreTests/TmuxTests.swift` (새)

**Interfaces:**
- Consumes: Task 1의 `.tmux(socket:paneId:pid:)`, `ProcessInspecting.parentPid`, `GhosttyScripts.newTab(initialInput:)`. 바깥 터미널의 탭 선택(Task 2의 `selectTab(tty:)`)은 Task 5가 `outer` 클로저 안에서 씀
- Produces:
  - `TmuxClient: Equatable, Sendable { tty: String; pid: Int32; session: String; activity: Int }`
  - `TmuxCLI.candidatePaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]`, `TmuxCLI.resolveExecutable() -> String?` (앱은 로그인 셸 PATH를 받지 않아 경로를 직접 찾음)
  - `TmuxCLI.parseClients(_ output: String) -> [TmuxClient]` — 형식 `#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}`
  - `TmuxCLI.chooseClient(for paneSession: String, among: [TmuxClient]) -> TmuxClient?`
  - `TmuxCLI.isSafeSocketPath(_:) -> Bool` (`/`로 시작, `[A-Za-z0-9/._-]`만), `TmuxCLI.isPaneId(_:) -> Bool` (`%` + 숫자)
  - `TmuxNavigator(runner:inspector:executable: String?, outer:)` — `executable`은 앱이 `resolveExecutable()`로 넘기고 테스트는 가짜 경로를 넘김. nil이면 `canNavigate`는 참이되 이동은 `terminalNotFound`. `outer`는 `outer: @Sendable (_ sessionPid: Int32, _ clientChain: [Int32], _ clientTty: String) async throws -> Void` — 바깥 터미널 처리를 앱 타깃이 주입(Task 5)

- [ ] **Step 1: 실패하는 테스트**

```swift
@Test func parsesClientList()   // "/dev/ttys001\t501\tmain\t1792370000\n/dev/ttys002\t502\twork\t1792370100\n" → 2개, 필드 일치
@Test func prefersClientOnPaneSession()
    // clients [main(활동 200), work(활동 100)], paneSession "work" → work. paneSession "other" → 활동이 큰 main. 빈 목록 → nil
@Test func attachedPaneSwitchesClientThenOuterTerminal() async throws
    // runner: "display-message" 에 "work\n", "list-clients" 에 work 클라이언트 → 호출 순서
    // 실행 파일은 생성자에 넘긴 "/fake/tmux", 인자 배열은 셸을 거치지 않음
    //   ["-S", "/s", "display-message", "-p", "-t", "%7", "#{session_name}"]
    //   ["-S", "/s", "list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"]
    //   ["-S", "/s", "switch-client", "-c", "/dev/ttys002", "-t", "%7"]
    // outer 가 (sessionPid 4013, [502, …부모], "/dev/ttys002") 로 1회 불림
@Test func detachedPaneOpensGhosttyAttachTab() async throws
    // list-clients 출력 "" → tmux ["-S","/s","select-window","-t","%7"], ["-S","/s","select-pane","-t","%7"] 뒤 osascript 1회,
    // 스크립트에 `tmux -S /s attach -t %7` 포함, outer 호출 0회. attach 는 세션만 열고 현재 창·pane 을 바꾸지 않으므로 미리 고름
@Test func missingPaneIsNotFound() async // display-message 가 commandFailed 를 던짐 → terminalNotFound
@Test func unsafeAttachInputIsRejected() async
    // .tmux(socket: "/tmp/a b", paneId: "%7", …) 또는 paneId "%7;x" → terminalNotFound, runner 호출 0회
@Test func tmuxNavigatorHandlesOnlyTmux() // .tmux 만 true
```

- [ ] **Step 2: 실행해 실패 확인** — 컴파일 실패

- [ ] **Step 3: 구현**
  - 순서: 형식 검사 → `display-message -p -t <pane> '#{session_name}'`로 pane이 살아 있는지와 세션 이름 확인(실패는 `terminalNotFound`) → `list-clients` → 클라이언트가 있으면 `switch-client -c <tty> -t <pane>` (pane 대상이면 세션·창·pane이 함께 바뀜, tmux 3.6 man) 후 클라이언트 pid에서 부모를 따라 올라간 체인으로 `outer` 호출. 없으면 `select-window -t <pane>`·`select-pane -t <pane>`(클라이언트 없이도 동작) 뒤 Ghostty 새 탭에 `tmux -S <socket> attach -t <pane>`
  - `resolveExecutable()`은 `FileManager.isExecutableFile`로 세 경로 중 처음 있는 것을 돌려줌
  - 부모 체인 상한은 `AppActivationNavigator`와 같은 32

- [ ] **Step 4: 통과 확인**

- [ ] **Step 5: 커밋** — `git commit -m "feat: navigate to tmux panes and attach detached sessions"`

---

### Task 4: 직접 선택 감시 일반화

**Files:**
- Modify: `Sources/AgentFloatCore/Navigation/NavigationConfirmation.swift` (`GhosttyWatchSchedule` → `FocusWatchSchedule`, 동작 그대로), `Sources/AgentFloat/AppModel.swift`
- Test: `Tests/AgentFloatCoreTests/NavigationConfirmationTests.swift` (이름 변경 반영)

**Interfaces:**
- Consumes: Task 2의 `FocusProbe`와 probe 3개
- Produces: `AppModel.init(store:navigators:focusProbes: [any FocusProbe], activator:)`

- [ ] **Step 1: 테스트 이름 변경** — 기존 `GhosttyWatchSchedule` 테스트를 `FocusWatchSchedule`로 바꾸고 실패(컴파일) 확인
- [ ] **Step 2: 구현**
  - schedule을 번들 id별로 둠: `[String: FocusWatchSchedule]`. 권한 거부는 그 앱만 멈춤. 이동 성공 시 그 세션 앱의 schedule만 `resume()`
  - 감시 주기는 "미확인 세션 중 어떤 probe의 `canProbe`가 참이고, 그 probe 앱의 schedule이 멈추지 않았을 때"만 돔. Orca·tmux만 미확인이면 깨어나지 않음. 한 주기에 맨 앞 앱의 probe 하나만 실행 (맨 앞이 아니면 osascript 0회 — spec 4.9 유휴 CPU)
  - 로그 문구는 `focus watch on|off|checked|failed bundle=<id> …`로 바꿈 (체크리스트 문구도 Task 6에서 갱신)
  - `targetCameForward`: `.tmux(_, _, pid)`도 `activator.takeFallbackChoice(forSession: pid)`로 실제 올린 앱 pid를 받음
- [ ] **Step 3: 통과 확인** — 전체 테스트 통과, `swift build -c release` 경고 0
- [ ] **Step 4: 커밋** — `git commit -m "refactor: generalize direct-selection watch to per-app focus probes"`

---

### Task 5: 앱 연결

**Files:**
- Modify: `Sources/AgentFloat/AppDelegate.swift`, `Sources/AgentFloat/AppActivator.swift`, `Sources/AgentFloat/Views/AppIcons.swift`, `Resources/Info.plist`

**Interfaces:**
- Consumes: Task 2·3·4의 navigator·probe·`AppModel.init`
- Produces: `AppActivator.chooseFirstRegularApp(forSession: Int32, among: [Int32]) -> (pid: Int32, bundleIdentifier: String?)?` — 고른 앱을 `fallbackChoices`에 기록 (R37 확인용)

- [ ] **Step 1: 구현**
  - 등록 순서: Ghostty → Orca → AppleTerminal → ITerm → Tmux → AppActivation
  - tmux `outer` 클로저: `chooseFirstRegularApp`로 바깥 앱을 고르고, 번들이 Terminal.app이면 `AppleTerminalNavigator.selectTab(tty: clientTty)`, iTerm2면 `ITermNavigator.selectTab`, 그 밖(Ghostty 포함)은 LaunchServices로 그 앱만 엶. 앱을 못 고르면 `terminalNotFound`
  - `AppModel.activate` 시작 때 그 세션 pid의 `fallbackChoices`를 버림 (`outer`가 기록한 뒤 이동이 실패하면 다음 클릭이 옛 pid를 기대하게 됨. 기존 폴백도 같은 성질)
  - `AppIcons.otherCandidates`에 `"iTerm.app": [TerminalBundle.iTerm]`
  - `NSAppleEventsUsageDescription`: `세션이 열린 터미널 탭으로 이동하려면 그 터미널을 제어할 권한이 필요합니다.`
- [ ] **Step 2: 확인** — `make bundle` 경고 0, `swift test` 통과
- [ ] **Step 3: 커밋** — `git commit -m "feat: wire Terminal.app, iTerm2 and tmux navigation into the app"`

---

### Task 6: 실측과 문서

**Files:**
- Modify: `docs/specs/2026-10-16-agent-float-design.md` (4.4에 세 터미널 항목, 5장 검증 행, 7장에서 Terminal.app·tmux 행 제거하고 v1.2 후보 정리), `docs/plans/2026-10-16-agent-float-rulings.md` (`## v1.1 (2026-10-19)` 섹션), `docs/checklists/2026-10-16-agent-float-v1-user-check.md` (1번 승인 창 문구, 로그 문구, v1.1 항목 추가), `README.md` (터미널 이동 표)

- [ ] **Step 1: iTerm2 설치** — `brew install --cask iterm2`(사용자 승인됨). 설치본 `sdef`로 Task 2의 iTerm2 명령(`select`, `tty`, `current session`) 확인, 다르면 Task 2 스크립트와 테스트를 고치고 커밋
- [ ] **Step 2: 화면 실측** (시험 세션은 haiku, 이미 신뢰된 폴더, 끝나면 `/exit`)
  - Terminal.app 탭 2개 중 다른 탭을 보는 중에 세션 줄 클릭 → 그 탭으로, `NEW` 해제. 탭을 직접 고르면 `NEW` 해제
  - iTerm2 같은 확인
  - tmux: 바깥 Terminal.app·Ghostty 각각에서 다른 창을 보는 중 클릭 → 그 pane으로, Terminal.app은 탭까지, Ghostty는 앱까지. 분리된 세션 클릭 → Ghostty 새 탭에서 붙음
  - 승인 창(Terminal.app·iTerm2 제어)은 사용자가 허용
- [ ] **Step 3: 문서 반영** — 실측 결과와 실패 시 원인·수정
- [ ] **Step 4: 최종 검사** — 회사 명칭·식별 정보 grep 0건, `swift test` 통과, `make bundle` 경고 0
- [ ] **Step 5: 커밋** — `git commit -m "docs: record v1.1 terminal navigation results"`
