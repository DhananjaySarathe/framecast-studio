import Foundation
import Network
import Observation
import FramecastEngine

/// The control link: a small MCP server so Claude (Claude Code, Claude Desktop) or another MCP app on this Mac can
/// work Framecast the way you do in chat: read the show, switch scenes, make scenes from layouts, write the rundown,
/// take its parts, show overlays and add markers. It can't start or stop recordings or broadcasts and doesn't touch
/// sound.
/// Off until switched on in Settings › AI. It listens on 127.0.0.1 only, answers only requests addressed to that
/// address (so a web page can't reach it through DNS rebinding), and every request needs the token kept in
/// Application Support/Framecast/ControlLink/token (readable by you only). Apps that start MCP servers as commands use
/// the `framecast-mcp` helper inside Framecast.app, which reads that token and passes messages through.
@Observable
final class ControlLink {
    static let port: UInt16 = CollectionStore.profile == "default" ? 8095 : 8096
    static var dir: URL { CollectionStore.root.appendingPathComponent(CollectionStore.profile == "default" ? "ControlLink" : "ControlLink (tests)") }
    static var tokenFile: URL { dir.appendingPathComponent("token") }
    static var url: String { "http://127.0.0.1:\(port)/mcp" }

    unowned let studio: Studio
    private(set) var isRunning = false
    private(set) var problem: String?
    /// The latest thing an app did through the link ("switch_scene Split · 14:02").
    private(set) var lastCall: String?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "framecast.controllink")
    @ObservationIgnored private let tokenLock = NSLock()
    @ObservationIgnored private var _token = ""
    private var token: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); _token = newValue; tokenLock.unlock() }
    }

    init(studio: Studio) { self.studio = studio }

    func start() {
        guard listener == nil else { return }
        problem = nil
        do {
            token = try Self.ensureToken()
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st {
                    DispatchQueue.main.async { self?.problem = "The control link couldn't use port \(Self.port): \(e.localizedDescription)"; self?.stop() }
                }
            }
            l.start(queue: queue)
            listener = l
            isRunning = true
        } catch {
            problem = "The control link couldn't start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        isRunning = false
    }

    /// The token, made on first use (32 random bytes as hex), in a file only you can read.
    static func ensureToken() throws -> String {
        if let t = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        return try newToken()
    }
    @discardableResult static func newToken() throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try t.write(to: tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return t
    }
    /// A new token: apps set up with the old one (by header) need the new one.
    func renewToken() {
        token = (try? Self.newToken()) ?? token
    }
    var currentToken: String { token.isEmpty ? ((try? Self.ensureToken()) ?? "") : token }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
                guard let self else { c.cancel(); return }
                if let data { buffer.append(data) }
                if buffer.count > 2_000_000 { self.send(c, "413 Content Too Large", ["error": "Too large"]); return }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    var lines = String(decoding: buffer[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                    let request = lines.removeFirst().split(separator: " ").map(String.init)
                    var headers: [String: String] = [:]
                    for l in lines {
                        let kv = l.split(separator: ":", maxSplits: 1)
                        if kv.count == 2 { headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
                    }
                    let length = Int(headers["content-length"] ?? "0") ?? 0
                    if buffer.count - range.upperBound >= length {
                        let body = buffer.subdata(in: range.upperBound..<(range.upperBound + length))
                        self.respond(c, method: request.first ?? "", path: request.count > 1 ? request[1] : "", headers: headers, body: body)
                        return
                    }
                }
                if done || err != nil { c.cancel(); return }
                readMore()
            }
        }
        readMore()
    }

    private func respond(_ c: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        let local = ["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"]
        guard local.contains(headers["host"]?.lowercased() ?? "") else { send(c, "421 Misdirected Request", ["error": "Wrong address"]); return }
        if let origin = headers["origin"], !local.contains(where: { origin.lowercased() == "http://\($0)" }) {
            send(c, "403 Forbidden", ["error": "Web pages can't use the control link"]); return
        }
        guard headers["authorization"] == "Bearer \(token)" else { send(c, "401 Unauthorized", ["error": "Missing or wrong token"]); return }
        guard path == "/mcp" || path == "/mcp/" else { send(c, "404 Not Found", ["error": "Use /mcp"]); return }
        guard method == "POST" else { send(c, "405 Method Not Allowed", ["error": "POST JSON-RPC messages to /mcp"], extra: "Allow: POST\r\n"); return }
        guard let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            send(c, "400 Bad Request", ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Send one JSON-RPC message"]]); return
        }
        guard let id = msg["id"] else { send(c, "202 Accepted", nil); return }      // notifications need no answer
        let params = msg["params"] as? [String: Any] ?? [:]
        // Downloads run here, off the main thread; everything else runs on the main thread like a click.
        let tool = msg["method"] as? String == "tools/call" ? params["name"] as? String : nil
        let args = params["arguments"] as? [String: Any] ?? [:]
        let answer: Result<Any, RPCError>
        switch tool {
        case "save_image": answer = toolResult("save_image") { try self.saveImage(args) }
        case "make_card": answer = toolResult("make_card") { try self.makeCard(args) }
        case "make_motion": answer = toolResult("make_motion") { try self.makeMotion(args) }
        default: answer = DispatchQueue.main.sync { self.rpc(msg) }
        }
        var out: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch answer { case .success(let r): out["result"] = r; case .failure(let e): out["error"] = ["code": e.code, "message": e.message] }
        send(c, "200 OK", out)
    }

    private func send(_ c: NWConnection, _ status: String, _ json: [String: Any]?, extra: String = "") {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\(extra)"
        if json != nil { head += "Content-Type: application/json\r\n" }
        c.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: MCP

    struct RPCError: Error { var code: Int; var message: String }

    private func rpc(_ msg: [String: Any]) -> Result<Any, RPCError> {
        let params = msg["params"] as? [String: Any] ?? [:]
        switch msg["method"] as? String ?? "" {
        case "initialize":
            return .success([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "framecast", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": "Framecast is the live-streaming studio on this Mac. Read get_show_state first. To prepare a show from the presenter's brief: write the outline with set_outline (topics with short points), make cards with make_card and save reference pictures with save_image (reusable sources only, never logos). During the show Framecast follows the presenter by itself. You can also switch and create scenes, write a scripted rundown, show overlays and add markers. You can't start or stop recordings or broadcasts.",
            ])
        case "ping": return .success([String: Any]())
        case "tools/list": return .success(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? "", args = params["arguments"] as? [String: Any] ?? [:]
            return toolResult(name) { try self.call(name, args) }
        default: return .failure(RPCError(code: -32601, message: "Unknown method"))
        }
    }

    private func toolResult(_ name: String, _ run: () throws -> Any) -> Result<Any, RPCError> {
        do {
            let result = try run()
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let note = "\(name) · \(f.string(from: Date()))"
            if Thread.isMainThread { lastCall = note } else { DispatchQueue.main.async { self.lastCall = note } }
            let text = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return .success(["content": [["type": "text", "text": text]], "isError": false])
        } catch let e as RPCError where e.code == -32602 {
            return .failure(e)
        } catch {
            let text = (error as? RPCError)?.message ?? error.localizedDescription
            return .success(["content": [["type": "text", "text": text]], "isError": true])
        }
    }

    /// A safe file name for the assets folder: lower case letters, digits and hyphens.
    static func assetName(_ raw: String, ext: String) -> String {
        let base = (raw as NSString).deletingPathExtension.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base.isEmpty ? "asset" : String(base.prefix(60))) + "." + ext
    }

    /// make_card: draws a card (PNG, or with animate an MP4 that ends on the finished card) into the assets folder.
    /// Runs off the main thread: an animated card takes a few seconds.
    private func makeCard(_ a: [String: Any]) throws -> Any {
        guard let folder = DispatchQueue.main.sync(execute: { studio.director.folder }) else { throw RPCError(code: 0, message: "Open or make a show in Framecast first.") }
        guard let k = (a["kind"] as? String).flatMap(CardMaker.Kind.init(rawValue:)) else {
            throw RPCError(code: -32602, message: "kind must be one of \(CardMaker.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let animate = a["animate"] as? Bool ?? false
        let name = Self.assetName(a["file"] as? String ?? "card", ext: animate ? "mp4" : "png")
        var card = CardMaker.Card(kind: k, title: a["title"] as? String ?? "", subtitle: a["subtitle"] as? String ?? "",
                                  items: a["items"] as? [String] ?? [], unit: a["unit"] as? String ?? "", source: a["source"] as? String ?? "")
        card.values = (a["values"] as? [[String: Any]] ?? []).compactMap { v in
            guard let l = v["label"] as? String, let n = (v["value"] as? NSNumber)?.doubleValue else { return nil }
            return (l, n)
        }
        let dir = folder.appendingPathComponent("assets")
        if k == .reference {
            guard let f = a["image"] as? String, FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) else {
                throw RPCError(code: 0, message: "A reference card needs image: a picture already in the assets folder (save_image first).")
            }
            card.image = dir.appendingPathComponent(f)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if let problem = animate ? CardMaker.writeVideo(card, to: url) : CardMaker.write(card, to: url) { throw RPCError(code: 0, message: problem) }
        let about = (a["about"] as? String)?.nilIfEmpty ?? "\(k.rawValue) card: \(card.title)"
        DispatchQueue.main.sync {
            studio.director.describeAsset(name, about)
            studio.showFlash("Control link: made \(name)")
        }
        return ["made": name]
    }

    /// make_motion: renders a motion-graphics template to MP4 in the assets folder (loops get `.loop.mp4`).
    private func makeMotion(_ a: [String: Any]) throws -> Any {
        guard let folder = DispatchQueue.main.sync(execute: { studio.director.folder }) else { throw RPCError(code: 0, message: "Open or make a show in Framecast first.") }
        guard let tpl = (a["template"] as? String).flatMap(Motion.Template.init(rawValue:)) else {
            throw RPCError(code: -32602, message: "template must be one of \(Motion.Template.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var spec = Motion.Spec(template: tpl, title: a["title"] as? String ?? "", subtitle: a["subtitle"] as? String ?? "",
                               value: (a["value"] as? NSNumber)?.doubleValue ?? 0, unit: a["unit"] as? String ?? "", source: a["source"] as? String ?? "")
        spec.items = (a["items"] as? [[String: Any]] ?? []).map {
            Motion.Item(label: $0["label"] as? String ?? "", detail: $0["detail"] as? String ?? "", icon: $0["icon"] as? String ?? "",
                        value: ($0["value"] as? NSNumber)?.doubleValue ?? 0)
        }
        let base = (Self.assetName(a["file"] as? String ?? tpl.rawValue, ext: "mp4") as NSString).deletingPathExtension
        let name = base + (tpl.loops ? ".loop.mp4" : ".mp4")
        let dir = folder.appendingPathComponent("assets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let problem = Motion.write(spec, to: dir.appendingPathComponent(name)) { throw RPCError(code: 0, message: problem) }
        let about = (a["about"] as? String)?.nilIfEmpty ?? "\(tpl.rawValue) animation: \(spec.title)"
        DispatchQueue.main.sync {
            studio.director.describeAsset(name, about)
            studio.showFlash("Control link: made \(name)")
        }
        return ["made": name, "seconds": Motion.duration(spec), "loops": tpl.loops]
    }

    /// save_image: fetches one picture over https (up to 20 MB) into the show's assets folder.
    private func saveImage(_ a: [String: Any]) throws -> Any {
        // https only (test launches may also use the stand-in server on 127.0.0.1).
        let testLocal = ScriptWriter.baseOverride != nil && (a["url"] as? String ?? "").hasPrefix("http://127.0.0.1:")
        guard let s = a["url"] as? String, let url = URL(string: s), url.scheme == "https" || testLocal else { throw RPCError(code: -32602, message: "url must be an https address") }
        guard let folder = DispatchQueue.main.sync(execute: { studio.director.folder }) else { throw RPCError(code: 0, message: "Open or make a show in Framecast first.") }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        req.setValue("Framecast (show preparation)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var got: (Data?, URLResponse?) = (nil, nil)
        URLSession.shared.dataTask(with: req) { d, r, _ in got = (d, r); done.signal() }.resume()
        done.wait()
        let type = (got.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard (got.1 as? HTTPURLResponse)?.statusCode == 200, let data = got.0, type.hasPrefix("image/") else {
            throw RPCError(code: 0, message: "That address didn't return a picture.")
        }
        guard data.count <= 20_000_000 else { throw RPCError(code: 0, message: "The picture is larger than 20 MB.") }
        let ext = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif", "image/heic": "heic", "image/tiff": "tiff"]
            .first { type.hasPrefix($0.key) }?.value ?? "jpg"
        let name = Self.assetName(a["file"] as? String ?? url.lastPathComponent, ext: ext)
        let dir = folder.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        let about = (a["about"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.sync {
            studio.director.describeAsset(name, about.isEmpty ? name : about)
            studio.showFlash("Control link: saved \(name)")
        }
        return ["saved": name, "bytes": data.count]
    }

    static func layoutNames() -> [(String, StudioLayoutTemplate)] {
        let r = LayoutTemplates.Roles(background: UUID(), camera: UUID(), screen: UUID(), lowerThird: UUID())
        return StudioLayoutTemplate.allCases.map { (LayoutTemplates.make($0, roles: r).name, $0) }
    }

    static var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
        }
        let str: [String: Any] = ["type": "string"]
        let part: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["title", "scene"], "properties": [
            "title": ["type": "string", "description": "Two to four words."],
            "scene": ["type": "string", "description": "Exact name of a scene in the studio."],
            "cue": ["type": "string", "description": "What the presenter says when this part should start (3-9 words, lower case). Empty for a part that starts by hand."],
            "alsoAccept": ["type": "array", "items": str, "description": "Other natural ways of saying the cue."],
            "notes": ["type": "string", "description": "The script text of this part."],
        ]]
        return [
            tool("get_show_state", "What's on air, the scenes, overlays, the show's rundown with its parts and which part is on air, the director mode, and whether Framecast is recording or live."),
            tool("switch_scene", "Put a scene on air now with the current transition.", ["name": ["type": "string", "description": "Exact scene name from get_show_state."]], required: ["name"]),
            tool("create_scene", "Make a new scene from one of Framecast's layouts (it uses the studio's camera, screen and background). It is not put on air.",
                 ["layout": ["type": "string", "enum": layoutNames().map(\.0)], "name": ["type": "string", "description": "Name for the new scene; leave out to use the layout's name."]],
                 required: ["layout"]),
            tool("set_rundown", "Replace the show's rundown with these parts, in order (opens a new show if none is open). The presenter can then go through the parts by voice or by hand.",
                 ["title": ["type": "string", "description": "Show title."], "script": ["type": "string", "description": "The full script, if there is one."],
                  "parts": ["type": "array", "items": part]], required: ["parts"]),
            tool("take_part", "Put a part of the rundown on air (its scene) and make it the current part.",
                 ["number": ["type": "integer", "description": "Part number, starting at 1."]], required: ["number"]),
            tool("toggle_overlay", "Show or hide overlay 1-9 (name tags, headlines, QR codes).", ["number": ["type": "integer"]], required: ["number"]),
            tool("add_marker", "Mark this moment of the recording or broadcast (it becomes a chapter). Only while recording or live."),
            tool("set_outline", "Write the show's outline from the presenter's brief (opens a new show if none is open). During the show Framecast follows which topic they're on, ticks off points and puts assets on screen when they fit.",
                 ["title": str, "brief": ["type": "string", "description": "The presenter's brief, as given."],
                  "topics": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["title", "points"], "properties": [
                      "title": str, "points": ["type": "array", "items": str, "description": "3-6 short phrases the presenter will cover, in their words."],
                      "look": ["type": "string", "description": "Optional scene name that suits this topic."],
                      "assets": ["type": "array", "items": str, "description": "Files in the assets folder for this topic."],
                      "notes": str]]],
                  "assets": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["file", "about"],
                                                       "properties": ["file": str, "about": ["type": "string", "description": "One line on what it shows."]]]]],
                 required: ["topics"]),
            tool("make_card", "Draw a 1920x1080 card into the show's assets folder in Framecast's style: title, bullets, chart (bar chart from values), quote (title is the quote, subtitle who said it), number (one big value) flow (items are 2-5 steps, shown as boxes with arrows) or reference (a picture from the assets folder in a browser-style frame, slowly zooming; subtitle is its address). With animate it's a short MP4 that animates in and ends on the finished card. Put the source of any number in source.",
                 ["file": ["type": "string", "description": "File name, e.g. price-chart"], "kind": ["type": "string", "enum": CardMaker.Kind.allCases.map(\.rawValue)],
                  "title": str, "subtitle": str, "items": ["type": "array", "items": str],
                  "values": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["label", "value"], "properties": ["label": str, "value": ["type": "number"]]]],
                  "unit": ["type": "string", "description": "Suffix after values, e.g. \" $\" or \"%\""], "source": str,
                  "about": ["type": "string", "description": "One line on what the card shows (how Framecast knows when it fits)."],
                  "animate": ["type": "boolean", "description": "Make an animated MP4 instead of a still PNG."],
                  "image": ["type": "string", "description": "reference: a picture in the assets folder; subtitle is the address shown in its frame."]],
                 required: ["file", "kind", "title"]),
            tool("make_motion", "Make a motion graphic (MP4, 1920x1080) for the show from data, like an editor would cut in. Prefer this to text cards. Templates: " +
                 Motion.Template.allCases.map { "\($0.rawValue): \($0.about)" }.joined(separator: "; ") +
                 ". Icons are SF Symbol names (e.g. mic.fill, chart.bar.xaxis, brain.head.profile, sparkles, key.fill, dollarsign.circle). Content stays clear of the bottom-right corner, where the camera bubble goes.",
                 ["file": ["type": "string", "description": "File name, e.g. how-it-works"], "template": ["type": "string", "enum": Motion.Template.allCases.map(\.rawValue)],
                  "title": str, "subtitle": str, "value": ["type": "number"], "unit": str, "source": str,
                  "items": ["type": "array", "items": ["type": "object", "additionalProperties": false, "properties": [
                      "label": str, "detail": str, "icon": ["type": "string", "description": "SF Symbol name"], "value": ["type": "number"]]]],
                  "about": ["type": "string", "description": "One line on what it shows (how Framecast knows when it fits)."]],
                 required: ["file", "template", "title"]),
            tool("save_image", "Save a picture from an https address into the show's assets folder. Use pictures that may be reused (Wikimedia Commons, Openverse, the presenter's own) and put the credit in about. Never a company logo.",
                 ["url": str, "file": ["type": "string", "description": "File name without extension"], "about": str], required: ["url", "about"]),
            tool("show_asset", "Put an asset on screen now, in an asset look (the camera stays in a circle or square, or the asset alone).",
                 ["file": str, "look": ["type": "string", "enum": [""] + Looks.assetLooks]], required: ["file"]),
        ]
    }

    /// Runs one tool on the main thread.
    private func call(_ name: String, _ a: [String: Any]) throws -> Any {
        func bad(_ m: String) -> RPCError { RPCError(code: -32602, message: m) }
        func scene(_ n: String) -> StudioScene? { studio.scenes.first { $0.name.caseInsensitiveCompare(n.trimmingCharacters(in: .whitespaces)) == .orderedSame } }
        let d = studio.director
        switch name {
        case "get_show_state":
            var state: [String: Any] = [
                "onAir": studio.programScene(.horizontal)?.name ?? "",
                "scenes": studio.scenes.map(\.name),
                "layouts": Self.layoutNames().map(\.0),
                "overlays": studio.collection.elements.prefix(9).enumerated().map { ["number": $0.offset + 1, "name": $0.element.name, "onScreen": studio.elementsOn[$0.element.id] != nil] },
                "previewBeforeAir": studio.previewMode, "recording": studio.isRecording, "live": studio.streaming.isLive,
            ]
            if let show = d.show, d.hasTopics || !show.assets.isEmpty {
                state["outline"] = [
                    "title": show.title, "director": d.mode.rawValue, "listening": d.isListening,
                    "currentTopic": d.topicIndex.map { $0 + 1 as Any } ?? NSNull(), "covered": d.covered.sorted(),
                    "assetOnScreen": d.currentAsset ?? "", "lastDecision": d.lastDecision,
                    "topics": show.topics.enumerated().map { ["number": $0.offset + 1, "title": $0.element.title, "points": $0.element.points,
                                                             "look": $0.element.look, "assets": $0.element.assets] },
                    "assets": show.assets.map { ["file": $0.file, "about": $0.about, "exists": d.assetExists($0.file)] },
                    "looks": Looks.catalog(studio).map { ["name": $0.name, "about": $0.about] },
                ]
            }
            if let show = d.show, !show.parts.isEmpty {
                state["rundown"] = [
                    "title": show.title, "director": d.mode.rawValue, "listening": d.isListening,
                    "currentPart": d.current.map { $0 + 1 as Any } ?? NSNull(),
                    "parts": show.parts.enumerated().map { ["number": $0.offset + 1, "title": $0.element.title, "scene": $0.element.scene,
                                                            "cue": $0.element.cue, "sceneExists": d.sceneID(for: $0.element) != nil] },
                ]
            }
            return state
        case "switch_scene":
            guard let n = a["name"] as? String else { throw bad("name is required") }
            guard let s = scene(n) else { throw RPCError(code: 0, message: "No scene called “\(n)”. Scenes: \(studio.scenes.map(\.name).joined(separator: ", "))") }
            studio.switchTo(s.id, everyCanvas: true)
            studio.showFlash("Control link: \(s.name)")
            return ["onAir": s.name]
        case "create_scene":
            guard let l = a["layout"] as? String, let t = Self.layoutNames().first(where: { $0.0 == l })?.1 else { throw bad("layout must be one of the listed layouts") }
            var s = LayoutTemplates.make(t, roles: studio.defaultRoles())
            let base = (a["name"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? s.name
            var n = base, k = 2
            while studio.scenes.contains(where: { $0.name == n }) { n = "\(base) \(k)"; k += 1 }
            s.name = n; s.verticalName = n
            studio.collection.scenes.append(s)
            studio.showFlash("Control link: new scene “\(n)”")
            return ["created": n]
        case "set_rundown":
            guard let list = a["parts"] as? [[String: Any]] else { throw bad("parts is required") }
            let parts = list.map { p in
                RundownPart(title: p["title"] as? String ?? "", scene: p["scene"] as? String ?? "", cue: p["cue"] as? String ?? "",
                            alsoAccept: p["alsoAccept"] as? [String] ?? [], notes: p["notes"] as? String ?? "")
            }
            if d.show == nil { d.newShow(title: a["title"] as? String ?? "New show") }
            d.edit { s in
                s.parts = parts
                if let t = a["title"] as? String, !t.isEmpty { s.title = t }
                if let sc = a["script"] as? String, !sc.isEmpty { s.script = sc }
            }
            d.current = nil
            studio.rail = .rundown
            studio.showFlash("Control link: rundown with \(parts.count) parts")
            let missing = Array(Set(parts.map(\.scene).filter { n in scene(n) == nil })).sorted()
            return ["parts": parts.count, "scenesNotFound": missing]
        case "take_part":
            guard let n = a["number"] as? Int else { throw bad("number is required") }
            guard d.parts.indices.contains(n - 1) else { throw RPCError(code: 0, message: "The rundown has \(d.parts.count) parts.") }
            guard d.sceneID(for: d.parts[n - 1]) != nil else { throw RPCError(code: 0, message: "Part \(n) uses “\(d.parts[n - 1].scene)”, which isn't a scene in the studio.") }
            d.take(n - 1, by: "control link")
            return ["currentPart": n, "onAir": d.parts[n - 1].scene]
        case "toggle_overlay":
            guard let n = a["number"] as? Int else { throw bad("number is required") }
            guard studio.collection.elements.indices.contains(n - 1) else { throw RPCError(code: 0, message: "There are \(studio.collection.elements.count) overlays.") }
            studio.toggleElement(number: n)
            let e = studio.collection.elements[n - 1]
            return ["overlay": e.name, "onScreen": studio.elementsOn[e.id] != nil]
        case "set_outline":
            guard let list = a["topics"] as? [[String: Any]] else { throw bad("topics is required") }
            let topics = list.map { t in ShowTopic(title: t["title"] as? String ?? "", points: t["points"] as? [String] ?? [], look: t["look"] as? String ?? "",
                                                   assets: t["assets"] as? [String] ?? [], notes: t["notes"] as? String ?? "") }
            let assets = (a["assets"] as? [[String: Any]] ?? []).map { ShowAsset(file: $0["file"] as? String ?? "", about: $0["about"] as? String ?? "") }.filter { !$0.file.isEmpty }
            d.setOutline(title: a["title"] as? String, brief: a["brief"] as? String, topics: topics, assets: assets)
            studio.rail = .rundown
            studio.showFlash("Control link: outline with \(topics.count) topics")
            let missing = topics.flatMap(\.assets).filter { !d.assetExists($0) }
            let badLooks = topics.map(\.look).filter { !$0.isEmpty && scene($0) == nil }
            return ["topics": topics.count, "assetsNotFoundYet": missing, "looksNotFound": badLooks]

        case "show_asset":
            guard let f = a["file"] as? String, d.assetExists(f) else { throw RPCError(code: 0, message: "No asset with that name in the show's assets folder.") }
            d.assetSlotID = Looks.ensure(studio)
            let look = (a["look"] as? String)?.nilIfEmpty ?? (Looks.assetLooks.contains(studio.programScene(.horizontal)?.name ?? "") ? studio.programScene(.horizontal)!.name : Looks.circle)
            d.execute(.asset(f, look: look), by: "control link")
            return ["onScreen": f, "look": look]
        case "add_marker":
            guard studio.isRecording || studio.streaming.isLive else { throw RPCError(code: 0, message: "Markers work only while recording or live.") }
            studio.addMarker()
            return ["marked": true]
        default:
            throw RPCError(code: -32602, message: "Unknown tool \(name)")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
