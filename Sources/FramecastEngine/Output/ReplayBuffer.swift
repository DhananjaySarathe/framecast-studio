import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Keeps the last moments of each canvas (already encoded, keyframe every second) and of the program sound, so a
/// clip can be saved after something happened. The studio runs it while recording or live.
public final class ReplayBuffer: CanvasFrameConsumer, AudioBlockConsumer, @unchecked Sendable {
    public struct Canvas: Sendable {
        public let kind: CanvasKind, width: Int, height: Int, fps: Int
        public init(kind: CanvasKind, width: Int, height: Int, fps: Int) { self.kind = kind; self.width = width; self.height = height; self.fps = fps }
    }
    public let seconds: Double
    private let canvases: [CanvasKind: Canvas]
    private let encoders: [CanvasKind: VideoEncoder]
    private let lock = NSLock()
    private var frames: [CanvasKind: [EncodedVideoFrame]] = [:]
    private var audio: [(pts: CMTime, samples: [Float])] = []
    private let saveQueue = DispatchQueue(label: "framecast.replay.save", qos: .userInitiated)

    public init(canvases list: [Canvas], seconds: Double = 30) throws {
        self.seconds = seconds
        var enc: [CanvasKind: VideoEncoder] = [:], cv: [CanvasKind: Canvas] = [:]
        for c in list {
            // About 8 Mbps at 1080p30, scaled by pixels × frame rate.
            let kbps = max(2_000, Int(8_000 * Double(c.width * c.height * c.fps) / Double(1920 * 1080 * 30)))
            enc[c.kind] = try VideoEncoder(config: .init(width: c.width, height: c.height, fps: c.fps, codec: .h264, bitrateKbps: kbps, keyframeSeconds: 1))
            cv[c.kind] = c
        }
        encoders = enc; canvases = cv
        for (kind, e) in enc { e.onFrame = { [weak self] f in self?.add(f, kind) } }
    }

    /// Seconds of picture held per canvas right now.
    public var heldSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return frames.values.compactMap { l in l.first.flatMap { f in l.last.map { CMTimeGetSeconds(CMTimeSubtract($0.pts, f.pts)) } } }.min() ?? 0
    }

    public func consume(_ pb: CVPixelBuffer, pts: CMTime, canvas: CanvasKind) { encoders[canvas]?.encode(pb, pts: pts) }

    public func consume(_ block: AudioBlock) {
        lock.lock()
        audio.append((block.pts, block.program))
        if let newest = audio.last?.pts {
            let cutoff = CMTimeSubtract(newest, CMTime(seconds: seconds + 3, preferredTimescale: 600))
            if let k = audio.firstIndex(where: { $0.pts >= cutoff }), k > 0 { audio.removeFirst(k) }
        }
        lock.unlock()
    }

    private func add(_ f: EncodedVideoFrame, _ kind: CanvasKind) {
        lock.lock()
        frames[kind, default: []].append(f)
        let cutoff = CMTimeSubtract(f.pts, CMTime(seconds: seconds + 2, preferredTimescale: 600))
        if var l = frames[kind], let k = l.firstIndex(where: { $0.pts >= cutoff }), k > 0 { l.removeFirst(k); frames[kind] = l }
        lock.unlock()
    }

    public func finish() { encoders.values.forEach { $0.finish() } }

    /// Writes the last `seconds` of each canvas to `<folder>/<baseName> 16x9.mp4` (and `9x16`), starting at a keyframe.
    public func save(to folder: URL, baseName: String, seconds want: Double? = nil, completion: @escaping ([URL], String?) -> Void) {
        lock.lock()
        let snapshot = frames, sound = audio
        lock.unlock()
        let length = want ?? seconds
        saveQueue.async {
            var urls: [URL] = [], problem: String?
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                completion([], "Couldn't create \(folder.path): \(error.localizedDescription)"); return
            }
            for (kind, list) in snapshot.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                guard let last = list.last, let c = self.canvases[kind] else { continue }
                let start = CMTimeSubtract(last.pts, CMTime(seconds: length, preferredTimescale: 600))
                guard let i0 = list.firstIndex(where: { $0.isKeyframe && $0.pts >= start }) ?? list.firstIndex(where: \.isKeyframe) else { continue }
                let url = folder.appendingPathComponent("\(baseName) \(kind == .horizontal ? "16x9" : "9x16").mp4")
                do { try Self.write(Array(list[i0...]), sound: sound, fps: c.fps, to: url); urls.append(url) }
                catch { problem = error.localizedDescription }
            }
            completion(urls, urls.isEmpty ? (problem ?? "Nothing has been held yet.") : problem)
        }
    }

    static func write(_ clip: [EncodedVideoFrame], sound: [(pts: CMTime, samples: [Float])], fps: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: clip[0].format)
        vin.expectsMediaDataInRealTime = false
        let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        ain.expectsMediaDataInRealTime = false
        guard writer.canAdd(vin), writer.canAdd(ain) else { throw NSError(domain: "Framecast.Clip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't set up the clip file."]) }
        writer.add(vin); writer.add(ain)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Framecast.Clip", code: 2) }
        writer.startSession(atSourceTime: .zero)
        let t0 = clip[0].pts, end = CMTimeSubtract(clip[clip.count - 1].pts, t0)
        var videoSamples: [CMSampleBuffer] = []
        for (j, f) in clip.enumerated() {
            let dur = j + 1 < clip.count ? CMTimeSubtract(clip[j + 1].pts, f.pts) : CMTime(value: 1, timescale: CMTimeScale(fps))
            if let sb = videoSample(f, pts: CMTimeSubtract(f.pts, t0), duration: dur) { videoSamples.append(sb) }
        }

        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var audioSamples: [CMSampleBuffer] = []
        if let fd {
            for b in sound {
                var rel = CMTimeConvertScale(CMTimeSubtract(b.pts, t0), timescale: 48_000, method: .roundHalfAwayFromZero)
                var samples = b.samples
                if rel.value < 0 {                                   // block straddles the clip start: drop the part before it
                    let skip = Int(-rel.value)
                    guard skip * 2 < samples.count else { continue }
                    samples.removeFirst(skip * 2); rel = .zero
                }
                guard rel <= end, let sb = audioSample(samples, pts: rel, format: fd) else { continue }
                audioSamples.append(sb)
            }
        }
        // Feed both tracks as the writer asks for them: it interleaves, so one track can't be written ahead of the other.
        let group = DispatchGroup()
        func feed(_ input: AVAssetWriterInput, _ samples: [CMSampleBuffer], _ label: String) {
            var i = 0, done = false
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "framecast.clip.\(label)")) {
                while !done && input.isReadyForMoreMediaData {
                    if i >= samples.count { input.markAsFinished(); done = true; group.leave(); return }
                    if !input.append(samples[i]) { input.markAsFinished(); done = true; group.leave(); return }
                    i += 1
                }
            }
        }
        feed(vin, videoSamples, "video")
        feed(ain, audioSamples, "audio")
        if group.wait(timeout: .now() + 60) == .timedOut { writer.cancelWriting(); throw NSError(domain: "Framecast.Clip", code: 4, userInfo: [NSLocalizedDescriptionKey: "Writing the clip took too long."]) }
        writer.endSession(atSourceTime: CMTimeAdd(end, CMTime(value: 1, timescale: CMTimeScale(fps))))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "Framecast.Clip", code: 3, userInfo: [NSLocalizedDescriptionKey: "The clip didn't finish writing."]) }
    }

    static func videoSample(_ f: EncodedVideoFrame, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let len = f.data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: len, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        f.data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: pts)
        var size = len
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: f.format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if !f.isKeyframe, let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    static func audioSample(_ samples: [Float], pts: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                   sampleCount: samples.count / 2, presentationTimeStamp: pts,
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
