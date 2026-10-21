import Foundation
import CoreMedia

/// Minimal Matroska muxer: one H.264/HEVC track and up to six AAC tracks. Clusters are written whole as
/// they close, so a crash loses at most the last ~2 seconds.
final class MKVWriter {
    struct Packet { let ms: Int64; let data: Data; let key: Bool; let track: Int }

    private let handle: FileHandle
    let url: URL
    private let audioTracks: [Int]          // Framecast track numbers (1 = program, 2…6)
    private let video: (codec: VideoCodec, width: Int, height: Int, fps: Int)
    private var headerWritten = false
    private var durationOffset: UInt64 = 0
    private var videoQ: [Packet] = []
    private var audioQ: [Int: [Packet]] = [:]
    private var lastVideoMs: Int64 = .min
    private var lastAudioMs: [Int: Int64] = [:]
    private var cluster = Data()
    private var clusterStart: Int64?
    private var maxMs: Int64 = 0
    private(set) var bytesWritten: Int64 = 0
    private(set) var failure: String?

    init(url: URL, video: (VideoCodec, Int, Int, Int), audioTracks: [Int]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "Framecast.MKV", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't create \(url.lastPathComponent)"])
        }
        handle = h; self.url = url; self.audioTracks = audioTracks
        self.video = (video.0, video.1, video.2, video.3)
        for t in audioTracks { audioQ[t] = []; lastAudioMs[t] = .min }
    }

    // MARK: EBML helpers

    static func vint(_ v: UInt64) -> Data {
        var len = 1
        while len < 8 && v >= (UInt64(1) << (7 * UInt64(len))) - 1 { len += 1 }
        var out = Data(count: len)
        for i in 0..<len { out[len - 1 - i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) }
        out[0] |= UInt8(0x80 >> (len - 1))
        return out
    }
    static func id(_ v: UInt32) -> Data {
        var bytes: [UInt8] = []
        var x = v
        while x > 0 { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return Data(bytes)
    }
    static func el(_ i: UInt32, _ payload: Data) -> Data { id(i) + vint(UInt64(payload.count)) + payload }
    static func uint(_ i: UInt32, _ v: UInt64) -> Data {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return el(i, Data(bytes))
    }
    static func str(_ i: UInt32, _ s: String) -> Data { el(i, Data(s.utf8)) }
    static func float(_ i: UInt32, _ v: Double) -> Data {
        var be = v.bitPattern.bigEndian
        return el(i, Data(bytes: &be, count: 8))
    }

    private func write(_ d: Data) {
        guard failure == nil else { return }
        do { try handle.write(contentsOf: d); bytesWritten += Int64(d.count) }
        catch { failure = "Write failed: \(error.localizedDescription)" }
    }

    private func writeHeader(videoPrivate: Data) {
        let ebml = Self.el(0x1A45DFA3, Self.uint(0x4286, 1) + Self.uint(0x42F7, 1) + Self.uint(0x42F2, 4) + Self.uint(0x42F3, 8)
                           + Self.str(0x4282, "matroska") + Self.uint(0x4287, 4) + Self.uint(0x4285, 2))
        write(ebml)
        // Segment with unknown size: readers accept it, and nothing has to be patched if we crash.
        write(Self.id(0x18538067) + Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        let infoPrefix = Self.uint(0x2AD7B1, 1_000_000) + Self.str(0x4D80, "Framecast") + Self.str(0x5741, "Framecast")
        let infoPayload = infoPrefix + Self.float(0x4489, 0)
        let info = Self.el(0x1549A966, infoPayload)
        // Duration's 8 data bytes are the last 8 bytes of the Info element.
        durationOffset = UInt64(bytesWritten) + UInt64(info.count) - 8
        write(info)

        var tracks = Data()
        let codecID = video.codec == .h264 ? "V_MPEG4/ISO/AVC" : "V_MPEGH/ISO/HEVC"
        let videoEl = Self.el(0xE0, Self.uint(0xB0, UInt64(video.width)) + Self.uint(0xBA, UInt64(video.height)))
        tracks += Self.el(0xAE, Self.uint(0xD7, 1) + Self.uint(0x73C5, 1) + Self.uint(0x83, 1) + Self.str(0x86, codecID)
                          + Self.el(0x63A2, videoPrivate) + Self.uint(0x23E383, UInt64(1_000_000_000 / max(1, video.fps)))
                          + Self.str(0x536E, "Video") + videoEl)
        for (i, t) in audioTracks.enumerated() {
            let num = UInt64(2 + i)
            let audioEl = Self.el(0xE1, Self.float(0xB5, 48_000) + Self.uint(0x9F, 2))
            tracks += Self.el(0xAE, Self.uint(0xD7, num) + Self.uint(0x73C5, num) + Self.uint(0x83, 2) + Self.str(0x86, "A_AAC")
                              + Self.el(0x63A2, AACEncoder.audioSpecificConfig) + Self.str(0x536E, t == 1 ? "Program" : "Track \(t)")
                              + Self.uint(0x88, i == 0 ? 1 : 0) + audioEl)
        }
        write(Self.el(0x1654AE6B, tracks))
        headerWritten = true
    }

    // MARK: Packets

    func addVideo(_ f: EncodedVideoFrame, ms: Int64) {
        if !headerWritten {
            guard f.isKeyframe, let rec = VideoEncoder.configurationRecord(f.format) else { return }
            writeHeader(videoPrivate: rec)
        }
        videoQ.append(Packet(ms: ms, data: f.data, key: f.isKeyframe, track: 1))
        lastVideoMs = ms
        flush(final: false)
    }

    func addAudio(_ p: EncodedAudioPacket, track: Int, ms: Int64) {
        guard audioQ[track] != nil else { return }
        audioQ[track]!.append(Packet(ms: ms, data: p.data, key: true, track: track))
        lastAudioMs[track] = ms
        flush(final: false)
    }

    private func blockTrackNumber(_ p: Packet, isVideo: Bool) -> UInt64 {
        isVideo ? 1 : UInt64(2 + (audioTracks.firstIndex(of: p.track) ?? 0))
    }

    private func flush(final: Bool) {
        guard headerWritten else { return }
        let horizon: Int64 = final ? .max : ([lastVideoMs] + audioTracks.map { lastAudioMs[$0] ?? .min }).min() ?? .min
        while true {
            // Next packet in timestamp order across all queues.
            var best: (isVideo: Bool, track: Int, ms: Int64)?
            if let v = videoQ.first { best = (true, 1, v.ms) }
            for t in audioTracks { if let a = audioQ[t]?.first, best == nil || a.ms < best!.ms { best = (false, t, a.ms) } }
            guard let b = best, b.ms <= horizon else { break }
            let p = b.isVideo ? videoQ.removeFirst() : audioQ[b.track]!.removeFirst()
            if let cs = clusterStart {
                let tooLong = p.ms - cs > 5_000 || p.ms - cs < -30_000
                if (b.isVideo && p.key && p.ms - cs >= 1_000) || tooLong { closeCluster() }
            }
            if clusterStart == nil { clusterStart = p.ms; cluster = Self.uint(0xE7, UInt64(max(0, p.ms))) }
            let rel = Int16(clamping: p.ms - clusterStart!)
            var block = Self.vint(blockTrackNumber(p, isVideo: b.isVideo))
            block.append(UInt8(UInt16(bitPattern: rel) >> 8)); block.append(UInt8(UInt16(bitPattern: rel) & 0xFF))
            block.append(p.key ? 0x80 : 0x00)
            block.append(p.data)
            cluster += Self.el(0xA3, block)
            maxMs = max(maxMs, p.ms)
        }
    }

    private func closeCluster() {
        guard clusterStart != nil else { return }
        write(Self.el(0x1F43B675, cluster))
        cluster = Data(); clusterStart = nil
    }

    func finish(durationMs: Int64) {
        flush(final: true)
        closeCluster()
        if headerWritten, failure == nil {
            do {
                try handle.seek(toOffset: durationOffset)
                var be = Double(max(durationMs, maxMs)).bitPattern.bigEndian
                try handle.write(contentsOf: Data(bytes: &be, count: 8))
                try handle.seekToEnd()
            } catch { failure = "Write failed: \(error.localizedDescription)" }
        }
        try? handle.synchronize()
        try? handle.close()
    }
}
