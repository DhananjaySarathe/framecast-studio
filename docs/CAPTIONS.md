# Live captions

What you say appears as captions at the bottom (or top) of the show while you say it, on both the 16:9 and the
9:16 canvas, so viewers see them on air and they're in your recordings. Apple's speech recognition does the work on
this Mac: free, no account, nothing sent anywhere.

## Using them

- **Turn them on or off:** the **Captions** button over the top-right corner of the canvases, the **Captions** tab
  on the right, Show › Turn On Live Captions, or **⌃⌥⌘L** from any app. They're off each time Framecast opens.
- **Captions tab:**
  - **Language:** English for your Mac's region unless you pick another. Any language this Mac's recogniser knows
    can be chosen (English and Hindi are listed first); one language at a time. A language used for the first time
    may need a one-time download from Apple, and the status line says so while it downloads.
  - **Size:** S, M or L. **Position:** Bottom or Top.
  - **Transcript:** every settled line with its time in the show (from the start of the recording or broadcast,
    else from when captions came on), and the words still being worked out, in grey, under it. Click a line to
    correct it: the correction goes into the transcript and the subtitle files, and, if the line is still on
    screen, onto the show at once. **Copy all** copies the transcript with times; the ⋯ menu clears it.
- **How they look:** white text on a rounded, dark, see-through plate, at most two lines. Words still being
  recognised are lighter and fade up to full white once they're settled. As you keep talking the lines roll up
  (a full bottom line moves up; words already placed never jump around). About 3 s after you stop, the captions
  fade out; the next words start fresh.
- **On 9:16** the captions stay above the bottom 22% (where Reels and Shorts put their buttons and text) and inside
  side margins.

Captions hear the presenter's microphone, picked as Listen picks it: the first microphone in the stream and not
muted. A muted microphone gives no captions. Switch microphones (remove one, or mute it and speak into another) and
captions follow within a second. They have their own way into the microphone, so they run at the same time as
Listen (the rundown director) and the angles' AI ears, and each keeps working when another stops.

## After the show

When a recording stops, Framecast writes two files next to each recording file (the 16:9 and 9:16 files and each
angle's file), the way it writes `… chapters.txt`:

- `<recording name>.srt`: subtitles for YouTube, editors and players, timed from the recording's start with pauses
  left out, at most two lines of 42 characters per cue, with your corrections.
- `<recording name> transcript.txt`: the plain transcript, one line per settled stretch, `[mm:ss] text`.

A line said mostly before the recording started (or during a pause) is left out. While captions are on, the files
are written about 1.5 s after the recording stops so the last words can settle. Nothing is written when nothing was
said while recording.

## Privacy

Recognition runs on this Mac with Apple's on-device speech models (`SpeechAnalyzer`, macOS 26 or later). Nothing
you say leaves the Mac; there's no account and no cost. The only network use is Apple's own one-time download of a
language's model, made by macOS, and only when that language isn't on the Mac yet (English and Hindi usually are).
On a Mac without Apple's speech recognition the controls are greyed out and say why.

## Limits

- One language at a time. **Hinglish** (Hindi and English mixed) is weaker: the English recogniser mangles Hindi
  words, and the Hindi one writes English words in Devanagari, sometimes wrongly. Listen's Hinglish mode runs two
  recognisers for the AI director; captions don't (two sets of captions would fight).
- Accuracy depends on the microphone, the room and how you speak. Names, brands and jargon are the usual misses
  ("frame cast" for Framecast): correct them in the transcript.
- Words show about 0.2–1.5 s after you say them; the first words after captions come on take a little longer
  (about 1–1.5 s) while the recogniser starts.
- With **Split recordings every … minutes**, the subtitle files are timed from the first part's start, so later
  parts' subtitles are off by the parts before them.
- The transcript keeps the last 3,000 lines of a session.

## Test hooks (`FRAMECAST_UI=…,test-control`)

`captions:on|off`, `captions-language:<locale id, e.g. hi_IN>|default`, `captions-size:small|medium|large`,
`captions-position:bottom|top`, `captions-feed:<audio file>` (turns captions on and plays the file through the
caption recogniser in real time instead of the microphone), `captions-correct:<line number|last>:<text>`,
`captions-clear`, `render-view:captions|<png>` (the panel drawn off-screen). `dump-state` has a `captions` section:
`on`, `status`, `language`, `hearing`, `size`, `position`, `supported`, `linesHorizontal` and `linesVertical` (the
lines readable on each canvas now), `transcriptCount`, `lastText`, `guess`, the last 30 `transcript` lines (`text`,
`heard`, `show`, `hostStart`, `hostEnd`) and `now` (host clock seconds).

`FRAMECAST_FAKE_MIC=<audio file>` (test launches with `FRAMECAST_FAKE_CAMERA` only): every microphone plays the file
on a loop, with 3 s of quiet between plays, into the mixer like a voice, instead of silence. No microphone is
opened. `fcverify captions` checks the logic and the drawing without a microphone; `fcverify ocr <png> [y0,y1]`
prints the text Vision reads (in a strip of the picture, top-left fractions) as JSON. `build/e2e/captions_e2e.mjs`
runs everything end to end on the test copy (results in docs/VERIFICATION.md, V66–V67).
