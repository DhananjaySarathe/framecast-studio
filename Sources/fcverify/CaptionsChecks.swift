import Foundation
import CoreGraphics
import CoreMedia
import FramecastEngine
import ImageIO
import Vision

/// Live captions without a microphone: line breaking on each canvas, rolling up, guesses settling into final text,
/// the fade, subtitle files, settings that still load, the caption clock, the microphone tap beside Listen's, and
/// the engine drawing the bar in the right band of both canvases (and nothing once off).
func captionsChecks() -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(name)\(detail.isEmpty ? "" : ": \(detail)") → \(ok ? "PASS" : "FAIL")")
        if !ok { failures += 1 }
    }
    func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
    let h16 = CGSize(width: 1920, height: 1080), v916 = CGSize(width: 1080, height: 1920)
    let speech = "so today I want to show you how the new captions work in Framecast they follow what you say and roll up as you keep talking without ever jumping around on screen"
    let words = speech.split(separator: " ").map { CaptionWord(String($0), settled: true) }

    // Line breaking by measured width (a stand-in measure: half the type size per character).
    for (name, canvas) in [("16:9", h16), ("9:16", v916)] {
        let px = CaptionGeometry.fontSize(.medium, canvas: canvas)
        let measure = { (s: String) in CGFloat(s.count) * px * 0.5 }
        let maxW = CaptionGeometry.maxTextWidth(canvas, font: px)
        let all = CaptionLayout.lines(words, maxWidth: maxW, measure: measure, space: px * 0.25, maxLines: 100)
        let shown = CaptionLayout.lines(words, maxWidth: maxW, measure: measure, space: px * 0.25)
        func lineWidth(_ l: [CaptionWord]) -> CGFloat {
            let text: CGFloat = l.map { measure($0.text) }.reduce(0, +)
            return text + px * 0.25 * CGFloat(l.count - 1)
        }
        let widest: CGFloat = all.map(lineWidth).max() ?? 0
        check("\(name): every line fits the caption width (\(Int(maxW)) px)", widest <= maxW, "\(all.count) lines, widest \(Int(widest)) px")
        check("\(name): at most two lines shown, the last two", shown.count == 2 && shown == Array(all.suffix(2)) && shown.last?.last?.text == "screen",
              shown.map(CaptionLayout.text).joined(separator: " / "))
        check("\(name): no word lost or reordered", all.flatMap { $0 }.map(\.text) == words.map(\.text))
    }
    let pxH = CaptionGeometry.fontSize(.medium, canvas: h16), pxV = CaptionGeometry.fontSize(.medium, canvas: v916)
    let linesH = CaptionLayout.lines(words, maxWidth: CaptionGeometry.maxTextWidth(h16, font: pxH), measure: { CGFloat($0.count) * pxH * 0.5 }, space: pxH * 0.25, maxLines: 100).count
    let linesV = CaptionLayout.lines(words, maxWidth: CaptionGeometry.maxTextWidth(v916, font: pxV), measure: { CGFloat($0.count) * pxV * 0.5 }, space: pxV * 0.25, maxLines: 100).count
    check("9:16 breaks into more lines than 16:9 (narrower)", linesV > linesH, "\(linesH) on 16:9, \(linesV) on 9:16")
    check("a word longer than the line stays whole on its own line",
          CaptionLayout.lines([CaptionWord("a", settled: true), CaptionWord("supercalifragilistic", settled: true), CaptionWord("b", settled: true)],
                              maxWidth: 10, measure: { CGFloat($0.count) }, space: 1, maxLines: 9).map(CaptionLayout.text) == ["a", "supercalifragilistic", "b"])

    // Rolling up: adding words never moves words already placed; the top line is always a line that was the bottom one.
    do {
        let measure = { (s: String) in CGFloat(s.count) * 10 }
        var prev: [[CaptionWord]] = []
        var stable = true, rolls = 0, topWasBottom = true
        var seenBottom: Set<String> = []
        for n in 1...words.count {
            let all = CaptionLayout.lines(Array(words.prefix(n)), maxWidth: 400, measure: measure, space: 10, maxLines: 100)
            if !prev.isEmpty && Array(all.prefix(prev.count - 1)) != Array(prev.dropLast()) { stable = false }
            if all.count > prev.count && !prev.isEmpty { rolls += 1 }
            let shown = Array(all.suffix(2))
            if shown.count == 2, !seenBottom.contains(CaptionLayout.text(shown[0])) { topWasBottom = false }
            if let b = shown.last { seenBottom.insert(CaptionLayout.text(b)) }
            prev = all
        }
        check("rolling: words already on screen never reflow as more come", stable)
        check("rolling: the captions roll up a line at a time (the top line was the bottom line)", topWasBottom && rolls >= 3, "\(rolls) roll-ups")
    }

    // Guesses settle into final text.
    do {
        var t = CaptionTrack()
        t.take("hello", isFinal: false, start: 0, end: 0.4, now: 10)
        t.take("hello wor", isFinal: false, start: 0, end: 0.7, now: 10.2)
        t.take("hello world", isFinal: false, start: 0, end: 0.9, now: 10.4)
        check("a guess is shown lighter and replaced by the next guess", t.words == [CaptionWord("hello", settled: false), CaptionWord("world", settled: false)])
        let id = t.take("Hello world.", isFinal: true, start: 0, end: 1.0, now: 10.9)
        check("final text replaces the guess, drawn full", t.words == [CaptionWord("Hello", settled: true), CaptionWord("world.", settled: true)] && id != nil,
              t.words.map { ($0.settled ? "" : "~") + $0.text }.joined(separator: " "))
        t.take("this is", isFinal: false, start: 1.1, end: 1.5, now: 11.2)
        check("the next guess follows the final words", t.words.map(\.text) == ["Hello", "world.", "this", "is"] && t.words.map(\.settled) == [true, true, false, false])
        t.take("stale", isFinal: false, start: 0.5, end: 0.8, now: 11.3)
        check("a late guess for speech already settled is ignored", t.words.map(\.text) == ["Hello", "world.", "this", "is"])
        var blink = CaptionTrack()
        blink.take("so today", isFinal: false, start: 4, end: 4.5, now: 20)
        blink.take("", isFinal: false, start: 4, end: 4.6, now: 20.1)
        check("an empty guess for the same stretch doesn't blink the captions off", blink.words.map(\.text) == ["so", "today"])
        let before = t.lastChange
        t.take("this is", isFinal: false, start: 1.1, end: 1.6, now: 12.5)
        check("a result that changes nothing doesn't keep the captions up", t.lastChange == before)
        let empty = t.take("", isFinal: true, start: 1.6, end: 1.7, now: 12.6)
        check("an empty final result adds no transcript line", empty == nil)
        let id2 = t.take("This is Framecast.", isFinal: true, start: 1.1, end: 2.2, now: 12.8)
        check("finals add up in order", t.words.map(\.text) == ["Hello", "world.", "This", "is", "Framecast."] && t.guess.isEmpty)
        if let id2 { t.correct(id: id2, text: "This is FrameCast live.") }
        check("a correction to a line still on screen changes the words shown", t.words.map(\.text) == ["Hello", "world.", "This", "is", "FrameCast", "live."])
        check("a correction to a line no longer on screen changes nothing", !t.correct(id: 999, text: "x"))

        // Fade: three seconds after the last new words, then about half a second to go.
        let lc = t.lastChange
        check("fade: fully shown for 3 s after the last words", CaptionFade.alpha(now: lc + 2.95, lastChange: lc) == 1)
        check("fade: half way at 3.3 s", near(CaptionFade.alpha(now: lc + 3.3, lastChange: lc), 0.5, 0.01), String(format: "%.3f", CaptionFade.alpha(now: lc + 3.3, lastChange: lc)))
        check("fade: gone at 3.6 s", CaptionFade.alpha(now: lc + 3.6, lastChange: lc) == 0 && CaptionFade.isGone(now: lc + 3.6, lastChange: lc))
        t.take("new", isFinal: false, start: 5, end: 5.3, now: lc + 2)
        check("speech before the fade continues the block", t.words.count == 7)
        t.take("next thought", isFinal: false, start: 9, end: 9.5, now: t.lastChange + 4)
        check("speech after the fade starts a fresh block", t.words.map(\.text) == ["next", "thought"])
        var long = CaptionTrack()
        for i in 0..<60 { long.take("word\(i) more\(i) text\(i)", isFinal: true, start: Double(i), end: Double(i) + 0.9, now: 100 + Double(i) * 0.5) }
        check("a long block keeps only its last words", long.words.count <= long.maxWords && long.words.last?.text == "text59", "\(long.words.count) words")
    }

    // Subtitle files.
    check("SRT timestamp", CaptionExport.timestamp(3661.5) == "01:01:01,500" && CaptionExport.timestamp(0) == "00:00:00,000" && CaptionExport.timestamp(-2) == "00:00:00,000")
    let srt = CaptionExport.srt([TimedCaption(start: 1.25, end: 3.5, text: "Hello and welcome."), TimedCaption(start: 4, end: 4.3, text: "Short.")])
    let wantSRT = "1\n00:00:01,250 --> 00:00:03,500\nHello and welcome.\n\n2\n00:00:04,000 --> 00:00:04,800\nShort.\n"
    check("SRT: numbered cues, times, text, blank lines between", srt == wantSRT, srt.debugDescription)
    let longText = "This is a much longer stretch of speech that goes on for a while so it needs more than one subtitle cue to stay readable on screen."
    let cues = CaptionExport.cues([TimedCaption(start: 10, end: 20, text: longText), TimedCaption(start: 20.5, end: 22, text: "Next.")])
    let lineOK = cues.allSatisfy { $0.text.split(separator: "\n").count <= 2 && $0.text.split(separator: "\n").allSatisfy { $0.count <= 42 } }
    let ordered = zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 }
    check("SRT: a long caption becomes several cues of at most two 42-character lines, time shared by length, never overlapping",
          cues.count == 3 && lineOK && ordered && near(cues[0].start, 10, 1e-9) && near(cues[1].end, 20, 1e-6) && cues[0].end > 14 && cues[0].end < 17,
          cues.map { String(format: "%.2f-%.2f", $0.start, $0.end) }.joined(separator: " "))
    let tight = CaptionExport.cues([TimedCaption(start: 1, end: 1.2, text: "One."), TimedCaption(start: 1.5, end: 2, text: "Two.")])
    check("SRT: a short cue stays up longer only until the next one starts", near(tight[0].end, 1.5, 1e-9) && near(tight[1].end, 2.3, 1e-9))
    check("SRT: empty text and zero-length captions are left out", CaptionExport.cues([TimedCaption(start: 1, end: 1, text: "x"), TimedCaption(start: 2, end: 3, text: "  ")]).isEmpty)
    check("SRT: a caption mostly said before the recording (or in a pause) is left out, one mostly inside kept",
          !CaptionExport.keeps(inside: 0.5, spoken: 3.2) && CaptionExport.keeps(inside: 2, spoken: 3.2) && !CaptionExport.keeps(inside: 0, spoken: 0)
          && CaptionExport.keeps(inside: 1.2, spoken: 1.2))
    check("transcript: one line per caption with its time", CaptionExport.transcript([TimedCaption(start: 65, end: 66, text: "Later."), TimedCaption(start: 5.4, end: 6, text: "First.")])
          == "[00:05] First.\n[01:05] Later.\n")

    // Settings load whatever was saved before (or after).
    func decode(_ json: String) -> CaptionSettings? { try? JSONDecoder().decode(CaptionSettings.self, from: Data(json.utf8)) }
    check("settings: empty settings load with defaults", decode("{}") == CaptionSettings())
    let odd = decode(#"{"language":"hi_IN","size":"huge","position":"top","later":1}"#)
    check("settings: an unknown size falls back, the rest is kept", odd?.language == "hi_IN" && odd?.size == .medium && odd?.position == .top)
    check("settings: a broken value never stops settings loading", decode(#"{"size":5,"position":null,"language":7}"#) == CaptionSettings())
    struct Outer: Codable { var other = 3; var captions: CaptionSettings? }
    let outer = try? JSONDecoder().decode(Outer.self, from: Data(#"{"other":4,"captions":"oops"}"#.utf8))
    check("settings: even a garbled captions entry keeps the rest of Settings", outer?.other == 4)
    var round = CaptionSettings(); round.language = "en_GB"; round.size = .large; round.position = .top
    check("settings: round trip", (try? JSONDecoder().decode(CaptionSettings.self, from: JSONEncoder().encode(round))) == round)

    // The caption clock: the recogniser's seconds map back to the microphone's capture times, across a gap.
    do {
        var c = CaptionClock()
        for i in 0..<10 { c.note(frames: 4800, host: 100 + Double(i) * 0.1 + (i % 2 == 0 ? 0.004 : -0.003)) }
        for i in 0..<10 { c.note(frames: 4800, host: 250 + Double(i) * 0.1) }      // muted for a while, then back
        check("clock: steady audio maps straight through (small jitter ignored)", near(c.host(at: 0.55) ?? 0, 100.554, 0.01), String(format: "%.3f", c.host(at: 0.55) ?? -1))
        check("clock: after a gap the times follow the microphone again", near(c.host(at: 1.25) ?? 0, 250.25, 0.001), String(format: "%.3f", c.host(at: 1.25) ?? -1))
        check("clock: nothing before any audio", CaptionClock().host(at: 1) == nil)
    }

    // Geometry: the bar stays clear of Reels and Shorts on 9:16, inside the side margins.
    do {
        let y = CaptionGeometry.plateY(.bottom, canvas: v916, height: 200)
        check("9:16 bottom: above the bottom 22%", y >= v916.height * 0.22, "plate from \(Int(y)) px")
        check("9:16: inside side margins", CaptionGeometry.maxPlateWidth(v916) <= v916.width * 0.8)
        check("top position stays below the top edge", CaptionGeometry.plateY(.top, canvas: h16, height: 120) + 120 < h16.height - 40
              && CaptionGeometry.plateY(.top, canvas: v916, height: 200) + 200 <= v916.height * 0.9)
    }

    // The microphone tap for captions works beside Listen's (and the angles' ears'), and hears nothing while muted.
    do {
        let mixer = AudioMixer(origin: HostClock.now())
        let mic = UUID()
        mixer.addSource(mic, settings: AudioSettings())
        var listenN = 0, captionN = 0
        var captionPTS = CMTime.invalid
        mixer.setListenTap(mic) { _, n in listenN += n }
        mixer.setCaptionTap(mic) { _, n, pts in captionN += n; captionPTS = pts }
        let buf = [Float](repeating: 0.1, count: 960)
        let at = HostClock.now()
        buf.withUnsafeBufferPointer { mixer.push(mic, samples: $0.baseAddress!, frames: 480, pts: at) }
        check("mic tap: Listen and captions both hear the microphone", listenN == 480 && captionN == 480 && CMTimeCompare(captionPTS, at) == 0)
        mixer.setListenTap(nil, nil)
        buf.withUnsafeBufferPointer { mixer.push(mic, samples: $0.baseAddress!, frames: 480, pts: at) }
        check("mic tap: Listen stopping leaves captions hearing", listenN == 480 && captionN == 960)
        var muted = AudioSettings(); muted.isMuted = true
        mixer.update(mic, settings: muted)
        buf.withUnsafeBufferPointer { mixer.push(mic, samples: $0.baseAddress!, frames: 480, pts: at) }
        check("mic tap: a muted microphone gives captions nothing", captionN == 960)
        mixer.setCaptionTap(nil, nil)
        mixer.setListenTap(mic) { _, n in listenN += n }
        mixer.update(mic, settings: AudioSettings())
        buf.withUnsafeBufferPointer { mixer.push(mic, samples: $0.baseAddress!, frames: 480, pts: at) }
        check("mic tap: captions stopping leaves Listen hearing", listenN == 960 && captionN == 960)
    }

    // The engine draws the bar in the right band of both canvases, and nothing once off.
    do {
        let engine = Engine()
        func bright(_ img: CGImage?) -> (count: Int, top: Int, bottom: Int, maxLuma: Int) {
            guard let img else { return (0, -1, -1, 0) }
            let w = img.width, h = img.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeMutableBytes { b in
                let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            var n = 0, top = Int.max, bottom = -1, mx = 0
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                let l = (Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / 3
                mx = max(mx, l)
                if data[i] > 200, data[i + 1] > 200, data[i + 2] > 200 { n += 1; top = min(top, y); bottom = max(bottom, y) }
            } }
            return (n, n > 0 ? top : -1, bottom, mx)
        }
        let say = "Captions on both canvases, drawn by Framecast".split(separator: " ").map { CaptionWord(String($0), settled: true) }
        func show(_ size: CaptionSize = .medium, _ pos: CaptionPosition = .bottom, words: [CaptionWord]? = nil, ago: Double = 0) {
            engine.showCaptions(CaptionFrame(words: words ?? say, size: size, position: pos, lastChange: HostClock.seconds() - ago))
        }
        show()
        let a = bright(engine.programSnapshot(.horizontal, width: 1920)), b = bright(engine.programSnapshot(.vertical, width: 1080))
        check("engine 16:9: white caption text in the bottom band only", a.count > 2000 && a.top > Int(1080 * 0.70) && a.bottom < 1080 - Int(1080 * 0.06),
              "\(a.count) px, rows \(a.top)–\(a.bottom)")
        check("engine 9:16: caption text above the bottom 22% and below the middle", b.count > 2000 && b.bottom < Int(1920 * 0.78) && b.top > 960,
              "\(b.count) px, rows \(b.top)–\(b.bottom)")
        let linesH = engine.captionLines(.horizontal), linesV = engine.captionLines(.vertical)
        check("engine: lines shown on each canvas (at most two, nothing lost)", (1...2).contains(linesH.count) && (1...2).contains(linesV.count)
              && linesH.joined(separator: " ") == say.map(\.text).joined(separator: " ") && linesV.joined(separator: " ") == linesH.joined(separator: " "),
              "16:9 \(linesH) · 9:16 \(linesV)")
        let again = bright(engine.programSnapshot(.horizontal, width: 1920))
        check("engine: the same words draw the same picture (no flicker)", again.count == a.count && again.top == a.top)
        let guessed = bright({ show(words: say.map { CaptionWord($0.text, settled: false) }); return engine.programSnapshot(.horizontal, width: 1920) }())
        check("engine: words still being recognised are drawn lighter", guessed.maxLuma < a.maxLuma - 40, "max \(guessed.maxLuma) vs \(a.maxLuma)")
        show()
        let settling = bright(engine.programSnapshot(.horizontal, width: 1920))
        Thread.sleep(forTimeInterval: 0.3)
        let settled = bright(engine.programSnapshot(.horizontal, width: 1920))
        check("engine: words settling fade up to full white (no jump)", settling.maxLuma < settled.maxLuma && settled.maxLuma == a.maxLuma && settled.count == a.count,
              "\(guessed.maxLuma) → \(settling.maxLuma) → \(settled.maxLuma)")
        show(.medium, .top)
        let topH = bright(engine.programSnapshot(.horizontal, width: 1920)), topV = bright(engine.programSnapshot(.vertical, width: 1080))
        check("engine: top position draws in the top band of both canvases", topH.bottom < 1080 / 4 && topH.top > 0 && topV.bottom < 1920 / 4 && topV.top > Int(1920 * 0.08),
              "16:9 rows \(topH.top)–\(topH.bottom), 9:16 rows \(topV.top)–\(topV.bottom)")
        show(.small); let s = bright(engine.programSnapshot(.horizontal, width: 1920))
        show(.large); let l = bright(engine.programSnapshot(.horizontal, width: 1920))
        check("engine: size L is bigger than S", (l.bottom - l.top) > (s.bottom - s.top) && l.count > s.count, "S \(s.bottom - s.top) px tall, L \(l.bottom - l.top)")
        show(ago: 3.3)
        let half = bright(engine.programSnapshot(.horizontal, width: 1920))
        check("engine: fading 3.3 s after the last words", half.maxLuma < a.maxLuma - 40 && half.maxLuma > 40, "max \(half.maxLuma)")
        show(ago: 4)
        let gone = bright(engine.programSnapshot(.horizontal, width: 1920))
        check("engine: gone after the fade", gone.count == 0 && engine.captionLines(.horizontal).isEmpty)
        show()
        _ = engine.programSnapshot(.horizontal, width: 1920)
        engine.showCaptions(nil)
        Thread.sleep(forTimeInterval: 0.4)
        let off = bright(engine.programSnapshot(.horizontal, width: 1920)), offV = bright(engine.programSnapshot(.vertical, width: 1080))
        check("engine: turned off, nothing is drawn on either canvas", off.count == 0 && offV.count == 0 && engine.captionLines(.horizontal).isEmpty)
    }

    print(failures == 0 ? "captions: all checks passed" : "captions: \(failures) failed")
    return failures == 0
}

/// Reads the text in a picture with Vision (accurate, English): one JSON object with each line found and its box
/// (0…1, top-left of the whole picture). `band` ("0.7,0.95", top-left) reads only that strip, so words elsewhere in
/// the picture (a clip with mirrored text) don't throw Vision off. The captions end-to-end test reads program
/// snapshots with it.
func ocrCheck(_ path: String?, band: String? = nil) -> Bool {
    guard let path, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print(#"{"error":"could not read the picture"}"#)
        return false
    }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ["en-US"]
    let v = band?.split(separator: ",").compactMap { Double($0) } ?? []
    let roi = v.count == 2 ? CGRect(x: 0, y: 1 - v[1], width: 1, height: v[1] - v[0]) : CGRect(x: 0, y: 0, width: 1, height: 1)
    req.regionOfInterest = roi
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    let lines: [[String: Any]] = (req.results ?? []).compactMap { o in
        guard let t = o.topCandidates(1).first else { return nil }
        // Boxes come relative to the region read: back to the whole picture, top-left.
        let b = o.boundingBox
        let y = roi.minY + b.minY * roi.height, h = b.height * roi.height
        return ["text": t.string, "confidence": t.confidence, "x": b.minX, "y": 1 - (y + h), "w": b.width, "h": h]
    }
    let out: [String: Any] = ["width": img.width, "height": img.height, "lines": lines]
    let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
    return true
}
