# Agent Float

여러 터미널에서 동시에 돌리는 AI 에이전트 세션의 상태를 화면 구석의 작은 유리 알약 하나로 보여 주는 macOS 앱. 마우스를 올리면 세션 목록이 펼쳐지고, 줄을 누르면 그 세션이 열린 터미널 탭으로 이동한다.

v1은 Claude Code 세션만 읽는다. 다른 에이전트는 같은 구조에 provider만 더해 붙이도록 설계했다.

## 무엇을 보여 주나

접힌 알약에는 상태별 개수가 **대기 → 진행 → 완료** 순으로 나온다.

| 점 | 묶음 | 뜻 |
|---|---|---|
| 주황 | 내 응답 대기 | 권한 승인·질문 도구, 또는 답변이 질문으로 끝난 채 멈춘 세션 |
| 파랑 | 진행 중 | 일하는 중이거나, `/loop`·예약 깨우기·백그라운드 작업처럼 스스로 다시 이어질 세션 |
| 초록 | 완료 | 턴이 끝나고 남은 일이 없는 세션 |
| 회색 | 상태 확인 불가 | 모르는 상태 값이거나 오래 응답이 없는 세션 |

봐야 할 것이 있으면 알약 테두리 빛이 돈다.

- `ASK`: 나를 기다리는 세션이 있음. 대기가 실제로 풀려야 꺼짐
- `NEW`: 아직 확인하지 않은 완료가 있음. 플로팅에서 그 줄을 누르거나, Ghostty·Terminal.app·iTerm2에서 그 탭을 직접 고르거나, 세션이 다시 일을 시작하면 꺼짐. 펼치기만 해서는 꺼지지 않음

## 터미널 이동

| 터미널 | 줄을 누르면 |
|---|---|
| Ghostty | 그 탭으로 이동 (탭 제목과 작업 폴더로 찾음) |
| Orca | 그 터미널 탭으로 이동 (`orca` CLI 사용) |
| Terminal.app · iTerm2 | 그 탭으로 이동 (세션의 tty로 찾음) |
| tmux (어느 터미널 안이든) | 그 pane으로 전환한 뒤 바깥 터미널을 앞으로. Terminal.app·iTerm2면 그 탭까지. 붙은 클라이언트가 없으면 Ghostty 새 탭에서 붙음 |
| `claude --bg` 백그라운드 세션 | Ghostty 새 탭에서 `claude attach <jobId>` 실행 |
| 그 밖의 터미널 (Cursor, Warp 등) | 그 앱만 앞으로 올림 |
| 갈 곳이 없는 세션 | 경고음 |

이동한 뒤 1초 안에 대상 앱이 실제로 앞에 와야 `NEW`가 꺼진다.

## 요구 사항

- macOS 26 이상 (Liquid Glass)
- Swift 6 도구 모음 (Xcode 26 또는 Command Line Tools)
- Orca 이동을 쓰려면 `/usr/local/bin/orca` CLI

## 빌드와 실행

```sh
make test     # 단위 테스트 (swift test)
make bundle   # build/Agent Float.app 조립 + ad-hoc 서명
make run      # 조립 후 실행
make install  # 조립 후 /Applications 에 설치하고 실행 (켜져 있던 앱은 먼저 종료)
make clean
```

Dock 아이콘 없이 메뉴바 아이콘으로 동작한다. 메뉴: `위치 초기화`, `로그인 시 실행`, `Agent Float 종료`.

### 권한

- Ghostty·Terminal.app·iTerm2로 처음 이동할 때 그 앱마다 "제어" 승인 창이 한 번 뜬다. 거절했다면 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 켤 수 있다
- ad-hoc 서명이라 다시 빌드하면 승인을 다시 물을 수 있다
- `로그인 시 실행`은 등록할 때의 앱 위치를 기억한다. `make install`로 설치한 앱에서 등록하면 `make clean`의 영향을 받지 않는다
- 다른 폴더에 설치하려면 `make install INSTALL_DIR=~/Applications`

## 개발용 환경 변수

`open --env 이름=값 "build/Agent Float.app"` 처럼 넘긴다.

| 변수 | 효과 |
|---|---|
| `AGENT_FLOAT_DEBUG=1` | 판정·이동·창 동작 로그를 stderr로 출력 (`open --stderr <파일>`과 같이 쓰면 편함) |
| `AGENT_FLOAT_FAKE_SESSIONS=<개수>` | 실제 세션 대신 가짜 세션으로 화면 확인 |
| `AGENT_FLOAT_CLAUDE_HOME=<폴더>` | `~/.claude` 대신 읽을 폴더 |
| `AGENT_FLOAT_APPEARANCE=light\|dark` | 라이트·다크 모양 고정 |
| `AGENT_FLOAT_REDUCE_MOTION=1` | 동작 줄이기 모드처럼 표시 |
| `AGENT_FLOAT_SLOW_MOTION=<배수>` | 애니메이션을 느리게 |

## 구조

```
Sources/
  AgentFloatCore/        UI 없는 로직 (단위 테스트 대상)
    Claude/              세션 파일·transcript 읽기와 상태 판정
    Provider/            에이전트 provider 규약과 여러 provider를 모으는 SessionStore
    Model/ Signals/      세션 모델, 묶음과 ASK·NEW 신호 규칙
    Navigation/          Ghostty·Orca·Terminal.app·iTerm2·tmux 이동과 폴백
    System/ Window/      프로세스 환경·부모·tty 조회, 알약 위치 저장·계산
  AgentFloat/            앱 (NSPanel, SwiftUI 화면, 메뉴바)
Tests/AgentFloatCoreTests/
docs/
  specs/                 설계 문서와 화면 시안
  plans/                 구현 계획과 결정 기록(rulings)
  checklists/            사람이 확인할 항목과 결과
```

## 알려진 한계

- 데스크탑(Space)을 넘기는 애니메이션 동안에는 알약이 같이 밀려 나간다. 전환이 끝나면 같은 자리에 있다
- Magnet 같은 창 관리 앱이 알약을 화면 칸에 붙일 수 있다
- Orca에서 직접 탭을 옮긴 것, tmux 안에서 직접 pane을 옮긴 것은 감지하지 못해 `NEW`가 남는다
- Ghostty 안의 tmux는 tmux pane까지는 가지만 Ghostty 탭은 고르지 못한다 (Ghostty가 탭의 tty를 알려 주지 않음)
- tmux 세션의 바깥 Terminal.app·iTerm2 탭을 고르지 못하면(제어 권한 거절 등) pane만 바뀌고 경고음이 난다
- Claude Code 세션 파일 형식은 공개 규격이 아니라 실측에 기대고 있다. 모르는 상태 값은 회색으로 표시한다

자세한 판단 근거는 [설계 문서](docs/specs/2026-10-16-agent-float-design.md)와 [결정 기록](docs/plans/2026-10-16-agent-float-rulings.md)에 있다.
