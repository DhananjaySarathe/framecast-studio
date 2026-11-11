// Throwaway: (1) which compute device the default picks, by forcing CPU / GPU / ANE; (2) a sustained "live editor" loop at 30 fps.
import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreML

setvbuf(stdout, nil, _IONBF, 0)
func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func loadFrames(_ path: String, start: Double, count: Int) throws -> [CVPixelBuffer] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let sem = DispatchSemaphore(value: 0); var track: AVAssetTrack?
    Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }; sem.wait()
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: 30, preferredTimescale: 600))
    let out = AVAssetReaderTrackOutput(track: track!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
    reader.add(out); reader.startReading()
    var frames: [CVPixelBuffer] = []
    while frames.count < count, let sb = out.copyNextSampleBuffer() { if let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) } }
    reader.cancelReading(); return frames
}
let ci = CIContext()
func scaled(_ pb: CVPixelBuffer, _ w: Int, _ h: Int) -> CVPixelBuffer {
    var out: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &out)
    let img = CIImage(cvPixelBuffer: pb)
    ci.render(img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height)), to: out!)
    return out!
}

let frames = try loadFrames(CommandLine.arguments[1], start: Double(CommandLine.arguments[2]) ?? 60, count: 120)
let hd = frames.map { scaled($0, 1280, 720) }
print("frames \(frames.count)")

func pick(_ r: VNRequest, _ want: String) -> Bool {
    guard let d = try? r.supportedComputeStageDevices, let list = d[.main] else { return false }
    for dev in list {
        switch (dev, want) {
        case (.cpu, "CPU"), (.gpu, "GPU"), (.neuralEngine, "ANE"): r.setComputeDevice(dev, for: .main); return true
        default: continue
        }
    }
    return false
}
func timeIt(_ make: () -> VNRequest, _ want: String?) -> String {
    let r = make()
    if let w = want, !pick(r, w) { return "  n/a " }
    try? VNImageRequestHandler(cvPixelBuffer: hd[0], options: [:]).perform([r])
    var t: [Double] = []
    for pb in hd.prefix(31).dropFirst() { let t0 = now(); try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([r]); t.append(now() - t0) }
    t.sort(); return String(format: "%6.1f", t[t.count / 2] * 1000)
}
print("--- forced compute device, 1280x720, median ms: default | ANE | GPU | CPU")
let cases: [(String, () -> VNRequest)] = [
    ("DetectFaceRectangles", { VNDetectFaceRectanglesRequest() }),
    ("DetectHumanRectangles upper", { let r = VNDetectHumanRectanglesRequest(); r.upperBodyOnly = true; return r }),
    ("DetectHumanHandPose x2", { let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2; return r }),
    ("DetectHumanBodyPose", { VNDetectHumanBodyPoseRequest() }),
    ("PersonSegmentation balanced", { let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .balanced; return r }),
    ("AttentionSaliency", { VNGenerateAttentionBasedSaliencyImageRequest() }),
]
for (name, make) in cases {
    print("\(name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(timeIt(make, nil)) | \(timeIt(make, "ANE")) | \(timeIt(make, "GPU")) | \(timeIt(make, "CPU"))")
}

// Sustained loop: 30 fps for 120 frames x2 passes (8 s). Every frame: tracker on the subject (half res).
// Every 3rd frame (10 Hz): face + upper-body detection at 720p (re-seed tracker). Every 3rd frame offset: hand pose.
// Every 30th frame (1 Hz): person segmentation fast. Measures wall time per frame and process CPU %.
print("--- sustained live loop @30 fps pacing (tracker 30 Hz, face+human 10 Hz, hands 10 Hz, person seg fast 1 Hz)")
let half = frames.map { scaled($0, 960, 540) }
let seq = VNSequenceRequestHandler()
var obs = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3))
let face = VNDetectFaceRectanglesRequest(); let hum = VNDetectHumanRectanglesRequest(); hum.upperBodyOnly = true
let hand = VNDetectHumanHandPoseRequest(); hand.maximumHandCount = 2
let seg = VNGeneratePersonSegmentationRequest(); seg.qualityLevel = .fast
try? VNImageRequestHandler(cvPixelBuffer: hd[0], options: [:]).perform([face, hum, hand, seg]) // warm
var worst = 0.0; var total = 0.0
let cpu0 = cpuSeconds(); let wall0 = now()
var k = 0
for pass in 0..<2 {
    for i in 0..<frames.count {
        let frameStart = now()
        if k % 3 == 0 {
            try? VNImageRequestHandler(cvPixelBuffer: hd[i], options: [:]).perform([face, hum])
            if let f = face.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) { obs = VNDetectedObjectObservation(boundingBox: f.boundingBox) }
        } else if k % 3 == 1 {
            try? VNImageRequestHandler(cvPixelBuffer: hd[i], options: [:]).perform([hand])
        }
        if k % 30 == 0 { try? VNImageRequestHandler(cvPixelBuffer: hd[i], options: [:]).perform([seg]) }
        let tr = VNTrackObjectRequest(detectedObjectObservation: obs); tr.revision = VNTrackObjectRequestRevision2
        try? seq.perform([tr], on: half[i])
        if let o = tr.results?.first as? VNDetectedObjectObservation { obs = o }
        let work = now() - frameStart
        worst = max(worst, work); total += work
        let sleep = 1.0 / 30.0 - work
        if sleep > 0 { usleep(useconds_t(sleep * 1e6)) }
        k += 1
        _ = pass
    }
}
let wall = now() - wall0; let cpu = cpuSeconds() - cpu0
print(String(format: "frames %d  wall %.1fs  vision work avg %.1f ms/frame  worst %.1f ms  process CPU %.1f%% of one core", k, wall, total / Double(k) * 1000, worst * 1000, cpu / wall * 100))
