#!/bin/zsh
# v11.0 acceptance: a scripted click tour on a test copy launched with FRAMECAST_UI=onboarded,test-control.
# Only fcctl test hooks are used: the cursor and the clicks are simulated, nothing on screen is clicked.
#   experiments/live-editor/acceptance/click_tour.sh <out dir>
#   python3 -I experiments/live-editor/acceptance/analyze_trace.py <out dir>/trace.jsonl
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT=${1:?out dir}; mkdir -p "$OUT"
F=build/fcctl
$F moves:rehearse; $F moves-intensity:moderate; $F moves-idle:5; $F own-windows:on; $F "never-zoom:"
$F "layout-named:Screen + camera"; $F rail:chat; sleep 3   # Comments, so no private panel sits on the screen
$F focus-cursor:756,491; sleep 1
$F "focus-trace:$OUT/trace.jsonl"; sleep 0.5
# Six clicks around the display, 7.5 s apart (each zooms in, then goes back after the 5 s quiet spell).
for p in 378,245 1134,245 756,491 378,736 1134,736 600,400; do
  $F focus-cursor:$p; sleep 0.1; $F focus-click:$p; sleep 7.5
done
# Follow: a click, then the cursor moves right across the display for about 4 s.
$F focus-cursor:300,500; sleep 0.1; $F focus-click:300,500; sleep 1.2
for x in $(seq 300 20 1200); do $F focus-cursor:$x,500; sleep 0.06; done
sleep 7
# Still: nothing happens for 10 s.
sleep 10
$F focus-trace:stop
$F "metrics-dump:$OUT/metrics.json"
$F own-windows:off; $F focus-cursor:off
