#!/usr/bin/env python3
"""실행 중인 촬영 앱의 가상 답장을 조작한다. 이 명령은 마우스·포커스를 사용한다."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

from media import BUNDLE_ID, WORK, current_launch, shot_for

ORCA = os.environ.get("ORCA_CLI_COMMAND") or ("orca-dev" if os.environ.get("ORCA_DEV_REPO_ROOT") else "orca")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("shot")
    args = parser.parse_args()
    shot = shot_for(args.shot)
    if shot is None:
        parser.error("촬영 명세에 없는 장면입니다.")
    state = current_launch(shot)
    pid = state["pid"]
    observations = []

    def call(command, *arguments):
        result = subprocess.run(
            [ORCA, "computer", command, *arguments, "--app", f"pid:{pid}", "--json", "--no-screenshot"],
            text=True, capture_output=True,
        )
        data = json.loads(result.stdout)
        if not data.get("ok"):
            raise RuntimeError(data.get("error"))
        snapshot = data["result"]["snapshot"]
        assert snapshot["app"]["bundleId"] == BUNDLE_ID
        tree = snapshot["treeText"]
        observations.append({"time": time.time(), "command": command, "tree": tree})
        return tree

    tree = call("get-app-state")
    assert "에이전트 이름 표시" in tree or "배포 순서" in tree or "SyncRetryPolicy" in tree or shot["scene"] == "permission", tree

    def choose(tree, option):
        # 줄 안 배치는 footer도 같은 깊이에 있어, 직접 입력 칸 앞의 선택지만 고른다.
        options = tree.split("텍스트 필드", 1)[0]
        buttons = re.findall(r"^\t\t(\d+) 버튼(?: \(selected\))?$", options, re.M)
        assert len(buttons) == 2, tree
        tree = call("click", "--element-index", buttons[option])
        assert "버튼 (selected)" in tree, tree
        return tree

    def primary(tree):
        indent = "\t\t" if shot["placement"] == "inline" else "\t"
        buttons = re.findall(r"^" + indent + r"(\d+) 버튼$", tree, re.M)
        assert buttons, tree
        return call("click", "--element-index", buttons[-1])

    time.sleep(.8)
    if shot["scene"] == "permission":
        assert "swift test" in tree
        print("가상 승인 내용 확인. 승인이나 터미널 이동을 실행하지 않습니다.", flush=True)
    else:
        if shot["scene"] == "body":
            fields = re.findall(r"^\t+(\d+) 텍스트 (?:필드|영역).*settable.*$", tree, re.M)
            assert len(fields) == 1, tree
            text = "네, 서버 설정값으로 분리해 주세요."
            tree = call("set-value", "--element-index", fields[0], "--value", text)
            assert text in tree, tree
        else:
            tree = choose(tree, 0)
        time.sleep(.8)
        if shot["scene"] == "multi":
            tree = primary(tree)
            assert "색인 주기" in tree, tree
            time.sleep(.8)
            tree = choose(tree, 1)
            tree = primary(tree)
            assert "이렇게 보낼게요" in tree, tree
            time.sleep(.8)
            edits = re.findall(r"^\t\t(\d+) 버튼$", tree, re.M)
            assert len(edits) == 2, tree
            tree = call("click", "--element-index", edits[0])
            tree = choose(tree, 1)
            tree = primary(tree)
            assert "이렇게 보낼게요" in tree, tree
            time.sleep(.8)
        tree = primary(tree)
        expected = {"delivered": "outcome=delivered(", "draft": "terminalDraft", "mismatch": "outcome=mismatched("}[shot["result"]]
        seen_result = False
        for _ in range(50):
            if expected in (WORK / "app.log").read_text():
                seen_result = True
                break
            time.sleep(.1)
        assert seen_result, "가상 전송 결과를 확인하지 못했습니다."
        print(f"가상 전송 결과 확인: {shot['result']}", flush=True)
    log = WORK / f"control-{Path(shot['file']).stem}.json"
    log.write_text(json.dumps(observations, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
