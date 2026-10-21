#!/bin/zsh
# Let Claude Code direct a Framecast TEST COPY and time it. Uses your own Claude login (run `claude` once first).
#   experiments/ai-director/mcp/try-with-claude.sh [live|oneshot]      (MODEL=sonnet to try another model)
# Only a copy started with FRAMECAST_UI=...,test-control listens, so your everyday Framecast is never touched.
set -e
REPO=${0:A:h:h:h:h}
FCCTL=$REPO/build/fcctl
[ -x $FCCTL ] || { mkdir -p $REPO/build; swiftc -O $REPO/scripts/fcctl.swift -o $FCCTL; }

answers() { local f=$(mktemp -u); $FCCTL "dump-state:$f"; for i in {1..20}; do [ -f $f ] && { rm -f $f; return 0; }; sleep 0.15; done; return 1; }
if ! answers; then
  [ -d $REPO/build/test/Framecast.app ] || { echo "Build the test copy first:  FRAMECAST_APP=build/test/Framecast.app scripts/build_app.sh"; exit 1; }
  echo "starting the test copy…"
  open -n --env FRAMECAST_UI="onboarded,test-control,window=1440x900" $REPO/build/test/Framecast.app
  for i in {1..10}; do sleep 1.5; answers && break; done
  answers || { echo "the test copy is not answering"; exit 1; }
fi
FCCTL=$FCCTL python3 -I ${0:A:h}/try_with_claude.py ${1:-live}
