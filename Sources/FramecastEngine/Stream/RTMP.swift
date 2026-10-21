import Foundation
import Network

// MARK: - AMF0

public enum AMF0Value: Equatable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case object([(String, AMF0Value)])
    case null
    case undefined
    case ecmaArray([(String, AMF0Value)])

    public static func == (a: AMF0Value, b: AMF0Value) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.null, .null), (.undefined, .undefined): return true
        default: return false
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public subscript(key: String) -> AMF0Value? {
        switch self {
        case .object(let kv), .ecmaArray(let kv): return kv.first { $0.0 == key }?.1
        default: return nil
        }
    }
}

enum AMF0 {
    static func encode(_ values: [AMF0Value]) -> Data {
        var d = Data()
        for v in values { write(v, into: &d) }
        return d
    }
    private static func u16(_ v: Int, _ d: inout Data) { d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF)) }
    private static func str(_ s: String, _ d: inout Data) { let b = Data(s.utf8); u16(b.count, &d); d.append(b) }
    static func write(_ v: AMF0Value, into d: inout Data) {
        switch v {
        case .number(let n): d.append(0x00); var be = n.bitPattern.bigEndian; d.append(Data(bytes: &be, count: 8))
        case .bool(let b): d.append(0x01); d.append(b ? 1 : 0)
        case .string(let s): d.append(0x02); str(s, &d)
        case .object(let kv): d.append(0x03); for (k, v) in kv { str(k, &d); write(v, into: &d) }; d.append(contentsOf: [0, 0, 9])
        case .null: d.append(0x05)
        case .undefined: d.append(0x06)
        case .ecmaArray(let kv):
            d.append(0x08); var n = UInt32(kv.count).bigEndian; d.append(Data(bytes: &n, count: 4))
            for (k, v) in kv { str(k, &d); write(v, into: &d) }; d.append(contentsOf: [0, 0, 9])
        }
    }
    static func decode(_ data: Data) -> [AMF0Value] {
        var i = data.startIndex
        var out: [AMF0Value] = []
        while i < data.endIndex, let v = read(data, &i) { out.append(v) }
        return out
    }
    private static func readU16(_ d: Data, _ i: inout Data.Index) -> Int? {
        guard i + 2 <= d.endIndex else { return nil }
        let v = Int(d[i]) << 8 | Int(d[i + 1]); i += 2; return v
    }
    private static func readStr(_ d: Data, _ i: inout Data.Index) -> String? {
        guard let n = readU16(d, &i), i + n <= d.endIndex else { return nil }
        let s = String(decoding: d[i..<(i + n)], as: UTF8.self); i += n; return s
    }
    private static func readProps(_ d: Data, _ i: inout Data.Index) -> [(String, AMF0Value)] {
        var kv: [(String, AMF0Value)] = []
        while i + 3 <= d.endIndex {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 9 { i += 3; break }
            guard let k = readStr(d, &i), let v = read(d, &i) else { break }
            kv.append((k, v))
        }
        return kv
    }
    static func read(_ d: Data, _ i: inout Data.Index) -> AMF0Value? {
        guard i < d.endIndex else { return nil }
        let t = d[i]; i += 1
        switch t {
        case 0x00:
            guard i + 8 <= d.endIndex else { return nil }
            var bits: UInt64 = 0
            for k in 0..<8 { bits = bits << 8 | UInt64(d[i + k]) }
            i += 8; return .number(Double(bitPattern: bits))
        case 0x01: guard i < d.endIndex else { return nil }; let b = d[i] != 0; i += 1; return .bool(b)
        case 0x02: return readStr(d, &i).map { .string($0) }
        case 0x03: return .object(readProps(d, &i))
        case 0x05: return .null
        case 0x06: return .undefined
        case 0x08: i += 4; return .ecmaArray(readProps(d, &i))
        case 0x0C:
            guard i + 4 <= d.endIndex else { return nil }
            let n = Int(d[i]) << 24 | Int(d[i+1]) << 16 | Int(d[i+2]) << 8 | Int(d[i+3]); i += 4
            guard i + n <= d.endIndex else { return nil }
            let s = String(decoding: d[i..<(i + n)], as: UTF8.self); i += n; return .string(s)
        default: return nil
        }
    }
}

// MARK: - URL

public struct RTMPURL: Equatable, Sendable {
    public let secure: Bool
    public let host: String
    public let port: Int
    public let app: String
    public let tcUrl: String
    /// Splits "rtmp(s)://host[:port]/app[/more]" into connection parts. The stream key is separate.
    public static func parse(_ s: String) -> RTMPURL? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps", let host = u.host, !host.isEmpty else { return nil }
        let secure = scheme == "rtmps"
        var path = u.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix("/") { path.removeLast() }
        let tc = s.trimmingCharacters(in: .whitespaces).hasSuffix("/") ? String(s.trimmingCharacters(in: .whitespaces).dropLast()) : s.trimmingCharacters(in: .whitespaces)
        return RTMPURL(secure: secure, host: host, port: u.port ?? (secure ? 443 : 1935), app: path, tcUrl: tc)
    }
}

/// Redacts a stream key for logs and errors ("abcd…wxyz" → "…wxyz").
public func redactKey(_ k: String) -> String { k.count <= 4 ? "…" : "…" + k.suffix(4) }

// MARK: - Client

public enum RTMPError: Error, LocalizedError, Equatable {
    case badURL
    case timeout
    case notRTMP
    case tls(String)
    case refused(String)
    case closed
    case network(String)
    public var errorDescription: String? {
        switch self {
        case .badURL: return "That isn't an rtmp:// or rtmps:// address."
        case .timeout: return "The server didn't answer within 8 seconds."
        case .notRTMP: return "The server answered, but not as an RTMP server. Check the address and port."
        case .tls(let m): return "The secure (rtmps) connection failed. \(m)"
        case .refused(let m): return "The server refused the stream (\(m))."
        case .closed: return "The server closed the connection."
        case .network(let m): return m
        }
    }
}

/// Minimal RTMP publisher (Adobe RTMP 1.0 + FLV payloads) on Network.framework.
public final class RTMPConnection: @unchecked Sendable {
    public enum State: Equatable { case idle, connecting, publishing, failed(RTMPError), closed }
    public private(set) var state: State = .idle
    public var onStateChange: ((State) -> Void)?
    public private(set) var bytesSent: Int64 = 0
    public private(set) var handshakeRTT: Double = 0
    /// Stop after the server accepts `connect` (used by "Test & save"; never publishes).
    public var probeOnly = false

    private let url: RTMPURL
    private let key: String
    private let queue: DispatchQueue
    private var conn: NWConnection?
    private var inbox = Data()
    private var chunkSizeOut = 4096
    private var chunkSizeIn = 128
    private var windowAck = 2_500_000
    private var received: Int64 = 0
    private var lastAck: Int64 = 0
    private var streamID: Double = 1
    private var txn: Double = 1
    private var pendingCreate: Double = 0
    private var handshakeDone = false
    private var publishContinuation: ((Result<Void, RTMPError>) -> Void)?
    private struct InChunk { var ts: UInt32 = 0; var length = 0; var type: UInt8 = 0; var streamID: UInt32 = 0; var payload = Data(); var tsDelta: UInt32 = 0 }
    private var inChunks: [UInt32: InChunk] = [:]
    private var sendBuffered = 0
    private let sendLock = NSLock()

    public init(url: RTMPURL, key: String, queue: DispatchQueue) {
        self.url = url; self.key = key; self.queue = queue
    }

    /// Bytes handed to the network but not yet acknowledged by the kernel (backpressure signal).
    public var unsentBytes: Int { sendLock.lock(); defer { sendLock.unlock() }; return sendBuffered }

    private func setState(_ s: State) {
        guard state != s else { return }
        state = s
        onStateChange?(s)
    }

    /// Connects, handshakes and starts publishing. `completion` runs on the connection queue.
    public func connect(timeout: Double = 8, completion: @escaping (Result<Void, RTMPError>) -> Void) {
        setState(.connecting)
        publishContinuation = completion
        let params: NWParameters
        if url.secure {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, url.host)
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            params = NWParameters(tls: nil, tcp: tcp)
        }
        let c = NWConnection(host: NWEndpoint.Host(url.host), port: NWEndpoint.Port(integerLiteral: UInt16(url.port)), using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.startHandshake()
            case .failed(let e): self.fail(Self.mapError(e))
            case .waiting(let e):
                // Network.framework waits on unreachable hosts; treat as failure so reconnect logic runs.
                self.fail(Self.mapError(e))
            case .cancelled: break
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            if self.state == .connecting { self.fail(self.handshakeDone ? .refused("no answer to publish") : .timeout) }
        }
    }

    static func mapError(_ e: NWError) -> RTMPError {
        switch e {
        case .tls(let s): return .tls("TLS error \(s)")
        case .posix(let p) where p == .ECONNREFUSED: return .network("Connection refused. Is the server running and the port right?")
        case .dns: return .network("The server name couldn't be found.")
        default: return .network(e.localizedDescription)
        }
    }

    private func fail(_ e: RTMPError) {
        if case .failed = state { return }
        if state == .closed { return }
        setState(.failed(e))
        conn?.cancel()
        if let k = publishContinuation { publishContinuation = nil; k(.failure(e)) }
    }

    public func close() {
        guard state != .closed else { return }
        if state == .publishing {
            sendCommand([.string("FCUnpublish"), .number(nextTxn()), .null, .string(key)], csid: 3, stream: 0)
            sendCommand([.string("deleteStream"), .number(nextTxn()), .null, .number(streamID)], csid: 3, stream: 0)
        }
        setState(.closed)
        let c = conn
        queue.asyncAfter(deadline: .now() + 0.2) { c?.cancel() }
    }

    private func nextTxn() -> Double { txn += 1; return txn }

    // MARK: Handshake

    private func startHandshake() {
        let start = Date()
        var c0c1 = Data([0x03])
        c0c1.append(Data(count: 8))
        var rnd = [UInt8](repeating: 0, count: 1528)
        for i in 0..<rnd.count { rnd[i] = UInt8.random(in: 0...255) }
        c0c1.append(contentsOf: rnd)
        write(c0c1)
        // Check S0 on its own first, so a non-RTMP server (HTTP, TLS on a plain port…) is reported as such.
        read(exactly: 1) { [weak self] s0 in
            guard let self else { return }
            guard let s0, s0.first == 0x03 else { self.fail(s0 == nil ? .closed : .notRTMP); return }
            self.read(exactly: 1536 + 1536) { [weak self] data in
                guard let self, let data else { self?.fail(.notRTMP); return }
                self.handshakeRTT = Date().timeIntervalSince(start)
                let s1 = data.subdata(in: data.startIndex..<(data.startIndex + 1536))
                self.write(s1)   // C2 echoes S1
                self.handshakeDone = true
                self.afterHandshake()
                self.receiveLoop()
            }
        }
    }

    private func read(exactly n: Int, _ done: @escaping (Data?) -> Void) {
        guard let conn else { done(nil); return }
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
            if let data, data.count == n { done(data) }
            else if err != nil || data == nil { done(nil) }
            else {
                // Partial read: keep reading the remainder.
                let got = data!
                self.read(exactly: n - got.count) { rest in done(rest.map { got + $0 }) }
            }
        }
    }

    private func afterHandshake() {
        // Set Chunk Size, then connect.
        var cs = UInt32(chunkSizeOut).bigEndian
        sendMessage(type: 1, csid: 2, stream: 0, ts: 0, payload: Data(bytes: &cs, count: 4))
        let connect: [AMF0Value] = [
            .string("connect"), .number(1),
            .object([("app", .string(url.app)), ("type", .string("nonprivate")),
                     ("flashVer", .string("FMLE/3.0 (compatible; Framecast)")), ("tcUrl", .string(url.tcUrl))]),
        ]
        sendCommand(connect, csid: 3, stream: 0)
    }

    // MARK: Sending

    private func write(_ d: Data) {
        sendLock.lock(); sendBuffered += d.count; sendLock.unlock()
        conn?.send(content: d, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.sendLock.lock(); self.sendBuffered -= d.count; self.sendLock.unlock()
            self.bytesSent += Int64(d.count)
            if let err { self.queue.async { self.fail(Self.mapError(err)) } }
        })
    }

    private func sendCommand(_ values: [AMF0Value], csid: UInt8, stream: UInt32) {
        sendMessage(type: 20, csid: csid, stream: stream, ts: 0, payload: AMF0.encode(values))
    }

    /// Serialises one RTMP message into chunks (type-0 header, then type-3 continuations).
    func sendMessage(type: UInt8, csid: UInt8, stream: UInt32, ts: UInt32, payload: Data) {
        var out = Data(capacity: payload.count + 32)
        let ext = ts >= 0xFFFFFF
        out.append(csid & 0x3F)
        let t3 = ext ? 0xFFFFFF : ts
        out.append(UInt8((t3 >> 16) & 0xFF)); out.append(UInt8((t3 >> 8) & 0xFF)); out.append(UInt8(t3 & 0xFF))
        let len = payload.count
        out.append(UInt8((len >> 16) & 0xFF)); out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        out.append(type)
        var sid = stream.littleEndian; out.append(Data(bytes: &sid, count: 4))
        var extBytes = Data()
        if ext { var e = ts.bigEndian; extBytes = Data(bytes: &e, count: 4); out.append(extBytes) }
        var off = 0
        while off < len {
            let n = min(chunkSizeOut, len - off)
            if off > 0 { out.append(0xC0 | (csid & 0x3F)); if ext { out.append(extBytes) } }
            out.append(payload[payload.startIndex + off ..< payload.startIndex + off + n])
            off += n
        }
        if len == 0 { /* header only */ }
        write(out)
    }

    // MARK: FLV payloads

    public func sendMetadata(width: Int, height: Int, fps: Int, videoKbps: Int, audioKbps: Int, hevc: Bool) {
        let meta: [(String, AMF0Value)] = [
            ("duration", .number(0)), ("width", .number(Double(width))), ("height", .number(Double(height))),
            ("videodatarate", .number(Double(videoKbps))), ("framerate", .number(Double(fps))),
            ("videocodecid", .number(hevc ? 12 : 7)), ("audiodatarate", .number(Double(audioKbps))),
            ("audiosamplerate", .number(48_000)), ("audiosamplesize", .number(16)), ("stereo", .bool(true)),
            ("audiocodecid", .number(10)), ("encoder", .string("Framecast")),
        ]
        let payload = AMF0.encode([.string("@setDataFrame"), .string("onMetaData"), .ecmaArray(meta)])
        sendMessage(type: 18, csid: 4, stream: UInt32(streamID), ts: 0, payload: payload)
    }

    public func sendVideoConfig(_ avcC: Data) {
        sendMessage(type: 9, csid: 6, stream: UInt32(streamID), ts: 0, payload: Data([0x17, 0x00, 0, 0, 0]) + avcC)
    }
    public func sendAudioConfig(_ asc: Data) {
        sendMessage(type: 8, csid: 4, stream: UInt32(streamID), ts: 0, payload: Data([0xAF, 0x00]) + asc)
    }
    public func sendVideo(_ nalus: Data, key: Bool, ts: UInt32) {
        sendMessage(type: 9, csid: 6, stream: UInt32(streamID), ts: ts, payload: Data([key ? 0x17 : 0x27, 0x01, 0, 0, 0]) + nalus)
    }
    public func sendAudio(_ aac: Data, ts: UInt32) {
        sendMessage(type: 8, csid: 4, stream: UInt32(streamID), ts: ts, payload: Data([0xAF, 0x01]) + aac)
    }

    // MARK: Receiving

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.received += Int64(data.count)
                self.inbox.append(data)
                self.parseInbox()
                if self.received - self.lastAck >= Int64(self.windowAck) {
                    self.lastAck = self.received
                    var v = UInt32(truncatingIfNeeded: self.received).bigEndian
                    self.sendMessage(type: 3, csid: 2, stream: 0, ts: 0, payload: Data(bytes: &v, count: 4))
                }
            }
            if complete || err != nil {
                if self.state == .publishing || self.state == .connecting { self.fail(.closed) }
                return
            }
            self.receiveLoop()
        }
    }

    private func parseInbox() {
        while true {
            var i = inbox.startIndex
            guard i < inbox.endIndex else { return }
            let b0 = inbox[i]; i += 1
            let fmt = b0 >> 6
            var csid = UInt32(b0 & 0x3F)
            if csid == 0 { guard i < inbox.endIndex else { return }; csid = 64 + UInt32(inbox[i]); i += 1 }
            else if csid == 1 { guard i + 1 < inbox.endIndex else { return }; csid = 64 + UInt32(inbox[i]) + 256 * UInt32(inbox[i + 1]); i += 2 }
            let hlen = [11, 7, 3, 0][Int(fmt)]
            guard i + hlen <= inbox.endIndex else { return }
            var ch = inChunks[csid] ?? InChunk()
            func u24(_ p: Int) -> UInt32 { UInt32(inbox[p]) << 16 | UInt32(inbox[p + 1]) << 8 | UInt32(inbox[p + 2]) }
            var tsField: UInt32 = 0
            if fmt <= 2 { tsField = u24(i) }
            if fmt <= 1 { ch.length = Int(u24(i + 3)); ch.type = inbox[i + 6] }
            if fmt == 0 { ch.streamID = UInt32(inbox[i + 7]) | UInt32(inbox[i + 8]) << 8 | UInt32(inbox[i + 9]) << 16 | UInt32(inbox[i + 10]) << 24 }
            i += hlen
            if tsField == 0xFFFFFF { guard i + 4 <= inbox.endIndex else { return }; tsField = u24(i) << 8 | UInt32(inbox[i + 3]); i += 4 }
            if fmt == 0 { ch.ts = tsField } else if fmt <= 2 { ch.tsDelta = tsField; ch.ts &+= tsField }
            let remaining = ch.length - ch.payload.count
            let n = min(chunkSizeIn, max(0, remaining))
            guard i + n <= inbox.endIndex else { return }
            ch.payload.append(inbox[i..<(i + n)])
            i += n
            inbox.removeSubrange(inbox.startIndex..<i)
            if ch.payload.count >= ch.length {
                let msg = ch.payload
                ch.payload = Data()
                inChunks[csid] = ch
                handle(type: ch.type, payload: msg)
            } else {
                inChunks[csid] = ch
            }
        }
    }

    private func handle(type: UInt8, payload: Data) {
        func be32(_ d: Data) -> Int { d.count >= 4 ? Int(d[d.startIndex]) << 24 | Int(d[d.startIndex+1]) << 16 | Int(d[d.startIndex+2]) << 8 | Int(d[d.startIndex+3]) : 0 }
        switch type {
        case 1: chunkSizeIn = max(1, be32(payload) & 0x7FFFFFFF)
        case 5: windowAck = max(1, be32(payload))
        case 4:
            // User control: answer ping requests (event 6) with ping responses (event 7).
            if payload.count >= 6, payload[payload.startIndex + 1] == 6 {
                sendMessage(type: 4, csid: 2, stream: 0, ts: 0, payload: Data([0, 7]) + payload.suffix(4))
            }
        case 20:
            let v = AMF0.decode(payload)
            guard let name = v.first?.string else { return }
            let t = v.count > 1 ? (v[1].number ?? 0) : 0
            switch name {
            case "_result":
                if t == 1 && probeOnly {
                    if let k = publishContinuation { publishContinuation = nil; k(.success(())) }
                    close(); return
                }
                if t == 1 {
                    sendCommand([.string("releaseStream"), .number(nextTxn()), .null, .string(key)], csid: 3, stream: 0)
                    sendCommand([.string("FCPublish"), .number(nextTxn()), .null, .string(key)], csid: 3, stream: 0)
                    pendingCreate = nextTxn()
                    sendCommand([.string("createStream"), .number(pendingCreate), .null], csid: 3, stream: 0)
                } else if t == pendingCreate {
                    streamID = v.count > 3 ? (v[3].number ?? 1) : 1
                    sendCommand([.string("publish"), .number(nextTxn()), .null, .string(key), .string("live")], csid: 4, stream: UInt32(streamID))
                }
            case "_error":
                let desc = v.compactMap { $0["description"]?.string ?? $0["code"]?.string }.first ?? "error"
                if t == 1 { fail(.refused("connect: \(desc)")) }
            case "onStatus":
                let info = v.count > 3 ? v[3] : .null
                let code = info["code"]?.string ?? ""
                if code == "NetStream.Publish.Start" {
                    setState(.publishing)
                    if let k = publishContinuation { publishContinuation = nil; k(.success(())) }
                } else if code.hasPrefix("NetStream.Publish.") || code.contains("Failed") || code.contains("Rejected") {
                    fail(.refused(code))
                }
            default: break
            }
        default: break
        }
    }
}
