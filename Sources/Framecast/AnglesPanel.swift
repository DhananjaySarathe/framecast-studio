import SwiftUI
import AppKit
import FramecastEngine

/// Angles: every camera angle live and numbered, like a switcher's multiview. Click one to put it in your camera frame
/// (it holds there; click again to let go), or let the shuffle cut between them. A red border is on air; green is in
/// the frame while that layout waits off air.
struct AnglesPanel: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let angles = studio.angles
        VStack(spacing: 0) {
            PanelHeader(title: "Angles", subtitle: subtitle) {
                Toggle("Shuffle", isOn: Binding(get: { angles.shuffleOn }, set: { _ in angles.toggleShuffle() }))
                    .toggleStyle(.switch).controlSize(.small).font(.fc(12, .semibold))
                    .help("Cut between the angles by itself, in your pauses (⌃⌥⌘S from any app).")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if angles.angles.isEmpty {
                        Text("No cameras yet. Add a camera: one camera can also make a medium and a close-up of you. Or invite a phone with the camera link below.")
                            .font(.fc(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(Array(angles.angles.enumerated()), id: \.element.id) { i, a in AngleTile(angle: a, number: i + 1) }
                    }
                    VirtualAnglesRow()
                    WaitingDevices()
                    CameraLinkRow()
                    SwitchingKeys()
                    ShuffleSettings()
                    MarkedFrameRow()
                    LipSyncSection()
                    AngleRecordingRow()
                    CutLog()
                }
                .padding(14)
            }
        }
        .onAppear { angles.tilesShown += 1; angles.rebuild() }
        .onDisappear { angles.tilesShown = max(0, angles.tilesShown - 1) }
    }

    var subtitle: String? {
        let a = studio.angles
        guard !a.angles.isEmpty else { return nil }
        return "\(a.angles.count) angle\(a.angles.count == 1 ? "" : "s")\(a.shuffleOn ? " · shuffling" : a.pinnedID != nil ? " · held" : "")"
    }
}

/// One angle, live: its number (the shortcut), name, how it frames you, and whether it's on air.
struct AngleTile: View {
    @Environment(Studio.self) var studio
    let angle: CameraAngle
    let number: Int
    var body: some View {
        let angles = studio.angles
        let now = HostClock.seconds()
        let inFrame = angles.markedFrame != nil && (angles.currentID ?? angles.primaryID) == angle.id
        let onAir = inFrame && angles.frameOnAir
        let pinned = angles.pinnedID == angle.id
        let sight = angles.sights[angle.id]
        // Every tile is 16:9 whatever the angle's shape: an upright phone fills it, moved to the face as it would be
        // on air (Keep me in frame).
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let pic = angles.pictures[angle.id], angle.usable {
                    GeometryReader { g in
                        // A crop's picture is already framed on the face.
                        Image(decorative: pic, scale: 1).resizable().scaledToFill()
                            .frame(width: g.size.width, height: g.size.height)
                            .offset(faceOffset(pic, in: g.size, face: angles.settings.keepFramed && !angle.isVirtual ? sight?.face : nil))
                    }
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: angle.icon).font(.system(size: 18)).foregroundStyle(Theme.text4)
                        // A crop says why it's off air ("Looking for you…", "Close-up needs a 4K camera").
                        Text(angle.usable ? "Starting…" : angles.virtualReason(angle) ?? "No picture").font(.fc(10.5)).foregroundStyle(Theme.text3)
                            .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 6)
                    }
                }
            }
            .clipped()
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                // The tile's switching key while those are on (F2, ⌥2…), else its number.
                let key = angles.settings.keysOn ? AngleKeyAction.allCases.first { $0.number == number }.flatMap { angles.settings.key($0)?.title } : nil
                Text(key ?? "\(number)").font(.fc(11, .bold).monospacedDigit()).foregroundStyle(.white).padding(.horizontal, key == nil ? 0 : 3)
                    .frame(minWidth: 18, minHeight: 18).background(RoundedRectangle(cornerRadius: 5).fill(onAir ? Theme.live : Color.black.opacity(0.6)))
                if onAir { Text("ON AIR").font(.fc(9, .heavy)).foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(Theme.live)) }
                if pinned { Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(4).background(Circle().fill(Theme.accent)) }
            }
            .padding(5)
        }
        .overlay(alignment: .topTrailing) {
            if let b = softness {
                Text(b.text).font(.fc(9.5, .bold).monospacedDigit()).foregroundStyle(b.color)
                    .padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6)))
                    .help(b.help).padding(5)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Image(systemName: angle.icon).font(.system(size: 9))
                if case .virtual(let p, let shot) = angle.kind {
                    // The camera's name gives way first; the shot word always shows.
                    Text(studio.source(p)?.name ?? "Camera").font(.fc(10.5, .semibold)).lineLimit(1)
                    Text("· \(shot.title)").font(.fc(10.5, .semibold)).fixedSize()
                } else {
                    Text(angle.name).font(.fc(10.5, .semibold)).lineLimit(1)
                }
                Spacer(minLength: 2)
                // Looking into the camera belongs to the camera itself, never to a crop of it.
                if !angle.isVirtual, let s = sight, s.facing(now) { Image(systemName: "eye.fill").font(.system(size: 9)).help("You're looking into this camera.") }
                if let shot = shotText(sight, now: now) { Text(shot).font(.fc(9.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(onAir ? Theme.live : inFrame ? Theme.healthy : pinned ? Theme.accent : Theme.hairline,
                                                               lineWidth: onAir ? 3 : inFrame || pinned ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { angles.tap(angle.id) }
        .help("\(angle.name). " + (pinned ? "Held in your frame. Click to let go."
            : "Click to put this angle in your frame and hold it\(angles.shortcut(for: angle.id).map { " (\($0))" } ?? "")."))
        .contextMenu {
            Button(pinned ? "Let go" : "Hold in my frame") { angles.tap(angle.id) }
            if angle.isDevice {
                Button(angle.audioAllowed ? "Take its sound out of the show" : "Let its sound into the show") { angles.setDeviceAudio(angle.id, !angle.audioAllowed) }
                Button("Line up its sound again") { angles.lineUp(angle.id) }
                Divider()
                Button("Remove this camera", role: .destructive) { angles.removeDevice(angle.id) }
            }
            // Angles from one camera: a crop can be turned off; the camera makes them or stops.
            if case .virtual(let p, let shot) = angle.kind {
                Divider()
                Button("Turn off this shot") {
                    var s = angles.settings.virtual.cameras[p.uuidString] ?? VirtualShots()
                    s[shot] = false
                    angles.setVirtual(camera: p, shots: s)
                }
                .disabled(studio.isRecording)
            } else if angle.kind == .mac {
                Divider()
                Group {
                    if angles.settings.virtual.cameras[angle.sourceID.uuidString] != nil {
                        Button("Stop making angles from this camera") { angles.setVirtual(camera: angle.sourceID, shots: nil) }
                    } else {
                        Button("Make medium and close-up") { angles.setVirtual(camera: angle.sourceID, shots: VirtualShots()) }
                    }
                }
                .disabled(studio.isRecording)
            }
        }
    }

    /// A crop enlarged past sharp: amber "1.4×" when a little soft, red "Soft 2.0×" when soft; "9:16 2.2×" when only
    /// the 9:16 frame (cut from a landscape camera, so enlarged more) isn't sharp.
    var softness: (text: String, color: Color, help: String)? {
        let angles = studio.angles
        guard case .virtual(let p, let shot) = angle.kind, let plan = angles.rigs[p]?.status(shot), plan.available else { return nil }
        let v = studio.isVerticalOn ? plan.enlargement[.vertical] : nil
        let vGrade = v.map { CropGrade(enlargement: $0) }
        guard plan.grade != .sharp || (vGrade != nil && vGrade != .sharp) else { return nil }
        let advice = angles.asks4K(p) ? " Sitting closer to the camera makes it sharper."
            : angles.offers4K(p) == true ? " Use 4K from this camera (below) for a sharper picture." : " A 4K camera makes it sharper."
        if plan.grade == .sharp, let v, let vGrade {
            let vx = String(format: "%.1f×", v)
            return ("9:16 \(vx)", vGrade == .soft ? Theme.live : Theme.warning,
                    "Sharp in 16:9. In 9:16 it's enlarged \(vx), so it looks \(vGrade.title) there." + advice)
        }
        let x = String(format: "%.1f×", plan.enlargement[.horizontal] ?? 1)
        var help = "Cut from the camera's picture and enlarged \(x), so it looks \(plan.grade.title)."
        if let v { help += String(format: " In 9:16 it's enlarged %.1f×.", v) }
        help += advice
        return plan.grade == .soft ? ("Soft \(x)", Theme.live, help) : (x, Theme.warning, help)
    }

    /// How far to move a filled picture so the face sits about 40% down the tile (never past the picture's edge).
    func faceOffset(_ pic: CGImage, in tile: CGSize, face: CGRect?) -> CGSize {
        guard let face, tile.width > 0, tile.height > 0 else { return .zero }
        let scale = max(tile.width / CGFloat(pic.width), tile.height / CGFloat(pic.height))
        let w = CGFloat(pic.width) * scale, h = CGFloat(pic.height) * scale
        let spareX = (w - tile.width) / 2, spareY = (h - tile.height) / 2
        let dx = tile.width / 2 - face.midX * w + w / 2 - tile.width / 2
        let dy = tile.height * 0.4 - face.midY * h + spareY
        return CGSize(width: min(spareX, max(-spareX, dx)), height: min(spareY, max(-spareY, dy)))
    }

    func shotText(_ s: AngleSight?, now: Double) -> String? {
        guard let s, s.checked else { return nil }
        if !s.inView(now) { return "you're not in view" }
        if angle.isVirtual { return nil }           // its name says the shot
        let shot = studio.angles.plannerShot(angle.id)
        return shot == .unknown ? nil : shot.title
    }
}

/// Angles from one camera: each of this Mac's cameras can also make a medium and a close-up that follow your face.
/// They're cut from the camera's picture on this Mac; nothing more is captured or sent.
struct VirtualAnglesRow: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let angles = studio.angles
        let cameras = angles.angles.filter { $0.kind == .mac }
        if !cameras.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "From one camera")
                // A single camera still asking for 4K gets its row, so Back to 1080p stays in reach.
                if angles.angles.count == 1, let cam = cameras.first, !angles.asks4K(cam.sourceID) {
                    // A single camera: the shuffle has nothing to cut to until it makes angles. Whether it can depends
                    // on its picture and how close you sit, so nothing is promised before it has seen you.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Only one camera? Try making a medium and a close-up from it for the shuffle to cut to. If your camera can't make them, this says why once it has seen you.")
                            .font(.fc(12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        PillButton(title: "Make angles from \(cam.name)", systemImage: "crop", prominent: true) {
                            angles.setVirtual(camera: cam.sourceID, shots: VirtualShots())
                        }
                        .disabled(studio.isRecording)
                        Text("They follow your face, cut from the camera's picture on this Mac. Nothing more is captured or sent.")
                            .font(.fc(10.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentFill))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.45)))
                } else {
                    ForEach(cameras) { VirtualCameraRow(camera: $0) }
                }
                // Only angles 1–6 have number keys.
                if angles.angles.count > 6, angles.angles.contains(where: \.isVirtual) {
                    Text("\(angles.angles.count) angles: number keys reach the first 6. Turn off a close-up, or use Next.")
                        .font(.fc(10.5)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One camera under From one camera: a button to make its angles; once on, its shots, how sharp they are, why one
/// is missing, and 4K when the camera has it.
struct VirtualCameraRow: View {
    @Environment(Studio.self) var studio
    let camera: CameraAngle
    var body: some View {
        let angles = studio.angles
        let id = camera.sourceID
        let recording = studio.isRecording
        VStack(alignment: .leading, spacing: 6) {
            if let shots = angles.settings.virtual.cameras[id.uuidString] {
                HStack(spacing: 6) {
                    Image(systemName: camera.icon).font(.system(size: 10)).foregroundStyle(Theme.text3)
                    Text(camera.name).font(.fc(12, .semibold)).lineLimit(1)
                    Spacer()
                    Button("Turn off") { angles.setVirtual(camera: id, shots: nil) }
                        .buttonStyle(.plain).font(.fc(11.5, .semibold)).foregroundStyle(Theme.text3)
                        .disabled(recording).opacity(recording ? 0.45 : 1)
                        .help("Stop making angles from \(camera.name).")
                }
                HStack(spacing: 6) {
                    ForEach(VirtualShot.allCases, id: \.self) { chip($0, shots) }
                }
                .disabled(recording).opacity(recording ? 0.45 : 1)
                if recording {
                    Text("After the recording: each angle has its own file until it stops.")
                        .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                }
                // The framer isn't observed (it changes with every face it sees), so this reads it once a second.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 3) {
                        if let q = angles.virtualQuality(camera: id) {
                            Text(q).font(.fc(10.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(angles.virtualProblems(camera: id), id: \.self) { r in
                            Text(r).font(.fc(10.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                        }
                        // Center Stage reframes the picture itself; Framecast only says so, never changes it.
                        if angles.centerStageOn(id) {
                            Text("Center Stage is on, so the medium and close-up move twice. Turn it off in Control Center › Video Effects.")
                                .font(.fc(10.5)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                fourK(angles, id)
            } else {
                PillButton(title: "Make angles from \(camera.name)", systemImage: "crop") { angles.setVirtual(camera: id, shots: VirtualShots()) }
                    .disabled(recording)
                Text("Adds a medium and a close-up that follow your face.")
                    .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                // Still asking for 4K with the shots off: Back to 1080p stays here.
                if angles.asks4K(id) { fourK(angles, id) }
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.control2))
    }

    /// "Medium ✓": one shot on or off (both off stops making angles from this camera).
    func chip(_ s: VirtualShot, _ shots: VirtualShots) -> some View {
        let on = shots[s]
        let name = s == .medium ? "medium shot" : "close-up"
        return Button {
            var x = shots
            x[s].toggle()
            studio.angles.setVirtual(camera: camera.sourceID, shots: x)
        } label: {
            HStack(spacing: 4) {
                Text(s.title).font(.fc(11.5, .semibold))
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(on ? Theme.accentInk : Theme.text2)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(on ? Theme.accent : Theme.control))
            .overlay(Capsule().stroke(on ? .clear : Theme.hairline))
        }
        .buttonStyle(.plain)
        .help(on ? "Stop making a \(name)." : "Make a \(name) too.")
    }

    /// 4K, when the camera has it: a sharper medium and close-up. Only this camera restarts (its picture stops for a second), so not
    /// while live or recording.
    @ViewBuilder func fourK(_ angles: CameraAngles, _ id: UUID) -> some View {
        let busy = angles.liveOrRecording
        if angles.asks4K(id) {
            HStack {
                Text("Asking this camera for 4K.").font(.fc(10.5)).foregroundStyle(Theme.text4)
                Spacer()
                Button("Back to 1080p") { angles.use4K(camera: id, false) }
                    .buttonStyle(.plain).font(.fc(11.5, .semibold)).foregroundStyle(Theme.accent)
                    .disabled(busy).opacity(busy ? 0.45 : 1)
                    .help("Uses less power. The camera restarts, and its picture stops for a second.")
            }
        } else if angles.offers4K(id) == true {
            PillButton(title: "Use 4K from this camera") { angles.use4K(camera: id, true) }
                .disabled(busy)
                .help("A sharper medium and close-up. The camera restarts (its picture stops for a second), and 4K uses more power.")
            if busy {
                Text("After the show: the camera restarts, and its picture stops for a second.")
                    .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Phones knocking on the camera link.
struct WaitingDevices: View {
    @Environment(Studio.self) var studio
    var body: some View {
        ForEach(studio.guests.devices.filter { $0.status == .waiting }) { d in
            HStack {
                Image(systemName: "iphone").foregroundStyle(Theme.text3)
                Text("\(d.name) wants to join as a camera").font(.fc(12)).lineLimit(2)
                Spacer()
                PillButton(title: "Let in", prominent: true) { studio.guests.admit(d.id) }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.control2))
        }
    }
}

/// Switching keys: one key per action, working from any app (so nothing shows on a shared window). A single key
/// stops typing in other apps while they're on, so they have an on/off switch (⌃⌥⌘K).
struct SwitchingKeys: View {
    @Environment(Studio.self) var studio
    @Local var recordingAction: AngleKeyAction?
    @Local var recorder = KeyRecorder()
    var body: some View {
        let angles = studio.angles
        let s = angles.settings
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Switching keys")
                Spacer()
                Toggle("", isOn: Binding(get: { s.keysOn }, set: { on in var x = angles.settings; x.keysOn = on; angles.settings = x }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help("⌃⌥⌘K turns them on or off from any app.")
            }
            Text(s.keysOn
                 ? "On: these keys switch angles from any app, so nothing shows on a shared window. Single keys don't type elsewhere until you turn this off (⌃⌥⌘K)."
                 : "Off: turn on before you go live, or press ⌃⌥⌘K from any app. ⌃⌥⌘1–6, ⌃⌥⌘0 and ⌃⌥⌘S always work.")
                .font(.fc(10.5)).foregroundStyle(s.keysOn ? Theme.text3 : Theme.text4).fixedSize(horizontal: false, vertical: true)
            ForEach(AngleKeyAction.allCases) { a in
                HStack {
                    Text(a.title).font(.fc(12)).foregroundStyle(Theme.text2)
                    if let n = a.number, angles.angles.indices.contains(n - 1) {
                        Text(angles.angles[n - 1].name).font(.fc(11)).foregroundStyle(Theme.text4).lineLimit(1)
                    }
                    Spacer()
                    KeyRecorderButton(combo: s.key(a), recording: recordingAction == a) { record(a) }
                }
            }
            HStack(spacing: 6) {
                Menu("Use a set") {
                    ForEach(AngleKeyPreset.allCases) { p in
                        Button(p.title) {
                            var x = angles.settings
                            x.keys = Dictionary(uniqueKeysWithValues: p.keys.map { ($0.key.rawValue, $0.value) })
                            angles.settings = x
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.fc(11.5, .semibold))
                Spacer()
                if recordingAction != nil { Text("Esc cancels · Delete clears").font(.fc(10.5)).foregroundStyle(Theme.text4) }
            }
            if !angles.keyProblems.isEmpty {
                Text("Taken by another app or shortcut: \(angles.keyProblems.joined(separator: ", ")). Record another key for them.")
                    .font(.fc(10.5)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func record(_ a: AngleKeyAction) {
        if recordingAction == a { stopRecording(); return }
        recordingAction = a
        GlobalHotkeys.pauseAngleKeys(true)        // so the key press reaches the recorder
        recorder.begin({ combo in
            if let combo { set(a, combo) }
            stopRecording()
        }, clear: { set(a, nil); stopRecording() })
    }

    private func set(_ a: AngleKeyAction, _ combo: KeyCombo?) {
        // Framecast's fixed shortcuts win over switching keys, so one of them can't be a switching key.
        if let combo, let owner = GlobalHotkeys.defaults.first(where: { UInt32($0.key) == combo.key && UInt32($0.mods) == combo.mods }) {
            studio.notice = "\(combo.title) is already Framecast's shortcut to \(owner.title.lowercased()). Pick another key."
            return
        }
        var x = studio.angles.settings
        // One key does one thing: the action that had this key loses it.
        if let combo { for (k, v) in x.keys where v == combo { x.keys[k] = nil } }
        x.keys[a.rawValue] = combo
        studio.angles.settings = x
    }

    private func stopRecording() {
        recorder.end()
        if recordingAction != nil { recordingAction = nil; GlobalHotkeys.pauseAngleKeys(false) }
    }
}

/// How the shuffle cuts.
struct ShuffleSettings: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let angles = studio.angles
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Shuffle")
            Picker("", selection: Binding(get: { angles.settings.pace }, set: { angles.settings.pace = $0 })) {
                ForEach(ShufflePace.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(paceNote(angles.settings.pace)).font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
            Toggle("Cut to the camera you turn to", isOn: Binding(get: { angles.settings.followLook }, set: { angles.settings.followLook = $0 }))
                .toggleStyle(.checkbox).font(.fc(12))
                .help("Look straight into a phone camera for a moment and the shuffle cuts to it; look back and it cuts back.")
            Toggle("Keep me in frame in phone angles", isOn: Binding(get: { angles.settings.keepFramed }, set: { angles.settings.keepFramed = $0 }))
                .toggleStyle(.checkbox).font(.fc(12))
                .help("An angle shaped unlike your frame (an upright phone in a 16:9 frame) is moved so your face stays in it.")
            Toggle("AI picks angles from what you say", isOn: Binding(get: { angles.settings.aiPicks }, set: { angles.settings.aiPicks = $0 }))
                .toggleStyle(.checkbox).font(.fc(12))
                .help("While the shuffle runs, the AI hears you and suggests an angle about every 10 s; it goes on air at your next pause.")
            let ai = OnDeviceAngleAI.availability
            Text(angles.settings.useAPIKey
                 ? "Using your API key in Settings › AI (each pick costs a little)."
                 : ai.ok ? "Apple's on-device model, on this Mac: free and private." : "On-device AI: \(ai.note). The shuffle still cuts by your pauses, your face and where you look.")
                .font(.fc(10.5)).foregroundStyle(ai.ok || angles.settings.useAPIKey ? Theme.text4 : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            if !angles.ears.status.isEmpty {
                Text(angles.ears.status).font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
            if let p = angles.lastPick, angles.settings.aiPicks {
                Text("Last suggestion: \(angles.angles.first { $0.id == p.angle }?.name ?? p.angle) · \(p.reason)")
                    .font(.fc(10.5)).foregroundStyle(Theme.text3).lineLimit(2)
            }
            Toggle("Use my API key instead (costs money)", isOn: Binding(get: { angles.settings.useAPIKey }, set: { angles.settings.useAPIKey = $0 }))
                .toggleStyle(.checkbox).font(.fc(11.5))
                .help("Claude or OpenAI with your key in Settings › AI. It can also look at each angle once.")
            if angles.settings.useAPIKey {
                HStack(spacing: 8) {
                    PillButton(title: "Check angles with the AI") { angles.analyse() }
                        .disabled(angles.angles.filter(\.usable).isEmpty || !angles.analysing.isEmpty)
                    if !angles.analysing.isEmpty { ProgressView().controlSize(.small) }
                }
            }
            if !angles.aiStatus.isEmpty {
                Text(angles.aiStatus).font(.fc(10.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    func paceNote(_ p: ShufflePace) -> String {
        switch p {
        case .calm: "Holds each angle about 8–14 s."
        case .normal: "Holds each angle about 6–10 s, cutting in your pauses."
        case .lively: "Holds each angle about 4–7 s."
        }
    }
}

/// The frame that shows the angles.
struct MarkedFrameRow: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let angles = studio.angles
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Frame that switches")
            Text(angles.markedFrameTitle ?? "None yet. Holding an angle or turning on the shuffle uses the camera in the layout on air.")
                .font(.fc(12)).foregroundStyle(angles.markedFrameTitle == nil ? Theme.text3 : Theme.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                PillButton(title: "Use the camera on air") { angles.markCameraOnAir() }
                if angles.markedFrame != nil { PillButton(title: "Unmark") { angles.unmark() } }
            }
            Text("Or select any layer and turn on Layer › Shuffle camera angles here. Its background and layout stay; only the picture in that frame changes.")
                .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Lip sync: a phone's picture arrives later than the Mac's microphone hears you, so your voice waits for it while
/// that angle is on air.
struct LipSyncSection: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let angles = studio.angles
        let devices = angles.angles.filter(\.isDevice)
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Lip sync")
            Toggle("Line up my voice with phone angles", isOn: Binding(get: { angles.settings.lipSync }, set: { angles.settings.lipSync = $0 }))
                .toggleStyle(.checkbox).font(.fc(12))
            if devices.isEmpty {
                Text("A phone's picture arrives a little after your microphone hears you. Phones join camera only; set how late each one is here, or tick \"Also lend the microphone\" on its page before joining and click Measure. Your voice then waits that long while the phone is on air; the change happens in a pause.")
                    .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(devices) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(a.name).font(.fc(12, .semibold)).lineLimit(1)
                        Spacer()
                        if angles.lining == a.id { ProgressView().controlSize(.small) }
                        else { Button("Measure") { angles.lineUp(a.id) }.buttonStyle(.plain).font(.fc(11.5, .semibold)).foregroundStyle(Theme.accent) }
                    }
                    let ms = angles.syncMs[a.id]
                    ValueRow(title: "Late by", value: Binding(get: { ms ?? 0 }, set: { angles.setSync(a.id, ms: ($0 / 5).rounded() * 5) }),
                             range: 0...600, step: 5, reset: ms ?? 0, format: { "\(Int($0)) ms" }, parse: { Double($0.replacingOccurrences(of: "ms", with: "").trimmingCharacters(in: .whitespaces)) })
                    Text(ms == nil ? "Not measured yet: your voice doesn't wait for it." : "Your voice waits \(Int(angles.holdMs(for: a.id))) ms while it's on air.")
                        .font(.fc(10.5)).foregroundStyle(Theme.text4)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.control2))
            }
            if !angles.syncStatus.isEmpty {
                Text(angles.syncStatus).font(.fc(10.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What a recording keeps.
struct AngleRecordingRow: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let angles = studio.angles
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "When you record")
            Picker("", selection: Binding(get: { angles.settings.recordAngles }, set: { angles.settings.recordAngles = $0 })) {
                Text("Record the show").tag(false)
                Text("Record the show and each angle").tag(true)
            }.pickerStyle(.radioGroup).labelsHidden().font(.fc(12))
            // Crops are left out unless ticked: their camera's file already holds them.
            if angles.angles.contains(where: \.isVirtual) {
                Toggle("Also record the medium and close-up", isOn: Binding(get: { angles.settings.virtual.recordCrops }, set: { angles.settings.virtual.recordCrops = $0 }))
                    .toggleStyle(.checkbox).font(.fc(12)).padding(.leading, 18)
                    .disabled(!angles.settings.recordAngles)
                    .help("A file for each medium and close-up too. Their camera's own file already holds them, and each file is a full render.")
            }
            Text("Each angle gets its own 16:9 file with the show's sound, for editing later. Not recording keeps nothing.")
                .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The camera link phones open to join as angles.
struct CameraLinkRow: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let room = studio.guests!
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Camera link")
            if room.isOpen {
                HStack {
                    Text(room.deviceInviteURL ?? "Making your camera link…").font(.fc(11.5).monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") { if let u = room.deviceInviteURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) } }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.fc(12, .semibold))
                    Button("New") { room.newDeviceLink() }.buttonStyle(.plain).foregroundStyle(Theme.text3).font(.fc(12, .semibold))
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                Text("Open it on each phone or computer (the same link for all), hold phones sideways and put them on a stand. They join camera only. \(room.reachNote)")
                    .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                JoinActivity(devices: true)
            } else {
                Text("The camera link comes with the guest room. Choose who can join in Guests (your Wi-Fi for phones in the room).")
                    .font(.fc(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                PillButton(title: "Open the guest room (\(room.reach.title))", systemImage: "door.left.hand.open", prominent: true) { room.open() }
            }
        }
    }
}

/// The latest steps of joining (knocked, let in, in the room, couldn't connect…), newest first, so a guest or
/// device that can't get in says why.
struct JoinActivity: View {
    @Environment(Studio.self) var studio
    let devices: Bool
    var body: some View {
        let list = studio.guests.joinEvents.filter { $0.device == devices }.suffix(5).reversed()
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(list)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: e.problem ? "exclamationmark.triangle.fill" : "checkmark.circle").font(.system(size: 10))
                            .foregroundStyle(e.problem ? Theme.warning : Theme.text4)
                        Text("\(e.name) \(e.text)").font(.fc(11)).foregroundStyle(e.problem ? Theme.text2 : Theme.text3)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(e.at, style: .time).font(.fc(10).monospacedDigit()).foregroundStyle(Theme.text4)
                    }
                }
            }
        }
    }
}

/// The latest cuts and why they happened.
struct CutLog: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let cuts = studio.angles.cuts.suffix(6).reversed()
        if !cuts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Latest cuts")
                ForEach(Array(cuts)) { c in
                    HStack(spacing: 6) {
                        Text(c.at, style: .time).font(.fc(10.5).monospacedDigit()).foregroundStyle(Theme.text4)
                        Text(c.angle).font(.fc(11, .semibold)).lineLimit(1)
                        Text(c.reason).font(.fc(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
            }
        }
    }
}
