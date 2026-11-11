import SwiftUI
import AppKit
import FramecastEngine

struct RootView: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    @Environment(\.openSettings) var openSettings
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Group {
            if !settings.s.hasOnboarded {
                OnboardingView()
            } else {
                StudioView()
            }
        }
        .sheet(isPresented: Binding(get: { settings.s.hasOnboarded && studio.tab == .destinations }, set: { if !$0 { studio.tab = .studio } })) {
            DestinationsView().frame(width: 860, height: 700)
        }
        .background(Theme.body)
        .background(WindowConfigurator())
        .toolbar { StudioToolbar() }
        .toolbarBackground(Theme.window, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(item: Binding(get: { studio.summary }, set: { studio.summary = $0 })) { SessionSummaryView(summary: $0) }
        .onChange(of: studio.testOpenSettings) { _, _ in openSettings() }
        .onChange(of: studio.testOpenPrompter) { _, _ in openWindow(id: "prompter") }
        .alert(studio.notice ?? "", isPresented: Binding(get: { studio.notice != nil }, set: { if !$0 { studio.notice = nil } })) {
            Button("OK") { studio.notice = nil }
        }
    }
}

/// Hides the window title and keeps the window colour behind the unified toolbar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titleVisibility = .hidden
            w.backgroundColor = Theme.windowNS
            w.isMovableByWindowBackground = false
            w.toolbar?.showsBaselineSeparator = false
            w.identifier = NSUserInterfaceItemIdentifier("framecast.studio")
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Toolbar

struct StudioToolbar: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // No glass capsule behind the custom controls (they draw their own backgrounds).
            ToolbarItem(placement: .principal) { ToolbarCenter() }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { ToolbarControls() }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { ToolbarCenter() }
            ToolbarItem(placement: .primaryAction) { ToolbarControls() }
        }
    }
}

struct ToolbarCenter: View {
    var body: some View { CanvasTabs().fixedSize() }
}

struct ToolbarControls: View {
    @Environment(Studio.self) var studio
    @Local var showChannels = false
    var body: some View {
        HStack(spacing: 10) {
            DestinationsPill(showChannels: $showChannels)
            Button { studio.testOpenPrompter += 1 } label: {
                Label("Presenter", systemImage: "eye.slash").font(.fc(12, .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Theme.control)).overlay(Capsule().stroke(Theme.hairline))
            }
            .buttonStyle(.plain).help("Presenter view: your outline and what the AI is doing, in a window only you can see (viewers never do)")
            Button { studio.isAddingSource = true } label: {
                Label("Add", systemImage: "plus").font(.fc(12, .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Theme.control)).overlay(Capsule().stroke(Theme.hairline))
            }
            .buttonStyle(.plain).help("Add a camera, screen, picture, text or creator-pack item to the scene (⇧⌘N)")
            SettingsLink {
                Image(systemName: "gearshape").font(.fc(13, .semibold)).foregroundStyle(Theme.icon)
                    .frame(width: 30, height: 30).background(Circle().fill(Theme.control)).overlay(Circle().stroke(Theme.hairline))
            }
            .buttonStyle(.plain).help("Settings (⌘,)")
        }
        .padding(.trailing, 2)
    }
}

struct DestinationsPill: View {
    @Environment(Studio.self) var studio
    @Binding var showChannels: Bool
    var body: some View {
        let all = studio.streaming.destinations.items
        let on = all.filter(\.isOn)
        Button { showChannels.toggle() } label: {
            HStack(spacing: 8) {
                HStack(spacing: -6) {
                    if on.isEmpty {
                        Circle().fill(Theme.selected).frame(width: 24, height: 24)
                            .overlay(Image(systemName: "antenna.radiowaves.left.and.right").font(.fc(10, .bold)).foregroundStyle(Theme.text3))
                    }
                    ForEach(Array(on.prefix(4).enumerated()), id: \.element.id) { i, d in
                        PlatformBadge(platform: d.platform.rawValue, size: 24, ring: Theme.control).zIndex(Double(4 - i))
                    }
                }
                Text(all.isEmpty ? "Destinations" : "Destinations · \(on.count) on")
                    .font(.fc(12, .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.leading, 4).padding(.trailing, 12).frame(height: 30)
            .background(Capsule().fill(Theme.control))
            .overlay(Capsule().stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help("Choose where your next broadcast goes")
        .popover(isPresented: $showChannels, arrowEdge: .bottom) { ChannelsMenu() }
    }
}

struct ChannelsMenu: View {
    @Environment(Studio.self) var studio
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let store = studio.streaming.destinations
        VStack(alignment: .leading, spacing: 10) {
            Text("Broadcast to").font(.fc(13, .bold))
            if store.items.isEmpty {
                Text("Connect YouTube or Twitch, or add a custom RTMP server, to choose where you stream.")
                    .font(.fc(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.items) { d in
                HStack(spacing: 10) {
                    PlatformBadge(platform: d.platform.rawValue, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.fc(12.5, .semibold))
                        Text("\(d.canvas.title) · \(String(format: "%.1f", Double(d.videoKbps) / 1000)) Mbps").font(.fc(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { d.isOn }, set: { v in
                        if let i = store.items.firstIndex(where: { $0.id == d.id }) { store.items[i].isOn = v }
                    })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(studio.streaming.isLive)
                }
            }
            Hairline()
            Button("Manage destinations…") { dismiss(); studio.tab = .destinations }.buttonStyle(.plain).font(.fc(12, .semibold)).foregroundStyle(Theme.accent)
            if studio.streaming.isLive { Text("You're broadcasting: changes here apply to the next broadcast.").font(.fc(11)).foregroundStyle(Theme.text3) }
        }
        .padding(16).frame(width: 320)
    }
}

struct RecordControl: View {
    @Environment(Studio.self) var studio
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if studio.isRecording {
                HStack(spacing: 0) {
                    Button { studio.stopRecording() } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.live).frame(width: 10, height: 10)
                            Text(studio.recordingPausedAt == nil ? "Stop recording" : "Paused").font(.fc(12.5, .bold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                            Text(formatClock(studio.recordedSeconds)).font(.fc(12.5, .medium).monospacedDigit()).foregroundStyle(Theme.stopText)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Stop recording and save the files")
                    Rectangle().fill(Theme.stopBorder).frame(width: 1).padding(.vertical, 8)
                    Menu {
                        Button(studio.recordingPausedAt == nil ? "Pause Recording" : "Resume Recording") { studio.togglePause() }
                        Divider()
                        ForEach(studio.recordingCanvases, id: \.self) { c in Text("Recording \(c.title) · \(studio.settings.container(c).title)") }
                        Button("Show Recordings in Finder") { if let f = studio.recordingFolders().first { NSWorkspace.shared.open(f) } }
                    } label: {
                        Image(systemName: studio.recordingPausedAt == nil ? "pause.fill" : "play.fill").font(.fc(11, .bold)).foregroundStyle(Theme.icon)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 38)
                }
                .frame(width: 250, height: 40)
                .background(Capsule().fill(Theme.stopBG))
                .overlay(Capsule().stroke(Theme.stopBorder))
            } else {
                Button { studio.startRecording() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.live).frame(width: 10, height: 10)
                        Text("Record").font(.fc(12.5, .bold)).foregroundStyle(Theme.text)
                        Text(studio.stage == .both && studio.isVerticalOn ? "16:9 + 9:16" : (studio.stage == .vertical ? "9:16" : "16:9"))
                            .font(.fc(11.5, .medium)).foregroundStyle(Theme.text3)
                    }
                    .frame(width: 250, height: 40)
                    .background(Capsule().fill(Theme.control))
                    .overlay(Capsule().stroke(Theme.hairline))
                }.buttonStyle(.plain).help("Record what the canvases show (⌘R)")
            }
        }
    }
}

struct GoLiveControl: View {
    @Environment(Studio.self) var studio
    @Binding var showGoLive: Bool
    @Binding var confirmEnd: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            switch studio.streaming.phase {
            case .idle:
                Button { showGoLive = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.fc(12, .bold))
                        Text("Start broadcast").font(.fc(12.5, .heavy))
                    }
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 250, height: 40)
                    .background(Capsule().fill(Theme.accent))
                }.buttonStyle(.plain).help("Start broadcasting to your destinations")
            case .starting(let step):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step).font(.fc(12, .semibold)).lineLimit(1) }
                    .frame(width: 250, height: 40)
                    .background(Capsule().fill(Theme.control))
                    .overlay(Capsule().stroke(Theme.hairline))
            case .live(let since):
                Button { if studio.settings.s.confirmsEndStream { confirmEnd = true } else { studio.streaming.endStream() } } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.stopText).frame(width: 10, height: 10)
                        Text("End broadcast").font(.fc(12.5, .heavy)).foregroundStyle(.white).lineLimit(1).fixedSize()
                        Text(formatClock(ctx.date.timeIntervalSince(since))).font(.fc(12.5, .medium).monospacedDigit()).foregroundStyle(Theme.stopText)
                    }
                    .frame(width: 250, height: 40)
                    .background(Capsule().fill(Theme.stopBG))
                    .overlay(Capsule().stroke(Theme.stopBorder))
                }.buttonStyle(.plain)
            case .stopping:
                Text("Ending broadcast…").font(.fc(12, .semibold)).frame(width: 250, height: 40)
                    .background(Capsule().fill(Theme.control))
            }
        }
        .confirmationDialog("End the broadcast?", isPresented: $confirmEnd) {
            Button("End Broadcast", role: .destructive) { studio.streaming.endStream() }
            Button("Keep Broadcasting", role: .cancel) {}
        } message: {
            Text(studio.isRecording ? "Viewers will see the broadcast end. Your recording keeps going." : "Viewers will see the broadcast end.")
        }
    }
}

// MARK: - Studio layout

/// Scenes on the left, the canvases in the middle, the inspector on the right, and the control bar across the
/// full width underneath all three.
struct StudioView: View {
    @Environment(Studio.self) var studio
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScenesSidebar().frame(width: 236)
                Hairline(vertical: true)
                ProgramArea().frame(minWidth: 480).clipped()
                Hairline(vertical: true)
                Inspector().frame(width: 340)
            }
            .frame(maxHeight: .infinity)
            Hairline()
            ControlBar()
        }
        .background(Theme.body)
        .overlay(alignment: .top) { Hairline() }
        .sheet(isPresented: Binding(get: { studio.isAddingSource }, set: { studio.isAddingSource = $0 })) { AddSourceSheet() }
        .sheet(item: Binding(get: { studio.backgroundTarget }, set: { studio.backgroundTarget = $0 })) { BackgroundPickerSheet(target: $0) }
        .sheet(isPresented: Binding(get: { studio.showsPreflight }, set: { studio.showsPreflight = $0 })) { PreflightSheet() }
    }
}

/// Under the canvases: transition on the left, record and broadcast in the middle, status on the right.
struct ControlBar: View {
    @Environment(Studio.self) var studio
    @Local var showGoLive = false
    @Local var confirmEnd = false
    var body: some View {
        ZStack {
            HStack(spacing: 14) {
                PreviewToggle()
                TransitionControl()
                Spacer(minLength: 8)
                HStack(spacing: 14) { MomentButtons(); LiveStats(); HealthIndicator() }.fixedSize()
            }
            HStack(spacing: 14) {
                RecordControl()
                GoLiveControl(showGoLive: $showGoLive, confirmEnd: $confirmEnd)
            }
        }
        .padding(.horizontal, 18).frame(height: 64).frame(maxWidth: .infinity)
        .background(Theme.window)
        .onReceive(NotificationCenter.default.publisher(for: .framecastGoLive)) { _ in
            if studio.streaming.isLive { confirmEnd = true } else { showGoLive = true }
        }
        .sheet(isPresented: $showGoLive) { GoLiveSheet() }
        .onChange(of: studio.testDismiss) { _, _ in showGoLive = false }
    }
}

/// How the program changes when you switch scenes.
/// Marker and instant-clip buttons, shown while recording or live.
struct MomentButtons: View {
    @Environment(Studio.self) var studio
    var body: some View {
        if studio.isRecording || studio.streaming.isLive {
            HStack(spacing: 6) {
                pill("flag.fill", "Marker", help: "Mark this moment: it becomes a chapter in the recap (⌥⌘M)") { studio.addMarker() }
                pill("scissors", studio.replayHeld >= 1 ? "Clip \(Int(studio.replayHeld)) s" : "Clip",
                     help: "Save the last 30 seconds as 16:9 and 9:16 clips next to your recordings (⌥⌘S)") { studio.saveClip() }
            }
        }
    }
    func pill(_ icon: String, _ title: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: icon).font(.fc(10.5, .semibold)); Text(title).font(.fc(11.5, .semibold)).monospacedDigit() }
                .foregroundStyle(Theme.text2).padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(Theme.control)).overlay(Capsule().stroke(Theme.hairline))
        }.buttonStyle(.plain).help(help)
    }
}

/// Preview before air on or off.
struct PreviewToggle: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let on = studio.previewMode
        Button { studio.setPreviewMode(!on) } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "eye.fill" : "eye").font(.fc(11.5, .semibold))
                Text("Preview").font(.fc(12, .semibold))
            }
            .foregroundStyle(on ? Theme.accentInk : Theme.text2)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(on ? Theme.healthy.opacity(0.85) : Theme.control))
            .overlay(Capsule().stroke(on ? .clear : Theme.hairline))
        }
        .buttonStyle(.plain)
        .help(on ? "Preview before air is on: set scenes up privately, then put them on air (⌥⌘P to turn off)"
                 : "Set scenes up privately before they go on air (⌥⌘P)")
    }
}

struct TransitionControl: View {
    @Environment(Studio.self) var studio
    var body: some View {
        Menu {
            ForEach(TransitionKind.allCases, id: \.self) { t in
                Button((studio.settings.s.transition == t ? "✓ " : "") + t.title) { studio.settings.s.transition = t }
            }
            Divider()
            ForEach([300, 500, 800, 1200], id: \.self) { ms in
                Button((studio.settings.s.transitionMs == ms ? "✓ " : "") + String(format: "%.1f s", Double(ms) / 1000)) { studio.settings.s.transitionMs = ms }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.angled").font(.fc(11.5, .semibold)).foregroundStyle(Theme.text3)
                Text(studio.settings.s.transition == .cut ? "Cut" : "\(studio.settings.s.transition.title) · \(String(format: "%.1f", Double(studio.settings.s.transitionMs) / 1000)) s")
                    .font(.fc(12, .semibold)).foregroundStyle(Theme.text2)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .help("Transition when you switch scenes")
    }
}

/// The right-hand inspector: tabs across the top, the chosen panel below.
struct Inspector: View {
    @Environment(Studio.self) var studio
    var body: some View {
        VStack(spacing: 0) {
            InspectorTabs()
            Hairline()
            SidePanel()
        }
        .background(Theme.panel)
    }
}

struct InspectorTabs: View {
    @Environment(Studio.self) var studio
    var body: some View {
        HStack(spacing: 0) {
            ForEach(StudioRail.allCases) { r in
                let on = studio.rail == r
                Button { studio.rail = r } label: {
                    VStack(spacing: 4) {
                        Image(systemName: r.icon).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(on ? Theme.accent : Theme.icon)
                            .overlay(alignment: .topTrailing) { badge(for: r) }
                        Text(r.title).font(.fc(10, .semibold)).foregroundStyle(on ? Theme.text : Theme.text3).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .overlay(alignment: .bottom) { Rectangle().fill(on ? Theme.accent : .clear).frame(height: 2).padding(.horizontal, 10) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(r == .chat ? "Comments from your destinations (⌥⌘C)" : r.title)
            }
        }
        .padding(.horizontal, 4)
        .background(Theme.window)
    }
    @ViewBuilder func badge(for r: StudioRail) -> some View {
        if r == .guests && !studio.guests.lobby.isEmpty {
            Text("\(studio.guests.lobby.count)").font(.fc(9, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Theme.live)).offset(x: 9, y: -6)
        }
        let knocking = studio.guests.devices.filter { $0.status == .waiting }.count
        if r == .angles && knocking > 0 {
            Text("\(knocking)").font(.fc(9, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Theme.live)).offset(x: 9, y: -6)
        } else if r == .angles && studio.angles.shuffleOn {
            Circle().fill(Theme.healthy).frame(width: 6, height: 6).offset(x: 7, y: -4)
        }
    }
}

struct HealthIndicator: View {
    @Environment(Studio.self) var studio
    @Local var showAlerts = false
    var body: some View {
        let h = studio.health
        Button { showAlerts.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(h.ok ? Theme.healthy : Theme.warning).frame(width: 8, height: 8)
                    .shadow(color: (h.ok ? Theme.healthy : Theme.warning).opacity(0.4), radius: 4)
                Text(h.ok ? "All good" : "Check status").font(.fc(11.5, .semibold)).foregroundStyle(Theme.text2)
                if !studio.alerts.isEmpty {
                    Text("\(studio.alerts.count)").font(.fc(10, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Theme.warning.opacity(0.8)))
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Theme.control2))
        }
        .buttonStyle(.plain)
        .help(h.text)
        .popover(isPresented: $showAlerts, arrowEdge: .top) { AlertsPopover() }
    }
}

struct AlertsPopover: View {
    @Environment(Studio.self) var studio
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Status").font(.fc(13, .bold)); Spacer()
                if !studio.alerts.isEmpty { Button("Clear all") { studio.alerts.removeAll() }.buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent) } }
            let h = studio.health
            if h.ok && studio.alerts.isEmpty {
                Text("All good · \(studio.droppedFrames) dropped frames").font(.fc(12)).foregroundStyle(Theme.text2)
            } else if studio.alerts.isEmpty {
                Text(h.text).font(.fc(12)).foregroundStyle(Theme.text2)
            }
            ForEach(studio.alerts.reversed()) { a in
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.title).font(.fc(12, .semibold))
                    Text(a.detail).font(.fc(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Text(a.time, style: .time).font(.fc(10.5)).foregroundStyle(Theme.text4)
                }
            }
        }
        .padding(16).frame(width: 300)
    }
}

struct SidePanel: View {
    @Environment(Studio.self) var studio
    var body: some View {
        Group {
            switch studio.rail {
            case .chat: ChatPanel()
            case .backstage: BackstagePanel()
            case .guests: GuestsPanel()
            case .angles: AnglesPanel()
            case .audio: AudioPanel()
            case .elements: ElementsPanel()
            case .captions: CaptionsPanel()
            case .edit: EditPanel()
            case .rundown:
                // Only the presenter sees the Rundown (script, outline, what the AI is doing); a shared screen or
                // window shows a "private" placeholder there.
                PrivatePanel { RundownPanel().background(Theme.panel) } placeholder: { PrivatePlaceholder(title: "Rundown") }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }
}

struct PanelHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.fc(14.5, .bold)).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(.fc(11.5)).foregroundStyle(Theme.text3).lineLimit(1) }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16).frame(height: 52)
        .overlay(alignment: .bottom) { Hairline() }
    }
}
extension PanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle; trailing = EmptyView() }
}
