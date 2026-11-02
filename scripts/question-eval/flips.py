"""Summarise judgement changes; write flipped samples for local review only.

usage: python3 -I flips.py <samples.jsonl> <base.txt> <head.txt> <flips.jsonl>
"""
import json
import sys

samples = [json.loads(line) for line in open(sys.argv[1])]
base = [line.strip() for line in open(sys.argv[2])]
head = [line.strip() for line in open(sys.argv[3])]
assert len(samples) == len(base) == len(head), "sample and judgement counts differ"
flips = []
for sample, before, after in zip(samples, base, head):
    if before != after:
        flips.append({"from": before, "to": after, "src": sample["src"], "text": sample["text"]})
with open(sys.argv[4], "w") as out:
    for flip in flips:
        out.write(json.dumps(flip, ensure_ascii=False) + "\n")
total = len(samples)
print(f"samples={total} base_wait={base.count('1')} head_wait={head.count('1')}")
print(f"wait->done={sum(f['to'] == '0' for f in flips)} done->wait={sum(f['to'] == '1' for f in flips)}")
