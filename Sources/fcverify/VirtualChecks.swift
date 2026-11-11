import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import CoreMedia
import Vision
import FramecastEngine

/// `fcverify virtual`: crops cut from one camera, run on made-up face readings and a 30 fps clock (no camera, no
/// engine). Each line prints PASS or FAIL; the process fails if any check does.
func virtualChecks() -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(name)\(detail.isEmpty ? "" : ": \(detail)") → \(ok ? "PASS" : "FAIL")")
        if !ok { failures += 1 }
    }
    func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
    func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    let cam1080 = CGSize(width: 1920, height: 1080), cam4K = CGSize(width: 3840, height: 2160)
    let both: [CanvasKind: CGSize] = [.horizontal: CGSize(width: 1920, height: 1080), .vertical: CGSize(width: 1080, height: 1920)]
    let wide = 16.0 / 9, tall = 9.0 / 16

    /// A face box `h` tall (camera heights) centred at (x, y); faces are about square in pixels.
    func box(_ x: Double, _ y: Double, _ h: Double, cam: CGSize) -> CGRect {
        let w = h * cam.height / cam.width
        return CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
    }
    func framer(_ cam: CGSize, face h: Double, frames: [CanvasKind: CGSize]? = nil, at p: CGPoint = CGPoint(x: 0.5, y: 0.4)) -> VirtualFramer {
        var f = VirtualFramer()
        f.setGeometry(camera: cam, frames: frames ?? both, shots: VirtualShots())
        f.ingest(FaceSample(boxes: [box(p.x, p.y, h, cam: cam)], at: 0))
        return f
    }

    // MARK: A. Shot plans

    do {
        let p = framer(cam1080, face: 0.12).plan, m = p[.medium]!, c = p[.close]!
        check("A1 1080p, face 0.12: medium zoom 1.417, a little soft", m.available && near(m.zoom, 1.417, 0.001) && near(m.enlargement[.horizontal]!, 1.417, 0.001) && m.grade == .slightlySoft,
              "zoom \(f3(m.zoom)), enlargement \(f3(m.enlargement[.horizontal]!)), \(m.grade.title)")
        check("A1 1080p, face 0.12: close loosened to 2.0, face 0.24, soft", c.available && near(c.zoom, 2.0, 1e-6) && near(c.faceInCrop, 0.24, 1e-6) && near(c.enlargement[.horizontal]!, 2.0, 1e-6) && c.grade == .soft,
              "zoom \(f3(c.zoom)), face \(f3(c.faceInCrop)), enlargement \(f3(c.enlargement[.horizontal]!)), \(c.grade.title)")
        check("A1 the close is at least 1.4× the medium", c.zoom / m.zoom >= 1.4 - 1e-9, f3(c.zoom / m.zoom))
        check("A1 9:16 enlargement is reported, not capped", near(m.enlargement[.vertical]!, 2.52, 0.01) && near(c.enlargement[.vertical]!, 3.56, 0.01),
              "\(f3(m.enlargement[.vertical]!)) / \(f3(c.enlargement[.vertical]!))")
    }
    do {
        let p = framer(cam4K, face: 0.12).plan, m = p[.medium]!, c = p[.close]!
        check("A2 4K: medium enlargement 0.71, close zoom 2.5 at 1.25, both sharp",
              m.available && c.available && near(m.enlargement[.horizontal]!, 0.708, 0.001) && near(c.zoom, 2.5, 1e-6) && near(c.enlargement[.horizontal]!, 1.25, 1e-6) && m.grade == .sharp && c.grade == .sharp,
              "medium \(f3(m.enlargement[.horizontal]!)), close zoom \(f3(c.zoom)) at \(f3(c.enlargement[.horizontal]!)); 9:16 \(f3(m.enlargement[.vertical]!)) / \(f3(c.enlargement[.vertical]!))")
    }
    do {
        let p = framer(cam1080, face: 0.10).plan, m = p[.medium]!, c = p[.close]!
        check("A3 1080p, face 0.10: medium only (zoom 1.7, soft); the close needs a 4K camera",
              m.available && near(m.zoom, 1.7, 1e-6) && m.grade == .soft && !c.available && (c.reason ?? "").contains("needs a 4K camera"),
              "medium \(f3(m.zoom)) \(m.grade.title); close: \(c.reason ?? "offered")")
    }
    do {
        let p = framer(cam1080, face: 0.25).plan
        check("A4 face 0.25: no crops, already a close-up", p.values.allSatisfy { !$0.available && ($0.reason ?? "").contains("already shows a close-up") }, p[.medium]?.reason ?? "")
    }
    do {
        let p = framer(cam4K, face: 0.18).plan, m = p[.medium]!, c = p[.close]!
        check("A5 4K, face 0.18: no medium; close zoom 1.67 at 0.83", !m.available && c.available && near(c.zoom, 1.667, 0.001) && near(c.enlargement[.horizontal]!, 0.833, 0.001),
              "medium: \(m.reason ?? "offered"); close \(f3(c.zoom)) at \(f3(c.enlargement[.horizontal]!))")
    }
    do {
        let p = framer(CGSize(width: 1280, height: 720), face: 0.12).plan
        check("A6 720p, face 0.12: nothing offered", p.values.allSatisfy { !$0.available && ($0.reason ?? "").contains("720p") }, p[.medium]?.reason ?? "")
    }
    do {
        let f = framer(CGSize(width: 1920, height: 1440), face: 0.09), m = f.plan(.medium)
        check("A7 4:3 camera: measured against a visible height of 0.75", near(f.lockedFace ?? 0, 0.12, 1e-6) && near(m.zoom, 1.417, 0.001) && near(m.height, 0.75 / m.zoom, 1e-6) && near(m.enlargement[.horizontal]!, 1.417, 0.001),
              "face \(f3(f.lockedFace ?? 0)), zoom \(f3(m.zoom)), crop height \(f3(m.height)), enlargement \(f3(m.enlargement[.horizontal]!))")
    }
    do {
        let p = framer(cam1080, face: 0.12, frames: [.horizontal: CGSize(width: 960, height: 540)]).plan, m = p[.medium]!, c = p[.close]!
        check("A8 frame half the canvas height: enlargement halves", near(m.enlargement[.horizontal]!, 1.417 / 2, 0.001) && near(c.zoom, 2.5, 1e-6) && near(c.enlargement[.horizontal]!, 1.25, 1e-6),
              "medium \(f3(m.enlargement[.horizontal]!)), close zoom \(f3(c.zoom)) at \(f3(c.enlargement[.horizontal]!))")
    }
    do {
        let f = framer(cam1080, face: 0.12)
        let h = f.previewRect(.medium, aspect: wide)!, v = f.previewRect(.medium, aspect: tall)!
        let pxW = v.width * 1920, pxH = v.height * 1080
        check("A9 9:16 frame: same crop height, shaped 9:16, enlargement reported", near(h.height, v.height, 1e-9) && near(pxW / pxH, tall, 1e-6) && f.plan(.medium).available && f.plan(.medium).enlargement[.vertical]! > 2,
              "heights \(f3(h.height)) / \(f3(v.height)), shape \(f3(pxW / pxH)), 9:16 enlargement \(f3(f.plan(.medium).enlargement[.vertical]!))")
    }
    do {
        var f = VirtualFramer()
        f.setGeometry(camera: cam1080, frames: both, shots: VirtualShots())
        let none = f.plan.values.allSatisfy { !$0.available && $0.reason == "Looking for you…" }
        let v = f.view(.close, key: .program(.horizontal), aspect: wide, t: 0)
        check("A10 no face yet: nothing available, a centred crop meanwhile", none && !f.usable(.close, now: 0) && v.map { near($0.rect.midX, 0.5, 1e-9) && near($0.zoom, 1.96, 1e-6) } == true,
              f.plan(.close).reason ?? "")
    }
    do {
        // Face 0.115: a medium at face 0.17 (zoom 1.48) would leave the 2× close-up only 1.35× tighter.
        let p = framer(cam1080, face: 0.115).plan, m = p[.medium]!, c = p[.close]!
        check("A11 1080p, face 0.115: the medium loosens to 1.43 so the close-up stays (2.0, face 0.23)",
              m.available && c.available && near(m.zoom, 2.0 / 1.4, 1e-6) && near(c.zoom, 2.0, 1e-6) && c.zoom / m.zoom >= 1.4 - 1e-9 && c.faceInCrop >= 0.22,
              "medium \(f3(m.zoom)) (face \(f3(m.faceInCrop))), close \(f3(c.zoom)) (face \(f3(c.faceInCrop)))")
    }
    do {
        // Face 0.115 on 4K: a close-up at face 0.30 (zoom 2.61) would be enlarged 1.30×, just past sharp.
        let c = framer(cam4K, face: 0.115).plan(.close), soft = framer(cam4K, face: 0.10).plan(.close)
        check("A12 4K, face 0.115: the close-up loosens to sharp (2.5 at 1.25, face 0.29); face 0.10 stays a little soft (more than 10% off)",
              c.available && near(c.zoom, 2.5, 1e-6) && c.grade == .sharp && near(c.faceInCrop, 0.2875, 1e-6) && near(soft.zoom, 3.0, 1e-6) && soft.grade == .slightlySoft,
              "close \(f3(c.zoom)) at \(f3(c.enlargement[.horizontal]!)) (face \(f3(c.faceInCrop))); face 0.10: \(f3(soft.zoom)) at \(f3(soft.enlargement[.horizontal]!))")
    }

    // MARK: B. Framing over time

    /// Seeded noise in -1...1.
    struct Noise {
        var r: UInt64
        mutating func next() -> Double { r = r &* 6364136223846793005 &+ 1442695040888963407; return Double(r >> 11) / Double(1 << 53) * 2 - 1 }
    }
    /// Runs a framer from t0 to t1: face readings 5 times a second, frames 30 times a second.
    func run(_ f: inout VirtualFramer, _ t0: Double, _ t1: Double, sample: (Double) -> FaceSample?, frame: (inout VirtualFramer, Double) -> Void) {
        var j = 0
        for i in 0..<Int(((t1 - t0) * 30).rounded()) {
            let t = t0 + Double(i) / 30
            while t0 + Double(j) * 0.2 <= t + 1e-9 {
                if let s = sample(t0 + Double(j) * 0.2) { f.ingest(s) }
                j += 1
            }
            frame(&f, t)
        }
    }
    struct Drawn { var key: VirtualDrawKey; var shot: VirtualShot; var aspect: Double; var size: CGSize }
    let keys = [Drawn(key: .program(.horizontal), shot: .medium, aspect: wide, size: both[.horizontal]!),
                Drawn(key: .program(.vertical), shot: .medium, aspect: tall, size: both[.vertical]!),
                Drawn(key: .iso, shot: .close, aspect: wide, size: both[.horizontal]!)]

    // B1 and B2: a still face with ±1% noise for 60 s, on both cameras.
    for (name, cam) in [("1080p", cam1080), ("4K", cam4K)] {
        var f = framer(cam, face: 0.12)
        let zooms = f.plan.mapValues(\.zoom)
        var noise = Noise(r: 11)
        let truth = box(0.5, 0.4, 0.12, cam: cam)
        var last: [Int: CGRect] = [:], moves: [Double] = [], travel: [Int: Double] = [:]
        var eyeErr = 0.0, sizeErr = 0.0, guardOK = true, inside = true, zoomSame = true
        // Close on 9:16 too, so all four eye lines get checked.
        let all = keys + [Drawn(key: .program(.vertical), shot: .close, aspect: tall, size: both[.vertical]!)]
        run(&f, 0, 60, sample: { t in
            FaceSample(boxes: [box(0.5 + 0.01 * noise.next(), 0.4 + 0.01 * noise.next(), 0.12 * (1 + 0.01 * noise.next()), cam: cam)], at: t)
        }, frame: { f, t in
            if f.plan.mapValues(\.zoom) != zooms { zoomSame = false }
            for (i, d) in all.enumerated() {
                guard let v = f.view(d.shot, key: i == 3 ? .program(.horizontal) : d.key, aspect: d.aspect, t: t)?.rect else { continue }
                if let p = last[i] {
                    moves.append(max(abs(v.midX - p.midX) / v.width * d.size.width, abs(v.midY - p.midY) / v.height * d.size.height,
                                     abs(v.height - p.height) / v.height * d.size.height))
                    travel[i, default: 0] += abs(v.midX - p.midX) / v.width
                }
                last[i] = v
                let eye = truth.minY + 0.4 * truth.height, crown = truth.minY - 0.35 * truth.height
                eyeErr = max(eyeErr, abs((eye - v.minY) / v.height - d.shot.eyeLine(aspect: d.aspect)))
                sizeErr = max(sizeErr, abs(truth.height / v.height / f.plan(d.shot).faceInCrop - 1))
                if (crown - v.minY) / v.height < d.shot.crownGuard - 1e-6 { guardOK = false }
                if !v.contains(truth) { inside = false }
            }
        })
        moves.sort()
        let p99 = moves.isEmpty ? 99 : moves[Int(Double(moves.count - 1) * 0.99)]
        let most = travel.values.max() ?? 0
        check("B1 \(name) still face with noise: p99 movement under 0.5 px a frame, travel under 0.02 W, zoom unchanged",
              !moves.isEmpty && p99 < 0.5 && most < 0.02 && zoomSame, String(format: "p99 %.3f px, travel %.4f W", p99, most))
        check("B2 \(name) eye lines on 0.34 / 0.37 / 0.30 / 0.32 ±0.02, face size ±10%, head clear, face inside",
              eyeErr <= 0.02 && sizeErr <= 0.10 && guardOK && inside, String(format: "eye line off by %.4f, size off by %.1f%%", eyeErr, sizeErr * 100))
    }

    // B3: a slow walk at 0.05 camera widths a second.
    do {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.3, y: 0.4))
        var noise = Noise(r: 23)
        func x(_ t: Double) -> Double { 0.3 + 0.05 * max(0, t - 1) }
        var lag = 0.0, speed = 0.0, reversals = 0, lags: [Double] = []
        var prev: [VirtualShot: (x: Double, v: Double)] = [:]
        run(&f, 0, 9, sample: { t in
            FaceSample(boxes: [box(x(t) + 0.01 * noise.next(), 0.4 + 0.01 * noise.next(), 0.12, cam: cam1080)], at: t)
        }, frame: { f, t in
            for s in VirtualShot.allCases {
                guard let r = f.view(s, key: s == .medium ? .program(.horizontal) : .iso, aspect: wide, t: t)?.rect else { continue }
                if let p = prev[s] {
                    let v = (r.midX - p.x) * 30
                    speed = max(speed, abs(v) / r.width)
                    if v * p.v < 0 && abs(v) > 1e-6 && abs(p.v) > 1e-6 { reversals += 1 }
                    prev[s] = (r.midX, v != 0 ? v : p.v)
                } else { prev[s] = (r.midX, 0) }
                // After the first reframe (the dead zone holds the start back on purpose).
                if t > 4 { lag = max(lag, (x(t) - r.midX) / 0.05); lags.append((x(t) - r.midX) / 0.05) }
            }
        })
        check("B3 slow walk: lag at most 1.2 s, speed within the cap, no reversals", lag <= 1.2 && speed <= 0.35 * 1.01 && reversals == 0,
              String(format: "lag %.2f s (mean %.2f), speed %.3f W/s, %d reversals", lag, lags.reduce(0, +) / Double(max(1, lags.count)), speed, reversals))
    }

    // B4: a jump of 0.3 of the close-up's width, with the close-up on air.
    do {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.4, y: 0.4))
        let W = f.previewRect(.close, aspect: wide)!.width
        let jumpAt = 3.0, to = 0.4 + 0.3 * W
        var xs: [(t: Double, x: Double)] = []
        var nz = Noise(r: 31)
        run(&f, 0, jumpAt + 6, sample: { t in
            FaceSample(boxes: [box((t < jumpAt ? 0.4 : to) + 0.01 * nz.next(), 0.4 + 0.01 * nz.next(), 0.12, cam: cam1080)], at: t)
        }, frame: { f, t in
            if let r = f.view(.close, key: .program(.horizontal), aspect: wide, t: t)?.rect { xs.append((t, r.midX)) }
        })
        let start = xs.first { $0.t >= jumpAt }!.x, end = xs.last!.x
        var vMax = 0.0, aMax = 0.0, over = 0.0
        var settled = jumpAt
        for i in 1..<xs.count where xs[i].t >= jumpAt {
            let v = (xs[i].x - xs[i - 1].x) * 30
            vMax = max(vMax, abs(v) / W)
            if i >= 2 { aMax = max(aMax, abs(v - (xs[i - 1].x - xs[i - 2].x) * 30) * 30 / W) }
            over = max(over, (xs[i].x - end) / (end - start))
            if abs(xs[i].x - end) > 0.01 * W { settled = xs[i].t }
        }
        check("B4 jump: speed at most 0.35 W/s, acceleration at most 1.2 W/s², overshoot under 1%, settled within 2.5 s",
              vMax <= 0.35 * 1.01 && aMax <= 1.2 * 1.05 && over < 0.01 && settled - jumpAt <= 2.5 && abs(end - to) < 0.03 * W,
              String(format: "speed %.3f, acceleration %.2f, overshoot %.2f%%, settled after %.2f s", vMax, aMax, over * 100, settled - jumpAt))
    }

    // B5: a cut lands framed: the close-up, on air while the presenter hurried 0.4 camera widths (0.8 of its width) in
    // 0.6 s, then unused for 0.6 s (too short for a glide to arrive), starts on its target.
    do {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.3, y: 0.4))
        func x(_ t: Double) -> Double { 0.3 + 0.4 * min(1, max(0, (t - 3) / 0.6)) }
        run(&f, 0, 4.5, sample: { t in FaceSample(boxes: [box(x(t), 0.4, 0.12, cam: cam1080)], at: t) },
            frame: { f, t in _ = f.view(.medium, key: .program(.horizontal), aspect: wide, t: t); if t < 3.9 { _ = f.view(.close, key: .program(.horizontal), aspect: wide, t: t) } })
        let first = f.view(.close, key: .program(.horizontal), aspect: wide, t: 4.5)!.rect, want = f.previewRect(.close, aspect: wide)!
        let err = max(abs(first.midX - want.midX), abs(first.midY - want.midY)) / want.width
        check("B5 first frame after more than 0.5 s unused is on target", err < 0.01 && abs(first.midX - 0.7) < 0.02, String(format: "off by %.4f W, at x %.3f", err, first.midX))
    }

    // B6: the same time twice, or time going backwards, never steps.
    do {
        var f = framer(cam1080, face: 0.12)
        run(&f, 0, 10, sample: { t in FaceSample(boxes: [box(t < 5 ? 0.5 : 0.6, 0.4, 0.12, cam: cam1080)], at: t) },
            frame: { f, t in _ = f.view(.close, key: .program(.horizontal), aspect: wide, t: t) })
        let a = f.view(.close, key: .program(.horizontal), aspect: wide, t: 10)!
        let b = f.view(.close, key: .program(.horizontal), aspect: wide, t: 10)!
        let c = f.view(.close, key: .program(.horizontal), aspect: wide, t: 9.98)!
        let d = f.view(.close, key: .program(.horizontal), aspect: wide, t: 10.2)!
        check("B6 same t twice or t going back: identical rectangle", a == b && a == c && d.rect != a.rect)
    }

    // B7: size wobble keeps the zoom; a lasting change moves it after 3 s, gliding on air and snapping off air.
    do {
        var onAir = framer(cam4K, face: 0.12), offAir = framer(cam4K, face: 0.12)
        let z0 = onAir.plan(.close).zoom
        func h(_ t: Double) -> Double { t < 20 ? 0.12 * (1 + 0.15 * sin(2 * .pi * t / 2.2)) : 0.156 }
        var changedAt: Double?, zoomAfter: [(t: Double, z: Double)] = []
        var wobbleKept = true
        let sample = { (t: Double) in FaceSample(boxes: [box(0.5, 0.4, h(t), cam: cam4K)], at: t) }
        run(&onAir, 0, 30, sample: sample, frame: { f, t in
            let z = f.plan(.close).zoom
            if t < 20 && z != z0 { wobbleKept = false }
            if changedAt == nil && z != z0 { changedAt = t }
            if let v = f.view(.close, key: .program(.horizontal), aspect: wide, t: t) { zoomAfter.append((t, v.zoom)) }
        })
        var snapZoom = 0.0
        run(&offAir, 0, 30, sample: sample, frame: { f, t in
            if t >= 28 && snapZoom == 0 { snapZoom = f.view(.close, key: .program(.horizontal), aspect: wide, t: t)!.zoom }
        })
        let z1 = onAir.plan(.close).zoom
        let ch = changedAt ?? 99
        let soon = zoomAfter.first { $0.t >= ch + 0.3 }?.z ?? 0
        let glided = abs(soon - z0) < 0.3 * abs(z1 - z0)
        let arrived = abs((zoomAfter.last?.z ?? 0) / z1 - 1) < 0.01
        check("B7 ±15% wobble keeps the zoom", wobbleKept, String(format: "zoom %.3f", z0))
        check("B7 +30% held: zoom changes after 3 s, glides on air, snaps off air",
              ch - 20 >= 3 && ch - 20 <= 5 && z1 < z0 && glided && arrived && abs(snapZoom / z1 - 1) < 1e-6,
              String(format: "changed after %.1f s, %.2f → %.2f; 0.3 s later on air %.2f; off air starts at %.2f", ch - 20, z0, z1, soon, snapZoom))
    }

    // B8: the face is lost; a body with no face where it was (turned away, looking down) keeps the crop, a body
    // elsewhere in the picture (the presenter at a whiteboard, someone at the back) or one with another face in it doesn't.
    do {
        let atFace = CGRect(x: 0.40, y: 0.30, width: 0.20, height: 0.70), shoulders = CGRect(x: 0.40, y: 0.50, width: 0.20, height: 0.50)
        let aside = CGRect(x: 0.05, y: 0.30, width: 0.15, height: 0.55)
        let cases: [(name: String, bodies: [CGRect], boxes: [CGRect], keeps: Bool)] = [
            ("lost face", [], [], false), ("a body where the face was", [atFace], [], true),
            ("a torso from the shoulders down", [shoulders], [], true), ("a body elsewhere", [aside], [], false),
            ("a body with another face in it", [atFace], [box(0.5, 0.75, 0.06, cam: cam1080)], false)]
        for c in cases {
            var f = framer(cam1080, face: 0.12)
            var rects: [CGRect] = []
            var usableAt14 = false, usableAt16 = true
            run(&f, 0, 8, sample: { t in
                t < 5 ? FaceSample(boxes: [box(0.5, 0.4, 0.12, cam: cam1080)], bodies: [atFace], at: t) : FaceSample(boxes: c.boxes, bodies: c.bodies, at: t)
            }, frame: { f, t in
                if let r = f.view(.close, key: .program(.horizontal), aspect: wide, t: t)?.rect, t >= 4.8 { rects.append(r) }
                // The last face is read at 4.8 s.
                if abs(t - 6.2) < 0.02 { usableAt14 = f.usable(.close, now: t) }
                if abs(t - 6.4) < 0.02 { usableAt16 = f.usable(.close, now: t) }
            })
            let still = rects.allSatisfy { $0 == rects[0] }
            if c.keeps {
                check("B8 \(c.name): still usable, view still", still && usableAt14 && usableAt16 && f.usable(.close, now: 8))
            } else {
                check("B8 \(c.name): view frozen, unusable from 1.5 s", still && usableAt14 && !usableAt16 && !f.usable(.close, now: 8))
            }
        }
    }

    // B9: a face at the picture's edge.
    do {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.03, y: 0.4))
        let r = f.view(.close, key: .program(.horizontal), aspect: wide, t: 0)!
        let inPicture = r.rect.minX >= -1e-9 && r.rect.maxX <= 1 + 1e-9 && r.rect.minY >= -1e-9 && r.rect.maxY <= 1 + 1e-9
        check("B9 face at x 0.03: crop inside the picture, edge-limited, not usable (the face sits on the crop's edge)",
              inPicture && r.edgeLimited && f.edgeLimited(.close) && !f.usable(.close, now: 0))
        let g = framer(cam1080, face: 0.12, at: CGPoint(x: 0.15, y: 0.4))
        check("B9 face at x 0.15: the close-up is edge-limited but usable", g.edgeLimited(.close) && g.usable(.close, now: 0))
    }

    // B10: two faces. A face seen beside the presenter never takes the crops, whatever its size; checked on every frame.
    do {
        let a = CGPoint(x: 0.35, y: 0.4), b = CGPoint(x: 0.7, y: 0.4)
        /// The followed face's centre on every frame.
        func twoFaces(_ bFrom: Double, _ bTo: Double, _ bh: Double) -> [Double] {
            var f = framer(cam1080, face: 0.12, at: a)
            var xs: [Double] = []
            run(&f, 0, 10, sample: { t in
                var boxes = [box(a.x, a.y, 0.12, cam: cam1080)]
                if t >= bFrom && t < bTo { boxes.insert(box(b.x, b.y, bh, cam: cam1080), at: 0) }
                return FaceSample(boxes: boxes, at: t)
            }, frame: { f, _ in xs.append(Double(f.face?.midX ?? 0)) })
            return xs
        }
        func offA(_ xs: [Double]) -> Int { xs.filter { abs($0 - a.x) >= 0.02 }.count }
        let short = twoFaces(2, 3.5, 0.19), big = twoFaces(2, 99, 0.18), bigger = twoFaces(2, 99, 0.156)
        var alt = framer(cam1080, face: 0.12, at: a)
        var altXs: [Double] = []
        var k = 0
        run(&alt, 0, 10, sample: { t in
            k += 1
            let ha = k % 2 == 0 ? 0.13 : 0.12, hb = k % 2 == 0 ? 0.12 : 0.13
            let boxes = [box(a.x, a.y, ha, cam: cam1080), box(b.x, b.y, hb, cam: cam1080)].sorted { $0.height > $1.height }
            return FaceSample(boxes: boxes, at: t)
        }, frame: { f, _ in altXs.append(Double(f.face?.midX ?? 0)) })
        check("B10 a face 1.6× bigger for 1.5 s never takes over", offA(short) == 0, "\(offA(short)) of \(short.count) frames off the presenter")
        check("B10 a face 1.5× bigger for 8 s never takes over", offA(big) == 0, "\(offA(big)) of \(big.count) frames off the presenter")
        check("B10 a face 1.3× bigger for 8 s never takes over", offA(bigger) == 0, "\(offA(bigger)) of \(bigger.count) frames off the presenter")
        check("B10 the biggest face alternating every reading never swaps", offA(altXs) == 0, "\(offA(altXs)) of \(altXs.count) frames off the presenter")
    }

    // B11: two framers fed the same readings draw the same crops.
    do {
        var traces: [[CGRect]] = []
        for _ in 0..<2 {
            var f = framer(cam1080, face: 0.12)
            var noise = Noise(r: 5)
            var trace: [CGRect] = []
            run(&f, 0, 20, sample: { t in
                FaceSample(boxes: [box(0.4 + 0.2 * sin(t / 3) + 0.01 * noise.next(), 0.4, 0.12, cam: cam1080)], at: t)
            }, frame: { f, t in
                for d in keys { if let r = f.view(d.shot, key: d.key, aspect: d.aspect, t: t)?.rect { trace.append(r) } }
            })
            traces.append(trace)
        }
        check("B11 same readings, same crops", !traces[0].isEmpty && traces[0] == traces[1], "\(traces[0].count) rectangles")
    }

    // B12: the slow walk of B3 on the 9:16 close-up, a third as wide as the 16:9 one.
    do {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.3, y: 0.4))
        var noise = Noise(r: 23)
        func x(_ t: Double) -> Double { 0.3 + 0.05 * max(0, t - 1) }
        let w16 = f.previewRect(.close, aspect: wide)!.width
        var lag = 0.0, speed = 0.0, worst = 0.0, inside = true, prev: Double?
        run(&f, 0, 9, sample: { t in
            FaceSample(boxes: [box(x(t) + 0.01 * noise.next(), 0.4 + 0.01 * noise.next(), 0.12, cam: cam1080)], at: t)
        }, frame: { f, t in
            guard let r = f.view(.close, key: .program(.vertical), aspect: tall, t: t)?.rect else { return }
            if let p = prev { speed = max(speed, abs(r.midX - p) * 30 / w16) }
            prev = r.midX
            let face = box(x(t), 0.4, 0.12, cam: cam1080)
            worst = max(worst, abs(face.midX - r.midX) / r.width)
            if face.minX < r.minX || face.maxX > r.maxX { inside = false }
            if t > 4 { lag = max(lag, (x(t) - r.midX) / 0.05) }
        })
        check("B12 9:16 close-up, slow walk: the face stays inside, lag at most 1.2 s, pans capped in the 16:9 crop's width",
              inside && lag <= 1.2 && speed <= 0.35 * 1.01,
              String(format: "lag %.2f s, face off centre by %.2f of the 9:16 width at most, speed %.3f (16:9 widths/s)", lag, worst, speed))
    }

    // B17: the e2e clip's walk measured against the TRUE face, not the readings: still 3 s, right at 0.082 camera
    // widths a second for 4 s, still 2 s, back for 4 s, still 5 s. Readings 5 times a second, each 80 ms after its
    // picture, ±0.4% noise, 5 noise seeds. For each shot and frame shape (worst seed): the share of frames from 3 s on
    // with the face wholly inside, the worst share of the face cut off, the lag behind the walk, how far the crop
    // passes where it comes to rest after each stop, and the p99 movement a frame (output pixels) over the last 2.5 s.
    struct WalkStats { var inside = 1.0, cut = 0.0, lag = 0.0, over = 0.0, p99 = 0.0 }
    let walkShapes = [Drawn(key: .program(.vertical), shot: .close, aspect: tall, size: both[.vertical]!),
                      Drawn(key: .program(.horizontal), shot: .close, aspect: wide, size: both[.horizontal]!),
                      Drawn(key: .program(.vertical), shot: .medium, aspect: tall, size: both[.vertical]!),
                      Drawn(key: .program(.horizontal), shot: .medium, aspect: wide, size: both[.horizontal]!)]
    func walk(speed: Double, noise amp: Double, seed: UInt64) -> [WalkStats] {
        let far = 0.3 + 4 * speed
        func x(_ t: Double) -> Double { t < 3 ? 0.3 : t < 7 ? 0.3 + speed * (t - 3) : t < 9 ? far : t < 13 ? far - speed * (t - 9) : 0.3 }
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.3, y: 0.4))
        var noise = Noise(r: seed)
        var rects: [[(t: Double, r: CGRect)]] = Array(repeating: [], count: walkShapes.count)
        var j = 0
        for i in 0..<(18 * 30) {
            let t = Double(i) / 30
            while Double(j) * 0.2 + 0.08 <= t + 1e-9 {
                let at = Double(j) * 0.2
                f.ingest(FaceSample(boxes: [box(x(at) + amp * noise.next(), 0.4 + amp * noise.next(), 0.12 * (1 + amp * noise.next()), cam: cam1080)], at: at))
                j += 1
            }
            for (k, d) in walkShapes.enumerated() { if let r = f.view(d.shot, key: d.key, aspect: d.aspect, t: t)?.rect { rects[k].append((t, r)) } }
        }
        return walkShapes.indices.map { k in
            let d = walkShapes[k], rs = rects[k]
            var st = WalkStats(), inside = 0, n = 0, moves: [Double] = []
            for (i, e) in rs.enumerated() {
                // Lag behind the face once a walk is under way, in seconds.
                if (e.t >= 4 && e.t < 7) || (e.t >= 10 && e.t < 13) { st.lag = max(st.lag, (x(e.t) - e.r.midX) * (e.t < 7 ? 1 : -1) / speed) }
                if e.t >= 3 - 1e-9 {
                    let face = box(x(e.t), 0.4, 0.12, cam: cam1080)
                    n += 1
                    if e.r.insetBy(dx: -1e-9, dy: -1e-9).contains(face) { inside += 1 }
                    st.cut = max(st.cut, min(1, (max(0, e.r.minX - face.minX) + max(0, face.maxX - e.r.maxX)) / face.width))
                }
                if e.t >= 15.5 - 1e-9, i > 0 {
                    let p = rs[i - 1].r
                    moves.append(max(abs(e.r.midX - p.midX) / e.r.width * d.size.width, abs(e.r.midY - p.midY) / e.r.height * d.size.height))
                }
            }
            // Overshoot: past where the crop rests at the end of each still spell, in the direction it travelled.
            for (from, to, dir) in [(7.0, 9.0, 1.0), (13.0, 18.0, -1.0)] {
                let spell = rs.filter { $0.t >= from - 1e-9 && $0.t < to - 1e-9 }
                guard let rest = spell.last?.r.midX else { continue }
                for e in spell { st.over = max(st.over, (e.r.midX - rest) * dir / e.r.width) }
            }
            moves.sort()
            st.p99 = moves.isEmpty ? 99 : moves[Int(Double(moves.count - 1) * 0.99)]
            st.inside = n == 0 ? 0 : Double(inside) / Double(n)
            return st
        }
    }
    func worst(_ runs: [[WalkStats]]) -> [WalkStats] {
        walkShapes.indices.map { k in
            runs.map { $0[k] }.reduce(WalkStats()) { a, b in
                WalkStats(inside: min(a.inside, b.inside), cut: max(a.cut, b.cut), lag: max(a.lag, b.lag), over: max(a.over, b.over), p99: max(a.p99, b.p99))
            }
        }
    }
    func describe(_ w: [WalkStats]) -> String {
        zip(walkShapes, w).map { d, st in
            String(format: "%@ %@ %.1f%% inside, worst cut %.0f%%, lag %.2f s, overshoot %.2f%%, still p99 %.2f px",
                   d.aspect < 1 ? "9:16" : "16:9", d.shot.title, st.inside * 100, st.cut * 100, st.lag, st.over * 100 + 0, st.p99)
        }.joined(separator: "; ")
    }
    do {
        let w = worst([41, 7, 99, 123, 2024].map { walk(speed: 0.082, noise: 0.004, seed: $0) })
        let ok = zip(walkShapes, w).allSatisfy { d, st in
            st.inside >= (d.aspect < 1 && d.shot == .close ? 0.95 : 1.0) - 1e-9 && st.over <= 1e-4 && st.p99 <= 0.01
        }
        check("B17 the e2e walk (0.082 W/s, readings 80 ms late, worst of 5 seeds): the true face inside the 9:16 close-up on 95% of frames, every other crop on all; no overshoot; still p99 0 px",
              ok, describe(w))
    }

    // B13: the presenter's face missed with someone beside them (a co-host 0.115 across the table, or shoulder to
    // shoulder): one missed reading at 4 s, then 1.4 s missed from 6 s. The crops stay on the presenter every frame.
    for (px, ox) in [(0.35, 0.70), (0.42, 0.58)] {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: px, y: 0.4))
        var off = 0, n = 0
        run(&f, 0, 10, sample: { t in
            let missed = abs(t - 4) < 0.01 || (t >= 6 - 1e-9 && t < 7.4 - 1e-9)
            var boxes = [box(ox, 0.4, 0.115, cam: cam1080)]
            if !missed { boxes.insert(box(px, 0.4, 0.12, cam: cam1080), at: 0) }
            return FaceSample(boxes: boxes, at: t)
        }, frame: { f, _ in
            n += 1
            if abs(Double(f.face?.midX ?? 0) - px) >= 0.02 { off += 1 }
        })
        check("B13 presenter at \(px), someone at \(ox): missed readings never move the crops to them",
              off == 0 && f.usable(.close, now: 10), "\(off) of \(n) frames off the presenter")
    }

    // B14: the presenter leaves at 5 s with a co-host in view the whole time. The crops are unusable 1.5 s after the
    // last reading and never go to the co-host (8 s as the only face). Back at 13 s where they were: usable at once;
    // somewhere else (2.2 face widths away): usable after 3 s as the only new face, not before.
    for (name, back) in [("where they were", 0.36), ("somewhere else", 0.2)] {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.35, y: 0.4))
        var onCoHost = 0, usableGone = 0, usableBack: [(t: Double, ok: Bool)] = []
        run(&f, 0, 18, sample: { t in
            var boxes = [box(0.7, 0.4, 0.115, cam: cam1080)]
            if t < 5 - 1e-9 { boxes.insert(box(0.35, 0.4, 0.12, cam: cam1080), at: 0) }
            if t >= 13 - 1e-9 { boxes.insert(box(back, 0.4, 0.12, cam: cam1080), at: 0) }
            return FaceSample(boxes: boxes, at: t)
        }, frame: { f, t in
            if abs(Double(f.face?.midX ?? 0) - 0.7) < 0.1 { onCoHost += 1 }
            if t >= 4.8 + 1.5 + 1e-6 && t < 13 - 1e-6 && (f.usable(.close, now: t) || f.usable(.medium, now: t)) { usableGone += 1 }
            if t >= 13 - 1e-6 { usableBack.append((t, f.usable(.close, now: t) && f.usable(.medium, now: t))) }
        })
        let firstOK = usableBack.first { $0.ok }?.t ?? 99
        let stays = usableBack.filter { $0.t >= firstOK }.allSatisfy(\.ok)
        let from = back == 0.36 ? 13.0 : 16.0
        check("B14 the presenter leaves with a co-host in view: unusable from 1.5 s, never on the co-host; back \(name): usable again from \(f3(from - 13)) s",
              onCoHost == 0 && usableGone == 0 && firstOK >= from - 1e-6 && firstOK <= from + 0.2 && stays,
              "\(usableGone) usable frames while gone, \(onCoHost) on the co-host, usable again \(f3(firstOK - 13)) s after coming back")
    }

    // B15: the presenter leaves at 5 s; at 7 s someone new sits down alone (never seen beside them). They take over
    // after 3 s as the only face, not before.
    do {
        var f = framer(cam1080, face: 0.12, at: CGPoint(x: 0.35, y: 0.4))
        var early = 0, tookAt: Double?
        run(&f, 0, 12, sample: { t in
            if t < 5 - 1e-9 { return FaceSample(boxes: [box(0.35, 0.4, 0.12, cam: cam1080)], at: t) }
            return FaceSample(boxes: t >= 7 - 1e-9 ? [box(0.65, 0.4, 0.11, cam: cam1080)] : [], at: t)
        }, frame: { f, t in
            let onNew = abs(Double(f.face?.midX ?? 0) - 0.65) < 0.02
            if onNew && tookAt == nil { tookAt = t }
            if t < 10 - 1e-6 && (onNew || (t > 6.4 && f.usable(.medium, now: t))) { early += 1 }
        })
        check("B15 someone new alone takes over after 3 s, not before", early == 0 && abs((tookAt ?? 99) - 10) < 0.05 && f.usable(.medium, now: 12),
              "took over at \(f3(tookAt ?? 99)) s, \(early) frames early")
    }

    // B16: a re-plan withdraws the close-up while it's drawn (1080p, the face shrinks from 0.115 to 0.09: "needs a 4K
    // camera"). The close-up keeps its last view for 1 s, then draws nothing (the camera's picture); a key not drawn in
    // the last 0.5 s draws nothing at once.
    do {
        var f = framer(cam1080, face: 0.115)
        var lastView: VirtualView?, withdrawnAt: Double?, heldFrom: VirtualView?, isoNil = false
        var held: [VirtualView?] = [], after: [VirtualView?] = []
        run(&f, 0, 10, sample: { t in FaceSample(boxes: [box(0.5, 0.4, t < 2 ? 0.115 : 0.09, cam: cam1080)], at: t) },
            frame: { f, t in
                if t < 1 { _ = f.view(.close, key: .iso, aspect: wide, t: t) }
                let v = f.view(.close, key: .program(.horizontal), aspect: wide, t: t)
                if withdrawnAt == nil, !f.plan(.close).available {
                    withdrawnAt = t; heldFrom = lastView
                    isoNil = f.view(.close, key: .iso, aspect: wide, t: t) == nil
                }
                if let w = withdrawnAt {
                    if t - w <= 1.0 + 1e-6 { held.append(v) } else if t - w > 1.0 + 0.04 { after.append(v) }
                }
                lastView = v
            })
        let ok = heldFrom != nil && !held.isEmpty && held.allSatisfy { $0 == heldFrom } && !after.isEmpty && after.allSatisfy { $0 == nil } && isoNil
        check("B16 a withdrawn close-up holds its last view for 1 s, then the camera's picture; a key unused for 0.5 s at once", ok,
              "withdrawn at \(f3(withdrawnAt ?? -1)) s (\(f.plan(.close).reason ?? "offered")), \(held.count) frames held, \(after.count) after")
    }

    // MARK: C. A headless engine (VirtualEngineChecks.swift)

    virtualEngineChecks(check)

    // MARK: D. The shuffle (VirtualPlannerChecks.swift)

    virtualPlannerChecks(check)

    // MARK: E. Settings

    do {
        let dec = JSONDecoder()
        let empty = try? dec.decode(VirtualAngleSettings.self, from: Data("{}".utf8))
        let odd = try? dec.decode(VirtualAngleSettings.self, from: Data(#"{"cameras":{"A":{"close":false,"zoom":3}},"later":1}"#.utf8))
        check("E an empty virtual section ({}) decodes with the defaults: no cameras, recordCrops off", empty == VirtualAngleSettings() && empty?.recordCrops == false && empty?.cameras.isEmpty == true)
        check("E missing and unknown fields are tolerated", odd?.cameras["A"] == VirtualShots(medium: true, close: false))
        var s = VirtualAngleSettings()
        s.cameras["B"] = VirtualShots(medium: false, close: true)
        s.recordCrops = true
        let back = (try? JSONEncoder().encode(s)).flatMap { try? dec.decode(VirtualAngleSettings.self, from: $0) }
        check("E a round trip keeps the values", back == s)
    }

    // MARK: F. The frame's own Layer › Crop and rotation

    /// FNV-1a over numbers printed to 9 decimals: plans and landing rects compared with the numbers before Layer › Crop
    /// was taken into account.
    func digest(_ v: [Double]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in v.map({ String(format: "%.9f", $0) }).joined(separator: ",").utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
    do {
        var nums: [Double] = []
        let cams = [cam1080, cam4K, CGSize(width: 1920, height: 1440)]
        let spots = [CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.03, y: 0.4), CGPoint(x: 0.15, y: 0.4), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.9)]
        for cam in cams {
            for h in [0.12, 0.10, 0.09] {
                for frames in [both, [.horizontal: CGSize(width: 960, height: 540)]] {
                    for p in spots {
                        let f = framer(cam, face: h, frames: frames, at: p)
                        for s in VirtualShot.allCases {
                            let pl = f.plan(s)
                            nums += [pl.available ? 1 : 0, pl.zoom, pl.height, pl.faceInCrop, pl.enlargement[.horizontal] ?? 0, pl.enlargement[.vertical] ?? 0]
                            for a in [wide, tall] {
                                let r = f.previewRect(s, aspect: a) ?? .zero
                                nums += [r.minX, r.minY, r.width, r.height].map(Double.init)
                            }
                            nums.append(f.usable(s, now: 0) ? 1 : 0)
                            nums.append(f.edgeLimited(s) ? 1 : 0)
                        }
                    }
                }
            }
        }
        // Recorded before the frame's crop was taken into account (e34d576f78dceebe); the drawn trace of a moving,
        // growing face was unchanged by that work too (d7ecd4b96649c2fc over 7200 numbers, before the D1 lead).
        let d = digest(nums)
        check("F1 no Layer › Crop: plans, landing rects, usable and edge flags exactly as before (\(nums.count) numbers, 270 cases)",
              d == 0xe34d576f78dceebe, String(d, radix: 16))
    }

    // F2: a Layer › Crop of left 10%, right 10%, top 5%, bottom 5% on a 4K camera. The zoom is measured against what the
    // wide shows (0.8 of the camera's height); a bigger face in the cut-off strip at the left, seen first and kept in
    // view, is never followed; the presenter walks right past the crop's edge and back; nothing drawn on any key or
    // shape (or in a landing rect, or while waiting for a face) ever leaves the crop.
    do {
        let shown = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)
        var f = VirtualFramer()
        f.setGeometry(camera: cam4K, frames: both, shots: VirtualShots(), shown: shown)
        let inside = { (r: CGRect) in r.minX >= shown.minX - 1e-9 && r.maxX <= shown.maxX + 1e-9 && r.minY >= shown.minY - 1e-9 && r.maxY <= shown.maxY + 1e-9 }
        var outside = 0, drawn = 0, onStranger = 0
        let all = keys + [Drawn(key: .program(.vertical), shot: .close, aspect: tall, size: both[.vertical]!)]
        for d in all {
            if let r = f.view(d.shot, key: d.key, aspect: d.aspect, t: 0)?.rect { drawn += 1; if !inside(r) { outside += 1 } }
        }
        let waited = drawn
        let stranger = box(0.05, 0.4, 0.16, cam: cam4K)
        func x(_ t: Double) -> Double { t < 2 ? 0.5 : t < 8 ? 0.5 + 0.08 * (t - 2) : t < 10 ? 0.98 : max(0.5, 0.98 - 0.08 * (t - 10)) }
        var plan: ShotPlan?, locked: Double?
        run(&f, 0, 20, sample: { t in
            FaceSample(boxes: t < 0.5 ? [stranger] : [stranger, box(x(t), 0.4, 0.12, cam: cam4K)].sorted { $0.height > $1.height }, at: t)
        }, frame: { f, t in
            if plan == nil, f.plan(.medium).available { plan = f.plan(.medium); locked = f.lockedFace }
            if let fx = f.face?.midX, abs(fx - 0.05) < 0.05 { onStranger += 1 }
            for d in all {
                if let r = f.view(d.shot, key: d.key, aspect: d.aspect, t: t)?.rect { drawn += 1; if !inside(r) { outside += 1 } }
                if let r = f.previewRect(d.shot, aspect: d.aspect) { drawn += 1; if !inside(r) { outside += 1 } }
            }
        })
        let m = plan
        check("F2 a Layer › Crop of 10/10/5/5% on 4K: the zoom is measured against what the wide shows (face 0.15 of it)",
              m.map { near($0.zoom, 1.4, 1e-6) && near($0.height, 0.8 / 1.4, 1e-6) && near($0.faceInCrop, 0.21, 1e-6) } == true && near(locked ?? 0, 0.15, 1e-6),
              "face \(f3(locked ?? 0)) of the wide, medium zoom \(f3(m?.zoom ?? 0)), crop height \(f3(m?.height ?? 0)), face in crop \(f3(m?.faceInCrop ?? 0))")
        check("F2 nothing drawn outside the crop (waiting, every key and shape, landing rects), the face outside it never followed",
              waited > 0 && outside == 0 && onStranger == 0 && f.usable(.close, now: 20) && abs((f.face?.midX ?? 0) - 0.5) < 0.02,
              "\(outside) of \(drawn) rects outside, \(onStranger) frames on the face outside, back on the presenter at x \(f3(Double(f.face?.midX ?? 0)))")
    }

    // F3: a rotated frame makes no crops, with a plain reason; straightened, they come back.
    do {
        var f = framer(cam1080, face: 0.12)
        f.setGeometry(camera: cam1080, frames: both, shots: VirtualShots(), turned: true)
        let turned = VirtualShot.allCases.allSatisfy { !f.plan($0).available && f.plan($0).reason == "The frame is rotated: set Layer › Rotation to 0°" }
        let none = f.view(.close, key: .program(.horizontal), aspect: wide, t: 0) == nil && !f.usable(.close, now: 0)
        f.setGeometry(camera: cam1080, frames: both, shots: VirtualShots())
        check("F3 a rotated frame: no crops, with a plain reason; straightened, both come back", turned && none && f.plan(.medium).available && f.plan(.close).available,
              f3(f.plan(.close).zoom))
    }

    // MARK: G. Use 4K and recording

    // G1: Use 4K is offered only when the chooser that opens the camera gives a 4K picture near 16:9 at the show's
    // frame rate; a 4K request never trades the frame rate away, and a 1080p request opens what it did before.
    do {
        typealias F = CameraSource.FormatInfo
        func fmt(_ w: Int, _ h: Int, _ r: Double) -> F { F(width: w, height: h, maxFPS: r) }
        func opens(_ list: [F], _ w: Int, _ h: Int, _ fps: Int) -> String {
            CameraSource.chooseFormat(list, width: w, height: h, fps: fps).map { "\(list[$0].width)x\(list[$0].height)@\(Int(list[$0].maxFPS))" } ?? "none"
        }
        let slow4K = [fmt(1280, 720, 30), fmt(1920, 1080, 30), fmt(3840, 2160, 15)]
        let cases: [(String, [F], Int, Bool, String)] = [
            ("4K at 15 fps only", slow4K, 30, false, "1920x1080@30"),
            ("4K at 24 fps in a 30 fps show", [fmt(1920, 1080, 30), fmt(3840, 2160, 24)], 30, false, "1920x1080@30"),
            ("4K at 24 fps in a 24 fps show", [fmt(1920, 1080, 30), fmt(3840, 2160, 24)], 24, true, "3840x2160@24"),
            ("4K at 30 fps", [fmt(1920, 1080, 30), fmt(3840, 2160, 30)], 30, true, "3840x2160@30"),
            ("4K at 30 fps in a 60 fps show", [fmt(1920, 1080, 60), fmt(3840, 2160, 30)], 60, false, "1920x1080@60"),
            ("4:3 only (4032x3024)", [fmt(1920, 1080, 30), fmt(4032, 3024, 30)], 30, false, "4032x3024@30"),
            ("17:9 (4096x2160)", [fmt(1920, 1080, 30), fmt(4096, 2160, 30)], 30, true, "4096x2160@30"),
            ("1080p only", [fmt(1280, 720, 30), fmt(1920, 1080, 30)], 30, false, "1920x1080@30"),
        ]
        var bad: [String] = []
        for (name, list, fps, offered, open) in cases {
            let o = CameraSource.offers4K(list, fps: fps), got = opens(list, 3840, 2160, fps)
            if o != offered || got != open { bad.append("\(name): offered \(o), opens \(got)") }
        }
        // 1080p requests keep the old chooser (a slower 1080p still beats a far smaller size).
        let p1 = opens(slow4K, 1920, 1080, 30), p2 = opens([fmt(320, 240, 30), fmt(1920, 1080, 25)], 1920, 1080, 30)
        if p1 != "1920x1080@30" || p2 != "1920x1080@25" { bad.append("1080p requests open \(p1) and \(p2)") }
        check("G1 Use 4K only where the camera opens 4K near 16:9 at the show's rate; 4K requests keep the rate, 1080p ones are unchanged",
              bad.isEmpty, bad.isEmpty ? "\(cases.count) format lists, 2 1080p requests" : bad.joined(separator: "; "))
    }

    // G2: the close-up's own file keeps its last framing when a re-plan drops the shot mid-take (the presenter leans
    // in until the camera already shows a close-up), instead of the camera's whole picture under the shot's name.
    do {
        let rig = VirtualRig(cameraID: UUID())
        rig.setGeometry(camera: cam1080, frames: both, shots: VirtualShots())
        let src = VirtualAngleSource(shot: .close, rig: rig)
        let pic = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: cam1080))
        var framedBefore = 0, wholeAfter = 0, after = 0, droppedAt: Double?
        for i in 0..<(12 * 30) {
            let t = Double(i) / 30
            if i % 6 == 0 { rig.setFace(FaceSample(boxes: [box(0.5, 0.4, t < 3 ? 0.12 : 0.26, cam: cam1080)], at: t)) }
            let out = src.derive(pic, at: CMTime(seconds: t, preferredTimescale: 600), canvas: .horizontal, frame: nil, role: .iso)
            let whole = out.extent.width >= cam1080.width - 0.5
            if droppedAt == nil, !rig.status(.close).available { droppedAt = t }
            if t < 3, !whole { framedBefore += 1 }
            if let d = droppedAt, t >= d { after += 1; if whole { wholeAfter += 1 } }
        }
        check("G2 a close-up dropped mid-take keeps its last framing in its own file, never the camera's whole picture",
              framedBefore == 90 && droppedAt != nil && after > 60 && wholeAfter == 0,
              "framed \(framedBefore)/90 frames before; dropped at \(f3(droppedAt ?? -1)) s (\(rig.status(.close).reason ?? "offered")); \(wholeAfter) of \(after) frames after it show the whole picture")
    }

    print(failures == 0 ? "virtual angles: all checks passed" : "virtual angles: \(failures) check(s) failed")
    return failures == 0
}

/// `fcverify face <png>`: the biggest face Vision finds in a picture, top-left 0...1, as one JSON line.
func faceCheck(_ path: String?) -> Bool {
    guard let path, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print(#"{"error":"could not read the picture"}"#)
        return false
    }
    let req = VNDetectFaceRectanglesRequest()
    req.revision = VNDetectFaceRectanglesRequestRevision3
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    var out: [String: Any] = ["width": img.width, "height": img.height, "faces": req.results?.count ?? 0]
    let face = (req.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    if let b = face?.boundingBox {
        out["x"] = b.minX; out["y"] = 1 - b.maxY; out["w"] = b.width; out["h"] = b.height
        if let y = face?.yaw { out["yaw"] = y.doubleValue * 180 / .pi }
    }
    let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
    return face != nil
}
