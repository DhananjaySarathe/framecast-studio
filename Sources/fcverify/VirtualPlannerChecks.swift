import Foundation
import FramecastEngine

/// `fcverify virtual`, group D: the shuffle with a medium and a close-up cut from one camera, on the same simulated
/// talk (seed 7) and planner seed (42) as `fcverify angles`.
func virtualPlannerChecks(_ report: (String, Bool, String) -> Void) {
    typealias Cuts = [(t: Double, to: String, reason: String)]
    let talk = Talk(seconds: 620, seed: 7)
    let w = PlannerAngle(id: "W", shot: .wide, isPrimary: true, yaw: 0)
    let m = PlannerAngle(id: "M", shot: .medium, yaw: 0, camera: "W")
    let c = PlannerAngle(id: "C", shot: .close, yaw: 0, camera: "W")
    let v = [w, m, c]

    func simulate(_ angles: [PlannerAngle], seconds: Double = 600, pace: ShufflePace = .normal,
                  facing: ((Double, String) -> Bool)? = nil) -> (cuts: Cuts, planner: ShufflePlanner) {
        var p = ShufflePlanner(seed: 42); p.pace = pace
        var cuts: Cuts = []
        var t = 0.0
        while t < seconds {
            let list = angles.map { a -> PlannerAngle in var x = a; x.facing = facing?(t, a.id) ?? a.facing; return x }
            if let cut = p.step(now: t, angles: list, voice: talk.voice(at: t)) { cuts.append((t, cut.to, cut.reason)) }
            t += 0.1
        }
        return (cuts, p)
    }
    func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
    /// Each cut after the first, as the pair of angles it joins.
    func joins(_ cuts: Cuts) -> [Set<String>] { zip(cuts, cuts.dropFirst()).map { Set([$0.to, $1.to]) } }

    let run = simulate(v)
    let p = run.planner
    let shares = v.map { p.share(of: $0.id) }
    report("D1 every angle gets at least 12%; the wide gets 35–65% and the most",
           shares.allSatisfy { $0 >= 0.12 } && shares[0] >= 0.35 && shares[0] <= 0.65 && shares[0] > shares[1] && shares[0] > shares[2],
           "W \(pct(shares[0])), M \(pct(shares[1])), C \(pct(shares[2]))")

    let pairs = joins(run.cuts), mc = Set(["M", "C"])
    let inCamera = pairs.filter { $0 == mc }.count
    let twice = zip(pairs, pairs.dropFirst()).contains { $0 == mc && $1 == mc }
    report("D2 medium ↔ close-up at most 25% of cuts, never two in a row", Double(inCamera) <= 0.25 * Double(pairs.count) && !twice,
           "\(inCamera) of \(pairs.count)\(twice ? ", two in a row" : "")")

    let later = run.cuts.dropFirst()
    let perMinute = Double(later.count) / 10
    let calm = simulate(v, pace: .calm).cuts.count, lively = simulate(v, pace: .lively).cuts.count
    let inPauses = later.filter { talk.inPause($0.t) }.count
    let holds = zip(run.cuts, run.cuts.dropFirst()).map { $1.t - $0.t }
    report("D3 3–9 cuts a minute; calm < normal < lively; 95% in pauses; holds within the bounds",
           perMinute >= 3 && perMinute <= 9 && calm < run.cuts.count && run.cuts.count < lively && Double(inPauses) >= 0.95 * Double(later.count)
               && (holds.min() ?? 99) >= p.minHold - 0.05 && (holds.max() ?? 0) <= p.maxHold + 2.1,
           String(format: "%.1f a minute; calm %d, normal %d, lively %d; %d of %d in a pause; holds %.1f–%.1f s",
                  perMinute, calm, run.cuts.count, lively, inPauses, later.count, holds.min() ?? 0, holds.max() ?? 0))

    // Every punch-in returns to the wide, so about half the cuts start on a crop; a cut from the close-up can't go to
    // it, so only cuts from the wide or the medium count.
    let afterLoud = zip(run.cuts, run.cuts.dropFirst())
        .filter { from, cut in from.to != "C" && talk.segments.contains { $0.loud && cut.t >= $0.end && cut.t < $0.end + 1.0 } }.map(\.1)
    let tight = afterLoud.filter { $0.to == "C" }.count
    report("D4 after a loud stretch, at least 40% of the cuts that can go to the close-up do", !afterLoud.isEmpty && Double(tight) >= 0.4 * Double(afterLoud.count),
           "\(tight) of \(afterLoud.count)")

    let wides = run.cuts.filter { $0.to == "W" }.map(\.t)
    let gap = zip(wides, wides.dropFirst()).map { $1 - $0 }.max() ?? 999
    report("D5 the wide comes round at least every 45 s", gap <= 45, String(format: "longest gap %.0f s", gap))

    // The presenter turns to a phone and back three times. Mac crops are wrongly reported as faced whenever the Mac
    // camera is: the shuffle must still never cut on the look to a crop, and turning back goes to the wide.
    let phone = PlannerAngle(id: "P", shot: .medium, yaw: 40)
    let turns: [(Double, Double)] = [(60, 80), (200, 215), (400, 430)]
    func turned(_ t: Double) -> Bool { turns.contains { t >= $0.0 && t < $0.1 } }
    let look = simulate([phone] + v, facing: { t, id in id == "P" ? turned(t) : !turned(t) }).cuts
    let toCrop = look.filter { ($0.to == "M" || $0.to == "C") && ($0.reason == "you turned to it" || $0.reason == "you turned back") }
    let followed = turns.map { turn -> (Double?, Double?) in
        // Already on the phone when they turn to it counts as following at once.
        let onAir = look.last { $0.t < turn.0 }?.to
        let out = onAir == "P" ? 0 : look.first { $0.t >= turn.0 && $0.to == "P" }.map { $0.t - turn.0 }
        let back = look.first { $0.t >= turn.1 }.flatMap { $0.to == "W" ? $0.t - turn.1 : nil }
        return (out, back)
    }
    report("D6 never a look cut to a crop; turning back from the phone cuts to the wide within 4 s",
           toCrop.isEmpty && followed.allSatisfy { ($0.0 ?? 99) < 4 && ($0.1 ?? 99) < 4 },
           "\(toCrop.count) look cuts to a crop; " + followed.map { String(format: "out %@, back %@", $0.0.map { String(format: "%.1f s", $0) } ?? "none",
                                                                             $0.1.map { String(format: "%.1f s", $0) } ?? "none") }.joined(separator: "; "))

    let withPhone = simulate([phone] + v)
    let phonePairs = joins(withPhone.cuts)
    let macOnly = phonePairs.filter { !$0.contains("P") }.count
    report("D7 with a phone: the phone gets at least 12%, cuts within the Mac camera at most 60%",
           withPhone.planner.share(of: "P") >= 0.12 && Double(macOnly) <= 0.6 * Double(phonePairs.count),
           "phone \(pct(withPhone.planner.share(of: "P"))), \(macOnly) of \(phonePairs.count) within the Mac camera")

    var softC = c; softC.quality = 2
    let soft = simulate([w, m, softC]).planner.share(of: "C"), sharp = shares[2]
    report("D8 a soft close-up (quality 2) gets less screen time", soft < sharp, "quality 2 \(pct(soft)), quality 3 \(pct(sharp))")

    let again = simulate(v).cuts
    report("D9 the same seed gives the same cuts", again.count == run.cuts.count && zip(again, run.cuts).allSatisfy { $0.t == $1.t && $0.to == $1.to && $0.reason == $1.reason },
           "\(run.cuts.count) cuts")
}
