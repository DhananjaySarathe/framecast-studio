import SwiftUI
import ImageIO
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
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
        settings = AppSettings()
        studio = Studio(settings: settings)
        super.init()
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
    ] + (1...9).map { Binding(id: UInt32(10 + $0), key: [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9][$0 - 1],
                                      mods: controlKey | optionKey, title: "Switch to scene \($0)") }
      + (1...9).map { Binding(id: UInt32(20 + $0), key: [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9][$0 - 1],
                                      mods: optionKey | cmdKey, title: "Show or hide overlay \($0)") }

    func register() {
        Self.shared = self
        let s = studio
        actions[1] = { s.isRecording ? s.stopRecording() : s.startRecording() }
        actions[2] = { s.togglePause() }
        actions[3] = { s.toggleMuteMics() }
        actions[4] = { s.setVertical(!s.isVerticalOn) }
        actions[5] = { s.director.takeSuggestionOrNext() }
        actions[6] = { s.director.undoAuto() }
        for i in 1...9 {
            actions[UInt32(10 + i)] = { if s.scenes.indices.contains(i - 1) { s.switchTo(s.scenes[i - 1].id) } }
            actions[UInt32(20 + i)] = { s.toggleElement(number: i) }
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { GlobalHotkeys.shared?.actions[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
        for b in Self.defaults {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(b.key), UInt32(b.mods), EventHotKeyID(signature: OSType(0x4643_5354), id: b.id),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    static func describe(_ b: Binding) -> String {
        var s = ""
        if b.mods & controlKey != 0 { s += "⌃" }
        if b.mods & optionKey != 0 { s += "⌥" }
        if b.mods & shiftKey != 0 { s += "⇧" }
        if b.mods & cmdKey != 0 { s += "⌘" }
        let keys: [Int: String] = [kVK_ANSI_R: "R", kVK_ANSI_P: "P", kVK_ANSI_M: "M", kVK_ANSI_V: "V", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_1: "1", kVK_ANSI_2: "2",
                                   kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9"]
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
                          let img = studio.engine.snapshot(items: scene.items(for: c), canvas: c, width: c == .horizontal ? 1920 : 1080),
                          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(arg)-\(c.rawValue).png") as CFURL, "public.png" as CFString, 1, nil)
                    else { continue }
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
            case "guests-host-mic-off": studio.guests.shareHostMic = false
            case "guest-reach": if let r = GuestReach(rawValue: arg) { studio.guests.testOverride = true; studio.guests.reach = r }
            case "guest-remote-local-test":
                // The remote-guest protocol against the LiveKit server on this Mac (not saved).
                studio.guests.testOverride = true; studio.guests.reach = .internet; studio.guests.cloud = .localTest
            case "stage-all": for g in studio.guests.guests where g.status == .lobby { studio.guests.bringOnStage(g.id) }
            case "unstage-all": for g in studio.guests.guests where g.status == .stage { studio.guests.takeOffStage(g.id) }
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
                    "backstage": studio.chat.backstage.map { ["user": $0.user, "text": $0.text] },
                    "recording": studio.isRecording, "lastRecordings": studio.lastRecordings.map(\.path),
                    "streamPhase": "\(studio.streaming.phase)", "health": studio.health.text,
                    "streams": studio.streaming.statuses.map { ["id": $0.key.uuidString, "status": "\($0.value)"] },
                    "sources": studio.collection.sources.map { s in ["name": s.name, "state": "\(studio.sourceStates[s.id].map { "\($0)" } ?? "none")"] },
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
