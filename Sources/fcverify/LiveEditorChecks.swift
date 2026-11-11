import Foundation
import CoreImage
import FramecastEngine

/// `fcverify live-editor`: the screen auto-zoom's rules, checked without capture or permissions. Each line prints
/// PASS or FAIL; the process fails if any check does.
func liveEditorChecks() -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(name)\(detail.isEmpty ? "" : ": \(detail)") → \(ok ? "PASS" : "FAIL")")
        if !ok { failures += 1 }
    }
    func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

    // Reach and sharpness on this Mac's built-in display (3024x1964 captured) and a 1080p camera.
    let screen16 = LayerGeometry(image: CGSize(width: 3024, height: 1964), frame: CGSize(width: 1920, height: 1080), fit: .fit)
    let screen9 = LayerGeometry(image: CGSize(width: 3024, height: 1964), frame: CGSize(width: 1080, height: 1920), fit: .fit)
    let camera9 = LayerGeometry(image: CGSize(width: 1920, height: 1080), frame: CGSize(width: 1080, height: 1920), fit: .fill)
    check("16:9 screen may zoom to 2.27x before it shows enlarged", near(screen16.maxZoom(enlargement: 1.25), 2.27, 0.01),
          String(format: "%.3f", screen16.maxZoom(enlargement: 1.25)))
    check("9:16 screen fills its frame at 2.74x and stays under the limit", near(screen9.fillZoom, 2.74, 0.01) && screen9.fillZoom < screen9.maxZoom(enlargement: 1.25),
          String(format: "fill %.3f, max %.3f", screen9.fillZoom, screen9.maxZoom(enlargement: 1.25)))
    check("full-frame 9:16 camera may only pan", camera9.maxZoom(enlargement: 1.25) == 1)

    // The compositor draws through a view: four coloured quadrants, zoom 2 on the top-left one.
    let comp = Compositor()
    let src = CGSize(width: 3000, height: 2000)
    func quad(_ x: Double, _ y: Double, _ c: CIColor) -> CIImage { CIImage(color: c).cropped(to: CGRect(x: x, y: y, width: 1500, height: 1000)) }
    // Core Image is bottom-left: y 1000...2000 is the top half.
    let quads = quad(0, 1000, .red).composited(over: quad(1500, 1000, .green)).composited(over: quad(0, 0, .blue)).composited(over: quad(1500, 0, .yellow))
    func pixel(_ img: CIImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var px = [UInt8](repeating: 0, count: 4)
        comp.context.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
    func draw(_ vp: Viewport?, canvas: CGSize) -> CIImage {
        let item = SceneItem(sourceID: UUID(), transform: .full, fit: .fit)
        let bg = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas))
        return comp.renderItem(item, input: LayerInput(image: quads, viewport: vp), canvas: canvas)!.composited(over: bg)
    }
    let c16 = CGSize(width: 1920, height: 1080)
    let zoomed = draw(Viewport(cx: 0.25, cy: 0.25, zoom: 2), canvas: c16)
    let mid = pixel(zoomed, 960, 540)
    check("zoom 2 on the top-left quarter shows it in the middle", mid.0 > 200 && mid.1 < 50 && mid.2 < 50, "\(mid)")
    let edge = draw(Viewport(cx: 0, cy: 0, zoom: 2), canvas: c16)
    let corner = pixel(edge, 2, 1077), far = pixel(edge, 1917, 2)
    check("a view past the edge is held inside the picture (no black)", corner.0 > 200 && far != (0, 0, 0), "top-left \(corner), bottom-right \(far)")
    let c9 = CGSize(width: 1080, height: 1920)
    let strip = draw(nil, canvas: c9), filled = draw(Viewport(cx: 0.5, cy: 0.5, zoom: LayerGeometry(image: src, frame: c9, fit: .fit).fillZoom), canvas: c9)
    check("9:16 today is a strip with black above and below", pixel(strip, 540, 1900) == (0, 0, 0))
    let top = pixel(filled, 540, 1915), bottom = pixel(filled, 540, 4)
    check("9:16 at the fill zoom has no black bars", top != (0, 0, 0) && bottom != (0, 0, 0), "top \(top), bottom \(bottom)")
    let plain = draw(nil, canvas: c16), still = draw(.identity, canvas: c16)
    check("a view at rest draws exactly as before", [(5, 5), (300, 300), (960, 540), (1700, 1000), (1915, 10)].allSatisfy { pixel(plain, $0.0, $0.1) == pixel(still, $0.0, $0.1) })

    // The controller: a click on a 1512x982 pt display shown full frame on 16:9.
    let desk = ScreenGeometry(rect: CGRect(x: 0, y: 0, width: 1512, height: 982))
    let source = UUID()
    func controller(_ moves: CameraMoves = .on) -> FocusController {
        let f = FocusController()
        var cfg = FocusController.Config(); cfg.moves = moves
        f.setConfig(cfg)
        f.cursor(CGPoint(x: 756, y: 491), at: 0)
        return f
    }
    func view(_ f: FocusController, _ t: Double, _ layer: LayerGeometry = screen16, canvas: CanvasKind = .horizontal) -> Viewport {
        f.viewport(source: source, canvas: canvas, screen: desk, layer: layer, at: t, hold: false, tier: .full) ?? .identity
    }
    let fps = 1.0 / 30
    var f = controller()
    var t = 0.0
    while t < 1 { _ = view(f, t); t += fps }
    let clickAt = (t * 30).rounded() / 30 + 0.004
    f.cursor(CGPoint(x: 378, y: 245.5), at: clickAt - 0.002)
    f.click(CGPoint(x: 378, y: 245.5), at: clickAt)
    var started: Double?
    var settled: Double?
    var samples: [(Double, Viewport)] = []
    t = clickAt - 0.004
    while t < clickAt + 3 {
        let v = view(f, t)
        samples.append((t, v))
        if started == nil && v.zoom > 1.001 { started = t }
        if settled == nil && near(v.zoom, 1.6, 0.032) { settled = t }
        t += fps
    }
    check("zoom starts within 2 frames of the click", (started ?? 99) - clickAt <= 2 * fps + 1e-6, String(format: "%.0f ms", ((started ?? 99) - clickAt) * 1000))
    check("zoom settles within 2 % of 1.6x in 0.9 s", (settled ?? 99) - clickAt <= 0.9, String(format: "%.2f s", (settled ?? 99) - clickAt))
    let final = samples.last!.1
    check("the click point is inside the final view", screen16.viewRect(final).contains(CGPoint(x: 0.25, y: 0.25)),
          String(format: "centre %.3f,%.3f zoom %.2f", final.cx, final.cy, final.zoom))
    // Quiet for the idle time (5 s): back to the whole screen within 1 s of the timer.
    while t < clickAt + 5 { _ = view(f, t); t += fps }
    var back: Double?
    while t < clickAt + 7 { let v = view(f, t); if back == nil && near(v.zoom, 1, 0.02) { back = t }; t += fps }
    check("back at the whole screen within 1 s of the quiet spell", (back ?? 99) - (clickAt + 5) <= 1, String(format: "%.2f s", (back ?? 99) - (clickAt + 5)))
    let a = view(f, t); t += 10
    let b = view(f, t)
    // In canvas pixels: how far the picture under the frame's centre moved.
    let drift = max(abs(a.cx - b.cx), abs(a.cy - b.cy)) * 3024 * 0.55 * a.zoom + abs(a.zoom - b.zoom) * 1920
    check("a still cursor for 10 s moves the picture less than half a pixel", near(a.zoom, 1, 0.001) && drift < 0.5, String(format: "%.4f px", drift))

    // Timer jitter: the same moves whether frames come on time or 0-4 ms late.
    func run(jitter: Bool) -> [Double] {
        let g = controller()
        var rng = SystemRandomNumberGenerator()
        var out: [Double] = []
        for i in 0..<120 {
            let base = Double(i) / 30
            if i == 20 { g.click(CGPoint(x: 1000, y: 300), at: base + 0.01) }
            if jitter && i > 0 { _ = view(g, base - Double.random(in: 0...0.004, using: &rng)) }
            out.append(view(g, base).zoom)
        }
        return out
    }
    let exact = run(jitter: false), jittered = run(jitter: true)
    check("identical moves with 0-4 ms timer jitter", zip(exact, jittered).allSatisfy { abs($0 - $1) < 1e-9 },
          String(format: "max difference %.2e", zip(exact, jittered).map { abs($0 - $1) }.max() ?? 0))

    // App switches: one right after a click is the click's own; ⌘-Tab goes back to the whole screen.
    f = controller(); t = 0
    func runTo(_ end: Double) { while t < end { _ = view(f, t); t += fps } }
    runTo(1); f.click(CGPoint(x: 378, y: 245), at: t); f.appSwitched(at: t + 0.2); runTo(3)
    check("an app switch from the click itself keeps the zoom", view(f, t).zoom > 1.5)
    f.appSwitched(at: t); runTo(t + 1.5)
    check("⌘-Tab goes back to the whole screen", near(view(f, t).zoom, 1, 0.03))
    f.click(CGPoint(x: 378, y: 245), at: t); runTo(t + 0.5)
    check("no zoom in again within 2.5 s of zooming out", view(f, t).zoom < 1.05)
    runTo(t + 2.5)
    check("…and the held-back click zooms after that", view(f, t).zoom > 1.4)

    // Password fields and the reset key.
    f = controller(); t = 0; runTo(1)
    f.secureInput(true, at: t); f.click(CGPoint(x: 378, y: 245), at: t + 0.1); runTo(t + 1.5)
    check("no zoom while a password field has the keyboard", view(f, t).zoom == 1)
    f.secureInput(false, at: t); runTo(t + 3); f.click(CGPoint(x: 378, y: 245), at: t); runTo(t + 1.5)
    check("zooms again once it's gone", view(f, t).zoom > 1.5)
    f.resetAndPause(seconds: 30, at: t); runTo(t + 1.2)
    check("the reset key goes back to the whole screen", near(view(f, t).zoom, 1, 0.03))
    f.click(CGPoint(x: 378, y: 245), at: t); runTo(t + 1.5)
    check("…and stays there while paused", near(view(f, t).zoom, 1, 0.03))

    // Never-zoom windows: the view shifts off one, or doesn't zoom when it can't.
    f = controller(); t = 0; runTo(1)
    f.setAreas(ignored: [], denied: [CGRect(x: 0, y: 0, width: 1512 * 0.25, height: 982)])
    f.cursor(CGPoint(x: 1512 * 0.3, y: 491), at: t); f.click(CGPoint(x: 1512 * 0.3, y: 491), at: t); runTo(t + 1.5)
    var v = view(f, t)
    let r = screen16.viewRect(v)
    check("a zoom next to a private window keeps it out of view", v.zoom > 1.5 && r.minX >= 0.249 && r.contains(CGPoint(x: 0.3, y: 0.5)),
          String(format: "view x %.3f…%.3f", r.minX, r.maxX))
    f = controller(); t = 0; runTo(1)
    f.setAreas(ignored: [], denied: [CGRect(x: 0, y: 0, width: 1512 * 0.45, height: 982), CGRect(x: 1512 * 0.55, y: 0, width: 1512 * 0.45, height: 982)])
    f.cursor(CGPoint(x: 1512 * 0.5, y: 491), at: t); f.click(CGPoint(x: 1512 * 0.5, y: 491), at: t); runTo(t + 1.5)
    v = view(f, t)
    check("no zoom when no view avoids a private window", v.zoom < 1.05, String(format: "zoom %.2f", v.zoom))

    // 9:16: the screen fills the frame as a slice that follows the cursor, and tightens a little on a click.
    f = controller(); t = 0
    let first = view(f, t, screen9, canvas: .vertical)
    check("9:16 starts as a full-height slice, with no move", near(first.zoom, screen9.fillZoom, 0.001))
    f.cursor(CGPoint(x: 1400, y: 491), at: 0.5)
    t = 0; while t < 2 { v = view(f, t, screen9, canvas: .vertical); t += fps }
    check("…which follows the cursor to the right edge", screen9.viewRect(v).contains(CGPoint(x: 1400 / 1512, y: 0.5)), String(format: "centre %.3f", v.cx))
    f.click(CGPoint(x: 1400, y: 491), at: t); let c0 = t
    while t < c0 + 1.5 { v = view(f, t, screen9, canvas: .vertical); t += fps }
    check("…and tightens 1.2x on a click", near(v.zoom, screen9.fillZoom * 1.2, 0.05), String(format: "%.2f", v.zoom))

    // Off, and Rehearse while live: nothing moves.
    f = controller(.off)
    check("Off draws exactly as before", f.viewport(source: source, canvas: .horizontal, screen: desk, layer: screen16, at: 1, hold: false, tier: .full) == nil)
    f = controller(.rehearse)
    var cfg = f.currentConfig; cfg.isLive = true; f.setConfig(cfg)
    f.click(CGPoint(x: 378, y: 245), at: 0.5)
    check("Rehearse keeps still while live", f.viewport(source: source, canvas: .horizontal, screen: desk, layer: screen16, at: 1.5, hold: false, tier: .full) == nil)
    f = controller(); t = 0; runTo(1); f.click(CGPoint(x: 378, y: 245), at: t); runTo(t + 1.5)
    t += 0.1
    check("the governor's T3 eases back to the whole screen",
          { () -> Bool in var z = 9.0; var tt = t; for _ in 0..<60 { z = f.viewport(source: source, canvas: .horizontal, screen: desk, layer: screen16, at: tt, hold: false, tier: .off)?.zoom ?? 1; tt += fps }; return near(z, 1, 0.02) }())

    // Review fixes. 9:16 goes back to today's strip for a password field and the reset key, and stays there.
    func vview(_ g: FocusController, _ t: Double) -> Viewport {
        g.viewport(source: source, canvas: .vertical, screen: desk, layer: screen9, at: t, hold: false, tier: .full) ?? .identity
    }
    var g = controller(); var tt = 0.0
    func runV(_ end: Double, cursor: ((Double) -> CGPoint)? = nil) -> [Viewport] {
        var out: [Viewport] = []
        while tt < end { if let c = cursor { g.cursor(c(tt), at: tt) }; out.append(vview(g, tt)); tt += fps }
        return out
    }
    _ = runV(1)
    g.secureInput(true, at: tt)
    let secureFrames = runV(tt + 3, cursor: { CGPoint(x: 200 + $0 * 300, y: 491) })
    check("9:16 eases back to the whole strip while a password field has the keyboard, and stops following",
          near(secureFrames.last!.zoom, 1, 0.02) && near(secureFrames.last!.cx, 0.5, 0.001), String(format: "zoom %.2f, centre %.3f", secureFrames.last!.zoom, secureFrames.last!.cx))
    g.secureInput(false, at: tt)
    let after = runV(tt + 1.5)
    check("…and fills the frame again once it's gone", near(after.last!.zoom, screen9.fillZoom, 0.05), String(format: "%.2f", after.last!.zoom))
    g.resetAndPause(seconds: 30, at: tt)
    let paused = runV(tt + 3, cursor: { CGPoint(x: 1300 - ($0 - tt) * 100, y: 491) })
    check("9:16 shows the whole strip during the reset pause", near(paused.last!.zoom, 1, 0.02), String(format: "%.2f", paused.last!.zoom))

    // A never-zoom window is never drawn magnified: not at the start of a new shot, not halfway through a glide.
    g = controller(); tt = 0
    let denyRect = CGRect(x: 600, y: 0, width: 300, height: 982)                // a tall window in the middle of the display
    g.setAreas(ignored: [], denied: [denyRect])
    g.cursor(CGPoint(x: 750, y: 491), at: 0)                                     // the cursor starts over it
    let crossing = runV(4, cursor: { CGPoint(x: 300 + $0 * 250, y: 491) })      // and then sweeps across it
    let deny = screen9.pictureRect(desk.normalized(denyRect))!
    let shows = crossing.filter { $0.zoom > 1.0001 && screen9.viewRect($0).intersects(deny) }
    check("no drawn 9:16 frame shows a never-zoom window magnified (new shot and a sweep across it)", shows.isEmpty, "\(shows.count) of \(crossing.count) frames")

    // Slow, steady cursor movement keeps a zoom alive (it adds up past the 3-point threshold).
    f = controller(); t = 0; runTo(1)
    f.click(CGPoint(x: 400, y: 400), at: t)
    while t < 9 { f.cursor(CGPoint(x: 400 + (t - 1) * 60, y: 400), at: t); _ = view(f, t); t += 1.0 / 120 }
    check("moving the cursor slowly (60 pt/s) keeps the zoom for 8 s", view(f, t).zoom > 1.5, String(format: "zoom %.2f", view(f, t).zoom))

    // A click on a part of the screen the layer crops away doesn't zoom that layer.
    let cropped = LayerGeometry(image: CGSize(width: 2419, height: 1964), frame: CGSize(width: 1920, height: 1080), fit: .fit,
                                crop: ItemCrop(left: 0.2, top: 0, right: 0, bottom: 0))     // the left fifth cropped away
    f = controller(); t = 0
    func cview(_ tt: Double) -> Viewport { f.viewport(source: source, canvas: .horizontal, screen: desk, layer: cropped, at: tt, hold: false, tier: .full) ?? .identity }
    while t < 1 { _ = cview(t); t += fps }
    f.click(CGPoint(x: 200, y: 400), at: t)                                    // in the cropped-away fifth
    while t < 2.5 { _ = cview(t); t += fps }
    check("a click in a cropped-away part doesn't zoom", cview(t).zoom < 1.01, String(format: "%.2f", cview(t).zoom))

    // Moves switched on glide in from today's framing instead of jumping.
    g = controller(.off); tt = 0
    while tt < 1 { _ = vview(g, tt); tt += fps }
    var on = g.currentConfig; on.moves = .on; g.setConfig(on)
    let glide = runV(tt + 1.5)
    check("switching moves on glides from the strip (no jump)", glide.first!.zoom < 1.05 && near(glide.last!.zoom, screen9.fillZoom, 0.1),
          String(format: "first %.2f, after 1.5 s %.2f", glide.first!.zoom, glide.last!.zoom))

    // The password-field state survives the event log being trimmed (a long session, then a new shot).
    g = controller(); tt = 0
    g.secureInput(true, at: 0.5)
    for i in 0..<600 { g.cursor(CGPoint(x: Double(100 + (i % 2) * 50), y: 300), at: 0.6 + Double(i) * 0.11) }
    let other = UUID()
    let tLate = 0.6 + 600 * 0.11
    g.click(CGPoint(x: 400, y: 400), at: tLate)
    var vz = 1.0
    for k in 0..<45 { vz = g.viewport(source: other, canvas: .horizontal, screen: desk, layer: screen16, at: tLate + Double(k) * fps, hold: false, tier: .full)?.zoom ?? 1 }
    check("a new shot after a long session still knows a password field has the keyboard", vz < 1.01, String(format: "zoom %.2f", vz))

    // Going live in Rehearse: today's framing at once, not an ease-out on air.
    f = controller(.rehearse); t = 0; runTo(1); f.click(CGPoint(x: 400, y: 400), at: t); runTo(t + 1.5)
    var live = f.currentConfig; live.isLive = true; f.setConfig(live)
    check("Rehearse is still the moment the show goes live", f.viewport(source: source, canvas: .horizontal, screen: desk, layer: screen16, at: t, hold: false, tier: .full) == nil)

    // The governor: steady frames decide the tier; transitions don't.
    let stats = TickStats()
    for i in 0..<600 { stats.add(TickStats.Sample(t: Double(i) / 30, tick: 6)) }
    for i in 0..<11 { stats.add(TickStats.Sample(t: 20 + Double(i) / 30, tick: 12, transition: true)) }
    check("a 0.35 s whip at 12 ms a tick leaves the steady p95 alone", stats.summary(since: 0).p95 == 6 && stats.summary(since: 0).transitionP95 == 12)
    let gov = BudgetGovernor(); gov.baselineMs = 7; gov.mode = .full; gov.testThermal = .nominal
    var gt = 0.0
    func feedGov(_ p95: Double, _ seconds: Double) { let end = gt + seconds; while gt < end { gov.evaluate(now: gt, fps: 30, steadyP95: p95, missedTotal: 0); gt += 1 } }
    feedGov(40, 14)
    check("the first 15 s (warm-up) never change the tier", gov.tier == .full, gov.current.reason)
    feedGov(6, 6)
    check("healthy frames stay at T0", gov.tier == .full, gov.current.reason)
    feedGov(15, 5)
    check("15 ms frames (8 ms over a 7 ms normal, under half the frame) stay at T0", gov.tier == .full, gov.current.reason)
    feedGov(18, 5)
    check("frames over half the frame (18 ms) enter T1 within 5 s", gov.tier == .eco, gov.current.reason)
    feedGov(23, 5)
    check("frames over two thirds (23 ms) enter T2", gov.tier == .minimal, gov.current.reason)
    feedGov(28, 6)
    check("frames over four fifths for 5 s turn the editor off (T3)", gov.tier == .off, gov.current.reason)
    feedGov(5, 120)
    check("T3 waits 5 healthy minutes before coming back", gov.tier == .off)
    feedGov(5, 200)
    check("…then climbs one tier at a time", gov.tier == .minimal || gov.tier == .eco, gov.current.tier.title)

    // Without a Gate 0 measurement it learns the normal frame time (15-45 s) and sets its lines above that.
    let learner = BudgetGovernor(); learner.mode = .full; learner.testThermal = .nominal
    var lt = 0.0
    func feedLearner(_ p95: Double, _ seconds: Double) { let end = lt + seconds; while lt < end { learner.evaluate(now: lt, fps: 30, steadyP95: p95, missedTotal: 0); lt += 1 } }
    feedLearner(25, 15); feedLearner(15, 35)
    check("learns a 15 ms normal frame and stays at T0 there", learner.tier == .full && near(learner.current.baseline, 15, 0.01) && learner.current.baselineFrom == "learned",
          "\(learner.current.baselineFrom) \(learner.current.baseline)")
    feedLearner(19, 5)
    check("…19 ms is normal swing there, still T0", learner.tier == .full, learner.current.reason)
    feedLearner(21, 5)
    check("…and 21 ms steps to T1 (its line is 15 + 5 ms)", learner.tier == .eco, learner.current.reason)

    // When a recording or stream starts, encoding makes every frame a bit slower: the governor learns the new normal
    // instead of calling it trouble.
    feedLearner(15, 30)
    check("back at T0 at the old normal", learner.tier == .full || learner.tier == .eco, learner.current.tier.title)
    learner.relearn()
    feedLearner(19, 75)
    check("after recording starts, 19 ms frames become the new normal (re-learned) and it climbs back to T0",
          learner.tier == .full && near(learner.current.baseline, 19, 0.01), "\(learner.current.tier.title), baseline \(learner.current.baseline)")

    // Missed recording frames: one slow frame (a slot in each of two recordings) is not a pattern; four in 10 s are.
    let mg = BudgetGovernor(); mg.baselineMs = 10; mg.mode = .full; mg.testThermal = .nominal
    var mt = 0.0, missed = 0
    func feedMissed(_ add: Int, _ seconds: Double) { let end = mt + seconds; while mt < end { missed += add; mg.evaluate(now: mt, fps: 30, steadyP95: 10, missedTotal: missed); mt += 1 } }
    feedMissed(0, 20); missed += 2; feedMissed(0, 5)
    check("one slow frame (2 missed slots) doesn't step down", mg.tier == .full, mg.current.reason)
    feedMissed(0, 12); missed += 4; feedMissed(0, 3)
    check("4 missed slots within 10 s step down to T2", mg.tier == .minimal, mg.current.reason)

    print(failures == 0 ? "live editor: all checks passed" : "live editor: \(failures) failed")
    return failures == 0
}
