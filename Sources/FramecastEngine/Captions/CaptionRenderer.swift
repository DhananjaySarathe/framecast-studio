import Foundation
import CoreImage
import AppKit

/// Draws the caption bar for each canvas: white text on a rounded, semi-transparent dark plate, guessed words a
/// little lighter. The picture is drawn only when the words change and kept until they do again; when the only
/// change is words settling, the new picture fades in over the old one. Call from one thread at a time (the engine
/// draws under its lock).
final class CaptionRenderer {
    private struct Drawn { var key: String; var words: [String]; var settled: [Bool]; var image: CIImage; var lines: [String]; var at: Double }
    private var drawn: [CanvasKind: Drawn] = [:]
    private var previous: [CanvasKind: Drawn] = [:]
    private var widths: [String: CGFloat] = [:]
    /// The lines last put on each canvas while readable (more than half faded in), and how visible they were.
    private(set) var shown: [CanvasKind: (lines: [String], alpha: Double)] = [:]
    static let settle = 0.25

    func reset() { drawn = [:]; previous = [:]; shown = [:] }

    /// The caption bar placed on a canvas of `size`, fully visible (nil when there's nothing to show). `version`
    /// changes whenever the frame does, so an unchanged frame is never drawn again.
    func image(_ f: CaptionFrame, version: Int, kind: CanvasKind, size: CGSize, now: Double) -> CIImage? {
        let key = "\(version)|\(Int(size.width))x\(Int(size.height))"
        if drawn[kind]?.key != key {
            guard let d = draw(f, size: size, key: key, now: now) else { drawn[kind] = nil; previous[kind] = nil; return nil }
            // Words settling (same words, now final) fade into their full colour; anything else changes at once.
            previous[kind] = drawn[kind].flatMap { o in
                o.words == d.words && o.lines == d.lines && !zip(o.settled, d.settled).contains { $0 && !$1 } ? o : nil
            }
            drawn[kind] = d
        }
        guard let d = drawn[kind] else { return nil }
        if let p = previous[kind] {
            let k = (now - d.at) / Self.settle
            // A dissolve (not one over the other): the plate is the same in both, so only the words change.
            if k < 1, p.image.extent == d.image.extent {
                return p.image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: d.image, kCIInputTimeKey: max(0, k)])
            }
            previous[kind] = nil
        }
        return d.image
    }

    func lines(_ kind: CanvasKind) -> [String] { drawn[kind]?.lines ?? [] }
    func noteShown(_ kind: CanvasKind, alpha: Double) { shown[kind] = (alpha >= 0.5 ? lines(kind) : [], alpha) }

    private func font(_ px: CGFloat) -> NSFont { NSFont.systemFont(ofSize: px, weight: .semibold) }

    private func width(_ s: String, _ f: NSFont) -> CGFloat {
        let k = "\(f.pointSize)|\(s)"
        if let w = widths[k] { return w }
        let w = ceil((s as NSString).size(withAttributes: [.font: f]).width)
        if widths.count > 4000 { widths.removeAll() }
        widths[k] = w
        return w
    }

    private func draw(_ f: CaptionFrame, size: CGSize, key: String, now: Double) -> Drawn? {
        guard !f.words.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let px = CaptionGeometry.fontSize(f.size, canvas: size)
        let fnt = font(px)
        let space = width("a a", fnt) - 2 * width("a", fnt)
        let maxText = CaptionGeometry.maxTextWidth(size, font: px)
        let lines = CaptionLayout.lines(f.words, maxWidth: maxText, measure: { self.width($0, fnt) }, space: space)
        guard !lines.isEmpty else { return nil }
        let pad = CaptionGeometry.padding(px)
        let lineH = ceil(px * 1.28)
        let textW = min(maxText, lines.map { l in l.map { width($0.text, fnt) }.reduce(0, +) + space * CGFloat(max(0, l.count - 1)) }.max() ?? 0)
        let w = Int(textW + 2 * pad.x), h = Int(CGFloat(lines.count) * lineH + 2 * pad.y)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), xRadius: px * 0.32, yRadius: px * 0.32).fill()
        let settled = NSColor.white, guessed = NSColor(white: 1, alpha: 0.6)
        for (i, line) in lines.enumerated() {
            let s = NSMutableAttributedString()
            for (j, word) in line.enumerated() {
                if j > 0 { s.append(NSAttributedString(string: " ", attributes: [.font: fnt, .foregroundColor: settled])) }
                s.append(NSAttributedString(string: word.text, attributes: [.font: fnt, .foregroundColor: word.settled ? settled : guessed]))
            }
            let lw = min(textW, ceil(s.size().width))
            // Lines from the top; the text's baseline box is centred in its line.
            let y = CGFloat(h) - pad.y - CGFloat(i + 1) * lineH + (lineH - s.size().height) / 2
            s.draw(with: CGRect(x: (CGFloat(w) - lw) / 2, y: y, width: lw + 2, height: s.size().height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        let x = ((size.width - CGFloat(w)) / 2).rounded()
        let y = CaptionGeometry.plateY(f.position, canvas: size, height: CGFloat(h))
        let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: x, y: y))
        return Drawn(key: key, words: f.words.map(\.text), settled: f.words.map(\.settled), image: img, lines: lines.map(CaptionLayout.text), at: now)
    }
}
