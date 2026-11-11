import SwiftUI
import ImageIO
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import AVFoundation
import FramecastEngine

@main
struct FramecastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Framecast", id: "studio") {
            RootView()
                .environment(delegate.studio)
                .environment(delegate.settings)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { FramecastCommands(studio: delegate.studio) }

        Window("Presenter view", id: "prompter") {
            PrompterView()
                .environment(delegate.studio)
                .environment(delegate.settings)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView()
                .environment(delegate.studio)
                .environment(delegate.settings)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: AppSettings
    let studio: Studio
    private var hotkeys: GlobalHotkeys?

    override init() {
        Self.refuseUntestedTestCopy()
        settings = AppSettings()
        studio = Studio(settings: settings)
        // Test launches with a fake camera: stand-ins replace every device before anything starts.
        FakeDevices.install(on: studio.engine)
        super.init()
    }

    /// A copy built for automated tests (its Info.plist has FramecastTestCopy) only runs as a test launch. It has its
    /// own bundle id, but macOS can still open it by its path (Spotlight, a double-click), and a plain launch would use
    /// your own studio, cameras and microphone, so it quits at once, before anything starts, and leaves a note in the
    /// temporary folder.
    private static func refuseUntestedTestCopy() {
        guard Bundle.main.object(forInfoDictionaryKey: "FramecastTestCopy") as? Bool == true,
              ProcessInfo.processInfo.environment["FRAMECAST_UI"] == nil else { return }
        let note = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("framecast-test-copy-refused.log")
        let line = "\(Date()) pid \(getpid()) parent \(getppid()): test copy opened without FRAMECAST_UI, quit before starting\n"
        if let h = try? FileHandle(forWritingTo: note) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: note, atomically: true, encoding: .utf8) }
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let icon = AppIcon.image() { NSApp.applicationIconImage = icon }
        studio.start()
        if settings.s.controlLink == true { studio.controlLink.start() }
        hotkeys = GlobalHotkeys(studio: studio)
        hotkeys?.register()
        if let ui = ProcessInfo.processInfo.environment["FRAMECAST_UI"] { AutoTest.run(ui, studio: studio) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Recordings are always finished before Framecast quits; live streams end only after asking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = studio.streaming.isLive, rec = studio.isRecording
        if (live || rec) && settings.s.confirmsQuit {
            let a = NSAlert()
            a.messageText = live && rec ? "End the stream, stop recording and quit?" : (live ? "End the stream and quit?" : "Stop recording and quit?")
            a.informativeText = live ? "Your viewers will see the stream end. Framecast finishes writing your recordings before it quits."
                                     : "Framecast will finish writing your recordings before it quits."
            a.addButton(withTitle: live ? "End Stream and Quit" : "Stop Recording and Quit")
            a.addButton(withTitle: live ? "Keep Streaming" : "Keep Recording")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if live { studio.streaming.endStream(makeSummary: false) }
        if studio.isRecording {
            studio.stopRecording { [weak self] in
                self?.studio.shutdown()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        studio.shutdown()
        return .terminateNow
    }
}

struct FramecastCommands: Commands {
    let studio: Studio
    @Environment(\.openWindow) var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .undoRedo) {
            Button(studio.undoTitle) { studio.performUndo() }.keyboardShortcut("z")
            Button(studio.redoTitle) { studio.performRedo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Show") {
            Button(studio.isRecording ? "Stop Recording" : "Start Recording") {
                studio.isRecording ? studio.stopRecording() : studio.startRecording()
            }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Pause or Resume Recording") { studio.togglePause() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button(studio.streaming.isLive ? "End Broadcast" : "Start Broadcast…") { NotificationCenter.default.post(name: .framecastGoLive, object: nil) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Mute or Unmute Microphones") { studio.toggleMuteMics() }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Show Comments") { studio.rail = .chat }.keyboardShortcut("c", modifiers: [.command, .option])
            Button(studio.isVerticalOn ? "Hide the 9:16 Canvas" : "Show the 9:16 Canvas") { studio.setVertical(!studio.isVerticalOn) }
            Divider()
            ForEach(Array(studio.scenes.prefix(9).enumerated()), id: \.element.id) { i, s in
                Button("Switch to \(s.name)") { studio.switchTo(s.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.control])
            }
            Divider()
            Button("Add to Scene…") { studio.isAddingSource = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(studio.previewMode ? "Turn Off Preview Before Air" : "Preview Before Air") { studio.setPreviewMode(!studio.previewMode) }
                .keyboardShortcut("p", modifiers: [.command, .option])
            // Always enabled: SwiftUI can leave a disabled menu item stale; takePreview does nothing outside preview mode.
            Button("Put Preview on Air") { studio.takePreview() }.keyboardShortcut(.return, modifiers: .command)
            Button("Pre-flight Check…") { studio.showsPreflight = true }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Add Marker") { studio.addMarker() }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("Save Last 30 Seconds") { studio.saveClip() }.keyboardShortcut("s", modifiers: [.command, .option])
            Menu("Sound Pad") {
                ForEach(0..<9, id: \.self) { i in
                    let s = studio.padSlots[i]
                    Button(s.isEmpty ? "Button \(i + 1) (empty)" : "Play \(s.name)") { studio.playPad(i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.control, .option])
                }
            }
            Button("Change Background…") { studio.chooseBackground() }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button(studio.captions.isOn ? "Turn Off Live Captions (⌃⌥⌘L)" : "Turn On Live Captions (⌃⌥⌘L)") { studio.captions.toggle() }
                .disabled(!studio.captions.canCaption)
            Divider()
            // The rundown's shortcuts are global (⌃⌥⌘T, ⌃⌥⌘U), so they also work from your slides or browser.
            Button("Show Rundown") { studio.rail = .rundown }
            Button("Open Presenter View") { openWindow(id: "prompter") }
            Button("Take Next Part (⌃⌥⌘T)") { studio.director.takeSuggestionOrNext() }
            Button("Undo Director Switch (⌃⌥⌘U)") { studio.director.undoAuto() }
            Button(studio.director.isListening ? "Stop Following My Voice" : "Follow My Voice") {
                studio.director.isListening ? studio.director.stopListening() : studio.director.startListening()
            }
        }
        CommandGroup(after: .sidebar) {
            Button("Close Destinations") { studio.tab = .studio }.keyboardShortcut("1", modifiers: .command)
            Button("Destinations…") { studio.tab = .destinations }.keyboardShortcut("2", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let framecastGoLive = Notification.Name("framecast.goLive")
}

/// System-wide shortcuts via Carbon hot keys (work while another app is focused; no Accessibility
/// permission needed).
final class GlobalHotkeys {
    unowned let studio: Studio
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private static weak var shared: GlobalHotkeys?

    init(studio: Studio) { self.studio = studio }

    struct Binding { let id: UInt32; let key: Int; let mods: Int; let title: String }
    static let defaults: [Binding] = [
        Binding(id: 1, key: kVK_ANSI_R, mods: cmdKey | optionKey | controlKey, title: "Start or stop recording"),
        Binding(id: 2, key: kVK_ANSI_P, mods: cmdKey | optionKey | controlKey, title: "Pause or resume recording"),
        Binding(id: 3, key: kVK_ANSI_M, mods: cmdKey | optionKey | controlKey, title: "Mute or unmute microphones"),
        Binding(id: 4, key: kVK_ANSI_V, mods: cmdKey | optionKey | controlKey, title: "Show or hide the 9:16 canvas"),
        Binding(id: 5, key: kVK_ANSI_T, mods: cmdKey | optionKey | controlKey, title: "Take the suggested or next rundown part"),
        Binding(id: 6, key: kVK_ANSI_U, mods: cmdKey | optionKey | controlKey, title: "Undo the director's last switch"),
        Binding(id: 7, key: kVK_ANSI_Z, mods: cmdKey | optionKey | controlKey, title: "Zoom the screen share to the cursor"),
        Binding(id: 8, key: kVK_ANSI_X, mods: cmdKey | optionKey | controlKey, title: "Whole screen, and no zooms for 30 s"),
        Binding(id: 9, key: kVK_ANSI_C, mods: cmdKey | optionKey | controlKey, title: "Camera moves on or off"),
    ] + (1...9).map { Binding(id: UInt32(10 + $0), key: [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9][$0 - 1],
                                      mods: controlKey | optionKey, title: "Switch to scene \($0)") }
      + (1...9).map { Binding(id: UInt32(20 + $0), key: [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9][$0 - 1],
                                      mods: optionKey | cmdKey, title: "Show or hide overlay \($0)") }
      // Camera angles, from any app (while another window is shared, viewers see only the cut).
      + (1...6).map { Binding(id: UInt32(30 + $0), key: [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6][$0 - 1],
                                      mods: controlKey | optionKey | cmdKey, title: "Camera angle \($0) (again: let go)") }
      + [Binding(id: 30, key: kVK_ANSI_0, mods: controlKey | optionKey | cmdKey, title: "Back to your own camera"),
         Binding(id: 37, key: kVK_ANSI_S, mods: controlKey | optionKey | cmdKey, title: "Camera angle shuffle on or off"),
         Binding(id: 38, key: kVK_ANSI_K, mods: controlKey | optionKey | cmdKey, title: "Switching keys on or off"),
         Binding(id: 39, key: kVK_ANSI_L, mods: controlKey | optionKey | cmdKey, title: "Live captions on or off")]

    func register() {
        Self.shared = self
        let s = studio
        actions[1] = { s.isRecording ? s.stopRecording() : s.startRecording() }
        actions[2] = { s.togglePause() }
        actions[3] = { s.toggleMuteMics() }
        actions[4] = { s.setVertical(!s.isVerticalOn) }
        actions[5] = { s.director.takeSuggestionOrNext() }
        actions[6] = { s.director.undoAuto() }
        actions[7] = { s.liveEditor.zoomToCursor() }
        actions[8] = { s.liveEditor.resetAndPause() }
        actions[9] = { s.liveEditor.toggleMoves() }
        for i in 1...9 {
            actions[UInt32(10 + i)] = { if s.scenes.indices.contains(i - 1) { s.switchTo(s.scenes[i - 1].id) } }
            actions[UInt32(20 + i)] = { s.toggleElement(number: i) }
        }
        for i in 1...6 { actions[UInt32(30 + i)] = { s.angles.pick(number: i) } }
        actions[30] = { s.angles.backToOwnCamera() }
        actions[37] = { s.angles.toggleShuffle() }
        actions[39] = { s.captions.toggle(); s.notice = s.captions.isOn ? "Live captions on" : "Live captions off" }
        actions[38] = {
            var set = s.angles.settings; set.keysOn.toggle(); s.angles.settings = set
            if !set.keysOn { s.notice = "Switching keys off" }
            else if s.angles.keyProblems.isEmpty { s.notice = "Switching keys on: \(s.angles.keysSummary)" }
            else { s.notice = "Switching keys on, but these are taken by another app or shortcut: \(s.angles.keyProblems.joined(separator: ", "))." }
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { GlobalHotkeys.shared?.actions[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
        let taken = registerFixed()
        // Another app holding a shortcut: say so instead of failing quietly.
        s.liveEditor.hotkeyProblems = taken
        if !taken.isEmpty { s.notice = "Another app already uses these shortcuts, so they won't work in Framecast: \(taken.joined(separator: "; "))." }
        registerAngleKeys()
    }

    /// The fixed ⌃⌥⌘ / ⌃⌥ / ⌥⌘ shortcuts. Returns the ones another app holds.
    private func registerFixed() -> [String] {
        var taken: [String] = []
        for b in Self.defaults {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(b.key), UInt32(b.mods), EventHotKeyID(signature: OSType(0x4643_5354), id: b.id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { taken.append("\(Self.describe(b)) \(b.title.lowercased())") }
            refs.append(ref)
        }
        return taken
    }

    // MARK: Switching keys (camera angles)

    /// Ids 100… : the switching keys, registered only while they're on (a single key then stops typing in other
    /// apps, which is why they can be turned off) and never while one is being recorded.
    private var angleRefs: [EventHotKeyRef?] = []
    private var recording = false

    static func applyAngleKeys() { shared?.registerAngleKeys() }
    /// While a key is being recorded every Framecast hot key steps aside, so the press reaches the recorder
    /// (⌃⌥⌘1 is recorded, not run).
    static func pauseAngleKeys(_ on: Bool) {
        guard let h = shared, h.recording != on else { return }
        h.recording = on
        if on { for r in h.refs { if let r { UnregisterEventHotKey(r) } }; h.refs = [] } else { _ = h.registerFixed() }
        h.registerAngleKeys()
    }

    private func registerAngleKeys() {
        for r in angleRefs { if let r { UnregisterEventHotKey(r) } }
        angleRefs = []
        let set = studio.angles.settings
        studio.angles.keyProblems = []
        guard set.keysOn, !recording else { return }
        var problems: [String] = []
        for (i, a) in AngleKeyAction.allCases.enumerated() {
            guard let k = set.key(a) else { continue }
            let id = UInt32(100 + i)
            actions[id] = { [weak studio] in studio?.angles.perform(a) }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(k.key, k.mods, EventHotKeyID(signature: OSType(0x4643_414B), id: id), GetApplicationEventTarget(), 0, &ref)
            if status != noErr { problems.append("\(k.title) (\(a.title.lowercased()))") }
            angleRefs.append(ref)
        }
        studio.angles.keyProblems = problems
        if !problems.isEmpty { studio.notice = "These switching keys are taken by another app or another shortcut: \(problems.joined(separator: ", "))." }
    }

    static func describe(_ b: Binding) -> String {
        var s = ""
        if b.mods & controlKey != 0 { s += "⌃" }
        if b.mods & optionKey != 0 { s += "⌥" }
        if b.mods & shiftKey != 0 { s += "⇧" }
        if b.mods & cmdKey != 0 { s += "⌘" }
        let keys: [Int: String] = [kVK_ANSI_R: "R", kVK_ANSI_P: "P", kVK_ANSI_M: "M", kVK_ANSI_V: "V", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
                                   kVK_ANSI_Z: "Z", kVK_ANSI_X: "X", kVK_ANSI_C: "C", kVK_ANSI_1: "1", kVK_ANSI_2: "2",
                                   kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
                                   kVK_ANSI_0: "0", kVK_ANSI_S: "S"]
        return s + (keys[b.key] ?? "?")
    }
}

/// Scriptable hooks so the packaged app can be put into a state and exercised without clicking
/// (used for screenshots and tests; this Mac has no Accessibility permission for UI automation).
/// FRAMECAST_UI="onboarded,rail=edit,stage=both,layout=2,select=camera,demo-chat,record=8,quit=12"
enum AutoTest {
    static func run(_ spec: String, studio: Studio) {
        for raw in spec.split(separator: ",") {
            let kv = raw.split(separator: "=", maxSplits: 1).map(String.init)
            let key = kv[0], val = kv.count > 1 ? kv[1] : ""
            switch key {
            case "onboarded": studio.settings.s.hasOnboarded = true
            case "folder": studio.settings.s.folders = [RecordingFolder(path: val)]
            case "container": if let c = ContainerFormat(rawValue: val) { studio.settings.s.containerH = c; studio.settings.s.containerV = c }
            case "rail": if let r = StudioRail(rawValue: val) { studio.rail = r }
            case "stage": if let s = StageCanvases(rawValue: val) { if s != .horizontal { studio.setVertical(true) }; studio.stage = s }
            case "tab": studio.tab = val == "destinations" ? .destinations : .studio
            case "layout": if let n = Int(val), studio.scenes.indices.contains(n - 1) { studio.switchTo(studio.scenes[n - 1].id) }
            case "select":
                if let it = studio.editingItems.first(where: { $0.role?.rawValue == val }) { studio.selectedItemID = it.id }
            case "element": if let n = Int(val) { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { studio.toggleElement(number: n) } }
            case "settings": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            case "add-source": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { studio.isAddingSource = true }
            case "demo-chat": DemoContent.chat(into: studio.chat)
            case "sync-test":
                // A/V sync check through the app: flash-every-second pattern + beep-every-second tone on both
                // canvases, in memory only (the saved scenes are not changed).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let pattern = SourceRecord(name: "Sync pattern", kind: .testPattern)
                    var tone = SourceRecord(name: "Sync tone", kind: .tone); tone.audio = AudioSettings()
                    var srcs = studio.collection.sources.map { s -> SourceRecord in var x = s; x.audio?.isInProgram = false; return x }
                    srcs += [pattern, tone]
                    studio.engine.sync(sources: srcs, fpsHint: studio.settings.s.horizontal.fps)
                    for c in CanvasKind.allCases {
                        studio.engine.setProgram([SceneItem(sourceID: pattern.id, transform: .full, fit: .fit)], for: c, transition: .cut, durationMs: 0)
                    }
                }
            case "window":
                let wh = val.split(separator: "x").compactMap { Double($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if wh.count == 2, let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "framecast.studio" }) {
                        w.setFrame(NSRect(x: 40, y: 40, width: wh[0], height: wh[1]), display: true)
                    }
                }
            case "mask-devices":
                // Screenshot privacy: show synthetic stand-ins instead of the real camera and screen (not saved).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    for src in studio.collection.sources {
                        switch src.kind {
                        case .camera: studio.engine.setExternalSource(src.id, StaticImageSource(id: src.id, image: DemoContent.cameraStandIn()))
                        case .display, .window, .application: studio.engine.setExternalSource(src.id, StaticImageSource(id: src.id, image: DemoContent.screenStandIn()))
                        default: break
                        }
                    }
                }
            case "open-guests": studio.guests.open()
            case "test-control": TestControl.shared.listen(studio)
            case "auto-admit": studio.guests.askBeforeLettingIn = false
            case "record":
                let secs = Double(val) ?? 6
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    studio.startRecording()
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                        studio.stopRecording { FileHandle.standardError.write("AUTOTEST files: \(studio.lastRecordings.map(\.path))\n".data(using: .utf8)!) }
                    }
                }
            case "quit": DispatchQueue.main.asyncAfter(deadline: .now() + (Double(val) ?? 10)) { NSApp.terminate(nil) }
            default: break
            }
        }
    }
}

/// Opt-in local test channel (only when launched with FRAMECAST_UI containing "test-control"):
/// scripts post `app.framecast.test` distributed notifications to press the same buttons a person would.
final class TestControl {
    static let shared = TestControl()
    private var observer: NSObjectProtocol?
    static var localStream: StreamOutput?
    static func point(_ s: String) -> CGPoint? {
        let v = s.split(separator: ",").compactMap { Double($0) }
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
    }
    static func write<T: Encodable>(_ value: T, to path: String) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(value).write(to: URL(fileURLWithPath: path))
    }
    /// The camera the angles-from-one-camera hooks act on: the marked frame's, else the first camera.
    static func angleCamera(_ studio: Studio) -> UUID? {
        let cams = studio.collection.sources.filter { if case .camera = $0.kind { return true }; return false }.map(\.id)
        if let m = studio.angles.markedFrame?.item.sourceID, cams.contains(m) { return m }
        return cams.first
    }
    /// Keeps every crop drawn for `seconds`, then writes one JSON line per draw: t, angle, key, x, y, w, h (camera
    /// picture, top-left 0...1), zoom, the followed face, and its last reading unsmoothed with that picture's time.
    static func traceCrops(_ studio: Studio, to url: URL, seconds: Double) {
        let rigs = Array(studio.angles.rigs.values)
        rigs.forEach { $0.startTrace() }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let rows = rigs.flatMap { rig in rig.stopTrace().map { (rig.cameraID, $0) } }.sorted { $0.1.t < $1.1.t }
            var out = Data()
            for (cam, e) in rows {
                let key = switch e.key { case .program(let c): c.rawValue; case .iso: "iso" }
                var d: [String: Any] = ["t": e.t, "angle": CameraAngles.virtualID(cam, e.shot), "key": key,
                                        "x": e.rect.minX, "y": e.rect.minY, "w": e.rect.width, "h": e.rect.height, "zoom": e.zoom]
                if let f = e.face { d["face"] = [f.minX, f.minY, f.width, f.height] }
                if let r = e.raw, let at = e.rawAt { d["raw"] = [r.minX, r.minY, r.width, r.height]; d["rawAt"] = at }
                if let line = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) { out.append(line); out.append(0x0A) }
            }
            try? out.write(to: url)
        }
    }
    func listen(_ studio: Studio) {
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.framecast.test"), object: nil, queue: .main) { n in
            guard let cmd = n.object as? String else { return }
            let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "admit-all": for g in studio.guests.guests where g.status == .waiting { studio.guests.admit(g.id) }
            case "open-guests": studio.guests.open()
            case "close-guests": studio.guests.close()
            case "remove-guests": for g in studio.guests.guests { studio.guests.remove(g.id) }
            case "new-invite": studio.guests.newInviteLink()
            case "put-in-stream":
                // Same as the Audio panel's "Put back in the stream" button.
                if let src = studio.audioSources.first(where: { $0.name == arg }) { studio.setAudio(src.id) { $0.isInProgram = true } }
            case "sheet-add-source": studio.testAddSourceCategory = arg; studio.isAddingSource = true
            case "activate": NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.identifier?.rawValue == "framecast.studio" }?.makeKeyAndOrderFront(nil)
            case "dump-windows":
                let lines = NSApp.windows.map { w in "\(w.title.isEmpty ? "(no title)" : w.title) | id=\(w.identifier?.rawValue ?? "-") | frame=\(NSStringFromRect(w.frame)) | visible=\(w.isVisible) | mini=\(w.isMiniaturized) | \(type(of: w))" }
                try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
            case "show-onboarding": studio.settings.s.hasOnboarded = false   // test launches have their own settings
            case "sheet-golive": NotificationCenter.default.post(name: .framecastGoLive, object: nil)
            case "sheet-close": studio.isAddingSource = false; studio.summary = nil; studio.backgroundTarget = nil; studio.showsPreflight = false; studio.testDismiss += 1
            case "preflight": studio.showsPreflight = true
            case "render-view":
                // "<preflight|backgrounds>|<png path>": draws a sheet off-screen (works while the screen is locked).
                let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
                guard p.count == 2 else { break }
                let (view, size): (AnyView, NSSize) = switch p[0] {
                case "preflight": (AnyView(PreflightSheet(isSnapshot: true).environment(studio)), NSSize(width: 640, height: 640))
                case "mixer": (AnyView(AudioPanel().environment(studio).background(Theme.panel)), NSSize(width: 340, height: 1100))
                case "layer": (AnyView(EditPanel().environment(studio).background(Theme.panel)), NSSize(width: 340, height: 640))
                case "prompter": (AnyView(PrompterView().environment(studio).environment(studio.settings)), NSSize(width: 980, height: 620))
                case "presenter": (AnyView(PrompterView().environment(studio).environment(studio.settings)), NSSize(width: 1100, height: 760))
                case "rundown": (AnyView(RundownPanel().environment(studio).environment(studio.settings).background(Theme.panel)), NSSize(width: 340, height: 1300))
                case "angles": (AnyView(AnglesPanel().environment(studio).background(Theme.panel)), NSSize(width: 340, height: 1500))
                case "captions": (AnyView(CaptionsPanel().environment(studio).background(Theme.panel)), NSSize(width: 340, height: 900))
                case "inspector": (AnyView(Inspector().environment(studio)), NSSize(width: 340, height: 700))
                case "program": (AnyView(ProgramArea().environment(studio)), NSSize(width: 560, height: 420))
                case "ai-settings": (AnyView(ScrollView { VStack(alignment: .leading, spacing: 18) { AIPane() }.padding(24) }
                    .environment(studio).environment(studio.settings).background(Theme.panel)), NSSize(width: 680, height: 1000))
                default: (AnyView(BackgroundPickerSheet(target: .scene).environment(studio)), NSSize(width: 1040, height: 680))
                }
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
                    }
                    _ = host
                }
            case "preflight-record": Task { await studio.preflight.recordTest(seconds: Double(arg) ?? 10) }
            case "preflight-upload": Task { await studio.preflight.testUpload() }
            case "preflight-fix": if let it = studio.preflight.items.first(where: { $0.id == arg }), let f = it.fix { studio.preflight.apply(f) }
            case "set-audio":
                // "<source name>:<muted|unmuted|out|in>" (test setup for the pre-flight check).
                let p = arg.split(separator: ":").map(String.init)
                if p.count == 2, let s = studio.audioSources.first(where: { $0.name == p[0] }) {
                    studio.setAudio(s.id) { a in
                        switch p[1] { case "muted": a.isMuted = true; case "unmuted": a.isMuted = false; case "out": a.isInProgram = false
                        case "voice": a.isVoice = true; case "novoice": a.isVoice = false; default: a.isInProgram = true }
                    }
                }
            case "sheet-backgrounds": if arg == "scene" { studio.backgroundTarget = .scene } else { studio.chooseBackground() }
            case "bg-picker": studio.testBackgroundPicker = (arg, (studio.testBackgroundPicker?.serial ?? 0) + 1)
            case "add-sheet-pick": studio.testAddSheetPick = (arg, (studio.testAddSheetPick?.serial ?? 0) + 1)
            case "menu":
                // Clicks the first menu item whose title starts with the argument (checks real menu wiring).
                func find(_ m: NSMenu) -> (NSMenu, Int)? {
                    for (i, it) in m.items.enumerated() {
                        if it.title.hasPrefix(arg), it.isEnabled { return (m, i) }
                        if let sub = it.submenu, let r = find(sub) { return r }
                    }
                    return nil
                }
                func refresh(_ m: NSMenu) { m.update(); m.items.forEach { if let s = $0.submenu { refresh(s) } } }
                if let main = NSApp.mainMenu { refresh(main); if let (m, i) = find(main) { m.performActionForItem(at: i) } }
            case "preview-mode": studio.setPreviewMode(arg != "off")
            case "preview-scene": if let s = studio.scenes.first(where: { $0.name == arg }) { studio.show(s.id) }
            case "take": studio.takePreview()
            case "add-media": studio.addMediaFile(URL(fileURLWithPath: arg))
            case "media":
                // "<source name>|play|pause|restart|seek=N|loop=on|off"
                let p = arg.split(separator: "|").map(String.init)
                if p.count == 2, let s = studio.collection.sources.first(where: { $0.name == p[0] }), let m = studio.engine.media(s.id) {
                    switch p[1] {
                    case "play": m.play()
                    case "pause": m.pause()
                    case "restart": m.restart()
                    case let x where x.hasPrefix("seek="): m.seek(to: Double(x.dropFirst(5)) ?? 0)
                    case "loop=on": studio.setMediaOptions(s.id) { $0.loop = true }
                    case "loop=off": studio.setMediaOptions(s.id) { $0.loop = false }
                    case "duck=on": studio.setAudio(s.id) { $0.ducksUnderVoice = true }
                    case "duck=off": studio.setAudio(s.id) { $0.ducksUnderVoice = false }
                    default: break
                    }
                }
            case "show-new": studio.director.newShow(title: arg.isEmpty ? "New show" : arg)
            case "show-script":
                // Reads a text file into the open show's script.
                if let t = try? String(contentsOfFile: arg, encoding: .utf8) { studio.director.edit { $0.script = t } }
            case "show-split":
                let parts = ScriptWriter.split(script: studio.director.show?.script ?? "", scenes: studio.scenes.map(\.name))
                studio.director.edit { $0.parts = parts }
            case "show-import":
                // A show.json written by hand or by a tool: opened as a new show.
                if let d = FileManager.default.contents(atPath: arg), let s = try? JSONDecoder().decode(ShowRundown.self, from: d) {
                    studio.director.newShow(title: s.title)
                    studio.director.edit { $0.script = s.script; $0.parts = s.parts; $0.aliases = s.aliases; $0.director = s.director }
                }
            case "show-close": studio.director.close()
            case "show-write": studio.director.writeWithAI()
            case "ai-setup":
                // "<claude|openai>|<key>|<model>" for tests against a stand-in server (test launches keep their own keys).
                let p = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if p.count == 3, let provider = AIProvider(rawValue: p[0]) {
                    studio.settings.s.aiProvider = provider
                    studio.settings.s.writeWithAPI = true
                    AIKeys.set(provider, p[1])
                    if provider == .claude { studio.settings.s.claudeModel = p[2] } else { studio.settings.s.openAIModel = p[2] }
                }
            case "director-mode": if let m = DirectorMode(rawValue: arg) { studio.director.setMode(m) }
            case "director-listen": studio.director.startListening(file: arg.isEmpty ? nil : URL(fileURLWithPath: arg))
            case "director-stop": studio.director.stopListening()
            case "director-take": studio.director.takeSuggestionOrNext()
            case "director-top": studio.director.current = nil; studio.director.suggestion = nil
            case "open-prompter": studio.testOpenPrompter += 1
            case "outline-import":
                // A JSON file with title, brief, topics and assets (as set_outline takes them).
                if let data = FileManager.default.contents(atPath: arg), let o = try? JSONDecoder().decode(ShowRundown.self, from: data) {
                    studio.director.setOutline(title: o.title, brief: o.brief, topics: o.topics, assets: o.assets)
                }
            case "topic": if let n = Int(arg) { studio.director.goToTopic(n - 1) }
            case "private-capturable": PrivateOverlayView.testCapturable = arg == "on"; studio.rail = .chat; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { studio.rail = .rundown }
            case "listen-language": if let l = ListenLanguage(rawValue: arg) { studio.settings.s.listenLanguage = l }
            case "own-windows":
                studio.settings.s.showsOwnWindows = arg == "on"
                ScreenSource.showsOwnWindows = arg == "on"
                studio.engine.refreshScreenFilters()
            case "show-open": studio.director.open(URL(fileURLWithPath: arg))
            case "snapshot-source":
                // "<source name>|<png path>": what one source shows right now, full frame.
                let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
                if p.count == 2, let src = studio.collection.sources.first(where: { $0.name == p[0] }),
                   let img = studio.engine.snapshot(items: [SceneItem(sourceID: src.id, transform: .full, fit: .fit)], canvas: .horizontal, width: 1920),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p[1]) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
            case "brain-model": studio.settings.s.brainClaudeModel = arg; studio.settings.s.brainOpenAIModel = arg
            case "rehearse-start": studio.director.startRehearsal(file: arg.isEmpty ? nil : URL(fileURLWithPath: arg))
            case "rehearse-stop": studio.director.stopRehearsal()
            case "rehearsal-import": studio.director.importRehearsal(URL(fileURLWithPath: arg))
            case "rehearsal-accept":
                // "<part number>": adds the closest thing said for that missed part as another way to say its cue.
                if let n = Int(arg), let m = studio.director.report?.misses.first(where: { $0.part == n - 1 }), let c = m.closest {
                    studio.director.acceptAlternative(part: n - 1, c)
                }
            case "rehearsal-alias":
                if let i = Int(arg), let list = studio.director.report?.mishearings, list.indices.contains(i - 1) { studio.director.acceptAlias(list[i - 1]) }
            case "director-undo": studio.director.undoAuto()
            case "control-link":
                studio.settings.s.controlLink = arg == "on"
                if arg == "on" { studio.controlLink.start() } else { studio.controlLink.stop() }
            case "pad": if let i = Int(arg) { studio.playPad(i - 1) }
            case "marker": studio.addMarker()
            case "clip": studio.saveClip()
            case "undo": studio.undo()
            case "redo": studio.redo()
            // Live editor (screen auto-zoom). Points are desktop points, top-left origin.
            case "moves": if let m = CameraMoves(rawValue: arg) { studio.liveEditor.setMoves(m) }
            case "moves-intensity": if let i = MoveIntensity(rawValue: arg) { studio.liveEditor.settings.intensity = i }
            case "moves-idle": if let s = Double(arg) { studio.liveEditor.settings.idleSeconds = s }
            case "focus-click": if let p = TestControl.point(arg) { studio.liveEditor.testClick(p) }
            case "focus-cursor": studio.liveEditor.testCursor(TestControl.point(arg))
            case "focus-secure": studio.liveEditor.testSecure(arg == "auto" ? nil : arg == "on")
            case "focus-zoom-here": studio.liveEditor.zoomToCursor()
            case "focus-reset": studio.liveEditor.resetAndPause()
            case "focus-trace": if arg == "stop" { studio.engine.focus.stopTrace() } else { studio.engine.focus.startTrace(to: URL(fileURLWithPath: arg)) }
            case "focus-dump": TestControl.write(studio.engine.focus.state(), to: arg)
            case "never-zoom": studio.liveEditor.settings.neverZoom = arg.isEmpty ? [] : arg.split(separator: ",").map(String.init)
            case "hide-password-managers": studio.liveEditor.settings.hidesPasswordManagers = arg == "on"
            case "click-rings": studio.liveEditor.settings.clickRings = arg == "on"
            case "metrics-dump": TestControl.write(Gate0.snapshot(studio), to: arg)
            case "metrics-reset": studio.engine.resetTickStats()
            case "inject-tick-ms": studio.engine.testMinTickMs = Double(arg) ?? 0
            case "governor-baseline": studio.liveEditor.settings.baselineP95Ms = Double(arg)
            case "moves-performance": if let m = PerformanceMode(rawValue: arg) { studio.liveEditor.settings.performance = m }
            case "mask-cameras":
                // Long test runs: a stand-in picture instead of the camera (not saved), so the camera stays off.
                for src in studio.collection.sources { if case .camera = src.kind { studio.engine.setExternalSource(src.id, StaticImageSource(id: src.id, image: DemoContent.cameraStandIn())) } }
            // It captures its own test window for real, so never with stand-in devices.
            case "live-editor-selftest": if !FakeDevices.isOn { LiveEditorSelfTest.run(studio, out: arg) }
            case "scene-tour": LiveEditorSelfTest.sceneTour(studio, out: arg)
            case "stream-local":
                // "<rtmp url>|<key>" to a test receiver on this Mac only (never a destination), or "stop".
                if arg == "stop" { if let s = TestControl.localStream { studio.engine.stopStream(s); TestControl.localStream = nil } }
                else {
                    let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
                    guard let first = p.first, let host = URL(string: first)?.host, ["127.0.0.1", "localhost"].contains(host), TestControl.localStream == nil else { break }
                    let h = studio.settings.s.horizontal
                    let spec = StreamSpec(name: "Local test", url: first, key: p.count > 1 ? p[1] : "", canvas: .horizontal,
                                          width: h.width, height: h.height, fps: h.fps, videoKbps: 6_000, autoReconnect: false, adaptiveBitrate: false)
                    TestControl.localStream = try? studio.engine.startStream(spec)
                }
            case "move-selected":
                // "dx,dy" in canvas fractions, applied to the selected layer (or the camera layer).
                let d = arg.split(separator: ",").compactMap { Double($0) }
                let id = studio.selectedItemID ?? studio.editingItems.first { $0.role == .camera }?.id
                if d.count == 2, let id { studio.updateItem(id) { $0.transform.x += d[0]; $0.transform.y += d[1] } }
            case "edit-all": studio.editsAllScenes = arg == "on"
            case "set-shape":
                // "circle|rect|none" on the selected layer (or the camera layer).
                let id = studio.selectedItemID ?? studio.editingItems.first { $0.role == .camera }?.id
                let m: ItemMask = arg == "circle" ? .circle : (arg == "rect" ? .roundedRect(radius: 0.12) : .none)
                if let id { studio.updateItem(id) { $0.mask = m } }
            case "set-crop":
                // "left,top,right,bottom" (0...1 of the picture) on the selected layer, or the camera layer, of the
                // canvas being edited; "none" takes the crop off.
                let v = arg.split(separator: ",").compactMap { Double($0) }
                let id = studio.selectedItemID ?? studio.editingItems.first { $0.role == .camera }?.id
                if let id { studio.updateItem(id) { $0.crop = v.count == 4 ? ItemCrop(left: v[0], top: v[1], right: v[2], bottom: v[3]) : ItemCrop() } }
            case "mirror":
                let id = studio.selectedItemID ?? studio.editingItems.first { $0.role == .camera }?.id
                if let id { studio.updateItem(id) { $0.isMirrored.toggle() } }
            case "select-layer": if let it = studio.editingItems.first(where: { $0.role?.rawValue == arg }) { studio.selectedItemID = it.id }
            case "set-background":
                if let c = BackgroundCatalog.choice(arg) { studio.setSceneBackground(.wallpaper(c.id), name: c.name) }
            case "settings-open":
                studio.testSettingsPane = arg
                studio.testOpenSettings += 1
            case "settings-close": for w in NSApp.windows where w.title.localizedCaseInsensitiveContains("settings") { w.close() }
            case "add-pack-layout": studio.addPackLayout(arg)
            case "add-pack":
                if let a = AssetPack.find(arg)?.asset {
                    studio.addSource(SourceRecord(name: a.name, kind: a.category == "backgrounds" ? .wallpaper("pack:\(a.id)") : .packImage(a.id)))
                }
            case "snapshot":
                // Writes what the program shows on each canvas to <arg>-horizontal.png / <arg>-vertical.png.
                for c in CanvasKind.allCases {
                    guard let scene = studio.programScene(c),
                          let img = studio.engine.snapshot(items: studio.airItems[c] ?? scene.items(for: c), canvas: c, width: c == .horizontal ? 1920 : 1080),
                          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(arg)-\(c.rawValue).png") as CFURL, "public.png" as CFString, 1, nil)
                    else { continue }
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
            case "window-png":
                // The studio window as drawn (Metal previews may come out blank), for checking panels.
                if let w = NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).max(by: { $0.frame.width < $1.frame.width }),
                   let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
            case "program-snapshot":
                // The program as it goes out (framing included), unlike "snapshot".
                for c in CanvasKind.allCases {
                    guard let img = studio.engine.programSnapshot(c, width: c == .horizontal ? 1280 : 720),
                          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(arg)-\(c.rawValue).png") as CFURL, "public.png" as CFString, 1, nil)
                    else { continue }
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
            case "guests-host-mic-off": studio.guests.shareHostMic = false
            // Camera angles: the same actions as ⌃⌥⌘1–6, ⌃⌥⌘0 and ⌃⌥⌘S, a scripted voice, and a JSON dump.
            case "angle-pick": if let n = Int(arg) { studio.angles.pick(number: n) }
            case "angle-back": studio.angles.backToOwnCamera()
            case "angle-shuffle": studio.angles.toggleShuffle()
            case "angle-test-voice": studio.angles.testVoice = arg != "off"
            case "angle-device-audio": if let a = studio.angles.angles.first(where: { $0.name == arg }) { studio.angles.setDeviceAudio(a.id, !a.audioAllowed) }
            case "angle-lineup":
                // "2" lines up angle 2; "2:180" tests it against its own sound moved 180 ms earlier.
                let p = arg.split(separator: ":").compactMap { Double($0) }
                if let n = p.first.map(Int.init), studio.angles.angles.indices.contains(n - 1) {
                    studio.angles.cancelLining()
                    studio.angles.testLineUpShift = p.count > 1 ? p[1] : nil
                    studio.angles.lineUp(studio.angles.angles[n - 1].id)
                }
            case "angle-sync":
                let p = arg.split(separator: ":").compactMap { Double($0) }
                if p.count == 2, studio.angles.angles.indices.contains(Int(p[0]) - 1) { studio.angles.setSync(studio.angles.angles[Int(p[0]) - 1].id, ms: p[1]) }
            case "angle-mark-camera": studio.angles.markCameraOnAir()
            case "angle-unmark": studio.angles.unmark()
            case "angle-set":
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                // Angles from one camera, for the marked frame's camera (else the first camera):
                // "virtual=on|both|medium|close|off" and "use4k=on|off".
                if kv.count == 2, kv[0] == "virtual" || kv[0] == "use4k" {
                    guard let cam = TestControl.angleCamera(studio) else { break }
                    if kv[0] == "use4k" { studio.angles.use4K(camera: cam, kv[1] == "on") }
                    else {
                        let shots: VirtualShots? = switch kv[1] {
                        case "on", "both": VirtualShots()
                        case "medium": VirtualShots(medium: true, close: false)
                        case "close": VirtualShots(medium: false, close: true)
                        default: nil
                        }
                        studio.angles.setVirtual(camera: cam, shots: shots)
                    }
                } else if kv.count == 2 {
                    var s = studio.angles.settings
                    let on = kv[1] == "on"
                    switch kv[0] {
                    case "followLook": s.followLook = on
                    case "keepFramed": s.keepFramed = on
                    case "lipSync": s.lipSync = on
                    case "aiPicks": s.aiPicks = on
                    case "recordAngles": s.recordAngles = on
                    case "keysOn": s.keysOn = on
                    case "useAPIKey": s.useAPIKey = on
                    case "recordCrops": s.virtual.recordCrops = on
                    case "pace": if let p = ShufflePace(rawValue: kv[1]) { s.pace = p }
                    default: break
                    }
                    studio.angles.settings = s
                }
            case "angle-tiles": studio.angles.tilesShown = arg == "on" ? 1 : 0
            // A switching key's action, as if its key were pressed ("angle2", "ownCamera", "shuffle", "next"…).
            case "angle-key": if let a = AngleKeyAction(rawValue: arg) { studio.angles.perform(a) }
            case "angle-hear": studio.angles.hear(arg, isFinal: true)   // as if Listen heard it (no speech permission needed)
            case "angle-analyse": studio.angles.analyse()
            case "angle-test-look":
                // "2": the presenter looks into angle 2; "off": back to what Vision sees.
                if let n = Int(arg), studio.angles.angles.indices.contains(n - 1) { studio.angles.testFacing = studio.angles.angles[n - 1].id }
                else { studio.angles.testFacing = nil }
            case "angle-test-face":
                // "cx,cy,h[,yaw]": cameras with crops see a face centred there (camera picture, top-left 0...1, h of
                // its height, square in pixels) instead of what Vision sees; "off": Vision again.
                let v = arg.split(separator: ",").compactMap { Double($0) }
                if v.count >= 3, let cam = TestControl.angleCamera(studio) {
                    let size = studio.engine.nativeSize(of: cam) ?? CGSize(width: 1920, height: 1080)
                    let w = v[2] * size.height / max(1, size.width)
                    studio.angles.testFace = (CGRect(x: v[0] - w / 2, y: v[1] - v[2] / 2, width: w, height: v[2]), v.count > 3 ? v[3] : nil)
                } else { studio.angles.testFace = nil }
            case "angle-trace":
                // "<file>:<seconds>": every crop drawn on air or into a recording for that long, as JSON lines.
                guard let colon = arg.lastIndex(of: ":"), let secs = Double(arg[arg.index(after: colon)...]) else { break }
                TestControl.traceCrops(studio, to: URL(fileURLWithPath: String(arg[..<colon])), seconds: secs)
            case "captions": if arg == "off" { studio.captions.stop() } else if !studio.captions.isOn { studio.captions.start() }
            case "captions-language": studio.captions.settings.language = arg == "default" ? "" : arg
            case "captions-size": if let v = CaptionSize(rawValue: arg) { studio.captions.settings.size = v }
            case "captions-position": if let v = CaptionPosition(rawValue: arg) { studio.captions.settings.position = v }
            case "captions-feed": studio.captions.start(file: URL(fileURLWithPath: arg))
            case "captions-correct":
                // "<line number, 1 first, or last>:<new text>"
                let p = arg.split(separator: ":", maxSplits: 1).map(String.init)
                let t = studio.captions.transcript
                if p.count == 2, let line = p[0] == "last" ? t.last : Int(p[0]).flatMap({ t.indices.contains($0 - 1) ? t[$0 - 1] : nil }) {
                    studio.captions.correct(line.id, p[1])
                }
            case "captions-clear": studio.captions.clearTranscript()
            case "angles-dump":
                if let d = try? JSONSerialization.data(withJSONObject: studio.angles.dump(), options: [.prettyPrinted]) {
                    try? d.write(to: URL(fileURLWithPath: arg))
                }
            case "guest-reach": if let r = GuestReach(rawValue: arg) { studio.guests.testOverride = true; studio.guests.reach = r }
            case "guest-remote-local-test":
                // The remote-guest protocol against the LiveKit server on this Mac (not saved).
                studio.guests.testOverride = true; studio.guests.reach = .internet; studio.guests.cloud = .localTest
            case "stage-all": for g in studio.guests.guests where g.status == .lobby { studio.guests.bringOnStage(g.id) }
            case "unstage-all": for g in studio.guests.guests where g.status == .stage { studio.guests.takeOffStage(g.id) }
            case "stage-guest": if let g = studio.guests.guests.first(where: { $0.name == arg }) { studio.guests.bringOnStage(g.id) }
            case "mute-guests": for g in studio.guests.guests { studio.guests.toggleMute(g.id) }
            case "backstage": studio.chat.backstageDraft = arg; studio.chat.sendBackstage()
            case "layout": if let i = Int(arg), studio.scenes.indices.contains(i - 1) { studio.switchTo(studio.scenes[i - 1].id) }
            case "layout-named": if let s = studio.scenes.first(where: { $0.name == arg }) { studio.switchTo(s.id) }
            case "rail": if let r = StudioRail(rawValue: arg) { studio.rail = r }
            case "stage": if let s = StageCanvases(rawValue: arg) { if s != .horizontal { studio.setVertical(true) }; studio.stage = s }
            case "record-start": studio.startRecording()
            case "record-stop": studio.stopRecording()
            case "record-pause": studio.togglePause()
            case "golive": studio.streaming.goLive(recordToo: arg == "record")
            case "endstream": studio.streaming.endStream()
            case "element": if let i = Int(arg) { studio.toggleElement(number: i) }
            case "chat-onscreen": if let m = studio.chat.visible.last { studio.chat.toggleOnScreen(m) }
            case "add-destination":
                // name|server|key|canvas
                let f = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if f.count == 4 { _ = studio.streaming.destinations.add(platform: .custom, name: f[0], server: f[1], key: f[2], canvas: CanvasKind(rawValue: f[3]) ?? .horizontal) }
            case "tab": studio.tab = arg == "destinations" ? .destinations : .studio
            case "summary-close": studio.summary = nil
            case "dump-state":
                // Writes a JSON snapshot for scripts (path given as the argument).
                var st: [String: Any] = [
                    "invite": studio.guests.inviteURL ?? "", "guestStatus": studio.guests.status,
                    "guestReach": studio.guests.reach.rawValue, "cloudReady": studio.guests.cloud.problem ?? "ok",
                    "guests": studio.guests.guests.map { ["name": $0.name, "status": $0.status.rawValue, "connected": $0.connected, "sharing": $0.sharingScreen] },
                    "stageSlots": studio.guests.stageNames,
                    "backstage": studio.chat.backstage.map { ["user": $0.user, "text": $0.text] },
                    "recording": studio.isRecording, "lastRecordings": studio.lastRecordings.map(\.path),
                    "streamPhase": "\(studio.streaming.phase)", "health": studio.health.text,
                    "streams": studio.streaming.statuses.map { ["id": $0.key.uuidString, "status": "\($0.value)"] },
                    "sources": studio.collection.sources.map { s in ["name": s.name, "state": "\(studio.sourceStates[s.id].map { "\($0)" } ?? "none")",
                                                                       "type": studio.engine.sourceTypeName(of: s.id) ?? "none"] },
                    "background": studio.editingBackground.flatMap { b in studio.source(b.sourceID).map { s -> String in
                        if case .wallpaper(let w) = s.kind { return "\(s.name) [\(w)] in \(studio.sceneCount(using: s.id)) scenes" }; return s.name } } ?? "",
                    "backgroundChoices": BackgroundCatalog.all.count,
                    "undo": studio.undoSteps.map(\.label), "redo": studio.redoSteps.map(\.label),
                    "scenes": studio.scenes.map(\.name),
                    "cameraLayers": studio.scenes.flatMap { sc in sc.horizontal.filter { $0.role == .camera }.map { it in
                        "\(sc.name): \(String(format: "%.3f,%.3f %.3fx%.3f", it.transform.x, it.transform.y, it.transform.width, it.transform.height)) \(it.mask) mirrored=\(it.isMirrored) filters=\(it.filters.count)" } },
                    "media": studio.collection.sources.compactMap { s -> String? in
                        guard case .media = s.kind, let st = studio.mediaStatus[s.id] else { return nil }
                        return "\(s.name): \(st.isPlaying ? "playing" : "paused") \(String(format: "%.2f", st.position))/\(String(format: "%.2f", st.duration)) video=\(st.hasVideo) audio=\(st.hasAudio) loop=\(s.media?.loop ?? false)" },
                    "duckLevel": studio.duckLevel,
                    "events": studio.showEvents.map { "\($0.isMarker ? "marker" : "scene") \($0.label) rec=\($0.recOffset.map { String(format: "%.1f", $0) } ?? "-") live=\($0.liveOffset.map { String(format: "%.1f", $0) } ?? "-")" },
                    "clips": studio.savedClips.map(\.path), "replayHeld": studio.replayHeld,
                    "summaryChapters": studio.summary?.chapters ?? "", "summaryClips": studio.summary?.clips.map(\.path) ?? [],
                    "preflight": studio.preflight.items.map { "\($0.id): \($0.status) | \($0.detail)" },
                    "preflightFile": studio.preflight.testFile?.path ?? "",
                    "previewMode": studio.previewMode, "previewScene": studio.previewMode ? (studio.previewScene?.name ?? "") : "",
                    "unaired": CanvasKind.allCases.filter { studio.hasUnairedChanges($0) }.map(\.rawValue),
                    "editingLayers": studio.editingItems.map { it in
                        "\(studio.source(it.sourceID)?.name ?? "?") \(String(format: "%.3f,%.3f", it.transform.x, it.transform.y))\(it.isVisible ? "" : " hidden")" },
                    "program": studio.programScene(.horizontal)?.name ?? "", "alerts": studio.alerts.map { $0.title + ": " + $0.detail },
                ]
                st["dropped"] = studio.droppedFrames
                let dir = studio.director
                st["rundown"] = [
                    "title": dir.show?.title ?? "", "folder": dir.folder?.path ?? "", "mode": dir.mode.rawValue,
                    "current": dir.current.map { $0 + 1 } ?? 0, "listening": dir.isListening, "status": dir.status, "heard": dir.heard,
                    "suggestion": dir.suggestion.map { "\($0.part + 1) \($0.how) “\($0.heard)” \($0.note ?? "")" } ?? "",
                    "lastAuto": dir.lastAuto.map { "\($0.part + 1)" } ?? "", "paused": dir.pausedUntil.map { $0 > Date() } ?? false,
                    "writing": dir.writing ?? "", "writeError": dir.writeError ?? "",
                    "parts": dir.parts.enumerated().map { "\($0.offset + 1). \($0.element.title) | \($0.element.scene) | \($0.element.cue) | +\($0.element.alsoAccept.count)" },
                    "aliases": (dir.show?.aliases ?? []).map { "\($0.heard)→\($0.meant)" },
                    "scriptPosition": dir.scriptPosition, "onScript": dir.onScript,
                    "heardHindi": dir.heardSecond.suffix(4).map(\.text),
                    "scriptAt": dir.prompterScript.words.indices.contains(dir.scriptPosition) ? dir.prompterScript.words[max(0, dir.scriptPosition - 4)...dir.scriptPosition].joined(separator: " ") : "",
                    "rehearsing": dir.isRehearsing,
                    "report": dir.report.map { r in [
                        "file": r.file.lastPathComponent, "caught": "\(r.fires.count)/\(r.cues)",
                        "fires": r.fires.map { "\($0.part + 1) at \(String(format: "%.1f", $0.t)) s (\($0.how)) “\($0.heard)”" },
                        "misses": r.misses.map { "\($0.part + 1) closest: \($0.closest ?? "-")" },
                        "mishearings": r.mishearings.map { "\($0.heard)→\($0.meant) ×\($0.count)" },
                    ] as [String: Any] } ?? [:],
                ] as [String: Any]
                st["outline"] = [
                    "topics": dir.topics.map { "\($0.title) [\($0.points.count) points]\($0.assets.isEmpty ? "" : " assets: " + $0.assets.joined(separator: ","))" },
                    "topic": dir.topicIndex.map { $0 + 1 } ?? 0, "covered": dir.covered.sorted(), "asset": dir.currentAsset ?? "",
                    "assets": (dir.show?.assets ?? []).map { "\($0.file): \($0.about)" },
                    "brainStatus": dir.brainStatus, "lastDecision": dir.lastDecision, "calls": dir.brainCalls, "cost": dir.brainCost,
                    "suggestion": dir.brainSuggestion.map { LiveBrain.describe($0.action) } ?? "",
                    "replay": dir.brainReport.map { r in ["steps": r.steps, "calls": r.calls, "topic": r.topicsReached, "covered": "\(r.covered)/\(r.points)", "problem": r.problem ?? ""] as [String: Any] } ?? [:],
                    "looks": Looks.catalog(studio).map(\.name),
                ] as [String: Any]
                st["controlLink"] = ["running": studio.controlLink.isRunning, "problem": studio.controlLink.problem ?? "", "lastCall": studio.controlLink.lastCall ?? ""]
                st["audio"] = studio.audioSources.map { ["name": $0.name, "inStream": $0.audio?.isInProgram ?? true, "muted": $0.audio?.isMuted ?? false] }
                st["screenPreflight"] = CGPreflightScreenCaptureAccess()
                st["bundlePath"] = Bundle.main.bundlePath
                st["captions"] = studio.captions.dump()
                if let d = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) {
                    try? d.write(to: URL(fileURLWithPath: arg.isEmpty ? "/tmp/framecast-state.json" : arg))
                }
            case "add-display":
                studio.addSource(SourceRecord(name: "Test display", kind: .display(displayID: 0)), toLayout: false)
            case "add-app":
                studio.addSource(SourceRecord(name: "Test app", kind: .application(bundleID: arg, name: arg)), toLayout: false)
            case "add-window":
                // Finds an on-screen window whose title contains the argument.
                Task { @MainActor in
                    let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    if let w = content?.windows.first(where: { ($0.title ?? "").contains(arg) }) {
                        studio.addSource(SourceRecord(name: "Test window", kind: .window(bundleID: w.owningApplication?.bundleIdentifier ?? "", title: w.title ?? "", windowID: w.windowID)), toLayout: false)
                    }
                }
            case "add-sysaudio": studio.addSource(SourceRecord(name: "Test system audio", kind: .systemAudio), toLayout: false)
            case "add-appaudio": studio.addSource(SourceRecord(name: "Test app audio", kind: .appAudio(bundleID: arg, name: arg)), toLayout: false)
            case "remove-named": for src in studio.collection.sources where src.name == arg { studio.removeFromStudio(src.id) }
            case "only-audio":
                // Keeps only the named audio source in the program mix, in the running mixer only: tests must never
                // change what's saved in the user's studio.
                for a in studio.audioSources {
                    var s = a.audio ?? AudioSettings(); s.isInProgram = (a.name == arg)
                    studio.engine.mixer.update(a.id, settings: s)
                }
            case "solo":
                // Shows one source full-frame on both canvases (in memory only; scenes unchanged).
                if let src = studio.collection.sources.first(where: { $0.name == arg }) {
                    for c in CanvasKind.allCases {
                        studio.engine.setProgram([SceneItem(sourceID: src.id, transform: .full, fit: .fit)], for: c, transition: .cut, durationMs: 0)
                    }
                }
            case "quit": NSApp.terminate(nil)
            default: break
            }
        }
    }
}

/// Test launches (FRAMECAST_UI set) with FRAMECAST_FAKE_CAMERA=<clip>: every source that would open a device gets a
/// stand-in from the moment the engine starts, so the camera, the screen and the microphone are never opened. Cameras
/// play the clip on a loop (FRAMECAST_FAKE_CAMERA_4K when 4K is asked for), screens show a drawn editor, and
/// microphones and system or app sound are silent, or, with FRAMECAST_FAKE_MIC=<audio file>, microphones play that
/// file on a loop into the mixer like a voice. Ignored outside test launches.
enum FakeDevices {
    private(set) static var isOn = false
    /// A 4K clip was given: the stand-in cameras "can send 4K" (the real camera is never asked).
    private(set) static var has4K = false

    static func install(on engine: Engine) {
        let env = ProcessInfo.processInfo.environment
        guard DestinationsStore.isTestLaunch, let clip = env["FRAMECAST_FAKE_CAMERA"], !clip.isEmpty else { return }
        let given4K = env["FRAMECAST_FAKE_CAMERA_4K"].flatMap { $0.isEmpty ? nil : $0 }
        let clip4K = given4K ?? clip
        let micFile = env["FRAMECAST_FAKE_MIC"].flatMap { $0.isEmpty ? nil : $0 }
        let mixer = engine.mixer
        isOn = true
        has4K = given4K != nil
        // Every kind is listed, so a new kind of source has to be decided on here.
        engine.standIn = { s in
            switch s.kind {
            case .camera(_, let w, let h, _):
                return .video(FakeCameraSource(id: s.id, path: w >= 3840 ? clip4K : clip, width: w, height: h, mixer: mixer))
            case .display, .window, .application:
                return .video(StaticImageSource(id: s.id, image: DemoContent.screenStandIn()))
            case .microphone:
                return micFile.map { .audio(FakeMicSource(id: s.id, path: $0, mixer: mixer)) } ?? .silent
            case .systemAudio, .appAudio:
                return .silent
            case .image, .color, .wallpaper, .packImage, .countdown, .text, .testPattern, .media, .soundPad, .tone,
                 .guest, .guestScreen, .guestGrid:
                return nil
            }
        }
    }
}

/// A test camera: a clip playing on a loop. It wraps the file player rather than being one, so the engine never
/// treats it as a media file (sync would turn its loop off). Without the clip it shows black: never nothing, so a
/// test can't end up on the real camera.
final class FakeCameraSource: VideoSource {
    let id: UUID
    private let clip: MediaFileSource?
    private let black: CIImage

    init(id: UUID, path: String, width: Int, height: Int, mixer: AudioMixer) {
        self.id = id
        black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: max(16, width), height: max(9, height)))
        if FileManager.default.fileExists(atPath: path) {
            let m = MediaFileSource(id: id, url: URL(fileURLWithPath: path), mixer: mixer)
            m.loop = true
            clip = m
        } else { clip = nil }
    }

    var state: SourceState { clip?.state ?? .running }
    var nativeSize: CGSize { clip?.nativeSize ?? black.extent.size }
    func image(at time: CMTime) -> CIImage? { clip?.image(at: time) ?? black }
    func start() { clip?.start(); clip?.play() }
    func stop() { clip?.stop() }
}

/// A test microphone: an audio file played on a loop (three seconds of quiet between plays, so the last words settle
/// and the captions fade), pushed into the mixer in real time with capture times like a real microphone. An unreadable
/// file is silence: never the real microphone.
final class FakeMicSource: AudioCaptureSource {
    let id: UUID
    let state: SourceState = .running
    let deviceName = "Stand-in (test audio file)"
    private let mixer: AudioMixer
    private let samples: [Float]          // interleaved stereo, 48 kHz
    private let queue = DispatchQueue(label: "framecast.fakemic", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var t0 = 0.0
    private var pushed: Int64 = 0

    init(id: UUID, path: String, mixer: AudioMixer) {
        self.id = id; self.mixer = mixer
        samples = Self.load(path) + [Float](repeating: 0, count: 2 * 3 * 48_000)
    }

    private static func load(_ path: String) -> [Float] {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let all = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: all)) != nil,
              let conv = AVAudioConverter(from: f.processingFormat, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(all.frameLength) * 48_000 / f.processingFormat.sampleRate) + 4_096)
        else { return [] }
        var given = false
        conv.convert(to: out, error: nil) { _, st in
            if given { st.pointee = .endOfStream; return nil }
            given = true; st.pointee = .haveData; return all
        }
        let n = Int(out.frameLength), l = out.floatChannelData![0], r = out.floatChannelData![1]
        var v = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { v[2 * i] = l[i]; v[2 * i + 1] = r[i] }
        return v
    }

    func start() {
        guard timer == nil else { return }
        t0 = HostClock.seconds(); pushed = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }
    func stop() { timer?.cancel(); timer = nil }

    // Pushes everything due up to now, 480 frames (10 ms) at a time, each stamped with when it "was captured".
    private func tick() {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        let due = Int64((HostClock.seconds() - t0) * 48_000)
        var chunk = [Float](repeating: 0, count: 480 * 2)
        while pushed + 480 <= due {
            for i in 0..<480 { let j = Int((pushed + Int64(i)) % Int64(frames)); chunk[2 * i] = samples[2 * j]; chunk[2 * i + 1] = samples[2 * j + 1] }
            let pts = CMTime(seconds: t0 + Double(pushed) / 48_000, preferredTimescale: 1_000_000_000)
            chunk.withUnsafeBufferPointer { mixer.push(id, samples: $0.baseAddress!, frames: 480, pts: pts) }
            pushed += 480
        }
    }
}

/// Sample chat used only for screenshots.
/// It is never shown unless FRAMECAST_UI contains "demo-chat".
enum DemoContent {
    /// A drawn "person" silhouette used instead of the real camera in screenshots.
    static func cameraStandIn() -> CIImage {
        let w = 1280.0, h = 720.0
        var img = CIImage(color: CIColor(red: 0.42, green: 0.33, blue: 0.27)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let g = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: w * 0.35, y: h * 0.8), "inputRadius0": 0, "inputRadius1": w * 0.7,
                                                                "inputColor0": CIColor(red: 0.62, green: 0.50, blue: 0.40), "inputColor1": CIColor(red: 0.22, green: 0.17, blue: 0.14)])!.outputImage!
        img = g.cropped(to: img.extent)
        let body = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: CGRect(x: w * 0.3, y: -h * 0.1, width: w * 0.4, height: h * 0.45)),
                                                                              "inputRadius": h * 0.18, "inputColor": CIColor(red: 0.12, green: 0.13, blue: 0.15)])!.outputImage!
        let head = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: CGRect(x: w * 0.42, y: h * 0.36, width: w * 0.16, height: w * 0.16)),
                                                                              "inputRadius": w * 0.08, "inputColor": CIColor(red: 0.85, green: 0.70, blue: 0.58)])!.outputImage!
        return head.composited(over: body.composited(over: img)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
    /// A drawn code-editor-like screen used instead of the real display in screenshots.
    static func screenStandIn() -> CIImage {
        let w = 1920.0, h = 1080.0
        var img = CIImage(color: CIColor(red: 0.12, green: 0.13, blue: 0.17)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        img = CIImage(color: CIColor(red: 0.09, green: 0.10, blue: 0.13)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: h)).composited(over: img)
        let colors: [CIColor] = [CIColor(red: 0.31, green: 0.82, blue: 0.77), CIColor(red: 0.95, green: 0.66, blue: 0.23), CIColor(red: 0.6, green: 0.6, blue: 0.95), CIColor(red: 0.8, green: 0.8, blue: 0.8)]
        for i in 0..<34 {
            let len = Double((i * 37) % 900 + 200)
            let line = CIImage(color: colors[i % 4]).cropped(to: CGRect(x: 360 + Double((i % 5) * 40), y: h - 80 - Double(i) * 28, width: len, height: 12))
            img = line.composited(over: img)
        }
        return img
    }

    static func chat(into hub: ChatHub) {
        let rows: [(ChatPlatform, String, String)] = [
            (.youtube, "maya.codes", "audio sounds great today"),
            (.twitch, "devon_k", "can you show the config file again?"),
            (.youtube, "priya_builds", "joining from Bengaluru 👋"),
            (.x, "lin.tran", "the 9:16 version looks clean on my phone"),
            (.instagram, "oskar.studio", "what camera are you using?"),
            (.twitch, "nova_streams", "first time here, love the setup"),
            (.youtube, "sam.writes", "will the slides be shared after?"),
            (.instagram, "jules_makes", "saving this for later"),
        ]
        for (i, r) in rows.enumerated() {
            hub.receive(ChatMessage(platform: r.0, user: r.1, text: r.2, date: Date().addingTimeInterval(Double(i - rows.count) * 20)))
        }
    }
}
