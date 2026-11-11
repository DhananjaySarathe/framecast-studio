// Framecast live-editor research: per-frame cost of Apple Vision requests on this Mac.
// Build: swiftc -O -swift-version 5 visionbench.swift -o visionbench
// Run:   ./visionbench <cmd> [args]   (cmds: video, ocr, flow, devices, track, concurrent)
// Nothing here touches the network or installs anything; frames are read from local folders.

import Foundation
import Vision
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO
import CoreML
import Metal

setvbuf(stdout, nil, _IOLBF, 0)

// BENCH_DIR: a scratch folder holding frames/ (extracted from your own recording) and the JSON results.
// UI_FOOTAGE: a folder with footage/walk/*.jpg and ui/*.png screenshots of the app, for the OCR runs.
let env = ProcessInfo.processInfo.environment
let BENCH = env["BENCH_DIR"] ?? FileManager.default.currentDirectoryPath
let FRAMES = BENCH + "/frames"
let PROMO = env["UI_FOOTAGE"] ?? BENCH + "/ui-footage"
let WALK = PROMO + "/footage/walk"
let UI = PROMO + "/ui"

// MARK: - timing and stats

@inline(__always) func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
@inline(__always) func msSince(_ t0: UInt64) -> Double { Double(now() &- t0) / 1e6 }
@inline(__always) func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted(); guard !s.isEmpty else { return .nan }
    let idx = p * Double(s.count - 1)
    let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (idx - Double(lo))
}
func mean(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s.padding(toLength: n, withPad: " ", startingAt: 0) }

struct Row: Codable {
    var request: String; var input: String; var n: Int
    var p50: Double; var p95: Double; var mean: Double; var min: Double; var max: Double
    var first: Double; var notes: String
}
var rows: [Row] = []

func record(_ request: String, _ input: String, _ t: [Double], first: Double, notes: String) {
    let r = Row(request: request, input: input, n: t.count, p50: pct(t, 0.5), p95: pct(t, 0.95), mean: mean(t),
                min: t.min() ?? .nan, max: t.max() ?? .nan, first: first, notes: notes)
    rows.append(r)
    print("\(pad(request, 46)) \(pad(input, 22)) n=\(t.count) p50=\(f2(r.p50)) p95=\(f2(r.p95)) mean=\(f2(r.mean)) min=\(f2(r.min)) max=\(f2(r.max)) first=\(f2(first)) | \(notes)")
}

func saveRows(_ name: String) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = URL(fileURLWithPath: BENCH + "/results_\(name)\(ProcessInfo.processInfo.environment["RUNTAG"] ?? "").json")
    // JSON cannot hold NaN; replace with -1
    let clean = rows.map { r -> Row in
        var r = r
        for kp in [\Row.p50, \Row.p95, \Row.mean, \Row.min, \Row.max, \Row.first] where r[keyPath: kp].isNaN { r[keyPath: kp] = -1 }
        return r
    }
    try? enc.encode(clean).write(to: url)
    print("wrote \(url.path)")
}

// MARK: - frames

func makeBGRA(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    return pb!
}

/// Decode an image file into an IOSurface-backed BGRA buffer (the format Framecast's capture sources deliver).
func loadPB(_ path: String, scale: Double = 1.0) -> CVPixelBuffer {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = Int((Double(img.width) * scale).rounded()), h = Int((Double(img.height) * scale).rounded())
    let pb = makeBGRA(w, h)
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

func listImages(_ dir: String) -> [String] {
    let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return items.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted().map { dir + "/" + $0 }
}

func loadSet(_ name: String, _ count: Int = 70) -> [CVPixelBuffer] {
    let files = Array(listImages(FRAMES + "/" + name).prefix(count))
    return files.map { f in autoreleasepool { loadPB(f) } }
}

// MARK: - geometry

func area(_ r: CGRect) -> CGFloat { r.width * r.height }
func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b); if i.isNull { return 0 }
    let u = area(a) + area(b) - area(i); return u > 0 ? Double(area(i) / u) : 0
}
func centerErr(_ a: CGRect, _ b: CGRect) -> Double { // in normalized units (fraction of frame width/height)
    let dx = a.midX - b.midX, dy = a.midY - b.midY; return Double((dx * dx + dy * dy).squareRoot())
}

let faceReq = VNDetectFaceRectanglesRequest()
func largestFace(_ pb: CVPixelBuffer) -> VNFaceObservation? {
    let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
    try? h.perform([faceReq])
    return faceReq.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) })
}
let upperReq: VNDetectHumanRectanglesRequest = { let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = true; return r }()
func largestUpperBody(_ pb: CVPixelBuffer) -> VNHumanObservation? {
    let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
    try? h.perform([upperReq])
    return upperReq.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) })
}

// MARK: - generic single-image request bench

func benchImage(_ name: String, _ input: String, count: Int, frame: (Int) -> CVPixelBuffer, warm: Int = 5, timed: Int = 60,
                make: () -> VNRequest, metric: ((VNRequest) -> Double)? = nil, metricLabel: String = "",
                describe: ((VNRequest) -> String)? = nil, extra: String = "") {
    let req = make()
    var times: [Double] = [], metrics: [Double] = [], first = 0.0
    var err: String? = nil, desc = ""
    for i in 0..<(warm + timed) {
        autoreleasepool {
            let pb = frame(i % count)
            let t0 = now()
            let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            do { try h.perform([req]) } catch { err = "\(error)" }
            let dt = msSince(t0)
            if i == 0 { first = dt }
            if i >= warm {
                times.append(dt)
                if let m = metric { metrics.append(m(req)) }
                if i == warm + timed - 1, let d = describe { desc = d(req) }
            }
        }
    }
    var notes = "rev \(req.revision)"
    if let m = metric, !metrics.isEmpty { _ = m; notes += "; \(metricLabel) avg \(f2(mean(metrics)))" }
    if !desc.isEmpty { notes += "; " + desc }
    if !extra.isEmpty { notes += "; " + extra }
    if let e = err { notes += "; ERROR \(e)" }
    record(name, input, times, first: first, notes: notes)
}

func countResults(_ r: VNRequest) -> Double { Double(r.results?.count ?? 0) }

// MARK: - tracking bench (VNSequenceRequestHandler)

func benchTrack(_ name: String, _ input: String, frames: [CVPixelBuffer], level: VNRequestTrackingLevel, warm: Int = 5, timed: Int = 60) {
    guard let face = largestFace(frames[0]) else { record(name, input, [], first: .nan, notes: "no face on frame 0"); return }
    let seq = VNSequenceRequestHandler()
    let req = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: face.boundingBox))
    req.trackingLevel = level
    var times: [Double] = [], ious: [Double] = [], confs: [Double] = [], cerr: [Double] = [], first = 0.0, fails = 0
    for i in 1...(warm + timed) {
        let pb = frames[i]
        let t0 = now()
        do { try seq.perform([req], on: pb, orientation: .up) } catch { fails += 1 }
        let dt = msSince(t0)
        if i == 1 { first = dt }
        guard let obs = req.results?.first as? VNDetectedObjectObservation else { fails += 1; continue }
        req.inputObservation = obs
        if i > warm {
            times.append(dt); confs.append(Double(obs.confidence))
            if let f = largestFace(pb) { ious.append(iou(obs.boundingBox, f.boundingBox)); cerr.append(centerErr(obs.boundingBox, f.boundingBox)) }
        }
    }
    let box = face.boundingBox
    record(name, input, times, first: first,
           notes: "rev \(req.revision); init face box \(f1(Double(box.width) * 100))%x\(f1(Double(box.height) * 100))% of frame; IoU vs per-frame face detect mean \(f2(mean(ious))) min \(f2(ious.min() ?? .nan)); centre err mean \(f2(mean(cerr) * 100))% max \(f2((cerr.max() ?? .nan) * 100))%; conf mean \(f2(mean(confs))); fails \(fails)")
}

// MARK: - commands

func videoSuite(_ set: String, _ size: String) {
    let frames = loadSet("\(set)_\(size)")
    let n = frames.count
    let input = "\(size) \(set)"
    print("== \(input): \(n) frames loaded")
    let fr: (Int) -> CVPixelBuffer = { frames[$0] }
    benchImage("FaceRectangles", input, count: n, frame: fr, make: { VNDetectFaceRectanglesRequest() }, metric: countResults, metricLabel: "faces",
               describe: { r in
                   guard let f = (r.results as? [VNFaceObservation])?.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else { return "no face" }
                   return "face \(f1(Double(f.boundingBox.width) * 100))% wide"
               })
    benchImage("FaceLandmarks (incl. detect)", input, count: n, frame: fr, make: { VNDetectFaceLandmarksRequest() }, metric: countResults, metricLabel: "faces")
    benchImage("HumanRectangles upperBodyOnly=true", input, count: n, frame: fr,
               make: { let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = true; return r }, metric: countResults, metricLabel: "humans")
    benchImage("HumanRectangles upperBodyOnly=false", input, count: n, frame: fr,
               make: { let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = false; return r }, metric: countResults, metricLabel: "humans")
    benchTrack("TrackObject .fast (face init)", input, frames: frames, level: .fast)
    benchTrack("TrackObject .accurate (face init)", input, frames: frames, level: .accurate)
    for (q, qn) in [(VNGeneratePersonSegmentationRequest.QualityLevel.fast, ".fast"), (.balanced, ".balanced"), (.accurate, ".accurate")] {
        benchImage("PersonSegmentation \(qn)", input, count: n, frame: fr,
                   make: { let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = q; r.outputPixelFormat = kCVPixelFormatType_OneComponent8; return r },
                   describe: { r in
                       guard let m = (r.results as? [VNPixelBufferObservation])?.first?.pixelBuffer else { return "no mask" }
                       return "mask \(CVPixelBufferGetWidth(m))x\(CVPixelBufferGetHeight(m))"
                   })
    }
    benchImage("AttentionSaliency", input, count: n, frame: fr, make: { VNGenerateAttentionBasedSaliencyImageRequest() },
               metric: { r in Double((r.results?.first as? VNSaliencyImageObservation)?.salientObjects?.count ?? 0) }, metricLabel: "salient boxes",
               describe: { r in
                   guard let o = r.results?.first as? VNSaliencyImageObservation else { return "" }
                   return "heatmap \(CVPixelBufferGetWidth(o.pixelBuffer))x\(CVPixelBufferGetHeight(o.pixelBuffer))"
               })
    benchImage("ObjectnessSaliency", input, count: n, frame: fr, make: { VNGenerateObjectnessBasedSaliencyImageRequest() },
               metric: { r in Double((r.results?.first as? VNSaliencyImageObservation)?.salientObjects?.count ?? 0) }, metricLabel: "salient boxes")
    benchImage("HumanBodyPose", input, count: n, frame: fr, make: { VNDetectHumanBodyPoseRequest() }, metric: countResults, metricLabel: "bodies")
    benchImage("HumanHandPose (max 2 hands)", input, count: n, frame: fr,
               make: { let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2; return r }, metric: countResults, metricLabel: "hands")
    benchImage("ForegroundInstanceMask", input, count: n, frame: fr, make: { VNGenerateForegroundInstanceMaskRequest() },
               metric: { r in Double((r.results?.first as? VNInstanceMaskObservation)?.allInstances.count ?? 0) }, metricLabel: "instances")
}

func ocrSuite() {
    // app-screen frames: 65 frames spread over the walk-through (every 20th) so the content varies
    let walk = (0..<65).map { String(format: "%@/%04d.jpg", WALK, 1 + $0 * 20) }
    let ui = listImages(UI)
    for (label, files) in [("walk", walk), ("ui", ui)] {
        for scale in [1.0, 0.5] {
            let probe = loadPB(files[0], scale: scale)
            let size = "\(CVPixelBufferGetWidth(probe))x\(CVPixelBufferGetHeight(probe))"
            let frames = files.map { f in autoreleasepool { loadPB(f, scale: scale) } }
            let input = "\(size) \(label) (\(files.count) imgs)"
            print("== \(input)")
            for (lvl, ln) in [(VNRequestTextRecognitionLevel.fast, ".fast"), (.accurate, ".accurate")] {
                var chars: [Double] = []
                benchImage("RecognizeText \(ln)", input, count: frames.count, frame: { frames[$0] },
                           make: { let r = VNRecognizeTextRequest(); r.recognitionLevel = lvl; return r },
                           metric: { r in
                               let obs = (r.results as? [VNRecognizedTextObservation]) ?? []
                               chars.append(Double(obs.compactMap { $0.topCandidates(1).first?.string.count }.reduce(0, +)))
                               return Double(obs.count)
                           }, metricLabel: "lines",
                           describe: { _ in "chars/frame avg \(f1(mean(chars)))" },
                           extra: "usesLanguageCorrection default")
            }
        }
    }
}

func flowSuite() {
    for size in ["640x360", "1280x720"] {
        let frames = loadSet("face_\(size)")
        let accs: [(VNGenerateOpticalFlowRequest.ComputationAccuracy, String)] =
            size == "640x360" ? [(.low, ".low"), (.medium, ".medium"), (.high, ".high"), (.veryHigh, ".veryHigh")] : [(.low, ".low"), (.medium, ".medium")]
        for (acc, an) in accs {
            var times: [Double] = [], first = 0.0, err: String? = nil, desc = "", rev = 0
            for i in 0..<65 {
                autoreleasepool {
                    let t0 = now()
                    let req = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: frames[i + 1], options: [:])
                    req.computationAccuracy = acc
                    req.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
                    let h = VNImageRequestHandler(cvPixelBuffer: frames[i], orientation: .up, options: [:])
                    do { try h.perform([req]) } catch { err = "\(error)" }
                    let dt = msSince(t0)
                    rev = req.revision
                    if i == 0 { first = dt }
                    if i >= 5 { times.append(dt) }
                    if i == 64, let o = req.results?.first as? VNPixelBufferObservation {
                        desc = "flow field \(CVPixelBufferGetWidth(o.pixelBuffer))x\(CVPixelBufferGetHeight(o.pixelBuffer)) 2x16F"
                    }
                }
            }
            record("OpticalFlow \(an)", "\(size) face (pairs)", times, first: first, notes: "rev \(rev); \(desc)" + (err.map { "; ERROR \($0)" } ?? ""))
        }
    }
}

func devName(_ d: MLComputeDevice) -> String {
    switch d {
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .neuralEngine: return "ANE"
    @unknown default: return "\(d)"
    }
}

func devicesSuite() {
    let frames = loadSet("face_1280x720")
    let n = frames.count
    let kinds: [(String, () -> VNRequest)] = [
        ("FaceRectangles", { VNDetectFaceRectanglesRequest() }),
        ("HumanRectangles upperBodyOnly=true", { let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = true; return r }),
        ("PersonSegmentation .fast", { let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .fast; return r }),
        ("PersonSegmentation .balanced", { let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .balanced; return r }),
        ("AttentionSaliency", { VNGenerateAttentionBasedSaliencyImageRequest() }),
        ("HumanBodyPose", { VNDetectHumanBodyPoseRequest() }),
        ("HumanHandPose (max 2 hands)", { let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2; return r }),
    ]
    for (name, make) in kinds {
        let probe = make()
        guard let sup = try? probe.supportedComputeStageDevices else { print("\(name): supportedComputeStageDevices unavailable"); continue }
        let summary = sup.map { "\($0.key.rawValue): " + $0.value.map { devName($0) }.joined(separator: ",") }.sorted().joined(separator: " | ")
        print("\(name) supports -> \(summary)")
        let mains = sup[.main] ?? []
        for d in mains {
            benchImage("\(name) [main=\(devName(d))]", "1280x720 face", count: n, frame: { frames[$0] },
                       make: { let r = make(); r.setComputeDevice(d, for: .main); return r }, extra: "supported: \(summary)")
        }
    }
}

/// Long tracking runs: how far does VNTrackObjectRequest drift from a fresh per-frame detection, with no re-initialisation?
func trackSuite() {
    struct TrackRow: Codable { var run: String; var frames: Int; var p50: Double; var p95: Double; var iouMean: Double; var iouP10: Double; var iouMin: Double; var fracIoU50: Double; var centreErrMeanPct: Double; var centreErrP95Pct: Double; var confMean: Double; var confMin: Double; var refMisses: Int; var fails: Int; var lostAt: Int }
    var out: [TrackRow] = []
    for clip in ["trackA", "trackB"] {
        for size in ["1280x720", "640x360"] {
            let files = listImages(FRAMES + "/\(clip)_\(size)")
            for step in [1, 2] {
                for (lvl, ln) in [(VNRequestTrackingLevel.fast, "fast"), (.accurate, "accurate")] {
                    for target in ["face", "upperBody"] {
                        let run = "\(clip) \(size) \(30 / step)Hz \(ln) \(target)"
                        let pb0 = loadPB(files[0])
                        let initBox: CGRect? = target == "face" ? largestFace(pb0)?.boundingBox : largestUpperBody(pb0)?.boundingBox
                        guard let box = initBox else { print("\(run): no init box"); continue }
                        let seq = VNSequenceRequestHandler()
                        let req = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
                        req.trackingLevel = lvl
                        var times: [Double] = [], ious: [Double] = [], cerr: [Double] = [], confs: [Double] = []
                        var refMisses = 0, fails = 0, lostAt = -1, count = 0
                        var i = step
                        while i < files.count {
                            autoreleasepool {
                                let pb = loadPB(files[i])
                                let t0 = now()
                                do { try seq.perform([req], on: pb, orientation: .up) } catch { fails += 1 }
                                let dt = msSince(t0)
                                count += 1
                                if let obs = req.results?.first as? VNDetectedObjectObservation {
                                    req.inputObservation = obs
                                    if count > 5 { times.append(dt) }
                                    confs.append(Double(obs.confidence))
                                    let ref: CGRect? = target == "face" ? largestFace(pb)?.boundingBox : largestUpperBody(pb)?.boundingBox
                                    if let r = ref {
                                        let v = iou(obs.boundingBox, r); ious.append(v); cerr.append(centerErr(obs.boundingBox, r))
                                        if v < 0.3 && lostAt < 0 { lostAt = i }
                                    } else { refMisses += 1 }
                                } else { fails += 1 }
                            }
                            i += step
                        }
                        let row = TrackRow(run: run, frames: count, p50: pct(times, 0.5), p95: pct(times, 0.95), iouMean: mean(ious), iouP10: pct(ious, 0.1),
                                           iouMin: ious.min() ?? -1, fracIoU50: Double(ious.filter { $0 >= 0.5 }.count) / Double(max(ious.count, 1)),
                                           centreErrMeanPct: mean(cerr) * 100, centreErrP95Pct: pct(cerr, 0.95) * 100, confMean: mean(confs), confMin: confs.min() ?? -1,
                                           refMisses: refMisses, fails: fails, lostAt: lostAt)
                        out.append(row)
                        print("\(pad(run, 40)) n=\(count) p50=\(f2(row.p50)) p95=\(f2(row.p95)) IoU mean=\(f2(row.iouMean)) p10=\(f2(row.iouP10)) min=\(f2(row.iouMin)) >=0.5: \(f1(row.fracIoU50 * 100))% centreErr mean=\(f2(row.centreErrMeanPct))% p95=\(f2(row.centreErrP95Pct))% conf mean=\(f2(row.confMean)) min=\(f2(row.confMin)) refMiss=\(refMisses) fails=\(fails) firstIoU<0.3 at frame \(lostAt) (init box \(f1(Double(box.width) * 100))%x\(f1(Double(box.height) * 100))%)")
                    }
                }
            }
        }
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
    enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    try? enc.encode(out).write(to: URL(fileURLWithPath: BENCH + "/results_track.json"))
}

// MARK: - concurrency + CPU

final class Locked<T> {
    private var v: T; private let l = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { l.lock(); defer { l.unlock() }; return v }
    func set(_ n: T) { l.lock(); v = n; l.unlock() }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }
}

func processCPUns() -> UInt64 {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return UInt64(u.ru_utime.tv_sec) * 1_000_000_000 + UInt64(u.ru_utime.tv_usec) * 1000 + UInt64(u.ru_stime.tv_sec) * 1_000_000_000 + UInt64(u.ru_stime.tv_usec) * 1000
}

func runCmd(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

func gpuUtil() -> Double {
    let s = runCmd("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator"])
    guard let r = s.range(of: "\"Device Utilization %\"=") else { return .nan }
    let tail = s[r.upperBound...].prefix(while: { $0.isNumber })
    return Double(tail) ?? .nan
}

/// A thread that spins on floating-point work and counts iterations (stands in for a busy render/main thread).
final class BusyThread {
    let stop = Locked(false); let iters = Locked<UInt64>(0); let cpu = Locked<UInt64>(0)
    let done = DispatchSemaphore(value: 0)
    func start() {
        let t = Thread { [self] in
            let c0 = threadCPU(); var x = 1.0; var n: UInt64 = 0
            while !stop.get() {
                for _ in 0..<200_000 { x = x * 1.000000001 + 0.000000001 }
                n += 1
                if n % 16 == 0 { iters.set(n); cpu.set(threadCPU() - c0) }
            }
            if x == 42 { print(x) }
            iters.set(n); cpu.set(threadCPU() - c0); done.signal()
        }
        t.qualityOfService = .userInteractive; t.name = "busy"; t.start()
    }
    func finish() -> (iters: UInt64, cpuNs: UInt64) { stop.set(true); done.wait(); return (iters.get(), cpu.get()) }
}

/// A 60 Hz CoreImage/Metal compositor stand-in: renders a 16:9 1920x1080 and a 9:16 1080x1920 canvas per tick.
final class GPULoad {
    let stop = Locked(false); let frameMs = Locked<[Double]>([]); let cpu = Locked<UInt64>(0); let missed = Locked(0)
    let done = DispatchSemaphore(value: 0)
    let ctx: CIContext; let src: CIImage; let bgSrc: CIImage
    let dstH = makeBGRA(1920, 1080), dstV = makeBGRA(1080, 1920)
    init(_ a: CVPixelBuffer, _ b: CVPixelBuffer) {
        ctx = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false])
        src = CIImage(cvPixelBuffer: a); bgSrc = CIImage(cvPixelBuffer: b)
    }
    func compose(_ w: CGFloat, _ h: CGFloat, _ phase: CGFloat) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        let bs = max(w / bgSrc.extent.width, h / bgSrc.extent.height)
        let bg = bgSrc.transformed(by: CGAffineTransform(scaleX: bs, y: bs)).clampedToExtent().applyingGaussianBlur(sigma: 24).cropped(to: canvas)
        let z = 0.55 + 0.05 * sin(phase)  // animated "zoom" on the camera layer
        let s = (w * z) / src.extent.width
        let cam = src.transformed(by: CGAffineTransform(scaleX: s, y: s)).transformed(by: CGAffineTransform(translationX: w * 0.05, y: h * 0.1))
        return cam.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.1]).composited(over: bg).cropped(to: canvas)
    }
    func start() {
        let t = Thread { [self] in
            let c0 = threadCPU(); var k: CGFloat = 0; var next = now()
            while !stop.get() {
                let t0 = now()
                autoreleasepool {
                    if let a = try? ctx.startTask(toRender: compose(1920, 1080, k), to: CIRenderDestination(pixelBuffer: dstH)),
                       let b = try? ctx.startTask(toRender: compose(1080, 1920, k), to: CIRenderDestination(pixelBuffer: dstV)) {
                        _ = try? a.waitUntilCompleted(); _ = try? b.waitUntilCompleted()
                    }
                }
                let dt = msSince(t0)
                frameMs.mutate { $0.append(dt) }
                k += 0.05
                next &+= 16_666_667
                let n = now()
                if n < next { usleep(UInt32((next - n) / 1000)) } else { missed.mutate { $0 += 1 }; next = n }
                cpu.set(threadCPU() - c0)
            }
            done.signal()
        }
        t.qualityOfService = .userInteractive; t.name = "gpu"; t.start()
    }
    func finish() -> (frames: [Double], missed: Int, cpuNs: UInt64) { stop.set(true); done.wait(); return (frameMs.get(), missed.get(), cpu.get()) }
}

/// Face detection + face tracking on a background queue at 15 Hz, re-initialising the tracker from detection when they disagree.
final class VisionLoop {
    let q = DispatchQueue(label: "vision.15hz", qos: .userInitiated)
    var timer: DispatchSourceTimer?
    let frames: [CVPixelBuffer]
    var k = 0
    var seq = VNSequenceRequestHandler()
    var tracker: VNTrackObjectRequest?
    let face = VNDetectFaceRectanglesRequest()
    var tick: [Double] = [], faceMs: [Double] = [], trackMs: [Double] = [], interval: [Double] = [], ious: [Double] = []
    var reinits = 0, lastTick: UInt64 = 0
    init(_ frames: [CVPixelBuffer]) { self.frames = frames }
    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .nanoseconds(66_666_667), leeway: .milliseconds(1))
        t.setEventHandler { [self] in step() }
        timer = t; t.resume()
    }
    func step() {
        autoreleasepool {
            let t0 = now()
            if lastTick != 0 { interval.append(Double(t0 - lastTick) / 1e6) }
            lastTick = t0
            let pb = frames[k % frames.count]; k += 1
            let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            try? h.perform([face])
            let t1 = now(); faceMs.append(Double(t1 - t0) / 1e6)
            let f = face.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) })
            if let tr = tracker {
                try? seq.perform([tr], on: pb, orientation: .up)
                trackMs.append(msSince(t1))
                if let o = tr.results?.first as? VNDetectedObjectObservation {
                    tr.inputObservation = o
                    if let f = f {
                        let v = iou(o.boundingBox, f.boundingBox); ious.append(v)
                        if v < 0.3 || o.confidence < 0.3 { tracker = nil }
                    }
                } else { tracker = nil }
            }
            if tracker == nil, let f = f {
                let tr = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: f.boundingBox))
                tr.trackingLevel = .accurate
                tracker = tr; reinits += 1
            }
            tick.append(msSince(t0))
        }
    }
    func finish() -> [String: Double] {
        timer?.cancel()
        return q.sync { () -> [String: Double] in
            var d: [String: Double] = [:]
            let rest = Array(tick.dropFirst(15)), head = Array(tick.prefix(15))
            d["ticks"] = Double(tick.count); d["tickP50"] = pct(tick, 0.5); d["tickP95"] = pct(tick, 0.95); d["tickMax"] = tick.max() ?? .nan
            d["faceP50"] = pct(faceMs, 0.5); d["faceP95"] = pct(faceMs, 0.95); d["trackP50"] = pct(trackMs, 0.5); d["trackP95"] = pct(trackMs, 0.95)
            d["intervalP50"] = pct(interval, 0.5); d["intervalP95"] = pct(interval, 0.95); d["intervalMax"] = interval.max() ?? .nan
            d["reinits"] = Double(reinits); d["iouMean"] = mean(ious)
            d["tickP95after15"] = pct(rest, 0.95); d["tickMaxAfter15"] = rest.max() ?? .nan; d["first15max"] = head.max() ?? .nan
            d["overruns67ms"] = Double(tick.filter { $0 > 66.7 }.count)
            return d
        }
    }
}

func concurrentSuite() {
    // 150 frames at 1280x720 (every other frame of the 424-450 s face clip, i.e. real 15 Hz motion)
    let files = listImages(FRAMES + "/trackA_1280x720")
    let frames = stride(from: 0, to: 300, by: 2).map { i in autoreleasepool { loadPB(files[i]) } }
    let big = loadSet("face_1920x1080", 2)
    print("concurrent: \(frames.count) frames loaded; thermal state \(ProcessInfo.processInfo.thermalState.rawValue)")

    // warm the models so phase 1 does not include model load
    let warm = VisionLoop(frames); for _ in 0..<10 { warm.q.sync { warm.step() } }

    let phase = Locked("setup")
    let samples = Locked<[(String, Double, Double)]>([])
    let samplerStop = Locked(false)
    let pid = String(ProcessInfo.processInfo.processIdentifier)
    let sampler = Thread {
        while !samplerStop.get() {
            let ps = Double(runCmd("/bin/ps", ["-o", "%cpu=", "-p", pid]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
            let g = gpuUtil()
            samples.mutate { $0.append((phase.get(), ps, g)) }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
    sampler.qualityOfService = .utility; sampler.start()

    struct PhaseOut: Codable { var phase: String; var seconds: Double; var processCPUpct: Double; var busyThreadCPUpct: Double; var gpuThreadCPUpct: Double; var visionAndOtherCPUpct: Double; var psCPUpctMedian: Double; var gpuUtilPctMedian: Double; var busyItersPerSec: Double; var gpuFrameP50: Double; var gpuFrameP95: Double; var gpuMissed: Int; var vision: [String: Double] }
    var outs: [PhaseOut] = []

    func runPhase(_ name: String, seconds: Double, busy: Bool, gpu: Bool, vision: Bool) {
        phase.set(name)
        let b = busy ? BusyThread() : nil
        let g = gpu ? GPULoad(big[0], big[1]) : nil
        let v = vision ? VisionLoop(frames) : nil
        let c0 = processCPUns(), w0 = now()
        b?.start(); g?.start(); v?.start()
        Thread.sleep(forTimeInterval: seconds)
        let vr = v?.finish() ?? [:]
        let br = b?.finish(); let gr = g?.finish()
        let wall = Double(now() - w0) / 1e9, cpu = Double(processCPUns() - c0) / 1e9
        phase.set("gap")
        let ss = samples.get().filter { $0.0 == name }
        let busyPct = Double(br?.cpuNs ?? 0) / 1e9 / wall * 100, gpuPct = Double(gr?.cpuNs ?? 0) / 1e9 / wall * 100
        let o = PhaseOut(phase: name, seconds: wall, processCPUpct: cpu / wall * 100, busyThreadCPUpct: busyPct, gpuThreadCPUpct: gpuPct,
                         visionAndOtherCPUpct: cpu / wall * 100 - busyPct - gpuPct,
                         psCPUpctMedian: pct(ss.map { $0.1 }.filter { !$0.isNaN }, 0.5), gpuUtilPctMedian: pct(ss.map { $0.2 }.filter { !$0.isNaN }, 0.5),
                         busyItersPerSec: Double(br?.iters ?? 0) / wall,
                         gpuFrameP50: pct(gr?.frames ?? [], 0.5), gpuFrameP95: pct(gr?.frames ?? [], 0.95), gpuMissed: gr?.missed ?? 0,
                         vision: vr.mapValues { $0.isNaN ? -1 : $0 })
        outs.append(o)
        print("\(pad(name, 28)) wall=\(f1(wall))s proc CPU=\(f1(o.processCPUpct))% busy=\(f1(busyPct))% gpuThr=\(f1(gpuPct))% vision+other=\(f1(o.visionAndOtherCPUpct))% ps~\(f1(o.psCPUpctMedian))% GPU util~\(f1(o.gpuUtilPctMedian))% busyIter/s=\(f1(o.busyItersPerSec)) gpuFrame p50=\(f2(o.gpuFrameP50)) p95=\(f2(o.gpuFrameP95)) missed=\(o.gpuMissed)")
        if !vr.isEmpty {
            let keys = ["ticks", "tickP50", "tickP95", "tickMax", "first15max", "tickP95after15", "tickMaxAfter15", "overruns67ms", "faceP50", "faceP95", "trackP50", "trackP95", "intervalP50", "intervalP95", "intervalMax", "reinits", "iouMean"]
            print("    vision: " + keys.map { "\($0)=\(f2(vr[$0] ?? .nan))" }.joined(separator: " "))
        }
        Thread.sleep(forTimeInterval: 3)  // let ps decay a bit between phases
    }

    runPhase("idle (sampler only)", seconds: 8, busy: false, gpu: false, vision: false)
    runPhase("busy thread", seconds: 15, busy: true, gpu: false, vision: false)
    runPhase("busy thread + vision15Hz", seconds: 20, busy: true, gpu: false, vision: true)
    runPhase("vision15Hz alone", seconds: 20, busy: false, gpu: false, vision: true)
    runPhase("busy + GPU compositor", seconds: 15, busy: true, gpu: true, vision: false)
    runPhase("busy + GPU comp + vision15Hz", seconds: 20, busy: true, gpu: true, vision: true)
    samplerStop.set(true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
    enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    do { try enc.encode(outs).write(to: URL(fileURLWithPath: BENCH + "/results_concurrent\(ProcessInfo.processInfo.environment["RUNTAG"] ?? "").json")) } catch { print("json write failed: \(error)") }
    print("thermal state end \(ProcessInfo.processInfo.thermalState.rawValue)")
}

/// Per-frame trace of the tracker against detection through a scene change (corner layout -> full-frame camera via the Move transition).
func traceSuite() {
    let files = listImages(FRAMES + "/trackA_1280x720")
    let pb0 = loadPB(files[0])
    guard let f0 = largestFace(pb0) else { print("no face"); return }
    let seq = VNSequenceRequestHandler()
    let req = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: f0.boundingBox))
    req.trackingLevel = .accurate
    var csv = "frame,t_s,trk_x,trk_y,trk_w,trk_h,conf,face_x,face_y,face_w,face_h,iou\n"
    for i in 1..<min(files.count, 240) {
        autoreleasepool {
            let pb = loadPB(files[i])
            try? seq.perform([req], on: pb, orientation: .up)
            let o = req.results?.first as? VNDetectedObjectObservation
            if let o = o { req.inputObservation = o }
            let f = largestFace(pb)
            let tb = o?.boundingBox ?? .zero, fb = f?.boundingBox ?? .zero
            csv += "\(i),\(String(format: "%.3f", 424 + Double(i) / 30)),\(f2(Double(tb.minX))),\(f2(Double(tb.minY))),\(f2(Double(tb.width))),\(f2(Double(tb.height))),\(f2(Double(o?.confidence ?? 0))),\(f2(Double(fb.minX))),\(f2(Double(fb.minY))),\(f2(Double(fb.width))),\(f2(Double(fb.height))),\(f2(f == nil ? -1 : iou(tb, fb)))\n"
        }
    }
    try? csv.write(toFile: BENCH + "/trace_trackA.csv", atomically: true, encoding: .utf8)
    print("wrote trace_trackA.csv")
}

/// Which engine does each default request lean on? Run each request back-to-back for 6 s and sample GPU utilisation + process CPU.
func gpuCheck() {
    let f720 = loadSet("face_1280x720"), f360 = loadSet("face_640x360")
    let walk = (0..<20).map { i in autoreleasepool { loadPB(String(format: "%@/%04d.jpg", WALK, 1 + i * 60)) } }
    let kinds: [(String, (Int) -> VNRequest, (Int) -> CVPixelBuffer)] = [
        ("FaceRectangles 720p", { _ in VNDetectFaceRectanglesRequest() }, { f720[$0 % 70] }),
        ("PersonSegmentation .balanced 720p", { _ in let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .balanced; return r }, { f720[$0 % 70] }),
        ("PersonSegmentation .accurate 720p", { _ in let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .accurate; return r }, { f720[$0 % 70] }),
        ("ForegroundInstanceMask 720p", { _ in VNGenerateForegroundInstanceMaskRequest() }, { f720[$0 % 70] }),
        ("AttentionSaliency 720p", { _ in VNGenerateAttentionBasedSaliencyImageRequest() }, { f720[$0 % 70] }),
        ("OpticalFlow .medium 360p", { i in let r = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: f360[(i % 69) + 1], options: [:]); r.computationAccuracy = .medium; return r }, { f360[$0 % 69] }),
        ("RecognizeText .accurate 2880x1800", { _ in let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; return r }, { walk[$0 % 20] }),
        ("RecognizeText .fast 2880x1800", { _ in let r = VNRecognizeTextRequest(); r.recognitionLevel = .fast; return r }, { walk[$0 % 20] }),
    ]
    for (name, make, frame) in kinds {
        let probe = make(0)
        let sup = (try? probe.supportedComputeStageDevices).map { $0.map { "\($0.key.rawValue.replacingOccurrences(of: "VNComputeStage", with: "")): " + $0.value.map { devName($0) }.joined(separator: ",") }.sorted().joined(separator: " | ") } ?? "n/a"
        let stop = Locked(false); let utils = Locked<[Double]>([])
        let sampler = Thread { Thread.sleep(forTimeInterval: 1.0); while !stop.get() { let g = gpuUtil(); utils.mutate { $0.append(g) }; Thread.sleep(forTimeInterval: 0.5) } }
        sampler.start()
        let c0 = processCPUns(), w0 = now(); var n = 0
        var reused: VNRequest? = nil
        while Double(now() - w0) / 1e9 < 6 {
            autoreleasepool {
                let r: VNRequest = (name.hasPrefix("OpticalFlow")) ? make(n) : (reused ?? make(n)); reused = r
                try? VNImageRequestHandler(cvPixelBuffer: frame(n), orientation: .up, options: [:]).perform([r])
                n += 1
            }
        }
        let wall = Double(now() - w0) / 1e9, cpu = Double(processCPUns() - c0) / 1e9
        stop.set(true); Thread.sleep(forTimeInterval: 0.6)
        let u = utils.get().filter { !$0.isNaN }
        print("\(pad(name, 36)) back-to-back \(f1(Double(n) / wall)) req/s (\(f2(wall * 1000 / Double(n))) ms each) | process CPU \(f1(cpu / wall * 100))% of one core | GPU util median \(f1(pct(u, 0.5)))% max \(f1(u.max() ?? .nan))% | supported \(sup)")
    }
}

// MARK: - main

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "help"
print("visionbench \(cmd) | \(ProcessInfo.processInfo.operatingSystemVersionString) | thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
switch cmd {
case "video":
    let sizes = args.count > 2 ? Array(args[2...]) : ["640x360", "1280x720", "1920x1080"]
    for s in sizes { videoSuite("face", s) }
    for s in sizes { videoSuite("corner", s) }
    saveRows("video")
case "ocr": ocrSuite(); saveRows("ocr")
case "flow": flowSuite(); saveRows("flow")
case "devices": devicesSuite(); saveRows("devices")
case "track": trackSuite()
case "concurrent": concurrentSuite()
case "trace": traceSuite()
case "gpucheck": gpuCheck()
default: print("usage: visionbench video|ocr|flow|devices|track|concurrent")
}
