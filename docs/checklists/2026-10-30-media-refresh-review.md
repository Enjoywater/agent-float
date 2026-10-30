# 배지 적용 버전 미디어 검수

2026-10-30에 MacBook 내장 디스플레이(논리 1800×1169, Retina 배율 2)에서 네이티브 앱을 촬영했다. 별도 번들 `dev.enjoywater.agent-float.media`와 단색 가상 배경을 사용했다. 촬영 앱·배경은 작업 후 종료했다.

Claude/Codex 세션·질문·전송 결과는 가상 데이터다. 실제 모델 API 호출, 실제 터미널 이동·승인·답장 전송을 녹화한 자료가 아니다. 일반 모드의 실제 provider 동작을 이 미디어로 검증했다고 주장하지 않는다.

## 교체한 GIF 11개

모든 파일은 기존 이름·해상도를 유지하고 15fps 무한 반복 GIF로 변환했다. 주요 상태의 캡처 프레임과 전체 동작을 대조해 배지·텍스트·카드 경계를 확인했다. 촬영 명세와 앱 로그로 선택·입력·전송 결과를 확인했고, 승인 대기에서는 승인·이동을 누르지 않았다.

| 파일 | 이전 KB | 현재 KB | 출력 크기 |
|---|---:|---:|---|
| `hero-light.gif` | 844 | 394 | 460×574 |
| `reply-choice-light.gif` | 1590 | 929 | 480×720 |
| `hero-dark.gif` | 973 | 405 | 460×574 |
| `reply-choice-dark.gif` | 1749 | 972 | 480×720 |
| `reply-multi.gif` | 1647 | 1259 | 480×720 |
| `reply-body.gif` | 1657 | 1155 | 480×720 |
| `reply-permission.gif` | 1060 | 480 | 480×720 |
| `guard-draft.gif` | 1571 | 1238 | 480×720 |
| `guard-mismatch.gif` | 1976 | 1008 | 480×720 |
| `placement-inline.gif` | 1523 | 1159 | 480×982 |
| `placement-card.gif` | 1234 | 904 | 720×680 |

교체 대상 합계는 15.45MB → 9.67MB로 약 37.4% 줄었다. 전체 GIF 바이트 합계 기준이며 원본 영상 용량은 포함하지 않는다.

- 혼합 목록: 라이트·다크 모두 Claude와 Codex 배지가 보인다.
- 선택지 답장: 라이트·다크 모두 Codex 배지가 목록과 답장 헤더에 이어진다.
- 여러 질문: Claude에서 두 질문에 답하고, 확인 화면에서 첫 답을 수정한 뒤 보낸다.
- 본문 질문: Codex에서 가상 답을 입력하고 보낸다.
- 승인 대기: Claude의 가상 명령과 읽기 전용 안내를 보여 준다.
- 기존 입력 감지: 보내지 않았다는 이유와 작성 중인 답을 보여 준다.
- 기록 불일치: 같은 질문의 다른 선택지가 기록된 것으로 재현하며 FAIL을 보여 준다.
- 줄 안 펼침·옆 카드: 각각 Claude와 Codex 배지가 유지되고, 질문·전송 UI가 촬영 영역 안에 들어간다.

## 유지한 GIF 14개

`state-{ask,running,new,unknown}-{light,dark}.gif` 8개와 `bg-{light,dark,doc,sonoma,code,vivid}.gif` 6개는 접힌 알약만 보여 주어 배지가 등장하지 않는다. 시간대별 프레임과 시작·종료 프레임을 대조했고, 상태 GIF의 모든 프레임에서 알약 바깥 영역이 정지 상태인 것도 확인했다. 배지 추가로 인한 UI 차이가 없어 유지한다. 배경 GIF의 팔레트 변화는 목록 펼침으로 해석하지 않았다.

현재 배지의 SwiftUI 렌더링 PNG 2개와 로고 PNG는 유지한다. Codex notes 전용 GIF 신설은 이번 교체 범위에 포함하지 않았다.

## 재현과 검증 자료

- [촬영 도구와 사용법](../../scripts/media/README.md)
- [촬영 명세](../../scripts/media/shots.json)
- [출력 크기·길이·프레임·해시 기록](../media/capture-manifest.json)
- 원본 MOV·장면별 실행 설정·크롭 좌표·검수 PNG·원본 앱 로그는 로컬 `build/media-refresh/`에 보관했다.
- 촬영 시점의 앱 소스는 기준 커밋 위 작업 중인 변경을 포함한다. 공개 manifest는 이 사실을 `source_working_tree_modified`로 표시한다.
- 가상 시나리오와 입력 경로 변경 후 Swift 테스트 468개가 통과했다.
- README와 소개서의 교체 GIF URL에는 새 캐시 버전을 붙였고, 소개서의 배지 적용 전 화면 안내를 현재 촬영 안내로 바꿨다.
- 사용자의 요청으로 최종 GIF 11개와 로컬 HTML 미리보기를 Desktop 검토 폴더에도 복사했다.

## 배포 확인

미디어 교체 커밋 `1d3cda3`의 GitHub Pages 빌드가 성공했다. [기능소개서](https://enjoywater.github.io/agent-float/)의 현재 촬영 안내와 새 캐시 버전을 확인했고, GIF 11개 모두 HTTP 200 응답과 검수본 SHA-256 일치를 확인했다. Desktop 검토 복사본도 같은 해시다.
