import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import AppKit

public enum TransitionKind: String, Codable, Sendable, CaseIterable {
    case cut, fade, slide, wipe, stinger, move
    public var title: String { rawValue.capitalized }
}

/// What the compositor needs to draw one layer.
public struct LayerInput {
    public var image: CIImage?
    public var isText: Bool
    public var lut: CubeLUT?
    public var lutAmount: Double
    public init(image: CIImage?, isText: Bool = false, lut: CubeLUT? = nil, lutAmount: Double = 1) {
        self.image = image; self.isText = isText; self.lut = lut; self.lutAmount = lutAmount
    }
}

public final class Compositor: @unchecked Sendable {
    public let context: CIContext
    public let device: MTLDevice?
    let keyers = KeyerCache()
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {
        device = MTLCreateSystemDefaultDevice()
        let opts: [CIContextOption: Any] = [
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
            .name: "Framecast compositor",
        ]
        if let device { context = CIContext(mtlDevice: device, options: opts) } else { context = CIContext(options: opts) }
    }

    // MARK: Layers

    /// Canvas-pixel frame of an item (Core Image coordinates: origin bottom-left).
    public static func frame(of t: ItemTransform, canvas: CGSize) -> CGRect {
        CGRect(x: t.x * canvas.width, y: canvas.height - (t.y + t.height) * canvas.height,
               width: t.width * canvas.width, height: t.height * canvas.height)
    }

    public func renderItem(_ item: SceneItem, input: LayerInput, canvas: CGSize, opacity extraOpacity: Double = 1) -> CIImage? {
        guard item.isVisible, var img = input.image, img.extent.width > 0, img.extent.height > 0 else { return nil }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if let lut = input.lut { img = lut.apply(to: img, amount: input.lutAmount) }
        if !item.filters.isEmpty { img = FilterChain.apply(item.filters, to: img, keyers: keyers) }

        // Crop (fractions of the source; top/bottom measured from the top edge like the UI).
        let e = img.extent
        if !item.crop.isEmpty {
            let c = item.crop
            let r = CGRect(x: e.minX + c.left * e.width, y: e.minY + c.bottom * e.height,
                           width: e.width * max(0.01, 1 - c.left - c.right), height: e.height * max(0.01, 1 - c.top - c.bottom))
            img = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        if item.isMirrored {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -img.extent.width, y: 0))
        }

        let frame = Self.frame(of: item.transform, canvas: canvas)
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        let iw = img.extent.width, ih = img.extent.height
        var sx = frame.width / iw, sy = frame.height / ih
        switch item.fit {
        case .fill: let s = max(sx, sy); sx = s; sy = s
        case .fit: let s = min(sx, sy); sx = s; sy = s
        case .stretch: break
        }
        let w = iw * sx, h = ih * sy
        var tx = frame.minX + (frame.width - w) / 2
        let ty = frame.minY + (frame.height - h) / 2
        if input.isText && item.role == .lowerThird { tx = frame.minX }   // lower thirds hug the left edge
        img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: tx, y: ty)))
        let shown = img.extent.intersection(frame)
        img = img.cropped(to: shown)

        switch item.mask {
        case .none: break
        case .circle:
            img = masked(img, rect: shown, radius: min(shown.width, shown.height) / 2)
        case .roundedRect(let r):
            img = masked(img, rect: shown, radius: CGFloat(r) * min(frame.width, frame.height))
        }
        let alpha = item.opacity * extraOpacity
        if alpha < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, alpha)))])
        }
        if item.transform.rotationDegrees != 0 {
            let cx = frame.midX, cy = frame.midY
            let rot = CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: -item.transform.rotationDegrees * .pi / 180))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
            img = img.transformed(by: rot)
        }
        return img
    }

    private func masked(_ img: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        guard radius > 0.5 else { return img }
        let gen = CIFilter.roundedRectangleGenerator()
        gen.extent = rect; gen.radius = Float(radius); gen.color = .white
        guard let mask = gen.outputImage else { return img }
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = img; blend.backgroundImage = CIImage.empty(); blend.maskImage = mask
        return blend.outputImage?.cropped(to: rect) ?? img
    }

    public func compose(items: [SceneItem], canvas: CGSize, opacity: Double = 1, resolve: (SceneItem) -> LayerInput?) -> CIImage {
        var acc = CIImage.empty()
        for item in items {
            guard let input = resolve(item), let layer = renderItem(item, input: input, canvas: canvas, opacity: opacity) else { continue }
            acc = layer.composited(over: acc)
        }
        return acc
    }

    // MARK: Transitions

    public static func ease(_ p: Double) -> Double {
        // cubic-bezier(0.65, 0, 0.35, 1) is close to ease-in-out cubic.
        p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    public func transition(_ kind: TransitionKind, from a: [SceneItem], to b: [SceneItem], progress raw: Double, canvas: CGSize,
                           accent: RGBA, resolve: (SceneItem) -> LayerInput?) -> CIImage {
        let p = Self.ease(min(max(raw, 0), 1))
        let bounds = CGRect(origin: .zero, size: canvas)
        switch kind {
        case .cut:
            return compose(items: b, canvas: canvas, resolve: resolve)
        case .fade:
            let ia = compose(items: a, canvas: canvas, resolve: resolve), ib = compose(items: b, canvas: canvas, resolve: resolve)
            let f = CIFilter.dissolveTransition(); f.inputImage = ia; f.targetImage = ib; f.time = Float(p)
            return f.outputImage?.cropped(to: bounds) ?? ib
        case .slide:
            let ia = compose(items: a, canvas: canvas, resolve: resolve).transformed(by: CGAffineTransform(translationX: -p * canvas.width, y: 0))
            let ib = compose(items: b, canvas: canvas, resolve: resolve).transformed(by: CGAffineTransform(translationX: (1 - p) * canvas.width, y: 0))
            return ib.composited(over: ia).cropped(to: bounds)
        case .wipe:
            let ia = compose(items: a, canvas: canvas, resolve: resolve), ib = compose(items: b, canvas: canvas, resolve: resolve)
            return ib.cropped(to: CGRect(x: 0, y: 0, width: p * canvas.width, height: canvas.height)).composited(over: ia).cropped(to: bounds)
        case .stinger:
            // A sweep in the accent colour that covers the cut at the midpoint.
            let under = p < 0.5 ? compose(items: a, canvas: canvas, resolve: resolve) : compose(items: b, canvas: canvas, resolve: resolve)
            let band = CIImage(color: CIColor(red: accent.red, green: accent.green, blue: accent.blue))
            let x = (p * 2.4 - 1.2) * canvas.width
            let bar = band.cropped(to: CGRect(x: x, y: 0, width: canvas.width * 1.2, height: canvas.height))
            return bar.composited(over: under).cropped(to: bounds)
        case .move:
            var out = CIImage.empty()
            var matchedA = Set<UUID>()
            for ib in b {
                if let ia = a.first(where: { $0.sourceID == ib.sourceID && !matchedA.contains($0.id) }) {
                    matchedA.insert(ia.id)
                    var mid = ib
                    let ta = ia.transform, tb = ib.transform
                    func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * p }
                    mid.transform = ItemTransform(x: lerp(ta.x, tb.x), y: lerp(ta.y, tb.y), width: lerp(ta.width, tb.width),
                                                  height: lerp(ta.height, tb.height), rotationDegrees: lerp(ta.rotationDegrees, tb.rotationDegrees))
                    mid.opacity = lerp(ia.isVisible ? ia.opacity : 0, ib.isVisible ? ib.opacity : 0)
                    mid.isVisible = ia.isVisible || ib.isVisible
                    if case .roundedRect(let ra) = ia.mask, case .roundedRect(let rb) = ib.mask { mid.mask = .roundedRect(radius: lerp(ra, rb)) }
                    else if p < 0.5 { mid.mask = ia.mask }
                    if let input = resolve(mid), let layer = renderItem(mid, input: input, canvas: canvas) { out = layer.composited(over: out) }
                } else if let input = resolve(ib), let layer = renderItem(ib, input: input, canvas: canvas, opacity: p) {
                    out = layer.composited(over: out)
                }
            }
            // Layers that leave fade out underneath.
            var leaving = CIImage.empty()
            for ia in a where !matchedA.contains(ia.id) {
                if let input = resolve(ia), let layer = renderItem(ia, input: input, canvas: canvas, opacity: 1 - p) { leaving = layer.composited(over: leaving) }
            }
            return out.composited(over: leaving)
        }
    }

    // MARK: Output

    public func render(_ image: CIImage, to pb: CVPixelBuffer, canvas: CGSize) {
        let bounds = CGRect(origin: .zero, size: canvas)
        let bg = CIImage(color: .black).cropped(to: bounds)
        context.render(image.composited(over: bg).cropped(to: bounds), to: pb, bounds: bounds, colorSpace: sRGB)
    }

    public func cgImage(_ image: CIImage, canvas: CGSize, scale: CGFloat) -> CGImage? {
        let bounds = CGRect(origin: .zero, size: canvas)
        let bg = CIImage(color: .black).cropped(to: bounds)
        let scaled = image.composited(over: bg).cropped(to: bounds).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded()))
    }
}
