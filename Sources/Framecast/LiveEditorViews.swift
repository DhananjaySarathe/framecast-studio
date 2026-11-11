import SwiftUI
import AppKit
import FramecastEngine

/// Settings › Live editor.
struct LiveEditorPane: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    var body: some View {
        let le = studio.liveEditor
        let s = settings.s.liveEditor ?? LiveEditorSettings()
        let edit = { (f: (inout LiveEditorSettings) -> Void) in var x = s; f(&x); settings.s.liveEditor = x }
        SettingsGroup(title: "Screen auto-zoom", footer: "A click on your shared screen zooms in and the view follows your cursor; after a quiet spell it goes back to the whole screen. On 9:16 the screen fills the frame as a slice that follows you. Zooms never go past what stays sharp.") {
            SettingRow(title: "Camera moves", detail: "Rehearse moves the picture only while you're not live: in the preview and in recordings made before you go live. ⌃⌥⌘C turns moves on or off; ⌃⌥⌘X goes back to the whole screen.") {
                Picker("", selection: Binding(get: { s.moves }, set: { le.setMoves($0) })) {
                    ForEach(CameraMoves.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingRow(title: "Intensity", detail: "How far a click zooms: Subtle 1.4x, Moderate 1.6x, Lively 2x.") {
                Picker("", selection: Binding(get: { s.intensity }, set: { v in edit { $0.intensity = v } })) {
                    ForEach(MoveIntensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingRow(title: "Back to the whole screen after", detail: "Seconds without a click or a cursor move.") {
                Stepper("\(Int(s.idleSeconds)) s", value: Binding(get: { s.idleSeconds }, set: { v in edit { $0.idleSeconds = v } }), in: 3...8, step: 1).font(.fc(12))
            }
            SettingRow(title: "Click rings", detail: "A ring around each click in the shared screen (macOS 15 and later).") {
                Toggle("", isOn: Binding(get: { s.clickRings }, set: { v in edit { $0.clickRings = v } })).toggleStyle(.switch).labelsHidden()
            }
        }
        SettingsGroup(title: "Privacy", footer: "Zooms follow clicks and the cursor position only, which need no extra permission. Nothing you type is read, and no zoom happens while a password field has the keyboard.") {
            SettingRow(title: "Hide password managers from screen shares", detail: "Keychain Access, Passwords, 1Password and Bitwarden are left out of captured displays.") {
                Toggle("", isOn: Binding(get: { s.hidesPasswordManagers }, set: { v in edit { $0.hidesPasswordManagers = v } })).toggleStyle(.switch).labelsHidden()
            }
            SettingRow(title: "Never zoom into", detail: "Clicks in these apps don't zoom, and a zoomed view keeps their windows out.") {
                Menu("Add app") {
                    ForEach(Self.runningApps(excluding: s.neverZoom), id: \.0) { app in
                        Button(app.1) { edit { $0.neverZoom.append(app.0) } }
                    }
                }.frame(width: 110)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(s.neverZoom, id: \.self) { id in
                    HStack {
                        Text(Self.appName(id)).font(.fc(12))
                        Spacer()
                        Button { edit { $0.neverZoom.removeAll { $0 == id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.text3).help("Allow zooms into \(Self.appName(id))")
                    }
                }
                Button("Restore the default list") { edit { $0.neverZoom = LiveEditor.defaultNeverZoom } }
                    .buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent).padding(.top, 2)
            }
        }
        SettingsGroup(title: "Performance") {
            SettingRow(title: "Effects", detail: "Auto calms moves on battery and in Low Power Mode. Whatever you choose, Framecast steps down if frames run late or the Mac gets hot, and stops moving at worst.") {
                Picker("", selection: Binding(get: { s.performance }, set: { v in edit { $0.performance = v } })) {
                    ForEach(PerformanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            SettingRow(title: "Status in the Rundown panel", detail: "Frame time, budget tier and missed frames. Only you see it.") {
                Toggle("", isOn: Binding(get: { s.showsHUD }, set: { v in edit { $0.showsHUD = v } })).toggleStyle(.switch).labelsHidden()
            }
        }
        if !le.hotkeyProblems.isEmpty {
            Text("Another app holds \(le.hotkeyProblems.joined(separator: "; ")), so those shortcuts don't work here.")
                .font(.fc(11.5)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    static func runningApps(excluding: [String]) -> [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .filter { !excluding.contains($0.0) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

/// The live editor's status in the private Rundown panel, while camera moves are on.
struct LiveEditorCard: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let le = studio.liveEditor, h = le.hud, s = le.settings
        let still = s.moves == .rehearse && studio.streaming.phase != .idle
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scope").font(.fc(12, .semibold)).foregroundStyle(still ? Theme.text3 : Theme.accent)
                Text(s.moves == .on ? "Camera moves: ON" : (still ? "Camera moves: still while live" : "Camera moves: Rehearse"))
                    .font(.fc(12.5, .bold))
                Spacer()
                Picker("", selection: Binding(get: { s.moves }, set: { le.setMoves($0) })) {
                    ForEach(CameraMoves.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            if s.showsHUD {
                Text("\(h.moves) · \(h.tier.title) · frames \(String(format: "%.1f", h.p95)) ms · missed \(h.missed)\(h.thermal == "nominal" ? "" : " · \(h.thermal)")")
                    .font(.fc(11).monospacedDigit()).foregroundStyle(Theme.text3)
                if h.tier != .full { Text(h.reason).font(.fc(11)).foregroundStyle(Theme.warning) }
            }
            HStack {
                PillButton(title: "Whole screen  ⌃⌥⌘X") { le.resetAndPause() }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(s.moves == .on ? Theme.accent.opacity(0.5) : Theme.hairline))
    }
}

/// On the Go Live sheet: what camera moves will do on air, and a reminder about notifications.
struct GoLiveMovesNote: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let m = studio.liveEditor.settings.moves
        VStack(alignment: .leading, spacing: 4) {
            if m == .on {
                Label("Camera moves: ON. Your screen share zooms on clicks; ⌃⌥⌘X goes back to the whole screen.", systemImage: "scope")
                    .font(.fc(11.5, .semibold)).foregroundStyle(Theme.accent)
            } else if m == .rehearse {
                Label("Camera moves stay still while you're live (Rehearse). Switch them On in Settings › Live editor.", systemImage: "scope")
                    .font(.fc(11.5)).foregroundStyle(Theme.text3)
            }
            Label("Turn on Do Not Disturb so notifications don't appear in your screen share.", systemImage: "moon")
                .font(.fc(11.5)).foregroundStyle(Theme.text3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
