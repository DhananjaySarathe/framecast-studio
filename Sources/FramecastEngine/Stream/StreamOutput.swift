import Foundation
import CoreMedia
import CoreVideo

public struct StreamSpec: Sendable {
    public var name: String
    public var url: String
    public var key: String
    public var canvas: CanvasKind
    public var width: Int, height: Int, fps: Int
    public var videoKbps: Int
    public var minVideoKbps: Int
    public var audioKbps = 160
    public var keyframeSeconds = 2
    public var maxQueueMs = 4_000
    public var autoReconnect = true
    public var adaptiveBitrate = true
    public init(name: String, url: String, key: String, canvas: CanvasKind, width: Int, height: Int, fps: Int, videoKbps: Int,
                minVideoKbps: Int? = nil, autoReconnect: Bool = true, adaptiveBitrate: Bool = true) {
        self.name = name; self.url = url; self.key = key; self.canvas = canvas; self.width = width; self.height = height
        self.fps = fps; self.videoKbps = videoKbps; self.minVideoKbps = minVideoKbps ?? max(500, videoKbps / 3)
        self.autoReconnect = autoReconnect; self.adaptiveBitrate = adaptiveBitrate
    }
}

public enum StreamStatus: Equatable, Sendable {
    case connecting
    case live
    case reconnecting(attempt: Int, retryIn: Double, reason: String)
    case failed(String)
    case stopped
}

public struct StreamStats: Sendable {
    public var bytesSent: Int64 = 0
    public var sendKbps: Double = 0
    public var currentBitrateKbps = 0
    public var droppedFrames = 0
    public var reconnects = 0
    public var queuedMs: Double = 0
    public var uptime: Double = 0
    public var liveSince: Date?
    public var lastHandoffGap: Double = 0
}

/// One live destination: encoders → FLV/RTMP with bounded queue, adaptive bitrate and auto-reconnect.
public final class StreamOutput: CanvasFrameConsumer, AudioBlockConsumer, @unchecked Sendable {
    public let spec: StreamSpec
    public private(set) var status: StreamStatus = .connecting
    public var onStatus: ((StreamStatus) -> Void)?
    public private(set) var stats = StreamStats()
    private let queue = DispatchQueue(label: "framecast.stream")
    private let encoder: VideoEncoder
    private let aac: AACEncoder
    private weak var mixer: AudioMixer?
    private var conn: RTMPConnection?
    private var url: RTMPURL?
    private var stopping = false
    private var attempt = 0
    private var base: CMTime?
    private var videoConfig: Data?
    private var configSent = false
    private var waitingForKey = true
    private struct Item { let ms: Int64; let data: Data; let key: Bool; let video: Bool }
    private var videoQ: [Item] = []
    private var audioQ: [Item] = []
    private var lastVideoMs: Int64 = .min, lastAudioMs: Int64 = .min
    private var lastSentMs: Int64 = 0
    private var bitrate: Int
    private var calmSince = Date()
    private var lastRateCheck = Date()
    private var lastBytes: Int64 = 0
    private var disconnectedAt: Date?

    public init(spec: StreamSpec, mixer: AudioMixer) throws {
        self.spec = spec
        self.mixer = mixer
        bitrate = spec.videoKbps
        encoder = try VideoEncoder(config: .init(width: spec.width, height: spec.height, fps: spec.fps, codec: .h264,
                                                 bitrateKbps: spec.videoKbps, keyframeSeconds: spec.keyframeSeconds))
        aac = try AACEncoder(bitrateKbps: spec.audioKbps)
        encoder.onFrame = { [weak self] f in self?.queue.async { self?.handleVideo(f) } }
        aac.onPacket = { [weak self] p in self?.queue.async { self?.handleAudio(p) } }
        stats.currentBitrateKbps = bitrate
    }

    private func set(_ s: StreamStatus) {
        status = s
        let cb = onStatus
        DispatchQueue.main.async { cb?(s) }
    }

    public func start() {
        guard let u = RTMPURL.parse(spec.url) else { set(.failed(RTMPError.badURL.localizedDescription)); return }
        url = u
        queue.async { self.connect() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.everySecond() }
        t.resume()
        meterSource = t
    }
    private var meterSource: DispatchSourceTimer?

    private func connect() {
        guard !stopping, let url else { return }
        let c = RTMPConnection(url: url, key: spec.key, queue: queue)
        conn = c
        configSent = false
        waitingForKey = true
        base = nil
        videoQ.removeAll(); audioQ.removeAll()
        lastVideoMs = .min; lastAudioMs = .min; lastSentMs = 0
        c.onStateChange = { [weak self] st in
            guard let self, case .failed(let e) = st, c === self.conn else { return }
            self.lostConnection(e.localizedDescription)
        }
        c.connect { [weak self] result in
            guard let self, c === self.conn else { return }
            switch result {
            case .success:
                if self.attempt > 0 { self.stats.reconnects += 1 }
                if let d = self.disconnectedAt { self.stats.lastHandoffGap = Date().timeIntervalSince(d); self.disconnectedAt = nil }
                self.attempt = 0
                c.sendMetadata(width: self.spec.width, height: self.spec.height, fps: self.spec.fps, videoKbps: self.bitrate,
                               audioKbps: self.spec.audioKbps, hevc: false)
                c.sendAudioConfig(AACEncoder.audioSpecificConfig)
                self.encoder.requestKeyframe()
                if self.stats.liveSince == nil { self.stats.liveSince = Date() }
                self.set(.live)
            case .failure(let e):
                self.lostConnection(e.localizedDescription)
            }
        }
    }

    private func lostConnection(_ reason: String) {
        guard !stopping else { return }
        conn?.close()
        conn = nil
        if disconnectedAt == nil { disconnectedAt = Date() }
        guard spec.autoReconnect else { set(.failed(reason)); return }
        attempt += 1
        // Backoff 1, 2, 3, 5, 5 … seconds: quick recovery from short drops, no hammering on long ones.
        let delay = [1.0, 2, 3, 5][min(attempt - 1, 3)]
        set(.reconnecting(attempt: attempt, retryIn: delay, reason: reason))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    public func stop() {
        queue.async {
            self.stopping = true
            self.meterSource?.cancel()
            self.conn?.close()
            self.conn = nil
            self.set(.stopped)
        }
        encoder.finish()
    }

    // MARK: Inputs

    public func consume(_ pb: CVPixelBuffer, pts: CMTime, canvas: CanvasKind) {
        guard canvas == spec.canvas, !stopping else { return }
        encoder.encode(pb, pts: pts)
    }

    public func consume(_ block: AudioBlock) {
        guard !stopping else { return }
        aac.append(block.program, timelineIndex: block.timelineIndex)
    }

    private func ms(_ host: CMTime) -> Int64? {
        guard let base else { return nil }
        return Int64((CMTimeGetSeconds(CMTimeSubtract(host, base)) * 1000).rounded())
    }

    private func handleVideo(_ f: EncodedVideoFrame) {
        if videoConfig == nil || f.isKeyframe, let rec = VideoEncoder.configurationRecord(f.format) { videoConfig = rec }
        guard let conn, conn.state == .publishing else { return }
        if waitingForKey {
            guard f.isKeyframe else { return }
            waitingForKey = false
            base = f.pts
        }
        if !configSent, let cfg = videoConfig { conn.sendVideoConfig(cfg); configSent = true }
        // Backlog guard: if the network can't keep up, drop to the next keyframe instead of queueing forever.
        if stats.queuedMs > Double(spec.maxQueueMs) && !f.isKeyframe {
            stats.droppedFrames += 1
            if !droppingToKey { droppingToKey = true; encoder.requestKeyframe() }
            return
        }
        if droppingToKey { if f.isKeyframe { droppingToKey = false } else { stats.droppedFrames += 1; return } }
        guard let m = ms(f.pts) else { return }
        videoQ.append(Item(ms: m, data: f.data, key: f.isKeyframe, video: true))
        lastVideoMs = m
        flush()
    }
    private var droppingToKey = false

    private func handleAudio(_ p: EncodedAudioPacket) {
        guard let conn, conn.state == .publishing, base != nil, let mixer else { return }
        let host = CMTimeAdd(mixer.origin, p.pts)
        guard let m = ms(host), m >= 0 else { return }
        audioQ.append(Item(ms: m, data: p.data, key: true, video: false))
        lastAudioMs = m
        flush()
    }

    /// Sends queued packets in timestamp order, up to the point both tracks have reached.
    private func flush() {
        guard let conn, conn.state == .publishing else { return }
        let horizon = min(lastVideoMs, lastAudioMs)
        while true {
            let v = videoQ.first, a = audioQ.first
            var next: Item?
            if let v, let a { next = v.ms <= a.ms ? v : a } else { next = v ?? a }
            guard let n = next, n.ms <= horizon || videoQ.count > 120 || audioQ.count > 200 else { break }
            if n.video { videoQ.removeFirst() } else { audioQ.removeFirst() }
            let ts = UInt32(clamping: max(n.ms, lastSentMs))   // never go backwards
            lastSentMs = Int64(ts)
            if n.video { conn.sendVideo(n.data, key: n.key, ts: ts) } else { conn.sendAudio(n.data, ts: ts) }
        }
    }

    // MARK: Metering and adaptive bitrate

    private func everySecond() {
        guard let conn else { return }
        let sent = conn.bytesSent
        let dt = max(0.001, Date().timeIntervalSince(lastRateCheck))
        stats.sendKbps = Double(sent - lastBytes) * 8 / 1000 / dt
        lastBytes = sent; lastRateCheck = Date()
        stats.bytesSent = sent
        let rateBytesPerMs = Double(bitrate + spec.audioKbps) / 8
        stats.queuedMs = Double(conn.unsentBytes) / max(1, rateBytesPerMs)
        if let since = stats.liveSince { stats.uptime = Date().timeIntervalSince(since) }
        guard spec.adaptiveBitrate, conn.state == .publishing else { return }
        if stats.queuedMs > 700 {
            let nb = max(spec.minVideoKbps, Int(Double(bitrate) * 0.8))
            if nb != bitrate { bitrate = nb; encoder.setBitrate(kbps: nb) }
            calmSince = Date()
        } else if stats.queuedMs < 150, Date().timeIntervalSince(calmSince) > 10, bitrate < spec.videoKbps {
            bitrate = min(spec.videoKbps, Int(Double(bitrate) * 1.15) + 100)
            encoder.setBitrate(kbps: bitrate)
            calmSince = Date()
        }
        stats.currentBitrateKbps = bitrate
    }
}
