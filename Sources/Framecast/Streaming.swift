import Foundation
import Observation
import FramecastEngine

/// Go live / end stream across every switched-on destination, with per-destination status.
@Observable
final class StreamingController {
    enum Phase: Equatable { case idle, starting(String), live(Date), stopping }
    unowned let studio: Studio
    let destinations = DestinationsStore()
    var phase: Phase = .idle
    var statuses: [UUID: StreamStatus] = [:]
    var stats: [UUID: StreamStats] = [:]
    var reports: [SessionSummary.StreamReport] = []
    var lastError: String?
    @ObservationIgnored private var outputs: [UUID: StreamOutput] = [:]

    init(studio: Studio) { self.studio = studio }

    var isLive: Bool { if case .live = phase { return true }; return false }
    var liveSince: Date? { if case .live(let d) = phase { return d }; return nil }
    var enabled: [Destination] { destinations.items.filter(\.isOn) }
    var anyReconnecting: Bool { statuses.values.contains { if case .reconnecting = $0 { return true }; return false } }
    var liveCount: Int { statuses.values.filter { $0 == .live }.count }

    /// Picture size for a destination: the canvas, scaled down to the platform's limit.
    func size(for d: Destination) -> (Int, Int, Int) {
        let c = studio.settings.canvas(d.canvas)
        var w = c.width, h = c.height
        let long = max(w, h), cap = d.maxHeight * 16 / 9
        let limit = d.canvas == .horizontal ? d.maxHeight : cap
        if (d.canvas == .horizontal ? h : long) > limit {
            let k = Double(limit) / Double(d.canvas == .horizontal ? h : long)
            w = Int(Double(w) * k) & ~1; h = Int(Double(h) * k) & ~1
        }
        return (w, h, min(c.fps, d.fps))
    }

    func goLive(recordToo: Bool) {
        guard phase == .idle else { return }
        let targets = enabled
        guard !targets.isEmpty else { lastError = "Add a destination first: add a stream key or a custom RTMP server."; return }
        if DestinationsStore.isTestLaunch, let d = targets.first(where: { !DestinationsStore.isThisMac($0.server) }) {
            lastError = "Test launches only stream to this Mac; \(d.name) was not started."; return
        }
        studio.warnIfSilent()
        for d in targets where d.canvas == .vertical && !studio.isVerticalOn {
            lastError = "\(d.name) streams the vertical canvas, which is off (Settings › Video)."; return
        }
        phase = .starting("Setting up your streams…")
        lastError = nil
        for d in targets {
            let key = destinations.key(for: d)
            let (w, h, fps) = size(for: d)
            let spec = StreamSpec(name: d.name, url: d.server, key: key, canvas: d.canvas, width: w, height: h, fps: fps,
                                  videoKbps: d.videoKbps, autoReconnect: d.autoReconnect, adaptiveBitrate: d.adaptiveBitrate)
            do {
                let id = d.id
                let out = try studio.engine.startStream(spec) { [weak self] st in self?.statusChanged(id, st) }
                outputs[d.id] = out
                statuses[d.id] = .connecting
            } catch {
                statuses[d.id] = .failed("Hardware video encoder unavailable (\(error.localizedDescription))")
            }
        }
        if studio.sessionStart == nil { studio.sessionStart = Date() }
        studio.holdSleep(true)
        if recordToo && !studio.isRecording { studio.startRecording() }
    }

    private func statusChanged(_ id: UUID, _ st: StreamStatus) {
        statuses[id] = st
        if st == .live, case .starting = phase { phase = .live(Date()) }
        if case .reconnecting(let a, _, let reason) = st, a == 1, let d = destinations.items.first(where: { $0.id == id }) {
            studio.alerts.append(AlertItem(title: "\(d.name) reconnecting", detail: "Network dropped on this stream only. Retrying with backoff; other streams and recordings are unaffected. (\(reason))"))
        }
        if st == .live, let d = destinations.items.first(where: { $0.id == id }) {
            studio.alerts.removeAll { $0.title == "\(d.name) reconnecting" }
        }
        // Every destination failed outright: give up the attempt.
        if case .starting = phase, statuses.values.allSatisfy({ if case .failed = $0 { return true }; return false }) {
            let reasons = statuses.values.compactMap { if case .failed(let m) = $0 { return m }; return nil }
            lastError = "Couldn't start streaming. " + (reasons.first ?? "")
            endStream(makeSummary: false)
        }
    }

    func endStream(makeSummary: Bool = true) {
        guard phase != .idle else { return }
        phase = .stopping
        for (id, o) in outputs {
            let d = destinations.items.first { $0.id == id }
            let s = o.stats
            reports.append(.init(name: d?.name ?? o.spec.name, canvas: o.spec.canvas.title, uptime: formatClock(s.uptime),
                                 bitrate: String(format: "%.1f Mbps", Double(s.currentBitrateKbps) / 1000),
                                 dropped: s.droppedFrames, reconnects: s.reconnects))
            studio.engine.stopStream(o)
        }
        outputs.removeAll()
        statuses.removeAll()
        stats.removeAll()
        phase = .idle
        if !studio.isRecording { studio.holdSleep(false); if makeSummary { studio.makeSummary() } }
    }

    func poll() {
        for (id, o) in outputs { stats[id] = o.stats }
    }

    /// "Test & save" for the custom server form: connect, handshake, then close.
    static func probe(server: String, key: String, completion: @escaping (String?) -> Void) {
        guard let url = RTMPURL.parse(server) else { completion(RTMPError.badURL.localizedDescription); return }
        let q = DispatchQueue(label: "framecast.probe")
        let c = RTMPConnection(url: url, key: key.isEmpty ? "framecast-probe" : key, queue: q)
        c.probeOnly = true   // checks the server answers as RTMP; the key is only used when you go live
        var done = false
        c.connect { r in
            guard !done else { return }; done = true
            c.close()
            DispatchQueue.main.async {
                switch r { case .success: completion(nil); case .failure(let e): completion(e.localizedDescription) }
            }
        }
    }
}
