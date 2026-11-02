"""Extract the reply text agent-float judges when a session goes idle.

Mirrors TranscriptReader.consumeAssistant: the last non-empty text block of the
last assistant record before the next real user prompt. Output contains raw
conversation text, so it must stay outside the repository.

usage: python3 -I extract.py <out.jsonl> [days=60]
"""
import glob
import json
import os
import sys
import time

out_path = sys.argv[1]
days = int(sys.argv[2]) if len(sys.argv) > 2 else 60
cutoff = time.time() - days * 86400
seen = set()
stats = {"files": 0, "samples": 0, "duplicates": 0}


def is_prompt(rec):
    # Tool results and local command echoes are recorded as "user" but are not a person answering.
    if rec.get("type") != "user" or rec.get("isMeta") or rec.get("isSidechain"):
        return False
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        return not content.startswith(("<local-command", "<command-name", "<command-message", "<task-notification"))
    if isinstance(content, list):
        blocks = [b for b in content if isinstance(b, dict)]
        return any(b.get("type") == "text" for b in blocks) and not any(b.get("type") == "tool_result" for b in blocks)
    return False


with open(out_path, "w") as out:
    def emit(text, source):
        if not text:
            return
        # Retried turns repeat the same reply; counting them twice would skew rates.
        if text in seen:
            stats["duplicates"] += 1
            return
        seen.add(text)
        stats["samples"] += 1
        out.write(json.dumps({"src": source, "text": text}, ensure_ascii=False) + "\n")

    for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
        if os.path.getmtime(path) < cutoff:
            continue
        stats["files"] += 1
        last = None
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("type") == "assistant" and not rec.get("isSidechain"):
                    blocks = (rec.get("message") or {}).get("content") or []
                    text = None
                    for b in blocks if isinstance(blocks, list) else []:
                        if isinstance(b, dict) and b.get("type") == "text" and (b.get("text") or "").strip():
                            text = b["text"]
                    if text:
                        last = text
                elif is_prompt(rec):
                    emit(last, "claude")
                    last = None
        emit(last, "claude")

    # Codex records the final reply of each turn on its task_complete event.
    for path in glob.glob(os.path.expanduser("~/.codex/sessions/**/*.jsonl"), recursive=True):
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                payload = rec.get("payload") or {}
                if rec.get("type") == "event_msg" and payload.get("type") == "task_complete" and payload.get("last_agent_message"):
                    emit(payload["last_agent_message"], "codex")

print(json.dumps(stats), file=sys.stderr)
