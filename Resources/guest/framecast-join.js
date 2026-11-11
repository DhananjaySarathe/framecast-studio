// What the guest page (index.html) and the camera page (camera.html) share: the Wi-Fi relay, telling the Mac what
// happened, this tab's pass, waiting for the host, choosing a camera, swapping tracks without losing the slot,
// keeping the screen on, and whether a dropped connection joins again. Loaded right after livekit-client.umd.js.
(() => {
  const LK = window.LivekitClient;
  const FJ = window.FJ = {
    // Framecast's TCP relay port from /api/room (Wi-Fi rooms); 0 when served on this Mac only or from a static host.
    relayPort: 0,
    // Phones and tablets get Front / Back instead of camera names (an iPad asks for desktop pages, but has touch).
    isPhone: /iPhone|iPad|Android/i.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1),
  };
  const sleep = FJ.sleep = (ms) => new Promise(r => setTimeout(r, ms));

  // Video to the Mac goes over a TCP connection this device opens, through Framecast's relay port (Wi-Fi rooms):
  // macOS can stop the Mac from sending to devices on the Wi-Fi, but not from answering a connection they opened.
  // LiveKit's TURN entry (with this device's own credentials) is pointed there and only the relay is used; the
  // public STUN servers LiveKit lists aren't needed on the Wi-Fi and are left out.
  const Native = window.RTCPeerConnection;
  if (Native) {
    let lastTurn = null;
    const relayed = (cfg) => {
      if (!FJ.relayPort || !cfg) return cfg;
      const turn = (cfg.iceServers || []).find(s => [].concat(s.urls || []).some(u => /^turns?:/.test(u))) || lastTurn;
      if (!turn) return cfg;
      lastTurn = turn;
      return { ...cfg, iceTransportPolicy: 'relay',
               iceServers: [{ ...turn, urls: ['turn:' + location.hostname + ':' + FJ.relayPort + '?transport=tcp'] }] };
    };
    function Relayed(cfg, ...rest) { return new Native(relayed(cfg), ...rest); }
    Relayed.prototype = Native.prototype;
    Object.setPrototypeOf(Relayed, Native);
    window.RTCPeerConnection = Relayed;
    // LiveKit's resume (a Wi-Fi blip, the phone locked for a moment) gives both connections the server's own list
    // again (turns:<Mac>:443, where nothing listens, and no relay-only rule) before restarting ICE: keep the relay.
    const set = Native.prototype.setConfiguration;
    if (set) Native.prototype.setConfiguration = function (cfg) { return set.call(this, relayed(cfg)); };
  }

  // JSON from Framecast's join API. A request that gets no answer (the Wi-Fi went away) gives up after `ms`.
  FJ.api = async (path, body, ms = 15000) => {
    const stop = typeof AbortController === 'function' ? new AbortController() : null;
    const timer = stop && setTimeout(() => stop.abort(), ms);
    const init = body ? { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) } : {};
    try {
      const r = await fetch(path, { ...init, signal: stop ? stop.signal : undefined });
      if (!r.ok) throw new Error((await r.text()) || r.statusText);
      return await r.json();
    } catch (e) {
      throw e.name === 'AbortError' ? new Error('No answer from Framecast on the Mac.') : e;
    } finally { clearTimeout(timer); }
  };

  // Who the page is, for reports: { remote, ticket: () => …, name: () => … }.
  let ctx = { remote: false, ticket: () => null, name: () => '' };
  FJ.setContext = (c) => { ctx = { ...ctx, ...c }; };

  // Tells the Mac what happened on this page (shown in Framecast's Guests and Angles tabs and kept in its log).
  FJ.report = (event, detail) => {
    if (ctx.remote) return;
    fetch('/api/log', { method: 'POST', headers: { 'content-type': 'application/json' }, keepalive: true,
      body: JSON.stringify({ ticket: ctx.ticket(), name: ctx.name(), event, detail: String(detail || '').slice(0, 300),
                             ua: navigator.userAgent.slice(0, 160), page: /\/camera\//.test(location.pathname) ? 'camera' : 'guest' }) }).catch(() => {});
  };

  // This tab's pass, kept across a retry or a reload so the page doesn't ask the host (and take a place) again.
  const key = (k) => 'framecast-ticket:' + k;
  FJ.loadTicket = (k) => { try { return sessionStorage.getItem(key(k)); } catch (e) { return null; } };
  FJ.saveTicket = (k, t) => { try { if (t) sessionStorage.setItem(key(k), t); else sessionStorage.removeItem(key(k)); } catch (e) {} };

  // Asks the Mac about a pass every second until the host decides, and resolves with that answer: 'admitted' with
  // the token, 'denied' when the host refused or removed it, or 'gone' for a pass the Mac no longer knows (from
  // before a reload or a restart, or dropped from the waiting list while the page stopped asking), which the page
  // replaces with a new knock. A failed request (Wi-Fi blip, the phone locked) is tried again with the same pass,
  // more slowly; after about 5 minutes without an answer it resolves null. Timers stop while a phone is locked, so
  // giving up needs both the time and a number of failed requests.
  FJ.waitForHost = async (ticket, { waiting, trouble } = {}) => {
    let fails = 0, since = 0;
    for (;;) {
      let t;
      try { t = await FJ.api('/api/ticket?id=' + encodeURIComponent(ticket), null, 10000); }
      catch (e) {
        if (!fails++) { since = Date.now(); FJ.report('poll-failed', e.message); }
        if (fails >= 20 && Date.now() - since > 300000) return null;
        if (trouble) trouble(e);
        await sleep(Math.min(5000, 1000 * fails));
        continue;
      }
      fails = 0;
      if (t.state !== 'waiting') return t;
      if (waiting) waiting();
      await sleep(1000);
    }
  };

  // Runs camera and microphone changes one at a time, in order: two camera requests at once fight on phones, and
  // two publishes at once send two cameras. A queued step must not wait for another queued step.
  FJ.queue = () => {
    let last = Promise.resolve();
    return (f) => { const run = last.then(f); last = run.catch(() => {}); return run; };
  };

  // The cameras this browser can open (ids are empty until the page was allowed to use one).
  FJ.cameras = async () => (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput' && d.deviceId);

  // The camera for a choice: a camera's id as it is, or for "Back"/"Front" the camera named so (Android: "camera2 0,
  // facing back", iPhone: "Back Camera"); with no direction in the names, at least a camera other than the current one.
  FJ.cameraId = async (choice, currentId) => {
    if (choice && choice !== 'user' && choice !== 'environment') return choice;
    const cams = await FJ.cameras();
    const want = choice === 'user' ? /front|user|face|selfie/i : /back|rear|environment|world/i;
    const named = cams.filter(c => want.test(c.label));
    if (named.length) return (named.find(c => /^(back|front) camera$/i.test(c.label.trim())) || named[0]).deviceId;
    if (currentId) return cams.find(c => c.deviceId !== currentId)?.deviceId || '';
    return '';
  };

  // This page's publication of that name ('camera', 'microphone') in a room.
  FJ.published = (room, name) => room ? [...room.localParticipant.trackPublications.values()].find(p => p.trackName === name) : undefined;

  // Puts a new camera or microphone on a publication the Mac already has, so it keeps the slot (nothing is
  // unpublished). LiveKit mutes a publication whose track ended and sets enabled = !muted on the new track, so the
  // publication is unmuted and the track put back on or off as the page's own buttons say.
  FJ.swapTrack = async (pub, track, on = true) => {
    if (pub.track && pub.track.mediaStreamTrack !== track) await pub.track.replaceTrack(track);
    if (pub.isMuted && track.readyState === 'live') await pub.unmute();
    track.enabled = on;
  };

  // Phones dim and lock after a while. While it's wanted, the page asks to keep the screen on, again each time it
  // comes back to the front (the browser lets go of it when the page is hidden).
  let awake = false, lock = null;
  FJ.keepAwake = async (on = true) => {
    awake = on;
    if (!on) { try { await lock?.release(); } catch (e) {} lock = null; return; }
    if (lock && !lock.released) return;
    try { lock = await navigator.wakeLock?.request('screen'); } catch (e) {}
  };
  document.addEventListener('visibilitychange', () => { if (awake && document.visibilityState === 'visible') FJ.keepAwake(); });

  // Whether a disconnect is for good: a leave the person asked for (Leave, or the host removing them), the server
  // removing them, a newer copy of this pass taking over, or the room closing. LiveKit also says CLIENT_INITIATED
  // when the browser hides or freezes the page; that one joins again like any other drop.
  FJ.isFinal = (reason, leftOnPurpose) => !!leftOnPurpose || [LK.DisconnectReason.DUPLICATE_IDENTITY,
    LK.DisconnectReason.PARTICIPANT_REMOVED, LK.DisconnectReason.ROOM_DELETED].includes(reason);

  // Joins again with the same pass every 3 s for a few minutes (the Mac keeps a dropped place for 3), until it works
  // or stop() says to stay out. Resolves the connected room, or null. A refused pass (the show was closed and opened
  // again) ends it at once: reloading the page asks the host again. An attempt the server ends while it connects (the
  // host removed them meanwhile) is given up at once instead of waiting ~15 s for LiveKit's own timeout; the page's
  // Disconnected handler sees that attempt's reason first and, if it's for good, makes stop() say so.
  FJ.connectAgain = async (makeRoom, joined, options, stop, attempt) => {
    for (let i = 1; i <= 60 && !stop(); i++) {
      if (attempt) attempt(i);
      await sleep(3000);
      if (stop()) break;
      const r = makeRoom();
      let pending = true, giveUp;
      const ended = new Promise((_, no) => { giveUp = no; });
      // A turn later, so a failed connect's own error (with its status) wins over this one.
      r.on(LK.RoomEvent.Disconnected, () => { if (pending) setTimeout(() => { r.disconnect(); giveUp(new Error('The server ended this attempt.')); }, 0); });
      try { await Promise.race([r.connect(joined.url, joined.token, options), ended]); pending = false; return r; }
      catch (e) { pending = false; r.disconnect(); if (e && e.status === 401) break; }
    }
    return null;
  };

  // Pressed Leave: tells the Mac before the page forgets its pass, so the place is let go at once (not kept for a
  // rejoin). Served by Framecast that's a report, which outlives the reload (fetch keepalive); through LiveKit Cloud,
  // where reports don't go, a message to the host, given 2 s at most. publishData resolves once the message is in the
  // data channel's buffer, not once it's sent, so it gets 300 ms more before the disconnect closes the channel.
  FJ.leaving = async (room) => {
    FJ.report('leaving', 'pressed Leave');
    if (!ctx.remote || !room || room.state === 'disconnected') return;
    const left = new TextEncoder().encode(JSON.stringify({ type: 'left' }));
    try {
      const sent = room.localParticipant.publishData(left, { reliable: true, topic: 'left', destinationIdentities: ['host'] });
      await Promise.race([sent.then(() => sleep(300)), sleep(2000)]);
    } catch (e) {}
  };
})();
