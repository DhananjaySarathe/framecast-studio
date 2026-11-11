// Scratch benchmark (research only, not part of the repo).
// "Voice-to-target": given the on-screen text items (as OCR would find them) and the presenter's newest words,
// which item should the live edit zoom to / highlight right now, or none?
// Compares (A) a deterministic matcher (fuzzy label match + a pointing-verb gate + a not-now veto) with
// (B) Apple's on-device model constrained to the item list (DynamicGenerationSchema anyOf), fresh session per call.
//   swiftc -O intent_bench.swift -o intent_bench && ./intent_bench
import Foundation
import FoundationModels

let items = ["General", "Appearance", "Settings", "Privacy & Security", "Notifications", "Accounts", "Storage",
             "Export", "Share", "Help", "File", "Edit", "View", "Insert", "Format", "Window",
             "Revenue growth by quarter", "42%", "Timer 00:12", "Run prompt", "Upgrade to Pro", "Save", "Discard",
             "Last updated 21 October 2026"]

// (words heard, expected item or nil). Some lines carry speech-recognition style errors on purpose.
let cases: [(String, String?)] = [
    ("now click the settings button up here", "Settings"),
    ("go into privacy and security", "Privacy & Security"),
    ("hit export", "Export"),
    ("we'll get to settings later, first let me talk about pricing", nil),
    ("see this number here, forty two percent", "42%"),
    ("okay let me set things up first", nil),
    ("and then open the share menu", "Share"),
    ("the notifications panel is where the magic happens", "Notifications"),
    ("my cat just walked across the desk, sorry", nil),
    ("watch the timer on the right", "Timer 00:12"),
    ("this chart shows revenue growth every quarter", "Revenue growth by quarter"),
    ("click on general", "General"),
    ("don't click upgrade, you don't need pro for this", nil),
    ("so I'll hit run prompt and we wait", "Run prompt"),
    ("if you ever need help just ask in the chat", nil),
    ("let's look at the appearance tab", "Appearance"),
    ("press safe to keep it", "Save"),              // ASR error: "safe" for "Save"
    ("this is the best format for beginners", nil),  // "format" said in passing
]

// ---------- (A) deterministic ----------
func norm(_ s: String) -> [String] {
    s.lowercased().replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "%", with: " percent ")
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
}
let numberWords = ["forty two": "42", "twenty one": "21", "two thousand twenty six": "2026"]
func normUtterance(_ s: String) -> [String] {
    var t = s.lowercased()
    for (k, v) in numberWords { t = t.replacingOccurrences(of: k, with: v) }
    return norm(t)
}
func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(a), y = Array(b)
    guard !x.isEmpty, !y.isEmpty else { return x == y ? 1 : 0 }
    var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
        swap(&prev, &cur)
    }
    return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
}
func same(_ a: String, _ b: String) -> Bool { a == b || (min(a.count, b.count) >= 4 && similarity(a, b) >= 0.75) }
let stop: Set<String> = ["the", "to", "by", "and", "of", "a", "on", "in"]
let pointing: Set<String> = ["click", "open", "hit", "press", "tap", "select", "into", "look", "see", "watch", "check", "this", "here", "these", "that", "go", "shows", "choose", "pick"]
let notNow = ["later", "in a minute", "next time", "don't", "do not", "won't", "never", "if you ever", "we'll get to"]

func deterministic(_ utter: String) -> String? {
    let w = normUtterance(utter)
    let lower = utter.lowercased()
    if notNow.contains(where: { lower.contains($0) }) { return nil }
    var best: (String, Double)?
    for item in items {
        let key = norm(item).filter { !stop.contains($0) }
        guard !key.isEmpty else { continue }
        // all key words (fuzzy) present, in order; also allow "42 percent" for "42%"
        var pos = 0, firstAt = -1, ok = true, exact = 0
        for k in key {
            guard let j = w[pos...].firstIndex(where: { same(k, $0) }) else { ok = false; break }
            if w[j] == k { exact += 1 }
            if firstAt < 0 { firstAt = j }
            pos = j + 1
        }
        guard ok, firstAt >= 0 else { continue }
        // a pointing word within the 4 words before the label
        let gate = w[max(0, firstAt - 4)..<firstAt].contains(where: { pointing.contains($0) })
        guard gate else { continue }
        let score = Double(key.count) + Double(exact) * 0.1
        if score > (best?.1 ?? 0) { best = (item, score) }
    }
    return best?.0
}

// ---------- (B) on-device model ----------
let instructions = """
The presenter is sharing their screen in a live video. You get the text items visible on screen and the presenter's \
newest words (from speech recognition, so they may contain errors). Pick the on-screen item the presenter is directing \
the viewer to right now: they tell the viewer to click, open, press, look at or watch it, or they present it as the thing \
being shown. Answer "none" if they mention it only in passing, talk about doing it later, tell the viewer not to use it, \
or nothing on screen matches.
"""

@MainActor
func run() async throws {
    print("Deterministic matcher")
    var detRight = 0, detFalse = 0, detMiss = 0
    var detTimes: [Double] = []
    for (u, exp) in cases {
        let t = CFAbsoluteTimeGetCurrent()
        let got = deterministic(u)
        detTimes.append(CFAbsoluteTimeGetCurrent() - t)
        let ok = got == exp
        if ok { detRight += 1 } else if got != nil && got != exp { detFalse += 1 } else { detMiss += 1 }
        print("  \(ok ? "ok   " : "WRONG")  \((got ?? "none").padding(toLength: 26, withPad: " ", startingAt: 0)) \(u)")
    }
    let dt = detTimes.sorted()[detTimes.count / 2]
    print(String(format: "  %d/%d right, %d wrong target or false trigger, %d missed; median %.3f ms", detRight, cases.count, detFalse, detMiss, dt * 1000))

    guard SystemLanguageModel.default.isAvailable else { print("on-device model not available: \(SystemLanguageModel.default.availability)"); return }
    print("\nOn-device model (context size \(SystemLanguageModel.default.contextSize) tokens)")
    let twoStep = CommandLine.arguments.contains("--two-step")
    var props: [DynamicGenerationSchema.Property] = []
    if twoStep {
        props.append(.init(name: "directingNow", description: "yes only if the newest words tell the viewer to click, open, press, look at or watch something on screen right now",
                           schema: DynamicGenerationSchema(name: "YesNo", anyOf: ["yes", "no"])))
    }
    props.append(.init(name: "target", schema: DynamicGenerationSchema(name: "Target", anyOf: items + ["none"])))
    print(twoStep ? "  (two-step schema: directingNow yes/no, then target)" : "  (one-step schema: target)")
    let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Pick", properties: props), dependencies: [])
    let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)
    let list = items.enumerated().map { "- \($0.element)" }.joined(separator: "\n")
    var right = 0, falseT = 0, miss = 0, times: [Double] = []
    for (u, exp) in cases {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm(promptPrefix: Prompt("On screen:\n\(list)\n"))
        try await Task.sleep(nanoseconds: 300_000_000)   // let prewarm land, as it would between sentences
        let t0 = Date()
        let r = try await session.respond(to: "On screen:\n\(list)\nNewest words: \(u)", schema: schema, options: options)
        let d = Date().timeIntervalSince(t0)
        let raw = try r.content.value(String.self, forProperty: "target")
        let yes = twoStep ? ((try? r.content.value(String.self, forProperty: "directingNow")) ?? "no") == "yes" : true
        let got: String? = (raw == "none" || !yes) ? nil : raw
        let ok = got == exp
        if ok { right += 1 } else if got != nil && got != exp { falseT += 1 } else { miss += 1 }
        times.append(d)
        print(String(format: "  %5.2fs %@  %@ %@", d, ok ? "ok   " : "WRONG", (got ?? "none").padding(toLength: 26, withPad: " ", startingAt: 0), u))
    }
    let s = times.sorted()
    print(String(format: "  %d/%d right, %d wrong target or false trigger, %d missed; median %.2f s, p90 %.2f s, max %.2f s",
                 right, cases.count, falseT, miss, s[s.count / 2], s[Int(Double(s.count) * 0.9)], s.last!))
}

Task { @MainActor in
    do { try await run() } catch { print("error: \(error)") }
    exit(0)
}
RunLoop.main.run()
