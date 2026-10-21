import SwiftUI
import AppKit
import FramecastEngine

struct DestinationsView: View {
    @Environment(Studio.self) var studio
    @Local var editing: UUID?
    var body: some View {
        let store = studio.streaming.destinations
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Destinations").font(.fc(22, .bold))
                        Text("Where your broadcast goes. Stream keys are kept in your Mac's Keychain.").font(.fc(12.5)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Button("Done") { studio.tab = .studio }.keyboardShortcut(.defaultAction)
                }
                if !store.items.isEmpty {
                    SectionLabel(text: "Your destinations")
                    ForEach(store.items) { d in DestinationRow(destination: d, editing: $editing) }
                }
                SectionLabel(text: "Add one")
                AddDestinationForm(compact: false)
                SettingsGroup(title: "Comments from YouTube and Twitch (optional)", footer: "Sign-in uses an app you register yourself with Google or Twitch (free). Framecast has no server of its own, so it can't share one. Stream keys work without this.") {
                    OAuthSetupRows()
                }
            }
            .padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Theme.body)
    }
}

struct DestinationRow: View {
    @Environment(Studio.self) var studio
    let destination: Destination
    @Binding var editing: UUID?
    var body: some View {
        let store = studio.streaming.destinations
        let st = studio.streaming.statuses[destination.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PlatformBadge(platform: destination.platform.rawValue, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name).font(.fc(13.5, .semibold))
                    Text("\(destination.server) · key …\(destination.keyHint)").font(.fc(11).monospaced()).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let st { StatusChip(status: st) }
                Toggle("", isOn: Binding(get: { destination.isOn }, set: { v in if let i = store.items.firstIndex(of: destination) { store.items[i].isOn = v } }))
                    .toggleStyle(.switch).labelsHidden().disabled(studio.streaming.isLive).help("Include in the next stream")
                Button(editing == destination.id ? "Done" : "Edit") { editing = editing == destination.id ? nil : destination.id }
            }
            if editing == destination.id {
                let i = store.items.firstIndex(of: destination)
                HStack(spacing: 16) {
                    Picker("Canvas", selection: Binding(get: { destination.canvas }, set: { v in if let i { store.items[i].canvas = v } })) {
                        ForEach(CanvasKind.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 200)
                    Stepper("Video \(String(format: "%.1f", Double(destination.videoKbps) / 1000)) Mbps", value: Binding(get: { destination.videoKbps }, set: { v in if let i { store.items[i].videoKbps = v } }), in: 1_000...51_000, step: 500)
                    Picker("Max", selection: Binding(get: { destination.maxHeight }, set: { v in if let i { store.items[i].maxHeight = v } })) {
                        ForEach([720, 1080, 1440, 2160], id: \.self) { Text("\($0)p").tag($0) }
                    }.frame(width: 120)
                }.font(.fc(12))
                HStack(spacing: 16) {
                    Toggle("Reconnect automatically", isOn: Binding(get: { destination.autoReconnect }, set: { v in if let i { store.items[i].autoReconnect = v } }))
                    Toggle("Adapt bitrate to the network", isOn: Binding(get: { destination.adaptiveBitrate }, set: { v in if let i { store.items[i].adaptiveBitrate = v } }))
                    Spacer()
                    Button("Remove this server", role: .destructive) { store.remove(destination.id) }.disabled(studio.streaming.isLive)
                }.toggleStyle(.checkbox).font(.fc(12))
                Text("Its address and stream key are deleted from this Mac when you remove it.").font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
            if let s = studio.streaming.stats[destination.id], st == .live {
                Text("Up \(formatClock(s.uptime)) · \(String(format: "%.1f", s.sendKbps / 1000)) Mbps out · target \(String(format: "%.1f", Double(s.currentBitrateKbps) / 1000)) Mbps · \(s.droppedFrames) dropped · \(s.reconnects) reconnects")
                    .font(.fc(11)).foregroundStyle(Theme.text3)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }
}

struct StatusChip: View {
    let status: StreamStatus
    var body: some View {
        let (t, c): (String, Color) = {
            switch status {
            case .connecting: return ("Connecting…", Theme.text3)
            case .live: return ("Live", Theme.live)
            case .reconnecting(let a, let r, _): return ("Reconnecting (try \(a), \(Int(r)) s)", Theme.warning)
            case .failed(let m): return (m, Theme.warning)
            case .stopped: return ("Stopped", Theme.text3)
            }
        }()
        Text(t).font(.fc(11, .bold)).foregroundStyle(c).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.15)))
    }
}

/// Stream-key form for YouTube, Twitch, X, Instagram and custom RTMP/RTMPS servers.
struct AddDestinationForm: View {
    @Environment(Studio.self) var studio
    var compact: Bool
    @Local var platform: Platform = .youtube
    @Local var name = ""
    @Local var server = Platform.youtube.defaultServer
    @Local var key = ""
    @Local var canvas: CanvasKind = .horizontal
    @Local var testing = false
    @Local var message: String?
    @Local var ok = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Platform.allCases) { p in
                    Button { platform = p; server = p.defaultServer; canvas = p.preferredCanvas; message = nil } label: {
                        HStack(spacing: 6) { PlatformBadge(platform: p.rawValue, size: 18); Text(p == .custom ? "Custom" : p.title).font(.fc(12, .semibold)) }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(platform == p ? Theme.selected : Theme.control2))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(platform == p ? Theme.accent : Theme.hairline))
                    }.buttonStyle(.plain)
                }
            }
            Text(platform.keyHelp).font(.fc(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            if !compact { field("Name", TextField(platform == .custom ? "Custom RTMP server" : platform.title, text: $name)) }
            field("Server URL", TextField("rtmps://live.example.tv/app", text: $server))
            field("Stream key", SecureField("Paste the stream key", text: $key))
            HStack {
                Picker("Canvas", selection: $canvas) { ForEach(CanvasKind.allCases) { Text($0.title).tag($0) } }.frame(width: 200)
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Test & save") { save(test: true) }.disabled(testing)
                Button("Save") { save(test: false) }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(testing)
            }
            if let message { Text(message).font(.fc(11.5)).foregroundStyle(ok ? Theme.healthy : Theme.warning).fixedSize(horizontal: false, vertical: true) }
            Text("Your key is stored in the macOS Keychain.").font(.fc(10.5)).foregroundStyle(Theme.text4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }
    func field<F: View>(_ label: String, _ f: F) -> some View {
        HStack { Text(label).font(.fc(12, .semibold)).frame(width: 90, alignment: .leading); f.textFieldStyle(.roundedBorder) }
    }
    func save(test: Bool) {
        if let e = DestinationsStore.validate(server: server) { message = e; ok = false; return }
        if key.trimmingCharacters(in: .whitespaces).isEmpty { message = "Enter the stream key."; ok = false; return }
        let store = studio.streaming.destinations
        let finalName = name.isEmpty ? (platform == .custom ? (URL(string: server)?.host ?? "Custom server") : platform.title) : name
        func commit() {
            if let e = store.add(platform: platform, name: finalName, server: server.trimmingCharacters(in: .whitespaces), key: key, canvas: canvas) { message = e; ok = false; return }
            if test, let i = store.items.indices.last { store.items[i].testedAt = Date() }
            message = test ? "Saved. The server answered; the key itself is checked when the broadcast starts." : "Saved."
            ok = true; key = ""; name = ""
        }
        guard test else { commit(); return }
        testing = true; message = nil
        StreamingController.probe(server: server, key: key) { err in
            testing = false
            if let err { message = err; ok = false } else { commit() }
        }
    }
}

/// Settings for the optional YouTube/Twitch OAuth apps (client IDs supplied by the user).
struct OAuthSetupRows: View {
    @Environment(Studio.self) var studio
    @AppStorage("framecast.youtubeClientID") var youtubeID = ""
    /// Typed here, saved to the Keychain (never to preferences); the field stays empty once saved.
    @Local var youtubeSecret = ""
    @Local var youtubeSecretSaved = YouTubeClientSecret.isSaved
    @AppStorage("framecast.twitchClientID") var twitchID = ""
    @AppStorage("framecast.twitchChannel") var twitchChannel = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PlatformBadge(platform: "youtube", size: 20)
                TextField("Google OAuth client ID (Desktop app)", text: $youtubeID).textFieldStyle(.roundedBorder)
                SecureField(youtubeSecretSaved ? "Secret saved" : "Client secret", text: $youtubeSecret).textFieldStyle(.roundedBorder).frame(width: 140)
                    .onChange(of: youtubeSecret) { _, new in
                        guard !new.isEmpty else { return }
                        YouTubeClientSecret.save(new); youtubeSecretSaved = true
                    }
                Button("Connect YouTube") { studio.chat.connectYouTubeChat() }.disabled(youtubeID.isEmpty)
            }
            HStack {
                PlatformBadge(platform: "twitch", size: 20)
                TextField("Twitch client ID (optional)", text: $twitchID).textFieldStyle(.roundedBorder)
                TextField("Channel", text: $twitchChannel).textFieldStyle(.roundedBorder).frame(width: 140)
                Button(twitchID.isEmpty ? "Read chat" : "Connect Twitch") { studio.chat.connectTwitchChat(channel: twitchChannel) }
                    .disabled(twitchID.isEmpty && twitchChannel.isEmpty)
            }
            Text("Without a client ID, Twitch chat of a public channel is read anonymously (read-only).").font(.fc(10.5)).foregroundStyle(Theme.text4)
            if let s = studio.chat.status { Text(s).font(.fc(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true) }
            Text("Needs your own Google or Twitch app ID; see docs/GUESTS.md for how accounts and keys work.")
                .font(.fc(10.5)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
        }
    }
}
