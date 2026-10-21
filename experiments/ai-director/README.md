# AI director experiments

Throwaway spikes for docs/AI-DIRECTOR-RESEARCH.md. None of this is part of the app. Anything that switches scenes
talks to a **test copy** started with `FRAMECAST_UI=…,test-control` (build it with
`FRAMECAST_APP=build/test/Framecast.app scripts/build_app.sh`); a normal Framecast ignores these commands.
`fcctl` is `swiftc -O scripts/fcctl.swift -o build/fcctl`.

| Folder | What it is |
|---|---|
| `research/` | Raw research notes with sources, one file per topic |
| `talk.txt`, `talk-adlib.txt` | The two 40 s test talks (scripted, and ad-libbed with a trap line). Audio: `say -v Samantha -r 185 -o talk.aiff -f talk.txt` (the .aiff files are not committed) |
| `stt-latency/` | Feeds a talk into Apple's on-device speech recognizer in real time. `--fast` for fast results, `--jsonl` to save every result; `word_latency.py` turns that into per-word delay |
| `transcripts/` | The saved results for both talks, default and fast mode |
| `cue-follower/` | Matches the transcript against `cues.json` (word matching + `--semantic` on-device sentence meaning) and fires scene switches (`--fcctl build/fcctl`). `results*.txt` and `live-end-to-end.txt` are the measured runs |
| `on-device-llm/` | Apple's on-device model as the director (`main.swift`, `results.txt`) and as show prep writing cue variants (`variants.swift` → `cue-follower/cues.expanded.json`) |
| `mcp/` | `framecast_mcp.py`, a minimal local MCP server so Claude Code / Claude Desktop can operate a test copy; `bench_link.py` times it without AI; `try-with-claude.sh` lets Claude direct the test copy on your own Claude login |
| `show-package/` | Example `show.json` for a per-show folder |

Live chain on one line (test copy running):

```bash
stt-latency.bin talk.aiff --fast --jsonl 2>/dev/null | cue-follower cue-follower/cues.json --semantic --fcctl ../../build/fcctl
```
