# Framecast

A native macOS live-streaming and recording studio.
One show, two formats at once: a 16:9 and a 9:16 canvas rendered on one clock, recorded side by side and streamed
to any RTMP/RTMPS destination, with layouts, overlay elements, live chat and browser guests.

- What was tested, the results, and what is missing: [docs/VERIFICATION.md](docs/VERIFICATION.md)
- Guests (this Mac, your Wi-Fi, or anywhere through your LiveKit Cloud project): [docs/GUESTS.md](docs/GUESTS.md)

No account, subscription, trial, paywall, analytics or update checks. Everything stays on this Mac except the
streams you send to destinations you add.

## Requirements

- macOS 14 or later on Apple silicon.
- Xcode Command Line Tools (Swift 6.x). Full Xcode is not needed.
- Optional, free and open source, via Homebrew:
  - `brew install livekit` for guests (Framecast starts it on 127.0.0.1 when you open the guest room).
  - `brew install mediamtx` to test streaming against a local RTMP server.
  - `brew install ffmpeg` for the verification scripts.

## Build and run

```bash
./scripts/build_app.sh
```

```bash
open build/Framecast.app
```

`build_app.sh` builds with SwiftPM in release mode, assembles `build/Framecast.app` (Info.plist with usage
descriptions, generated icon, embedded `LiveKitWebRTC.framework`, guest web page) and signs it.

Signing: by default the app is signed ad hoc. macOS then forgets camera, microphone and screen permissions after
every rebuild. To keep them, create a local self-signed identity once (stored in `build/signing`, nothing is added
to your login keychain or trust settings):

```bash
./scripts/make_signing_identity.sh
```

The first launch shows onboarding (permissions, devices, format, destinations). macOS asks for Camera, Microphone
and Screen Recording access when a source first needs it. If macOS keeps asking for Screen Recording although
Framecast is switched on in System Settings, clear its old entries and allow again on the next launch:

```bash
tccutil reset All app.framecast.studio
```

## Using it

The window has three columns: **Scenes** on the left, the canvases in the middle with the control bar under them,
and the inspector on the right (Comments · Green room · Guests · Mixer · Overlays · Layer · Rundown). The toolbar switches
between the **16:9**, **9:16** or **Both** canvases and opens Destinations, Add to scene and Settings.

- **Scenes**: click a scene (⌃1–⌃9) to put it on air with the transition shown in the control bar. With
  **Preview** on (control bar, ⌥⌘P) a click puts the scene in a private preview instead; set it up, then
  **Put on air** (⌘↩ or double-click). Every edit can be undone (⌘Z) and redone (⇧⌘Z). Edit layers on
  the canvas (drag, corner-resize, snapping) or in the Layer tab (position, crop, fit, shape, opacity, mirror,
  filters, colour, camera LUT). Right-click a scene to rename, duplicate, restore or delete it; **+** adds a new one.
- **Record**: records the canvases shown in the toolbar. Files go to `~/Movies/Framecast` by default
  (Settings › Recording) as `Framecast 2026-10-19 14.03.22 16x9.mov` (MOV, MP4 or MKV).
- **Broadcast**: add destinations in **Destinations** (⌘2): YouTube, Twitch, X, Instagram or a custom RTMP/RTMPS
  server, each with a stream key (kept in the Keychain) and a canvas. **Start broadcast** sends to every
  switched-on destination; "Also record on this Mac" records at the same time.
- **Overlays**: name tags, headlines, thank-you cards and QR codes animate over every scene (⌥⌘1–9).
- **Video and music**: Add to scene › Video or music… Videos play while their scene is on air; music loops in
  the mix and can lower itself while someone talks. The Mixer has a sound pad (⌃⌥1–9) with six built-in
  sounds and three for your own.
- **During a show**: Marker (⌥⌘M) and Clip (⌥⌘S) in the control bar. Markers and scene changes become a
  YouTube chapter list in the recap and in `<recording> chapters.txt`; Clip saves the last 30 seconds as
  16:9 and 9:16 MP4s.
- **Pre-flight check** (⇧⌘K, or in Start a broadcast): sound in the stream, mic level, cameras, permissions,
  destinations and disk space, plus an optional 10-second test recording and upload speed test.
- **Backgrounds**: Layer tab › Change background… (or ⇧⌘B) opens a picker with all 60 backgrounds (gradients,
  aurora, abstract, textures, rooms, nature, neon, basic), Dark/Light filters and large 16:9 and 9:16 previews. Add your own with `scripts/add_backgrounds.swift`
  (docs/BACKGROUNDS.md, which also has a prompt for generating them).
- **Creator pack**: Add to scene › Creator pack. Card scenes (intro with a live countdown, break, outro; four
  styles), frame scenes (camera, screen or guest placed in each opening), 20 backgrounds and 9 annotations.
  Every piece has its own 16:9 and 9:16 artwork. Countdowns restart from the Layer tab.
- **Comments**: click a comment to show it on screen. YouTube/Twitch connections need your own OAuth apps (see
  docs/VERIFICATION.md).
- **Show from a brief**: tell Claude about your next stream (Rundown › Brief › **Copy for Claude** for Claude
  Desktop, or **Claude Code** for the show folder). On your Claude plan it writes the outline (topics and points),
  makes motion graphics (roadmaps, stick-figure scenes, bar charts, gauges, pipelines, checklists), cards and
  website references, and saves them into the show's folder. Live, with **Listen** and **Auto**, a small model on
  your API key (about $0.10–0.50 per show-hour) follows whichever topic you're on, in any order, ticks off what
  you've covered, puts each asset on screen when you talk about it and keeps changing the look (camera circle
  bottom right, camera square beside the asset, screen share); ⌃⌥⌘U undoes. The **Presenter view** (toolbar ›
  **Presenter**) shows your topics, ticking off points as you cover them, and only you see it. The Rundown tab is private as well: anyone watching your shared screen sees a
  "private" placeholder there. Listen understands Hinglish (Settings › AI › Language). Details: docs/RUNDOWN.md.
- **Rundown**: plan a show from a rough script. **Write it for me** (your own Claude or OpenAI API key, Settings ›
  AI) or **Split by paragraphs** (no AI) turns it into parts, each with a scene and the words that start it.
  **Listen** follows your voice on this Mac and, when you say the next part's cue, suggests the switch (take it
  with ⌃⌥⌘T from any app) or makes it in Auto (⌃⌥⌘U switches back). Settings › AI also has a **control link**
  so Claude Desktop, Claude Code or other MCP apps on this Mac can switch scenes and write the rundown.
  **Prompter** shows the script in large type that follows you (said words dim, cue lines highlighted, mirror
  for teleprompter glass). **Rehearse** a run-through, then see which cues were caught; a missed one shows what
  you said instead, with one click to accept it, and likely mishearings ("opa" for "opus") get a Fix button.
  Details: docs/RUNDOWN.md.
- **Guests**: choose who can join (this Mac, your Wi-Fi, or anyone through your own LiveKit Cloud project), open
  the guest room in the Guests tab, send the invite link, let people in, then **Put on air** in the
  Conversation, Panel or Screen with guests scenes. Guests only need a browser. Set-up: docs/GUESTS.md.

## Privacy and security

Framecast has no account, no server of its own, no analytics and no update checks. It only connects where you
point it:

| What | Goes to | Who sees your IP address |
|---|---|---|
| Streaming | the RTMP/RTMPS servers you add (YouTube, Twitch, …) | that platform |
| Chat connections (optional) | Google / Twitch APIs, with OAuth apps you register | that platform |
| Guests: This Mac | nothing leaves the Mac; every listener is on 127.0.0.1 | nobody |
| Guests: Wi-Fi | devices on your network; listeners only on the Mac's private address | devices on your Wi-Fi |
| Guests: anywhere | your LiveKit Cloud project; guests load the page from your static host | LiveKit (not your guests) |
| Upload speed test (only when you click it) | 8 MB of random data to speed.cloudflare.com | Cloudflare |
| Write it for me (only when you click it) | the script, show title and scene names to Anthropic or OpenAI, with your own API key | that service |
| Live brain (topic shows, while listening in Suggest or Auto) | the outline and the last 90 s of what you said, as text, every few seconds, with your own API key | that service |
| Listen (rundown director) | nothing leaves the Mac: Apple's on-device speech recognition | nobody |
| Control link (off by default) | nothing leaves the Mac: 127.0.0.1 only, token required | nobody |

- Stream keys, AI API keys, the LiveKit API secret and the optional Google client secret are kept in the macOS
  Keychain.
  Sign-in tokens stay in memory only. LiveKit Cloud settings come from your own `.env` (see `.env.example`),
  which git ignores.
- Invite links for remote guests carry a short-lived token that can only ask to join; you let each person in.
  Each link works for one person. The token sits after `#`, which browsers never send to the web host.
- The guest page servers answer only requests addressed to them (127.0.0.1 or the Mac's Wi-Fi address), so web
  pages can't reach them through look-alike addresses (DNS rebinding). Wi-Fi mode refuses to open if the Mac has
  a public address.
- `FRAMECAST_UI` and its `test-control` mode exist for automated tests: they let local scripts press buttons.
  Don't set them for normal use.

## Command-line verification

`fcverify` drives the engine headlessly with a test pattern that flashes on every whole second and a tone that
beeps on the same seconds, so sync can be measured without cameras or permissions.

```bash
swift build --product fcverify
```

```bash
.build/debug/fcverify record --seconds 10 --container mkv --out local-output/verify --name t
```

```bash
python3 -I scripts/avsync.py --summary local-output/verify/t-horizontal.mkv local-output/verify/t-vertical.mkv
```

```bash
.build/debug/fcverify stream --url rtmp://127.0.0.1:1935/live --key test --seconds 15
```

```bash
.build/debug/fcverify filters
```

`scripts/mediamtx-local.yml` runs a local RTMP server with every listener on 127.0.0.1
(`mediamtx scripts/mediamtx-local.yml`).

The packaged app also accepts test hooks through `FRAMECAST_UI` (for example
`open --env FRAMECAST_UI="onboarded,test-control,mask-devices" build/Framecast.app`) and, when launched with
`test-control`, takes commands from `build/fcctl` (built from `scripts/fcctl.swift`): `record-start`,
`record-stop`, `golive`, `endstream`, `admit-all`, `stage-all`, `layout:N`, `dump-state:/path.json` and more.
These exist because this Mac had no Accessibility permission for UI automation. They are off unless requested.

## Layout

```
Sources/FramecastEngine   media engine: sources, compositor, mixer, encoders, MOV/MP4/MKV, RTMP
Sources/Framecast         SwiftUI app: studio, panels, settings, destinations, chat, guests
Sources/fcverify          headless verification harness
Resources/guest           guest web page (+ vendored livekit-client, Apache-2.0)
Resources/AssetPacks      creator asset pack (manifest, artwork, previews, editable SVGs) and background library
scripts/                  build, signing, sync analysis, local servers, guest page export
docs/                     verification record, guest set-up, backgrounds, screenshots
local-output/             test recordings and captures (git-ignored)
```

Framecast's code, icon and artwork are its own. The guest page bundles livekit-client (Apache-2.0; licence in
Resources/guest), and the app uses the LiveKit Swift SDK (Apache-2.0) through Swift Package Manager.

## License

MIT; see [LICENSE](LICENSE). The LiveKit parts named above keep their Apache-2.0 license.
