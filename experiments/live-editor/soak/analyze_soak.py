"""Summarises a soak (soak.sh): frame times per minute, governor tiers, missed frames, CPU, memory, recordings.

    python3 -I experiments/live-editor/soak/analyze_soak.py <out dir> [<other out dir> ...]
"""
import glob
import json
import os
import subprocess
import sys


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                        "stream=nb_read_packets,r_frame_rate:format=duration", "-of", "json", path], capture_output=True, text=True)
    d = json.loads(r.stdout or "{}")
    s = (d.get("streams") or [{}])[0]
    fps = s.get("r_frame_rate", "30/1").split("/")
    return int(s.get("nb_read_packets", 0)), float(d.get("format", {}).get("duration", 0)), float(fps[0]) / float(fps[1])


def main(out):
    dumps = sorted(glob.glob(os.path.join(out, "m-[0-9]*.json")))
    end = os.path.join(out, "m-end.json")
    ms = [json.load(open(p)) for p in dumps] + ([json.load(open(end))] if os.path.exists(end) else [])
    if len(ms) < 2:
        print(out, "too few dumps"); return
    # The recording counters reset when recording stops, so the last dump (after the stop) only counts for time-based rows.
    recording = [m for m in ms if m["rendered"] and m is not ms[-1]] or ms
    rows = []
    for a, b in zip(ms, ms[1:]):
        dt = b["t"] - a["t"]
        rows.append({
            "p50": b["last60s"]["p50"], "p95": b["last60s"]["p95"], "p99": b["last60s"]["p99"], "max": b["last60s"]["max"],
            "transitions": b["last60s"]["transitionCount"], "tier": b["governor"]["tier"],
            "missed": b["recordingMissed"] - a["recordingMissed"], "late": b["lateFrames"] - a["lateFrames"],
            "drops": b["captureDrops"] - a["captureDrops"], "cpu%": 100 * (b["cpuSeconds"] - a["cpuSeconds"]) / dt,
            "mb": b["footprintMB"], "thermal": b["governor"]["thermal"],
        })
    pick = lambda k: [r[k] for r in rows]
    srt = lambda xs: sorted(xs)
    med = lambda xs: srt(xs)[len(xs) // 2]
    first, last = ms[0], ms[-1]
    summary = {
        "minutes": round((last["t"] - first["t"]) / 60, 1),
        "tick ms, median of minutes: p50 / p95 / p99": [round(med(pick("p50")), 2), round(med(pick("p95")), 2), round(med(pick("p99")), 2)],
        "tick ms, worst minute: p95 / p99 / max": [round(max(pick("p95")), 2), round(max(pick("p99")), 2), round(max(pick("max")), 2)],
        "minutes per tier (T0..T3)": [pick("tier").count(t) for t in range(4)],
        "governor reason at end": last["governor"]["reason"],
        "baseline": f'{last["governor"]["baseline"]:.1f} ms ({last["governor"]["baselineFrom"]})',
        "missed recording frames": max(m["recordingMissed"] for m in recording), "late ticks": sum(pick("late")), "camera drops": sum(pick("drops")),
        "recording dropped (encoder)": max(m["recordingDropped"] for m in recording),
        "minutes with a tick over 50 ms": sum(1 for r in rows if r["max"] > 50),
        "stream": last["stream"], "stream dropped": last["streamDropped"],
        "CPU % of one core, median / max minute": [round(med(pick("cpu%")), 1), round(max(pick("cpu%")), 1)],
        "memory MB, first / last / max": [round(rows[0]["mb"]), round(rows[-1]["mb"]), round(max(pick("mb")))],
        "thermal states seen": sorted(set(pick("thermal"))),
    }
    focus = os.path.join(out, "focus-end.json")
    if os.path.exists(focus):
        summary["clicks the live editor took"] = json.load(open(focus)).get("clicks")
    files = sorted(glob.glob(os.path.join(out, "rec", "*.mov")) + glob.glob(os.path.join(out, "rec", "*.mp4")))
    recs = []
    for f in files:
        n, dur, fps = probe(f)
        recs.append({"file": os.path.basename(f), "frames": n, "seconds": round(dur, 2), "expected": round(dur * fps), "diff": n - round(dur * fps)})
    summary["recordings"] = recs
    print(out); print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    for o in sys.argv[1:]:
        main(o)
