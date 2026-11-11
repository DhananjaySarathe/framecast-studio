"""Scores a live-editor trace (fcctl focus-trace) from click_tour.sh against the v11.0 acceptance tests.

Assumes the screen layer shows the whole main display (1512 x 982 pt here) with no crop or mirror.
"""
import json
import sys

DESK = (1512.0, 982.0)
FRAME = 1 / 30


def main(path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    clicks = [r for r in rows if r.get("event") == "click"]
    frames = [r for r in rows if "canvas" in r]
    ticks = [r for r in rows if "tick" in r]
    by = {}
    for r in frames:
        by.setdefault(r["canvas"], []).append(r)
    out = {"clicks": len(clicks), "frames": {k: len(v) for k, v in by.items()}}
    starts, settles, inside, idle_back = [], [], [], []
    same_frame = []
    for i, c in enumerate(clicks):
        t0 = c["t"]
        nxt = clicks[i + 1]["t"] if i + 1 < len(clicks) else 1e18
        first = {}
        for canvas, fr in by.items():
            before = [r for r in fr if r["t"] < t0]
            after = [r for r in fr if t0 <= r["t"] < nxt]
            if not before or not after:
                continue
            z0 = before[-1]["zoom"]
            rise = next((r for r in after if r["zoom"] > z0 + 1e-3), None)
            if rise is None:
                continue
            first[canvas] = rise["t"]
            starts.append((canvas, rise["t"] - t0))
            target = max(r["zoom"] for r in after if r["t"] < t0 + 3)
            settle = next((r for r in after if abs(r["zoom"] - target) <= 0.02 * target), None)
            if settle:
                settles.append((canvas, settle["t"] - t0))
            # The click point is in the view 1.5 s later.
            at = next((r for r in after if r["t"] >= t0 + 1.5), None)
            if at:
                px, py = c["x"] / DESK[0], c["y"] / DESK[1]
                ok = abs(px - at["cx"]) <= at["vw"] / 2 + 1e-6 and abs(py - at["cy"]) <= at["vh"] / 2 + 1e-6
                inside.append((canvas, ok))
            # Back at the base zoom within 1 s of the quiet spell (5 s after the last click or cursor move).
            quiet = next((r for r in after if r["reason"] == "quiet"), None)
            if quiet:
                base = quiet.get("base", 1)
                back = next((r for r in after if r["t"] >= quiet["t"] and abs(r["zoom"] - base) <= 0.02 * base), None)
                if back:
                    idle_back.append((canvas, back["t"] - quiet["t"]))
        if len(first) == 2:
            same_frame.append(abs(first["horizontal"] - first["vertical"]) < 0.004)
    zoomed = [r for r in frames if r["zoom"] > r.get("base", 1) * 1.05 and r["px"] >= 0]
    safe = [abs(r["px"] - r["cx"]) <= 0.375 * r["vw"] + 1e-6 and abs(r["py"] - r["cy"]) <= 0.375 * r["vh"] + 1e-6 for r in zoomed]
    over = [r for r in frames if r["zoom"] > r["zmax"] + 1e-6]
    last = frames[-1]["t"] if frames else 0
    still = {}
    for canvas, fr in by.items():
        tail = [r for r in fr if r["t"] >= last - 9]
        if tail:
            still[canvas] = max(abs(tail[-1]["cx"] - tail[0]["cx"]), abs(tail[-1]["cy"] - tail[0]["cy"]), abs(tail[-1]["zoom"] - tail[0]["zoom"]))
    tick = sorted(r["tick"] for r in ticks if not r.get("transition"))
    p = lambda q: tick[min(len(tick) - 1, int(round((len(tick) - 1) * q)))] if tick else 0
    out.update({
        "start after click, ms (max)": round(max(s for _, s in starts) * 1000, 1) if starts else None,
        "starts within 2 frames": all(s <= 2 * FRAME + 0.002 for _, s in starts),
        "settle within 2 % of target, s (max)": round(max(s for _, s in settles), 3) if settles else None,
        "settles within 0.9 s": all(s <= 0.9 for _, s in settles),
        "click point in view 1.5 s later": f"{sum(ok for _, ok in inside)}/{len(inside)}",
        "back at base after the quiet spell starts, s (max)": round(max(s for _, s in idle_back), 3) if idle_back else None,
        "cursor in the middle 75 % while zoomed": f"{100 * sum(safe) / max(1, len(safe)):.1f} % of {len(safe)} frames",
        "both canvases start on the same frame": f"{sum(same_frame)}/{len(same_frame)}",
        "frames past the sharpness limit": len(over),
        "still for 9 s, largest change (fraction of picture / zoom)": {k: round(v, 6) for k, v in still.items()},
        "tick ms p50 / p95 / p99 / max (steady)": [round(p(0.5), 2), round(p(0.95), 2), round(p(0.99), 2), round(tick[-1], 2) if tick else 0],
    })
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main(sys.argv[1])
