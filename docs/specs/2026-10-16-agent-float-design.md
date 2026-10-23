# agent-float — AI 에이전트 세션 상태 플로팅 위젯 설계

- 작성일: 2026-10-16
- 상태: 승인됨 (2026-10-16)
- 시안: `2026-10-16-agent-float-mockups/` (`collapsed-signals.html`의 B안, `expanded-layout.html`, `apple-style.html`, `light-border.html`의 A안)
- v1 지원 에이전트: Claude Code만. 이름·구조는 다른 AI를 붙일 수 있게 에이전트 중립으로 둠 **[사용자]** (4.0 참고)

표기: **[사용자]** = 사용자가 직접 정한 것, **[판단]** = 대화 중 Claude가 정하고 사용자에게 알린 것(반대 없음). 표기가 없는 항목은 조사로 확인된 사실이다.

---

## 1. 의도

Ghostty·Orca 여러 터미널에서 AI 에이전트 세션(현재는 Claude Code, 앞으로 3~4종이 섞일 수 있음)을 동시에 돌리는데, 각 세션이 "진행 중인지 / 내 응답을 기다리며 멈췄는지 / 끝나서 멈췄는지"를 확인하려면 터미널을 하나씩 열어봐야 한다. 데스크톱 구석에 작은 플로팅을 띄워 **한눈에 상태를 보고, 클릭하면 그 세션의 터미널 탭으로 바로 이동**하게 한다.

성공의 모습: 흘끗 봐서 "나를 기다리는 세션이 있는지", "새로 끝난 세션이 있는지"를 알 수 있고, 클릭 한 번이면 그 세션 앞에 가 있다.

## 2. 목표 / 비목표 / 실패 조건

### 목표
1. 이 머신의 모든 Claude Code 세션(대화형 + 백그라운드) 상태를 3가지로 표시 **[사용자]** — v1 범위. 이후 다른 AI 에이전트 추가 가능성을 열어 둠 **[사용자]**
   - 진행 중 / 내 응답 대기(승인·질문) / 완료 — 대기와 완료는 반드시 구분 **[사용자]**
2. 세션 클릭 → 해당 터미널 탭으로 포커스 이동 **[사용자]** (Ghostty, Orca)
3. 놓친 완료를 확인 전까지 알아볼 수 있음 (`NEW`) **[사용자]**

### 비목표 **[판단]**
- 플로팅에서 세션에 명령 보내기 (보기 + 이동만). 대기 중인 질문에 답하기는 v1.2에서 추가됨 **[사용자]** → `2026-10-23-agent-float-v1.2-reply-design.md`
- 원격(SSH)·다른 머신의 세션
- Ghostty·Orca 외 터미널의 **정확한 탭** 이동 — v1은 그 터미널 앱만 앞으로 올림 **[사용자]**. 터미널별 정확한 이동은 이후 하나씩 추가 **[사용자]** (7장 로드맵)
- 소리, macOS 알림센터 알림
- 기본적으로 Claude Code 설정·hook을 바꾸지 않음 (세션 쪽 설치물 0개). 단, 세션 파일로 못 잡는 대기 유형이 실측으로 확인되면 상태 기록용 hook 설치 허용 **[사용자]** — 4.2 참고
- 사용량·토큰·비용 표시
- v1에서 Claude Code 외 에이전트(Gemini, cursor-agent, Codex 등) 감지 — 구조만 열어 두고 구현은 안 함 **[사용자]**

### 실패 조건 (동작은 해도 실패로 보는 것) **[판단]**
- 상태가 실제와 다르게 보임 — 특히 대기인데 진행으로 보이는 경우
- 클릭이나 hover 시 현재 작업 중인 앱의 포커스를 뺏음 (단, 세션으로 이동하는 클릭은 의도된 포커스 이동)
- 가만히 있을 때 CPU를 계속 점유
- 움직임이 많아 산만함 (그래서 움직이는 요소는 테두리 하나뿐)

## 3. 제약

- macOS 전용, 사용자 본인 머신(macOS 26.4, Apple Silicon)에서만 사용
- 대상 터미널: Ghostty 1.3.1, Orca (`/usr/local/bin/orca` CLI 제공)
- Claude Code 2.1.30x. 아래 데이터 소스는 공개 API가 아닌 내부 파일이라 버전업 시 깨질 수 있음 → 파싱은 관대하게, 모르는 값은 무시
- 사용자는 모든 대화형 세션을 `--dangerously-skip-permissions`로 실행 → 권한 승인 대기는 드물고, 대기는 대부분 질문(AskUserQuestion 등)에서 발생

## 4. 결정된 사항

### 4.0 명명과 확장 구조 **[사용자: Claude로 이름 고정 금지 / 판단: 구체 이름·구조]**

- 앱·저장소·번들·모듈·공통 타입 이름에 `claude`를 쓰지 않음
  - 저장소/폴더: `agent-float`, 앱 표시 이름: `Agent Float`, 번들 ID 예: `dev.enjoywater.agent-float` (접두는 빌더 재량)
  - 공통 모델: `AgentSession`, `AgentStatus`(`running` / `waiting` / `done` / `unknown`), `WaitReason`
- **에이전트별 어댑터(provider)** 로 상태 수집을 분리: 공통 프로토콜(예: `AgentProvider`)이 "현재 세션 목록 + 변경 알림"을 내고, UI·신호 규칙·이동 로직은 공통 모델만 봄
  - v1 구현체는 `ClaudeCodeProvider` 하나 (에이전트 고유 구현이므로 이 이름엔 Claude를 씀). 4.2·4.3은 이 provider의 명세
  - 원천별 차이(`busy`/`idle` 같은 Claude 고유 값)는 provider 안에서 공통 상태로 변환하고 밖으로 새지 않게 함
- 터미널 이동도 같은 방식으로 분리: `TerminalNavigator`(예) 프로토콜 + `GhosttyNavigator`, `OrcaNavigator`. 세션은 "어느 터미널 앱의 어떤 위치"라는 중립 정보만 가짐
- **여러 에이전트 동시 사용 전제 [사용자: 3~4종이 동시에 돌 수 있음]**
  - provider는 여러 개가 동시에 돌고, 결과를 하나의 목록으로 합침. 한 provider가 실패해도 나머지는 계속 표시
  - 세션 식별 키는 `(providerId, sessionId)` — 에이전트 간 ID 충돌 방지
  - 접힌 알약의 개수·`ASK`·`NEW`는 에이전트 구분 없이 합산. 묶음(대기/진행/완료)도 에이전트를 가로질러 상태 기준
  - 펼친 목록의 2행에 에이전트 종류 표시: `Claude · Ghostty · ~ · 질문 답변 대기` 형태. v1에선 한 종류뿐이라 생략 가능하되, 자리와 데이터 필드는 처음부터 둠 (빌더 재량: 글자 vs 작은 아이콘)
  - provider 목록은 코드에 하드코딩된 단일 분기(`if claude`)가 아니라 등록 방식 (새 provider 추가 시 UI·신호 코드 수정 불필요)
- 참고: 다른 AI는 Claude 같은 상태 파일이 없어 hook으로 상태를 기록해야 할 가능성이 큼 (Orca가 12종 에이전트용 hook 스크립트를 보유, 이 머신에선 Claude만 연결됨). 이 경우를 대비해 provider가 "파일 감시"뿐 아니라 "외부가 써 주는 상태 디렉터리 읽기"도 할 수 있는 형태면 좋음 — 구현은 v2

### 4.1 기술 스택 **[판단 — 사용자가 위임]**

- Swift 6 + SwiftUI(뷰) + AppKit `NSPanel`(창). 서드파티 의존성 없음
- SwiftPM 실행 타깃 + Makefile로 `.app` 번들 조립 (Xcode 프로젝트 파일 없이). 참고 사례: `~/projects/sample-menubar-app` (같은 방식의 메뉴바 앱)
- 선택 이유: 상시 메모리 최소(수십 MB), 비활성 플로팅 패널·모든 Space 표시가 기본 지원, 파일 감시·AppleScript·외부 프로세스 실행이 표준 라이브러리로 해결
- 로컬 빌드 툴체인: Swift 6.3.3, Xcode 26.6 설치 확인됨

### 4.2 상태 모델

**원천 데이터: `~/.claude/sessions/<pid>.json`** — Claude Code가 살아있는 세션마다 직접 쓰고 갱신한다. 확인된 필드:

| 필드 | 예 | 용도 |
|---|---|---|
| `pid` | 36441 | 생존 확인, 프로세스 환경변수 조회 |
| `sessionId` | `00000000-…-0000000000a1` | 세션 식별, transcript 찾기 |
| `cwd` | `/Users/me/work/feat-checkout-retry` | 2행 폴더 표시 |
| `kind` | `interactive` / `bg` | 백그라운드 구분 |
| `status` | `busy` / `idle` / `waiting` | 3상태 |
| `waitingFor` | `input needed` 등 | 대기 사유 |
| `name`, `nameSource` | `sample-df` / `derived` | 제목 폴백 |
| `statusUpdatedAt` | epoch ms | 경과시간 |
| `jobId` | `fe50860d` | 백그라운드 세션 attach용 |

표시 상태 매핑:

| `status` | 표시 | 점 색 |
|---|---|---|
| `busy` | 진행 중 | 파랑 |
| `waiting` | 내 응답 대기 | 주황 |
| `idle` | 완료 | 초록 |
| `shell` | 진행 중 (본문 질문으로 끝났으면 대기) | 파랑 |
| 그 외/누락 | 진행 중으로 취급하지 말 것 — 알 수 없음(회색) | 회색 |

- `shell`: 턴이 끝났는데 백그라운드 셸이 남은 `idle` (2.1.301 세션에서 관찰, 실행 파일 코드 `idle && 백그라운드 셸 ? "shell" : status`로 확인, R44)

- 바이너리 코드 기준 `waiting`은 다음일 때 설정됨: 질문(elicitation) 대기(`input needed`), 상단 다이얼로그 대기(권한 등, 다이얼로그별 문자열), `worker request`, `sandbox request`, `dialog open`. 알려진 값은 한국어 사유로 바꾸고("질문 답변 대기", "승인 대기" 등), 모르는 값은 원문 그대로 표시
- **실측 (2026-10-16)**: AskUserQuestion 질문 창이 떠 있는 동안 세션 파일이 `busy` → `waiting`(`waitingFor: "input needed"`)로 바뀌고, 답한 뒤 `busy`로 돌아옴 (약 0.3초 간격 폴링 로그로 확인)

**세션 파일만으로는 틀리게 보이는 두 경우 — transcript 끝부분 판독으로 보정 [사용자]**

| 경우 | 세션 파일 | 표시 | 판정 근거 (빌더가 실측해 확정) | 해제 |
|---|---|---|---|---|
| 평문 질문으로 턴 종료 (질문 도구 없이 본문으로 "어떻게 할까?" 묻고 끝냄. 브레인스토밍류 흐름에서 흔함) | `idle` | **대기** (`ASK`), 사유 "질문(본문)" | 마지막 턴의 마지막 assistant 텍스트가 질문으로 끝남. 한국어 종결 다양성 주의: `?`뿐 아니라 "~할까", "~인지 궁금함", "알려줘" 등. 설계 대화의 transcript(`~/.claude/projects/-Users-me/<sessionId>.jsonl`)가 좋은 실물 표본 | 사용자의 다음 입력이 들어옴 (`busy` 전환 또는 transcript에 새 user 메시지) |
| 스스로 다시 깨어날 세션 (`/loop`, 예약 깨우기, 대기 중인 백그라운드 작업, 워커 완료 알림 대기, 주기 폴링 스킬) | `idle` | **진행 중** (파랑), `NEW` 안 켬 | transcript에 미완료 백그라운드 작업, 예약된 깨우기, 살아 있는 cron 흔적이 있음 (형태는 5장 실측) | 흔적이 사라진 채 `idle`이면 그때 완료로 전환 |

- 오탐 허용: 질문형 문장으로 끝나는 완료 보고가 대기로 보일 수 있음을 사용자가 감수함 **[사용자]**
- 판정은 상태가 `idle`·`shell`일 때만, transcript 끝부분만 읽음 (전체 파싱 금지)
- 백그라운드 작업 시작·예약 깨우기(`ScheduleWakeup`)는 지금 프로세스가 뜬 뒤(세션 파일 `procStart` 이후, 레코드 `timestamp` 기준) 기록된 것만 셈. `--resume`한 세션은 이 둘을 이어받지 않아(예약 깨우기는 실측) 그 흔적을 세면 끝 알림이 영영 오지 않아 진행 중으로 굳음. 시각이 없는 레코드는 셈. 평문 질문 판정은 시각 제한 없음
- cron은 `--resume`하면 되살아나 다시 울림(실측: 종료 창에서 "작업 중단"을 골라도 되살아남) → 시각 제한 없이 셈. 등록은 CronCreate 결과 문구(`Scheduled recurring job <id>` / `Scheduled one-shot task <id>`)로 id별로 세고, `CronDelete {id}`로 그 id만 지움. 한 번짜리는 `scheduled_task_fire`(`taskId`) 기록으로 울린 뒤 지움(CronDelete 없이 저절로 지워짐). 반복은 등록 7일 뒤 만료("Auto-expires after 7 days")
- **hook 폴백 [사용자: 허용]**: 위 판독이나 세션 파일로 못 잡는 대기 유형(예: 권한 다이얼로그가 파일에 안 찍히는 경우)이 실측으로 나오면, 상태 기록용 전역 Claude hook 설치 허용. 조건: hook 경로 제한·하드코딩 없이 모든 경로에 적용, 기존 hook과 공존, 4.0의 "외부가 써 주는 상태 디렉터리" 형태로 기록해 다른 에이전트 어댑터도 같은 방식을 재사용. 필요 없으면 설치하지 않음
- **pid가 죽었으면 목록에서 제거** (크래시로 남은 파일 무시). pid 재사용 대비로 파일의 `procStart`와 `ps -o lstart= -p <pid>`를 비교
- **응답 없음 의심(회색 점)**: 세션 파일 원본이 `busy`인데 transcript 파일(`~/.claude/projects/*/<sessionId>.jsonl`)의 마지막 수정이 오래됨. `statusUpdatedAt`은 상태가 바뀔 때만 갱신되므로 긴 작업 중엔 오래돼도 정상 → 기준으로 쓰지 말 것. 임계값은 빌더 재량 (출발점 10분). 4.2 보정으로 진행 표시된 자동 재개 세션(원본 `idle`)은 제외 — 깨우기 사이 공백이 길어도 정상
- 서브에이전트는 별도 줄 없이 부모 세션에 포함 **[판단]**
- 백그라운드 세션(`kind: bg`)도 목록에 포함 **[판단]**

### 4.3 세션 제목과 2행 정보

- **1행 제목**: transcript jsonl의 마지막 `{"type":"ai-title","aiTitle":…}` 레코드. 파일이 수 MB일 수 있으므로 끝에서부터 읽을 것. 없으면 세션 파일의 `name`
- **2행**: `(에이전트 ·) [앱 아이콘] 폴더 · 대기 사유` — 앱은 이름 대신 실제 앱 아이콘 12pt로 표시(4.10), 에이전트 칸은 4.0 참고
  - 앱: Ghostty / Orca / 기타. 판별은 `ps -E -ww -p <pid>`의 `TERM_PROGRAM` (`ghostty` / `Orca`). pid별 1회만 조회해 캐시
  - 폴더: `cwd`의 마지막 경로명 (홈이면 `~`)
  - 대기 사유: 대기 상태일 때만
- **오른쪽 경과시간**: 지금 상태로 바뀐 뒤 흐른 시간(`now - statusUpdatedAt`), `3m`·`1h` 같은 축약 **[판단]**

### 4.4 세션 → 터미널 이동

**Ghostty** (실측 확인)
- AppleScript로 `windows → tabs → terminals`를 열거해 각 터미널의 `id`, `name`(탭 제목), `working directory`를 얻음
- Ghostty는 tty·pid를 노출하지 않음 → **탭 제목으로 매칭**. Claude Code는 탭 제목을 `"<기호> <ai-title>"`로 설정함(기호: 진행 중 `◐`/`◑` 교대, 정지 `✳`). 앞의 기호+공백을 떼고 ai-title과 비교, 동률이면 `working directory == cwd`로 좁힘
- 그래도 여러 개면 첫 번째로 이동 (모호함은 빌더가 로그로 남김)
- 이동: `focus <terminal>` — 다른 탭으로 갔다 돌아오는 것까지 실측 확인
- 주의: 같은 홈 폴더(`~`)에서 띄운 세션이 많아 cwd만으로는 구분 불가(현재 4개)

**Orca** (실측 확인)
- Claude 프로세스 환경변수에 `ORCA_TAB_ID`, `ORCA_PANE_KEY`(`<tabId>:<leafId>`), `ORCA_TERMINAL_HANDLE`이 있음 (`ps -E`로 실측 확인)
- `orca terminal list --json`에서 `handle`이 `ORCA_TERMINAL_HANDLE`과 같은 터미널을 먼저 찾고, 없으면 `tabId`·`leafId`가 같은 것을 찾아 `orca terminal switch --terminal <handle>` 실행 + Orca 앱 활성화
  - handle을 먼저 보는 이유: 아직 열지 않은 워크트리의 터미널은 목록에 `tabId`·`leafId`가 임시 값(`pty:…`, `orphaned: true`)으로 나옴 (1.4.224 실측, R43)
- switch 뒤 Orca가 앞으로 오고 그 탭이 보임, 새 창은 안 생김 (2026-10-19 실측)

**백그라운드 세션** **[판단]**
- 붙어 있는 터미널이 없으므로, 클릭 시 Ghostty 새 탭을 열어 `claude attach <jobId>` 실행 (Ghostty AppleScript `new tab` + surface configuration의 command/initial input)

**Terminal.app · iTerm2** (v1.1, 실측 확인)
- 제어 터미널(tty, `proc_bsdinfo.e_tdev`)을 읽음. 두 앱은 AppleScript로 탭(iTerm2는 세션)마다 `tty`를 알려 줌 → 같은 tty인 탭을 고르고 창을 앞으로, 앱 활성화
  - 세션 프로세스 자신이 아니라 부모를 따라 tty가 이어지는 가장 바깥 프로세스(탭을 연 셸)의 tty를 씀. nvim `:terminal`·screen처럼 안쪽 pty를 만드는 프로그램 아래에서는 세션의 tty가 탭의 tty가 아님 (R52)
  - Terminal.app: `set selected of <tab> to true` + `set frontmost of <window> to true`
  - iTerm2: `select <window>`, `select <tab>`, `select <session>` (세션 `select`만으로는 탭·창이 안 바뀜)
- 판별: `TERM_PROGRAM`이 `Apple_Terminal` / `iTerm.app`. tty를 못 읽으면 앱만 올리는 폴백
- tty는 `/dev/ttys<숫자>` 형태만 스크립트에 넣음
- 직접 선택 감지: 그 앱이 맨 앞일 때 선택된 탭(iTerm2는 현재 세션)의 tty로 Ghostty와 같은 방식으로 `NEW` 해제. 앱별로 권한 거부를 따로 관리 (R38 일반화)

**tmux** (v1.1, 실측 확인)
- 세션 프로세스 환경변수 `TMUX`(`<소켓>,<서버 pid>,<번호>`)와 `TMUX_PANE`(`%<숫자>`)으로 pane을 정확히 앎. tmux 안에서는 `TERM_PROGRAM`이 `tmux`로 덮이므로 이것을 먼저 봄
  - 서버 pid가 세션의 조상일 때만 tmux 안으로 봄. tmux 안에서 띄운 IDE처럼 환경변수만 물려받은 프로세스를 거르기 위함 (R53)
- 이동: `display-message`로 pane이 살아 있는지와 세션 이름을 확인 → `list-clients`에서 그 세션을 보는 클라이언트(없으면 가장 최근 활동 클라이언트)를 골라 `switch-client -c <client tty> -t <pane>`(세션·창·pane이 함께 바뀜)
- 바깥 터미널: 클라이언트 pid에서 부모를 따라 첫 일반 앱을 고름. Terminal.app·iTerm2면 클라이언트 tty로 그 탭까지, 그 밖(Ghostty 포함)은 앱만 올림. Ghostty는 tty를 알려 주지 않아 tmux가 있는 탭까지는 못 감
- 바깥 탭 선택이 실패하면(제어 권한 거절, 그 tty의 탭 없음) 앱만 올리는 폴백으로 내려가지 않고 이동 실패(경고음). pane은 이미 바뀐 상태 — 알려진 한계
- 붙은 클라이언트가 없으면 `select-window`·`select-pane`으로 pane을 고른 뒤 Ghostty 새 탭에서 `<tmux 경로> -S <소켓> attach -t <pane>` 실행. 소켓 경로는 `[A-Za-z0-9/._-]`만 받음
- tmux 실행 파일은 `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` 순서로 찾음 (앱은 로그인 셸 PATH를 받지 않음)
- tmux 안의 직접 선택 감지는 없음 (v1.2 후보)

**기타 터미널 (폴백) [사용자]**: 클릭하면 그 세션을 띄운 터미널 앱을 앞으로 올림 (정확한 탭 이동은 아님). 앱 판별: Claude 프로세스에서 부모 프로세스를 따라 올라가며 처음 만나는 일반 GUI 앱(Dock에 뜨는 앱). 예: Cursor 내장 터미널, tty를 못 읽은 Terminal.app. 그런 앱을 못 찾으면 이동 실패로 보고 경고음을 냄 (R39). 소리 없이 무시하는 것은 이동할 곳이 아예 없는 세션(hover 강조도 없는 줄)뿐

### 4.5 화면 — 접힌 상태(알약) **[사용자: 접이식 알약 + 펼침 시 묶음·두 줄]**

시안: `collapsed-signals.html`의 **B안**

- 화면 구석에 떠 있는 작은 알약. 내용: 상태 점 + 개수, 순서는 **대기 → 진행 → 완료** (개수가 0인 상태는 생략)
- 폭은 내용에 따라 늘어남 (실측: 꼬리 둘 다 있을 때 약 148px)
- 세션이 0개면 알약을 흐리게 유지 (숨기면 앱이 꺼졌는지 헷갈림) **[판단]**

### 4.6 신호 규칙 **[사용자 결정 위주]**

| 신호 | 의미 | 켜지는 조건 | 꺼지는 조건 |
|---|---|---|---|
| 테두리 빛 회전 (다크 흰빛 / 라이트 먹색) **[사용자]** | "봐야 할 게 있음" | `ASK` 또는 `NEW`가 하나라도 있음 | 둘 다 없어짐 |
| `ASK` 꼬리 (주황 글자, 대기 개수 바로 뒤) | 나를 기다리는 세션 있음 | 대기 세션 ≥ 1 (4.2의 평문 질문 보정 포함) | 대기가 실제로 해소됨 (`status`가 `waiting`에서 벗어남, 평문 질문은 다음 사용자 입력). **이동·클릭만으로는 안 꺼짐 [사용자]** |
| `NEW` 꼬리 (초록 글자, 완료 개수 바로 뒤) **[사용자]** | 확인 안 한 완료 있음 | 미확인 완료 세션 ≥ 1 | 모든 완료를 확인함 |

- 상태 점은 깜빡이지 않음 — 움직이는 요소는 테두리 하나뿐 **[판단, 사용자에게 추천으로 제시]**
- 테두리 색은 상태 색(파랑·주황·초록)과 겹치지 않는 시스템 글자색(label color) — 다크 모드는 흰빛, 라이트 모드는 먹색(거의 검정)으로 자동 반전. 두께 1.5px로 사방 균일 **[사용자]** (시안: `light-border.html` A안)
- 대기와 미확인 완료가 동시에 있어도 충돌 없음: 테두리는 하나의 뜻, 무엇인지는 글자가 말함 **[사용자의 아이디어]**
- 완료 순간 별도 애니메이션 없음 (`NEW`가 붙고 테두리가 돌기 시작하는 것이 알림)

**미확인 완료(`NEW`) 규칙**
- 플로팅이 켜져 있는 동안 세션의 **표시 상태**가 진행/대기 → 완료로 바뀌면 그 세션을 미확인으로 표시. 세션 파일 원본이 `idle`로 바뀌는 것만으로는 켜지 않음 (4.2 보정으로 자동 재개 세션은 진행, 평문 질문은 대기로 남으므로 NEW가 주기마다 반복되지 않음)
- 앱 시작 시 이미 `idle`인 세션은 확인한 것으로 간주 (시작하자마자 NEW가 쏟아지지 않게) **[판단]**
- 세션 단위로 해제. 완료가 2개 미확인이면 둘 다 확인해야 꼬리가 사라짐
- 해제 조건:
  1. 플로팅에서 그 세션 줄을 클릭해 이동 **[사용자]**
  2. Ghostty·Terminal.app·iTerm2에서 사용자가 그 탭을 직접 선택 — 그 앱의 미확인이 있고 그 앱이 맨 앞에 있을 때만 수 초 간격으로 선택된 탭 확인(Ghostty는 `focused terminal`, Terminal.app·iTerm2는 선택된 탭의 tty) **[판단]**
     - 제어 권한이 거절되면 그 앱의 확인은 그 앱 세션으로 이동에 성공할 때까지 멈춤 (R38·R50). 백그라운드 세션이나 붙은 클라이언트 없는 tmux 세션을 Ghostty 새 탭으로 연 것은 여기서 말하는 이동에 들지 않아, Ghostty 확인이 다시 켜지지 않음 — 알려진 한계
  3. 그 세션이 다시 `busy`가 됨 (새 지시를 넣음)
  4. 펼치기만 해서는 해제 안 됨 **[판단]** — 펼치자마자 사라지면 NEW를 볼 수 없음
- Orca에서 직접 탭을 옮긴 경우는 감지 못함 (Orca는 작업 폴더별 활성 탭만 알려주고, 화면에 보이는 작업 폴더는 모름) → 3번으로 해제됨
- tmux 안에서 직접 pane을 옮긴 경우도 감지 못함 (4.4) → 3번으로 해제됨

### 4.7 화면 — 펼친 상태 **[사용자]**

시안: `expanded-layout.html` (v3)

- 폭 약 260px. 묶음 순서: **내 응답 대기 → 진행 중 → 완료**, 묶음 머리에 개수. **모든 묶음 항상 펼침** (완료도 접지 않음) **[사용자]**
- 각 세션은 두 줄 카드: 1행 제목, 2행 `앱 · 폴더 · 대기 사유`, 오른쪽 경과시간
- 대기 줄은 옅은 주황 배경
- 미확인 완료 줄: 제목 굵게 + `NEW` 배지 **[사용자]**. 확인한 완료 줄은 살짝 흐리게 **[판단]**
- 응답 없음 의심 세션: 회색 점 + 2행에 "N분째 활동 없음"
- 줄 클릭 → 4.4의 이동. v1.2부터 답할 수 있거나 읽을 수 있는 대기 줄(질문 창·본문 질문·승인 대기)은 답장 화면을 열고, ⌘+클릭은 바로 이동 (v1.2 설계 4.7)

### 4.8 창 동작 **[판단]**

- `NSPanel` 비활성(non-activating) 패널, 항상 위
- **어느 데스크탑(Space)으로 넘어가도 같은 자리에 고정 노출 [사용자]**: 모든 Space에 동시에 존재하고, 데스크탑을 옆으로 넘기는 애니메이션 중에도 같이 밀려가지 않으며, 전체화면 앱 위에도 보임 (`canJoinAllSpaces` + `stationary` + `fullScreenAuxiliary`). 위치는 화면 좌표 하나로 저장해 어느 데스크탑에서든 동일
  - 실측 한계 (R45): 전환이 끝나면 같은 자리에 있지만, 넘어가는 애니메이션 동안은 이전 데스크탑과 같이 밀려 나감. 창 레벨을 statusBar·popUpMenu·screenSaver로 올려도 같아 공개 API로는 막을 수 없음 → v1 수용
- Dock 아이콘 없음(`LSUIElement`). 메뉴바 아이콘: 종료, 로그인 시 실행, 위치 초기화, 가장자리 대비(4.10)
- 마우스를 올리면 펼침, 벗어나면 짧은 지연 후 접힘
- **마우스로 끌어 위치 이동 [사용자]**: 접힌 알약은 어디서든, 펼친 패널은 맨 위 요약 줄에서 끎. 끄는 동안 펼침·접힘 전환과 줄 클릭 이동은 일어나지 않음. 펼친 상태에서 옮기면 접힐 때 옮긴 자리에서 알약으로 접힘. 놓은 위치 기억(화면 밖이면 보이는 곳으로 복귀)
- **펼침·접힘은 자연스럽고 부드럽게 [사용자]**: 창 크기는 애니메이션하지 않고 한 번에 바꾸며 움직임은 SwiftUI 안에서만 처리. 내용은 고정 모서리에 붙여 창이 커져도 알약이 화면상 제자리. 펼칠 때 유리가 먼저 커지고 목록이 뒤따라 페이드인, 접을 때 목록이 먼저 사라진 뒤 유리가 줄어듦. 펼치기 전에 목표 높이를 계산해 한 번에 도달(출렁임 없음). 튕김이 거의 없는 spring. 수치는 조정하기 쉽게 상수로 모음
- hover·펼치기·드래그는 다른 앱의 포커스를 뺏지 않음
  - 예외 (v1.2): 답장 화면이 열린 동안만 패널(옆 카드 배치면 카드)이 키 입력을 받음. 앱은 활성화하지 않고, 닫으면 열기 전 앱이 키 입력을 되찾음 (v1.2 설계 4.7, 실측 S4)

### 4.9 갱신 방식 **[판단]**

- `~/.claude/sessions/` 디렉터리 변경 감시(FSEvents/DispatchSource) + 저빈도 폴링 보조 (pid 생존·경과시간 갱신용)
- `claude agents --json`을 주기적으로 실행하지 않음 (매번 큰 바이너리를 띄우는 비용)
- 터미널 AppleScript(Ghostty·Terminal.app·iTerm2)는 클릭 이동 시와 4.6의 미확인 해제 확인 시에만 호출. 해제 확인은 맨 앞 앱의 것 하나만 실행 (R49)
- tmux CLI는 클릭 이동 시에만 호출
- 목표: 변화 없을 때 CPU 사실상 0

### 4.10 시각 디자인 — macOS 26 Liquid Glass 문법 **[사용자: iOS·macOS스러운 디자인]**

시안: `apple-style.html` (라이트·다크 나란히, 뒤에 창·배경을 깔아 유리 질감 확인). 4.5~4.7의 색·모양 묘사보다 이 절이 우선.

| 항목 | 결정 | 근거 |
|---|---|---|
| 재질 | 바깥 껍데기 하나에만 Liquid Glass `regular` (`glassEffect`). 안쪽 줄에는 유리를 겹치지 않고 반투명 채움으로 강조 | HIG Materials: 유리는 콘텐츠 위에 뜬 조작·탐색 레이어용, "Use Liquid Glass effects sparingly", 텍스트가 많은 요소는 regular |
| 모양과 전환 | 접힘 = 캡슐(유리 기본 모양), 펼침 = 둥근 사각형(반경 22pt 출발점). `GlassEffectContainer` + `glassEffectID`로 같은 유리가 늘어나며 모양이 바뀌는 morph | SwiftUI "Applying Liquid Glass to custom views" |
| 펼침 구성 | 펼친 패널 맨 위에 접힌 알약과 같은 요약 줄을 그대로 둠 | HIG Live Activities: 펼침은 접힘의 확대판, 요소의 상대 위치 유지 |
| 여백·모서리 | 동심 모서리: 패널 22 / 안쪽 여백 6 / 줄 강조 16. 구분선 없이 간격과 소제목으로 묶음. 패널 높이는 내용에 맞춰 가변 | HIG Live Activities: "consistent margins and concentric placement", 높이 동적 조정 |
| 색 | 시스템 색만 사용: `systemBlue`·`systemOrange`·`systemGreen`·`systemGray` (라이트·다크 자동). 색은 상태 표시에만. 라이트 모드의 `ASK` 주황 글자는 대비가 낮으므로 더 진한 톤으로 보정 | HIG Color: 색은 "status indicators"처럼 강조가 필요한 곳에만 |
| 글자 | 시스템 폰트(SF Pro, 한글은 시스템 대체). 개수 12.5pt Semibold·고정폭 숫자, 제목 13pt Medium, 보조 11pt `secondaryLabel`, 시간 `tertiaryLabel`·고정폭 숫자. 개수가 바뀌면 숫자 굴림 전환(`.contentTransition(.numericText())`) | HIG Live Activities: Medium 이상 굵기, 숫자 전환 |
| 테두리 신호 | 평소엔 유리 가장자리의 얇은 밝은 선(hairline)만. 주의가 필요하면 글자색 빛(다크 흰빛 / 라이트 먹색)이 그 선을 따라 돎. Dynamic Island 테두리(key line)를 macOS로 옮긴 것 | HIG Live Activities: key line, HIG Color: 유리 위 기호는 배경이 밝으면 어둡게·어두우면 밝게 |
| 가장자리 대비 **[사용자: 권장안 채택, 2026-10-19]** | 유리는 뒤 화면 밝기를 보고 스스로 밝아지거나 어두워져(시스템 모드와 별개), 흰 화면 위 밝은 알약·어두운 에디터 위 어두운 알약은 윤곽이 사라짐. 메뉴에서 고름: **윤곽선(기본값)** = 유리 톤의 반대 톤 1pt 선을 가장자리에 두름 / 뒤 화면과 반대 = 유리 위에 반대 톤 면을 깔고 글자·테두리 빛도 그 면에 맞추며, 빛은 가장자리에서 2pt 안쪽 / 유리 그대로 | 실측(R54~R56): 윤곽선은 배경 7가지 모두에서 윤곽이 남음. 반대 모드는 단색 배경에서 가장 눈에 띄지만, 글자가 많은 흰 화면에서는 유리가 어두워져 밝은 알약이 흰 화면 위에 놓임 |
| 앱 표시 | 2행의 앱 이름 대신 실제 앱 아이콘 12pt (`NSWorkspace` 아이콘) | macOS 관례 (Finder·Spotlight) |
| 움직임 | 스프링 기반 전환. 회전 외 애니메이션은 2초 이내 | HIG Live Activities: 애니메이션 최대 2초 |
| 접근성 | 동작 줄이기(Reduce Motion): 회전 대신 밝기를 올린 정지 테두리. 투명도 줄이기·대비 증가: 시스템 유리 대응을 확인하고, 깨지면 불투명 재질로 대체 | HIG Materials: 시스템 설정에 따라 유리 모양이 바뀜 |

- 라이트 모드에서 흰빛이 안 보이던 문제는 먹색 전환으로 해결 **[사용자: A안 채택]**. 색은 고정 값이 아니라 시스템 글자색을 따라야 모드 전환·대비 증가 설정에 자동 대응함
- 대상 OS: macOS 26 (사용자 머신 26.4.1). 2차 출처 기준으로 WWDC26에서 macOS 27용 Liquid Glass 개편이 발표됨. 27로 올리면 모양이 달라질 수 있으나 API는 시스템 유리를 쓰므로 따라감
- 참고 자료
  - HIG Materials: https://developer.apple.com/design/human-interface-guidelines/materials
  - HIG Live Activities: https://developer.apple.com/design/human-interface-guidelines/live-activities
  - HIG Color (Liquid Glass color): https://developer.apple.com/design/human-interface-guidelines/color
  - SwiftUI Applying Liquid Glass to custom views: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
  - SwiftUI GlassEffectContainer: https://developer.apple.com/documentation/swiftui/glasseffectcontainer
  - 비슷한 Mac 앱(Dynamic Island 계열): NotchNook, Alcove, Boring Notch. MacStories 리뷰는 "노치 모양보다 떠 있는 섬"을 제안했고, 이 설계의 떠 있는 알약과 같은 방향

## 5. 검증 상태

| 항목 | 상태 | 근거 |
|---|---|---|
| 세션 파일의 필드·`busy`/`idle` 기록 | ✅ 확인 | 실제 파일 7개 열람 |
| `waiting` + `waitingFor`가 파일에 기록됨 (질문 도구) | ✅ 확인 | AskUserQuestion 중 `waiting` / `input needed` 기록, 답 후 `busy` 복귀 (폴링 로그) |
| 권한 다이얼로그 대기도 `waiting`으로 기록됨 | ✅ 확인 | 권한 확인 모드 세션(분리된 tmux, 2.1.302)에서 셸 명령 승인 창이 떠 있는 동안 `waiting` / `waitingFor: "permission prompt"` → 판정 대기·승인 대기, 승인 뒤 완료. hook 폴백 불필요. 화면(2026-10-19): 알약 주황 + `ASK`, 줄 사유 "승인 대기" |
| 평문 질문 판정 휴리스틱의 정확도 | ✅ 확인 | 4.2 표본 transcript의 질문 29/29 검출 (Task 3 실측). URL·`?.` 때문에 생기는 오탐 약 2%는 감수 |
| 자동 재개 흔적의 transcript 레코드 형식 | ✅ 확인 | 실제 transcript 6개(읽기 전용)의 `ScheduleWakeup` 10회 — 입력 `{delaySeconds, noop, prompt, reason}`, 취소는 `{stop: true}`, `CronCreate` 5회 `{cron, prompt, recurring: true}`, `CronDelete` 5회 `{id}`. 예약 실행은 `scheduledTaskId`·`scheduledFireId`가 붙은 `user` 레코드(+ `system` `scheduled_task_fire`)로 들어옴. 각 턴 끝 20곳에서 잘라 `TranscriptReader`로 읽은 `pendingWake`가 규칙 예상과 20/20 일치 → 규칙·fixture 변경 없음 |
| 자동 재개 세션이 진행으로 판정되고 `NEW`가 안 켜짐 | ✅ 확인 | 실제 세션(분리된 tmux)에서 판정만 확인: `/loop 5m`(cron)·명시적 `ScheduleWakeup` → 진행, 루프 취소 → 완료. `--resume` 뒤 되살아난 cron → 진행(수정 전에는 완료로 잘못 판정), 한 번짜리 cron이 울린 뒤 → 완료(수정 전에는 진행으로 굳음). 예약 깨우기는 resume 뒤 울리지 않음 → 완료. 화면(2026-10-19): `/loop 5m` 동안 알약 파랑·`NEW` 없음, 루프 취소 뒤 완료 + `NEW` |
| 질문 도구 대기의 판정 | ✅ 확인 | AskUserQuestion이 떠 있는 동안 `input needed` → 대기·질문, 답한 뒤 완료. 화면(2026-10-19): 세션 파일이 바뀐 뒤 0.17초 안에 `ASK` + 테두리 회전, 답하면 꺼짐 |
| Ghostty AppleScript 열거·`focus` | ✅ 확인 | 다른 탭으로 이동 후 복귀 실측. Task 11: 열거 3개 0.36초, `focused terminal` 0.16초, 지금 선택된 탭을 그 세션과 정확히 짝지음(읽기 전용) |
| Claude의 탭 제목 형식 `"<기호> <ai-title>"` | ✅ 확인 | 실제 탭 제목 + 바이너리 코드 |
| transcript의 `ai-title` 레코드 | ✅ 확인 | 현재 세션 jsonl |
| `ps -E`로 `TERM_PROGRAM`·`ORCA_TAB_ID`·`ORCA_PANE_KEY` 조회 | ✅ 확인 | Orca 세션·Ghostty 세션 각각 |
| `orca terminal list --json`의 `tabId`·`leafId`·`handle` | ✅ 확인 | 실제 출력 |
| `orca terminal list --json --limit 1000`이 전체 목록을 줌 | ✅ 확인 | `--limit` 옵션 존재(`--help`), 실제 출력 total 8 · truncated false, 살아 있는 Orca 세션의 `handle`을 찾음 |
| `orca terminal switch`로 실제 포커스 이동 + Orca 앞으로 | ✅ 확인 | 2026-10-19: 브라우저가 앞일 때 줄 클릭 → Orca가 앞으로, 그 탭이 보임, 0.69초, 새 창 없음. 첫 클릭은 아직 열지 않은 워크트리라 목록의 tab·leaf가 임시 값이어서 `terminalNotFound` → handle 우선 판정으로 고침(R43) |
| 별도 앱에서 Ghostty로 AppleScript 보낼 때 권한(TCC) 요청 흐름 | 사용자 확인 대기 | `NSAppleEventsUsageDescription` 들어 있음. 첫 클릭 또는 첫 미확인 감시에서 승인 창 1회 예상. 실측 도구는 Ghostty 안에서 실행해 Ghostty가 보낸 것으로 처리되어 승인 창이 없었음. ad-hoc 서명이라 다시 빌드하면 다시 물을 수 있음. 거부되면(-1743/-1744) 직접 선택 감시는 다음 이동 성공까지 멈춤. 2026-10-19: 다시 빌드한 앱의 첫 이동이 클릭 뒤 3.5초 걸렸고(이후는 0.5초 안팎) 그 사이 커서가 움직임 → 승인 창에 사용자가 답했을 가능성이 있으나 화면으로 못 봄 |
| 백그라운드 세션 `claude attach <jobId>`를 Ghostty 새 탭으로 여는 것 | 사용자 확인 대기 | 스크립트가 Ghostty 사전으로 컴파일됨(`osacompile`), `surface configuration`에 `initial input`·`command` 속성 존재(sdef). 새 탭을 여는 실행은 하지 않음 |
| 기타 터미널 폴백: 부모 프로세스 순회 | ✅ 확인 | Ghostty는 root 소유 `/usr/bin/login`을 거쳐 셸을 띄움(실측, Terminal.app도 기본 설정에서 login을 거침) → `PROC_PIDTBSDINFO`가 EPERM이라 순회가 login에서 끊기던 것을 `PROC_PIDT_SHORTBSDINFO`로 고침. 수정 뒤 셸 → login → Ghostty, Orca 세션 → 보조 프로세스 → Orca까지 도달하고 첫 일반 앱을 고름 |
| 기타 터미널 폴백: 찾은 앱을 앞으로 올림 | 사용자 확인 대기 | Cursor에서 확인 예정(아직 실행 안 함). Terminal.app은 v1.1에서 탭 이동으로 바뀜. 갈 곳이 없는 tmux 안 세션은 2026-10-19에 확인: 클릭하면 `navigate failed`(경고음 경로), 앞 앱 그대로, `NEW` 유지. macOS 14+ 협조적 활성화가 비활성 앱의 `activate()`를 무시할 수 있어 LaunchServices 경로로 엶 |
| 미확인 Ghostty 감시의 실행 조건 | ✅ 확인 | 합성 세션으로 실측: 미확인 Ghostty 세션이 생기면 감시 시작, 없어지면 멈춤(Ghostty 밖 미확인만 남으면 멈춤). Ghostty가 맨 앞이 아닐 때 5주기 동안 osascript 0회, CPU 18초에 0.01초 |
| Ghostty에서 그 탭을 직접 고르면 3초 안에 `NEW` 해제 | ✅ 확인 | 2026-10-19: Ghostty가 맨 앞일 때 탭을 고른 뒤 3.2초에 해제(측정 도구 실행 시간 약 0.3초 포함, 감시 주기 3초). 해제 뒤 알약 폭이 줄고 테두리 빛이 꺼짐 |
| 세션 줄 클릭 → 그 터미널로 이동 + `NEW` 해제, 실패면 경고음 + `NEW` 유지 | ✅ 확인 | 2026-10-19: 브라우저가 앞일 때 Ghostty 줄 클릭 → 0.48~0.68초에 그 탭으로 이동, `NEW` 해제. 실패 경로는 tmux 안 세션으로 확인(`NEW` 유지). 해제 조건은 명령 성공 뒤 1초 안에 기대한 앱(Ghostty·Orca·폴백이 고른 앱)이 맨 앞에 오는 것이고, 30초 제한 시간과 `ExpectedFrontmost` 규칙은 단위 테스트로 확인 |
| 세션 상태 `shell` | ✅ 확인 (R44) | 2.1.301 세션에서 관찰. 실행 파일 코드로 의미 확인(백그라운드 셸이 남은 `idle`). 고친 뒤 실제 세션이 회색에서 진행으로 바뀜 |
| 창 동작: 끌기·누르고 있기·위치 저장·화면 끝·포커스 유지·메뉴 | ✅ 확인 | 2026-10-19 합성 입력(`cliclick`)으로: 접힌 알약과 펼친 요약 줄 끌기 중 펼침·접힘 없음, 0.6초 눌러도 안 펼쳐지고 떼면 펼쳐짐, 끈 뒤 종료·끈 직후 종료 모두 같은 자리로 복원, 화면 끝 너머에 두고 접으면 안쪽 끝에 붙음, 다른 앱에 입력하는 중에 알약을 누르거나 끌어도 입력이 그 앱으로 감, `위치 초기화`·`Agent Float 종료` 동작. 합성 입력에서는 끌기가 시작되기까지 약 0.5초가 걸려 그 사이 움직임은 반영 안 됨(실제 마우스에서는 사용자 확인) |
| 데스크탑 전환 중 고정 | ❌ 한계 (R45) | 전환 뒤에는 같은 자리, 전환 애니메이션 동안은 같이 밀려 나감. 레벨 4종 비교로 공개 API 한계 확인 |
| 외부 창 관리 앱과의 간섭 | 참고 | 알약을 화면 아래 끝까지 끌자 Magnet이 화면의 1/3 칸 위치로 옮김. 앱 결함 아님(7장) |
| Terminal.app 탭 이동·직접 선택 감지 (v1.1) | ✅ 확인 | 2026-10-19: 승인 창(새 문구) 허용 뒤, 다른 탭을 보는 중 완료 → `NEW` 유지, 브라우저가 앞일 때 줄 클릭 → 0.23초에 그 탭으로·`NEW` 해제, Ctrl+Tab으로 탭 직접 선택 → 2.51초에 해제 |
| iTerm2 탭 이동·직접 선택 감지 (v1.1) | ✅ 확인 | 2026-10-19 (iTerm2 3.7.4): 가린 탭에서 완료 → `NEW` 유지, ⌘2로 탭 직접 선택 → 0.46초에 해제, 줄 클릭 → 0.28초에 그 탭으로. 보이는 탭에서 끝난 세션은 바로 확인 처리 |
| tmux pane 이동 (v1.1) | ✅ 확인 | 2026-10-19 (tmux 3.6a): Terminal 안 → tmux 창 전환 + Terminal 탭까지, Ghostty 안 → tmux 창 전환 + Ghostty 앱까지(탭은 그대로), 클라이언트 없는 서버 → Ghostty 새 탭에서 attach 후 그 창이 보임. 다른 세션을 보는 클라이언트만 있으면 가장 최근 클라이언트를 옮김 |
| 승인 창에 답이 없을 때 | 참고 | 탭 확인 명령이 약 2분 뒤 AppleEvent 시간 초과(-1712)로 끝나고 감시 간격이 최대 60초까지 늘어남. 허용 뒤 다음 주기에 정상 |
| 가장자리 대비 3모드 (유리 그대로·윤곽선·반대) | ✅ 확인 | 2026-10-19 가짜 세션 시험 빌드를 흰색·밝은 회색·중간 회색·어두운 에디터·검정·글자 깔린 흰/어두운 화면 위에 두고 접힘·펼침 캡처. 유리 톤 변화는 세 모드에서 같은 순서(칠한 면이 유리 판단을 흔들지 않음), 0.3초 간격 8번 전환에 톤 6번 바뀜 |

## 6. 빌더 재량

- 코드 구조, 파일 분할, 테스트 범위
- 애니메이션 속도·곡선, 정확한 색 값, 폰트 크기, 여백
- 응답 없음 의심 임계값, 폴링 간격, hover 지연 시간
- 묶음 안 정렬 순서 (출발점: 대기는 오래 기다린 순, 나머지는 최근 변경 순)
- 펼침 방향 (화면 가장자리 위치에 따라)
- Ghostty 제목 매칭이 모호할 때의 세부 처리
- 알 수 없는 `waitingFor` 값의 문구
- 버전업으로 세션 파일 형식이 바뀌었을 때의 방어 수준 (최소: 크래시하지 않고 "알 수 없음"으로 표시)

## 7. 로드맵 (v1 이후) **[사용자: 차차 추가]**

v1 구조(`TerminalNavigator`·`AgentProvider` 등록 방식)에 구현체만 더하는 항목들. 정확도는 조사 전 추정.

| 항목 | 방식 (추정) | 정확도 |
|---|---|---|
| Cursor·VS Code 내장 터미널 | 외부에서 터미널 탭을 고르는 API 없음 → 앱(창) 활성화가 한계 | 앱 단위 |
| ~~플로팅에서 특정 세션에 간단한 메시지 보내기~~ **[사용자]** | v1.2에서 구현 → `2026-10-23-agent-float-v1.2-reply-design.md`. 대기 중인 질문 창·본문 질문에 터미널 키 입력으로 답함(`messagingSocketPath`는 다른 세션 메시지로 들어가 쓰지 않음) | tmux 전부, Orca·Ghostty는 질문 창만(본문 질문은 보기만, R57·R64), Terminal.app·iTerm2는 보기만 |
| 다른 AI 에이전트 (Gemini, cursor-agent, Codex 등) | 에이전트별 hook이 4.0의 "외부가 써 주는 상태 디렉터리"에 상태 기록 → 공통 provider가 읽음 | 에이전트별 hook 이벤트 지원 범위에 따름 |
| 외부 창 관리 앱(Magnet 등)의 칸 붙이기에서 빼기 | 창 관리 앱은 손쉬운 사용 API로 창을 다루므로, 패널을 일반 창으로 보이지 않게 하는 방법(접근성 역할 조정 등)을 조사 | 앱마다 다름 (2026-10-19 Magnet 간섭 실측) |
| 데스크탑 전환 애니메이션 중에도 고정 | 공개 API의 창 레벨로는 불가(R45). 다른 공개 경로가 있는지 조사, 사적 API는 쓰지 않음 | 미정 |
| WezTerm 정확한 pane 이동 | 환경변수 `WEZTERM_PANE` + `wezterm cli activate-pane --pane-id` | pane 단위 정확 |
| cmux | CLI·소켓 API의 `pane.focus`·`window.focus` (공식 문서 확인 필요) | pane 단위 정확(추정) |
| kitty | `kitten @ focus-window --match id:<KITTY_WINDOW_ID>`. 사용자가 원격 제어를 켜야 함 | 켜면 창 단위 정확 |
| iTerm2 tmux 통합(`tmux -CC`) | 제어 모드 클라이언트의 tty는 `tmux -CC`를 실행한 탭의 것이라, 지금은 tmux 창이 열린 탭이 아니라 그 탭으로 갈 수 있음(미실측). iTerm2 쪽에서 tmux 창과 탭의 짝을 얻는 방법 조사 | 미정 |
| tmux 안의 직접 선택 감지, Ghostty 안 tmux의 바깥 탭 | 클라이언트가 보는 pane을 주기적으로 확인. Ghostty 탭은 tmux 제목(`set-titles`)과 탭 제목을 맞추는 방법을 조사 | 미정 |
