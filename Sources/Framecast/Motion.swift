import AppKit
import AVFoundation

/// Motion graphics for a show, drawn on this Mac from data: what a video editor would cut in, made for live.
/// Each template is a short 1920×1080 MP4 at 30 fps with a slowly moving background, eased motion and Apple's
/// symbol icons (any SF Symbol name). Templates ending in a loop (juggle, relax, pipeline) are rendered seamless and
/// saved as `*.loop.mp4`, which Framecast plays on repeat while they're on screen; the others play once and hold
/// their last frame. Everything stays clear of the bottom-right corner, where the camera bubble sits.
enum Motion {
    enum Template: String, CaseIterable {
        case title, roadmap, juggle, relax, compare, bars, gauge, pipeline, checklist
        var loops: Bool { self == .juggle || self == .relax || self == .pipeline }
        var about: String {
            switch self {
            case .title: "kinetic title: the words rise in one by one (title, subtitle)"
            case .roadmap: "a path that draws itself with milestones popping in (items: label, detail, icon)"
            case .juggle: "a stick figure juggling too many tasks, looping (items: the tasks, with icons)"
            case .relax: "a relaxed presenter while an AI orb handles the tasks and the layouts change, looping (items: what the AI does)"
            case .compare: "before and after, side by side: the juggling figure vs the relaxed one (subtitle: the two labels as 'left|right')"
            case .bars: "an animated bar chart, values counting up (items: label and value; unit; source)"
            case .gauge: "a gauge whose needle swings to the value, with a big counter (value, unit, items[0].value = maximum; source)"
            case .pipeline: "icons connected by lines with data flowing between them, looping (items: label and icon)"
            case .checklist: "rows with icons that tick off one by one; an item with value -1 gets a red cross instead (items: label, detail, icon)"
            }
        }
    }

    struct Item { var label = ""; var detail = ""; var icon = ""; var value = 0.0 }
    struct Spec {
        var template: Template
        var title = ""
        var subtitle = ""
        var items: [Item] = []
        var value = 0.0
        var unit = ""
        var source = ""
    }

    static let size = CGSize(width: 1920, height: 1080)
    static let fps = 30
    static let loopPeriod = 6.0

    static func duration(_ s: Spec) -> Double {
        let n = Double(max(s.items.count, 1))
        switch s.template {
        case .title: return 4.5
        case .roadmap: return 2.2 + 0.9 * n + 1.2
        case .juggle, .relax, .pipeline: return loopPeriod
        case .compare: return 7
        case .bars: return 2.5 + 0.35 * n + 1.5
        case .gauge: return 5
        case .checklist: return 1.2 + 0.75 * n + 1.2
        }
    }

    /// Renders the motion graphic to an MP4; returns an error message or nil.
    static func write(_ s: Spec, to url: URL) -> String? {
        encode(seconds: duration(s), to: url) { t, ctx in draw(s, t: t, ctx: ctx) }
    }

    /// One frame as PNG (by default the last), for previews.
    static func still(_ s: Spec, at t: Double? = nil, to url: URL) -> String? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "Couldn't draw." }
        draw(s, t: t ?? duration(s) - 1.0 / Double(fps), ctx: ctx)
        guard let img = ctx.makeImage(), let rep = Optional(NSBitmapImageRep(cgImage: img)), let png = rep.representation(using: .png, properties: [:]) else { return "Couldn't save." }
        do { try png.write(to: url) } catch { return error.localizedDescription }
        return nil
    }

    /// Frame by frame into an H.264 MP4.
    static func encode(seconds: Double, to url: URL, frame: (Double, CGContext) -> Void) -> String? {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return "Couldn't create the video." }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { return "Couldn't create the video." }
        writer.add(input)
        guard writer.startWriting() else { return "Couldn't write the video." }
        writer.startSession(atSourceTime: .zero)
        let frames = Int((seconds * Double(fps)).rounded())
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { return "Couldn't write the video." }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return "Couldn't write the video." }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                frame(Double(i) / Double(fps), ctx)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? nil : "Couldn't finish the video."
    }

    // MARK: Drawing

    static func draw(_ s: Spec, t: Double, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        let d = D(ctx: ctx, t: t, period: s.template.loops ? loopPeriod : 24)
        d.background()
        switch s.template {
        case .title: title(s, d)
        case .roadmap: roadmap(s, d)
        case .juggle: d.heading(s.title); juggleScene(s, d, origin: CGPoint(x: 0, y: 0), scale: 1, showList: true)
        case .relax: d.heading(s.title); relaxScene(s, d, origin: .zero, scale: 1, showList: true)
        case .compare: compare(s, d)
        case .bars: bars(s, d)
        case .gauge: gauge(s, d)
        case .pipeline: pipeline(s, d)
        case .checklist: checklist(s, d)
        }
        if !s.source.isEmpty { d.text("Source: \(s.source)", 26, .regular, d.ink2, at: CGPoint(x: 120, y: 1012), alpha: d.ease(0.8, 0.8)) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Drawing helpers for one frame, in a flipped (top-left origin) context.
    struct D {
        let ctx: CGContext
        let t: Double
        let period: Double
        let accent = NSColor(srgbRed: 0.49, green: 0.42, blue: 1.0, alpha: 1)
        let teal = NSColor(srgbRed: 0.24, green: 0.84, blue: 0.78, alpha: 1)
        let pink = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.54, alpha: 1)
        let amber = NSColor(srgbRed: 1.0, green: 0.71, blue: 0.28, alpha: 1)
        let green = NSColor(srgbRed: 0.24, green: 0.84, blue: 0.55, alpha: 1)
        let ink = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.98, alpha: 1)
        let ink2 = NSColor(srgbRed: 0.66, green: 0.69, blue: 0.77, alpha: 1)
        let panel = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.20, alpha: 1)
        var palette: [NSColor] { [accent, teal, pink, amber, green] }

        /// 0→1 between start and start+len, ease-out cubic.
        func ease(_ start: Double, _ len: Double = 0.5) -> CGFloat {
            let x = max(0, min(1, (t - start) / len)); return CGFloat(1 - pow(1 - x, 3))
        }
        /// 0→1 with a little overshoot (pop).
        func pop(_ start: Double, _ len: Double = 0.55) -> CGFloat {
            let x = max(0, min(1, (t - start) / len)); let c1 = 1.70158, c3 = c1 + 1
            return CGFloat(1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2))
        }
        /// A wave that repeats exactly over the loop period (so loops are seamless).
        func wave(_ cycles: Double, _ phase: Double = 0) -> CGFloat { CGFloat(sin(2 * .pi * (cycles * t / period + phase))) }

        func background() {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1).cgColor, NSColor(srgbRed: 0.09, green: 0.07, blue: 0.18, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let blobs: [(NSColor, CGPoint, CGFloat, Double)] = [(accent, CGPoint(x: 380, y: 260), 620, 0), (pink, CGPoint(x: 1500, y: 220), 520, 0.33), (teal, CGPoint(x: 1100, y: 900), 640, 0.66)]
            for (c, p, r, ph) in blobs {
                let center = CGPoint(x: p.x + 90 * wave(1, ph), y: p.y + 60 * CGFloat(cos(2 * .pi * (t / period + ph))))
                let rg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c.withAlphaComponent(0.20).cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                ctx.drawRadialGradient(rg, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
            }
        }

        func font(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = true) -> NSFont {
            let f = NSFont.systemFont(ofSize: size, weight: weight)
            return rounded ? NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f : f
        }

        @discardableResult
        func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint, alpha: CGFloat = 1,
                  width: CGFloat = 1600, align: NSTextAlignment = .left) -> CGSize {
            guard !s.isEmpty, alpha > 0.002 else { return .zero }
            let para = NSMutableParagraphStyle(); para.alignment = align; para.lineSpacing = size * 0.1
            let a = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha), .paragraphStyle: para])
            let r = a.boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin])
            let x = align == .center ? p.x - width / 2 : p.x
            a.draw(with: CGRect(x: x, y: p.y, width: width, height: r.height + 4), options: [.usesLineFragmentOrigin])
            return r.size
        }

        func measure(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, width: CGFloat) -> CGFloat {
            guard !s.isEmpty else { return 0 }
            let para = NSMutableParagraphStyle(); para.lineSpacing = size * 0.1
            return NSAttributedString(string: s, attributes: [.font: font(size, weight), .paragraphStyle: para])
                .boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin]).height
        }

        func heading(_ title: String) {
            let a = ease(0.1, 0.6)
            accent.withAlphaComponent(a).setFill()
            NSBezierPath(roundedRect: CGRect(x: 120, y: 112, width: 110 * ease(0, 0.5), height: 12), xRadius: 6, yRadius: 6).fill()
            text(title, 68, .heavy, ink, at: CGPoint(x: 120, y: 138 + 30 * (1 - a)), alpha: a)
        }

        /// An SF Symbol, tinted, centred on `c`.
        func icon(_ name: String, _ pt: CGFloat, _ color: NSColor, at c: CGPoint, alpha: CGFloat = 1) {
            guard alpha > 0.002, pt > 1 else { return }
            let base = NSImage(systemSymbolName: name.isEmpty ? "sparkles" : name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold).applying(.init(paletteColors: [color.withAlphaComponent(alpha)]))
            guard let img = base?.withSymbolConfiguration(cfg) else { return }
            let s = img.size
            img.draw(in: CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        /// A rounded "app icon" tile with a symbol, popping in with `scale`.
        func tile(_ name: String, _ side: CGFloat, _ color: NSColor, at c: CGPoint, scale: CGFloat = 1, alpha: CGFloat = 1) {
            guard scale > 0.01, alpha > 0.01 else { return }
            let s = side * scale
            let r = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30 * scale, color: color.withAlphaComponent(0.45 * alpha).cgColor)
            panel.withAlphaComponent(alpha).setFill(); NSBezierPath(roundedRect: r, xRadius: s * 0.26, yRadius: s * 0.26).fill()
            ctx.restoreGState()
            color.withAlphaComponent(0.9 * alpha).setStroke()
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: s * 0.25, yRadius: s * 0.25); b.lineWidth = 3; b.stroke()
            icon(name, s * 0.42, color, at: c, alpha: alpha)
        }

        func glowDot(_ c: CGPoint, _ r: CGFloat, _ color: NSColor, alpha: CGFloat = 1) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 2.5, color: color.withAlphaComponent(alpha).cgColor)
            color.withAlphaComponent(alpha).setFill(); NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            ctx.restoreGState()
        }

        /// Draws the first `upTo` (0…1) of a polyline.
        func partial(_ pts: [CGPoint], upTo f: CGFloat, width: CGFloat, color: NSColor, glow: Bool = true) -> CGPoint? {
            guard pts.count > 1, f > 0 else { return nil }
            let n = max(1, Int(CGFloat(pts.count - 1) * min(f, 1)))
            let path = NSBezierPath(); path.move(to: pts[0])
            for i in 1...n { path.line(to: pts[i]) }
            path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            ctx.saveGState()
            if glow { ctx.setShadow(offset: .zero, blur: 18, color: color.withAlphaComponent(0.7).cgColor) }
            color.setStroke(); path.stroke()
            ctx.restoreGState()
            return pts[n]
        }
    }

    // MARK: Stick figures

    /// Limb angles in radians from straight down (positive swings toward +x). Elbow/knee angles are relative.
    struct Pose {
        var lean: CGFloat = 0
        var armL: (CGFloat, CGFloat) = (-0.25, 0.2), armR: (CGFloat, CGFloat) = (0.25, -0.2)
        var legL: (CGFloat, CGFloat) = (-0.18, 0.05), legR: (CGFloat, CGFloat) = (0.18, -0.05)
        var head: CGFloat = 0
    }

    /// Draws a stick figure standing on `feet`, `h` tall; returns the hand positions (left, right) and head centre.
    @discardableResult
    static func stickman(_ d: D, feet: CGPoint, h: CGFloat, pose p: Pose, color: NSColor, alpha: CGFloat = 1, seated: Bool = false,
                         mood: CGFloat = 0) -> (CGPoint, CGPoint, CGPoint) {
        func end(_ o: CGPoint, _ len: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: o.x + len * sin(a), y: o.y + len * cos(a)) }
        let hip = CGPoint(x: feet.x, y: feet.y - h * (seated ? 0.28 : 0.46))
        let neck = CGPoint(x: hip.x + h * 0.34 * sin(p.lean), y: hip.y - h * 0.34 * cos(p.lean))
        let headC = CGPoint(x: neck.x + h * 0.11 * sin(p.lean + p.head), y: neck.y - h * 0.11 * cos(p.lean + p.head))
        let shoulder = CGPoint(x: neck.x, y: neck.y + h * 0.04)
        let ua = h * 0.19, fa = h * 0.18, th = h * 0.22, sh = h * 0.22
        let eL = end(shoulder, ua, p.armL.0), hL = end(eL, fa, p.armL.0 + p.armL.1)
        let eR = end(shoulder, ua, p.armR.0), hR = end(eR, fa, p.armR.0 + p.armR.1)
        let kL: CGPoint, fL: CGPoint, kR: CGPoint, fR: CGPoint
        if seated {
            kL = CGPoint(x: hip.x + th * 0.95, y: hip.y + th * 0.1); fL = CGPoint(x: kL.x + 10, y: kL.y + sh)
            kR = CGPoint(x: hip.x + th * 1.05, y: hip.y + th * 0.05); fR = CGPoint(x: kR.x + 22, y: kR.y + sh)
        } else {
            kL = end(hip, th, p.legL.0); fL = end(kL, sh, p.legL.0 + p.legL.1)
            kR = end(hip, th, p.legR.0); fR = end(kR, sh, p.legR.0 + p.legR.1)
        }
        let path = NSBezierPath()
        for (a, b, c) in [(shoulder, eL, hL), (shoulder, eR, hR), (hip, kL, fL), (hip, kR, fR)] { path.move(to: a); path.line(to: b); path.line(to: c) }
        path.move(to: hip); path.line(to: neck)
        path.lineWidth = h * 0.035; path.lineCapStyle = .round; path.lineJoinStyle = .round
        d.ctx.saveGState()
        d.ctx.setShadow(offset: .zero, blur: 16, color: color.withAlphaComponent(0.5 * alpha).cgColor)
        color.withAlphaComponent(alpha).setStroke(); path.stroke()
        let r = h * 0.085
        let head = NSBezierPath(ovalIn: CGRect(x: headC.x - r, y: headC.y - r, width: 2 * r, height: 2 * r))
        head.lineWidth = h * 0.035; head.stroke()
        d.ctx.restoreGState()
        // A face: two eyes and a mouth that smiles (mood > 0) or worries (mood < 0).
        color.withAlphaComponent(alpha).setFill()
        for sx in [-1.0, 1.0] as [CGFloat] {
            NSBezierPath(ovalIn: CGRect(x: headC.x + sx * r * 0.36 - r * 0.11, y: headC.y - r * 0.22 - r * 0.11, width: r * 0.22, height: r * 0.22)).fill()
        }
        let mouth = NSBezierPath()
        mouth.move(to: CGPoint(x: headC.x - r * 0.38, y: headC.y + r * 0.34))
        mouth.curve(to: CGPoint(x: headC.x + r * 0.38, y: headC.y + r * 0.34),
                    controlPoint1: CGPoint(x: headC.x - r * 0.15, y: headC.y + r * (0.34 + 0.35 * mood)),
                    controlPoint2: CGPoint(x: headC.x + r * 0.15, y: headC.y + r * (0.34 + 0.35 * mood)))
        mouth.lineWidth = h * 0.016; mouth.lineCapStyle = .round
        color.withAlphaComponent(alpha).setStroke(); mouth.stroke()
        return (hL, hR, headC)
    }

    static func juggleScene(_ s: Spec, _ d: D, origin o: CGPoint, scale k: CGFloat, showList: Bool) {
        d.ctx.saveGState(); d.ctx.translateBy(x: o.x, y: o.y); d.ctx.scaleBy(x: k, y: k)
        let items = s.items.isEmpty ? [Item(label: "Switch layouts", icon: "rectangle.3.group"), Item(label: "Find the chart", icon: "chart.bar"),
                                       Item(label: "Read comments", icon: "bubble.left"), Item(label: "Prepare slides", icon: "doc.richtext")] : s.items
        let feet = CGPoint(x: 560, y: 940), h: CGFloat = 420
        // Arms raised, pumping in turn as the tasks fly round.
        var pose = Pose(lean: 0.04 * d.wave(2))
        pose.armL = (-2.2 + 0.25 * d.wave(4), -0.6 + 0.2 * d.wave(4)); pose.armR = (2.2 + 0.25 * d.wave(4, 0.5), 0.6 + 0.2 * d.wave(4, 0.5))
        pose.head = 0.12 * d.wave(2, 0.25)
        let (_, _, headC) = stickman(d, feet: feet, h: h, pose: pose, color: d.ink, mood: -1)
        // Sweat drops.
        for i in 0..<2 {
            let ph = (d.t / 1.5 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            d.icon("drop.fill", 26, d.teal, at: CGPoint(x: headC.x + 70 + CGFloat(i) * 26, y: headC.y - 20 + CGFloat(ph) * 80), alpha: CGFloat(1 - ph))
        }
        // The tasks orbit above the head.
        for (i, it) in items.prefix(6).enumerated() {
            let a = 2 * Double.pi * (d.t / 3 + Double(i) / Double(min(items.count, 6)))
            let c = CGPoint(x: headC.x + 290 * CGFloat(cos(a)), y: headC.y - 165 + 80 * CGFloat(sin(a)))
            d.tile(it.icon.isEmpty ? "questionmark" : it.icon, 96, d.palette[i % d.palette.count], at: c, scale: d.pop(0.2 + 0.15 * Double(i)))
        }
        if showList {
            for (i, it) in items.prefix(6).enumerated() {
                let a = d.ease(0.4 + 0.25 * Double(i), 0.5)
                d.text(it.label, 44, .semibold, d.ink, at: CGPoint(x: 1010 + 40 * (1 - a), y: 330 + CGFloat(i) * 92), alpha: a)
                d.palette[i % d.palette.count].withAlphaComponent(a).setFill()
                NSBezierPath(ovalIn: CGRect(x: 970, y: 352 + CGFloat(i) * 92, width: 18, height: 18)).fill()
            }
        }
        d.ctx.restoreGState()
    }

    static func relaxScene(_ s: Spec, _ d: D, origin o: CGPoint, scale k: CGFloat, showList: Bool) {
        d.ctx.saveGState(); d.ctx.translateBy(x: o.x, y: o.y); d.ctx.scaleBy(x: k, y: k)
        let items = s.items.isEmpty ? [Item(label: "Picks the layout", icon: "rectangle.3.group"), Item(label: "Brings up the chart", icon: "chart.bar.xaxis"),
                                       Item(label: "Follows my topics", icon: "list.bullet.rectangle")] : s.items
        // A presenter on a stool, talking with one hand.
        let feet = CGPoint(x: 430, y: 930), h: CGFloat = 470
        let stool = NSBezierPath(); stool.move(to: CGPoint(x: feet.x - 60, y: feet.y - h * 0.28 + 14)); stool.line(to: CGPoint(x: feet.x + 120, y: feet.y - h * 0.28 + 14))
        stool.move(to: CGPoint(x: feet.x - 40, y: feet.y - h * 0.28 + 14)); stool.line(to: CGPoint(x: feet.x - 60, y: feet.y))
        stool.move(to: CGPoint(x: feet.x + 100, y: feet.y - h * 0.28 + 14)); stool.line(to: CGPoint(x: feet.x + 120, y: feet.y))
        stool.lineWidth = 10; stool.lineCapStyle = .round; d.ink2.withAlphaComponent(0.6).setStroke(); stool.stroke()
        var pose = Pose(lean: -0.06 + 0.03 * d.wave(1))
        pose.armL = (-0.5, 0.9); pose.armR = (1.2 + 0.25 * d.wave(3), -1.1 + 0.2 * d.wave(3, 0.2)); pose.head = 0.08 * d.wave(1, 0.3)
        let (_, hand, headC) = stickman(d, feet: feet, h: h, pose: pose, color: d.ink, seated: true, mood: 1)
        // Speech marks near the mouth.
        for i in 0..<3 {
            let ph = CGFloat((d.t / 2 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: headC.x + 30, y: headC.y), radius: 40 + 40 * ph, startAngle: -30, endAngle: 30)
            arc.lineWidth = 5; arc.lineCapStyle = .round; d.teal.withAlphaComponent(0.8 * (1 - ph)).setStroke(); arc.stroke()
        }
        _ = hand
        // The AI orb, pulsing, sending work to a little screen whose layout keeps changing.
        let orb = CGPoint(x: 820, y: 360 + 20 * d.wave(2))
        d.glowDot(orb, 46 + 6 * d.wave(4), d.accent)
        d.icon("sparkles", 46, .white, at: orb)
        let screen = CGRect(x: 980, y: 240, width: 560, height: 315)
        d.panel.setFill(); NSBezierPath(roundedRect: screen, xRadius: 18, yRadius: 18).fill()
        d.accent.withAlphaComponent(0.8).setStroke(); let sb = NSBezierPath(roundedRect: screen, xRadius: 18, yRadius: 18); sb.lineWidth = 3; sb.stroke()
        let phase = Int((d.t / 2).rounded(.down)) % 3
        let blend = d.ease(Double(Int((d.t / 2).rounded(.down))) * 2, 0.35)
        let inner = screen.insetBy(dx: 22, dy: 22)
        d.ctx.saveGState(); NSBezierPath(roundedRect: inner, xRadius: 10, yRadius: 10).addClip()
        d.teal.withAlphaComponent(0.25).setFill(); NSBezierPath(rect: inner).fill()
        for (i, h) in [0.55, 0.85, 0.4, 0.7].enumerated() {   // a little chart on the "screen"
            d.teal.withAlphaComponent(0.85).setFill()
            let bw = inner.width / 11
            NSBezierPath(roundedRect: CGRect(x: inner.minX + bw * (1.2 + CGFloat(i) * 2.2), y: inner.maxY - inner.height * CGFloat(h) * 0.8 - 12, width: bw, height: inner.height * CGFloat(h) * 0.8), xRadius: 6, yRadius: 6).fill()
        }
        // The camera shape changes: circle, square, full.
        let camR: CGRect
        switch phase {
        case 0: camR = CGRect(x: inner.maxX - 120, y: inner.maxY - 120, width: 104, height: 104)
        case 1: camR = CGRect(x: inner.maxX - 170, y: inner.minY + 20, width: 150, height: 150)
        default: camR = inner.insetBy(dx: inner.width * 0.3, dy: inner.height * 0.12)
        }
        d.ink.withAlphaComponent(0.9 * blend + 0.1).setFill()
        (phase == 0 ? NSBezierPath(ovalIn: camR) : NSBezierPath(roundedRect: camR, xRadius: 18, yRadius: 18)).fill()
        d.icon("person.fill", camR.height * 0.5, d.panel, at: CGPoint(x: camR.midX, y: camR.midY), alpha: 1)
        d.ctx.restoreGState()
        // Packets from the orb to the screen.
        for i in 0..<3 {
            let f = CGFloat((d.t / 1.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
            let p = CGPoint(x: orb.x + (screen.minX - orb.x) * f, y: orb.y + (screen.midY - orb.y) * f - 60 * sin(.pi * f))
            d.glowDot(p, 9, d.accent, alpha: 0.9)
        }
        if showList {
            for (i, it) in items.prefix(4).enumerated() {
                let y = 640 + CGFloat(i) * 86, a = d.ease(0.3 + 0.35 * Double(i), 0.5)
                d.icon("checkmark.circle.fill", 40, d.green, at: CGPoint(x: 1010, y: y + 26), alpha: a)
                d.text(it.label, 40, .semibold, d.ink, at: CGPoint(x: 1050, y: y + 2), alpha: a, width: 640)
            }
        }
        d.ctx.restoreGState()
    }

    // MARK: Templates

    static func title(_ s: Spec, _ d: D) {
        let words = s.title.split(separator: " ").map(String.init)
        var x: CGFloat = 120, y: CGFloat = 330
        let size: CGFloat = words.count > 6 ? 104 : 124
        for (i, w) in words.enumerated() {
            let a = d.pop(0.15 + 0.12 * Double(i), 0.6)
            let font = d.font(size, .heavy)
            let wsz = (w as NSString).size(withAttributes: [.font: font])
            if x + wsz.width > 1700 { x = 120; y += size * 1.12 }
            d.text(w, size, .heavy, i == words.count - 1 ? d.accent : d.ink, at: CGPoint(x: x, y: y + 60 * (1 - a)), alpha: min(1, a), width: wsz.width + 20)
            x += wsz.width + size * 0.28
        }
        let u = d.ease(0.15 + 0.12 * Double(words.count), 0.6)
        d.accent.setFill(); NSBezierPath(roundedRect: CGRect(x: 120, y: y + size * 1.25, width: 520 * u, height: 14), xRadius: 7, yRadius: 7).fill()
        d.text(s.subtitle, 48, .medium, d.ink2, at: CGPoint(x: 120, y: y + size * 1.25 + 50), alpha: d.ease(0.6 + 0.12 * Double(words.count), 0.6))
        if !s.items.isEmpty {   // a row of icons
            for (i, it) in s.items.prefix(5).enumerated() {
                d.tile(it.icon, 110, d.palette[i % d.palette.count], at: CGPoint(x: 190 + CGFloat(i) * 150, y: 860), scale: d.pop(1.2 + 0.15 * Double(i)))
            }
        }
    }

    static func roadmap(_ s: Spec, _ d: D) {
        d.heading(s.title)
        let items = s.items.isEmpty ? [Item(label: "Start")] : s.items
        // A rising S-curve that stays clear of the bottom-right corner.
        let p0 = CGPoint(x: 170, y: 800), c1 = CGPoint(x: 620, y: 1010), c2 = CGPoint(x: 900, y: 300), p3 = CGPoint(x: 1480, y: 420)
        let pts: [CGPoint] = (0...300).map { i in
            let u = CGFloat(i) / 300, v = 1 - u
            return CGPoint(x: v * v * v * p0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * p3.x,
                           y: v * v * v * p0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * p3.y)
        }
        let drawTime = 0.9 * Double(items.count) + 0.6
        let prog = d.ease(0.6, drawTime)
        _ = d.partial(pts, upTo: 1, width: 10, color: d.ink2.withAlphaComponent(0.18), glow: false)
        if let head = d.partial(pts, upTo: prog, width: 12, color: d.accent) { d.glowDot(head, 12, .white) }
        // Milestones evenly spaced along the path's length (not its parameter), so none crowd together.
        var lengths: [CGFloat] = [0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = lengths.last ?? 1
        for (i, it) in items.enumerated() {
            let want = (items.count == 1 ? 0.5 : 0.03 + 0.94 * CGFloat(i) / CGFloat(items.count - 1)) * total
            let idx = lengths.firstIndex { $0 >= want } ?? (pts.count - 1)
            let f = CGFloat(idx) / 300
            let p = pts[idx]
            let reach = 0.6 + drawTime * Double(f)
            let k = d.pop(reach - 0.1, 0.55)
            let col = d.palette[i % d.palette.count]
            d.tile(it.icon.isEmpty ? "flag.fill" : it.icon, 104, col, at: p, scale: k)
            let above = i % 2 == 1
            let a = d.ease(reach, 0.5)
            // Label and detail stacked by their real heights (labels can wrap), above or below the node.
            let lh = d.measure(it.label, 36, .bold, width: 300), dh = it.detail.isEmpty ? 0 : d.measure(it.detail, 27, .medium, width: 300)
            let ty = above ? p.y - 70 - lh - (dh > 0 ? dh + 4 : 0) : p.y + 66
            d.text(it.label, 36, .bold, d.ink, at: CGPoint(x: p.x, y: ty), alpha: a, width: 300, align: .center)
            if dh > 0 { d.text(it.detail, 27, .medium, d.ink2, at: CGPoint(x: p.x, y: ty + lh + 4), alpha: a, width: 300, align: .center) }
        }
    }

    static func compare(_ s: Spec, _ d: D) {
        d.heading(s.title)
        let labels = s.subtitle.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        let wipe = d.ease(0.3, 0.8)
        // Both panels end left of the bottom-right corner, where the camera circle sits.
        let left = CGRect(x: 90, y: 260, width: 690, height: 700), right = CGRect(x: 800, y: 260, width: 690, height: 700)
        for (r, col, i) in [(left, d.pink, 0), (right, d.green, 1)] {
            let a = d.ease(0.3 + Double(i) * 0.5, 0.6)
            col.withAlphaComponent(0.08 * a).setFill(); NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28).fill()
            col.withAlphaComponent(0.6 * a).setStroke(); let b = NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28); b.lineWidth = 3; b.stroke()
            d.text(labels.indices.contains(i) ? labels[i] : (i == 0 ? "Alone" : "With Framecast"), 46, .heavy, col, at: CGPoint(x: r.minX + 40, y: r.minY + 30), alpha: a)
        }
        d.ctx.saveGState(); NSBezierPath(rect: CGRect(x: left.minX, y: left.minY, width: left.width, height: left.height)).addClip()
        juggleScene(Spec(template: .juggle, items: s.items), d, origin: CGPoint(x: left.minX - 110, y: left.minY + 70), scale: 0.54, showList: false)
        d.ctx.restoreGState()
        d.ctx.saveGState(); NSBezierPath(rect: CGRect(x: right.minX, y: right.minY, width: right.width * wipe, height: right.height)).addClip()
        relaxScene(Spec(template: .relax), d, origin: CGPoint(x: right.minX - 150, y: right.minY + 70), scale: 0.54, showList: false)
        d.ctx.restoreGState()
    }

    static func bars(_ s: Spec, _ d: D) {
        d.heading(s.title)
        let items = s.items.isEmpty ? [Item(label: "A", value: 1)] : Array(s.items.prefix(7))
        let top = max(items.map(\.value).max() ?? 1, 0.0001)
        let area = CGRect(x: 160, y: 330, width: 1280, height: 520)
        for i in 0...4 {   // grid
            let y = area.maxY - area.height * CGFloat(i) / 4
            d.ink2.withAlphaComponent(0.15 * d.ease(0.2)).setFill(); NSBezierPath(rect: CGRect(x: area.minX, y: y, width: area.width, height: 2)).fill()
        }
        let slot = area.width / CGFloat(items.count), bw = min(160, slot * 0.56)
        for (i, it) in items.enumerated() {
            let g = d.pop(0.7 + 0.35 * Double(i), 0.9)
            let hgt = area.height * CGFloat(it.value / top) * g
            let x = area.minX + slot * (CGFloat(i) + 0.5) - bw / 2
            let col = it.value == top ? d.accent : d.teal.withAlphaComponent(0.75)
            d.ctx.saveGState()
            d.ctx.setShadow(offset: .zero, blur: it.value == top ? 30 : 0, color: d.accent.withAlphaComponent(0.6).cgColor)
            col.setFill(); NSBezierPath(roundedRect: CGRect(x: x, y: area.maxY - hgt, width: bw, height: max(hgt, 4)), xRadius: 14, yRadius: 14).fill()
            d.ctx.restoreGState()
            let shown = it.value * Double(min(g, 1))
            d.text(CardMaker.withUnit(it.value == it.value.rounded() ? shown.rounded() : (shown * 100).rounded() / 100, s.unit), 40, .heavy, d.ink,
                   at: CGPoint(x: x + bw / 2, y: area.maxY - hgt - 58), alpha: d.ease(0.8 + 0.35 * Double(i)), width: 300, align: .center)
            d.text(it.label, 32, .semibold, d.ink2, at: CGPoint(x: x + bw / 2, y: area.maxY + 22), alpha: d.ease(0.5 + 0.35 * Double(i)), width: slot, align: .center)
            if !it.icon.isEmpty { d.icon(it.icon, 34, col, at: CGPoint(x: x + bw / 2, y: area.maxY - 34), alpha: d.ease(1.2 + 0.35 * Double(i))) }
        }
    }

    static func gauge(_ s: Spec, _ d: D) {
        d.heading(s.title)
        let maxV = s.items.first.map(\.value).flatMap { $0 > 0 ? $0 : nil } ?? max(s.value * 2.5, 1)
        let c = CGPoint(x: 760, y: 690), r: CGFloat = 340
        // Coloured bands: low (green), middle (amber), high (pink).
        for (from, to, col) in [(0.0, 0.4, d.green), (0.4, 0.75, d.amber), (0.75, 1.0, d.pink)] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 180 + 180 * from, endAngle: 180 + 180 * to)
            arc.lineWidth = 44; col.withAlphaComponent(0.85 * d.ease(0.2, 0.7)).setStroke(); arc.stroke()
        }
        for i in 0...10 {   // ticks
            let a = CGFloat.pi + CGFloat.pi * CGFloat(i) / 10
            let p1 = CGPoint(x: c.x + (r - 70) * cos(a), y: c.y + (r - 70) * sin(a)), p2 = CGPoint(x: c.x + (r - 40) * cos(a), y: c.y + (r - 40) * sin(a))
            let tk = NSBezierPath(); tk.move(to: p1); tk.line(to: p2); tk.lineWidth = 4; d.ink2.withAlphaComponent(0.6 * d.ease(0.4)).setStroke(); tk.stroke()
        }
        // The needle swings past and settles (spring).
        let x = max(0, d.t - 0.8)
        let spring = 1 - exp(-4.5 * x) * cos(7 * x)
        let f = CGFloat(min(s.value / maxV, 1)) * CGFloat(spring)
        let a = CGFloat.pi + CGFloat.pi * f
        let tip = CGPoint(x: c.x + (r - 90) * cos(a), y: c.y + (r - 90) * sin(a))
        let needle = NSBezierPath(); needle.move(to: c); needle.line(to: tip); needle.lineWidth = 14; needle.lineCapStyle = .round
        d.ctx.saveGState(); d.ctx.setShadow(offset: .zero, blur: 20, color: NSColor.white.withAlphaComponent(0.6).cgColor)
        d.ink.setStroke(); needle.stroke(); d.ctx.restoreGState()
        d.glowDot(c, 26, d.accent)
        let shown = s.value * Double(min(1, spring))
        d.text(CardMaker.withUnit((shown * 100).rounded() / 100, s.unit), 120, .heavy, d.ink, at: CGPoint(x: c.x, y: c.y + 40), alpha: d.ease(0.6), width: 700, align: .center)
        d.text(s.subtitle, 40, .semibold, d.ink2, at: CGPoint(x: c.x, y: c.y + 200), alpha: d.ease(1.2), width: 800, align: .center)
        d.text(CardMaker.withUnit(0, s.unit), 30, .medium, d.ink2, at: CGPoint(x: c.x - r - 30, y: c.y + 30), alpha: d.ease(0.5), width: 200, align: .center)
        d.text(CardMaker.withUnit(maxV, s.unit), 30, .medium, d.ink2, at: CGPoint(x: c.x + r + 30, y: c.y + 30), alpha: d.ease(0.5), width: 200, align: .center)
    }

    static func pipeline(_ s: Spec, _ d: D) {
        d.heading(s.title)
        let items = s.items.isEmpty ? [Item(label: "Step", icon: "circle")] : Array(s.items.prefix(5))
        let n = items.count
        let xs: [CGFloat] = (0..<n).map { n == 1 ? 810 : 220 + CGFloat($0) * (1180 / CGFloat(n - 1)) }
        let y: CGFloat = 560
        // Connectors with data flowing along them (seamless over the loop).
        for i in 0..<(n - 1) {
            let a = CGPoint(x: xs[i] + 80, y: y), b = CGPoint(x: xs[i + 1] - 80, y: y)
            let line = NSBezierPath(); line.move(to: a); line.line(to: b); line.lineWidth = 6; line.lineCapStyle = .round
            d.ink2.withAlphaComponent(0.25).setStroke(); line.stroke()
            for k in 0..<3 {
                let f = CGFloat((d.t / 1.5 + Double(k) / 3 + Double(i) * 0.17).truncatingRemainder(dividingBy: 1))
                d.glowDot(CGPoint(x: a.x + (b.x - a.x) * f, y: y), 9, d.palette[(i + 1) % d.palette.count], alpha: sin(.pi * f))
            }
        }
        for (i, it) in items.enumerated() {
            let pulse = 1 + 0.05 * d.wave(4, Double(i) * 0.2)
            d.tile(it.icon.isEmpty ? "circle" : it.icon, 150, d.palette[i % d.palette.count], at: CGPoint(x: xs[i], y: y), scale: pulse)
            d.text(it.label, 36, .bold, d.ink, at: CGPoint(x: xs[i], y: y + 110), width: 300, align: .center)
            if !it.detail.isEmpty { d.text(it.detail, 27, .medium, d.ink2, at: CGPoint(x: xs[i], y: y + 160), width: 290, align: .center) }
        }
    }

    static func checklist(_ s: Spec, _ d: D) {
        d.heading(s.title)
        for (i, it) in s.items.prefix(6).enumerated() {
            let start = 0.8 + 0.75 * Double(i)
            let a = d.ease(start, 0.5), y = 300 + CGFloat(i) * 112
            let row = CGRect(x: 120 + 60 * (1 - a), y: y, width: 1220, height: 92)
            d.panel.withAlphaComponent(0.85 * a).setFill(); NSBezierPath(roundedRect: row, xRadius: 22, yRadius: 22).fill()
            let col = d.palette[i % d.palette.count]
            d.icon(it.icon.isEmpty ? "circle.fill" : it.icon, 40, col, at: CGPoint(x: row.minX + 56, y: row.midY), alpha: a)
            d.text(it.label, 40, .bold, d.ink, at: CGPoint(x: row.minX + 110, y: row.minY + (it.detail.isEmpty ? 20 : 8)), alpha: a, width: 880)
            if !it.detail.isEmpty { d.text(it.detail, 27, .medium, d.ink2, at: CGPoint(x: row.minX + 110, y: row.minY + 54), alpha: a, width: 880) }
            // The tick (or, for something missing, a cross) draws itself.
            let k = d.ease(start + 0.35, 0.45)
            let cc = CGPoint(x: row.maxX - 60, y: row.midY)
            let missing = it.value < 0
            let ring = NSBezierPath(); ring.appendArc(withCenter: cc, radius: 28, startAngle: -90, endAngle: -90 + 360 * k); ring.lineWidth = 6
            (missing ? d.pink : d.green).setStroke(); ring.stroke()
            if missing, k > 0.4 {
                let m = min(1, (k - 0.4) / 0.6) * 12
                let x = NSBezierPath(); x.move(to: CGPoint(x: cc.x - m, y: cc.y - m)); x.line(to: CGPoint(x: cc.x + m, y: cc.y + m))
                x.move(to: CGPoint(x: cc.x + m, y: cc.y - m)); x.line(to: CGPoint(x: cc.x - m, y: cc.y + m))
                x.lineWidth = 6; x.lineCapStyle = .round; x.stroke()
            } else if k > 0.5 {
                let m = (k - 0.5) * 2
                let tick = NSBezierPath(); tick.move(to: CGPoint(x: cc.x - 13, y: cc.y + 1)); tick.line(to: CGPoint(x: cc.x - 4, y: cc.y + 11 * min(1, m * 2)))
                if m > 0.5 { tick.line(to: CGPoint(x: cc.x - 4 + 18 * (m - 0.5) * 2, y: cc.y + 11 - 22 * (m - 0.5) * 2)) }
                tick.lineWidth = 6; tick.lineCapStyle = .round; tick.lineJoinStyle = .round; tick.stroke()
            }
        }
    }
}
