#!/usr/bin/env python3
"""Render English guide PNGs from production SwiftUI views without display interaction."""
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "build/media-refresh/identity"
WORK.mkdir(parents=True, exist_ok=True)
subprocess.run(["swift", "build", "--target", "AgentFloatCore"], cwd=ROOT, check=True)
binary_dir = Path(subprocess.check_output(
    ["swift", "build", "--show-bin-path"], cwd=ROOT, text=True
).strip())
sources = sorted(path for path in (ROOT / "Sources/AgentFloat").rglob("*.swift") if path.name != "main.swift")
objects = sorted((binary_dir / "AgentFloatCore.build").glob("*.swift.o"))
if not objects:
    raise RuntimeError("AgentFloatCore object files are missing")
renderer = WORK / "render-identity"
subprocess.run([
    "swiftc", "-parse-as-library", "-swift-version", "6",
    "-target", f"{platform.machine()}-apple-macosx26.0",
    "-I", str(binary_dir / "Modules"),
    *map(str, sources), str(ROOT / "scripts/media/identity.swift"),
    *map(str, objects), "-o", str(renderer),
], cwd=ROOT, check=True)
environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_FLOAT_")}
environment["AGENT_FLOAT_LANGUAGE"] = "en"
subprocess.run([str(renderer), str(ROOT / "docs/media/en")], cwd=ROOT, env=environment, check=True)
