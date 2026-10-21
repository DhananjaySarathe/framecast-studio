import Foundation
import Network
import CryptoKit
import Darwin

/// Runs the guest infrastructure. Three reaches (GuestReach):
///  • This Mac: a LiveKit server (open source, `brew install livekit`) with every listener on 127.0.0.1 and a
///    small HTTP server on 127.0.0.1 that serves the guest page and its join API.
///  • Wi-Fi: the same, plus an https server on the Mac's private Wi-Fi address that serves the page and passes
///    LiveKit signalling through to 127.0.0.1; media also listens on that address. Nothing on public addresses.
///  • Internet: no local server. The user's own LiveKit Cloud project carries the video and the user hosts the
///    guest page; guests knock over LiveKit data messages and are let in by a permission change.
/// Local tokens are signed with a secret generated per session and never stored.
final class GuestServer {
    static let httpPort: UInt16 = 8090
    static let httpsPort: UInt16 = 8443
    static let signalPort = 7880
    static let mediaPort = 7882
    let reach: GuestReach
    let apiKey: String
    let secret: String
    /// Where the host connects; for LiveKit Cloud also where guests connect.
    let signalURL: String
    /// Base URL of LiveKit's server API (RoomService).
    private let apiBase: String
    let runsLocalServer: Bool
    private(set) var lanAddress: String?
    private var lanInterface: String?
    private var process: Process?
    private var listener: NWListener?
    private var tlsListener: NWListener?
    private let queue = DispatchQueue(label: "framecast.guestserver")

    init(reach: GuestReach, cloud: GuestCloudConfig? = nil) {
        self.reach = reach
        if reach == .internet, let cloud, !cloud.isLocalTest {
            apiKey = cloud.apiKey; secret = cloud.secret; signalURL = cloud.url; apiBase = cloud.apiBase
            runsLocalServer = false
        } else {
            apiKey = "framecast"
            secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            signalURL = "ws://127.0.0.1:\(Self.signalPort)"; apiBase = "http://127.0.0.1:\(Self.signalPort)"
            runsLocalServer = true
        }
    }

    /// Join API callbacks, answered on the main queue by the guest room.
    var onRoomInfo: ((String) -> (title: String, open: Bool))?
    var onKnock: ((_ code: String, _ name: String, _ detail: String) -> (ticket: String, state: String)?)?
    var onTicket: ((String) -> [String: Any])?

    static func binaryPath() -> String? {
        ["/opt/homebrew/bin/livekit-server", "/usr/local/bin/livekit-server"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Framecast.Guests", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    func start() throws {
        let bin = Self.binaryPath()
        if runsLocalServer && bin == nil {
            throw Self.failure("The local guest server isn't installed. It's free and open source: run `brew install livekit` in Terminal, then open the room again.")
        }
        let dir = CollectionStore.root.appendingPathComponent("GuestServer")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if reach == .wifi {
            guard let lan = LocalNetwork.privateIPv4() else {
                throw Self.failure("Framecast couldn't find this Mac's Wi-Fi address. Join a Wi-Fi (or Ethernet) network and open the room again.")
            }
            lanAddress = lan.address; lanInterface = lan.interface
        }
        try startHTTP()
        if let lan = lanAddress { try startHTTPS(host: lan, identity: GuestTLS.identity(for: lan, dir: dir)) }
        guard runsLocalServer, let bin else { return }
        // Signalling stays on 127.0.0.1:7880 (Wi-Fi guests reach it through the https server on 8443). Media is
        // UDP 7882 on loopback and, for Wi-Fi guests, on the Mac's private Wi-Fi address only. ICE/TCP and TURN off.
        let ips = ["127.0.0.1"] + (lanAddress.map { [$0] } ?? [])
        let interfaces = ["lo0"] + (lanInterface.map { [$0] } ?? [])
        let config = """
        port: \(Self.signalPort)
        bind_addresses: ["127.0.0.1"]
        rtc:
          tcp_port: 0
          udp_port: \(Self.mediaPort)
          use_external_ip: false
          node_ip: \(lanAddress ?? "127.0.0.1")
          enable_loopback_candidate: true
          interfaces:
            includes: [\(interfaces.map { "\"\($0)\"" }.joined(separator: ", "))]
          ips:
            includes: [\(ips.map { "\"\($0)/32\"" }.joined(separator: ", "))]
        turn:
          enabled: false
        logging:
          level: warn
        """
        // A server left behind by a crash would hold the ports: stop it first (only if it's ours).
        let pidURL = dir.appendingPathComponent("livekit.pid")
        if let old = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(old.trimmingCharacters(in: .whitespacesAndNewlines)) {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasSuffix("livekit-server") { kill(pid, SIGKILL); usleep(300_000) }
        }
        let cfgURL = dir.appendingPathComponent("livekit.yaml")
        try config.write(to: cfgURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--config", cfgURL.path]
        // The API secret goes in through the environment so it never touches the disk.
        p.environment = ["LIVEKIT_KEYS": "\(apiKey): \(secret)"]
        let log = dir.appendingPathComponent("livekit.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        try p.run()
        process = p
        try? "\(p.processIdentifier)".write(to: pidURL, atomically: true, encoding: .utf8)
    }

    /// LiveKit treats SIGTERM as "drain and wait for rooms to empty", so interrupt, give it a moment,
    /// then force it: the server must never outlive Framecast.
    func stop() {
        listener?.cancel(); listener = nil
        tlsListener?.cancel(); tlsListener = nil
        if let p = process, p.isRunning {
            p.interrupt()
            let deadline = Date().addingTimeInterval(1.5)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
    }

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: Tokens

    /// LiveKit access token (JWT, HS256). `lobby` tokens (remote invites) can only send data and set their
    /// name until the host lets them in.
    func token(identity: String, name: String, room: String, admin: Bool = false, lobby: Bool = false, ttl: TimeInterval = 6 * 3600) -> String {
        func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let now = Int(Date().timeIntervalSince1970)
        var grants: [String: Any] = ["room": room, "roomJoin": true, "canPublish": !lobby, "canSubscribe": !lobby, "canPublishData": true]
        if lobby { grants["canUpdateOwnMetadata"] = true }
        if admin { grants["roomAdmin"] = true }
        let payload: [String: Any] = ["iss": apiKey, "sub": identity, "name": name, "nbf": now - 10, "exp": now + Int(ttl), "video": grants]
        let h = b64(try! JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"]))
        let p = b64(try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(h).\(p)".utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return "\(h).\(p).\(b64(Data(mac)))"
    }

    /// Server-side removal through LiveKit's RoomService (admin token).
    func removeParticipant(room: String, identity: String) {
        roomService("RemoveParticipant", ["room": room, "identity": identity], room: room)
    }

    /// Opens a waiting remote guest's connection to messages from the host (the let-in message follows).
    func allowMessages(room: String, identity: String, done: ((Bool) -> Void)? = nil) {
        roomService("UpdateParticipant", ["room": room, "identity": identity,
                                          "permission": ["canSubscribe": true, "canPublish": false, "canPublishData": true]], room: room, done: done)
    }

    private func roomService(_ method: String, _ body: [String: Any], room: String, done: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(apiBase)/twirp/livekit.RoomService/\(method)") else { done?(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token(identity: "framecast-admin", name: "admin", room: room, admin: true, ttl: 60))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done?(ok) }
        }.resume()
    }

    // MARK: HTTP (127.0.0.1) and HTTPS (private Wi-Fi address)

    private func startHTTP() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.httpPort)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        listener = l
    }

    /// TLS with the self-signed certificate; serves the page and passes `/rtc` (LiveKit signalling) through.
    private func startHTTPS(host: String, identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        guard let id = sec_identity_create(identity) else { throw Self.failure("Couldn't use the guest room's certificate.") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, id)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Self.httpsPort)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        tlsListener = l
    }

    /// Hands a connection to the local LiveKit server, bytes unchanged in both directions (WebSocket upgrade
    /// and frames included).
    private func proxy(_ c: NWConnection, initial: Data) {
        let up = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(Self.signalPort))!, using: .tcp)
        up.start(queue: queue)
        up.send(content: initial, completion: .contentProcessed { _ in })
        pipe(c, to: up); pipe(up, to: c)
    }

    private func pipe(_ a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            if let data, !data.isEmpty { b.send(content: data, completion: .contentProcessed { _ in }) }
            if done || err != nil { a.cancel(); b.cancel(); return }
            self?.pipe(a, to: b)
        }
    }

    private var resourceDir: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("guest"), FileManager.default.fileExists(atPath: r.path) { return r }
        // Running from `swift run`: use the repository copy.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/guest")
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    let lines = head.components(separatedBy: "\r\n")
                    let parts = (lines.first ?? "").split(separator: " ")
                    // Only answer requests addressed to this server, so a web page can't reach it through a
                    // domain that resolves to this Mac (DNS rebinding).
                    let host = lines.dropFirst().compactMap { l -> String? in
                        let kv = l.split(separator: ":", maxSplits: 1)
                        return kv.count == 2 && kv[0].lowercased() == "host" ? kv[1].trimmingCharacters(in: .whitespaces).lowercased() : nil
                    }.first ?? ""
                    guard self.allowedHosts.contains(host) else {
                        self.send(c, status: "421 Misdirected Request", type: "text/plain", body: Data("Wrong address".utf8)); return
                    }
                    if parts.count >= 2, self.runsLocalServer, parts[1].hasPrefix("/rtc") || parts[1].hasPrefix("/twirp") {
                        self.proxy(c, initial: buffer); return
                    }
                    let length = lines.compactMap { l -> Int? in
                        let kv = l.split(separator: ":", maxSplits: 1); return kv.count == 2 && kv[0].lowercased() == "content-length" ? Int(kv[1].trimmingCharacters(in: .whitespaces)) : nil
                    }.first ?? 0
                    let body = buffer[range.upperBound...]
                    if body.count >= length, parts.count >= 2 {
                        self.respond(c, method: String(parts[0]), target: String(parts[1]), body: Data(body.prefix(length)))
                        return
                    }
                }
                if done || err != nil || buffer.count > 1_000_000 { c.cancel(); return }
                readMore()
            }
        }
        readMore()
    }

    private var allowedHosts: Set<String> {
        var s: Set<String> = ["127.0.0.1:\(Self.httpPort)", "localhost:\(Self.httpPort)"]
        if let lan = lanAddress { s.insert("\(lan):\(Self.httpsPort)") }
        return s
    }

    private func send(_ c: NWConnection, status: String, type: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
    private func json(_ c: NWConnection, _ obj: Any, status: String = "200 OK") {
        send(c, status: status, type: "application/json", body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
    }

    private func respond(_ c: NWConnection, method: String, target: String, body: Data) {
        let comps = URLComponents(string: "http://x\(target)")
        let path = comps?.path ?? "/"
        let q = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        func onMain<T>(_ f: @escaping () -> T, _ k: @escaping (T) -> Void) { DispatchQueue.main.async { let v = f(); self.queue.async { k(v) } } }

        if path.hasSuffix("/livekit-client.umd.js") {
            // The page loads it relative to itself, so it may be asked for under /invite/ too.
            send(c, status: "200 OK", type: "application/javascript", body: (try? Data(contentsOf: resourceDir.appendingPathComponent("livekit-client.umd.js"))) ?? Data())
        } else if path.hasPrefix("/invite/") || path == "/" || path == "/index.html" {
            let url = resourceDir.appendingPathComponent("index.html")
            send(c, status: "200 OK", type: "text/html; charset=utf-8", body: (try? Data(contentsOf: url)) ?? Data("Missing guest page".utf8))
        } else if path == "/api/room" {
            onMain({ self.onRoomInfo?(q["code"] ?? "") ?? ("", false) }) { r in self.json(c, ["title": r.title, "open": r.open]) }
        } else if path == "/api/knock", method == "POST" {
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let code = o["code"] as? String ?? "", name = String((o["name"] as? String ?? "Guest").prefix(60)), detail = String((o["detail"] as? String ?? "").prefix(80))
            onMain({ self.onKnock?(code, name, detail) }) { r in
                if let r { self.json(c, ["ticket": r.ticket, "state": r.state]) }
                else { self.send(c, status: "403 Forbidden", type: "text/plain", body: Data("This link has expired. Ask the host for a new one.".utf8)) }
            }
        } else if path == "/api/ticket" {
            onMain({ self.onTicket?(q["id"] ?? "") ?? ["state": "denied"] }) { r in self.json(c, r) }
        } else {
            send(c, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }
}
