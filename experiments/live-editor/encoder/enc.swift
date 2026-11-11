// What do live effects cost the stream encoder? Encode 4 s of each effect at a fixed live bitrate with
// VideoToolbox H.264 (via AVAssetWriter), decode it, and measure PSNR against the exact source frames.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import AVFoundation

setbuf(stdout, nil)
let W = 1920, H = 1080, FPS = 30, N = 120
let kbps = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "4500")!
let bounds = CGRect(x: 0, y: 0, width: W, height: H)
let device = MTLCreateSystemDefaultDevice()!
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(mtlDevice: device, options: [.outputColorSpace: sRGB, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
// No colour management for the error measurement: compare the stored 8-bit values directly.
let raw = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
func noise(_ seed: Int, _ amp: CGFloat) -> CIImage {
    CIFilter.randomGenerator().outputImage!
        .transformed(by: .init(translationX: CGFloat((seed * 211) % 997), y: CGFloat((seed * 127) % 991))).cropped(to: bounds)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amp, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: amp, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: amp, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - amp / 2, y: 0.5 - amp / 2, z: 0.5 - amp / 2, w: 0)])
}
// A "camera" shot: soft texture + gradient, drifting slightly, plus faint per-frame sensor noise.
func shot(_ seed: CGFloat, _ color: CIColor, _ i: Int) -> CIImage {
    let tex = CIFilter.randomGenerator().outputImage!
        .transformed(by: .init(translationX: seed * 97, y: seed * 37)).cropped(to: bounds.insetBy(dx: -200, dy: -200))
        .applyingGaussianBlur(sigma: 2.5)
        .transformed(by: .init(translationX: CGFloat(i) * 0.6, y: CGFloat(i) * 0.25))
    let g = CIFilter.linearGradient(); g.point0 = .zero; g.point1 = CGPoint(x: W, y: H); g.color0 = color; g.color1 = CIColor(red: 0.08, green: 0.08, blue: 0.1)
    let base = tex.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: g.outputImage!.cropped(to: bounds)]).cropped(to: bounds)
    return noise(i + Int(seed) * 1000, 0.025).applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: base]).cropped(to: bounds)
}
func A(_ i: Int) -> CIImage { shot(1, CIColor(red: 0.9, green: 0.5, blue: 0.3), i) }
func B(_ i: Int) -> CIImage { shot(7, CIColor(red: 0.2, green: 0.5, blue: 0.9), i) }
func grain(_ img: CIImage, _ i: Int, _ amt: CGFloat) -> CIImage {
    noise(i + 50000, amt).applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: bounds)
}
func scaled(_ img: CIImage, _ s: Double) -> CIImage {
    img.clampedToExtent().transformed(by: CGAffineTransform(translationX: -960, y: -540).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: 960, y: 540))).cropped(to: bounds)
}
// Every effect repeats a transition every 2 s (frames 30..(30+len)) so each clip holds two transitions.
func phase(_ i: Int, len: Int) -> Double? { let k = i % 60; return k >= 20 && k < 20 + len ? Double(k - 20) / Double(len - 1) : nil }
func pick(_ i: Int) -> (CIImage, CIImage) { (i / 60) % 2 == 0 ? (A(i), B(i)) : (B(i), A(i)) }
func held(_ i: Int) -> CIImage { let k = i % 60; let (a, b) = pick(i); return k < 20 ? a : b }

let effects: [(String, (Int) -> CIImage)] = [
    ("static shot (camera + sensor noise)", { i in A(i) }),
    ("static shot + grain 0.03", { i in grain(A(i), i, 0.03) }),
    ("static shot + grain 0.06", { i in grain(A(i), i, 0.06) }),
    ("slow push-in 1.00->1.06 over 4 s", { i in scaled(A(i), 1 + 0.06 * Double(i) / Double(N - 1)) }),
    ("punch-in 1.00->1.15 in 0.25 s, hold", { i in let k = i % 60; let p = min(1, Double(max(0, k - 20)) / 7); return scaled(A(i), 1 + 0.15 * ease(p)) }),
    ("hard cuts every 2 s", { i in held(i) }),
    ("dissolve 0.5 s", { i in
        guard let p = phase(i, len: 15) else { return held(i) }
        let (a, b) = pick(i); let f = CIFilter.dissolveTransition(); f.inputImage = a; f.targetImage = b; f.time = Float(ease(p)); return f.outputImage!.cropped(to: bounds) }),
    ("Move: PiP grows to full 0.7 s", { i in
        guard let p = phase(i, len: 21) else { return held(i) }
        let (a, b) = pick(i); let e = ease(p)
        let r = CGRect(x: 1180 * (1 - e), y: 80 * (1 - e), width: 640 + 1280 * e, height: 360 + 720 * e)
        let pip = b.transformed(by: CGAffineTransform(scaleX: r.width / 1920, y: r.height / 1080).concatenating(.init(translationX: r.minX, y: r.minY)))
        return pip.composited(over: a).cropped(to: bounds) }),
    ("fast slide 0.33 s, no blur", { i in
        guard let p = phase(i, len: 10) else { return held(i) }
        let (a, b) = pick(i); let e = ease(p)
        return b.transformed(by: .init(translationX: CGFloat(1 - e) * 1920, y: 0)).composited(over: a.transformed(by: .init(translationX: -CGFloat(e) * 1920, y: 0))).cropped(to: bounds) }),
    ("whip pan 0.33 s, motion blur r=60", { i in
        guard let p = phase(i, len: 10) else { return held(i) }
        let (a, b) = pick(i); let e = ease(p)
        let both = b.transformed(by: .init(translationX: CGFloat(1 - e) * 1920, y: 0)).composited(over: a.transformed(by: .init(translationX: -CGFloat(e) * 1920, y: 0))).cropped(to: bounds)
        let m = CIFilter.motionBlur(); m.inputImage = both.clampedToExtent(); m.radius = Float(60 * sin(.pi * p)); m.angle = 0
        return m.outputImage!.cropped(to: bounds) }),
    ("zoom-through 0.5 s, zoom blur", { i in
        guard let p = phase(i, len: 15) else { return held(i) }
        let (a, b) = pick(i); let e = ease(p)
        let img = p < 0.5 ? scaled(a, 1 + 1.5 * e) : scaled(b, 1.25 - 0.25 * e)
        let z = CIFilter.zoomBlur(); z.inputImage = img.clampedToExtent(); z.center = CGPoint(x: 960, y: 540); z.amount = Float(25 * sin(.pi * p))
        return z.outputImage!.cropped(to: bounds) }),
]

func encode(_ name: String, _ make: (Int) -> CIImage) -> (psnrMean: Double, psnrMin: Double, psnrTransMin: Double, mb: Double) {
    let url = outDir.appendingPathComponent("enc-\(abs(name.hashValue)).mov")
    try? FileManager.default.removeItem(at: url)
    let w = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: kbps * 1000, AVVideoMaxKeyFrameIntervalKey: FPS * 2,
                                          AVVideoExpectedSourceFrameRateKey: FPS, AVVideoAllowFrameReorderingKey: false,
                                          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
    input.expectsMediaDataInRealTime = true
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
    w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
    for i in 0..<N {
        while !input.isReadyForMoreMediaData { usleep(500) }
        var pbo: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pbo)
        let dest = CIRenderDestination(pixelBuffer: pbo!); dest.colorSpace = sRGB
        _ = try! ctx.startTask(toRender: make(i).composited(over: CIImage(color: .black)).cropped(to: bounds), to: dest).waitUntilCompleted()
        ad.append(pbo!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0); w.finishWriting { sem.signal() }; sem.wait()

    // Decode and compare with a fresh render of the same source frame.
    let asset = AVURLAsset(url: url)
    var track: AVAssetTrack?
    let s2 = DispatchSemaphore(value: 0)
    Task { track = try? await asset.loadTracks(withMediaType: .video).first; s2.signal() }; s2.wait()
    let reader = try! AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    let refPB: CVPixelBuffer = { var p: CVPixelBuffer?; CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &p); return p! }()
    var psnrs: [Double] = [], trans: [Double] = []
    var i = 0
    while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        let dest = CIRenderDestination(pixelBuffer: refPB); dest.colorSpace = sRGB
        _ = try! ctx.startTask(toRender: make(i).composited(over: CIImage(color: .black)).cropped(to: bounds), to: dest).waitUntilCompleted()
        let d = CIImage(cvPixelBuffer: pb).applyingFilter("CIColorAbsoluteDifference", parameters: ["inputImage2": CIImage(cvPixelBuffer: refPB)])
        let sq = d.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: d])
        let avg = sq.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: bounds)])
        var px = [Float](repeating: 0, count: 4)
        raw.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let mse = Double(px[0] + px[1] + px[2]) / 3
        let psnr = mse > 0 ? 10 * log10(1 / mse) : 99
        psnrs.append(psnr)
        let k = i % 60; if k >= 20 && k < 41 { trans.append(psnr) }
        i += 1
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    try? FileManager.default.removeItem(at: url)
    return (psnrs.reduce(0, +) / Double(max(1, psnrs.count)), psnrs.min() ?? 0, trans.min() ?? 0, Double(size) * 8 / 1e6 / (Double(N) / Double(FPS)))
}

print("H.264 VideoToolbox, \(W)x\(H)@\(FPS), target \(kbps) kbps, no B-frames, keyframe every 2 s. PSNR vs exact source (higher is better; <30 dB looks soft/blocky).")
for (name, make) in effects {
    let r = encode(name, make)
    print(String(format: "%-40@ PSNR mean %5.1f dB | worst frame %5.1f dB | worst in transition window %5.1f dB | actual %.2f Mbps",
                 name as NSString, r.psnrMean, r.psnrMin, r.psnrTransMin, r.mb))
}
