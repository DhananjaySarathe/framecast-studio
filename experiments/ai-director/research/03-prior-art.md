# Research notes: prior art for an AI live director

Raw notes from a research pass on 2026-10-21, with sources as cited. Summarised in docs/AI-DIRECTOR-RESEARCH.md. Some sources were blocked (the IMX 2026 "AI Director" full text, the TalkDirector PDF, BBC "Ed"); where a claim comes only from the vendor, it is marked.

## Products and projects

| Name | What it automates | Technique | Notes | URL |
|---|---|---|---|---|
| Advanced Scene Switcher (OBS) | Scene/source/transition macros; v1.36.1 (Aug 2026) adds a **speech recognition condition** (phrase/regex) | Rules + whisper.cpp tiny | No accuracy data. Run rules "only on condition change" so they don't fight manual moves | [releases](https://github.com/WarmUpTill/SceneSwitcher/releases) |
| LocalVocal (OBS) | Local captions/translation | whisper.cpp | No triggers of its own | [forum](https://obsproject.com/forum/resources/localvocal-local-live-captions-translation-on-the-go.1769) |
| Streamlabs Intelligent Streaming Agent | Producer: scene changes, cues, highlights, replays | Local vision on RTX, voice commands, triggers | Capped at 5–30 automations; no approval flow documented | [NVIDIA](https://blogs.nvidia.com/blog/rtx-ai-garage-logitech-streamlabs-agent) |
| Streamer.bot Voice Control | Phrase → action | Windows speech recognition, exact/start/anywhere matching | Brittle inside continuous speech | [wiki](https://wiki.streamer.bot/en/Voice-Control) |
| Visor (waitlist 2026) | Recommends and switches the next shot for multi-camera podcasts | Undisclosed | **Recommendation mode first**, confidence per decision, decision log ("held wide due to low confidence"), instant takeover, user maps which scenes it may use | [site](https://www.visorai.org/) |
| Ecamm / StreamYard / Restream | No live AI director; timers, AI clips | | Repurposing, not directing | |
| Riverside Co-Creator | Editing agent hands work to a "Director" agent; offers options | LLM + tools (Mastra) | Returns options for the user to choose | [case study](https://mastra.ai/customers/riverside) |
| Descript Underlord + Automatic Multicam | Agentic transcript editing; multicam cutaways every 10–30 s | LLM agent with tools (Claude); speaker detection | Evals: "Don't break things / Do what I asked / Do it well" with a calibrated LLM judge. **Users forgive taste misses far more than overreach.** Multicam complaints: too many cuts, cuts on "mm-hmm"; minimum shot length has been requested since 2025 | [Claude case study](https://claude.com/customers/descript), [feedback](https://feedback.descript.com/feature-requests/p/automatic-multicam-force-minimum-scene-cut-length) |
| Screen Studio | Auto-zoom on clicks | Rules | "Zooms start and end too late" | [request](https://hub.screen.studio/p/custom-settings-for-default-automatic-zoom-range) |
| Zoom / Teams / Webex | Speaker framing and switching | Computer vision + mic arrays | Jumps on coughs and unmute clicks; hosts pin views | [Zoom](https://news.zoom.us/?p=546) |
| Huddly, Crestron, Owl | Room camera direction | On-device AI | Owl takes about 2 s to swap views | |
| PTZOptics voice tracking | Camera presets by audio zone | Rules | | [Videoguys](https://videoguys.com/blogs/news-and-sales/hands-free-ptz-camera-automation-with-ptzoptics-voice-tracking) |
| Viz Mosart (+ Vizrt agents, IBC 2026) | Rundown-driven studio automation | Templates fired from the rundown; agents under human editorial control | Operators can leave the rundown and come back with "Take Next"; one operator ran a whole Premier League show | [Vizrt](https://www.vizrt.com/blog/taking-manual-control-with-viz-mosart/) |
| Pixellot | Automated sports production | Computer vision | Followed a bald linesman's head instead of the ball; needs a fallback shot | [PetaPixel](https://petapixel.com/2020/11/02/ai-tracking-camera-mistakes-referees-bald-head-for-a-soccer-ball) |
| SmartVerses / Pewbeam (church) | Hear a Bible reference, stage or show the verse | Live speech recognition + matching | SmartVerses stages it and a human sends it to air | [SmartVerses](https://faith.tools/app/smartverses) |
| Gemini Live API | Real-time multimodal input | Streaming LLM | Video at **1 FPS**, about 600 ms to first token | [docs](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/live-api/send-audio-video-streams) |

Streaming Media, March 2026: AI in live control is "usually advisory or diagnostic rather than directly in control" ([article](https://www.streamingmedia.com/Articles/Editorial/Featured-Articles/The-State-of-AI-In-Live-Streaming-173245.aspx)).

## Research
**Closest to Framecast:**
- **"Toward an AI Director"** (IMX 2026): local vision-language models for live presentations ([DOI](https://doi.org/10.1145/3788851.3815032)).
- **TalkDirector** (UMD + Google): before the talk, a vision-language model **aligns the script to the slides**; live, speech recognition and gestures find what the presenter is referring to. Dataset VTalk-68 ([UMD](https://www.cs.umd.edu/content/talkdirector-real-time-multimodal-slide-augmentation-adaptive-presenter-integration)). Same split as our plan: prepare, then match live.
- **Visual Captions** (CHI 2023): an LLM every 100 ms suggests visuals. Autonomy levels: auto-display, auto-suggest, on-demand. **The preferred level depends on the setting** ([Google](https://research.google/blog/visual-captions-using-large-language-models-to-augment-video-conferences-with-dynamic-visuals)).
- **ChatDirector**, **RealityTalk** (speech-driven live graphics), **VisAider** (live data visualisation; struggles with data transforms, ambiguity and latency), **SlideSAVR**.

**Editing research:**
- **B-Script** (CHI 2019): experts place B-roll at narration keywords, which supports keyword-anchored cues ([arXiv](https://arxiv.org/abs/1902.11216)).
- **LAVE**, **ExpressEdit** (still often wrong about *when*: temporal recall 0.68), **EditDuet** (editor + critic agents), **UniVA** (planner + MCP executors).

**Asset generation:**
- PresentAgent and Paper2Video.
- TheoremExplainAgent: 93.8% Manim success, but layout faults remain. Later work adds a vision check of rendered frames.

**Classic directors:**
- MSR lecture director (2000): close to a human operator.
- Dartmouth 2024: viewers prefer human > model > random cuts.
- BBC "Ed".
- Evaluation methods: preference studies, "can you tell?" tests, shot statistics.

**Following a script live:** news subtitle alignment is mature (Interspeech 2009, Red Bee Subito). The Dutch broadcaster NPO needed a **5 s broadcast delay** before automatic subtitles worked ([EBU](https://tech.ebu.ch/news/2021/04/automated-subtitles-on-a-247-news-channel)).

## Open-source to reuse or learn from
**OBS MCP servers:**
- [takurot/obs-showrunner-mcp](https://github.com/takurot/obs-showrunner-mcp) (MIT): show-level tools (`start_show`, `switch_segment`, `extend_segment`, `trigger_effect`); strict, normal and dry-run safety modes; stopping the stream or recording is blocked by default. **The best model to copy.**
- [ironystock/agentic-obs](https://github.com/ironystock/agentic-obs): no licence, ideas only.
- [royshil/obs-mcp](https://github.com/royshil/obs-mcp): GPL-2.0.
- The OpenClaw OBS plugin recommends a tool allowlist, confirmation for start/stop, and **warns about prompt injection from chat**.

**Script followers:**
- [f/textream](https://github.com/f/textream) (MIT, Swift, macOS): word tracking with Apple speech, pause for off-script, tap to jump.
- [EdNutting/autocue](https://github.com/EdNutting/autocue) (MIT): rapidfuzz, backtrack detection, under 250 ms. The author says the AI-written first version was unreliable, so tracking is the hard part.
- clicue.

**Alignment:** online DTW from music score following (Dixon; Arzt & Widmer handle jumps and restarts), [pymatchmaker](https://pymatchmaker.readthedocs.io/en/stable/modules/matchmaker.dp.html).

**Patents to review:** US9953646, US11902690, US12367641 (speech-tracked scripts, AI presenters).

## Lessons for Framecast
1. Let the user choose the autonomy level, and start low: suggest, then auto with veto, then full auto, per show or segment.
2. Split preparation from live. The LLM turns the script into a deterministic cue list beforehand; a fast local follower fires the cues. No LLM call per cut.
3. Anticipate cues: pre-arm on partial text, fire on anchor words. Lag looks like a mistake. Offer an optional output delay.
4. Hysteresis is mandatory: minimum shot length, a cap on cuts per minute, ignore "mm-hmm" and coughs.
5. A small, user-mapped set of scenes the AI may pick from; intros and sponsor segments stay manual.
6. Make the director legible: what's live, what's next, why, how confident; hold a safe shot when unsure; keep a decision log.
7. The script follower must survive skips, backtracks and ad-libs, detect off-script, and re-acquire its position.
8. Manual always wins: kill switch, pause, and "take next" to rejoin.
9. Strict safety by default: no stopping the stream or recording, a tool allowlist, dry-run mode, chat is never an instruction.
10. Don't break things, then do it well. Every AI action is undoable and logged.
11. Assets: offer options; check rendered charts and animations with a vision pass; build charts from real data only.
12. Build in evaluation: cue to on-air time, false and missed cues, override rate, cuts per minute, comparison with a human director.
13. Local-first is viable.
14. Licences: borrow ideas from GPL and unlicensed projects, not code.
15. **Gap / opportunity: no shipping product combines script following, prepared assets and multi-scene direction for a single presenter.**
