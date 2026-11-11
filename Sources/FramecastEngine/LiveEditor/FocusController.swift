import Foundation
import CoreGraphics

/// Whether the live editor may move the picture: never, only while not live (rehearsing), or always.
public enum CameraMoves: String, Codable, Sendable, CaseIterable {
    case off, rehearse, on
    public var title: String { switch self { case .off: "Off"; case .rehearse: "Rehearse"; case .on: "On" } }
}

public enum MoveIntensity: String, Codable, Sendable, CaseIterable {
    case subtle, moderate, lively
    public var title: String { rawValue.capitalized }
    var click: Double { switch self { case .subtle: 1.4; case .moderate: 1.6; case .lively: 2.0 } }
    var navigate: Double { switch self { case .subtle: 1.3; case .moderate: 1.5; case .lively: 1.8 } }
    /// How much more a 9:16 screen that already fills its frame tightens on a click.
    var followClick: Double { switch self { case .subtle: 1.12; case .moderate: 1.2; case .lively: 1.28 } }
    /// Seconds for zoom and region changes to settle (no overshoot).
    var zoomResponse: Double { switch self { case .subtle: 0.9; case .moderate: 0.75; case .lively: 0.6 } }
}

/// The screen auto-zoom: turns clicks and cursor movement into a camera per screen layer and canvas. Producers
/// (the pointer monitor) call in from any thread; the render queue asks for a view once per layer per frame.
/// Moves follow fixed rules (no model): zoom in on a click, follow the cursor with a dead zone, go back to the
/// whole screen after a quiet spell, an app switch, a password field or the reset key.
public final class FocusController: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        public var moves: CameraMoves = .off
        /// Streaming (or about to): Rehearse keeps the picture still.
        public var isLive = false
        public var intensity: MoveIntensity = .moderate
        public var idleSeconds = 5.0
        /// The most a source may be shown enlarged (canvas pixels per source pixel).
        public var maxEnlargement = 1.25
        public init() {}
        public var allowsMoves: Bool { moves == .on || (moves == .rehearse && !isLive) }
    }

    enum Level: String { case overview, click, navigate }
    enum Event {
        case click(CGPoint)                 // desktop point, already checked against windows that must not zoom
        case activity(CGPoint)              // the cursor moved (it only keeps a zoom alive on its own screen)
        case home                           // app switch: back to the whole screen
        case reset(pause: Double)           // the reset key: back to the whole screen and stay there a while
        case secure(Bool)                   // a password field has the keyboard
    }
    struct Timed { var t: Double; var seq: Int; var event: Event }
    /// One change of what a source's shot should be, from a given time.
    struct Change { var t: Double; var level: Level; var at: CGPoint?; var reason: String }

    /// Per screen source: the level it's at and when that changed (shared by both canvases).
    struct Shot {
        var seen = 0                         // events already applied
        var until = 0.0                      // time the state is worked out to
        var level: Level = .overview
        var at: CGPoint?                     // raw source point the zoom centres on
        var lastActivity = -1e9
        var lastClick: (t: Double, p: CGPoint)?
        var lastOut = -1e9                   // last time it went back to the whole screen
        var pausedUntil = 0.0
        var secure = false
        var pendingIn: Change?
        var changes: [Change] = [Change(t: -1e9, level: .overview, at: nil, reason: "start")]
    }
    /// Per screen layer camera, keyed by source and canvas.
    struct Cam {
        var cx: Spring, cy: Spring, z: Spring
        var lastT: Double
        var lastSeen: Double
        var target: Viewport
        var regionUntil = 0.0                // after a zoom change the centre moves at the slow region speed
        var appliedChange = -1e9
        var reason = "start"
    }
    struct CamKey: Hashable { var source: UUID; var canvas: CanvasKind }

    private let lock = NSLock()
    private var config = Config()
    private var events: [Timed] = []
    private var seq = 0
    private var cursor: [(t: Double, p: CGPoint)] = []
    private var lastActivityMark = -1e9
    private var activityAnchor: CGPoint?
    // The latest password-field and reset-pause state, for shots that start after their events left the log.
    private var secureNow = false
    private var pauseUntilNow = 0.0
    /// When each layer was last drawn still (today's framing), so moves switched back on glide in instead of jumping.
    private var stillAt: [CamKey: Double] = [:]
    private var ignored: [CGRect] = []        // desktop areas where panning freezes (Framecast, the Dock, the menu bar)
    private var denied: [CGRect] = []         // windows of apps that must never be magnified
    private var shots: [UUID: Shot] = [:]
    private var cams: [CamKey: Cam] = [:]
    private var clicks = 0
    private var trace: FocusTrace?

    public init() {}

    // MARK: Inputs (any thread)

    public func setConfig(_ c: Config) { lock.lock(); config = c; lock.unlock() }
    public var currentConfig: Config { lock.lock(); defer { lock.unlock() }; return config }

    public func cursor(_ p: CGPoint, at t: Double) {
        lock.lock(); defer { lock.unlock() }
        // Movement adds up from the last mark, so slow, steady tracing counts too.
        if let a = activityAnchor {
            if hypot(a.x - p.x, a.y - p.y) > 3, t - lastActivityMark > 0.1 { lastActivityMark = t; activityAnchor = p; append(.activity(p), t) }
        } else { activityAnchor = p }
        cursor.append((t, p))
        if cursor.count > 600 { cursor.removeFirst(cursor.count - 400) }
    }
    public func click(_ p: CGPoint, at t: Double) {
        lock.lock(); clicks += 1; append(.click(p), t); trace?.add(["t": t, "event": "click", "x": p.x, "y": p.y]); lock.unlock()
    }
    /// An app came to the front without a click (⌘-Tab): back to the whole screen.
    public func appSwitched(at t: Double) {
        lock.lock(); defer { lock.unlock() }
        let clickedJustNow = events.contains { if case .click = $0.event { return t - $0.t < 1 && t >= $0.t } else { return false } }
        if !clickedJustNow { append(.home, t) }
    }
    public func resetAndPause(seconds: Double, at t: Double) {
        lock.lock(); pauseUntilNow = max(pauseUntilNow, t + seconds); append(.reset(pause: seconds), t); lock.unlock()
    }
    public func secureInput(_ on: Bool, at t: Double) { lock.lock(); secureNow = on; append(.secure(on), t); lock.unlock() }
    public func setAreas(ignored: [CGRect], denied: [CGRect]) { lock.lock(); self.ignored = ignored; self.denied = denied; lock.unlock() }

    private func append(_ e: Event, _ t: Double) {
        seq += 1
        events.append(Timed(t: t, seq: seq, event: e))
        if events.count > 400 { events.removeFirst(events.count - 300) }
    }

    // MARK: Render queue

    /// The view for a screen layer at render time `t`, or nil to draw it exactly as today. `hold`: a transition or a
    /// switch a moment ago, so targets stay where they are. `slow`: the budget governor asks for calmer moves.
    public func viewport(source: UUID, canvas: CanvasKind, screen: ScreenGeometry, layer: LayerGeometry, at t: Double,
                         hold: Bool, tier: BudgetTier) -> Viewport? {
        lock.lock(); defer { lock.unlock() }
        let cfg = config
        let moving = cfg.allowsMoves && tier < .off
        var shot = shots[source] ?? Shot()
        advance(&shot, to: t, screen: screen, cfg: cfg)
        shots[source] = shot

        let key = CamKey(source: source, canvas: canvas)
        // Going live in Rehearse: back to today's framing at once, before the stream starts, rather than easing out on air.
        if !moving && cfg.moves == .rehearse && cfg.isLive { cams[key] = nil; stillAt[key] = t; return nil }
        // Follow: a screen much narrower than its frame (the 9:16 canvas) fills it as a slice that follows the cursor.
        // A password field or the reset pause takes it back to today's framing too.
        let follow = layer.fillZoom > 1.5
        let calm = shot.secure || t < shot.pausedUntil
        let zMax = layer.maxZoom(enlargement: cfg.maxEnlargement)
        let base = moving && follow && !calm ? min(layer.fillZoom, zMax) : 1
        var cam: Cam
        if let c = cams[key], t - c.lastSeen < 0.5 { cam = c }
        else {
            // New on air (or back after a while): start where the shot is, with no move, unless the layer was drawn as
            // today a moment ago (moves just switched on), in which case it glides in from there.
            guard moving else { stillAt[key] = t; return nil }
            let wasStill = stillAt[key].map { t - $0 < 0.5 } ?? false
            var start = Viewport.identity
            if !wasStill && base > 1.0001 {
                let c = layer.clamp(cursorPoint(at: t, screen: screen, layer: layer) ?? CGPoint(x: 0.5, y: 0.5), zoom: base)
                start = avoidDenied(Viewport(cx: c.x, cy: c.y, zoom: base), screen: screen, layer: layer) ?? .identity
            }
            // Steps fall on one absolute grid, so a view depends only on the time it's drawn for, not on timer jitter.
            cam = Cam(cx: Spring(start.cx), cy: Spring(start.cy), z: Spring(start.zoom), lastT: (t / Spring.step).rounded(.down) * Spring.step,
                      lastSeen: t, target: start)
        }
        cam.lastSeen = t
        let slow = tier >= .minimal ? 1.5 : 1
        let zoomResponse = cfg.intensity.zoomResponse * slow, panResponse = 0.35 * slow
        while cam.lastT + Spring.step <= t {
            let ts = cam.lastT + Spring.step
            // Holding keeps a target only while it's safe: a password field or a never-zoom window under it ends the hold.
            let unsafe = shot.secure || (cam.target.zoom > 1.0001 && touchesDenied(cam.target, screen: screen, layer: layer))
            if !hold || unsafe { cam.target = target(for: &cam, shot: shot, at: ts, screen: screen, layer: layer, base: base, zMax: zMax,
                                                     moving: moving, follow: follow, cfg: cfg) }
            let r = ts < cam.regionUntil ? zoomResponse : panResponse
            cam.cx.step(toward: cam.target.cx, response: r, damping: 0.9)
            cam.cy.step(toward: cam.target.cy, response: r, damping: 0.9)
            cam.z.step(toward: cam.target.zoom, response: zoomResponse)
            cam.lastT = ts
        }
        let dt = t - cam.lastT
        var vp = Viewport(cx: cam.cx.ahead(dt), cy: cam.cy.ahead(dt), zoom: min(max(1, cam.z.ahead(dt)), max(zMax, 1)))
        let c = layer.clamp(CGPoint(x: vp.cx, y: vp.cy), zoom: vp.zoom)
        vp.cx = c.x; vp.cy = c.y
        // What's drawn must never show a never-zoom window magnified, even halfway through a glide: cut to the target,
        // which is already clear of them.
        if vp.zoom > 1.0001 && touchesDenied(vp, screen: screen, layer: layer) {
            let s = cam.target
            cam.cx = Spring(s.cx); cam.cy = Spring(s.cy); cam.z = Spring(s.zoom)
            vp = s
            cam.reason = "kept off a private window"
        }
        let resting = abs(vp.zoom - 1) < 0.002 && cam.z.isAtRest && cam.cx.isAtRest && cam.cy.isAtRest
        if let trace {
            let seen = layer.visible(zoom: vp.zoom), p = cursorPoint(at: t, screen: screen, layer: layer)
            trace.add(["t": t, "canvas": canvas.rawValue, "source": String(source.uuidString.prefix(8)), "cx": vp.cx, "cy": vp.cy,
                       "zoom": vp.zoom, "vz": cam.z.velocity, "zmax": zMax, "base": base, "vw": seen.width, "vh": seen.height,
                       "px": p?.x ?? -1, "py": p?.y ?? -1, "level": shot.level.rawValue, "reason": cam.reason, "hold": hold, "tier": tier.rawValue])
        }
        if !moving && resting { cams[key] = nil; stillAt[key] = t; return nil }
        cams[key] = cam
        return vp
    }

    /// Applies new events to a source's shot in time order, and the quiet-spell timeout, up to `t`.
    private func advance(_ s: inout Shot, to t: Double, screen: ScreenGeometry, cfg: Config) {
        // A shot that missed events which have since left the log (a new one, or one off air for long) starts from
        // the latest password-field and pause state.
        if let first = events.first, first.seq > s.seen + 1 {
            s.secure = secureNow; s.pausedUntil = max(s.pausedUntil, pauseUntilNow)
            if secureNow { s.pendingIn = nil; if s.level != .overview { s.level = .overview; s.at = nil
                s.changes.append(Change(t: max(t, s.changes.last?.t ?? t), level: .overview, at: nil, reason: "password field")) } }
        }
        let fresh = events.filter { $0.seq > s.seen }.sorted { $0.t < $1.t }
        if let last = events.last { s.seen = last.seq }
        func set(_ level: Level, _ at: CGPoint?, _ when: Double, _ reason: String) {
            let when = max(when, s.until, s.changes.last?.t ?? when)
            if level == .overview && s.level != .overview { s.lastOut = when }
            s.level = level; s.at = at
            s.changes.append(Change(t: when, level: level, at: at, reason: reason))
            if s.changes.count > 32 { s.changes.removeFirst(s.changes.count - 16) }
        }
        func quiet(until limit: Double) {
            if let p = s.pendingIn, p.t <= limit { s.pendingIn = nil; set(p.level, p.at, p.t, p.reason) }
            let end = s.lastActivity + cfg.idleSeconds
            if s.level != .overview, end <= limit { set(.overview, nil, end, "quiet") }
        }
        for e in fresh {
            let te = max(e.t, s.until)
            quiet(until: te)
            switch e.event {
            case .activity(let p):
                if screen.normalized(p) != nil { s.lastActivity = te }
            case .click(let p):
                guard let n = screen.normalized(p) else { break }
                s.lastActivity = te
                guard !s.secure, te >= s.pausedUntil else { break }
                let navigating = s.lastClick.map { te - $0.t < 2 && hypot($0.p.x - n.x, $0.p.y - n.y) < 0.5 } ?? false
                s.lastClick = (te, n)
                let level: Level = navigating ? .navigate : .click
                if s.level == .overview && te - s.lastOut < 2.5 {
                    // At least 2.5 s between zooming out and in again.
                    s.pendingIn = Change(t: s.lastOut + 2.5, level: level, at: n, reason: "click (held back)")
                } else {
                    s.pendingIn = nil
                    set(level, n, te, navigating ? "navigating" : "click")
                }
            case .home:
                s.pendingIn = nil
                if s.level != .overview { set(.overview, nil, te, "app switch") }
            case .reset(let pause):
                s.pendingIn = nil; s.pausedUntil = te + pause
                set(.overview, nil, te, "reset")
            case .secure(let on):
                s.secure = on
                if on { s.pendingIn = nil; if s.level != .overview { set(.overview, nil, te, "password field") } }
            }
            s.until = te
        }
        quiet(until: t)
        s.until = max(s.until, t)
    }

    private func change(_ s: Shot, at t: Double) -> Change {
        s.changes.last { $0.t <= t } ?? s.changes[0]
    }

    private func cursorPoint(at t: Double, screen: ScreenGeometry, layer: LayerGeometry) -> CGPoint? {
        guard let p = (cursor.last { $0.t <= t } ?? cursor.last)?.p, let n = screen.normalized(p) else { return nil }
        return layer.picturePoint(n)
    }

    /// What one camera aims at for step time `t`.
    private func target(for cam: inout Cam, shot: Shot, at t: Double, screen: ScreenGeometry, layer: LayerGeometry,
                        base: Double, zMax: Double, moving: Bool, follow: Bool, cfg: Config) -> Viewport {
        guard moving else { cam.reason = "still"; return .identity }
        var ch = change(shot, at: t)
        // A click this layer crops away doesn't zoom it.
        if ch.level != .overview, let at = ch.at, layer.picturePoint(at) == nil { ch.level = .overview; ch.at = nil }
        var zoom = base
        switch ch.level {
        case .overview: break
        case .click: zoom = base * (follow ? cfg.intensity.followClick : cfg.intensity.click)
        case .navigate: zoom = base * (follow ? cfg.intensity.followClick : cfg.intensity.navigate)
        }
        zoom = min(zoom, zMax)
        if ch.t != cam.appliedChange {
            cam.appliedChange = ch.t
            cam.regionUntil = t + cfg.intensity.zoomResponse
            cam.reason = ch.reason
            if let at = ch.at, let p = layer.picturePoint(at) { cam.target = Viewport(cx: p.x, cy: p.y, zoom: zoom) }
            else if zoom <= 1.0001 { cam.target = Viewport(cx: 0.5, cy: 0.5, zoom: 1) }
        }
        var c = CGPoint(x: cam.target.cx, y: cam.target.cy)
        if zoom <= 1.0001 && !follow {
            c = CGPoint(x: 0.5, y: 0.5)
        } else if let p = cursorPoint(at: t, screen: screen, layer: layer), !isIgnored(at: t, screen: screen) {
            // Dead zone: the cursor moves freely in the middle 75 % of the view; past it the view follows, leaving
            // it 15 % inside the edge so the camera doesn't flip back and forth.
            let v = layer.visible(zoom: zoom)
            let sx = v.width * 0.375, sy = v.height * 0.375
            if abs(p.x - c.x) > sx { c.x = p.x - (p.x > c.x ? 1 : -1) * sx * 0.85 }
            if abs(p.y - c.y) > sy { c.y = p.y - (p.y > c.y ? 1 : -1) * sy * 0.85 }
        }
        c = layer.clamp(c, zoom: zoom)
        var vp = Viewport(cx: c.x, cy: c.y, zoom: zoom)
        if zoom > 1.0001, let safe = avoidDenied(vp, screen: screen, layer: layer) { vp = safe }
        else if zoom > 1.0001 && touchesDenied(vp, screen: screen, layer: layer) { vp = .identity; cam.reason = "kept off a private window" }
        return vp
    }

    private func isIgnored(at t: Double, screen: ScreenGeometry) -> Bool {
        guard let p = (cursor.last { $0.t <= t } ?? cursor.last)?.p else { return false }
        return ignored.contains { $0.contains(p) }
    }

    private func deniedRects(_ screen: ScreenGeometry, _ layer: LayerGeometry) -> [CGRect] {
        denied.compactMap { layer.pictureRect(screen.normalized($0)) }
    }
    private func touchesDenied(_ vp: Viewport, screen: ScreenGeometry, layer: LayerGeometry) -> Bool {
        let view = layer.viewRect(vp)
        return deniedRects(screen, layer).contains { $0.intersects(view) }
    }
    /// Nudges a zoomed view sideways or up/down so it no longer shows a private window, if one small move does it.
    private func avoidDenied(_ vp: Viewport, screen: ScreenGeometry, layer: LayerGeometry) -> Viewport? {
        let rects = deniedRects(screen, layer)
        let view = layer.viewRect(vp)
        guard let hit = rects.first(where: { $0.intersects(view) }) else { return vp }
        let v = layer.visible(zoom: vp.zoom)
        let tries = [CGPoint(x: hit.minX - v.width / 2 - 0.001, y: vp.cy), CGPoint(x: hit.maxX + v.width / 2 + 0.001, y: vp.cy),
                     CGPoint(x: vp.cx, y: hit.minY - v.height / 2 - 0.001), CGPoint(x: vp.cx, y: hit.maxY + v.height / 2 + 0.001)]
        let original = CGPoint(x: vp.cx, y: vp.cy)
        let ok = tries.map { layer.clamp($0, zoom: vp.zoom) }
            .map { Viewport(cx: $0.x, cy: $0.y, zoom: vp.zoom) }
            .filter { cand in !rects.contains { $0.intersects(layer.viewRect(cand)) } && layer.viewRect(cand).contains(original) }
            .min { hypot($0.cx - vp.cx, $0.cy - vp.cy) < hypot($1.cx - vp.cx, $1.cy - vp.cy) }
        return ok
    }

    // MARK: Tests and the HUD

    public struct State: Codable, Sendable {
        public var config: String
        public var sources: [String: String]
        public var cameras: [String: [Double]]
        public var clicks: Int
        public var cursor: [Double]
    }
    public func state() -> State {
        lock.lock(); defer { lock.unlock() }
        let c = config
        return State(config: "moves=\(c.moves.rawValue) live=\(c.isLive) intensity=\(c.intensity.rawValue) idle=\(c.idleSeconds)",
                     sources: Dictionary(uniqueKeysWithValues: shots.map { ($0.key.uuidString, "\($0.value.level.rawValue) at=\($0.value.at.map { "\($0.x),\($0.y)" } ?? "-") secure=\($0.value.secure)") }),
                     cameras: Dictionary(uniqueKeysWithValues: cams.map { ("\($0.key.source.uuidString)/\($0.key.canvas.rawValue)", [$0.value.cx.value, $0.value.cy.value, $0.value.z.value, $0.value.target.cx, $0.value.target.cy, $0.value.target.zoom]) }),
                     clicks: clicks,
                     cursor: cursor.last.map { [$0.t, $0.p.x, $0.p.y] } ?? [])
    }
    /// The level each source is at right now (for the HUD): the most zoomed one wins.
    public var summary: String {
        lock.lock(); defer { lock.unlock() }
        if !config.allowsMoves { return config.moves == .off ? "off" : "still (live)" }
        let levels = shots.values.map(\.level)
        if levels.contains(.click) { return "zoomed in" }
        if levels.contains(.navigate) { return "following" }
        return "whole screen"
    }

    public func startTrace(to url: URL) { lock.lock(); trace = FocusTrace(url: url); lock.unlock() }
    public func stopTrace() { lock.lock(); trace?.close(); trace = nil; lock.unlock() }
    func traceTick(_ fields: [String: Any]) { lock.lock(); trace?.add(fields); lock.unlock() }
}

/// A JSON line per camera per frame (debug only), written off the render queue.
final class FocusTrace: @unchecked Sendable {
    private let handle: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "framecast.focus.trace", qos: .utility)
    private var lastFlush = 0.0
    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }
    func add(_ fields: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        buffer.append(d); buffer.append(0x0A)
        let now = HostClock.seconds()
        if now - lastFlush > 0.5 || buffer.count > 256_000 { flush(); lastFlush = now }
    }
    private func flush() {
        let d = buffer; buffer = Data()
        queue.async { [handle] in handle?.write(d) }
    }
    func close() { flush(); queue.sync { try? handle?.close() } }
}
