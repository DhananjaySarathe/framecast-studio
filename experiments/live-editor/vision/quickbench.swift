// Throwaway Vision latency bench. Reads frames from a local movie, runs requests, prints timings.
// Nothing is uploaded; no model downloads (iterative segmentation only reports asset status).
import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML

setvbuf(stdout, nil, _IONBF, 0)

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func ms(_ s: Double) -> String { String(format: "%6.1f", s * 1000) }

func loadFrames(_ path: String, start: Double, count: Int) throws -> [CVPixelBuffer] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let sem = DispatchSemaphore(value: 0)
    var track: AVAssetTrack?
    Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
    sem.wait()
    guard let t = track else { throw NSError(domain: "bench", code: 1) }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: Double(count) / 20.0 + 2, preferredTimescale: 600))
    let out = AVAssetReaderTrackOutput(track: t, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
    out.alwaysCopiesSampleData = true
    reader.add(out)
    reader.startReading()
    var frames: [CVPixelBuffer] = []
    while frames.count < count, let sb = out.copyNextSampleBuffer() {
        if let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
    }
    reader.cancelReading()
    return frames
}

let ci = CIContext(options: [.cacheIntermediates: false])
func scaled(_ pb: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer {
    var out: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &out)
    let img = CIImage(cvPixelBuffer: pb)
    let sx = CGFloat(width) / img.extent.width, sy = CGFloat(height) / img.extent.height
    ci.render(img.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: out!)
    return out!
}

func devices(_ r: VNRequest) -> String {
    guard let d = try? r.supportedComputeStageDevices else { return "?" }
    var parts: [String] = []
    for (stage, list) in d {
        let names = list.map { dev -> String in
            switch dev {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .neuralEngine: return "ANE"
            @unknown default: return "other"
            }
        }
        parts.append("\(stage.rawValue.replacingOccurrences(of: "VNComputeStage", with: "")):\(names.joined(separator: "/"))")
    }
    return parts.sorted().joined(separator: " ")
}

struct Row { let name: String; let cold: Double; let med: Double; let p90: Double; let cpu: Double; let note: String; let dev: String }
var rows: [Row] = []
func report(_ r: Row) {
    rows.append(r)
    print("\(r.name.padding(toLength: 46, withPad: " ", startingAt: 0)) cold \(ms(r.cold))  med \(ms(r.med))  p90 \(ms(r.p90))  cpu/frame \(ms(r.cpu))  | \(r.note) | \(r.dev)")
}
func stats(_ t: [Double]) -> (Double, Double) {
    let s = t.sorted(); return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))])
}

// Single-image requests via VNImageRequestHandler, one handler per frame (how a live loop would do it).
func benchImage(_ name: String, _ frames: [CVPixelBuffer], _ reqs: [VNRequest], note: () -> String = { "" }) {
    let h0 = VNImageRequestHandler(cvPixelBuffer: frames[0], options: [:])
    let c0 = now(); try? h0.perform(reqs); let cold = now() - c0
    var times: [Double] = []
    let cpu0 = cpuSeconds()
    for pb in frames.dropFirst() {
        let h = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        let t0 = now(); do { try h.perform(reqs) } catch { print("  error \(name): \(error)") }; times.append(now() - t0)
    }
    let cpu = (cpuSeconds() - cpu0) / Double(times.count)
    let (m, p) = stats(times)
    report(Row(name: name, cold: cold, med: m, p90: p, cpu: cpu, note: note(), dev: reqs.map(devices).joined(separator: " + ")))
}

let moviePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let startAt = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 60 : 60
let screenshotPath = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
let n = 41
let full = try loadFrames(moviePath, start: startAt, count: n)
print("loaded \(full.count) frames \(CVPixelBufferGetWidth(full[0]))x\(CVPixelBufferGetHeight(full[0])) from t=\(startAt)s")
let half = full.map { scaled($0, width: 960, height: 540) }
let hd = full.map { scaled($0, width: 1280, height: 720) }
print("OS \(ProcessInfo.processInfo.operatingSystemVersionString), cores \(ProcessInfo.processInfo.activeProcessorCount)")
print("--- single-image requests on 1920x1080 BGRA unless noted (cold = first call incl. model load; med/p90 over \(full.count - 1) frames; cpu/frame = process CPU time per frame)")

let face = VNDetectFaceRectanglesRequest()
benchImage("VNDetectFaceRectangles rev\(face.revision)", full, [face]) { "faces=\(face.results?.count ?? 0)" }
let faceHD = VNDetectFaceRectanglesRequest()
benchImage("VNDetectFaceRectangles @1280x720", hd, [faceHD]) { "faces=\(faceHD.results?.count ?? 0)" }
let lm = VNDetectFaceLandmarksRequest()
benchImage("VNDetectFaceLandmarks rev\(lm.revision) (detect+landmarks)", full, [lm]) { "faces=\(lm.results?.count ?? 0)" }
let fq = VNDetectFaceCaptureQualityRequest()
benchImage("VNDetectFaceCaptureQuality", full, [fq]) { "q=\(fq.results?.first?.faceCaptureQuality.map { String(format: "%.2f", $0) } ?? "-")" }
let hum = VNDetectHumanRectanglesRequest(); hum.upperBodyOnly = true
benchImage("VNDetectHumanRectangles rev\(hum.revision) upperBody", full, [hum]) { "humans=\(hum.results?.count ?? 0)" }
let humF = VNDetectHumanRectanglesRequest(); humF.upperBodyOnly = false
benchImage("VNDetectHumanRectangles fullBody", full, [humF]) { "humans=\(humF.results?.count ?? 0)" }
let body = VNDetectHumanBodyPoseRequest()
benchImage("VNDetectHumanBodyPose (2D, 19 joints)", full, [body]) { "bodies=\(body.results?.count ?? 0)" }
let hand = VNDetectHumanHandPoseRequest(); hand.maximumHandCount = 2
benchImage("VNDetectHumanHandPose max2", full, [hand]) { "hands=\(hand.results?.count ?? 0)" }
let hand1 = VNDetectHumanHandPoseRequest(); hand1.maximumHandCount = 1
benchImage("VNDetectHumanHandPose max1 @960x540", half, [hand1]) { "hands=\(hand1.results?.count ?? 0)" }
let att = VNGenerateAttentionBasedSaliencyImageRequest()
benchImage("VNGenerateAttentionBasedSaliency", full, [att]) { "boxes=\((att.results?.first?.salientObjects?.count) ?? 0)" }
let obj = VNGenerateObjectnessBasedSaliencyImageRequest()
benchImage("VNGenerateObjectnessBasedSaliency", full, [obj]) { "boxes=\((obj.results?.first?.salientObjects?.count) ?? 0)" }
let inst = VNGeneratePersonInstanceMaskRequest()
benchImage("VNGeneratePersonInstanceMask", full, [inst]) { "people=\(inst.results?.first?.allInstances.count ?? 0)" }
let fg = VNGenerateForegroundInstanceMaskRequest()
benchImage("VNGenerateForegroundInstanceMask", full, [fg]) { "objects=\(fg.results?.first?.allInstances.count ?? 0)" }
for q in [VNGeneratePersonSegmentationRequest.QualityLevel.fast, .balanced, .accurate] {
    let seg = VNGeneratePersonSegmentationRequest(); seg.qualityLevel = q; seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
    let label = q == .fast ? "fast" : q == .balanced ? "balanced" : "accurate"
    benchImage("VNGeneratePersonSegmentation \(label) (image handler)", full, [seg]) {
        guard let m = seg.results?.first?.pixelBuffer else { return "-" }
        return "mask \(CVPixelBufferGetWidth(m))x\(CVPixelBufferGetHeight(m))"
    }
}
let bp3 = VNDetectHumanBodyPose3DRequest()
benchImage("VNDetectHumanBodyPose3D", full, [bp3]) { "bodies=\(bp3.results?.count ?? 0)" }
let combo = [VNDetectFaceRectanglesRequest(), { let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = true; return r }(), { let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2; return r }()] as [VNRequest]
benchImage("COMBO face+humanRect+hand in one perform", full, combo)
let combo2 = [VNDetectFaceRectanglesRequest(), { let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = true; return r }()] as [VNRequest]
benchImage("COMBO face+humanRect @1280x720", hd, combo2)

// CIFilter person segmentation (Core Image wrapper over the same model)
do {
    let f = CIFilter.personSegmentation(); f.qualityLevel = 1
    var times: [Double] = []; var cold = 0.0
    let cpu0 = cpuSeconds()
    for (i, pb) in full.enumerated() {
        f.inputImage = CIImage(cvPixelBuffer: pb)
        let t0 = now()
        if let o = f.outputImage { _ = ci.createCGImage(o, from: o.extent) }
        let dt = now() - t0
        if i == 0 { cold = dt } else { times.append(dt) }
    }
    let (m, p) = stats(times)
    report(Row(name: "CIFilter.personSegmentation q=1 (balanced)+render", cold: cold, med: m, p90: p, cpu: (cpuSeconds() - cpu0) / Double(full.count), note: "", dev: "CI"))
}

print("--- stateful / sequence requests (VNSequenceRequestHandler)")
for q in [VNGeneratePersonSegmentationRequest.QualityLevel.fast, .balanced] {
    let seq = VNSequenceRequestHandler()
    let seg = VNGeneratePersonSegmentationRequest(); seg.qualityLevel = q
    var times: [Double] = []; var cold = 0.0
    let cpu0 = cpuSeconds()
    for (i, pb) in full.enumerated() {
        let t0 = now(); try? seq.perform([seg], on: pb); let dt = now() - t0
        if i == 0 { cold = dt } else { times.append(dt) }
    }
    let (m, p) = stats(times)
    report(Row(name: "PersonSegmentation \(q == .fast ? "fast" : "balanced") via sequence handler", cold: cold, med: m, p90: p, cpu: (cpuSeconds() - cpu0) / Double(full.count), note: "temporally smoothed", dev: devices(seg)))
}

// Object tracker seeded from the first face (or human, or centre box)
func seedObservation() -> VNDetectedObjectObservation {
    let f = VNDetectFaceRectanglesRequest(); let h = VNDetectHumanRectanglesRequest(); h.upperBodyOnly = true
    try? VNImageRequestHandler(cvPixelBuffer: full[0], options: [:]).perform([f, h])
    if let o = f.results?.first { return VNDetectedObjectObservation(boundingBox: o.boundingBox.insetBy(dx: -o.boundingBox.width * 0.2, dy: -o.boundingBox.height * 0.2)) }
    if let o = h.results?.first { return VNDetectedObjectObservation(boundingBox: o.boundingBox) }
    return VNDetectedObjectObservation(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
}
for (label, frames) in [("1920x1080", full), ("960x540", half)] {
    for rev in [VNTrackObjectRequestRevision1, VNTrackObjectRequestRevision2] {
        for level in [VNRequestTrackingLevel.fast, .accurate] {
            if rev == VNTrackObjectRequestRevision2 && level == .fast { continue } // level has no effect on rev2
            let seq = VNSequenceRequestHandler()
            var obs = seedObservation()
            var times: [Double] = []; var cold = 0.0; var minConf: Float = 1
            let cpu0 = cpuSeconds()
            var maxTrackers = 0
            for (i, pb) in frames.enumerated() {
                let r = VNTrackObjectRequest(detectedObjectObservation: obs); r.revision = rev; r.trackingLevel = level
                if i == 0 { maxTrackers = (r.supportedNumber(ofTrackersAndReturnError: nil))  }
                let t0 = now(); try? seq.perform([r], on: pb); let dt = now() - t0
                if let o = r.results?.first as? VNDetectedObjectObservation { obs = o; minConf = min(minConf, o.confidence) }
                if i == 0 { cold = dt } else { times.append(dt) }
            }
            let (m, p) = stats(times)
            report(Row(name: "VNTrackObject rev\(rev) \(level == .fast ? "fast" : "accurate") @\(label)", cold: cold, med: m, p90: p, cpu: (cpuSeconds() - cpu0) / Double(frames.count), note: "minConf=\(String(format: "%.2f", minConf)) maxTrackers=\(maxTrackers)", dev: ""))
        }
    }
}

// Optical flow between consecutive frames
for (label, frames) in [("1920x1080", full), ("960x540", half)] {
    for acc in [VNGenerateOpticalFlowRequest.ComputationAccuracy.low, .medium, .high, .veryHigh] {
        var times: [Double] = []; var cold = 0.0
        let cpu0 = cpuSeconds(); var outSize = ""
        var devs = ""
        for i in 1..<min(frames.count, 16) {
            let r = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: frames[i - 1], options: [:]); r.computationAccuracy = acc
            r.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
            let t0 = now(); try? VNImageRequestHandler(cvPixelBuffer: frames[i], options: [:]).perform([r]); let dt = now() - t0
            if let o = r.results?.first { outSize = "\(CVPixelBufferGetWidth(o.pixelBuffer))x\(CVPixelBufferGetHeight(o.pixelBuffer))" }
            if i == 1 { cold = dt; devs = devices(r) } else { times.append(dt) }
        }
        let (m, p) = stats(times)
        let name = ["low", "medium", "high", "veryHigh"][Int(acc.rawValue)]
        report(Row(name: "VNGenerateOpticalFlow \(name) @\(label)", cold: cold, med: m, p90: p, cpu: (cpuSeconds() - cpu0) / 15, note: "flow \(outSize)", dev: devs))
    }
}
do {
    let seq = VNSequenceRequestHandler()
    let r = VNTrackTranslationalImageRegistrationRequest()
    var times: [Double] = []; var cold = 0.0
    let cpu0 = cpuSeconds()
    for (i, pb) in half.enumerated() {
        let t0 = now(); try? seq.perform([r], on: pb); let dt = now() - t0
        if i == 0 { cold = dt } else { times.append(dt) }
    }
    let (m, p) = stats(times)
    report(Row(name: "VNTrackTranslationalImageRegistration @960x540", cold: cold, med: m, p90: p, cpu: (cpuSeconds() - cpu0) / Double(half.count), note: "global shift", dev: devices(r)))
}

print("--- text recognition")
var textInputs: [(String, CVPixelBuffer?, CGImage?)] = [("video frame 1920x1080", full[0], nil)]
if !screenshotPath.isEmpty, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: screenshotPath) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
    textInputs.append(("screenshot \(img.width)x\(img.height)", nil, img))
}
for (label, pb, img) in textInputs {
    for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
        var times: [Double] = []; var cold = 0.0; var lines = 0
        let cpu0 = cpuSeconds()
        let r = VNRecognizeTextRequest(); r.recognitionLevel = level; r.usesLanguageCorrection = level == .accurate
        for i in 0..<8 {
            let h = pb != nil ? VNImageRequestHandler(cvPixelBuffer: pb!, options: [:]) : VNImageRequestHandler(cgImage: img!, options: [:])
            let t0 = now(); try? h.perform([r]); let dt = now() - t0
            lines = r.results?.count ?? 0
            if i == 0 { cold = dt } else { times.append(dt) }
        }
        let (m, p) = stats(times)
        report(Row(name: "VNRecognizeText \(level == .fast ? "fast" : "accurate") on \(label)", cold: cold, med: m, p90: p, cpu: (cpuSeconds() - cpu0) / 8, note: "lines=\(lines)", dev: devices(r)))
    }
    let tr = VNDetectTextRectanglesRequest()
    var times: [Double] = []; var cold = 0.0
    for i in 0..<8 {
        let h = pb != nil ? VNImageRequestHandler(cvPixelBuffer: pb!, options: [:]) : VNImageRequestHandler(cgImage: img!, options: [:])
        let t0 = now(); try? h.perform([tr]); let dt = now() - t0
        if i == 0 { cold = dt } else { times.append(dt) }
    }
    let (m, p) = stats(times)
    report(Row(name: "VNDetectTextRectangles on \(label)", cold: cold, med: m, p90: p, cpu: 0, note: "boxes=\(tr.results?.count ?? 0)", dev: devices(tr)))
}

print("--- Swift Vision API (macOS 15+) and macOS 27 revisions")
func benchAsync<R: ImageProcessingRequest>(_ name: String, _ req: R, _ frames: [CVPixelBuffer], note: (R.Result) -> String) async {
    var times: [Double] = []; var cold = 0.0; var last: R.Result?
    let cpu0 = cpuSeconds()
    for (i, pb) in frames.enumerated() {
        let t0 = now()
        do { last = try await req.perform(on: pb, orientation: nil) } catch { print("  error \(name): \(error)"); return }
        let dt = now() - t0
        if i == 0 { cold = dt } else { times.append(dt) }
    }
    let (m, p) = stats(times)
    report(Row(name: name, cold: cold, med: m, p90: p, cpu: (cpuSeconds() - cpu0) / Double(frames.count), note: last.map(note) ?? "", dev: ""))
}
await benchAsync("Swift DetectFaceRectanglesRequest rev3", DetectFaceRectanglesRequest(.revision3), full) { "faces=\($0.count)" }
await benchAsync("Swift DetectHumanRectanglesRequest rev2", { var r = DetectHumanRectanglesRequest(.revision2); r.upperBodyOnly = true; return r }(), full) { "humans=\($0.count)" }
if #available(macOS 27.0, *) {
    await benchAsync("Swift DetectFaceRectanglesRequest rev4 (27)", DetectFaceRectanglesRequest(.revision4), full) { "faces=\($0.count)" }
    await benchAsync("Swift DetectHumanRectanglesRequest rev3 (27)", { var r = DetectHumanRectanglesRequest(.revision3); r.upperBodyOnly = true; return r }(), full) { "humans=\($0.count)" }
    await benchAsync("Swift DetectFaceLandmarksRequest rev4 (27)", DetectFaceLandmarksRequest(.revision4), full) { "faces=\($0.count)" }
    let it = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
    print("GenerateIterativeSegmentationRequest assetStatus (no download attempted): \(await it.assetStatus)  qualityLevels=\(GenerateIterativeSegmentationRequest.QualityLevel.allCases)")
    print("supported compute devices rev4 face: \(DetectFaceRectanglesRequest(.revision4).supportedComputeStageDevices.map { "\($0.key): \($0.value)" })")
}
print("done")
