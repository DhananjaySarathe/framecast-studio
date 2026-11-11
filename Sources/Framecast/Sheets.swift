import SwiftUI
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import ImageIO
import FramecastEngine

// MARK: - Add source

enum SourceCategory: String, CaseIterable { case displays, windows, cameras, audio, guests, media, graphics, pack
    var title: String {
        switch self {
        case .displays: "Screens"
        case .windows: "Windows & apps"
        case .cameras: "Cameras"
        case .audio: "Sound"
        case .guests: "Guests"
        case .media: "Pictures"
        case .graphics: "Text & shapes"
        case .pack: "Creator pack"
        }
    }
    var icon: String {
        switch self { case .displays: "display"; case .windows: "macwindow"; case .cameras: "camera"; case .audio: "waveform"
        case .guests: "person.2"; case .media: "photo"; case .graphics: "textformat"; case .pack: "sparkles.rectangle.stack" }
    }
}

struct SourceCard: Identifiable {
    let id: String
    let name: String
    let detail: String
    let record: SourceRecord
    var preview: CGImage? = nil
    var icon: String
    /// Cards that build a whole layout instead of adding one source.
    var action: (() -> Void)? = nil
}

struct AddSourceSheet: View {
    @Environment(Studio.self) var studio
    @Environment(\.dismiss) var dismiss
    @Local var category: SourceCategory = .cameras
    @Local var cards: [SourceCard] = []
    @Local var search = ""
    @Local var problem: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to scene").font(.fc(15, .bold))
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Hairline()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SourceCategory.allCases, id: \.self) { c in
                        Button { category = c } label: {
                            Label(c.title, systemImage: c.icon).font(.fc(12.5, .semibold)).foregroundStyle(category == c ? Theme.text : Theme.text2)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(category == c ? Theme.selected : .clear))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(10).frame(width: 170)
                Hairline(vertical: true)
                ScrollView {
                    if let problem { Text(problem).font(.fc(12)).foregroundStyle(Theme.warning).padding(.top, 12) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(cards.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { c in
                            Button { pick(c) } label: { card(c) }.buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    if cards.isEmpty && problem == nil { Text("Nothing of this kind yet.").font(.fc(12)).foregroundStyle(Theme.text3).padding(30) }
                }
            }
        }
        .frame(width: 760, height: 520)
        .background(Theme.panel)
        .task(id: category) { await load() }
        .onAppear { if let c = studio.testAddSourceCategory.flatMap(SourceCategory.init(rawValue:)) { category = c } }
        .onChange(of: studio.testAddSheetPick?.serial) { _, _ in
            if let id = studio.testAddSheetPick?.id, let c = cards.first(where: { $0.id == id }) { pick(c) }
        }
    }
    func pick(_ c: SourceCard) {
        if let action = c.action {
            action()
        } else if c.id == "media" {
            let p = NSOpenPanel(); p.allowedContentTypes = [.movie, .audio]
            p.message = "Choose a video (shown as a layer) or a music file (added to the mix)."
            guard p.runModal() == .OK, let u = p.url else { return }
            studio.addMediaFile(u)
        } else if c.id == "img" {
            let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.message = "Choose a picture (logo, overlay, background)."
            guard p.runModal() == .OK, let u = p.url else { return }
            studio.addSource(SourceRecord(name: u.deletingPathExtension().lastPathComponent, kind: .image(path: u.path)))
        } else {
            studio.addSource(c.record)
        }
        dismiss()
    }
    func card(_ c: SourceCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.programWell)
                if let img = c.preview { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                else { Image(systemName: c.icon).font(.fc(26)).foregroundStyle(Theme.text4) }
            }
            .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(c.name).font(.fc(12.5, .semibold)).lineLimit(1)
            Text(c.detail).font(.fc(11)).foregroundStyle(Theme.text3).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .contentShape(Rectangle())
    }

    @MainActor func load() async {
        problem = nil
        var out: [SourceCard] = []
        switch category {
        case .cameras:
            for d in CameraSource.devices() {
                out.append(SourceCard(id: d.uniqueID, name: d.localizedName, detail: d.modelID,
                                      record: SourceRecord(name: d.localizedName, kind: .camera(deviceID: d.uniqueID, width: 1920, height: 1080, fps: 30)), icon: "camera"))
            }
            if out.isEmpty { problem = "No cameras found. Connect one, or use Continuity Camera with your iPhone." }
        case .displays, .windows:
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                // A test launch with stand-in devices never takes a picture of the real screen: icons instead.
                if category == .displays {
                    for (i, d) in content.displays.enumerated() {
                        let img = FakeDevices.isOn ? nil : (try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []),
                                                                                configuration: thumbConfig(d.width, d.height)))
                        out.append(SourceCard(id: "d\(d.displayID)", name: "Display \(i + 1)", detail: "\(d.width) × \(d.height)",
                                              record: SourceRecord(name: "Display \(i + 1)", kind: .display(displayID: d.displayID)), preview: img, icon: "display"))
                    }
                    for app in content.applications.filter({ !$0.applicationName.isEmpty && $0.bundleIdentifier != Bundle.main.bundleIdentifier }).prefix(30) {
                        out.append(SourceCard(id: "a\(app.bundleIdentifier)", name: app.applicationName, detail: "Every window of the app",
                                              record: SourceRecord(name: app.applicationName, kind: .application(bundleID: app.bundleIdentifier, name: app.applicationName)), icon: "app.dashed"))
                    }
                } else {
                    for w in content.windows.filter({ ($0.title ?? "").count > 0 && $0.frame.width > 120 && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }).prefix(40) {
                        let img = FakeDevices.isOn ? nil : (try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                                configuration: thumbConfig(Int(w.frame.width), Int(w.frame.height))))
                        let app = w.owningApplication?.applicationName ?? "App"
                        out.append(SourceCard(id: "w\(w.windowID)", name: w.title ?? app, detail: app,
                                              record: SourceRecord(name: "\(app) window", kind: .window(bundleID: w.owningApplication?.bundleIdentifier ?? "", title: w.title ?? "", windowID: w.windowID)),
                                              preview: img, icon: "macwindow"))
                    }
                }
            } catch {
                problem = "Framecast needs Screen Recording access to show screens, windows and apps. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen this sheet."
            }
        case .audio:
            for d in MicrophoneSource.devices() {
                out.append(SourceCard(id: d.uniqueID, name: d.localizedName, detail: "Microphone", record: SourceRecord(name: d.localizedName, kind: .microphone(deviceID: d.uniqueID)), icon: "mic"))
            }
            out.append(SourceCard(id: "sys", name: "Desktop audio", detail: "Everything your Mac plays", record: SourceRecord(name: "Desktop", kind: .systemAudio), icon: "speaker.wave.2"))
            out.append(SourceCard(id: "tone", name: "Test tone", detail: "1 kHz beep every second", record: SourceRecord(name: "Test tone", kind: .tone), icon: "waveform"))
        case .guests:
            for i in 1...4 {
                out.append(SourceCard(id: "g\(i)", name: "Guest \(i)", detail: "Whoever is guest \(i)", record: SourceRecord(name: "Guest \(i)", kind: .guest(slot: i)), icon: "person.fill"))
            }
            out.append(SourceCard(id: "gs", name: "Guest screen", detail: "Shows when a guest shares their screen", record: SourceRecord(name: "Guest screen", kind: .guestScreen(slot: 1)), icon: "rectangle.on.rectangle"))
        case .media:
            out.append(backgroundsCard())
            out.append(SourceCard(id: "img", name: "Image…", detail: "Logo, overlay, background", record: SourceRecord(name: "Image", kind: .image(path: "")), icon: "photo"))
            out.append(SourceCard(id: "media", name: "Video or music…", detail: "Intro clip, b-roll or background music", record: SourceRecord(name: "Media", kind: .media(path: "")), icon: "film"))
        case .pack:
            guard let pack = AssetPack.creator else {
                problem = "The creator asset pack isn't in this build of Framecast."
                break
            }
            func preview(_ a: AssetPack.Asset) -> CGImage? {
                guard let u = pack.previewURL(a), let s = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(s, 0, nil)
            }
            for a in pack.assets(in: "stream-scenes") + pack.assets(in: "frames") {
                guard let info = Studio.packLayoutInfo(a) else { continue }
                let detail = a.category == "frames" ? "Scene: camera in the frame" : "Scene with text and countdown"
                out.append(SourceCard(id: a.id, name: info.name, detail: detail, record: SourceRecord(name: info.name, kind: .packImage(a.id)),
                                      preview: preview(a), icon: "rectangle.3.group", action: { [studio] in studio.addPackLayout(a.id) }))
            }
            out.append(backgroundsCard())
            // Step markers are blank badges that need a number drawn on them; they stay in the pack for now.
            for a in pack.assets(in: "annotations") where !a.id.contains("-step-") {
                out.append(SourceCard(id: a.id, name: a.name, detail: "Annotation", record: SourceRecord(name: a.name, kind: .packImage(a.id)),
                                      preview: preview(a), icon: "arrow.up.right"))
            }
        case .graphics:
            out.append(SourceCard(id: "text", name: "Text", detail: "Big centered title", record: SourceRecord(name: "Text", kind: .text(TextStyle(text: "Your text here"))), icon: "textformat"))
            out.append(SourceCard(id: "lower", name: "Lower third", detail: "Name + title", record: SourceRecord(name: "Lower third", kind: .text(TextStyle(text: "Your name · what you're making today", fontSize: 44, color: RGBA(0.06, 0.08, 0.09), background: RGBA(0.30, 0.82, 0.77)))), icon: "text.below.photo"))
            out.append(SourceCard(id: "color", name: "Color block", detail: "Solid colour", record: SourceRecord(name: "Color block", kind: .color(RGBA(0.12, 0.14, 0.18))), icon: "square.fill"))
            out.append(SourceCard(id: "bars", name: "Color bars", detail: "Test pattern with a flash each second", record: SourceRecord(name: "Test pattern", kind: .testPattern), icon: "chart.bar.fill"))
        }
        if category == .media, let i = out.firstIndex(where: { $0.id == "img" }) {
            // The image card opens a file picker before it's added.
            out[i] = SourceCard(id: "img", name: "Image…", detail: "Choose a picture (logo, overlay, background).", record: out[i].record, icon: "photo")
        }
        cards = out
    }
    /// Opens the background picker (every background, grouped, with 16:9 and 9:16 previews).
    func backgroundsCard() -> SourceCard {
        let sample = BackgroundCatalog.choice("pack:fc-v1-bg-mesh-indigo-current") ?? BackgroundCatalog.all.first
        let preview = sample?.previews[.horizontal].flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        return SourceCard(id: "backgrounds", name: "Backgrounds…", detail: "\(BackgroundCatalog.all.count) backgrounds, 16:9 and 9:16",
                          record: SourceRecord(name: "Background", kind: .wallpaper("midnight")), preview: preview, icon: "photo.on.rectangle",
                          action: { [studio] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { studio.backgroundTarget = .scene } })
    }
    func thumbConfig(_ w: Int, _ h: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration(); let k = 320.0 / Double(max(w, h)); c.width = max(2, Int(Double(w) * k)); c.height = max(2, Int(Double(h) * k)); return c
    }
}

// MARK: - Go live

struct GoLiveSheet: View {
    @Environment(Studio.self) var studio
    @Environment(\.dismiss) var dismiss
    @Local var recordToo = true
    var body: some View {
        let store = studio.streaming.destinations
        VStack(alignment: .leading, spacing: 16) {
            Text("Start a broadcast").font(.fc(17, .bold))
            Text("Choose where this broadcast goes.").font(.fc(12.5)).foregroundStyle(Theme.text2)
            if store.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a destination first: paste a stream key for YouTube, Twitch, X or Instagram, or add a custom RTMP server.")
                        .font(.fc(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Set up destinations", prominent: true) { dismiss(); studio.tab = .destinations }
                }
            }
            ForEach(store.items) { d in
                HStack(spacing: 10) {
                    PlatformBadge(platform: d.platform.rawValue, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.fc(13, .semibold))
                        let (w, h, f) = studio.streaming.size(for: d)
                        Text("\(d.canvas.title) · \(w)×\(h) · \(f) fps · \(String(format: "%.1f", Double(d.videoKbps) / 1000)) Mbps")
                            .font(.fc(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { d.isOn }, set: { v in if let i = store.items.firstIndex(where: { $0.id == d.id }) { store.items[i].isOn = v } }))
                        .toggleStyle(.switch).labelsHidden()
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
            }
            Toggle("Also record on this Mac", isOn: $recordToo).toggleStyle(.checkbox).font(.fc(12.5))
            GoLiveMovesNote()
            if let e = studio.streaming.lastError { Text(e).font(.fc(12)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(studio.streaming.enabled.isEmpty ? "Turn on at least one destination." : "Your destinations start receiving the broadcast right away.")
                    .font(.fc(11.5)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Pre-flight check…") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [studio] in studio.showsPreflight = true }
                }
                .help("Check sound, cameras, destinations and space before you start (⇧⌘K)")
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start broadcast") { studio.streaming.goLive(recordToo: recordToo); if studio.streaming.lastError == nil { dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(studio.streaming.enabled.isEmpty)
            }
        }
        .padding(22).frame(width: 520)
        .background(Theme.panel)
    }
}

// MARK: - Session summary

struct SessionSummaryView: View {
    @Environment(Studio.self) var studio
    @Environment(\.dismiss) var dismiss
    let summary: SessionSummary
    @Local var chapters: String?
    @Local var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show recap").font(.fc(17, .bold))
                    Text("\(summary.title) · \(summary.started.formatted(date: .abbreviated, time: .shortened)) – \(summary.ended.formatted(date: .omitted, time: .shortened))")
                        .font(.fc(12)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Text(formatClock(summary.ended.timeIntervalSince(summary.started))).font(.fc(20, .bold).monospacedDigit())
            }
            HStack(spacing: 12) {
                kpi("Recordings", "\(summary.recordings.count)")
                kpi("Streams", "\(summary.streams.count)")
                kpi("Dropped frames", "\(summary.droppedFrames)")
            }
            if !summary.streams.isEmpty {
                SectionLabel(text: "Broadcasts")
                ForEach(Array(summary.streams.enumerated()), id: \.offset) { _, s in
                    HStack { Text(s.name).font(.fc(12.5, .semibold)); Spacer()
                        Text("Up \(s.uptime) · \(s.bitrate) · \(s.dropped) dropped · \(s.reconnects) reconnects").font(.fc(11.5)).foregroundStyle(s.reconnects > 0 ? Theme.warning : Theme.text3) }
                }
            }
            if !summary.recordings.isEmpty {
                SectionLabel(text: "Recordings")
                ForEach(summary.recordings, id: \.self) { u in
                    HStack {
                        Image(systemName: "film").foregroundStyle(Theme.icon)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.lastPathComponent).font(.fc(12.5, .semibold))
                            Text(meta(u)).font(.fc(11)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.fc(12, .semibold))
                    }
                }
            }
            if !summary.chapters.isEmpty {
                HStack {
                    SectionLabel(text: "Chapters")
                    Spacer()
                    Text(chapterCount < 3 ? "YouTube needs at least three chapters, 10 s or longer" : "Paste into your YouTube description")
                        .font(.fc(11)).foregroundStyle(Theme.text4)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chapters ?? summary.chapters, forType: .string); copied = true
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.fc(12, .semibold))
                }
                TextEditor(text: Binding(get: { chapters ?? summary.chapters }, set: { chapters = $0; copied = false }))
                    .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: min(160, CGFloat(summary.chapters.split(separator: "\n").count) * 18 + 24))
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.fieldBorder))
            }
            if !summary.clips.isEmpty {
                SectionLabel(text: "Clips")
                ForEach(summary.clips, id: \.self) { u in
                    HStack {
                        Image(systemName: "scissors").foregroundStyle(Theme.icon)
                        Text(u.lastPathComponent).font(.fc(12.5, .semibold)).lineLimit(1)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.fc(12, .semibold))
                    }
                }
            }
            HStack {
                Button("Export report") { export() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 600)
        .background(Theme.panel)
    }
    var chapterCount: Int { (chapters ?? summary.chapters).split(separator: "\n").count }
    func kpi(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(v).font(.fc(18, .bold)); Text(l).font(.fc(11)).foregroundStyle(Theme.text3) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
    }
    func meta(_ u: URL) -> String {
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0 ?? 0), countStyle: .file) } ?? ""
        return "\(u.deletingLastPathComponent().path) · \(size)"
    }
    func export() {
        struct Report: Codable { var title: String; var started: Date; var ended: Date; var recordings: [String]; var streams: [SessionSummary.StreamReport]; var droppedFrames: Int }
        let r = Report(title: summary.title, started: summary.started, ended: summary.ended, recordings: summary.recordings.map(\.path), streams: summary.streams, droppedFrames: summary.droppedFrames)
        let p = NSSavePanel(); p.nameFieldStringValue = "Session Report.json"
        if p.runModal() == .OK, let u = p.url {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]; e.dateEncodingStrategy = .iso8601
            try? e.encode(r).write(to: u)
        }
    }
}
