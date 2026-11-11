#!/bin/zsh
# Gate 0 / v11.0 soak: one hour on a test copy with both canvases recording, a local test stream and the replay
# buffer, metrics every minute. Run it twice: moves off (the baseline), then moves on with a click every ~20 s.
# The camera is a stand-in (mask-cameras); the screen capture is real. Recordings go to <out dir>/rec.
#   experiments/live-editor/soak/soak.sh <out dir> <off|on> [minutes]
# Needs a test copy at build/test/Framecast.app, build/fcctl, and ffmpeg (for the local RTMP receiver).
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT=${1:?out dir}; MODE=${2:?off|on}; MIN=${3:-60}
mkdir -p "$OUT/rec"
F=build/fcctl
pkill -f "build/test/Framecast.app/Contents/MacOS/Framecast" || true; sleep 2
open -n --env FRAMECAST_UI="onboarded,test-control,folder=$OUT/rec" build/test/Framecast.app
sleep 8
$F mask-cameras; $F "layout-named:Screen + camera"; $F rail:chat; $F stage:both
$F "never-zoom:"; $F moves-performance:auto
# Framecast is part of the shared screen here, so clicks on its window zoom too (it covers much of the display).
$F own-windows:on
if [ "$MODE" = on ]; then $F moves:rehearse; else $F moves:off; fi
# A local RTMP receiver that throws the stream away (127.0.0.1 only).
ffmpeg -v error -f flv -listen 1 -i rtmp://127.0.0.1:1935/live/test -f null - > "$OUT/ffmpeg.log" 2>&1 &
RX=$!
sleep 2
$F "stream-local:rtmp://127.0.0.1:1935/live|test"
sleep 50   # the governor learns this Mac's normal frame time from 15 to 45 s after launch
$F metrics-reset
$F record-start
START=$(date +%s)
$F "metrics-dump:$OUT/m-000.json"
i=0
while (( $(date +%s) - START < MIN * 60 )); do
  if [ "$MODE" = on ]; then
    # A click somewhere on the display, the cursor wandering for a couple of seconds, then quiet.
    X=$(( 150 + RANDOM % 1200 )); Y=$(( 120 + RANDOM % 740 ))
    $F focus-cursor:$X,$Y; sleep 0.1; $F focus-click:$X,$Y
    for k in 1 2 3 4 5 6 7 8 9 10; do $F focus-cursor:$(( X + k * 15 )),$(( Y + k * 6 )); sleep 0.15; done
    sleep 17
  else
    sleep 20
  fi
  i=$(( i + 1 ))
  if (( i % 3 == 0 )); then $F "metrics-dump:$OUT/m-$(printf %03d $(( i / 3 ))).json"; fi
done
$F "focus-dump:$OUT/focus-end.json"
$F record-stop; sleep 6
$F "metrics-dump:$OUT/m-end.json"
$F stream-local:stop; sleep 2
kill $RX 2>/dev/null || true
$F focus-cursor:off; $F own-windows:off
echo "soak $MODE done: $(ls "$OUT"/m-*.json | wc -l) metric dumps, recordings in $OUT/rec"
