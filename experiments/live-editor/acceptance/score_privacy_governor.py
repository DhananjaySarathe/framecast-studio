"""Scores privacy_governor.sh: the privacy guards (from focus dumps and the trace) and the governor's tiers."""
import json
import os
import sys

DESK = (1512.0, 982.0)
HELPER = (100, 382, 400, 682)   # NeverZoomTest's window, desktop points, top-left origin: x0, y0, x1, y1


def main(out):
    load = lambda name: json.load(open(os.path.join(out, name)))
    level = lambda d: next(iter(d["sources"].values())).split(" ")[0] if d["sources"] else "none"
    d = {n: load(n + ".json") for n in ["1-secure", "2-secure-off", "3-menubar", "4-own-window", "5-next-to-never-zoom",
                                        "6-on-never-zoom", "7-reset", "8-paused"]}
    results = []
    def check(name, ok, detail=""):
        results.append((name, ok, detail))
    check("no zoom while a password field has the keyboard", level(d["1-secure"]) == "overview", level(d["1-secure"]))
    check("zooms again once it's gone", level(d["2-secure-off"]) == "click", level(d["2-secure-off"]))
    check("a click on the menu bar is ignored", d["3-menubar"]["clicks"] == d["2-secure-off"]["clicks"], f'clicks {d["2-secure-off"]["clicks"]} → {d["3-menubar"]["clicks"]}')
    check("a click on Framecast's own window is ignored while it isn't shared", d["4-own-window"]["clicks"] == d["3-menubar"]["clicks"],
          f'clicks {d["3-menubar"]["clicks"]} → {d["4-own-window"]["clicks"]}')
    check("a click next to a never-zoom window zooms", level(d["5-next-to-never-zoom"]) == "click", level(d["5-next-to-never-zoom"]))
    check("a click on a never-zoom window is ignored", d["6-on-never-zoom"]["clicks"] == d["5-next-to-never-zoom"]["clicks"],
          f'clicks {d["5-next-to-never-zoom"]["clicks"]} → {d["6-on-never-zoom"]["clicks"]}')
    check("the reset key goes back to the whole screen", level(d["7-reset"]) == "overview", level(d["7-reset"]))
    check("…and a click right after doesn't zoom (paused)", level(d["8-paused"]) == "overview" and d["8-paused"]["clicks"] > d["7-reset"]["clicks"],
          f'{level(d["8-paused"])}, clicks {d["7-reset"]["clicks"]} → {d["8-paused"]["clicks"]}')
    # The zoomed views after the click next to the never-zoom window never show it.
    rows = [json.loads(l) for l in open(os.path.join(out, "trace.jsonl")) if l.strip()]
    clicks = [r for r in rows if r.get("event") == "click" and abs(r["x"] - 430) < 1 and abs(r["y"] - 530) < 1]
    hx0, hy0, hx1, hy1 = HELPER[0] / DESK[0], HELPER[1] / DESK[1], HELPER[2] / DESK[0], HELPER[3] / DESK[1]
    shown = []
    if clicks:
        t0 = clicks[0]["t"]
        for r in rows:
            if "canvas" in r and t0 + 0.9 <= r["t"] <= t0 + 4 and r["zoom"] > 1.0001:
                x0, x1 = r["cx"] - r["vw"] / 2, r["cx"] + r["vw"] / 2
                y0, y1 = r["cy"] - r["vh"] / 2, r["cy"] + r["vh"] / 2
                if x0 < hx1 - 1e-4 and x1 > hx0 + 1e-4 and y0 < hy1 - 1e-4 and y1 > hy0 + 1e-4:
                    shown.append((r["canvas"], round(r["t"] - t0, 2)))
    check("zoomed views keep the never-zoom window out", bool(clicks) and not shown, f"{len(shown)} frames show it" if shown else "")
    # Governor tiers.
    g = {n: load(n + ".json")["governor"] for n in ["g0", "g1-t1", "g2-t2", "g3-recover1", "g4-recover2", "g5-t3", "g6-reenabled"]}
    check(f'baseline known ({g["g0"]["baselineFrom"]}, {g["g0"]["baseline"]:.1f} ms)', g["g0"]["baselineFrom"] in ("learned", "measured"))
    for name, want in [("g1-t1", 1), ("g2-t2", 2), ("g3-recover1", 1), ("g4-recover2", 0), ("g5-t3", 3), ("g6-reenabled", 0)]:
        check(f"governor {name}: tier {want}", g[name]["tier"] == want, f'tier {g[name]["tier"]}, {g[name]["reason"]}, p95 {g[name]["steadyP95"]:.1f}')
    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'}  {name}{'  (' + detail + ')' if detail else ''}")
    print(f"{sum(ok for _, ok, _ in results)}/{len(results)} passed")


if __name__ == "__main__":
    main(sys.argv[1])
