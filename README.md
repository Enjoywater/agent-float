# Agent Float

여러 터미널에서 동시에 돌리는 AI 에이전트 세션의 상태를 화면 구석의 작은 유리 알약 하나로 보여 주는 macOS 앱. 마우스를 올리면 세션 목록이 펼쳐지고, 줄을 누르면 그 세션이 열린 터미널 탭으로 이동한다. 질문하며 기다리는 세션에는 터미널로 가지 않고 그 자리에서 답할 수 있다.

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

## 플로팅에서 답하기

질문 창(선택지·직접 쓰기·여러 개 고르기·질문 여러 개)이나 답변 끝의 질문으로 기다리는 줄을 누르면 답장 화면이 열린다. 승인 대기는 내용만 보여 준다. ⌘+클릭은 지금처럼 바로 이동한다.

| 터미널 | 질문 창 | 답변 끝의 질문 |
|---|---|---|
| tmux (어느 터미널 안이든, Orca 팀 tmux 포함) | 보냄 | 보냄 |
| Orca | 보냄 | 보기만 |
| Ghostty | 보냄 — 지금 보이는 창의 선택된 탭이고 분할이 없을 때만. 그 밖은 보기만 | 보기만 |
| Terminal.app · iTerm2 · 그 밖 | 보기만 | 보기만 |

- 보내기는 터미널에 키를 하나씩 넣고 매번 화면이 그 키대로 바뀌었는지 확인한 뒤, 기록된 답이 고른 답과 같은지 대조한다. 확인할 수 없으면 보내지 않고 이유를 보여 준다 (터미널에 쓰던 글이 있음, 질문이 바뀜 등)
- 답변 끝의 질문은 빈 입력 칸에도 흐린 안내 문구가 떠서, 글자 스타일을 읽을 수 있는 tmux에서만 보낸다
- `/`·`!`·`#`로 시작하거나 `@`가 든 답, 여러 줄 답은 자동 완성·줄바꿈이 Enter를 가로챌 수 있어 터미널에서 직접 보낸다
- 보내다 멈추거나 기록이 다르면 알약 맨 앞에 빨간 `FAIL`, 목록 맨 위에 "확인 필요"가 남는다. 그 줄의 실패 화면에서 `닫기`·`터미널에서 열기`를 누르거나 ⌘+클릭해야 꺼진다
- 답장 화면이 열린 동안만 패널이 키 입력을 받는다. 앱은 앞으로 오지 않고, 닫으면 원래 앱에서 바로 이어서 타이핑할 수 있다
- 키: 1~9 선택지 고르기, ⏎ 보내기(한글 조합 중에는 확정만), Tab 이동, esc 입력 칸에서 나가기 → 목록으로. 쓰던 답은 다시 열 때까지 남는다

## 요구 사항

- macOS 26 이상 (Liquid Glass)
- Swift 6 도구 모음 (Xcode 26 또는 Command Line Tools)
- Orca 이동을 쓰려면 `/usr/local/bin/orca` CLI

## 빌드와 실행

```sh
make test     # 단위 테스트 (swift test)
make bundle   # build/Agent Float.app 조립 + 서명 (아래 "서명")
make run      # 조립 후 실행
make install  # 조립 후 /Applications 에 설치하고 실행 (켜져 있던 앱은 먼저 종료)
make clean
```

Dock 아이콘 없이 메뉴바 아이콘으로 동작한다. 메뉴: `위치 초기화`, `가장자리 대비`, `답장 화면`, `로그인 시 실행`, `Agent Float 종료`.

`답장 화면`: `패널 전환` (기본값, 패널이 그 세션의 답장 화면으로 바뀜) / `줄 안에서 펼침` (누른 줄이 그 자리에서 길어짐) / `옆에 카드` (목록은 두고 패널 옆에 카드가 뜸).

`가장자리 대비`: 알약 유리는 뒤 화면에 맞춰 밝아지거나 어두워져 같은 톤의 배경에서는 윤곽이 흐려진다.

- `윤곽선` (기본값): 가장자리에 반대 톤의 얇은 선을 두른다
- `뒤 화면과 반대`: 알약을 뒤와 반대 톤으로 칠한다. 단색 배경에서 가장 눈에 띄지만 글자가 많은 흰 화면에서는 대비가 약하다
- `유리 그대로`: 유리가 고른 대로 둔다

### 서명

다시 빌드해도 손쉬운 사용·자동화 권한이 유지되도록 로그인 키체인의 로컬 전용 자체 서명 인증서 `Agent Float Local Signing`으로 서명한다. 처음 한 번 `scripts/create-signing-identity.sh`로 만든다(인증서에는 앱 이름만 들어감). 인증서가 없으면 경고를 출력하고 ad-hoc으로 서명하며, 이때는 다시 빌드할 때마다 승인을 다시 물을 수 있다.

### 권한

- Ghostty·Terminal.app·iTerm2로 처음 이동할 때 그 앱마다 "제어" 승인 창이 한 번 뜬다. 거절했다면 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 켤 수 있다
- Ghostty 세션에 답하려면 손쉬운 사용 권한이 필요하다(화면을 읽어 확인하기 위해). 처음 Ghostty 세션의 답장 화면을 열 때 승인 창이 뜨고, 거절하면 답장 화면의 `설정 열기`로 켤 수 있다
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
| `AGENT_FLOAT_CONTRAST=standard\|outline\|inverse` | 가장자리 대비를 메뉴 선택보다 우선해 고정 (유리 그대로·윤곽선·반대) |
| `AGENT_FLOAT_REDUCE_MOTION=1` | 동작 줄이기 모드처럼 표시 |
| `AGENT_FLOAT_SLOW_MOTION=<배수>` | 애니메이션을 느리게 |
| `AGENT_FLOAT_REPLY_PLACEMENT=panel\|inline\|card` | 답장 화면 배치를 메뉴 선택보다 우선해 고정 |
| `AGENT_FLOAT_FAKE_REPLY=delivered\|hidden\|accessibility\|draft\|stopped\|mismatch` | 가짜 세션(`AGENT_FLOAT_FAKE_SESSIONS`)일 때 보내기 결과를 흉내 냄. 실제로 보내지 않음 |

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
Tests/
  AgentFloatCoreTests/   Core 단위 테스트와 화면 fixture
  AgentFloatTests/       답장 화면 상태(ReplyCenter) 테스트
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
- 답하기는 Claude Code 질문 창의 화면 모양(2.1.309 실측)에 기대고 있다. 모양이 바뀌면 키를 넣기 전이면 보내지 않고, 넣는 도중이면 거기서 멈춰 실패로 표시한다
- Orca·Ghostty에서는 답변 끝의 질문에 답할 수 없고, Ghostty는 가려진 탭·다른 데스크탑의 창·분할된 탭에 답할 수 없다(보기만)
- 승인 대기에는 답할 수 없다(내용만 보여 줌)

자세한 판단 근거는 [설계 문서](docs/specs/2026-10-16-agent-float-design.md)와 [결정 기록](docs/plans/2026-10-16-agent-float-rulings.md)에 있다.
