// Apple's on-device model (Foundation Models) as the director's advisor: free, offline, nothing leaves the Mac.
// For every sentence of both test talks it decides "switch to scene X" or "hold", with the answer constrained to a
// schema (scene names are an enum, so it cannot invent one), and reports accuracy and time per decision.
//
//   swiftc -O main.swift -o director-local && ./director-local
import Foundation
import FoundationModels

let instructions = """
You are the live director of a video show. You get the scene on air, the previous sentence and the newest sentence \
the presenter said. Decide whether to switch scene now. Hold unless the newest sentence is one of these cues:
- the presenter is about to show a chart, benchmark results or numbers → "Screen + camera"
- the presenter brings up their screen or compares things side by side → "Split"
- the presenter turns to the audience to ask which to choose or to give the verdict → "Camera"
- the presenter says goodbye or thanks for watching → "Outro"
Promising to show something later is not a cue. Sentences come from speech recognition and may contain errors.
"""
let scenes = ["Camera", "Screen + camera", "Split", "Outro"]

// (sentence, expected scene or nil for hold)
let talks: [(String, [(String, String?)])] = [
    ("scripted", [
        ("Hey everyone, welcome back.", nil),
        ("Today it's Claude Opus 5.5 against Claude Sonnet 5.5.", nil),
        ("Let's start with the prize, because that surprises people.", nil),
        ("Opus costs four dollars per million input tokens, and Sonnet costs two dollars.", nil),
        ("Now let me show you the benchmark chart.", "Screen + camera"),
        ("On the coding test, OPA solved more tasks, but Sonnet was almost twice as fast.", nil),
        ("Let me switch to my screen and run the same prompt on both models.", "Split"),
        ("Watch the timer on the right.", nil),
        ("Sonnet finished first.", nil),
        ("Okay, so which one should you pick?", "Camera"),
        ("If speed matters, go with Sonnet.", nil),
        ("If quality matters most, pick Opus.", nil),
        ("That's it for today, thanks for watching, see you next time.", "Outro"),
    ]),
    ("ad-libbed", [
        ("Hey folks, good to see you.", nil),
        ("So today it's Opus versus Sonnet, the five point five versions.", nil),
        ("Quick heads up, I'll put a chart up in a minute, but first, the price.", nil),
        ("Opus is four dollars per million input tokens and Sonnet is two.", nil),
        ("Okay, here are the benchmark numbers.", "Screen + camera"),
        ("On coding, Opus solved more tasks, though Sonnet was nearly twice as quick.", nil),
        ("By the way, my cat just walked across the desk, sorry about that.", nil),
        ("Let me bring up my screen and run one prompt on both.", "Split"),
        ("Sonnet came back first.", nil),
        ("So, which should you go for?", "Camera"),
        ("If you need speed, Sonnet.", nil),
        ("If you need the best answers, Opus.", nil),
        ("Alright, that's all for today, thanks so much for watching.", "Outro"),
    ]),
]

let decision = DynamicGenerationSchema(name: "Decision", properties: [
    .init(name: "action", schema: DynamicGenerationSchema(name: "Action", anyOf: ["switch", "hold"])),
    .init(name: "scene", description: "scene to switch to; ignored when holding",
          schema: DynamicGenerationSchema(name: "Scene", anyOf: scenes)),
])

@MainActor
func run() async throws {
    guard SystemLanguageModel.default.isAvailable else { print("on-device model not available: \(SystemLanguageModel.default.availability)"); exit(1) }
    let schema = try GenerationSchema(root: decision, dependencies: [])
    let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 40)
    var times: [Double] = [], right = 0, total = 0
    for (name, lines) in talks {
        print("\n\(name) talk")
        var onAir = "Camera", previous = "(show start)"
        for (line, expected) in lines {
            let session = LanguageModelSession(instructions: instructions)   // fresh and stateless per decision
            let prompt = "On air: \(onAir)\nPrevious: \(previous)\nNewest: \(line)"
            let t0 = Date()
            let r = try await session.respond(to: prompt, schema: schema, options: options)
            let dt = Date().timeIntervalSince(t0)
            let action = try r.content.value(String.self, forProperty: "action")
            let scene = try? r.content.value(String.self, forProperty: "scene")
            let got: String? = action == "switch" && scene != onAir ? scene : nil
            let ok = got == expected
            times.append(dt); total += 1; right += ok ? 1 : 0
            if let got { onAir = got }
            print(String(format: "%5.2fs  %@  %-16@ %@", dt, ok ? "ok   " : "WRONG", got ?? "hold", String(line.prefix(64))))
            previous = line
        }
    }
    let s = times.sorted()
    print(String(format: "\n%d/%d decisions right; time per decision median %.2f s, p90 %.2f s, max %.2f s",
                 right, total, s[s.count / 2], s[Int(Double(s.count) * 0.9)], s.last!))
}

Task { @MainActor in
    do { try await run() } catch { print("error: \(error)") }
    exit(0)
}
RunLoop.main.run()
