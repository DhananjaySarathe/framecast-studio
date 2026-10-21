import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// A chat message pinned on screen ("Click to show it on stream").
public struct ChatOverlay: Sendable, Equatable {
    public var author: String
    public var text: String
    public var platform: String
    public init(author: String, text: String, platform: String) { self.author = author; self.text = text; self.platform = platform }
}

/// Draws overlay elements and the on-screen chat card, and animates them in and out.
public final class OverlayRenderer: @unchecked Sendable {
    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    public static func accentColor(_ a: OverlayElement.Accent) -> NSColor {
        switch a {
        case .amber: return NSColor(srgbRed: 0.96, green: 0.70, blue: 0.20, alpha: 1)
        case .red: return NSColor(srgbRed: 0.94, green: 0.31, blue: 0.29, alpha: 1)
        case .green: return NSColor(srgbRed: 0.30, green: 0.76, blue: 0.54, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.30, green: 0.55, blue: 0.97, alpha: 1)
        case .violet: return NSColor(srgbRed: 0.58, green: 0.44, blue: 0.96, alpha: 1)
        }
    }

    private func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> CIImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    private func attr(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    /// Element card at canvas scale (height of the canvas drives type size).
    public func image(for e: OverlayElement, canvasHeight H: CGFloat) -> CIImage? {
        let key = "\(e.hashValue)-\(Int(H))"
        lock.lock(); if let c = cache[key] { lock.unlock(); return c }; lock.unlock()
        let accent = Self.accentColor(e.accent)
        let (bg, fg, sub): (NSColor, NSColor, NSColor) = {
            switch e.look {
            case .solid: return (accent, NSColor(white: 0.07, alpha: 1), NSColor(white: 0.12, alpha: 0.85))
            case .dark: return (NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.92), .white, NSColor(white: 0.8, alpha: 1))
            case .light: return (NSColor(white: 0.98, alpha: 0.97), NSColor(white: 0.08, alpha: 1), NSColor(white: 0.3, alpha: 1))
            }
        }()
        let u = H / 1080
        var img: CIImage?
        switch e.kind {
        case .lower:
            let t = attr(e.title, size: 40 * u, weight: .bold, color: fg)
            let s = attr(e.subtitle, size: 26 * u, weight: .medium, color: sub)
            let tw = t.size().width, sw = e.subtitle.isEmpty ? 0 : s.size().width
            let bar: CGFloat = e.look == .solid ? 0 : 10 * u
            let w = Int(max(tw, sw) + 64 * u + bar), h = Int((e.subtitle.isEmpty ? 84 : 124) * u)
            img = draw(width: w, height: h) { ctx in
                let r = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
                bg.setFill(); NSBezierPath(roundedRect: r, xRadius: 14 * u, yRadius: 14 * u).fill()
                if bar > 0 { accent.setFill(); NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: bar + 8 * u, height: CGFloat(h)), xRadius: 6 * u, yRadius: 6 * u).fill()
                    bg.setFill(); NSRect(x: bar, y: 0, width: 10 * u, height: CGFloat(h)).fill() }
                let x = 32 * u + bar
                if e.subtitle.isEmpty { t.draw(at: CGPoint(x: x, y: (CGFloat(h) - t.size().height) / 2)) }
                else { t.draw(at: CGPoint(x: x, y: CGFloat(h) - 22 * u - t.size().height)); s.draw(at: CGPoint(x: x, y: 20 * u)) }
            }
        case .text, .thanks:
            let big: CGFloat = e.kind == .thanks ? 84 : 64
            let t = attr(e.kind == .thanks ? e.title.uppercased() : e.title, size: big * u, weight: .heavy, color: fg)
            let s = attr(e.subtitle, size: 30 * u, weight: .semibold, color: sub)
            let w = Int(max(t.size().width, s.size().width) + 120 * u)
            let h = Int((t.size().height + (e.subtitle.isEmpty ? 0 : s.size().height + 12 * u)) + 70 * u)
            img = draw(width: w, height: h) { _ in
                let r = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
                bg.setFill(); NSBezierPath(roundedRect: r, xRadius: 22 * u, yRadius: 22 * u).fill()
                let ty = e.subtitle.isEmpty ? (CGFloat(h) - t.size().height) / 2 : CGFloat(h) - 32 * u - t.size().height
                t.draw(at: CGPoint(x: (CGFloat(w) - t.size().width) / 2, y: ty))
                if !e.subtitle.isEmpty { s.draw(at: CGPoint(x: (CGFloat(w) - s.size().width) / 2, y: 30 * u)) }
            }
        case .qr:
            let gen = CIFilter.qrCodeGenerator()
            gen.message = Data((e.url.isEmpty ? " " : e.url).utf8); gen.correctionLevel = "M"
            let code = gen.outputImage
            let side = 240 * u
            let t = attr(e.title, size: 26 * u, weight: .bold, color: NSColor(white: 0.08, alpha: 1))
            let w = Int(side + 48 * u), h = Int(side + 48 * u + (e.title.isEmpty ? 0 : t.size().height + 12 * u))
            let ctx = CIContext()
            let qrCG: CGImage? = code.flatMap { c in
                let k = side / c.extent.width
                return ctx.createCGImage(c.transformed(by: CGAffineTransform(scaleX: k, y: k)), from: CGRect(x: 0, y: 0, width: side, height: side))
            }
            img = draw(width: w, height: h) { cg in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), xRadius: 18 * u, yRadius: 18 * u).fill()
                if let qrCG { cg.interpolationQuality = .none; cg.draw(qrCG, in: CGRect(x: 24 * u, y: 24 * u, width: side, height: side)) }
                if !e.title.isEmpty { t.draw(at: CGPoint(x: (CGFloat(w) - t.size().width) / 2, y: side + 34 * u)) }
            }
        }
        if let img { lock.lock(); cache[key] = img; if cache.count > 64 { cache.removeAll() }; lock.unlock() }
        return img
    }

    public func chatCard(_ m: ChatOverlay, canvasHeight H: CGFloat) -> CIImage? {
        let u = H / 1080
        let name = attr(m.author, size: 24 * u, weight: .heavy, color: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1))
        let body = NSAttributedString(string: m.text, attributes: [
            .font: NSFont.systemFont(ofSize: 30 * u, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1)])
        let maxW = 640 * u
        let bb = body.boundingRect(with: CGSize(width: maxW, height: 1000 * u), options: [.usesLineFragmentOrigin])
        let w = Int(max(name.size().width, bb.width) + 56 * u), h = Int(bb.height + name.size().height + 52 * u)
        return draw(width: w, height: h) { _ in
            NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 0.97).setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), xRadius: 24 * u, yRadius: 24 * u).fill()
            name.draw(at: CGPoint(x: 28 * u, y: CGFloat(h) - 20 * u - name.size().height))
            body.draw(with: CGRect(x: 28 * u, y: 22 * u, width: bb.width + 2, height: bb.height), options: [.usesLineFragmentOrigin])
        }
    }

    /// Places `card` at a 3×3 position with margins and applies the motion for `progress` (0 hidden, 1 shown).
    public func place(_ card: CIImage, position: OverlayElement.Position, motion: OverlayElement.Motion, progress raw: Double, canvas: CGSize) -> CIImage {
        let p = Compositor.ease(min(max(raw, 0), 1))
        guard p > 0.001 else { return .empty() }
        // Keep cards inside the canvas on narrow (vertical) canvases.
        var img = card
        let maxW = canvas.width * 0.9
        if img.extent.width > maxW { let k = maxW / img.extent.width; img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
        let w = img.extent.width, h = img.extent.height
        let mx = canvas.width * 0.035, my = canvas.height * 0.06
        let col: Int, row: Int
        switch position {
        case .topLeft: (col, row) = (0, 0); case .topCenter: (col, row) = (1, 0); case .topRight: (col, row) = (2, 0)
        case .middleLeft: (col, row) = (0, 1); case .middleCenter: (col, row) = (1, 1); case .middleRight: (col, row) = (2, 1)
        case .bottomLeft: (col, row) = (0, 2); case .bottomCenter: (col, row) = (1, 2); case .bottomRight: (col, row) = (2, 2)
        }
        let x = [mx, (canvas.width - w) / 2, canvas.width - w - mx][col]
        let y = [canvas.height - h - my, (canvas.height - h) / 2, my][row]
        var t = CGAffineTransform(translationX: x, y: y)
        var alpha = p
        switch motion {
        case .fade: break
        case .slide:
            let dx = (col == 2 ? 1.0 : -1.0) * (w + mx) * (1 - p)
            t = t.concatenating(CGAffineTransform(translationX: dx, y: 0)); alpha = min(1, p * 1.5)
        case .rise:
            t = t.concatenating(CGAffineTransform(translationX: 0, y: -h * 0.6 * (1 - p)))
        case .pop:
            let s = 0.82 + 0.18 * p
            let pre = CGAffineTransform(translationX: -w / 2, y: -h / 2).concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
            t = pre.concatenating(t)
        }
        img = img.transformed(by: t)
        if alpha < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
        }
        return img
    }
}
