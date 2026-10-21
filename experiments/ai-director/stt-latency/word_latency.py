#!/usr/bin/env python3
"""Per-word live-transcription latency from a `stt-latency --jsonl` run.

For every word of the settled (final) transcript: when it was spoken (end of its audio time range), when it FIRST
showed up spelled correctly in any result (volatile guesses included), and when its final result arrived.
Volatile results carry no word times, so a volatile result's words are lined up against the final words that start
where that result starts.

usage: python3 -I word_latency.py run.jsonl [more.jsonl …]
"""
import json, re, statistics, sys

def norm(w):
    return re.sub(r"[^\w.']", "", w.lower()).strip(".'")

def words_of(text):
    return [norm(w) for w in text.split() if norm(w)]

def final_words(results):
    out = []  # [norm, start, end, arrival]
    for r in results:
        if not r["final"]:
            continue
        text, spans, pos = "", [], 0
        for piece, s, e in r["pieces"]:
            spans.append((pos, pos + len(piece), s, e)); text += piece; pos += len(piece)
        for m in re.finditer(r"\S+", text):
            times = [(s, e) for a, b, s, e in spans if a < m.end() and b > m.start() and s is not None]
            if norm(m.group()) and times:
                out.append([norm(m.group()), min(t[0] for t in times), max(t[1] for t in times), r["t"]])
    return out

def analyse(path):
    results = [json.loads(l) for l in open(path) if l.strip()]
    fw = final_words(results)
    first = [None] * len(fw)
    for r in results:
        offset = next((i for i, w in enumerate(fw) if w[1] >= r["start"] - 0.05), None)
        if offset is None:
            continue
        for j, w in enumerate(words_of(r["text"])):
            k = offset + j
            if k < len(fw) and w == fw[k][0] and first[k] is None:
                first[k] = r["t"]
    seen = [first[k] - fw[k][2] for k in range(len(fw)) if first[k] is not None]
    settled = [w[3] - w[2] for w in fw]
    def s(xs):
        xs = sorted(xs)
        return f"median {statistics.median(xs):.2f} s, p90 {xs[int(len(xs) * 0.9)]:.2f} s, max {xs[-1]:.2f} s"
    print(f"{path}: {len(fw)} words")
    print(f"  first shown correctly after it was spoken: {s(seen)}")
    print(f"  settled (final) after it was spoken:       {s(settled)}")

for p in sys.argv[1:]:
    analyse(p)
