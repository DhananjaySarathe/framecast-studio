import Foundation
import Observation
import AppKit
import CoreImage
import CoreMedia
import FramecastEngine

/// A camera angle: one of this Mac's cameras, a medium or close-up cut from one of them, or a phone or computer
/// that joined through the camera link.
struct CameraAngle: Identifiable, Equatable {
    enum Kind: Equatable { case mac, device(guestID: String), virtual(parent: UUID, shot: VirtualShot) }
    var id: String            // "mac:<source id>", "virt:<camera id>:<shot>" or the device's identity
    var name: String
    var kind: Kind
    var sourceID: UUID        // what the engine draws
    var usable: Bool
    var audioAllowed = false
    var isDevice: Bool { if case .device = kind { return true }; return false }
    var isVirtual: Bool { if case .virtual = kind { return true }; return false }
    /// The camera a crop is cut from.
    var parentID: UUID? { if case .virtual(let p, _) = kind { return p }; return nil }
    var virtualShot: VirtualShot? { if case .virtual(_, let s) = kind { return s }; return nil }
    var icon: String {
        switch kind {
        case .mac: "camera.fill"
        case .device: "iphone"
        case .virtual: "crop"
        }
    }
}

/// What the AI saw when it looked at an angle.
struct AngleLabel: Codable, Equatable {
    var shot: AngleShot
    var side: String
    var subjectVisible: Bool
    var quality: Int
    var about: String
    var title: String { side.isEmpty || side == "none" ? shot.title : "\(shot.title) · \(side)" }
}

/// Angles › how the shuffle cuts, whether the AI picks angles, and what a recording keeps.
struct CameraAngleSettings: Codable, Equatable {
    var pace: ShufflePace = .normal
    var aiPicks = true
    /// Each angle also goes to its own file when recording (with the program's sound, so they line up).
    var recordAngles = false
    /// The shuffle cuts to a camera when the presenter turns to it, and back when they turn back.
    var followLook = true
    /// Angles shaped differently from the frame (a portrait phone in a 16:9 frame) keep the presenter's face in it.
    var keepFramed = true
    /// The presenter's microphone waits for a phone angle's later picture while it's on air (changed in pauses).
    var lipSync = true
    /// Switching keys: one key (or combination) per action, recorded in Angles. They work from any app while on.
    var keys: [String: KeyCombo] = Dictionary(uniqueKeysWithValues: AngleKeyPreset.numbers.keys.map { ($0.key.rawValue, $0.value) })
    /// Not saved: single keys take typing from every app, so they start off each launch (the Angles switch or
    /// ⌃⌥⌘K turns them on for the show).
    var keysOn = false
    func key(_ a: AngleKeyAction) -> KeyCombo? { keys[a.rawValue] }
    /// The AI's picks use Apple's on-device model (free). With this on they use the Claude or OpenAI key in
    /// Settings › AI instead, which costs money per request; it also lets the AI look at each angle once.
    var useAPIKey = false
    /// Angles from one camera: which cameras make a medium and a close-up (none at first).
    var virtual = VirtualAngleSettings()
    enum CodingKeys: String, CodingKey { case pace, aiPicks, recordAngles, followLook, keepFramed, lipSync, keys, useAPIKey, virtual }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pace = (try? c.decodeIfPresent(ShufflePace.self, forKey: .pace)) ?? .normal
        aiPicks = (try? c.decodeIfPresent(Bool.self, forKey: .aiPicks)) ?? true
        recordAngles = (try? c.decodeIfPresent(Bool.self, forKey: .recordAngles)) ?? false
        followLook = (try? c.decodeIfPresent(Bool.self, forKey: .followLook)) ?? true
        keepFramed = (try? c.decodeIfPresent(Bool.self, forKey: .keepFramed)) ?? true
        lipSync = (try? c.decodeIfPresent(Bool.self, forKey: .lipSync)) ?? true
        if let k = try? c.decodeIfPresent([String: KeyCombo].self, forKey: .keys) { keys = k }
        useAPIKey = (try? c.decodeIfPresent(Bool.self, forKey: .useAPIKey)) ?? false
        virtual = (try? c.decodeIfPresent(VirtualAngleSettings.self, forKey: .virtual)) ?? .init()
    }
}

/// Draws a device's latest camera frame in the engine.
final class DeviceAngleSource: VideoSource {
    let id: UUID
    let identity: String
    weak var room: GuestRoom?
    var state: SourceState { .running }
    var nativeSize = CGSize(width: 1920, height: 1080)
    init(id: UUID, identity: String, room: GuestRoom) { self.id = id; self.identity = identity; self.room = room }
    func image(at time: CMTime) -> CIImage? {
        guard let s = room?.deviceFrameSlot(identity), let (pb, _) = s.get(), s.age < 3 else { return nil }
        let img = CIImage(cvPixelBuffer: pb).rotatedUpright(s.rotation)
        nativeSize = img.extent.size
        return img
    }
    func start() {}
    func stop() {}
}

/// Camera angles and the shuffle. One frame in the layouts can be marked; while the shuffle is on, that frame cuts
/// between the angles like a multicam edit: in pauses of the presenter's voice, holding each angle a while, varying the
/// shot size, giving the frame's own camera the most time (ShufflePlanner). The Mac watches every angle (Vision: where
/// the face is, how tight, which camera the presenter looks into), keeps the presenter framed in angles shaped unlike
/// the frame, and holds the microphone back while a phone's later picture is on air (lip sync, measured from the
/// phone's own microphone). The AI, when set up, looks at each angle once and, while Listen hears the presenter,
/// suggests which angle suits what they're saying; its pick goes on air at the next pause. A tap on an angle pins it
/// (the shuffle waits); a second tap lets it go. An angle that stops sending goes back to the frame's own camera.
@Observable
final class CameraAngles {
    unowned let studio: Studio
    private(set) var angles: [CameraAngle] = []
    var shuffleOn = false { didSet { if shuffleOn != oldValue { shuffleChanged() } } }
    private(set) var pinnedID: String?
    /// The angle in the shuffle frame (nil: the frame shows its own source).
    private(set) var currentID: String?
    private(set) var labels: [String: AngleLabel] = [:]
    private(set) var analysing: Set<String> = []
    var aiStatus = ""
    struct CutNote: Identifiable, Equatable { let id = UUID(); var angle: String; var reason: String; var at: Date; var t = HostClock.seconds() }
    private(set) var cuts: [CutNote] = []
    /// The AI's latest suggestion (shown in Angles; a test can read it).
    private(set) var lastPick: AngleAI.Pick?
    /// What the Mac sees in each angle (AngleWatch).
    private(set) var sights: [String: AngleSight] = [:]
    /// The latest small picture of each angle (the Angles tiles; refreshed faster while they're shown).
    private(set) var pictures: [String: CGImage] = [:]
    /// Angles tiles on screen now.
    @ObservationIgnored var tilesShown = 0
    /// Milliseconds each device angle's picture arrives after this Mac's microphone hears the same moment.
    private(set) var syncMs: [String: Double] = [:]
    /// The device whose sound is being lined up now.
    private(set) var lining: String?
    var syncStatus = ""
    /// Switching keys macOS wouldn't give Framecast (taken by another app or shortcut).
    var keyProblems: [String] = []
    /// "1–6 angles, 0 your camera, S shuffle" for notices.
    var keysSummary: String {
        let s = settings
        let angles = (1...6).compactMap { n in AngleKeyAction.allCases.first { $0.number == n }.flatMap { s.key($0)?.title } }
        var parts: [String] = []
        if !angles.isEmpty { parts.append("\(angles.first!)–\(angles.last!) angles") }
        if let k = s.key(.ownCamera) { parts.append("\(k.title) your camera") }
        if let k = s.key(.shuffle) { parts.append("\(k.title) shuffle") }
        return parts.joined(separator: ", ")
    }

    @ObservationIgnored private var planner = ShufflePlanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var deviceSources: [String: UUID] = [:]
    // Angles from one camera: one rig per camera that makes crops, and each crop's engine source. A crop's UUID stays
    // the same for the session, like a device's.
    @ObservationIgnored private(set) var rigs: [UUID: VirtualRig] = [:]
    @ObservationIgnored private var virtualIDs: [String: UUID] = [:]
    @ObservationIgnored private var virtualSources: [String: VirtualAngleSource] = [:]
    @ObservationIgnored private var fourK: [String: Bool] = [:]      // camera device id: has a 4K format
    @ObservationIgnored private var tallied: String?
    // The presenter's voice, sampled from the program mix.
    @ObservationIgnored private var lastLoud = -1e9
    @ObservationIgnored private var speakingSince: Double?
    @ObservationIgnored private var longLevel: Float = 0
    @ObservationIgnored private var phraseLevel: Float = 0
    @ObservationIgnored private var lastPhraseLoud = false
    // What Listen heard (any show or none), for the AI's picks.
    @ObservationIgnored private var heard: [(t: Double, text: String)] = []
    @ObservationIgnored private var heardGuess = ""
    @ObservationIgnored private var heardGuessAt = 0.0
    @ObservationIgnored private var aiHint: (id: String, until: Double)?
    @ObservationIgnored private var lastAdvice = -1e9
    @ObservationIgnored private var adviceInFlight = false
    @ObservationIgnored private var autoLooked: Set<String> = []
    // Watching the angles.
    @ObservationIgnored private let watch = AngleWatch()
    /// Hears the presenter for the AI when Listen isn't running.
    @ObservationIgnored lazy var ears = AngleEars(studio: studio)
    @ObservationIgnored private var lastWatch = -1e9
    @ObservationIgnored private var lastFaceLook = -1e9
    @ObservationIgnored private var faceTargets: [String: CGPoint] = [:]
    /// Vision's looks at each angle since launch, and how many found a face (the angles dump).
    @ObservationIgnored private var looks: [String: (n: Int, faces: Int)] = [:]
    @ObservationIgnored private var stalledSince: Double?
    // Lip sync.
    @ObservationIgnored private let aligner = SoundAligner()
    @ObservationIgnored private var liningStarted = 0.0
    @ObservationIgnored private var lastEstimate = 0.0
    @ObservationIgnored private var estimating = false
    @ObservationIgnored private var estimates: [Double] = []
    @ObservationIgnored private var lineQueue: [String] = []
    @ObservationIgnored private var measureMic: UUID?
    @ObservationIgnored private var measureOther: UUID?
    @ObservationIgnored private(set) var appliedHold = 0.0
    @ObservationIgnored private var holdPendingSince: Double?
    /// Test launches: a scripted voice (talk 3 s, pause 0.6 s) instead of the microphone.
    @ObservationIgnored var testVoice = false
    /// Test launches: the presenter "looks into" this angle (instead of what Vision sees).
    @ObservationIgnored var testFacing: String?
    /// Test launches: line up against the device's own sound moved this many ms earlier (no Mac microphone needed).
    @ObservationIgnored var testLineUpShift: Double?
    /// Test launches: the face cameras with crops "see" (top-left box in the camera picture, and yaw), instead of
    /// what Vision sees.
    @ObservationIgnored var testFace: (box: CGRect, yaw: Double?)? {
        // Starting or stopping the scripted face: the crops follow the next face at once, as a new presenter.
        didSet { if (oldValue == nil) != (testFace == nil) { for r in rigs.values { r.refollow(at: HostClock.seconds()) } } }
    }
    @ObservationIgnored private var lastTestFace = -1e9
    @ObservationIgnored private var testVoiceStart = HostClock.seconds()

    init(studio: Studio) { self.studio = studio }

    var settings: CameraAngleSettings {
        get { studio.settings.s.cameraAngles ?? CameraAngleSettings() }
        set {
            let old = settings
            studio.settings.s.cameraAngles = newValue; planner.pace = newValue.pace
            if old.keys != newValue.keys || old.keysOn != newValue.keysOn { GlobalHotkeys.applyAngleKeys() }
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        rebuild()
    }

    // MARK: The marked frame

    /// The frame that shuffles: its layout and the item (16:9 list first).
    var markedFrame: (scene: StudioScene, item: SceneItem)? {
        for s in studio.scenes {
            if let it = s.horizontal.first(where: { $0.shufflesAngles == true }) ?? s.vertical.first(where: { $0.shufflesAngles == true }) { return (s, it) }
        }
        return nil
    }

    /// What the marked frame is called in the UI ("Camera in Just me").
    var markedFrameTitle: String? {
        guard let m = markedFrame else { return nil }
        return "\(studio.source(m.item.sourceID)?.name ?? "A frame") in \(m.scene.name)"
    }

    /// Whether the marked frame is in a layout on air now.
    var frameOnAir: Bool {
        guard let m = markedFrame else { return false }
        return CanvasKind.allCases.contains { c in (c == .horizontal || studio.isVerticalOn) && studio.programID(c) == m.scene.id }
    }

    /// Marks one frame (v1: one in the whole studio). Its 9:16 twin is the item with the same id, or else the one
    /// showing the same source in the same role.
    func mark(itemID: UUID, sceneID: UUID) {
        var c = studio.collection
        for i in c.scenes.indices {
            c.scenes[i].horizontal = c.scenes[i].horizontal.map { var x = $0; x.shufflesAngles = nil; return x }
            c.scenes[i].vertical = c.scenes[i].vertical.map { var x = $0; x.shufflesAngles = nil; return x }
        }
        guard let si = c.scenes.firstIndex(where: { $0.id == sceneID }) else { studio.collection = c; return }
        let s = c.scenes[si]
        let item = s.horizontal.first { $0.id == itemID } ?? s.vertical.first { $0.id == itemID }
        guard let item else { studio.collection = c; return }
        func twin(_ list: [SceneItem]) -> Int? {
            list.firstIndex { $0.id == item.id } ?? list.firstIndex { $0.sourceID == item.sourceID && $0.role == item.role }
        }
        if let h = twin(s.horizontal) { c.scenes[si].horizontal[h].shufflesAngles = true }
        if let v = twin(s.vertical) { c.scenes[si].vertical[v].shufflesAngles = true }
        studio.collection = c
        rebuild()
        studio.refreshAir()
    }

    /// Marks the camera in the layout on air (the usual choice).
    func markCameraOnAir() {
        guard let s = studio.programScene(.horizontal),
              let it = s.horizontal.first(where: { $0.role == .camera }) ?? s.horizontal.first(where: { if case .camera? = studio.source($0.sourceID)?.kind { return true }; return false })
        else { aiStatus = "The layout on air has no camera frame to mark."; return }
        mark(itemID: it.id, sceneID: s.id)
    }

    func unmark() {
        var c = studio.collection
        for i in c.scenes.indices {
            c.scenes[i].horizontal = c.scenes[i].horizontal.map { var x = $0; x.shufflesAngles = nil; return x }
            c.scenes[i].vertical = c.scenes[i].vertical.map { var x = $0; x.shufflesAngles = nil; return x }
        }
        studio.collection = c
        shuffleOn = false; pinnedID = nil; setCurrent(nil, reason: "frame unmarked")
    }

    // MARK: Angles

    /// The angle the marked frame shows by itself (its own camera); it gets the most screen time.
    var primaryID: String? {
        if let m = markedFrame, angles.contains(where: { $0.id == "mac:\(m.item.sourceID)" }) { return "mac:\(m.item.sourceID)" }
        return angles.first { $0.kind == .mac }?.id ?? angles.first?.id
    }

    /// Called when devices join, leave, start or stop sending video.
    func devicesChanged() { rebuild() }

    func rebuild() {
        var list: [CameraAngle] = []
        let now = HostClock.seconds()
        var crops: Set<String> = []
        let frames = rigs.isEmpty && settings.virtual.cameras.isEmpty ? [:] : markedFrameSizes()
        let view = markedFrameView()
        for s in studio.collection.sources {
            guard case .camera = s.kind else { continue }
            let running = studio.engine.state(of: s.id) == .running
            list.append(CameraAngle(id: "mac:\(s.id)", name: s.name, kind: .mac, sourceID: s.id, usable: running))
            // Angles from one camera: its medium and close-up come straight after it (keys 1, 2 and 3).
            guard let shots = settings.virtual.cameras[s.id.uuidString], shots.any else { continue }
            let rig = rigs[s.id] ?? VirtualRig(cameraID: s.id)
            rigs[s.id] = rig
            placeRig(rig, camera: s.id, frames: frames, view: view, shots: shots)
            for shot in VirtualShot.allCases where shots[shot] {
                let id = Self.virtualID(s.id, shot)
                crops.insert(id)
                let uuid = virtualIDs[id] ?? UUID()
                virtualIDs[id] = uuid
                if virtualSources[id]?.rig !== rig {
                    let src = VirtualAngleSource(id: uuid, shot: shot, rig: rig)
                    virtualSources[id] = src
                    studio.engine.setExternalSource(uuid, src)
                }
                list.append(CameraAngle(id: id, name: "\(s.name) · \(shot.title)", kind: .virtual(parent: s.id, shot: shot),
                                        sourceID: uuid, usable: running && rig.usable(shot, now: now)))
            }
        }
        if let room = studio.guests {
            var keep: Set<String> = []
            for g in room.devices where g.status != .waiting {
                let slot = room.deviceFrameSlot(g.identity)
                // A device that dropped (kept for 3 minutes) keeps its angle number, source and delay, marked as
                // not sending; a new one appears once it sends its first picture.
                guard slot != nil || deviceSources[g.identity] != nil else { continue }
                keep.insert(g.identity)
                let id: UUID
                if let known = deviceSources[g.identity] { id = known }
                else {
                    id = UUID(); deviceSources[g.identity] = id
                    studio.engine.setExternalSource(id, DeviceAngleSource(id: id, identity: g.identity, room: room))
                }
                list.append(CameraAngle(id: g.identity, name: g.name, kind: .device(guestID: g.id), sourceID: id, usable: (slot?.age ?? .infinity) < 1.5, audioAllowed: g.audioAllowed))
            }
            for (identity, id) in deviceSources where !keep.contains(identity) {
                studio.engine.removeExternalSource(id); deviceSources[identity] = nil
                syncMs[identity] = nil; sights[identity] = nil; pictures[identity] = nil
                lineQueue.removeAll { $0 == identity }
                if lining == identity { finishLining(nil) }
            }
        }
        if list != angles { angles = list }
        if let p = pinnedID, !angles.contains(where: { $0.id == p }) { pinnedID = nil }
        if let c = currentID, !angles.contains(where: { $0.id == c }) { setCurrent(shuffleOn ? primaryID : nil, reason: "the angle left") }
        // Crops that went go only now, once the frame no longer draws them.
        for (id, src) in virtualSources where !crops.contains(id) {
            studio.engine.removeExternalSource(src.id)
            virtualSources[id] = nil
            sights[id] = nil; pictures[id] = nil; labels[id] = nil
        }
        for cam in rigs.keys where !virtualSources.values.contains(where: { $0.baseID == cam }) { rigs[cam] = nil }
        // A new angle gets looked at once (when the AI is set up), so the AI knows its shot size. Crops never: their
        // shot is known, and a look costs money.
        let fresh = angles.filter { $0.usable && !$0.isVirtual && labels[$0.id] == nil && !autoLooked.contains($0.id) }
        if !fresh.isEmpty, settings.aiPicks, settings.useAPIKey, angles.filter({ !$0.isVirtual }).count >= 2 {
            fresh.forEach { autoLooked.insert($0.id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.analyse(fresh.map(\.id), quietly: true) }
        }
    }

    /// The source the marked frame draws now, when it isn't its own (nil: unchanged), whether to mirror it, and
    /// whether it's cut from the frame's own camera.
    var override: (source: UUID, mirrored: Bool?, sameCamera: Bool)? {
        guard let id = currentID, let a = angles.first(where: { $0.id == id }), let m = markedFrame, a.sourceID != m.item.sourceID else { return nil }
        // Phones send the picture the right way round; a Mac camera (or a crop of one) keeps the frame's own mirror.
        return (a.sourceID, a.isDevice ? false : nil, a.parentID == m.item.sourceID)
    }

    // MARK: Angles from one camera

    static func virtualID(_ camera: UUID, _ shot: VirtualShot) -> String { "virt:\(camera):\(shot.rawValue)" }

    /// The marked frame's size in output pixels on each canvas (the whole 16:9 canvas when none is marked).
    func markedFrameSizes() -> [CanvasKind: CGSize] {
        var out: [CanvasKind: CGSize] = [:]
        for c in CanvasKind.allCases {
            let cfg = studio.settings.canvas(c)
            let canvas = CGSize(width: cfg.width, height: cfg.height)
            if let m = markedFrame, let it = m.scene.items(for: c).first(where: { $0.shufflesAngles == true }) {
                out[c] = Compositor.frame(of: it.transform, canvas: canvas).size
            } else if c == .horizontal { out[c] = canvas }
        }
        return out
    }

    /// What the marked frame shows of the camera it was set up for: its Layer › Crop (top-left 0...1; where the 16:9
    /// and 9:16 frames differ, the area both show), and whether either frame is rotated.
    func markedFrameView() -> (camera: UUID?, shown: CGRect, turned: Bool) {
        guard let m = markedFrame else { return (nil, CGRect(x: 0, y: 0, width: 1, height: 1), false) }
        var shown = CGRect(x: 0, y: 0, width: 1, height: 1), turned = false
        for c in CanvasKind.allCases {
            guard let it = m.scene.items(for: c).first(where: { $0.shufflesAngles == true }) else { continue }
            let k = it.crop
            shown = shown.intersection(CGRect(x: k.left, y: k.top, width: max(0.01, 1 - k.left - k.right), height: max(0.01, 1 - k.top - k.bottom)))
            if it.transform.rotationDegrees != 0 { turned = true }
        }
        return (m.item.sourceID, shown.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : shown, turned)
    }

    /// Hands a camera's rig its picture size, the marked frame's sizes, what that frame shows of this camera (its crop
    /// was set for its own camera only; any other shows whole) and whether it's rotated.
    private func placeRig(_ rig: VirtualRig, camera: UUID, frames: [CanvasKind: CGSize], view: (camera: UUID?, shown: CGRect, turned: Bool), shots: VirtualShots) {
        rig.setGeometry(camera: studio.engine.nativeSize(of: camera) ?? CGSize(width: 1920, height: 1080), frames: frames, shots: shots,
                        shown: view.camera == camera ? view.shown : CGRect(x: 0, y: 0, width: 1, height: 1), turned: view.turned)
    }

    /// The marked frame's crop or rotation changed in Layer: the crops follow on the next tick, not at the next rebuild.
    private func refreshRigs() {
        guard !rigs.isEmpty else { return }
        let frames = markedFrameSizes(), view = markedFrameView()
        for (cam, rig) in rigs {
            guard let shots = settings.virtual.cameras[cam.uuidString], shots.any else { continue }
            placeRig(rig, camera: cam, frames: frames, view: view, shots: shots)
        }
    }

    /// Turns a camera's medium and close-up on or off (nil, or neither shot: off). Cameras and phones after it move
    /// up or down as many numbers, and a notice says so. Not while recording: each angle's file is fixed for the take.
    func setVirtual(camera: UUID, shots: VirtualShots?) {
        var s = settings
        s.virtual.cameras[camera.uuidString] = shots?.any == true ? shots : nil
        guard s != settings else { return }
        guard !studio.isRecording else {
            studio.notice = "Change the medium and close-up after the recording: each angle has its own file until it stops."
            return
        }
        let before = Dictionary(angles.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let phonesFrom = angles.firstIndex(where: \.isDevice)
        settings = s
        rebuild()
        let name = studio.source(camera)?.name ?? "Camera"
        var note: [String] = []
        if let i = angles.firstIndex(where: { $0.id == "mac:\(camera)" }) {
            let mine = angles.filter { $0.parentID == camera }
            let one = mine.first?.virtualShot == .medium ? "medium shot" : "close-up"
            note.append(mine.isEmpty ? "Stopped making angles from \(name)."
                        : mine.count == 1 ? "\(name) is angle \(i + 1); its \(one) is angle \(i + 2)."
                        : "\(name) is angle \(i + 1); its medium and close-up are angles \(i + 2)–\(i + 1 + mine.count).")
        }
        // Other Mac cameras after this one (and their medium and close-up) move by as many numbers.
        for (j, a) in angles.enumerated() where a.kind == .mac && a.sourceID != camera {
            guard let old = before[a.id], old != j else { continue }
            let theirs = angles.filter { $0.parentID == a.sourceID }
            let shot = theirs.first?.virtualShot == .medium ? "medium shot" : "close-up"
            note.append(theirs.isEmpty ? "\(a.name) is now angle \(j + 1)."
                        : theirs.count == 1 ? "\(a.name) is now angle \(j + 1), its \(shot) \(j + 2)."
                        : "\(a.name) is now angle \(j + 1), its medium and close-up \(j + 2)–\(j + 1 + theirs.count).")
        }
        if let a = phonesFrom, let b = angles.firstIndex(where: \.isDevice), a != b {
            let n = angles.filter(\.isDevice).count
            note.append(n == 1 ? "The phone is now angle \(b + 1)." : "Phones are now angles \(b + 1)–\(b + n).")
        }
        if angles.count > 6 { note.append("Number keys reach the first 6 angles; use Next for the rest.") }
        if !note.isEmpty { studio.notice = note.joined(separator: " ") }
    }

    /// Asks a camera for 4K (3840×2160), or back for 1080p, so its crops come out sharper. Only that camera restarts,
    /// a gap of about a second, so not while live or recording. A camera without 4K sends its nearest size.
    func use4K(camera: UUID, _ on: Bool) {
        guard let src = studio.source(camera), case .camera(let dev, let w, _, let fps) = src.kind, (w >= 3840) != on else { return }
        guard !liveOrRecording else {
            studio.notice = "Change the camera's size after the show: it restarts, and the picture stops for a second."
            return
        }
        studio.updateSource(camera) { $0.kind = .camera(deviceID: dev, width: on ? 3840 : 1920, height: on ? 2160 : 1080, fps: fps) }
    }

    /// Going live, live or recording: a camera mustn't restart now.
    var liveOrRecording: Bool { studio.streaming.phase != .idle || studio.isRecording }

    /// The camera asks for 4K.
    func asks4K(_ camera: UUID) -> Bool {
        guard case .camera(_, let w, _, _)? = studio.source(camera)?.kind else { return false }
        return w >= 3840
    }

    /// Whether Use 4K would give a camera a 4K picture near 16:9 at its frame rate, read from its list of formats by
    /// the chooser that opens it (the camera isn't opened). Kept per device and frame rate; "Default camera" is asked
    /// each time, as it can change. Test launches with stand-ins never ask the real camera: the 4K clip answers. Nil:
    /// not known (not connected).
    func offers4K(_ camera: UUID) -> Bool? {
        guard case .camera(let dev, _, _, let fps)? = studio.source(camera)?.kind else { return nil }
        if FakeDevices.isOn { return FakeDevices.has4K }
        let key = "\(dev)@\(fps)"
        if !dev.isEmpty, let known = fourK[key] { return known }
        let k = CameraSource.offers4K(deviceID: dev, fps: fps)
        if let k, !dev.isEmpty { fourK[key] = k }
        return k
    }

    /// Whether Center Stage is reframing a camera's picture, so its medium and close-up would move twice (the row
    /// says so). Read only: Framecast never changes the system setting. Test launches never ask the real camera.
    func centerStageOn(_ camera: UUID) -> Bool {
        guard !FakeDevices.isOn, case .camera(let dev, _, _, _)? = studio.source(camera)?.kind else { return false }
        return CameraSource.centerStageActive(deviceID: dev) == true
    }

    /// How sharp each shot a camera offers is, for its row in Angles ("Medium: a little soft (1.4×) · Close-up: sharp,
    /// soft in 9:16 (2.2×)"); nil when none is offered.
    func virtualQuality(camera: UUID) -> String? {
        guard let rig = rigs[camera] else { return nil }
        let parts = angles.compactMap { a -> String? in
            guard a.parentID == camera, let s = a.virtualShot else { return nil }
            let p = rig.status(s)
            guard p.available else { return nil }
            let e = String(format: "%.1f×", p.enlargement[.horizontal] ?? 1)
            var line = "\(s.title): \(p.grade.title)\(p.grade == .sharp ? "" : " (\(e))")"
            // The grade is the 16:9 frame's; a 9:16 frame from a landscape camera is enlarged more.
            if studio.isVerticalOn, let v = p.enlargement[.vertical], CropGrade(enlargement: v) != p.grade {
                line += String(format: ", %@ in 9:16 (%.1f×)", CropGrade(enlargement: v).title, v)
            }
            return line
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Why a camera's crops can't go on air now, each reason once ("Close-up needs a 4K camera").
    func virtualProblems(camera: UUID) -> [String] {
        var out: [String] = []
        for a in angles where a.parentID == camera {
            if let r = virtualReason(a), !out.contains(r) { out.append(r) }
        }
        return out
    }

    /// The parent camera's angle id for a crop (the planner treats crops of one camera as punch-ins), else nil.
    private func plannerCamera(_ id: String) -> String? {
        angles.first { $0.id == id }?.parentID.map { "mac:\($0)" }
    }

    /// Why a crop can't go on air now, as the Angles row says it.
    func virtualReason(_ a: CameraAngle) -> String? {
        guard case .virtual(let p, let shot) = a.kind else { return nil }
        guard studio.engine.state(of: p) == .running else { return "The camera isn't sending a picture" }
        guard let rig = rigs[p] else { return "Looking for you…" }
        if let r = rig.status(shot).reason {
            // The framer knows only the picture's size: a camera that has 4K but sends 1080p needs Use 4K, not a new camera.
            if r.hasSuffix("needs a 4K camera"), !asks4K(p), offers4K(p) == true { return "\(shot.title) needs 4K from this camera" }
            return r
        }
        let now = HostClock.seconds()
        if rig.usable(shot, now: now) { return nil }
        return rig.seen(now: now) ? "Move nearer the middle of the picture" : "Looking for you…"
    }

    /// "Angle 3 (Camera · Close-up) isn't sending a picture, so it stays off air." or a crop's reason.
    private func offAirNote(_ a: CameraAngle, number n: Int) -> String {
        guard let why = virtualReason(a) else { return "Angle \(n) (\(a.name)) isn't sending a picture, so it stays off air." }
        let end = why.hasSuffix("…") || why.hasSuffix(".") ? "" : "."
        return "Angle \(n) (\(a.name)) stays off air: \(why)\(end) (Angles › From one camera)"
    }

    /// Tap: put this angle in the frame and hold it there (the shuffle waits); tap again to let the shuffle go on.
    func tap(_ id: String) {
        if pinnedID == id {
            pinnedID = nil
            if !shuffleOn { setCurrent(nil, reason: "unpinned") }
            return
        }
        guard let i = angles.firstIndex(where: { $0.id == id }) else { return }
        // A medium or close-up that can't go on air now stays off, as the number keys refuse it (its tile says why).
        if angles[i].isVirtual, !angles[i].usable { studio.notice = offAirNote(angles[i], number: i + 1); return }
        if markedFrame == nil { markCameraOnAir() }
        pinnedID = id
        if shuffleOn { planner.force(id, now: HostClock.seconds(), shot: plannerShot(id), camera: plannerCamera(id)) }
        setCurrent(id, reason: "pinned by you")
    }

    // MARK: Shortcuts (⌃⌥⌘1–6, ⌃⌥⌘0, ⌃⌥⌘S; they work from any app)

    /// Angle N (1-based: this Mac's cameras first, then devices in the order they joined) into the frame; the same
    /// key again lets go of it.
    func pick(number n: Int) {
        rebuild()
        guard angles.indices.contains(n - 1) else { studio.notice = "There's no camera angle \(n). Invite a phone with the camera link (Guests), or make angles from one camera (Angles › From one camera)."; return }
        let a = angles[n - 1]
        guard a.usable || pinnedID == a.id else { studio.notice = offAirNote(a, number: n); return }
        tap(a.id)
        studio.notice = pinnedID == a.id ? "Angle \(n): \(a.name)" : (shuffleOn ? "Shuffle goes on" : "Back to your camera")
    }

    // MARK: Switching keys (one key each, set in Angles; they work from any app while on)

    /// Puts angle N in the frame and holds it there (pressing it again keeps it; your own camera's key or Shuffle
    /// lets go).
    func cut(to n: Int) {
        rebuild()
        guard angles.indices.contains(n - 1) else { studio.notice = "There's no camera angle \(n) yet."; return }
        let a = angles[n - 1]
        guard a.usable else { studio.notice = offAirNote(a, number: n); return }
        if pinnedID != a.id { tap(a.id) }
        studio.notice = "Angle \(n): \(a.name)"
    }

    /// The next (or previous) angle that's sending pictures, held in the frame.
    func step(_ delta: Int) {
        rebuild()
        let live = angles.filter(\.usable)
        guard !live.isEmpty else { return }
        let cur = live.firstIndex { $0.id == (currentID ?? primaryID) } ?? -1
        let next = live[((cur + delta) % live.count + live.count) % live.count]
        if pinnedID != next.id { tap(next.id) }
        studio.notice = "Angle \((angles.firstIndex { $0.id == next.id } ?? 0) + 1): \(next.name)"
    }

    /// Shuffle key: while an angle is held with the shuffle on, lets go of it (the shuffle goes on); otherwise turns
    /// the shuffle on or off.
    func shuffleKey() {
        if shuffleOn && pinnedID != nil {
            pinnedID = nil
            studio.notice = "Shuffle goes on"
        } else { toggleShuffle() }
    }

    func perform(_ a: AngleKeyAction) {
        if let n = a.number { cut(to: n); return }
        switch a {
        case .ownCamera: backToOwnCamera()
        case .shuffle: shuffleKey()
        case .next: step(1)
        case .previous: step(-1)
        default: break
        }
    }

    func backToOwnCamera() {
        pinnedID = nil
        shuffleOn = false
        setCurrent(nil, reason: "back to your camera")
        studio.notice = "Back to your camera"
    }

    func toggleShuffle() {
        rebuild()
        // Only angles that can go on air count: a medium or close-up its camera can't make is left out.
        let n = angles.filter(offered).count
        if !shuffleOn, n < 2 {
            var why: [String] = []
            for r in angles.filter({ !offered($0) }).compactMap(virtualReason) where !why.contains(r) { why.append(r) }
            studio.notice = why.isEmpty
                ? "Shuffle needs at least two camera angles. Invite a phone with the camera link (Guests), or make angles from one camera (Angles › From one camera)."
                : "Shuffle needs at least two angles that can go on air. The medium and close-up can't now: \(why.joined(separator: "; ")). Invite a phone with the camera link (Guests) for another angle."
            return
        }
        pinnedID = nil
        shuffleOn.toggle()
        studio.notice = shuffleOn ? "Shuffle on: \(n) angles" : "Shuffle off"
    }

    /// Whether an angle can go on air: cameras and phones (a dropped one comes back), and a medium or close-up whose
    /// shot is offered or still waiting for the first look at the presenter.
    func offered(_ a: CameraAngle) -> Bool {
        guard case .virtual(let p, let shot) = a.kind, let plan = rigs[p]?.status(shot) else { return true }
        return plan.available || plan.reason == VirtualFramer.waiting
    }

    /// "⌃⌥⌘2" for the angle with this id.
    func shortcut(for id: String) -> String? {
        angles.firstIndex { $0.id == id }.flatMap { $0 < 6 ? "⌃⌥⌘\($0 + 1)" : nil }
    }

    func setDeviceAudio(_ angleID: String, _ on: Bool) {
        guard let a = angles.first(where: { $0.id == angleID }), case .device(let gid) = a.kind else { return }
        studio.guests.setDeviceAudio(gid, on)
        rebuild()
    }

    func removeDevice(_ angleID: String) {
        guard let a = angles.first(where: { $0.id == angleID }), case .device(let gid) = a.kind else { return }
        studio.guests.remove(gid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.rebuild() }
    }

    private func shuffleChanged() {
        if shuffleOn {
            if markedFrame == nil { markCameraOnAir() }
            planner = ShufflePlanner(seed: UInt64.random(in: 1...UInt64.max))
            planner.pace = settings.pace
            let start = pinnedID ?? currentID ?? primaryID
            if let s = start { planner.force(s, now: HostClock.seconds(), shot: plannerShot(s), camera: plannerCamera(s)) }
            if pinnedID == nil { setCurrent(start, reason: "shuffle on") }
        } else if pinnedID == nil {
            setCurrent(nil, reason: "shuffle off")
        }
    }

    private func setCurrent(_ id: String?, reason: String) {
        guard id != currentID else { return }
        currentID = id
        // The log names the angle now in the frame (nil: the frame's own camera).
        if let a = angles.first(where: { $0.id == (id ?? primaryID) }) {
            cuts.append(CutNote(angle: a.name, reason: reason, at: Date()))
            if cuts.count > 40 { cuts.removeFirst(cuts.count - 40) }
        }
        studio.refreshAir()
        updateTally()
    }

    /// A device page (re)connected and starts with no tally: if its angle is live, tell it again.
    func deviceArrived(_ identity: String) {
        guard tallied == identity else { return }
        tallied = nil
        updateTally()
    }

    /// Devices show a red frame while their angle is in a layout on air.
    private func updateTally() {
        let live = frameOnAir ? (currentID ?? primaryID) : nil
        let identity = live.flatMap { id in angles.first { $0.id == id && $0.isDevice }?.id }
        guard identity != tallied else { return }
        if let old = tallied { studio.guests.tellDevice(old, onAir: false) }
        if let new = identity { studio.guests.tellDevice(new, onAir: true) }
        tallied = identity
    }

    // MARK: The clock

    @ObservationIgnored private var ticks = 0
    private func tick() {
        let now = HostClock.seconds()
        ticks += 1
        // Cameras added or removed in the studio; in between, the marked frame's crop and rotation.
        if ticks % 20 == 0 { rebuild() } else { refreshRigs() }
        // The AI picks between angles: speech recognition runs only while there are two that can go on air.
        if ticks % 10 == 0 { ears.keep(settings.aiPicks && shuffleOn && aiReady && angles.filter(offered).count >= 2) }
        // Keep usability fresh (a device can stall; a camera can drop).
        var changed = false
        for i in angles.indices {
            let ok: Bool
            switch angles[i].kind {
            case .mac: ok = studio.engine.state(of: angles[i].sourceID) == .running
            case .device: ok = (studio.guests.deviceFrameSlot(angles[i].id)?.age ?? .infinity) < 1.5
            // A crop: its camera sends, and the presenter was seen in the last 1.5 s, inside the shot.
            case .virtual(let p, let shot): ok = studio.engine.state(of: p) == .running && rigs[p]?.usable(shot, now: now) == true
            }
            if ok != angles[i].usable { angles[i].usable = ok; changed = true }
        }
        if changed { updateTally() }
        let voice = sampleVoice(now)
        feedTestFace(now)
        watchAngles(now)
        stepLining(now)
        applyHold(now, voice: voice)
        // The angle on air stopped sending: back to the frame's own camera (the shuffle picks another by itself).
        if let c = currentID, let a = angles.first(where: { $0.id == c }), !a.usable {
            if stalledSince == nil { stalledSince = now }
            if now - stalledSince! > 0.5, pinnedID == c || !shuffleOn {
                stalledSince = nil
                pinnedID = nil
                // A shot whose camera still sends went off air for its own reason; only a lost presenter is "lost
                // sight of you".
                let why = a.isVirtual && studio.engine.state(of: a.parentID!) == .running ? (virtualReason(a) ?? "Looking for you…") : nil
                let what = why.map { $0 == "Looking for you…" ? "lost sight of you" : "went off air: \($0)" }
                if !shuffleOn { setCurrent(nil, reason: what.map { "\(a.name) \($0)" } ?? "\(a.name) stopped sending") }
                studio.notice = what.map { "\(a.name) \($0). Back to your camera." } ?? "\(a.name) stopped sending a picture. Back to your camera."
            }
        } else { stalledSince = nil }
        guard shuffleOn, pinnedID == nil, markedFrame != nil else { return }
        updateTally()
        let pa = angles.map { a -> PlannerAngle in
            // A crop is a punch-in of its camera: soft or pushed off the presenter by the picture's edge, it's
            // quality 2; looking into the camera belongs to the camera itself.
            var quality = labels[a.id]?.quality ?? 3
            if let p = a.parentID, let s = a.virtualShot, let r = rigs[p] { quality = r.status(s).grade == .soft || r.edgeLimited(s) ? 2 : 3 }
            return PlannerAngle(id: a.id, shot: plannerShot(a.id), usable: a.usable && inView(a.id, now),
                                isPrimary: a.id == primaryID, quality: quality,
                                facing: !a.isVirtual && settings.followLook && (testFacing.map { $0 == a.id } ?? (sights[a.id]?.facing(now) ?? false)),
                                yaw: sights[a.id].flatMap { $0.inView(now) ? $0.yaw : nil },
                                camera: a.parentID.map { "mac:\($0)" })
        }
        let hint = aiHint.flatMap { $0.until > now ? $0.id : nil }
        if let cut = planner.step(now: now, angles: pa, voice: voice, hint: hint) {
            if cut.to == hint { aiHint = nil }
            setCurrent(cut.to, reason: cut.reason)
        }
        askForPick(now)
    }

    /// Speaking or not, how long the silence has lasted, and whether the phrase just spoken was louder than usual.
    private func sampleVoice(_ now: Double) -> VoiceState {
        let peak: Float
        if testVoice { let t = (now - testVoiceStart).truncatingRemainder(dividingBy: 3.6); peak = t < 3 ? 0.2 : 0 }
        else { peak = studio.engine.mixer.voicePeak }
        let loud = peak > 0.03                       // about −30 dBFS, as the music ducking uses
        if loud { lastLoud = now; if speakingSince == nil { speakingSince = now; phraseLevel = peak } }
        let speaking = now - lastLoud < 0.18          // bridges the gaps between words
        if speaking {
            phraseLevel += (peak - phraseLevel) * 0.15
            longLevel = longLevel == 0 ? peak : longLevel + (peak - longLevel) * 0.004
            lastPhraseLoud = longLevel > 0.03 && phraseLevel > longLevel * 1.6
        } else { speakingSince = nil }
        let silence = speaking ? 0 : now - lastLoud
        return VoiceState(speaking: speaking, silence: silence, emphasis: lastPhraseLoud && (speaking || silence < 1.5))
    }

    // MARK: Watching the angles

    /// How tight the angle frames the presenter: a detail shot as the AI saw it, else from the face's size, else the
    /// AI's label.
    func plannerShot(_ id: String) -> AngleShot {
        if !rigs.isEmpty, let a = angles.first(where: { $0.id == id }) {
            // A crop is the shot it's cut to; a camera that offers crops is their wide.
            if let s = a.virtualShot { return s.angleShot }
            if a.kind == .mac, let r = rigs[a.sourceID], VirtualShot.allCases.contains(where: { r.status($0).available }) { return .wide }
        }
        if labels[id]?.shot == .detail { return .detail }
        if let s = sights[id], s.face != nil, s.shot != .unknown { return s.shot }
        return labels[id]?.shot ?? .unknown
    }

    /// The presenter is in this angle's view (unknown counts as yes until the Mac has looked; detail shots never show
    /// the face).
    private func inView(_ id: String, _ now: Double) -> Bool {
        guard let s = sights[id], s.checked else { return labels[id]?.subjectVisible != false }
        return s.inView(now) || labels[id]?.shot == .detail
    }

    /// The marked frame's width over height (on its canvas).
    var markedFrameAspect: Double {
        guard let m = markedFrame else { return 16.0 / 9 }
        let vertical = !m.scene.horizontal.contains { $0.id == m.item.id }
        return (vertical ? 9.0 / 16 : 16.0 / 9) * m.item.transform.width / max(0.01, m.item.transform.height)
    }

    /// A small picture of each angle (fast while the tiles show) and, twice a second, a look for the presenter. A
    /// camera that makes crops is looked at on every pass (5 times a second while a crop is on air, the shuffle runs
    /// or the tiles show), in a bigger picture so a small face is still found; its crops are never looked at.
    private func watchAngles(_ now: Double) {
        let live = angles.filter { $0.usable && !$0.isVirtual }
        guard !live.isEmpty, tilesShown > 0 || (live.count >= 2 && (shuffleOn || markedFrame != nil)) || !rigs.isEmpty else { return }
        // 5 times a second only while a medium or close-up can be drawn: the frame on air with the shuffle or one of
        // them in it, or one being recorded to its own file.
        let cropOnAir = currentID.flatMap { id in angles.first { $0.id == id } }?.isVirtual == true
        let cropRecorded = studio.isRecording && settings.recordAngles && settings.virtual.recordCrops
        let busy = tilesShown > 0 || (!rigs.isEmpty && ((frameOnAir && (shuffleOn || cropOnAir)) || cropRecorded))
        guard now - lastWatch >= (busy ? 0.2 : 0.5) else { return }
        lastWatch = now
        let faces = now - lastFaceLook >= 0.45 && live.count >= 1
        if faces { lastFaceLook = now }
        // A picture is taken only to be read, or for the tiles.
        let list = live.compactMap { a -> (id: String, source: UUID, maxSide: CGFloat, read: Bool)? in
            let read = rigs[a.sourceID] != nil ? testFace == nil : faces
            guard read || tilesShown > 0 else { return nil }
            return (a.id, a.sourceID, rigs[a.sourceID] != nil ? 640 : 480, read)
        }
        guard !list.isEmpty else { return }
        watch.look(engine: studio.engine, angles: list) { [weak self] pics, reads in
            guard let self else { return }
            for (id, r) in reads { self.looks[id, default: (0, 0)].n += 1; if r.face != nil { self.looks[id]!.faces += 1 } }
            if !reads.isEmpty { self.merge(reads, now: HostClock.seconds()) }
            if self.tilesShown > 0 { self.pictures.merge(pics) { $1 }; self.cropPictures(pics) }
        }
    }

    /// Crop tiles are cut from their camera's picture (no extra snapshot): where a cut to them would land now.
    private func cropPictures(_ pics: [String: CGImage]) {
        for a in angles {
            guard case .virtual(let p, let shot) = a.kind, let pic = pics["mac:\(p)"],
                  let r = rigs[p]?.previewRect(shot, aspect: 16.0 / 9) else { continue }
            let w = CGFloat(pic.width), h = CGFloat(pic.height)
            if let c = pic.cropping(to: CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h).integral) { pictures[a.id] = c }
        }
    }

    /// Test launches: the scripted face reaches cameras with crops 5 times a second, as Vision's would.
    private func feedTestFace(_ now: Double) {
        guard let f = testFace, !rigs.isEmpty, now - lastTestFace >= 0.2 else { return }
        lastTestFace = now
        var reads: [String: AngleReading] = [:]
        for a in angles where a.kind == .mac && a.usable && rigs[a.sourceID] != nil {
            let size = studio.engine.nativeSize(of: a.sourceID) ?? CGSize(width: 1920, height: 1080)
            reads[a.id] = AngleReading(face: f.box, faces: [f.box], yaw: f.yaw, pitch: 0, person: true,
                                       aspect: size.width / max(1, size.height), at: now)
        }
        if !reads.isEmpty { merge(reads, now: now) }
    }

    private func merge(_ readings: [String: AngleReading], now: Double) {
        let frameAspect = markedFrameAspect
        for (id, r) in readings {
            var s = sights[id] ?? AngleSight()
            s.checked = true
            s.aspect = r.aspect
            if r.person { s.lastSeen = now }
            if let f = r.face {
                s.face = f; s.yaw = r.yaw; s.pitch = r.pitch
                s.shot = AngleWatch.shot(faceHeight: f.height, pictureAspect: r.aspect, frameAspect: frameAspect)
                let straight = abs(r.yaw ?? 90) < 20 && abs(r.pitch ?? 0) < 25
                if straight { if s.facingSince == nil { s.facingSince = now } } else { s.facingSince = nil }
            } else {
                s.yaw = nil; s.facingSince = nil
                if !r.person { s.face = nil }       // a profile or a back keeps the last face for framing
            }
            if s != sights[id] { sights[id] = s }
            // A camera that makes crops: its rig follows the presenter.
            if !rigs.isEmpty, let a = angles.first(where: { $0.id == id }), a.kind == .mac, let rig = rigs[a.sourceID] {
                rig.setFace(FaceSample(boxes: r.faces, yaw: r.yaw, bodies: r.bodies, at: r.at))
            }
        }
        if !rigs.isEmpty { cropSights() }
        pushFaces()
    }

    /// Each crop sees what its camera sees: the face in the crop, when it was seen, which way it turns, and the shot
    /// it's cut to. Never "looking into it": that belongs to the camera.
    private func cropSights() {
        let aspect = markedFrameAspect
        for a in angles {
            guard case .virtual(let p, let shot) = a.kind, let cam = sights["mac:\(p)"], let rig = rigs[p] else { continue }
            var s = AngleSight()
            s.checked = cam.checked
            s.lastSeen = cam.lastSeen
            s.yaw = cam.yaw; s.pitch = cam.pitch
            s.shot = shot.angleShot
            s.aspect = aspect
            if let f = rig.face, let r = rig.previewRect(shot, aspect: aspect), r.width > 0, r.height > 0 {
                s.face = CGRect(x: (f.minX - r.minX) / r.width, y: (f.minY - r.minY) / r.height, width: f.width / r.width, height: f.height / r.height)
            }
            if s != sights[a.id] { sights[a.id] = s }
        }
    }

    /// Tells the engine where the face is in each angle the frame may show (not the frame's own camera: its framing
    /// is the user's). Small moves are ignored so a still presenter keeps a still frame.
    private func pushFaces() {
        guard settings.keepFramed, let m = markedFrame else { studio.engine.setAngleFaces([:]); return }
        var faces: [UUID: CGPoint] = [:]
        for a in angles where a.sourceID != m.item.sourceID && !a.isVirtual {     // crops frame themselves
            guard let f = sights[a.id]?.face else { continue }
            let p = CGPoint(x: f.midX, y: f.midY)
            if let old = faceTargets[a.id], hypot(old.x - p.x, old.y - p.y) < 0.05 { faces[a.sourceID] = old; continue }
            faceTargets[a.id] = p
            faces[a.sourceID] = p
        }
        studio.engine.setAngleFaces(faces)
    }

    // MARK: Lip sync

    /// This Mac's microphones (the presenter's voice): they wait while a later-arriving angle is on air.
    private var micIDs: Set<UUID> {
        Set(studio.collection.sources.filter { if case .microphone = $0.kind { return true }; return false }.map(\.id))
    }
    /// The microphone a device's sound is lined up against: the first one in the show.
    private var referenceMic: UUID? {
        studio.collection.sources.first { s in
            if case .microphone = s.kind { return s.audio?.isInProgram != false && s.audio?.isMuted != true }
            return false
        }?.id
    }

    /// Milliseconds the program's voice waits while this angle is on air: how much later its picture arrives than
    /// the frame's own camera's.
    func holdMs(for id: String) -> Double {
        guard settings.lipSync, let a = angles.first(where: { $0.id == id }) else { return 0 }
        let own = (markedFrame.flatMap { studio.engine.captureLag(of: $0.item.sourceID) } ?? 0.05) * 1000
        switch a.kind {
        case .device: return max(0, (syncMs[id] ?? 0) - own)
        // A crop's lag is its camera's (the engine forwards it), so cuts within one camera never move the hold.
        case .mac, .virtual: return max(0, (studio.engine.captureLag(of: a.sourceID) ?? 0) * 1000 - own)
        }
    }

    /// Changes the hold to suit the angle on air, in a pause (where dropping or adding a moment of silence isn't
    /// heard); after 8 s of nonstop talk it changes anyway.
    private func applyHold(_ now: Double, voice: VoiceState) {
        let onAir = frameOnAir ? (currentID ?? primaryID) : nil
        let want = onAir.map(holdMs(for:)) ?? 0
        guard abs(want - appliedHold) >= 5 else { holdPendingSince = nil; return }
        if holdPendingSince == nil { holdPendingSince = now }
        guard (!voice.speaking && voice.silence >= 0.12) || now - holdPendingSince! > 8 else { return }
        appliedHold = want
        holdPendingSince = nil
        studio.engine.mixer.setHold(want, for: micIDs)
    }

    /// Measures how far a device's picture runs behind this Mac's microphone: its page lends its microphone (not into
    /// the show) while the presenter talks, and the two recordings of the voice are lined up (SoundAligner).
    func lineUp(_ id: String) {
        guard let a = angles.first(where: { $0.id == id }), a.isDevice else { return }
        if let l = lining { if l != id && !lineQueue.contains(id) { lineQueue.append(id) }; return }
        let mic = referenceMic
        guard mic != nil || testLineUpShift != nil else { syncStatus = "Lining up a phone's sound needs your microphone in the show."; return }
        lining = id
        liningStarted = HostClock.seconds()
        lastEstimate = liningStarted
        estimates = []
        aligner.reset()
        syncStatus = "Lining up \(a.name)'s sound: keep talking for a few seconds."
        studio.guests.askDeviceForSync(id, on: true)
        let al = aligner
        if let mic, testLineUpShift == nil {
            studio.engine.mixer.setMeasureTap(mic) { s, n, pts in al.addReference(s, frames: n, pts: pts) }
            measureMic = mic
        }
    }

    private func stepLining(_ now: Double) {
        guard let id = lining else { return }
        // The device's sound arrives once its page publishes the microphone.
        // Follows the device's current sound (it can publish its microphone again while this runs).
        if let src = studio.guests.audioSourceID(id), src != measureOther {
            if let o = measureOther { studio.engine.mixer.setMeasureTap(o, nil) }
            let al = aligner
            if let shift = testLineUpShift {
                let back = CMTime(seconds: shift / 1000, preferredTimescale: 1_000_000)
                studio.engine.mixer.setMeasureTap(src) { s, n, pts in
                    al.addOther(s, frames: n, pts: pts); al.addReference(s, frames: n, pts: CMTimeSubtract(pts, back))
                }
            } else {
                studio.engine.mixer.setMeasureTap(src) { s, n, pts in al.addOther(s, frames: n, pts: pts) }
            }
            measureOther = src
        }
        if now - liningStarted > 45 {
            let name = angles.first { $0.id == id }?.name ?? "The phone"
            finishLining(nil, measureOther == nil
                ? "\(name) didn't lend its microphone, so its sound isn't lined up. Set its delay by hand."
                : "Couldn't line up \(name)'s sound: talk for a few seconds with the phone near you, then measure again.")
            return
        }
        guard measureOther != nil, !estimating, now - lastEstimate >= 1.5 else { return }
        lastEstimate = now
        estimating = true
        let al = aligner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = al.estimate()
            DispatchQueue.main.async { self?.estimating = false; self?.took(r, for: id) }
        }
    }

    private func took(_ r: SoundAligner.Result?, for id: String) {
        guard lining == id, let r, r.confidence >= 0.3, r.speechSeconds >= 3 else { return }
        estimates.append(r.laterMs)
        // One very clear match, or two in a row that agree within 20 ms.
        let n = estimates.count
        if r.confidence >= 0.75 { finishLining(r.laterMs) }
        else if n >= 2, abs(estimates[n - 1] - estimates[n - 2]) <= 20 { finishLining((estimates[n - 1] + estimates[n - 2]) / 2) }
    }

    private func finishLining(_ ms: Double?, _ note: String? = nil) {
        guard let id = lining else { return }
        if let m = measureMic { studio.engine.mixer.setMeasureTap(m, nil) }
        if let o = measureOther { studio.engine.mixer.setMeasureTap(o, nil) }
        measureMic = nil; measureOther = nil
        let a = angles.first { $0.id == id }
        if a?.audioAllowed != true { studio.guests.askDeviceForSync(id, on: false) }
        if let ms {
            let v = (ms / 5).rounded() * 5
            syncMs[id] = v
            syncStatus = "\(a?.name ?? "The phone") is lined up: its picture arrives \(Int(v)) ms after your microphone hears you."
        } else if let note { syncStatus = note }
        lining = nil
        if !lineQueue.isEmpty { lineUp(lineQueue.removeFirst()) }
    }

    /// Stops lining up (the device keeps its last delay).
    func cancelLining() { lineQueue.removeAll(); finishLining(nil) }

    /// Sets a device's delay by hand (milliseconds its picture arrives after the Mac's microphone).
    func setSync(_ id: String, ms: Double) { syncMs[id] = max(0, min(1000, ms)) }

    /// A camera page's answer on the "camera" topic.
    func deviceSaid(_ identity: String, _ o: [String: Any]) {
        if o["type"] as? String == "sync", o["available"] as? Bool == false, lining == identity {
            let name = angles.first { $0.id == identity }?.name ?? "The phone"
            finishLining(nil, "\(name) joined camera only, so its sound can't be measured. Set its delay by hand, or tick \"Also lend the microphone\" on its page before joining.")
        }
    }

    // MARK: Listen (what the presenter says, for the AI's picks)

    func hear(_ text: String, isFinal: Bool) {
        let now = HostClock.seconds()
        if isFinal { heard.append((now, text)); heardGuess = ""; heard.removeAll { $0.t < now - 60 } } else { heardGuess = text; heardGuessAt = now }
    }

    // MARK: AI

    private var provider: AIProvider { studio.settings.s.aiProvider ?? .claude }

    /// Looks at angles with the AI (one picture each) and keeps what it says about how they frame the presenter.
    /// `quietly`: an automatic look (a new angle) says nothing when no API key is set.
    func analyse(_ ids: [String]? = nil, quietly: Bool = false) {
        // Crops never: their shot is known, and each look costs money.
        let targets = angles.filter { ids?.contains($0.id) ?? true }.filter { $0.usable && !$0.isVirtual }
        guard !targets.isEmpty else { aiStatus = "No angle is sending a picture yet."; return }
        let p = provider, model = studio.settings.brainModel(for: p)
        var shots: [(String, String)] = []
        for a in targets {
            guard let img = studio.engine.sourceSnapshot(a.sourceID, maxSide: 768), let jpeg = Self.jpeg(img) else { continue }
            shots.append((a.id, jpeg))
        }
        guard !shots.isEmpty else { aiStatus = "Couldn't take a picture from the angles yet."; return }
        analysing.formUnion(shots.map(\.0))
        aiStatus = "The AI is looking at \(shots.count == 1 ? "the angle" : "\(shots.count) angles")…"
        Task { @MainActor in
            guard let key = await AIKeys.load(p) else {
                self.analysing.subtract(shots.map(\.0))
                self.aiStatus = quietly ? "" : "Add an API key in Settings › AI so the AI can look at your angles. The shuffle works without it."
                return
            }
            // One task per angle (not a task group: built with optimisation, Swift 6.4 loses a task group's results
            // here, checked with a small program).
            var left = shots.count, problems: [String] = []
            for (id, jpeg) in shots {
                Task { @MainActor in
                    do { self.labels[id] = try await AngleAI.label(provider: p, model: model, key: key, jpeg: jpeg) }
                    catch { problems.append(error.localizedDescription) }
                    self.analysing.remove(id)
                    left -= 1
                    if left == 0 { self.aiStatus = problems.first.map { "The AI couldn't look: \($0)" } ?? "Angles checked." }
                }
            }
        }
    }

    /// While the shuffle runs and Listen hears the presenter, asks every ~10 s which angle suits what they're saying.
    /// Whether the AI can pick now: Apple's on-device model is ready, or the API key is to be used.
    var aiReady: Bool { settings.useAPIKey || OnDeviceAngleAI.availability.ok }

    private func askForPick(_ now: Double) {
        guard settings.aiPicks, aiReady, !adviceInFlight, now - lastAdvice >= 10, angles.filter(\.usable).count >= 2 else { return }
        let recent = heard.filter { $0.t >= now - 40 }
        if !heardGuess.isEmpty && now - heardGuessAt > 15 { heardGuess = "" }   // a guess never finished (the recognizer stopped)
        guard !recent.isEmpty || !heardGuess.isEmpty, let cur = currentID ?? primaryID else { return }
        lastAdvice = now
        adviceInFlight = true
        let p = provider, model = studio.settings.brainModel(for: p)
        let list = angles.filter(\.usable).map { a -> (String, String, String, String) in
            var about = labels[a.id]?.about ?? ""
            if let p = a.parentID, let shot = a.virtualShot {
                about = "same camera as \(studio.source(p)?.name ?? "the camera"), cropped to \(shot == .close ? "a close-up" : "a medium shot")"
            }
            if let s = sights[a.id], s.checked {
                let seen = s.inView(now) ? (s.facing(now) ? "presenter looking into it" : "presenter in view") : "presenter not in view"
                about = about.isEmpty ? seen : "\(about); \(seen)"
            }
            let shot = plannerShot(a.id)
            return (a.id, a.name, shot == .unknown ? (labels[a.id]?.title ?? "not checked") : shot.title, about)
        }
        let onAir = angles.first { $0.id == cur }?.name ?? cur
        let held = Int(now - planner.since)
        var said = recent.map { "[\(Int(now - $0.t)) s ago] \($0.text)" }.joined(separator: "\n")
        if !heardGuess.isEmpty { said += "\n[now] \(heardGuess)" }
        let useAPI = settings.useAPIKey
        Task { @MainActor in
            defer { self.adviceInFlight = false }
            do {
                let pick: AngleAI.Pick
                if useAPI {
                    guard let key = await AIKeys.load(p) else { self.aiStatus = "Add an API key in Settings › AI, or turn off \"Use my API key\"."; return }
                    pick = try await AngleAI.pick(provider: p, model: model, key: key, angles: list, onAir: onAir, heldSeconds: held, said: said)
                } else {
                    pick = try await OnDeviceAngleAI.pick(angles: list, onAir: onAir, heldSeconds: held, said: said)
                }
                self.lastPick = pick
                if pick.confidence >= 0.6, pick.angle != cur, self.angles.contains(where: { $0.id == pick.angle }) {
                    self.aiHint = (pick.angle, HostClock.seconds() + 9)
                    self.aiStatus = "AI: \(pick.reason)"
                }
            } catch { self.aiStatus = "The AI's pick failed: \(error.localizedDescription)" }
        }
    }

    static func jpeg(_ img: CGImage) -> String? {
        NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.72])?.base64EncodedString()
    }

    /// For test scripts.
    func dump() -> [String: Any] {
        let frame16 = markedFrameSizes()[.horizontal] ?? CGSize(width: 1920, height: 1080)
        let aspect16 = frame16.width / max(1, frame16.height)
        var out: [String: Any] = [
            "angles": angles.map { a in
                var d: [String: Any] = ["id": a.id, "name": a.name, "device": a.isDevice, "usable": a.usable, "audio": a.audioAllowed,
                                        "label": labels[a.id]?.title ?? "", "about": labels[a.id]?.about ?? "",
                                        "kind": a.isDevice ? "device" : a.isVirtual ? "virtual" : "mac"]
                if case .virtual(let p, let shot) = a.kind, let rig = rigs[p] {
                    let plan = rig.status(shot)
                    d["parent"] = p.uuidString; d["shot"] = shot.rawValue
                    d["available"] = plan.available; d["reason"] = virtualReason(a) ?? ""
                    d["zoom"] = plan.zoom; d["faceInCrop"] = plan.faceInCrop; d["grade"] = plan.grade.rawValue
                    d["enlargement"] = ["h": plan.enlargement[.horizontal] ?? 0, "v": plan.enlargement[.vertical] ?? 0]
                    d["edgeLimited"] = rig.edgeLimited(shot)
                    if let r = rig.previewRect(shot, aspect: aspect16) { d["crop"] = [r.minX, r.minY, r.width, r.height] }
                } else if a.kind == .mac, let rig = rigs[a.sourceID] {
                    if let f = rig.face { d["framedFace"] = [f.minX, f.minY, f.width, f.height] }
                    if let l = rig.lockedFace { d["lockedFace"] = l }
                }
                if let l = looks[a.id] { d["looks"] = [l.n, l.faces] }
                return d
            },
            "marked": markedFrameTitle ?? "", "frameOnAir": frameOnAir, "shuffle": shuffleOn, "pinned": pinnedID ?? "",
            "current": currentID ?? "", "primary": primaryID ?? "", "pace": settings.pace.rawValue, "aiPicks": settings.aiPicks,
            "recordAngles": settings.recordAngles, "aiStatus": aiStatus, "deviceLink": studio.guests.deviceInviteURL ?? "",
            "devices": studio.guests.devices.map { ["name": $0.name, "status": $0.status.rawValue, "audio": $0.audioAllowed] },
            "cuts": cuts.map { ["angle": $0.angle, "reason": $0.reason, "at": $0.at.timeIntervalSince1970, "t": $0.t] },
            // The scripted voice's clock (host seconds): it talks 3 s and pauses 0.6 s from here.
            "voiceStart": testVoiceStart,
            "sights": sights.mapValues { s -> [String: Any] in
                var d: [String: Any] = ["shot": s.shot.rawValue, "inView": s.inView(HostClock.seconds()), "facing": s.facing(HostClock.seconds()),
                                        "aspect": s.aspect, "checked": s.checked]
                if let f = s.face { d["face"] = [f.minX, f.minY, f.width, f.height] }
                if let y = s.yaw { d["yaw"] = y }
                return d
            },
            "sync": syncMs, "lining": lining ?? "", "syncStatus": syncStatus, "hold": appliedHold,
            "measuring": ["mic": measureMic?.uuidString ?? "", "device": measureOther?.uuidString ?? "",
                          "heldReference": aligner.held.reference, "heldDevice": aligner.held.other, "estimates": estimates],
            "followLook": settings.followLook, "keepFramed": settings.keepFramed, "lipSync": settings.lipSync,
            "pictures": pictures.count, "labelCount": labels.count, "keysOn": settings.keysOn, "useAPIKey": settings.useAPIKey,
            "aiReady": aiReady, "onDeviceAI": OnDeviceAngleAI.availability.note, "ears": ears.on, "earsStatus": ears.status,
            "lastPick": lastPick.map { ["angle": $0.angle, "reason": $0.reason, "confidence": $0.confidence] } ?? [:],
            "heard": heard.map(\.text).suffix(3).joined(separator: " | "), "notice": studio.notice ?? "",
        ]
        let v = settings.virtual
        out["virtual"] = ["cameras": v.cameras.mapValues { ["medium": $0.medium, "close": $0.close] }, "recordCrops": v.recordCrops] as [String: Any]
        // What actually draws each source (a test checks that no real camera, screen or microphone was opened).
        // Two cameras with one name show both types, so a real camera can't hide behind a stand-in's name.
        let sources = studio.collection.sources
        out["fakeDevices"] = FakeDevices.isOn
        out["cameraKind"] = Dictionary(sources.compactMap { s -> (String, String)? in
            guard case .camera = s.kind else { return nil }
            return (s.name, studio.engine.sourceTypeName(of: s.id) ?? "none")
        }, uniquingKeysWith: { a, b in a == b ? a : "\(a), \(b)" })
        out["sourceKinds"] = sources.map { s in
            ["name": s.name, "kind": String(String(describing: s.kind).prefix { $0 != "(" }), "type": studio.engine.sourceTypeName(of: s.id) ?? "none"]
        }
        return out
    }
}

/// The two small AI requests the angles make: describe an angle (one picture), and pick an angle for what's being said.
enum AngleAI {
    static let labelSystem = """
    You look at one camera angle of a live show presented by one person who talks to the audience. Say how the angle \
    frames the presenter, so an automatic editor can cut between angles well.
    - shot: wide (whole body or most of the room), medium (waist or chest up), close (head and shoulders), \
    extreme_close (face only), or detail (hands, a desk, a product: not the face).
    - side: front, left side, right side, high, low, overhead, behind, or none (no presenter in view).
    - subject_visible: whether a person is clearly in view.
    - quality: 1 to 5 for framing, light and focus together.
    - about: at most eight words a director would note ("front, slightly low, warm light").
    """

    static func label(provider: AIProvider, model: String, key: String, jpeg: String) async throws -> AngleLabel {
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "required": ["shot", "side", "subject_visible", "quality", "about"],
            "properties": [
                "shot": ["type": "string", "enum": ["wide", "medium", "close", "extreme_close", "detail"]],
                "side": ["type": "string", "enum": ["front", "left side", "right side", "high", "low", "overhead", "behind", "none"]],
                "subject_visible": ["type": "boolean"], "quality": ["type": "integer"], "about": ["type": "string"],
            ]]
        let o = try await ask(provider: provider, model: model, key: key, system: labelSystem, text: "This is the angle.", jpeg: jpeg, schema: schema, name: "angle")
        return AngleLabel(shot: AngleShot(rawValue: o["shot"] as? String ?? "") ?? .unknown, side: o["side"] as? String ?? "",
                          subjectVisible: o["subject_visible"] as? Bool ?? true, quality: min(5, max(1, o["quality"] as? Int ?? 3)),
                          about: String((o["about"] as? String ?? "").prefix(80)))
    }

    struct Pick: Equatable { var angle: String; var reason: String; var confidence: Double }

    static func pickPrompt(angles: [(id: String, name: String, label: String, about: String)], onAir: String, heldSeconds: Int, said: String) -> String {
        var text = "Angles:\n" + angles.map { "- \($0.id): \($0.name) (\($0.label)\($0.about.isEmpty ? "" : ", \($0.about)"))" }.joined(separator: "\n")
        text += "\n\nOn air: \(onAir), for \(heldSeconds) s.\n\nWhat the presenter said, oldest first:\n\(said)"
        return text
    }

    static let pickSystem = """
    You are the editor of a live show with one presenter and several camera angles of them. Every ten seconds you get \
    what they just said and the angles, and you pick the angle that suits the moment best, the way a multicam editor \
    would: a close angle when they make a point or tell something personal, a wide angle when they explain with their \
    hands, show something or start a new subject, the front angle for normal talking, a side angle for a short change of \
    view. Give "angle" (an id from the list), a short "reason" (at most twelve words) and "confidence" from 0 to 1. Pick \
    the angle on air again (with any confidence) when it still suits; the editor then keeps it. The text comes from live \
    speech recognition and has errors; the presenter may speak Hinglish.
    """
    /// Added when the list has crops (their ids start "virt:").
    static let punchInNote = "Angles cropped from the same camera are punch-ins: use them for emphasis, not as a change of view."
    static func pickInstructions(for ids: [String]) -> String {
        ids.contains { $0.hasPrefix("virt:") } ? pickSystem + " " + punchInNote : pickSystem
    }

    static func pick(provider: AIProvider, model: String, key: String, angles: [(id: String, name: String, label: String, about: String)],
                     onAir: String, heldSeconds: Int, said: String) async throws -> Pick {
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["angle", "reason", "confidence"],
            "properties": ["angle": ["type": "string", "enum": angles.map(\.id)], "reason": ["type": "string"], "confidence": ["type": "number"]]]
        let text = pickPrompt(angles: angles, onAir: onAir, heldSeconds: heldSeconds, said: said)
        let o = try await ask(provider: provider, model: model, key: key, system: pickInstructions(for: angles.map(\.id)), text: text, jpeg: nil, schema: schema, name: "pick")
        return Pick(angle: o["angle"] as? String ?? "", reason: String((o["reason"] as? String ?? "").prefix(120)), confidence: o["confidence"] as? Double ?? 0)
    }

    /// One structured request to Claude or OpenAI (optionally with one picture); returns the JSON object it answered.
    static func ask(provider: AIProvider, model: String, key: String, system: String, text: String, jpeg: String?,
                    schema: [String: Any], name: String) async throws -> [String: Any] {
        let base = ScriptWriter.baseOverride
        var req: URLRequest
        let body: [String: Any]
        if provider == .claude {
            req = URLRequest(url: URL(string: (base ?? "https://api.anthropic.com") + "/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = []
            if let jpeg { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg]]) }
            content.append(["type": "text", "text": text])
            body = ["model": model, "max_tokens": 600, "system": system, "messages": [["role": "user", "content": content]],
                    "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]]]
        } else {
            req = URLRequest(url: URL(string: (base ?? "https://api.openai.com") + "/v1/responses")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var content: [[String: Any]] = [["type": "input_text", "text": text]]
            if let jpeg { content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg)", "detail": "low"]) }
            var b: [String: Any] = ["model": model, "max_output_tokens": 600,
                    "input": [["role": "system", "content": system], ["role": "user", "content": content]],
                    "text": ["format": ["type": "json_schema", "name": name, "strict": true, "schema": schema]]]
            if ["gpt-5", "gpt-6", "o"].contains(where: model.hasPrefix) { b["reasoning"] = ["effort": "low"] }
            body = b
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw ScriptWriter.failure("\(provider.company) \(status == 401 || status == 403 ? "didn't accept the API key" : "answered \(status)")\(msg.map { ": \($0)" } ?? "")")
        }
        var out = ""
        if provider == .claude {
            out = (obj["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        } else {
            for item in obj["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for c in item["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "output_text" { out += c["text"] as? String ?? "" }
            }
        }
        guard let o = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { throw ScriptWriter.failure("The model's answer couldn't be read.") }
        return o
    }
}
