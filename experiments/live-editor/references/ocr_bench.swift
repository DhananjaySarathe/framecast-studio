// Scratch benchmark (research only, not part of the repo).
// Renders a synthetic "app window" screenshot (no real screen is captured), then times Apple Vision on it:
//  - VNRecognizeTextRequest fast / accurate, at 2560x1600, 1920x1200, 1280x800 and on a quarter region of interest
//  - recall of the known labels and the word-level box for "Settings"
//  - VNDetectHumanHandPoseRequest on a 1280x720 frame with no hands (cost floor of the detector stage)
//  - VNTrackObjectRequest following a textured square across 60 synthetic frames (per-frame cost and drift)
//  - VNTranslationalImageRegistrationRequest between a frame and the same frame scrolled 120 px (scroll detection)
//   swiftc -O ocr_bench.swift -o ocr_bench && ./ocr_bench
import AppKit
import Vision
import CoreImage

func median(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }
func ms(_ t: Double) -> String { String(format: "%6.1f ms", t * 1000) }
func time(_ n: Int, _ body: () throws -> Void) rethrows -> [Double] {
    var out: [Double] = []
    for _ in 0..<n { let t = CFAbsoluteTimeGetCurrent(); try body(); out.append(CFAbsoluteTimeGetCurrent() - t) }
    return out
}

// ---------- synthetic screen ----------
struct Label { var text: String; var x: CGFloat; var y: CGFloat; var size: CGFloat; var bold = false }
// Coordinates in a 1280x800 logical space, drawn at scale.
let labels: [Label] = {
    var l: [Label] = []
    let side = ["General", "Appearance", "Settings", "Privacy & Security", "Notifications", "Accounts", "Storage", "Export", "Share", "Help"]
    for (i, s) in side.enumerated() { l.append(Label(text: s, x: 24, y: 90 + CGFloat(i) * 34, size: 13)) }
    let toolbar = ["File", "Edit", "View", "Insert", "Format", "Window"]
    for (i, s) in toolbar.enumerated() { l.append(Label(text: s, x: 260 + CGFloat(i) * 70, y: 22, size: 13)) }
    l.append(Label(text: "Revenue growth by quarter", x: 260, y: 90, size: 22, bold: true))
    l.append(Label(text: "42%", x: 260, y: 140, size: 40, bold: true))
    l.append(Label(text: "Timer 00:12", x: 1080, y: 90, size: 18))
    l.append(Label(text: "Run prompt", x: 1080, y: 140, size: 13, bold: true))
    l.append(Label(text: "Upgrade to Pro", x: 1080, y: 190, size: 11))
    let body = ["The quick summary shows that throughput doubled after the change.",
                "Click Save to keep your work, or Discard to undo every edit.",
                "let session = LanguageModelSession(instructions: rules)",
                "for item in items where item.isVisible { draw(item) }",
                "Last updated 21 October 2026 at 10:42"]
    for (i, s) in body.enumerated() { l.append(Label(text: s, x: 260, y: 220 + CGFloat(i) * 30, size: i == 4 ? 10 : 14)) }
    for i in 0..<12 { l.append(Label(text: "Row \(i + 1)  item-\(1000 + i * 7)  $\(i * 13 + 9).00", x: 260, y: 400 + CGFloat(i) * 26, size: 12)) }
    return l
}()

func renderScreen(width: Int, height: Int, scrollY: CGFloat = 0) -> CGImage {
    let scale = CGFloat(width) / 1280
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 220 * scale, height: CGFloat(height)))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 1070 * scale, y: CGFloat(height) - 160 * scale, width: 120 * scale, height: 30 * scale))
    let g = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    // flip so y grows downward
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    for lab in labels {
        let font = lab.bold ? NSFont.boldSystemFont(ofSize: lab.size * scale) : NSFont.systemFont(ofSize: lab.size * scale)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)]
        let y = lab.y * scale - (lab.x > 250 ? scrollY * scale : 0)
        NSAttributedString(string: lab.text, attributes: attrs).draw(at: CGPoint(x: lab.x * scale, y: y))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

// ---------- OCR ----------
func ocr(_ img: CGImage, level: VNRequestTextRecognitionLevel, correction: Bool, roi: CGRect? = nil) throws -> [VNRecognizedTextObservation] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.usesLanguageCorrection = correction
    if let roi { req.regionOfInterest = roi }
    try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    return req.results ?? []
}

func recall(_ obs: [VNRecognizedTextObservation]) -> (Int, Int, [String]) {
    func squash(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    let found = obs.compactMap { $0.topCandidates(1).first.map { squash($0.string) } }.joined(separator: " | ")
    var hit = 0, missed: [String] = []
    for l in labels { if found.contains(squash(l.text)) { hit += 1 } else { missed.append(l.text) } }
    return (hit, labels.count, missed)
}

print("Vision OCR on a synthetic app window (\(labels.count) known text items, sizes 10-40 pt at 1280x800 logical)")
for (w, h) in [(2560, 1600), (1920, 1200), (1280, 800)] {
    let img = renderScreen(width: w, height: h)
    for (name, level) in [("fast", VNRequestTextRecognitionLevel.fast), ("accurate", .accurate)] {
        for corr in [false, true] {
            _ = try ocr(img, level: level, correction: corr)   // warm-up
            var last: [VNRecognizedTextObservation] = []
            let t = try time(7) { last = try ocr(img, level: level, correction: corr) }
            let (hit, n, missed) = recall(last)
            print("  \(w)x\(h) \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) correction=\(corr ? "on " : "off")  median \(ms(median(t)))  min \(ms(t.min()!))  recall \(hit)/\(n)  missed: \(missed.prefix(5).joined(separator: ", "))")
        }
    }
}
// region of interest: the left sidebar only (normalized, origin bottom-left)
do {
    let img = renderScreen(width: 2560, height: 1600)
    let roi = CGRect(x: 0, y: 0, width: 0.2, height: 1)
    for (name, level) in [("fast", VNRequestTextRecognitionLevel.fast), ("accurate", .accurate)] {
        _ = try ocr(img, level: level, correction: false, roi: roi)
        let t = try time(7) { _ = try ocr(img, level: level, correction: false, roi: roi) }
        print("  2560x1600 \(name) ROI=sidebar (20% of width)  median \(ms(median(t)))")
    }
    // word-level box for "Settings"
    let obs = try ocr(img, level: .accurate, correction: false)
    for o in obs {
        guard let c = o.topCandidates(1).first, let r = c.string.range(of: "Settings") else { continue }
        let box = try c.boundingBox(for: r)?.boundingBox
        print("  'Settings' found in line \"\(c.string)\" confidence \(c.confidence); line box \(o.boundingBox); word box \(box.map { "\($0)" } ?? "nil")")
        print("  expected approx x 0.019-0.08, y (from bottom) ~0.83-0.86")
    }
}

// ---------- hand pose cost floor ----------
do {
    let w = 1280, h = 720
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    for i in 0..<400 { // blotches to mimic a room
        ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: (i * 97) % w, y: (i * 53) % h, width: 60 + i % 40, height: 40 + i % 30))
    }
    let img = ctx.makeImage()!
    let req = VNDetectHumanHandPoseRequest(); req.maximumHandCount = 2
    try VNImageRequestHandler(cgImage: img).perform([req])
    let t = try time(15) { try VNImageRequestHandler(cgImage: img).perform([req]) }
    print("\nHand pose on 1280x720 with no hands (detector cost floor): median \(ms(median(t)))  results \(req.results?.count ?? 0)")
    let body = VNDetectHumanBodyPoseRequest()
    try VNImageRequestHandler(cgImage: img).perform([body])
    let tb = try time(15) { try VNImageRequestHandler(cgImage: img).perform([body]) }
    print("Body pose on 1280x720 with no person: median \(ms(median(tb)))")
    let sal = VNGenerateAttentionBasedSaliencyImageRequest()
    try VNImageRequestHandler(cgImage: img).perform([sal])
    let ts = try time(10) { try VNImageRequestHandler(cgImage: img).perform([sal]) }
    print("Attention saliency on 1280x720: median \(ms(median(ts)))")
}

// ---------- object tracking ----------
do {
    let w = 1280, h = 720, side = 120
    func frame(_ k: Int) -> (CGImage, CGRect) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<150 { ctx.setFillColor(CGColor(gray: CGFloat(i % 9) / 9, alpha: 1)); ctx.fill(CGRect(x: (i * 211) % w, y: (i * 89) % h, width: 18, height: 18)) }
        let x = 200 + Double(k) * 12, y = 300 + 80 * sin(Double(k) / 8)
        let r = CGRect(x: x, y: y, width: Double(side), height: Double(side))
        for i in 0..<6 { for j in 0..<6 {
            ctx.setFillColor((i + j) % 2 == 0 ? CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1) : CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: x + Double(i * 20), y: y + Double(j * 20), width: 20, height: 20)) } }
        return (ctx.makeImage()!, CGRect(x: r.minX / Double(w), y: r.minY / Double(h), width: r.width / Double(w), height: r.height / Double(h)))
    }
    for level in [VNRequestTrackingLevel.fast, .accurate] {
        let (f0, b0) = frame(0)
        var obs = VNDetectedObjectObservation(boundingBox: b0)
        let seq = VNSequenceRequestHandler()
        _ = f0
        var times: [Double] = [], maxErr = 0.0
        for k in 1..<60 {
            let (f, truth) = frame(k)
            let req = VNTrackObjectRequest(detectedObjectObservation: obs); req.trackingLevel = level
            let t = CFAbsoluteTimeGetCurrent()
            try seq.perform([req], on: f)
            times.append(CFAbsoluteTimeGetCurrent() - t)
            if let o = req.results?.first as? VNDetectedObjectObservation { obs = o }
            let err = hypot(obs.boundingBox.midX - truth.midX, obs.boundingBox.midY - truth.midY)
            maxErr = max(maxErr, err)
        }
        print("TrackObject \(level == .fast ? "fast" : "accurate") 1280x720, 59 frames: median \(ms(median(times)))  max centre error \(String(format: "%.3f", maxErr)) of frame width")
    }
}

// ---------- scroll detection ----------
do {
    let a = renderScreen(width: 1280, height: 800), b = renderScreen(width: 1280, height: 800, scrollY: 60)
    let req = VNTranslationalImageRegistrationRequest(targetedCGImage: b)
    try VNImageRequestHandler(cgImage: a).perform([req])
    let t = try time(10) { try VNImageRequestHandler(cgImage: a).perform([VNTranslationalImageRegistrationRequest(targetedCGImage: b)]) }
    let tr = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform
    print("\nScroll registration 1280x800 (content right of sidebar scrolled 60 px): median \(ms(median(t)))  transform \(tr.map { "tx \($0.tx) ty \($0.ty)" } ?? "nil")")
}
