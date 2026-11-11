// Framecast live-editor research: per-frame GPU cost of candidate transitions and "produced look" effects
// at 1920x1080, using the same CIContext options as Framecast's Compositor. Scratch benchmark only.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import AVFoundation
import AppKit

setbuf(stdout, nil)
let W = 1920, H = 1080
let canvas = CGSize(width: W, height: H)
let bounds = CGRect(origin: .zero, size: canvas)
let device = MTLCreateSystemDefaultDevice()!
print("GPU: \(device.name)  supportsDynamicLibraries: \(device.supportsDynamicLibraries)")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(mtlDevice: device, options: [
    .outputColorSpace: sRGB,
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .cacheIntermediates: false, .name: "bench",
])
let black = CIImage(color: .black).cropped(to: bounds)

func makePB(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                kCVPixelBufferMetalCompatibilityKey as String: true]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    return pb!
}

func renderOnce(_ img: CIImage, to pb: CVPixelBuffer) -> CIRenderInfo {
    let dest = CIRenderDestination(pixelBuffer: pb)
    dest.colorSpace = sRGB
    let task = try! ctx.startTask(toRender: img, to: dest)
    return try! task.waitUntilCompleted()
}

// Two "camera" frames with real texture so nothing is trivially cheap.
func sourcePB(seed: CGFloat, color: CIColor) -> CVPixelBuffer {
    let pb = makePB(W, H)
    let noise = CIFilter.randomGenerator().outputImage!
        .transformed(by: CGAffineTransform(translationX: seed * 97, y: seed * 37)).cropped(to: bounds)
        .applyingGaussianBlur(sigma: 3).cropped(to: bounds)
    let g = CIFilter.linearGradient()
    g.point0 = .zero; g.point1 = CGPoint(x: W, y: H); g.color0 = color; g.color1 = CIColor(red: 0.08, green: 0.08, blue: 0.1)
    let img = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: g.outputImage!.cropped(to: bounds)])
    _ = renderOnce(img.cropped(to: bounds), to: pb)
    return pb
}
let pbA = sourcePB(seed: 1, color: CIColor(red: 0.9, green: 0.5, blue: 0.3))
let pbB = sourcePB(seed: 7, color: CIColor(red: 0.2, green: 0.5, blue: 0.9))
func A() -> CIImage { CIImage(cvPixelBuffer: pbA) }
func B() -> CIImage { CIImage(cvPixelBuffer: pbB) }

func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }

struct Row { let name: String; let wallMed: Double; let wallP95: Double; let gpuMed: Double; let gpuP95: Double; let passes: Int }
var rows: [Row] = []
let outPB = makePB(W, H)

func pct(_ v: [Double], _ q: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * q))] }

func bench(_ name: String, frames: Int = 90, _ make: (Double, Int) -> CIImage) {
    var walls: [Double] = [], gpus: [Double] = [], passes = 0
    for i in 0..<(frames + 10) {
        let p = Double(i % frames) / Double(frames - 1)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let img = make(p, i).composited(over: black).cropped(to: bounds)
        let info = renderOnce(img, to: outPB)
        let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if i >= 10 { walls.append(wall); gpus.append(info.kernelExecutionTime * 1000); passes = max(passes, info.passCount) }
    }
    let r = Row(name: name, wallMed: pct(walls, 0.5), wallP95: pct(walls, 0.95), gpuMed: pct(gpus, 0.5), gpuP95: pct(gpus, 0.95), passes: passes)
    rows.append(r)
    print(String(format: "%-46@ wall %6.2f / p95 %6.2f ms   gpu %6.2f / p95 %6.2f ms   passes %d",
                 name as NSString, r.wallMed, r.wallP95, r.gpuMed, r.gpuP95, r.passes))
}

// ---------- Built-in transition filters available on this Mac ----------
let transitionNames = CIFilter.filterNames(inCategory: kCICategoryTransition)
print("Core Image transition filters on this Mac (\(transitionNames.count)): \(transitionNames.joined(separator: ", "))")

func radial(_ c: CGPoint, _ r0: Float, _ r1: Float, _ c0: CIColor, _ c1: CIColor) -> CIImage {
    let g = CIFilter.radialGradient(); g.center = c; g.radius0 = r0; g.radius1 = r1; g.color0 = c0; g.color1 = c1
    return g.outputImage!.cropped(to: bounds)
}
let shading = radial(CGPoint(x: 960, y: 540), 0, 900, CIColor(red: 1, green: 1, blue: 1, alpha: 1), CIColor(red: 0, green: 0, blue: 0, alpha: 0))
let maskNoise = CIFilter.randomGenerator().outputImage!.cropped(to: bounds).applyingGaussianBlur(sigma: 20).cropped(to: bounds)

func ciTransition(_ name: String, _ extra: [String: Any] = [:]) -> (Double, Int) -> CIImage {
    return { p, _ in
        let f = CIFilter(name: name)!
        f.setDefaults()
        f.setValue(A(), forKey: kCIInputImageKey)
        f.setValue(B(), forKey: kCIInputTargetImageKey)
        f.setValue(ease(p), forKey: kCIInputTimeKey)
        if f.inputKeys.contains(kCIInputExtentKey) { f.setValue(CIVector(cgRect: bounds), forKey: kCIInputExtentKey) }
        if f.inputKeys.contains(kCIInputCenterKey) { f.setValue(CIVector(x: 960, y: 540), forKey: kCIInputCenterKey) }
        for (k, v) in extra { f.setValue(v, forKey: k) }
        return f.outputImage!.cropped(to: bounds)
    }
}

bench("baseline: one full-frame camera") { _, _ in A() }
bench("baseline: Move-like 2 layers, rounded mask") { p, _ in
    let e = ease(p)
    let big = A().transformed(by: CGAffineTransform(scaleX: 1 - 0.45 * e, y: 1 - 0.45 * e).concatenating(.init(translationX: 40 * e, y: 40 * e)))
    let r = CGRect(x: 1100 - 300 * e, y: 120, width: 720, height: 405)
    let pip = B().transformed(by: CGAffineTransform(scaleX: r.width / 1920, y: r.height / 1080).concatenating(.init(translationX: r.minX, y: r.minY)))
    let gen = CIFilter.roundedRectangleGenerator(); gen.extent = r; gen.radius = 28; gen.color = .white
    let masked = pip.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: gen.outputImage!]).cropped(to: r)
    return masked.composited(over: big)
}
bench("CIDissolveTransition (current Fade)", ciTransition("CIDissolveTransition"))
bench("CISwipeTransition", ciTransition("CISwipeTransition", ["inputWidth": 400.0]))
bench("CIBarsSwipeTransition", ciTransition("CIBarsSwipeTransition"))
bench("CICopyMachineTransition", ciTransition("CICopyMachineTransition"))
bench("CIFlashTransition", ciTransition("CIFlashTransition"))
bench("CIModTransition", ciTransition("CIModTransition"))
bench("CIRippleTransition", ciTransition("CIRippleTransition", ["inputShadingImage": shading]))
bench("CIPageCurlTransition", ciTransition("CIPageCurlTransition", ["inputShadingImage": shading, "inputBacksideImage": A()]))
bench("CIPageCurlWithShadowTransition", ciTransition("CIPageCurlWithShadowTransition", ["inputBacksideImage": A()]))
bench("CIAccordionFoldTransition", ciTransition("CIAccordionFoldTransition"))
bench("CIDisintegrateWithMaskTransition", ciTransition("CIDisintegrateWithMaskTransition", ["inputMaskImage": maskNoise]))

// Track-matte / luma wipe: gradient mask sweeping across (OBS track matte equivalent, no video decode).
bench("luma/track-matte wipe (CIBlendWithMask)") { p, _ in
    let g = CIFilter.smoothLinearGradient()
    let x = CGFloat(-400 + ease(p) * 2720)
    g.point0 = CGPoint(x: x + 300, y: 0); g.point1 = CGPoint(x: x - 300, y: 200)
    g.color0 = CIColor(red: 0, green: 0, blue: 0); g.color1 = CIColor(red: 1, green: 1, blue: 1)
    return B().applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: A(), kCIInputMaskImageKey: g.outputImage!.cropped(to: bounds)])
}

// Whip pan: push both shots sideways with a directional motion blur that peaks mid-move.
func whip(_ maxRadius: Double) -> (Double, Int) -> CIImage {
    return { p, _ in
        let e = ease(p)
        let a = A().transformed(by: .init(translationX: CGFloat(-e) * canvas.width, y: 0))
        let b = B().transformed(by: .init(translationX: CGFloat(1 - e) * canvas.width, y: 0))
        let both = b.composited(over: a).cropped(to: bounds)
        let r = maxRadius * sin(.pi * p)
        if r < 0.5 { return both }
        let m = CIFilter.motionBlur(); m.inputImage = both.clampedToExtent(); m.radius = Float(r); m.angle = 0
        return m.outputImage!.cropped(to: bounds)
    }
}
bench("whip pan, CIMotionBlur peak r=40", whip(40))
bench("whip pan, CIMotionBlur peak r=100", whip(100))
bench("CIMotionBlur r=100 held (worst frame)") { _, _ in
    let m = CIFilter.motionBlur(); m.inputImage = A().clampedToExtent(); m.radius = 100; m.angle = 0
    return m.outputImage!.cropped(to: bounds)
}

// Zoom-through: outgoing shot scales up with a radial zoom blur, incoming settles from 1.25x to 1x.
bench("zoom-through, CIZoomBlur peak 25") { p, _ in
    let e = ease(p)
    let img: CIImage
    if p < 0.5 {
        let s = 1 + 1.5 * e
        img = A().transformed(by: CGAffineTransform(translationX: -960, y: -540).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: 960, y: 540)))
    } else {
        let s = 1.25 - 0.25 * e
        img = B().transformed(by: CGAffineTransform(translationX: -960, y: -540).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: 960, y: 540)))
    }
    let z = CIFilter.zoomBlur(); z.inputImage = img.clampedToExtent(); z.center = CGPoint(x: 960, y: 540); z.amount = Float(25 * sin(.pi * p))
    return z.outputImage!.cropped(to: bounds)
}
bench("CIGaussianBlur sigma 20 (defocus / bg blur)") { _, _ in A().clampedToExtent().applyingGaussianBlur(sigma: 20).cropped(to: bounds) }

// Camera motion on a static shot.
bench("push-in / Ken Burns affine 1.00->1.08") { p, _ in
    let s = 1 + 0.08 * p
    return A().transformed(by: CGAffineTransform(translationX: -960, y: -540).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: 960 + 30 * p, y: 540)))
}
bench("push-in via CILanczosScaleTransform") { p, _ in
    let l = CIFilter.lanczosScaleTransform(); l.inputImage = A(); l.scale = Float(1 + 0.08 * p); l.aspectRatio = 1
    return l.outputImage!.transformed(by: .init(translationX: -CGFloat(0.04 * p) * 1920, y: -CGFloat(0.04 * p) * 1080))
}

// Grading and texture.
func cubeData(_ n: Int) -> Data {
    var d = [Float](); d.reserveCapacity(n * n * n * 4)
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
        let rf = Float(r) / Float(n - 1), gf = Float(g) / Float(n - 1), bf = Float(b) / Float(n - 1)
        d += [min(1, rf * 1.04 + 0.02), gf, max(0, bf * 0.94), 1]   // gentle warm grade
    } } }
    return d.withUnsafeBufferPointer { Data(buffer: $0) }
}
let cube33 = cubeData(33), cube64 = cubeData(64)
bench("LUT CIColorCubeWithColorSpace 33^3") { _, _ in
    let f = CIFilter.colorCubeWithColorSpace(); f.inputImage = A(); f.cubeDimension = 33; f.cubeData = cube33; f.colorSpace = sRGB
    return f.outputImage!
}
bench("LUT CIColorCubeWithColorSpace 64^3") { _, _ in
    let f = CIFilter.colorCubeWithColorSpace(); f.inputImage = A(); f.cubeDimension = 64; f.cubeData = cube64; f.colorSpace = sRGB
    return f.outputImage!
}
bench("grain: CIRandomGenerator + soft light") { _, i in
    let n = CIFilter.randomGenerator().outputImage!
        .transformed(by: .init(translationX: CGFloat((i * 211) % 997), y: CGFloat((i * 127) % 991))).cropped(to: bounds)
    let mono = n.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.12, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0.12, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0.44, y: 0.44, z: 0.44, w: 0)])
    return mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: A()])
}
bench("light leak: 2 moving radial gradients, screen") { p, _ in
    let warm = radial(CGPoint(x: 200 + 1400 * p, y: 900), 0, 700, CIColor(red: 1, green: 0.45, blue: 0.15, alpha: 0.55), CIColor(red: 1, green: 0.3, blue: 0, alpha: 0))
    let pink = radial(CGPoint(x: 1700 - 900 * p, y: 200), 0, 500, CIColor(red: 1, green: 0.3, blue: 0.5, alpha: 0.35), CIColor(red: 1, green: 0.2, blue: 0.4, alpha: 0))
    return pink.composited(over: warm).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: A()])
}
bench("CIVignetteEffect") { _, _ in
    let v = CIFilter.vignetteEffect(); v.inputImage = A(); v.center = CGPoint(x: 960, y: 540); v.radius = 1100; v.intensity = 0.35; v.falloff = 0.6
    return v.outputImage!
}

// ---------- Runtime-compiled Metal Core Image kernels (no offline `metal` compiler needed) ----------
let metalSource = """
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
  // gl-transitions "directionalwarp" (MIT), ported.
  [[stitchable]] float4 fc_directionalWarp(sampler a, sampler b, float progress, float2 dir, float smoothness, float2 size, destination dest) {
    float2 uv = dest.coord() / size;
    float2 v = normalize(dir);
    v /= abs(v.x) + abs(v.y);
    float d = v.x * 0.5 + v.y * 0.5;
    float m = 1.0 - smoothstep(-smoothness, 0.0, v.x * uv.x + v.y * uv.y - (d - 0.5 + progress * (1.0 + smoothness)));
    float4 ca = a.sample(a.transform(((uv - 0.5) * (1.0 - m) + 0.5) * size));
    float4 cb = b.sample(b.transform(((uv - 0.5) * m + 0.5) * size));
    return mix(ca, cb, m);
  }
  // gl-transitions "CrossZoom" (MIT), ported: 41 taps x 2 sources per pixel.
  [[stitchable]] float4 fc_crossZoom(sampler a, sampler b, float progress, float strengthIn, float2 size, destination dest) {
    float2 uv = dest.coord() / size;
    float2 center = float2(0.25 + 0.5 * progress, 0.5);
    float dissolve;
    if (progress <= 0.0) dissolve = 0.0;
    else if (progress >= 1.0) dissolve = 1.0;
    else { float t = progress * 2.0; dissolve = t < 1.0 ? 0.5 * pow(2.0, 10.0 * (t - 1.0)) : 0.5 * (-pow(2.0, -10.0 * (t - 1.0)) + 2.0); }
    float strength = -strengthIn / 2.0 * (cos(M_PI_F * progress / 0.5) - 1.0);
    float3 color = float3(0.0); float total = 0.0;
    float2 toCenter = center - uv;
    float offset = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    for (float t = 0.0; t <= 40.0; t += 1.0) {
      float percent = (t + offset) / 40.0;
      float weight = 4.0 * (percent - percent * percent);
      float2 p = (uv + toCenter * percent * strength) * size;
      color += mix(a.sample(a.transform(p)).rgb, b.sample(b.transform(p)).rgb, dissolve) * weight;
      total += weight;
    }
    return float4(color / total, 1.0);
  }
  // Procedural film grain, weighted to mid-tones, fresh every frame.
  [[stitchable]] float4 fc_grain(coreimage::sample_t s, float seed, float amount, coreimage::destination dest) {
    float2 p = dest.coord();
    float n = fract(sin(dot(p + seed, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    float luma = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float w = max(0.2, 1.0 - abs(luma - 0.5) * 1.4);
    return float4(s.rgb + n * amount * w * s.a, s.a);
  }
}}
"""
let tc0 = DispatchTime.now().uptimeNanoseconds
var kernels: [String: CIKernel] = [:]
do {
    let ks = try CIKernel.kernels(withMetalString: metalSource)
    for k in ks { kernels[k.name] = k }
    print(String(format: "Runtime Metal CI kernel compile: %.1f ms, kernels: %@", Double(DispatchTime.now().uptimeNanoseconds - tc0) / 1e6, kernels.keys.sorted().joined(separator: ", ")))
} catch {
    print("Runtime Metal CI kernel compile FAILED: \(error)")
}
if let k = kernels["fc_directionalWarp"] {
    bench("gl directionalwarp (runtime Metal CIKernel)") { p, _ in
        k.apply(extent: bounds, roiCallback: { _, _ in bounds }, arguments: [A(), B(), Float(ease(p)), CIVector(x: -1, y: 1), Float(0.5), CIVector(x: 1920, y: 1080)])!
    }
}
if let k = kernels["fc_crossZoom"] {
    bench("gl CrossZoom 82 taps (runtime Metal CIKernel)") { p, _ in
        k.apply(extent: bounds, roiCallback: { _, _ in bounds }, arguments: [A().clampedToExtent(), B().clampedToExtent(), Float(p), Float(0.4), CIVector(x: 1920, y: 1080)])!
    }
}
if let k = kernels["fc_grain"] as? CIColorKernel {
    bench("grain (runtime Metal CIColorKernel)") { _, i in
        k.apply(extent: bounds, arguments: [A(), Float(i % 97), Float(0.06)])!
    }
}

// The full "produced look" stack on top of a live layout: push-in + LUT + grain + vignette.
if let g = kernels["fc_grain"] as? CIColorKernel {
    bench("STACK: Move layout + push-in + LUT33 + grain + vignette") { p, i in
        let e = ease(p)
        let s = 1 + 0.04 * p
        let big = A().transformed(by: CGAffineTransform(translationX: -960, y: -540).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: 960, y: 540)))
        let r = CGRect(x: 1100 - 300 * e, y: 120, width: 720, height: 405)
        let pip = B().transformed(by: CGAffineTransform(scaleX: r.width / 1920, y: r.height / 1080).concatenating(.init(translationX: r.minX, y: r.minY)))
        let gen = CIFilter.roundedRectangleGenerator(); gen.extent = r; gen.radius = 28; gen.color = .white
        let masked = pip.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: gen.outputImage!]).cropped(to: r)
        var img = masked.composited(over: big).cropped(to: bounds)
        let f = CIFilter.colorCubeWithColorSpace(); f.inputImage = img; f.cubeDimension = 33; f.cubeData = cube33; f.colorSpace = sRGB
        img = f.outputImage!
        img = g.apply(extent: bounds, arguments: [img, Float(i % 97), Float(0.04)])!
        let v = CIFilter.vignetteEffect(); v.inputImage = img; v.center = CGPoint(x: 960, y: 540); v.radius = 1100; v.intensity = 0.3; v.falloff = 0.6
        return v.outputImage!
    }
}

// ---------- Kinetic captions: text rasterised every frame vs cached per line ----------
func captionString(_ words: [String], hot: Int, size: CGFloat) -> NSAttributedString {
    let s = NSMutableAttributedString()
    for (i, w) in words.enumerated() {
        let color: NSColor = i == hot ? NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1) : .white
        s.append(NSAttributedString(string: w + (i < words.count - 1 ? " " : ""), attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: color,
            .strokeColor: NSColor.black, .strokeWidth: -3.0]))
    }
    return s
}
let words = ["this", "is", "how", "the", "edit", "feels"]
bench("caption: re-rasterise text every frame") { p, _ in
    let hot = min(words.count - 1, Int(p * Double(words.count)))
    let t = CIFilter.attributedTextImageGenerator(); t.text = captionString(words, hot: hot, size: 64); t.scaleFactor = 1
    let img = t.outputImage!
    return img.transformed(by: .init(translationX: 960 - img.extent.width / 2, y: 140)).composited(over: A())
}
var captionCache: [Int: CIImage] = [:]
for h in 0..<words.count {
    let t = CIFilter.attributedTextImageGenerator(); t.text = captionString(words, hot: h, size: 64); t.scaleFactor = 1
    let img = t.outputImage!
    let pb = makePB(Int(img.extent.width.rounded(.up)), Int(img.extent.height.rounded(.up)))
    _ = renderOnce(img, to: pb)
    captionCache[h] = CIImage(cvPixelBuffer: pb)
}
bench("caption: cached line images + pop scale") { p, _ in
    let hot = min(words.count - 1, Int(p * Double(words.count)))
    let img = captionCache[hot]!
    let local = (p * Double(words.count)).truncatingRemainder(dividingBy: 1)
    let s = CGFloat(1 + 0.06 * sin(.pi * min(1, local * 3)))
    return img.transformed(by: CGAffineTransform(translationX: -img.extent.width / 2, y: 0).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: 960, y: 140))).composited(over: A())
}

// ---------- Both canvases in one tick: 16:9 + 9:16 with the CrossZoom transition + produced-look stack ----------
let outV = makePB(1080, 1920)
if let cz = kernels["fc_crossZoom"], let g = kernels["fc_grain"] as? CIColorKernel {
    var walls: [Double] = [], gpus: [Double] = []
    for i in 0..<130 {
        let p = Double(i % 60) / 59
        let t0 = DispatchTime.now().uptimeNanoseconds
        var gsum = 0.0
        for (size, pb) in [(CGSize(width: 1920, height: 1080), outPB), (CGSize(width: 1080, height: 1920), outV)] {
            let bb = CGRect(origin: .zero, size: size)
            let a = A().transformed(by: .init(scaleX: size.width / 1920, y: size.height / 1080))
            let b = B().transformed(by: .init(scaleX: size.width / 1920, y: size.height / 1080))
            var img = cz.apply(extent: bb, roiCallback: { _, _ in bb }, arguments: [a.clampedToExtent(), b.clampedToExtent(), Float(p), Float(0.4), CIVector(x: size.width, y: size.height)])!
            let f = CIFilter.colorCubeWithColorSpace(); f.inputImage = img; f.cubeDimension = 33; f.cubeData = cube33; f.colorSpace = sRGB
            img = g.apply(extent: bb, arguments: [f.outputImage!, Float(i % 97), Float(0.04)])!
            let dest = CIRenderDestination(pixelBuffer: pb); dest.colorSpace = sRGB
            let info = try! ctx.startTask(toRender: img.cropped(to: bb), to: dest).waitUntilCompleted()
            gsum += info.kernelExecutionTime * 1000
        }
        if i >= 10 { walls.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6); gpus.append(gsum) }
    }
    print(String(format: "BOTH CANVASES (CrossZoom + LUT + grain): wall %.2f / p95 %.2f ms, gpu %.2f / p95 %.2f ms per tick (budget 16.7 ms at 60 fps)",
                 pct(walls, 0.5), pct(walls, 0.95), pct(gpus, 0.5), pct(gpus, 0.95)))
}

// ---------- Per-tick cost with BOTH canvases, sources fitted the way a layout would (fill + centre crop) ----------
func fill(_ img: CIImage, _ size: CGSize) -> CIImage {
    let sc = max(size.width / 1920, size.height / 1080)
    return img.transformed(by: CGAffineTransform(scaleX: sc, y: sc).concatenating(.init(translationX: (size.width - 1920 * sc) / 2, y: (size.height - 1080 * sc) / 2))).cropped(to: CGRect(origin: .zero, size: size))
}
func tick(_ name: String, _ make: (CGSize, Double, Int) -> CIImage) {
    var walls: [Double] = []
    for i in 0..<130 {
        let p = Double(i % 42) / 41   // a 0.7 s transition at 60 fps
        let t0 = DispatchTime.now().uptimeNanoseconds
        for (size, pb) in [(CGSize(width: 1920, height: 1080), outPB), (CGSize(width: 1080, height: 1920), outV)] {
            let bb = CGRect(origin: .zero, size: size)
            let img = make(size, p, i).composited(over: CIImage(color: .black)).cropped(to: bb)
            let dest = CIRenderDestination(pixelBuffer: pb); dest.colorSpace = sRGB
            _ = try! ctx.startTask(toRender: img, to: dest).waitUntilCompleted()
        }
        if i >= 10 { walls.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
    }
    print(String(format: "TICK both canvases %-44@ wall %5.2f / p95 %5.2f ms  (60 fps budget 16.7 ms)", name as NSString, pct(walls, 0.5), pct(walls, 0.95)))
}
tick("plain: one camera, fill") { sz, _, _ in fill(A(), sz) }
if let g = kernels["fc_grain"] as? CIColorKernel {
    tick("look: push-in + LUT33 + grain + vignette") { sz, p, i in
        let bb = CGRect(origin: .zero, size: sz)
        let s = 1 + 0.04 * p
        var img = fill(A(), sz).transformed(by: CGAffineTransform(translationX: -sz.width / 2, y: -sz.height / 2).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: sz.width / 2, y: sz.height / 2))).cropped(to: bb)
        let f = CIFilter.colorCubeWithColorSpace(); f.inputImage = img; f.cubeDimension = 33; f.cubeData = cube33; f.colorSpace = sRGB
        img = g.apply(extent: bb, arguments: [f.outputImage!, Float(i % 97), Float(0.04)])!
        let v = CIFilter.vignetteEffect(); v.inputImage = img; v.center = CGPoint(x: sz.width / 2, y: sz.height / 2); v.radius = Float(max(sz.width, sz.height) * 0.6); v.intensity = 0.3; v.falloff = 0.6
        return v.outputImage!
    }
}
tick("whip pan r=60") { sz, p, _ in
    let bb = CGRect(origin: .zero, size: sz); let e = ease(p)
    let both = fill(B(), sz).transformed(by: .init(translationX: CGFloat(1 - e) * sz.width, y: 0)).composited(over: fill(A(), sz).transformed(by: .init(translationX: CGFloat(-e) * sz.width, y: 0))).cropped(to: bb)
    let r = 60 * sin(.pi * p); if r < 0.5 { return both }
    let m = CIFilter.motionBlur(); m.inputImage = both.clampedToExtent(); m.radius = Float(r); m.angle = 0
    return m.outputImage!.cropped(to: bb)
}
tick("zoom-through CIZoomBlur 25") { sz, p, _ in
    let bb = CGRect(origin: .zero, size: sz); let e = ease(p)
    let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
    let s = p < 0.5 ? 1 + 1.5 * e : 1.25 - 0.25 * e
    let src = p < 0.5 ? fill(A(), sz) : fill(B(), sz)
    let img = src.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: c.x, y: c.y)))
    let z = CIFilter.zoomBlur(); z.inputImage = img.clampedToExtent(); z.center = c; z.amount = Float(25 * sin(.pi * p))
    return z.outputImage!.cropped(to: bb)
}
if let cz = kernels["fc_crossZoom"] {
    tick("gl CrossZoom (82 taps)") { sz, p, _ in
        let bb = CGRect(origin: .zero, size: sz)
        return cz.apply(extent: bb, roiCallback: { _, _ in bb }, arguments: [fill(A(), sz), fill(B(), sz), Float(p), Float(0.4), CIVector(x: sz.width, y: sz.height)])!
    }
}
if let dw = kernels["fc_directionalWarp"] {
    tick("gl directionalwarp") { sz, p, _ in
        let bb = CGRect(origin: .zero, size: sz)
        return dw.apply(extent: bb, roiCallback: { _, _ in bb }, arguments: [fill(A(), sz), fill(B(), sz), Float(ease(p)), CIVector(x: -1, y: 1), Float(0.5), CIVector(x: sz.width, y: sz.height)])!
    }
}
tick("CIPageCurlWithShadow") { sz, p, _ in
    let bb = CGRect(origin: .zero, size: sz)
    let f = CIFilter(name: "CIPageCurlWithShadowTransition")!; f.setDefaults()
    f.setValue(fill(A(), sz), forKey: kCIInputImageKey); f.setValue(fill(B(), sz), forKey: kCIInputTargetImageKey); f.setValue(fill(A(), sz), forKey: "inputBacksideImage")
    f.setValue(CIVector(cgRect: bb), forKey: kCIInputExtentKey); f.setValue(ease(p), forKey: kCIInputTimeKey)
    return f.outputImage!.cropped(to: bb)
}

// ---------- Stinger: encode a 1 s 60 fps alpha clip, then measure decode cost ----------
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
func stingerFrame(_ i: Int, _ n: Int) -> CIImage {
    let p = Double(i) / Double(n - 1)
    let x = CGFloat(-2400 + 4800 * ease(p))
    let bar = CIImage(color: CIColor(red: 0.30, green: 0.82, blue: 0.77)).cropped(to: CGRect(x: x, y: 0, width: 1600, height: 1080))
    let bar2 = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.1)).cropped(to: CGRect(x: x + 300, y: 0, width: 1000, height: 1080))
    return bar2.composited(over: bar).composited(over: CIImage(color: .clear).cropped(to: bounds)).cropped(to: bounds)
}
func writeStinger(codec: AVVideoCodecType, name: String) -> URL? {
    let url = outDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: W, AVVideoHeightKey: H])
    input.expectsMediaDataInRealTime = false
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
    guard w.canAdd(input) else { print("cannot add input for \(name)"); return nil }
    w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
    let n = 60
    for i in 0..<n {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pbo: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pbo)
        let pb = pbo!
        let dest = CIRenderDestination(pixelBuffer: pb); dest.colorSpace = sRGB; dest.alphaMode = .premultiplied
        _ = try! ctx.startTask(toRender: stingerFrame(i, n), from: bounds, to: dest, at: .zero).waitUntilCompleted()
        ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 60))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    w.finishWriting { sem.signal() }
    sem.wait()
    if w.status != .completed { print("writer failed \(name): \(String(describing: w.error))"); return nil }
    return url
}
func decodeCost(_ url: URL) {
    let asset = AVURLAsset(url: url)
    let sem = DispatchSemaphore(value: 0)
    var track: AVAssetTrack?
    Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
    sem.wait()
    guard let track, let reader = try? AVAssetReader(asset: asset) else { print("no reader"); return }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var n = 0; var alphaSeen = false
    let t0 = DispatchTime.now().uptimeNanoseconds
    while let sb = out.copyNextSampleBuffer() {
        if let pb = CMSampleBufferGetImageBuffer(sb), n == 30 {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            for y in stride_by(0, 1080, 135) { for x in stride_by(0, 1920, 64) { if base[y * stride + x * 4 + 3] < 250 { alphaSeen = true } } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        n += 1
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print(String(format: "stinger %@: %d frames decoded in %.1f ms (%.2f ms/frame), file %.1f MB, alpha preserved: %@",
                 url.lastPathComponent, n, ms, ms / Double(max(n, 1)), Double(size) / 1e6, alphaSeen ? "yes" : "NO"))
}
func stride_by(_ a: Int, _ b: Int, _ s: Int) -> StrideTo<Int> { stride(from: a, to: b, by: s) }
if let u = writeStinger(codec: .hevcWithAlpha, name: "stinger-hevc-alpha.mov") { decodeCost(u) }
if let u = writeStinger(codec: .proRes4444, name: "stinger-prores4444.mov") { decodeCost(u) }
let webm = AVURLAsset.audiovisualTypes().map { $0.rawValue }.filter { $0.lowercased().contains("webm") || $0.lowercased().contains("matroska") }
print("AVURLAsset audiovisual types mentioning webm/matroska: \(webm.isEmpty ? "none" : webm.joined(separator: ", "))")

// ---------- Summary ----------
print("\nSUMMARY (1920x1080 BGRA, ms per frame per canvas; x2 for both canvases)")
for r in rows {
    print(String(format: "%-56@ | gpu %6.2f | gpu p95 %6.2f | wall %6.2f | passes %d", r.name as NSString, r.gpuMed, r.gpuP95, r.wallMed, r.passes))
}
