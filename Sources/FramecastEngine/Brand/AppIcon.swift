import Foundation
import AppKit
import CoreGraphics

/// Framecast's logo, drawn in code (no external artwork): a viewfinder with a wide and a tall frame
/// overlapping — one take, two formats — and a record dot.
public enum AppIcon {
    public static func cgImage(size px: Int) -> CGImage? {
        let s = CGFloat(px)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

        // macOS icon grid: 824/1024 body with ~185 corner radius.
        let inset = s * 100 / 1024
        let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = body.width * 0.225
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: col(0, 0, 0, 0.45))
        ctx.addPath(path); ctx.setFillColor(col(0.06, 0.06, 0.12)); ctx.fillPath()
        ctx.restoreGState()

        // Body gradient.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [col(0.16, 0.13, 0.36), col(0.04, 0.04, 0.09)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
        // Soft glow behind the frames.
        let glow = CGGradient(colorsSpace: cs, colors: [col(0.49, 0.42, 1.0, 0.35), col(0.49, 0.42, 1.0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.midY), startRadius: 0,
                               endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: body.width * 0.55, options: [])
        ctx.restoreGState()

        let accent = col(0.49, 0.42, 1.0)
        let mint = col(0.90, 0.88, 1.0)
        let lw = s * 0.035

        // Viewfinder corner brackets.
        let vf = body.insetBy(dx: body.width * 0.14, dy: body.width * 0.14)
        let arm = vf.width * 0.2
        ctx.setStrokeColor(accent); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for (cx, cy, dx, dy) in [(vf.minX, vf.minY, 1.0, 1.0), (vf.maxX, vf.minY, -1.0, 1.0), (vf.minX, vf.maxY, 1.0, -1.0), (vf.maxX, vf.maxY, -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: cx, y: cy + dy * arm)); ctx.addLine(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
        }
        ctx.strokePath()

        // Wide frame (16:9) and tall frame (9:16), overlapping.
        let wideW = vf.width * 0.62, wideH = wideW * 9 / 16
        let wide = CGRect(x: vf.midX - wideW * 0.62, y: vf.midY - wideH * 0.62, width: wideW, height: wideH)
        let tallH = vf.height * 0.58, tallW = tallH * 9 / 16
        let tall = CGRect(x: vf.midX + vf.width * 0.04, y: vf.midY - tallH * 0.38, width: tallW, height: tallH)
        let r = s * 0.025
        ctx.addPath(CGPath(roundedRect: wide, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(col(0.49, 0.42, 1.0, 0.22)); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: wide, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setStrokeColor(accent); ctx.setLineWidth(lw * 0.85); ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: tall, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(col(0.80, 0.98, 0.95, 0.16)); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: tall, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setStrokeColor(mint); ctx.setLineWidth(lw * 0.85); ctx.strokePath()

        // Record dot.
        let dot = s * 0.07
        ctx.setFillColor(col(0.94, 0.31, 0.29))
        ctx.fillEllipse(in: CGRect(x: vf.maxX - dot * 1.7, y: vf.maxY - dot * 1.7, width: dot, height: dot))
        return ctx.makeImage()
    }

    public static func image() -> NSImage? {
        guard let cg = cgImage(size: 1024) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
    }

    /// Writes an .iconset folder (for `iconutil -c icns`).
    public static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let cg = cgImage(size: base * scale) else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
