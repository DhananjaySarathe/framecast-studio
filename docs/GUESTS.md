# Guests in Framecast

Guests use LiveKit (open-source WebRTC). Framecast has no service of its own, so you choose where the guest room
runs, in the Guests panel under **Who can join**:

| Choice | Who can join | What it needs | Your IP address |
|---|---|---|---|
| **This Mac only** (default) | Browsers on this Mac | `brew install livekit` | Never leaves the Mac |
| **People on my Wi-Fi** | Phones and computers on the same Wi-Fi | `brew install livekit` | Seen by devices on your Wi-Fi only |
| **Anyone with a link (LiveKit Cloud)** | Anyone, anywhere | Your own LiveKit Cloud project + the guest page on a static host | Seen by LiveKit, not by guests |

The room also gives you a **camera link**: phones and other computers join as extra camera angles of you, switched
in Angles. See [ANGLES.md](ANGLES.md).

Guests choose their camera before joining (Front or Back on phones; every camera by name on computers with more
than one) and can switch while in the show (**Switch camera**: same connection, sound unaffected).

In every mode guests only need a browser: they open the invite link, type their name, check their camera and mic,
and ask to join. You **Let in**, then **Put on air** (their camera fills the next guest slot and their voice goes
into the mix), **Take off air**, **Mute** or **Remove**. Green room chat runs over LiveKit data messages and never
reaches viewers. Guest scenes added on first open: Conversation, Panel, Screen with guests.

When connections break:
- **A guest or camera drops** (Wi-Fi blip, phone locked, page reloaded): the page rejoins by itself with the same
  pass, and Framecast keeps their place for three minutes. An on-air guest's tile goes to the next guest meanwhile;
  they go back on air in the tile they had, still muted if you muted them, and a camera gets its sound setting and
  red on-air frame back.
- **Leave**: the guest or camera is gone at once (no three-minute place), and joining again is a fresh knock.
- **Remove**: their pass stops working. A removed guest or camera that reloads is told "The host removed you or
  didn't let you in" instead of knocking again. A page whose place Framecast let go (it slept past a minute while
  waiting, or the room or Framecast restarted) knocks again by itself.
- **Framecast loses the room** (LiveKit Cloud and the Mac's internet goes away longer than LiveKit's own retries):
  it keeps reconnecting to the same room with the same links, and guests who rejoined meanwhile are found again.

## This Mac only

1. **LiveKit server** (open source, `brew install livekit`). Framecast starts it when you open the guest room:
   signalling on `127.0.0.1:7880`, media on UDP `127.0.0.1:7882`, ICE/TCP and TURN off. The API secret is random
   per session and passed through the environment; it is never written to disk. When Framecast quits it stops the
   server (and kills a leftover one from a crash on the next start).
2. **Guest page** served by Framecast on `127.0.0.1:8090` (`Resources/guest/index.html` with the vendored
   `livekit-client` 2.15.7, Apache-2.0).
3. **Host connection** inside Framecast (LiveKit Swift SDK 2.8.1): publishes the horizontal program at 15 fps and
   your microphone so guests see and hear the show; subscribes to guests' cameras, screens and microphones.

## People on my Wi-Fi

Same as above, plus:

- An **https** server on the Mac's private Wi-Fi address, port 8443. It serves the guest page and the join requests,
  and passes LiveKit signalling (`/rtc`) through to `127.0.0.1:7880`. Browsers only allow the camera and microphone
  on https pages (or on the same computer), which is why this is https.
- The certificate is **self-signed**, made by macOS's own `openssl` when the room first opens and kept in
  `~/Library/Application Support/Framecast/GuestServer/tls` (key readable by your user only). It's loaded into
  memory, never into a keychain, and it's remade when the Mac's address changes.
- **Guests see a warning once** ("Your connection is not private" in Chrome, "This Connection Is Not Private" in
  Safari). They choose Advanced / Show Details, then continue to the address. That's expected: no public
  authority can vouch for an address on your own network.
- **Video and sound go over a TCP connection the device opens**, to port **7884** on the Wi-Fi address. Framecast
  passes it to LiveKit's TURN relay (plain TCP on 7883, on loopback in practice), and the relay talks to LiveKit's
  media on `127.0.0.1:7882`. The pages point LiveKit's TURN entry (with the device's own credentials) at 7884 and
  use only the relay. LiveKit's media is never on the Wi-Fi address.
- Why: macOS's **Local Network permission** stops Framecast, and the LiveKit server it starts, from sending to
  other devices on the Wi-Fi, and its answer isn't saved for Framecast. Seen on 2026-11-01 with a real phone on
  home Wi-Fi: the page and the knock worked (connections the phone opened), but LiveKit's socket on the Wi-Fi
  address received the phone's packets and sent 0 bytes; clicking Allow helped only the server already running,
  and switching Framecast on in System Settings changed nothing. A socket on the Wi-Fi address sent nothing even
  to the Mac's own address, while loopback sockets worked. Answering connections a device opened is never
  blocked, so the relay works without the permission. It also gets through Wi-Fi networks that block UDP between
  devices (common in offices), which the old TCP 7881 fallback was for; that's gone.
- The relay serves only devices that were let in (TURN credentials signed with the room's own secret, made fresh
  each time the room opens), and relays only to `127.0.0.1` (LiveKit refuses private addresses by default; that's
  the one exception). LiveKit's relay port listens on every network of the Mac; relayed UDP uses ports
  30000–30099. Everything else listens on the Wi-Fi address or loopback only; if the Mac's own address is public
  (no router in between), Wi-Fi mode refuses to open.
- Anyone on the same Wi-Fi can open the page, so keep **Ask before letting guests in** on (the default) on shared
  networks. If the macOS firewall is on, allow incoming connections for Framecast and `livekit-server` when asked.
- Guest networks that isolate devices from each other (common in offices, hotels and cafés) block this mode.

## Anyone with a link (LiveKit Cloud)

Nothing runs on your Mac except Framecast itself. Your own LiveKit Cloud project carries the video, and your own
copy of the guest page is on a static web host. Each invite link holds a LiveKit token that can only knock: the
guest joins a waiting state, asks to join over a LiveKit data message, and Framecast lets them in with a fresh
token for a new identity, so a forwarded or reused link can't take their place. Each link lets **one person** in;
a new link appears in the panel as soon as one is used. A guest let in who reloads (or misses the admission) can
knock again with the same link and is let back in. The token sits after the `#` in the link, which browsers
never send to the web host.

### Set-up (once)

1. **LiveKit Cloud project.** Sign up at cloud.livekit.io (free plan; you create the account, Framecast never
   does) and create a project. In the project's settings, create an API key. Copy three values:
   - the project URL, `wss://<your-project>.livekit.cloud`
   - the API key (starts with `API`)
   - the API secret (shown once when the key is created)
2. **Host the guest page.** Run `./scripts/export_guest_page.sh`. It writes `build/guest-page/` (the page, the
   LiveKit client library, its licence, and a `_headers` file). Put that folder on any static host that serves
   https, for example Cloudflare Pages (upload the folder directly), Netlify or GitHub Pages. Note its address,
   e.g. `https://your-guest-page.pages.dev/`. The folder contains no keys.
3. **Write a `.env` file** with these four lines (the repository ignores `.env`, so it is never committed):

   ```
   LIVEKIT_URL=wss://your-project.livekit.cloud
   LIVEKIT_API_KEY=APIxxxxxxxxxxxx
   LIVEKIT_API_SECRET=your-secret
   GUEST_PAGE_URL=https://your-guest-page.pages.dev/
   ```

4. **Load it into Framecast.** Guests tab › Who can join › **Anyone with a link (LiveKit Cloud)** ›
   **Load .env file…** and pick the file. Framecast keeps the URL, key and page address in its preferences and the
   secret in your login Keychain (service "Framecast guest server"); the panel shows the two host names. After
   that you can delete the `.env` file.

Then open the guest room, copy the link and send it to one guest; copy the next link for the next guest.

- The first time a LiveKit Cloud room opens, macOS may ask whether Framecast can use the secret in your Keychain.
  Choose **Always Allow**. (Each new build of Framecast can ask once more.)
- If you update Framecast, run `./scripts/export_guest_page.sh` again and upload the new `build/guest-page` folder,
  so the hosted page matches the app.
- If the hosted page shows an error (Cloudflare "522" for example), open the project in your host's dashboard and
  check that the latest deployment finished and that the address matches `GUEST_PAGE_URL`.

## Verification

See VERIFICATION.md V36–V40. Wi-Fi mode and the remote-guest flow were tested on this Mac with a headless Chrome
guest; the remote flow also through a real LiveKit Cloud project (V39) with the guest page on Cloudflare Pages
(V40). Not yet tested: a guest on another device or network, and Safari's certificate warning in Wi-Fi mode.
