# AI director for Framecast: research and first experiments

Branch `feat/AI_experiment`, 2026-10-21. This is research, not a feature yet. It covers three things:
- **the AI decision-maker**: Claude, GPT or on-device;
- **script to show**: a rough script becomes scenes, charts, animations and images, stored per show in a folder;
- **the live director**: it listens and watches, and decides when to switch, which transition to use, and when to end.

It also answers "can we use Claude credits?" Each topic has raw notes with sources in `experiments/ai-director/research/`. The experiments are in `experiments/ai-director/`, and every number marked *measured* was produced on this Mac (M5 Pro, macOS 27).

## The short version

1. **Don't let an AI make every cut live.** The products that work prepare with AI before the show and run live with fast, predictable local logic. AI only *suggests* in the ambiguous moments. No shipping product combines script following, prepared assets and multi-scene direction for one presenter, so that is the gap Framecast can fill.
2. **The local live layer already works in a test copy (measured).** Audio goes through Apple's on-device speech recognition, then a script cue follower, then Framecast switches scenes.
   - On the scripted talk it made 4/4 switches. The scene changed **about 0.7–1.1 s after the cue word was spoken**.
   - On an ad-libbed talk it made 3/4 switches with **no false cuts**.
   - It costs $0, works offline, and needs no account.
3. **Claude's best job is show prep, not split-second cuts.** Prep means turning the rough script into a rundown, cue phrases, charts from sourced numbers, and animations. A local "control link" (MCP server) lets Claude operate Framecast the way you do in chat. It works today against a test copy: **11 ms per command, about 0.1 s until the scene is on air** (measured).
4. **Claude credits, honestly:**
   - Your **Claude subscription** can drive Framecast through Claude Code or Claude Desktop with that control link. This is allowed for *your own use*, but you **may not ship it to customers** as "log in with Claude". It is also too slow for live cuts: several seconds per decision, by the research numbers. A test script is ready for when you log in again.
   - **Max or Team plans** now include **$100–$200 a month of API credits**, which is the sanctioned way to call Claude from inside the app.
   - A live advisor on Claude Haiku 5.5 costs about **$0.10–$0.20 per show-hour**. A Haiku + Sonnet hybrid costs about **$0.70–$1.30 per hour**.
5. **Apple's on-device model is free and fast but not reliable enough to decide alone (measured).**
   - It took 0.66 s per decision and got 20 of 26 right.
   - A small change to one rule's wording dropped it to 17/26.
   - Use it as a tie-breaker or for suggestions, not for autopilot.

## How it would fit together

```
BEFORE THE SHOW (AI does the heavy lifting; time doesn't matter)
  rough script ──► Claude (your plan via the control link, or API) ──► show package folder
                     rundown · cue phrases + ways to say them · charts from sourced numbers ·
                     pre-rendered animations · licensed images · source lines          (you review, then approve)

DURING THE SHOW (local, about 1 s, $0, works offline)
  mic ─► on-device speech recognition ─► cue follower ─┐
  screen ─► change detection + text reading (OCR) ─────┼─► director rules ─► guards ─► mode gate ─► Framecast switch
  AI advisor (on-device or Claude, optional) ──────────┘   (min shot 3 s,    (suggest / one-key
                                                             rate limit,        approve / autopilot
                                                             undo, audit log)   with veto)
  never automatic: go live · end stream · stop recording · audio changes
```

## Experiments and what they showed

All of these ran on a **test copy** (`build/test/Framecast.app`), never your everyday app. The two test talks are about 40 s each, spoken by the Mac's `say` voice:
- `talk.txt` follows the script.
- `talk-adlib.txt` says the same things in other words. It also contains a trap line ("I'll put a chart up in a minute") and a tangent about a cat.

| # | Experiment | Result (measured) |
|---|---|---|
| 1 | **On-device speech recognition** (Apple SpeechTranscriber, offline) fed in real time (`stt-latency/`) | With "fast results": a word first shows up **correctly a median 0.6 s after it is spoken** (p90 0.9 s), and settles in about 2 s. Default mode is much slower (1.9 s / 3.5–3.8 s). Mistakes it makes: "Opus" → "OPA", "Sonnet" → "sonic", "price" → "prize", "heads up" → "heads off", "four dollars per million" → "4 per 10000". Giving it a vocabulary list does nothing (Apple's newer recognizer ignores it), so we fix names with an alias table. |
| 2 | **Control link without AI** (`mcp/bench_link.py`): an MCP tool call → Framecast test hook | Command returns in **11 ms** (median of 12). Switch **confirmed on air after 116 ms**, including a state read. The link is never the bottleneck. |
| 3 | **Script cue follower, word matching** (`cue-follower/`), replaying the transcripts | Scripted talk: **4/4 cues, fired 0.6–0.8 s after the cue word** (one fired 0.1 s *before* its last word ended). Ad-libbed talk: only 1/4, because word matching can't recognise paraphrases. |
| 4 | **+ on-device sentence meaning** (Apple NLEmbedding, per finished sentence) | Ad-libbed talk: **3/4 with no false cuts**. "Let me bring up my screen" (+1.8 s, waits for the sentence to end), "which should you go for" (+0.45 s), "thanks so much for watching" (+0.6 s). The trap "I'll put a chart up in a minute" stayed well clear (distance 1.23 against a 0.85 threshold). **Missed:** "here are the benchmark numbers" (1.06). The threshold was picked on these two talks, so it needs a bigger test set. |
| 5 | **+ cue variants written by the on-device model before the show** (`on-device-llm/variants.swift`) | Still 3/4. The verdict match got stronger. The variants were weak, though: it phrased the screen cue around the scene name ("the split"), and suggested "stay tuned" for the outro, which would misfire mid-show. **Prep needs a stronger model (Claude) and your review.** |
| 6 | **Full live chain on the test copy**: audio → speech recognition → cue follower → Framecast (`cue-follower/live-end-to-end.txt`) | Scripted: Camera → Screen + camera → Split → Camera → Outro, **all 4 switched**. Ad-libbed: 3/4. Framecast showed each new scene **0.08–0.30 s after the command** (polled every 0.2 s), so from the spoken cue to the new scene is about 1 s. |
| 7 | **Apple's on-device model as the director** (`on-device-llm/main.swift`), 26 sentences, answers forced to valid scene names | **0.66 s per decision**, **20/26 right**. One early cut on the price sentence ("numbers") caused 3 of the 6 misses. With one rule reworded it dropped to 17/26 at 0.48 s. Free, private and fast, but brittle. |
| 8 | **Claude driving Framecast** through Claude Code + the control link (`mcp/try-with-claude.sh`) | **Not run:** this Mac's Claude Code login has expired, and logging in is yours to do. The script works up to the login check and stops with a clear message. |

### To try Claude yourself (about 2 minutes)
1. In a terminal, run `claude` once and sign in.
2. Build the test copy if it isn't there: `FRAMECAST_APP=build/test/Framecast.app scripts/build_app.sh`.
3. Run:
   ```bash
   experiments/ai-director/mcp/try-with-claude.sh live
   ```
   This plays six presenter lines to one long-running Claude session. It prints each decision, whether it was right, and the time from line to tool call.

`oneshot` instead of `live` starts Claude fresh for every line, which shows the start-up cost. `MODEL=sonnet` tries another model.

The run sends only the director prompt and the six fake lines, under your login. It uses `--system-prompt` to replace Claude Code's large default prompt, which should make each turn faster and lighter. That is my reasoning, not measured yet.

## The decision-maker (details in research/02)

| Option | Cost per show-hour (fast loop every 4 s) | Speed | Privacy | Who can use it |
|---|---|---|---|---|
| **Local rules + cue follower** (built here) | $0 | about 1 s cue → on air | stays on the Mac | everyone, offline |
| **Apple on-device model** | $0 | 0.5–0.7 s per decision (measured) | stays on the Mac | macOS 26+ with Apple Intelligence |
| **Claude Haiku 5.5** via API, cached prompt, thinking off | about $0.11 (+$0.02–0.04 with screen frames) | about 1 s with thinking off (one third-party sample; to measure) | transcript leaves the Mac | API key: yours, or each customer's |
| Haiku every 4 s + **Sonnet 5.5 planner** every 30–60 s | about $0.67–$1.25 | — | same | same |
| Claude Sonnet 5.5 / Opus 5.5 in the fast loop | about $1.80 / $3.60 | slower | same | same |
| **Your Claude plan** via Claude Code + control link | counts against plan limits | several seconds per turn (to measure) | leaves the Mac | **you only**; not for customers |
| GPT-6 Luna (OpenAI) | about $0.11 | 0.8 s first token (third-party) | leaves the Mac | API key |
| Gemini Live (audio + video in) | hard to predict; re-bills context every turn | — | **free tier is used for training** | not recommended |

**Using Claude credits, by route:**
- **Claude subscription + Claude Code / Claude Desktop + Framecast's local control link.** Allowed for personal use. Anthropic's terms forbid offering claude.ai login inside a product or routing customers' requests through their plans.
  - Best for **show prep** (minutes, not milliseconds) and for "operate the editor like I do in chat".
  - A packaged Claude Desktop extension (`.mcpb`) makes it a one-click install for you.
- **Max/Team monthly API credits** (new on 7 Oct 2026; Max 5x $100, Max 20x $200, Team up to $500). Link a Console organisation and put the key in the Keychain; Framecast already stores secrets there.
  - At about $0.70–$1.30 per show-hour, $100 covers roughly 75–150 show-hours of the hybrid director (40–75 if the planner also "thinks").
  - **Pro plans don't get these credits.**
- **To sell Framecast:** each customer brings their own API key, or you pay for the API and price it into a subscription.
  - OpenAI's "Sign in with ChatGPT" for open-source and locally hosted apps is the only program that explicitly lets an app use a customer's chat subscription.
- **The rules have changed four times in 2026.** Never make the product depend on subscription login.

## Script → show package (details in research/04)

- **The AI writes data, not code that runs on air.**
  - JSON fills Framecast's own templates: title, lower third, bar/compare chart, quote card, source card.
  - Explainer animations are HTML/CSS + Web Animations in the open EBU **OGraf** format. Framecast **pre-renders** them to alpha video during prep (WKWebView, frame by frame, to HEVC with alpha), and plays them with the existing media layer.
  - Live HTML on macOS is unreliable, so it is left out.
- **Licences:**
  - Avoid GSAP (bars animation-builder use) and Remotion (company licence above 3 people).
  - Lottie only works as designer templates the AI fills in, not generated from scratch.
- **Images, in order:** your own files and screenshots, then Openverse and Wikimedia Commons (free, no key, attribution stored), then local AI images (FLUX.2 klein 4B, Apache-2.0, via Draw Things), then optional stock with your key.
  - **No Google Images scraping.** Google's image-search API is closed to new users and shuts down on 1 Jan 2027.
  - **Logos:** official files only, unaltered; never AI-drawn. Default to a typeset name.
- **Numbers on screen must be traceable.**
  1. Snapshot the source.
  2. Claude's Citations feature returns the exact sentence.
  3. Code checks that the number is in that sentence and the sentence is in the snapshot.
  4. You approve it.
  5. A source line goes on screen.

  Language models invent citations 11–57% of the time in studies, so this pipeline isn't optional.
- **Show package:** a folder per show (`Shows/<date>-<slug>/`) holding `show.json`, the script, sources, data, assets, renders, credits and a prep log.
  - It follows broadcast practice: rundown → segments → parts (one "take" each) → pieces, plus ad-libs.
  - Example: `experiments/ai-director/show-package/show.example.json`.
- **To check:** whether Framecast's media layer keeps alpha from HEVC-alpha or ProRes 4444 files. It decodes to BGRA, so it should, but this is untested.

## The live director: rules worth copying (details in research/03 and 05)

- **Modes:**
  - Suggest: highlights the next scene; one key to take it.
  - Auto with undo, for script cues.
  - Autopilot with a 1.5–3 s veto countdown, for AI-started switches.

  Users forgive a missed shot far more than an AI that overreaches (Descript's experience).
- **Guards:**
  - Minimum shot of 3 s, a 2 s cooldown, at most 6 automatic switches a minute.
  - An oscillation breaker: A→B→A twice in 10 s freezes autopilot.
  - Proposals expire after 2 s.
  - Any manual action pauses autopilot for 30 s.
  - A kill switch drops back to Suggest mode.
- **Never automatic:** go live, end stream, stop recording, anything audio.
  - Ending the stream is *proposed* only in the last segment, after the outro and a closing phrase. It then shows a visible countdown and needs your confirmation.
- **Chat, on-screen text and window titles are untrusted.** A guest or chat saying "end the stream" can trigger nothing. The AI only picks from an allowed list of actions.
- **Watching the screen cheaply:**
  1. A fingerprint of a small screenshot catches slide changes in under 1 ms (estimate).
  2. Apple's text recognition (OCR) reads the slide title in about 0.15–0.2 s (published figures).
  3. Only unknown content goes to an AI, on-device first.
  4. Cloud only if you opt in for that show, with downscaled keyframes and never audio.
- **Log every decision** to a file per show, and **replay recorded rehearsals** to measure missed cues, false cuts and delay before trusting autopilot.

## Limits of this research

- The test talks are synthetic: one clear voice, no noise, about 40 s each. Real shows will have more recognition errors, guests talking over each other, and long ad-libs.
- The semantic threshold (0.85) was chosen on the same two talks it was tested on.
- The Claude path is untested here because of the login. Model speeds and prices come from third-party benchmarks and vendor pages fetched on 21 Oct 2026, and prices change.
- Framecast targets macOS 14. On-device speech recognition and Apple's model need macOS 26+, so older Macs need a fallback: the open-source Parakeet model via FluidAudio, or cloud speech recognition.
- Nothing here is wired into the app yet. The experiments drive a test copy through test hooks.

## Proposed path (for tomorrow)

1. **Phase 1, foundation (no AI needed live):**
   - The show package format and a "Shows" folder in Framecast.
   - A rundown panel.
   - The live cue follower in Suggest mode, then Auto with undo.
   - Framecast's own local control link, so Claude Desktop/Code can build scenes and show packages from a rough script on your plan.
2. **Phase 2, assets:**
   - Chart, lower-third and title templates filled from JSON.
   - OGraf pre-rendering.
   - Licensed image search.
   - The fact-check pipeline.
   - The prep AI writes cue variants for you to review.
3. **Phase 3, live AI advisor:**
   - Screen understanding (fingerprints + OCR).
   - An advisor (Claude Haiku with your credits/key, or on-device) in Suggest mode.
   - Autopilot with veto once replay tests pass.
   - End-of-show proposals with confirmation.

## Decisions for you

1. **Which Claude plan are you on** (Pro, Max or Team)? Only Max and Team come with monthly API credits.
2. **Personal tool first, or a product to sell?** That decides between your-plan-via-Claude-Code and bring-your-own-API-key.
3. **May show transcripts leave the Mac** when a cloud advisor is on? Or should everything stay on-device, accepting a weaker advisor?
4. **Start with Phase 1?** It is useful even with no AI at all, and every later phase builds on it.
5. When convenient, **sign in to Claude Code and run `try-with-claude.sh`**, so the subscription route gets real numbers.
