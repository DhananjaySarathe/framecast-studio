import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Framecast's own procedurally drawn backgrounds (no third-party artwork).
public enum Wallpapers {
    public struct Item: Identifiable, Hashable, Sendable { public let id: String; public let name: String }

    public static let all: [Item] = [
        Item(id: "dusk-grid", name: "Dusk Grid"),
        Item(id: "teal-tide", name: "Teal Tide"),
        Item(id: "graphite", name: "Graphite"),
        Item(id: "aurora", name: "Aurora"),
        Item(id: "ember", name: "Ember"),
        Item(id: "ocean-mesh", name: "Ocean Mesh"),
        Item(id: "paper", name: "Paper"),
        Item(id: "midnight", name: "Midnight"),
    ]

    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()
    static let side: CGFloat = 2160

    public static func image(_ id: String) -> CIImage {
        lock.lock(); if let c = cache[id] { lock.unlock(); return c }; lock.unlock()
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let rendered: CIImage
        if let cg = ctx.createCGImage(make(id), from: CGRect(x: 0, y: 0, width: side, height: side)) {
            rendered = CIImage(cgImage: cg)
        } else {
            rendered = make(id).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        }
        lock.lock(); cache[id] = rendered; lock.unlock()
        return rendered
    }

    /// A small picture of a built-in background, cropped the way a `width`×`height` canvas shows it (uncached: the
    /// background picker draws these at thumbnail size instead of keeping full-size wallpapers in memory).
    public static func preview(_ id: String, width: Int, height: Int) -> CGImage? {
        let w = CGFloat(width), h = CGFloat(height), k = max(w, h) / side
        let img = make(id).transformed(by: CGAffineTransform(scaleX: k, y: k))
        return previewContext.createCGImage(img, from: CGRect(x: (side * k - w) / 2, y: (side * k - h) / 2, width: w, height: h))
    }
    private static let previewContext = CIContext(options: [.cacheIntermediates: false])

    static func linear(_ a: CIColor, _ b: CIColor, from p0: CGPoint, to p1: CGPoint) -> CIImage {
        let g = CIFilter.linearGradient(); g.color0 = a; g.color1 = b; g.point0 = p0; g.point1 = p1
        return g.outputImage!
    }
    static func radial(_ a: CIColor, _ b: CIColor, center: CGPoint, r0: Float, r1: Float) -> CIImage {
        let g = CIFilter.radialGradient(); g.color0 = a; g.color1 = b; g.center = center; g.radius0 = r0; g.radius1 = r1
        return g.outputImage!
    }
    static func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }

    static func make(_ id: String) -> CIImage {
        let s = side
        let rect = CGRect(x: 0, y: 0, width: s, height: s)
        switch id {
        case "teal-tide":
            var img = linear(c(0.03, 0.17, 0.20), c(0.02, 0.06, 0.09), from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            for i in 0..<5 {
                let band = radial(c(0.18, 0.75, 0.70, 0.22 - Double(i) * 0.03), c(0, 0, 0, 0),
                                  center: CGPoint(x: s * (0.2 + 0.15 * Double(i)), y: s * (0.15 + 0.12 * Double(i))), r0: 0, r1: Float(s) * 0.45)
                img = band.composited(over: img)
            }
            return img.cropped(to: rect)
        case "graphite":
            let base = linear(c(0.16, 0.16, 0.17), c(0.07, 0.07, 0.08), from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: 0))
            let noise = CIFilter.randomGenerator().outputImage!.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0.04, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)])
            return noise.composited(over: base).cropped(to: rect)
        case "aurora":
            var img = linear(c(0.04, 0.03, 0.10), c(0.01, 0.02, 0.05), from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: 0))
            img = radial(c(0.20, 0.85, 0.60, 0.35), c(0, 0, 0, 0), center: CGPoint(x: s * 0.3, y: s * 0.75), r0: 0, r1: Float(s) * 0.5).composited(over: img)
            img = radial(c(0.45, 0.30, 0.90, 0.30), c(0, 0, 0, 0), center: CGPoint(x: s * 0.75, y: s * 0.6), r0: 0, r1: Float(s) * 0.45).composited(over: img)
            return img.cropped(to: rect)
        case "ember":
            var img = linear(c(0.22, 0.06, 0.04), c(0.06, 0.02, 0.03), from: CGPoint(x: s, y: s), to: CGPoint(x: 0, y: 0))
            img = radial(c(0.95, 0.45, 0.15, 0.35), c(0, 0, 0, 0), center: CGPoint(x: s * 0.8, y: s * 0.2), r0: 0, r1: Float(s) * 0.55).composited(over: img)
            return img.cropped(to: rect)
        case "ocean-mesh":
            var img = linear(c(0.03, 0.10, 0.25), c(0.01, 0.03, 0.08), from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            img = radial(c(0.10, 0.55, 0.95, 0.30), c(0, 0, 0, 0), center: CGPoint(x: s * 0.25, y: s * 0.3), r0: 0, r1: Float(s) * 0.5).composited(over: img)
            img = radial(c(0.25, 0.85, 0.80, 0.18), c(0, 0, 0, 0), center: CGPoint(x: s * 0.8, y: s * 0.85), r0: 0, r1: Float(s) * 0.4).composited(over: img)
            return img.cropped(to: rect)
        case "paper":
            return linear(c(0.95, 0.94, 0.91), c(0.86, 0.85, 0.82), from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0)).cropped(to: rect)
        case "midnight":
            return linear(c(0.05, 0.06, 0.09), c(0.02, 0.02, 0.03), from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: 0)).cropped(to: rect)
        default: // dusk-grid
            var img = linear(c(0.09, 0.11, 0.16), c(0.04, 0.05, 0.07), from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            img = radial(c(0.30, 0.82, 0.77, 0.16), c(0, 0, 0, 0), center: CGPoint(x: s * 0.82, y: s * 0.86), r0: 0, r1: Float(s) * 0.55).composited(over: img)
            // Fine grid lines.
            let line = CIImage(color: c(1, 1, 1, 0.035))
            let step = s / 24
            for i in 0...24 {
                img = line.cropped(to: CGRect(x: CGFloat(i) * step, y: 0, width: 2, height: s)).composited(over: img)
                img = line.cropped(to: CGRect(x: 0, y: CGFloat(i) * step, width: s, height: 2)).composited(over: img)
            }
            return img.cropped(to: rect)
        }
    }
}
