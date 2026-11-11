#!/bin/zsh
# v11.0 acceptance: privacy guards and the budget governor, on a test copy launched with
# FRAMECAST_UI=onboarded,test-control. The cursor and clicks are simulated; NeverZoomTest.app (an orange window
# from its own bundle id) stands in for a never-zoom app. Results: <out dir>/*.json, scored by score_privacy_governor.py.
#   experiments/live-editor/acceptance/privacy_governor.sh <out dir> <path to NeverZoomTest.app>
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT=${1:?out dir}; HELPER=${2:?NeverZoomTest.app}; mkdir -p "$OUT"
F=build/fcctl
$F moves:rehearse; $F moves-intensity:moderate; $F moves-idle:5; $F own-windows:on; $F "never-zoom:"; $F moves-performance:auto
$F "layout-named:Screen + camera"; $F rail:chat; sleep 3
$F focus-cursor:900,300; sleep 0.5
$F "focus-trace:$OUT/trace.jsonl"; sleep 0.3

# 1. No zoom while a password field has the keyboard; zooms again once it's gone.
$F focus-secure:on; sleep 0.6; $F focus-click:900,300; sleep 1.5; $F "focus-dump:$OUT/1-secure.json"
$F focus-secure:off; sleep 3; $F focus-click:900,300; sleep 1.5; $F "focus-dump:$OUT/2-secure-off.json"
sleep 6
# 2. A click on the menu bar doesn't zoom.
$F focus-cursor:756,8; sleep 0.1; $F focus-click:756,8; sleep 1; $F "focus-dump:$OUT/3-menubar.json"
# 3. A click on Framecast's own window doesn't zoom when Framecast isn't in the shared screen.
$F own-windows:off; sleep 0.6; $F focus-cursor:700,500; sleep 0.1; $F focus-click:700,500; sleep 1; $F "focus-dump:$OUT/4-own-window.json"
$F own-windows:on
# 4. Never-zoom: a click next to the window zooms with the window kept out of view; a click on it doesn't zoom.
open -n "$HELPER"; sleep 2; $F "never-zoom:app.framecast.never-zoom-test"; sleep 1
$F focus-cursor:430,530; sleep 0.1; $F focus-click:430,530; sleep 1.5; $F "focus-dump:$OUT/5-next-to-never-zoom.json"
sleep 6
$F focus-cursor:250,530; sleep 0.1; $F focus-click:250,530; sleep 1; $F "focus-dump:$OUT/6-on-never-zoom.json"
pkill -f NeverZoomTest.app || true
$F "never-zoom:"
sleep 6
# 5. The reset key: back to the whole screen, and clicks don't zoom for 30 s.
$F focus-cursor:900,300; sleep 0.1; $F focus-click:900,300; sleep 1.2; $F focus-reset; sleep 1.2; $F "focus-dump:$OUT/7-reset.json"
$F focus-click:900,300; sleep 1; $F "focus-dump:$OUT/8-paused.json"
$F focus-trace:stop

# 6. Governor: frames held to just over each line enter T1, then T2; back up a tier per 60 healthy seconds;
#    over the T3 line for 5 s turns moves off; switching moves back on clears it.
$F "metrics-dump:$OUT/g0.json"; sleep 1
B=$(python3 -I -c "import json; print(json.load(open('$OUT/g0.json'))['governor']['baseline'])")
L1=$(python3 -I -c "print(max($B + 5, 1000 / 30 * 0.5))"); L2=$(python3 -I -c "print(max($B + 8, 1000 / 30 * 0.65))")
L3=$(python3 -I -c "print(max($B + 12, 1000 / 30 * 0.8))")
$F inject-tick-ms:$(python3 -I -c "print(($L1 + $L2) / 2)"); sleep 8; $F "metrics-dump:$OUT/g1-t1.json"
$F inject-tick-ms:$(python3 -I -c "print(($L2 + $L3) / 2)"); sleep 8; $F "metrics-dump:$OUT/g2-t2.json"
$F inject-tick-ms:0; sleep 85; $F "metrics-dump:$OUT/g3-recover1.json"
sleep 65; $F "metrics-dump:$OUT/g4-recover2.json"
$F inject-tick-ms:$(python3 -I -c "print($L3 + 3)"); sleep 9; $F "metrics-dump:$OUT/g5-t3.json"
$F inject-tick-ms:0; $F moves:off; sleep 1; $F moves:rehearse; sleep 2; $F "metrics-dump:$OUT/g6-reenabled.json"
$F own-windows:off; $F focus-cursor:off; $F focus-secure:auto
