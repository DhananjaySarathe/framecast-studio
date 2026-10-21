import Foundation
import AVFoundation
import CoreImage
import CoreMedia

/// Plays a video or music file on the mixer's timeline, so its picture and sound stay together in recordings and
/// streams. Frames and samples are decoded a few seconds ahead with AVAssetReader on a background queue; the first
/// seconds of sound are kept so restarts and loops start instantly.
public final class MediaFileSource: VideoSource, @unchecked Sendable {
    public let id: UUID
    public let url: URL
    private let mixer: AudioMixer
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "framecast.media", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private static let sr = AudioBlock.sampleRate

    public struct Status: Sendable, Equatable {
        public var isPlaying: Bool
        public var position: Double
        public var duration: Double
        public var hasVideo: Bool
        public var hasAudio: Bool
    }

    // File
    private var loaded = false
    private var problem: String?
    private var duration: Double = 0
    private var totalFrames: Int64 = 0
    /// Readers must come from the asset the tracks belong to (AVFoundation throws otherwise).
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var size = CGSize(width: 1920, height: 1080)

    // Transport: position = anchorPos + (timeline index − anchorIndex) / sample rate while playing.
    private var playing = false
    private var anchorIndex: Int64 = 0
    private var anchorPos: Double = 0
    private var looping = false

    // Sound: the first seconds (instant restarts and seamless loops) and a moving window ahead of the playhead.
    private var head: [Float] = []
    private var buf: [Float] = []
    private var bufStart: Int64 = 0
    private var audioReader: AVAssetReader?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var audioNext: Int64 = 0
    private var audioDone = false

    // Picture
    private var frames: [(pos: Double, pb: CVPixelBuffer)] = []
    private var videoReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var videoNext: Double = 0
    private var videoDone = false
    private var current: CIImage?

    public init(id: UUID, url: URL, mixer: AudioMixer) {
        self.id = id; self.url = url; self.mixer = mixer
    }

    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
    public static func isAudioOnly(_ path: String) -> Bool { audioExtensions.contains((path as NSString).pathExtension.lowercased()) }

    // MARK: VideoSource

    public var state: SourceState {
        lock.lock(); defer { lock.unlock() }
        if let p = problem { return .failed(p) }
        return loaded ? .running : .starting
    }
    public var nativeSize: CGSize { lock.lock(); defer { lock.unlock() }; return size }

    public func image(at time: CMTime) -> CIImage? {
        let idx = mixer.timelineIndex(for: time)
        lock.lock(); defer { lock.unlock() }
        guard videoTrack != nil else { return nil }
        let p = position(at: idx)
        while frames.count >= 2 && frames[1].pos <= p + 0.004 { frames.removeFirst() }
        if let f = frames.first, f.pos <= p + 0.004 {
            current = CIImage(cvPixelBuffer: f.pb)
            if frames.count == 1 && videoDone { /* keep the last frame on screen */ }
        }
        return current
    }

    public func start() {
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            do {
                let d = try await asset.load(.duration)
                let vt = try await asset.loadTracks(withMediaType: .video).first
                let at = try await asset.loadTracks(withMediaType: .audio).first
                var sz = CGSize(width: 1920, height: 1080)
                if let vt {
                    let (n, t) = try await vt.load(.naturalSize, .preferredTransform)
                    let r = CGRect(origin: .zero, size: n).applying(t)
                    sz = CGSize(width: abs(r.width), height: abs(r.height))
                }
                guard let self else { return }
                guard vt != nil || at != nil else { self.fail("This file has no picture or sound Framecast can play."); return }
                self.lock.lock()
                self.duration = max(0, CMTimeGetSeconds(d))
                self.totalFrames = Int64(self.duration * Self.sr)
                self.asset = asset; self.videoTrack = vt; self.audioTrack = at; self.size = sz
                self.lock.unlock()
                self.queue.async {
                    self.loadHead(asset)
                    self.lock.lock(); self.loaded = true; self.lock.unlock()
                    self.startTimer()
                }
            } catch {
                self?.fail("Couldn't open \(self?.url.lastPathComponent ?? "the file"): \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        timer?.cancel(); timer = nil
        lock.lock()
        playing = false
        audioReader?.cancelReading(); videoReader?.cancelReading()
        audioReader = nil; videoReader = nil; frames = []; buf = []; head = []; current = nil
        lock.unlock()
    }

    private func fail(_ m: String) { lock.lock(); problem = m; lock.unlock() }

    // MARK: Transport

    public var status: Status {
        let idx = mixer.timelineIndex(for: HostClock.now())
        lock.lock(); defer { lock.unlock() }
        return Status(isPlaying: playing, position: position(at: idx), duration: duration, hasVideo: videoTrack != nil, hasAudio: audioTrack != nil)
    }
    public var loop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return looping }
        set { lock.lock(); looping = newValue; lock.unlock() }
    }
    private var nowIndex: Int64 { mixer.timelineIndex(for: HostClock.now()) }

    public func play() {
        let idx = nowIndex
        lock.lock()
        if !playing {
            if !looping && duration > 0 && anchorPos >= duration - 0.05 { anchorPos = 0 }   // play again from the top
            anchorIndex = idx; playing = true
        }
        lock.unlock()
    }
    public func pause() {
        let idx = nowIndex
        lock.lock(); if playing { anchorPos = position(at: idx); playing = false }; lock.unlock()
    }
    public func restart() {
        let idx = nowIndex
        lock.lock(); anchorPos = 0; anchorIndex = idx; playing = true; lock.unlock()
    }
    public func seek(to seconds: Double) {
        let idx = nowIndex
        lock.lock(); anchorPos = max(0, min(duration, seconds)); anchorIndex = idx; lock.unlock()
    }

    /// Media position (seconds) for a timeline index. Caller holds the lock.
    private func position(at index: Int64) -> Double {
        var p = playing ? anchorPos + Double(index - anchorIndex) / Self.sr : anchorPos
        if p < 0 { p = 0 }
        if duration > 0 && p >= duration { p = looping ? p.truncatingRemainder(dividingBy: duration) : duration }
        return p
    }

    // MARK: Sound (called by the mixer on its queue)

    public func generate(_ index: Int64, _ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n * 2)
        lock.lock(); defer { lock.unlock() }
        guard playing, audioTrack != nil, totalFrames > 0 else { return out }
        let startFrame = Int64((anchorPos * Self.sr).rounded()) + (index - anchorIndex)
        let headFrames = Int64(head.count / 2), bufFrames = Int64(buf.count / 2)
        for f in 0..<n {
            var m = startFrame + Int64(f)
            if m < 0 { continue }
            if m >= totalFrames { if looping { m %= totalFrames } else { break } }
            if m < headFrames { out[f * 2] = head[Int(m) * 2]; out[f * 2 + 1] = head[Int(m) * 2 + 1]; continue }
            let k = m - bufStart
            if k >= 0 && k < bufFrames { out[f * 2] = buf[Int(k) * 2]; out[f * 2 + 1] = buf[Int(k) * 2 + 1] }
        }
        return out
    }

    // MARK: Decoding (background queue)

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioBlock.sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]

    private func loadHead(_ asset: AVURLAsset) {
        guard let track = audioTrack, let r = try? AVAssetReader(asset: asset) else { return }
        r.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: Self.audioSettings)
        r.add(o)
        guard r.startReading() else { return }
        var h: [Float] = []
        while let sb = o.copyNextSampleBuffer() { Self.append(sb, to: &h) }
        lock.lock(); head = h; lock.unlock()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(30))
        t.setEventHandler { [weak self] in self?.refill() }
        timer = t
        t.resume()
    }

    private func refill() {
        let idx = nowIndex
        // The mixer asks for sound about `latency` behind now; decode for where it is, not for the picture's position,
        // or a loop or seek could drop sound the mixer still needs.
        let soundIdx = idx - Int64((mixer.latency + 0.05) * Self.sr)
        lock.lock()
        let p = position(at: idx)
        let pa = position(at: soundIdx)
        let isPlaying = playing, loop = looping, dur = duration
        if isPlaying && !loop && dur > 0 && anchorPos + Double(idx - anchorIndex) / Self.sr >= dur {
            anchorPos = dur; playing = false          // finished: hold the last frame, stop the sound
        }
        let hasAudio = audioTrack != nil, hasVideo = videoTrack != nil
        lock.unlock()
        if hasAudio { refillAudio(at: pa) }
        if hasVideo { refillVideo(at: p) }
    }

    private func refillAudio(at p: Double) {
        let want = Int64(p * Self.sr)
        let wantEnd = min(totalFrames, want + Int64(3 * Self.sr))
        lock.lock()
        let bufEnd = bufStart + Int64(buf.count / 2)
        let needsRestart = audioReader == nil || want < bufStart - Int64(0.2 * Self.sr) || want > max(bufEnd, audioNext) + Int64(Self.sr)
        lock.unlock()
        if needsRestart {
            let from = max(0, want - Int64(0.25 * Self.sr))
            lock.lock(); let a = asset, track = audioTrack; lock.unlock()
            guard let a, let track, let r = try? AVAssetReader(asset: a) else { return }
            r.timeRange = CMTimeRange(start: CMTime(value: from, timescale: CMTimeScale(Self.sr)), duration: .positiveInfinity)
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: Self.audioSettings)
            o.alwaysCopiesSampleData = false
            r.add(o)
            guard r.startReading() else { return }
            lock.lock()
            audioReader?.cancelReading()
            audioReader = r; audioOutput = o; buf = []; bufStart = from; audioNext = from; audioDone = false
            lock.unlock()
        }
        // Decode until 3 s ahead of the playhead (or the end).
        while true {
            lock.lock(); let done = audioDone || audioNext >= wantEnd; let o = audioOutput; lock.unlock()
            if done { break }
            guard let o, let sb = o.copyNextSampleBuffer() else { lock.lock(); audioDone = true; lock.unlock(); break }
            var chunk: [Float] = []
            Self.append(sb, to: &chunk)
            let startFrame = Int64((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * Self.sr).rounded())
            lock.lock()
            if buf.isEmpty { bufStart = startFrame }
            buf.append(contentsOf: chunk)
            audioNext = bufStart + Int64(buf.count / 2)
            // Keep one second behind the playhead.
            let drop = Int(max(0, want - Int64(Self.sr) - bufStart))
            if drop > 0 && drop < buf.count / 2 { buf.removeFirst(drop * 2); bufStart += Int64(drop) }
            lock.unlock()
        }
    }

    private func refillVideo(at p: Double) {
        lock.lock()
        let first = frames.first?.pos ?? videoNext
        let needsRestart = videoReader == nil || p < first - 0.15 || p > videoNext + 1.0
        lock.unlock()
        if needsRestart {
            lock.lock(); let a = asset, track = videoTrack; lock.unlock()
            guard let a, let track, let r = try? AVAssetReader(asset: a) else { return }
            r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, p - 0.05), preferredTimescale: 600), duration: .positiveInfinity)
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
            o.alwaysCopiesSampleData = false
            r.add(o)
            guard r.startReading() else { return }
            lock.lock()
            videoReader?.cancelReading()
            videoReader = r; videoOutput = o; frames = []; videoNext = max(0, p - 0.05); videoDone = false
            lock.unlock()
        }
        // Keep up to half a second (at most 12 frames) decoded ahead.
        while true {
            lock.lock()
            let full = videoDone || frames.count >= 12 || (frames.last.map { $0.pos > p + 0.5 } ?? false)
            let o = videoOutput
            lock.unlock()
            if full { break }
            guard let o, let sb = o.copyNextSampleBuffer() else { lock.lock(); videoDone = true; lock.unlock(); break }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pos = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            lock.lock(); frames.append((pos, pb)); videoNext = pos; lock.unlock()
        }
    }

    /// Appends a sample buffer's interleaved Float32 samples to an array.
    static func append(_ sb: CMSampleBuffer, to out: inout [Float]) {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let n = CMBlockBufferGetDataLength(block) / 4
        guard n > 0 else { return }
        let start = out.count
        out.append(contentsOf: repeatElement(0, count: n))
        out.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: raw.baseAddress! + start * 4)
        }
    }
}

// MARK: - Sound pad

/// Plays short sounds (the sound pad) into the mix. Each press starts a new voice; voices end on their own.
public final class SoundPadSource: @unchecked Sendable {
    private let lock = NSLock()
    private var voices: [(samples: [Float], start: Int64?)] = []
    public init() {}

    public func trigger(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); voices.append((samples, nil)); lock.unlock()
    }
    public func stopAll() { lock.lock(); voices = []; lock.unlock() }
    public var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return !voices.isEmpty }

    public func generate(_ index: Int64, _ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n * 2)
        lock.lock(); defer { lock.unlock() }
        for i in voices.indices {
            if voices[i].start == nil { voices[i].start = index }
            let s = voices[i].samples, off = Int(index - voices[i].start!) * 2
            let m = min(n * 2, s.count - off)
            if m > 0 { for k in 0..<m { out[k] += s[off + k] } }
        }
        voices.removeAll { v in Int(index - (v.start ?? index)) * 2 + n * 2 >= v.samples.count }
        return out
    }
}

/// Built-in sounds, synthesised by Framecast (no recorded audio), and decoding of the user's own files.
public enum SoundBank {
    public static let builtIns: [(id: String, name: String)] = [
        ("chime", "Chime"), ("ding", "Ding"), ("applause", "Applause"), ("drumroll", "Drumroll"), ("whoosh", "Whoosh"), ("pop", "Pop"),
    ]
    private static var cache: [String: [Float]] = [:]
    private static let lock = NSLock()

    /// Interleaved stereo 48 kHz samples for a built-in sound id or a file path (first 30 s).
    public static func samples(for key: String) -> [Float] {
        lock.lock(); if let c = cache[key] { lock.unlock(); return c }; lock.unlock()
        let s = builtIns.contains { $0.id == key } ? synth(key) : (decode(URL(fileURLWithPath: key)) ?? [])
        lock.lock(); cache[key] = s; lock.unlock()
        return s
    }

    static func decode(_ url: URL, maxSeconds: Double = 30) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioBlock.sampleRate, channels: 2, interleaved: true),
              let conv = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let frames = AVAudioFrameCount(min(Double(file.length), maxSeconds * file.processingFormat.sampleRate))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames), (try? file.read(into: inBuf, frameCount: frames)) != nil else { return nil }
        let outCap = AVAudioFrameCount(Double(frames) * AudioBlock.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, let p = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength) * 2))
    }

    static func synth(_ id: String) -> [Float] {
        let sr = AudioBlock.sampleRate
        var rng = SystemRandomNumberGenerator()
        func noise() -> Float { Float.random(in: -1...1, using: &rng) }
        func make(_ seconds: Double, _ f: (Double, Int) -> (Float, Float)) -> [Float] {
            let n = Int(seconds * sr)
            var out = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { let (l, r) = f(Double(i) / sr, i); out[i * 2] = l; out[i * 2 + 1] = r }
            return out
        }
        switch id {
        case "chime":
            return make(1.6) { t, _ in
                let partials: [(Double, Double)] = [(880, 0.5), (1318.5, 0.3), (1760, 0.2), (2637, 0.1)]
                var v = 0.0
                for (f, a) in partials { v += a * sin(2 * .pi * f * t) * exp(-t * (2.2 + f / 1500)) }
                let attack = min(1, t / 0.004)
                return (Float(v * attack * 0.45), Float(v * attack * 0.42))
            }
        case "ding":
            return make(1.1) { t, _ in
                let v = (0.6 * sin(2 * .pi * 1046.5 * t) + 0.25 * sin(2 * .pi * 2093 * t) + 0.1 * sin(2 * .pi * 3140 * t)) * exp(-t * 4.5)
                let a = Float(v * min(1, t / 0.003) * 0.5); return (a, a)
            }
        case "pop":
            return make(0.12) { t, _ in
                let f = 620 - 3600 * t
                let v = sin(2 * .pi * f * t) * exp(-t * 38)
                let a = Float(v * 0.55); return (a, a)
            }
        case "whoosh":
            var lp: Float = 0, lp2: Float = 0
            return make(0.9) { t, _ in
                let env = Float(sin(.pi * t / 0.9))
                let cutoff = Float(0.02 + 0.25 * (t / 0.9))
                lp += cutoff * (noise() - lp); lp2 += cutoff * (lp - lp2)
                let v = (lp - lp2) * env * 1.6
                return (v * Float(1 - t / 0.9 * 0.5), v * Float(0.5 + t / 0.9 * 0.5))
            }
        case "drumroll":
            var env: Float = 0, lp: Float = 0
            return make(2.6) { t, i in
                // Snare hits 28 times a second getting louder for 2 s, then a crash.
                if t < 2.0 {
                    if i % Int(sr / 28) == 0 { env = Float(0.25 + 0.6 * t / 2) * (0.85 + 0.15 * Float.random(in: 0...1)) }
                    env *= 0.9988
                    lp += 0.35 * (noise() - lp)
                    let v = (noise() - lp * 0.6) * env * 0.5
                    return (v, v)
                }
                let c = Float(exp(-(t - 2.0) * 5)) * 0.6
                let v = noise() * c
                return (v, v * 0.95)
            }
        case "applause":
            // Many short claps at random times with random pan, swelling and fading over 3 s.
            var out = [Float](repeating: 0, count: Int(3.2 * sr) * 2)
            let total = out.count / 2
            for _ in 0..<520 {
                let t0 = Double.random(in: 0...2.9)
                let start = Int(t0 * sr)
                let swell = Float(sin(.pi * min(1, t0 / 2.9)))
                let pan = Float.random(in: 0.2...0.8)
                var lp: Float = 0
                let len = Int(0.018 * sr)
                for k in 0..<len where start + k < total {
                    lp += 0.5 * (noise() - lp)
                    let v = (noise() - lp) * Float(exp(-Double(k) / (0.004 * sr))) * swell * 0.22
                    out[(start + k) * 2] += v * (1 - pan); out[(start + k) * 2 + 1] += v * pan
                }
            }
            return out
        default:
            return []
        }
    }
}
