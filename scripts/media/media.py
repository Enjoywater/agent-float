#!/usr/bin/env python3
"""네이티브 앱 미디어 준비. prepare/check/show는 앱 실행·화면 캡처를 하지 않는다."""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "build/media-refresh"
APP = WORK / "Agent Float Media.app"
EXECUTABLE = APP / "Contents/MacOS/AgentFloat"
BUNDLE_ID = "dev.enjoywater.agent-float.media"
SHOTS = json.loads(Path(__file__).with_name("shots.json").read_text())["shots"]


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, **kwargs)


def output(args):
    return run(args, text=True, capture_output=True).stdout.strip()


def shot_for(name):
    return next((s for s in SHOTS if s["file"] == name or s["file"] == name + ".gif"), None)


def environment(shot):
    return {
        "AGENT_FLOAT_FAKE_SESSIONS": "4",
        "AGENT_FLOAT_MEDIA_SCENE": shot["scene"],
        "AGENT_FLOAT_MEDIA_AGENT": shot["agent"],
        "AGENT_FLOAT_APPEARANCE": shot["theme"],
        "AGENT_FLOAT_REPLY_PLACEMENT": shot["placement"],
        "AGENT_FLOAT_FAKE_REPLY": shot["result"],
        "AGENT_FLOAT_FAKE_REPLY_STAGE_DELAY": "0.6",
        "AGENT_FLOAT_CONTRAST": "outline",
        "AGENT_FLOAT_DEBUG": "1",
    }


def check():
    names = [s["file"] for s in SHOTS]
    assert len(names) == len(set(names)) == 25
    for shot in SHOTS:
        assert (ROOT / "docs/media" / shot["file"]).is_file(), shot["file"]
        assert shot["scene"] in {"mixed", "choice", "multi", "body", "permission", "ask", "running", "new", "unknown"}
        assert shot["agent"] in {"claude", "codex"}
        assert shot["theme"] in {"light", "dark"}
        assert shot["placement"] in {"panel", "inline", "card"}
        assert shot["result"] in {"delivered", "draft", "mismatch"}
        assert 0 < shot["seconds"] <= 30
        assert all(isinstance(n, int) and n > 0 for n in shot["size"])
    for tool in ("swift", "ffmpeg", "ffprobe", "codesign"):
        if not shutil.which(tool):
            raise RuntimeError(f"필요한 도구가 없습니다: {tool}")
    if EXECUTABLE.exists():
        with (APP / "Contents/Info.plist").open("rb") as stream:
            assert plistlib.load(stream)["CFBundleIdentifier"] == BUNDLE_ID
        run(["codesign", "--verify", "--strict", APP])
    print(f"촬영 명세 {len(SHOTS)}개 검증 완료. 번들: {'준비됨' if EXECUTABLE.exists() else '미준비'}")


def prepare():
    if (WORK / "launch.json").exists():
        raise RuntimeError("촬영 앱을 stop으로 정리한 뒤 빌드하세요.")
    check()
    run(["swift", "build", "-c", "release"])
    binary_dir = Path(output(["swift", "build", "-c", "release", "--show-bin-path"]))
    WORK.mkdir(parents=True, exist_ok=True)
    if APP.exists():
        shutil.rmtree(APP)
    (APP / "Contents/MacOS").mkdir(parents=True)
    resources = APP / "Contents/Resources"
    resources.mkdir()
    shutil.copy2(binary_dir / "AgentFloat", EXECUTABLE)
    with (ROOT / "Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    info.update(CFBundleIdentifier=BUNDLE_ID, CFBundleName="Agent Float Media", CFBundleDisplayName="Agent Float Media")
    with (APP / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    for name in ("AppIcon.icns", "MenuBarIcon.png", "MenuBarIcon@2x.png"):
        shutil.copy2(ROOT / "Resources" / name, resources / name)
    run(["codesign", "--force", "--sign", "-", APP])
    run(["swiftc", ROOT / "scripts/media/backdrop.swift", "-o", WORK / "background"])
    (WORK / "prepared.json").write_text(json.dumps({
        "source_commit": output(["git", "rev-parse", "HEAD"]),
        "working_tree_changes": output(["git", "status", "--porcelain"]),
        "bundle_id": BUNDLE_ID,
        "prepared_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "gui_started": False,
    }, ensure_ascii=False, indent=2) + "\n")
    check()
    print("준비 완료: 앱을 실행하지 않았습니다.")


def current_launch(shot=None):
    state = json.loads((WORK / "launch.json").read_text())
    command = output(["ps", "-p", str(state["pid"]), "-o", "command="])
    if command != str(EXECUTABLE):
        raise RuntimeError("촬영용 앱 프로세스를 확인할 수 없습니다.")
    if shot is not None and state["shot"] != shot["file"]:
        raise RuntimeError("촬영 명세와 실행 중인 장면이 다릅니다.")
    return state


def launch(shot, open_reply=False):
    if not EXECUTABLE.exists():
        raise RuntimeError("먼저 prepare를 실행하세요.")
    if (WORK / "launch.json").exists():
        raise RuntimeError("이전 촬영 앱은 stop으로 정리한 뒤 실행하세요.")
    env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_FLOAT_")}
    env.update(environment(shot))
    if open_reply:
        env.update(AGENT_FLOAT_OPEN_REPLY="0", AGENT_FLOAT_OPEN_REPLY_SESSION="fake-media-target")
    log = WORK / "app.log"
    with log.open("wb") as stream:
        process = subprocess.Popen([str(EXECUTABLE)], env=env, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
    (WORK / "launch.json").write_text(json.dumps({"pid": process.pid, "shot": shot["file"], "environment": {k: v for k, v in env.items() if k.startswith("AGENT_FLOAT_")}}, indent=2) + "\n")
    print(f"촬영 앱 PID {process.pid}. 로그: {log}")


def record(shot, rect):
    state = current_launch(shot)
    x, y, width, height = [int(n) for n in rect.split(",")]
    if width <= 0 or height <= 0:
        raise ValueError("촬영 너비·높이는 양수여야 합니다.")
    target_width, target_height = shot["size"]
    if abs(width / height - target_width / target_height) > 0.005:
        raise ValueError("촬영 영역과 출력 크기의 가로세로 비율을 맞추세요.")
    take = WORK / "takes" / Path(shot["file"]).stem / datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    take.mkdir(parents=True)
    run(["/usr/sbin/screencapture", "-v", "-x", f"-R{x},{y},{width},{height}", f"-V{shot['seconds']}", take / "raw.mov"])
    metadata = {
        **shot, "rect": [x, y, width, height], "launch": state,
        "prepared": json.loads((WORK / "prepared.json").read_text()),
        "macos": output(["sw_vers", "-productVersion"]),
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "raw_video": json.loads(output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", take / "raw.mov"])),
    }
    (take / "manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"원본과 촬영 기록: {take}")


def convert(take):
    take = Path(take).resolve()
    if not take.is_relative_to(WORK / "takes"):
        raise ValueError("build/media-refresh/takes 아래의 촬영 원본만 변환합니다.")
    metadata = json.loads((take / "manifest.json").read_text())
    width, height = metadata["size"]
    gif = take / metadata["file"]
    filters = f"fps=15,scale={width}:{height}:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-n", "-i", take / "raw.mov", "-filter_complex", filters, "-loop", "0", gif])
    metadata["gif"] = {"bytes": gif.stat().st_size, "fps": 15, "probe": json.loads(output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", gif]))}
    (take / "manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"변환 완료: {gif}\ndocs/media에는 아직 반영하지 않았습니다.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "prepare", "list", "stop"):
        subs.add_parser(name)
    for name in ("show", "launch", "record"):
        sub = subs.add_parser(name)
        sub.add_argument("shot")
        if name == "record":
            sub.add_argument("--rect", required=True, help="화면 좌표 x,y,w,h. 이 명령부터 실제 화면을 녹화합니다.")
        if name == "launch":
            sub.add_argument("--open-reply", action="store_true", help="USR1 펼침 후 지정된 가상 질문을 자동으로 연다.")
    subs.add_parser("convert").add_argument("take")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "check":
        check()
    elif args.command == "list":
        for shot in SHOTS:
            print(f"{shot['priority']:8} {shot['file']:28} {shot['agent']:6} {shot['theme']:5} {shot['scene']}")
    elif args.command == "stop":
        state = current_launch()
        os.kill(state["pid"], signal.SIGTERM)
        (WORK / "launch.json").unlink()
    elif args.command == "convert":
        convert(args.take)
    else:
        shot = shot_for(args.shot)
        if shot is None:
            parser.error("촬영 명세에 없는 파일입니다. list로 목록을 확인하세요.")
        if args.command == "show":
            print(json.dumps({**shot, "environment": environment(shot)}, ensure_ascii=False, indent=2))
        elif args.command == "launch":
            launch(shot, args.open_reply)
        else:
            record(shot, args.rect)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"media: {error}", file=sys.stderr)
        sys.exit(1)
