# Rundown and show director

Two kinds of show:
- **From a brief** (topic shows): you describe the stream and Claude prepares the outline and the assets on your
  Claude plan. Live, a small model follows what you've covered and runs the visuals.
- **From a script** (parts with cue lines): described further down.

## Topic shows: prepared from a brief

1. **Rundown › New show**, then write the **Brief**: topics, what you want to get across, a few lines you might
   say. Not a script.
2. **Let Claude prepare it, on your Claude plan (no API cost):**
   - **Copy for Claude** copies a request for Claude Desktop. Turn on the control link in Settings › AI and add
     Framecast to Claude Desktop once (Settings › AI shows the text). Claude then calls `set_outline`,
     `make_motion`, `make_card` and `save_image`.
   - **Claude Code** copies a Terminal command that opens Claude Code in the show folder. The folder's
     `CLAUDE.md` tells it what to make.
   - Either way you get topics with 3–6 points each and reference pictures from reusable sources (never logos).
   - **Motion graphics** (`make_motion`), drawn by Framecast from data in the show's style, are what the guide
     asks for first:
     - `title`, `roadmap` (milestones along a glowing path), `checklist` (ticks, or a red cross for a negative
       value), `bars`, `gauge` (needle sweeps to a value), `pipeline` (steps with data flowing between them);
     - stick-figure scenes: `juggle` (overwhelmed, juggling icons), `relax` (an AI orb doing the work while the
       figure sits back) and `compare` (the two side by side).

     `juggle`, `relax` and `pipeline` loop seamlessly (saved as `*.loop.mp4`, which Framecast repeats on screen).
     The others end on their finished frame. Every template leaves the bottom-right corner clear for the camera
     circle; reference frames do too.
   - You also get cards drawn by Framecast: title, bullets, bar chart, quote, big number, and a flow of 2–5
     steps with arrows, each with its source printed.
   - Cards can be **animated** (`make_card` with `animate`): a short MP4 where the title slides in, list items
     and steps appear one by one, bars grow and numbers count up. It ends on the finished card, which stays on
     screen.
   - Framecast reloads `show.json` and `assets/` within 2 s when they change, and lists any new file in
     `assets/`.
3. **Live: Listen, and pick a mode.**
   - **Auto** changes things on its own; ⌃⌥⌘U undoes the last change.
   - **Suggest** shows each change for you to take with ⌃⌥⌘T. With no suggestion showing, ⌃⌥⌘T moves to the
     next topic.
   - Every 6 s while you're talking, Framecast sends the **live brain** the outline, what's on air and the last
     90 s of speech, as text. The live brain is Claude Haiku 5.5 or OpenAI's gpt-6-luna, on your key (Settings ›
     AI › Live brain).
   - It answers with the topic you're on, the points covered and at most one change: show an asset, end the
     asset, or change the look.
   - **Topics in any order:** you can jump from the first topic to the tenth and back. The brain picks whichever
     topic matches what you're saying now, and the offline fallback compares against every topic.
   - The outline part of the prompt is the same each time, so it's cached. Cost is about $0.10–0.50 per
     show-hour, shown in the presenter view.
4. **Looks**: the brain picks from your camera and screen scenes plus three asset looks Framecast adds:
   - **Asset + camera circle** (circle bottom right);
   - **Asset + camera square** (asset left, square camera right);
   - **Asset full**.

   The asset looks show whichever asset is on air, through an "Asset slot" layer, so your scenes are never edited.
   - When an asset comes up from a camera shot, the circle and square looks take turns, so you stay in view and
     the shapes keep changing. **Asset full** (which hides you) only comes up when the brain asks for it.
   - Framecast also adds a round "Camera bubble" if your studio has none.
   - Scenes with guest slots are left out, since they're empty without guests.
5. **The Rundown tab is private.** In the studio window, a shared screen or window shows "Rundown · private" in
   that spot.
   - What you see is a separate window lying exactly over the panel. It moves and resizes with the studio, and
     viewers never see it, even if the tab is opened by mistake during a show.
   - That window is left out of Framecast's own capture and asks macOS to keep it out of other apps' captures.
   - While live, the panel scrolls to the topic you're on.
6. **Hinglish:** Settings › AI › Following your voice › **Language you speak**.
   - **Hinglish (English + Hindi)** runs Apple's English (India) and Hindi recognisers together on the same mic.
     The Hindi one writes code-mixed speech in Latin letters ("aaj main aapko… it is called Framecast"), and
     the live brain reads both versions.
   - The Hindi model downloads from Apple once.
   - Cue lines and the word prompter use the English recogniser.
7. **References:** `make_card` with `kind: reference` and `image` (a picture already in `assets/`, for example
   from `save_image`). It draws the picture in a browser-style frame with its address, and the picture slowly
   zooms while on screen. Raw screenshots can live in `assets/sources/`, which isn't listed as assets.
8. **Presenter view** (toolbar › **Presenter**, Rundown › Presenter view, or Show › Open Presenter View): every topic with its points, ticked off as you cover them;
   NEXT; the asset on screen; the last decision; cost so far. The current topic scrolls to the top.
   - Framecast's screen capture leaves out its own windows.
   - To demo Framecast itself, turn on Settings › General › **Show Framecast in screen shares**. A captured
     display then includes the studio window, but the presenter view stays hidden. Framecast leaves it out
     by window, and macOS keeps it out of other apps' captures.
   - This window also asks macOS to keep it out of other apps' captures. A screenshot of it fails with "could
     not create image from window".

**Rules the brain follows:**
- It only changes scenes and the asset on screen.
- It acts only with confidence ≥ 0.55.
- A look stays at least 20 s (8 s when the topic changes) and an asset at least 8 s.
- Nothing happens within 3 s of any switch, and at most six automatic changes a minute.
- A change held only by those minimums is tried again when they're up, unless a newer decision comes first.
- A switch by hand pauses it for 30 s.
- Answers that arrive later than 8 s are only used for the outline.

**Without a key, or offline:** after 3 failed calls the outline keeps moving on the Mac (sentence meaning
against each topic and point) and the visuals pause. Calls are retried after 30 s.

**Rehearse** in a topic show replays the run-through through the brain with today's outline: one call per 6 s of
speech, the same rules, a timeline of what it would have done, topics reached, points covered and cost.

**API key:** read once per listening session, off the main thread, because macOS may ask for Keychain access
after an update.

## Scripted shows

Phase 1 of the AI director (see docs/AI-DIRECTOR-RESEARCH.md): plan the show before you go live, then let
Framecast follow along while you present. The AI works only before the show. The live part runs on this Mac,
offline and free.

## Using it

1. **Rundown** tab (inspector, right) › **New show**. Give it a title and paste your rough script.
2. Turn the script into parts:
   - **Write it for me** sends the script, the title and your scene names to Claude or OpenAI with your own API
     key (Settings › AI). It returns the parts. Each part has a title, a scene (always one that exists in your
     studio), the cue (the words that start it), other ways of saying the cue, and its script text. It also
     returns words speech recognition may mishear ("opa" → "opus"). The parts it replaces are kept as
     `show-before-ai.json`.
   - **Split by paragraphs** needs no AI. It makes one part per paragraph, takes the cue from the start of the
     first sentence, and guesses the scene from words like "show you" or "thanks for watching".
   - Click a part's header to edit it: title, scene, cue, other wordings (one per line) and notes. Right-click
     a part to move, duplicate or delete it, or use **Add part**.
3. Choose a mode:
   - **Suggest** (the default): when you say the next part's cue, a card shows the part and what was heard.
     **Take** (⌃⌥⌘T, from any app) puts it on air.
   - **Auto**: Framecast switches itself, and ⌃⌥⌘U switches back.
   - **Off**: you take parts by hand.

   With no suggestion showing, ⌃⌥⌘T takes the next part.
4. **Listen**: Framecast listens to the first microphone that's in the stream, and not while it's muted. Apple's
   on-device recognizer does the listening (macOS 26 or later). Speech never leaves the Mac. It listens for the
   next three parts that have a cue.

**Rules the director keeps**
- It only changes scenes. It never records, broadcasts or touches sound.
- In Auto it won't switch within 3 s of the last switch. A cue heard sooner is switched when the 3 s are up.
- At most six automatic switches a minute.
- A switch by hand to the next part's scene moves the rundown there.
- Any other switch by hand pauses Auto for 30 s. The panel shows the countdown, and **Resume** ends it early.
- Undo also pauses Auto for 30 s.
- Words that already triggered a part can't trigger another one.
- Suggestions disappear after 12 s.

Each decision is logged in the show's folder, so you can see later why it switched:
listen, suggest, auto, hold, take, undo, manual, mode, write.

## Prompter

Rundown › **Prompter** (or Show › Open Prompter) opens the script in its own window in large type. The text is
each part's text under its title and scene, or the whole script when the parts have none.

While Framecast listens:
- Words you've said dim, the current line stays a third of the way down, and cue lines are in the accent colour.
- The bar shows On script or Off script, the part on air, and the next cue.
- **Follow** turns the scrolling off. The A buttons change the size, and **Mirror** flips the text for
  teleprompter glass.

How it finds your place: the last 10 words heard are lined up with the script (local alignment, which allows
skipped and extra words).
- Moving up to 80 words ahead needs 3 matching words.
- Moving back, or further ahead, needs 5.
- After 8 s without a match it counts as Off script and searches the whole script.
- Taking a part moves the place to the start of its text.

## Rehearsal

**Rehearse** listens as in a show and keeps what was heard. The transcript only, never audio, goes to
`rehearsals/<date time>.jsonl` in the show folder. **Stop rehearsal** replays it at once against the rundown,
moving through the parts as Auto would. The result shows:
- **Caught N of M cues**, with the time of each and whether it matched by words or by meaning.
- **Missed** cues, with the closest thing you said between the neighbouring cues. **Use this as another way to
  say it** adds it to the part and replays.
- **Possibly misheard** words: heard where the script has a similar word with the same first letter, such as
  "opa" for "opus". Only lines that clearly follow the script count. **Fix** adds an alias and replays.

**Replay** runs a rehearsal again with the cues as they are now, so you can edit and check. The clock button
lists earlier rehearsals.

## Show folders

`~/Library/Application Support/Framecast/Shows/<date> <title>/` (Finder: Rundown › ⋯ › Show in Finder) holds:
- `show.json`
- `script.md`
- `logs/director-<date>.jsonl`, one JSON line per decision
- `rehearsals/<date time>.jsonl`, what was heard in each rehearsal
- `show-before-ai.json`, after a rewrite

`show.json` (fields that are left out get their defaults, so hand-written files work):

```json
{
  "format": "framecast-show/0.1",
  "title": "Opus vs Sonnet",
  "script": "…",
  "parts": [
    { "title": "Welcome", "scene": "Camera", "cue": "", "alsoAccept": [], "notes": "…" },
    { "title": "Benchmark chart", "scene": "Screen + camera", "cue": "now let me show you the benchmark chart",
      "alsoAccept": ["here are the benchmark numbers"], "notes": "…" }
  ],
  "aliases": [{ "heard": "opa", "meant": "opus" }],
  "director": { "mode": "suggest", "minShotSeconds": 3 }
}
```

Scenes are matched by name, ignoring case. A part whose scene doesn't exist shows a warning and can't be taken
until you pick one.

## How cues are matched

On each transcription result (about 0.6 s after the words are spoken, in "fast" mode):

- **By words**: the cue's words appear in order among the last few words heard. Small misspellings are
  allowed (75% letter similarity for words of 4+ letters), and the show's aliases are applied. At least 75% of
  the cue's words must be found, ending on its last word. This fires as soon as the last word is heard.
- **By meaning**: once a sentence is finished, Apple's on-device sentence embedding compares it with the cue
  and each other wording. A cosine distance of 0.85 or less counts as a match. This catches paraphrases, but
  only at the end of the sentence.

The 0.85 threshold and the 75% share come from two 40 s test talks (experiments/ai-director). Replay real
rehearsals before relying on Auto.

## Control link (Settings › AI)

A local MCP server so Claude Desktop, Claude Code or another MCP app on this Mac can operate Framecast from
chat. It's off until you switch it on.

**Tools:**
- `get_show_state`
- `switch_scene`
- `create_scene` (from one of the layouts)
- `set_rundown`
- `take_part`
- `toggle_overlay`
- `add_marker`
- for topic shows: `set_outline`, `make_motion`, `make_card`, `save_image`, `show_asset`

It can't record, broadcast or change sound.

**Safety:**
- Listens on 127.0.0.1:8095 only.
- Answers only requests addressed to 127.0.0.1 or localhost, so DNS rebinding can't reach it.
- Refuses requests that carry a web page's `Origin`.
- Every request needs `Authorization: Bearer <token>`. The token is in
  `~/Library/Application Support/Framecast/ControlLink/token` (mode 600); **New Token** replaces it.

**Setup:**
- **Claude Desktop** (Settings › Developer › Edit Config): add
  `"framecast": { "command": "/…/Framecast.app/Contents/MacOS/framecast-mcp" }` under `mcpServers`. Settings ›
  AI shows the exact text with a Copy button. The helper reads the token itself.
- **Claude Code**: `claude mcp add framecast -- "/…/Framecast.app/Contents/MacOS/framecast-mcp"`.
- **Other MCP apps**: Streamable HTTP at `http://127.0.0.1:8095/mcp` with the bearer token.

Using your Claude subscription this way (Claude Desktop or Claude Code signed in with your plan) is fine for
your own use. A product sold to others must use API keys (see the research doc).

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌃⌥⌘T (global) | take the suggested part, or the next part |
| ⌃⌥⌘U (global) | switch back after the director's last automatic switch |

The **Show** menu also has: Show Rundown, Follow My Voice.

## Test hooks (`FRAMECAST_UI=…,test-control`)

- Show: `show-new:<title>`, `show-script:<file>`, `show-split`, `show-import:<show.json>`, `show-write`,
  `show-close`.
- `ai-setup:<claude|openai>|<key>|<model>` sets a test key and model. Test launches keep their own Keychain
  items and their own `Shows (tests)` and `ControlLink (tests)` folders, on port 8096.
- `FRAMECAST_AI_BASE_URL` (test launches only) sends Write it for me to a stand-in server instead of the real
  service.
- Director: `director-mode:<off|suggest|auto>`, `director-listen[:<audio file>]` (a file plays in real time, like
  a mic), `director-stop`, `director-take`, `director-undo`, `director-top`.
- `control-link:<on|off>`.
- `open-prompter`.
- Topic shows: `outline-import:<json>` (title, brief, topics, assets), `topic:<n>`, `brain-model:<model>`.
  `FRAMECAST_AI_TEST_KEY` gives a test launch that uses the stand-in a key without the Keychain.
- `render-view:presenter|<png>`.
- Rehearsal: `rehearse-start[:<audio file>]`, `rehearse-stop`, `rehearsal-import:<jsonl>` (any transcript in
  the experiments' format), `rehearsal-accept:<part number>`, `rehearsal-alias:<n>`.
- `render-view:<rundown|ai-settings|prompter>|<png>`.
- `dump-state` includes `rundown` and `controlLink`.

## Verified (2026-10-21, test copy, this Mac)

- **Write it for me**, against a stand-in server on 127.0.0.1. Requests were shaped as the APIs expect:
  - Anthropic: `x-api-key`, `anthropic-version`, streaming, `output_config.format` JSON schema with the scene
    names as an enum.
  - OpenAI: Responses API, strict `text.format` schema.

  Both answers were parsed into 5 parts plus aliases. **Not yet tried against the real services:** that needs
  your keys.
- **Suggest mode, scripted talk:** 4/4 suggestions, each within about 0.9 s of its cue word (one at the same
  moment). Take put the scene on air about 0.1 s later.
- **Auto mode, ad-libbed talk:** 4/4 switches, about 0.5–0.8 s after each cue, with no false switches. The
  paraphrased cues matched the other wordings the stand-in supplied. I wrote those knowing the test talk, so a
  real AI's wordings may catch fewer.
- **Undo** switched back and paused Auto.
- **Switches by hand:**
  - To the next part's scene: moved the rundown along.
  - Anything else: paused Auto.
- **Control link:** all 7 tools work through `framecast-mcp`, in 1–24 ms each. It refused:
  - a wrong or missing token (401);
  - a web page's `Origin` (403);
  - a look-alike `Host` (421);
  - GET (405).

  It listens on 127.0.0.1 only.
- **Split by paragraphs:** 4 paragraphs became 4 parts with sensible scenes.
- **Prompter:** on the ad-libbed talk it found its place after about 8 s and then followed every part. On the
  scripted talk it followed throughout. The open window scrolled with the speech.
- **Rehearsal:**
  - The ad-libbed talk caught 3/4. The miss's closest line was "Okay, here are the benchmark numbers".
    Accepting it gave 4/4 on replay.
  - The only mishearing flagged was opa → opus.
  - The scripted talk's transcript caught 4/4 and flagged sonic → sonnet and opa → opus.

- **Topic show, end to end, with a stand-in brain.** Note that the stand-in's own choices are simple keyword
  rules, so decision quality isn't tested.
  - **Preparation through the control link:** `set_outline` wrote 6 topics, `make_card` drew 2 cards, and
    `save_image` saved a picture, from 127.0.0.1 only. `CLAUDE.md` and `AGENTS.md` were written into the folder.
  - **Auto on the ad-libbed talk** (7 calls, about 0.4 s each):
    - price chart at 0:16;
    - benchmark card at 0:25, after its hold;
    - Screen + camera for the demo at 0:30;
    - reference picture at 0:37;
    - Camera at 0:46.

    Topics moved 1 → 6 and 8 points were ticked off.
  - **Suggest** offered the same changes without making them.
  - **Undo** restored the asset look with its asset and paused Auto.
  - **Editing `show.json` from outside** was picked up within 3 s.
  - **Rehearsal replay** through the brain produced a timeline.
  - **Privacy:** the presenter window could not be captured by macOS screen capture.
- **Motion graphics and a talk that jumps between topics** (13-topic show, 17 motion graphics, 6 references):
  - Every graphic was rendered and checked frame by frame with the camera circle drawn in place; nothing sits
    under it.
  - A talk going Welcome → Cost of one hour → How I built it → What's already solved → What you need moved the
    topic 1 → 11 → 9 → 3 → 10, with the matching graphic on screen each time and the camera bottom right.
  - Looping graphics repeat on screen; swapping the asset keeps the look.

**Not verified:**
- the real live brain (Haiku 5.5 or gpt-6-luna) choosing topics and visuals;
- a real microphone in a live show;
- Claude Desktop or Claude Code actually connected (the Claude Code login on this Mac has expired);
- the real Anthropic and OpenAI services;
- macOS versions before 26 (Listen is disabled there).
