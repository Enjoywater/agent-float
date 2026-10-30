# 미디어 촬영 도구

가상 세션이 있는 최신 네이티브 앱을 촬영하기 위한 준비 도구다. `docs/media`의 최종 파일은 자동으로 덮어쓰지 않는다.

## 화면 제어 전에 할 수 있는 준비

```sh
python3 scripts/media/media.py check
python3 scripts/media/media.py list
python3 scripts/media/media.py show hero-light
python3 scripts/media/media.py prepare
```

`prepare`는 release 바이너리를 빌드해 `build/media-refresh/Agent Float Media.app`을 만든다. 앱을 실행하거나 스크린샷을 찍지 않는다. 번들 식별자는 `dev.enjoywater.agent-float.media`이며 설치된 앱과 설정 저장소를 공유하지 않는다. 설치된 앱을 종료하거나 교체하지 않는다. 빌드 기록은 `build/media-refresh/prepared.json`에 남는다.

내장 디스플레이용 가상 배경 실행 파일 `build/media-refresh/background`도 빌드한다. `background` 또는 `background dark`로 실행하며, 실제 촬영 단계에서만 띄운다. 사용자 배경화면 설정은 바꾸지 않는다.

`shots.json`은 기존 GIF 25개의 촬영 명세다. `required` 11개를 먼저 교체하고, `review` 14개는 기존 녹화의 전체 프레임을 검토해 교체 여부를 정한다. 장면과 에이전트 선택은 `AGENT_FLOAT_MEDIA_SCENE`·`AGENT_FLOAT_MEDIA_AGENT`로 전달하며, `AGENT_FLOAT_FAKE_SESSIONS`가 켜져 있을 때만 적용된다.

가상 모드에서는 실제 provider·터미널 navigator·포커스 probe를 사용하지 않는다. 답장 결과는 가상 backend가 만든다. 실전 전송이나 이동이 검증된 영상으로 소개하지 않는다.

## 아래부터는 화면을 사용하는 단계

앱 실행은 화면에 패널을 띄우고, 답장 조작은 포커스를 바꿀 수 있다. 사용자에게 촬영 시작을 알린 뒤 실행한다. 준비 단계에서는 아래 명령을 실행하지 않는다.

```sh
python3 scripts/media/media.py launch hero-light
```

질문 장면은 `launch reply-choice-light --open-reply`처럼 실행할 수 있다. 이때 촬영 앱 PID에 `USR1`을 보내면 목록을 펼치고 1초 뒤 `fake-media-target` 질문을 연다. 평소 포커스를 가져오지 않는 목록에 합성 클릭을 보내지 않고도 답장 진입을 재현하는 방법이다. `USR2`는 목록을 접는다.

질문을 연 뒤에는 `python3 scripts/media/control.py reply-choice-light`처럼 실제 UI를 조작할 수 있다. 이 명령도 마우스·포커스를 사용한다. `computer-use` 스킬의 Orca CLI를 사용하며, 실행 중인 촬영 앱의 PID·실행 경로·번들 ID·장면을 확인한 뒤 신선한 접근성 트리에서 선택지·입력 칸·버튼을 찾는다. 실제 사용자 세션에는 입력하지 않는다. 다중 질문의 확인·수정, 본문 입력, 가상 성공·실패 결과도 재현한다. 명령 반환만으로 전송 성공을 판단하지 않고 선택 상태·입력 값과 가상 backend의 결과를 확인한다.

첫 시범 촬영은 `hero-light`, `reply-choice-light`, `placement-card` 순서로 한다. `show`에 나온 조작을 실행하고, 앱 로그 `build/media-refresh/app.log`에서 위치를 확인한다. 설치된 앱이 구도에 들어오면 촬영 단계에서 정리한다. 현재 모니터의 좌표·배율·카드 최대 범위를 확인해 촬영 영역을 정한다.

녹화는 비대화형 macOS `screencapture`를 사용한다. 예를 들어 출력 460×574와 같은 비율의 화면 영역을 정한 뒤 녹화한다. 아래 좌표는 예시이므로 실제 위치로 바꿔야 한다.

```sh
python3 scripts/media/media.py record hero-light --rect 100,100,460,574
```

명령은 지정된 시간 동안 녹화하므로 실행 중에 화면 조작을 진행한다. 조작 자체는 이 Python 스크립트가 대신하지 않는다. 녹화 파일은 `build/media-refresh/takes/<장면>/<시각>/raw.mov`에 저장된다. 원본 영상의 실제 해상도·fps·촬영 영역과 실행 설정도 manifest에 기록한다. 화면 기록 권한과 GUI 조작 도구의 손쉬운 사용 권한은 실제 촬영 단계에서 확인해야 한다. `check`는 권한을 요청하거나 녹화를 시험하지 않는다.

macOS 화면 기록이 선택한 원본 fps를 보장한다고 가정하지 않는다. 원본의 실제 fps를 확인하고, 변환할 때 15fps로 맞춘다. 원본은 가급적 30fps 이상을 확보한다.

```sh
python3 scripts/media/media.py convert build/media-refresh/takes/hero-light/<시각>
python3 scripts/media/media.py stop
```

변환은 출력 크기·팔레트·반복 재생을 적용하고 같은 take 폴더에 GIF를 만든다. 기존 출력이 있으면 덮어쓰지 않는다. `stop`은 기록한 촬영 앱 PID와 실행 경로를 확인한 뒤 종료하며, 설치된 앱을 대상으로 하지 않는다.

## 검수와 반영

- 우선 3개 시험 촬영에서 배지 가독성, 커서 위치, 그림자·카드 잘림과 움직임을 확인한다.
- 실제 표시 크기에서도 이름이 읽히는지 확인한 뒤 최종 GIF만 `docs/media`에 반영한다.
- 가상 데이터·배경만 녹화됐는지 영상을 직접 확인한다. manifest의 로컬 절대 경로는 공개 문서에 복사하기 전에 제거한다.
- 원본·중간 파일과 빌드 결과는 `.gitignore`의 `build/` 아래에 보관한다.
- 전체 범위와 완료 기준은 [확보 계획](../../docs/plans/2026-10-30-media-refresh.md)을 따른다.
