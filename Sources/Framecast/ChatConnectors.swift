import Foundation
import AppKit
import Network
import CryptoKit

// YouTube and Twitch chat. Both need OAuth apps registered by the user (free developer accounts), because
// Framecast has no server to hold shared credentials. NOT VERIFIED: no such apps were created while
// building Framecast. Tokens are kept in memory only.

/// One-shot loopback receiver for OAuth redirects (http://127.0.0.1:<port>/callback).
final class LoopbackRedirect {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    func start(_ handler: @escaping ([String: String]) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let line = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let q = URLComponents(string: "http://x\(target)")?.queryItems ?? []
                let body = "<html><body style='font:16px -apple-system;background:#1A1816;color:#EEE9E2;padding:40px'>Finish in Framecast. You can close this tab.</body></html>"
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                       completion: .contentProcessed { _ in c.cancel() })
                handler(Dictionary(q.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a }))
            }
        }
        l.start(queue: .main)
        _ = ready.wait(timeout: .now() + 2)
        port = l.port?.rawValue ?? 0
        listener = l
    }
    func stop() { listener?.cancel(); listener = nil }
}

/// YouTube live chat over the Data API v3 (OAuth with PKCE, polling liveChatMessages).
final class YouTubeChatConnector: ChatConnector {
    let platform = ChatPlatform.youtube
    var canSend: Bool { token != nil && chatID != nil }
    private weak var hub: ChatHub?
    private let clientID: String
    private let clientSecret: String
    private var token: String?
    private var chatID: String?
    private var pageToken: String?
    private var timer: Timer?
    private let redirect = LoopbackRedirect()
    private var verifier = ""

    init(hub: ChatHub, clientID: String, clientSecret: String) { self.hub = hub; self.clientID = clientID; self.clientSecret = clientSecret }

    func start() {
        verifier = (0..<64).map { _ in String("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".randomElement()!) }.joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        do {
            try redirect.start { [weak self] q in self?.redirected(q) }
        } catch { hub?.status = "Couldn't listen: \(error.localizedDescription)"; return }
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: "http://127.0.0.1:\(redirect.port)/callback"),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "https://www.googleapis.com/auth/youtube.force-ssl"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
        ]
        hub?.status = "Choose your Google account and click Allow. Framecast picks it up as soon as you're done."
        NSWorkspace.shared.open(c.url!)
    }

    private func redirected(_ q: [String: String]) {
        redirect.stop()
        guard let code = q["code"] else { hub?.status = "YouTube access wasn't allowed. Click Connect to try again."; return }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "code", value: code), .init(name: "client_id", value: clientID),
                           .init(name: "redirect_uri", value: "http://127.0.0.1:\(redirect.port)/callback"),
                           .init(name: "grant_type", value: "authorization_code"), .init(name: "code_verifier", value: verifier)]
        if !clientSecret.isEmpty { form.queryItems?.append(.init(name: "client_secret", value: clientSecret)) }
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let t = o?["access_token"] as? String else { self.hub?.status = "Couldn't connect YouTube. Please try again."; return }
                self.token = t
                self.findChat()
            }
        }.resume()
    }

    private func api(_ path: String, method: String = "GET", body: [String: Any]? = nil, _ done: @escaping ([String: Any]?) -> Void) {
        guard let token else { return }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(o) }
        }.resume()
    }

    private func findChat() {
        api("liveBroadcasts?part=snippet&broadcastStatus=active&broadcastType=all") { [weak self] o in
            guard let self else { return }
            let items = o?["items"] as? [[String: Any]] ?? []
            guard let snip = items.first?["snippet"] as? [String: Any], let id = snip["liveChatId"] as? String else {
                self.hub?.status = "Connected to YouTube. Chat starts once a broadcast on your channel is live."
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.findChat() }
                return
            }
            self.chatID = id
            self.hub?.status = nil
            self.poll()
        }
    }

    private func poll() {
        guard let chatID else { return }
        var path = "liveChat/messages?part=snippet,authorDetails&liveChatId=\(chatID)"
        if let pageToken { path += "&pageToken=\(pageToken)" }
        api(path) { [weak self] o in
            guard let self else { return }
            self.pageToken = o?["nextPageToken"] as? String
            for item in o?["items"] as? [[String: Any]] ?? [] {
                let s = item["snippet"] as? [String: Any] ?? [:], a = item["authorDetails"] as? [String: Any] ?? [:]
                let text = (s["displayMessage"] as? String) ?? ""
                let paid = (s["superChatDetails"] as? [String: Any])?["amountDisplayString"] as? String
                var m = ChatMessage(platform: .youtube, user: a["displayName"] as? String ?? "Viewer", text: text, paidAmount: paid, remoteID: item["id"] as? String)
                if (a["isChatModerator"] as? Bool) == true { m.role = .mod }
                if (a["isChatOwner"] as? Bool) == true { m.role = .you }
                self.hub?.receive(m)
            }
            let wait = max(2.0, ((o?["pollingIntervalMillis"] as? Double) ?? 5000) / 1000)
            if o?["error"] != nil { self.hub?.status = "YouTube's chat is having trouble. Reconnecting…" }
            self.timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.poll() }
        }
    }

    func send(_ text: String) {
        guard let chatID else { return }
        api("liveChat/messages?part=snippet", method: "POST",
            body: ["snippet": ["liveChatId": chatID, "type": "textMessageEvent", "textMessageDetails": ["messageText": text]]]) { _ in }
    }

    func stop() { timer?.invalidate(); redirect.stop(); token = nil }
}

/// Twitch chat over IRC-on-WebSocket. Signs in with the OAuth device-code flow (no redirect needed),
/// or reads a public channel anonymously when no client ID is given.
final class TwitchChatConnector: ChatConnector {
    let platform = ChatPlatform.twitch
    var canSend: Bool { token != nil }
    private weak var hub: ChatHub?
    private let clientID: String
    private var channel: String
    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var pollTimer: Timer?

    init(hub: ChatHub, clientID: String, channel: String) { self.hub = hub; self.clientID = clientID; self.channel = channel.lowercased() }

    func start() {
        guard !clientID.isEmpty else { connectIRC(); return }
        post("https://id.twitch.tv/oauth2/device", ["client_id": clientID, "scopes": "chat:read chat:edit user:read:email"]) { [weak self] o in
            guard let self, let device = o?["device_code"] as? String, let uri = o?["verification_uri"] as? String else {
                self?.hub?.status = "Couldn't connect Twitch. Please try again."; return
            }
            self.hub?.status = "Sign in to Twitch and click Authorize. Framecast picks it up as soon as you're done."
            NSWorkspace.shared.open(URL(string: uri)!)
            self.pollToken(device: device, interval: (o?["interval"] as? Double) ?? 5)
        }
    }

    private func post(_ url: String, _ form: [String: String], _ done: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = form.map { .init(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(o) }
        }.resume()
    }

    private func pollToken(device: String, interval: Double) {
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.post("https://id.twitch.tv/oauth2/token", ["client_id": self.clientID, "device_code": device,
                                                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]) { o in
                if let t = o?["access_token"] as? String { self.token = t; self.lookupLogin() }
                else if (o?["message"] as? String) == "authorization_pending" { self.pollToken(device: device, interval: interval) }
                else { self.hub?.status = "Twitch access wasn't allowed. Click Connect to try again." }
            }
        }
    }

    private func lookupLogin() {
        guard let token else { return }
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/users")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let login = ((o?["data"] as? [[String: Any]])?.first?["login"] as? String) ?? ""
            DispatchQueue.main.async { if self.channel.isEmpty { self.channel = login }; self.login = login; self.connectIRC() }
        }.resume()
    }
    private var login = ""

    private func connectIRC() {
        guard !channel.isEmpty else { hub?.status = "Enter a Twitch channel name to read its chat."; return }
        let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        socket = ws
        ws.resume()
        let nick = token == nil ? "justinfan\(Int.random(in: 10_000...99_999))" : login
        if let token { ws.send(.string("PASS oauth:\(token)")) { _ in } }
        ws.send(.string("CAP REQ :twitch.tv/tags")) { _ in }
        ws.send(.string("NICK \(nick)")) { _ in }
        ws.send(.string("JOIN #\(channel)")) { _ in }
        hub?.status = nil
        receive()
    }

    private func receive() {
        socket?.receive { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(.string(let s)):
                for line in s.components(separatedBy: "\r\n") where !line.isEmpty { self.handle(line) }
                self.receive()
            case .success: self.receive()
            case .failure:
                DispatchQueue.main.async { self.hub?.status = "Twitch chat stopped. Reconnecting…" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.connectIRC() }
            }
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("PING") { socket?.send(.string("PONG :tmi.twitch.tv")) { _ in }; return }
        guard line.contains(" PRIVMSG #") else { return }
        var tags: [String: String] = [:]
        var rest = line
        if line.hasPrefix("@"), let sp = line.firstIndex(of: " ") {
            for kv in line[line.index(after: line.startIndex)..<sp].split(separator: ";") {
                let p = kv.split(separator: "=", maxSplits: 1); if p.count == 2 { tags[String(p[0])] = String(p[1]) }
            }
            rest = String(line[line.index(after: sp)...])
        }
        guard let msgStart = rest.range(of: " :", range: rest.range(of: "PRIVMSG")!.upperBound..<rest.endIndex) else { return }
        let text = String(rest[msgStart.upperBound...])
        let user = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? String(rest.dropFirst().prefix { $0 != "!" })
        var m = ChatMessage(platform: .twitch, user: user, text: text, remoteID: tags["id"])
        if let bits = tags["bits"] { m.paidAmount = "\(bits) bits" }
        if tags["mod"] == "1" { m.role = .mod }
        DispatchQueue.main.async { self.hub?.receive(m) }
    }

    func send(_ text: String) { guard token != nil else { return }; socket?.send(.string("PRIVMSG #\(channel) :\(text)")) { _ in } }
    func stop() { pollTimer?.invalidate(); socket?.cancel(); socket = nil }
}

/// The optional Google OAuth client secret lives in the Keychain. Older builds kept it in preferences;
/// it is moved over the first time it's needed.
enum YouTubeClientSecret {
    private static let service = "Framecast YouTube client", account = "client-secret", legacyKey = "framecast.youtubeClientSecret"
    static var isSaved: Bool { SecretStore.exists(service: service, account: account) || UserDefaults.standard.string(forKey: legacyKey) != nil }
    static func save(_ value: String) { SecretStore.set(value, service: service, account: account); UserDefaults.standard.removeObject(forKey: legacyKey) }
    static func read() -> String {
        if let old = UserDefaults.standard.string(forKey: legacyKey) { save(old) }
        return SecretStore.get(service: service, account: account) ?? ""
    }
}

extension ChatHub {
    func connectYouTubeChat() {
        let id = UserDefaults.standard.string(forKey: "framecast.youtubeClientID") ?? ""
        let secret = YouTubeClientSecret.read()
        guard !id.isEmpty else { status = "Add your Google OAuth client ID first."; return }
        let c = YouTubeChatConnector(hub: self, clientID: id, clientSecret: secret)
        connectors.append(c); c.start()
    }
    func connectTwitchChat(channel: String) {
        let id = UserDefaults.standard.string(forKey: "framecast.twitchClientID") ?? ""
        let c = TwitchChatConnector(hub: self, clientID: id, channel: channel)
        connectors.append(c); c.start()
    }
}
