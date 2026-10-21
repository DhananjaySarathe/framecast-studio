import SwiftUI
import UniformTypeIdentifiers
import AppKit
import FramecastEngine

// MARK: - Live chat

struct ChatPanel: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let chat = studio.chat!
        VStack(spacing: 0) {
            PanelHeader(title: "Comments", subtitle: "From every destination")
            HStack(spacing: 7) {
                pill("All", on: chat.hiddenPlatforms.isEmpty && chat.kind == .all) { chat.hiddenPlatforms = []; chat.kind = .all }
                ForEach([ChatPlatform.youtube, .twitch, .x, .instagram], id: \.self) { p in
                    Button {
                        if chat.hiddenPlatforms.contains(p) { chat.hiddenPlatforms.remove(p) } else { chat.hiddenPlatforms.insert(p) }
                    } label: { PlatformBadge(platform: p.rawValue, size: 26).opacity(chat.hiddenPlatforms.contains(p) ? 0.35 : 1) }
                        .buttonStyle(.plain).help("Show or hide \(p.rawValue.capitalized) messages")
                }
                Spacer()
                pill("Supporters", on: chat.kind == .paid) { chat.kind = chat.kind == .paid ? .all : .paid }
            }
            .padding(.horizontal, 14).frame(height: 50)
            .overlay(alignment: .bottom) { Hairline() }
            ZStack(alignment: .top) {
                if chat.visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.fc(22)).foregroundStyle(Theme.text4)
                        Text(chat.messages.isEmpty ? "Chat shows up here while you're live on YouTube or Twitch." : "No messages match these filters.")
                            .font(.fc(12.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                        if let s = chat.status { Text(s).font(.fc(11.5)).foregroundStyle(Theme.text4).multilineTextAlignment(.center) }
                    }
                    .padding(28).frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(chat.visible) { m in ChatRow(message: m).id(m.id) }
                            }
                            .padding(.vertical, 14).padding(.horizontal, 12)
                        }
                        .onChange(of: chat.messages.count) { _, _ in
                            if let last = chat.visible.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                }
                LinearGradient(colors: [Theme.panel, Theme.panel.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 30).allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            Composer(text: Binding(get: { chat.draft }, set: { chat.draft = $0 }), placeholder: "Say something…") { chat.send() }
        }
    }
    func pill(_ t: String, on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.fc(11.5, .bold)).foregroundStyle(on ? .white : Theme.text2)
                .padding(.horizontal, 11).frame(height: 28).background(Capsule().fill(on ? Theme.selected : Theme.control2))
        }.buttonStyle(.plain)
    }
}

struct ChatRow: View {
    @Environment(Studio.self) var studio
    let message: ChatMessage
    @Local var hover = false
    var body: some View {
        let onScreen = studio.chatOnScreen == message.id
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(LinearGradient(colors: [Color(hex: avatarColor.0), Color(hex: avatarColor.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    .overlay(Text(String(message.user.prefix(2)).uppercased()).font(.fc(10.5, .bold)).foregroundStyle(.white))
                PlatformBadge(platform: message.platform.rawValue, size: 15, ring: Theme.panel).offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.user).font(.fc(12.5, .bold)).lineLimit(1)
                    if message.role == .you { tag("HOST", Theme.accent, Theme.accentInk) }
                    if message.role == .mod { tag("MOD", Theme.selected, Theme.text) }
                    if let paid = message.paidAmount { tag(paid, Theme.warning, Theme.programWell) }
                    if onScreen { tag("ON SCREEN", .white, Theme.programWell) }
                }
                Text(message.text).font(.fc(13.5)).lineSpacing(3).foregroundStyle(Theme.chatText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(onScreen || hover ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { studio.chat.toggleOnScreen(message) }
        .help(onScreen ? "On stream: click to remove" : "Click to show on stream")
        .contextMenu {
            Button(onScreen ? "Remove from Stream" : "Show on Stream") { studio.chat.toggleOnScreen(message) }
            Button("Copy Message") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
            Button("Reply") { studio.chat.draft = "@\(message.user) " }
        }
    }
    var avatarColor: (UInt32, UInt32) {
        let palette: [(UInt32, UInt32)] = [(0x8B7BFF, 0x5A45F0), (0x6AB8FF, 0x3D6BFF), (0xFFB45C, 0xF0504A), (0xFF8FC7, 0xD9468F), (0x7FE0B8, 0x2FA77A), (0xF5D76E, 0xD9A51E)]
        return palette[abs(message.user.hashValue) % palette.count]
    }
    func tag(_ t: String, _ bg: Color, _ fg: Color) -> some View {
        Text(t).font(.fc(9, .heavy)).tracking(0.36).foregroundStyle(fg).padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(bg))
    }
}

struct Composer: View {
    @Binding var text: String
    var placeholder: String
    var send: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.fc(13.5))
                .padding(.horizontal, 13).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.fieldBorder))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.fc(15, .bold)).foregroundStyle(text.isEmpty ? Theme.text2 : Theme.accentInk)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10).fill(text.isEmpty ? Theme.selected : Theme.accent))
            }.buttonStyle(.plain)
        }
        .padding(.top, 11).padding(.horizontal, 12).padding(.bottom, 14)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Backstage

struct BackstagePanel: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let chat = studio.chat!
        VStack(spacing: 0) {
            PanelHeader(title: "Green room", subtitle: "Private with your guests")
            if chat.backstage.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.fc(22)).foregroundStyle(Theme.text4)
                    Text("Chat privately with your guests here. Viewers never see it.")
                        .font(.fc(12.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                }
                .padding(28).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) { ForEach(chat.backstage) { ChatRow(message: $0) } }
                        .padding(.vertical, 14).padding(.horizontal, 12)
                }.frame(maxHeight: .infinity)
            }
            Composer(text: Binding(get: { chat.backstageDraft }, set: { chat.backstageDraft = $0 }), placeholder: "Message your guests…") { chat.sendBackstage() }
        }
    }
}

// MARK: - Audio

struct AudioPanel: View {
    @Environment(Studio.self) var studio
    @Local var adding = false
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Mixer", subtitle: "Everything you hear on air") {
                Menu {
                    ForEach(MicrophoneSource.devices(), id: \.uniqueID) { d in
                        Button("Microphone: \(d.localizedName)") { studio.addSource(SourceRecord(name: d.localizedName, kind: .microphone(deviceID: d.uniqueID)), toLayout: false) }
                    }
                    Button("Everything your Mac plays") { studio.addSource(SourceRecord(name: "Desktop", kind: .systemAudio), toLayout: false) }
                    Menu("One app's audio") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "App") {
                                studio.addSource(SourceRecord(name: app.localizedName ?? "App", kind: .appAudio(bundleID: app.bundleIdentifier!, name: app.localizedName ?? "")), toLayout: false)
                            }
                        }
                    }
                    Button("Music or sound file…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.audio, .movie]
                        p.message = "Choose music to play under your show (it loops, and lowers while someone talks)."
                        if p.runModal() == .OK, let u = p.url { studio.addMediaFile(u) }
                    }
                    Divider()
                    Button("Test tone (1 kHz beep each second)") { studio.addSource(SourceRecord(name: "Test tone", kind: .tone), toLayout: false) }
                } label: { Label("Add", systemImage: "plus").font(.fc(12, .semibold)) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Adds to the mix, in every scene")
            }
            ScrollView {
                VStack(spacing: 10) {
                    if studio.audioSources.isEmpty {
                        Text("No sound sources yet. Add one with + Add; every scene uses it.").font(.fc(12.5)).foregroundStyle(Theme.text3).padding(20)
                    }
                    ForEach(studio.audioSources) { s in AudioSourceRow(source: s) }
                    SoundPadGrid()
                    MasterRow()
                }
                .padding(12)
            }
        }
    }
}

struct LevelBar: View {
    var level: AudioLevel
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(0.00001, Double(level.peak)))
            let frac = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.control2)
                Capsule().fill(LinearGradient(colors: [Theme.healthy, Theme.healthy, Theme.warning, Theme.live], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width).mask(alignment: .leading) { Capsule().frame(width: g.size.width * frac) }
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.06), value: level.peak)
    }
}

struct AudioSourceRow: View {
    @Environment(Studio.self) var studio
    let source: SourceRecord
    @Local var showDelay = false
    var body: some View {
        let a = source.audio ?? AudioSettings()
        let isMic: Bool = { if case .microphone = source.kind { return true }; return false }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: source.kind.iconName).font(.fc(12, .semibold)).foregroundStyle(Theme.icon).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.fc(12.5, .semibold)).lineLimit(1)
                    Text(detail).font(.fc(10.5)).foregroundStyle(stateColor).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                iconToggle(a.isMonitored ? "headphones" : "headphones", on: a.isMonitored, help: a.isMonitored ? "In your headphones" : "Not in your headphones") {
                    studio.setAudio(source.id) { $0.isMonitored.toggle() }
                }
                iconToggle(a.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: !a.isMuted, danger: a.isMuted, help: a.isMuted ? "Unmute" : "Mute") {
                    studio.setAudio(source.id) { $0.isMuted.toggle() }
                }
            }
            LevelBar(level: studio.levels[source.id] ?? .silent)
            if !a.isInProgram {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.fc(10.5)).foregroundStyle(Theme.warning)
                    Text("Not in the stream: recordings and viewers don't hear it").font(.fc(11)).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Put back in the stream") { studio.setAudio(source.id) { $0.isInProgram = true } }
                        .buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 8) {
                Slider(value: Binding(get: { a.fader }, set: { v in studio.setAudio(source.id) { $0.fader = v } }), in: 0...1)
                    .controlSize(.small).tint(Theme.accent)
                    .help("Volume · double-click for 0 dB")
                    .onTapGesture(count: 2) { studio.setAudio(source.id) { $0.fader = 0.8 } }
                Text(AudioSettings.dbLabel(fader: a.fader)).font(.fc(10.5, .medium).monospacedDigit()).foregroundStyle(Theme.text3).frame(width: 52, alignment: .trailing)
            }
            if case .media = source.kind { MediaControls(source: source) }
            if !isMic && source.kind != .soundPad && a.isVoice != true {
                Toggle("Lower while someone talks", isOn: Binding(get: { a.ducksUnderVoice ?? false }, set: { v in studio.setAudio(source.id) { $0.ducksUnderVoice = v } }))
                    .toggleStyle(.checkbox).font(.fc(11.5))
                    .help("Drops this source by about 12 dB while a microphone or guest is talking, and brings it back after.")
            }
            if isMic && (showDelay || a.delayMs > 0) {
                HStack(spacing: 8) {
                    Text("Mic delay").font(.fc(11)).foregroundStyle(Theme.text2)
                    Slider(value: Binding(get: { a.delayMs }, set: { v in studio.setAudio(source.id) { $0.delayMs = (v / 5).rounded() * 5 } }), in: 0...500)
                        .controlSize(.mini).tint(Theme.accent)
                        .help("Holds your voice back so it matches your lips when the camera lags behind the mic.")
                    Text("\(Int(a.delayMs)) ms").font(.fc(10.5).monospacedDigit()).foregroundStyle(Theme.text3).frame(width: 46, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .contextMenu {
            if isMic {
                Menu("Echo Cancellation") {
                    ForEach(EchoCancellation.allCases, id: \.self) { e in
                        Button((a.echoCancellation == e ? "✓ " : "") + e.rawValue.capitalized + (e == .auto ? " · while guests play on speakers" : "")) {
                            studio.setAudio(source.id) { $0.echoCancellation = e }
                        }
                    }
                }
                Button((a.noiseReduction == true ? "✓ " : "") + "Reduce Background Noise") { studio.setAudio(source.id) { $0.noiseReduction = !($0.noiseReduction ?? false) } }
                Button(showDelay ? "Hide Mic Delay" : "Mic Delay…") { showDelay.toggle() }
            }
            Menu("Recording Track") {
                ForEach(1...6, id: \.self) { t in
                    Button((a.tracks.contains(t) ? "✓ " : "") + (t == 1 ? "Track 1 (program)" : "Track \(t)")) {
                        studio.setAudio(source.id) { if $0.tracks.contains(t) { $0.tracks.remove(t) } else { $0.tracks.insert(t) } }
                    }
                }
            }
            Button(a.isInProgram ? "Leave Out of the Stream" : "Put in the Stream") { studio.setAudio(source.id) { $0.isInProgram.toggle() } }
            Divider()
            Button("Remove from the Mix (Every Scene)", role: .destructive) { studio.removeFromStudio(source.id) }
        }
    }
    var detail: String {
        if case .failed(let m)? = studio.sourceStates[source.id] { return m }
        if case .media(let p) = source.kind {
            let lowered = (source.audio?.ducksUnderVoice ?? false) && studio.duckLevel < 0.9 ? " · lowered for voice" : ""
            return (MediaFileSource.isAudioOnly(p) ? "Music" : "Video") + lowered
        }
        if case .soundPad = source.kind { return "The buttons below" }
        if case .lost(let m)? = studio.sourceStates[source.id] { return m }
        let dev = studio.engine.deviceName(of: source.id) ?? ""
        var bits: [String] = []
        if !dev.isEmpty { bits.append(dev) }
        if source.audio?.echoCancellation == .on || source.audio?.noiseReduction == true { bits.append("Voice processing") }
        return bits.isEmpty ? "Follows your Mac's input" : bits.joined(separator: " · ")
    }
    var stateColor: Color {
        switch studio.sourceStates[source.id] { case .failed?, .lost?: return Theme.warning; default: return Theme.text3 }
    }
    func iconToggle(_ icon: String, on: Bool, danger: Bool = false, help: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: icon).font(.fc(11, .semibold)).foregroundStyle(danger ? Theme.live : (on ? Theme.text : Theme.text4))
                .frame(width: 26, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(on && !danger ? Theme.selected : Theme.control))
        }.buttonStyle(.plain).help(help)
    }
}

struct MasterRow: View {
    @Environment(Studio.self) var studio
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Output").font(.fc(12, .semibold)); Spacer(); Text("Peak limit −1 dB").font(.fc(10.5)).foregroundStyle(Theme.text4) }
            LevelBar(level: studio.masterLevel)
            HStack(spacing: 8) {
                Text("Master").font(.fc(11)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { studio.collection.audio.masterFader }, set: { studio.setMaster($0) }), in: 0...1).controlSize(.small).tint(Theme.accent)
            }
            HStack(spacing: 8) {
                Text("Headphones").font(.fc(11)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { studio.collection.audio.headphoneLevel }, set: { studio.setHeadphoneLevel($0) }), in: 0...1).controlSize(.small).tint(Theme.accent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}
