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
    /// The live editor's screen camera, and the governor that keeps it inside the frame budget.
    public let focus = FocusController()
    public let governor = BudgetGovernor()
    private let stats = TickStats()
    /// Test launches only: makes every tick take at least this long (checks the governor).
    public var testMinTickMs = 0.0
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
    /// Buffers for camera-angle recordings, by size ("1920x1080").
    private var isoPools: [String: CVPixelBufferPool] = [:]

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
    /// Live captions: what's shown and, once turned off, when they started fading out.
    private var captions: (frame: CaptionFrame, hidingAt: Double?, version: Int)?
    private var captionVersion = 0
    private let captionRenderer = CaptionRenderer()
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

    private func isoPool(_ size: CGSize) -> CVPixelBufferPool? {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if let p = isoPools[key] { return p }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
        isoPools[key] = p
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

    /// Screen captures pick up a changed click-ring setting (ScreenSource.showsClicks).
    public func refreshScreenConfigurations() {
        lock.lock(); let screens = videoSources.values.compactMap { $0 as? ScreenSource }; lock.unlock()
        screens.forEach { $0.refreshConfiguration() }
    }

    public func restartSource(_ id: UUID) {
        lock.lock(); let r = records[id]; lock.unlock()
        guard let r else { return }
        stopSource(id); startSource(r, fps: canvas(.horizontal).fps)
    }

    /// What a source shows instead of its device: a picture, silence (an empty picture for a video source), or a
    /// sound source that pushes samples into the mixer like a microphone (a test file).
    public enum StandIn { case video(VideoSource), silent, audio(AudioCaptureSource) }
    /// Asked first whenever a source starts or restarts (`sync`, `restartSource`). A stand-in replaces the device,
    /// which is then never opened (test launches: a clip for each camera, a still for each screen, silence for each
    /// microphone). Set it before `start()`; nil, or a nil answer, starts the real source.
    public var standIn: ((SourceRecord) -> StandIn?)?

    private func startSource(_ s: SourceRecord, fps: Int) {
        let (video, audio) = standIn?(s).map { standInSources($0, for: s) } ?? makeSources(s, fps: fps)
        lock.lock()
        if let video { videoSources[s.id] = video }
        if let audio { audioSources[s.id] = audio }
        if let lut = s.lut, luts[lut.path] == nil { loadLUT(lut.path) }
        lock.unlock()
        video?.start(); audio?.start()
    }

    private func standInSources(_ stand: StandIn, for s: SourceRecord) -> (VideoSource?, AudioCaptureSource?) {
        switch stand {
        case .video(let v): return (v, nil)
        case .silent:
            var audio: AudioCaptureSource?
            if s.kind.hasAudio {
                mixer.addGenerator(s.id, settings: s.audio ?? AudioSettings()) { _, n in [Float](repeating: 0, count: n * 2) }
                if case .microphone = s.kind { mixer.setVoice(s.id, true) }
                audio = SilentAudioSource(id: s.id)
            }
            return (s.kind.hasVideo ? EmptySlotSource(id: s.id) : nil, audio)
        case .audio(let a):
            mixer.addSource(s.id, settings: s.audio ?? AudioSettings())
            if case .microphone = s.kind { mixer.setVoice(s.id, true) }
            return (s.kind.hasVideo ? EmptySlotSource(id: s.id) : nil, a)
        }
    }

    private func makeSources(_ s: SourceRecord, fps: Int) -> (VideoSource?, AudioCaptureSource?) {
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
        return (video, audio)
    }

    /// Transport controls of a video or music file source.
    public func media(_ id: UUID) -> MediaFileSource? { lock.lock(); defer { lock.unlock() }; return videoSources[id] as? MediaFileSource }
    public func soundPad(_ id: UUID) -> SoundPadSource? { lock.lock(); defer { lock.unlock() }; return soundPads[id] }

    /// Lets the guest room (or tests) replace what a source shows.
    public func setExternalSource(_ id: UUID, _ source: VideoSource) {
        lock.lock(); let old = videoSources[id]; videoSources[id] = source; lock.unlock()
        old?.stop(); source.start()
    }

    /// Drops a source the app added with `setExternalSource` that has no record in the collection (a camera angle
    /// from a device that left).
    public func removeExternalSource(_ id: UUID) {
        lock.lock()
        guard records[id] == nil, let old = videoSources.removeValue(forKey: id) else { lock.unlock(); return }
        lock.unlock()
        old.stop()
    }

    /// A crop reports its camera's state.
    public func state(of id: UUID) -> SourceState? {
        lock.lock(); defer { lock.unlock() }
        if let d = videoSources[id] as? DerivedVideoSource { return base(of: d)?.state }
        return videoSources[id]?.state ?? audioSources[id]?.state
    }
    /// The type that draws a source ("CameraSource", or a test stand-in's), for the angles dump.
    public func sourceTypeName(of id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        let s: AnyObject? = videoSources[id] ?? audioSources[id]
        return s.map { String(describing: type(of: $0)) }
    }
    public func deviceName(of id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = videoSources[id] as? CameraSource { return c.deviceName }
        return audioSources[id]?.deviceName
    }
    /// Seconds a Mac camera takes from capture to arrival (nil for other sources). A crop reports its camera's.
    public func captureLag(of id: UUID) -> Double? {
        lock.lock(); defer { lock.unlock() }
        var s = videoSources[id]
        if let d = s as? DerivedVideoSource { s = base(of: d) }
        return (s as? CameraSource)?.captureLag
    }
    public func screenSource(_ id: UUID) -> ScreenSource? { lock.lock(); defer { lock.unlock() }; return videoSources[id] as? ScreenSource }
    public func screenGeometry(of id: UUID) -> ScreenGeometry? { lock.lock(); defer { lock.unlock() }; return (videoSources[id] as? ScreenSource)?.geometry }
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

    /// Live captions on both program canvases, above everything else (nil fades them out). Drawn again only when
    /// the words change.
    public func showCaptions(_ f: CaptionFrame?) {
        lock.lock()
        if let f {
            // The same words again keep the picture already drawn.
            if captions?.frame != f || captions?.hidingAt != nil { captionVersion += 1 }
            captions = (f, nil, captionVersion)
        } else if let c = captions, c.hidingAt == nil { captions = (c.frame, HostClock.seconds(), c.version) }
        lock.unlock()
    }
    /// The caption lines on a canvas in its latest frame (empty when none are readable: off, or mostly faded).
    public func captionLines(_ kind: CanvasKind) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return captionRenderer.shown[kind]?.lines ?? []
    }

    // MARK: Consumers

    public func addConsumer(_ c: CanvasFrameConsumer) { lock.lock(); consumers[ObjectIdentifier(c)] = c; lock.unlock() }
    public func removeConsumer(_ c: CanvasFrameConsumer) { lock.lock(); consumers[ObjectIdentifier(c)] = nil; lock.unlock() }

    // MARK: Rendering

    /// What the program render tells the live editor: hold targets during a transition or just after a switch.
    private struct Framing { var size: CGSize; var hold: Bool; var tier: BudgetTier }

    /// The base a crop is cut from (never another crop). Call with `lock` held.
    private func base(of d: DerivedVideoSource) -> VideoSource? {
        guard let b = videoSources[d.baseID], !(b is DerivedVideoSource) else { return nil }
        return b
    }

    /// A source's picture; a crop is cut from its camera's picture, fetched by ID on every call. `canvas` nil asks
    /// for the source's plain picture (stills). Call with `lock` held.
    private func picture(_ src: VideoSource, at t: CMTime, canvas: CanvasKind?, frame: CGSize?, role: DeriveRole) -> CIImage? {
        func plain(_ s: VideoSource) -> CIImage? {
            if let canvas { return s.image(at: t, canvas: canvas) }
            return s.image(at: t)
        }
        guard let d = src as? DerivedVideoSource else { return plain(src) }
        guard let b = base(of: d), let img = plain(b) else { return nil }
        return d.derive(img, at: t, canvas: canvas ?? .horizontal, frame: frame, role: role)
    }

    private func layerInput(_ item: SceneItem, at t: CMTime, canvas: CanvasKind, framing: Framing? = nil) -> LayerInput? {
        guard let src = videoSources[item.sourceID] else { return nil }
        // A crop is cut to the layer's frame on this canvas; it glides only on the program.
        let frame = src is DerivedVideoSource ? Compositor.frame(of: item.transform, canvas: framing?.size ?? canvases[canvas]?.size ?? .zero).size : nil
        guard let img = picture(src, at: t, canvas: canvas, frame: frame, role: framing == nil ? .preview : .program) else { return nil }
        // A crop keeps its camera's LUT.
        let rec = records[item.sourceID] ?? (src as? DerivedVideoSource).flatMap { records[$0.baseID] }
        var lut: CubeLUT?
        if let l = rec?.lut, l.isEnabled { lut = luts[l.path] }
        var isText = false
        if case .text = rec?.kind { isText = true }
        if case .countdown = rec?.kind { isText = true }
        var input = LayerInput(image: img, isText: isText, lut: lut, lutAmount: rec?.lut?.amount ?? 1)
        // Only the program on air moves; thumbnails, snapshots and the preview before air stay as the scene says.
        if let framing, item.isVisible, let screen = src as? ScreenSource, let geo = screen.geometry {
            let c = item.crop
            let picture = CGSize(width: img.extent.width * max(0.01, 1 - c.left - c.right), height: img.extent.height * max(0.01, 1 - c.top - c.bottom))
            let frame = Compositor.frame(of: item.transform, canvas: framing.size).size
            if picture.width >= 1, picture.height >= 1, frame.width >= 1, frame.height >= 1 {
                let layer = LayerGeometry(image: picture, frame: frame, fit: item.fit, crop: c, mirrored: item.isMirrored)
                input.viewport = focus.viewport(source: item.sourceID, canvas: canvas, screen: geo, layer: layer,
                                                at: CMTimeGetSeconds(t), hold: framing.hold, tier: framing.tier)
            }
        }
        if let framing, item.isVisible, item.shufflesAngles == true, input.viewport == nil {
            input.viewport = angleViewport(item, image: img, canvas: canvas, size: framing.size, at: CMTimeGetSeconds(t))
        }
        return input
    }

    // MARK: Camera angles

    /// Where the presenter's face is in each camera angle the shuffle frame may show (0…1, top-left, in the whole
    /// upright picture). The frame then keeps them framed when the angle's shape differs from the frame's (a portrait
    /// phone in a 16:9 frame, a 16:9 phone in a 9:16 frame). Angles without an entry show centred, as the scene says.
    public func setAngleFaces(_ faces: [UUID: CGPoint]) { angleLock.lock(); angleFaces = faces; angleLock.unlock() }
    private let angleLock = NSLock()
    private var angleFaces: [UUID: CGPoint] = [:]
    private var angleViews: [CanvasKind: (source: UUID, cx: Double, cy: Double, at: Double)] = [:]

    private func angleViewport(_ item: SceneItem, image: CIImage, canvas: CanvasKind, size: CGSize, at now: Double) -> Viewport? {
        angleLock.lock(); defer { angleLock.unlock() }
        guard let face = angleFaces[item.sourceID], item.fit != .stretch else { angleViews[canvas] = nil; return nil }
        let c = item.crop
        let picture = CGSize(width: image.extent.width * max(0.01, 1 - c.left - c.right), height: image.extent.height * max(0.01, 1 - c.top - c.bottom))
        let frame = Compositor.frame(of: item.transform, canvas: size).size
        guard picture.width >= 1, picture.height >= 1, frame.width >= 1, frame.height >= 1 else { return nil }
        let geo = LayerGeometry(image: picture, frame: frame, fit: item.fit, crop: c, mirrored: item.isMirrored)
        guard let p = geo.picturePoint(face) else { return nil }
        // The face's centre about 40% down the frame (a little headroom), never past the picture's edge.
        let target = geo.clamp(CGPoint(x: p.x, y: p.y + 0.1 * geo.visible(zoom: 1).height), zoom: 1)
        if var v = angleViews[canvas], v.source == item.sourceID {
            let k = min(1, max(0, now - v.at) / 0.9)          // follows the presenter over about a second
            v.cx += (target.x - v.cx) * k; v.cy += (target.y - v.cy) * k; v.at = now
            angleViews[canvas] = v
            return Viewport(cx: v.cx, cy: v.cy, zoom: 1)
        }
        angleViews[canvas] = (item.sourceID, target.x, target.y, now)   // a cut lands already framed, no slide
        return Viewport(cx: target.x, cy: target.y, zoom: 1)
    }

    private func inTransition(_ p: Program, at now: Double) -> Bool { p.duration > 0 && now - p.started < p.duration && !p.previous.isEmpty }

    /// Composites one canvas at time `t` (also used for thumbnails and snapshots).
    func composite(_ kind: CanvasKind, at t: CMTime, size: CGSize) -> CIImage {
        let p = programs[kind]!
        let now = CMTimeGetSeconds(t)
        let progress = p.duration > 0 ? (now - p.started) / p.duration : 1
        let framing = Framing(size: size, hold: inTransition(p, at: now) || now - p.started < 1.5, tier: governor.tier)
        var img: CIImage
        if progress < 1 && !p.previous.isEmpty {
            // A medium or close-up moves as its camera: the frame glides into the next layout instead of fading.
            img = compositor.transition(p.transition, from: p.previous, to: p.items, progress: progress, canvas: size, accent: accent,
                                        match: { (self.videoSources[$0.sourceID] as? DerivedVideoSource)?.baseID ?? $0.sourceID })
                                        { self.layerInput($0, at: t, canvas: kind, framing: framing) }
        } else {
            img = compositor.compose(items: p.items, canvas: size) { self.layerInput($0, at: t, canvas: kind, framing: framing) }
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
        // Live captions over everything, so they're seen on air and in recordings.
        if let c = captions {
            var alpha = CaptionFade.alpha(now: now, lastChange: c.frame.lastChange)
            if let h = c.hidingAt { alpha = min(alpha, 1 - (now - h) / 0.3) }
            if alpha > 0.001, let bar = captionRenderer.image(c.frame, version: c.version, kind: kind, size: size, now: now) {
                img = (alpha < 0.999 ? bar.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))]) : bar)
                    .composited(over: img)
            }
            captionRenderer.noteShown(kind, alpha: max(0, alpha))
            if c.hidingAt != nil, alpha <= 0 { captions = nil; captionRenderer.reset() }
        }
        return img
    }

    private func tick() {
        let tNow = HostClock.now()
        let now = CMTimeGetSeconds(tNow)
        lock.lock()
        let lockedAt = HostClock.seconds()
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
        let moving = due.contains { inTransition(programs[$0.0]!, at: now) }
        metrics.thermalSerious = governor.current.thermal == "serious" || governor.current.thermal == "critical"
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
        // Camera-angle recordings: each draws its source alone (fitted, on black) at the 16:9 canvas's cadence.
        var isoFrames: [(CanvasRecorder, CVPixelBuffer)] = []
        if due.contains(where: { $0.0 == .horizontal }) {
            for r in recs {
                guard let sid = r.spec.isoSource else { continue }
                let size = CGSize(width: r.spec.width, height: r.spec.height)
                guard let pool = isoPool(size) else { continue }
                var pbOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                guard let pb = pbOut else { continue }
                var img = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
                if let src = videoSources[sid], let pic = picture(src, at: tNow, canvas: .horizontal, frame: size, role: .iso),
                   pic.extent.width >= 1, pic.extent.height >= 1 {
                    let s = min(size.width / pic.extent.width, size.height / pic.extent.height)
                    let w = pic.extent.width * s, h = pic.extent.height * s
                    let placed = pic.transformed(by: CGAffineTransform(translationX: -pic.extent.minX, y: -pic.extent.minY))
                        .transformed(by: CGAffineTransform(scaleX: s, y: s))
                        .transformed(by: CGAffineTransform(translationX: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded()))
                    img = placed.composited(over: img)
                }
                compositor.render(img, to: pb, canvas: size)
                isoFrames.append((r, pb))
            }
        }
        metrics.renderMs = (HostClock.seconds() - start) * 1000
        let renderMs = metrics.renderMs
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
        if testMinTickMs > 0 { let until = lockedAt + testMinTickMs / 1000; while HostClock.seconds() < until { usleep(200) } }
        let fps = canvases[.horizontal]?.fps ?? 30
        lock.unlock()
        let lockMs = (HostClock.seconds() - lockedAt) * 1000
        for (kind, pb) in scenePreviews { scenePreviewHandler?(kind, pb) }

        for (r, pb) in isoFrames { r.appendVideo(pb, pts: tNow) }
        for (kind, pb) in produced {
            for r in recs where r.spec.canvas == kind && r.spec.isoSource == nil { r.appendVideo(pb, pts: tNow) }
            for c in cons { c.consume(pb, pts: tNow, canvas: kind) }
            if previewEvery > 0 && tc % previewEvery == 0 { previewHandler?(kind, pb) }
        }
        // The whole tick, from taking the lock until every output has its frame.
        let tickMs = (HostClock.seconds() - lockedAt) * 1000
        stats.add(TickStats.Sample(t: now, tick: tickMs, lock: lockMs, render: renderMs, transition: moving))
        governor.evaluate(now: now, fps: fps, stats: stats, missedTotal: recs.reduce(0) { $0 + $1.missedFrames })
        focus.traceTick(["t": now, "tick": tickMs, "lock": lockMs, "render": renderMs, "transition": moving, "tier": governor.tier.rawValue])
    }

    /// Tick times over the last `seconds` (the HUD, the governor and the Gate 0 benchmark read this).
    public func tickSummary(seconds: Double) -> TickSummary { stats.summary(since: HostClock.seconds() - seconds) }
    public func resetTickStats() { stats.reset() }
    /// Frames cameras had to drop, and frame slots recordings missed, since launch.
    public var captureDrops: Int { lock.lock(); defer { lock.unlock() }; return videoSources.values.compactMap { $0 as? CameraSource }.reduce(0) { $0 + $1.droppedFrames } }
    public var missedRecordingFrames: Int { lock.lock(); defer { lock.unlock() }; return recorders.reduce(0) { $0 + $1.missedFrames } }

    /// A still of a layout for thumbnails ("live" layout cards), rendered off the main thread.
    /// The program as it goes out, with the live editor's and the camera angles' framing (tests).
    public func programSnapshot(_ kind: CanvasKind, width: CGFloat) -> CGImage? {
        lock.lock()
        let cfg = canvases[kind]!
        let img = composite(kind, at: HostClock.now(), size: cfg.size)
        lock.unlock()
        return compositor.cgImage(img, canvas: cfg.size, scale: width / cfg.size.width)
    }

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
        let t = HostClock.now()
        let img = videoSources[id].flatMap { picture($0, at: t, canvas: nil, frame: nil, role: .preview) }
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
        governor.relearn()
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
            self.governor.relearn()
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
        governor.relearn()
        return s
    }
    /// Starts holding the last moments of the canvases for instant clips.
    public func startReplay(_ canvases: [ReplayBuffer.Canvas], seconds: Double = 30) throws -> ReplayBuffer {
        let r = try ReplayBuffer(canvases: canvases, seconds: seconds)
        addConsumer(r); mixer.addConsumer(r)
        governor.relearn()
        return r
    }
    public func stopReplay(_ r: ReplayBuffer) { removeConsumer(r); mixer.removeConsumer(r); r.finish(); governor.relearn() }

    public func stopStream(_ s: StreamOutput) {
        s.stop()
        removeConsumer(s)
        mixer.removeConsumer(s)
        governor.relearn()
    }
}

final class RecorderAudioBridge: AudioBlockConsumer {
    weak var engine: Engine?
    func consume(_ block: AudioBlock) { engine?.deliverAudio(block) }
}

/// A microphone or system-audio stand-in: running, and silent (the mixer gets a generator of zeros).
final class SilentAudioSource: AudioCaptureSource {
    let id: UUID
    let state: SourceState = .running
    let deviceName = "Stand-in (silent)"
    init(id: UUID) { self.id = id }
    func start() {}
    func stop() {}
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
