import SwiftUI
import AppKit
import FramecastEngine

struct ElementsPanel: View {
    @Environment(Studio.self) var studio
    @Local var editing: UUID?
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Overlays", subtitle: "⌥⌘1–9") {
                Menu {
                    ForEach(OverlayElement.Kind.allCases, id: \.self) { k in
                        Button(title(k)) {
                            let e = OverlayElement(kind: k, name: title(k), title: k == .thanks ? "Thanks for joining" : (k == .qr ? "Scan for the link" : "Your title"),
                                                   subtitle: k == .lower ? "Name or headline" : "", url: k == .qr ? "https://example.com" : "")
                            studio.collection.elements.append(e); editing = e.id
                        }
                    }
                } label: { Label("New", systemImage: "plus").font(.fc(12, .semibold)) }
                .menuStyle(.borderlessButton).fixedSize().help("Make a new overlay")
            }
            ScrollView {
                VStack(spacing: 8) {
                    if studio.collection.elements.isEmpty {
                        Text("No elements yet. Click New to make one.").font(.fc(12.5)).foregroundStyle(Theme.text3).padding(20)
                    }
                    ForEach(Array(studio.collection.elements.enumerated()), id: \.element.id) { i, e in
                        ElementCard(element: e, number: i + 1, editing: $editing)
                    }
                }
                .padding(12)
            }
        }
    }
    func title(_ k: OverlayElement.Kind) -> String {
        switch k { case .text: "Title"; case .lower: "Lower third"; case .thanks: "Thanks card"; case .qr: "QR code" }
    }
}

struct ElementCard: View {
    @Environment(Studio.self) var studio
    let element: OverlayElement
    let number: Int
    @Binding var editing: UUID?
    var body: some View {
        let on = studio.elementsOn[element.id] != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: OverlayRenderer.accentColor(element.accent))).frame(width: 6, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(element.name).font(.fc(12.5, .semibold)).lineLimit(1)
                    Text(element.title).font(.fc(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer()
                if number <= 9 { Text("⌥⌘\(number)").font(.fc(10, .semibold)).foregroundStyle(Theme.text4) }
                Button { studio.toggleElement(element) } label: {
                    Text(on ? "On screen" : "Show").font(.fc(11.5, .bold)).foregroundStyle(on ? Theme.accentInk : Theme.text)
                        .padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(on ? Theme.accent : Theme.selected))
                }.buttonStyle(.plain).help(on ? "Click to take it off screen" : "Click to show it on stream")
            }
            if editing == element.id { ElementEditor(element: element) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.accent.opacity(0.6) : Theme.hairline))
        .contentShape(Rectangle())
        .onTapGesture { editing = editing == element.id ? nil : element.id }
        .contextMenu {
            Button("Edit") { editing = element.id }
            Button("Duplicate") { var c = element; c.id = UUID(); c.name += " copy"; studio.collection.elements.append(c) }
            Button("Delete element", role: .destructive) {
                if studio.elementsOn[element.id] != nil { studio.toggleElement(element) }
                studio.collection.elements.removeAll { $0.id == element.id }
            }
        }
    }
}

struct ElementEditor: View {
    @Environment(Studio.self) var studio
    let element: OverlayElement
    func set(_ f: @escaping (inout OverlayElement) -> Void) {
        guard let i = studio.collection.elements.firstIndex(where: { $0.id == element.id }) else { return }
        f(&studio.collection.elements[i])
        studio.engine.updateElement(studio.collection.elements[i])
    }
    func text(_ label: String, _ kp: WritableKeyPath<OverlayElement, String>) -> some View {
        HStack {
            Text(label).font(.fc(11.5)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
            TextField(label, text: Binding(get: { element[keyPath: kp] }, set: { v in set { $0[keyPath: kp] = v } })).textFieldStyle(.roundedBorder).font(.fc(12))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            text("Name", \.name)
            text("Title", \.title)
            if element.kind == .lower || element.kind == .thanks || element.kind == .text { text("Subtitle", \.subtitle) }
            if element.kind == .qr { text("Link", \.url) }
            row("Accent") {
                HStack(spacing: 6) {
                    ForEach(OverlayElement.Accent.allCases, id: \.self) { a in
                        Circle().fill(Color(nsColor: OverlayRenderer.accentColor(a))).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: element.accent == a ? 2 : 0))
                            .onTapGesture { set { $0.accent = a } }
                    }
                }
            }
            row("Look") { seg(OverlayElement.Look.allCases, element.look) { v in set { $0.look = v } } }
            row("Motion") { seg(OverlayElement.Motion.allCases, element.motion) { v in set { $0.motion = v } } }
            row("Speed") { seg(OverlayElement.Speed.allCases, element.speed) { v in set { $0.speed = v } } }
            row("Position") {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<3, id: \.self) { r in
                        GridRow {
                            ForEach(0..<3, id: \.self) { c in
                                let p = OverlayElement.Position.allCases[r * 3 + c]
                                RoundedRectangle(cornerRadius: 3).fill(element.position == p ? Theme.accent : Theme.selected).frame(width: 22, height: 14)
                                    .onTapGesture { set { $0.position = p } }
                            }
                        }
                    }
                }
            }
            row("Auto-hide") {
                Picker("", selection: Binding(get: { element.autoHide }, set: { v in set { $0.autoHide = v } })) {
                    Text("Never").tag(0); Text("5 s").tag(5); Text("10 s").tag(10); Text("30 s").tag(30)
                }.labelsHidden().frame(width: 110)
            }
            PillButton(title: "Play the animation again") {
                if studio.elementsOn[element.id] != nil { studio.toggleElement(element) }
                DispatchQueue.main.asyncAfter(deadline: .now() + element.durationSeconds + 0.05) { studio.toggleElement(element) }
            }
        }
    }
    func row<C: View>(_ l: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center) { Text(l).font(.fc(11.5)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading); c(); Spacer() }
    }
    func seg<T: Hashable & RawRepresentable>(_ all: [T], _ cur: T, _ set: @escaping (T) -> Void) -> some View where T.RawValue == String {
        Picker("", selection: Binding(get: { cur }, set: set)) { ForEach(all, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            .pickerStyle(.segmented).labelsHidden()
    }
}

// MARK: - Guests

struct GuestsPanel: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let room = studio.guests!
        VStack(spacing: 0) {
            PanelHeader(title: "Guests", subtitle: room.isOpen ? "\(room.stage.count + 1) on air, including you" : nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !room.isOpen {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Anyone with the link joins from a browser. You let them in.").font(.fc(12.5)).foregroundStyle(Theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                            SectionLabel(text: "Who can join")
                            Picker("", selection: Binding(get: { room.reach }, set: { room.reach = $0 })) {
                                ForEach(GuestReach.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.radioGroup).labelsHidden().font(.fc(12))
                            if room.reach == .internet { CloudSetupRow() }
                            Text(room.status).font(.fc(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                            PillButton(title: "Open the guest room", systemImage: "door.left.hand.open", prominent: true) { room.open() }
                            Text("The room also gives you a camera link: phones and other computers join as extra camera angles of you.")
                                .font(.fc(11)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Invite link")
                            HStack {
                                Text(room.inviteURL ?? "Making your link…").font(.fc(11.5).monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Copy") { if let u = room.inviteURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) } }
                                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.fc(12, .semibold))
                            }
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                            Text(room.reachNote)
                                .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                            Toggle("Ask before letting guests in", isOn: Binding(get: { room.askBeforeLettingIn }, set: { room.askBeforeLettingIn = $0 })).toggleStyle(.checkbox).font(.fc(12))
                            Toggle("Guests join muted", isOn: Binding(get: { room.joinMuted }, set: { room.joinMuted = $0 })).toggleStyle(.checkbox).font(.fc(12))
                        }
                        JoinActivity(devices: false)
                        section("Waiting room", room.lobby, empty: "Nobody waiting.")
                        section("On air", room.stage, empty: "Just you so far.")
                        CameraLinkSection()
                        HStack {
                            PillButton(title: "New link") { room.newInviteLink() }
                            PillButton(title: "Close room", destructive: true) { room.close() }
                        }
                    }
                }
                .padding(14)
            }
        }
    }
    @ViewBuilder func section(_ title: String, _ list: [Guest], empty: String) -> some View {
        SectionLabel(text: title)
        if list.isEmpty { Text(empty).font(.fc(12)).foregroundStyle(Theme.text3) }
        ForEach(list) { g in GuestRow(guest: g) }
    }
}

/// Phones and computers as extra camera angles: the camera link and phones knocking on it. The angles themselves,
/// the shuffle and lip sync live in the Angles tab.
struct CameraLinkSection: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let room = studio.guests!
        let angles = studio.angles
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Camera angles")
            HStack {
                Text(room.deviceInviteURL ?? "Making your camera link…").font(.fc(11.5).monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copy") { if let u = room.deviceInviteURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) } }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.fc(12, .semibold))
                Button("New") { room.newDeviceLink() }.buttonStyle(.plain).foregroundStyle(Theme.text3).font(.fc(12, .semibold))
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            Text("Open it on a phone or another computer to add it as a camera angle of you. Its sound stays out of the show unless you allow it.")
                .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
            WaitingDevices()
            HStack {
                Text("\(angles.angles.count) angle\(angles.angles.count == 1 ? "" : "s")\(angles.shuffleOn ? ", shuffling" : "")").font(.fc(12)).foregroundStyle(Theme.text2)
                Spacer()
                PillButton(title: "Open Angles", systemImage: "camera.metering.multispot") { studio.rail = .angles }
            }
        }
        .onAppear { angles.rebuild() }
    }
}

/// LiveKit Cloud details for remote guests, loaded from the user's .env file (the secret goes to the Keychain).
struct CloudSetupRow: View {
    @Environment(Studio.self) var studio
    @Local var message = ""
    var body: some View {
        let room = studio.guests!
        VStack(alignment: .leading, spacing: 6) {
            if let problem = room.cloud.problem {
                Text(problem).font(.fc(11.5)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("LiveKit Cloud: \(URL(string: room.cloud.url)?.host ?? "")\nGuest page: \(URL(string: room.cloud.pageURL)?.host ?? "")")
                    .font(.fc(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                PillButton(title: "Load .env file…") {
                    let panel = NSOpenPanel()
                    panel.showsHiddenFiles = true
                    panel.message = "Choose the .env file with LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET and GUEST_PAGE_URL."
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    message = room.loadEnv(url.path)
                }
                if !message.isEmpty { Text(message).font(.fc(11)).foregroundStyle(Theme.text3) }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
    }
}

struct GuestRow: View {
    @Environment(Studio.self) var studio
    let guest: Guest
    var body: some View {
        let room = studio.guests!
        HStack(spacing: 10) {
            Circle().fill(Theme.selected).frame(width: 30, height: 30).overlay(Text(String(guest.name.prefix(2)).uppercased()).font(.fc(10.5, .bold)))
            VStack(alignment: .leading, spacing: 1) {
                Text(guest.name).font(.fc(12.5, .semibold))
                Text(stateText).font(.fc(10.5)).foregroundStyle(guest.status != .waiting && !guest.connected ? Theme.warning : Theme.text3)
            }
            Spacer()
            switch guest.status {
            case .waiting: PillButton(title: "Let in", prominent: true) { room.admit(guest.id) }
            case .lobby: PillButton(title: "Put on air", prominent: true) { room.bringOnStage(guest.id) }.disabled(!guest.connected)
            case .stage: PillButton(title: "Take off air") { room.takeOffStage(guest.id) }
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 9).fill(Theme.control2))
        .contextMenu {
            Button(guest.mutedByHost ? "Unmute" : "Mute") { room.toggleMute(guest.id) }
            Button("Remove from room", role: .destructive) { room.remove(guest.id) }
        }
    }

    /// Where they are: asking, let in but still connecting, in the room, or dropped and rejoining.
    var stateText: String {
        if guest.status == .waiting { return "Asking to join" }
        if !guest.connected { return guest.everConnected ? "Dropped out, rejoining…" : "Let in, connecting…" }
        return guest.status == .stage ? "On air" : "Ready, off air"
    }
}
