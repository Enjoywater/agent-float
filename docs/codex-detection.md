# Codex 탐지·이동·답장

Codex 0.165.0의 로컬 공유 app-server와 실제 TUI 터미널을 함께 확인한다. Claude와 같은 목록·hover·클릭 이동·질문 답장 화면을 사용한다.

## 종료된 세션 제외

공유 서버의 `thread/loaded/list`는 열린 터미널 목록이 아니다. 터미널이 종료된 뒤에도 서버 메모리에 예전 세션이 남고, 임시 세션도 반환될 수 있다. 이 목록을 그대로 표시하던 초기 구현은 종료된 세션을 초록색 완료 항목으로 표시했다.

현재는 다음 조건을 모두 확인한다.

1. Codex 실행 파일을 가진 살아 있는 TUI 프로세스가 있고 tty가 있어야 한다. 공유 데몬 자체는 제외한다.
2. TUI가 사용하는 Codex 홈과 세션 작업 디렉터리가 일치해야 한다.
3. 실제 터미널의 현재 제목이 세션 이름과 정확히 맞아야 한다. Codex의 braille 진행 기호와 ` | 디렉터리명` 표시는 정규화한다.
4. 터미널 후보가 정확히 하나여야 한다. 이름 없는 임시 세션, 닫힌 탭, 중복 제목으로 구별할 수 없는 항목은 표시하지 않는다.

Ghostty, Orca, Terminal.app, iTerm2, tmux에서 위치를 찾는다. 찾은 위치를 기존 navigator에 넘기므로 hover·클릭 이동·Ghostty 포커스 감지가 연결된다. 제목을 임의로 바꾸거나 자동 제목을 꺼 둔 터미널은 탐지에서 빠질 수 있다. Ghostty는 tty를 공개하지 않아 프로세스의 홈·작업 경로와 고유한 현재 탭 제목을 함께 대조한다.

## 상태와 질문

기존 control socket의 Unix WebSocket을 통해 `initialize` → `initialized` → `thread/loaded/list` → `thread/read(includeTurns: false)`를 요청한다. 서버를 새로 시작하거나 세션을 resume하지 않는다. 기존 앱의 5초 폴링을 사용한다.

| 근거 | 표시 |
|---|---|
| `active`, 빈 `activeFlags` | 진행 |
| `active`, `waitingOnApproval` | 승인 대기 (Claude와 동일하게 보기만) |
| `active`, `waitingOnUserInput` | 질문 대기 |
| `idle`, 마지막 본문이 질문 | 본문 질문 대기 |
| 그 밖의 `idle` | 완료 / 유휴 |
| `systemError`, 모르는 상태·플래그 | 알 수 없음 |
| `notLoaded`, 살아 있는 터미널 없음 | 목록에서 제외 |

질문 본문·선택지는 Codex JSONL의 `response_item`에서 읽는다. 구조화된 `request_user_input`과 마지막 본문 질문을 지원하며, 본문 질문 판정에는 Claude와 같은 `QuestionHeuristic`을 사용한다. 상태 시작 시각은 앱이 처음 관측한 시각이다. `updatedAt`은 실행 생존 여부를 판단하는 근거로 쓰지 않는다.

소켓이 없어지면 목록을 비운다. 통신이나 스키마 해석이 실패하면 기존 항목을 오래된 `알 수 없음`으로 바꾸며 이전의 `진행`·`완료`를 유지하지 않는다. 원인은 `CodexCodeProvider.lastError`로 확인할 수 있다.

## 답장

기존 `ReplyDelivery`의 같은 질문 확인 → 화면 확인 → 한 단계씩 입력 → 기록 확인 절차를 재사용한다. Codex 화면은 `CodexScreen`으로 따로 판독한다.

- 선택지 하나 고르기, 여러 질문을 차례로 답하기, `None of the above`의 notes 직접 입력, 본문 질문에 텍스트 답장을 지원한다.
- Codex의 마지막 질문은 `enter to submit all`로 표시된다. 마지막 Enter 뒤에는 더 이상 키를 보내지 않고 기록으로 결과를 판정한다.
- 구조화된 답은 `function_call_output`의 질문 ID별 `answers`와 비교한다. 직접 입력은 `None of the above`와 `user_note:`를 사용자가 쓴 답으로 정규화한다.
- 본문 답은 해당 assistant 메시지 다음의 실제 user 메시지와 비교한다. 제출 후 새 턴이 시작돼도 기존 질문과 답의 연결을 유지한다.
- 화면이 바뀌거나 사용자가 이미 글을 써 둔 경우에는 보내지 않는다. 다른 답이 기록되거나 시간 안에 기록이 없으면 성공으로 표시하지 않는다.
- 전송 가능한 터미널과 제약은 Claude와 같다. Ghostty·Orca·tmux에서 전송하며, Terminal.app·iTerm2에서는 이동만 지원한다. Ghostty는 선택된 비분할 탭과 손쉬운 사용 권한이 필요하다. 승인 대기는 자동으로 승인하지 않는다.

## 검증과 범위

```sh
swift test
AGENT_FLOAT_TEST_LIVE_CODEX=1 swift test --filter liveSharedDaemonReadOnlySmoke
AGENT_FLOAT_TEST_LIVE_NAVIGATION=1 swift test --filter liveDetectedGhosttySessionCanBeFocused
```

실제 사용자 공유 서버에서는 남아 있던 3개 중 열린 TUI 세션 1개만 탐지되는 것과 Ghostty로 이동한 뒤 포커스가 맞는 것을 확인했다. 사용자 세션에 답을 전송하지는 않았다.

답장 전송은 임시 Codex 홈·로컬 가짜 모델 응답 서버·격리된 tmux에 연결한 실제 Codex 0.165.0 TUI에서 검증했다. 선택지, notes 직접 입력, 본문 답장, 두 질문 연속 답장을 실제로 보내고 저장 기록이 일치하는 것을 확인했다. 실제 모델 API는 호출하지 않았다. 이 검사는 기본 테스트에서 건너뛰며, 준비된 fixture의 manifest 경로를 `AGENT_FLOAT_CODEX_TUI_FIXTURE`로 주어 실행한다. manifest에는 `id`, `path`(JSONL), `socket`(tmux), `pane`, `kind`(`choice`, `other`, `text`)를 넣는다.

`--no-daemon`, 별도·원격 app-server, 공유 서버를 사용하지 않는 IDE·데스크톱 세션, 예전 Codex 버전은 이번 검증 범위에 포함하지 않는다. 새 UI 변형이나 임의 제목 변경까지 완전한 탐지를 보장하지 않는다.

프로토콜 근거: [공식 App Server 문서](https://learn.chatgpt.com/docs/app-server). 설치 버전의 타입은 `codex app-server generate-ts --experimental --out <임시폴더>`로 확인했다.
