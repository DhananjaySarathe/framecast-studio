// Sharpness test: does a whole-canvas zoom sample the 4K screen at native resolution (Core Image pushes the affine
// down to the source) or upscale an already-1080p composite? Compared with a per-layer crop zoom.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

func makePB(_ w: Int, _ h: Int) -> CVPixelBuffer {
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    return pb!
}
let comp = Compositor()
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
// 4K screen with 1-pixel vertical stripes: visible only when sampled at (or above) native resolution.
let scrPB = makePB(3840, 2160)
let stripes = CIFilter.stripesGenerator()
stripes.color0 = .white; stripes.color1 = .black; stripes.width = 1; stripes.sharpness = 1; stripes.center = .zero
comp.context.render(stripes.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 3840, height: 2160)), to: scrPB,
                    bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160), colorSpace: srgb)

let scrID = UUID()
let canvas = CGSize(width: 1920, height: 1080)
func resolve(_ i: SceneItem) -> LayerInput? { LayerInput(image: CIImage(cvPixelBuffer: scrPB)) }
let item = SceneItem(sourceID: scrID, transform: .full, fit: .fit)

func contrast(_ img: CIImage) -> Double {
    let out = makePB(1920, 1080)
    comp.render(img, to: out, canvas: canvas)
    CVPixelBufferLockBaseAddress(out, .readOnly); defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(out)
    var vals: [Double] = []
    for y in stride(from: 500, to: 580, by: 4) { for x in 900..<1020 { vals.append(Double(base[y * bpr + x * 4 + 1])) } }
    let m = vals.reduce(0, +) / Double(vals.count)
    return sqrt(vals.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(vals.count))
}
let plain = comp.compose(items: [item], canvas: canvas, resolve: resolve)
print(String(format: "no zoom (4K shown at 1080p):            pixel std-dev %.1f (stripes average out)", contrast(plain)))
let t = CGAffineTransform(translationX: -960, y: -540).concatenating(CGAffineTransform(scaleX: 2, y: 2)).concatenating(CGAffineTransform(translationX: 960, y: 540))
let canvasZoom = plain.transformed(by: t).cropped(to: CGRect(origin: .zero, size: canvas))
print(String(format: "whole-canvas zoom 2x (affine on composite): pixel std-dev %.1f", contrast(canvasZoom)))
var cropped = item; cropped.crop = ItemCrop(left: 0.25, top: 0.25, right: 0.25, bottom: 0.25)
let layerZoom = comp.compose(items: [cropped], canvas: canvas, resolve: resolve)
print(String(format: "per-layer crop zoom 2x (ItemCrop):          pixel std-dev %.1f", contrast(layerZoom)))
// A composite that was flattened to 1080p first, then zoomed (what an upscale would look like).
let flat = makePB(1920, 1080); comp.render(plain, to: flat, canvas: canvas)
let upscaled = CIImage(cvPixelBuffer: flat).transformed(by: t).cropped(to: CGRect(origin: .zero, size: canvas))
print(String(format: "reference: flattened 1080p then zoomed 2x:  pixel std-dev %.1f", contrast(upscaled)))
