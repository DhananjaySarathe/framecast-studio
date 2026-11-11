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
    /// A phone or computer joined through the camera link: a camera angle of the presenter, never a guest on stage.
    var isDevice = false
    /// Its microphone is heard in the show only once the host allows it (off by default).
    var audioAllowed = false
    /// When its page last asked about its pass (or knocked); a page that stops asking and never connected is gone.
    var lastSeen = Date()
    /// Reached the room at least once (a dropped one keeps its place for a while; one that never came is let go).
    var everConnected = false
    /// Counts drops, so the grace period of an earlier drop can't remove it after it dropped again.
    var drops = 0
    /// Where they were in the on-air order when they dropped, so a rejoin puts them back in the same tile.
    var stageIndex: Int?
    var identity: String { "\(isDevice ? "d" : "g")-\(id)\(admittedSuffix)" }
}

/// Receives one guest's camera or screen frames.
final class GuestVideoSink: NSObject, VideoRenderer, @unchecked Sendable {
    let slot = FrameSlot()
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 1920, height: 1080) }
    func render(frame: LiveKit.VideoFrame) {
        guard let pb = frame.toCVPixelBuffer() else { return }
        // Phones send portrait frames sideways with a rotation tag; the sources turn them upright.
        slot.put(pb, pts: HostClock.now(), rotation: frame.rotation.rawValue)
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
        let img = CIImage(cvPixelBuffer: pb).rotatedUpright(s.rotation)
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
    /// The camera link: phones and computers that open it become camera angles (Angles tab).
    var deviceInviteURL: String?
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
    @ObservationIgnored private var deviceCode = ""
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
    @ObservationIgnored private var currentDeviceInvite: String?
    static let maxGuests = 10, maxDevices = 6

    init(studio: Studio) { self.studio = studio; super.init() }

    var lobby: [Guest] { guests.filter { !$0.isDevice && $0.status != .stage } }
    var stage: [Guest] { guests.filter { !$0.isDevice && $0.status == .stage } }
    /// Camera angles from phones and computers (asking to join, or in).
    var devices: [Guest] { guests.filter(\.isDevice) }

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
        s.onRoomInfo = { [weak self] c in
            guard let self else { return ("", false) }
            return (self.roomTitle, c == self.code || (!self.deviceCode.isEmpty && c == self.deviceCode))
        }
        s.onKnock = { [weak self] c, name, detail in self?.knock(code: c, name: name, detail: detail) }
        s.onTicket = { [weak self] id in self?.ticket(id) ?? ["state": "denied"] }
        s.onDeviceLog = { [weak self] t, name, event, detail, camera in self?.pageSaid(ticket: t, name: name, event: event, detail: detail, camera: camera) }
        isOpen = true
        newInviteLink(rotate: false)
        newDeviceLink(rotate: false)
        status = "Opening your guest room…"
        ensureGuestLayouts()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.dropAbandoned() }
        // A local LiveKit server needs a moment to start listening.
        let gen = hostGen
        DispatchQueue.main.asyncAfter(deadline: .now() + (s.runsLocalServer ? 1.2 : 0.1)) { [weak self] in self?.connectHost(attempt: 1, gen: gen) }
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
        hostGen += 1                          // any connect still in flight belongs to the old room
        if let feed = programFeed { studio.engine.removeConsumer(feed) }
        programFeed = nil
        let r = room
        Task { await r?.disconnect() }
        room = nil
        server?.stop(); server = nil
        for (_, a) in audioSinks { studio.engine.mixer.removeSource(a.id) }
        audioSinks.removeAll()
        // The render thread reads these under the lock.
        lock.lock(); videoSinks.removeAll(); screenSinks.removeAll(); stageOrder.removeAll(); lock.unlock()
        guests.removeAll(); openInvites.removeAll(); currentInvite = nil; currentDeviceInvite = nil
        removedIdentities.removeAll(); refusedTickets.removeAll(); tokens.removeAll()
        sweepTimer?.invalidate(); sweepTimer = nil
        isOpen = false; inviteURL = nil; deviceInviteURL = nil
        status = "Not connected to the guest room"
        studio.angles.devicesChanged()
    }

    /// The invite link. On this Mac and the Wi-Fi it stays the same across rooms and restarts, so a link sent
    /// earlier keeps working (`rotate`: New link replaces it, and the old one stops working). Internet links are
    /// single-use and always new.
    func newInviteLink(rotate: Bool = true) {
        guard let server else { return }
        switch reach {
        case .thisMac:
            code = Self.savedCode("GuestInviteCode", rotate: rotate)
            inviteURL = "http://127.0.0.1:\(GuestServer.httpPort)/invite/\(code)"
        case .wifi:
            code = Self.savedCode("GuestInviteCode", rotate: rotate)
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

    /// The camera link (phones and computers join as camera angles); stays the same like the invite link.
    func newDeviceLink(rotate: Bool = true) {
        guard let server else { return }
        switch reach {
        case .thisMac:
            deviceCode = Self.savedCode("GuestCameraCode", rotate: rotate)
            deviceInviteURL = "http://127.0.0.1:\(GuestServer.httpPort)/camera/\(deviceCode)"
        case .wifi:
            deviceCode = Self.savedCode("GuestCameraCode", rotate: rotate)
            deviceInviteURL = "https://\(server.lanAddress ?? "127.0.0.1"):\(GuestServer.httpsPort)/camera/\(deviceCode)"
        case .internet:
            if let old = currentDeviceInvite { openInvites.remove(old) }
            let identity = "d-\(UUID().uuidString.prefix(8).lowercased())"
            openInvites.insert(identity); currentDeviceInvite = identity
            let token = server.token(identity: identity, name: "Camera", room: roomName, lobby: true)
            let fragment = [("u", server.signalURL), ("t", token), ("n", roomTitle)]
                .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "")" }
                .joined(separator: "&")
            deviceInviteURL = Self.cameraPage(cloud.pageURL) + "#" + fragment
        }
    }

    /// The camera page sits next to the hosted guest page.
    static func cameraPage(_ guestPage: String) -> String {
        guard var c = URLComponents(string: guestPage) else { return guestPage }
        var path = c.path.isEmpty ? "/" : c.path
        if path.hasSuffix(".html") { path = (path as NSString).deletingLastPathComponent }
        if !path.hasSuffix("/") { path += "/" }
        c.path = path + "camera.html"
        c.fragment = nil
        return c.string ?? guestPage
    }

    /// A link code kept in the user defaults (test launches keep their own), made new when asked or missing.
    static func savedCode(_ key: String, rotate: Bool) -> String {
        let k = key + (CollectionStore.profile == "default" ? "" : ".tests")
        if !rotate, let c = UserDefaults.standard.string(forKey: k), c.count >= 8 { return c }
        let c = makeCode()
        UserDefaults.standard.set(c, forKey: k)
        return c
    }

    static func makeCode() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars.randomElement()! })
    }

    /// Bumped by close(): a connect from an earlier room must not take over the new one.
    @ObservationIgnored private var hostGen = 0

    /// `persistent`: the room was lost mid-show, so keep trying (with growing pauses) until it's back or closed.
    private func connectHost(attempt: Int, gen: Int, persistent: Bool = false) {
        guard let server, isOpen, gen == hostGen else { return }
        // LiveKit's audio engine would otherwise switch the input device to Apple's voice processing, which hands
        // every other microphone reader in the app (Framecast's own Mic source) silence for as long as it runs.
        try? AudioManager.shared.setVoiceProcessingEnabled(false)
        let r = Room(delegate: self)
        room = r
        let token = server.token(identity: "host", name: "Host", room: roomName)
        Task { @MainActor in
            do {
                try await r.connect(url: server.signalURL, token: token)
                guard gen == self.hostGen, self.room === r else { await r.disconnect(); return }
                // Participants already in the room come in the join response, which LiveKit doesn't announce.
                for p in r.remoteParticipants.values { self.room(r, participantDidConnect: p) }
                switch reach {
                case .thisMac: status = "Guest room open on this Mac"
                case .wifi: status = "Guest room open to your Wi-Fi"
                case .internet: status = cloud.isLocalTest ? "Guest room open (remote-guest test on this Mac)" : "Guest room open on LiveKit Cloud"
                }
            } catch {
                guard gen == self.hostGen, self.room === r else { return }
                if persistent || attempt < 5 {
                    let delay = persistent ? min(30, pow(2, Double(min(attempt, 5)))) : 1
                    if persistent { status = "Lost the guest room, trying again… (\(error.localizedDescription))" }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connectHost(attempt: attempt + 1, gen: gen, persistent: persistent) }
                } else { status = "The guest room didn't answer. \(error.localizedDescription)" }
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
            catch {
                guard self.room === r else { studio.engine.removeConsumer(feed); return }
                status = "Guest room open, but your show couldn't be sent to guests (\(error.localizedDescription))."
            }
            guard self.room === r else { return }
            // Guests hear you: the SDK captures your default microphone with echo cancellation (never in a test
            // launch with stand-in devices).
            if shareHostMic && !FakeDevices.isOn { do { _ = try await r.localParticipant.setMicrophone(enabled: true) }
            catch { status = "Guest room open. Your microphone couldn't be shared with guests (\(error.localizedDescription))." } }

        }
    }

    // MARK: Join API (main queue)

    private func knock(code c: String, name: String, detail: String) -> (ticket: String, state: String)? {
        let isDevice = !deviceCode.isEmpty && c == deviceCode
        guard isOpen, c == code || isDevice else {
            joinLog(name, "used an old or wrong link (send the current one from Guests or Angles)", problem: true, device: detail == "camera")
            return nil
        }
        func taken() -> Int { isDevice ? devices.count : guests.count - devices.count }
        if taken() >= (isDevice ? Self.maxDevices : Self.maxGuests) { dropAbandoned() }
        guard taken() < (isDevice ? Self.maxDevices : Self.maxGuests) else {
            joinLog(name, "couldn't join: the room is full (\(isDevice ? Self.maxDevices : Self.maxGuests) at most)", problem: true, device: isDevice)
            return ("", "full")
        }
        let id = UUID().uuidString.prefix(8).lowercased()
        var g = Guest(id: String(id), name: name, detail: detail, status: askBeforeLettingIn ? .waiting : .lobby)
        g.isDevice = isDevice
        guests.append(g)
        joinLog(name, askBeforeLettingIn ? "is waiting to be let in" : "joined", device: isDevice, ticket: String(id))
        if !askBeforeLettingIn { issueToken(g) }
        return (String(id), askBeforeLettingIn ? "waiting" : "admitted")
    }

    private func ticket(_ id: String) -> [String: Any] {
        // "denied" only for a pass the host took back; a pass the Mac lost track of (the page slept past its
        // minute, the room or app restarted) is "gone", and the page knocks again by itself.
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return ["state": refusedTickets.contains(id) ? "denied" : "gone"] }
        guests[i].lastSeen = Date()
        let g = guests[i]
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
        let isDevice = identity.hasPrefix("d-")
        guard reach == .internet, isOpen, identity.hasPrefix("g-") || isDevice else { return }
        // The page repeats its knock until it's let in, also while its admission is on the way (the entry is then
        // "-in"). One let in earlier that isn't in the room (it reloaded, or missed the admission) is let in again.
        let ticket = String(identity.dropFirst(2))
        if let i = guests.firstIndex(where: { $0.id == ticket && $0.isDevice == isDevice }) {
            if guests[i].admittedSuffix == "-in", !guests[i].connected, Date().timeIntervalSince(guests[i].lastSeen) > 5 {
                guests[i].lastSeen = Date()
                letInRemote(i)
            }
            return
        }
        let roomFull = isDevice ? devices.count >= Self.maxDevices : guests.count - devices.count >= Self.maxGuests
        guard openInvites.remove(identity) != nil, !roomFull else {
            server?.removeParticipant(room: roomName, identity: identity)       // used, replaced or room full
            return
        }
        if identity == currentInvite { currentInvite = nil; newInviteLink() }  // single-use: show a fresh one
        if identity == currentDeviceInvite { currentDeviceInvite = nil; newDeviceLink() }
        var g = Guest(id: String(identity.dropFirst(2)), name: name, detail: detail, status: askBeforeLettingIn ? .waiting : .lobby)
        g.isDevice = isDevice
        g.connected = true
        guests.append(g)
        if !askBeforeLettingIn { admit(g.id) }
    }

    // MARK: Host actions

    func admit(_ id: String) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        if guests[i].status == .waiting { joinLog(guests[i].name, "let in", device: guests[i].isDevice, ticket: id) }
        guests[i].status = .lobby
        guests[i].lastSeen = Date()          // the let-in page gets a fresh minute to arrive (remote pages never poll)
        if reach == .internet { letInRemote(i) } else { issueToken(guests[i]) }
    }

    /// Remote guests wait on an invite token that can only knock. Letting one in hands them a full token for a
    /// new identity over a data message; their page reconnects with it. Repeated until they arrive.
    private func letInRemote(_ i: Int) {
        guard let server else { return }
        let lobbyIdentity = "\(guests[i].isDevice ? "d" : "g")-\(guests[i].id)"
        guests[i].admittedSuffix = "-in"
        // The admitted identity is a new arrival: it hasn't been in the room, and a lobby blip doesn't count.
        guests[i].connected = false
        guests[i].everConnected = false
        guests[i].drops = 0
        let g = guests[i]
        let token = server.token(identity: g.identity, name: g.name, room: roomName)
        server.allowMessages(room: roomName, identity: lobbyIdentity) { [weak self] _ in
            self?.sendAdmission(token, to: lobbyIdentity, arrivingAs: g.identity, attempt: 1)
        }
    }

    private func sendAdmission(_ token: String, to lobbyIdentity: String, arrivingAs identity: String, attempt: Int) {
        guard isOpen, attempt <= 10, guests.contains(where: { $0.identity == identity }),
              room?.remoteParticipants[Participant.Identity(from: identity)] == nil else { return }
        if let j = guests.firstIndex(where: { $0.identity == identity }) { guests[j].lastSeen = Date() }
        send(["type": "admit", "token": token], to: lobbyIdentity, topic: "control")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendAdmission(token, to: lobbyIdentity, arrivingAs: identity, attempt: attempt + 1)
        }
    }

    func bringOnStage(_ id: String) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        guard guests[i].connected else {
            joinLog(guests[i].name, "isn't in the room yet, so it can't go on air", problem: true, device: guests[i].isDevice, ticket: id)
            return
        }
        guests[i].status = .stage
        guests[i].stageIndex = nil
        lock.lock(); if !stageOrder.contains(guests[i].identity) { stageOrder.append(guests[i].identity) }; lock.unlock()
        send(["type": "stage", "on": true], to: guests[i].identity, topic: "control")
        updateGuestAudio()
    }

    func takeOffStage(_ id: String) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        guests[i].status = .lobby
        guests[i].stageIndex = nil
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
        removedIdentities.insert(g.identity)
        refusedTickets.insert(id)
    }

    /// Identities the host removed: their pass is still valid for LiveKit, so if one comes back it's sent away.
    @ObservationIgnored private var removedIdentities: Set<String> = []
    @ObservationIgnored private var refusedTickets: Set<String> = []
    @ObservationIgnored private var sweepTimer: Timer?

    /// Lets go of entries whose page went away before reaching the room (closed or reloaded while waiting, or let in
    /// but never connected): they'd otherwise fill the room. A page asks about its pass every second while it waits.
    private func dropAbandoned() {
        let now = Date()
        // Entries that were in the room and dropped have the 3-minute grace instead; one LiveKit says is in the
        // room is never dropped here.
        let gone = guests.filter { !$0.connected && !$0.everConnected && $0.drops == 0 && now.timeIntervalSince($0.lastSeen) > 60
            && room?.remoteParticipants[Participant.Identity(from: $0.identity)] == nil }
        guard !gone.isEmpty else { return }
        for g in gone {
            joinLog(g.name, "stopped waiting (its page closed or lost the Wi-Fi)", device: g.isDevice, ticket: g.id)
            tokens[g.id] = nil
            // Nothing of it may stay in the room unseen: a remote page's lobby connection, or a late arrival.
            server?.removeParticipant(room: roomName, identity: g.identity)
            if g.admittedSuffix == "-in" { server?.removeParticipant(room: roomName, identity: String(g.identity.dropLast(3))) }
        }
        let ids = Set(gone.map(\.id))
        guests.removeAll { ids.contains($0.id) }
    }

    func sendChat(_ text: String) { send(["text": text, "from": "Host"], to: nil, topic: "backstage") }

    // MARK: Camera angles (devices)

    /// What devices reported about themselves, newest last (Angles shows the latest; GuestServer/devices.log keeps all).
    /// Every step of joining, for guests and devices alike: what the Mac saw (knock, old link, let in, connected,
    /// dropped) and what the pages reported (couldn't connect, camera failed, reconnected). The Guests and Angles
    /// panels show the latest; GuestServer/devices.log keeps them all.
    struct JoinEvent: Identifiable, Equatable { let id = UUID(); var name: String; var text: String; var problem: Bool; var device: Bool; var at: Date }
    private(set) var joinEvents: [JoinEvent] = []

    func joinLog(_ name: String, _ text: String, problem: Bool = false, device: Bool, detail: String = "", ticket: String = "") {
        joinEvents.append(JoinEvent(name: name.isEmpty ? (device ? "A device" : "A guest") : name, text: text, problem: problem, device: device, at: Date()))
        if joinEvents.count > 40 { joinEvents.removeFirst(joinEvents.count - 40) }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(device ? "device" : "guest") \(ticket) \(name): \(text)\(detail.isEmpty ? "" : " · \(detail)")\n"
        let url = GuestServer.folder.appendingPathComponent("devices.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// The page pressed Leave: no 3-minute place, and its pass can't bring it back (a new join knocks again).
    private func leftForGood(_ i: Int) {
        let g = guests[i]
        lock.lock(); stageOrder.removeAll { $0 == g.identity }; lock.unlock()
        tokens[g.id] = nil
        guests.remove(at: i)
        joinLog(g.name, "left", device: g.isDevice, ticket: g.id)
        if g.isDevice { studio.angles.devicesChanged() }
        updateGuestAudio()
    }

    fileprivate func pageSaid(ticket: String, name: String, event: String, detail: String, camera: Bool) {
        if event == "leaving" {
            if let i = guests.firstIndex(where: { $0.id == ticket }) { leftForGood(i) }
            return
        }
        // A page still reporting (retrying its connection, say) hasn't been abandoned.
        if let i = guests.firstIndex(where: { $0.id == ticket }), event != "left" { guests[i].lastSeen = Date() }
        let plain: String
        switch event {
        case "connected": plain = "connected"
        case "rejoined": plain = "reconnected"
        case "disconnected": plain = "lost the connection, reconnecting"
        case "connect-failed": plain = "couldn't connect (\(detail.components(separatedBy: " · ").first ?? ""))"
        case "camera-failed": plain = "couldn't start its camera (\(detail.components(separatedBy: " · ").first ?? ""))"
        case "mic-refused": plain = "joined without its microphone"
        case "mic-failed": plain = "couldn't start its microphone (\(detail.components(separatedBy: " · ").first ?? ""))"
        case "left": plain = "left"
        case "poll-failed": plain = "lost touch with this Mac while waiting, trying again"
        case "knock-again": plain = "knocked again (this Mac had let its place go)"
        case "camera-switched": plain = "switched camera (\(detail.components(separatedBy: " · ").first ?? ""))"
        case "camera-ended": plain = "lost its camera (the phone took it away), restarting it"
        case "camera-restarted": plain = "got its camera back"
        case "publish-failed": plain = "couldn't send its picture (\(detail.components(separatedBy: " · ").first ?? ""))"
        case "share-failed": plain = "couldn't share its screen (\(detail.components(separatedBy: " · ").first ?? ""))"
        default: plain = event
        }
        let problem = ["connect-failed", "camera-failed", "disconnected", "mic-failed", "poll-failed", "camera-ended", "publish-failed", "share-failed"].contains(event)
        let device = guests.first { $0.id == ticket }?.isDevice ?? camera
        joinLog(name, plain, problem: problem, device: device, detail: "page: \(event) \(detail)", ticket: ticket)
    }

    /// Lets a device's microphone into the show, or takes it out again (devices join with it off).
    func setDeviceAudio(_ id: String, _ on: Bool) {
        guard let i = guests.firstIndex(where: { $0.id == id && $0.isDevice }) else { return }
        guests[i].audioAllowed = on
        send(["type": "audio", "on": on], to: guests[i].identity, topic: "control")
        updateGuestAudio()
    }

    /// Tells a device page whether its angle is on air (it shows a red frame, like a tally light).
    func tellDevice(_ identity: String, onAir: Bool) { send(["type": "tally", "on": onAir], to: identity, topic: "control") }

    /// Asks a device page to lend its microphone (not into the show) while its sound is lined up with the Mac's.
    func askDeviceForSync(_ identity: String, on: Bool) { send(["type": "sync", "on": on], to: identity, topic: "control") }

    /// The mixer source carrying a device's (or guest's) sound, once its microphone track arrived.
    func audioSourceID(_ identity: String) -> UUID? { audioSinks[identity]?.id }

    /// The latest frame a device sent.
    func deviceFrameSlot(_ identity: String) -> FrameSlot? {
        lock.lock(); defer { lock.unlock() }
        return videoSinks[identity]?.slot
    }

    /// A page that (re)connected starts from scratch: tell it where it stands (on air or not, muted by the host, its
    /// sound let into the show, its tally).
    private func resync(_ g: Guest) {
        if g.isDevice {
            send(["type": "audio", "on": g.audioAllowed], to: g.identity, topic: "control")
            studio.angles.deviceArrived(g.identity)
        } else {
            send(["type": "stage", "on": g.status == .stage], to: g.identity, topic: "control")
            if g.mutedByHost { send(["type": "mute"], to: g.identity, topic: "control") }
        }
    }

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
            a.isInProgram = (g.isDevice ? g.audioAllowed : g.status == .stage) && !g.mutedByHost
            a.isMuted = g.mutedByHost
            studio.engine.mixer.update(sink.id, settings: a)
        }
    }

    // MARK: Slots for layouts

    /// Who fills the guest tiles on air, in slot order (for tests).
    var stageNames: [String] {
        lock.lock(); let order = stageOrder; lock.unlock()
        return order.map { id in guests.first { $0.identity == id }?.name ?? id }
    }

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
        let name = participant.name ?? ""
        DispatchQueue.main.async {
            guard room === self.room else { return }
            if let i = self.guests.firstIndex(where: { $0.identity == id }) {
                if self.guests[i].connected && self.guests[i].everConnected { return }   // already counted (join response)
                // A remote page still waiting in the lobby is back, but it hasn't been let in.
                if self.reach == .internet, self.guests[i].status == .waiting { self.guests[i].connected = true; return }
                let back = self.guests[i].everConnected
                self.guests[i].connected = true
                self.guests[i].everConnected = true
                self.joinLog(self.guests[i].name, back ? "is back in the room" : "is in the room", device: self.guests[i].isDevice, ticket: self.guests[i].id)
                // A guest who was on air when they dropped goes back on air, in the tile they had.
                if self.guests[i].status == .stage {
                    self.lock.lock()
                    if !self.stageOrder.contains(id) { self.stageOrder.insert(id, at: min(self.guests[i].stageIndex ?? self.stageOrder.count, self.stageOrder.count)) }
                    self.lock.unlock()
                }
                self.guests[i].stageIndex = nil
                self.resync(self.guests[i])
                if self.guests[i].isDevice { self.studio.angles.devicesChanged() }
                self.updateGuestAudio()
                return
            }
            guard id.hasPrefix("g-") || id.hasPrefix("d-") else { return }
            let isDevice = id.hasPrefix("d-")
            let full = isDevice ? self.devices.count >= Self.maxDevices : self.guests.count - self.devices.count >= Self.maxGuests
            // Remote rooms: lobby identities ("g-xxxxxxxx") still go through the knock. An admitted one ("…-in")
            // holds a pass the host issued; with no entry, it was removed (sent away) or its 3 minutes ran out
            // (its place is given back, as on this Mac and the Wi-Fi).
            if self.reach == .internet {
                guard id.hasSuffix("-in") else { return }
                if self.removedIdentities.contains(id) || full {
                    self.server?.removeParticipant(room: self.roomName, identity: id)
                    return
                }
                var g = Guest(id: String(id.dropFirst(2).dropLast(3)), name: name.isEmpty ? (isDevice ? "Phone camera" : "Guest") : name, detail: "", status: .lobby)
                g.isDevice = isDevice; g.admittedSuffix = "-in"; g.connected = true; g.everConnected = true
                self.guests.append(g)
                self.joinLog(g.name, "is back in the room", device: isDevice, ticket: g.id)
                self.resync(g)
                if isDevice { self.studio.angles.devicesChanged() }
                self.updateGuestAudio()
                return
            }
            // On this Mac or the Wi-Fi every pass comes from a knock: a page coming back after its place ran out
            // gets it again; one the host removed (its pass still opens LiveKit) is sent away.
            var ticket = String(id.dropFirst(2))
            if ticket.hasSuffix("-in") { ticket = String(ticket.dropLast(3)) }
            if !self.removedIdentities.contains(id), self.tokens[ticket] != nil, !full {
                var g = Guest(id: ticket, name: name.isEmpty ? (id.hasPrefix("d-") ? "Phone camera" : "Guest") : name, detail: "", status: .lobby)
                g.isDevice = id.hasPrefix("d-"); g.connected = true; g.everConnected = true
                self.guests.append(g)
                self.joinLog(g.name, "is back in the room", device: g.isDevice, ticket: ticket)
                self.resync(g)
                if g.isDevice { self.studio.angles.devicesChanged() }
            } else {
                self.server?.removeParticipant(room: self.roomName, identity: id)
            }
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let id = participant.identity?.stringValue ?? ""
        // A page that rejoined with the same pass replaces its old connection: if a newer one is already in the
        // room, this is only the old one leaving. While the host's own connection is being rebuilt, the SDK clears
        // everyone and the join response puts them back silently, so those aren't drops either.
        if let p = room.remoteParticipants[Participant.Identity(from: id)], p !== participant || room.connectionState == .reconnecting { return }
        DispatchQueue.main.async { if room === self.room { self.dropped(id) } }
    }

    /// Someone's connection ended. The media belonged to it (a rejoin subscribes fresh). Guests and cameras both
    /// rejoin by themselves after a blip (their pages retry with the same pass), so they keep their place, on-air
    /// status and angle number for 3 minutes; meanwhile the next guest on air moves up so no tile is left blank.
    private func dropped(_ id: String, why: String = "dropped out") {
        lock.lock(); let pos = stageOrder.firstIndex(of: id); videoSinks[id] = nil; screenSinks[id] = nil; stageOrder.removeAll { $0 == id }; lock.unlock()
        if let a = audioSinks.removeValue(forKey: id) { studio.engine.mixer.removeSource(a.id) }
        if let i = guests.firstIndex(where: { $0.identity == id }), guests[i].connected || !guests[i].everConnected {
            if let pos { guests[i].stageIndex = pos }
            guests[i].connected = false
            guests[i].drops += 1
            // Keyed on the ticket: letting a remote guest in renames their identity.
            let drop = guests[i].drops, g = guests[i], ticket = g.id, isDevice = g.isDevice
            joinLog(g.name, "\(why) (keeping \(g.isDevice ? "its" : "their") place for 3 minutes)", problem: true, device: g.isDevice, ticket: g.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                guard let self, let g = self.guests.first(where: { $0.id == ticket && $0.isDevice == isDevice }), !g.connected, g.drops == drop else { return }
                self.lock.lock(); self.stageOrder.removeAll { $0 == g.identity }; self.lock.unlock()
                self.guests.removeAll { $0.id == ticket && $0.isDevice == isDevice }
                self.joinLog(g.name, "didn't come back", device: g.isDevice, ticket: g.id)
                if g.isDevice { self.studio.angles.devicesChanged() }
            }
        }
        updateGuestAudio()
        if id.hasPrefix("d-") { studio.angles.devicesChanged() }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let id = participant.identity?.stringValue ?? ""
        guard let track = publication.track else { return }
        DispatchQueue.main.async {
            guard room === self.room else { return }
            if let v = track as? RemoteVideoTrack {
                let sink = GuestVideoSink()
                v.add(videoRenderer: sink)
                self.lock.lock()
                if publication.source == .screenShareVideo { self.screenSinks[id] = sink } else { self.videoSinks[id] = sink }
                self.lock.unlock()
                if let i = self.guests.firstIndex(where: { $0.identity == id }) {
                    if publication.source == .screenShareVideo { self.guests[i].sharingScreen = true } else { self.guests[i].camOn = true }
                }
                if id.hasPrefix("d-") { self.studio.angles.devicesChanged() }
            } else if let a = track as? RemoteAudioTrack {
                if let old = self.audioSinks.removeValue(forKey: id) { self.studio.engine.mixer.removeSource(old.id) }
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
            guard room === self.room else { return }
            // A camera's picture stays until its next track replaces it (a page that switches cameras the old way, or
            // republishes after the phone took the camera away), so its angle and stage slot don't vanish between
            // the two. The frame still ages, so a camera that really stopped is cut away from.
            self.lock.lock()
            if publication.source == .screenShareVideo { self.screenSinks[id] = nil }
            self.lock.unlock()
            if publication.kind == .audio, let a = self.audioSinks.removeValue(forKey: id) { self.studio.engine.mixer.removeSource(a.id) }
            if let i = self.guests.firstIndex(where: { $0.identity == id }), publication.source == .screenShareVideo { self.guests[i].sharingScreen = false }
            if id.hasPrefix("d-") { self.studio.angles.devicesChanged() }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        // A camera page answers the Mac (it can't lend its microphone for lining up sound, say).
        if topic == "camera", let identity = participant?.identity?.stringValue, identity.hasPrefix("d-"),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            DispatchQueue.main.async { self.studio.angles.deviceSaid(identity, o) }
            return
        }
        // A remote page pressed Leave (pages on this Mac and the Wi-Fi say so through /api/log).
        if topic == "left", let identity = participant?.identity?.stringValue {
            DispatchQueue.main.async { if let i = self.guests.firstIndex(where: { $0.identity == identity }) { self.leftForGood(i) } }
            return
        }
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
        // The SDK clears its participants without telling us one by one, so everyone counts as dropped here.
        DispatchQueue.main.async {
            guard self.isOpen, room === self.room else { return }   // close() already cleaned up
            self.status = "Not connected to the guest room. \(error?.localizedDescription ?? "")"
            for g in self.guests where g.connected { self.dropped(g.identity, why: "lost the room (the guest room disconnected)") }
            // Get back in, with the same room and passes: pages that rejoin meanwhile are found in the join response.
            if let feed = self.programFeed { self.studio.engine.removeConsumer(feed) }
            self.programFeed = nil; self.programTrack = nil
            self.room = nil
            self.status = "Lost the guest room, reconnecting…"
            self.connectHost(attempt: 1, gen: self.hostGen, persistent: true)
        }
    }

    nonisolated func roomDidReconnect(_ room: Room) {
        // After a full reconnect the join response lists who is there, silently: count arrivals, and anyone the Mac
        // still thinks is connected but who isn't there any more dropped out during the gap.
        let present = Set(room.remoteParticipants.keys.map(\.stringValue))
        for p in room.remoteParticipants.values { self.room(room, participantDidConnect: p) }
        DispatchQueue.main.async {
            guard room === self.room else { return }
            for g in self.guests where g.connected && g.everConnected && !present.contains(g.identity) { self.dropped(g.identity) }
        }
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
