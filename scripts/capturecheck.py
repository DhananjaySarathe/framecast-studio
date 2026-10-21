#!/usr/bin/env python3
"""Numeric checks for capture tests (no frames are saved or shown).

  colors FILE   – per-second mean RGB of the centre of the picture; expects the test window's
                  red → green → blue cycle (window and app capture)
  activity FILE – luma statistics only, to show a display capture is live (not black, not frozen)
  tone FILE HZ  – level of a narrow band at HZ against a neighbouring band (system/app audio)
"""
import json
import re
import subprocess
import sys

FFPROBE, FFMPEG = "/opt/homebrew/bin/ffprobe", "/opt/homebrew/bin/ffmpeg"


def lavfi(path, chain, tags):
    esc = path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")
    out = subprocess.run([FFPROBE, "-v", "error", "-f", "lavfi", "-i", f"movie='{esc}',{chain}",
                          "-show_entries", "frame=pts_time:frame_tags=" + ",".join(tags), "-of", "json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)["frames"]


def colors(path):
    # Centre 30 % of the frame, averaged per channel (signalstats on each plane after rgb split is heavy;
    # scale to 1×1 and read the pixel instead).
    out = subprocess.run([FFMPEG, "-v", "error", "-i", path, "-vf", "crop=iw*0.3:ih*0.3,scale=1:1,format=rgb24", "-r", "4",
                          "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    px = [tuple(out[i:i + 3]) for i in range(0, len(out) - 2, 3)]
    names = []
    for r, g, b in px:
        m = max(r, g, b)
        if m < 120 or sorted((r, g, b))[1] > m * 0.6:
            names.append("other")
        else:
            names.append("red" if m == r else "green" if m == g else "blue")
    seen = [n for i, n in enumerate(names) if n != "other" and (i == 0 or names[i - 1] != n)]
    ok = all(c in names for c in ("red", "green", "blue"))
    # The cycle order must be red → green → blue → red.
    order = {"red": "green", "green": "blue", "blue": "red"}
    order_ok = all(order[a] == b for a, b in zip(seen, seen[1:]))
    print(json.dumps({"file": path, "samples": len(px), "sequence": seen[:12],
                      "all_three_colours": ok, "cycle_order_correct": order_ok,
                      "result": "PASS" if ok and order_ok else "FAIL"}))


def colors_any(path):
    """Like colors(), but looks for the test colours anywhere in a 48×27 thumbnail (app capture)."""
    out = subprocess.run([FFMPEG, "-v", "error", "-i", path, "-vf", "scale=48:27,format=rgb24", "-r", "4", "-f", "rawvideo", "-"],
                         capture_output=True, check=True).stdout
    frame = 48 * 27 * 3
    names = []
    for i in range(0, len(out) - frame + 1, frame):
        counts = {"red": 0, "green": 0, "blue": 0}
        for j in range(i, i + frame, 3):
            r, g, b = out[j], out[j + 1], out[j + 2]
            if r > 200 and g < 60 and b < 60: counts["red"] += 1
            elif g > 200 and r < 60 and b < 60: counts["green"] += 1
            elif b > 200 and r < 60 and g < 60: counts["blue"] += 1
        best = max(counts, key=counts.get)
        names.append(best if counts[best] >= 6 else "other")
    seen = [n for k, n in enumerate(names) if n != "other" and (k == 0 or names[k - 1] != n)]
    ok = all(c in names for c in ("red", "green", "blue"))
    order = {"red": "green", "green": "blue", "blue": "red"}
    order_ok = all(order[a] == b for a, b in zip(seen, seen[1:]))
    print(json.dumps({"file": path, "samples": len(names), "sequence": seen[:12], "all_three_colours": ok,
                      "cycle_order_correct": order_ok, "result": "PASS" if ok and order_ok else "FAIL"}))


def activity(path):
    f = lavfi(path, "signalstats", ["lavfi.signalstats.YAVG", "lavfi.signalstats.YMIN", "lavfi.signalstats.YMAX"])
    y = [float(x["tags"]["lavfi.signalstats.YAVG"]) for x in f]
    rng = [float(x["tags"]["lavfi.signalstats.YMAX"]) - float(x["tags"]["lavfi.signalstats.YMIN"]) for x in f]
    live = len(y) > 0 and max(rng) > 50
    print(json.dumps({"file": path, "frames": len(y), "mean_luma": round(sum(y) / max(1, len(y)), 1),
                      "max_luma_range": max(rng) if rng else 0, "result": "PASS" if live else "FAIL"}))


def band(path, hz, width):
    r = subprocess.run([FFMPEG, "-hide_banner", "-i", path, "-af", f"bandpass=f={hz}:width_type=h:w={width},volumedetect",
                        "-f", "null", "-"], capture_output=True, text=True)
    m = re.search(r"mean_volume: (-?[0-9.]+) dB", r.stderr)
    return float(m.group(1)) if m else -120.0


def tone(path, hz):
    hz = float(hz)
    on, off = band(path, hz, 40), band(path, hz * 2.3, 200)
    print(json.dumps({"file": path, "tone_band_db": on, "neighbour_band_db": off,
                      "result": "PASS" if on > off + 12 and on > -50 else "FAIL"}))


if __name__ == "__main__":
    cmd = sys.argv[1]
    {"colors": lambda: colors(sys.argv[2]), "colors-any": lambda: colors_any(sys.argv[2]), "activity": lambda: activity(sys.argv[2]),
     "tone": lambda: tone(sys.argv[2], sys.argv[3])}[cmd]()
