import Foundation
import AVFoundation
import CoreMedia

public enum ContainerFormat: String, Codable, Sendable, CaseIterable {
    case mov, mp4, mkv
    public var title: String { rawValue.uppercased() }
    public var detail: String {
        switch self {
        case .mov: return "Best for Final Cut and Premiere. Recoverable after a crash."
        case .mp4: return "Plays everywhere. Recoverable after a crash."
        case .mkv: return "The most crash-proof. Remux to MP4 when you edit."
        }
    }
}

public struct RecordingSpec: Sendable {
    public var canvas: CanvasKind
    public var container: ContainerFormat
    public var codec: VideoCodec
    public var bitrateKbps: Int
    public var width: Int, height: Int, fps: Int
    public var folders: [URL]
    public var baseName: String
    public var splitMinutes: Double       // 0 = one file
    public var audioTracks: [Int]         // 1 = program mix; 2…6 = separate tracks
    /// A camera angle recorded on its own (one file per angle, with the program's sound); nil records the canvas.
    public var isoSource: UUID?
    public init(canvas: CanvasKind, container: ContainerFormat, codec: VideoCodec, bitrateKbps: Int, width: Int, height: Int, fps: Int,
                folders: [URL], baseName: String, splitMinutes: Double = 0, audioTracks: [Int] = [1], isoSource: UUID? = nil) {
        self.canvas = canvas; self.container = container; self.codec = codec; self.bitrateKbps = bitrateKbps
        self.width = width; self.height = height; self.fps = fps; self.folders = folders; self.baseName = baseName
        self.splitMinutes = splitMinutes; self.audioTracks = audioTracks; self.isoSource = isoSource
    }
}

/// One output file (one part of one canvas, written to one folder).
protocol RecordingSink: AnyObject {
    var url: URL { get }
    var failure: String? { get }
    var bytesWritten: Int64 { get }
    var droppedFrames: Int { get }
    func appendVideo(_ pb: CVPixelBuffer, at rel: CMTime)
    func appendAudio(track: Int, samples: [Float], at relIndex: Int64)
    func finish(endRel: CMTime, completion: @escaping () -> Void)
}

final class AssetWriterSink: RecordingSink {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInputs: [Int: AVAssetWriterInput] = [:]
    private let audioFormat: CMAudioFormatDescription
    private(set) var droppedFrames = 0
    private var started = false
    private let lock = NSLock()
    var failure: String? { writer.status == .failed ? (writer.error?.localizedDescription ?? "Writer failed") : nil }
    var bytesWritten: Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0 }

    init(url: URL, spec: RecordingSpec) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: spec.container == .mp4 ? .mp4 : .mov)
        // Fragments every second keep the file playable up to the last second if the app or Mac dies.
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: spec.bitrateKbps * 1000,
            AVVideoExpectedSourceFrameRateKey: spec.fps,
            AVVideoMaxKeyFrameIntervalKey: spec.fps * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let vs: [String: Any] = [
            AVVideoCodecKey: spec.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw NSError(domain: "Framecast.Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recording couldn't start."]) }
        writer.add(videoInput)

        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        audioFormat = fd!
        for t in spec.audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); audioInputs[t] = input }
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Framecast.Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Recording couldn't start."])
        }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    func appendVideo(_ pb: CVPixelBuffer, at rel: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard writer.status == .writing else { return }
        if videoInput.isReadyForMoreMediaData { if !adaptor.append(pb, withPresentationTime: rel) { droppedFrames += 1 } }
        else { droppedFrames += 1 }
    }

    func appendAudio(track: Int, samples: [Float], at relIndex: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard writer.status == .writing, let input = audioInputs[track], input.isReadyForMoreMediaData, !samples.isEmpty else { return }
        let frames = samples.count / 2
        var block: CMBlockBuffer?
        let bytes = samples.count * 4
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: relIndex, timescale: 48_000)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat,
                                                                   sampleCount: frames, presentationTimeStamp: pts,
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb else { return }
        input.append(sb)
    }

    func finish(endRel: CMTime, completion: @escaping () -> Void) {
        lock.lock()
        guard writer.status == .writing else { lock.unlock(); completion(); return }
        writer.endSession(atSourceTime: endRel)
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        lock.unlock()
        writer.finishWriting { completion() }
    }
}

final class MKVSink: RecordingSink {
    let url: URL
    private let mkv: MKVWriter
    private let encoder: VideoEncoder
    private var aac: [Int: AACEncoder] = [:]
    private let queue = DispatchQueue(label: "framecast.mkv")
    var failure: String? { mkv.failure }
    var bytesWritten: Int64 { mkv.bytesWritten }
    var droppedFrames: Int { encoder.framesDropped }

    init(url: URL, spec: RecordingSpec) throws {
        self.url = url
        mkv = try MKVWriter(url: url, video: (spec.codec, spec.width, spec.height, spec.fps), audioTracks: spec.audioTracks)
        encoder = try VideoEncoder(config: .init(width: spec.width, height: spec.height, fps: spec.fps, codec: spec.codec,
                                                 bitrateKbps: spec.bitrateKbps, keyframeSeconds: 2))
        encoder.onFrame = { [weak self] f in
            guard let self else { return }
            self.queue.async { self.mkv.addVideo(f, ms: Int64((CMTimeGetSeconds(f.pts) * 1000).rounded())) }
        }
        for t in spec.audioTracks {
            let e = try AACEncoder(bitrateKbps: 192)
            e.onPacket = { [weak self] p in
                guard let self else { return }
                self.queue.async { self.mkv.addAudio(p, track: t, ms: Int64((CMTimeGetSeconds(p.pts) * 1000).rounded())) }
            }
            aac[t] = e
        }
    }

    func appendVideo(_ pb: CVPixelBuffer, at rel: CMTime) { encoder.encode(pb, pts: rel) }
    func appendAudio(track: Int, samples: [Float], at relIndex: Int64) { aac[track]?.append(samples, timelineIndex: relIndex) }
    func finish(endRel: CMTime, completion: @escaping () -> Void) {
        encoder.finish()
        queue.async {
            self.mkv.finish(durationMs: Int64(CMTimeGetSeconds(endRel) * 1000))
            completion()
        }
    }
}

/// Records one canvas: owns its files, splits parts, applies pauses, and lines audio up on the same
/// timeline as video. Times are timeline sample indices (48 kHz) relative to the engine origin.
public final class CanvasRecorder: @unchecked Sendable {
    public let spec: RecordingSpec
    private var startIndex: Int64 = .max     // set by begin(at:) once every file is open
    private var stopIndex: Int64?
    private var pauses: [(start: Int64, end: Int64?)] = []
    private let lock = NSLock()
    private let toIndex: (CMTime) -> Int64
    private struct Part {
        let index: Int; let start: Int64; var end: Int64?; let sinks: [RecordingSink]; var audioDoneTo: Int64; var finished = false
        var firstVideoRel: Int64?      // grid anchor for constant-frame-rate timestamps
        var lastFrameNumber: Int64 = -1
        var lastFrameIdx: Int64 = -1         // timeline index of that frame (a pause in between isn't a miss)
    }
    private var parts: [Part] = []
    public private(set) var files: [URL] = []
    public private(set) var failure: String?
    public var onFinished: (([URL]) -> Void)?
    public var onFailure: ((String) -> Void)?
    private var finishedCallbackSent = false

    /// Opens the files. Nothing is written until `begin(at:)`, which must get the same time for every
    /// canvas started together so their files line up.
    public init(spec: RecordingSpec, toIndex: @escaping (CMTime) -> Int64) throws {
        self.spec = spec
        self.toIndex = toIndex
        try openPart(number: 1, at: .max)
    }

    public func begin(at pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        startIndex = toIndex(pts)
        if !parts.isEmpty {
            let p = parts[0]
            parts[0] = Part(index: p.index, start: startIndex, end: p.end, sinks: p.sinks, audioDoneTo: startIndex)
        }
    }

    private func fileURL(folder: URL, part: Int) -> URL {
        let ext = spec.container.rawValue
        let name = part == 1 ? spec.baseName : "\(spec.baseName)-part\(part)"
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)"); n += 1
        }
        return url
    }

    private func openPart(number: Int, at index: Int64) throws {
        var sinks: [RecordingSink] = []
        for folder in spec.folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = fileURL(folder: folder, part: number)
            let sink: RecordingSink = spec.container == .mkv ? try MKVSink(url: url, spec: spec) : try AssetWriterSink(url: url, spec: spec)
            sinks.append(sink)
            files.append(url)
        }
        parts.append(Part(index: number, start: index, end: nil, sinks: sinks, audioDoneTo: index))
    }

    /// Output-relative position: time since start minus everything paused before `idx`.
    private func relative(_ idx: Int64) -> Int64 {
        var paused: Int64 = 0
        for p in pauses where p.start < idx { paused += min(p.end ?? idx, idx) - p.start }
        return idx - startIndex - paused
    }
    private func isPaused(_ idx: Int64) -> Bool { pauses.contains { idx >= $0.start && idx < ($0.end ?? .max) } }

    public func pause(at pts: CMTime) { lock.lock(); if pauses.last?.end != nil || pauses.isEmpty { pauses.append((toIndex(pts), nil)) }; lock.unlock() }
    public func resume(at pts: CMTime) { lock.lock(); if let i = pauses.indices.last, pauses[i].end == nil { pauses[i].end = toIndex(pts) }; lock.unlock() }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pauses.last.map { $0.end == nil } ?? false }

    /// Recorded duration so far (seconds), excluding pauses.
    public func recordedSeconds(now: CMTime) -> Double {
        lock.lock(); defer { lock.unlock() }
        return Double(relative(min(toIndex(now), stopIndex ?? .max))) / 48_000
    }
    public var bytesWritten: Int64 { lock.lock(); defer { lock.unlock() }; return parts.flatMap(\.sinks).reduce(0) { $0 + $1.bytesWritten } }
    public var droppedFrames: Int { lock.lock(); defer { lock.unlock() }; return parts.flatMap(\.sinks).reduce(0) { $0 + $1.droppedFrames } }
    /// Frame slots on the constant-rate grid that no render reached (a stall upstream of the encoder).
    public var missedFrames: Int { lock.lock(); defer { lock.unlock() }; return missed }
    private var missed = 0

    public func appendVideo(_ pb: CVPixelBuffer, pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        let idx = toIndex(pts)
        guard idx >= startIndex, idx < (stopIndex ?? .max), !isPaused(idx) else { return }
        // Start a new part at the split boundary (on output time, so pauses don't shorten parts).
        if spec.splitMinutes > 0, let cur = parts.last, cur.end == nil {
            let partLen = Int64(spec.splitMinutes * 60 * 48_000)
            if relative(idx) - relative(cur.start) >= partLen {
                parts[parts.count - 1].end = idx
                do { try openPart(number: cur.index + 1, at: idx) } catch { report(error.localizedDescription) }
            }
        }
        guard let pi = parts.lastIndex(where: { idx >= $0.start && idx < ($0.end ?? .max) }) else { return }
        // Snap to an exact frame grid anchored on the part's first frame: constant frame rate, no jitter.
        let relSamples = relative(idx) - relative(parts[pi].start)
        let anchor = parts[pi].firstVideoRel ?? relSamples
        parts[pi].firstVideoRel = anchor
        let n = Int64((Double(relSamples - anchor) * Double(spec.fps) / 48_000).rounded())
        guard n > parts[pi].lastFrameNumber else { return }        // two renders in one frame slot
        if parts[pi].lastFrameNumber >= 0 {
            let last = parts[pi].lastFrameIdx
            if !pauses.contains(where: { $0.start > last && $0.start <= idx }) { missed += Int(n - parts[pi].lastFrameNumber - 1) }
        }
        parts[pi].lastFrameNumber = n
        parts[pi].lastFrameIdx = idx
        let rel = CMTimeAdd(CMTime(value: anchor, timescale: 48_000), CMTime(value: n, timescale: CMTimeScale(spec.fps)))
        for s in parts[pi].sinks { s.appendVideo(pb, at: rel) }
        checkFailures(parts[pi])
    }

    public func appendAudio(_ block: AudioBlock) {
        lock.lock(); defer { lock.unlock() }
        guard startIndex != .max else { return }
        let n = Int64(block.program.count / 2)
        let b0 = block.timelineIndex, b1 = b0 + n
        for pi in parts.indices where !parts[pi].finished {
            let p = parts[pi]
            let lo = max(b0, p.start), hi = min(b1, p.end ?? stopIndex ?? .max)
            if lo < hi {
                // Skip paused spans inside this block.
                var s = lo
                while s < hi {
                    if isPaused(s) {
                        let pend = pauses.first { s >= $0.start && s < ($0.end ?? .max) }?.end ?? hi
                        s = min(hi, max(pend, s + 1)); continue
                    }
                    let nextPause = pauses.map(\.start).filter { $0 > s && $0 < hi }.min() ?? hi
                    let e = nextPause
                    let off = Int(s - b0) * 2, cnt = Int(e - s) * 2
                    let rel = relative(s) - relative(p.start)
                    for t in spec.audioTracks {
                        guard let src = block.tracks[t] ?? (t == 1 ? nil : [Float](repeating: 0, count: block.program.count)) else { continue }
                        let slice = Array(src[off..<(off + cnt)])
                        for sink in p.sinks { sink.appendAudio(track: t, samples: slice, at: rel) }
                    }
                    s = e
                }
            }
            parts[pi].audioDoneTo = max(p.audioDoneTo, b1)
            // A part is complete once audio has passed its end.
            if let end = p.end ?? stopIndex, b1 >= end { finishPart(pi, end: end) }
        }
    }

    private func finishPart(_ pi: Int, end: Int64) {
        guard !parts[pi].finished else { return }
        parts[pi].finished = true
        let p = parts[pi]
        let endRel = CMTime(value: relative(end) - relative(p.start), timescale: 48_000)
        let group = DispatchGroup()
        for s in p.sinks { group.enter(); s.finish(endRel: endRel) { group.leave() } }
        group.notify(queue: .global()) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let allDone = self.stopIndex != nil && self.parts.allSatisfy(\.finished)
            let send = allDone && !self.finishedCallbackSent
            if send { self.finishedCallbackSent = true }
            let files = self.files
            self.lock.unlock()
            if send { self.onFinished?(files) }
        }
    }

    private func checkFailures(_ p: Part) {
        for s in p.sinks { if let f = s.failure, failure == nil { report(f) } }
    }
    private func report(_ f: String) {
        failure = f
        let cb = onFailure
        DispatchQueue.main.async { cb?(f) }
    }

    /// Stops at `pts`. Files close once the mixer's audio (which runs slightly behind) has reached `pts`.
    public func stop(at pts: CMTime) {
        lock.lock()
        let idx = toIndex(pts)
        stopIndex = idx
        if let i = pauses.indices.last, pauses[i].end == nil { pauses[i].end = idx }
        for pi in parts.indices where parts[pi].end == nil { parts[pi].end = idx }
        lock.unlock()
    }

    /// Safety net if audio stops arriving (for example the mixer was torn down): close everything now.
    public func forceFinish() {
        lock.lock(); defer { lock.unlock() }
        for pi in parts.indices where !parts[pi].finished { finishPart(pi, end: parts[pi].end ?? stopIndex ?? parts[pi].audioDoneTo) }
    }
}
