# Camera angles

Phones and other computers join as extra cameras of you, through a camera link, and one camera can also make a
medium shot and a close-up of you (Angles from one camera). One frame in your layouts shows the angle you pick, or
cuts between the angles by itself (the shuffle). The background and the layout stay the same; only the picture in
that frame changes.

## Going live with angles (the short version)

1. Open Framecast, **Guests** › **People on my Wi-Fi** › **Open the guest room**. Your links are the same as last
   time, so phones that already have the camera link just reload it.
2. On each phone: open the **camera link**, hold it sideways on a stand, pick **Back** or **Front**, **Join as a
   camera**. On the Mac: **Let in** (Angles shows each one as a numbered tile with its picture).
3. Guests: send the **invite link**; they pick their camera, **Ask to join**; you **Let in**, then **Put on air**.
4. Angles › **Switching keys** on (or **⌃⌥⌘K** from anywhere). Now **1–6** cut to an angle, **0** back to your
   camera, **S** the shuffle (the AI cuts for you), **]** / **[** next and previous. They start off every time
   Framecast opens, because while on those keys don't type in other apps; turn them off after the show.
5. Want the AI to run it? Press **S**. It cuts in your pauses, follows where you look, varies the shot sizes, and
   (macOS 26 with Apple Intelligence) Apple's on-device model picks angles from what you're saying. Any angle key
   takes over at once; **S** again hands back to the AI.
6. If something doesn't connect, Guests and Angles say exactly what happened to that person or phone.

## Set up

1. **Guests › Who can join**: choose **People on my Wi-Fi** for phones in the room, then **Open the guest room**.
   The room gives you two links: one for guests and one for cameras. Both stay the same when you close and reopen
   the room or restart Framecast, so a link you sent earlier keeps working; **New link** replaces one.
2. **Angles › Camera link › Copy**, and open the same link on every phone or computer. Hold phones sideways (16:9)
   and put them on a stand. Allow the camera, then tap **Join as a camera**. Devices join camera only; ticking
   "Also lend the microphone" is optional (for measuring lip sync, or to let its sound into the show).
3. Click **Let in** (Angles or Guests). The phone becomes the next numbered angle.

On your Wi-Fi the phone's video comes to the Mac over a connection the phone opens (a relay inside Framecast), so it
works without macOS's Local Network permission and on Wi-Fi that blocks UDP between devices (docs/GUESTS.md).

A guest or device that loses its connection (a Wi-Fi blip, the phone sleeping) rejoins by itself with the same
pass and keeps its place (on-air status, angle number, delay) for three minutes. While an on-air guest is away the
next guest moves up, so no tile is left blank; the guest goes back on air by itself when they return. Reloading the page reuses its pass
too, and pages that stop waiting are let go after a minute, so retries never fill the room (10 guests, 6 cameras).
Guests and Angles show every step of joining (waiting, let in, in the room, couldn't connect, dropped, back), and
`GuestServer/devices.log` keeps them all. The phone page keeps the screen awake and shows a red frame while its
angle is on air. Guests and devices pick **Front** or **Back** (or a camera by name on a computer) and can
**Switch camera** at any time without leaving the show.

## Angles from one camera

One camera can also be a medium shot and a close-up of you, cut from its own picture and framed on your face, so
the shuffle can cut with one camera alone. Click **Angles › From one camera › Make angles from Camera** (when your
camera is the only angle, Angles offers it in a highlighted card), right-click the camera's tile › **Make medium
and close-up**, or select the camera's layer and click **Make angles from this camera** under Camera angles.

- **Keys.** "Camera · Medium" and "Camera · Close-up" come straight after the camera, so **1**, **2** and **3** are
  wide, medium and close-up. Phones and other cameras move up, and a notice names each new number ("Desk cam is now
  angle 4, its medium and close-up 5–6."). Only six angles have number keys; past six the row warns you (turn off a
  close-up, or use **]**).
- **Shots.** The chips **Medium ✓** and **Close-up ✓** turn each one on or off; **Turn off** stops both. The
  medium's and close-up's tiles have **Turn off this shot**, the camera's tile **Stop making angles from this
  camera**. While you record, the chips and **Turn off** are greyed out ("After the recording: each angle has its
  own file until it stops.") and a change is refused with a notice.
- **Framing.** The medium shows your face at 0.17 of the frame's height and the close-up at 0.30, eyes about a third
  of the way down with room above your head. Each shot is at least 1.4× tighter than the one before, so every cut
  changes the size. A shot your camera already gives (you sit close) isn't offered.
- **Sharpness.** A crop enlarges the camera's pixels. Up to 1.25× it's sharp; up to 1.6× it's a little soft (an
  amber "1.4×" on its tile); past that it's soft (a red "Soft 2.0×"), and the shuffle uses it less. In the 16:9 frame
  nothing is enlarged past 2×: the shot is loosened instead, so with your face at 0.12 of a 1080p picture the
  close-up shows it at 0.24. When that leaves no room for a close-up, the medium loosens a little (never below
  1.4×). A shot just past sharp (within 10%) is loosened to sharp. The row sums it up: "Medium: a little soft
  (1.4×) · Close-up: soft (2.0×)".
- **4K.** Framecast asks every camera for 1080p, so a 4K webcam sends 1080p. When your camera can send 4K close to
  16:9 at the show's frame rate (chosen the same way the camera is opened), the row offers **Use 4K from this
  camera**: with your face at 0.12 of the picture, the medium goes from 1.4× to 0.71× and
  the close-up from 2.0× to 1.25×, both sharp. The camera restarts (its picture stops for about a second), so the
  button is greyed out while you're live or recording (and refused with a notice); **Back to 1080p** undoes it. An
  undo while live or recording keeps the camera's size until the show ends, and says so. A 9:16 frame from a landscape
  camera is enlarged much more (2.5× and 3.6× at 1080p), so for vertical use 4K.
- **Off air, and why.** The tile and the row say: "Looking for you…" (no face yet), "Close-up needs a 4K camera" (or
  "Close-up needs 4K from this camera" when it can send 4K), "This camera sends 720p", "Your camera already shows a
  close-up", "Sit closer to the camera", "Move nearer the middle of the picture" (the picture's edge would cut you
  off), or "The frame is rotated: set Layer › Rotation to 0°". A key or a tile click for a shot that can't go on air
  is refused with that reason. A shot that goes off air while on air says why ("Camera · Close-up went off air:
  …. Back to your camera.", or "lost sight of you").
- **On air.** The crop holds completely still while you sit still. When you move clearly off your mark it follows
  you over about a second, smoothly, without overshooting; while you keep moving it leads a little (never past where
  it last saw your face) and pans quicker as you near its edge, then stops without running back. A small offset
  that lasts 4 s is re-centred. It doesn't
  zoom in and out as you lean: the size changes only once your face stays about 20% bigger or smaller for a few
  seconds, and then it glides. A 9:16 frame keeps its own framing: its crop is a third as wide, so it reframes on
  smaller moves, and it pans as fast across the camera's picture as the 16:9 one. Turning away or looking down keeps
  the crop still while your body stays where you were; if you leave the picture, it goes off air within about 2 s
  (the shuffle cuts away, a held crop goes back to your camera), even with someone else in view. The crops follow
  only you: someone seen beside you never takes them, and once you've gone a new face takes them only after 3 s;
  coming back where you were picks you up at once. Every cut lands already framed.
- **The shuffle** counts only angles that can go on air ("Shuffle on: 3 angles"); a medium or close-up the camera
  can't make doesn't count, and with fewer than two the shuffle says why. It cuts like an editor punching in on one
  camera: mostly between the camera and a crop, medium ↔
  close-up only now and then, close-ups when you make a point, the wide in silences. Looking into your Mac camera
  never cuts to a crop, and the AI is told crops are punch-ins for emphasis. Cuts within one camera never change how
  long your voice waits (Lip sync).
- **Tiles** show the cropped picture with a crop icon. The eye and the shot size stay on the camera's own tile.
- **Move transition.** A Move between a medium or close-up and its own camera slides and scales the frame like a
  Move between two layers of one source, instead of crossfading.
- **The frame's own crop.** The medium and close-up stay inside what the marked frame shows (its Layer › Crop) and
  are sized against what the wide shows there, so cropping the frame can make a 1080p close-up unavailable; a face
  in the cut-off part is ignored. Other cameras in that frame use their whole picture. A rotated frame makes none
  ("The frame is rotated: set Layer › Rotation to 0°").
- **Limits.** The medium and close-up of the frame's camera keep the frame's mirror and filters. A 9:16 close-up
  runs about 0.4 s behind a presenter who keeps moving: in a test at a slow walk the face stayed wholly inside, but
  off centre much of the time, and a faster walk can still cut its edge. They leave no extra room on the side you
  look towards.
- **Center Stage.** If Center Stage is reframing the camera, the row says so: the medium and close-up would move
  twice. Turn it off in Control Center › Video Effects; Framecast never changes the setting.
- **Privacy.** The medium and close-up are cut on this Mac from the picture the camera already sends; nothing more
  is captured or sent. Faces are found in the camera's picture (Vision, on this Mac) 5 times a second while the frame
  is on air with the shuffle running or a medium or close-up in it, while the tiles show, or while the shots are
  recorded to their own files; otherwise twice a second.

## Switching

- **Click a tile** in Angles to put that angle in your frame and hold it there. Click it again to let go.
- **Switching keys** (Angles › Switching keys): one key per action, working from any app, so nothing shows on a
  shared window. Turn them on before you go live (the switch, or **⌃⌥⌘K** from anywhere). Out of the box:
  **1–6** an angle, **0** your own camera, **S** shuffle on or off, **]** and **[** next and previous angle. Click a
  key to record another one (any key, with or without ⌘⌃⌥⇧: an F-key, a keypad key, a Stream Deck or foot pedal
  key), or **Use a set** (1–6 / F1–F6 / keypad / ⌥1–⌥6). While they're on, a single key doesn't type in other apps,
  which is why they have an on/off switch and start off each time Framecast opens. While you record a key, all of
  Framecast's shortcuts step aside (so ⌃⌥⌘1 is recorded, not run); clicking into another app or window cancels.
- An angle's key does nothing when that angle isn't sending a picture (Framecast says so), so an empty frame never
  goes on air.
- **⌃⌥⌘1–6**, **⌃⌥⌘0** and **⌃⌥⌘S** always work as well.
- Tiles are numbered like a switcher's multiview: **red** is on air, **green** is in your frame while that layout
  waits off air, the **eye** means you're looking into that camera, and the label says how tight it frames you.
- **The frame that switches** is the camera in the layout on air unless you mark another one: select any layer and
  turn on **Layer › Shuffle camera angles here**. One frame in the studio switches.
- If the angle on air stops sending, the frame goes back to your own camera after about two seconds.

## The shuffle

Cuts are hard cuts, as in live TV, made like a multicam editor would make them:

- **In your pauses**, never mid-word. Each angle holds about 6–10 s at the Normal pace (Calm about 8–14 s,
  Lively about 4–7 s); tighter shots hold shorter, and nothing holds past about 16 s.
- **Shot sizes vary.** The Mac sees how tight each angle frames you (from your face's size), and avoids cutting
  between two angles that look alike: the same size from less than 30° apart reads as a jump cut.
- **Your own camera** gets the most screen time (about 40–45%). A wide shot comes round about every 30 s.
- **A point made louder** favours a close-up; a long silence favours the wide shot.
- **Look into a phone** for most of a second and the shuffle cuts to it, mid-sentence if need be; it stays there
  while you talk into it, and cuts back when you turn back to your own camera (Cut to the camera you turn to).
- **The AI** (on by default, free): while the shuffle runs it hears you (Apple's on-device speech recognition, or
  Listen when that's on) and about every 10 s Apple's on-device language model (macOS 26 or later with Apple
  Intelligence) suggests the angle that suits what you're saying; its pick goes on air at your next pause. Nothing
  leaves the Mac and nothing costs money. **Use my API key instead** switches to Claude or OpenAI with your key in
  Settings › AI (each pick costs a little; it can also look at each angle once). Without either, the shuffle still
  cuts by your pauses, your face, your shot sizes and where you look. Angles shows what the AI hears and its last
  pick; if speech recognition can't start or stops mid-show it says so and tries again (after 5 s, then longer).
  Starting Listen takes the microphone over from it without a gap.

## Keep me in frame

An angle shaped unlike the frame (an upright phone in a 16:9 frame, a 16:9 phone in a 9:16 frame) is moved so your
face sits about 40% down the frame, following you over about a second. A cut lands already framed. Your own
camera's framing is never changed. Tiles show the same framing. Crops from one camera always frame themselves
(Angles from one camera); this setting doesn't change them.

## Lip sync

A phone's picture reaches the Mac later than your Mac's microphone hears you: typically 100–250 ms over Wi-Fi, and
viewers notice sound that's early by more than about 45 ms. So:

1. Set how late each phone runs with its slider in Angles › Lip sync. Or tick "Also lend the microphone" on the
   phone's page before joining and click **Measure**: the phone's microphone listens for a few seconds (heard by
   the Mac only, never in the show), and the Mac lines up the two recordings of your voice.
2. While that phone is on air, your microphone waits by the difference between the phone and your own camera. The
   change happens in a pause (where a moment of silence added or dropped isn't heard); after 8 s of nonstop talk it
   happens anyway. A cut you make mid-sentence is in sync from your next pause.

## Recording

**Angles › When you record**: the show only, or the show and each angle. Each angle gets its own 16:9 file
(`… angle Side.mov`), the whole picture fitted on black, with the show's sound, starting with the show's file so they
line up for editing. The medium and close-up get files only when **Also record the medium and close-up** is ticked
(`… angle Camera · Close-up.mov`, framed as in the 16:9 frame), and only shots that can go on air when the
recording starts: the camera's own file already holds them, and each file is a full render. A shot dropped
mid-take keeps its last framing in its file. Not recording keeps nothing.

## From anywhere (LiveKit Cloud)

Camera links work in the internet mode too. The hosted guest page needs the camera page: run
`./scripts/export_guest_page.sh` and upload `build/guest-page` again (it now includes `camera.html`).

## Privacy

Face tracking (Vision), crops from one camera, hearing you (speech recognition) and the AI's picks (Apple's
on-device model) all run on this Mac. Pictures and sound from the phones go to your Mac only (on your Wi-Fi, or
through your own LiveKit Cloud project). Only **Use my API key instead** sends anything out: one small picture per
angle when it looks (never of a crop: crops are only named), and the recent transcript every ~10 s, to Anthropic or
OpenAI with your key.

## Test hooks (`FRAMECAST_UI=…,test-control`)

`angle-pick:<n>`, `angle-back`, `angle-shuffle`, `angle-mark-camera`, `angle-unmark`, `angle-test-voice:on|off`
(talk 3 s, pause 0.6 s), `angle-test-look:<n>|off`, `angle-lineup:<n>[:<ms>]` (with ms: against the phone's own
sound moved that much earlier), `angle-sync:<n>:<ms>`, `angle-set:<followLook|keepFramed|lipSync|aiPicks|recordAngles>=on|off`
or `angle-set:pace=calm|normal|lively`, `angle-tiles:on|off`, `angle-hear:<text>`, `angle-analyse`,
`angle-device-audio:<name>`, `angle-key:<angle1…angle6|ownCamera|shuffle|next|previous>` (a switching key's
action), `angle-set:keysOn|useAPIKey=on|off`, `angles-dump:<file.json>`, `program-snapshot:<path>` (the program as
it goes out). Test launches use their own guest ports (+10000) and folder, so they never touch your room.
The camera page takes `?auto=1` (join by itself), `?test=1` (synthetic picture), `?testmic=voice` (a made-up voice)
and `?nomic=1`. `fcverify angles` runs the shuffle, lining-up and rotation checks.

Angles from one camera: `angle-set:virtual=on|both|medium|close|off` (the marked frame's camera, else the first
camera), `angle-set:use4k=on|off`, `angle-set:recordCrops=on|off`, `angle-test-face:<cx>,<cy>,<h>[,<yaw>]|off`
(cameras with crops see a face centred there instead of what Vision sees: camera picture, top-left 0…1, h of its
height), `angle-trace:<file>:<seconds>` (every crop drawn on air or into a recording, one JSON line each: t, angle,
key, x, y, w, h, zoom, face, and `raw`/`rawAt`: the followed face's last reading unsmoothed and its picture's host
time), `set-crop:<left>,<top>,<right>,<bottom>|none` (Layer › Crop on the selected layer, or the camera layer, of the
canvas being edited) and `render-view:angles|<png>` (Angles drawn off-screen). `angles-dump` also gives each
angle's `kind` and `looks` ([looks, faces found]); each crop's `parent`, `shot`, `available`, `reason`, `zoom`,
`faceInCrop`, `grade`, `enlargement`, `edgeLimited` and `crop`; a camera's `framedFace` and `lockedFace`; each cut's
`t` (host seconds); `voiceStart` (the scripted voice's clock); `notice` (the notice showing now); `virtual`, `fakeDevices`, and what draws each source
(`cameraKind`, `sourceKinds`). `dump-state` gives each source's `type`.

`FRAMECAST_FAKE_CAMERA=<clip>` (test launches only): from before the engine starts, every camera plays the clip on a
loop, screens, windows and apps show a drawn stand-in, and microphones, system and app sound are silent (or, with
`FRAMECAST_FAKE_MIC=<audio file>`, microphones play that file on a loop: docs/CAPTIONS.md), so no device is opened.
The test copy built by `build/e2e/quick_build.sh` is marked `FramecastTestCopy` in its Info.plist and quits at once
when opened without `FRAMECAST_UI`. The guest room then never sends your microphone, Add Source shows icons instead of screen pictures, and
`live-editor-selftest` does nothing. `FRAMECAST_FAKE_CAMERA_4K=<clip>` plays when 4K is asked for, and makes the
stand-in camera offer **Use 4K**. `fcverify virtual` runs the shot-size, framing, engine, shuffle and settings
checks; `fcverify face <png>` prints Vision's biggest face (top-left x, y, w, h, yaw, faces) as JSON and exits 1 when
there's none.
