import Foundation

/// The AI service that writes rundowns from a rough script. The user brings their own API key; the request
/// carries only the script, the show title and the studio's scene names.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case claude, openai
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude (Anthropic)" : "OpenAI" }
    var company: String { self == .claude ? "Anthropic" : "OpenAI" }
    var defaultModel: String { self == .claude ? "claude-opus-5-5" : "gpt-6-astra" }
    var keyHint: String { self == .claude ? "sk-ant-…" : "sk-…" }
    var keyPage: URL { URL(string: self == .claude ? "https://platform.claude.com/settings/keys" : "https://platform.openai.com/api-keys")! }
}

/// API keys live in the login Keychain. Automated test launches use their own items, and a test launch pointed at
/// the stand-in server (FRAMECAST_AI_BASE_URL) uses FRAMECAST_AI_TEST_KEY instead, so tests never touch the Keychain.
/// Reading can make macOS ask for Keychain access (after a rebuild), so callers read off the main thread.
enum AIKeys {
    static let service = CollectionStore.profile == "default" ? "Framecast AI keys" : "Framecast AI keys (tests)"
    private static var testKey: String? { ScriptWriter.baseOverride == nil ? nil : ProcessInfo.processInfo.environment["FRAMECAST_AI_TEST_KEY"] }
    static func has(_ p: AIProvider) -> Bool { testKey != nil || SecretStore.exists(service: service, account: p.rawValue) }
    static func get(_ p: AIProvider) -> String? { testKey ?? SecretStore.get(service: service, account: p.rawValue) }
    /// The key, read off the main thread.
    static func load(_ p: AIProvider) async -> String? { await Task.detached { get(p) }.value }
    static func set(_ p: AIProvider, _ key: String) { SecretStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), service: service, account: p.rawValue) }
}

struct WrittenRundown { var title: String; var parts: [RundownPart]; var aliases: [WordAlias] }

enum ScriptWriter {
    static let instructions = """
    You prepare rundowns for Framecast, a Mac app for live streams and recordings. The presenter gives you a rough \
    script. Split it into the parts of the show, in order. Start a new part only where the scene on air should change.

    For each part:
    - title: two to four words.
    - scene: one of the scene names you are given, exactly as written. Use a camera scene while the presenter talks \
    to the audience, a scene with the screen while they show something on it (a chart, a demo, slides, a website), and \
    a closing scene for the goodbye.
    - cue: the words the presenter will say at the moment this part should start, usually the start of the part's \
    first sentence, taken from the script: three to nine words, lower case, no punctuation. Leave it empty for the \
    first part, which the presenter starts by hand.
    - alsoAccept: up to six other natural ways a presenter might say the cue out loud at that moment. Don't mention \
    scene names or the app.
    - notes: the script text of this part, unchanged.

    aliases: names and technical words in the script that live speech recognition is likely to mishear, each with a \
    likely mishearing (for example heard "opa", meant "opus"). Leave it empty if nothing stands out.

    Keep to what the script says; don't add content or facts.
    """

    static func prompt(script: String, title: String, scenes: [String]) -> String {
        "Show title: \(title)\n\nScenes in the studio:\n\(scenes.map { "- \($0)" }.joined(separator: "\n"))\n\nScript:\n\(script)"
    }

    /// JSON Schema for the answer. Scene names are an enum, so the AI can only pick scenes that exist.
    static func schema(scenes: [String]) -> [String: Any] {
        let str: [String: Any] = ["type": "string"]
        let part: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["title": str, "scene": ["type": "string", "enum": scenes], "cue": str,
                           "alsoAccept": ["type": "array", "items": str], "notes": str],
            "required": ["title", "scene", "cue", "alsoAccept", "notes"],
        ]
        let alias: [String: Any] = ["type": "object", "additionalProperties": false,
                                    "properties": ["heard": str, "meant": str], "required": ["heard", "meant"]]
        return ["type": "object", "additionalProperties": false,
                "properties": ["title": str, "parts": ["type": "array", "items": part], "aliases": ["type": "array", "items": alias]],
                "required": ["title", "parts", "aliases"]]
    }

    /// Test launches only: send requests to a stand-in server on this Mac instead of the real service.
    static var baseOverride: String? {
        let env = ProcessInfo.processInfo.environment
        return env["FRAMECAST_UI"] == nil ? nil : env["FRAMECAST_AI_BASE_URL"]
    }

    /// Writes a rundown. `progress` gets short status lines on the main queue.
    static func write(script: String, title: String, scenes: [String], provider: AIProvider, model: String, key: String,
                      progress: @escaping (String) -> Void) async throws -> WrittenRundown {
        let user = prompt(script: script, title: title, scenes: scenes)
        let json = provider == .claude
            ? try await claude(user: user, scenes: scenes, model: model, key: key, progress: progress)
            : try await openAI(user: user, scenes: scenes, model: model, key: key, progress: progress)
        struct Out: Decodable { var title: String?; var parts: [RundownPart]; var aliases: [WordAlias]? }
        guard let out = try? JSONDecoder().decode(Out.self, from: Data(json.utf8)) else { throw failure("The answer wasn't a rundown Framecast could read.") }
        return WrittenRundown(title: out.title ?? title, parts: out.parts, aliases: out.aliases ?? [])
    }

    // Anthropic Messages API, streamed: thinking first, then the JSON answer as text.
    private static func claude(user: String, scenes: [String], model: String, key: String, progress: @escaping (String) -> Void) async throws -> String {
        var req = URLRequest(url: URL(string: (baseOverride ?? "https://api.anthropic.com") + "/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model, "max_tokens": 16_000, "stream": true, "system": instructions,
            "messages": [["role": "user", "content": user]],
            "output_config": ["format": ["type": "json_schema", "schema": schema(scenes: scenes)]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        report(progress, "Sending the script to Anthropic…")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 20_000 { break } }
            throw failure(httpProblem(.claude, status, text))
        }
        var answer = "", stop = "", thinking = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let d = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            switch ev["type"] as? String {
            case "content_block_delta":
                let delta = ev["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let t = delta?["text"] as? String {
                    answer += t
                    if answer.count % 200 < t.count { report(progress, "Writing the rundown… \(answer.count) characters") }
                } else if !thinking {
                    thinking = true; report(progress, "Claude is thinking it through…")
                }
            case "message_delta": stop = (ev["delta"] as? [String: Any])?["stop_reason"] as? String ?? stop
            case "error": throw failure("Anthropic: \(((ev["error"] as? [String: Any])?["message"] as? String) ?? "the request failed").")
            default: break
            }
        }
        if stop == "refusal" { throw failure("Claude declined to write this rundown.") }
        if stop == "max_tokens" { throw failure("The script is too long for one pass. Split it into two shows and try again.") }
        return answer
    }

    // OpenAI Responses API with a strict JSON schema.
    private static func openAI(user: String, scenes: [String], model: String, key: String, progress: @escaping (String) -> Void) async throws -> String {
        var req = URLRequest(url: URL(string: (baseOverride ?? "https://api.openai.com") + "/v1/responses")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model, "max_output_tokens": 16_000,
            "input": [["role": "system", "content": instructions], ["role": "user", "content": user]],
            "text": ["format": ["type": "json_schema", "name": "rundown", "strict": true, "schema": schema(scenes: scenes)]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        report(progress, "Sending the script to OpenAI and waiting for the rundown…")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(httpProblem(.openai, status, String(decoding: data, as: UTF8.self))) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("OpenAI sent an answer Framecast couldn't read.") }
        if obj["status"] as? String == "incomplete" { throw failure("The script is too long for one pass. Split it into two shows and try again.") }
        for item in obj["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for c in item["content"] as? [[String: Any]] ?? [] {
                if c["type"] as? String == "refusal" { throw failure("OpenAI declined to write this rundown.") }
                if c["type"] as? String == "output_text", let t = c["text"] as? String { return t }
            }
        }
        throw failure("OpenAI's answer had no rundown in it.")
    }

    private static func httpProblem(_ p: AIProvider, _ status: Int, _ body: String) -> String {
        let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        switch status {
        case 401, 403: return "\(p.company) didn't accept the API key. Check it in Settings › AI."
        case 429: return "\(p.company) says the limit is reached (too many requests, or no credit left). \(message ?? "")"
        case 0: return "Couldn't reach \(p.company). Check the internet connection."
        default: return "\(p.company) answered with an error (\(status)). \(message ?? "")"
        }
    }

    private static func report(_ progress: @escaping (String) -> Void, _ s: String) { DispatchQueue.main.async { progress(s) } }
    static func failure(_ text: String) -> NSError { NSError(domain: "Framecast.AI", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    /// Without AI: one part per paragraph. The cue is the start of the paragraph's first sentence, and the scene is a
    /// guess from a few words ("show", "screen", "thanks for watching"), to adjust by hand.
    static func split(script: String, scenes: [String]) -> [RundownPart] {
        var paras = script.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if paras.count == 1 { paras = paras[0].components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        func find(_ words: [String]) -> String? { scenes.first { s in words.contains { s.lowercased().contains($0) } } }
        let camera = scenes.first { $0.lowercased().contains("camera") && !$0.lowercased().contains("screen") } ?? scenes.first ?? "Camera"
        let screen = find(["screen"]) ?? camera
        let closing = find(["outro", "ending", "thanks", "goodbye"]) ?? camera
        return paras.enumerated().map { i, p in
            let lower = p.lowercased()
            let firstSentence = lower.split(whereSeparator: { ".?!".contains($0) }).first.map(String.init) ?? lower
            let words = firstSentence.split(whereSeparator: \.isWhitespace).map { $0.filter { $0.isLetter || $0.isNumber || $0 == "'" } }.filter { !$0.isEmpty }
            let shows = ["show you", "screen", "chart", "demo", "slide", "look at", "let me show"].contains { lower.contains($0) }
            let ends = i == paras.count - 1 && ["thanks for watching", "thank you for watching", "see you", "bye"].contains { lower.contains($0) }
            let title = p.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            return RundownPart(title: title.isEmpty ? "Part \(i + 1)" : title, scene: ends ? closing : (shows ? screen : camera),
                               cue: i == 0 ? "" : words.prefix(9).joined(separator: " "), notes: p)
        }
    }
}
