import Foundation
import VideoToolbox
import AudioToolbox
import CoreMedia

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc
    public var title: String { self == .h264 ? "H.264" : "HEVC" }
}

public struct EncodedVideoFrame {
    public let data: Data            // AVCC/HVCC: 4-byte length-prefixed NAL units
    public let pts: CMTime
    public let dts: CMTime
    public let isKeyframe: Bool
    public let format: CMFormatDescription
}

/// Hardware video encoder (VideoToolbox). No B-frames, so decode order equals presentation order.
public final class VideoEncoder: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var width: Int, height: Int, fps: Int
        public var codec: VideoCodec = .h264
        public var bitrateKbps: Int
        public var keyframeSeconds: Int = 2
        public var constantBitRate = false
        public init(width: Int, height: Int, fps: Int, codec: VideoCodec = .h264, bitrateKbps: Int, keyframeSeconds: Int = 2, constantBitRate: Bool = false) {
            self.width = width; self.height = height; self.fps = fps; self.codec = codec
            self.bitrateKbps = bitrateKbps; self.keyframeSeconds = keyframeSeconds; self.constantBitRate = constantBitRate
        }
    }
    public let config: Config
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKey = true
    public var onFrame: ((EncodedVideoFrame) -> Void)?
    public private(set) var framesEncoded = 0
    public private(set) var framesDropped = 0
    public private(set) var usingHardware = true
    public private(set) var lastFailure: String?

    public init(config: Config) throws {
        self.config = config
        try createSession()
    }

    private func createSession() throws {
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(config.width), height: Int32(config.height),
                                            codecType: config.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw NSError(domain: "Framecast.VideoEncoder", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "Hardware video encoder unavailable (\(st))"]) }
        func set(_ k: CFString, _ v: Any) { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel, config.codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, config.fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, config.fps * config.keyframeSeconds)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, config.keyframeSeconds)
        applyBitrate(on: s, kbps: config.bitrateKbps)
        var hw: CFBoolean?
        if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw) == noErr {
            usingHardware = (hw == kCFBooleanTrue)
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    private func applyBitrate(on s: VTCompressionSession, kbps: Int) {
        let bps = kbps * 1000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Cap bursts at 1.5x the average over one second (CBR asks for a tighter cap).
        let capBytes = Double(bps) / 8 * (config.constantBitRate ? 1.1 : 1.5)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [capBytes, 1.0] as CFArray)
    }

    public func setBitrate(kbps: Int) {
        lock.lock(); defer { lock.unlock() }
        if let session { applyBitrate(on: session, kbps: kbps) }
    }

    public func requestKeyframe() { lock.lock(); forceKey = true; lock.unlock() }

    public func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard let session else { lock.unlock(); return }
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        lock.unlock()
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                                 duration: CMTime(value: 1, timescale: CMTimeScale(config.fps)),
                                                 frameProperties: props, infoFlagsOut: nil) { [weak self] status, flags, sb in
            guard let self else { return }
            if flags.contains(.frameDropped) { self.framesDropped += 1; return }
            guard status == noErr, let sb, let frame = Self.unpack(sb) else {
                if status != noErr { self.lastFailure = "Encoder error \(status)"; self.framesDropped += 1 }
                return
            }
            self.framesEncoded += 1
            self.onFrame?(frame)
        }
        if st != noErr {
            lastFailure = "Encoder error \(st)"
            if st == kVTInvalidSessionErr { rebuild() }
        }
    }

    /// Recreate the session after a failure (the hardware encoder can be reset by the system).
    public func rebuild() {
        lock.lock(); defer { lock.unlock() }
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        try? createSession()
        forceKey = true
    }

    static func unpack(_ sb: CMSampleBuffer) -> EncodedVideoFrame? {
        guard let bb = CMSampleBufferGetDataBuffer(sb), let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let ptr else { return nil }
        let data = Data(bytes: ptr, count: length)
        var key = true
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = att.first?[kCMSampleAttachmentKey_NotSync] as? Bool { key = !notSync }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        var dts = CMSampleBufferGetDecodeTimeStamp(sb)
        if !dts.isValid { dts = pts }
        return EncodedVideoFrame(data: data, pts: pts, dts: dts, isKeyframe: key, format: fd)
    }

    public func finish() {
        lock.lock(); let s = session; lock.unlock()
        if let s { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    /// avcC / hvcC configuration record for the stream.
    public static func configurationRecord(_ fd: CMFormatDescription) -> Data? {
        guard let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] else { return nil }
        return (atoms["avcC"] ?? atoms["hvcC"]) as? Data
    }
}

public struct EncodedAudioPacket {
    public let data: Data
    public let pts: CMTime
}

/// AAC-LC encoder for 48 kHz stereo Float32 blocks. Output timestamps are corrected for encoder priming.
public final class AACEncoder: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private var pending: [Float] = []
    private var pendingStartIndex: Int64 = 0
    private var packetIndex: Int64 = 0
    private var firstIndex: Int64?
    private var priming: Int64 = 2112
    public let bitrateKbps: Int
    public var onPacket: ((EncodedAudioPacket) -> Void)?
    /// AudioSpecificConfig for AAC-LC 48 kHz stereo.
    public static let audioSpecificConfig = Data([0x11, 0x90])

    public init(bitrateKbps: Int = 160) throws {
        self.bitrateKbps = bitrateKbps
        var inDesc = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                                 mBitsPerChannel: 32, mReserved: 0)
        var outDesc = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2,
                                                  mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                  mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var conv: AudioConverterRef?
        let st = AudioConverterNew(&inDesc, &outDesc, &conv)
        guard st == noErr, let conv else { throw NSError(domain: "Framecast.AAC", code: Int(st)) }
        var br = UInt32(bitrateKbps * 1000)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
        var prime = AudioConverterPrimeInfo()
        var size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(conv, kAudioConverterPrimeInfo, &size, &prime) == noErr, prime.leadingFrames > 0 {
            priming = Int64(prime.leadingFrames)
        }
        converter = conv
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    /// Input handed to the converter callback. The memory must outlive the callback, so it is malloc'd.
    private final class Feed {
        let ptr: UnsafeMutablePointer<Float>
        let count: Int
        var consumed = false
        init(_ s: [Float]) {
            count = s.count
            ptr = .allocate(capacity: s.count)
            s.withUnsafeBufferPointer { ptr.initialize(from: $0.baseAddress!, count: s.count) }
        }
        deinit { ptr.deallocate() }
    }

    /// Feed interleaved stereo samples whose first frame sits at timeline sample `index`.
    public func append(_ samples: [Float], timelineIndex index: Int64) {
        if firstIndex == nil { firstIndex = index; pendingStartIndex = index }
        pending.append(contentsOf: samples)
        while pending.count >= 1024 * 2 {
            let chunk = Array(pending[0..<(1024 * 2)])
            pending.removeFirst(1024 * 2)
            encodeChunk(chunk)
        }
    }

    private func encodeChunk(_ chunk: [Float]) {
        guard let converter else { return }
        let feed = Feed(chunk)
        var outBytes = [UInt8](repeating: 0, count: 4096)
        var packetDesc = AudioStreamPacketDescription()
        var packets: UInt32 = 1
        _ = outBytes.withUnsafeMutableBytes { raw -> OSStatus in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096, mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, _, user in
                let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                if feed.consumed { ioPackets.pointee = 0; return 1 }   // "no more data for now"
                feed.consumed = true
                ioPackets.pointee = UInt32(feed.count / 2)
                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(feed.ptr)
                ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.count * MemoryLayout<Float>.size)
                ioData.pointee.mBuffers.mNumberChannels = 2
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &packets, &abl, &packetDesc)
        }
        guard packets > 0 else { return }
        let n = Int(packetDesc.mDataByteSize)
        guard n > 0 else { return }
        let idx = pendingStartIndex + packetIndex * 1024 - priming
        packetIndex += 1
        guard let first = firstIndex, idx + 1024 > first else { return }   // drop pure priming packets
        let pts = CMTime(value: max(idx, first), timescale: 48_000)
        onPacket?(EncodedAudioPacket(data: Data(outBytes[0..<n]), pts: pts))
    }
}
