# Live editor experiments

Throwaway benchmarks behind docs/LIVE-EDITOR-PLAN.md, run on an M5 Pro MacBook Pro (24 GB, macOS 27.0.1) on
21 October 2026. None of this is part of the app. Everything uses Apple frameworks and the Command Line Tools
(`swiftc -O -swift-version 5 <file> -o <name>`); nothing is downloaded or installed, and nothing touches the network.
Frames extracted from your own recordings stay in a scratch folder and are never committed.

| Folder | What it is |
|---|---|
| `vision/` | `visionbench.swift` times Apple Vision requests (faces, upper bodies, tracker, masks, saliency, hand and body pose, OCR, optical flow) on frames from a local recording, plus forced-device and concurrent-load runs. Set `BENCH_DIR` (holding `frames/`) and `UI_FOOTAGE` (app screenshots, for OCR). `quickbench.swift` and `devices-and-loop.swift` are the first quick passes (`<movie> [start s]`). Results in `results/`; `final_table.md` is the summary |
| `compositor/` | `results.txt`: both canvases per tick through Framecast's own compositor (camera, screen + camera, per-layer zoom, whole-canvas zoom, Move, fade, motion blur, whip, zoom blur). The harness source was lost; Gate 0 rebuilds it in the repo |
| `effects/` | `main.swift`: isolated Core Image costs of candidate transitions and finishing effects at 1920x1080. Reads 3-5x lower than the real compositor, so use it for relative costs only. `results/run1-3.txt` |
| `encoder/` | `enc.swift`: what effects cost the hardware H.264 encoder (bits used, worst-frame PSNR) at 4.5 and 1.5 Mbps |
| `sharpness/` | `main.swift`: does a 2x zoom keep a 3840-px screen's detail? Builds with the engine: `swiftc -O main.swift $(find ../../../Sources/FramecastEngine -name '*.swift')` |
| `metal-kernel/` | `main.swift`: custom Metal transitions compiled at run time through Core Image (no offline `metal` compiler needed) |
| `camera-probe/` | `main.swift`: lists cameras, formats, Center Stage and Reactions support without opening a camera |
| `references/` | `ocr_bench.swift` (OCR on a synthetic app screen), `intent_bench.swift` (voice-to-target: deterministic matcher vs Apple's on-device model, 18 scripted lines), `image_bench.swift` (the on-device model with the screen image attached) |
| `cursor/` | `cursorcost.swift`: cost of reading the cursor position at 30 Hz |
| `models/` | `licences.tsv`: licence, size and Core ML availability of the small open models surveyed |
