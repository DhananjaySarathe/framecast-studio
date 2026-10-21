import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Draws 1920×1080 cards for a show's assets folder in Framecast's own style, from words and numbers only (so
/// an AI preparing the show sends data, never code): a title card, a bullet list, a bar chart, a quote, one big
/// number, a flow of steps, or a reference (a screenshot or picture in a browser-style frame with its address).
/// Numbers come with their source, which is printed on the card.
/// A card is a still PNG, or an animated MP4 (a few seconds; it ends on the finished card, which stays on screen):
/// the title slides in, list items and flow steps appear one by one, bars grow, numbers count up.
enum CardMaker {
    enum Kind: String, CaseIterable { case title, bullets, chart, quote, number, flow, reference }

    struct Card {
        var kind: Kind
        var title = ""
        var subtitle = ""
        var items: [String] = []
        var values: [(label: String, value: Double)] = []
        var unit = ""
        var source = ""
        /// reference: the picture's file, and the address shown in the frame's bar (`subtitle`).
        var image: URL?
    }

    static let size = CGSize(width: 1920, height: 1080)
    static let accent = NSColor(srgbRed: 0x7D / 255.0, green: 0x6B / 255.0, blue: 0xFF / 255.0, alpha: 1)
    static let ink = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.97, alpha: 1)
    static let ink2 = NSColor(srgbRed: 0.66, green: 0.69, blue: 0.75, alpha: 1)
    static let fps = 30

    /// Seconds until everything has appeared.
    static func revealTime(_ c: Card) -> Double {
        switch c.kind {
        case .title: return 1.4
        case .bullets: return 0.7 + 0.45 * Double(min(c.items.count, 6))
        case .chart, .number: return 1.9
        case .quote: return 1.6
        case .flow: return 0.7 + 0.55 * Double(min(c.items.count, 5))
        case .reference: return 6.0          // the picture keeps slowly zooming while it's on screen
        }
    }

    /// Renders the finished card as PNG; returns an error message or nil.
    static func write(_ c: Card, to url: URL) -> String? {
        guard let ctx = context() else { return "Couldn't draw the card." }
        render(c, t: .infinity, in: ctx)
        guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return "Couldn't save the card."
        }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? nil : "Couldn't save the card."
    }

    /// Renders the card animating in, as an H.264 MP4 that ends on the finished card; returns an error or nil.
    static func writeVideo(_ c: Card, to url: URL) -> String? {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return "Couldn't create the video." }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
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
        let frames = Int((revealTime(c) + 1.2) * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { return "Couldn't write the video." }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return "Couldn't write the video." }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            if let ctx { render(c, t: Double(i) / Double(fps), in: ctx) }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? nil : "Couldn't finish the video."
    }

    private static func context() -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws the card as it looks `t` seconds into its animation (.infinity: finished).
    private static func render(_ c: Card, t: Double, in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        draw(c, t: t)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 0→1 between `start` and `start + length`, eased.
    private static func ease(_ t: Double, _ start: Double, _ length: Double = 0.45) -> CGFloat {
        let x = max(0, min(1, (t - start) / length))
        return CGFloat(1 - pow(1 - x, 3))
    }

    // Drawing happens in a flipped (top-left origin) AppKit context.
    private static func draw(_ c: Card, t: Double) {
        let bounds = CGRect(origin: .zero, size: size)
        NSGradient(starting: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1), ending: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.20, alpha: 1))?
            .draw(in: bounds, angle: -35)
        let m: CGFloat = 120
        accent.setFill(); NSBezierPath(roundedRect: CGRect(x: m, y: 120, width: 120 * ease(t, 0, 0.4), height: 14), xRadius: 7, yRadius: 7).fill()
        let a = ease(t, 0.1, 0.5)                                // the title's arrival
        func titleRect(_ y: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: m, y: y + 40 * (1 - a), width: size.width - 2 * m, height: h) }
        switch c.kind {
        case .title:
            text(c.title, size: 112, weight: .heavy, alpha: a, in: titleRect(330, 300))
            text(c.subtitle, size: 48, weight: .medium, color: ink2, alpha: ease(t, 0.6, 0.6), in: CGRect(x: m, y: 640, width: size.width - 2 * m, height: 200))
        case .bullets:
            text(c.title, size: 76, weight: .bold, alpha: a, in: titleRect(170, 120))
            var y: CGFloat = 330
            for (i, item) in c.items.prefix(6).enumerated() {
                let p = ease(t, 0.6 + 0.45 * Double(i))
                accent.withAlphaComponent(p).setFill(); NSBezierPath(ovalIn: CGRect(x: m, y: y + 22, width: 22, height: 22)).fill()
                let h = text(item, size: 50, weight: .medium, alpha: p, in: CGRect(x: m + 54 - 30 * (1 - p), y: y, width: size.width - 2 * m - 54, height: 140))
                y += max(80, (h > 0 ? h : 60) + 34)
            }
        case .chart:
            text(c.title, size: 70, weight: .bold, alpha: a, in: titleRect(170, 120))
            let vals = Array(c.values.prefix(8)), top = max(vals.map(\.value).max() ?? 1, 0.000_001)
            let row = min(130, 600 / CGFloat(max(vals.count, 1)))
            let area = CGRect(x: m, y: 320 + (600 - row * CGFloat(vals.count)) / 2, width: size.width - 2 * m, height: row * CGFloat(vals.count))
            let labelW: CGFloat = 420, grow = ease(t, 0.5, 1.0)
            for (i, v) in vals.enumerated() {
                let y = area.minY + CGFloat(i) * row
                text(v.label, size: 40, weight: .semibold, alpha: ease(t, 0.3), in: CGRect(x: m, y: y + row * 0.18, width: labelW - 20, height: row))
                let barW = (area.width - labelW - 260) * CGFloat(v.value / top) * grow
                (i == 0 ? accent : accent.withAlphaComponent(0.55)).setFill()
                NSBezierPath(roundedRect: CGRect(x: m + labelW, y: y + row * 0.15, width: max(barW, 8), height: row * 0.62), xRadius: 12, yRadius: 12).fill()
                text(withUnit(v.value, c.unit), size: 40, weight: .bold, alpha: ease(t, 1.3), in: CGRect(x: m + labelW + barW + 20, y: y + row * 0.18, width: 260, height: row))
            }
        case .quote:
            text("“", size: 220, weight: .heavy, color: accent, alpha: ease(t, 0, 0.4), in: CGRect(x: m - 10, y: 150, width: 200, height: 220))
            text(c.title, size: 64, weight: .semibold, alpha: ease(t, 0.3, 0.7), in: CGRect(x: m, y: 330, width: size.width - 2 * m, height: 420))
            text(c.subtitle.isEmpty ? "" : "— \(c.subtitle)", size: 42, weight: .medium, color: ink2, alpha: ease(t, 1.0), in: CGRect(x: m, y: 790, width: size.width - 2 * m, height: 80))
        case .number:
            let count = Double(ease(t, 0.3, 1.2))        // counts up to the value
            let big = c.values.first.map { v in withUnit(v.value == v.value.rounded() ? (v.value * count).rounded() : v.value * count, c.unit) } ?? c.title
            text(big, size: 260, weight: .heavy, color: accent, alpha: ease(t, 0.1, 0.3), in: CGRect(x: m, y: 250, width: size.width - 2 * m, height: 320))
            text(c.values.first?.label ?? c.subtitle, size: 60, weight: .semibold, alpha: ease(t, 0.8), in: CGRect(x: m, y: 600, width: size.width - 2 * m, height: 200))
        case .flow:
            text(c.title, size: 70, weight: .bold, alpha: a, in: titleRect(170, 120))
            let steps = Array(c.items.prefix(5)), n = CGFloat(max(steps.count, 1))
            let gap: CGFloat = 70, w = (size.width - 2 * m - gap * (n - 1)) / n, h: CGFloat = 320, y: CGFloat = 420
            let stepSize: CGFloat = steps.count >= 5 ? 33 : (steps.count == 4 ? 36 : 40)
            for (i, s) in steps.enumerated() {
                let p = ease(t, 0.6 + 0.55 * Double(i)), x = m + CGFloat(i) * (w + gap)
                let box = CGRect(x: x, y: y + 30 * (1 - p), width: w, height: h)
                NSColor(srgbRed: 0.14, green: 0.13, blue: 0.24, alpha: p).setFill()
                NSBezierPath(roundedRect: box, xRadius: 26, yRadius: 26).fill()
                accent.withAlphaComponent(p).setStroke()
                let border = NSBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), xRadius: 25, yRadius: 25); border.lineWidth = 3; border.stroke()
                text("\(i + 1)", size: 40, weight: .heavy, color: accent, alpha: p, in: CGRect(x: x + 30, y: box.minY + 26, width: 80, height: 50))
                text(s, size: stepSize, weight: .semibold, alpha: p, in: CGRect(x: x + 28, y: box.minY + 90, width: w - 52, height: h - 105))
                if i < steps.count - 1 {
                    let q = ease(t, 0.9 + 0.55 * Double(i), 0.3)
                    accent.withAlphaComponent(q).setFill()
                    let ax = x + w + 14, ay = y + h / 2
                    let arrow = NSBezierPath()
                    arrow.move(to: CGPoint(x: ax, y: ay - 3)); arrow.line(to: CGPoint(x: ax + (gap - 40) * q, y: ay - 3))
                    arrow.line(to: CGPoint(x: ax + (gap - 40) * q, y: ay - 14)); arrow.line(to: CGPoint(x: ax + (gap - 28) * q + 12, y: ay))
                    arrow.line(to: CGPoint(x: ax + (gap - 40) * q, y: ay + 14)); arrow.line(to: CGPoint(x: ax + (gap - 40) * q, y: ay + 3))
                    arrow.line(to: CGPoint(x: ax, y: ay + 3)); arrow.close(); arrow.fill()
                }
            }
            if !c.subtitle.isEmpty {
                text(c.subtitle, size: 40, weight: .medium, color: ink2, alpha: ease(t, revealTime(c) - 0.3), in: CGRect(x: m, y: y + h + 70, width: size.width - 2 * m, height: 120))
            }
        case .reference:
            text(c.title, size: 58, weight: .bold, alpha: a, in: titleRect(160, 90))
            let p = ease(t, 0.25, 0.6)
            let img = c.image.flatMap { NSImage(contentsOf: $0) }
            let aspect = img.map { $0.size.width / max($0.size.height, 1) } ?? 1.6
            let bar: CGFloat = 46, maxH: CGFloat = 1080 - 280 - 130 - bar
            // The frame ends left of the bottom-right corner, where the camera circle sits in the asset looks.
            let right = size.width * 0.79
            let w = min(right - m, maxH * aspect), h = w / aspect
            let frame = CGRect(x: m + (right - m - w) / 2, y: 280 + 50 * (1 - p), width: w, height: h + bar)
            NSGraphicsContext.saveGraphicsState()
            let shape = NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18)
            NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: p).setFill(); shape.fill()
            shape.addClip()
            for (i, col) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                col.withAlphaComponent(0.9 * p).setFill()
                NSBezierPath(ovalIn: CGRect(x: frame.minX + 20 + CGFloat(i) * 24, y: frame.minY + 16, width: 13, height: 13)).fill()
            }
            NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: p).setFill()
            NSBezierPath(roundedRect: CGRect(x: frame.minX + 110, y: frame.minY + 9, width: min(560, w - 140), height: 28), xRadius: 8, yRadius: 8).fill()
            text(c.subtitle, size: 17, weight: .medium, color: ink2, alpha: p, in: CGRect(x: frame.minX + 124, y: frame.minY + 13, width: min(540, w - 160), height: 24))
            if let img {
                let zoom = 1 + 0.045 * CGFloat(min(1, max(0, t.isInfinite ? 0 : t / revealTime(c))))
                let area = CGRect(x: frame.minX, y: frame.minY + bar, width: w, height: h)
                NSBezierPath(rect: area).addClip()
                img.draw(in: CGRect(x: area.midX - w * zoom / 2, y: area.minY, width: w * zoom, height: h * zoom),
                         from: .zero, operation: .sourceOver, fraction: p, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if !c.source.isEmpty {
            text("Source: \(c.source)", size: 28, weight: .regular, color: ink2, alpha: ease(t, c.kind == .reference ? 0.8 : revealTime(c) - 0.4),
                 in: CGRect(x: m, y: size.height - 110, width: size.width - 2 * m, height: 50))
        }
    }

    @discardableResult
    private static func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = ink, alpha: CGFloat = 1, in rect: CGRect) -> CGFloat {
        guard !s.isEmpty, alpha > 0.001 else { return 0 }
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping; p.lineSpacing = size * 0.12
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                           .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha), .paragraphStyle: p])
        a.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return a.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
    }

    /// Currency symbols go in front ("$4"), anything else after ("40%", "12 ms").
    static func withUnit(_ v: Double, _ unit: String) -> String {
        let u = unit.trimmingCharacters(in: .whitespaces)
        if let f = u.first, "$€£¥₹".contains(f) { return u + (v == v.rounded() ? format(v) : String(format: "%.2f", v)) }
        return format(v) + unit
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e12 ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}
