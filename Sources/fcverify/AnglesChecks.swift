import Foundation
import CoreMedia
import CoreImage
import FramecastEngine

/// A talk: sentences of 2–7 s, pauses of 0.3–0.9 s, now and then a 2–3 s silence; louder stretches now and then.
struct Talk {
    var segments: [(start: Double, end: Double, loud: Bool)] = []
    init(seconds: Double, seed: UInt64) {
        var r = seed
        func rand() -> Double { r = r &* 6364136223846793005 &+ 1442695040888963407; return Double(r >> 11) / Double(1 << 53) }
        var t = 0.5
        while t < seconds {
            let len = 2 + 5 * rand()
            segments.append((t, t + len, rand() < 0.2))
            t += len + (rand() < 0.12 ? 2 + rand() : 0.3 + 0.6 * rand())
        }
    }
    func voice(at t: Double) -> VoiceState {
        if let s = segments.first(where: { t >= $0.start && t < $0.end }) { return VoiceState(speaking: true, silence: 0, emphasis: s.loud) }
        // In a pause, "emphasis" still describes the phrase just spoken (as the app reports it).
        let last = segments.last(where: { $0.end <= t })
        let lastEnd = last?.end ?? 0
        return VoiceState(speaking: false, silence: t - lastEnd, emphasis: (last?.loud ?? false) && t - lastEnd < 1.5)
    }
    func inPause(_ t: Double) -> Bool { !voice(at: t).speaking }
}

/// `fcverify angles`: the camera-angle shuffle's rules, run on a simulated talk (no cameras, no AI). Each line prints
/// PASS or FAIL; the process fails if any check does.
func anglesChecks() -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(name)\(detail.isEmpty ? "" : ": \(detail)") → \(ok ? "PASS" : "FAIL")")
        if !ok { failures += 1 }
    }

    struct Run { var cuts: [(t: Double, to: String, reason: String)] = []; var planner: ShufflePlanner }
    func simulate(_ angles: [PlannerAngle], seconds: Double = 600, pace: ShufflePace = .normal, talk: Talk,
                  hint: ((Double) -> String?)? = nil, usable: ((Double, String) -> Bool)? = nil) -> Run {
        var p = ShufflePlanner(seed: 42); p.pace = pace
        var run = Run(planner: p)
        var t = 0.0
        while t < seconds {
            let list = angles.map { a -> PlannerAngle in var x = a; x.usable = usable?(t, a.id) ?? true; return x }
            if let c = run.planner.step(now: t, angles: list, voice: talk.voice(at: t), hint: hint?(t)) { run.cuts.append((t, c.to, c.reason)) }
            t += 0.1
        }
        return run
    }

    let talk = Talk(seconds: 620, seed: 7)
    let three = [PlannerAngle(id: "mac", shot: .medium, isPrimary: true), PlannerAngle(id: "side", shot: .wide), PlannerAngle(id: "close", shot: .close)]
    let run = simulate(three, talk: talk)
    let holds = zip(run.cuts, run.cuts.dropFirst()).map { $1.t - $0.t }
    let p = run.planner
    check("never holds an angle shorter than the minimum", (holds.min() ?? 99) >= p.minHold - 0.05, String(format: "shortest %.1f s (min %.1f)", holds.min() ?? 0, p.minHold))
    check("never holds an angle much past the maximum", (holds.max() ?? 0) <= p.maxHold + 2.1, String(format: "longest %.1f s (max %.1f)", holds.max() ?? 0, p.maxHold))
    let later = run.cuts.dropFirst()
    let inPauses = later.filter { talk.inPause($0.t) }.count
    check("cuts land in pauses, not mid-word", Double(inPauses) >= 0.95 * Double(later.count), "\(inPauses) of \(later.count) in a pause")
    let perMinute = Double(later.count) / 10
    check("cuts at a watchable rate (normal pace)", perMinute >= 4 && perMinute <= 12, String(format: "%.1f a minute", perMinute))
    let primary = p.share(of: "mac")
    check("the frame's own camera gets the most screen time", primary >= 0.35 && primary <= 0.65 && primary > p.share(of: "side") && primary > p.share(of: "close"),
          String(format: "mac %.0f%%, side %.0f%%, close %.0f%%", primary * 100, p.share(of: "side") * 100, p.share(of: "close") * 100))
    check("every angle gets used", ["mac", "side", "close"].allSatisfy { p.share(of: $0) >= 0.12 })
    check("never cuts to the angle already on air", zip(run.cuts, run.cuts.dropFirst()).allSatisfy { $0.to != $1.to })

    // Emphasis goes tight: of cuts made while a loud stretch was just running, most go to the close-up.
    let afterLoud = later.filter { c in talk.segments.contains { $0.loud && c.t >= $0.end && c.t < $0.end + 1.0 } }
    let tight = afterLoud.filter { $0.to == "close" }.count
    check("after a point is made loudly, the close-up is favoured", afterLoud.isEmpty || Double(tight) >= 0.4 * Double(afterLoud.count),
          "\(tight) of \(afterLoud.count)")

    // Pace: calm cuts less often than lively.
    let calm = simulate(three, pace: .calm, talk: talk).cuts.count, lively = simulate(three, pace: .lively, talk: talk).cuts.count
    check("calm cuts less often than lively", calm < run.cuts.count && run.cuts.count < lively, "calm \(calm), normal \(run.cuts.count), lively \(lively)")

    // The AI's pick is taken at the next pause once the shot has had its minimum.
    // (The run is the same as the unhinted one up to 60 s, so the pick is an angle that isn't on air then.)
    let onAirAt60 = run.cuts.last { $0.t < 60 }?.to
    let picked = ["side", "close"].first { $0 != onAirAt60 }!
    let hinted = simulate(three, seconds: 120, talk: talk, hint: { $0 >= 60 && $0 < 75 ? picked : nil })
    let firstAfter = hinted.cuts.first { $0.t >= 60 }
    check("the AI's pick goes on air at the next pause", firstAfter?.to == picked && (firstAfter.map { $0.t - 60 } ?? 99) < 9,
          firstAfter.map { String(format: "%@ after %.1f s (%@)", $0.to, $0.t - 60, $0.reason) } ?? "no cut")

    // An angle that stops sending is replaced at once, mid-sentence or not.
    let lost = simulate(three, seconds: 120, talk: talk, usable: { t, id in !(id == "close" && t >= 50) })
    let onAirAt50 = lost.cuts.last { $0.t < 50 }?.to
    let after50 = lost.cuts.first { $0.t >= 50 }
    check("an angle that stops sending is replaced at once", onAirAt50 != "close" || (after50.map { $0.t - 50 } ?? 99) < 0.25,
          "on air at 50 s: \(onAirAt50 ?? "-"), next cut \(after50.map { String(format: "%.1f s later to %@", $0.t - 50, $0.to) } ?? "none")")
    check("a lost angle never comes back on air while it's gone", !lost.cuts.contains { $0.t >= 50 && $0.to == "close" })

    // One angle: no cuts after the first.
    let single = simulate([PlannerAngle(id: "mac", isPrimary: true)], seconds: 120, talk: talk)
    check("one angle never cuts", single.cuts.count == 1)

    // Unlabelled angles still rotate fairly.
    let plain = simulate([PlannerAngle(id: "a", isPrimary: true), PlannerAngle(id: "b"), PlannerAngle(id: "c"), PlannerAngle(id: "d")], talk: talk).planner
    check("unlabelled angles all get used", ["a", "b", "c", "d"].allSatisfy { plain.share(of: $0) >= 0.1 },
          ["a", "b", "c", "d"].map { String(format: "%@ %.0f%%", $0, plain.share(of: $0) * 100) }.joined(separator: ", "))

    // The presenter turns to a phone camera (60–80 s) and back: the shuffle follows the look, holds while they talk
    // into it, and comes back when they turn back.
    var lookAngles = three
    lookAngles[0].facing = true
    var lp = ShufflePlanner(seed: 9)
    var lookCuts: [(t: Double, to: String, reason: String)] = []
    var t = 0.0
    while t < 120 {
        let turned = t >= 60 && t < 80
        let list = lookAngles.map { a -> PlannerAngle in var x = a; x.facing = a.id == "side" ? turned : (a.id == "mac" ? !turned : false); return x }
        if let c = lp.step(now: t, angles: list, voice: talk.voice(at: t)) { lookCuts.append((t, c.to, c.reason)) }
        t += 0.1
    }
    let toSide = lookCuts.first { $0.t >= 60 && $0.to == "side" }
    check("turning to a camera cuts to it", toSide.map { $0.t - 60 < 4 } ?? false,
          toSide.map { String(format: "%.1f s after the turn (%@)", $0.t - 60, $0.reason) } ?? "no cut")
    let awayWhileLooking = lookCuts.contains { $0.t > (toSide?.t ?? 60) + 0.05 && $0.t < 80 }
    check("stays on the camera they talk into", !awayWhileLooking)
    let back = lookCuts.first { $0.t >= 80 }
    check("turning back cuts back to the frame's own camera", back.map { $0.to == "mac" && $0.t - 80 < 4 } ?? false,
          back.map { String(format: "%@ %.1f s after (%@)", $0.to, $0.t - 80, $0.reason) } ?? "no cut")

    // The 30° rule: two medium angles 10° apart look alike; the shuffle cuts between them far less than to a
    // medium angle 45° away.
    let alike = simulate([PlannerAngle(id: "a", shot: .medium, isPrimary: true, yaw: 0), PlannerAngle(id: "b", shot: .medium, yaw: 10),
                          PlannerAngle(id: "c", shot: .medium, yaw: 45)], talk: talk)
    let pairs = zip(alike.cuts, alike.cuts.dropFirst())
    let jumps = pairs.filter { Set([$0.to, $1.to]) == Set(["a", "b"]) }.count, real = pairs.filter { Set([$0.to, $1.to]) == Set(["a", "c"]) }.count
    check("avoids cuts between angles that look alike (30° rule)", jumps * 3 < real, "a↔b \(jumps), a↔c \(real)")

    // A wide shot comes round now and then.
    let wides = run.cuts.filter { $0.to == "side" }.map(\.t)
    let wideGaps = zip(wides, wides.dropFirst()).map { $1 - $0 }
    check("a wide shot at least every 45 s or so", (wideGaps.max() ?? 999) <= 45, String(format: "longest gap %.0f s", wideGaps.max() ?? 0))

    // Lining up a phone's sound: the same voice, quieter, noisier and 173 ms later, stamped in 10 ms blocks with
    // arrival jitter, comes out at 173 ms; unrelated sound gives no answer.
    func voice(seconds: Double, seed: UInt64) -> [Float] {
        var r = seed
        func rand() -> Double { r = r &* 6364136223846793005 &+ 1442695040888963407; return Double(r >> 11) / Double(1 << 53) }
        var out = [Float](repeating: 0, count: Int(seconds * 48000))
        var i = 0
        while i < out.count {
            let syl = Int((0.12 + 0.2 * rand()) * 48000), amp = Float(0.1 + 0.4 * rand())
            for k in 0..<syl where i + k < out.count {
                let env = Float(sin(Double.pi * Double(k) / Double(syl)))
                out[i + k] = amp * env * Float(rand() * 2 - 1)
            }
            i += syl + Int((rand() < 0.15 ? 0.4 + 0.5 * rand() : 0.04 + 0.1 * rand()) * 48000)
        }
        return out
    }
    func feed(_ add: (UnsafePointer<Float>, Int, CMTime) -> Void, _ mono: [Float], start: Double, gain: Float, noise: Float, jitter: Double, seed: UInt64) {
        var r = seed
        func rand() -> Double { r = r &* 2862933555777941757 &+ 3037000493; return Double(r >> 11) / Double(1 << 53) }
        var i = 0
        while i + 480 <= mono.count {
            var block = [Float](repeating: 0, count: 960)
            for k in 0..<480 {
                let echo = i + k >= 2400 ? mono[i + k - 2400] * 0.35 : 0
                let v = (mono[i + k] + echo) * gain + noise * Float(rand() * 2 - 1)
                block[k * 2] = v; block[k * 2 + 1] = v
            }
            let pts = CMTime(seconds: start + Double(i) / 48000 + (rand() * 2 - 1) * jitter, preferredTimescale: 1_000_000)
            block.withUnsafeBufferPointer { add($0.baseAddress!, 480, pts) }
            i += 480
        }
    }
    let speech = voice(seconds: 14, seed: 3)
    let aligner = SoundAligner()
    feed({ aligner.addReference($0, frames: $1, pts: $2) }, speech, start: 1000, gain: 1, noise: 0.002, jitter: 0, seed: 1)
    feed({ aligner.addOther($0, frames: $1, pts: $2) }, speech, start: 1000.173, gain: 0.3, noise: 0.004, jitter: 0.003, seed: 2)
    let found = aligner.estimate()
    check("lines up a phone's sound to within 5 ms", found.map { abs($0.laterMs - 173) <= 5 && $0.confidence >= 0.5 } ?? false,
          found.map { String(format: "%.1f ms (confidence %.2f, %.1f s of speech)", $0.laterMs, $0.confidence, $0.speechSeconds) } ?? "no answer")
    let unrelated = SoundAligner()
    feed({ unrelated.addReference($0, frames: $1, pts: $2) }, speech, start: 1000, gain: 1, noise: 0.002, jitter: 0, seed: 1)
    feed({ unrelated.addOther($0, frames: $1, pts: $2) }, voice(seconds: 14, seed: 77), start: 1000.1, gain: 0.5, noise: 0.004, jitter: 0.003, seed: 5)
    let none = unrelated.estimate()
    check("gives no confident answer for unrelated sound", (none?.confidence ?? 0) < 0.3, none.map { String(format: "%.0f ms at confidence %.2f", $0.laterMs, $0.confidence) } ?? "no answer")

    // A phone held upright sends a sideways frame tagged "turn 90° clockwise": a mark at the frame's top-left must
    // end up top-right once it's turned upright (Core Image's origin is bottom-left).
    let wide = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
    let mark = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 80, width: 10, height: 10))
    let turned = mark.composited(over: wide).rotatedUpright(90)
    let ctx = CIContext()
    var px = [UInt8](repeating: 0, count: 4)
    let e = turned.extent
    ctx.render(turned, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: e.maxX - 5, y: e.maxY - 5, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
    check("an upright phone's frame turns the right way", e.width == 90 && e.height == 160 && px[0] > 200,
          "\(Int(e.width))×\(Int(e.height)), top-right \(px[0] > 200 ? "marked" : "empty")")

    print(failures == 0 ? "All angle checks passed." : "\(failures) angle check(s) failed.")
    return failures == 0
}
