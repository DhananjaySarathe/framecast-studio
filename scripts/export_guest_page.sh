#!/bin/zsh
# Copies the guest page into build/guest-page/ for a static host (Cloudflare Pages, GitHub Pages, Netlify…),
# used when guests join from anywhere through LiveKit Cloud. The page holds no keys: each invite link carries
# its own LiveKit token after the "#", which browsers never send to the web host.
set -e
cd "${0:A:h}/.."
OUT=build/guest-page
rm -rf "$OUT"; mkdir -p "$OUT"
cp Resources/guest/index.html Resources/guest/livekit-client.umd.js Resources/guest/LICENSE-livekit-client.txt "$OUT/"
# Response headers for hosts that read a _headers file (Cloudflare Pages, Netlify); others ignore it.
cat > "$OUT/_headers" <<'H'
/*
  Referrer-Policy: no-referrer
  X-Content-Type-Options: nosniff
  Permissions-Policy: camera=(self), microphone=(self), display-capture=(self)
H
echo "Guest page ready in $OUT ($(ls "$OUT" | wc -l | tr -d ' ') files). Upload that folder to your static host."
