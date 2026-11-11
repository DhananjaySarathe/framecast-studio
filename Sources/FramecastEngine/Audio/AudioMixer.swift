import Foundation
import CoreMedia
import AVFoundation

/// One block of mixed audio on the engine timeline: 48 kHz, stereo, interleaved Float32.
public struct AudioBlock: @unchecked Sendable {
    public static let sampleRate = 48_000.0
    public static let channels = 2
    public static let frames = 1024
    public let pts: CMTime
    public let timelineIndex: Int64
    /// Track 1 is the program mix. Tracks 2…6 carry the sources assigned to them (separate audio tracks).
    public let tracks: [Int: [Float]]
    public var program: [Float] { tracks[1] ?? [] }
}

public struct AudioLevel: Sendable, Equatable {
    public var peak: Float = 0
    public var rms: Float = 0
    public static let silent = AudioLevel()
}

/// Per-source buffer addressed by timeline sample index. Sources write where their capture timestamp
/// says the audio belongs; the mixer reads a fixed latency behind real time, so each source lands at
/// the right moment no matter how it batches its callbacks.
final class TimelineRing {
    let capacity: Int
    private var data: [Float]
    private(set) var writtenEnd: Int64 = .min
    private var writtenStart: Int64 = .max
    private let tolerance: Int64

    init(seconds: Double = 4, tolerance: Double = 0.012) {
        capacity = Int(seconds * AudioBlock.sampleRate)
        data = [Float](repeating: 0, count: capacity * 2)
        self.tolerance = Int64(tolerance * AudioBlock.sampleRate)
    }

    func write(_ src: UnsafePointer<Float>, frames: Int, at index: Int64) {
        var idx = index
        if writtenEnd != .min {
            // Snap small timestamp jitter onto the previous write so audio stays continuous.
            if abs(idx - writtenEnd) <= tolerance { idx = writtenEnd }
            else if idx > writtenEnd {
                // Gap (source paused or dropped): clear the skipped span so old audio isn't replayed.
                var z = max(writtenEnd, idx - Int64(capacity))
                while z < idx {
                    let p = Int(((z % Int64(capacity)) + Int64(capacity)) % Int64(capacity))
                    data[p*2] = 0; data[p*2+1] = 0; z += 1
                }
            }
        } else {
            writtenStart = idx
        }
        for f in 0..<frames {
            let j = idx + Int64(f)
            let p = Int(((j % Int64(capacity)) + Int64(capacity)) % Int64(capacity))
            data[p*2] = src[f*2]; data[p*2+1] = src[f*2+1]
        }
        writtenEnd = max(writtenEnd == .min ? idx + Int64(frames) : writtenEnd, idx + Int64(frames))
        if idx < writtenStart { writtenStart = idx }
    }

    /// Adds `frames` samples starting at timeline `index` into `dst`, scaled by `gain`. Missing samples are silence.
    func mix(into dst: inout [Float], frames: Int, at index: Int64, gain: Float, levels: inout (peak: Float, sum: Float)) {
        guard writtenEnd != .min else { return }
        let validStart = max(writtenStart, writtenEnd - Int64(capacity))
        for f in 0..<frames {
            let j = index + Int64(f)
            guard j >= validStart && j < writtenEnd else { continue }
            let p = Int(((j % Int64(capacity)) + Int64(capacity)) % Int64(capacity))
            let l = data[p*2] * gain, r = data[p*2+1] * gain
            dst[f*2] += l; dst[f*2+1] += r
            let m = max(abs(l), abs(r)); if m > levels.peak { levels.peak = m }
            levels.sum += (l*l + r*r) * 0.5
        }
    }
}

public protocol AudioBlockConsumer: AnyObject {
    func consume(_ block: AudioBlock)
}

/// Mixes every audio source into a program mix (and up to five extra tracks) on one clock.
public final class AudioMixer: @unchecked Sendable {
    public let origin: CMTime
    public let latency: Double
    private let queue = DispatchQueue(label: "framecast.mixer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var rings: [UUID: TimelineRing] = [:]
    private var settings: [UUID: AudioSettings] = [:]
    private var generators: [UUID: (Int64, Int) -> [Float]] = [:]
    /// Microphones (and guests, via `isVoice`): their level lowers sources set to duck under voices.
    private var voiceIDs: Set<UUID> = []
    /// 1 = not lowered; drops to about −12 dB while someone talks.
    public private(set) var duckLevel: Float = 1
    /// Loudest voice in the program in the latest block (0…1): camera-angle cuts wait for pauses in it.
    public private(set) var voicePeak: Float = 0
    private var duckHold = 0
    private var consumers: [ObjectIdentifier: AudioBlockConsumer] = [:]
    private var nextIndex: Int64
    public var masterGain: Float = 1
    /// Latest meter readings by source id; `masterLevel` for the program mix.
    public private(set) var levels: [UUID: AudioLevel] = [:]
    public private(set) var masterLevel = AudioLevel.silent
    /// Monitor (headphones) tap: receives only sources marked `isMonitored`, already scaled.
    public var monitorTap: (([Float]) -> Void)?

    public init(origin: CMTime, latency: Double = 0.12) {
        self.origin = origin
        self.latency = latency
        nextIndex = 0
    }

    public func timelineIndex(for pts: CMTime) -> Int64 {
        Int64((CMTimeGetSeconds(CMTimeSubtract(pts, origin)) * AudioBlock.sampleRate).rounded())
    }
    public func pts(forIndex i: Int64) -> CMTime {
        CMTimeAdd(origin, CMTime(value: i, timescale: CMTimeScale(AudioBlock.sampleRate)))
    }

    public func addSource(_ id: UUID, settings: AudioSettings) {
        lock.lock(); rings[id] = TimelineRing(); self.settings[id] = settings; lock.unlock()
    }
    /// A generator is called with (timeline index, frame count) and returns interleaved stereo samples.
    public func addGenerator(_ id: UUID, settings: AudioSettings, _ gen: @escaping (Int64, Int) -> [Float]) {
        lock.lock(); generators[id] = gen; self.settings[id] = settings; lock.unlock()
    }
    public func removeSource(_ id: UUID) {
        lock.lock(); rings[id] = nil; settings[id] = nil; generators[id] = nil; levels[id] = nil; voiceIDs.remove(id); lock.unlock()
    }
    public func setVoice(_ id: UUID, _ on: Bool) { lock.lock(); if on { voiceIDs.insert(id) } else { voiceIDs.remove(id) }; lock.unlock() }
    public func update(_ id: UUID, settings s: AudioSettings) { lock.lock(); settings[id] = s; lock.unlock() }

    /// Push interleaved stereo 48 kHz Float32 samples captured at `pts`.
    public func push(_ id: UUID, samples: UnsafePointer<Float>, frames: Int, pts: CMTime) {
        lock.lock()
        guard let ring = rings[id] else { lock.unlock(); return }
        let held = hold.ids.contains(id) ? hold.ms : 0
        let delay = Int64((((settings[id]?.delayMs ?? 0) + held) / 1000) * AudioBlock.sampleRate)
        ring.write(samples, frames: frames, at: timelineIndex(for: pts) + delay)
        let tap = listenTap?.id == id && settings[id]?.isMuted != true ? listenTap?.handler : nil
        let measure = measureTaps[id]
        let caption = captionTap?.id == id && settings[id]?.isMuted != true ? captionTap?.handler : nil
        lock.unlock()
        tap?(samples, frames)
        measure?(samples, frames, pts)
        caption?(samples, frames, pts)
    }

    /// Holds these sources (the presenter's microphones) back by `ms` on top of their own delay, so their sound lines
    /// up with a camera angle whose picture arrives later (a phone). Changed in a pause, the jump isn't heard.
    public func setHold(_ ms: Double, for ids: Set<UUID>) { lock.lock(); hold = (ids, max(0, ms)); lock.unlock() }
    public var holdMs: Double { lock.lock(); defer { lock.unlock() }; return hold.ms }
    private var hold: (ids: Set<UUID>, ms: Double) = ([], 0)

    /// Hands a source's samples, as captured and with their capture time, to a measurement (lining up a phone's sound).
    public func setMeasureTap(_ id: UUID, _ handler: ((UnsafePointer<Float>, Int, CMTime) -> Void)?) {
        lock.lock(); measureTaps[id] = handler; lock.unlock()
    }
    private var measureTaps: [UUID: (UnsafePointer<Float>, Int, CMTime) -> Void] = [:]

    /// Also hands one source's samples, as captured, to a listener (live transcription). Nothing while it's muted.
    public func setListenTap(_ id: UUID?, _ handler: ((UnsafePointer<Float>, Int) -> Void)?) {
        lock.lock(); listenTap = id.flatMap { i in handler.map { (i, $0) } }; lock.unlock()
    }
    private var listenTap: (id: UUID, handler: (UnsafePointer<Float>, Int) -> Void)?

    /// Live captions' own tap, beside the listen tap (so captions, Listen and the angles' ears each keep hearing),
    /// with each block's capture time. Nothing while the source is muted.
    public func setCaptionTap(_ id: UUID?, _ handler: ((UnsafePointer<Float>, Int, CMTime) -> Void)?) {
        lock.lock(); captionTap = id.flatMap { i in handler.map { (i, $0) } }; lock.unlock()
    }
    private var captionTap: (id: UUID, handler: (UnsafePointer<Float>, Int, CMTime) -> Void)?

    public func addConsumer(_ c: AudioBlockConsumer) { lock.lock(); consumers[ObjectIdentifier(c)] = c; lock.unlock() }
    public func removeConsumer(_ c: AudioBlockConsumer) { lock.lock(); consumers[ObjectIdentifier(c)] = nil; lock.unlock() }

    public func start() {
        nextIndex = max(0, timelineIndex(for: HostClock.now()) - Int64(latency * AudioBlock.sampleRate))
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }
    public func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        let target = timelineIndex(for: HostClock.now()) - Int64(latency * AudioBlock.sampleRate)
        let n = AudioBlock.frames
        while nextIndex + Int64(n) <= target {
            produce(at: nextIndex, frames: n)
            nextIndex += Int64(n)
        }
    }

    private func produce(at index: Int64, frames n: Int) {
        lock.lock()
        let snapshotRings = rings, snapshotSettings = settings, gens = generators
        let voices = voiceIDs
        let cons = Array(consumers.values)
        let gainMaster = masterGain
        let duckStart = duckLevel
        lock.unlock()

        var tracks: [Int: [Float]] = [1: [Float](repeating: 0, count: n * 2)]
        var monitor = [Float](repeating: 0, count: n * 2)
        var anyMonitor = false
        var newLevels: [UUID: AudioLevel] = [:]

        var voicePeak: Float = 0
        var duckRamp: (Float, Float) = (1, 1)
        func route(_ id: UUID, _ s: AudioSettings, _ fill: (inout [Float], Float, inout (peak: Float, sum: Float)) -> Void) {
            var lv: (peak: Float, sum: Float) = (0, 0)
            var scratch = [Float](repeating: 0, count: n * 2)
            fill(&scratch, s.isMuted ? 0 : s.linearGain, &lv)
            newLevels[id] = AudioLevel(peak: lv.peak, rms: sqrt(lv.sum / Float(n)))
            if voices.contains(id) || s.isVoice == true { if s.isInProgram { voicePeak = max(voicePeak, lv.peak) } }
            else if s.ducksUnderVoice == true && duckRamp != (1, 1) {
                // Ramp across the block so the level change doesn't click.
                let (a, b) = duckRamp
                for f in 0..<n { let g = a + (b - a) * Float(f) / Float(n); scratch[f * 2] *= g; scratch[f * 2 + 1] *= g }
            }
            if s.isInProgram {
                for i in 0..<(n*2) { tracks[1]![i] += scratch[i] }
            }
            for t in s.tracks where t >= 2 && t <= 6 {
                if tracks[t] == nil { tracks[t] = [Float](repeating: 0, count: n * 2) }
                for i in 0..<(n*2) { tracks[t]![i] += scratch[i] }
            }
            if s.isMonitored {
                anyMonitor = true
                for i in 0..<(n*2) { monitor[i] += scratch[i] }
            }
        }

        // Voices first: their level sets how far ducked sources come down in this block.
        func isVoice(_ id: UUID) -> Bool { voices.contains(id) || snapshotSettings[id]?.isVoice == true }
        for (id, ring) in snapshotRings where isVoice(id) {
            guard let s = snapshotSettings[id] else { continue }
            route(id, s) { buf, g, lv in ring.mix(into: &buf, frames: n, at: index, gain: g, levels: &lv) }
        }
        func runGenerator(_ id: UUID, _ gen: (Int64, Int) -> [Float]) {
            guard let s = snapshotSettings[id] else { return }
            let samples = gen(index, n)
            route(id, s) { buf, g, lv in
                for i in 0..<(n*2) {
                    let v = samples[i] * g; buf[i] = v
                    lv.peak = max(lv.peak, abs(v)); lv.sum += v * v * 0.5
                }
            }
        }
        for (id, gen) in gens where isVoice(id) { runGenerator(id, gen) }
        var duckEnd = duckStart
        if voicePeak > 0.03 { duckHold = 18 }                       // about −30 dBFS; hold ~0.4 s after the last word
        let target: Float = duckHold > 0 ? 0.25 : 1
        if duckHold > 0 { duckHold -= 1 }
        duckEnd += (target - duckEnd) * (target < duckEnd ? 0.45 : 0.06)   // fast down, slow back up
        duckRamp = (duckStart, duckEnd)
        for (id, ring) in snapshotRings where !isVoice(id) {
            guard let s = snapshotSettings[id] else { continue }
            route(id, s) { buf, g, lv in ring.mix(into: &buf, frames: n, at: index, gain: g, levels: &lv) }
        }
        for (id, gen) in gens where !isVoice(id) { runGenerator(id, gen) }

        // Master gain plus a soft limiter ("Limiter −1 dBTP"); keeps peaks under 0.89.
        var mp: Float = 0, ms: Float = 0
        for i in 0..<(n*2) {
            var v = tracks[1]![i] * gainMaster
            let a = abs(v)
            if a > 0.89 { v = (v > 0 ? 1 : -1) * (0.89 + (1 - 0.89) * tanh((a - 0.89) / (1 - 0.89))) }
            tracks[1]![i] = v
            mp = max(mp, abs(v)); ms += v * v * 0.5
        }
        lock.lock()
        levels = newLevels
        masterLevel = AudioLevel(peak: mp, rms: sqrt(ms / Float(n)))
        duckLevel = duckEnd
        self.voicePeak = voicePeak
        lock.unlock()

        let block = AudioBlock(pts: pts(forIndex: index), timelineIndex: index, tracks: tracks)
        for c in cons { c.consume(block) }
        if anyMonitor { monitorTap?(monitor) }
    }

    public func level(for id: UUID) -> AudioLevel { lock.lock(); defer { lock.unlock() }; return levels[id] ?? .silent }
    public var currentMasterLevel: AudioLevel { lock.lock(); defer { lock.unlock() }; return masterLevel }
}

/// A 1 kHz beep for 100 ms at every whole second of the timeline (pairs with TestPatternSource's flash).
public enum ToneGenerator {
    public static func make(beepEverySecond: Bool = true, frequency: Double = 1000, amplitude: Float = 0.5) -> (Int64, Int) -> [Float] {
        return { index, n in
            var out = [Float](repeating: 0, count: n * 2)
            let sr = Int64(AudioBlock.sampleRate)
            for f in 0..<n {
                let j = index + Int64(f)
                let inSecond = ((j % sr) + sr) % sr
                let on = beepEverySecond ? inSecond < sr / 10 : true
                if on {
                    let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(j) / AudioBlock.sampleRate))
                    out[f*2] = v; out[f*2+1] = v
                }
            }
            return out
        }
    }
}
