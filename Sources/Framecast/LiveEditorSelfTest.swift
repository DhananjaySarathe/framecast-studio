import Foundation
import AppKit
import CoreImage
import FramecastEngine

/// Test launches only (`fcctl live-editor-selftest:<json path>`): checks the live editor against the real screen
/// capture. It shows click-through test windows for about 6 s (no clicks, no keys). Only numbers and crops of its
/// own test window are saved:
/// 1. mapping: nine markers on the main display, found in the captured frame, against where the mapping puts them;
/// 2. a window capture of a marker window, before and after the window moves 300 pt;
/// 3. sharpness: a patch of 1-pixel stripes in that window, drawn through the compositor at zoom 1, pixel for pixel,
///    and at the zoom limit.
enum LiveEditorSelfTest {
    struct Report: Codable {
        var displayErrorsPx: [Double] = []
        var windowErrorsPx: [Double] = []
        var windowErrorsAfterMovePx: [Double] = []
        var stripes: [String: Double] = [:]
        var notes: [String] = []
    }

    static func run(_ studio: Studio, out: String) {
        guard let screenRec = studio.collection.sources.first(where: { if case .display = $0.kind { return true }; return false }),
              let main = NSScreen.screens.first else { return }
        let dir = (out as NSString).deletingLastPathComponent
        var report = Report()
        let ownBefore = ScreenSource.showsOwnWindows
        ScreenSource.showsOwnWindows = true
        studio.engine.refreshScreenFilters()
        let H = main.frame.height
        // Nine markers on an uneven grid (a flip can't line up with another marker), in desktop points, top-left.
        let points = [0.12, 0.5, 0.85].flatMap { y in [0.1, 0.45, 0.9].map { x in CGPoint(x: (main.frame.width * x).rounded(), y: (H * y).rounded()) } }
        let patch = NSRect(x: 1000, y: 600, width: 120, height: 120)      // stripes on the display overlay, clear of the small window
        let overlay = TestWindow(frame: main.frame, kind: .markers(points.map { CGPoint(x: $0.x, y: H - $0.y) }, stripes: patch))
        overlay.orderFrontRegardless()
        let stripes = NSRect(x: 220, y: 40, width: 120, height: 120)       // in the small window, bottom-left origin
        let small = TestWindow(frame: NSRect(x: 200, y: 200, width: 400, height: 300),
                               kind: .markers([CGPoint(x: 60, y: 240), CGPoint(x: 340, y: 240), CGPoint(x: 120, y: 200)], stripes: stripes), opaque: true)
        small.orderFrontRegardless()
        let windowSource = ScreenSource(id: UUID(), target: .window(CGWindowID(small.windowNumber)), fps: 30)

        func later(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        later(1.5) {
            // 1. Display mapping.
            if let img = studio.engine.sourceSnapshot(screenRec.id, maxSide: max(studio.engine.nativeSize(of: screenRec.id)?.width ?? 3024, 100)),
               let geo = studio.engine.screenGeometry(of: screenRec.id) {
                let found = Self.markers(in: img)
                for p in points {
                    guard let n = geo.normalized(p) else { continue }
                    let want = CGPoint(x: n.x * Double(img.width), y: n.y * Double(img.height))
                    report.displayErrorsPx.append(found.map { hypot($0.x - want.x, $0.y - want.y) }.min() ?? -1)
                }
                report.notes.append("display \(img.width)x\(img.height) px, \(found.count) markers found, geometry \(geo.rect)")
                // 3. Sharpness on the real display capture, through the compositor on a 16:9 canvas: at zoom 1, pixel for
                //    pixel, and at the limit (1.25 canvas pixels per source pixel).
                if let n = geo.normalized(CGPoint(x: patch.midX, y: H - patch.midY)) {
                    let ci = CIImage(cgImage: img)
                    report.stripes["display capture, 1:1"] = Self.stdDev(ci, around: CGPoint(x: n.x * ci.extent.width, y: (1 - n.y) * ci.extent.height), comp: studio.engine.compositor)
                    let canvas = CGSize(width: 1920, height: 1080)
                    let layer = LayerGeometry(image: ci.extent.size, frame: canvas, fit: .fit)
                    for (name, zoom) in [("zoom 1", 1.0), ("pixel for pixel", 1 / layer.referenceScale), ("limit", layer.maxZoom(enlargement: 1.25))] {
                        let vp = Viewport(cx: n.x, cy: n.y, zoom: zoom)
                        guard let drawn = studio.engine.compositor.renderItem(SceneItem(sourceID: screenRec.id, transform: .full, fit: .fit),
                                                                              input: LayerInput(image: ci, viewport: vp), canvas: canvas) else { continue }
                        let at = Self.canvasPoint(n, layer: layer, vp: vp)
                        report.stripes[String(format: "display %@ (%.2fx, %.2f canvas px per source px)", name, zoom, layer.referenceScale * zoom)] =
                            Self.stdDev(drawn, around: at, comp: studio.engine.compositor)
                    }
                }
            } else { report.notes.append("no display frame or geometry") }
            // 2. Window capture.
            windowSource.start()
        }
        func windowFrame() -> (CGImage, ScreenGeometry)? {
            guard let ci = windowSource.image(at: HostClock.now()), let geo = windowSource.geometry,
                  let img = studio.engine.compositor.context.createCGImage(ci, from: ci.extent) else { return nil }
            return (img, geo)
        }
        func windowErrors(_ label: String) -> [Double] {
            guard let (img, geo) = windowFrame() else { report.notes.append("no window frame"); return [] }
            let found = Self.markers(in: img)
            report.notes.append("window \(label): \(img.width)x\(img.height) px, geometry \(geo.rect), frame \(NSStringFromRect(small.frame))")
            guard case .markers(let marks, _) = small.kind else { return [] }
            let f = small.frame
            return marks.map { m in
                let p = CGPoint(x: f.minX + m.x, y: H - (f.minY + m.y))      // window point → desktop, top-left
                guard let n = geo.normalized(p) else { return -1 }
                let want = CGPoint(x: n.x * Double(img.width), y: n.y * Double(img.height))
                return found.map { hypot($0.x - want.x, $0.y - want.y) }.min() ?? -1
            }
        }
        later(3.5) {
            report.windowErrorsPx = windowErrors("before")
            // 3. Sharpness: the window's stripe patch through the compositor, as a full-frame layer on a 16:9 canvas.
            if let (img, _) = windowFrame() {
                let ci = CIImage(cgImage: img)
                Self.savePNG(ci.cropped(to: CGRect(x: 440, y: 80, width: 240, height: 240)), comp: studio.engine.compositor, to: dir + "/stripes-captured.png")
                let n = CGPoint(x: stripes.midX / small.frame.width, y: 1 - stripes.midY / small.frame.height)
                let rawAt = CGPoint(x: n.x * ci.extent.width, y: (1 - n.y) * ci.extent.height)
                report.stripes["captured window, 1:1"] = Self.stdDev(ci, around: rawAt, comp: studio.engine.compositor)
                let canvas = CGSize(width: 1920, height: 1080)
                let layer = LayerGeometry(image: ci.extent.size, frame: canvas, fit: .fit)
                for (name, zoom) in [("zoom 1", 1.0), ("pixel for pixel", 1 / layer.referenceScale), ("limit 1.25x", layer.maxZoom(enlargement: 1.25))] {
                    let vp = Viewport(cx: n.x, cy: n.y, zoom: zoom)
                    guard let drawn = studio.engine.compositor.renderItem(SceneItem(sourceID: screenRec.id, transform: .full, fit: .fit),
                                                                          input: LayerInput(image: ci, viewport: vp), canvas: canvas) else { continue }
                    let at = Self.canvasPoint(n, layer: layer, vp: vp)
                    report.stripes[String(format: "%@ (%.2fx, %.2f canvas px per source px)", name, zoom, layer.referenceScale * zoom)] =
                        Self.stdDev(drawn, around: at, comp: studio.engine.compositor)
                    Self.savePNG(drawn.cropped(to: CGRect(x: at.x - 40, y: at.y - 40, width: 80, height: 80)), comp: studio.engine.compositor,
                                 to: dir + "/stripes-\(Int(zoom * 100)).png")
                }
            }
            small.setFrameOrigin(NSPoint(x: small.frame.minX + 300, y: small.frame.minY))
            small.redraw()
        }
        // The render loop asks for the geometry every frame; asking once starts a lookup off the render path.
        later(4.4) { _ = windowSource.geometry }
        later(5) {
            report.windowErrorsAfterMovePx = windowErrors("after moving 300 pt")
            windowSource.stop()
            [small, overlay].forEach { $0.orderOut(nil) }
            ScreenSource.showsOwnWindows = ownBefore
            studio.engine.refreshScreenFilters()
            TestControl.write(report, to: out)
        }
    }

    /// Where a picture point lands on a full-frame layer's canvas (Core Image coordinates), the compositor's way.
    static func canvasPoint(_ p: CGPoint, layer: LayerGeometry, vp: Viewport) -> CGPoint {
        let s = layer.referenceScale * vp.zoom, w = layer.image.width * s, h = layer.image.height * s, f = layer.frame
        var tx = f.width / 2 - vp.cx * w, ty = f.height / 2 - (1 - vp.cy) * h
        tx = w >= f.width ? min(0, max(f.width - w, tx)) : (f.width - w) / 2
        ty = h >= f.height ? min(0, max(f.height - h, ty)) : (f.height - h) / 2
        return CGPoint(x: tx + p.x * w, y: ty + (1 - p.y) * h)
    }

    /// Spread of brightness in a 40 x 40 px square (127.5 is perfect 1-pixel black and white stripes).
    static func stdDev(_ img: CIImage, around c: CGPoint, comp: Compositor) -> Double {
        let r = CGRect(x: (c.x - 20).rounded(), y: (c.y - 20).rounded(), width: 40, height: 40)
        var px = [UInt8](repeating: 0, count: 40 * 40 * 4)
        comp.context.render(img, toBitmap: &px, rowBytes: 40 * 4, bounds: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let g = stride(from: 0, to: px.count, by: 4).map { Double(px[$0 + 1]) }
        let mean = g.reduce(0, +) / Double(g.count)
        return (g.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(g.count)).squareRoot()
    }

    static func savePNG(_ img: CIImage, comp: Compositor, to path: String) {
        guard let cg = comp.context.createCGImage(img, from: img.extent.integral),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
    }

    /// Centres of magenta blobs, in image pixels (top-left origin: a bitmap context's first row is the image's top).
    static func markers(in img: CGImage) -> [CGPoint] {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var seen = [Bool](repeating: false, count: w * h)
        func magenta(_ i: Int) -> Bool { px[i * 4] > 200 && px[i * 4 + 1] < 70 && px[i * 4 + 2] > 200 }
        var out: [CGPoint] = []
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where !seen[y * w + x] && magenta(y * w + x) {
                var stack = [(x, y)], sx = 0.0, sy = 0.0, n = 0.0
                seen[y * w + x] = true
                while let (cx, cy) = stack.popLast() {
                    sx += Double(cx); sy += Double(cy); n += 1
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h, !seen[ny * w + nx], magenta(ny * w + nx) else { continue }
                        seen[ny * w + nx] = true; stack.append((nx, ny))
                    }
                }
                if n >= 9 { out.append(CGPoint(x: sx / n + 0.5, y: sy / n + 0.5)) }
            }
        }
        return out
    }
}

/// A click-through test window with magenta markers and, optionally, a patch of 1-pixel stripes.
final class TestWindow: NSWindow {
    enum Kind { case markers([CGPoint], stripes: NSRect?) }
    let kind: Kind
    private let view: TestView
    init(frame: NSRect, kind: Kind, opaque: Bool = false) {
        self.kind = kind
        view = TestView(kind: kind)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = opaque; backgroundColor = opaque ? .white : .clear
        ignoresMouseEvents = true; level = .floating; hasShadow = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        contentView = view
    }
    func redraw() { view.needsDisplay = true }
}

final class TestView: NSView {
    let kind: TestWindow.Kind
    init(kind: TestWindow.Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        guard case .markers(let marks, let stripes) = kind else { return }
        NSColor.magenta.setFill()
        for m in marks { NSRect(x: m.x - 5, y: m.y - 5, width: 10, height: 10).fill() }
        // 1-pixel black and white columns, drawn pixel by pixel through Core Graphics at the backing scale.
        guard let s = stripes, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(s)
        ctx.setFillColor(NSColor.black.cgColor)
        var x = s.minX
        while x < s.maxX { ctx.fill(CGRect(x: x, y: s.minY, width: 1 / scale, height: s.height)); x += 2 / scale }
        ctx.restoreGState()
    }
}

extension LiveEditorSelfTest {
    /// Gate 0's first-use costs: switches through every scene, 2.5 s each, and notes the slowest tick after each
    /// switch (Core Image builds each new combination of effects the first time it draws it).
    static func sceneTour(_ studio: Studio, out: String) {
        struct Row: Codable { var scene: String; var worstMs: Double; var transitionMs: Double; var steadyP95Ms: Double }
        var rows: [Row] = []
        let scenes = studio.scenes
        func step(_ i: Int) {
            guard i < scenes.count else { TestControl.write(rows, to: out); return }
            studio.switchTo(scenes[i].id, everyCanvas: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let s = studio.engine.tickSummary(seconds: 2.4)
                rows.append(Row(scene: scenes[i].name, worstMs: max(s.max, s.transitionMax), transitionMs: s.transitionP95, steadyP95Ms: s.p95))
                step(i + 1)
            }
        }
        step(0)
    }
}
