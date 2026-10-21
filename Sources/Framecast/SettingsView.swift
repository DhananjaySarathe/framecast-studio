import SwiftUI
import AppKit
import FramecastEngine

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, video, recording, streaming, ai, hotkeys, streamDeck, remote, camera, account
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"; case .video: "Canvases"; case .recording: "Recording"; case .streaming: "Broadcasting"
        case .ai: "AI"
        case .hotkeys: "Shortcuts"; case .camera: "Extras"; case .account: "Privacy"
        case .streamDeck: "Stream Deck"; case .remote: "Remote"
        }
    }
    /// What the sidebar lists. Stream Deck, Remote and Virtual camera notes live together under Extras.
    static let shown: [SettingsPane] = [.general, .video, .recording, .streaming, .ai, .hotkeys, .camera, .account]
    var icon: String {
        switch self {
        case .general: "gearshape"; case .video: "rectangle.on.rectangle"; case .recording: "record.circle"; case .streaming: "dot.radiowaves.left.and.right"
        case .ai: "sparkles"
        case .hotkeys: "keyboard"; case .streamDeck: "square.grid.3x2"; case .remote: "iphone"; case .camera: "video"; case .account: "person.crop.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(Studio.self) var studio
    @Local var pane: SettingsPane = .general
    @Local var search = ""
    var body: some View {
        content
            .onAppear { if let p = studio.testSettingsPane.flatMap(SettingsPane.init(rawValue:)) { pane = p } }
            .onChange(of: studio.testSettingsPane) { _, p in if let p = p.flatMap(SettingsPane.init(rawValue:)) { pane = p } }
    }
    @ViewBuilder var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Search settings", text: $search).textFieldStyle(.roundedBorder).padding(.bottom, 8)
                ForEach(SettingsPane.shown.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { p in
                    Button { pane = p } label: {
                        Label(p.title, systemImage: p.icon).font(.fc(12.5, .semibold)).foregroundStyle(pane == p ? Theme.text : Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(pane == p ? Theme.selected : .clear))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Framecast \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
            .padding(12).frame(width: 200).background(Theme.rail)
            Hairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(pane.title).font(.fc(18, .bold))
                    switch pane {
                    case .general: GeneralPane()
                    case .video: VideoPane()
                    case .recording: RecordingPane()
                    case .streaming: StreamingPane()
                    case .ai: AIPane()
                    case .hotkeys: HotkeysPane()
                    case .streamDeck: GapPane(title: "Stream Deck", text: "Framecast v1 doesn't include an Elgato Stream Deck plugin. Every action has a global keyboard shortcut instead (Hotkeys), which Stream Deck's built-in Hotkey action can trigger.")
                    case .remote: GapPane(title: "Remote", text: "Framecast v1 has no iPhone/iPad app for controlling the studio. Use global hotkeys, or the scriptable test hooks described in README.md.")
                    case .camera:
                        GapPane(title: "Virtual camera", text: "A virtual camera would let Zoom, Meet and FaceTime use your canvas. It needs a camera system extension, which has to be signed with a paid Apple Developer account and notarized, so this version doesn't include one.")
                        GapPane(title: "Stream Deck", text: "There's no Stream Deck plugin yet. Every action has a global shortcut (Settings › Shortcuts), which Stream Deck's Hotkey action can press.")
                        GapPane(title: "Phone remote", text: "There's no iPhone or iPad remote yet. Global shortcuts work from any app on this Mac.")
                    case .account: AccountPane()
                    }
                }
                .padding(24).frame(maxWidth: 640, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 880, height: 620)
        .background(Theme.panel)
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
            if let footer { Text(footer).font(.fc(11)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SettingRow<Content: View>: View {
    var title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.fc(12.5, .semibold))
                if let detail { Text(detail).font(.fc(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            content
        }
    }
}

struct GeneralPane: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    var body: some View {
        @Bindable var st = settings
        SettingsGroup(title: "During a show") {
            SettingRow(title: "Keep the screen on", detail: "No screen sleep or screen saver while you broadcast or record. The Mac itself never sleeps during a show.") {
                Toggle("", isOn: $st.s.keepsDisplayAwake).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: "Confirm before ending a broadcast") { Toggle("", isOn: $st.s.confirmsEndStream).toggleStyle(.switch).labelsHidden() }
            SettingRow(title: "Confirm before quitting", detail: "Only during a broadcast or recording. Recordings are always saved before Framecast quits.") {
                Toggle("", isOn: $st.s.confirmsQuit).toggleStyle(.switch).labelsHidden()
            }
        }
        SettingsGroup(title: "Studio") {
            SettingRow(title: "Preview quality", detail: "Lower it to save GPU power on long shows. Broadcasts and recordings stay the same.") {
                Picker("", selection: Binding(get: { settings.s.previewQuality }, set: { settings.s.previewQuality = $0; studio.applyCanvases() })) {
                    ForEach(PreviewQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            SettingRow(title: "Show Framecast in screen shares",
                       detail: "For demoing Framecast itself: a captured display then includes Framecast's windows (with the usual picture-in-picture tunnel). The presenter view always stays hidden.") {
                Toggle("", isOn: Binding(get: { settings.s.showsOwnWindows ?? false }, set: { v in
                    settings.s.showsOwnWindows = v
                    ScreenSource.showsOwnWindows = v
                    studio.engine.refreshScreenFilters()
                })).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: "Scene transition") {
                Picker("", selection: $st.s.transition) { ForEach(TransitionKind.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 110)
                Stepper("\(settings.s.transitionMs) ms", value: $st.s.transitionMs, in: 100...2000, step: 50).font(.fc(12)).disabled(settings.s.transition == .cut)
            }
        }
        SettingsGroup(title: "Updates", footer: "Framecast is a local build: it never checks for updates and has no update server.") {
            SettingRow(title: "This build doesn't check for updates.") { EmptyView() }
        }
    }
}

struct VideoPane: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    var body: some View {
        SettingsGroup(title: "16:9 canvas", footer: "Changes apply right away. Scenes rescale to fit.") {
            CanvasEditor(kind: .horizontal)
        }
        SettingsGroup(title: "9:16 canvas", footer: "For Shorts, TikTok and Reels. Both canvases share the same sound; each has its own scene arrangement.") {
            SettingRow(title: "Use the 9:16 canvas", detail: settings.s.isVerticalOn ? "Broadcasts and recordings can use 9:16 too." : "Turn it on to broadcast and record 9:16 as well.") {
                Toggle("", isOn: Binding(get: { settings.s.isVerticalOn }, set: { studio.setVertical($0) })).toggleStyle(.switch).labelsHidden()
            }
            if settings.s.isVerticalOn { CanvasEditor(kind: .vertical) }
        }
        SettingsGroup(title: "Performance") {
            let h = settings.s.horizontal, v = settings.s.vertical
            let load = Double(h.width * h.height * h.fps + (settings.s.isVerticalOn ? v.width * v.height * v.fps : 0)) / Double(1920 * 1080 * 60)
            SettingRow(title: load < 1.2 ? "Light" : (load < 2.5 ? "Moderate" : "Heavy"),
                       detail: load < 2.5 ? "Plenty of headroom for effects, guests and long shows." : "Fine on Apple silicon. Watch for dropped frames with many guests.") {
                Text(String(format: "%.0f%%", min(100, load / 4 * 100))).font(.fc(12, .semibold).monospacedDigit()).foregroundStyle(Theme.text2)
            }
        }
    }
}

struct CanvasEditor: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    let kind: CanvasKind
    var body: some View {
        let c = settings.canvas(kind)
        let blocked = studio.isRecording || studio.streaming.isLive
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Size") {
                Picker("", selection: Binding(get: { c.size }, set: { p in update { $0.apply(p, vertical: kind == .vertical) } })) {
                    ForEach(CanvasSizePreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            if c.size == .custom {
                HStack {
                    Text("Width").font(.fc(11.5)).foregroundStyle(Theme.text2)
                    TextField("", value: Binding(get: { c.width }, set: { v in update { $0.width = Self.clampEven(v) } }), format: .number).frame(width: 70)
                    Text("Height").font(.fc(11.5)).foregroundStyle(Theme.text2)
                    TextField("", value: Binding(get: { c.height }, set: { v in update { $0.height = Self.clampEven(v) } }), format: .number).frame(width: 70)
                    Text("Use even numbers; video encoders need them. 320–7680 px.").font(.fc(10.5)).foregroundStyle(Theme.text4)
                }
            }
            SettingRow(title: "Frame rate") {
                Picker("", selection: Binding(get: { c.fps }, set: { v in update { $0.fps = v } })) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            Text("\(c.width) × \(c.height) at \(c.fps) fps").font(.fc(11)).foregroundStyle(Theme.text3)
            if blocked { Text("Stop recording and end the broadcast to change the canvas.").font(.fc(11)).foregroundStyle(Theme.warning) }
        }
        .disabled(blocked)
    }
    static func clampEven(_ v: Int) -> Int { min(7680, max(320, v)) & ~1 }
    func update(_ f: (inout CanvasSetting) -> Void) {
        if kind == .horizontal { f(&settings.s.horizontal) } else { f(&settings.s.vertical) }
        studio.applyCanvases()
    }
}

struct RecordingPane: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    var body: some View {
        @Bindable var st = settings
        SettingsGroup(title: "What to record", footer: "Framecast records the canvases shown at the top of the window: 16:9, 9:16 or both. With both, each file name ends in its format.") {
            SettingRow(title: "Canvases") {
                Picker("", selection: Binding(get: { studio.stage }, set: { studio.stage = $0 })) {
                    ForEach(StageCanvases.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260).disabled(studio.isRecording)
            }
            SettingRow(title: "Record every broadcast") { Toggle("", isOn: $st.s.recordsWhenLive).toggleStyle(.switch).labelsHidden() }
        }
        SettingsGroup(title: "Format") {
            ForEach(CanvasKind.allCases, id: \.self) { k in
                SettingRow(title: "\(k.title) container", detail: settings.container(k).detail) {
                    Picker("", selection: Binding(get: { settings.container(k) }, set: { v in if k == .horizontal { settings.s.containerH = v } else { settings.s.containerV = v } })) {
                        ForEach(ContainerFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
            }
        }
        SettingsGroup(title: "Quality", footer: "Recordings use each canvas’s size and frame rate from Canvases.") {
            SettingRow(title: "Preset") {
                Picker("", selection: $st.s.preset) { ForEach(RecordingPreset.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if settings.s.preset == .custom {
                SettingRow(title: "Codec") {
                    Picker("", selection: $st.s.customCodec) { ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
                SettingRow(title: "16:9 bitrate", detail: "Mbps · higher is sharper") {
                    Stepper("\(settings.s.customKbpsH / 1000) Mbps", value: $st.s.customKbpsH, in: 2_000...100_000, step: 1_000).font(.fc(12))
                }
                SettingRow(title: "9:16 bitrate") {
                    Stepper("\(settings.s.customKbpsV / 1000) Mbps", value: $st.s.customKbpsV, in: 2_000...100_000, step: 1_000).font(.fc(12))
                }
            }
            ForEach(CanvasKind.allCases, id: \.self) { k in
                let (codec, kbps) = settings.quality(k)
                Text("\(k.title): \(codec.title) · \(String(format: "%.1f", Double(kbps) / 1000)) Mbps · uses about \(String(format: "%.1f", settings.gbPerHour(k))) GB an hour")
                    .font(.fc(11)).foregroundStyle(Theme.text3)
            }
        }
        SettingsGroup(title: "Folders", footer: "Record to more than one place at once, including a NAS or network drive.") {
            ForEach(settings.s.folders) { f in
                HStack {
                    Toggle("", isOn: Binding(get: { f.isEnabled }, set: { v in if let i = settings.s.folders.firstIndex(of: f) { settings.s.folders[i].isEnabled = v } })).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text((f.path as NSString).abbreviatingWithTildeInPath).font(.fc(12, .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(freeSpace(f.path)).font(.fc(10.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }.buttonStyle(.plain).font(.fc(11.5, .semibold)).foregroundStyle(Theme.accent)
                    if settings.s.folders.count > 1 { Button("Remove") { settings.s.folders.removeAll { $0.id == f.id } }.buttonStyle(.plain).font(.fc(11.5)).foregroundStyle(Theme.text3) }
                }
            }
            PillButton(title: "Add Folder…", systemImage: "plus") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                if p.runModal() == .OK, let u = p.url { settings.s.folders.append(RecordingFolder(path: u.path)) }
            }
        }
        SettingsGroup(title: "Files") {
            SettingRow(title: "Start a new file every", detail: "Off keeps one file per recording.") {
                Picker("", selection: $st.s.splitMinutes) { Text("Off").tag(0); Text("15 min").tag(15); Text("30 min").tag(30); Text("60 min").tag(60) }
                    .labelsHidden().frame(width: 110)
            }
            SettingRow(title: "File name", detail: "Example: \(RecordingFileName.base(tags: settings.s.nameTags, canvas: .horizontal, addsCanvas: studio.stage == .both, show: studio.sessionName, layout: "Screen + cam")).mov") {
                HStack(spacing: 4) {
                    ForEach(NameTag.allCases.filter { $0 != .canvas }, id: \.self) { t in
                        let on = settings.s.nameTags.contains(t)
                        Button(t.title) { if on { settings.s.nameTags.removeAll { $0 == t } } else { settings.s.nameTags.append(t) } }
                            .buttonStyle(.plain).font(.fc(11, .semibold)).padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().fill(on ? Theme.accentFill : Theme.selected)).foregroundStyle(on ? Theme.accent : Theme.text2)
                    }
                }
            }
            SettingRow(title: "Show name") { TextField("Optional, added to file names", text: Binding(get: { studio.sessionName }, set: { studio.sessionName = $0 })).frame(width: 200) }
            SettingRow(title: "Separate audio tracks", detail: "Track 1 is the full mix; send sources to tracks 2–6 from the Mixer's right-click menu.") {
                Toggle("", isOn: $st.s.separateTracks).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: "Alert me when the disk is nearly full") { Toggle("", isOn: $st.s.warnsLowSpace).toggleStyle(.switch).labelsHidden() }
        }
    }
    func freeSpace(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]),
              let cap = v.volumeAvailableCapacityForImportantUsage else { return "Missing" }
        return "\(v.volumeName ?? "Disk") · \(ByteCountFormatter.string(fromByteCount: cap, countStyle: .file)) free"
    }
}

struct StreamingPane: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    var body: some View {
        @Bindable var st = settings
        SettingsGroup(title: "Encoders", footer: "Each destination gets its own hardware encoder. The other options are saved for a later version.") {
            ForEach(EncoderSharing.allCases, id: \.self) { e in
                HStack(alignment: .top) {
                    Image(systemName: settings.s.encoderSharing == e ? "largecircle.fill.circle" : "circle").foregroundStyle(settings.s.encoderSharing == e ? Theme.accent : Theme.text3)
                    VStack(alignment: .leading, spacing: 2) { Text(e.title).font(.fc(12.5, .semibold)); Text(e.detail).font(.fc(11)).foregroundStyle(Theme.text3) }
                }
                .contentShape(Rectangle()).onTapGesture { settings.s.encoderSharing = e }
            }
        }
        SettingsGroup(title: "Destinations") {
            SettingRow(title: "\(studio.streaming.destinations.items.count) saved", detail: "Add, edit or remove where you broadcast") {
                PillButton(title: "Open Destinations") { studio.tab = .destinations; NSApp.keyWindow?.close() }
            }
        }
    }
}

struct HotkeysPane: View {
    var body: some View {
        SettingsGroup(title: "Global shortcuts", footer: "These work while another app is focused. They use macOS hot keys, so no Accessibility permission is needed.") {
            ForEach(GlobalHotkeys.defaults, id: \.id) { b in
                HStack { Text(b.title).font(.fc(12.5)); Spacer(); Text(GlobalHotkeys.describe(b)).font(.fc(12, .semibold).monospaced()).foregroundStyle(Theme.text2) }
            }
        }
        SettingsGroup(title: "In the app") {
            ForEach([("Start or stop recording", "⇧⌘R"), ("Pause or resume recording", "⇧⌘P"), ("Start or end broadcast", "⇧⌘L"), ("Mute microphones", "⇧⌘M"),
                     ("Switch to scene 1–9", "⌃1–9"), ("Comments", "⌥⌘C"), ("Back to the studio", "⌘1"), ("Destinations", "⌘2")], id: \.0) { r in
                HStack { Text(r.0).font(.fc(12.5)); Spacer(); Text(r.1).font(.fc(12, .semibold).monospaced()).foregroundStyle(Theme.text2) }
            }
        }
    }
}

struct GapPane: View {
    var title: String
    var text: String
    var body: some View {
        SettingsGroup(title: "Not in this version") {
            Text(text).font(.fc(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AccountPane: View {
    var body: some View {
        SettingsGroup(title: "No account needed") {
            Text("There is no sign-in, subscription or paywall. Every feature is available.").font(.fc(12.5)).fixedSize(horizontal: false, vertical: true)
        }
        SettingsGroup(title: "Privacy") {
            Text("No analytics, crash reports or update checks. Your camera, screen and sound stay on this Mac and only leave for the destinations you broadcast to. Following your voice for the rundown happens on this Mac too. A script leaves only when you click Write it for me, and goes to the AI service you chose in Settings › AI. Stream keys and API keys are stored in your Keychain.")
                .font(.fc(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
