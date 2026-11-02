#!/bin/sh
# Judge the same samples with the heuristic at <base-ref> and in the working tree, then list flips.
# usage: scripts/question-eval/compare.sh <samples.jsonl> <work-dir outside the repo> [base-ref=HEAD]
set -eu
SAMPLES=$1
WORK=$2
BASE=${3:-HEAD}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
SRC=Sources/AgentFloatCore/Claude/QuestionHeuristic.swift
mkdir -p "$WORK"
git -C "$ROOT" show "$BASE:$SRC" > "$WORK/base.swift"
swiftc -O -o "$WORK/base" "$WORK/base.swift" "$HERE/main.swift"
swiftc -O -o "$WORK/head" "$ROOT/$SRC" "$HERE/main.swift"
"$WORK/base" < "$SAMPLES" > "$WORK/base.txt"
"$WORK/head" < "$SAMPLES" > "$WORK/head.txt"
python3 -I "$HERE/flips.py" "$SAMPLES" "$WORK/base.txt" "$WORK/head.txt" "$WORK/flips.jsonl"
