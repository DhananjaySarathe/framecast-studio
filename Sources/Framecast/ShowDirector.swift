import Foundation
import Observation
import FramecastEngine

/// Runs the show from its rundown: listens on this Mac, notices when the presenter says the next part's cue and
/// either suggests the switch (one key to take it) or makes it (with undo).
/// Guards: nothing automatic within the minimum shot after any switch, at most six automatic switches a minute,
/// automatic switching pauses for 30 s after a switch by hand that isn't the next part, and the director only ever
/// changes scenes (never recording, broadcasting or sound).
@Observable
final class ShowDirector {
    unowned let studio: Studio
    private(set) var show: ShowRundown?
    private(set) var folder: URL?
    /// The part on air (nil before the show starts).
    var current: Int?
    var suggestion: Suggestion?
    var lastAuto: AutoSwitch?
    var pausedUntil: Date?
    var isListening = false
    var status = ""
    var heard = ""
    /// While the AI writes a rundown: what it's doing. `writeError` holds the last failure.
    var writing: String?
    var writeError: String?
    /// Where the presenter is in the script (last word matched, -1 before the first) and whether recent speech
    /// matches the script.
    var scriptPosition = -1
    var onScript = false
    /// A rehearsal records what was heard (rehearsals/<date time>.jsonl in the show folder); when it ends, it's
    /// replayed against the rundown (see Rehearsal.swift).
    var isRehearsing = false
    var rehearsalStart: Date?
    var report: RehearsalReport?
    var isReplaying = false
    /// Live brain (topic shows, see LiveBrain.swift and BrainDirector.swift): where the show is, what's covered,
    /// the asset on screen, and what the brain last did.
    var topicIndex: Int?
    var covered: Set<String> = []
    var currentAsset: String?
    var brainStatus = ""
    var lastDecision = ""
    var brainCost = 0.0
    var brainCalls = 0
    var brainSuggestion: BrainSuggestion?
    var brainReport: BrainReplayReport?

    struct Suggestion: Equatable { var part: Int; var heard: String; var how: String; var note: String?; var at = Date() }
    /// The director's last automatic change, for undo. `part` is -1 for a live-brain change.
    struct AutoSwitch: Equatable {
        var part: Int; var fromScene: UUID?; var fromPart: Int?; var label = ""
        var fromAsset: String?; var restoresAsset = false; var at = Date()
    }
    struct BrainSuggestion: Equatable { var action: BrainAction; var reason: String; var at = Date() }

    static let pauseAfterManual = 30.0
    static let maxAutoPerMinute = 6
    static let suggestionLife = 12.0

    @ObservationIgnored let matcher = CueMatcher()
    @ObservationIgnored let tracker = ScriptTracker()
    @ObservationIgnored private var scriptCache: (show: ShowRundown?, script: PrompterScript)?
    @ObservationIgnored var rehearsalFile: FileHandle?
    @ObservationIgnored var rehearsalURL: URL?
    @ObservationIgnored var assetSlotID: UUID?
    @ObservationIgnored var assetSourceID: UUID?
    @ObservationIgnored var brain = BrainState()
    @ObservationIgnored var showClockStart = Date()
    @ObservationIgnored var heardFinals: [(t: Double, text: String)] = []
    @ObservationIgnored var heardGuess = ""
    @ObservationIgnored var heardSinceCall = false
    @ObservationIgnored var brainInFlight = false
    @ObservationIgnored var brainLastCall = Date.distantPast
    @ObservationIgnored var brainFailures = 0
    @ObservationIgnored var brainTimer: Timer?
    @ObservationIgnored var brainChanges: [(t: Double, text: String)] = []
    @ObservationIgnored var brainPrompt: (key: String, system: String, schema: [String: Any])?
    @ObservationIgnored var brainRetry: DispatchWorkItem?
    /// The API key for the live brain, read once per listening session (off the main thread).
    @ObservationIgnored var brainKeyCache: String?
    /// Hinglish: the Hindi recogniser and what it heard (for the live brain only).
    @ObservationIgnored var secondListener: AnyObject?
    @ObservationIgnored var heardSecond: [(t: Double, text: String)] = []
    @ObservationIgnored var folderStamp = ""
    @ObservationIgnored var folderTimer: Timer?
    @ObservationIgnored private var listener: AnyObject?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var expiryWork: DispatchWorkItem?
    @ObservationIgnored private var deferredWork: DispatchWorkItem?
    @ObservationIgnored private var lastSwitch = Date.distantPast
    @ObservationIgnored private var autoTimes: [Date] = []
    @ObservationIgnored private var switching = false
    @ObservationIgnored private let logQueue = DispatchQueue(label: "framecast.director.log", qos: .utility)

    init(studio: Studio) {
        self.studio = studio
        if let last = ShowStore.lastOpened, FileManager.default.fileExists(atPath: last.appendingPathComponent("show.json").path) { open(last) }
    }

    var mode: DirectorMode { show?.director.mode ?? .off }
    var parts: [RundownPart] { show?.parts ?? [] }
    var topics: [ShowTopic] { show?.topics ?? [] }
    /// A topic show is run by the live brain; a parts show by cue lines.
    var hasTopics: Bool { !topics.isEmpty }

    /// The show's words for the prompter, rebuilt when the show changes.
    var prompterScript: PrompterScript {
        if let c = scriptCache, c.show == show { return c.script }
        let s = PrompterScript(show: show, norm: matcher.norm)
        scriptCache = (show, s)
        tracker.reset()
        return s
    }

    // MARK: Show files

    func newShow(title: String = "New show") {
        close()
        let f = ShowStore.newFolder(title: title)
        show = ShowRundown(title: title)
        folder = f
        ShowStore.save(show!, in: f)
        ShowStore.lastOpened = f
        watchFolder()
    }

    func open(_ url: URL) {
        guard let s = try? ShowStore.load(url) else { studio.notice = "That show couldn't be read."; return }
        close()
        show = s; folder = url
        ShowStore.lastOpened = url
        applyAliases()
        ShowGuide.write(in: url)
        watchFolder()
    }

    func close() {
        saveNow()
        stopListening()
        folderTimer?.invalidate(); folderTimer = nil
        show = nil; folder = nil; current = nil; suggestion = nil; lastAuto = nil; pausedUntil = nil; report = nil
        topicIndex = nil; covered = []; currentAsset = nil; assetSourceID = nil; brainSuggestion = nil; brainReport = nil
        lastDecision = ""; brainStatus = ""; brain = BrainState()
        matcher.reset(); tracker.reset(); scriptPosition = -1
    }

    /// Changes the open show and saves it shortly after.
    func edit(_ change: (inout ShowRundown) -> Void) {
        guard var s = show else { return }
        change(&s)
        guard s != show else { return }
        show = s
        applyAliases()
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        if let show, let folder { ShowStore.save(show, in: folder); folderStamp = Self.stamp(folder) }
    }

    func setMode(_ m: DirectorMode) {
        edit { $0.director.mode = m }
        suggestion = nil; pausedUntil = nil
        log("mode", ["mode": m.rawValue])
    }

    private func applyAliases() {
        matcher.aliases = Dictionary((show?.aliases ?? []).map { (matcher.norm($0.heard), $0.meant.lowercased()) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Parts

    func sceneID(for part: RundownPart) -> UUID? {
        studio.scenes.first { $0.name.caseInsensitiveCompare(part.scene.trimmingCharacters(in: .whitespaces)) == .orderedSame }?.id
    }

    /// The next three parts that have a cue, in order: what the director listens for.
    var upcoming: [(index: Int, part: RundownPart)] { Self.upcoming(parts, after: current) }

    static func upcoming(_ parts: [RundownPart], after current: Int?) -> [(index: Int, part: RundownPart)] {
        let from = (current ?? -1) + 1
        guard from < parts.count else { return [] }
        return Array(parts.enumerated().dropFirst(from).filter { !$0.element.cue.trimmingCharacters(in: .whitespaces).isEmpty || !$0.element.alsoAccept.contains { !$0.isEmpty } }
            .prefix(3).map { (index: $0.offset, part: $0.element) })
    }

    /// The prompter's place moves to the start of a part's text when that part goes on air.
    private func movePrompter(to part: Int) {
        let s = prompterScript
        guard let start = s.partStart[part] else { return }
        tracker.jump(to: start)
        scriptPosition = tracker.position
    }

    var nextPart: Int? { let n = (current ?? -1) + 1; return n < parts.count ? n : nil }

    /// Puts a part on air now (the Take button, the shortcut, or the control link).
    func take(_ i: Int, by who: String = "you") {
        guard parts.indices.contains(i) else { return }
        let part = parts[i]
        guard let id = sceneID(for: part) else {
            studio.notice = "There's no scene called “\(part.scene)” in your studio. Choose a scene for “\(part.title)” in the Rundown."
            return
        }
        perform(id)
        current = i
        suggestion = nil
        matcher.consumeAll()
        movePrompter(to: i)
        log("take", ["part": i + 1, "scene": part.scene, "by": who])
    }

    /// ⌃⌥⌘T: the suggested part, or else the next one.
    func takeSuggestionOrNext() {
        if hasTopics { takeBrainSuggestionOrNextTopic(); return }
        if let s = suggestion { take(s.part, by: "you (suggestion)") } else if let n = nextPart { take(n) }
    }

    func skipSuggestion() {
        if let s = suggestion { log("skip", ["part": s.part + 1]) }
        if let b = brainSuggestion { log("skip", ["change": LiveBrain.describe(b.action)]) }
        suggestion = nil; brainSuggestion = nil
    }

    /// ⌃⌥⌘U: back to the scene before the director's last automatic switch; automatic switching pauses for a while.
    func undoAuto() {
        guard let a = lastAuto else { return }
        if a.restoresAsset { setAsset(a.fromAsset) }
        if let from = a.fromScene { perform(from) }
        if a.part >= 0 { current = a.fromPart }
        brain.asset = currentAsset
        brain.look = studio.programScene(.horizontal)?.name ?? brain.look
        brain.pausedUntil = showClock + Self.pauseAfterManual
        lastAuto = nil
        pausedUntil = Date().addingTimeInterval(Self.pauseAfterManual)
        studio.showFlash("Director: switched back")
        log("undo", ["part": a.part + 1])
    }

    func perform(_ sceneID: UUID) {
        deferredWork?.cancel(); deferredWork = nil
        switching = true
        studio.switchTo(sceneID, everyCanvas: true)
        switching = false
    }

    /// Every switch, by anyone. A switch by hand to a coming part's scene moves the rundown there; any other switch
    /// by hand pauses automatic switching.
    func noteSwitch(to sceneID: UUID) {
        lastSwitch = Date()
        guard !switching, show != nil else { return }
        if hasTopics { noteManualSwitchForBrain(to: sceneID); return }
        deferredWork?.cancel(); deferredWork = nil
        suggestion = nil
        matcher.consumeAll()
        let from = (current ?? -1) + 1
        if let i = parts.indices.dropFirst(max(0, from)).prefix(3).first(where: { self.sceneID(for: parts[$0]) == sceneID }) {
            current = i
            log("manual", ["part": i + 1])
        } else if mode == .auto {
            pausedUntil = Date().addingTimeInterval(Self.pauseAfterManual)
            log("manual", ["paused": Self.pauseAfterManual])
        }
    }

    // MARK: Listening

    var canListen: Bool { if #available(macOS 26.0, *) { return ShowListener.isSupported } else { return false } }

    /// Starts following the presenter's voice: the first microphone in the studio (or, for tests, an audio file).
    func startListening(file: URL? = nil) {
        guard !isListening else { if let file { feed(file) }; return }
        guard #available(macOS 26.0, *) else { status = "Following your voice needs macOS 26 or later."; return }
        guard ShowListener.isSupported else { status = "Speech recognition isn't available on this Mac."; return }
        let mics = studio.audioSources.filter { if case .microphone = $0.kind { return true }; return false }
        let mic = mics.first { ($0.audio?.isInProgram ?? true) && !($0.audio?.isMuted ?? false) } ?? mics.first
        guard file != nil || mic != nil else { status = "Add a microphone to the studio first."; return }
        let language = studio.settings.s.listenLanguage ?? .auto
        let l = ShowListener(locale: language.primary)
        listener = l
        l.onResult = { [weak self] text, fin, start, end in self?.hear(text, isFinal: fin, start: start, end: end) }
        l.onStatus = { [weak self] s in self?.status = s }
        // Hinglish: the same microphone also goes to a Hindi recogniser.
        let second = language.secondary.map { ShowListener(locale: $0) }
        secondListener = second
        heardSecond = []
        second?.onResult = { [weak self] text, fin, _, _ in
            guard let self, fin, self.isListening else { return }
            self.heardSecond.append((self.showClock, text))
            self.heardSecond.removeAll { $0.t < self.showClock - LiveBrain.window - 30 }
        }
        second?.onStatus = { [weak self] s in self?.status = s }
        let tap: (UnsafePointer<Float>, Int) -> Void = { [weak l, weak second] samples, frames in
            l?.push(stereo: samples, frames: frames); second?.push(stereo: samples, frames: frames)
        }
        matcher.reset()
        isListening = true
        status = "Starting speech recognition…"
        Task { @MainActor in
            do {
                try await l.start()
                guard self.isListening, self.listener === l else { l.stop(); return }
                if let second {
                    do { try await second.start() } catch {
                        self.secondListener = nil
                        self.status = "Hindi recognition couldn't start (\(error.localizedDescription)); listening in English only."
                    }
                }
                if let file {
                    self.status = "Listening to \(file.lastPathComponent)"
                    l.feed(file: file)
                    (self.secondListener as? ShowListener)?.feed(file: file)
                } else if let mic {
                    self.studio.engine.mixer.setListenTap(mic.id, tap)
                    self.status = "Listening to \(mic.name) in \(language == .auto ? "English" : language.title), on this Mac only"
                }
                self.log("listen", ["source": file?.lastPathComponent ?? mic?.name ?? ""])
                if self.hasTopics {
                    let provider = self.studio.settings.s.aiProvider ?? .claude
                    if AIKeys.has(provider) { self.brainStatus = "Reading your API key (macOS may ask for Keychain access)…" }
                    self.brainKeyCache = AIKeys.has(provider) ? await AIKeys.load(provider) : nil
                    if self.isListening { self.startBrain() }
                }
            } catch {
                self.isListening = false; self.listener = nil
                self.status = error.localizedDescription
            }
        }
    }

    private func feed(_ file: URL) {
        if #available(macOS 26.0, *), let l = listener as? ShowListener { l.feed(file: file) }
    }

    func stopListening() {
        guard isListening else { return }
        if isRehearsing { finishRehearsal() }
        studio.engine.mixer.setListenTap(nil, nil)
        stopBrain()
        if #available(macOS 26.0, *), let l = listener as? ShowListener { l.stop() }
        if #available(macOS 26.0, *), let l = secondListener as? ShowListener { l.stop() }
        listener = nil; secondListener = nil
        isListening = false
        status = ""; heard = ""
        log("listen-stop", [:])
    }

    private func hear(_ text: String, isFinal: Bool, start: Double, end: Double) {
        guard isListening else { return }
        matcher.take(text: text, isFinal: isFinal, start: start, end: end)
        heard = matcher.recent
        if isRehearsing { record(text, isFinal: isFinal, start: start, end: end) }
        if hasTopics { brainHear(text, isFinal: isFinal); return }
        let script = prompterScript
        tracker.update(heard: matcher.tail(10), script: script)
        if tracker.position != scriptPosition { scriptPosition = tracker.position }
        if tracker.onScript != onScript { onScript = tracker.onScript }
        guard show != nil, mode != .off, let hit = matcher.match(upcoming) else { return }
        let part = parts[hit.part]
        guard let id = sceneID(for: part) else {
            suggest(hit, note: "There's no scene called “\(part.scene)” in your studio."); return
        }
        if mode == .suggest { suggest(hit, note: nil); return }
        if let until = pausedUntil, until > Date() { suggest(hit, note: "Automatic switching is paused after your switch."); return }
        autoTimes = autoTimes.filter { $0.timeIntervalSinceNow > -60 }
        if autoTimes.count >= Self.maxAutoPerMinute { suggest(hit, note: "Held: six automatic switches in the last minute."); return }
        let wait = (show?.director.minShotSeconds ?? 3) - Date().timeIntervalSince(lastSwitch)
        if wait > 0 {
            // Too soon after the last switch: switch when the minimum shot is up, unless something changes first.
            let w = DispatchWorkItem { [weak self] in self?.autoSwitch(hit, to: id) }
            deferredWork?.cancel(); deferredWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
            log("hold", ["part": hit.part + 1, "seconds": (wait * 10).rounded() / 10])
        } else {
            autoSwitch(hit, to: id)
        }
    }

    private func autoSwitch(_ hit: CueMatcher.Hit, to id: UUID) {
        let fromScene = studio.programID(.horizontal), fromPart = current
        perform(id)
        current = hit.part
        movePrompter(to: hit.part)
        lastAuto = AutoSwitch(part: hit.part, fromScene: fromScene, fromPart: fromPart, label: parts[hit.part].scene)
        autoTimes.append(Date())
        suggestion = nil
        studio.showFlash("Director: \(parts[hit.part].scene)")
        log("auto", ["part": hit.part + 1, "scene": parts[hit.part].scene, "heard": hit.heard, "how": hit.how])
    }

    private func suggest(_ hit: CueMatcher.Hit, note: String?) {
        suggestion = Suggestion(part: hit.part, heard: hit.heard, how: hit.how, note: note)
        log("suggest", ["part": hit.part + 1, "scene": parts[hit.part].scene, "heard": hit.heard, "how": hit.how, "note": note ?? ""])
        expiryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in if self?.suggestion?.part == hit.part { self?.suggestion = nil } }
        expiryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.suggestionLife, execute: w)
    }

    // MARK: Writing the rundown

    /// Asks the chosen AI service to turn the script into parts and replaces the parts with its answer. The parts it
    /// replaces are kept in the show folder as show-before-ai.json.
    func writeWithAI() {
        guard let show, writing == nil else { return }
        guard studio.settings.s.writeWithAPI ?? false else { writeError = "Write it for me is off (Settings › AI)."; return }
        let provider = studio.settings.s.aiProvider ?? .claude
        guard AIKeys.has(provider) else { writeError = "Add your \(provider.company) API key in Settings › AI first."; return }
        let model = studio.settings.model(for: provider)
        let scenes = studio.scenes.map(\.name)
        writeError = nil
        writing = "Starting…"
        log("write", ["provider": provider.rawValue, "model": model, "characters": show.script.count])
        Task { @MainActor in
            guard let key = await AIKeys.load(provider), !key.isEmpty else {
                self.writing = nil; self.writeError = "Framecast couldn't read your API key from the Keychain."; return
            }
            do {
                let r = try await ScriptWriter.write(script: show.script, title: show.title, scenes: scenes, provider: provider, model: model, key: key) { s in
                    if self.writing != nil { self.writing = s }
                }
                if let folder = self.folder, !self.parts.isEmpty, let d = try? JSONEncoder().encode(self.show) {
                    try? d.write(to: folder.appendingPathComponent("show-before-ai.json"))
                }
                self.edit { s in
                    s.parts = r.parts
                    if !r.aliases.isEmpty { s.aliases = r.aliases }
                    if s.title == "New show" { s.title = r.title }
                }
                self.current = nil
                self.writing = nil
                self.log("written", ["parts": r.parts.count])
            } catch {
                self.writing = nil
                self.writeError = error.localizedDescription
            }
        }
    }

    // MARK: Log

    /// One JSON line per decision in the show folder (logs/director-<date>.jsonl), to see later why it did what it did.
    func log(_ event: String, _ fields: [String: Any]) {
        guard let folder else { return }
        var line = fields
        line["event"] = event
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        line["time"] = iso.string(from: Date())
        line["mode"] = mode.rawValue
        logQueue.async {
            let dir = folder.appendingPathComponent("logs")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let url = dir.appendingPathComponent("director-\(f.string(from: Date())).jsonl")
            guard let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d + Data([0x0A])); try? h.close() }
            else { try? (d + Data([0x0A])).write(to: url) }
        }
    }
}
