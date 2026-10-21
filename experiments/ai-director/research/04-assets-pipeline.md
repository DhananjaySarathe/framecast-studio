# Research notes: script-to-assets pipeline (charts, animations, images, facts, show package)

Raw notes from a research pass on 2026-10-21, with sources as cited; items marked (unverified) need checking. Summarised in docs/AI-DIRECTOR-RESEARCH.md.

Correction: the research pass said Framecast has no video-file layer. Since v3-baseline it does: `.media(path:)` / MediaFileSource. It decodes to BGRA, so pre-rendered clips with alpha should composite; verify with an HEVC-alpha or ProRes 4444 file.

## Recommendations
1. **The LLM never writes code that runs on air.** It writes:
   - **JSON** that fills Framecast's own native templates: title card, lower third, bar/compare chart, quote card, source card.
   - **HTML/CSS + Web Animations / anime.js explainer animations**, packaged as **EBU OGraf**, which Framecast **pre-renders** frame by frame to alpha video during show prep.
2. **Live rendering stays native:** CG/Core Image, Lottie through `CARenderer`, Swift Charts snapshots. Live HTML is the riskiest path on macOS, so leave it for later.
3. **Assets, in order of preference:**
   - The presenter's own files and screenshots.
   - Openverse and Wikimedia Commons (no key needed).
   - Official brand kits, for logos only, unaltered.
   - Local AI generation, for illustrations only.
   - Key-based stock (optional, user's own key).
   - Never scrape Google Images.
4. **Every number is sourced:** a source ID plus the exact quote, then a deterministic check, then human approval before the director can cue it. A source line shows on screen.

## Live HTML on macOS
- Offscreen windows and HTML overlays update about once per second. Apple suggests `CARenderer` into an IOSurface/Metal texture on your own clock ([thread 831477](https://developer.apple.com/forums/thread/831477)).
- WKWebView only renders when visible ([710015](https://developer.apple.com/forums/thread/710015)), and `takeSnapshot` is slow and memory-heavy ([718092](https://developer.apple.com/forums/thread/718092)).
- `CARenderer` with WKWebView is unproven on macOS ([839506](https://developer.apple.com/forums/thread/839506)).
- The OBS approach is CEF offscreen rendering with IOSurface `OnAcceleratedPaint` and a host-driven frame clock ([cef_render_handler.h](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_render_handler.h)). It works but means shipping Chromium.

## Comparison

| Tech | Quality | LLM authoring | In Framecast | Licence |
|---|---|---|---|---|
| HTML/CSS + WAAPI / anime.js / Motion | Excellent | **Highest** | Pre-render (deterministic seek); live only via CEF | Free / MIT |
| GSAP | Excellent | High | Same | "No charge", but bars no-code animation builders. **Avoid** |
| Chart.js / ECharts / D3 / Vega-Lite | Good | Good for simple charts ([eval](https://www.arxiv.org/pdf/2401.11255)) | Pre-render or static SVG; ECharts can render SVG without a browser | MIT / Apache / ISC / BSD |
| **EBU OGraf** (wraps the above) | = HTML | High (small interface) | Both; `supportsNonRealTime` + `goToTime()` | MIT ([repo](https://github.com/ebu/ograf)) |
| Lottie (lottie-ios) | Excellent if designed | **Low from scratch** (GPT-5 succeeds 12.7–68.7% on the schema ([CVPR 2026 supp.](https://openaccess.thecvf.com/content/CVPR2026/supplemental/Yang_OmniLottie_Generating_Vector_CVPR_2026_supplemental.pdf))); good for filling a designer's template | Live via Core Animation / `CARenderer` (test) | Apache-2.0 |
| Rive | Excellent | None (binary export) | Live | Runtime MIT; editor export is paid |
| Remotion | Excellent | High | Pre-render, ProRes 4444 alpha | **Company licence needed above 3 employees** ([pricing](https://www.remotion.dev/docs/license/pricing)) |
| HyperFrames (HeyGen) | Excellent | High | Pre-render to MP4 via headless Chrome + FFmpeg | Apache-2.0 ([repo](https://github.com/heygen-com/hyperframes)) |
| Motion Canvas / Revideo | Very good | Medium | Pre-render | MIT (Revideo unverified) |
| Manim | Excellent for diagrams | Medium | Pre-render | MIT |
| Swift Charts + ImageRenderer | Native | LLM fills a ChartSpec JSON | Live static frame + compositor animation | OS |
| Native CG/CA templates | Template quality | **Highest** (JSON only) | Live at 30–60 fps | Ours |

**Pre-render without Chromium:**
1. Load the OGraf component in WKWebView and pause its animations.
2. For each frame, `goToTime(t)` / set `currentTime`, then `takeSnapshot`.
3. Write frames with AVAssetWriter to HEVC with alpha ([WWDC19 506](https://developer.apple.com/videos/play/wwdc2019/506/)) or ProRes 4444.

Rules: no WebGL and no `<video>`. Snapshot alpha is unverified. Fallback: HyperFrames.

## Images and sources
**Google Images:** it is an index of other people's work, and its usage-rights filter only reflects host metadata ([help](https://support.google.com/websearch/answer/29508)). The **Custom Search JSON API is closed to new customers and ends 2027-01-01** ([Google](https://developers.google.com/custom-search/v1/overview)).

| Source | Licence | Key? | Limits / rules |
|---|---|---|---|
| **Openverse** | CC + public domain | No | Licence must be verified at the source |
| **Wikimedia Commons** | CC BY/BY-SA, public domain | No (User-Agent required) | 200 requests/min with a User-Agent ([limits](https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits)); attribution ([reuse](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia)) |
| Pexels | Pexels licence | Yes | 200/hour; credit ([docs](https://www.pexels.com/api/documentation/)) |
| Pixabay | Pixabay licence | Yes | Download, don't hotlink ([docs](https://pixabay.com/api/docs/)) |
| Unsplash | Unsplash licence | Yes | **Must hotlink**, which doesn't suit an offline show folder |
| Brand kits | Trademark | — | Anthropic marks need prior approval and no alteration ([guidelines](https://www.anthropic.com/legal/trademark-guidelines)); OpenAI logo via permission ([brand](https://openai.com/brand/)). Default: **typeset name** |
| Own screenshots | Vendor UI copyright | — | Editorial / comparative use; show date and URL |
| Local AI images | Ours | — | FLUX.2 [klein] 4B (Apache-2.0); the 9B is non-commercial; Draw Things is free and offline |
| Gemini / OpenAI image models | Ours | Key + billing | ~$0.07–0.13 (Gemini) / ~$0.01–0.13 (GPT Image) per image ([Gemini](https://ai.google.dev/gemini-api/docs/pricing), [OpenAI](https://developers.openai.com/api/docs/pricing)) |

Logo rule: never AI-generate or redraw a company logo (this matches the org rule for competitor logos).

## Numbers and fact-checking
**Risk:**
- LLMs fabricate citations 11.4–56.8% of the time ([Naser 2026](https://www.alphaxiv.org/abs/2603.03299)).
- Benchmark numbers shift up to 11–15 points with scaffolding alone ([Epoch AI](https://epochai.substack.com/p/why-benchmarking-is-hard)).

**Pipeline:**
1. Snapshot the sources, with hashes.
2. Extract claims with **Claude Citations**, which return the exact `cited_text` ([docs](https://platform.claude.com/docs/en/build-with-claude/citations)). Citations can't be combined with structured outputs, so normalisation is a separate call.
3. Run a deterministic check in code: the number appears in the quote, the quote appears in the snapshot, and metric, version and settings match.
4. Human approval.
5. The on-screen source line is mandatory.

## Show package (how others do it)
- **MOS protocol** (ENPS / iNEWS ↔ Viz Mosart): Running Order → Stories → Items ([MOS 2.8.5](https://mosprotocol.com/wp-content/MOS-Protocol-Documents/MOS_Protocol_Version_2.8.5_Final.htm)).
- **Sofie** (NRK, MIT): Rundown → Segment → Part (one TAKE) → Piece, plus AdLibs and Buckets ([concepts](https://sofie-automation.github.io/sofie-core/docs/user-guide/concepts-and-architecture)).
- **QLab cue sheets:** pre-wait, post-wait, auto-continue.
- **OGraf manifest:** `*.ograf.json` with a data schema and `goToTime`.

**Proposed folder:**
```
Shows/<date>-<slug>/
  show.json  script.md  sources/  data/  assets/{images,logos,screenshots,generated}/
  graphics/<name>/ (OGraf)  renders/ (HEVC-alpha .mov)  credits.json  logs/prep.jsonl
```
The `show.json` example (sources, sourced data with null values until verified, assets with rights, rundown segments → parts with template, fields, cue phrases, trigger, durations, transitions, adlibs, and director settings) is reproduced in docs/AI-DIRECTOR-RESEARCH.md.

## Risks
- Live HTML throttling.
- Snapshot fidelity and alpha.
- Licence traps: Remotion, GSAP, Unsplash, non-commercial model variants, wrong CC metadata.
- Trademark approval.
- Invented or non-comparable numbers.
- Monthly pricing and deprecation churn.
- Keys and accounts conflict with the no-account rule, so keep them optional.
- Mis-cues need thresholds and overrides.
