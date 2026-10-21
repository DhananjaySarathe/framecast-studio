import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// A parsed Adobe/Resolve `.cube` 3D LUT.
public struct CubeLUT: Sendable {
    public let size: Int
    public let data: Data       // RGBA Float32, red fastest, for CIColorCubeWithColorSpace
    public enum Problem: Error, LocalizedError {
        case unreadable, noSize, wrongCount(Int, Int), tooLarge
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read"
            case .noSize: return "No LUT_3D_SIZE in the file"
            case .wrongCount(let e, let g): return "Expected \(e) rows, found \(g)"
            case .tooLarge: return "The GPU could not hold this LUT"
            }
        }
    }

    public static func load(path: String) throws -> CubeLUT {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw Problem.unreadable }
        var size = 0
        var dmin: [Float] = [0, 0, 0], dmax: [Float] = [1, 1, 1]
        var values: [Float] = []
        values.reserveCapacity(65 * 65 * 65 * 3)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.first == "LUT_3D_SIZE", parts.count > 1 { size = Int(parts[1]) ?? 0; continue }
            if parts.first == "LUT_1D_SIZE" { continue }
            if parts.first == "DOMAIN_MIN", parts.count >= 4 { dmin = parts[1...3].compactMap { Float($0) }; continue }
            if parts.first == "DOMAIN_MAX", parts.count >= 4 { dmax = parts[1...3].compactMap { Float($0) }; continue }
            if parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                values.append(contentsOf: [r, g, b])
            }
        }
        guard size > 1 else { throw Problem.noSize }
        guard size <= 128 else { throw Problem.tooLarge }
        let n = size * size * size
        guard values.count == n * 3 else { throw Problem.wrongCount(n, values.count / 3) }
        var rgba = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            for c in 0..<3 {
                let v = (values[i*3+c] - dmin[c]) / max(0.0001, dmax[c] - dmin[c])
                rgba[i*4+c] = min(max(v, 0), 1)
            }
        }
        return CubeLUT(size: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    public func apply(to image: CIImage, amount: Double) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(size)
        f.cubeData = data
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let graded = f.outputImage else { return image }
        if amount >= 0.999 { return graded }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = graded
        mix.time = Float(max(0, amount))
        return mix.outputImage ?? graded
    }
}

/// Builds and caches colour-cube tables for the chroma and luma keyers.
final class KeyerCache {
    private var cache: [Int: Data] = [:]
    private let lock = NSLock()
    private let dim = 48

    func chroma(_ s: ChromaKeySettings) -> (Data, Int) {
        let key = s.hashValue
        lock.lock(); if let d = cache[key] { lock.unlock(); return (d, dim) }; lock.unlock()
        let n = dim
        var out = [Float](repeating: 0, count: n * n * n * 4)
        func ycc(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (y, (b - y) / 1.8556, (r - y) / 1.5748)
        }
        let k = ycc(Float(s.key.red), Float(s.key.green), Float(s.key.blue))
        let sim = Float(s.similarity) * 0.5, smooth = max(0.001, Float(s.smoothness) * 0.5)
        // Which channel is the key? Spill removal clamps it toward the other two.
        let keyIsGreen = s.key.green >= s.key.blue
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = Float(ri) / Float(n - 1), g = Float(gi) / Float(n - 1), b = Float(bi) / Float(n - 1)
            let c = ycc(r, g, b)
            let d = sqrt((c.1 - k.1) * (c.1 - k.1) + (c.2 - k.2) * (c.2 - k.2))
            var a = min(max((d - sim) / smooth, 0), 1)
            var rr = r, gg = g, bb = b
            if s.spill > 0 {
                if keyIsGreen { let lim = max(r, b); if gg > lim { gg = gg - Float(s.spill) * (gg - lim) } }
                else { let lim = max(r, g); if bb > lim { bb = bb - Float(s.spill) * (bb - lim) } }
            }
            if s.lumaRestore > 0 && a < 1 { a = min(1, a + Float(s.lumaRestore) * c.0 * 0.5) }
            let m = s.matte
            if a <= Float(m.clipBlack) { a = 0 } else if a >= Float(m.clipWhite) { a = 1 }
            let i = ((bi * n + gi) * n + ri) * 4
            out[i] = rr * a; out[i+1] = gg * a; out[i+2] = bb * a; out[i+3] = a
            _ = (rr, bb)
        } } }
        let d = out.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); cache[key] = d; lock.unlock()
        return (d, n)
    }

    func luma(_ s: LumaKeySettings) -> (Data, Int) {
        let key = s.hashValue &+ 7
        lock.lock(); if let d = cache[key] { lock.unlock(); return (d, dim) }; lock.unlock()
        let n = dim
        var out = [Float](repeating: 0, count: n * n * n * 4)
        let lo = Float(s.low), hi = Float(s.high), soft = max(0.001, Float(s.softness))
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = Float(ri) / Float(n - 1), g = Float(gi) / Float(n - 1), b = Float(bi) / Float(n - 1)
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // Keys out (transparent) luma inside [low, high], with soft edges.
            let inside = min(max((y - lo) / soft + 1, 0), 1) * min(max((hi - y) / soft + 1, 0), 1)
            var a = 1 - inside
            if s.invert { a = 1 - a }
            let i = ((bi * n + gi) * n + ri) * 4
            out[i] = r * a; out[i+1] = g * a; out[i+2] = b * a; out[i+3] = a
        } } }
        let d = out.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); cache[key] = d; lock.unlock()
        return (d, n)
    }
}

enum FilterChain {
    static func colorCorrection(_ img: CIImage, _ c: ColorCorrection) -> CIImage {
        if c.isNeutral { return img }
        var out = img
        let cc = CIFilter.colorControls()
        cc.inputImage = out; cc.brightness = Float(c.brightness); cc.contrast = Float(c.contrast); cc.saturation = Float(c.saturation)
        out = cc.outputImage ?? out
        if c.gamma != 1 {
            let g = CIFilter.gammaAdjust(); g.inputImage = out; g.power = Float(1 / max(0.05, c.gamma)); out = g.outputImage ?? out
        }
        if c.hueDegrees != 0 {
            let h = CIFilter.hueAdjust(); h.inputImage = out; h.angle = Float(c.hueDegrees * .pi / 180); out = h.outputImage ?? out
        }
        return out
    }

    static func cube(_ img: CIImage, data: Data, dim: Int) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = img; f.cubeDimension = Float(dim); f.cubeData = data
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return f.outputImage ?? img
    }

    static func matte(_ img: CIImage, _ m: MatteSettings) -> CIImage {
        var out = img
        if m.choke > 0 {
            // Shrink the matte edge by eroding alpha.
            let e = CIFilter.morphologyMinimum(); e.inputImage = out; e.radius = Float(m.choke * 6); out = e.outputImage?.cropped(to: img.extent) ?? out
        }
        if m.edgeRefine > 0 {
            let b = CIFilter.gaussianBlur(); b.inputImage = out.clampedToExtent(); b.radius = Float(m.edgeRefine * 2.5)
            out = b.outputImage?.cropped(to: img.extent) ?? out
        }
        return out
    }

    static func apply(_ filters: [FilterSpec], to img: CIImage, keyers: KeyerCache) -> CIImage {
        var out = img
        for f in filters where f.isEnabled {
            switch f.kind {
            case .colorCorrection(let c): out = colorCorrection(out, c)
            case .chromaKey(let s):
                let (d, n) = keyers.chroma(s); out = matte(cube(out, data: d, dim: n), s.matte)
            case .lumaKey(let s):
                let (d, n) = keyers.luma(s); out = matte(cube(out, data: d, dim: n), s.matte)
            }
        }
        return out
    }
}
