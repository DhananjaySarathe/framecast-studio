#!/usr/bin/env python3
"""Measure A/V sync in Framecast test recordings.

The test pattern flashes white on the frame nearest every whole second of the engine timeline and the
tone source beeps (1 kHz, 100 ms) starting exactly on those seconds. For each file this finds flash frames
(mean luma via ffprobe signalstats) and beep onsets (ffmpeg silencedetect), pairs them, and reports the
audio-minus-video offset. With two files it also compares their timelines (landscape vs portrait).

Usage: python3 -I scripts/avsync.py FILE [FILE2]
"""
import json
import re
import subprocess
import sys

FFPROBE = "/opt/homebrew/bin/ffprobe"
FFMPEG = "/opt/homebrew/bin/ffmpeg"


def flashes(path):
    # movie= paths need ':' and '\' escaped for the lavfi parser.
    esc = path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")
    out = subprocess.run([FFPROBE, "-v", "error", "-f", "lavfi", "-i", f"movie='{esc}',signalstats",
                          "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG", "-of", "json"],
                         capture_output=True, text=True, check=True).stdout
    frames = json.loads(out)["frames"]
    vals = [(float(f["pts_time"]), float(f.get("tags", {}).get("lavfi.signalstats.YAVG", 0))) for f in frames]
    ys = sorted(v for _, v in vals)
    if not ys:
        return [], 0
    median, top = ys[len(ys) // 2], ys[-1]
    # Flash frames stand far above the usual picture brightness (works for 16:9 and letterboxed 9:16).
    threshold = median + 0.5 * (top - median) if top - median > 20 else float("inf")
    times = [t for t, y in vals if y > threshold]
    # Collapse consecutive flash frames (shouldn't happen, but be safe).
    out_t = []
    for t in times:
        if not out_t or t - out_t[-1] > 0.5:
            out_t.append(t)
    return out_t, len(frames)


def beeps(path):
    r = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", path, "-map", "0:a:0", "-af",
                        "silencedetect=n=-30dB:d=0.25", "-f", "null", "-"], capture_output=True, text=True)
    return [float(m) for m in re.findall(r"silence_end: ([0-9.]+)", r.stderr)]


def stream_info(path):
    out = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "stream=codec_type,start_time,duration,nb_frames,width,height",
                          "-show_entries", "format=duration", "-of", "json", path], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def analyse(path):
    f, nframes = flashes(path)
    b = beeps(path)
    pairs = []
    for t in f:
        if not b:
            break
        nb = min(b, key=lambda x: abs(x - t))
        if abs(nb - t) < 0.3:
            pairs.append((t, nb, nb - t))
    offs = [p[2] for p in pairs]
    info = stream_info(path)
    res = {
        "file": path,
        "frames": nframes,
        "flashes": len(f),
        "beeps": len(b),
        "paired": len(pairs),
        "mean_offset_ms": round(1000 * sum(offs) / len(offs), 2) if offs else None,
        "max_abs_offset_ms": round(1000 * max(abs(o) for o in offs), 2) if offs else None,
        "streams": [{k: s.get(k) for k in ("codec_type", "start_time", "duration", "nb_frames", "width", "height")}
                    for s in info["streams"]],
        "flash_times": [round(t, 4) for t in f],
        "beep_times": [round(t, 4) for t in b],
    }
    return res


def summary_line(r):
    v = next((s for s in r["streams"] if s["codec_type"] == "video"), {})
    a = next((s for s in r["streams"] if s["codec_type"] == "audio"), {})
    return (f"{r['file']}: {v.get('width')}x{v.get('height')} frames={r['frames']} flashes={r['flashes']} beeps={r['beeps']} "
            f"paired={r['paired']} A-V mean={r['mean_offset_ms']}ms max={r['max_abs_offset_ms']}ms | "
            f"v start={v.get('start_time')} dur={v.get('duration')} | a start={a.get('start_time')} dur={a.get('duration')}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    short = "--summary" in sys.argv
    results = [analyse(p) for p in args]
    for r in results:
        if short:
            print(summary_line(r))
        else:
            print(json.dumps({k: v for k, v in r.items() if k not in ("flash_times", "beep_times")}, indent=1))
    if len(results) == 2:
        a, b = results
        n = min(len(a["flash_times"]), len(b["flash_times"]))
        dv = [b["flash_times"][i] - a["flash_times"][i] for i in range(n)]
        m = min(len(a["beep_times"]), len(b["beep_times"]))
        da = [b["beep_times"][i] - a["beep_times"][i] for i in range(m)]
        print(json.dumps({
            "cross_file_video_flash_delta_ms": [round(1000 * x, 2) for x in dv],
            "cross_file_audio_beep_delta_ms": [round(1000 * x, 2) for x in da],
        }))


if __name__ == "__main__":
    main()
