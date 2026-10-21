import Foundation
import Observation
import CoreImage
import CoreMedia
import AVFoundation
@preconcurrency import LiveKit
import FramecastEngine

enum GuestStatus: String, Codable { case waiting, lobby, stage }

struct Guest: Identifiable, Equatable {
    var id: String             // ticket id; LiveKit identity is "g-<id>"
    var name: String
    var detail: String
    var status: GuestStatus
    var micOn = true
    var camOn = true
    var mutedByHost = false
    var connected = false
    var sharingScreen = false
    var since = Date()
    /// Remote guests rejoin under a new identity once let in, so a reused invite link can't push them out.
    var admittedSuffix = ""
    var identity: String { "g-\(id)\(admittedSuffix)" }
}

/// Receives one guest's camera or screen frames.
final class GuestVideoSink: NSObject, VideoRenderer, @unchecked Sendable {
    let slot = FrameSlot()
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 1920, height: 1080) }
    func render(frame: LiveKit.VideoFrame) {
        guard let pb = frame.toCVPixelBuffer() else { return }
        slot.put(pb, pts: HostClock.now())
    }
}

/// Feeds a guest's audio into Framecast's mixer.
final class GuestAudioSink: NSObject, AudioRenderer, @unchecked Sendable {
    let id: UUID
    weak var mixer: AudioMixer?
    private let normalizer = AudioNormalizer()
    init(id: UUID, mixer: AudioMixer) { self.id = id; self.mixer = mixer }
    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let s = normalizer.convert(pcmBuffer) else { return }
        s.withUnsafeBufferPointer { mixer?.push(id, samples: $0.baseAddress!, frames: s.count / 2, pts: HostClock.now()) }
    }
}

/// A layout layer that shows whichever guest currently holds a stage slot.
final class GuestSlotSource: VideoSource {
    let id: UUID
    let slot: Int
    let screen: Bool
    weak var room: GuestRoom?
    var state: SourceState { .running }
    var nativeSize = CGSize(width: 1280, height: 720)
    init(id: UUID, slot: Int, screen: Bool, room: GuestRoom) { self.id = id; self.slot = slot; self.screen = screen; self.room = room }
    func image(at time: CMTime) -> CIImage? {
        guard let s = room?.frameSlot(forSlot: slot, screen: screen), let (pb, _) = s.get(), s.age < 3 else { return nil }
        let img = CIImage(cvPixelBuffer: pb)
        nativeSize = img.extent.size
        return img
    }
    func start() {}
    func stop() {}
}

/// The guest room: browser guests join through the guest page, wait in the lobby, and go on stage into
/// the layouts' guest slots. Runs on this Mac, on the Wi-Fi, or on the user's LiveKit Cloud project (GuestServer).
@Observable
final class GuestRoom: NSObject, RoomDelegate, @unchecked Sendable {
    unowned let studio: Studio
    var guests: [Guest] = []
    var roomTitle = ""
    var inviteURL: String?
    var askBeforeLettingIn = true
    var joinMuted = false
    var joinCameraOff = false
    var status: String = "Not connected to the guest room"
    var isOpen = false
    /// Who can join; changing it applies the next time the room opens.
    var reach: GuestReach = GuestReach.saved { didSet { if !testOverride { GuestReach.saved = reach } } }
    var cloud = GuestCloudConfig.load(secret: false)
    @ObservationIgnored var testOverride = false
    /// Tests turn this off so a test room never carries the real microphone.
    @ObservationIgnored var shareHostMic = true

    @ObservationIgnored private var server: GuestServer?
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var roomName = ""
    @ObservationIgnored private var code = ""
    @ObservationIgnored private var tokens: [String: String] = [:]
    @ObservationIgnored private var videoSinks: [String: GuestVideoSink] = [:]      // identity → camera
    @ObservationIgnored private var screenSinks: [String: GuestVideoSink] = [:]     // identity → screen share
    @ObservationIgnored private var audioSinks: [String: GuestAudioSink] = [:]
    @ObservationIgnored private var programTrack: LocalVideoTrack?
    @ObservationIgnored private var programFeed: ProgramFeed?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var stageOrder: [String] = []   // identities in slot order
    /// Remote invites (one person each): identities whose link hasn't been used yet, and the one on show.
    @ObservationIgnored private var openInvites: Set<String> = []
    @ObservationIgnored private var currentInvite: String?

    init(studio: Studio) { self.studio = studio; super.init() }

    var lobby: [Guest] { guests.filter { $0.status != .stage } }
    var stage: [Guest] { guests.filter { $0.status == .stage } }

    // MARK: Open / close

    func open() {
        guard !isOpen else { return }
        if reach == .internet && !cloud.isLocalTest { cloud = GuestCloudConfig.load() }   // the latest saved settings
        if reach == .internet, let problem = cloud.problem { status = problem; return }
        if reach == .internet, cloud.secret.isEmpty { status = "Framecast couldn't read your LiveKit API secret from the Keychain. Allow access when macOS asks, or load your .env file again."; return }
        let s = GuestServer(reach: reach, cloud: reach == .internet ? cloud : nil)
        do { try s.start() } catch { s.stop(); status = error.localizedDescription; return }
        server = s
        roomName = "framecast-\(UUID().uuidString.prefix(8).lowercased())"
        roomTitle = studio.sessionName.isEmpty ? "Framecast show" : studio.sessionName
        s.onRoomInfo = { [weak self] c in (self?.roomTitle ?? "", c == self?.code) }
        s.onKnock = { [weak self] c, name, detail in self?.knock(code: c, name: name, detail: detail) }
        s.onTicket = { [weak self] id in self?.ticket(id) ?? ["state": "denied"] }
        isOpen = true
        newInviteLink()
        status = "Opening your guest room…"
        ensureGuestLayouts()
        // A local LiveKit server needs a moment to start listening.
        DispatchQueue.main.asyncAfter(deadline: .now() + (s.runsLocalServer ? 1.2 : 0.1)) { [weak self] in self?.connectHost(attempt: 1) }
    }

    /// Reads the LiveKit Cloud details from the user's .env file and saves them (secret in the Keychain).
    /// Returns a short result for the UI and never echoes the values.
    func loadEnv(_ path: String) -> String {
        do {
            let c = try GuestCloudConfig.fromEnvFile(path, base: cloud)
            c.save(); cloud = c
            return c.problem ?? "Loaded."
        } catch { return error.localizedDescription }
    }

    /// What the invite link reaches, shown under it.
    var reachNote: String {
        switch reach {
        case .thisMac: "Works in browsers on this Mac only."
        case .wifi: "Works for phones and computers on your Wi-Fi. Their browser warns once about the certificate (made by this Mac): choose to continue. Nothing is reachable from the internet."
        case .internet: "Each link lets one person in; a fresh link appears once it's used. Video goes through your LiveKit Cloud project."
        }
    }

    func close() {
        if let feed = programFeed { studio.engine.removeConsumer(feed) }
        programFeed = nil
        let r = room
        Task { await r?.disconnect() }
        room = nil
        server?.stop(); server = nil
        for (_, a) in audioSinks { studio.engine.mixer.removeSource(a.id) }
        audioSinks.removeAll(); videoSinks.removeAll(); screenSinks.removeAll()
        guests.removeAll(); stageOrder.removeAll(); openInvites.removeAll(); currentInvite = nil
        isOpen = false; inviteURL = nil
        status = "Not connected to the guest room"
    }

    /// Replaces the invite link; the previous one stops working.
    func newInviteLink() {
        guard let server else { return }
        switch reach {
        case .thisMac:
            code = Self.makeCode()
            inviteURL = "http://127.0.0.1:\(GuestServer.httpPort)/invite/\(code)"
        case .wifi:
            code = Self.makeCode()
            inviteURL = "https://\(server.lanAddress ?? "127.0.0.1"):\(GuestServer.httpsPort)/invite/\(code)"
        case .internet:
            // The link carries a LiveKit token that can only knock; the page itself holds no secrets.
            if let old = currentInvite { openInvites.remove(old) }
            let identity = "g-\(UUID().uuidString.prefix(8).lowercased())"
            openInvites.insert(identity); currentInvite = identity
            let token = server.token(identity: identity, name: "Guest", room: roomName, lobby: true)
            let fragment = [("u", server.signalURL), ("t", token), ("n", roomTitle)]
                .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "")" }
                .joined(separator: "&")
            inviteURL = cloud.pageURL + "#" + fragment
        }
    }

    static func makeCode() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars.randomElement()! })
    }

    private func connectHost(attempt: Int) {
        guard let server, isOpen else { return }
        // LiveKit's audio engine would otherwise switch the input device to Apple's voice processing, which hands
        // every other microphone reader in the app (Framecast's own Mic source) silence for as long as it runs.
        try? AudioManager.shared.setVoiceProcessingEnabled(false)
        let r = Room(delegate: self)
        room = r
        let token = server.token(identity: "host", name: "Host", room: roomName)
        Task { @MainActor in
            do {
                try await r.connect(url: server.signalURL, token: token)
                switch reach {
                case .thisMac: status = "Guest room open on this Mac"
                case .wifi: status = "Guest room open to your Wi-Fi"
                case .internet: status = cloud.isLocalTest ? "Guest room open (remote-guest test on this Mac)" : "Guest room open on LiveKit Cloud"
                }
            } catch {
                if attempt < 5 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connectHost(attempt: attempt + 1) } }
                else { status = "The guest room didn't answer. \(error.localizedDescription)" }
                return
            }
            // Guests see the show: the horizontal program at 15 fps. Frames must flow before publishing,
            // because LiveKit reads the track's size from the first frame.
            let track = LocalVideoTrack.createBufferTrack(name: "program", source: .camera)
            let feed = ProgramFeed(track: track)
            programFeed = feed
            programTrack = track
            studio.engine.addConsumer(feed)
            do { _ = try await r.localParticipant.publish(videoTrack: track) }
            catch { status = "Guest room open, but your show couldn't be sent to guests (\(error.localizedDescription))." }
            // Guests hear you: the SDK captures your default microphone with echo cancellation.
            if shareHostMic { do { _ = try await r.localParticipant.setMicrophone(enabled: true) }
            catch { status = "Guest room open. Your microphone couldn't be shared with guests (\(error.localizedDescription))." } }

        }
    }

    // MARK: Join API (main queue)

    private func knock(code c: String, name: String, detail: String) -> (ticket: String, state: String)? {
        guard isOpen, c == code else { return nil }
        guard guests.count < 10 else { return nil }
        let id = UUID().uuidString.prefix(8).lowercased()
        let g = Guest(id: String(id), name: name, detail: detail, status: askBeforeLettingIn ? .waiting : .lobby)
        guests.append(g)
        if !askBeforeLettingIn { issueToken(g) }
        return (String(id), askBeforeLettingIn ? "waiting" : "admitted")
    }

    private func ticket(_ id: String) -> [String: Any] {
        guard let g = guests.first(where: { $0.id == id }) else { return ["state": "denied"] }
        if g.status == .waiting { return ["state": "waiting"] }
        guard let t = tokens[id], let server else { return ["state": "denied"] }
        return ["state": "admitted", "token": t, "url": server.signalURL, "title": roomTitle]
    }

    private func issueToken(_ g: Guest) {
        guard let server else { return }
        tokens[g.id] = server.token(identity: g.identity, name: g.name, room: roomName)
    }

    /// A remote guest connected with their invite and asked to join (LiveKit data message, topic "knock").
    private func remoteKnock(identity: String, name: String, detail: String) {
        guard reach == .internet, isOpen, identity.hasPrefix("g-") else { return }
        if guests.contains(where: { $0.identity == identity }) { return }      // the page repeats its knock
        guard openInvites.remove(identity) != nil, guests.count < 10 else {
            server?.removeParticipant(room: roomName, identity: identity)       // used, replaced or room full
            return
        }
        if identity == currentInvite { currentInvite = nil; newInviteLink() }  // single-use: show a fresh one
        var g = Guest(id: String(identity.dropFirst(2)), name: name, detail: detail, status: askBeforeLettingIn ? .waiting : .lobby)
        g.connected = true
        guests.append(g)
        if !askBeforeLettingIn { admit(g.id) }
    }

    // MARK: Host actions

    func admit(_ id: String) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        guests[i].status = .lobby
        if reach == .internet { letInRemote(i) } else { issueToken(guests[i]) }
    }

    /// Remote guests wait on an invite token that can only knock. Letting one in hands them a full token for a
    /// new identity over a data message; their page reconnects with it. Repeated until they arrive.
    private func letInRemote(_ i: Int) {
        guard let server else { return }
        let lobbyIdentity = guests[i].identity
        guests[i].admittedSuffix = "-in"
        let g = guests[i]
        let token = server.token(identity: g.identity, name: g.name, room: roomName)
        server.allowMessages(room: roomName, identity: lobbyIdentity) { [weak self] _ in
            self?.sendAdmission(token, to: lobbyIdentity, arrivingAs: g.identity, attempt: 1)
        }
    }

    private func sendAdmission(_ token: String, to lobbyIdentity: String, arrivingAs identity: String, attempt: Int) {
        guard isOpen, attempt <= 10, guests.contains(where: { $0.identity == identity }),
              room?.remoteParticipants[Participant.Identity(from: identity)] == nil else { return }
        send(["type": "admit", "token": token], to: lobbyIdentity, topic: "control")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendAdmission(token, to: lobbyIdentity, arrivingAs: identity, attempt: attempt + 1)
        }
    }

    func bringOnStage(_ id: String) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        guests[i].status = .stage
        lock.lock(); if !stageOrder.contains(guests[i].identity) { stageOrder.append(guests[i].identity) }; lock.unlock()
        send(["type": "stage", "on": true], to: guests[i].identity, topic: "control")
        updateGuestAudio()
    }

    func takeOffStage(_ id: String) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        guests[i].status = .lobby
        lock.lock(); stageOrder.removeAll { $0 == guests[i].identity }; lock.unlock()
        send(["type": "stage", "on": false], to: guests[i].identity, topic: "control")
        updateGuestAudio()
    }

    func toggleMute(_ id: String) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        guests[i].mutedByHost.toggle()
        if guests[i].mutedByHost { send(["type": "mute"], to: guests[i].identity, topic: "control") }
        updateGuestAudio()
    }

    func remove(_ id: String) {
        guard let g = guests.first(where: { $0.id == id }) else { return }
        send(["type": "remove"], to: g.identity, topic: "control")
        // Give the goodbye message a moment to arrive before the server disconnects them.
        let room = roomName
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.server?.removeParticipant(room: room, identity: g.identity) }
        lock.lock(); stageOrder.removeAll { $0 == g.identity }; lock.unlock()
        guests.removeAll { $0.id == id }
        tokens[id] = nil
    }

    func sendChat(_ text: String) { send(["text": text, "from": "Host"], to: nil, topic: "backstage") }

    private func send(_ obj: [String: Any], to identity: String?, topic: String) {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let opts = DataPublishOptions(destinationIdentities: identity.map { [Participant.Identity(from: $0)] } ?? [], topic: topic, reliable: true)
        Task { try? await room.localParticipant.publish(data: data, options: opts) }
    }

    /// Only guests on stage (and not muted by the host) are heard in the program.
    private func updateGuestAudio() {
        for g in guests {
            guard let sink = audioSinks[g.identity] else { continue }
            var a = AudioSettings()
            a.isVoice = true                     // music set to duck lowers while guests talk
            a.isInProgram = g.status == .stage && !g.mutedByHost
            a.isMuted = g.mutedByHost
            studio.engine.mixer.update(sink.id, settings: a)
        }
    }

    // MARK: Slots for layouts

    func frameSlot(forSlot slot: Int, screen: Bool) -> FrameSlot? {
        lock.lock(); defer { lock.unlock() }
        if screen {
            // Guest screen: the first guest on stage who is sharing.
            for id in stageOrder { if let s = screenSinks[id] { return s.slot } }
            return nil
        }
        guard slot >= 1, slot <= stageOrder.count else { return nil }
        return videoSinks[stageOrder[slot - 1]]?.slot
    }

    /// Guest layers exist as sources; this binds them to live slots and adds guest layouts once.
    private func ensureGuestLayouts() {
        var guestIDs: [Int: UUID] = [:]
        for s in studio.collection.sources { if case .guest(let n) = s.kind { guestIDs[n] = s.id } }
        for n in 1...3 where guestIDs[n] == nil {
            let r = SourceRecord(name: "Guest \(n)", kind: .guest(slot: n))
            studio.collection.sources.append(r); guestIDs[n] = r.id
        }
        var screenID = studio.collection.sources.first { if case .guestScreen = $0.kind { return true }; return false }?.id
        if screenID == nil { let r = SourceRecord(name: "Guest screen", kind: .guestScreen(slot: 1)); studio.collection.sources.append(r); screenID = r.id }
        studio.engine.sync(sources: studio.collection.sources, fpsHint: studio.settings.s.horizontal.fps)
        for (n, id) in guestIDs { studio.engine.setExternalSource(id, GuestSlotSource(id: id, slot: n, screen: false, room: self)) }
        if let sid = screenID { studio.engine.setExternalSource(sid, GuestSlotSource(id: sid, slot: 1, screen: true, room: self)) }

        guard !studio.scenes.contains(where: { $0.arrangesGuests }) else { return }
        let roles = studio.defaultRoles()
        func item(_ id: UUID, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ role: LayoutRole = .camera2) -> SceneItem {
            SceneItem(sourceID: id, role: role, transform: ItemTransform(x: x, y: y, width: w, height: h), fit: .fill, mask: .roundedRect(radius: 0.035))
        }
        let bg = SceneItem(sourceID: roles.background, role: .background)
        // Same grid as the built-in scenes: 3% safe margin, 2% gaps.
        let m = 0.03, my = 0.03 * 16 / 9, gx = 0.02, gy = 0.02 * 16 / 9
        let halfW = (1 - 2 * m - gx) / 2, tileH = halfW * 16 / 9 / 1.6
        var interview = StudioScene(name: "Conversation", verticalName: "Conversation",
            horizontal: [bg, item(roles.camera, m, (1 - tileH) / 2, halfW, tileH, .camera), item(guestIDs[1]!, m + halfW + gx, (1 - tileH) / 2, halfW, tileH)],
            vertical: [bg, item(roles.camera, 0.04, 0.07, 0.92, 0.42, .camera), item(guestIDs[1]!, 0.04, 0.51, 0.92, 0.42)])
        interview.arrangesGuests = true; interview.group = .together
        let gridH = (1 - 2 * my - gy) / 2
        var everyone = StudioScene(name: "Panel", verticalName: "Panel",
            horizontal: [bg, item(roles.camera, m, my, halfW, gridH, .camera), item(guestIDs[1]!, m + halfW + gx, my, halfW, gridH),
                         item(guestIDs[2]!, m, my + gridH + gy, halfW, gridH), item(guestIDs[3]!, m + halfW + gx, my + gridH + gy, halfW, gridH)],
            vertical: [bg, item(roles.camera, 0.04, 0.03, 0.92, 0.225, .camera), item(guestIDs[1]!, 0.04, 0.27, 0.92, 0.225),
                       item(guestIDs[2]!, 0.04, 0.51, 0.92, 0.225), item(guestIDs[3]!, 0.04, 0.75, 0.92, 0.225)])
        everyone.arrangesGuests = true; everyone.group = .together
        let colW = 0.25, colX = 1 - m - colW, colTile = (1 - 2 * my - 2 * gy) / 3
        var screenGuests = StudioScene(name: "Screen with guests", verticalName: "Screen with guests",
            horizontal: [bg, SceneItem(sourceID: screenID!, role: .screen, transform: ItemTransform(x: m, y: my, width: colX - gx - m, height: 1 - 2 * my), fit: .fit, mask: .roundedRect(radius: 0.035)),
                         item(roles.camera, colX, my, colW, colTile, .camera), item(guestIDs[1]!, colX, my + colTile + gy, colW, colTile),
                         item(guestIDs[2]!, colX, my + 2 * (colTile + gy), colW, colTile)],
            vertical: [bg, SceneItem(sourceID: screenID!, role: .screen, transform: ItemTransform(x: 0.04, y: 0.04, width: 0.92, height: 0.36), fit: .fit, mask: .roundedRect(radius: 0.035)),
                       item(roles.camera, 0.04, 0.42, 0.92, 0.26, .camera), item(guestIDs[1]!, 0.04, 0.70, 0.92, 0.26)])
        screenGuests.arrangesGuests = true; screenGuests.group = .together
        studio.collection.scenes.append(contentsOf: [interview, everyone, screenGuests])
    }

    // MARK: RoomDelegate (called off the main thread)

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let id = participant.identity?.stringValue ?? ""
        DispatchQueue.main.async {
            if let i = self.guests.firstIndex(where: { $0.identity == id }) { self.guests[i].connected = true }
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let id = participant.identity?.stringValue ?? ""
        DispatchQueue.main.async {
            self.lock.lock(); self.stageOrder.removeAll { $0 == id }; self.videoSinks[id] = nil; self.screenSinks[id] = nil; self.lock.unlock()
            if let a = self.audioSinks.removeValue(forKey: id) { self.studio.engine.mixer.removeSource(a.id) }
            self.guests.removeAll { $0.identity == id }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let id = participant.identity?.stringValue ?? ""
        guard let track = publication.track else { return }
        DispatchQueue.main.async {
            if let v = track as? RemoteVideoTrack {
                let sink = GuestVideoSink()
                v.add(videoRenderer: sink)
                self.lock.lock()
                if publication.source == .screenShareVideo { self.screenSinks[id] = sink } else { self.videoSinks[id] = sink }
                self.lock.unlock()
                if let i = self.guests.firstIndex(where: { $0.identity == id }) {
                    if publication.source == .screenShareVideo { self.guests[i].sharingScreen = true } else { self.guests[i].camOn = true }
                }
            } else if let a = track as? RemoteAudioTrack {
                let sink = GuestAudioSink(id: UUID(), mixer: self.studio.engine.mixer)
                var s = AudioSettings(); s.isInProgram = false; s.isVoice = true
                self.studio.engine.mixer.addSource(sink.id, settings: s)
                a.add(audioRenderer: sink)
                self.audioSinks[id] = sink
                self.updateGuestAudio()
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        let id = participant.identity?.stringValue ?? ""
        DispatchQueue.main.async {
            self.lock.lock()
            if publication.source == .screenShareVideo { self.screenSinks[id] = nil } else if publication.kind == .video { self.videoSinks[id] = nil }
            self.lock.unlock()
            if let i = self.guests.firstIndex(where: { $0.identity == id }), publication.source == .screenShareVideo { self.guests[i].sharingScreen = false }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        if topic == "knock", let identity = participant?.identity?.stringValue,
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = String(((o["name"] as? String) ?? "Guest").prefix(60)), detail = String(((o["detail"] as? String) ?? "").prefix(80))
            DispatchQueue.main.async { self.remoteKnock(identity: identity, name: name.isEmpty ? "Guest" : name, detail: detail) }
            return
        }
        guard topic == "backstage", let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = o["text"] as? String else { return }
        let name = participant?.name ?? "Guest"
        DispatchQueue.main.async {
            self.studio.chat.backstage.append(ChatMessage(platform: .guest, user: name, text: text))
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        DispatchQueue.main.async { if self.isOpen { self.status = "Not connected to the guest room. \(error?.localizedDescription ?? "")" } }
    }
}

/// Sends the horizontal program to the guest room at 15 fps so guests can see the show.
final class ProgramFeed: CanvasFrameConsumer, @unchecked Sendable {
    let track: LocalVideoTrack
    private var n = 0
    init(track: LocalVideoTrack) { self.track = track }
    func consume(_ pb: CVPixelBuffer, pts: CMTime, canvas: CanvasKind) {
        guard canvas == .horizontal else { return }
        n += 1
        guard n % 2 == 0, let cap = track.capturer as? BufferCapturer else { return }
        cap.capture(pb)
    }
}
