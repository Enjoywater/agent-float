# Orca·Ghostty 본문 질문 답장 — 조사와 설계 초안

- 작성일: 2026-10-24
- 상태: Orca는 D로 구현함 (2026-10-24, R77). Ghostty는 C(첫 글자로 넣어 보고 확인)로 구현함 (2026-10-26, R78). V는 사용자 기각(클립보드)
- 바탕: v1.2 설계(`2026-10-23-agent-float-v1.2-reply-design.md`)의 R57·R64. Orca·Ghostty에서는 답변 끝의 질문(본문 질문)에 보기만 됨

## 1. 문제

본문 질문에 답하려면 Claude Code 프롬프트가 비어 있는지 먼저 알아야 한다. 사용자가 쓰다 만 글 뒤에 답을 붙여 Enter를 누르면 의도와 다른 메시지가 보내진다 **[사용자: 절대 금지]**. 그런데 빈 프롬프트에도 흐린(SGR 2) 안내·제안 문구가 떠서, 글자만 읽으면 쓰다 만 글과 구분할 수 없다(실측 S1 ⑨). tmux는 `capture-pane -e`로 흐림을 읽어 해결했고, Orca·Ghostty는 흐림을 읽지 못해 보기만으로 두었다.

## 2. 조사 결과 (2026-10-24, 화면 잠금 중이라 문서·CLI만)

| 경로 | 입력 커서 위치 | 글자 스타일(흐림) | 근거 |
|---|---|---|---|
| Orca `terminal read --screen --json` | 없음 | 없음 | 필드: `handle`·`source`·`status`·`tail`·`tailRows`(줄마다 `trailingSpaces`·`wrapped`뿐)·`truncated`·`limited`와 줄 단위 페이지 커서(`oldestCursor`·`nextCursor`·`latestCursor`, 입력 커서 아님) |
| Orca `terminal show --json` | 없음 | — | 탭·창·워크트리·연결 상태 등 메타데이터만 |
| Ghostty AppleScript (1.3.1 sdef) | 없음 | 없음 | terminal: `id`·`name`·`working directory`·`command`·`initial input`. 화면 내용 속성 없음 |
| Ghostty 손쉬운 사용 API | 모름 | 모름 | 지금은 텍스트 영역의 값(글자만)을 읽음(S3). 커서(`AXSelectedTextRange`·`AXInsertionPointLineNumber`)나 글자 속성(`AXAttributedStringForRange`)을 주는지는 실측해야 함 |

### 실측 S5 (2026-10-24, Claude Code 2.1.310, 화면 잠금 중 — tmux 시험 세션·Orca 시험 탭, 끝난 뒤 닫음)

| # | 항목 | 결과 |
|---|---|---|
| ① | 흐린 안내 문구가 있는 빈 칸에 글을 넣음 (tmux) | 안내 문구가 모두 사라지고 줄에는 넣은 글만 남음. 다 지우면 안내 문구가 돌아옴 |
| ② | 지우기 한 번 | tmux `BSpace`, Orca `--text` 로 넣은 DEL(0x7f) 모두 정확히 한 글자(한글 음절 포함)를 지움 |
| ③ | 다음 입력 제안(흐림) | 두 턴(하나는 질문으로 끝남) 뒤에도 뜨지 않아 확인하지 못함. "제안 앞부분을 치면 흐린 꼬리가 남는가"는 미확인 |
| ④ | **Orca `draft`** | Claude 입력 칸에 넣은 글은 화면 줄(`tail`)에서 빠지고 `draft`로만 옴. 빈 칸이면 `draft` 없음 + 화면 줄에 안내 문구. 일부를 지우면 `draft`도 따라 줄고, 다 지우면 다시 없음. Enter 뒤에는 `draft` 없음 + 보낸 글이 기록 줄로 올라감. 앞 공백은 `draft`에서 빠짐(공백만 있으면 없음) |
| ⑤ | Orca `--text=--dry-run 먼저` | 받아서 입력됨 (최종 리뷰 M3 수정이 맞음) |

④ 때문에 v1.2 실측 S2 ⑫의 해석("`draft`는 Orca 자체 입력창의 글")을 고친다 — Orca는 에이전트 입력 칸의 실제 글을 알아내 `draft`로 주고 화면 줄에서는 뺀다. 다만 S7에서 다음 입력 제안도 `draft`에 들어가는 것을 확인했다. `draft`가 실제 입력만 담는다고 가정하면 안 된다.

### 실측 S6 (2026-10-26, Ghostty 1.3.1 · Claude Code 2.1.310 — Ghostty 시험 창 하나)

| # | 항목 | 결과 |
|---|---|---|
| ① | 텍스트 영역 속성 | `AXSelectedTextRange`·`AXNumberOfCharacters`·`AXVisibleCharacterRange`·`AXSelectedText`·`AXValue` 등. 매개변수 속성 `AXStringForRange`·`AXAttributedStringForRange`·`AXLineForIndex`·`AXReplaceRangeWithText`. `AXInsertionPointLineNumber` 없음 |
| ② | `AXSelectedTextRange` | 글을 넣어도 늘 `0, 0` — 입력 커서가 아니라 마우스 선택. **방식 A 불가** |
| ③ | `AXAttributedStringForRange` | 목록에는 있으나 어떤 범위든 `-25201`(잘못된 인자). 같은 범위의 `AXStringForRange`는 됨. **방식 B 불가** |
| ④ | `perform action "write_screen_file:paste,vt"` | 화면을 SGR 이 섞인 글로 `$TMPDIR/<무작위>/screen.txt` 에 씀. 빈 칸은 `❯` + NBSP + `ESC[2m` 안내 문구, 넣은 글은 흐림 없는 글 — tmux 와 같은 규칙으로 가려짐. 파일은 남으므로 지워야 함 |
| ⑤ | ④ 를 창이 손쉬운 사용 목록에 없을 때(다른 데스크탑) | 그래도 써짐 |
| ⑥ | 경로를 넘기는 방식 | `copy`(클립보드)·`paste`(그 터미널에 붙여넣기)·`open`(편집기)뿐. `write_screen_file:vt`(방식 없음)는 `false`. 앱에서 쓸 수 있는 것은 `copy` 하나 — 읽을 때마다 사용자 클립보드를 덮어씀 |
| ⑦ | `send key "backspace"` | 한 번에 정확히 한 글자(한글 음절 포함). `한글` → `한` |
| ⑧ | 긴 글 `input text` | 800자(ASCII)는 그대로, 801자부터 `[Pasted text #N]` 으로 접힘. 접힌 자리표시자에 지우기를 누를 때의 동작은 확인하지 않음 — 의존하지 말 것 |

④ 로 Ghostty 도 키를 넣기 전에 빈 칸을 판정할 수 있다(방식 V). 대신 ⑥ 의 클립보드 덮어쓰기가 따라와 사용자가 기각했다(2026-10-26).

### 실측 S7 (2026-10-29, Claude Code 2.1.312 · Ghostty 1.3.1 · Orca 1.4.242)

- 시험 방법: 도구를 끈 haiku 세션에서 가상의 재시도 정책·의사코드 질문을 주고 다음 입력 제안을 켰다(`CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1`, `promptSuggestionEnabled: true`). 전용 tmux 세션에 시험 Ghostty 창을 붙여 SGR 흐림과 실제 입력을 대조했다. Orca는 같은 세션과 별도의 tmux 없는 시험 탭에서 확인했다. 기존 작업 세션에는 입력하지 않았다.
- Ghostty: 제안과 같은 첫 글자를 `input text`로 넣으면 흐린 꼬리 전체가 사라지고 입력한 글자만 남았다. 손쉬운 사용 화면을 읽는 실제 `GhosttyConsole`·`ReplyDelivery`로 확인하니, 수정 전에는 그 글자가 제안의 접두사이기도 해서 `isPartial`에 걸려 시간 초과(`stopped`)가 났다. 덜 그려진 화면인지 보기 전에 기대한 입력 결과인지 확인하도록 수정했다(R80).
- 수정 후 Ghostty: 첫 글자 → 나머지 답 → Enter 순서로 진행하고 `ClaudeCodeProvider.recordedAnswer`와 대조해 `delivered` 확인. 제안과 첫 글자가 같은 한글 답으로 재현했다. 이어서 수정한 번들 앱에서도 확인했다: 시험 세션만 보이는 실제 파일 사본을 읽게 하고, 답장 화면은 디버그 경로로 열었다(비활성 목록의 좌표 클릭은 GUI 도구가 차단). UI 입력 칸에 Tab으로 포커스를 주고 답을 입력한 뒤 보내기 버튼을 `AXPress`로 눌렀다. 흐린 제안과 같은 첫 글자로 시작하는 답이 "보냈어요"로 표시되고, 원본 transcript에도 입력한 답이 그대로 남았다. 목록에서 답장 화면을 여는 실제 클릭은 이번 실측 범위 밖이다.
- Orca: 다음 입력 제안도 `draft`로 반환하고 `tail`의 프롬프트에서는 뺀다. tmux 없는 시험 탭에서도 직접 입력하지 않은 제안이 `draft`에 있었다. 실제 `OrcaConsole`·`ReplyDelivery`는 `notSent(terminalDraft)`, 입력 0개로 끝났다. 제안과 쓰던 글을 구분할 정보가 없어 기존 차단을 유지한다. 기존 S5의 "입력 칸 글자는 늘 안내·제안 문구" 해석은 이 경우 성립하지 않는다.
- 검증: 회귀 테스트가 수정 전 `stopped`로 실패하고 수정 후 통과. 전체 `swift test` 438개 통과, `make bundle` 성공.

## 3. 방식 후보

| 방식 | 어디에 | 내용 | 안전성 |
|---|---|---|---|
| A. 커서 위치로 빈 칸 판정 | Ghostty (AX가 커서를 줄 때) | 흐린 안내 문구는 커서 뒤에 그려진다. 커서가 프롬프트 줄의 `❯ ` 바로 뒤에 있으면 빈 칸 | tmux와 같은 수준. 키를 넣기 전에 판정 |
| B. 글자 속성으로 흐림 판정 | Ghostty (AX가 속성을 줄 때) | tmux와 같은 규칙을 그대로 씀 | tmux와 같은 수준 |
| D. Orca `draft` 로 판정 | Orca | 빈 칸 = `draft` 없음(화면 줄의 안내 문구는 무시). 글을 넣은 뒤 `draft`가 넣은 글과 같아야 Enter. Enter 뒤 `draft` 없음 | tmux와 같은 수준. 키를 넣기 전에 판정하고 지우기가 필요 없음 |
| V. 화면 파일(vt)로 판정 | Ghostty | `write_screen_file:copy,vt` 로 받은 파일을 tmux 와 같은 규칙으로 읽음. 클립보드는 실행 전 항목 전체를 저장했다가, 그 사이 변경이 Ghostty 의 한 번뿐일 때만 되돌림. 파일은 읽은 뒤 지움 | tmux 와 같은 수준. 비용: 읽을 때마다 클립보드 덮어씀(본문 답 하나에 보통 3~7번), 클립보드 기록 앱에는 경로가 남음 |
| C. 써 보고 확인 | Orca·Ghostty 공통 | 글을 넣은 뒤 프롬프트 줄이 정확히 그 글이면 원래 비어 있던 것 → Enter. 더 길면(쓰던 글 + 내 글, 또는 자동 제안 꼬리) Enter 없이 넣은 글자 수만큼 지우고(지울 때마다 화면 확인) "보내지 않음" | Enter는 줄이 내 글과 같을 때만 → 다른 답은 보내지지 않음. 남는 위험: 지우기가 실패하면 사용자 입력 칸에 내 글이 남음 → 실패 표시(`FAIL`)와 "입력 칸에 글이 남았어요"로 알림 |

C의 세부
- 넣기 전 화면은 지금처럼 읽되(질문 창이 아니고 프롬프트인지, Orca 입력창 `draft`가 비었는지), 프롬프트 줄의 글자는 판정에 쓰지 않는다
- 지우기는 새 키 `backspace`로만 한다. 글 안의 제어 문자 금지(DEL 포함)는 그대로 둔다
- 쓰던 글이 있던 경우 사용자 화면에 내 글이 잠깐 붙었다 지워진다. 그 사이 사용자가 터미널에서 Enter를 누르면 섞인 글이 보내질 수 있으나, 이는 사용자의 키 입력이라 지금의 "보내는 도중 터미널 입력이 끼어듦"(Review Focus 1)과 같은 종류로 본다 — 이 점은 사용자 확인이 필요함

## 4. 추천

1. **Orca는 D** — 구현 완료. 다음 입력 제안은 `draft`로 반환되어 쓰던 글로 판단하고 전송을 막는다(S7). 제안과 실제 입력을 구분할 정보가 생기기 전까지 이 제한을 유지한다.
2. Ghostty AX는 커서도 글자 속성도 주지 않음(S6 ②·③). 사용자가 C를 고름 → 첫 글자 하나로 넣어 보고 확인하도록 구현(R78). 800자를 넘는 답은 막음(R79, ⑧)
3. 앞 공백은 `draft`에서 빠지므로, 보낼 답도 앞뒤 공백을 뺀 글로 비교한다(최종 리뷰 M1 수정과 같음)

## 5. 잠금 해제 후 실측 목록

| # | 확인할 것 | 방법 |
|---|---|---|
| 1 | ~~Ghostty 텍스트 영역의 속성·매개변수 속성 목록, 커서 추적~~ | S6 ①~③ 완료 |
| 2 | ~~Ghostty `send key` 의 지우기 키 이름~~ | S6 ⑦ `backspace` |
| 3 | ~~다음 입력 제안이 뜬 상태에서 글을 넣었을 때의 화면과 Orca `draft`~~ | S7 완료: Ghostty 입력 시 제안 사라짐, Orca 제안은 `draft`로 반환되어 전송 차단. tmux SGR로 흐림 대조 |
| 4 | ~~지우기 한 번이 정확히 한 글자(한글 포함)를 지우는지~~ | tmux·Orca S5 ②, Ghostty S6 ⑦ |
| 5 | 넣기와 Enter 사이에 사용자가 Orca에서 직접 타이핑하면 `draft`가 어떻게 바뀌는지 | Orca 시험 탭, 실제 키보드 (잠금 해제 후) |
| 6 | `write_screen_file:copy,vt` 가 클립보드에 무엇을 올리는지(경로 글만인지, 임시 표시가 있는지)와 되돌리기 — V 를 쓸 때만, 사용자 클립보드를 한 번 덮어쓰므로 승인 뒤 | 시험 창 |
| 7 | 선택되지 않은 탭에서도 화면 파일이 써지는지 — 되면 R62(보이는 창·선택 탭만)를 풀 단서. 이번 범위 밖 | 다음 후보 |

시험 세션·시험 탭은 v1.2와 같은 방식(haiku, 이 저장소 폴더, 끝나면 닫음)으로만 쓰고, 사용자의 실제 세션에는 보내지 않는다.
