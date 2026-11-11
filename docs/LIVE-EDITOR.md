# Live editor: camera moves on your screen share

Version 11.0 of the live editor makes a screen share look edited while you're live. When you click, the stream
glides in to where you clicked, and the view follows your cursor. After a quiet spell it goes back to the whole
screen. On the 9:16 canvas the screen stops being a thin strip and fills the frame as a slice that follows you.
Everything runs on your Mac with fixed rules (no AI model), and it needs no new permission.

## Turning it on

Settings › **Live editor**:

| Setting | Choices | Default |
|---|---|---|
| Camera moves | **Off**, **Rehearse** (moves only while you're not live: in the preview and in recordings made before you go live), **On** | Off |
| Intensity | how far a click zooms: Subtle 1.4x, Moderate 1.6x, Lively 2x | Moderate |
| Back to the whole screen after | 3-8 seconds without a click or cursor move | 5 s |
| Click rings | a ring around each click in the shared screen (macOS 15 or later) | off |
| Hide password managers from screen shares | Keychain Access, Passwords, 1Password and Bitwarden are left out of captured displays | on |
| Never zoom into | apps whose windows are never magnified | password managers, Messages, Mail, System Settings, Notification Center, Control Center |
| Effects | Auto steps moves down on battery and in Low Power Mode; Eco always; Full ignores power | Auto |
| Status in the Rundown panel | frame time, budget tier, missed frames | on |

Shortcuts, from any app:

- **⌃⌥⌘Z**: zoom to where the cursor is.
- **⌃⌥⌘X**: back to the whole screen, with no zooms for 30 seconds.
- **⌃⌥⌘C**: camera moves on or off.

While camera moves are on, the Rundown tab shows a card with the mode, the budget tier and the frame time. Only you
see it. The Start a broadcast window says whether moves will happen on air.

## How it moves

- **A click** zooms in on that spot within one frame, and settles in about 0.6 seconds with no overshoot.
- **Two clicks close together** (within 2 seconds and half a screen) zoom a little less, so you can move between
  them.
- **The cursor** can move freely in the middle three quarters of the view. Past that the view follows, smoothly.
- **A quiet spell** with no click and no cursor movement (5 seconds by default) goes back to the whole screen.
  **Switching apps with ⌘-Tab** does the same.
- After zooming out, the next zoom-in waits at least 2.5 seconds, so it never bounces in and out.
- Moves pause during a scene transition and for 1.5 seconds after a switch.
- Both canvases move on the same frame. The springs step on a fixed clock, so moves look the same whatever the
  timing of each frame.

## What never gets magnified

- **Password fields:** while macOS secure input is on, nothing zooms and the 9:16 slice goes back to the whole
  strip.
- **Apps on the never-zoom list:** clicks in them don't zoom, and a zoomed view is kept clear of their windows. If
  no view can avoid them, there's no zoom.
- **macOS itself:** clicks on the menu bar, status items, the Dock, Notification Center or Control Center don't
  zoom.
- **Framecast:** clicks on Framecast's own windows don't zoom unless Framecast is part of the shared screen.
  Panning stops while the cursor is over them.
- **Nothing typed is read.** The live editor only knows where the cursor is and where you click.

## Sharpness

No source is ever shown more than 1.25 times its own pixel size, however the zooms add up. Where a source is
already enlarged (a full-frame 1080p camera on 9:16), the view can pan but not zoom.

On this MacBook Pro's display (captured at 3024 pixels wide), the default Moderate zoom stays below one canvas pixel
per screen pixel, so it's fully sharp. Lively, and the extra tightening on 9:16, go past it: the finest one-pixel
detail softens, but text stays readable.

## Keeping the Mac comfortable

A budget governor watches each frame's time, missed recording frames, heat and power, once a second. In the first
45 seconds after launch it learns this Mac's normal frame time; other apps share the graphics chip, so that's often
10-17 ms. It then steps down when frames run late:

| Tier | When | What changes |
|---|---|---|
| T0 Full | normal | everything |
| T1 Eco | frames 5 ms over normal and over half the frame, on battery, Low Power Mode, or warm for 2 minutes | nothing yet in 11.0 (reserved for later effects) |
| T2 Minimal | frames 8 ms over normal and over two thirds of the frame, 4 missed recording frames in 10 s, or the Mac is hot | calmer, slower moves |
| T3 Off | frames 12 ms over normal and over four fifths of the frame for 5 s, or the Mac is very hot | moves ease back to the whole screen |

It learns the normal frame time again whenever a recording, stream or replay buffer starts or stops, since encoding
makes every frame a little slower. It climbs back one tier after a minute of healthy frames (5 minutes to leave T3),
or as soon as you switch camera moves back on.

## Permissions and privacy

The live editor needs no new permission. Reading the cursor position, a global mouse-down monitor, the secure-input
check and the window list don't ask for Accessibility or Input Monitoring. Nothing new leaves the Mac.

## How it was tested

`fcverify live-editor` runs 55 checks without cameras or permissions: the zoom maths, sharpness limits, springs
(identical under 0-4 ms timer jitter), every rule above, and the governor.

`experiments/live-editor/acceptance/` drives a test copy with simulated clicks and cursor moves (nothing on screen
is clicked), and the self-test checks the real screen capture:

- Clicks map to the captured screen at 0 px error at nine points, and in a window capture before and after the
  window moved.
- The zoom starts within 39 ms of a click, settles in 0.59 s, and comes back to the whole screen 0.63 s after the
  quiet spell starts.
- The cursor stayed inside the middle three quarters of the view in 99.7% of zoomed frames.
- Each privacy rule and governor tier passed.

`experiments/live-editor/soak/` runs an hour with both canvases recording and a local test stream, with moves off and
on. In an hour with moves Off and an hour with moves On, both recordings kept every frame except during brief stalls
elsewhere on the Mac (one 169 ms stall cost about half a second), memory stayed steady, and nothing reached the
stream as dropped. Side by side, 15 minutes each on the same build: moves Off missed 2 frames (one 64 ms stall),
moves On (48 zooms) missed none.
