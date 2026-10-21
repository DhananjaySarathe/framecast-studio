# Framecast: verification record

Date: 2026-10-17. Machine: Apple silicon, macOS 27.0.1, Command Line Tools only (Swift 6.4).
"Verified" below means it was run and the result was measured or observed; the evidence column says how.
Test files are in `local-output/` (git-ignored). Nothing was uploaded; every stream went to a local server.

## Verified

| # | Feature | How it was tested | Result |
|---|---|---|---|
| V1 | Simultaneous landscape + portrait recording (MOV, H.264) | `fcverify record` 8 s, both canvases | 1920×1080 and 1080×1920, 30 fps, 240 frames each, AAC 48 kHz stereo |
| V2 | A/V sync inside each file | `scripts/avsync.py`: white-flash frames vs 1 kHz beep onsets, every second | MOV mean 0.48 ms, MP4/HEVC 1.98 ms, MKV 0.15 ms (all ≤ 2.5 ms max) |
| V3 | Sync **between** the two formats | same script, flash and beep times compared across files | 0.0 ms difference for video and audio in every run (MOV, MP4, MKV, app path) |
| V4 | MP4 + HEVC | `fcverify record --container mp4 --codec hevc` | HEVC Main + AAC LC; durations 8.000/8.002 s |
| V5 | MKV (own muxer) | `fcverify record --container mkv`; `ffmpeg -f null` decode | decodes with 0 warnings; duration element patched (8.002 s); H.264 High + AAC LC |
| V6 | Pause / resume | 10 s run, paused 3 s–6 s | 7.0 s output, 210 frames, A/V 0.26 ms, both formats identical |
| V7 | Split into parts | split every 0.1 min, 13 s run | parts 6.0 s + 6.0 s + 0.98 s (390 frames total) per canvas |
| V8 | Constant frame rate output | packet timestamps | exact 1/30 s steps; first frame within one frame of start |
| V9 | File names | app recordings | `20-33-58-17-10-26-horizontal.mov` / `-vertical.mov`; single canvas `20-33-07-17-10-26.mov` |
| V10 | In-app recording path (Record button logic, both canvases) | app launched with `sync-test`, recorded via `record-start/stop` | 298 frames each, A/V −5.7 ms (constant, within ±½ frame), 0.0 ms between files |
| V11 | RTMP publish (own client) | `fcverify stream` to local mediamtx (127.0.0.1) + `ffprobe rtmp://…` | server received H.264 High 1920×1080 30 fps + AAC LC 48 kHz stereo |
| V12 | A/V sync of what the server received | mediamtx's own recording of the stream, `avsync.py` | mean −0.15 ms, max 1.35 ms over 12 pairs |
| V13 | Stream reconnect | server killed 10 s in, restarted 7 s later | status live → reconnecting (backoff 1, 2, 3, 5 s; reason shown) → live; recovered automatically |
| V14 | Go live from the app, two destinations (horizontal + vertical) + recording | `add-destination`, `golive:record`, `ffprobe` both server paths | 1920×1080 and 1080×1920 streams live at the same time |
| V15 | Recording survives stream failure | server killed during V14 | both recordings 41.10 s, 1,233 frames, **no gaps**, bit-identical audio (same SHA-256 of decoded PCM) |
| V16 | In-app reconnect UI | V14 outage | per-destination "reconnecting" status, alert "Network dropped on this stream only…", health light; back to "Healthy" after recovery |
| V17 | RTMP error reporting | refused port, HTTP server, silent server, http:// URL | "Connection refused…", "The server answered, but not as an RTMP server…", "The server didn't answer within 8 seconds.", "That isn't an rtmp:// or rtmps:// address." |
| V18 | Recording to an unwritable folder | `--out /System/…` | writer fails with "Cannot create file"; the app shows "Recording couldn't start." |
| V19 | Guests: join, lobby, stage | built-in browser on this Mac joins the invite link with synthetic camera/mic (`?test=1`) | knock → waiting → admitted → lobby → on stage; guest page shows "On stage" |
| V20 | Guests see/hear the show | guest page inspected | host "program" video track playing (adaptive 640×360 layer) + host microphone track |
| V21 | Guest in the program | recording in the Interview layout | guest half of the frame shows the guest's animated colours; guest's 440 Hz tone at −19.5 dB vs −40.9 dB in a neighbouring band |
| V22 | Backstage chat | host → guest and guest → host | both messages delivered and listed |
| V23 | Everything local only | `lsof` on mediamtx, LiveKit and Framecast | only 127.0.0.1 listeners: RTMP 1935, LiveKit TCP 7880 + UDP 7882, guest page 8090 |
| V24 | Filters | `fcverify filters` pixel checks | chroma key, luma key, .cube LUT, saturation, circle mask: all PASS |
| V25 | Overlay elements and chat on screen | app screenshot (old interface) | lower third (slide in) and chat card shown on canvas; "ON SCREEN" chip in chat |
| V26 | Camera capture | app with the user's camera permission | camera shown in layouts and thumbnails (screenshots containing the camera were deleted) |
| V27 | Microphone capture | Audio panel | device name resolved, level meter moving |
| V28 | Session summary | ending stream + recording | summary sheet with streams, recordings (Reveal in Finder), export report |
| V29 | Window capture (ScreenCaptureKit) | `fcverify capture --kind window` on a test window cycling red → green → blue each second; `scripts/capturecheck.py colors` | 1920×1080 recording shows the full cycle in order: PASS |
| V30 | App capture | `--kind app` with the test app's bundle id; `capturecheck.py colors-any` | cycle found in order: PASS |
| V31 | App audio and system audio | test app plays a quiet 700 Hz tone; `--kind appaudio` / `--kind sysaudio`; `capturecheck.py tone` | 700 Hz band −25.0 dB vs −48.5 dB neighbour band, both: PASS |
| V32 | Display capture | `--kind display`, brightness statistics only (the recording was deleted right after, it contained the user's screen) | 90 frames in 3 s, full luma range (live picture): PASS |
| V33 | Capture **inside the packaged app** (`build/Framecast.app`) | app recordings via `test-control`: each source shown alone (`solo`) or alone in the mix (`only-audio`), then the same `capturecheck.py` checks | window: red → green → blue cycle PASS; app: cycle PASS; app audio: 700 Hz −25.0 dB vs −48.5 dB PASS; system audio: −28.5 dB vs −52.0 dB PASS; display: 90 frames, luma range 246 PASS (display and system-audio recordings deleted after the statistics) |
| V34 | Captured window closes | test app quit while its window was on the program | source turns "Window not found. Add it again from the + menu."; the program stops showing the last frame (no test colour in the next recording) |
| V35 | App and app-audio sources follow their app | Framecast started before the test app; test app opened, quit, opened again; `dump-state` plus a recording at each step (`capturecheck.py colors-any` / `tone`) | before opening: "Waiting for the app to open."; after opening: both start by themselves, cycle and 700 Hz tone PASS; after quitting: "Waiting for the app to open.", no picture and silence; after reopening: both start again, cycle and tone PASS. Picture checked in 8 recordings: 7 showed the full cycle; the first one after the app's first launch showed it for only part of the clip, and this didn't happen in 7 repeats |
| V36 | Guests on the Wi-Fi (https) | Wi-Fi mode; headless Chrome with a throwaway profile opens the https invite on the Mac's Wi-Fi address with synthetic camera/mic, accepting the self-signed certificate as a guest would; let in, on stage, recording in the Interview layout | listeners only on 127.0.0.1 and the private Wi-Fi address (none on public or wildcard addresses); page and join requests over https; signalling through the https address; guest's tone −19.5 dB vs −39.1 dB and moving picture in the program; guest page shows the show playing, "On stage" and the host's backstage message |
| V37 | Remote-guest flow (the LiveKit Cloud code path) | "Anyone with a link" mode pointed at the LiveKit server on this Mac; guest page loaded with the invite token after `#` | knock over a data message → "Waiting"; link replaced at once (single use); let in → guest reconnects under a new identity, sees the show; on stage → tone −19.5 dB vs −39.1 dB and moving picture in the recording; backstage message delivered; a second person reusing the used link is turned away and the original guest stays on stage; Remove works |
| V38 | This Mac only, after the changes | same flow as V19–V22 with a headless guest | let in, on stage, show playing, backstage message; LiveKit still listens on 127.0.0.1 only |
| V39 | Guests through a real LiveKit Cloud project (the user's own, free plan) | settings loaded by the user in the Guests panel; host microphone kept out of the test room; headless Chrome guest with synthetic camera/mic using Framecast's copy of the guest page with the LiveKit Cloud invite token | no LiveKit server on the Mac; host connected ("Guest room open on LiveKit Cloud"); knock → waiting; link replaced after use; let in → show playing on the guest page; on stage → "On stage", backstage message delivered, tone −19.5 dB vs −39.1 dB and moving picture in the recording; reused link refused by LiveKit ("invalid token: revoked") while the original guest stayed on stage; Remove → guest page says "The host removed you from the room." |
| V40 | Guest page on the user's static host (Cloudflare Pages, free) + LiveKit Cloud | page uploaded unchanged from `scripts/export_guest_page.sh`; checked with curl, then a headless Chrome guest opened the real invite link (hosted page + token after `#`) | page and client library byte-identical to the app's copies; `_headers` applied (no-referrer, nosniff, camera/mic for the page only); knock → let in → show playing → on stage; tone −19.5 dB vs −39.1 dB and moving picture in the recording; backstage chat both ways; Remove → "The host removed you from the room."; a reused link is refused |
| V41 | Creator asset pack import | `scripts/import_asset_pack.swift` on the 132 runtime files | every file present, SHA-256 and pixel size match the manifest; 270 MB → 44 MB (opaque 4K art as 10-bit HEIC, transparent PNGs unchanged) |
| V42 | No banding from the smaller files | dark gradient at ×5–7 contrast: original PNG vs 8-bit HEIC vs 10-bit HEIC with grain restored on load | 8-bit HEIC showed contour bands; 10-bit + restored grain matched the original (54 dB PSNR) |
| V43 | Scene and frame layouts on both canvases | added 3 plates and 4 frames via test hooks, screenshots of both canvases (stand-in camera/screen) | text in the plates' slots on 16:9 and 9:16 (portrait slots and the missing badges corrected from the pack's SVG shapes); countdown ticking; camera/screen/guest inside the frame openings with matching corners |
| V44 | Backgrounds and annotations | swapped a layout's background 5 times; added an arrow | background replaced (not hidden underneath), each canvas uses its own orientation; arrow centred with correct proportions on both |
| V45 | Performance with pack artwork | dual-canvas recording on a frame layout; drops and memory while adding layouts | 235 frames in 7.85 s on each canvas (30 fps), 0 dropped frames; artwork decoded off the render thread at canvas size; memory +126 MB for 4 pack layouts, flat across background swaps |
| V46 | Your mic while the guest room is open | recording with the room closed, open, closed again (local LiveKit and LiveKit Cloud) | before the fix: −28.6 dB, then digital silence (−91 dB) once the room opened and after it closed (LiveKit switched the input to Apple voice processing, which hands other readers silence). After: −30.9 / −25.5 / −30.7 dB |
| V47 | Sound through LiveKit Cloud and the stream | your LiveKit Cloud room + hosted guest page, tone guest on stage, recording; then the same with the local guest room streaming to a local RTMP server | recording: guest tone −17.4 vs −37.0 dB, your mic −31.2 dB; guest hears you at −29.9 dBFS; stream received by the server: guest tone −22.5 vs −41.2 dB, your mic −31.4 dB |
| V48 | Tests can't touch your studio or channels | test launches (FRAMECAST_UI) | own scenes, settings, guest choice, destinations and stream keys; a non-local destination is refused (0 outbound connections) |
| V49 | Interface redesign (ui-refresh branch) keeps everything working | screenshot tour of every screen before and after; then on the redesigned app: dual-canvas recording, a creator-pack scene, guest room with a tone guest put on air, streaming to a local RTMP server, `fcverify` A/V sync | both formats recorded (`Framecast … 16x9.mov` / `9x16.mov`) with sound; guest page shows the show, "On air" and the green-room message; guest tone −17.7 vs −37.2 dB; the server received 1920×1080 video with audio; A/V 1.54 ms in each file, 0.0 ms between formats |
| V50 | Background picker and importer | `scripts/add_backgrounds.swift` on sample pictures (3:2 pair, 4K portrait + landscape without size in the name, a 16:9-only picture, an 800×450 one), then the picker in the test copy: groups, Dark/Light, 16:9/9:16, search, apply to all scenes and to one scene, Add to scene › Backgrounds…; then a creator-pack scene and a recording | 3:2 pair cropped 16% to 1536×864 / 864×1536 with a "soft at 1080p" note; orientation read from the shape; 16:9-only noted; 800×450 refused; re-adding replaced files. Picker listed 31 (20 pack + 3 new + 8 basic); new "Neon" group appeared; each canvas showed its own version (snapshots); "all scenes" changed 15 scenes, "only this scene" 1; plate scene and countdown rendered; 3.9 s recording with 118 frames and audio |
| V51 | 32 new backgrounds | 50 generated pairs reviewed: contact sheets, Vision text and face detection, centre busyness, feature-print similarity against each other and the existing 28; banding checked on 4×-stretched crops; imported with `--deband`; picker and program snapshots in the test copy | no text, watermarks or faces; all centres calm; 18 left out as near-duplicates or weak (docs/BACKGROUNDS.md); 8-bit steps visible in the sources, gone in the stored 10-bit files, average colour within 1/255; 64 files, 8 MB; picker lists 60 with the new Nature and Neon groups; Sunset Arcade shown on both canvases with its own 16:9 and 9:16 versions |
| V52 | Live scene preview in the background picker | test copy: Camera card and Screen + camera previewed on Lilac Morning and City Window; a flashing test pattern added to the scene and the preview captured six times 0.35 s apart; the full-frame Camera scene with "all scenes" on and off; Picture only; CPU with the picker open and closed | both canvases rendered with the candidate background behind the live layers; 6 of 6 captures differed (the pattern's marker moved); full-frame scene switched the preview to Camera card, and with only that scene it said the background doesn't show; CPU about 41% with the preview vs 37% closed |
| V53 | Undo and redo | test copy: move a layer twice quickly, undo/redo through hooks and through Edit › Undo/Redo menu items, change a background and undo, switch scenes then undo, remove a source and undo | two quick moves = one "Move Layer" step; positions and backgrounds restored exactly; scene switches not recorded and undo never changed the scene on air; removed source and its layer came back |
| V54 | Preview before air | preview on; put Screen + camera in the preview while Camera card stayed on air; edit the preview; put on air (hook and Show › Put Preview on Air); edit the scene on air; turn preview off; both canvases; CPU | air unchanged until Put on air; edits to the on-air scene held as "unaired" until Update on air; turning preview off sent them with the transition; CPU about 49% with preview vs 38% without |
| V55 | Pre-flight check | all checks in the test copy; sound taken out of the stream and the fix button; 5-s test recording; upload test against a sink on 127.0.0.1 (FRAMECAST_SPEEDTEST_URL); sheet drawn off-screen while the screen was locked | six checks passed; sound check failed with mic and desktop left out, fix put the mic back; test recording 1080p H.264 + AAC with sound detected; 8 MB received by the local sink |
| V56 | Video, music, ducking, sound pad | 8-s flash/beep MP4 as a layer (play, end, seek, loop) and recorded; 6-s mono 44.1 kHz M4A looped with a beeping "voice" added mid-recording; pads 1, 3, 2 recorded | video A/V 5.7 ms mean, 13.6 ms max; music looped without a gap (fixed: sound was decoded for "now" instead of the mixer's position); music fell from ~610 to ~150 at 330 Hz after each beep and recovered; chime, applause and ding in the recording |
| V57 | Markers, chapters, instant clips | recording with scene changes at 11 s and 24 s, a marker at 24 s, clip at 33 s; clip while live | chapters "0:00 Camera / 0:11 Camera card / 0:24 Marker 1" in the recap and in both `chapters.txt`; two 30.03-s MP4 clips (901 frames, AAC), A/V −1.9 ms mean; clip while live saved both canvases (fixed: the clip writer deadlocked writing video before audio) |
| V58 | Regression on the studio-pro branch | `fcverify record`; app: preview on, recording both canvases, Put on air mid-recording, local RTMP broadcast to mediamtx on 127.0.0.1 | headless A/V 0.4 ms; both recordings with sound and the scene change; server received 1080p H.264 + 48 kHz AAC, A/V −13 ms, stream up until ended; guest room on this Mac with a headless tone guest: −19.5 dB on air, −90 dB off air; also found and fixed: free disk space was read 15×/s on the main thread |

## Implemented but not verified

| Feature | Why not verified |
|---|---|
| Creator pack card backplates and step markers | In the pack and the repo, not offered in the app yet: they're blank plates that need text or a number drawn on them. |
| Guests from another device on the Wi-Fi | V36 ran the guest browser on this Mac, using the Wi-Fi address. A phone or second computer, and Safari's certificate warning, are untested. |
| RTMPS (TLS) to real services | No real stream keys were used (by design). TLS uses Network.framework; the plain-RTMP path is verified. |
| YouTube connect + live chat (OAuth PKCE, liveChatMessages polling, sending) | Needs your own Google Cloud OAuth client. Not created (would need an account). |
| Twitch connect + chat (device-code OAuth, IRC over WebSocket); anonymous read of a public channel | Needs a Twitch developer app for sign-in; anonymous read would contact Twitch, which wasn't approved. |
| Echo cancellation / noise reduction (Apple voice processing on the mic) | Switches on; effect not measured. |
| Global hotkeys (Carbon hot keys) | Pressing keys from a script needs Accessibility, which wasn't available. |
| Transitions (cut, fade, slide, wipe, move, stinger) | Rendered by the compositor; not frame-measured. |
| Adaptive bitrate | Logic runs every second; the loopback link never congested, so it never stepped down. |
| Multiple recording folders | Code writes every enabled folder; tested with one. |
| Low disk space alert, sleep prevention | Logic present; disk-full and sleep were not simulated. |

## Gaps (not in Framecast v1)

| Feature | Reason |
|---|---|
| Virtual camera (canvas as a webcam in Zoom/Meet) | A CoreMediaIO system extension must be signed by a paid Apple Developer account and notarized. |
| Remote-control app for iPhone/iPad | Separate iOS app; out of scope for v1. |
| Stream Deck plugin | Out of scope; every action has a global hotkey instead. |
| YouTube broadcast management (title, description, thumbnail, privacy, scheduling, DVR, made-for-kids) | Requires a connected YouTube account via OAuth; only chat is wired. Stream-key streaming works without it. |
| Live viewer/like/subscriber stats | Need platform APIs with accounts; the header shows send rate, live count and dropped frames instead. |
| Floating windows view mode, profiles | Not built (time). |
| Encoder sharing (balanced / efficiency first) | Setting is stored; every destination gets its own encoder. |
| Stinger transition with a video file | Simplified to an accent-colour sweep. |
| Accounts, plans, trial, paywall, usage reporting, analytics, auto-update | Deliberately removed: no account, nothing phones home. |

## Accounts, credentials and costs by feature

| Feature | Needs | Cost |
|---|---|---|
| Recording, layouts, elements, filters | nothing | free |
| Streaming to YouTube / Twitch / X / Instagram | your account on that platform and its stream key (X and Instagram may restrict "streaming software" access to eligible accounts) | free from Framecast's side |
| Streaming to a custom server | server URL + key | depends on the server |
| Local streaming test | mediamtx (open source, Homebrew) | free |
| Guests on this Mac | LiveKit server (open source, Homebrew) | free, no account |
| Guests on your Wi-Fi | LiveKit server (Homebrew) | free, no account |
| Guests from anywhere | your LiveKit Cloud project + a static host for the guest page (e.g. Cloudflare Pages, GitHub Pages) | free plans, each needs an account you create |
| YouTube connect / chat | Google account + Google Cloud project + OAuth client (Desktop) | free (default API quota 10,000 units/day) |
| Twitch connect / chat | Twitch account + developer application | free; anonymous read-only needs nothing |
| Virtual camera (not built) | Apple Developer Program | US$99/year |

## Screenshots

`docs/screenshots/` shows the redesigned studio at 1440×900: the studio with comments (S01), the Mixer (S02),
both canvases (S03), Destinations (S04), Add to scene › Creator pack (S05), onboarding (S06) and the guest room with
the Conversation scene (S07). Camera and screen are synthetic stand-ins and the comments are sample text.

## Screen Recording permission (packaged app)

For a while macOS kept asking for Screen Recording even though Framecast was switched on in System Settings.
Cause (from the `tccd` log): the permission entries had been stored against earlier builds' code hashes, and adding
the app again with "+" reused that stale record, so the current build never matched. Fix: `tccutil reset All
app.framecast.studio`, then allow camera, microphone and Screen Recording again when Framecast asks. The build is
signed with a stable local identity (`scripts/make_signing_identity.sh`), so later rebuilds keep the grants; the
self-signed certificate was not the cause.

## Privacy incidents during the build (all local, all fixed)

- mediamtx 1.21 enabled a MoQ listener on all interfaces (:8892/:8893) for about 15 seconds before it was stopped;
  the config now disables it and pins every address to 127.0.0.1.
- LiveKit's ICE/TCP listener bound `*:7881` for about 3 seconds in a test; ICE/TCP is now off and media uses UDP on
  127.0.0.1 only.
