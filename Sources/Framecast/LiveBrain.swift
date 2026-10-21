import Foundation
import NaturalLanguage
import FramecastEngine

/// What the live brain answers every few seconds.
struct BrainDecision: Decodable, Equatable {
    var topic: Int            // 1-based topic the presenter is on now
    var covered: [String]     // points covered, as "topic.point" ("2.3")
    var action: String        // hold | look | asset | end_asset
    var look: String
    var asset: String
    var reason: String
    var confidence: Double
}

/// The show as the guards see it, on the show clock (seconds since listening started).
struct BrainState {
    var topic: Int?
    var covered: Set<String> = []
    var look = ""                 // scene on air
    var asset: String?            // asset on air (only while an asset look is on air)
    var lastLookChange = -1e9, lastAssetChange = -1e9, lastSwitch = -1e9
    var autoTimes: [Double] = []
    var pausedUntil = -1e9
    /// The asset look used last, so assets coming up from a camera shot take turns: circle, square, full screen.
    var lastAssetLook = ""
}

/// A change the guards allowed.
enum BrainAction: Equatable {
    case look(String)
    case asset(String, look: String)
    var look: String { switch self { case .look(let l): l; case .asset(_, let l): l } }
}

/// The live brain for topic shows. Every few seconds while the presenter talks it sends a small model (Claude
/// Haiku or OpenAI's fast model, on the presenter's key) the outline, what's on air and the last 90 seconds of
/// speech, and gets back the topic, the points covered and at most one visual change. The outline part of the
/// prompt is the same on every call, so it's cached. Framecast's guards decide whether a change goes on air:
/// confident answers only, a look stays at least 20 s (8 s when the topic changes), an asset at least 8 s, nothing
/// within 3 s of any switch, at most six automatic changes a minute, and none for 30 s after a switch by hand.
enum LiveBrain {
    static let interval = 6.0
    static let window = 90.0

    static func defaultModel(_ p: AIProvider) -> String { p == .claude ? "claude-haiku-5-5" : "gpt-6-luna" }
    /// $ per million tokens: input, cached input, output (only for the default fast models).
    static func prices(_ model: String) -> (Double, Double, Double)? {
        ["claude-haiku-5-5": (0.10, 0.01, 0.50), "gpt-6-luna": (0.10, 0.01, 0.50)][model]
    }

    // MARK: Prompt

    static func system(show: ShowRundown, looks: [Looks.Look]) -> String {
        var s = """
        You direct a live, one-person video show in Framecast. Every few seconds you get what the presenter just \
        said and what's on screen, and you decide three things:
        1. topic: which topic of the outline they're on now (its number).
        2. covered: the points they have now covered, as "topic.point" (for example "2.3"); only points clearly \
        talked about.
        3. action, at most one change to what viewers see:
           - "asset": put an asset on screen because the presenter is talking about what it shows, or says they're \
        showing something. Name it in "asset" and pick an asset look in "look" (or leave "look" empty).
           - "end_asset": the presenter has moved on from the asset on screen; name a camera or screen look in "look".
           - "look": change the camera look, to keep the show lively about every 30 to 90 seconds of talk, or when \
        the topic changes. Pick a look that fits what they're doing: camera looks while they talk to the audience, \
        screen looks when they talk about their screen, the closing look for the goodbye.
           - "hold": change nothing. Choose this when unsure, mid-thought, or when nothing new is happening.
        Never pick the look that's already on air. Give "confidence" from 0 to 1 and a short "reason".
        The presenter doesn't follow the outline in order: they jump between topics, so pick the topic that matches \
        what they're talking about now, whichever number it is.
        The text comes from live speech recognition and has errors; the newest words may still change. The \
        presenter may speak Hinglish (Hindi and English mixed). Sometimes you also get the same speech recognised \
        as Hindi: use whichever version makes sense for each part.

        """
        s += "Outline:\n"
        for (i, t) in show.topics.enumerated() {
            s += "\(i + 1). \(t.title)\(t.look.isEmpty ? "" : " (suggested look: \(t.look))")\n"
            for (j, p) in t.points.enumerated() { s += "   \(i + 1).\(j + 1) \(p)\n" }
            if !t.assets.isEmpty { s += "   assets: \(t.assets.joined(separator: ", "))\n" }
            if !t.notes.isEmpty { s += "   notes: \(t.notes)\n" }
        }
        s += "\nAssets:\n" + (show.assets.isEmpty ? "(none)\n" : show.assets.map { "- \($0.file): \($0.about)\n" }.joined())
        s += "\nLooks:\n" + looks.map { "- \($0.name): \($0.about)\n" }.joined()
        return s
    }

    static func user(state: BrainState, now: Double, show: ShowRundown, heard: [(t: Double, text: String)], guess: String,
                     changes: [(t: Double, text: String)], hindi: [(t: Double, text: String)] = []) -> String {
        func clock(_ s: Double) -> String { Studio.chapterTime(max(0, s)) }
        let topic = state.topic.map { "\($0 + 1) (\(show.topics[$0].title))" } ?? "not started"
        var u = "Show time \(clock(now)). On air: \(state.look.isEmpty ? "unknown" : state.look) for \(Int(now - max(0, state.lastLookChange))) s."
        u += state.asset.map { " Asset on screen: \($0) for \(Int(now - state.lastAssetChange)) s." } ?? " No asset on screen."
        u += "\nCurrent topic: \(topic). Covered so far: \(state.covered.isEmpty ? "none" : state.covered.sorted().joined(separator: ", "))."
        if !changes.isEmpty { u += "\nRecent changes: " + changes.suffix(4).map { "\(clock($0.t)) \($0.text)" }.joined(separator: "; ") + "." }
        u += "\n\nWhat the presenter said in the last \(Int(window)) seconds, oldest first:\n"
        u += heard.filter { $0.t >= now - window }.map { "[\(clock($0.t))] \($0.text)" }.joined(separator: "\n")
        if !guess.isEmpty { u += "\n[now, still being recognised] \(guess)" }
        let hi = hindi.filter { $0.t >= now - window }
        if !hi.isEmpty {
            u += "\n\nThe same speech recognised as Hindi:\n" + hi.map { "[\(clock($0.t))] \($0.text)" }.joined(separator: "\n")
        }
        return u
    }

    static func schema(show: ShowRundown, looks: [Looks.Look]) -> [String: Any] {
        let str: [String: Any] = ["type": "string"]
        return ["type": "object", "additionalProperties": false,
                "required": ["topic", "covered", "action", "look", "asset", "reason", "confidence"],
                "properties": [
                    "topic": ["type": "integer"],
                    "covered": ["type": "array", "items": str],
                    "action": ["type": "string", "enum": ["hold", "look", "asset", "end_asset"]],
                    "look": ["type": "string", "enum": [""] + looks.map(\.name)],
                    "asset": ["type": "string", "enum": [""] + show.assets.map(\.file)],
                    "reason": str, "confidence": ["type": "number"],
                ]]
    }

    // MARK: Calling the model

    struct Answer { var decision: BrainDecision; var cost: Double?; var tokens: Int; var seconds: Double }

    static func ask(provider: AIProvider, model: String, key: String, system: String, user: String, schema: [String: Any]) async throws -> Answer {
        let t0 = Date()
        let base = ScriptWriter.baseOverride
        var req: URLRequest
        let body: [String: Any]
        if provider == .claude {
            req = URLRequest(url: URL(string: (base ?? "https://api.anthropic.com") + "/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 1_500,
                    "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
                    "messages": [["role": "user", "content": user]],
                    "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]]]
        } else {
            req = URLRequest(url: URL(string: (base ?? "https://api.openai.com") + "/v1/responses")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var b: [String: Any] = ["model": model, "max_output_tokens": 1_500,
                    "input": [["role": "system", "content": system], ["role": "user", "content": user]],
                    "text": ["format": ["type": "json_schema", "name": "decision", "strict": true, "schema": schema]]]
            // Reasoning models default to medium effort, which took 4–10 s a call live; low keeps answers inside the
            // 8 s a decision stays useful. (Other models reject the parameter.)
            if ["gpt-5", "gpt-6", "o"].contains(where: model.hasPrefix) { b["reasoning"] = ["effort": "low"] }
            body = b
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw ScriptWriter.failure("\(provider.company) \(status == 401 || status == 403 ? "didn't accept the API key" : "answered \(status)")\(msg.map { ": \($0)" } ?? "")")
        }
        var text = "", inTok = 0, cached = 0, written = 0, outTok = 0
        if provider == .claude {
            text = (obj["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let u = obj["usage"] as? [String: Any] ?? [:]
            inTok = u["input_tokens"] as? Int ?? 0; outTok = u["output_tokens"] as? Int ?? 0
            cached = u["cache_read_input_tokens"] as? Int ?? 0; written = u["cache_creation_input_tokens"] as? Int ?? 0
        } else {
            for item in obj["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for c in item["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "output_text" { text += c["text"] as? String ?? "" }
            }
            let u = obj["usage"] as? [String: Any] ?? [:]
            let all = u["input_tokens"] as? Int ?? 0
            cached = (u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            inTok = all - cached; outTok = u["output_tokens"] as? Int ?? 0
        }
        guard let d = try? JSONDecoder().decode(BrainDecision.self, from: Data(text.utf8)) else { throw ScriptWriter.failure("The model's answer couldn't be read.") }
        let cost = prices(model).map { p in
            (Double(inTok) * p.0 + Double(cached) * p.1 + Double(written) * p.0 * 1.25 + Double(outTok) * p.2) / 1_000_000
        }
        return Answer(decision: d, cost: cost, tokens: inTok + cached + written + outTok, seconds: Date().timeIntervalSince(t0))
    }

    // MARK: Guards

    /// Applies the outline part of a decision to `state` and returns the visual change the guards allow, or why not.
    static func plan(_ d: BrainDecision, state s: inout BrainState, now: Double, show: ShowRundown, looks: [Looks.Look],
                     settings: DirectorSettings, assetExists: (String) -> Bool) -> (BrainAction?, String?) {
        var topicChanged = false
        if show.topics.indices.contains(d.topic - 1), d.topic - 1 != s.topic { s.topic = d.topic - 1; topicChanged = true }
        for id in d.covered {
            let p = id.split(separator: ".").compactMap { Int($0) }
            if p.count == 2, show.topics.indices.contains(p[0] - 1), show.topics[p[0] - 1].points.indices.contains(p[1] - 1) { s.covered.insert(id) }
        }
        guard d.action != "hold" else { return (nil, nil) }
        guard d.confidence >= 0.55 else { return (nil, "not sure enough") }
        if s.pausedUntil > now { return (nil, "paused after your switch") }
        if now - s.lastSwitch < settings.minShotSeconds { return (nil, "too soon after the last switch") }
        s.autoTimes = s.autoTimes.filter { $0 > now - 60 }
        if s.autoTimes.count >= 6 { return (nil, "six automatic changes in the last minute") }
        let byName = Dictionary(looks.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let onAsset = byName[s.look]?.isAsset ?? false
        switch d.action {
        case "asset":
            guard assetExists(d.asset) else { return (nil, "no asset called \(d.asset)") }
            if d.asset == s.asset { return (nil, nil) }
            if s.asset != nil, now - s.lastAssetChange < settings.assetHoldSeconds { return (nil, "the asset on screen is new") }
            let look: String
            if let l = byName[d.look], l.isAsset { look = l.name }
            else if onAsset { look = s.look }
            else {
                // The presenter stays in view: circle and square take turns; "Asset full" only when asked for.
                let all = Looks.boxedAssetLooks.filter { byName[$0] != nil }
                let i = all.firstIndex(of: s.lastAssetLook).map { ($0 + 1) % max(all.count, 1) } ?? 0
                look = all.isEmpty ? Looks.circle : all[i]
            }
            guard byName[look] != nil else { return (nil, "no asset look") }
            return (.asset(d.asset, look: look), nil)
        case "end_asset", "look":
            if d.action == "end_asset" && s.asset == nil { return (nil, nil) }
            if d.action == "end_asset", now - s.lastAssetChange < settings.assetHoldSeconds { return (nil, "the asset on screen is new") }
            let hold = topicChanged ? 8 : settings.lookHoldSeconds
            if d.action == "look", now - s.lastLookChange < hold { return (nil, "the look on air is new") }
            var target = byName[d.look]
            if target?.isAsset == true && s.asset == nil { target = nil }
            if d.action == "end_asset", target == nil || target!.isAsset {
                let topicLook = s.topic.flatMap { byName[show.topics[$0].look] }
                target = (topicLook?.isAsset == false ? topicLook : nil) ?? looks.first { !$0.isAsset && $0.name != s.look }
            }
            guard let t = target, t.name != s.look else { return (nil, nil) }
            return (.look(t.name), nil)
        default:
            return (nil, nil)
        }
    }

    /// Records an allowed change in `state`.
    static func commit(_ a: BrainAction, state s: inout BrainState, now: Double, looks: [Looks.Look]) {
        let wasAsset = s.asset
        switch a {
        case .asset(let f, let look): s.asset = f; s.lastAssetChange = now; if look != s.look { s.lastLookChange = now }; s.look = look; s.lastAssetLook = look
        case .look(let l): s.look = l; s.lastLookChange = now; if !(looks.first { $0.name == l }?.isAsset ?? false) { s.asset = nil }
        }
        if wasAsset != s.asset { s.lastAssetChange = now }
        s.lastSwitch = now
        s.autoTimes.append(now)
    }

    static func describe(_ a: BrainAction) -> String {
        switch a { case .look(let l): "look → \(l)"; case .asset(let f, let l): "asset \(f) on \(l)" }
    }

    // MARK: Following topics on this Mac (no model)

    /// Without a model (no key, offline): finished sentences move the outline on by meaning and tick off points.
    static func followLocally(_ sentence: String, state s: inout BrainState, show: ShowRundown) {
        guard let e = NLEmbedding.sentenceEmbedding(for: .english), !show.topics.isEmpty else { return }
        let cur = s.topic ?? 0
        func d(_ a: String) -> Double { e.distance(between: sentence, and: a, distanceType: .cosine) }
        func topicText(_ i: Int) -> String { ([show.topics[i].title] + show.topics[i].points).joined(separator: ". ") }
        // Any topic can come next (the presenter jumps around): move to the closest one if it's clearly closer.
        let here = d(topicText(cur))
        if let best = show.topics.indices.filter({ $0 != cur }).map({ ($0, d(topicText($0))) }).min(by: { $0.1 < $1.1 }),
           best.1 < min(0.9, here - 0.1) {
            s.topic = best.0
        }
        let t = s.topic ?? 0
        for (j, p) in show.topics[t].points.enumerated() where d(p) < 0.75 { s.covered.insert("\(t + 1).\(j + 1)") }
    }
}
