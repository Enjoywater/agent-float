# Agent Float v1 — 구현 중 결정 기록

Subagent-driven 구현 중 컨트롤러가 사용자 대신 내린 판단. 각 줄: 결정 — 이유 — 틀렸을 때 비용.

- Ruling R1: 별도 worktree 없이 같은 저장소의 `feat/v1-floating-widget` 브랜치에서 작업 — 새 개인 저장소라 main 보호만 되면 충분하고, ~ 세션에서 worktree 격리가 불안정했던 실측 기록이 있음 — 틀리면: 브랜치 하나 정리하면 끝
- Ruling R2: 펼친 패널 폭 280 (plan) — spec 4.10이 4.5~4.7보다 우선이고 기준 시안 apple-style이 286 — 틀리면: 상수 하나 수정
- Ruling R3: 환경변수는 `ps -E` 대신 `sysctl KERN_PROCARGS2` (plan) — 같은 데이터, 상시 앱에서 프로세스 생성 비용 제거 — 틀리면: 일부 프로세스에서 앱 판별이 폴백으로 떨어짐
- Ruling R4: `ClaudeCodeProvider.snapshot`은 sessions 디렉터리가 없으면 `[]`(던지지 않음), 디렉터리 열거 자체가 실패할 때만 던짐 — 처음 설치한 머신에서 정상 상태를 오류로 보지 않기 위함 — 틀리면: 오류 표시가 늦어짐
- Ruling R5: GUI·사람 손이 필요한 수동 확인은 자동 대체로 수행: 디버그 환경변수 `AGENT_FLOAT_CLAUDE_HOME`(합성 sessions/projects + `sleep` 프로세스 pid로 실제 provider 경로 검증), `AGENT_FLOAT_REDUCE_MOTION=1`, `screencapture`로 스크린샷. 사용자 시스템 설정 변경·로그인 항목 실제 등록·새 Claude 세션 생성은 금지. TCC 승인 클릭, 패널 끌기, 실제 Orca/Terminal.app/Cursor/bg/loop/권한 세션 확인은 최종 보고의 "사용자 확인 체크리스트"로 넘김 — 사용자 머신 상태를 바꾸지 않고 연속 실행하기 위함 — 틀리면: 해당 동작은 사용자가 확인할 때까지 미검증
- Ruling R6: 앱을 띄워 확인한 뒤에는 반드시 `pkill -x AgentFloat`로 종료 — 사용자 화면에 검증용 패널이 남지 않게
- Ruling R7: 최종 전체 리뷰 모델은 fable(가장 강한 모델), 구현자는 Task 성격별 sonnet/opus — Model Selection 규칙
- Ruling R8: Package.swift는 tools 6.0 + `.macOS("26.0")` 유지 (plan의 `.macOS(.v26)`은 PackageDescription 6.2부터) — 배포 대상은 동일하고 제약의 의도(macOS 26 하한)를 지킴 — 틀리면: tools-version 한 줄 수정
- Ruling R9: 커밋 공동 작성자 줄은 실제 작업한 모델 이름을 따름 (구현자 sonnet이면 Sonnet 5.5) — 출처 표기의 정확성이 목적 — 틀리면: 표기만 다름
- Ruling R10: `<command-name>` 레코드라도 바로 다음 user 레코드가 `<local-command-stdout>`이면 사용자 입력에서 제외 (로컬 명령은 Claude가 응답하는 턴이 아님, brief 의도) — 틀리면: /effort 류 입력이 평문 질문 ASK를 잘못 지움
- Ruling R11: 마지막 사용자 입력 이후 마지막 ScheduleWakeup이 stop:true면 pendingWake=false (stop은 예약 취소) — 틀리면: 루프를 끝낸 세션이 진행 중으로 남음
- Ruling R12: 출처 문단 판정은 좁게(`참고:` 라벨 단독·빈 뒤·URL일 때만) — `참고로 ~ 알려줘`를 버리지 않기 위함 — 틀리면: 일부 출처 문단 뒤 질문을 놓침
- Ruling R13: 마지막 문단에 `주시면`·`해 주면`·`해주면`·`알려주면`이 있으면 질문으로 봄 (조건부 대기 "~해 주시면 진행하겠습니다"는 사실상 사용자 대기, 사용자가 놓침보다 오탐을 택함) — 틀리면: 일부 완료 보고가 대기로 보임
- Ruling R14: brief 밖 어미(`주세요`·`부탁드립니다`·`해달라`·`알려달라`·`인가요`)와 끝 기호(`~`·이모지) 제거 추가 수용 — 실측 누락 190건 해소, spec 의도와 일치 — 틀리면: 오탐 소폭 증가
- Ruling R15: URL·`?.` 때문에 생기는 오탐(약 2%)은 그대로 둠 — 사용자가 오탐 감수 — 틀리면: 드물게 완료가 대기로 보임
- Ruling R16: 같은 sessionId의 살아 있는 파일이 둘 이상이면 statusUpdatedAt 최신(동률은 큰 pid) 하나만 — SwiftUI ForEach id 충돌 방지 — 틀리면: 드물게 다른 터미널의 같은 세션이 목록에서 빠짐
- Ruling R17: 제목 캐시 — provider가 sessionId별 마지막 aiTitle을 기억하고, 이미 알면 reader의 앞부분 8MB 훑기를 건너뜀(reader에 `scanHeadForTitle: Bool = true` 인자 추가) — 바쁜 세션마다 5초마다 최대 8MB 읽기를 막음 — 틀리면: 제목 변경 반영이 끝부분에 새 ai-title이 찍힐 때까지 늦음
- Ruling R18: stale 판정의 마지막 활동 시각 = max(transcript mtime, `<projects>/<proj>/<sessionId>/subagents/` 안 파일들의 최신 mtime) — 서브에이전트·워크플로가 일하는 동안 부모 transcript가 조용해 회색으로 잘못 보이는 것 방지(실측: 이 세션 subagents/에 jsonl 28개). transcript가 임계값보다 오래됐을 때만 디렉터리를 봄 — 틀리면: 서브에이전트 산출물 위치가 바뀌면 다시 오탐
- Ruling R19: Orca인데 ORCA_PANE_KEY가 없거나 깨지면 앱 .orca + 위치 .application(pid:) (plan 문자 그대로는 .other("Orca")) — Orca 아이콘을 유지하고 앱 활성화 폴백으로 이동 가능 — 틀리면: 표시 라벨만 다름
- Ruling R20: snapshot은 한 곳에서 직렬로만 호출 (Task 10 AppModel 갱신을 직렬화) — provider가 느린 I/O 동안 잠금을 쥐고, store가 겹친 호출 시 오래된 결과를 나중에 저장할 수 있음 — 틀리면: 겹친 갱신에서 잠깐 이전 상태
- Ruling R21: done → unknown → done이면 미확인 상태 유지 (unknown은 "확인함"이 아님, unknown 동안은 done 키가 아니라 NEW만 잠시 꺼짐) — 틀리면: 일시적 파싱 실패 뒤 NEW가 다시 보임(원래 미확인이었으므로 무해)
- Ruling R22: 직전 상태가 unknown이면 그 전의 마지막 비-unknown 상태를 기준으로 전환 판정 (진행 → unknown → 완료도 NEW) — NEW를 놓치는 쪽이 더 나쁨 — 틀리면: 드물게 unknown 사이 전환에서 NEW가 하나 더 뜸
- Ruling R23: Task 11의 AppModel.activate는 navigate를 30초 타임아웃으로 감쌈(첫 실행 TCC 승인 대기 포함), 타임아웃이면 경고음 — runner 자체엔 타임아웃 없음 — 틀리면: 승인 창을 30초 넘게 두면 첫 클릭이 실패로 처리
- Ruling R24: activateOrca·activateFirstApp 클로저는 앱 쪽에서 메인 스레드로 넘겨 실행(메인이면 바로, 아니면 DispatchQueue.main.sync) — AppKit 호출은 메인 전용 — 틀리면: 없음(안전 쪽)
- Ruling R25: jobId 허용 문자 목록(영숫자·-·_) 추가 수용 — 셸에 타이핑되는 문자열이라 주입 방지 — 틀리면: 특이한 jobId 세션은 attach 불가
- Ruling R26: Orca 목록 호출에 `--limit 1000` 추가 (Task 11에서 Core Orca.swift 소폭 수정) — 기본 페이지 크기 미상, 현재 8개라 영향 없음(실측 total 8, truncated false) — 틀리면: 없음
- Ruling R23 보강: Task 11 타임아웃은 ProcessCommandRunner에 `withTaskCancellationHandler { process.terminate() }`를 넣어 취소가 실제로 osascript를 끝내게 한 뒤 구현 — 취소를 무시하면 TaskGroup 타임아웃이 무력 — 틀리면: 첫 클릭이 TCC 대기 중 멈춤
- Ruling R27 (Task 10에 전달): 저장 위치는 "접힌 알약의 고정 모서리 점"(오른쪽 위 또는 왼쪽 위 + 어느 쪽인지)으로 저장하고, 펼침 setFrame으로 생긴 didMove는 저장하지 않거나 알약 좌표로 환산 — 펼친 프레임 원점이 저장돼 다음 실행에 위치가 튀는 것 방지, 폭이 달라져도 같은 모서리에 붙음 — 틀리면: 재실행 시 위치 어긋남
- Ruling R28 (Task 10에 전달): applicationWillTerminate에서 대기 중인 위치 저장을 즉시 flush — 끈 직후 ⌘Q 시 위치 유실 방지
- Ruling R29 (Task 10에 전달): 로그인 항목 상태 .requiresApproval이면 register() 재호출 대신 설정 열기·해제 가능하게 분기
- Ruling R30: morph는 if/else 두 뷰 대신 유리 하나의 크기·모서리 반경을 애니메이션 — 같은 glassEffectID의 if/else가 즉시 점프해서. spec의 "같은 유리가 늘어나며 모양이 바뀜"과 일치 — 틀리면: Apple 기본 morph 질감과 약간 다를 수 있음
- Ruling R31: 테두리 회전은 Core Animation으로 (SwiftUI 회전은 상시 5~10% CPU) — 실패 조건 "가만히 있을 때 CPU 점유" 방지 — 틀리면: 없음
- Ruling R32: 알약이 오른쪽에 있으면 펼친 요약 줄을 오른쪽 정렬 — 펼침 중에 숫자가 제자리(Live Activities "상대 위치 유지") — 틀리면: 시안과 정렬이 반대(한 줄 수정)
- Ruling R33: 로그인 항목 승인 대기 상태의 해제는 Option-클릭으로 (새 메뉴 문구 없이) — 드문 경우라 — 틀리면: 사용자가 해제 방법을 못 찾음 → 체크리스트에 안내
- Ruling R34: 묶음 머리에 개수 표시 (예: "내 응답 대기 1") — spec 4.7이 기준(brief·apple 시안엔 없음) — 틀리면: 한 줄 제거
- Ruling R35: 마우스 버튼을 누르는 동안엔 펼침 예약 취소·펼치지 않음, 끌기 시작은 willMoveNotification(또는 mouse-down)으로 판정 — 사용자 요구 "마우스로 움직이기"에서 접힌 알약을 끌 때 먼저 펼쳐지는 문제 — 틀리면: 끌기 중 펼침이 늦게 일어남
- Ruling R36: 앱 활성화는 NSRunningApplication.activate() 대신 LaunchServices 경로(NSWorkspace.openApplication(at:configuration: activates=true))로 — macOS 14+ 협조적 활성화에서 비활성 앱의 activate 요청이 무시될 수 있음 — 틀리면: 여전히 앞으로 안 올 수 있음(R37이 NEW 오해제를 막음)
- Ruling R37: NEW 해제는 이동 후 1초 안에 대상 앱이 실제 맨 앞(frontmostApplication)이 됐을 때만 — 아무것도 안 왔는데 NEW만 꺼지는 것 방지 — 틀리면: 느린 앱 전환에서 NEW가 남아 다시 클릭 필요
- Ruling R38: Ghostty 자동화 권한 거부(-1743 등) 오류가 나면 직접 선택 감지 폴링을 멈추고 다음 성공적 이동 때 재개 — 3초마다 실패하는 osascript 반복 방지 — 틀리면: 권한 허용 직후 감지가 늦게 재개
- Ruling R39: spec 4.4의 "GUI 앱을 못 찾으면 아무 동작 없음"을 "경고음"으로 고침 (R23·plan의 "탭을 못 찾음 → 경고음"과 일치) — 최종 정리 때 문서 수정 — 틀리면: 문구만 다름
- Ruling R40: 최종 수정 일괄에 값싼 Minor 포함 — 더블클릭 가드, jobId 첫 글자 영숫자, AppIcons TERM_PROGRAM→번들 매핑(Apple_Terminal·vscode), DirectoryWatcher를 .json만 감시, @unchecked Sendable 제거, statusUpdatedAt 없을 때 첫 관찰 시각 캐시 — 나머지 Minor는 유지(ledger 그대로) — 틀리면: 범위가 약간 넓어짐
- 최종 재검토의 잔여 경미 지적(tool_use마다 timestamp 재파싱, ProcStart 2회 파싱, resume 직후 읽기 실패 시 한 번의 유령 대기, 취소 시 busy loop, .json 하드코딩, resume 후 cron 유지 미확인): 보류 — 모두 경미·자가 복구, v1 병합 차단 아님 (cron은 체크리스트 36 → R41에서 실측·수정)

## 사용자 확인 단계 (2026-10-17)

- Ruling R41: cron 판정을 실측에 맞게 고침 (36번에서 결함 2건 확인)
  - 실측(2.1.302): `--resume`하면 cron이 되살아나 다시 울림(kill 뒤에도, 종료 창의 "작업 중단" 뒤에도). 예약 깨우기는 resume 뒤 울리지 않음. 한 번짜리 cron은 울린 뒤 CronDelete 기록 없이 저절로 지워짐(`scheduled_task_fire`에 `taskId`)
  - 수정: cron만 `procStart` 제한에서 뺌. CronCreate 결과 문구로 id·반복 여부를 등록하고, `CronDelete {id}`는 그 id만, 한 번짜리는 울린 기록으로 지움. 반복은 등록 7일 뒤 만료(`cronLiveUntil`을 판정 쪽이 `now`와 비교). 예약 깨우기와 백그라운드 작업 제한은 그대로
  - 이유: 수정 전에는 resume 뒤 도는 루프가 완료+NEW로, 울린 뒤의 한 번짜리 cron이 진행으로 굳어 보였음. 하나만 지워도 전부 꺼지던 문제도 같이 해결됨
  - 틀리면: CronCreate 결과 문구가 바뀌면 cron 세션이 완료로 보임(진행으로 굳지는 않음 → 오래 남는 오표시 없음)
- Ruling R42: 사용자가 "가능한 부분은 시도"를 허락함 → R5의 "새 Claude 세션 생성 금지"를 풀고, 화면이 잠긴 동안 분리된 tmux 안에 haiku 세션(`--permission-mode default`, 이미 신뢰된 개인 폴더)을 띄워 체크리스트 15·16·17·36을 실측. 판정은 실제 `ClaudeCodeProvider`를 그대로 부르는 임시 도구(작업 공간 밖)로 확인하고, 화면이 필요한 항목은 잠금 해제를 기다림 — 화면 없이 확인할 수 있는 항목부터 끝내기 위함 — 틀리면: 판정만 확인됐고 알약 표시는 미확인으로 남음

## 화면 확인 단계 (2026-10-19)

- 진행 방식: 사용자가 자리에 있는 상태에서 `screencapture`·`cliclick`으로 화면을 직접 조작. 시험 세션은 Ghostty 새 탭 1개와 분리된 tmux 1개(둘 다 haiku, 이미 신뢰된 개인 폴더)만 쓰고 끝난 뒤 `/exit`로 닫음. 스크롤은 앱의 `AGENT_FLOAT_FAKE_SESSIONS=30`으로 확인
- Ruling R43: Orca 이동을 handle 우선으로 찾음 (체크리스트 6에서 결함 확인)
  - 실측(Orca 1.4.224): 아직 열지 않은 워크트리의 터미널은 `orca terminal list`에 `tabId`·`leafId`가 임시 값(`pty:…`)으로, `orphaned: true`로 나옴. 같은 터미널의 `handle`은 세션 프로세스의 `ORCA_TERMINAL_HANDLE`과 일치했고, `orca terminal switch --terminal <handle>`이 성공한 뒤로는 진짜 탭 id가 나옴
  - 수정: `TerminalLocator.orca`에 `handle`(기본 nil)을 더하고 provider가 `ORCA_TERMINAL_HANDLE`을 읽음. 일치 판정은 handle이 목록에 있으면 그것, 없으면 기존 tab·leaf
  - 이유: 수정 전에는 그런 세션 줄을 누르면 `terminalNotFound`로 경고음만 났음
  - 틀리면: handle이 다른 터미널을 가리키는 경우(관찰된 적 없음) 엉뚱한 탭으로 감. handle이 바뀌면 기존 tab·leaf 판정으로 돌아가므로 지금보다 나빠지지 않음
- Ruling R44: 세션 상태 `shell`을 진행으로 판정
  - 실측(2.1.301 세션에서 관찰, 2.1.303 실행 파일로 확인): 턴이 끝났는데 백그라운드 셸이 남아 있으면 세션 파일 `status`가 `idle` 대신 `shell`. 실행 파일 코드에 `idle && 백그라운드 셸 ? "shell" : status`가 있고, 다른 곳도 `idle`·`shell`을 같은 쉬는 상태로 다룸
  - 수정: `shell`은 `idle`과 같은 판정을 거치되 남은 일이 있는 것으로 봄 → 본문 질문으로 끝났으면 대기, 아니면 진행(정체 아님)
  - 이유: 수정 전에는 모르는 값이라 회색 "상태 확인 불가"로 보였음. 트랜스크립트 꼬리에서 셸 시작 기록이 밀려나도 이 값만으로 알 수 있음
  - 틀리면: 계속 도는 개발 서버 같은 셸이 있는 세션이 계속 진행으로 보임. 기존 "백그라운드 작업이 남은 idle → 진행" 규칙과 같은 성질이라 수용
- Ruling R45: 데스크탑 전환 애니메이션 중 고정은 v1에서 포기
  - 실측: 전환이 끝나면 새 데스크탑의 같은 자리에 있지만, 넘어가는 동안은 이전 데스크탑과 같이 밀려 나감. 시험 창으로 `floating`·`statusBar`·`popUpMenu`·`screenSaver` 레벨을 같은 collection behavior로 비교했더니 모두 같이 밀림
  - 이유: 공개 API의 창 레벨로는 막을 수 없음. 사용자 요구("모든 데스크탑에서 같은 자리")는 전환 뒤 위치로 충족되고 남는 것은 보이는 모습뿐. 사적 API(CGS)는 쓰지 않음
  - 틀리면: 전환 중 잠깐 사라졌다 나타나는 모습이 거슬리면 v2에서 다른 방법을 조사해야 함

## v1.1 터미널 (2026-10-19)

계획: `docs/plans/2026-10-19-agent-float-v1.1-terminals.md`. 직접 구현(executing-plans) 후 마지막에 리뷰 1회

- Ruling R46: Terminal.app·iTerm2는 세션 프로세스의 tty로 탭을 고름 — 두 앱 모두 AppleScript가 탭·세션마다 tty를 알려 줘서 짝이 하나로 정해짐(제목 매칭보다 확실) — 틀리면: tty를 못 읽는 경우 앱만 올리는 폴백으로 내려감
- Ruling R47: tmux는 환경변수 `TMUX`·`TMUX_PANE`으로 pane을 정하고, 바깥 터미널은 클라이언트 pid의 부모에서 찾음. 그 세션을 보는 클라이언트를 먼저, 없으면 가장 최근 클라이언트를 `switch-client`로 옮김 — tmux 안에서는 `TERM_PROGRAM`이 덮여 바깥 앱을 알 방법이 클라이언트뿐 — 틀리면: 다른 세션을 보던 클라이언트의 화면이 바뀜
- Ruling R48: 붙은 클라이언트가 없는 tmux 세션은 Ghostty 새 탭에서 `<tmux 절대 경로> -S <소켓> attach -t <pane>`. attach 전에 `select-window`·`select-pane` — attach는 세션의 현재 창을 바꾸지 않음. 소켓 경로·pane id는 형식 검사 뒤에만 셸 입력에 넣음 — 틀리면: Ghostty가 없는 환경에서는 경고음
- Ruling R49: 직접 선택 감시를 앱별 probe(`FocusProbe`)와 앱별 schedule로 일반화. 감시는 짝지을 수 있는 미확인 세션이 있을 때만, 맨 앞 앱의 probe 하나만 실행 — spec 4.9 유휴 CPU, R38 권한 거부를 앱마다 따로 — 틀리면: 없음(Ghostty 동작은 그대로)
- Ruling R50: 이동 성공 뒤 감시 재개는 그 세션을 짝지을 수 있는 probe의 앱만 — 다른 앱의 권한 상태는 이 이동으로 알 수 없음 — 틀리면: tmux 이동으로 Terminal 권한이 풀려도 Terminal 감시는 다음 Terminal 이동 때 재개
- Ruling R51: `AppModel.activate` 시작 때 그 세션 pid의 폴백 선택 기록을 비움 — 지난 클릭이 기록 뒤 실패하면 다음 클릭이 옛 앱을 기다리게 됨 — 틀리면: 없음
- 구현 중 결정: `TmuxCLI.isPaneId`를 Task 1에서 먼저 정의, `FocusProbe`는 `NavigatorRegistry.swift`에 둠, 부모 순회를 `ProcessAncestry.chain`으로 빼 폴백과 tmux가 같이 씀, `display-message`의 명령 실패만 찾지 못함으로 바꿈(취소는 그대로 올림), `activateFirstRegularApp`을 고르기·올리기로 나눔
- 실측 중 알게 된 것: 이 세션에서 처음 띄운 Terminal은 이 세션의 `CLAUDE_CODE_*` 환경을 물려받아 그 안의 claude가 하위 세션(세션 파일 없음)이 됨 → 시험 스크립트에서 환경을 비워 해결. 사용자가 띄운 터미널에는 해당 없음

### 최종 리뷰 (2026-10-19)

- Ruling R52: Terminal.app·iTerm2 탭을 고르는 tty는 세션에서 부모를 따라 tty가 이어지는 가장 바깥 프로세스의 것 — nvim `:terminal`·screen 아래 세션은 안쪽 pty를 가져 어느 탭과도 맞지 않아 매번 경고음이 남(리뷰 지적, 실측 전 수정). `/dev/ttys<숫자>`가 아닌 값은 폴백으로 보냄 — 틀리면: 탭을 연 셸 위에서 tty를 가진 프로세스가 더 있으면 엉뚱한 tty를 고름(실측 사례 없음)
- Ruling R53: `TMUX`가 있어도 그 서버 pid가 세션의 조상일 때만 tmux 안으로 봄 — tmux 안에서 CLI로 띄운 IDE처럼 환경변수만 물려받은 세션이 tmux 이동으로 빠져 IDE 대신 엉뚱한 pane으로 감(리뷰 지적, 실측 전 수정) — 틀리면: 서버가 조상 체인 32단계 밖이면 tmux가 아닌 터미널 이동으로 처리됨
- 알려진 한계 (고치지 않고 남김. 둘 다 제어 권한 거절 같은 드문 조건에서만 생김)
  - tmux 바깥 Terminal.app·iTerm2 탭 선택이 실패하면 앱만 올리는 폴백으로 내려가지 않고 경고음. pane은 이미 바뀐 상태
  - Ghostty 확인이 권한 거절로 멈춘 뒤에는, 백그라운드 세션이나 붙은 클라이언트 없는 tmux 세션을 Ghostty 새 탭으로 열어도 확인이 다시 켜지지 않음 (R50은 Ghostty 세션으로 이동했을 때만 재개)
- iTerm2 `tmux -CC` 제어 모드는 미대응 → 설계 7장 로드맵

## 가장자리 대비 (2026-10-19)

사용자 제기: 뒤 화면에 따라 알약이 밝아지거나 어두워져 안 보이는 경우가 있음 → "뒤 화면과 반대" 모드 제안, 그러면 테두리 빛이 안 보이는 딜레마 지적 → 두 안 모두 로컬 구현·시험 후 권장안 채택

- Ruling R54: 기본값은 윤곽선, 반대 모드와 유리 그대로는 메뉴에서 고름 — 배경 7가지 캡처에서 윤곽선만 모든 경우에 윤곽이 남았고 유리 모양·테두리 빛 동작이 그대로임. 반대 모드는 앱이 뒤 화면 밝기가 아니라 유리가 고른 톤만 알 수 있어, 글자가 많은 흰 화면(문서·웹)처럼 유리가 스스로 어두워지는 곳에서 밝은 알약이 흰 화면 위에 놓임. 뒤 화면 밝기를 직접 읽으려면 화면 기록 권한이 필요해 쓰지 않음 — 틀리면: 단색 배경에서 더 눈에 띄길 원하면 반대 모드를 직접 골라야 함
- Ruling R55: 유리 톤은 유리 안에 둔 AppKit 뷰의 `effectiveAppearance`(VibrantLight·VibrantDark)로 읽고, 톤을 덮어쓰는 내용 바깥에 둠 — SwiftUI의 `colorScheme`은 시스템 설정에 고정돼 유리의 판단을 알려 주지 않음. 50% 검정 틴트도 흰 배경 위에서 유리가 도로 밝아져, 반대 모드는 70~80% 불투명 면을 깖 — 틀리면: 이후 macOS에서 이 신호가 바뀌면 윤곽선·반대 모드의 톤이 시스템 모드에 고정됨
- Ruling R56: 반대 모드의 글자·`ASK`·`NEW`·정지 테두리 색은 칠한 톤으로 직접 정함 — 동적 색은 유리가 고른 톤으로 풀리고, 시스템과 같은 톤으로 `colorScheme`을 덮어쓰면 값이 안 바뀌어 유리가 고른 글자색이 남음(실측: 다크 모드, 흰 배경 위 진한 면에 검은 글자) — 틀리면: 없음(기본 모드는 그대로)
- 알려진 한계: 반대 모드에서 뒤 내용을 스크롤하면 알약 전체가 0.15초 전환으로 밝음·어두움을 오갈 수 있음(0.3초 간격 8번 전환에 톤 6번 바뀜). 거슬리는 정도는 사람이 써 봐야 앎

## v1.2 답장 (2026-10-23~)

계획: `docs/plans/2026-10-23-agent-float-v1.2-reply.md`, 설계: `docs/specs/2026-10-23-agent-float-v1.2-reply-design.md`. 직접 구현(executing-plans) 후 마지막에 리뷰 1회

### 실측 S1·S2 (Claude Code 2.1.309, tmux 3.6a, Orca 1.4.237)

시험 세션은 haiku, 이 저장소 폴더, `env -i` 셸의 전용 tmux 소켓, Orca는 시험용 탭을 만들어 실측한 뒤 닫음. fixture는 같은 줄 모양으로 가상 내용을 다시 만든 것

| # | 항목 | 결과 |
|---|---|---|
| ① | 포커스 줄 | `❯ 1. 라벨` (포인터 + 일반 공백). 다른 줄은 앞 두 칸 공백. 설명은 다음 줄 들여쓰기. `N. Type something.` 다음 구분선, 그 아래 `N+1. Chat about this`, 맨 아래 `Enter to select · ↑/↓ to navigate · Esc to cancel` |
| ② | 위·아래 | 화살표가 포커스를 한 줄씩 옮김. 구분선 아래 Chat 줄까지 내려감 |
| ③ | 고르기 | 포커스한 선택지에서 Enter. 직접 쓰기 칸에 글이 남아 있어도 고른 선택지가 기록됨 |
| ④ | 직접 쓰기 | `Type something.` 줄에 포커스가 가면 그 문구가 흐려지고(입력 칸 안내 문구) 바로 글자를 받음. 쓴 글은 `❯ 4. 잠시 대기`처럼 번호 뒤에 보이고 포커스를 옮겨도 남음. Enter로 제출 |
| ⑤ | 여러 개 고르기 | 줄이 `1. [ ] 라벨`, 켜면 `[✔]`. Space·Enter 모두 켜고 끔. 직접 쓰기는 `4. [ ] Type something`(마침표 없음), 그 아래 번호 없는 `   Submit` 줄. 위에 탭 줄 `←  ☐ 머리표  ✔ Submit  →`(답한 질문은 ☒) |
| ⑥ | 질문 여러 개 | 탭 줄에 질문마다 머리표. 한 질문에서 Enter로 고르면 다음 질문(포커스 1)으로. 마지막 질문 뒤(여러 개 고르기는 질문 하나여도 Submit 뒤) 확인 화면: `Review your answers` / `● 질문` / `→ 답` / `Ready to submit your answers?` / `❯ 1. Submit answers` / `2. Cancel`, 기본 포커스는 Submit |
| ⑦ | 기록 형식 | `toolUseResult.answers[질문] =` 하나 고르기는 원래 라벨(`(Recommended)` 포함), 여러 개는 선택지 순서대로 `", "`로 이음, 직접 쓰기는 쓴 글 그대로. 본문 질문 답은 사용자 메시지 문자열 그대로 |
| ⑧ | 줄바꿈 | 확인하지 않고 막음 유지 (R59) |
| ⑨ | 빈 프롬프트 | 프롬프트 줄은 `❯` + NBSP(U+00A0). 비어 있어도 흐린(SGR 2) 글이 보일 수 있음: 시작 직후 `Try "…"`, 턴이 끝난 뒤 다음 입력 제안. 진행 중에는 `❯` + NBSP만 |
| ⑩ | 자동 완성 | 프롬프트에서 `/`로 시작하면 명령, `@`가 있으면(글 중간 포함) 파일·리소스 자동 완성이 프롬프트 위에 뜸. 직접 쓰기 칸에서는 뜨지 않음 |
| ⑪ | 창이 뜬 순간의 기록 | 창이 떠 있는 동안 이미 `AskUserQuestion` `tool_use` 레코드가 있고 세션 파일은 `waiting` / `input needed` |
| ⑫ | Orca | `terminal send --text <글>`은 글자 그대로, `--enter`는 CR 1바이트, 화살표는 `--text $'\e[A'`(3바이트)로 들어감. `terminal read --screen --json`은 `result.terminal.tail`(줄 목록)·`tailRows`(감김)·`source: "screen"`, Orca 입력창에 글이 있을 때만 `draft`. 글자 스타일 정보 없음 |
| — | 감긴 질문 | 질문이 길면 각 줄 앞에 `│ ` 거터. 판독 때 떼고 이어 붙임 |

- Ruling R57: 본문 질문 답장은 흐림(SGR 2)을 읽을 수 있는 콘솔에서만 보냄 — 빈 프롬프트에도 흐린 안내·제안 문구가 보여, 글자만으로는 쓰다 만 글과 구분할 수 없음(⑨). tmux는 `capture-pane -e`로 흐림을 읽어 흐린 글만 있으면 빈 칸으로 봄. Orca(⑫)와 스타일을 못 읽는 Ghostty는 본문 질문을 보기만(새 이유 `promptUnverifiable`, 문구 "이 터미널에서는 입력 칸이 비었는지 확인할 수 없어요"). 질문 창은 영향 없음(직접 쓰기 칸의 빈 상태는 `Type something` 글자로 앎) — 틀리면: Orca·Ghostty에서 본문 질문은 패널로 답할 수 없음(S3에서 Ghostty 스타일·커서 정보를 다시 확인)
- Ruling R58: 프롬프트 답장에서 `/`·`!`·`#`로 시작하는 글과 `@`가 들어간 글은 막음(`TextBlock.commandLike`·`.mention`, 문구 "명령으로 읽힐 수 있어 여기서 보낼 수 없어요" / "파일 자동 완성으로 읽힐 수 있어 여기서 보낼 수 없어요") — 자동 완성이 떠 있으면 Enter가 글 대신 제안을 고름(⑩). 직접 쓰기 칸은 막지 않음 — 틀리면: `@`가 든 답은 터미널에서 직접 보내야 함
- Ruling R59: 줄바꿈은 계속 막음 — tmux `send-keys -l`의 줄바꿈은 Enter와 같아 글이 중간에 제출될 수 있음 — 틀리면: 여러 줄 답은 터미널에서
- Ruling R60: 여러 개 고르기는 Space로 켜고 끔 — Enter도 되지만 직접 쓰기 줄에서는 Enter의 뜻이 달라질 수 있어 한 가지 키로 고정 — 틀리면: 없음
- Ruling R61: 서명 확인은 `codesign -dvv`의 `Authority=` 줄로 함 — `-dv`는 Authority를 출력하지 않음(실측) — 틀리면: 없음
