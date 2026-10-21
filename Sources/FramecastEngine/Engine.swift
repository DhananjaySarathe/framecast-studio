import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import AVFoundation

public struct CanvasConfig: Equatable, Sendable {
    public var width: Int, height: Int, fps: Int
    public var isOn: Bool
    public init(width: Int, height: Int, fps: Int, isOn: Bool = true) { self.width = width; self.height = height; self.fps = fps; self.isOn = isOn }
    public var size: CGSize { CGSize(width: width, height: height) }
}

public protocol CanvasFrameConsumer: AnyObject {
    /// Called on the render queue for every composited frame of `canvas`.
    func consume(_ pb: CVPixelBuffer, pts: CMTime, canvas: CanvasKind)
}

public struct EngineMetrics: Sendable {
    public var renderedFrames: [CanvasKind: Int] = [:]
    public var lateFrames = 0              // ticks that could not render in time
    public var renderMs: Double = 0
    public var recordingDropped = 0
    public var thermalSerious = false
}

/// Framecast's media engine: sources → compositor (two canvases on one clock) → preview, recordings, streams.
public final class Engine: @unchecked Sendable {
    public let origin: CMTime
    public let mixer: AudioMixer
    public let compositor = Compositor()
    public let overlays = OverlayRenderer()
    private let renderQueue = DispatchQueue(label: "framecast.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    private var videoSources: [UUID: VideoSource] = [:]
    private var audioSources: [UUID: AudioCaptureSource] = [:]
    private var soundPads: [UUID: SoundPadSource] = [:]
    private var records: [UUID: SourceRecord] = [:]
    private var luts: [String: CubeLUT] = [:]
    public private(set) var lutProblems: [String: String] = [:]
    private var canvases: [CanvasKind: CanvasConfig] = [
        .horizontal: CanvasConfig(width: 1920, height: 1080, fps: 30),
        .vertical: CanvasConfig(width: 1080, height: 1920, fps: 30),
    ]
    private var pools: [CanvasKind: CVPixelBufferPool] = [:]

    private struct Program {
        var items: [SceneItem] = []
        var previous: [SceneItem] = []
        var transition: TransitionKind = .cut
        var started: Double = 0
        var duration: Double = 0
    }
    private var programs: [CanvasKind: Program] = [.horizontal: Program(), .vertical: Program()]
    /// Preview before air: a scene shown in the studio but not on air, rendered at half size.
    private var previewItems: [CanvasKind: [SceneItem]] = [:]
    private var previewPools: [CanvasKind: CVPixelBufferPool] = [:]
    public var scenePreviewHandler: ((CanvasKind, CVPixelBuffer) -> Void)?

    private struct ElementState { var element: OverlayElement; var shownAt: Double; var hidingAt: Double? }
    private var elements: [UUID: ElementState] = [:]
    private var chatOverlay: (ChatOverlay, Double, Double?)?
    public var accent = RGBA(0.30, 0.82, 0.77)

    private var consumers: [ObjectIdentifier: CanvasFrameConsumer] = [:]
    private var recorders: [CanvasRecorder] = []
    private var recorderBridge: RecorderAudioBridge?
    public var previewHandler: ((CanvasKind, CVPixelBuffer) -> Void)?
    public var previewEvery = 1          // 1 = every frame, 2 = half rate, 0 = off
    private var tickCount = 0
    private var nextDue: [CanvasKind: Double] = [:]
    public private(set) var metrics = EngineMetrics()
    private var monitor: MonitorOutput?

    public init() {
        AssetPack.canvasSizes = canvases.mapValues(\.size)
        origin = HostClock.now()
        mixer = AudioMixer(origin: origin)
    }

    // MARK: Lifecycle

    public func start() {
        mixer.start()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        let mon = MonitorOutput(mixer: mixer)
        monitor = mon
        mon.start()
    }

    public func stop() {
        timer?.cancel(); timer = nil
        mixer.stop()
        monitor?.stop()
        lock.lock()
        let vs = Array(videoSources.values), as_ = Array(audioSources.values)
        videoSources.removeAll(); audioSources.removeAll()
        lock.unlock()
        vs.forEach { $0.stop() }; as_.forEach { $0.stop() }
    }

    public func timelineIndex(_ t: CMTime) -> Int64 { mixer.timelineIndex(for: t) }

    // MARK: Canvases

    public func setCanvas(_ kind: CanvasKind, _ cfg: CanvasConfig) {
        lock.lock()
        var resized = false
        if canvases[kind] != cfg {
            if canvases[kind]?.width != cfg.width || canvases[kind]?.height != cfg.height { pools[kind] = nil; previewPools[kind] = nil; resized = true }
            canvases[kind] = cfg
        }
        let packLayers = resized ? videoSources.values.compactMap { $0 as? PackImageSource } : []
        lock.unlock()
        if resized { AssetPack.canvasSizes[kind] = cfg.size }
        // Pack artwork is decoded to fit the canvas: decode again at the new size.
        for p in packLayers { p.stop(); p.start() }
    }
    public func canvas(_ kind: CanvasKind) -> CanvasConfig { lock.lock(); defer { lock.unlock() }; return canvases[kind]! }

    private func pool(for kind: CanvasKind, _ cfg: CanvasConfig) -> CVPixelBufferPool? {
        if let p = pools[kind] { return p }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: cfg.width, kCVPixelBufferHeightKey as String: cfg.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attrs as CFDictionary, &p)
        pools[kind] = p
        return p
    }

    // MARK: Sources

    /// Brings running sources in line with the collection: starts new ones, stops removed ones, and
    /// restarts any whose device or target changed.
    public func sync(sources: [SourceRecord], fpsHint: Int) {
        lock.lock()
        let old = records
        records = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var toStart: [SourceRecord] = []
        var toStop: [UUID] = []
        for s in sources {
            if let o = old[s.id] {
                if o.kind != s.kind { toStop.append(s.id); toStart.append(s) }
                else {
                    if let a = s.audio { mixer.update(s.id, settings: a) }
                    if let m = videoSources[s.id] as? MediaFileSource { m.loop = s.media?.loop ?? false }
                }
                if let lut = s.lut, luts[lut.path] == nil { loadLUT(lut.path) }
            } else { toStart.append(s) }
        }
        for id in old.keys where records[id] == nil { toStop.append(id) }
        lock.unlock()
        for id in toStop { stopSource(id) }
        for s in toStart { startSource(s, fps: fpsHint) }
    }

    private func loadLUT(_ path: String) {
        do { luts[path] = try CubeLUT.load(path: path); lutProblems[path] = nil }
        catch { lutProblems[path] = error.localizedDescription }
    }

    private func stopSource(_ id: UUID) {
        lock.lock()
        let v = videoSources.removeValue(forKey: id)
        let a = audioSources.removeValue(forKey: id)
        soundPads[id] = nil
        lock.unlock()
        v?.stop(); a?.stop()
        mixer.removeSource(id)
    }

    /// Display captures pick up a changed own-windows setting or presenter window (ScreenSource.showsOwnWindows).
    public func refreshScreenFilters() {
        lock.lock(); let screens = videoSources.values.compactMap { $0 as? ScreenSource }; lock.unlock()
        screens.forEach { $0.refreshFilter() }
    }

    public func restartSource(_ id: UUID) {
        lock.lock(); let r = records[id]; lock.unlock()
        guard let r else { return }
        stopSource(id); startSource(r, fps: canvas(.horizontal).fps)
    }

    private func startSource(_ s: SourceRecord, fps: Int) {
        var video: VideoSource?
        var audio: AudioCaptureSource?
        switch s.kind {
        case .camera(let dev, let w, let h, let f): video = CameraSource(id: s.id, deviceID: dev, width: w, height: h, fps: f)
        case .display(let did): video = ScreenSource(id: s.id, target: .display(did), fps: fps)
        case .window(_, _, let wid): video = ScreenSource(id: s.id, target: .window(wid), fps: fps)
        case .application(let bid, _): video = ScreenSource(id: s.id, target: .application(bid), fps: fps)
        case .image(let path): video = StaticImageSource(id: s.id, image: StaticImageSource.image(path: path))
        case .color(let c): video = StaticImageSource(id: s.id, image: StaticImageSource.color(c))
        case .wallpaper(let w) where w.hasPrefix("pack:"): video = PackImageSource(id: s.id, assetID: String(w.dropFirst(5)))
        case .wallpaper(let w): video = StaticImageSource(id: s.id, image: Wallpapers.image(w))
        case .packImage(let asset): video = PackImageSource(id: s.id, assetID: asset)
        case .countdown(let style, let endsAt): video = CountdownSource(id: s.id, style: style, endsAt: endsAt)
        case .text(let style): video = StaticImageSource(id: s.id, image: StaticImageSource.text(style, scale: 1))
        case .testPattern: video = TestPatternSource(id: s.id, origin: origin, fps: Double(fps))
        case .media(let path):
            let m = MediaFileSource(id: s.id, url: URL(fileURLWithPath: path), mixer: mixer)
            m.loop = s.media?.loop ?? false
            video = m
            mixer.addGenerator(s.id, settings: s.audio ?? AudioSettings(), m.generate)
        case .soundPad:
            let pad = SoundPadSource()
            lock.lock(); soundPads[s.id] = pad; lock.unlock()
            mixer.addGenerator(s.id, settings: s.audio ?? AudioSettings(), pad.generate)
        case .microphone(let dev):
            mixer.addSource(s.id, settings: s.audio ?? AudioSettings())
            mixer.setVoice(s.id, true)
            let ec = s.audio?.echoCancellation == .on || s.audio?.noiseReduction == true
            audio = MicrophoneSource(id: s.id, deviceUID: dev, voiceProcessing: ec, mixer: mixer)
        case .systemAudio:
            mixer.addSource(s.id, settings: s.audio ?? AudioSettings())
            audio = SystemAudioSource(id: s.id, appBundleID: nil, appName: nil, mixer: mixer)
        case .appAudio(let bid, let name):
            mixer.addSource(s.id, settings: s.audio ?? AudioSettings())
            audio = SystemAudioSource(id: s.id, appBundleID: bid, appName: name, mixer: mixer)
        case .tone:
            mixer.addGenerator(s.id, settings: s.audio ?? AudioSettings(), ToneGenerator.make())
        case .guest, .guestScreen, .guestGrid:
            video = EmptySlotSource(id: s.id)   // the guest room swaps in a live slot when it opens
        }
        lock.lock()
        if let video { videoSources[s.id] = video }
        if let audio { audioSources[s.id] = audio }
        if let lut = s.lut, luts[lut.path] == nil { loadLUT(lut.path) }
        lock.unlock()
        video?.start(); audio?.start()
    }

    /// Transport controls of a video or music file source.
    public func media(_ id: UUID) -> MediaFileSource? { lock.lock(); defer { lock.unlock() }; return videoSources[id] as? MediaFileSource }
    public func soundPad(_ id: UUID) -> SoundPadSource? { lock.lock(); defer { lock.unlock() }; return soundPads[id] }

    /// Lets the guest room (or tests) replace what a source shows.
    public func setExternalSource(_ id: UUID, _ source: VideoSource) {
        lock.lock(); let old = videoSources[id]; videoSources[id] = source; lock.unlock()
        old?.stop(); source.start()
    }

    public func state(of id: UUID) -> SourceState? {
        lock.lock(); defer { lock.unlock() }
        return videoSources[id]?.state ?? audioSources[id]?.state
    }
    public func deviceName(of id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = videoSources[id] as? CameraSource { return c.deviceName }
        return audioSources[id]?.deviceName
    }
    public func nativeSize(of id: UUID) -> CGSize? { lock.lock(); defer { lock.unlock() }; return videoSources[id]?.nativeSize }

    // MARK: Program, transitions, overlays

    public func setProgram(_ items: [SceneItem], for canvas: CanvasKind, transition: TransitionKind, durationMs: Int) {
        lock.lock(); defer { lock.unlock() }
        var p = programs[canvas]!
        let now = HostClock.seconds()
        // Start from what is on screen right now, even mid-transition.
        p.previous = p.items
        p.items = items
        p.transition = transition
        p.started = now
        p.duration = transition == .cut ? 0 : Double(durationMs) / 1000
        programs[canvas] = p
    }
    /// Shows a scene in the studio's preview without putting it on air (nil stops the preview render).
    public func setPreviewItems(_ items: [SceneItem]?, for canvas: CanvasKind) {
        lock.lock(); previewItems[canvas] = items; lock.unlock()
    }

    private func previewPool(for kind: CanvasKind, _ size: CGSize) -> CVPixelBufferPool? {
        if let p = previewPools[kind] { return p }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
        previewPools[kind] = p
        return p
    }

    /// Live edits (dragging a layer) update the program without a transition.
    public func updateProgramItems(_ items: [SceneItem], for canvas: CanvasKind) {
        lock.lock(); programs[canvas]!.items = items; lock.unlock()
    }

    public func show(element e: OverlayElement) {
        lock.lock(); elements[e.id] = ElementState(element: e, shownAt: HostClock.seconds(), hidingAt: nil); lock.unlock()
    }
    public func hide(element id: UUID) {
        lock.lock()
        if var s = elements[id], s.hidingAt == nil { s.hidingAt = HostClock.seconds(); elements[id] = s }
        lock.unlock()
    }
    public func updateElement(_ e: OverlayElement) { lock.lock(); if elements[e.id] != nil { elements[e.id]!.element = e }; lock.unlock() }
    public func showChat(_ m: ChatOverlay?) {
        lock.lock()
        if let m { chatOverlay = (m, HostClock.seconds(), nil) }
        else if let c = chatOverlay, c.2 == nil { chatOverlay = (c.0, c.1, HostClock.seconds()) }
        lock.unlock()
    }

    // MARK: Consumers

    public func addConsumer(_ c: CanvasFrameConsumer) { lock.lock(); consumers[ObjectIdentifier(c)] = c; lock.unlock() }
    public func removeConsumer(_ c: CanvasFrameConsumer) { lock.lock(); consumers[ObjectIdentifier(c)] = nil; lock.unlock() }

    // MARK: Rendering

    private func layerInput(_ item: SceneItem, at t: CMTime, canvas: CanvasKind) -> LayerInput? {
        guard let src = videoSources[item.sourceID], let img = src.image(at: t, canvas: canvas) else { return nil }
        let rec = records[item.sourceID]
        var lut: CubeLUT?
        if let l = rec?.lut, l.isEnabled { lut = luts[l.path] }
        var isText = false
        if case .text = rec?.kind { isText = true }
        if case .countdown = rec?.kind { isText = true }
        return LayerInput(image: img, isText: isText, lut: lut, lutAmount: rec?.lut?.amount ?? 1)
    }

    /// Composites one canvas at time `t` (also used for thumbnails and snapshots).
    func composite(_ kind: CanvasKind, at t: CMTime, size: CGSize) -> CIImage {
        let p = programs[kind]!
        let now = CMTimeGetSeconds(t)
        let progress = p.duration > 0 ? (now - p.started) / p.duration : 1
        var img: CIImage
        if progress < 1 && !p.previous.isEmpty {
            img = compositor.transition(p.transition, from: p.previous, to: p.items, progress: progress, canvas: size,
                                        accent: accent) { self.layerInput($0, at: t, canvas: kind) }
        } else {
            img = compositor.compose(items: p.items, canvas: size) { self.layerInput($0, at: t, canvas: kind) }
        }
        // Overlay elements and the on-screen chat card sit above every layout.
        for (id, s) in elements {
            let d = s.element.durationSeconds
            var prog = min(1, (now - s.shownAt) / d)
            if s.element.autoHide > 0 && s.hidingAt == nil && now - s.shownAt > Double(s.element.autoHide) {
                elements[id]?.hidingAt = s.shownAt + Double(s.element.autoHide)
            }
            if let h = elements[id]?.hidingAt {
                prog = min(prog, 1 - (now - h) / d)
                if prog <= 0 { elements[id] = nil; continue }
            }
            if let card = overlays.image(for: s.element, canvasHeight: size.height * (kind == .vertical ? 0.6 : 1)) {
                img = overlays.place(card, position: s.element.position, motion: s.element.motion, progress: prog, canvas: size).composited(over: img)
            }
        }
        if let (m, shown, hiding) = chatOverlay {
            var prog = min(1, (now - shown) / 0.4)
            if let h = hiding { prog = min(prog, 1 - (now - h) / 0.4); if prog <= 0 { chatOverlay = nil } }
            if prog > 0, let card = overlays.chatCard(m, canvasHeight: size.height * (kind == .vertical ? 0.6 : 1)) {
                img = overlays.place(card, position: .topRight, motion: .rise, progress: prog, canvas: size).composited(over: img)
            }
        }
        return img
    }

    private func tick() {
        let tNow = HostClock.now()
        let now = CMTimeGetSeconds(tNow)
        lock.lock()
        // One shared timestamp per tick: both canvases render the same instant, so their files stay in step.
        var due: [(CanvasKind, CanvasConfig)] = []
        for (kind, cfg) in canvases where cfg.isOn {
            let interval = 1 / Double(cfg.fps)
            let next = nextDue[kind] ?? now
            if now + 0.0015 >= next {
                due.append((kind, cfg))
                var n = next + interval
                if now - n > interval { metrics.lateFrames += Int((now - n) / interval); n = now + interval }
                nextDue[kind] = n
            }
        }
        guard !due.isEmpty else { lock.unlock(); return }
        tickCount += 1
        let cons = Array(consumers.values)
        let recs = recorders
        let start = HostClock.seconds()
        var produced: [(CanvasKind, CVPixelBuffer)] = []
        for (kind, cfg) in due {
            guard let pool = pool(for: kind, cfg) else { continue }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { metrics.lateFrames += 1; continue }
            let img = composite(kind, at: tNow, size: cfg.size)
            compositor.render(img, to: pb, canvas: cfg.size)
            metrics.renderedFrames[kind, default: 0] += 1
            produced.append((kind, pb))
        }
        metrics.renderMs = (HostClock.seconds() - start) * 1000
        let previewEvery = self.previewEvery
        let tc = tickCount
        var scenePreviews: [(CanvasKind, CVPixelBuffer)] = []
        if previewEvery > 0 && tc % previewEvery == 0 {
            for (kind, cfg) in due {
                guard let items = previewItems[kind] else { continue }
                let half = CGSize(width: (cfg.size.width / 2).rounded(), height: (cfg.size.height / 2).rounded())
                guard let pool = previewPool(for: kind, half) else { continue }
                var pbOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                guard let pb = pbOut else { continue }
                let img = compositor.compose(items: items, canvas: cfg.size) { self.layerInput($0, at: tNow, canvas: kind) }
                compositor.render(img.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)), to: pb, canvas: half)
                scenePreviews.append((kind, pb))
            }
        }
        lock.unlock()
        for (kind, pb) in scenePreviews { scenePreviewHandler?(kind, pb) }

        for (kind, pb) in produced {
            for r in recs where r.spec.canvas == kind { r.appendVideo(pb, pts: tNow) }
            for c in cons { c.consume(pb, pts: tNow, canvas: kind) }
            if previewEvery > 0 && tc % previewEvery == 0 { previewHandler?(kind, pb) }
        }
    }

    /// A still of a layout for thumbnails ("live" layout cards), rendered off the main thread.
    public func snapshot(items: [SceneItem], canvas kind: CanvasKind, width: CGFloat) -> CGImage? {
        lock.lock()
        let cfg = canvases[kind]!
        let t = HostClock.now()
        let img = compositor.compose(items: items, canvas: cfg.size) { self.layerInput($0, at: t, canvas: kind) }
        lock.unlock()
        return compositor.cgImage(img, canvas: cfg.size, scale: width / cfg.size.width)
    }

    /// A scene rendered with some layers' pictures swapped for the given images (keyed by source ID). The background
    /// picker uses it to show a scene on a background before it's applied; everything else is live.
    public func snapshot(items: [SceneItem], canvas kind: CanvasKind, width: CGFloat, replacing: [UUID: CIImage]) -> CGImage? {
        lock.lock()
        let cfg = canvases[kind]!
        let t = HostClock.now()
        let img = compositor.compose(items: items, canvas: cfg.size) { item in
            if let r = replacing[item.sourceID] { return LayerInput(image: r) }
            return self.layerInput(item, at: t, canvas: kind)
        }
        lock.unlock()
        return compositor.cgImage(img, canvas: cfg.size, scale: width / cfg.size.width)
    }

    /// Picture of a single source (Add Source gallery, Edit panel).
    public func sourceSnapshot(_ id: UUID, maxSide: CGFloat) -> CGImage? {
        lock.lock()
        let img = videoSources[id]?.image(at: HostClock.now())
        lock.unlock()
        guard let img, img.extent.width > 0 else { return nil }
        let k = maxSide / max(img.extent.width, img.extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        return compositor.context.createCGImage(scaled, from: scaled.extent.integral)
    }

    // MARK: Recording

    /// Starts every spec at the same timeline instant (so horizontal and vertical files line up).
    @discardableResult
    public func startRecording(_ specs: [RecordingSpec]) throws -> [CanvasRecorder] {
        var made: [CanvasRecorder] = []
        for s in specs {
            made.append(try CanvasRecorder(spec: s, toIndex: { [mixer] in mixer.timelineIndex(for: $0) }))
        }
        // Opening writers takes a moment; stamp the shared start only once every file is ready.
        lock.lock()
        let start = HostClock.now()
        made.forEach { $0.begin(at: start) }
        recorders.append(contentsOf: made)
        if recorderBridge == nil {
            let b = RecorderAudioBridge(); b.engine = self; recorderBridge = b; mixer.addConsumer(b)
        }
        lock.unlock()
        return made
    }

    public func stopRecording(_ recs: [CanvasRecorder], queue: DispatchQueue = .main, completion: @escaping ([URL]) -> Void) {
        let end = HostClock.now()
        let group = DispatchGroup()
        var files: [URL] = []
        let fl = NSLock()
        for r in recs {
            group.enter()
            r.onFinished = { urls in fl.lock(); files += urls; fl.unlock(); group.leave() }
            r.stop(at: end)
        }
        // Audio runs ~0.12 s behind; if it has stopped flowing, close the files anyway after a grace period.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { recs.forEach { $0.forceFinish() } }
        group.notify(queue: queue) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.recorders.removeAll { r in recs.contains { $0 === r } }; self.lock.unlock()
            completion(files)
        }
    }

    fileprivate func deliverAudio(_ b: AudioBlock) {
        lock.lock(); let recs = recorders; lock.unlock()
        for r in recs { r.appendAudio(b) }
    }

    public func setHeadphoneLevel(_ v: Double) { monitor?.level = Float(v) }

    // MARK: Streaming

    /// Starts one RTMP/RTMPS destination fed from `spec.canvas` and the program mix.
    public func startStream(_ spec: StreamSpec, onStatus: ((StreamStatus) -> Void)? = nil) throws -> StreamOutput {
        let s = try StreamOutput(spec: spec, mixer: mixer)
        s.onStatus = onStatus      // set before start so an immediate failure is reported
        addConsumer(s)
        mixer.addConsumer(s)
        s.start()
        return s
    }
    /// Starts holding the last moments of the canvases for instant clips.
    public func startReplay(_ canvases: [ReplayBuffer.Canvas], seconds: Double = 30) throws -> ReplayBuffer {
        let r = try ReplayBuffer(canvases: canvases, seconds: seconds)
        addConsumer(r); mixer.addConsumer(r)
        return r
    }
    public func stopReplay(_ r: ReplayBuffer) { removeConsumer(r); mixer.removeConsumer(r); r.finish() }

    public func stopStream(_ s: StreamOutput) {
        s.stop()
        removeConsumer(s)
        mixer.removeConsumer(s)
    }
}

final class RecorderAudioBridge: AudioBlockConsumer {
    weak var engine: Engine?
    func consume(_ block: AudioBlock) { engine?.deliverAudio(block) }
}

/// Plays monitored sources to the default output ("Monitor in headphones").
final class MonitorOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var fifo: [Float] = []
    private let lock = NSLock()
    var level: Float = 0.62
    weak var mixer: AudioMixer?

    init(mixer: AudioMixer) { self.mixer = mixer }

    func start() {
        mixer?.monitorTap = { [weak self] samples in
            guard let self else { return }
            self.lock.lock()
            self.fifo.append(contentsOf: samples)
            if self.fifo.count > 48_000 { self.fifo.removeFirst(self.fifo.count - 48_000) }   // cap at 0.5 s
            self.lock.unlock()
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let n = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, abl in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            self.lock.lock()
            let avail = min(frames, self.fifo.count / 2)
            for ch in 0..<min(2, buffers.count) {
                let out = buffers[ch].mData!.assumingMemoryBound(to: Float.self)
                for f in 0..<frames { out[f] = f < avail ? self.fifo[f*2 + ch] * self.level : 0 }
            }
            if avail > 0 { self.fifo.removeFirst(avail * 2) }
            self.lock.unlock()
            return noErr
        }
        node = n
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }
    func stop() { mixer?.monitorTap = nil; engine.stop() }
}
