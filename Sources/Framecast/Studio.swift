import Foundation
import SwiftUI
import Observation
import AVFoundation
import IOKit.pwr_mgt
import FramecastEngine

enum StudioRail: String, CaseIterable, Identifiable {
    case chat, backstage, guests, audio, elements, edit, rundown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "Comments"
        case .backstage: "Green room"
        case .guests: "Guests"
        case .audio: "Mixer"
        case .elements: "Overlays"
        case .edit: "Layer"
        case .rundown: "Rundown"
        }
    }
    var icon: String {
        switch self {
        case .chat: "bubble.left"
        case .backstage: "bubble.left.and.text.bubble.right"
        case .guests: "person.2"
        case .audio: "waveform"
        case .elements: "square.on.square"
        case .edit: "square.3.layers.3d"
        case .rundown: "list.bullet.rectangle"
        }
    }
}

enum AppTab: String { case studio, destinations }

struct AlertItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var isWarning = true
    var time = Date()
}

struct SessionSummary: Identifiable {
    let id = UUID()
    var title: String
    var started: Date
    var ended: Date
    var recordings: [URL]
    var streams: [StreamReport]
    var droppedFrames: Int
    /// YouTube-style chapter list from scene changes and markers (empty when there were none).
    var chapters = ""
    var clips: [URL] = []
    struct StreamReport: Codable { var name: String; var canvas: String; var uptime: String; var bitrate: String; var dropped: Int; var reconnects: Int }
}

/// The studio: scenes, program state, recording and everything the UI binds to.
@Observable
final class Studio {
    let settings: AppSettings
    let engine = Engine()
    var collection: SceneCollection { didSet { scheduleSave(); noteUndoableChange(from: oldValue) } }
    var tab: AppTab = .studio
    var rail: StudioRail = .chat
    var editingCanvas: CanvasKind = .horizontal
    var selectedItemID: UUID?
    var isAddingSource = false
    /// Layer edits also go to the same source's layer in every other scene. Off by default, every launch.
    var editsAllScenes = false
    var showsPreflight = false
    @ObservationIgnored lazy var preflight = Preflight(studio: self)
    /// The show's rundown and the director that follows it (see ShowDirector.swift).
    @ObservationIgnored lazy var director = ShowDirector(studio: self)
    @ObservationIgnored lazy var controlLink = ControlLink(studio: self)
    /// Test hooks (screenshot tours): which Add Source category / Settings pane to show, and a dismiss signal.
    /// Open background picker and what it changes.
    var backgroundTarget: BackgroundTarget?
    var testAddSourceCategory: String?
    var testBackgroundPicker: (command: String, serial: Int)?
    var testAddSheetPick: (id: String, serial: Int)?
    var testSettingsPane: String?
    var testDismiss = 0
    var testOpenSettings = 0
    var testOpenPrompter = 0
    var isEditingFilters = false
    var alerts: [AlertItem] = []
    var notice: String?
    var sessionName = ""

    // Recording
    var isRecording = false
    var recordingStarted: Date?
    var recordingPausedAt: Date?
    private(set) var recorders: [CanvasRecorder] = []
    var recordingCanvases: [CanvasKind] = []
    var lastRecordings: [URL] = []
    var summary: SessionSummary?
    var sessionStart: Date?

    // Live readings (refreshed ~15×/s)
    var levels: [UUID: AudioLevel] = [:]
    var masterLevel = AudioLevel.silent
    var sourceStates: [UUID: SourceState] = [:]
    var thumbnails: [UUID: CGImage] = [:]
    var elementsOn: [UUID: Date] = [:]
    var chatOnScreen: UUID?
    var droppedFrames = 0
    var freeBytes: Int64 = 0

    // Undo (see Undo.swift)
    var undoSteps: [UndoStep] = []
    var redoSteps: [UndoStep] = []
    /// A short note over the canvases after undo or redo ("Undo: Move layer").
    var flash: String?
    @ObservationIgnored var undoPending: (before: SceneCollection, work: DispatchWorkItem)?
    @ObservationIgnored var isRestoringUndo = false
    @ObservationIgnored var flashWork: DispatchWorkItem?

    /// Preview before air: the scene being set up, and what the engine has on air per canvas.
    var previewSceneID: UUID?
    @ObservationIgnored let scenePreview = PreviewHub()
    @ObservationIgnored var airItems: [CanvasKind: [SceneItem]] = [:]
    /// Video files on air (they play while shown and pause when their scene leaves the air).
    @ObservationIgnored var mediaOnAir: Set<UUID> = []
    var mediaStatus: [UUID: MediaFileSource.Status] = [:]
    /// Scene changes and markers during this show (for chapters), clips saved, and the instant-clip buffer.
    var showEvents: [ShowEvent] = []
    var savedClips: [URL] = []
    var replayHeld: Double = 0
    @ObservationIgnored var replay: ReplayBuffer?
    var duckLevel: Float = 1

    @ObservationIgnored let preview = PreviewHub()
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastSpaceCheck = Date.distantPast
    @ObservationIgnored private var thumbTimer: Timer?
    @ObservationIgnored private let thumbQueue = DispatchQueue(label: "framecast.thumbs", qos: .utility)
    @ObservationIgnored private var sleepAssertion: IOPMAssertionID = 0
    @ObservationIgnored var streaming: StreamingController!
    @ObservationIgnored var guests: GuestRoom!
    @ObservationIgnored var chat: ChatHub!

    init(settings: AppSettings) {
        self.settings = settings
        let loaded = CollectionStore.load()
        collection = loaded.collection
        if let n = loaded.notice { alerts.append(AlertItem(title: "Scenes restored from a backup", detail: n)) }
        editingCanvas = settings.s.stage == .vertical ? .vertical : .horizontal
        streaming = StreamingController(studio: self)
        guests = GuestRoom(studio: self)
        chat = ChatHub(studio: self)
    }

    func start() {
        ScreenSource.showsOwnWindows = settings.s.showsOwnWindows ?? false
        applyCanvases()
        engine.accent = RGBA(0.31, 0.82, 0.77)
        engine.previewHandler = { [preview] kind, pb in preview.push(kind, pb) }
        engine.scenePreviewHandler = { [scenePreview] kind, pb in scenePreview.push(kind, pb) }
        engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps)
        for c in CanvasKind.allCases { pushProgram(c, transition: .cut) }
        pushPreviewItems()
        engine.start()
        engine.setHeadphoneLevel(collection.audio.headphoneLevel)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.poll() }
        thumbTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshThumbnails() }
        refreshThumbnails()
    }

    func shutdown() {
        pollTimer?.invalidate(); thumbTimer?.invalidate()
        director.close()
        controlLink.stop()
        guests.close()
        CollectionStore.save(collection)
        engine.stop()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in if let c = self?.collection { CollectionStore.save(c) } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // MARK: Canvases

    var isVerticalOn: Bool { settings.s.isVerticalOn }
    var stage: StageCanvases {
        get { settings.s.isVerticalOn ? settings.s.stage : .horizontal }
        set {
            settings.s.stage = newValue
            if newValue != .both { editingCanvas = newValue == .vertical ? .vertical : .horizontal }
        }
    }

    func applyCanvases() {
        let h = settings.s.horizontal, v = settings.s.vertical
        engine.setCanvas(.horizontal, CanvasConfig(width: h.width, height: h.height, fps: h.fps))
        engine.setCanvas(.vertical, CanvasConfig(width: v.width, height: v.height, fps: v.fps, isOn: settings.s.isVerticalOn))
        engine.previewEvery = settings.s.previewQuality == .full ? 1 : (settings.s.previewQuality == .half ? 2 : 0)
    }

    func setVertical(_ on: Bool) {
        if !on && isRecording && recordingCanvases.contains(.vertical) {
            notice = "Stop recording to turn off the vertical canvas."; return
        }
        settings.s.isVerticalOn = on
        if !on { stage = .horizontal } else if settings.s.stage == .horizontal { stage = .both }
        applyCanvases()
    }

    // MARK: Scenes

    var scenes: [StudioScene] { collection.scenes }
    func programID(_ c: CanvasKind) -> UUID? {
        c == .horizontal ? collection.pointers.horizontalProgram : collection.pointers.verticalProgram
    }
    func programScene(_ c: CanvasKind) -> StudioScene? { scenes.first { $0.id == programID(c) } ?? scenes.first }
    /// The scene edits apply to: the preview scene in preview mode, otherwise the one on air.
    var editingScene: StudioScene? { previewMode ? previewScene : programScene(editingCanvas) }
    func editScene(_ c: CanvasKind) -> StudioScene? { previewMode ? previewScene : programScene(c) }

    // MARK: Preview before air

    var previewMode: Bool { settings.s.previewBeforeAir ?? false }
    var previewScene: StudioScene? { scenes.first { $0.id == previewSceneID } ?? programScene(editingCanvas) }

    func setPreviewMode(_ on: Bool) {
        guard on != previewMode else { return }
        if on {
            settings.s.previewBeforeAir = true
            previewSceneID = programScene(editingCanvas)?.id
        } else {
            // Edits still waiting in the preview go on air with the transition.
            let waiting = CanvasKind.allCases.filter(hasUnairedChanges)
            settings.s.previewBeforeAir = false
            previewSceneID = nil
            for c in waiting { pushProgram(c, transition: settings.s.transition) }
        }
        selectedItemID = nil
        pushPreviewItems()
    }

    /// Clicking a scene: into the preview in preview mode, otherwise straight on air.
    func show(_ id: UUID) {
        if previewMode { previewSceneID = id; selectedItemID = nil; pushPreviewItems() } else { switchTo(id) }
    }

    /// Puts the preview scene (with any edits) on air using the transition.
    func takePreview() {
        guard previewMode, let p = previewScene else { return }
        switchTo(p.id)
    }

    /// The on-air scene has edits the engine isn't showing yet.
    func hasUnairedChanges(_ c: CanvasKind) -> Bool {
        guard previewMode, let s = programScene(c) else { return false }
        return resolvedItems(s.items(for: c)) != airItems[c]
    }

    func pushPreviewItems() {
        for c in CanvasKind.allCases { engine.setPreviewItems(previewMode ? previewScene?.items(for: c) : nil, for: c) }
    }

    /// Switches the layout. With both canvases shown, it acts on the canvas being edited, unless `everyCanvas`
    /// (the show director switches both).
    func switchTo(_ id: UUID, everyCanvas: Bool = false) {
        let targets: [CanvasKind] = stage == .both && !everyCanvas ? [editingCanvas] : CanvasKind.allCases
        for c in targets {
            if c == .horizontal { collection.pointers.horizontalProgram = id } else { collection.pointers.verticalProgram = id }
            pushProgram(c, transition: settings.s.transition)
        }
        selectedItemID = nil
        if let s = scenes.first(where: { $0.id == id }) { noteEvent(s.name, marker: false) }
        director.noteSwitch(to: id)
    }

    func pushProgram(_ c: CanvasKind, transition: TransitionKind) {
        guard let s = programScene(c) else { return }
        let items = resolvedItems(s.items(for: c))
        airItems[c] = items
        engine.setProgram(items, for: c, transition: transition, durationMs: settings.s.transitionMs)
        updateMediaOnAir()
    }

    /// Starts video files that just went on air (from the top, unless set otherwise) and pauses those that left.
    func updateMediaOnAir() {
        var onAir: Set<UUID> = []
        for c in CanvasKind.allCases where c == .horizontal || isVerticalOn {
            for it in (airItems[c] ?? []) where it.isVisible {
                if case .media(let p)? = source(it.sourceID)?.kind, !MediaFileSource.isAudioOnly(p) { onAir.insert(it.sourceID) }
            }
        }
        for id in onAir.subtracting(mediaOnAir) {
            if source(id)?.media?.playsWhenShown ?? true { engine.media(id)?.restart() } else { engine.media(id)?.play() }
        }
        for id in mediaOnAir.subtracting(onAir) { engine.media(id)?.pause() }
        mediaOnAir = onAir
    }
    /// Live edits refresh the program without a transition. In preview mode they refresh the preview only and
    /// reach the air when the preview is put on air.
    func refreshProgram() {
        if previewMode { pushPreviewItems(); return }
        for c in CanvasKind.allCases {
            guard let s = programScene(c) else { continue }
            let items = resolvedItems(s.items(for: c))
            airItems[c] = items
            engine.updateProgramItems(items, for: c)
        }
        updateMediaOnAir()
    }
    /// The live brain's asset slot shows the asset it put on air (Looks.swift).
    private func resolvedItems(_ items: [SceneItem]) -> [SceneItem] {
        guard let slot = director.assetSlotID, let asset = director.assetSourceID else { return items }
        return items.map { var x = $0; if x.sourceID == slot { x.sourceID = asset }; return x }
    }

    func sceneIndex(_ id: UUID) -> Int? { collection.scenes.firstIndex { $0.id == id } }

    func addLayout(from template: StudioLayoutTemplate?) {
        let roles = defaultRoles()
        var scene: StudioScene
        if let template { scene = LayoutTemplates.make(template, roles: roles) }
        else {
            let bg = roles.background
            scene = StudioScene(name: "New scene", horizontal: [SceneItem(sourceID: bg, role: .background)], vertical: [SceneItem(sourceID: bg, role: .background)])
        }
        var n = scene.name; var k = 2
        while scenes.contains(where: { $0.name == n }) { n = "\(scene.name) \(k)"; k += 1 }
        scene.name = n; scene.verticalName = n
        collection.scenes.append(scene)
        show(scene.id)
    }

    func defaultRoles() -> LayoutTemplates.Roles {
        func first(_ match: (SourceKind) -> Bool) -> UUID? { collection.sources.first { match($0.kind) }?.id }
        let bg = first { if case .wallpaper = $0 { return true }; if case .color = $0 { return true }; return false } ?? ensureSource(.wallpaper("dusk-grid"), "Background")
        let cam = first { if case .camera = $0 { return true }; return false } ?? ensureSource(.camera(deviceID: "", width: 1920, height: 1080, fps: 30), "Camera")
        let scr = first { if case .display = $0 { return true }; return false } ?? ensureSource(.display(displayID: 0), "Screen")
        let lower = collection.sources.first { $0.name == "Lower third" }?.id
            ?? ensureSource(.text(TextStyle(text: "Your name", fontSize: 44, color: RGBA(0.06, 0.08, 0.09), background: RGBA(0.30, 0.82, 0.77))), "Lower third")
        return LayoutTemplates.Roles(background: bg, camera: cam, screen: scr, lowerThird: lower)
    }

    @discardableResult
    func ensureSource(_ kind: SourceKind, _ name: String) -> UUID {
        let r = SourceRecord(name: name, kind: kind)
        collection.sources.append(r)
        engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps)
        return r.id
    }

    func renameLayout(_ id: UUID, _ name: String, canvas: CanvasKind? = nil) {
        guard let i = sceneIndex(id), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if canvas == .vertical { collection.scenes[i].verticalName = name }
        else { collection.scenes[i].name = name; if canvas == nil { collection.scenes[i].verticalName = name } }
    }
    func duplicateLayout(_ id: UUID) {
        guard let i = sceneIndex(id) else { return }
        var s = collection.scenes[i]
        s.id = UUID(); s.name += " copy"; s.verticalName += " copy"
        s.horizontal = s.horizontal.map { var x = $0; x.id = UUID(); return x }
        s.vertical = s.vertical.map { var x = $0; x.id = UUID(); return x }
        collection.scenes.insert(s, at: i + 1)
    }
    func deleteLayout(_ id: UUID) {
        guard scenes.count > 1, let i = sceneIndex(id) else { return }
        if previewSceneID == id { previewSceneID = nil }
        let wasProgram = CanvasKind.allCases.filter { programID($0) == id }
        collection.scenes.remove(at: i)
        for c in wasProgram {
            let next = collection.scenes[min(i, collection.scenes.count - 1)].id
            if c == .horizontal { collection.pointers.horizontalProgram = next } else { collection.pointers.verticalProgram = next }
            pushProgram(c, transition: .cut)
        }
        pushPreviewItems()
    }
    func resetLayout(_ id: UUID) {
        guard let i = sceneIndex(id), let t = collection.scenes[i].template else { return }
        var fresh = LayoutTemplates.make(t, roles: defaultRoles())
        fresh.id = id; fresh.name = collection.scenes[i].name; fresh.verticalName = collection.scenes[i].verticalName
        collection.scenes[i] = fresh
        refreshProgram()
    }
    func moveLayout(from: Int, to: Int) {
        guard from != to, scenes.indices.contains(from) else { return }
        let s = collection.scenes.remove(at: from)
        collection.scenes.insert(s, at: min(to, collection.scenes.count))
    }

    // MARK: Layers

    var editingItems: [SceneItem] { editingScene?.items(for: editingCanvas) ?? [] }
    var selectedItem: SceneItem? { editingItems.first { $0.id == selectedItemID } }
    func source(_ id: UUID) -> SourceRecord? { collection.source(id) }

    /// Edits one layer of the scene being edited, on the canvas being edited. Only that scene changes, unless
    /// "Update in all scenes" is on: then a change to the layer's look (shape, fit, opacity, filters, mirroring,
    /// input) is copied to the same source's layer in every other scene on that canvas. Position, size and crop
    /// always stay per scene, since each layout places the layer differently.
    func updateItem(_ id: UUID, live: Bool = true, _ change: (inout SceneItem) -> Void) {
        guard let scene = editingScene, let si = sceneIndex(scene.id) else { return }
        var items = scene.items(for: editingCanvas)
        guard let ii = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[ii]
        change(&items[ii])
        let after = items[ii]
        collection.scenes[si].setItems(items, for: editingCanvas)
        if editsAllScenes && before.role != .background && before != after {
            for sj in collection.scenes.indices where sj != si {
                var list = collection.scenes[sj].items(for: editingCanvas)
                var changed = false
                var lookChanged = before; lookChanged.transform = after.transform; lookChanged.crop = after.crop
                guard lookChanged != after else { continue }        // only moved or cropped: nothing to copy
                for k in list.indices where list[k].sourceID == before.sourceID && list[k].role != .background {
                    if before.fit != after.fit { list[k].fit = after.fit }
                    if before.mask != after.mask { list[k].mask = after.mask }
                    if before.opacity != after.opacity { list[k].opacity = after.opacity }
                    if before.filters != after.filters { list[k].filters = after.filters }
                    if before.isMirrored != after.isMirrored { list[k].isMirrored = after.isMirrored }
                    if before.sourceID != after.sourceID { list[k].sourceID = after.sourceID }
                    changed = true
                }
                if changed { collection.scenes[sj].setItems(list, for: editingCanvas) }
            }
        }
        refreshProgram()
    }

    /// Other scenes that show the same source as a layer (what "Update in all scenes" would also change).
    func otherScenes(showing sourceID: UUID) -> Int {
        guard let current = editingScene?.id else { return 0 }
        return collection.scenes.filter { $0.id != current && $0.items(for: editingCanvas).contains { $0.sourceID == sourceID } }.count
    }

    func reorder(_ id: UUID, up: Bool) {
        guard let scene = editingScene, let si = sceneIndex(scene.id) else { return }
        var items = scene.items(for: editingCanvas)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = up ? i + 1 : i - 1
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
        collection.scenes[si].setItems(items, for: editingCanvas)
        refreshProgram()
    }

    func removeFromLayout(_ id: UUID) {
        guard let scene = editingScene, let si = sceneIndex(scene.id) else { return }
        var items = scene.items(for: editingCanvas)
        items.removeAll { $0.id == id }
        collection.scenes[si].setItems(items, for: editingCanvas)
        if selectedItemID == id { selectedItemID = nil }
        refreshProgram()
    }

    func removeFromStudio(_ sourceID: UUID) {
        collection.sources.removeAll { $0.id == sourceID }
        for i in collection.scenes.indices {
            collection.scenes[i].horizontal.removeAll { $0.sourceID == sourceID }
            collection.scenes[i].vertical.removeAll { $0.sourceID == sourceID }
        }
        engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps)
        refreshProgram()
    }

    /// Adds a source to the studio and, for pictures, as a new layer on top of the current layout.
    func addSource(_ record: SourceRecord, toLayout: Bool = true) {
        var rec = record
        if let existing = collection.sources.first(where: { $0.kind == record.kind && record.kind.hasVideo }) { rec = existing }
        else { collection.sources.append(rec); engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps) }
        guard toLayout, rec.kind.hasVideo, let scene = editingScene, let si = sceneIndex(scene.id) else { return }
        var replaced: Set<UUID> = []
        for c in (stage == .both ? [editingCanvas] : CanvasKind.allCases) {
            var items = scene.items(for: c)
            let t: ItemTransform
            switch rec.kind {
            case .text: t = ItemTransform(x: 0.05, y: 0.82, width: 0.5, height: 0.08)
            case .color, .wallpaper, .media: t = .full
            case .packImage(let a): t = AssetPack.find(a).map { Studio.annotationRect($0.asset, canvas: c) } ?? .full
            default: t = c == .horizontal ? ItemTransform(x: 0.25, y: 0.25, width: 0.5, height: 0.5) : ItemTransform(x: 0.1, y: 0.3, width: 0.8, height: 0.4)
            }
            var item = SceneItem(sourceID: rec.id, transform: t, fit: rec.kind.isFillByDefault ? .fill : .fit)
            if case .color = rec.kind { items.insert(item, at: 0) }
            else if case .wallpaper = rec.kind, let b = items.firstIndex(where: { $0.role == .background }) {
                // A new wallpaper replaces the layout's background rather than hiding underneath it.
                if items[b].sourceID != rec.id { replaced.insert(items[b].sourceID) }
                items[b].sourceID = rec.id; item = items[b]
            }
            else if case .wallpaper = rec.kind { item.role = .background; items.insert(item, at: 0) }
            else { item.role = rec.kind.defaultRole; items.append(item) }
            collection.scenes[si].setItems(items, for: c)
            if c == editingCanvas { selectedItemID = item.id }
        }
        refreshProgram()
        dropUnusedPackBackgrounds(replaced)
    }

    /// Puts a background on the editing scene, on both canvases (each shows its own 16:9 or 9:16 version).
    func setSceneBackground(_ kind: SourceKind, name: String) {
        guard let scene = editingScene, let si = sceneIndex(scene.id) else { return }
        var rec = SourceRecord(name: name, kind: kind)
        if let existing = collection.sources.first(where: { $0.kind == kind }) { rec = existing }
        else { collection.sources.append(rec); engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps) }
        var replaced: Set<UUID> = []
        for c in CanvasKind.allCases {
            var items = scene.items(for: c)
            if let b = items.firstIndex(where: { $0.role == .background }) {
                if items[b].sourceID != rec.id { replaced.insert(items[b].sourceID) }
                items[b].sourceID = rec.id
            } else {
                items.insert(SceneItem(sourceID: rec.id, role: .background, transform: .full, fit: .fill), at: 0)
            }
            collection.scenes[si].setItems(items, for: c)
        }
        refreshProgram()
        dropUnusedPackBackgrounds(replaced)
    }

    /// Changes a background everywhere it appears. Its name follows along unless someone named it themselves.
    func changeBackground(_ sourceID: UUID, to choice: BackgroundChoice) {
        guard let src = source(sourceID) else { return }
        let autoNamed: Bool
        if case .wallpaper(let old) = src.kind { autoNamed = BackgroundCatalog.choice(old)?.name == src.name } else { autoNamed = false }
        updateSource(sourceID) { $0.kind = .wallpaper(choice.id); if autoNamed { $0.name = choice.name } }
        engine.restartSource(sourceID)
    }

    /// How many scenes show a source (on either canvas).
    func sceneCount(using sourceID: UUID) -> Int {
        collection.scenes.filter { s in (s.horizontal + s.vertical).contains { $0.sourceID == sourceID } }.count
    }

    /// A pack background that no layout uses any more is dropped, so its 4K artwork doesn't stay in memory.
    func dropUnusedPackBackgrounds(_ ids: Set<UUID>) {
        for id in ids {
            guard case .wallpaper(let w)? = collection.source(id)?.kind, w.hasPrefix("pack:"), sceneCount(using: id) == 0 else { continue }
            removeFromStudio(id)
        }
    }

    /// The background layer of the editing scene, if any.
    var editingBackground: SceneItem? { editingItems.first { $0.role == .background } }

    /// Opens the background picker for the editing scene's background: changes that background in place when it's
    /// a picture, otherwise puts a new one on the scene.
    func chooseBackground() {
        if let bg = editingBackground, case .wallpaper? = source(bg.sourceID)?.kind { backgroundTarget = .source(bg.sourceID) }
        else { backgroundTarget = .scene }
    }

    /// Restarts a countdown layer so it ends `minutes` from now.
    func restartCountdown(_ id: UUID, style: TextStyle, minutes: Int) {
        updateSource(id) { $0.kind = .countdown(style, endsAt: Date().timeIntervalSince1970 + Double(minutes * 60)) }
        engine.restartSource(id)
    }

    func updateSource(_ id: UUID, _ change: (inout SourceRecord) -> Void) {
        guard let i = collection.sources.firstIndex(where: { $0.id == id }) else { return }
        change(&collection.sources[i])
        engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps)
        if case .text = collection.sources[i].kind { engine.restartSource(id) }
    }

    // MARK: Audio

    var audioSources: [SourceRecord] { collection.sources.filter { $0.kind.hasAudio } }
    func setAudio(_ id: UUID, _ change: (inout AudioSettings) -> Void) {
        guard let i = collection.sources.firstIndex(where: { $0.id == id }) else { return }
        var a = collection.sources[i].audio ?? AudioSettings()
        let oldVP = a.echoCancellation == .on || a.noiseReduction == true
        change(&a)
        collection.sources[i].audio = a
        engine.mixer.update(id, settings: a)
        let newVP = a.echoCancellation == .on || a.noiseReduction == true
        if oldVP != newVP { engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps); engine.restartSource(id) }
    }
    var allMuted: Bool { audioSources.filter { if case .microphone = $0.kind { return true }; return false }.allSatisfy { $0.audio?.isMuted ?? false } }
    func toggleMuteMics() {
        let mute = !allMuted
        for s in audioSources { if case .microphone = s.kind { setAudio(s.id) { $0.isMuted = mute } } }
    }
    func setHeadphoneLevel(_ v: Double) { collection.audio.headphoneLevel = v; engine.setHeadphoneLevel(v) }
    func setMaster(_ v: Double) { collection.audio.masterFader = v; engine.mixer.masterGain = Float(pow(v / 0.8, 3)) }

    // MARK: Video and music files, sound pad

    /// Adds a video (as a full-canvas layer) or a music file (to the mix only).
    func addMediaFile(_ url: URL) {
        var rec = SourceRecord(name: url.deletingPathExtension().lastPathComponent, kind: .media(path: url.path))
        rec.media = MediaOptions()
        if MediaFileSource.isAudioOnly(url.path) {
            rec.audio?.ducksUnderVoice = true          // music sits under your voice by default
            rec.media?.loop = true
            addSource(rec, toLayout: false)
            rail = .audio
        } else {
            addSource(rec)
        }
    }

    func setMediaOptions(_ id: UUID, _ change: (inout MediaOptions) -> Void) {
        updateSource(id) { s in var o = s.media ?? MediaOptions(); change(&o); s.media = o }
    }

    var padSlots: [SoundSlot] { collection.soundPad ?? SoundSlot.defaults }
    func setPadSlot(_ i: Int, _ slot: SoundSlot) {
        var p = padSlots; guard p.indices.contains(i) else { return }
        p[i] = slot; collection.soundPad = p
    }

    /// Plays sound pad button `i` (0-based) into the mix through the "Sound pad" channel.
    func playPad(_ i: Int) {
        guard padSlots.indices.contains(i), !padSlots[i].isEmpty else { return }
        let key = padSlots[i].key
        let id = collection.sources.first { $0.kind == .soundPad }?.id ?? {
            var r = SourceRecord(name: "Sound pad", kind: .soundPad); r.audio?.fader = 0.7
            collection.sources.append(r)
            engine.sync(sources: collection.sources, fpsHint: settings.s.horizontal.fps)
            return r.id
        }()
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            let samples = SoundBank.samples(for: key)
            engine.soundPad(id)?.trigger(samples)
        }
    }

    // MARK: Elements and chat on screen

    func toggleElement(_ e: OverlayElement) {
        if elementsOn[e.id] != nil { engine.hide(element: e.id); elementsOn[e.id] = nil }
        else { engine.show(element: e); elementsOn[e.id] = Date() }
    }
    func toggleElement(number n: Int) {
        guard collection.elements.indices.contains(n - 1) else { return }
        toggleElement(collection.elements[n - 1])
    }

    // MARK: Recording

    func recordingFolders() -> [URL] {
        settings.s.folders.filter(\.isEnabled).map { URL(fileURLWithPath: $0.path) }
    }

    /// Names of sound sources left out of the stream when none is in it (nil when something will be heard).
    var silentStreamWarning: AlertItem? {
        let sources = audioSources
        guard !sources.isEmpty, !sources.contains(where: { ($0.audio ?? AudioSettings()).isInProgram && !($0.audio?.isMuted ?? false) }) else { return nil }
        let names = sources.map(\.name).joined(separator: ", ")
        return AlertItem(title: "No sound in the stream",
                         detail: "\(names) \(sources.count == 1 ? "is" : "are") left out of the stream or muted, so recordings and live streams are silent. In the Audio panel, click Put back in the stream.")
    }
    func warnIfSilent() {
        if let w = silentStreamWarning, !alerts.contains(where: { $0.title == w.title }) { alerts.append(w) }
    }

    func startRecording() {
        guard !isRecording else { return }
        warnIfSilent()
        let canvases = stage.kinds.filter { $0 == .horizontal || isVerticalOn }
        guard !canvases.isEmpty else { notice = "Nothing to record"; return }
        let folders = recordingFolders()
        guard !folders.isEmpty else { notice = "No recording destination is available."; return }
        let now = Date()
        var specs: [RecordingSpec] = []
        for c in canvases {
            let cfg = settings.canvas(c)
            let (codec, kbps) = settings.quality(c)
            let base = RecordingFileName.base(tags: settings.s.nameTags, canvas: c, addsCanvas: canvases.count > 1,
                                              show: sessionName, layout: programScene(c)?.name(for: c) ?? "", at: now)
            let tracks = settings.s.separateTracks ? Array(Set([1] + audioSources.flatMap { Array($0.audio?.tracks ?? [1]) })).sorted() : [1]
            specs.append(RecordingSpec(canvas: c, container: settings.container(c), codec: codec, bitrateKbps: kbps,
                                       width: cfg.width, height: cfg.height, fps: cfg.fps, folders: folders, baseName: base,
                                       splitMinutes: Double(settings.s.splitMinutes), audioTracks: tracks))
        }
        do {
            recorders = try engine.startRecording(specs)
            for r in recorders {
                r.onFailure = { [weak self] msg in
                    self?.alerts.append(AlertItem(title: "Recording destination failed", detail: msg))
                }
            }
            recordingCanvases = canvases
            isRecording = true
            recordingStarted = now
            showEvents.append(ShowEvent(date: now, label: programScene(editingCanvas)?.name ?? "Start", isMarker: false, recOffset: 0,
                                        liveOffset: streaming.liveSince.map { now.timeIntervalSince($0) }))
            recordingPausedAt = nil
            if sessionStart == nil { sessionStart = now }
            holdSleep(true)
        } catch {
            notice = "Recording couldn't start. \(error.localizedDescription)"
        }
    }

    func togglePause() {
        guard isRecording else { notice = "Start recording to pause"; return }
        let t = HostClock.now()
        if recordingPausedAt == nil { recorders.forEach { $0.pause(at: t) }; recordingPausedAt = Date() }
        else { recorders.forEach { $0.resume(at: t) }; recordingPausedAt = nil }
    }

    func stopRecording(then: (() -> Void)? = nil) {
        guard isRecording else { then?(); return }
        let recs = recorders
        isRecording = false
        recordingPausedAt = nil
        let chapterText = chapters(onRecording: true)
        engine.stopRecording(recs) { [weak self] files in
            guard let self else { return }
            self.lastRecordings = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Chapters next to each recording, ready to paste into a YouTube description.
            if chapterText.split(separator: "\n").count >= 2 {
                for f in files {
                    let side = URL(fileURLWithPath: f.deletingPathExtension().path + " chapters.txt")
                    try? chapterText.write(to: side, atomically: true, encoding: .utf8)
                }
            }
            self.recorders = []
            if !self.streaming.isLive { self.holdSleep(false); self.makeSummary() }
            then?()
        }
    }

    var recordedSeconds: Double {
        guard let r = recorders.first else { return 0 }
        return r.recordedSeconds(now: HostClock.now())
    }

    func makeSummary() {
        guard let start = sessionStart else { return }
        let hasRecordingTimes = showEvents.contains { $0.recOffset != nil }
        summary = SessionSummary(title: sessionName.isEmpty ? "Session" : sessionName, started: start, ended: Date(),
                                 recordings: lastRecordings, streams: streaming.reports, droppedFrames: droppedFrames,
                                 chapters: chapters(onRecording: hasRecordingTimes), clips: savedClips)
        sessionStart = nil
        streaming.reports = []
        showEvents = []
        savedClips = []
    }

    // MARK: Sleep, polling, health

    func holdSleep(_ hold: Bool) {
        if hold, sleepAssertion == 0 {
            let type = settings.s.keepsDisplayAwake ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Framecast is recording or live" as CFString, &sleepAssertion)
        } else if !hold, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0
        }
    }

    private func poll() {
        var lv: [UUID: AudioLevel] = [:]
        for s in audioSources { lv[s.id] = engine.mixer.level(for: s.id) }
        levels = lv
        masterLevel = engine.mixer.currentMasterLevel
        var st: [UUID: SourceState] = [:]
        for s in collection.sources { if let x = engine.state(of: s.id) { st[s.id] = x } }
        if st != sourceStates { sourceStates = st }
        // Instant clips: hold the last 30 s while recording or live.
        let wantsReplay = isRecording || streaming.phase != .idle
        if wantsReplay && replay == nil { startReplay() } else if !wantsReplay, let r = replay { engine.stopReplay(r); replay = nil }
        let held = (replay?.heldSeconds ?? 0).rounded()
        if held != replayHeld { replayHeld = held }
        var ms: [UUID: MediaFileSource.Status] = [:]
        for s in collection.sources { if case .media = s.kind, let m = engine.media(s.id) { ms[s.id] = m.status } }
        if ms != mediaStatus { mediaStatus = ms }
        let dl = (engine.mixer.duckLevel * 20).rounded() / 20
        if dl != duckLevel { duckLevel = dl }
        let d = recorders.reduce(0) { $0 + $1.droppedFrames } + engine.metrics.lateFrames
        if d != droppedFrames { droppedFrames = d }
        // Free space: asking macOS is slow (it can take a moment to work out purgeable space), so every 5 s, off the main thread.
        if Date().timeIntervalSince(lastSpaceCheck) > 5, let f = recordingFolders().first {
            lastSpaceCheck = Date()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let cap = (try? f.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.freeBytes = cap
                    if self.isRecording && self.settings.s.warnsLowSpace && cap < 2_000_000_000 && !self.alerts.contains(where: { $0.title == "Disk almost full" }) {
                        self.alerts.append(AlertItem(title: "Disk almost full", detail: "Less than 2 GB left on the recording drive."))
                    }
                }
            }
        }
        streaming.poll()
    }

    /// One status light for the rail footer: healthy, or the most important problem.
    var health: (ok: Bool, text: String) {
        if let a = alerts.last { return (false, a.title) }
        if streaming.anyReconnecting { return (false, "Reconnecting") }
        let failed = collection.sources.compactMap { s -> String? in
            if case .failed(let m)? = sourceStates[s.id], isUsedInProgram(s.id) { return "\(s.name): \(m)" }
            if case .lost(let m)? = sourceStates[s.id], isUsedInProgram(s.id) { return "\(s.name): \(m)" }
            return nil
        }
        if let f = failed.first { return (false, f) }
        return (true, "All good")
    }
    func isUsedInProgram(_ id: UUID) -> Bool {
        CanvasKind.allCases.contains { c in programScene(c)?.items(for: c).contains { $0.sourceID == id && $0.isVisible } ?? false }
    }

    private func refreshThumbnails() {
        let canvas = editingCanvas
        let list = scenes.map { ($0.id, $0.items(for: canvas)) }
        thumbQueue.async { [weak self] in
            guard let self else { return }
            var out: [UUID: CGImage] = [:]
            for (id, items) in list { if let img = self.engine.snapshot(items: items, canvas: canvas, width: 420) { out[id] = img } }
            DispatchQueue.main.async { self.thumbnails = out }
        }
    }
}

extension SourceKind {
    var isFillByDefault: Bool {
        switch self { case .camera, .color, .wallpaper, .guest, .media: return true; default: return false }
    }
    var defaultRole: LayoutRole? {
        switch self { case .camera: return .camera; case .display, .window, .application: return .screen; case .text: return .title; default: return nil }
    }
}

/// Delivers composited frames to preview views on the main thread.
final class PreviewHub: @unchecked Sendable {
    private var sinks: [CanvasKind: [ObjectIdentifier: (CVPixelBuffer) -> Void]] = [:]
    private let lock = NSLock()
    private var pending: [CanvasKind: CVPixelBuffer] = [:]
    private var scheduled = false

    func add(_ owner: AnyObject, canvas: CanvasKind, _ f: @escaping (CVPixelBuffer) -> Void) {
        lock.lock(); sinks[canvas, default: [:]][ObjectIdentifier(owner)] = f; lock.unlock()
    }
    func remove(_ owner: AnyObject) {
        lock.lock(); for k in sinks.keys { sinks[k]?[ObjectIdentifier(owner)] = nil }; lock.unlock()
    }
    func push(_ kind: CanvasKind, _ pb: CVPixelBuffer) {
        lock.lock()
        pending[kind] = pb
        let needs = !scheduled
        scheduled = true
        lock.unlock()
        guard needs else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let p = self.pending; self.pending = [:]; self.scheduled = false
            let s = self.sinks
            self.lock.unlock()
            for (k, pb) in p { s[k]?.values.forEach { $0(pb) } }
        }
    }
}
