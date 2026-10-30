# 기능소개서 대조 결과

- 대상: [HTML 기능소개서](../agent-float-guide.html)
- 기준: [README](../../README.md), 현재 메뉴와 UI·탐지·이동·답장 구현
- 검토일: 2026-10-30
- 방법: 문서와 소스 대조, 브라우저의 문서 표시·데모 확인. 앱의 모든 기능을 새로 실환경에서 실행한 검증은 포함하지 않는다.

## 기능별 반영 상태

| 기능 | 소개서 위치 | 결과 / 구현 근거 |
|---|---|---|
| 접힌 알약·hover 목록·상태별 개수와 정렬 | [주요 기능](../agent-float-guide.html#features) | 설명 있음. `FloatRootView`, `ExpandedPanelView`, `SessionGrouping` |
| 대기·진행·완료·상태 확인 불가 | [주요 기능](../agent-float-guide.html#features) | 설명 있음. `SignalTracker`, `SummaryRow` |
| ASK·NEW와 NEW 해제 조건 | [주요 기능](../agent-float-guide.html#features) | 해제 조건·직접 탭 감지 한계 보완. `SignalTracker`, `AppModel`, focus probes |
| Claude·Codex 구분 배지 | [에이전트 구분](../agent-float-guide.html#identity) | 목록·답장 헤더·옆 카드와 실제 SwiftUI 렌더링 설명. `AgentBadge` |
| Ghostty·Orca·Terminal.app·iTerm2 이동 | [지원 범위](../agent-float-guide.html#support) | 설명 있음. 각 navigator |
| tmux pane 전환·분리된 세션 연결 | [지원 범위](../agent-float-guide.html#support) | 클라이언트가 없을 때 Ghostty 연결 설명 보완. `TmuxNavigator` |
| Claude `--bg` attach | [지원 범위](../agent-float-guide.html#support) | 누락 보완. `GhosttyNavigator` |
| 그 밖의 터미널 앱 활성화 폴백 | [지원 범위](../agent-float-guide.html#support) | Claude 범위로 설명 보완. `AppActivationNavigator` |
| 이동 위치 없음·이동 실패 | [지원 범위](../agent-float-guide.html#support) | 이동용 hover·클릭 비활성, 실패 경고음 설명 보완. `SessionRow`, `AppModel` |
| 선택지·직접 입력·본문 질문·여러 질문 | [답장](../agent-float-guide.html#reply), [지원 범위](../agent-float-guide.html#support) | 에이전트별 차이 포함. `ReplyEditor`, `ReplyDriver`, `CodexScreen` |
| 질문별 작성 중인 답·확인 화면에서 수정·전체 보기 | [답장](../agent-float-guide.html#reply) | 유지·폐기 범위와 수정 기능 보완. `ReplyCenter`, `ReplyEditor`, `ReviewList`, `MessageTail` |
| 같은 질문·화면·단계별 입력·기록 확인 | [답장](../agent-float-guide.html#reply) | 설명 있음. `ReplyDelivery` |
| 보내지 않음·재확인·권한 설정 열기 | [답장](../agent-float-guide.html#reply) | 결과 후 동작 보완. `ReplyFooter`, `ReplyCenter` |
| FAIL·확인 필요·자동 목록 복귀 | [답장](../agent-float-guide.html#reply) | 자동 복귀와 실패 유지 차이 보완. `ReplyCenter`, `SummaryRow` |
| 승인 대기 보기만·터미널별 전송 제한 | [지원 범위](../agent-float-guide.html#support) | 설명 있음. `ConsoleRegistry`, `ReplyFooter` |
| 800 UTF-16 단위·한 줄·명령·자동 완성 제한 | [지원 범위](../agent-float-guide.html#support) | 설명 있음. `ReplyText` |
| 패널 전환·줄 안·옆 카드 | [사용자 설정](../agent-float-guide.html#personalize) | 별도 설명과 기본값 보완. `ReplyPlacement`, `MenuBarController` |
| 윤곽선·뒤 화면과 반대·유리 그대로 | [사용자 설정](../agent-float-guide.html#personalize) | 별도 설명과 기본값 보완. `GlassContrast`, `MenuBarController` |
| 메뉴바·Dock·둘 다·Dock 우클릭·⌘Tab | [사용자 설정](../agent-float-guide.html#personalize) | 별도 설명 보완. `IconPresence`, `AppDelegate`, `MenuBarController` |
| 드래그·위치 저장·위치 초기화·여러 데스크톱·목록 스크롤 | [사용자 설정](../agent-float-guide.html#personalize) | 누락 보완. `PanelController`, `FloatingPanel`, `ExpandedPanelView` |
| 로그인 시 실행·앱 종료 | [사용자 설정](../agent-float-guide.html#personalize) | 메뉴 동작과 시스템 승인 설명 보완. `MenuBarController` |
| 비활성 목록·답장 입력·포커스 복귀 | [사용자 설정](../agent-float-guide.html#personalize) | 누락 보완. `FloatingPanel`, `PanelController` |
| macOS 동작 줄이기 반영 | [사용자 설정](../agent-float-guide.html#personalize) | 누락 보완. `Motion`, `BorderSweep`, `FloatRootView` |
| 숫자·Enter·Tab·Esc·텍스트 편집 단축키 | [시작하기](../agent-float-guide.html#setup) | 편집 단축키 추가. `ReplyKeys`, `MainMenu` |
| 설치·로컬 서명·자동화·손쉬운 사용 권한 | [시작하기](../agent-float-guide.html#setup) | 설명 있음. `Makefile`, `MenuBarController`, `ReplyFooter` |
| 탐지 범위·Codex 제목/서버 제약·자동화 세션 | [지원 범위](../agent-float-guide.html#support), [FAQ](../agent-float-guide.html#questions) | 설명 있음. `ClaudeCodeProvider`, `CodexCodeProvider`, `CodexTerminalInventory` |

## 미구현 기능과 표시 범위

- 직접 실행 / 자동화 자동 분류와 필터는 미구현으로 명시했다.
- 에이전트별 필터는 UI 비교 문서의 선택적 시안이며, 현재 앱 기능으로 소개하지 않는다.
- `--no-daemon`·별도·원격 Codex 서버는 지원 기능으로 소개하지 않는다.
- 소개서의 테마 버튼·전송 데모·명령 복사는 웹 문서 기능이다. 앱의 설정과 구분했다.
- 기능 설명용 세션은 가상 데이터다. 녹화에는 배지 적용 전 화면이 포함되며 이를 표시했다.
- 현재 배지 렌더링의 제목에서 검토안 명칭인 `A안`을 라이트·다크 이미지 모두 제거했다.

소스 대조 범위에서 빠져 있던 사용자 기능 설명을 보완했다. 터미널·OS별 세부 제약과 개발용 환경 변수는 README와 상세 문서로 연결한다.

## 소개서 레이아웃 점검

- Chrome에서 320·390·650·651·700·768·850·1024·1440px 너비, 라이트·다크를 확인했다.
- 상태 확인·터미널 이동·답장 선택·전송 결과·FAQ 펼침의 90개 조합과, 동작 줄이기를 해제하고 녹화를 펼친 18개 조합을 검사했다.
- 320px에서 히어로와 기능 데모의 그리드 최소 너비 때문에 내부 요소가 카드 경계 밖으로 잘리는 문제를 수정했다. 그리드가 가용 너비로 줄어들고 데모가 카드 안에 맞도록 했다.
- 재검사에서 페이지 가로 넘침, 데모 카드 잘림, 헤더 요소 겹침은 발견되지 않았다. 비교표와 설치 명령은 의도적으로 영역 안에서 가로 스크롤한다.
- 기능 전환 간 위치 비교를 추가했다. 중앙 정렬과 이동 안내문의 자동 너비로 데모가 상하·좌우로 움직이던 문제를 수정했다. 데모는 280px 너비(좁은 화면에서는 가용 너비), 최소 360px 표시 영역과 일정한 캡션 영역을 사용한다. 결과 화면의 자동 포커스도 페이지를 스크롤하지 않도록 했다.
- 320·390·651·768·1024·1440px에서 상태 확인·이동·답장·완료 간 패널 시작 위치와 너비, 섹션 높이 차이가 1px 미만임을 확인했고, 위의 108개 조건도 다시 통과했다.
- 데스크톱의 주요 기능·사용자 설정·지원 범위와 320px 다크 화면을 이미지로 확인했다.
- 헤더 로고는 30px에서 26px로 줄였다. 메뉴가 표시되는 화면에서는 현재 섹션에 파란 글자·밑줄과 `aria-current="location"`을 적용한다.
- 여섯 메뉴의 스크롤 활성 상태를 확인했다. 첫 화면과 FAQ처럼 대응 메뉴가 없는 구간은 활성 표시를 해제한다. 이미지 로드·FAQ 펼침·창 크기 변경 후에도 위치를 다시 계산한다.
- 문서의 링크·이미지 참조 22개, 중복 ID, JavaScript 구문을 확인했다. 브라우저 실행 오류는 없었다.

이 점검은 HTML 기능소개서에 대한 것으로, 네이티브 앱 UI 전체를 재검증한 결과는 아니다.
