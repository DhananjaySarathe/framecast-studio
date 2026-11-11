# Live editor: research and plan

Framecast v11, 21 October 2026.

**About the numbers.** Every number was measured on your Mac unless it is marked *estimate* or *unmeasured*. Your Mac is a MacBook Pro with an M5 Pro chip, 24 GB of memory, macOS 27.0.1 and a built-in 3024x1964 display. Most measurements come from small stand-alone test programs, not from the full app running with everything switched on. The first build step (Gate 0) measures the real app. During this research nothing was installed or downloaded, and the repo was only read.

---

## 1. In one minute

**What we'll build.** A live editor inside Framecast. It has two parts:
- **A camera operator that runs on your Mac every frame.** It zooms, follows and punches in.
- **Transitions and finishing that look produced.**

The AI director decides *what* to show. The Mac works out *exactly where*, frame by frame. The AI never moves pixels itself.

**What it will look like live**, in the order it ships:
1. **v11.0, screen auto-zoom.**
   - When you click on your shared screen, the 16:9 view glides in to about 1.6x and follows your cursor gently. After 5 seconds with no activity it pulls back to the full screen.
   - On 9:16 the screen stops being a thin letterboxed strip. It becomes a full-height slice that follows what you're doing.
2. **v11.1, auto framing and "trace the object".**
   - The camera keeps you framed when you lean or shift. On 9:16 the crop slides with you instead of cutting you off. The circle camera stays on your face.
   - Draw a box around a product and the shot follows it.
3. **v11.2, Morph 2.0 and camera life.**
   - Layout changes glide with weight, and new elements arrive cleanly.
   - Still shots slowly push in. Holding a key gives a quick punch-in.
4. **v11.3, the AI director directs the camera.** It chooses wide, presenter, screen or speaker, punches in on key lines, and emphasises whichever guest is talking.
5. **v11.4, brand finish.**
   - Whip and zoom-through transitions for segment changes.
   - A branded stinger shaped for each canvas. (A stinger is a short animation that covers a cut.)
   - One colour grade on both canvases.
   - Optional word-by-word captions on 9:16.
6. **v11.5, "say it, it zooms there".**
   - Say "open Settings" and the screen zooms to Settings with a soft spotlight, then returns.
   - Saying a prepared keyword brings up its card or motion graphic.

**Honest limits of doing this live:**
- **Zooms follow the click; they can't start before it.** They land about 0.7-0.9 s after it.
- **Spoken references land about 1.1-1.4 s after the word.** Speech text takes about 0.6 s to arrive.
- **Camera zoom stays gentle**, at 1.2x at most, because your camera delivers 1080p.
- **On your 14-inch display a 2x screen zoom is slightly enlarged** (about 1.1x). It is pixel-sharp only on 4K-class screens.

**Cost: free.**
- **Apple frameworks only through v11.5:** Vision, AVFoundation, ScreenCaptureKit, Core Image, AppKit and Speech.
- **No sign-ups, no new cloud calls.** The live brain on your own key stays the only cloud call.
- **The brain learns only a few abstract words,** such as "screen on air, face visible". It never gets pixels, coordinates or screen text.
- **Tests use an offline stand-in for the brain, so they spend nothing.** Any test that needs the real brain is listed for your OK, with a call count.

**What gets installed: nothing.**
- No model files, no brew, pip or npm.
- **Two small optional models exist if a real need shows up later:** D-FINE-N (about 13 MB) and Depth Anything V2 Small (19 MB), both Apache-2.0. Each one needs your OK first.
- **Two Apple features would download models from Apple, so they stay off:**
  - tap-to-segment, whose download size Apple hasn't published;
  - Apple Intelligence, whose models are several GB. It is used only if you already have it on.

**Load on the laptop:**
- **Frame time.** A frame for both canvases takes 4-7 ms of the 33 ms available at 30 fps today (measured in a test program).
- **Zooming and panning cost essentially nothing extra.**
- **Face tracking runs mostly on the Neural Engine,** Apple's built-in AI chip, which is separate from the graphics chip. It also uses a little CPU: about 9-18% of one core in tests. The Mac has 15 cores, so that is roughly 1% of the whole CPU. Graphics load did not change.
- **A governor (an automatic safety controller) watches the load.** It tracks render time, missed frames, heat and battery, and turns features down one step at a time. In the worst case the picture eases back to today's framing; it never jumps.

**Safe by default:**
- **Camera moves start OFF.** You rehearse first: the moves show in your preview and in a local test recording, while you are not live.
- **Every automatic behaviour is scored on rehearsal replays** before it is allowed on air.
- **Private screen areas are guarded:**
  - no zoom while a password field is active;
  - a pre-filled "never zoom" list (password managers, Messages, Mail, System Settings and others);
  - clicks on Framecast's own windows, other displays and notifications are ignored.

**Effort (estimate):**
- v11.0-v11.3: about 34-43 engineer-days.
- Everything through v11.5: about 53-68 days, plus one day of labelling rehearsals.
- First demo (screen auto-zoom): end of v11.0.


---

## 2. What Framecast does today

**Rendering.**
- A 2 ms timer drives one render loop that draws the 16:9 and 9:16 canvases at the same instant, with Core Image on the graphics chip.
- Framecast uses no Vision and no machine-learning models anywhere.
- Each layer is fitted to its tile **always centred**, so on 9:16, or in a circle tile, an off-centre presenter gets cut off.

**Transitions.**
- Cut, fade, slide, wipe, a colour-bar "stinger" (not a video), and "Move" (0.7 s), which slides layers between layouts.
- Move doesn't animate crops.
- Switching in the middle of a transition makes the picture jump.

**Capture.**
- The camera delivers 1920x1080 at 30 fps.
- The screen comes from ScreenCaptureKit with the cursor drawn in.
- Nothing reads cursor position, clicks or app focus.

**Director.**
- The live brain (about every 6 s, on your key, from on-device speech) picks looks and assets.
- It has guards and a single undo slot on ⌃⌥⌘U.
- Render time is measured but never shown, and the "thermal serious" flag is never set.

**Output.** Whatever is drawn into a canvas goes to the stream, both recordings, the replay buffer, the guest feed and your preview. It is one identical picture.

---

## 3. What the research found

### 3.1 Tracking on the Mac: Apple's built-in tools are enough
- **What Vision offers.** Apple Vision ships with macOS and is free. It finds faces, upper bodies, hands, people masks and "salient" objects (whatever stands out), and it follows a box from frame to frame ([Vision](https://developer.apple.com/documentation/vision/vnrequest), [WWDC21 10040](https://developer.apple.com/videos/play/wwdc2021/10040/), [WWDC22 10024](https://developer.apple.com/videos/play/wwdc2022/10024/), [WWDC17 506](https://developer.apple.com/videos/play/wwdc2017/506/)).
- **Leave it on its default chip.** By default the neural requests run on the Neural Engine. Forcing them onto the CPU made them 3-14x slower. Forcing them onto the graphics chip made them 2x slower and put them in competition with Framecast's own rendering.
- **What to use and what to avoid, from tests on frames of your own recording:**
  - **Upper-body mode** for people. Full-body mode found 0 people in the corner-camera layout.
  - **Not body pose,** which is unreliable for a seated presenter.
  - **Not optical flow,** which runs only on the graphics chip and stalls badly on first use.
- **The tracker is cheap (about 1 ms) but drifts.** Its box lags in size and sits 2-3% low after about 2 s. Re-anchor it from the face detector every 0.5-1 s. It runs on the CPU, not the Neural Engine.
- **Hand pose changed in macOS 26.** The new model's "joints are not in the same locations" ([WWDC25 272](https://developer.apple.com/videos/play/wwdc2025/272/)), so gesture thresholds need tuning per macOS generation.
- **New in macOS 27:**
  - "tap to segment" (`GenerateIterativeSegmentationRequest`, [WWDC26 237](https://developer.apple.com/videos/play/wwdc2026/237/)), which needs a model download from Apple and reports "not ready" on your Mac;
  - image input for the on-device Apple model ([WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241)).
- **Camera features on your Mac:**
  - The MacBook Pro camera supports **Center Stage** on all 7 formats ([Apple](https://support.apple.com/guide/mac-help/aside/glos7c8cf8b7/mac), [WWDC21 10047](https://developer.apple.com/videos/play/wwdc2021/10047/)).
  - Center Stage frames everyone in view, can't be aimed at one subject, and limits the frame rate to 15-30 fps.
  - Running it together with our own follow would move the shot twice.
  - Its "rect of interest" blacks out everything outside the box, so it can't serve two canvases ([doc](https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagerectofinterest)).
  - A separate **Desk View camera** (1920x1440 at 30 fps) is present.
  - **Video Reactions** (confetti and similar, which hand gestures can trigger by accident) are on.
  - The macOS 27 SDK lets an app default gesture reactions to off with the Info.plist key `NSCameraReactionEffectGesturesEnabledDefault`, until you choose otherwise in Control Center.
- **Smoothing.** Detection boxes jitter. The **1€ filter** ([Casiez et al., CHI 2012](https://gery.casiez.net/1euro/)) removes jitter without adding lag. It is about 40 lines that we write ourselves.

### 3.2 Small models, and why we may not need any
- **What Vision already covers:** people, faces, hands, salient objects, text, barcodes and rectangles.
- **What it lacks:**
  - a *labelled* object detector ("zoom to the cup");
  - masks that follow an object through occlusion;
  - depth.
- **Two candidates under 50 MB are worth keeping for later:**

  | Model | Licence | Size | What it adds | Catch |
  |---|---|---|---|---|
  | D-FINE-N | Apache-2.0 | about 13 MB (community Core ML conversion) | Labelled boxes for 80 everyday object types | Its key operation may fall off the Neural Engine ([Apple forum](https://developer.apple.com/forums/thread/740621)). Check before adopting. Fallback: RTMDet-tiny (Apache-2.0 in mmdetection; *not* mmyolo, which is GPL) |
  | Depth Anything V2 Small | Apache-2.0 (the Base, Large and Giant sizes are non-commercial) | 19 MB at 6-bit, published by Apple | Depth for parallax or background blur | Only the Small size may be used |

- **Too heavy:**
  - open-vocabulary detectors (460-690 MB);
  - SAM 2.1 tiny (80 MB, about 1 fps on a phone);
  - RF-DETR-Nano (54 MB, graphics chip only);
  - EdgeTAM (55 MB), which stays on a watch list.
- **Excluded by licence:**
  - Ultralytics YOLO, YOLOv10 and YOLOE (AGPL);
  - YOLOv6/7/9, YOLO-World, RobustVideoMatting and mmyolo (GPL);
  - DEIMv2 (non-commercial);
  - Apple MobileCLIP, Depth Pro and FastVLM (research-only);
  - SORT and boxmot code (GPL/AGPL).
- **Following several people at once:** we write a ByteTrack-style tracker from the published paper, about 300 lines of Swift.
- **Conclusion:** no model is needed for v11.0-v11.5.

### 3.3 Auto-zoom done well
- **Every polished auto-zoom tool zooms after recording,** when the whole timeline can be seen: Screen Studio, Cap, Tella, FocuSee, Screenize, Recordly and Arcade.
  - Screen Studio zooms only where you click ([guide](https://screen.studio/guide/auto-zoom)).
  - Its users complain that zooms start and end too late ([feedback](https://hub.screen.studio/p/custom-settings-for-default-automatic-zoom-range)).
- **Live tools either zoom by hand or reframe only the camera:**
  - by hand: Ecamm ([support](https://support.ecamm.com/en/articles/3216957-zooming-and-panning-in-screen-share-mode)) and the OBS scripts ([obs-zoom-to-mouse](https://github.com/BlankSourceCode/obs-zoom-to-mouse));
  - camera only: Center Stage, Zoom and Teams.
- **I found no app that does automatic screen zoom during a live stream.** That gap is the opportunity.
- **The best blueprint is Screenize** (Apache-2.0, a native Swift Mac app, [repo](https://github.com/syi0808/screenize)). We take ideas and values from it, not code. Its published defaults:
  - **Zoom per activity:** typing 1.6-2.8x, clicking 1.5-2.5x, navigating 1.5-1.8x, scrolling 1.3-1.5x, idle 1.0x. The target fills about 70% of the frame, with 0.08 padding.
  - **Intent rules:**
    - "navigating" means 2 or more clicks within 2 s and within 0.5 of the screen apart;
    - a typing session times out after 1.5 s;
    - idle starts after 5 s.
  - **Dead-zone camera:**
    - the cursor may move freely inside the middle 75% of the view (60% while typing);
    - the camera corrects only 45% of the way;
    - hysteresis 0.15, so the camera doesn't flip back and forth at an edge;
    - pan response 0.2-0.5 s.
  - **Two-layer camera:** a slow layer for region and zoom (about 0.8 s, no overshoot) and a fast layer for small pans ([design](https://raw.githubusercontent.com/syi0808/screenize/main/docs/plans/2026-03-07-dual-layer-camera-design.md)).
- **Cap's springs** (AGPL, ideas only) step on a fixed 8 ms clock ([zoom_spring.rs](https://raw.githubusercontent.com/CapSoftware/Cap/main/crates/rendering/src/zoom_spring.rs)). A **spring** eases toward a target and keeps its speed when the target changes, so a retarget never jerks.
  - The conversion from response and damping is k = (2π/response)² and c = 4πζ/response ([SwiftUI Spring](https://developer.apple.com/documentation/swiftui/spring)).
  - OBS's per-frame blend depends on the frame rate. Don't copy it.
- **Two ways to do it live:**
  - **Mode A, react with no added delay.** Good enough for version 1.
  - **Mode B, a "director delay" of 250-400 ms.** The output is shown slightly late so the editor can see a moment ahead and start a zoom just before the click. OBS caps its own render delay at about 500 ms because of memory ([forum](https://obsproject.com/forum/threads/increase-render-delay-limit.108334/)).
- **Signals and the permissions they need:**
  - cursor position: none;
  - clicks through a global mouse monitor: none, per Apple's header, which says only key events need Accessibility ([doc](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))). Unverified on macOS 27;
  - the text caret: Accessibility;
  - keystrokes: Input Monitoring ([Apple DTS](https://developer.apple.com/forums/thread/707680)).
- **Good practice:** never read typed characters, suppress zoom on password fields ([TN2150](https://developer.apple.com/library/mac/technotes/tn2150/_index.html)), and keep a per-app "no zoom" list.

### 3.4 Transitions that look produced
- **Every pro tool leads with a "morph"** that animates matching sources between layouts:
  - vMix Merge ([forum](https://forums.vmix.com/posts/t26850-What-does-the--Merge--transition-do-when-used-for-a-Stinger));
  - Ecamm Live Motion, the default since v4.4 ([support](https://support.ecamm.com/en/articles/10751152-using-live-motion));
  - Wirecast Smooth ([page](https://www.wirecast.io/en/resources/smooth-transitions));
  - Streamlabs Motion Effect ([post](https://streamlabs.com/content-hub/post/streamlabs-desktop-now-supports-motion-effect));
  - OBS Move ([plugin](https://obsproject.com/forum/resources/move.913/), GPL, ideas only).
- **Stingers are everywhere:**
  - OBS track-matte stingers ([kb](https://obsproject.com/kb/track-matte-stinger-transitions));
  - vMix cut points ([help](https://www.vmix.com/help28/StingerTransitions.html)).
- **Rules of taste:**
  1. **Cut is the default.** It is the most-used transition on Blackmagic's ATEM switchers ([ATEM](https://www.blackmagicdesign.com/products/atemtelevisionstudio/features)). Morph is for layout changes. Allow at most one showy transition per segment change, never one during back-and-forth conversation, and never a random pick.
  2. **Durations:**
     - morph 0.5-0.8 s;
     - whip pan 7-10 frames ([Shotcut](https://forum.shotcut.org/t/motion-blur-transitions-a-demo-video-tutorial-in-progress/20498));
     - things enter in about 225-300 ms and leave in about 195 ms; anything over 400 ms feels slow ([Material](https://m1.material.io/motion/duration-easing.html)).
  3. **Easing:** ease-out for arrivals, and springs for anything the director may retarget mid-move ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10158/)). Bounce looks cheap.
  4. **Camera life:**
     - a slow push of 2-6% over 8-20 s;
     - punch-ins of 10-15% on the emphasised word, not on every line ([Tella](https://www.tella.com/skills/add-zooms)).
  5. **Grain, colour grade and vignette should be barely visible.**
  6. **Captions on 9:16:**
     - 1-3 words at a time, two lines at most;
     - kept out of the bottom 35% and top 15% of the frame ([third-party reading](https://www.revid.ai/youtube-shorts-safe-zone)).
  7. **Avoid** glitch, page curl, ripple, cube and kaleidoscope effects.
- **The stream encoder pays for some effects:**
  - Film grain is expensive to encode; Netflix saves bits by synthesising it instead ([IBC](https://ibc.org/content-management/news/netflix-rolls-out-av1-film-grain-synthesis-for-classic-movies/22018)).
  - Fades are bit-hungry ([patent](https://patents.google.com/patent/US8270483)).
  - Our own test agrees, and shows that motion blur *helps* (section 4).
- **Custom shader transitions work without full Xcode.** The Command Line Tools have no offline Metal compiler, but Core Image can compile Metal source at run time. One permissively licensed source of transitions is gl-transitions (MIT, [licence](https://raw.githubusercontent.com/gl-transitions/gl-transitions/master/LICENSE), [list](https://cdn.jsdelivr.net/npm/gl-transitions@1.67.0/gl-transitions.json)).

### 3.5 References ("show the thing I'm talking about")
- **What "referencing" can mean:**
  - **(a) On-screen:** you name or point at something on the screen and the edit zooms and spotlights it.
  - **(b) Prepared:** you say a keyword and a card or motion graphic made during show prep appears.
- **Don't fetch images live:**
  - the Bing Search APIs were retired on 2025-08-11 ([Microsoft](https://learn.microsoft.com/en-us/bing/search-apis));
  - Unsplash needs an app key and approval ([guidelines](https://help.unsplash.com/api-guidelines/unsplash-api-guidelines)), which breaks the no-sign-up rule;
  - the RealityTalk researchers dropped automatic image search as "random and distracting" in favour of a keyword table ([arXiv 2208.06350](https://ar5iv.arxiv.org/html/2208.06350)).
- **How on-screen referencing works on the Mac alone:**
  1. Vision reads the screen's text and positions (OCR).
  2. The cursor position comes free.
  3. A deterministic matcher, built on Framecast's existing CueMatcher, links your spoken words to a label on screen.
  4. "This" or "here" resolves to where the cursor has been over the last ~1.5 s, the classic "Put-that-there" pattern ([Bolt 1980](https://www.media.mit.edu/speech/papers/1980/bolt_SIGGRAPH80_put-that-there.pdf)).
- **Voice-to-target test** (18 synthetic lines, including traps and speech errors):

  | Approach | Right | Wrong target or false trigger | Missed | Time |
  |---|---|---|---|---|
  | Deterministic matcher | 15 | 1 | 2 | 0.06 ms |
  | On-device Apple model, one step | 12 | 6 | 0 | 0.51 s median |
  | On-device model, "yes/no" first | 14 | 1 | 3 | 0.52 s median |
  | Both must agree | 13 | 0 | 5 | |

  - The matcher and the test lines were written together, so 15 of 18 is optimistic.
  - With the screen image attached, the on-device model got 2 of 6 visual references right ("the blue button"). It should not be used for that.
- **Latency:** the word appears in about 0.6 s, the match takes under 1 ms, and the zoom eases in. The zoom therefore lands about **1.1-1.4 s after the word**, close to RealityTalk's measured 1.47 s.
- **Gestures misfire because people talk with their hands.** Products such as Zoom, Insta360 and OBSBOT use one deliberate gesture that you hold, and keep it off by default ([Zapier](https://zapier.com/blog/zoom-hand-gestures/)).
- **The live brain is too slow to point at things** (it runs every 6 s). It is fine for slow "keep the code pane in view" focus, but only without screen text being sent.

---

## 4. Measured on your Mac

### 4.1 Method
All test programs were built with the Command Line Tools only (`swiftc`). Nothing was installed; the ffmpeg already on the Mac extracted frames. Each harness is listed below.

**Real-compositor harness.** Framecast's own engine sources, compiled outside the repo.
- Inputs: a stand-in 1080p camera frame and a 4K stand-in screen frame (your display is actually 3024x1964).
- Each figure is one **tick**, meaning one pass of the render loop that draws both canvases. It is reported as mean / **p95**, the time 95% of ticks come in under.
- The first 10 ticks were discarded, so first-use compile costs are *not* included.
- This harness's source was later overwritten in the shared scratch folder, so it must be rebuilt and kept in the repo at Gate 0. Its results are in `experiments/live-editor/compositor/results.txt`.

**Isolated Core Image harness.**
- The same rendering settings as Framecast, at 1920x1080, 90 frames per effect.
- Other research jobs were using the graphics chip at the time.
- It reads **3-5x lower** than the real compositor (plain camera: 0.78 ms here against 4.12 ms real). Its numbers are relative costs only.

**Vision harness.**
- 60 timed frames after 5 warm-up frames, taken from one of your own 1080p recordings at 640x360, 1280x720 and 1920x1080, in the same pixel format the camera delivers.
- Run 2 was on a quiet machine.
- Run 1 ran beside other benchmarks and an XProtect scan at about 190% CPU.
- The load test ran face detection plus tracking at 15 times a second, alone, beside a busy thread, and beside a stand-in compositor.
- CPU was measured with getrusage, and graphics-chip use with ioreg once a second.

**Other harnesses:**
- OCR and voice-intent: synthetic app screens and 18 scripted lines;
- encoder: synthetic camera-like footage through the hardware H.264 encoder;
- cursor-read probe.

**Caveats that apply to all of it:**
- Each benchmark ran in isolation: no stream, recorders, speech and Vision all together.
- The tests were 15-60 s long, not an hour. Heat stayed normal, on mains power.
- Neural Engine power couldn't be measured (that needs sudo).
- With 60 samples, p95 is roughly the 57th value, so treat it as indicative.
- Re-timing the same scene gave a p95 of 6.21 ms against 7.20 ms, so differences under about 1 ms are noise.

### 4.2 Results

**A. Rendering: real Framecast compositor, both canvases per tick (mean / p95)**

| What | ms | What it means |
|---|---|---|
| Camera only | 4.12 / 4.52 | Reference |
| Screen + camera | 5.79 / 7.20 | Today's typical show |
| Same, animated per-layer zoom (camera 1.4x, screen 2x) | 5.70 / 6.67 | **Zooming a layer is free** (within noise) |
| Whole-canvas 1.3x zoom | 3.55 / 4.03 | Free. The figure is below the baseline, which is noise |
| Move transition, mid-way | 4.96 / 5.43 | Today's transition |
| Fade, mid-way | 4.68 / 5.20 | |
| Whole-canvas motion blur, radius 20 | 9.06 / 10.4 | Only during fast moves |
| Whip pan (slide + motion blur, radius 60) | 9.52 / 11.5 | Under the 12 ms transition limit, for 0.35 s |
| Zoom + zoom blur | 14.3 / 17.2 | **Not used** |

**B. Effects: isolated harness (reads 3-5x low; relative costs only)**

| What | ms |
|---|---|
| Plain, both canvases (median / p95) | 0.78 / 1.05 |
| Look stack: push + colour grade + vignette + grain | 1.30 / 1.63 |
| Whip pan | 3.33 / 4.67 |
| directionalwarp (a gl-transitions shader) | 4.09 / 4.94 |
| Zoom-through | 5.43 / 6.92 |
| Matte wipe or spotlight, per canvas | 0.53 |
| Push-in with a plain transform / with Lanczos scaling, per canvas | 0.45 / 1.54. Use the plain transform |
| Captions from cached line images, per canvas | 0.48 |
| Custom shader: compile once / render | 284-424 ms cold, about 1.2 ms when cached / 0.34 ms per 1080p frame |

**C. Vision per analysed frame (run 2, quiet machine; p50 = median)**

| Request | p50 at 640x360 / 720p / 1080p | Notes |
|---|---|---|
| Face boxes | 3.11 / 3.42 / 3.85 ms | Found the face in 60 of 60 frames, including the small corner-camera face |
| Upper-body boxes | 2.49 / 2.65 / 3.36 ms | 92-98% found |
| Face + upper body in one call (720p) | 6.1 ms, 4.4 ms of CPU | Run 1, loaded machine |
| Tracker | 0.79 / 1.00 / 1.49 ms | Runs on the CPU. Overlap with the detector's box (IoU, 1 = perfect) 0.77-0.85. Held the face through a Move transition |
| Salient object box | 2.94 / 3.01 / 3.74 ms | Re-finds a traced object |
| Hand pose | 4.26 / 3.43 / 4.86 ms | |
| Person mask (fast) | 1.83 / 2.63 / 4.05 ms | |
| Optical flow | 12-34 ms | Graphics chip only. **Not used** |
| Forced to graphics chip / CPU | 2x / 5-10x slower | **Never force a chip** |

**D. Load test: face detect + track, 15 times a second**

| Condition | Per tick | CPU | Graphics chip |
|---|---|---|---|
| Alone on an idle Mac | 12.23 ms p50 | 18.3% of one core | none |
| Beside a busy thread | 4.93 ms p50 | 9.2% | none |
| Beside a busy thread + a two-canvas compositor | 5.05 ms p50 / 5.44 p95 | 9.5% | 25% → 24%. The compositor did not slow down (3.22 → 2.98 ms) |
| Fuller loop: tracker every frame, face + body 10/s, hand pose 10/s, mask 1/s | 4.9-8.2 ms average | 11.5-22.6% | |

The idle Mac is *slower* because its cores clock down. Budgets are therefore stated in CPU time per analysed frame, which doesn't depend on clock speed.

**E. Reading text and speech**

| What | Result |
|---|---|
| OCR accurate, language correction off | 66.6 ms at 1920x1200 and 95.4 ms at 2560x1600, finding 38 of 38 labels. About 135 ms of CPU per call. 41-52 ms when limited to one region |
| OCR accurate, 2880x1800 app walk-through | 84 ms p50 |
| OCR fast | 16.5-18.3 ms, but it **missed labels** (19 of 38 at 1280x800) |
| Scroll shift detection | 0.7 ms at 540p; 8.3-8.5 ms at 1280x800, finding the exact 60 px shift |
| Speech: a word first appears correctly | 0.6 s median, 0.9 s p90. It settles in about 2 s |

**F. First-use costs.** These are one-time compiles that macOS then caches. They come back after an OS update or a cache purge.

| Call | First use ever | First call in a later process |
|---|---|---|
| OCR accurate | 34.8 s (not checked for network activity) | 135-150 ms |
| Hand pose | 4.0 s | about 51 ms |
| Tracker (1080p) | 358 ms | about 11.5 ms |
| Optical flow | 11.6 s | (not used) |
| Custom shader compile | 284-424 ms | about 1.2 ms |
| Face detection forced onto the graphics chip | 674 ms | (never forced) |
| Core Image's first render of each new effect combination | **unmeasured** (the first frames were discarded) | |

**G. Other measurements**
- **Sharpness.** A 2x zoom of a 3840-wide screen of 1-pixel stripes kept full detail (pixel std-dev 127.5, whether the zoom was applied per layer or to the whole canvas). Shrinking to 1080p first and then zooming gave 0.0. So Core Image zooms from the full-resolution source. This was checked only on an unmasked layer and a 3840-wide source.
- **Cursor read.**
  - `CGEvent(source:nil).location` took 8.7 µs p50, 37.5 µs p99 and 56.8 µs max; its first call took 24 ms.
  - `NSEvent.mouseLocation` had one 15.7 ms spike in 300 samples.
- **Video stingers with transparency.** HEVC-with-alpha decodes at 1.27 ms per frame and ProRes 4444 at 1.56 ms, both keeping transparency. WebM isn't supported, so WebM stingers need converting.
- **Memory.**
  - One screen frame on your display is 23.8 MB as delivered, or 8.9 MB in the compact 420v format.
  - One camera frame is 8.3 MB as delivered, or 3.1 MB in 420v.
- **Camera formats:** 1920x1080, 1760x1328, 1080x1920, 1552x1552, 1328x1760, 1280x720 and 640x480, all at 30 fps, all with Center Stage, which is currently off.

**H. Encoder, synthetic footage, hardware H.264.** PSNR is a picture-quality score; higher is better.
- **Grain costs bits.** At a 4.5 Mbps target, the bits actually used rose from 2.69 Mbps to 3.51 Mbps with grain 0.03, and to 4.56 Mbps (+70%) with grain 0.06.
- **Under a starved 1.5 Mbps, the worst frame of each shot scored:**

  | Shot | Worst-frame PSNR |
  |---|---|
  | Static | 37.1 dB |
  | Sharp slide | 37.1 dB |
  | Dissolve | **34.1 dB** |
  | Scaling Move | 35.3 dB |
  | Blurred whip | 37.7 dB |
  | Zoom-through | 37.6 dB |

- **So:** keep dissolves short, avoid grain on the stream, and prefer blurred moves.

### 4.3 What this means for a live budget
- **The frame budget.** At 30 fps each frame has 33.3 ms, and today's rendering uses about 4-7 ms in the test program.
  - We plan to keep roughly two-thirds of the frame free.
  - The reason: the recorders, two or more hardware encodes, the replay buffer, the guest feed and the preview all run on the same queue right after rendering, and none of them were in these tests.
  - Gate 0 measures the real app first.
- **Zooms and follows are free on the render side,** because they are just a different crop.
- **Analysis happens off the render path.** It runs on the Neural Engine plus a little CPU: about 5-6 ms per analysed frame, about 9-18% of one core, with no change in graphics-chip use.
- **Motion blur and whips are affordable only briefly.** They take about 9-11.5 ms for about 0.35 s, and only when the Mac has headroom.
- **What doesn't fit live:** zoom blur, optical flow, and per-frame accurate OCR.
- **At 50 or 60 fps the budget halves to 16.7 ms.** Today's screen + camera p95 (7.2 ms) is already 43% of that, so at those rates only the free crop-based moves are offered.
- **First-use compiles must happen before you go live, never during.**

---

## 5. The plan

### 5.1 Architecture
```
 CAPTURE (exists)              SIGNALS (new; each with its own small lock, never the render lock)
 camera --+                    Vision worker (Neural Engine + CPU, background queue):
 screen --+--> newest-frame -->   face + upper body 10/s, tracker 15/s, salient box for Trace
 guests --+    slots              -> subject boxes
               screen stream -->  screen signals: changed areas, window position, scale, "settled"
               120 Hz sampler ->  cursor; click ring; app switches; secure-input flag
               (v11.5) OCR on a settled, downscaled copy -> text boxes (never leave the Mac)

 DECIDERS                                          WHO WINS (highest first)
 you: hot keys, Trace, panel ...................... 1
 reset / pause / undo ............................. 2
 reference hit (v11.5) ............................ 3
 live brain, ~6 s: look, move, focus INTENT only .. 4
 click / screen activity .......................... 5
 subject follow ................................... 6
 camera life (slow push) .......................... 7
 wide ............................................. 8

 RENDER LOOP (every frame, both canvases, one clock)
 FocusController: choose target -> smooth (1-euro) -> spring -> sharpness rule
   layout -> per-layer framing (crop/zoom/pan) -> canvas camera (push/punch)
          -> finishing (grade, vignette) -> overlays, lower thirds, chat (never move)
   -> one picture per canvas -> stream, both recordings, replay buffer, guest feed, preview
   -> (optional, v11.1) clean 16:9 copy without moves

 BUDGET GOVERNOR (once a second): frame time, missed frames, capture drops, heat, battery,
 Low Power Mode -> tier T0..T3 -> analysis rates and effects step down, never jump
```

### 5.2 Who decides what
| Layer | How often | Decides | Never |
|---|---|---|---|
| Frame (FocusController) | every frame | the exact view, springs, blur | asks a model |
| Beat (on the Mac) | 0.5-1.5 s | punch-ins, reference zoom and spotlight, captions | changes the look |
| Segment (live brain, your key) | about 6 s | look, transition style, focus *intent* | sends or receives coordinates or per-frame moves |
| Prep (Claude over the local control link) | before the show | camera style and transition per rundown part, reference table, stinger | runs live |
| You | any time | everything; you override all of the above | |

### 5.3 Ground rules (every phase)
1. **The render path stays light.** Inside the render lock the new code only copies small snapshots, steps springs (microseconds) and builds Core Image graphs.
   - It never runs Vision, compiles anything, touches files, waits on the main thread, or takes another subsystem's lock.
   - Producers never take the render lock.
2. **Apple frameworks only through v11.5.** No installs, no third-party models, no Apple model downloads.
3. **Failures ease back.** Every failure eases the shot back to today's framing over 1 s.
4. **Nothing new leaves the Mac, and no new permissions.**
5. **Rehearse before air.** Every automatic behaviour moves through a fixed ladder:
   - **Off.**
   - **Shadow:** it decides and logs; the picture doesn't move.
   - **Rehearse:** moves show only while you're not live, in your preview and in a local test recording.
   - **On air.**

   A behaviour reaches On air only after its replay score passes. Behaviours where a one-key suggestion makes sense (brain focus, references) also get a **Suggest** step. The live picture shows chips you can accept with one key.
6. **Measured in the real app.** Gate 0 records the app's own baseline, and every phase passes the same 60-minute soak test (section 5.8).
7. **Budgets are absolute ceilings or changes of at least 1 ms.** Smaller differences are noise.

**Frame ceilings at 30 fps (per tick, both canvases).** If Gate 0 shows that the app's own baseline is already near these, they will be reset from it, and I'll bring that to you.

| Measure | Ceiling |
|---|---|
| Steady frames, p95 | 9 ms or less, and no more than 1 ms above baseline per phase |
| During a transition (0.7 s or less), p95 | 12 ms or less |
| Worst tick during a transition | 20 ms or less |
| p99 overall | 14 ms or less |

### 5.4 Sharpness rule (one limit on the combined zoom)
- **The rule.** No source is ever shown enlarged more than **1.25x**, meaning at least 0.8 source pixels per output pixel.
- **It applies to the product of every zoom.** Layer framing × slow push × punch-in together. When the product would break the limit, the lower-priority moves give way first.
- **Where the source is already enlarged more than that today,** the shot may pan but not zoom further.
- **The limit is worked out from the pixels actually delivered.** That means the live scale and content size of the capture, not a fixed number. So a small corner tile can zoom onto your face, while the full-screen 9:16 camera can only pan.

| Case on your Mac | Today's view | Allowed |
|---|---|---|
| Built-in display (3024x1964) on 16:9 | whole screen at 0.55 scale | up to about 2.27x; Lively stops at 2.0x, which is 1.1x enlarged |
| Same display on 9:16 | thin 1080x701 strip (0.357) | **Overview** (today's strip) → **Follow** (a full-height slice about a third of the screen wide, 0.98 scale) → up to about 1.28x more on a click |
| A 4K external display on 16:9 | 0.5 scale | 2.0x is pixel-for-pixel |
| A 1x 1920x1080 display on 16:9 | 1.0 | 1.25x |
| Camera, full frame, 16:9 | 1.0 | 1.2x (Moderate), 1.25x at most |
| Camera, full frame, 9:16 | already 1.78x enlarged | **pan only** |
| Camera in a small tile | well under 1.0 | zooms toward the face within the rule |

### 5.5 How the camera moves
**Springs.**
- Critically damped, meaning no overshoot.
- Stepped in fixed 1/120 s steps up to each canvas's *scheduled* frame time, with the leftover fraction interpolated. Motion therefore doesn't depend on timer jitter, and every output gets identical motion.
- Speed carries into a new target, so a retarget never jerks.

**Screens: the two-layer camera** (values from Screenize, ideas only):
- **Region and zoom:** 0.6-0.8 s, no overshoot.
- **Pan:**
  - safe zone 75% of the view;
  - the camera corrects 45% of the way;
  - hysteresis 0.15;
  - response 0.2-0.5 s;
  - damping 0.9.
- At least 2.5 s between zoom levels.
- The target fills about 70% of the frame, with 0.08 padding.

**Camera follow:**
- a 1€ filter on box centre and size (start with β = 0);
- a dead zone over the middle 60% of the frame;
- reframes of about 1 s;
- a cap on zoom speed, a minimum hold of 2.5 s, and rule-of-thirds headroom.

**Limits:**
- Zoom never below the canvas's reference view, and the view always stays inside the source, so there are no black edges.
- No retarget while a transition runs, or within 1.5 s of a look switch.
- When a scene switch drops a source, that shot returns to wide.

**Canvases.** 16:9 and 9:16 get independent shots from the same detections. 9:16 follows more tightly from side to side.

### 5.6 Who wins
Each layer has its own shot, so click zoom on the screen and face follow on the camera run side by side. When two requests want the same shot, the order in 5.1 decides.

### 5.7 Budget governor

**What it measures:**
- **The whole tick,** from its start until the outputs have been fed. Today's `renderMs` misses the scene previews and the outputs.
- **How long the render lock is held.**
- **Missed recording frames.** The recorder sees a gap in frame numbers. This is the true "dropped frame"; today's late-frame counter misses ticks up to two intervals late.
- **Camera and screen-capture drops.** New counters.
- **Heat, power source and Low Power Mode.**

**How it judges.**
- **Steady frames and transition frames are judged separately.** Transition frames are left out of the steady figure, which uses a 20 s window. A transition is checked against its own limit (p95 of 12 ms or less, worst tick 20 ms or less).
- **A transition style that breaks its limit twice in one show** is swapped for Morph for the rest of the show and logged. The tier does not change. That stops whips switching themselves off.
- **Thresholds start from the Gate 0 baseline B,** measured in the app at your frame rate, never lower than the floors shown.

| Tier | Enter when (any one) | Analysis | Picture extras |
|---|---|---|---|
| **T0 Full** | default on mains power | camera detect 10/s + track 15/s; guests 1/s; OCR at most once per 2 s | everything the phase ships |
| **T1 Eco** | steady p95 above the larger of B + 3 ms and 30% of the frame interval (10 ms at 30 fps); heat "fair" for more than 2 min; on battery; Low Power Mode | detect 2/s, track 10/s; guests 0.5/s; OCR at most once per 5 s; no on-device model | no motion blur; signature transitions become Morph; scene previews at 10 fps |
| **T2 Minimal** | steady p95 above the larger of B + 5 ms and 40% (13.3 ms); 2 or more missed recording frames in 10 s; heat "serious" | detect 1/s, no tracker, wider dead zone, slower spring; OCR off | Morph or cut only; colour-grade-only finishing; scene previews at 2 fps; brain focus vetoed |
| **T3 Off** | steady p95 above 50% of the interval (16.7 ms) for 5 s; heat "critical"; an analysis error | stopped | the shot eases to today's framing over 1 s; transitions as today |

**Recovery.**
- Up one tier after 60 s healthy: under the T1 line, no missed frames, heat "fair" or better.
- Leaving T3 needs you to re-enable it, or 5 healthy minutes.

**Every tier change** eases in, is logged, and shows in the HUD.

**At 50 or 60 fps** only the **Light** profile runs: crop-based zoom and follow, Morph and cut only, no blur, no signature transitions, no finishing extras. Its thresholds come from a separate Gate 0 baseline at that frame rate.

### 5.8 How every phase is tested
**Harness** (built in v11.0, extended every phase):
- **`fcctl` commands:** `focus:click x y`, `focus:target …`, `focus:punch`, `focus:dump` and `moves:` setters.
- **A per-frame trace behind a debug flag:** time, canvas, source, centre, zoom, speed, reason, tick ms, tier.
- **The real-compositor benchmark goes into the repo** (for example under `experiments/`). It runs interleaved A/B/A/B for 1000 or more ticks after a fixed warm-up, and reports confidence intervals.
- **An offline brain stand-in** replays recorded brain decisions from a file, selected by a test flag. It makes no network calls and costs nothing. It is the only brain allowed in soaks and in the v11.0-v11.2 acceptance runs.
- **Rehearsal replay.** An opt-in "edit signals" file (section 6) is replayed through the existing media-file source, so each phase can be scored offline.

**60-minute soak, run for every phase.**

*Setup:*
- both canvases at 30 fps, your Retina screen plus the camera;
- both shapes recording, replay buffer on, speech on, brain on the offline stand-in;
- streaming to a local test receiver using the ffmpeg already installed: `ffmpeg -listen 1 -i rtmp://127.0.0.1:1935/live/test -f null -`. `lsof` confirms it listens on 127.0.0.1 only. Nothing new is installed.

*Logged locally:*
- whole-tick p50/p95/p99/max per minute, and render-lock hold time;
- missed recording frames, and camera and screen-capture drops;
- analysis time and CPU time;
- process CPU, and graphics-chip use (logged, not a pass/fail gate, because ioreg samples too coarsely);
- heat changes, memory footprint, and memory right after Prepare;
- time spent in each tier;
- speech partial latency;
- how quickly click and hot-key events reach the main thread (p99).

*Pass when:*
- missed recording frames and capture drops are at or below Gate 0;
- p99 is 14 ms or less;
- each recording has exactly fps × duration frames, with audio/video drift of 1 frame or less;
- memory drifts 50 MB or less after warm-up;
- memory after Prepare stays within a budget set at Gate 0;
- heat never reaches "serious" on mains power at default settings;
- speech latency p90 stays within baseline + 0.2 s;
- CPU stays within the phase budget.

### 5.9 Where it goes in the code
Names marked NEW are proposed.

**Analysis tap.**
- An optional observer on `FrameSlot.put` (VideoSource.swift:47-49) covers camera, screen and guests in one hook.
- NEW `Sources/FramecastEngine/LiveEditor/AnalysisTap.swift` and `VisionWorker.swift`.

**Screen signals.**
- Read the frame attachments in the ScreenCaptureKit handler (CaptureSources.swift:351-358), and keep the capture geometry from `begin()` (:268-298).
- NEW `LiveEditor/ScreenSignals.swift` and `Sources/Framecast/LiveEditor/PointerMonitor.swift`.

**Controller.** NEW `LiveEditor/FocusController.swift`, `Spring.swift` and `OneEuro.swift`, all written in-house.

**Per-layer framing.**
- An optional `framing` on `LayerInput` (Compositor.swift:14-22), filled in `Engine.layerInput` (Engine.swift:324-333) from a store keyed by (source, canvas).
- Applied in `renderItem` after the user crop and before the mirror (Compositor.swift:55-65). It replaces the centred placement (:77-78), and masks stay round because they are applied after scaling (:84-90).

**Canvas camera.** In `Engine.composite`, between the layout (:340-346) and the overlays and chat (:347-368).

**Transitions.**
- `TransitionKind` and its switch (Compositor.swift:8-11, 131-183), with Morph 2.0 replacing the `.move` case (:156-181).
- The retarget fix in `setProgram` (Engine.swift:266-277).
- NEW `Compositor/KernelLibrary.swift`.

**Governor.** NEW `FramecastEngine/BudgetGovernor.swift`. It sets the unused `thermalSerious` flag (Engine.swift:24) and feeds the HUD through the Studio 15 Hz poll (Studio.swift:756-792).

**Director glue:**
- LiveBrain.swift (:6-14, :54-119, :184-244);
- BrainDirector.swift (:113-210, replay :233-298);
- ShowDirector.swift (:18, :50-53, :230-242, log :447);
- ControlLink.swift (:292-457);
- App.swift (hot keys :165-204, TestControl :291-300);
- ShowListener.swift (:34-35);
- CueMatcher.swift (:102-108);
- AudioMixer.swift (:131, :262).

**Settings.**
- Only optional fields: `SceneItem.framing`, `AppSettings.liveEditor`, focus fields on `DirectorSettings`, and a separate optional `transitionStyle`.
- An enum value an older build doesn't know silently resets the whole settings blob (Settings.swift:102-103). That is why the legacy `transition` keeps only values older builds understand.

---

### 5.10 v11.0: Safety rails and screen auto-zoom (no AI)

**What viewers see.**
- You click on your shared screen and the 16:9 view glides in (about 1.6x) toward the click, settling within about 0.9 s. It follows your cursor without twitching, and returns to the whole screen after 5 s with no activity.
- On 9:16 the screen leaves its thin strip, fills the frame as a full-height slice that follows your cursor, and tightens a little on a click.

**How it works.**
- **Gate 0.** An in-app benchmark scenario through `fcctl`, with camera, screen capture, both encoders, speech and the replay buffer running, then a 60-minute baseline soak of the current build. It also records first-frame render times for every effect combination in your scenes.
- **Governor and a "Live editor" HUD** in the Private panel: tick p50/p95, missed frames, heat and tier.
- **The framing seam,** the sharpness rule and fixed-step springs.
- **Pointer signals:**
  - a 120 Hz sampler reads the cursor *outside* the render lock, after a warm-up read;
  - a global click monitor, plus a local monitor whose clicks count only when Framecast's own windows are part of the capture;
  - a fallback that checks `CGEventSourceSecondsSinceLastEventType` on each tick, instead of polling the pressed buttons, which misses short clicks;
  - app-switch notifications.
  - Click timing uses each event's own timestamp; back-dating is limited to 1 frame.
- **Where clicks count.** Every click and cursor position is checked against the window list before it can become a target. It is ignored when it lands:
  - outside the captured display or window;
  - on Framecast's own windows (including the Private panel and prompter);
  - on the Dock, the menu bar, Notification Center or an app on the never-zoom list.

  While the cursor is over an ignored area, panning freezes.
- **Intents:**

  | Intent | Zoom | Status in v11.0 |
  |---|---|---|
  | Click | 1.6x (range 1.5-2.0) | live after rehearsal |
  | Navigating (2 or more clicks within 2 s, within 0.5 of the screen apart) | 1.5x | live after rehearsal |
  | Idle for 5 s (3-5 s, you choose), or an app switch | back to the whole screen | live after rehearsal |
  | Typing, read from screen-change areas | 1.8x | **shadow only** |
  | Scrolling, read from screen-change areas | 1.3x | **shadow only** |

  Typing counts only when small, text-line-sized changes move forward along a line or down a page, after removing the cursor's own area. Steady blinks (the caret, clocks) and large areas that change every frame (video) are ignored. Typing holds for at most 8 s without cursor movement.
- **Mapping the cursor to capture pixels.**
  - For display and app captures: global point → display-local → × pixel scale → × the 3840-px cap factor → flipped and normalised.
  - For window captures: the window position reported with each frame, so moving the window keeps working.
  - If a mapping can't be worked out, that source drops to manual only and says so.
- **Privacy guards:**
  - no zoom, and an ease back to wide, while macOS secure input is on (password fields, Terminal's Secure Keyboard Entry), checked with the Carbon call `IsSecureEventInputEnabled`, which needs no permission;
  - a pre-filled never-zoom list;
  - the view is kept off any never-zoom window; if no view can avoid it, no zoom;
  - optional hiding of password managers and Keychain Access from screen capture altogether (D4);
  - a Go Live reminder to turn on Do Not Disturb.
- **Click rings** (macOS 15+) are optional. The cursor stays drawn into the capture: Apple marks `currentSystemCursor` as to-be-deprecated and says it "will always be nil in a future version of macOS".

**Budget.**
- Steady p95 within 1 ms of the Gate 0 baseline and under 9 ms.
- Reading screen-capture attachments: 0.05 ms or less per frame.
- Cursor copy inside the lock: microseconds (the read itself measured 8.7 µs p50, and it happens outside the lock).

**Controls.**
- **Camera moves:** Off (default) / Rehearse / On. A "Camera moves: ON" indicator shows in the Private panel and on the Go Live sheet.
- **Intensity:** Subtle / Moderate (default) / Lively.
- **Also:** idle-return seconds, the never-zoom list, "hide password managers from capture", click rings, HUD, and Performance (Auto / Eco / Full; Eco on battery).
- **Hot keys** (Carbon, no Accessibility needed):
  - ⌃⌥⌘Z: zoom to cursor;
  - ⌃⌥⌘X: reset and pause camera moves for 30 s;
  - ⌃⌥⌘C: camera moves on or off (⌃⌥⌘M is already Mute).
  - Registration is checked, and a warning appears if a key couldn't be claimed (today the result is ignored).

**Acceptance test.**
1. Gate 0 baseline recorded. The benchmark harness and the offline brain stand-in are in the repo.
2. The cursor maps to capture pixels within 2 px at 9 grid points, on:
   - the built-in 3024x1964 display;
   - a scaled or external display if one is available;
   - a window capture after the window moves 300 pt.
3. A 10-minute scripted tour with 60 clicks: steady p95 within baseline + 1 ms and under 9 ms; missed recording frames at baseline.
4. Click zooms:
   - the zoom starts within 2 frames of the click's timestamp;
   - it settles within 2% of its target in 0.9 s or less;
   - the click point is inside the final view 100% of the time;
   - the cursor stays inside the safe zone in at least 97% of zoomed frames.
5. Zero black-edge frames and zero out-of-bounds views in sampled recordings.
6. Sharpness:
   - the combined zoom never exceeds 1.25x enlargement in any logged frame;
   - a 1-pixel stripe pattern on the real 3024-px capture keeps std-dev of 120 or more at the cap.
7. Idle and shadow cases:
   - Cursor still for 10 s: the view drifts 0 px.
   - Back at the overview within 1 s of the idle timer.
   - Three cases each return to idle on time in the shadow log, with no stuck zoom: a caret blinking in an empty field for 30 s, a video playing beside the click, and a menu-bar clock showing seconds.
8. Both canvases start the zoom on the same frame. A spring unit test gives identical output with 0-4 ms of random timer jitter.
9. Governor:
   - an injected 12 ms delay on steady frames enters T1 within 5 s, and 14 ms enters T2;
   - moves ease out with no jump and recover after 60 s healthy;
   - a simulated 0.35 s whip at 12 ms per tick does *not* change the tier.
10. On a test build never granted Accessibility or Input Monitoring, clicks are detected with no permission prompt, through the global monitor or the fallback.
11. Privacy:
    - zoom stays at 1.0 while secure input is on;
    - a click next to an open Messages window never puts that window in view;
    - clicks on the Framecast toolbar, on a second display and on a notification banner cause no move.
12. A fresh install and an upgrade both start with Camera moves Off. Rehearse moves the picture only while you're not live.
13. The 60-minute soak passes.

**Effort:** 11-14 engineer-days (estimate), including 1 day of tuning against real recordings.

---

**Built, 22 October 2026: what v11.0 changed from this plan.** User guide: [LIVE-EDITOR.md](LIVE-EDITOR.md).

1. **Frame-time lines.**
   - Gate 0 in the real app measured a normal frame at 10-17 ms (p95). The isolated benchmark had measured 6-7 ms: other apps share the graphics chip, which was 40-60 % busy.
   - The fixed 9 / 10 / 13.3 / 16.7 ms lines above would have put an idle studio into T3. So the governor now learns this Mac's normal frame time B 15-45 s after launch, and again whenever a recording, stream or replay buffer starts or stops.
   - The lines are B+5 (T1), B+8 (T2) and B+12 (T3, held for 5 s), and never below half, two thirds and four fifths of the frame. The hour-long runs showed frame time swinging 12-17 ms minute to minute, so the first try (B+3 / B+5 / B+8) flapped between T0 and T2.
   - It takes 4 missed recording frames within 10 s to step down. One slow frame costs a slot in each recording.
   - After the governor is reset it judges only new frames.
2. **Typing and scrolling (shadow) were dropped.** macOS merges the changed areas of several windows into one large rectangle, so typing can't be read from them. The proper route is the opt-in Accessibility caret (v11.6).
3. **Sharpness.** On the real 3024-px capture, 1-pixel stripes keep full detail at 1:1 (127.5) but drop to 72 at the 1.25x limit. Moderate (1.6x) stays under 1:1 on this display. Whether to lower the limit to 1.0 is a decision for the user.
4. **Click filter.** Third-party overlay windows above the menu-bar level (a dictation app's full-height layer-1000 overlay, for example) are looked through. Only the menu bar, status items and Apple's own interface block a zoom.
5. **Review fixes.** An adversarial review found 18 issues, all fixed. The main ones:
   - 9:16 returns to the strip during a password field and the reset pause.
   - No drawn frame shows a never-zoom window magnified (new shots, holds, glides).
   - Password-field state survives a long session.
   - A password manager opened later is hidden.
   - No phantom zoom when moves are switched on.
   - Window geometry is looked up off the render path.
   - Resized windows are re-captured at their new size.
6. **Tests.**
   - `fcverify live-editor`: 55 checks.
   - On the real screen (`experiments/live-editor/acceptance/`):
     - mapping 0 px at 9 display points and in a window capture before and after a move;
     - zoom starts ≤ 39 ms after a click and settles in 0.6 s;
     - back to the whole screen 0.63 s after the quiet spell;
     - cursor in the middle 75 % in 99.7 % of zoomed frames;
     - both canvases start on the same frame;
     - every privacy rule and governor tier.
   - Soak, moves Off (54 min, build before the review fixes): 0 missed, late or dropped frames; both recordings exactly fps × duration; memory steady.
   - Soak, moves On (60 min, final build except the governor lines): no dropped stream or encoder frames and memory steady. The only losses were 30 frame slots per recording, mostly from one 169 ms stall early on.
   - Side by side, 15 min each on the final build: Off missed 2 slots (one 64 ms stall); On (48 zooms) missed none, slowest frame 37 ms. Camera moves add no measurable cost beyond run-to-run swing.

### 5.11 v11.1: Auto framing and trace the object (built-in Vision)

**What viewers see.**
- You stay framed when you lean or shift. On 9:16 the crop slides with you instead of cutting you off.
- The circle or corner camera stays on your face and zooms in gently when the tile is small enough to stay sharp.
- A product you trace is followed as it moves. If it is lost, the shot glides wide.

**How it works.**
- **Analysis tap:**
  - only sources that are on air are analysed;
  - a quick "due and idle" check runs first;
  - at most one frame is in flight, and frames are dropped when the worker is busy.
- **Vision worker:**
  - face + upper body in one call at 10/s (6.1 ms measured at 720p);
  - the tracker at 15/s on the native frame (1.49 ms at 1080p), which avoids a per-frame downscale that was never measured;
  - re-anchored from the detector every 0.5-1 s, or when overlap drops below 0.3;
  - on macOS 27, Apple's newer face path (`#available`); the classic API from macOS 14;
  - the queue priority (utility or user-initiated) is chosen from a measurement of both.
- **Free detector probe.** If the camera itself offers face boxes (`AVCaptureMetadataOutput`), Vision detection drops to 1/s, used only for checking. Those boxes are top-left based and need converting.
- **Framing:**
  - the face box is expanded and joined with the upper body, with the eye line on the upper third;
  - 9:16 full camera pans only;
  - 16:9 zooms to 1.2x at most;
  - circle and square tiles stay face-centred;
  - all within the sharpness rule.
- **Fallbacks:**
  - no face for 1.5 s: use the upper body;
  - nothing for 3 s: ease to wide over 1 s;
  - analysis more than 500 ms late: hold;
  - two faces for more than 2 s: widen to include both.
- **Trace the object:**
  - arm it with ⌃⌥⌘O or the toolbar; a crosshair appears with "Esc to cancel";
  - while armed, the layer editor's drag-to-move is switched off;
  - one box seeds the tracker, then Trace disarms (or after 5 s);
  - when confidence drops, the salient-object box re-finds the object (3-4 ms);
  - if it stays lost for more than 1 s, the shot glides wide.
- **Center Stage:**
  - a picker offers "Framecast Auto framing / Apple Center Stage / Off";
  - if Center Stage is active, our follow switches off for that camera, with a banner;
  - Framecast records your Center Stage setting, restores it when the camera stops or the app quits, and treats a Control Center change as a manual override;
  - changes happen only when you're not live, or after a confirmation that warns of a short camera interruption;
  - the frame rate is watched, since Center Stage limits it to 15-30 fps.
- **Guests:** face-centred framing at 1/s, no tracker, up to 4 guests.
- **Global limit on Vision requests:** at most 30 / 15 / 5 per second at T0 / T1 / T2.
- **"Prepare live editor"** runs in the background **at app launch**, never at Go Live and never while live. It:
  - warms every Vision request;
  - renders one frame of every effect combination in your current scenes into a scratch buffer;
  - times each step.

  Any step over 1 s is logged as a one-time "cold compile", usually after a macOS update. Features whose preparation hasn't finished stay off, showing "first-time preparation".
- **Camera format test.** 1760x1328 against 1920x1080 for 9:16 sharpness, run off air.
- **Clean 16:9 recording option** (default off). One extra 16:9 render with no moves plus one more hardware encode. Its cost is measured at Gate 0 (estimate +2-4 ms per tick).
- **Coordinate tests:**
  - Vision bottom-left boxes to the post-crop view;
  - camera-metadata top-left boxes;
  - mirroring after the crop.

**Budget.**
- Render within 1 ms of v11.0.
- Analysis: 10 ms or less p95 per analysed frame.
- Camera analysis CPU target: 200 CPU-ms per second or less on average, which is 20% of one core and about 1.3% of the whole CPU.
  - Estimate from measured per-call CPU: 4.4 ms × 10 + about 3.3 ms × 15 ≈ 94 CPU-ms/s.
  - Measured range for this mix: 9.2-18.3% of one core.
  - The final ceiling is set from the in-app soak. If it is exceeded, upper body drops to 5/s.
- Camera and screen-capture drops stay at baseline. If a frame is held longer than 10 ms, a small copy is analysed instead.

**Controls.**
- Per camera: Framecast Auto framing / Apple Center Stage / Off.
- Per layer: off / follow cursor and clicks / follow face / trace / manual rectangle, with strength and maximum zoom. The sharpness limit is shown beside it.
- Higher camera format (off air only), the clean recording toggle, "Save edit signals for tuning" (per recording, off by default), and the Trace hot key.

**Acceptance test.**
1. On two local rehearsal clips (one including a Move transition, one with heavy gesturing) plus one live session:
   - the face centre stays inside the middle 60% in at least 95% of frames;
   - the face box is fully in view in at least 99%;
   - overshoot is 2% of the frame width or less;
   - 6 or fewer reframes a minute while seated;
   - the combined zoom never goes over 1.25x.
2. Seated still for 60 s: the view moves 0.3% of the frame width or less, with 0 reframes.
3. Tracker against detector: mean overlap of 0.75 or more, never lost for more than 0.5 s.
4. A traced moving object keeps overlap of 0.5 or more for at least 10 s. After it is covered, it is recovered within 1 s, or the shot glides wide.
5. Camera covered for 5 s: wide within 4 s with no black edges. Uncovered: the face is found again within 1 s.
6. A mirrored camera follows in the right direction. A circle mask stays round at maximum zoom.
7. Center Stage:
   - with Center Stage on, our follow switches off every time;
   - your original setting is restored on quit;
   - no Center Stage or format change happens while live without the confirmation.
8. Load:
   - analysis CPU within budget;
   - 1% or fewer frames dropped by the worker;
   - render within 1 ms of v11.0;
   - capture drops at baseline;
   - no warm-up runs while live.
9. The clean recording, when on, contains no moves and passes the frame-count and sync checks.
10. The 60-minute soak passes. 30 minutes on battery in Eco also passes, with the battery drop recorded.

**Effort:** 10-12 engineer-days (estimate).

---

### 5.12 v11.2: Morph 2.0 and camera life

**What viewers see.**
- Layout changes glide with weight instead of slide-and-pop.
- Crops reshape smoothly, and layers arrive a beat apart.
- Still shots slowly breathe in. A held key punches in.
- Switching in the middle of a transition never jumps.

**How it works.**
- **Morph 2.0** replaces Move's internals:
  - a separate ease for each property (ease-out or a spring for position and size; opacity on its own curve);
  - crops and framing animate, which fixes the current jump;
  - layers are staggered 30-60 ms apart;
  - arriving layers grow from 0.94 to 1 while fading in, and leaving layers fade faster (about 195 ms);
  - an optional curved path (off by default);
  - 700 ms by default (0.5-0.8 s usable).
- **Switching mid-transition:**
  - **Morph** starts from what is actually on screen.
  - **Fade, slide, wipe, whip and stingers** are blends of two whole scenes, so they can't be expressed that way. A new switch either lets the current one finish, or turns into a cut or a short Morph. Each kind has a test.
- **Motion blur:**
  - only on fast frames, above about 25 px per frame (tuned by eye);
  - blur length is half the pixels moved per frame, radius capped at 20;
  - T0 and 30 fps only;
  - speed comes from the Morph maths or the spring.
- **Camera life:**
  - **Slow push:** 2% / 4% / 6% over 8-20 s on full-frame shots, absorbed into the next look change.
  - **Punch-in:**
    - hold ⌃⌥⌘I: 1.0 to 1.12 in about 200 ms;
    - held while the key is down, up to 3 s, then released over 0.6 s;
    - needs the new key-release event, which today's hot-key handler doesn't register;
    - anchored on the face or the cursor.
  - **Where camera life is blocked:**
    - no canvas push in screen + corner-camera looks, because it would zoom the corner tile too; a punch-in goes to the screen layer there;
    - no push or punch on the full-frame 9:16 camera (sharpness rule).
- **Prepare** extends to every new transition combination.

**Budget.**
- Morph 2.0 transition window p95 of 12 ms or less (bench target 8.5 ms or less).
- Steady p95 with follow and push within 1 ms of v11.1.
- Blur only on fast frames.

**Controls.**
- Transition picker with Morph 2.0 as the new default, and duration 100-2000 ms.
- Motion blur Off / Auto.
- Slow push and punch-ins by intensity.
- Punch-in hot key.

**Acceptance test.**
1. Ten switches made at 30-60% of the way through a transition:
   - no frame moves more than twice the previous frame's move plus 2 px;
   - no layer moves more than 2% of the canvas width in one frame.
   - The same test runs for each transition kind with its own rule.
2. Two scenes that differ only in crop: the crop changes smoothly and in one direction, and no step is larger than 5%.
3. Punch-in:
   - it starts within 1 frame of the key;
   - it reaches 1.12 in 250 ms ± 1 frame;
   - overlays and chat move 0 px;
   - the combined zoom never breaks the sharpness rule.
4. The push is 6% or less over at least 8 s, with no single-frame zoom step at a look change.
5. On a real rehearsal at your stream bitrate, the worst-frame PSNR during Morph 2.0 is no more than 0.5 dB below today's Move.
6. Settings and collections from `v4-baseline` and older load without a reset, and a v11.1 build reads v11.2 settings without a reset.
7. After Prepare, the worst tick on the first use of each transition is 20 ms or less.
8. A 60-minute soak with a look switch every 20-30 s passes.

**Effort:** 6-8 engineer-days (estimate).


---

### 5.13 v11.3: The AI director directs the camera

**What viewers see.** The edit follows the content:
- wide for intros;
- pushed in on you for stories;
- on the screen while code is discussed;
- a punch-in on the key line;
- emphasis on whoever is talking.

**How it works.**
- **Word timing.** Speech recognition starts reporting word times and confidence (`.audioTimeRange`, `.transcriptionConfidence`).
- **Speech punch-ins:**
  - triggered by a sentence starting after a pause, an outline or reference keyword, or a jump in voice level;
  - 1.10-1.15x, released after 1.5-3 s;
  - at most 3 a minute, and at least 20 s apart;
  - never in asset looks, during transitions, within 1.5 s of a switch, or during back-and-forth conversation;
  - they land about 0.6-0.9 s after the word.
- **Brain schema.** Three new fields, required with "" allowed, as strict schemas demand:
  - `focus`: wide / presenter / pointer / text / speaker / object;
  - `focus_text`;
  - `move`: cut / morph / push / punch / signature / reset.

  The targets are explained in the cached system prompt. The user message carries only abstract flags, such as "screen on air, cursor active, face visible", so the prompt cache stays stable.
- **Focus guards:**
  - confidence of 0.6 or more;
  - the target must exist on the Mac right now, otherwise hold and log "not visible";
  - hold at least 4 s;
  - at most 8 focus changes a minute, separate from the 6 looks a minute;
  - nothing within 1.5 s of a look switch or during a transition;
  - a 30 s pause after a manual change;
  - pointer or presenter answers older than 3-4 s are dropped (looks still accept 8 s);
  - requests expire after 6 s;
  - signature transitions at most once per 90 s, and only on a topic change;
  - vetoed at T2 and above.
- **Undo, scoped:**
  - **⌃⌥⌘U** reverts *director decisions only:* brain looks, brain focus and, later, reference zooms. It keeps a separate slot for focus, so it never overwrites a look's undo.
  - **The reset/pause key (⌃⌥⌘X)** cancels local moves: click zoom, follow, camera life and punch-ins.
  - The Private panel shows "Undo will revert: …" and a countdown for any pause.
- **Control-link (MCP) tools:**
  - `set_focus`, `punch_in`, `set_camera_moves`;
  - `get_show_state.focus/moves/tier`, which returns only an allowlist of abstract words (wide, presenter, pointer, text, speaker, object, tier, intensity), never screen text, coordinates or reason strings.

  All of them go through the same guards.
- **Per-look move profiles,** and per-show limits in the director settings.
- **Speaker emphasis in guest grids,** from audio levels: a 1.5 s sustained lead to switch, and a hold of at least 4 s.
- **Brain replay scoring** for focus and move decisions.

**Budget.**
- No new render cost.
- An estimated few dozen extra tokens per brain call.
- Guards take microseconds.

**Controls.**
- Brain focus: off / suggest / auto, per show.
- Focus hold, focus changes per minute, punch-ins per minute.
- A move profile per look:

  | Look | Camera behaviour |
  |---|---|
  | Talking head | auto framing + slow push; punch-ins allowed |
  | Screen focus | auto zoom; no canvas push |
  | Screen + corner camera | auto zoom on the screen layer; face-centred corner tile; no canvas push |
  | Asset looks | the asset layer is locked: no zoom, no blur. Camera tile keeps following. Camera life paused |
  | Guest grid | face-centred tiles; speaker emphasis |

**Acceptance test.**
1. Offline replay (stand-in brain) of 2-3 rehearsals:
   - 0 guard violations;
   - focus changes at most 8 a minute and looks at most 6 a minute, counted separately;
   - none during transitions or within 1.5 s of a look change;
   - 100% of stale pointer or presenter answers dropped.
2. Punch-ins: at most 3 a minute, each 1.10-1.15x, none in asset looks. A human reviewer flags at most 1 bad punch-in per 10 minutes.
3. Undo:
   - ⌃⌥⌘U after an automatic look and an automatic focus reverts the focus first, then the look;
   - it never reverts a click zoom;
   - the reset key cancels local moves within 1 frame plus the spring.
4. Speaker emphasis starts within 1 s of a sustained onset, with no ping-pong on coughs.
5. Egress tests:
   - brain requests carry only speech plus abstract flags;
   - every MCP tool result passes the allowlist check.
6. **Real-brain runs, only after your yes (D5):**
   - strict-schema check on both providers (an estimated 10 or fewer calls each);
   - one replay on your usual provider (up to about 600 calls per rehearsal hour);
   - a 60-minute live soak in auto (up to about 600 calls).

   The app's own cost meter shows the spend. The code's own comment on the replay tool describes it as costing "a few cents". These runs check that the prompt cache hit rate is unchanged, that the tier stays at T0 at least 95% of the time on mains power, and that app CPU rises by no more than about 10 points over today's 37-49%.

**Effort:** 7-9 engineer-days (estimate).

---

### 5.14 v11.4: Signature transitions, brand stingers, finishing, captions

**What viewers see.**
- Segment changes get a blurred whip, a zoom-through or a branded stinger sized for each shape.
- Camera and screen share one grade.
- Shorts can get word-by-word captions.

**How it works.**
- **Re-measured first.** Every effect in this phase and in v11.5 is run through the real-compositor benchmark (screen + camera, both canvases) before its budget is fixed. Until then those budgets are **unmeasured in the real app** and the effects are T0-only.
- **Shader library.** Metal source compiled at launch in the background, with a "ready" flag and a fallback to built-in effects. It is never compiled on the render queue.
- **Whip pan:** a slide plus motion blur peaking at radius about 60, about 0.33 s. T0 only; otherwise Morph.
- **Zoom-through:** a scale plus dissolve centred on the current focus. A radial-blur shader is added only if the real benchmark shows +3 ms or less. **Never zoom blur.**
- **One gl-transitions port (directionalwarp, MIT):**
  - dropped if its real-compositor p95 exceeds 12 ms;
  - its own licence field and commit are recorded in THIRD_PARTY_NOTICES.
- **Brand stinger, generated for each canvas shape:**
  - your accent colours plus a slot for your own logo file;
  - reveals the next scene through a matte wipe;
  - replaces the colour bar.
- **File stingers:**
  - HEVC-with-alpha or ProRes 4444 MOV, one per shape;
  - played as a media source with a cut point;
  - sound through the existing mixer path, with a pre-roll;
  - WebM must be converted first.
- **Finishing per canvas:** a 33³ colour grade at 30-60% strength, identical on both canvases, plus a subtle vignette. **No grain in v11**, because the stream and recordings share one render and grain 0.06 used 70% more bits.
- **Captions on 9:16:**
  - **off by default;**
  - on air, only **final** words, above a confidence floor;
  - a profanity and blocklist mask;
  - a language check that turns captions off when the speech language doesn't match;
  - a kill key ⌃⌥⌘L;
  - words still being revised show only in your private preview;
  - 1-3 words at a time, two lines at most, kept out of the top 15% and bottom 35%;
  - the current word pops by 10% or less for about 150 ms;
  - cached line images.

  Before designing the pop, check whether word times ever appear on unfinished results.
- **Taste rules:**
  - cut or a short Morph if the last switch was under 8 s ago;
  - Morph for layout changes;
  - signature transitions only on a topic or part change, at most once per 90 s;
  - never random;
  - dissolves 0.5 s or less;
  - a per-scene "transition in" override.
- **Bundled assets** (stinger art, caption font, colour grade) must be original, CC0 or OFL.

**Budget.**
- Whip 9.52 / 11.5 ms, measured in the real compositor.
- All other effects: transition window p95 of 12 ms or less and worst tick 20 ms or less, as measured in the real compositor.
- Finishing within 1 ms of steady.
- Captions within 1 ms of steady.
- Stinger decode 1.27-1.56 ms per frame, on the media queue.

**Controls.**
- Transition picker: Morph 2.0 (default), cut, fade, whip, zoom-through, brand stinger, file stinger, directionalwarp.
- "Allow signature transitions", with a minimum gap (default 90 s).
- Stinger file per shape.
- Finishing: colour grade and strength, vignette.
- Captions: on/off, style, "show words as heard" (off; D14).

**Acceptance test.**
1. Zero shader compiles on the render queue, verified by instrumentation. After Prepare, the worst tick at launch and on the first use of each transition is 20 ms or less.
2. 200 scripted transitions (100 Morph, 50 whip, 50 stinger or zoom-through):
   - missed frames at baseline;
   - transition window p95 of 12 ms or less;
   - worst tick 20 ms or less.
3. Stingers:
   - transparency survives (a see-through pixel shows the scene beneath);
   - the cut lands within ±1 frame;
   - sound stays in sync within ±1 frame.
4. At T1, a requested whip renders as Morph and is logged as a "budget downgrade".
5. Captions:
   - final words appear 2.5 s or less after being spoken (p90);
   - 100% stay inside the safe zones;
   - a replay of a Hinglish rehearsal shows no word below the confidence floor.
6. On real footage at your bitrate, the worst-frame PSNR of whip and zoom-through is at least that of an unblurred slide.
7. In a 60-minute auto-directed rehearsal, at most one signature transition per 90 s and none during back-and-forth talk.

**Effort:** 10-12 engineer-days (estimate).

---

### 5.15 v11.5: Referencing, "say it, it zooms there", and spotlight

**What viewers see.**
- You say "open Settings", and about 1.1-1.4 s later the screen zooms to Settings with everything else dimmed, then returns.
- Naming a prepared topic brings up its motion graphic or card.

**How it works.**
- **Pre-check before building.** Run accurate OCR in three fresh processes while watching network activity with `nettop` and `lsof` (both built in). This checks:
  - whether the 34.8 s first use downloads anything (if it does, it joins the Apple-download items that need your OK);
  - whether the stall repeats.
- **Screen text map:**
  - accurate OCR with language correction off;
  - on a copy no wider than 1920 px, made with VideoToolbox or Accelerate (measure both, keep the cheaper; never the render context), so capture buffers are never held;
  - only after the screen has been still for 500 ms or more;
  - at most once per 2 s, limited to the changed regions, on its own queue, and only while a screen source is on air;
  - between runs, boxes are shifted for scrolls (0.7 ms at 540p);
  - warm-up happens at app launch, only when referencing is enabled. "Referencing ready" stays off until it finishes.
- **Matcher** (deterministic, built on CueMatcher):
  - fuzzy labels with aliases, including Hinglish transliterations;
  - a pointing-verb or "this/here" gate;
  - a veto for negation, "later" and "not now";
  - fires on stable partial text;
  - "this" and "here" resolve to where the cursor was over the last ~1.5 s.
- **Fire policy:**
  - auto-fire only when the matcher hits **and** either the cursor is within about 150 px of the box or the phrase is an exact verb plus label;
  - everything else becomes a one-key chip in the Private panel;
  - optional and off by default: the on-device Apple model as a tie-breaker (yes/no first, then a choice among the region labels, at most 1 call per 2 s), never the only trigger.
- **Spotlight:**
  - applied in source coordinates, so it zooms with the layer;
  - a 40-55% dim with a soft rounded cutout, a ring or an underline;
  - in over 225-300 ms, out over about 195 ms;
  - returns by itself after 4-6 s;
  - high-confidence hits only.
- **Prepared reference table:**
  - built during show prep over the control link (`set_references`): keyword or alias → an existing asset-library ID only, never a file path or URL;
  - aired through the existing asset slot and director guards;
  - nothing is fetched live.
- **Guards:**
  - at least 3 s between automatic zooms, at most 6 a minute;
  - a 30 s pause after a manual change;
  - kill switch, log, and modes off / shadow / suggest / auto;
  - **shadow mode for 1-2 shows first.**

**Budget.**
- OCR at most 1 call per 2 s, about 135 ms of CPU each, so 7% of one core or less on average.
- Copy 5 ms or less.
- Render p99 within baseline + 1 ms during OCR calls.
- Spotlight within the transition ceiling while shown (real-compositor cost re-measured in v11.4).
- Matcher 0.06 ms.
- All analysis together: 25% of one core or less.

**Controls.**
- Referencing: off / shadow / suggest (default after shadow) / auto.
- Spotlight dim amount and return time.
- Reference-table editor.
- Tie-breaker toggle, shown only if Apple Intelligence is already on.

**Acceptance test.**
1. On 2-3 real local rehearsals that you label:
   - auto-fire precision of 0.9 or more, and 1 false auto-fire per 30 minutes or fewer, before auto can be a default;
   - recall from auto-fire plus chips of 0.7 or more.
2. From the spoken word to the zoom: it starts within 1.0 s (median) and lands within 1.5 s.
3. OCR:
   - never on the render queue or during a transition;
   - 0.2 Hz or less at T1, off at T2 and above;
   - capture frame rate within ±1%;
   - 0 capture buffers held longer than 10 ms;
   - render p99 within baseline + 1 ms.
4. Privacy:
   - a network check shows no destinations other than your RTMP endpoint, 127.0.0.1 (LiveKit, control link) and, with the brain on, its API, compared against the Gate 0 list;
   - unit tests show no OCR text in brain requests or MCP results.
5. No spotlight ever comes from a chip you didn't accept. The kill switch and undo act within 1 frame.
6. The tie-breaker, if enabled, passes the same render-p99 check.
7. A 60-minute screen-heavy soak passes.

**Effort:** 9-13 engineer-days plus 1 day of labelling (estimate).

**Milestone:** second public sync after v11.5 passes acceptance.

---

### 5.16 v11.6 and later: opt-in extras (each needs your OK and is scoped one at a time)

**Director delay ("Mode B", 250-400 ms).**
- **What it buys:**
  - zooms can start before a click (about 0.15 s ahead) and ahead of typing (about 0.4 s);
  - punch-ins can land on the word.
- **The real trade-off.** Your preview and the guest feed use the same picture as the stream. So either:
  - they are delayed too, or
  - Framecast draws a second, undelayed 16:9 picture (estimate +2-4 ms per tick, to be benchmarked).
- **What must be delayed together:** every video source and the audio, to keep lip sync.
- **Memory for 300 ms (9 frames):**
  - screen + camera: about 108 MB in the compact 420v format, which costs a conversion pass, or about 290 MB as delivered;
  - plus guests.
- **Acceptance:**
  - a clap test in sync within ±1 frame on the output, the preview and the guest feed;
  - zooms begin at least 150 ms before their click;
  - a 60-minute soak with 0 extra missed frames.

**Typing follow through Accessibility (opt-in).**
- Reads the caret position through `AXFocusedUIElement` → `AXSelectedTextRange` → `AXBoundsForRange`, with a 50-100 ms timeout.
- Never reads typed text, never asks for Input Monitoring, and is suppressed on password fields.
- Has a per-app off list and a "following typing" indicator.

**Gesture punch-in.**
- One deliberate gesture held for at least 0.8 s, seen in at least 3 consistent frames.
- Joint confidence of at least 0.3-0.5, no hands at the frame edge, and a 3 s cooldown.
- Thresholds tuned per macOS hand-model generation.
- Blocked while Apple's gesture reactions are on.
- Target: 1 false trigger per 30 minutes or fewer.

**"Hold it up" punch-in.** Triggers when an object held toward the camera stays salient for at least 0.8 s.

**Several people.** A ByteTrack-style tracker in Swift, with Vision feature prints for re-identification. These are kept in memory only, never saved or logged.

**Cut-out spotlight.** Uses Apple's macOS 27 tap-to-segment, only after you approve Apple's model download. Its size and speed are unmeasured.

**Optional small models,** only if a measured need appears:
- **D-FINE-N** (Apache-2.0, about 13 MB). Only Apple-published or self-converted weights. Converting needs `coremltools` via pip, which is a separate decision for you. It also needs a check that it runs on the Neural Engine; otherwise RTMDet-tiny.
- **Depth Anything V2 Small** (Apache-2.0, 19 MB).

**Other experiments:**
- 60 fps evaluation (the camera tops out at 30 fps);
- the Desk View camera as a product source, since whether it runs alongside the main camera is unverified.

### 5.17 Effort totals (estimates)
| Scope | Engineer-days | Reviewed draft for comparison |
|---|---|---|
| v11.0 | 11-14 | 9-11 |
| v11.1 | 10-12 | 8-10 |
| v11.2 | 6-8 | 5-7 |
| v11.3 | 7-9 | 6-8 |
| **v11.0-v11.3** | **about 34-43** | about 27-35 |
| v11.4 | 10-12 | 8-10 |
| v11.5 | 9-13 + 1 labelling | 8-12 + 1 |
| **v11.0-v11.5** | **about 53-68 + labelling** | about 43-57 |

The increase pays for the reviewers' fixes:
- the offline brain stand-in;
- the privacy guards and click filtering;
- better frame metrics;
- the clean recording;
- re-measuring effects in the real app;
- caption safety;
- the OCR network check.

---

## 6. Permissions and privacy

| What | Permission | Notes |
|---|---|---|
| Camera, microphone, screen recording, speech | already granted | Vision reads frames Framecast already captures |
| Screen-change areas, click rings, OCR on captured frames | covered by Screen Recording | |
| Camera face boxes, Center Stage | covered by Camera | Your Center Stage setting is recorded and restored |
| Cursor position, app switches, Carbon hot keys, the secure-input check, window owner and position | none | Window titles are not read |
| Global click monitor | none, per Apple's header | Verified on a clean test build on macOS 27 in v11.0. The fallback's permission status is checked too |
| Apple Intelligence | not a permission | Offered only if already on. Turning it on downloads several GB of Apple models, and Framecast never prompts you to |
| Accessibility | v11.6+ typing follow only, opt-in | |
| Input Monitoring | **never** | |
| Apple model downloads, third-party models | your explicit OK first | |
| Network | no new destinations | |

**Privacy guarantees:**
1. **Screen text never leaves the Mac.** It doesn't go to the brain or into MCP results, and it isn't logged by default. Screen text is also treated as untrusted, since it could contain prompt-injection attempts.
2. **The brain gains only abstract flags.** Unit tests check every brain request and every MCP tool result against an allowlist.
3. **Zooming never makes private things readable:**
   - no zoom while secure input is on;
   - a default never-zoom list you can edit: Keychain Access, 1Password, Bitwarden, Passwords, Messages, Mail, Wallet, System Settings, Notification Center and Control Center;
   - the app under the click is checked, not just the frontmost one;
   - the view is kept off never-zoom windows;
   - optional hiding of password managers and Keychain from capture;
   - a Do Not Disturb reminder at Go Live.
4. **Ignored areas:** Framecast's own windows (including the Private panel and prompter), other displays, the menu bar, the Dock and notifications.
5. **Local files:**
   - the "edit signals" file is off by default, opt-in per recording, and kept in the show's local folder, not beside exported media;
   - it never contains guests' face boxes or OCR text;
   - `.gitignore` gains `*.signals.jsonl`, `rehearsals/` and benchmark output;
   - real labelled rehearsals stay outside the repo.
   - The repo already tracks four transcript files under `experiments/ai-director/transcripts/` (also in the public repo). They are transcripts of synthetic test audio made with macOS `say`, not your voice, so they are safe to keep.
6. **No API spend in tests** without your yes (D5).
7. **The local test stream** uses the ffmpeg already on the Mac, bound to 127.0.0.1. Nothing is installed.
8. **The on-device Apple model only.** `PrivateCloudComputeLanguageModel` (cloud-hosted) is banned by a build-script check.

---

## 7. Risks and how we handle them

**Performance**

| Risk | How we handle it |
|---|---|
| The render lock covers the whole render, so anything that takes it stalls frames | Producers use their own small locks. The tick only copies snapshots and steps springs. The cursor is read outside the lock |
| Every benchmark ran in isolation; nothing has been measured for an hour with everything on | Gate 0 in the app, a soak every phase, the governor from v11.0, and a battery soak in v11.1 |
| CPU cost varies with load (9-18% of one core for detect + track; up to 23% with more requests) | Budgets in CPU time per analysed frame. Ceilings come from the in-app soak. The detector rate drops if a budget is exceeded |
| Neural Engine, graphics chip and speech all stacked; heat over a long stream unmeasured | Soaks run with speech on and log speech latency next to render p99. Eco on battery. T3 holds |
| Core Image compiles each new effect combination on first render, on the render queue | Prepare renders every combination off air at launch. Acceptance requires a worst tick of 20 ms or less on first use |
| One-time model compiles (34.8 s OCR, 4 s hand pose) come back after macOS updates | Warm-ups run at launch, never while live. Anything over 1 s is flagged as a cold compile, and that feature waits |
| Capture buffers held too long starve the capture pool | One frame in flight, drop counters, and a small copy if holds go over 10 ms |
| 50 or 60 fps halves the budget | Light profile only at 50 or 60 fps |
| No offline Metal compiler | Runtime Metal source, compiled in the background, with a built-in fallback |

**Look and feel**

| Risk | How we handle it |
|---|---|
| Over-zooming, jitter, motion sickness | Dead zones, hysteresis, minimum holds and rate limits; Moderate by default; rehearse before air; a master switch and a reset key from v11.0 |
| Typing or scroll inference sticks at 1.8x on a blinking caret or a video | Shadow only until it scores, strict typing pattern rules, an 8 s maximum hold, and tests for caret, video and clock cases |
| Zooms trail the click; references land 1.1-1.4 s late | Honest defaults; the director delay stays an opt-in experiment |
| Stacked zooms go soft | One sharpness rule on the combined zoom; 9:16 full camera pans only |
| A bad automatic move is baked into the recording | Master switch off by default, rehearsal, a clean 16:9 recording option from v11.1, undo and reset keys |
| Captions show mistakes on air | Off by default; final words only; a confidence floor, a blocklist, a language check and a kill key |
| The encoder struggles with dissolves, scaling moves and grain | No grain, dissolves 0.5 s or less, blurred whips, and a PSNR check at your real bitrate |

**Coordinates and camera**

| Risk | How we handle it |
|---|---|
| Coordinate traps: bottom-left against top-left origins, Retina scale, the 3840 cap, crop and mirror order, moving windows | Coordinate tests for every flip before any automatic mode ships. Per-frame window position |
| Center Stage moves the shot twice and changes both canvases | Center Stage and our follow are mutually exclusive. Your setting is recorded and restored. Changes happen only off air or with a confirmation. Whether it affects other apps is to be tested |
| A camera-format switch glitches the camera on air | Only off air, or with a confirmation |
| Video Reactions trigger by accident | Gestures defaulted off for Framecast through the Info.plist key; Preflight reads `reactionEffectGesturesEnabled` |
| The cursor drifts into hidden or excluded areas | Hit-testing; panning freezes over ignored areas |

**Privacy and safety**

| Risk | How we handle it |
|---|---|
| Private details become readable when zoomed | Secure-input suppression, the default never-zoom list, the window check, view clamping, optional capture hiding |
| Screen text leaks via the brain or MCP | Never sent. Allowlisted MCP schema. Egress tests |
| Tests spend money on the API | Offline brain stand-in; real runs only with your yes |
| Sensitive local files reach the public repo | Signals file opt-in, `.gitignore` rules, the sync scan |
| Wrong reference fires on air | Verb and cursor corroboration, suggest by default, shadow shows, your own labelled rehearsals |

**Persistence, UI and process**

| Risk | How we handle it |
|---|---|
| Older builds silently reset settings | Optional fields only, a separate `transitionStyle`, and load tests in both directions against the restore tags |
| Undo collisions or surprises | ⌃⌥⌘U for director decisions only; the reset key for local moves; "Undo will revert: …" shown |
| Trace drags move layers in the editor | An explicit Trace mode that switches off editor dragging |
| Hot keys clash (⌃⌥⌘M is already Mute) | New keys checked against existing bindings; registration failures shown |
| The click monitor needs a permission on macOS 27 after all | Clean test-build check in v11.0, plus a fallback |
| Licence contamination | Apple frameworks and our own code only. SPDX ID and commit recorded for every reused source. Exclusion list |
| Scope creep toward heavy models | Nothing third-party through v11.5. Later models need a measured need, Apache or MIT, and your OK |

---

## 8. Decisions for you

| # | Decision | Recommended default | Needed by |
|---|---|---|---|
| D1 | Add a short output delay so zooms can start before clicks? | **No delay through v11.5.** Try Mode B later as an experiment, knowing the preview and guests are delayed too (or a second render is needed) and it costs about 110-290 MB | v11.6 |
| D2 | Canvas frame rate | **30 fps.** At 50 or 60 fps only the Light profile runs | v11.0 |
| D3 | Camera moves on first launch and after upgrading | **Off, rehearse first** | v11.0 |
| D4 | Hide password managers and Keychain Access from screen capture | **Yes, those apps only.** Others stay visible but never zoomed | v11.0 |
| D5 | Test runs that use the real brain on your key | **Only with your yes per run,** with the call count shown. The offline stand-in for everything else | v11.3 |
| D6 | Default follow for the built-in camera | **Framecast Auto framing.** Apple Center Stage offered as the battery option, never both | v11.1 |
| D7 | Higher camera format (1760x1328) for 9:16 sharpness | **A/B test off air in v11.1.** Keep 1920x1080 unless there is a clear gain | v11.1 |
| D8 | Clean (unmoved) 16:9 recording | **Offer it, default off.** I suggest turning it on for your first few shows with camera moves | v11.1 |
| D9 | Guests | **Face-centred framing for up to 4 guests at 1/s;** speaker emphasis on in grids | v11.1 |
| D10 | What ⌃⌥⌘U undoes | **Director decisions only.** ⌃⌥⌘X resets local moves | v11.3 |
| D11 | Motion blur | **Auto:** fast moves and transitions only, full tier, 30 fps, radius 20 or less | v11.2 |
| D12 | Stingers | **Procedural brand stinger by default;** file stingers optional | v11.4 |
| D13 | Grain | **Off in v11** | v11.4 |
| D14 | Captions | **Off by default.** When on, final words only on air; "show words as heard" off | v11.4 |
| D15 | What "referencing" means | **Both:** zoom and spotlight on what you name on screen, and prepared cards or motion graphics from prep. No live image fetching | v11.5 |
| D16 | Referencing mode after the shadow shows | **Suggest (chips).** Auto per show only once precision passes | v11.5 |
| D17 | May screen text ever go to the cloud brain or over MCP? | **Never** | v11.3 |
| D18 | On-device Apple model as tie-breaker | **Off,** and offered only if Apple Intelligence is already on | v11.5 |
| D19 | Typing follow | **Skip Accessibility in v11.** Inferred typing zoom stays in shadow until it scores | v11.0 / v11.6 |
| D20 | Any third-party model, or Apple's segmentation download, in v11? | **No** | any |
| D21 | Apple video Reactions on air | **Gestures default off for Framecast** (Info.plist key); Preflight warns if they're on | v11.1 |

---

## Appendix A. Reviewer issues and how they were handled

Two reviews were run:
- **P:** performance and feasibility;
- **S:** rules, licences, privacy and UX risk.

Before deciding, I checked these points directly:
- the macOS 27 SDK headers (Center Stage, Reactions, NSCursor, the secure-input call, the window list);
- the display (3024x1964);
- the existing hot keys;
- the repo state;
- the key evidence files.

| # | Issue (short) | Severity | Outcome | Where |
|---|---|---|---|---|
| P1 | Governor trigger below transition costs; stuck at 50/60 fps | high | Accepted | 5.7 |
| P2 | v11.4 budgets came from a harness reading 3-5x low | high | Accepted | 4.1, 5.14 |
| P3 | 9:16 can't fill under a 2x cap; 2x not sharp on 3024 px | high | Accepted | 5.4 |
| P4 | Core Image first-render compiles on the render queue | high | Accepted | 5.11 Prepare, 5.12, 5.14 |
| P5 | First-use stalls are one-time compiles, not per process | medium | Accepted | 4.2 F, 5.11 |
| P6 | Mode B: preview and guests can't stay live for free; memory undercounted | medium | Accepted | 5.16, D1 |
| P7 | Vision CPU depends on QoS and clock speed | medium | Partly (see below) | 5.11 |
| P8 | Metrics blind to real stalls | medium | Accepted | 5.7, 5.8 |
| P9 | Typing inferred from screen changes will misfire | medium | Accepted (merged with S3) | 5.10 |
| P10 | Caption timing contradicts speech timing | medium | Partly (see below) | 5.14, D14 |
| P11 | Stacked chip loads untested | medium | Accepted | 5.8, 5.15 |
| P12 | Deltas below noise; benchmark source lost | medium | Accepted; graphics-chip use logged, not gated | 4.1, 5.3, 5.8 |
| P13 | Fixed-step springs at a jittered time | low | Accepted | 5.5 |
| P14 | Retarget fix only works for Morph | low | Accepted | 5.12 |
| P15 | Main-thread latency, own-window clicks, key release | low | Partly (see below) | 5.10, 5.12 |
| P16 | Cursor read inside the render lock | low | Accepted | 5.10 |
| P17 | 640x360 tracker needs a per-frame downscale | low | Accepted: native frame by default | 5.11 |
| P18 | Hold limits against measured outliers; no drop counters | low | Accepted | 5.8, 5.11 |
| P19 | Overstated platform claims | low | Accepted; checked against headers | 3.1, 5.10, 7 |
| S1 | Soaks would call the paid API | high | Accepted | 5.8, 5.13, D5 |
| S2 | Zoom makes private screen detail legible | high | Accepted (all six parts) | 5.10, 6, D4 |
| S3 | Typing or scroll zoom gets stuck | high | Accepted | 5.10 |
| S4 | Cursor follows into excluded areas | medium | Accepted | 5.10 |
| S5 | MCP `get_show_state` is a new path to the cloud | medium | Accepted | 5.13, 6 |
| S6 | Surprising defaults; shadow mode only for referencing | medium | Partly (see below) | 5.3, 5.10, D3 |
| S7 | One undo key for everything | medium | Accepted | 5.13, D10 |
| S8 | Zoom caps compound past the sharpness limits | medium | Accepted | 5.4 |
| S9 | Signals file retention; risk to the public repo | medium | Accepted; existing tracked transcripts flagged | 6 |
| S10 | No clean recording until v11.6 | medium | Accepted; moved to v11.1 | 5.11, D8 |
| S11 | Laptop cost understated; "every number measured" too strong | medium | Accepted | 1, 4 |
| S12 | 34.8 s OCR first use not checked for downloads | medium | Accepted | 5.15 |
| S13 | Captions burn mistakes into the stream | medium | Accepted | 5.14, D14 |
| S14 | Center Stage and camera-format changes mid-show | low | Accepted | 5.11 |
| S15 | Reactions preflight reads the wrong property | low | Accepted, and improved | 3.1, D21 |
| S16 | Trace drag collides with the layer editor | low | Accepted | 5.11 |
| S17 | Apple Intelligence means a big OS download | low | Accepted | 5.15, 6 |
| S18 | Local RTMP test receiver and an impossible egress test | low | Accepted (ffmpeg already at `/opt/homebrew/bin/ffmpeg`) | 5.8, 5.15 |
| S19 | Licence provenance unverified | low | Accepted | 3.2, 5.14, 5.16 |

### What changed beyond the reviews
- **S15 improved.** The SDK header shows apps can default gesture reactions to off with `NSCameraReactionEffectGesturesEnabledDefault` in Info.plist, until you choose otherwise in Control Center. That is more direct than the reviewer's suggested key.
- **P19 and S14 reconciled.** `centerStageEnabled` is a class property, so it is app-wide and changes both canvases. The header says it follows your Control Center choice in cooperative mode. Whether other apps are affected stays to be tested.
- **The 1.3x camera hard cap became 1.25x,** and the "9:16 camera 1.1x, pan only" rule became "pan only". Both changes keep them consistent with the single sharpness rule.
- **Hot keys.** ⌃⌥⌘M is already Mute, so the camera-moves toggle is ⌃⌥⌘C. The other new keys are ⌃⌥⌘Z, ⌃⌥⌘X, ⌃⌥⌘I, ⌃⌥⌘O and ⌃⌥⌘L, all free today.

### Declined or narrowed amendments, and why
- **P10, showing words still being revised on air in a lighter style: declined as a default.** A mistake shown on a live stream can't be taken back (S13). It stays an opt-in option, "show words as heard" (D14). The rest of P10 is accepted: animate only final words, and set the timing targets from the measured settle time.
- **S6, a "suggest" chip step for every automatic behaviour: narrowed.** A chip that appears after a click, or after you lean, is useless, because the moment has passed. Click zoom, auto framing and camera life instead go through Shadow → Rehearse (off air) → On air, with a replay score. Chips are kept where they fit: brain focus and references. The rest of S6 is accepted: master switch off, rehearse view, on-air indicator, and defaults stated.
- **P15, a local monitor for clicks in Framecast's own windows: narrowed.** Those clicks count only when Framecast's windows are part of the capture. Otherwise they land where viewers can't see, which is exactly S4's concern.
- **P15, back-dating the zoom start from the event timestamp: limited to at most 1 frame.** More than that would show as a jump at the start of the move. Delivery latency is logged, as asked.
- **P7, "consider .userInitiated for the camera loop": not decided yet.** Both priorities get measured and the lighter overall result wins. The CPU-time budgets and the in-app ceiling are accepted.
- **S10, the alternative of recording the raw screen source: not chosen.** A clean 16:9 program needs no editing to use, while a raw screen recording would.
- **P12, widening the graphics-chip criterion: chose to log it instead of gating on it.** ioreg's once-a-second sampling can't resolve a 2-point change.
- **S2 part 4, clamping the view away from denied windows: clarified.** When no view can avoid a denied window, there is no zoom. Easing to "wide" wouldn't hide a window that is already visible at 1.0x; the point is not to magnify it.

---

## Appendix B. Sources

**Apple platform**
- Vision `VNRequest` / compute devices: https://developer.apple.com/documentation/vision/vnrequest
- WWDC17 506 (Vision tracking): https://developer.apple.com/videos/play/wwdc2017/506/
- Tracking sample: https://developer.apple.com/documentation/vision/tracking-multiple-objects-or-rectangles-in-video
- WWDC20 10653 (hand and body pose): https://developer.apple.com/videos/play/wwdc2020/10653/
- WWDC21 10040 (faces): https://developer.apple.com/videos/play/wwdc2021/10040/
- WWDC21 10047 (Center Stage control): https://developer.apple.com/videos/play/wwdc2021/10047/
- WWDC22 10024: https://developer.apple.com/videos/play/wwdc2022/10024/
- WWDC22 10018 (Continuity Camera): https://developer.apple.com/videos/play/wwdc2022/10018/
- WWDC22 10155 (ScreenCaptureKit): https://developer.apple.com/videos/play/wwdc2022/10155/
- WWDC23 111241 (segmentation): https://developer.apple.com/videos/play/wwdc2023/111241/
- WWDC23 10158 (springs): https://developer.apple.com/videos/play/wwdc2023/10158/
- WWDC25 272 (new hand model): https://developer.apple.com/videos/play/wwdc2025/272/
- WWDC25 286 (Foundation Models): https://developer.apple.com/videos/play/wwdc2025/286/
- WWDC26 237 (iterative segmentation): https://developer.apple.com/videos/play/wwdc2026/237/
- WWDC26 241 (Foundation Models image input): https://developer.apple.com/videos/play/wwdc2026/241
- WWDC26 machine-learning guide: https://developer.apple.com/wwdc26/guides/machine-learning/
- Person segmentation: https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest
- Center Stage (Mac Help glossary): https://support.apple.com/guide/mac-help/aside/glos7c8cf8b7/mac
- `centerStageRectOfInterest`: https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagerectofinterest
- Mac17,9 camera (Apple Wiki): https://theapplewiki.com/wiki/Mac17%2C9
- Global event monitor: https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
- Input Monitoring (DTS): https://developer.apple.com/forums/thread/707680
- `showMouseClicks`: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showmouseclicks
- Accessibility caret forum: https://developer.apple.com/forums/thread/659755
- Secure input TN2150: https://developer.apple.com/library/mac/technotes/tn2150/_index.html
- `NSCursor.currentSystem`: https://developer.apple.com/documentation/appkit/nscursor/currentsystem
- SwiftUI Spring: https://developer.apple.com/documentation/swiftui/spring
- macOS Zoom follow modes: https://support.apple.com/guide/mac-help/mh35715/mac
- Image Playground `ImageCreator`: https://developer.apple.com/documentation/imageplayground/imagecreator
- Core ML `grid_sample` fallback: https://developer.apple.com/forums/thread/740621
- macOS 27 SDK headers read locally: `AVCaptureDevice.h` (`centerStageEnabled` :2496, `reactionEffectGesturesEnabled` :2592-2602), `NSCursor.h:156`, `CGWindow.h:170`, `CGEventSource.h:141`, and the Carbon/HIToolbox exports (`IsSecureEventInputEnabled`)

**Auto-zoom prior art**
- Screen Studio:
  - auto zoom: https://screen.studio/guide/auto-zoom
  - cursor: https://screen.studio/guides/custom-macos-cursor-size
  - animations: https://screen.studio/guide/animations
  - feedback: https://hub.screen.studio/p/custom-settings-for-default-automatic-zoom-range
- Tella:
  - API: https://help.tella.com/docs/api-reference/clips/auto-generate-zooms-from-mouse-activity.md
  - help: https://www.tella.com/help/editing/add-a-zoom.md
- FocuSee review: https://hongkiat.com/blog/screen-recorder-focusee-review
- Cap:
  - https://cap.so/llms-full.txt
  - https://raw.githubusercontent.com/CapSoftware/Cap/main/crates/project/src/configuration.rs
  - https://raw.githubusercontent.com/CapSoftware/Cap/main/crates/rendering/src/cursor_interpolation.rs
  - https://raw.githubusercontent.com/CapSoftware/Cap/main/crates/rendering/src/zoom_spring.rs
- Screenize:
  - https://github.com/syi0808/screenize
  - https://raw.githubusercontent.com/syi0808/screenize/main/Screenize/Generators/GenerationSettings.swift
  - https://raw.githubusercontent.com/syi0808/screenize/main/docs/plans/2026-03-09-dead-zone-camera-design.md
  - https://raw.githubusercontent.com/syi0808/screenize/main/docs/plans/2026-03-10-smart-generation-quality.md
  - https://raw.githubusercontent.com/syi0808/screenize/main/docs/plans/2026-03-07-dual-layer-camera-design.md
- OBS:
  - zoom-to-mouse: https://github.com/BlankSourceCode/obs-zoom-to-mouse and https://raw.githubusercontent.com/BlankSourceCode/obs-zoom-to-mouse/main/obs-zoom-to-mouse.lua
  - Guzzi fork: https://obsproject.com/forum/resources/zoom-and-follow-mouse-and-more-by-edoardo-guzzi.2289
  - render-delay limit: https://obsproject.com/forum/threads/increase-render-delay-limit.108334/
- Ecamm zoom: https://support.ecamm.com/en/articles/3216957-zooming-and-panning-in-screen-share-mode
- Riverside auto-crop: https://riverside.com/university-videos/auto-crop
- Arcade: https://docs.arcade.software/kb/build/edit/pan-and-zoom
- Screenity: https://github.com/alyssaxuu/screenity
- Unity SmoothDamp: https://docs.unity.com/en-us/engine/6000.3/script-reference/unityengine/mathf/smoothdamp
- Cinemachine: https://docs.unity3d.com/Packages/com.unity.cinemachine@3.1/manual/CinemachinePositionComposer.html
- Caret location write-up: https://dev.to/ahab_indieseek/how-to-locate-the-input-position-on-macos-and-what-it-took-to-get-it-right-3n5d
- 1€ filter: https://gery.casiez.net/1euro/ and https://cristal.univ-lille.fr/~casiez/1euro

**Transitions and finishing**
- vMix:
  - Merge: https://forums.vmix.com/posts/t26850-What-does-the--Merge--transition-do-when-used-for-a-Stinger
  - stingers: https://www.vmix.com/help28/StingerTransitions.html
- Ecamm Live Motion: https://support.ecamm.com/en/articles/10751152-using-live-motion
- Wirecast:
  - Smooth: https://www.wirecast.io/en/resources/smooth-transitions
  - review: https://streamingmedia.com/Articles/Editorial/Featured-Articles/Review-Telestream-Wirecast-12-132525.aspx?pageNum=2
- Streamlabs Motion Effect: https://streamlabs.com/content-hub/post/streamlabs-desktop-now-supports-motion-effect
- OBS:
  - Move: https://obsproject.com/forum/resources/move.913/ and https://github.com/exeldro/obs-move-transition
  - track matte: https://obsproject.com/kb/track-matte-stinger-transitions
  - transitions guide: https://obs-versions.com/blog/obs-scene-transitions
- StreamYard: https://streamyard.com/blog/streaming-software-with-customizable-scene-transitions
- Blackmagic ATEM: https://www.blackmagicdesign.com/products/atemtelevisionstudio/features
- Cut (transition): https://en.wikipedia.org/wiki/Cut_(transition)
- Shotcut whip pans: https://forum.shotcut.org/t/motion-blur-transitions-a-demo-video-tutorial-in-progress/20498
- Material motion durations: https://m1.material.io/motion/duration-easing.html
- Lower thirds: https://riverside.fm/blog/lower-thirds
- Zoom punch-ins:
  - Tella: https://www.tella.com/skills/add-zooms
  - Opus: https://www.opus.pro/tools/zoom-in-effect
- Shorts safe zone: https://www.revid.ai/youtube-shorts-safe-zone
- Subtitle pace: https://clevercast.com/bbc-subtitling-guidelines
- Netflix grain synthesis: https://ibc.org/content-management/news/netflix-rolls-out-av1-film-grain-synthesis-for-classic-movies/22018
- Fades and bits: https://patents.google.com/patent/US8270483
- gl-transitions:
  - licence: https://raw.githubusercontent.com/gl-transitions/gl-transitions/master/LICENSE
  - list v1.67.0: https://cdn.jsdelivr.net/npm/gl-transitions@1.67.0/gl-transitions.json
- MTTransitions: https://github.com/alexiscn/MTTransitions

**References and gestures**
- RealityTalk: https://ar5iv.arxiv.org/html/2208.06350
- Bolt, "Put-that-there": https://www.media.mit.edu/speech/papers/1980/bolt_SIGGRAPH80_put-that-there.pdf
- Electron accessibility: https://www.electronjs.org/docs/tutorial/accessibility
- Lense (vendor claim): https://lense-kdp8.onrender.com/
- Bing Search APIs retirement: https://learn.microsoft.com/en-us/bing/search-apis
- Unsplash API guidelines: https://help.unsplash.com/api-guidelines/unsplash-api-guidelines
- ZoomIt: https://technet.microsoft.com/en-us/sysinternals/bb897434
- Adobe body-driven graphics: https://research.adobe.com/publication/interactive-body-driven-graphics-for-augmented-video-performance
- Gestures:
  - Reactions off: https://teamdynamix.umich.edu/TDClient/30/Portal/KB/Article/11027/Turn-Off-Mac-iPhone-iPad-Video-Reactions-FaceTime-Zoom
  - Zoom: https://zapier.com/blog/zoom-hand-gestures/
  - Insta360: https://onlinemanual.insta360.com/link2pro/en-us/tutorial/first-use/basic-use
  - OBSBOT: https://the-gadgeteer.com/2021/02/17/obsbot-tiny-webcam-review-an-ai-powered-ptz-webcam

**Models**
- EdgeTAM: https://github.com/facebookresearch/EdgeTAM
- YOLOX: https://github.com/Megvii-BaseDetection/YOLOX
- Also surveyed (licences recorded in `experiments/live-editor/models/licences.tsv`):
  - permissive: D-FINE / DEIM, RT-DETR, RF-DETR, RTMDet (mmdetection), NanoDet-Plus, PP-PicoDet, Apple YOLOv3-Tiny, DETR-R50, MobileSAM, EfficientSAM, SAM 2.1, MODNet, Depth Anything V2, ByteTrack / OC-SORT / BoT-SORT, OWL-ViT / OWLv2, Grounding DINO, OmDet-Turbo;
  - excluded: Ultralytics YOLO, YOLOv6/7/9, YOLO-World, RobustVideoMatting, mmyolo, DEIMv2, MobileCLIP, Depth Pro, FastVLM, SORT, boxmot.
- The D-FINE-N Core ML package is a community conversion (john-rocky/peaceofcake v0.2.0), with its licence unverified.

**Local evidence.** The scripts and their outputs are in `experiments/live-editor/` (see its README). Frames from your recordings were never committed.

- **Real compositor:** `experiments/live-editor/compositor/results.txt`
- **Isolated Core Image harness:** `experiments/live-editor/effects/main.swift`, `effects/results/run1.txt`, `run2.txt`, `run3.txt`
- **Sharpness:** `experiments/live-editor/sharpness/`
- **Runtime Metal kernel:** `experiments/live-editor/metal-kernel/`
- **Encoder:** `experiments/live-editor/encoder/enc.swift`, `enc-4500.txt`, `enc-1500.txt`
- **Vision:** `experiments/live-editor/vision/visionbench.swift` and `vision/results/` (`final_table.md`, `out_video_run2.txt`, `out_concurrent_run3.txt`, `out_ocr.txt`, `out_ocr_run2.txt`, `out_devices_run2.txt`, `out_flow_run2.txt`, `out_track.txt`, `quickbench-run1.txt`, `devices-and-loop-run2.txt`, `devices-and-loop-run2b.txt`)
- **Camera probe:** `experiments/live-editor/camera-probe/`
- **Referencing:** `experiments/live-editor/references/` (`ocr_bench`, `intent_bench`, `intent_bench.twostep`, `image_bench`, each `.swift` with its `.out.txt`)
- **Cursor-read probe:** `experiments/live-editor/cursor/cursorcost.swift`
- **Licences:** `experiments/live-editor/models/licences.tsv`
- **Repo files read (read-only):** `Sources/FramecastEngine/Engine.swift`, `Sources/FramecastEngine/Compositor/Compositor.swift`, `Sources/FramecastEngine/Sources/CaptureSources.swift`, `Sources/FramecastEngine/Sources/VideoSource.swift`, `Sources/Framecast/App.swift`, `Sources/Framecast/LiveBrain.swift`, `Sources/Framecast/BrainDirector.swift`, `Sources/Framecast/ShowDirector.swift`, `Sources/Framecast/ControlLink.swift`, `Sources/Framecast/ShowListener.swift`, `Sources/Framecast/Settings.swift`, `docs/VERIFICATION.md`, `docs/AI-DIRECTOR-RESEARCH.md`, `experiments/ai-director/on-device-llm/results.txt`
