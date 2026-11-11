import Foundation
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ScreenCaptureKit

// MARK: - Audio format conversion

/// Converts whatever a capture device delivers into 48 kHz stereo interleaved Float32.
public final class AudioNormalizer {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    public let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioBlock.sampleRate, channels: 2, interleaved: true)!
    public init() {}

    func convert(_ sb: CMSampleBuffer) -> [Float]? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var desc = asbd.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, let inFmt = AVAudioFormat(streamDescription: &desc) else { return nil }
        if inputFormat == nil || inputFormat! != inFmt {
            inputFormat = inFmt
            converter = AVAudioConverter(from: inFmt, to: outputFormat)
        }
        guard let converter, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        inBuf.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return convert(inBuf, converter: converter)
    }

    public func convert(_ inBuf: AVAudioPCMBuffer) -> [Float]? {
        if inputFormat == nil || inputFormat! != inBuf.format {
            inputFormat = inBuf.format
            converter = AVAudioConverter(from: inBuf.format, to: outputFormat)
        }
        guard let converter else { return nil }
        return convert(inBuf, converter: converter)
    }

    private func convert(_ inBuf: AVAudioPCMBuffer, converter: AVAudioConverter) -> [Float]? {
        // Mono inputs are spread to both channels.
        if inBuf.format.channelCount == 1 { converter.channelMap = [0, 0] }
        let ratio = outputFormat.sampleRate / inBuf.format.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if err != nil || out.frameLength == 0 { return nil }
        let p = out.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength) * 2))
    }
}

// MARK: - Camera

public final class CameraSource: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let id: UUID
    public private(set) var state: SourceState = .stopped
    public var nativeSize: CGSize { size }
    private var size = CGSize(width: 1920, height: 1080)
    private let deviceID: String
    private let wanted: (Int, Int, Int)
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "framecast.camera", qos: .userInteractive)
    private let slot = FrameSlot()
    public private(set) var deviceName = ""
    private var observer: NSObjectProtocol?
    private let dropLock = NSLock()
    private var drops = 0
    /// Frames the camera delivered too late to use (the governor and Gate 0 watch this).
    public var droppedFrames: Int { dropLock.lock(); defer { dropLock.unlock() }; return drops }
    /// Average seconds from capture to arrival; a phone angle's sound waits for the difference (lip sync).
    public var captureLag: Double { slot.lag }

    public init(id: UUID, deviceID: String, width: Int, height: Int, fps: Int) {
        self.id = id; self.deviceID = deviceID; wanted = (width, height, fps)
    }

    public static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified).devices
            .filter { !$0.localizedName.contains("Framecast") }
    }

    /// One of a camera's formats: its size and best frame rate.
    public struct FormatInfo: Equatable, Sendable {
        public var width: Int, height: Int, maxFPS: Double
        public init(width: Int, height: Int, maxFPS: Double) { self.width = width; self.height = height; self.maxFPS = maxFPS }
    }

    /// The format a camera opens for a requested size and frame rate (an index into `formats`): the closest size, a
    /// format that can't reach the rate counting as 2000 pixels further. A 4K request never gives up the frame rate:
    /// when the closest 4K format is slower, the camera opens as for 1080p.
    public static func chooseFormat(_ formats: [FormatInfo], width w: Int, height h: Int, fps: Int) -> Int? {
        func closest(_ w: Int, _ h: Int) -> Int? {
            formats.indices.min { a, b in
                func score(_ f: FormatInfo) -> Double {
                    abs(Double(f.width - w)) + abs(Double(f.height - h)) + (f.maxFPS + 0.5 < Double(fps) ? 2000 : 0)
                }
                return score(formats[a]) < score(formats[b])
            }
        }
        let best = closest(w, h)
        if w >= 3840, let b = best, formats[b].maxFPS + 0.5 < Double(fps) { return closest(1920, 1080) }
        return best
    }

    /// Whether a 4K request opens a 4K picture shaped near 16:9 (to 17:9) at the camera's frame rate.
    public static func offers4K(_ formats: [FormatInfo], fps: Int) -> Bool {
        guard let i = chooseFormat(formats, width: 3840, height: 2160, fps: fps) else { return false }
        let f = formats[i], aspect = Double(f.width) / Double(max(1, f.height))
        return f.width >= 3840 && f.height >= 2160 && aspect >= 1.70 && aspect <= 1.92 && f.maxFPS + 0.5 >= Double(fps)
    }

    private static func info(_ f: AVCaptureDevice.Format) -> FormatInfo {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return FormatInfo(width: Int(d.width), height: Int(d.height), maxFPS: f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
    }

    /// Whether Use 4K would give this camera a 4K picture at `fps`, decided by the chooser `configure` uses. Reads
    /// the device's list of formats only: the camera isn't opened. Nil when no such camera is connected.
    public static func offers4K(deviceID: String, fps: Int) -> Bool? {
        let device = deviceID.isEmpty ? (AVCaptureDevice.default(for: .video) ?? devices().first) : AVCaptureDevice(uniqueID: deviceID)
        guard let device else { return nil }
        return offers4K(device.formats.map(info), fps: fps)
    }

    /// Whether Center Stage (Control Center › Video Effects) is reframing this camera's picture. Reads the setting
    /// only: the camera isn't opened, and nothing is changed. Nil when no such camera is connected.
    public static func centerStageActive(deviceID: String) -> Bool? {
        let device = deviceID.isEmpty ? (AVCaptureDevice.default(for: .video) ?? devices().first) : AVCaptureDevice(uniqueID: deviceID)
        guard let device else { return nil }
        return device.isCenterStageActive
    }

    public func start() {
        state = .starting
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.queue.async { self?.configure() } } else { self?.state = .failed("Needs Camera access") }
            }
            return
        }
        guard auth == .authorized else { state = .failed("Needs Camera access"); return }
        queue.async { self.configure() }
    }

    private func configure() {
        let device = deviceID.isEmpty ? (AVCaptureDevice.default(for: .video) ?? Self.devices().first)
                                      : AVCaptureDevice(uniqueID: deviceID)
        guard let device else { state = .failed("Camera not found."); return }
        deviceName = device.localizedName
        do {
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { state = .failed("Camera is in use by another app."); session.commitConfiguration(); return }
            session.addInput(input)
            // Closest format to the requested size and frame rate (the same chooser Use 4K asks).
            let (w, h, fps) = wanted
            let best = Self.chooseFormat(device.formats.map(Self.info), width: w, height: h, fps: fps).map { device.formats[$0] }
            if let best {
                try device.lockForConfiguration()
                device.activeFormat = best
                if best.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate + 0.5 >= Double(fps) && $0.minFrameRate <= Double(fps) }) {
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                }
                device.unlockForConfiguration()
                let d = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
                size = CGSize(width: Int(d.width), height: Int(d.height))
            }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            session.commitConfiguration()
            observer = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.state = .lost("Camera unavailable")
            }
            session.startRunning()
            state = .running
        } catch {
            session.commitConfiguration()
            state = .failed("Camera unavailable.")
        }
    }

    public func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        state = .stopped
        slot.clear()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        slot.put(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if case .lost = state { state = .running }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dropLock.lock(); drops += 1; dropLock.unlock()
    }

    public func image(at time: CMTime) -> CIImage? {
        guard let (pb, _) = slot.get() else { return nil }
        if state == .running && slot.age > 2.5 { state = .lost("No new frames from the camera") }
        return CIImage(cvPixelBuffer: pb)
    }
}

// MARK: - Screen, window and app capture (ScreenCaptureKit)

public enum ScreenTarget: Sendable {
    case display(UInt32)          // 0 = main display
    case window(UInt32)
    case application(String)      // bundle id
}

/// Follows one app by bundle id so app sources can wait for it to open and pick it up again after it quits.
final class AppWatcher {
    static let waiting = "Waiting for the app to open."
    private var tokens: [NSObjectProtocol] = []

    init(bundleID: String, opened: @escaping () -> Void, quit: @escaping () -> Void) {
        let nc = NSWorkspace.shared.notificationCenter
        let matches = { (n: Notification) in
            (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == bundleID
        }
        tokens = [
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { if matches($0) { opened() } },
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { if matches($0) { quit() } },
        ]
    }

    deinit { tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// An app that has just opened takes a moment to appear in ScreenCaptureKit's list; one with no windows
    /// may not be listed until it opens one. Quick retries first, then a slow poll while it keeps running.
    static func retryDelay(_ attempt: Int) -> Double { attempt < 6 ? 0.5 : 3 }
}

public final class ScreenSource: NSObject, VideoSource, SCStreamOutput, SCStreamDelegate {
    public let id: UUID
    public private(set) var state: SourceState = .stopped
    public var nativeSize: CGSize { size }
    private var size = CGSize(width: 1920, height: 1080)
    private let target: ScreenTarget
    private let fps: Int
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "framecast.screen", qos: .userInteractive)
    private let slot = FrameSlot()
    private var watcher: AppWatcher?
    private var generation = 0      // bumped by stop and app quit, so a start still in flight is dropped
    private var config: SCStreamConfiguration?
    /// Where the capture sits on the desktop, for mapping the cursor and clicks (the live editor).
    private let geoLock = NSLock()
    private var geo: ScreenGeometry?
    private var displayID: CGDirectDisplayID?
    private var geoCheckedAt = 0.0
    private var geoRefreshing = false
    private var pixelScale: CGFloat = 2
    private var capturedPoints = CGSize.zero
    /// A moved window sends no new frames while its content stays the same, so asking also has it looked up again, on
    /// the capture queue (4 times a second at most for a window): the render queue never waits on the window server.
    public var geometry: ScreenGeometry? {
        geoLock.lock(); defer { geoLock.unlock() }
        if !geoRefreshing, HostClock.seconds() - geoCheckedAt > (displayID == nil ? 0.25 : 2) {
            geoRefreshing = true
            queue.async { [weak self] in
                self?.refreshGeometry()
                self?.geoLock.lock(); self?.geoRefreshing = false; self?.geoLock.unlock()
            }
        }
        return geo
    }

    public init(id: UUID, target: ScreenTarget, fps: Int) { self.id = id; self.target = target; self.fps = fps }

    /// Display capture leaves out Framecast's own windows, unless `showsOwnWindows` is on (for demoing Framecast
    /// itself). Windows in `privateWindows` (the presenter view) are always left out.
    public static var showsOwnWindows: Bool {
        get { optionsLock.lock(); defer { optionsLock.unlock() }; return _showsOwn }
        set { optionsLock.lock(); _showsOwn = newValue; optionsLock.unlock() }
    }
    public static var privateWindows: Set<CGWindowID> {
        get { optionsLock.lock(); defer { optionsLock.unlock() }; return _private }
        set { optionsLock.lock(); _private = newValue; optionsLock.unlock() }
    }
    /// Apps whose windows display captures leave out (password managers, by default), by bundle id.
    public static var hiddenApps: Set<String> {
        get { optionsLock.lock(); defer { optionsLock.unlock() }; return _hiddenApps }
        set { optionsLock.lock(); _hiddenApps = newValue; optionsLock.unlock() }
    }
    /// Draws a ring around each click (macOS 15 and later).
    public static var showsClicks: Bool {
        get { optionsLock.lock(); defer { optionsLock.unlock() }; return _showsClicks }
        set { optionsLock.lock(); _showsClicks = newValue; optionsLock.unlock() }
    }
    private static let optionsLock = NSLock()
    nonisolated(unsafe) private static var _showsOwn = false
    nonisolated(unsafe) private static var _private: Set<CGWindowID> = []
    nonisolated(unsafe) private static var _hiddenApps: Set<String> = []
    nonisolated(unsafe) private static var _showsClicks = false

    private static func displayFilter(_ display: SCDisplay, _ content: SCShareableContent) -> SCContentFilter {
        let hiddenApps = hiddenApps
        if showsOwnWindows {
            let hidden = privateWindows
            return SCContentFilter(display: display, excludingWindows: content.windows.filter {
                hidden.contains($0.windowID) || hiddenApps.contains($0.owningApplication?.bundleIdentifier ?? "")
            })
        }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier || hiddenApps.contains($0.bundleIdentifier) }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
    }

    /// Applies a change of `showsClicks` to a running capture.
    public func refreshConfiguration() {
        guard let s = stream, let cfg = config else { return }
        if #available(macOS 15.0, *) { cfg.showMouseClicks = Self.showsClicks }
        Task { try? await s.updateConfiguration(cfg) }
    }

    /// Applies a change of `showsOwnWindows` or `privateWindows` to a running display capture.
    public func refreshFilter() {
        guard case .display(let did) = target, let s = stream else { return }
        Task {
            // All windows, not just on-screen ones, so a password manager with no window showing is still left out.
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let display = content.displays.first(where: { did == 0 ? $0.displayID == CGMainDisplayID() : $0.displayID == did }) ?? content.displays.first
            else { return }
            try? await s.updateContentFilter(Self.displayFilter(display, content))
        }
    }

    public func start() {
        if case .application(let bid) = target, watcher == nil {
            watcher = AppWatcher(bundleID: bid, opened: { [weak self] in self?.appOpened() },
                                 quit: { [weak self] in self?.appQuit() })
        }
        begin()
    }

    private func begin(attempt: Int = 0) {
        if attempt == 0 { state = .starting }
        let gen = generation
        Task {
            do {
                var isDisplay = false
                if case .display = target { isDisplay = true }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: !isDisplay)
                let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                // What the display filter is built from: if it changes while the capture starts, build it again after.
                let used = (Self.hiddenApps, Self.showsOwnWindows, Self.privateWindows, Self.showsClicks)
                let filter: SCContentFilter
                switch target {
                case .display(let did):
                    guard let display = content.displays.first(where: { did == 0 ? $0.displayID == CGMainDisplayID() : $0.displayID == did })
                            ?? content.displays.first else { state = .failed("No display available to capture."); return }
                    filter = Self.displayFilter(display, content)
                    size = CGSize(width: display.width, height: display.height)
                    setGeometry(display: display.displayID)
                case .window(let wid):
                    guard let w = content.windows.first(where: { $0.windowID == wid }) else {
                        state = .failed("Window not found. Add it again from the + menu."); return
                    }
                    filter = SCContentFilter(desktopIndependentWindow: w)
                    size = w.frame.size
                    setGeometry(window: wid)
                case .application(let bid):
                    guard let app = content.applications.first(where: { $0.bundleIdentifier == bid }),
                          let display = content.displays.first else {
                        state = .failed(AppWatcher.waiting)
                        if AppWatcher.isRunning(bid) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + AppWatcher.retryDelay(attempt)) { [weak self] in
                                guard let self, self.generation == gen, self.stream == nil else { return }
                                self.begin(attempt: attempt + 1)
                            }
                        }
                        return
                    }
                    filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                    size = CGSize(width: display.width, height: display.height)
                    setGeometry(display: display.displayID)
                }
                let scale = CGFloat(filter.pointPixelScale)
                geoLock.lock(); pixelScale = scale; capturedPoints = size; geoLock.unlock()
                var w = size.width * scale, h = size.height * scale
                let maxSide: CGFloat = 3840
                if max(w, h) > maxSide { let k = maxSide / max(w, h); w *= k; h *= k }
                size = CGSize(width: Int(w) & ~1, height: Int(h) & ~1)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(size.width); cfg.height = Int(size.height)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.queueDepth = 6
                cfg.showsCursor = true
                if #available(macOS 15.0, *) { cfg.showMouseClicks = Self.showsClicks }
                cfg.colorSpaceName = CGColorSpace.sRGB
                config = cfg
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await s.startCapture()
                guard generation == gen else { try? await s.stopCapture(); return }
                stream = s
                state = .running
                if isDisplay && (used.0 != Self.hiddenApps || used.1 != Self.showsOwnWindows || used.2 != Self.privateWindows) { refreshFilter() }
                if used.3 != Self.showsClicks { refreshConfiguration() }
            } catch {
                guard generation == gen else { return }
                state = .failed(Self.describe(error))
            }
        }
    }

    private func appOpened() {
        guard stream == nil, state != .stopped else { return }
        generation += 1
        begin()
    }

    private func appQuit() {
        guard state != .stopped else { return }
        generation += 1
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        slot.clear()
        state = .lost(AppWatcher.waiting)
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue {
            return "Needs Screen Recording access"
        }
        return "Couldn't capture: \(ns.localizedDescription)"
    }

    public func stop() {
        generation += 1
        watcher = nil
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        state = .stopped
        slot.clear()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        slot.put(pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
        refreshGeometry()
    }

    private func setGeometry(display: CGDirectDisplayID) {
        geoLock.lock(); displayID = display; geo = ScreenGeometry(rect: CGDisplayBounds(display)); geoCheckedAt = HostClock.seconds(); geoLock.unlock()
    }
    private func setGeometry(window: CGWindowID) {
        let r = Self.windowBounds(window)
        geoLock.lock()
        displayID = nil; geo = r.map(ScreenGeometry.init); geoCheckedAt = HostClock.seconds()
        let capturing = capturedPoints != .zero
        let resized = capturing && (r.map { abs($0.width - capturedPoints.width) > 1 || abs($0.height - capturedPoints.height) > 1 } ?? false)
        let scale = pixelScale
        if resized, let r { capturedPoints = r.size }
        geoLock.unlock()
        // A resized window would be scaled into the old frame size, off from its bounds: capture it at its new size.
        if resized, let r, let s = stream, let cfg = config {
            var w = r.width * scale, h = r.height * scale
            if max(w, h) > 3840 { let k = 3840 / max(w, h); w *= k; h *= k }
            cfg.width = Int(w) & ~1; cfg.height = Int(h) & ~1
            size = CGSize(width: cfg.width, height: cfg.height)
            Task { try? await s.updateConfiguration(cfg) }
        }
    }
    /// Windows move and displays get rearranged: look again now and then (4 times a second for a window).
    private func refreshGeometry() {
        let now = HostClock.seconds()
        geoLock.lock(); let did = displayID, last = geoCheckedAt; geoLock.unlock()
        if let did { if now - last > 2 { setGeometry(display: did) } }
        else if case .window(let wid) = target, now - last > 0.25 { setGeometry(window: wid) }
    }
    static func windowBounds(_ id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let b = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The window closed, the app quit or the display went away: stop showing its last frame.
        slot.clear()
        if self.stream === stream { self.stream = nil }
        if case .window = target { state = .lost("Window not found. Add it again from the + menu.") }
        else if case .display = target { state = .lost("Display disconnected") }
        else if case .application(let bid) = target, !AppWatcher.isRunning(bid) { state = .lost(AppWatcher.waiting) }
        else { state = .lost(Self.describe(error)) }
    }

    public func image(at time: CMTime) -> CIImage? {
        guard let (pb, _) = slot.get() else { return nil }
        return CIImage(cvPixelBuffer: pb)
    }
}

// MARK: - Audio sources

public protocol AudioCaptureSource: AnyObject {
    var id: UUID { get }
    var state: SourceState { get }
    var deviceName: String { get }
    func start()
    func stop()
}

/// System audio ("Everything your Mac plays") or one app's audio, via ScreenCaptureKit.
public final class SystemAudioSource: NSObject, AudioCaptureSource, SCStreamOutput, SCStreamDelegate {
    public let id: UUID
    public private(set) var state: SourceState = .stopped
    public let deviceName: String
    private let bundleID: String?
    private weak var mixer: AudioMixer?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "framecast.sysaudio", qos: .userInteractive)
    private let normalizer = AudioNormalizer()
    private var watcher: AppWatcher?
    private var generation = 0      // bumped by stop and app quit, so a start still in flight is dropped

    public init(id: UUID, appBundleID: String?, appName: String?, mixer: AudioMixer) {
        self.id = id; bundleID = appBundleID; self.mixer = mixer
        deviceName = appName ?? "Everything your Mac plays"
    }

    public func start() {
        if let bundleID, watcher == nil {
            watcher = AppWatcher(bundleID: bundleID, opened: { [weak self] in self?.appOpened() },
                                 quit: { [weak self] in self?.appQuit() })
        }
        begin()
    }

    private func begin(attempt: Int = 0) {
        if attempt == 0 { state = .starting }
        let gen = generation
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { state = .failed("No display available to capture."); return }
                let filter: SCContentFilter
                if let bundleID {
                    guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                        state = .failed(AppWatcher.waiting)
                        if AppWatcher.isRunning(bundleID) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + AppWatcher.retryDelay(attempt)) { [weak self] in
                                guard let self, self.generation == gen, self.stream == nil else { return }
                                self.begin(attempt: attempt + 1)
                            }
                        }
                        return
                    }
                    filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                } else {
                    let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                    filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                }
                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.excludesCurrentProcessAudio = true
                cfg.sampleRate = 48_000
                cfg.channelCount = 2
                cfg.width = 2; cfg.height = 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await s.startCapture()
                guard generation == gen else { try? await s.stopCapture(); return }
                stream = s
                state = .running
            } catch {
                guard generation == gen else { return }
                state = .failed(ScreenSource.describe(error))
            }
        }
    }

    private func appOpened() {
        guard stream == nil, state != .stopped else { return }
        generation += 1
        begin()
    }

    private func appQuit() {
        guard state != .stopped else { return }
        generation += 1
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        state = .lost(AppWatcher.waiting)
    }

    public func stop() {
        generation += 1
        watcher = nil
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        state = .stopped
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let samples = normalizer.convert(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        samples.withUnsafeBufferPointer { mixer?.push(id, samples: $0.baseAddress!, frames: samples.count / 2, pts: pts) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        if self.stream === stream { self.stream = nil }
        if let bundleID, !AppWatcher.isRunning(bundleID) { state = .lost(AppWatcher.waiting) }
        else { state = .lost(ScreenSource.describe(error)) }
    }
}

/// A microphone or audio interface. Uses AVAudioEngine so Apple's voice processing (echo cancellation,
/// noise suppression) can be switched on.
public final class MicrophoneSource: AudioCaptureSource {
    public let id: UUID
    public private(set) var state: SourceState = .stopped
    public private(set) var deviceName = ""
    private let deviceUID: String
    private weak var mixer: AudioMixer?
    private var engine: AVAudioEngine?
    private let normalizer = AudioNormalizer()
    private let queue = DispatchQueue(label: "framecast.mic")
    public var voiceProcessing: Bool
    // Another audio engine in the app (the guest room's WebRTC audio with voice processing) reconfigures the input
    // device; AVAudioEngine then stops and the mic falls silent. Restart on configuration changes and on stalls.
    private var configObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private var lastBuffer = 0.0
    private var wanted = false

    public init(id: UUID, deviceUID: String, voiceProcessing: Bool, mixer: AudioMixer) {
        self.id = id; self.deviceUID = deviceUID; self.voiceProcessing = voiceProcessing; self.mixer = mixer
    }

    public static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    public func start() {
        state = .starting
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if auth == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                guard let self else { return }
                if ok { self.queue.async { self.wanted = true; self.configure(); self.startWatchdog() } } else { self.state = .failed("Needs Microphone access") }
            }
            return
        }
        guard auth == .authorized else { state = .failed("Microphone access is turned off for Framecast in System Settings."); return }
        queue.async { self.wanted = true; self.configure(); self.startWatchdog() }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.wanted, case .running = self.state, HostClock.seconds() - self.lastBuffer > 2 else { return }
            self.restart()
        }
        t.resume(); watchdog = t
    }

    /// Tears the engine down and builds a new one on the same device (on `queue`).
    private func restart() {
        teardown()
        guard wanted else { return }
        configure()
    }

    private func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func configure() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty {
            guard let devID = AudioDevices.deviceID(forUID: deviceUID) else { state = .failed("Microphone not found."); return }
            var d = devID
            let err = AudioUnitSetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr { state = .failed("Core Audio would not open that device for input."); return }
            deviceName = AudioDevices.name(of: devID) ?? "Microphone"
        } else {
            deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default microphone"
        }
        if voiceProcessing {
            try? input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { state = .failed("That device has no microphone input."); return }
        input.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buf, when in
            guard let self else { return }
            self.lastBuffer = HostClock.seconds()
            guard let samples = self.normalizer.convert(buf) else { return }
            let pts: CMTime = when.isHostTimeValid
                ? CMClockMakeHostTimeFromSystemUnits(when.hostTime)
                : HostClock.now()
            samples.withUnsafeBufferPointer { self.mixer?.push(self.id, samples: $0.baseAddress!, frames: samples.count / 2, pts: pts) }
        }
        do {
            try engine.start()
            self.engine = engine
            lastBuffer = HostClock.seconds()
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.queue.asyncAfter(deadline: .now() + 0.3) { self?.restart() }
            }
            state = .running
        } catch {
            state = .failed("That microphone could not be started.")
        }
    }

    public func stop() {
        queue.sync {
            wanted = false
            watchdog?.cancel(); watchdog = nil
            teardown()
        }
        state = .stopped
    }
}

public enum AudioDevices {
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
        }
        return err == noErr && dev != 0 ? dev : nil
    }
    public static func name(of dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }
}
