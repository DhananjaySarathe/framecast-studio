import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import FramecastEngine

/// A made-up camera: a grey room with a red block where the presenter's face is (box top-left, 0...1). Sources are
/// only ever handed to the engine with `setExternalSource` or a stand-in, so no device can open.
final class PresenterSource: VideoSource {
    let id: UUID
    let state: SourceState = .running
    let nativeSize: CGSize
    private let picture: CIImage
    init(id: UUID, size: CGSize, face: CGRect) {
        self.id = id; nativeSize = size
        let room = CIImage(color: CIColor(red: 0.55, green: 0.55, blue: 0.55)).cropped(to: CGRect(origin: .zero, size: size))
        let block = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: face.minX * size.width, y: (1 - face.maxY) * size.height, width: face.width * size.width, height: face.height * size.height))
        picture = block.composited(over: room)
    }
    func image(at time: CMTime) -> CIImage? { picture }
    func start() {}
    func stop() {}
}

/// An 8-bit RGBA copy of a picture, read top-left.
private struct Pixels {
    let w: Int, h: Int
    private var data: [UInt8]
    init?(_ img: CGImage?) {
        guard let img else { return nil }
        w = img.width; h = img.height
        data = [UInt8](repeating: 0, count: w * h * 4)
        let (w, h) = (w, h)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
    }
    subscript(x: Int, y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    /// The box of pixels matching `test`, top-left pixels (nil if none).
    func bounds(_ test: ((Int, Int, Int)) -> Bool) -> CGRect? {
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where test(self[x, y]) { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        return x1 < 0 ? nil : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }
    /// Pixels on the outer rows and columns more than `tol` off `ref` in any channel.
    func edgeMisses(_ ref: (Int, Int, Int), tol: Int) -> Int {
        var n = 0
        func off(_ p: (Int, Int, Int)) -> Bool { abs(p.0 - ref.0) > tol || abs(p.1 - ref.1) > tol || abs(p.2 - ref.2) > tol }
        for x in 0..<w { if off(self[x, 0]) { n += 1 }; if off(self[x, h - 1]) { n += 1 } }
        for y in 0..<h { if off(self[0, y]) { n += 1 }; if off(self[w - 1, y]) { n += 1 } }
        return n
    }
}

/// `fcverify virtual`, group C: crops drawn by a headless engine that is never started, from a procedural 4K
/// presenter registered with `setExternalSource`. No camera record is ever synced, so no device can open.
func virtualEngineChecks(_ report: (String, Bool, String) -> Void) {
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
    func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    let engine = Engine()
    let cam = CGSize(width: 3840, height: 2160)
    let h16 = CGSize(width: 1920, height: 1080), v916 = CGSize(width: 1080, height: 1920)
    let faceH = 0.12, faceW = 0.12 * cam.height / cam.width
    let face = CGRect(x: 0.5 - faceW / 2, y: 0.4 - faceH / 2, width: faceW, height: faceH)
    let camID = UUID()
    engine.setExternalSource(camID, PresenterSource(id: camID, size: cam, face: face))
    let rig = VirtualRig(cameraID: camID)
    rig.setGeometry(camera: cam, frames: [.horizontal: h16, .vertical: v916], shots: VirtualShots())
    rig.setFace(FaceSample(boxes: [face], at: HostClock.seconds()))
    let medium = VirtualAngleSource(shot: .medium, rig: rig), close = VirtualAngleSource(shot: .close, rig: rig)
    engine.setExternalSource(medium.id, medium)
    engine.setExternalSource(close.id, close)

    func onAir(_ id: UUID) {
        for c in CanvasKind.allCases { engine.setProgram([SceneItem(sourceID: id, transform: .full, fit: .fill)], for: c, transition: .cut, durationMs: 0) }
    }
    func shot(_ c: CanvasKind) -> Pixels? { Pixels(engine.programSnapshot(c, width: c == .horizontal ? 1920 : 1080)) }
    let isRed: ((Int, Int, Int)) -> Bool = { $0.0 > 150 && $0.1 < 90 && $0.2 < 90 }

    // C1: the face lands where the plan puts it, on both canvases, with no seam at the frame's edge.
    let pm = rig.status(.medium), pc = rig.status(.close)
    check("C1 4K presenter, face 0.12: medium zoom 1.417, close 2.5, both usable",
          abs(pm.zoom - 1.417) < 0.001 && abs(pc.zoom - 2.5) < 1e-6 && rig.usable(.medium, now: HostClock.seconds()) && rig.usable(.close, now: HostClock.seconds()),
          String(format: "medium %.3f, close %.3f", pm.zoom, pc.zoom))
    for (src, plan) in [(medium, pm), (close, pc)] {
        onAir(src.id)
        for c in CanvasKind.allCases {
            let size = c == .horizontal ? h16 : v916
            guard let px = shot(c), let got = px.bounds(isRed) else { check("C1 \(src.shot.title) on \(c.title)", false, "no face block drawn"); continue }
            // Face height in the frame from the plan; eyes (40% down the face) on the shot's eye line; centred.
            let bh = plan.faceInCrop * size.height
            let want = CGRect(x: (size.width - bh) / 2, y: (src.shot.eyeLine(aspect: size.width / size.height) - 0.4 * plan.faceInCrop) * size.height, width: bh, height: bh)
            let err = [got.minX - want.minX, got.minY - want.minY, got.maxX - want.maxX, got.maxY - want.maxY].map { abs(Double($0)) }.max()!
            let ref = px[size.width > size.height ? 100 : 60, Int(size.height) / 2]
            let seam = px.edgeMisses(ref, tol: 6)
            let e = plan.enlargement[c] ?? 0
            check("C1 \(src.shot.title) on \(c.title) (enlarged \(String(format: "%.2f", e))×): face block within 2 px, no seam",
                  err <= 2 && seam == 0,
                  "block x \(Int(got.minX)) y \(Int(got.minY)) \(Int(got.width))×\(Int(got.height)) vs \(f1(want.minX)), \(f1(want.minY)), \(f1(want.width)); off by \(f1(err)) px; \(seam) edge pixels off the room's grey \(ref)")
        }
    }
    // Control: a plain crop of the same area, drawn by the compositor, does leave a seam (so the check can see one).
    do {
        let comp = Compositor()
        guard let r = rig.previewRect(.close, aspect: v916.width / v916.height),
              let pic = PresenterSource(id: UUID(), size: cam, face: face).image(at: .zero) else { check("C1 control", false, "no crop"); return }
        let px = CGRect(x: r.minX * cam.width, y: (1 - r.maxY) * cam.height, width: r.width * cam.width, height: r.height * cam.height)
        let plain = pic.cropped(to: px).transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY))
        let drawn = comp.renderItem(SceneItem(sourceID: UUID(), transform: .full, fit: .fill), input: LayerInput(image: plain), canvas: v916)!
        let img = comp.cgImage(drawn, canvas: v916, scale: 1)
        let p = Pixels(img)
        let seam = p.map { $0.edgeMisses($0[60, 960], tol: 6) } ?? 0
        check("C1 control: a plain crop drawn the same way shows a seam", seam > 0, "\(seam) edge pixels off grey")
    }
    // The studio's rebuild hands the rig the camera's configured size every second: once a picture was drawn, its
    // size wins (a 1080p figure would re-plan the 4K close-up to 2.0 until the next frame). A stand-in that sends 4K
    // while 1080p is configured: configured, drawn, then the rebuild again.
    do {
        let hd = CGSize(width: 1920, height: 1080), frames = [CanvasKind.horizontal: h16, .vertical: v916]
        rig.setGeometry(camera: hd, frames: frames, shots: VirtualShots())
        onAir(close.id); _ = shot(.horizontal)
        rig.setGeometry(camera: hd, frames: frames, shots: VirtualShots())
        let z = rig.status(.close).zoom
        check("C1 a rebuild with the configured size keeps the plan made from the picture drawn",
              abs(z - pc.zoom) < 1e-9 && rig.usable(.close, now: HostClock.seconds()), String(format: "close zoom %.3f", z))
        // The camera asked for another size (Use 4K, Back to 1080p): the plan follows it before any crop is drawn,
        // not the old picture's size; the next picture drawn wins again.
        rig.setGeometry(camera: CGSize(width: 1280, height: 720), frames: frames, shots: VirtualShots())
        let asked = rig.status(.close)
        _ = shot(.horizontal)
        let drawn = rig.status(.close)
        rig.setGeometry(camera: cam, frames: frames, shots: VirtualShots())
        check("C1 a new size asked of the camera re-plans at once, before a crop is drawn; the next picture wins again",
              !asked.available && drawn.available && abs(drawn.zoom - pc.zoom) < 1e-9 && abs(rig.status(.close).zoom - pc.zoom) < 1e-9,
              "asked 720p: \(asked.reason ?? "offered"); drawn 4K: " + String(format: "close zoom %.3f", drawn.zoom))
    }

    // C2: swap the camera for a green still; the next picture of a crop is green (no stale camera).
    onAir(close.id)
    _ = shot(.horizontal)
    let green = CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: cam))
    engine.setExternalSource(camID, StaticImageSource(id: camID, image: green))
    do {
        let p = shot(.horizontal), still = Pixels(engine.sourceSnapshot(close.id, maxSide: 640))
        let mid = p?[960, 540], tile = still?[still!.w / 2, still!.h / 2]
        let isGreen: ((Int, Int, Int)?) -> Bool = { $0.map { $0.1 > 150 && $0.0 < 90 && $0.2 < 110 } ?? false }
        check("C2 the camera swapped for a green still: the crop shows green at once, on air and in its tile",
              isGreen(mid) && isGreen(tile) && p?.bounds(isRed) == nil, "program \(mid.map { "\($0)" } ?? "none"), tile \(tile.map { "\($0)" } ?? "none")")
    }
    engine.setExternalSource(camID, PresenterSource(id: camID, size: cam, face: face))

    // C3: the camera's record carries an invert LUT; the crop comes out inverted too. The camera's record is a
    // colour (never a device), and the stand-in hook swaps in the presenter, which also checks the hook runs first.
    let cubePath = (ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()) + "/framecast-virtual-invert.cube"
    var cube = "TITLE \"invert\"\nLUT_3D_SIZE 2\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
    try? cube.write(toFile: cubePath, atomically: true, encoding: .utf8)
    let silentID = UUID()
    engine.standIn = { r in
        if r.id == camID { return .video(PresenterSource(id: camID, size: cam, face: face)) }
        if r.id == silentID { return .silent }
        return nil
    }
    let camRecord = SourceRecord(id: camID, name: "Camera", kind: .color(RGBA(0, 0, 1)), lut: CameraLUT(path: cubePath))
    let silentRecord = SourceRecord(id: silentID, name: "Tone", kind: .tone)
    engine.sync(sources: [camRecord, silentRecord], fpsHint: 30)
    check("C3 the stand-in hook is asked first: the camera's record draws the stand-in, a silenced sound is a silent stand-in",
          engine.sourceTypeName(of: camID) == "PresenterSource" && engine.sourceTypeName(of: silentID) == "SilentAudioSource" && engine.state(of: silentID) == .running,
          "\(engine.sourceTypeName(of: camID) ?? "none"), \(engine.sourceTypeName(of: silentID) ?? "none")")
    do {
        let p = shot(.horizontal)
        let block = p?.bounds { $0.0 < 90 && $0.1 > 150 && $0.2 > 150 }        // red inverted is cyan
        let room = p?[100, 540]
        check("C3 the camera's LUT reaches its crop", block != nil && p?.bounds(isRed) == nil && (room.map { $0.0 < 130 } ?? false),
              "cyan block \(block.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none"), room \(room.map { "\($0)" } ?? "none")")
    }
    engine.restartSource(camID)
    do {
        let p = shot(.horizontal)
        check("C3 a restart goes through the stand-in again, and the crop follows the new picture",
              engine.sourceTypeName(of: camID) == "PresenterSource" && p?.bounds { $0.0 < 90 && $0.1 > 150 && $0.2 > 150 } != nil,
              engine.sourceTypeName(of: camID) ?? "none")
    }
    // The rest without the LUT (same kind: no restart).
    var plainRecord = camRecord; plainRecord.lut = nil
    engine.sync(sources: [plainRecord], fpsHint: 30)
    try? FileManager.default.removeItem(atPath: cubePath)

    // C5: stills of a crop on another thread while the program is drawn and faces arrive: nothing locks up.
    do {
        let until = HostClock.seconds() + 2
        let group = DispatchGroup()
        let counts = NSLock()
        var stills = 0, programs = 0, faces = 0
        group.enter()
        DispatchQueue.global().async {
            while HostClock.seconds() < until { _ = engine.sourceSnapshot(close.id, maxSide: 640); counts.lock(); stills += 1; counts.unlock() }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            while HostClock.seconds() < until { _ = engine.programSnapshot(.horizontal, width: 480); counts.lock(); programs += 1; counts.unlock() }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            while HostClock.seconds() < until {
                rig.setFace(FaceSample(boxes: [face], at: HostClock.seconds()))
                counts.lock(); faces += 1; counts.unlock()
                usleep(20_000)
            }
            group.leave()
        }
        let done = group.wait(timeout: .now() + 5) == .success
        counts.lock(); let (s, p, f) = (stills, programs, faces); counts.unlock()
        check("C5 2 s of crop stills, program snapshots and face readings at once finish within 5 s", done && s > 0 && p > 0,
              "\(s) stills, \(p) program snapshots, \(f) readings")
        if !done { return }
    }

    // C6: drawing a crop costs about what drawing the camera does.
    do {
        var base: [Double] = [], crop: [Double] = []
        for i in 0..<620 {
            let isCrop = i % 2 == 1
            onAir(isCrop ? close.id : camID)
            let t0 = HostClock.seconds()
            _ = engine.programSnapshot(.horizontal, width: 1920)
            let ms = (HostClock.seconds() - t0) * 1000
            if i >= 20 { if isCrop { crop.append(ms) } else { base.append(ms) } }
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        let d = median(crop) - median(base)
        check("C6 300 frames: a crop's median render time is within 1 ms of the camera's", d <= 1,
              String(format: "camera %.2f ms, crop %.2f ms, difference %+.2f ms (snapshot with readback)", median(base), median(crop), d))
    }

    // C8: Move from the close-up filling the frame to its camera in a small frame: one picture, so the frame moves
    // (at the start it is still full size, showing the camera) rather than the close-up fading out underneath.
    do {
        rig.setFace(FaceSample(boxes: [face], at: HostClock.seconds()))
        onAir(close.id)
        _ = shot(.horizontal)
        let small = ItemTransform(x: 0.6, y: 0.6, width: 0.35, height: 0.35)
        engine.setProgram([SceneItem(sourceID: camID, transform: small, fit: .fill)], for: .horizontal, transition: .move, durationMs: 3_600_000)
        let b = shot(.horizontal)?.bounds(isRed)
        let wideH = faceH * 1080, closeH = pc.faceInCrop * 1080
        check("C8 Move from the close-up to its camera in a smaller frame moves the frame (no crossfade)",
              b.map { abs(Double($0.height) - wideH) <= 3 } ?? false,
              "face block \(b.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none") at the start; the camera's is \(Int(wideH)) px, the close-up's \(Int(closeH))")
    }

    // C4: take the crop away, then the camera; a crop of a crop is refused. Nothing crashes and nothing is drawn.
    onAir(medium.id)
    engine.removeExternalSource(medium.id)
    let gone = shot(.horizontal)
    let black: ((Int, Int, Int)?) -> Bool = { $0.map { $0.0 < 8 && $0.1 < 8 && $0.2 < 8 } ?? false }
    check("C4 a removed crop draws nothing", black(gone?[960, 540]) && engine.state(of: medium.id) == nil)
    onAir(close.id)
    engine.standIn = nil
    engine.sync(sources: [], fpsHint: 30)
    let noCamera = shot(.horizontal)
    check("C4 a crop whose camera is gone draws nothing and reports no state",
          black(noCamera?[960, 540]) && engine.state(of: close.id) == nil && engine.sourceSnapshot(close.id, maxSide: 640) == nil)
    engine.setExternalSource(camID, PresenterSource(id: camID, size: cam, face: face))
    let chained = VirtualAngleSource(shot: .medium, rig: VirtualRig(cameraID: close.id))
    engine.setExternalSource(chained.id, chained)
    onAir(chained.id)
    check("C4 a crop of a crop is refused", black(shot(.horizontal)?[960, 540]) && engine.state(of: chained.id) == nil)
    for id in [close.id, chained.id, camID] { engine.removeExternalSource(id) }
    check("C4 everything removed: the frame is empty", black(shot(.horizontal)?[960, 540]))

    // C7: a keyed frame with a Layer › Crop (a green screen that stops short of the picture's edges, magenta beyond
    // it). On air a crop of the frame's own camera keeps the key but not the crop (as the studio draws it), so the
    // shown area alone keeps the unkeyed wall out, with the presenter near the crop's edge. Control: the same rig told
    // the whole picture shows the wall.
    do {
        let keyed = Engine()
        let shown = CGRect(x: 0.15, y: 0.1, width: 0.65, height: 0.8)
        let face9 = CGRect(x: 0.72 - 0.09 * cam.height / cam.width / 2, y: 0.35 - 0.045, width: 0.09 * cam.height / cam.width, height: 0.09)
        let srcID = UUID()
        keyed.setExternalSource(srcID, KeyedRoomSource(id: srcID, size: cam, screen: shown, face: face9))
        var item = SceneItem(sourceID: UUID(), transform: .full, fit: .fill)
        item.filters = [FilterSpec(kind: .chromaKey(ChromaKeySettings()))]
        let isWall: ((Int, Int, Int)) -> Bool = { $0.0 > 150 && $0.1 < 90 && $0.2 > 150 }
        func walls(_ area: CGRect) -> (count: Int, faces: Int, detail: String) {
            let r = VirtualRig(cameraID: srcID)
            r.setGeometry(camera: cam, frames: [.horizontal: h16, .vertical: v916], shots: VirtualShots(), shown: area)
            r.setFace(FaceSample(boxes: [face9], at: HostClock.seconds()))
            var n = 0, faces = 0, parts: [String] = []
            for s in VirtualShot.allCases {
                let src = VirtualAngleSource(shot: s, rig: r)
                keyed.setExternalSource(src.id, src)
                var it = item; it.sourceID = src.id
                for c in CanvasKind.allCases { keyed.setProgram([it], for: c, transition: .cut, durationMs: 0) }
                for c in CanvasKind.allCases {
                    guard let p = Pixels(keyed.programSnapshot(c, width: c == .horizontal ? 1920 : 1080)) else { continue }
                    let w = p.bounds(isWall).map { Int($0.width * $0.height) } ?? 0
                    n += w
                    if p.bounds(isRed) != nil { faces += 1 }
                    parts.append("\(s.title) \(c.title) \(w > 0 ? "wall" : "no wall")")
                }
                keyed.removeExternalSource(src.id)
            }
            return (n, faces, parts.joined(separator: ", "))
        }
        let cropped = walls(shown), whole = walls(CGRect(x: 0, y: 0, width: 1, height: 1))
        check("C7 a keyed frame with a Layer › Crop: the unkeyed wall beyond the crop never shows, the presenter does",
              cropped.count == 0 && cropped.faces == 4, cropped.detail)
        check("C7 control: told the whole picture shows, the close-up reaches the wall", whole.count > 0, whole.detail)
        keyed.removeExternalSource(srcID)
    }
}

/// A made-up keyed set: a green screen over `screen` (top-left 0...1), a magenta wall around it, a red face.
final class KeyedRoomSource: VideoSource {
    let id: UUID
    let state: SourceState = .running
    let nativeSize: CGSize
    private let picture: CIImage
    init(id: UUID, size: CGSize, screen: CGRect, face: CGRect) {
        self.id = id; nativeSize = size
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height) }
        let wall = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.9)).cropped(to: CGRect(origin: .zero, size: size))
        let green = CIImage(color: CIColor(red: 0, green: 0.8, blue: 0.2)).cropped(to: px(screen))
        let block = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: px(face))
        picture = block.composited(over: green.composited(over: wall))
    }
    func image(at time: CMTime) -> CIImage? { picture }
    func start() {}
    func stop() {}
}
