import Foundation
import FramecastEngine

/// A rehearsal replayed through the live brain: what it would have done, when, and what it cost.
struct BrainReplayReport: Equatable {
    var file: URL
    var steps: [String]
    var calls: Int
    var cost: Double?
    var topicsReached: Int
    var covered: Int
    var points: Int
    var problem: String?
}

/// Running a topic show: the live brain's loop, putting its changes on air, and the show folder watch.
extension ShowDirector {
    var showClock: Double { Date().timeIntervalSince(showClockStart) }

    // MARK: Show folder

    /// Notices when show.json or the assets folder change on disk (an AI app preparing the show there) and reloads.
    func watchFolder() {
        folderTimer?.invalidate()
        guard let folder else { return }
        folderStamp = Self.stamp(folder)
        folderTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let f = self.folder else { return }
            let now = Self.stamp(f)
            guard now != self.folderStamp else { return }
            self.folderStamp = now
            if let s = try? ShowStore.load(f), s != self.show {
                self.edit { old in
                    old.title = s.title; old.brief = s.brief; old.topics = s.topics; old.assets = s.assets
                    old.script = s.script; old.parts = s.parts; old.aliases = s.aliases
                }
                self.brainPrompt = nil
                self.log("reloaded", ["topics": s.topics.count, "assets": s.assets.count])
            }
            self.describeNewAssets()
        }
    }

    /// Files in assets/ that show.json doesn't describe yet are listed by name (the brain sees them too).
    func describeNewAssets() {
        guard let folder, let show else { return }
        let files = ShowStore.assetFiles(in: folder)
        let known = Set(show.assets.map(\.file))
        let new = files.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        edit { s in s.assets += new.map { ShowAsset(file: $0, about: ($0 as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")) } }
        brainPrompt = nil
    }

    static func stamp(_ folder: URL) -> String {
        let fm = FileManager.default
        func m(_ u: URL) -> String { ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970).map { "\($0)" } ?? "-" }
        let assets = folder.appendingPathComponent("assets")
        let names = ((try? fm.contentsOfDirectory(atPath: assets.path)) ?? []).sorted()
        return m(folder.appendingPathComponent("show.json")) + "|" + names.map { $0 + m(assets.appendingPathComponent($0)) }.joined(separator: ",")
    }

    // MARK: Asset on air

    /// Which asset the asset looks show (nil: none).
    func setAsset(_ file: String?) {
        currentAsset = file
        assetSourceID = file.flatMap { f in folder.flatMap { Looks.source(for: f, in: $0, studio: studio) } }
    }

    func assetExists(_ file: String) -> Bool {
        guard !file.isEmpty, let folder else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("assets").appendingPathComponent(file).path)
    }

    // MARK: The loop

    var brainKey: String? { brainKeyCache.flatMap { $0.isEmpty ? nil : $0 } }

    func startBrain() {
        assetSlotID = Looks.ensure(studio)
        describeNewAssets()
        showClockStart = Date()
        brain = BrainState(topic: topicIndex ?? 0, covered: covered, look: studio.programScene(.horizontal)?.name ?? "", asset: currentAsset)
        topicIndex = brain.topic
        heardFinals = []; heardGuess = ""; brainChanges = []; brainFailures = 0
        brainStatus = brainKey == nil ? "No API key: following the outline on this Mac only (Settings › AI to add one)" : "Live brain on"
        brainTimer?.invalidate()
        brainTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.brainTick() }
        log("brain-start", ["topics": topics.count, "assets": show?.assets.count ?? 0])
    }

    func stopBrain() {
        brainTimer?.invalidate(); brainTimer = nil
    }

    func brainHear(_ text: String, isFinal: Bool) {
        if isFinal {
            heardFinals.append((showClock, text)); heardGuess = ""
            heardFinals.removeAll { $0.t < showClock - LiveBrain.window - 30 }
            if !brainUsable, let show {
                LiveBrain.followLocally(text, state: &brain, show: show)
                syncFromBrain()
            }
        } else {
            heardGuess = text
        }
        heardSinceCall = true
    }

    var brainUsable: Bool { mode != .off && brainKey != nil && (brainFailures < 3 || Date().timeIntervalSince(brainLastCall) > 30) }

    func brainTick() {
        if let s = brainSuggestion, Date().timeIntervalSince(s.at) > Self.suggestionLife { brainSuggestion = nil }
        guard isListening, hasTopics, brainUsable, heardSinceCall, !brainInFlight,
              Date().timeIntervalSince(brainLastCall) >= LiveBrain.interval, let show, let key = brainKey else { return }
        let provider = studio.settings.s.aiProvider ?? .claude
        let model = studio.settings.brainModel(for: provider)
        let looks = Looks.catalog(studio)
        let cacheKey = "\(show.topics)|\(show.assets)|\(looks.map(\.name))"
        if brainPrompt?.key != cacheKey {
            brainPrompt = (cacheKey, LiveBrain.system(show: show, looks: looks), LiveBrain.schema(show: show, looks: looks))
        }
        guard let p = brainPrompt else { return }
        brain.look = studio.programScene(.horizontal)?.name ?? brain.look
        let now = showClock
        let user = LiveBrain.user(state: brain, now: now, show: show, heard: heardFinals, guess: heardGuess, changes: brainChanges, hindi: heardSecond)
        brainInFlight = true; heardSinceCall = false; brainLastCall = Date()
        Task { @MainActor in
            do {
                let a = try await LiveBrain.ask(provider: provider, model: model, key: key, system: p.system, user: user, schema: p.schema)
                self.brainInFlight = false
                self.brainFailures = 0
                self.brainCalls += 1
                if let c = a.cost { self.brainCost += c }
                self.brainStatus = "Live brain on · \(String(format: "%.1f", a.seconds)) s per decision"
                self.applyBrain(a.decision, latency: a.seconds)
            } catch {
                self.brainInFlight = false
                self.brainFailures += 1
                self.brainStatus = self.brainFailures >= 3
                    ? "Live brain offline (\(error.localizedDescription)). Following on this Mac; visuals paused."
                    : "Live brain: \(error.localizedDescription)"
            }
        }
    }

    /// Holds that only need a few more seconds: the change is tried again when the hold is up, unless a newer
    /// decision comes first.
    static let shortHolds: Set<String> = ["the asset on screen is new", "too soon after the last switch", "the look on air is new"]

    func applyBrain(_ d: BrainDecision, latency: Double, retry: Int = 0) {
        guard let show else { return }
        if retry == 0 { brainRetry?.cancel(); brainRetry = nil }
        brain.look = studio.programScene(.horizontal)?.name ?? brain.look
        let looks = Looks.catalog(studio)
        let now = showClock
        var (action, held) = LiveBrain.plan(d, state: &brain, now: now, show: show, looks: looks, settings: show.director, assetExists: assetExists)
        if latency > 8, action != nil { action = nil; held = "answer came too late" }
        syncFromBrain()
        let clock = Studio.chapterTime(now)
        lastDecision = "\(clock) \(d.action == "hold" ? "hold" : action.map(LiveBrain.describe) ?? d.action)\(held.map { " (held: \($0))" } ?? "") · \(d.reason)"
        log("brain", ["topic": d.topic, "covered": d.covered, "action": d.action, "look": d.look, "asset": d.asset, "reason": d.reason,
                      "confidence": d.confidence, "applied": action.map(LiveBrain.describe) ?? "", "held": held ?? "", "seconds": (latency * 10).rounded() / 10])
        if action == nil, let held, Self.shortHolds.contains(held), retry < 4, mode != .off {
            let w = DispatchWorkItem { [weak self] in self?.applyBrain(d, latency: 0, retry: retry + 1) }
            brainRetry = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        }
        guard let action else { return }
        switch mode {
        case .auto: execute(action)
        case .suggest: brainSuggestion = BrainSuggestion(action: action, reason: d.reason)
        case .off: break
        }
    }

    /// Puts an allowed change on air and remembers how to undo it.
    func execute(_ a: BrainAction, by who: String = "brain") {
        guard let scene = studio.scenes.first(where: { $0.name == a.look }) else { return }
        lastAuto = AutoSwitch(part: -1, fromScene: studio.programID(.horizontal), fromPart: nil, label: LiveBrain.describe(a),
                              fromAsset: currentAsset, restoresAsset: true)
        switch a {
        case .asset(let f, _): setAsset(f)
        case .look(let l): if !Looks.assetLooks.contains(l) { setAsset(nil) }
        }
        perform(scene.id)
        LiveBrain.commit(a, state: &brain, now: showClock, looks: Looks.catalog(studio))
        brainChanges.append((showClock, LiveBrain.describe(a)))
        brainSuggestion = nil
        studio.showFlash("Director: \(LiveBrain.describe(a))")
        log("change", ["what": LiveBrain.describe(a), "by": who])
    }

    func syncFromBrain() {
        if topicIndex != brain.topic { topicIndex = brain.topic; log("topic", ["topic": (brain.topic ?? 0) + 1]) }
        if covered != brain.covered { covered = brain.covered }
    }

    /// A switch by hand during a topic show pauses the brain's changes for a while (Auto) and tells it what's on air.
    func noteManualSwitchForBrain(to sceneID: UUID) {
        let name = studio.scenes.first { $0.id == sceneID }?.name ?? ""
        if !Looks.assetLooks.contains(name) { setAsset(nil) }
        brain.look = name; brain.asset = currentAsset
        brain.lastSwitch = showClock; brain.lastLookChange = showClock
        brainSuggestion = nil
        brainRetry?.cancel(); brainRetry = nil
        if mode == .auto, isListening { brain.pausedUntil = showClock + Self.pauseAfterManual; pausedUntil = Date().addingTimeInterval(Self.pauseAfterManual) }
        log("manual", ["scene": name])
    }

    /// ⌃⌥⌘T in a topic show: take the brain's suggestion, or else move the outline to the next topic (and its look).
    func takeBrainSuggestionOrNextTopic() {
        if let s = brainSuggestion { execute(s.action, by: "you (suggestion)"); return }
        let next = (topicIndex ?? -1) + 1
        guard topics.indices.contains(next) else { return }
        brain.topic = next; syncFromBrain()
        if let look = studio.scenes.first(where: { $0.name == topics[next].look }), look.name != studio.programScene(.horizontal)?.name {
            execute(.look(look.name), by: "you (next topic)")
        }
    }

    /// Moves the outline to a topic (from the panel or the presenter view).
    func goToTopic(_ i: Int) {
        guard topics.indices.contains(i) else { return }
        brain.topic = i; syncFromBrain()
    }

    // MARK: Rehearsal through the brain

    /// Replays a recorded rehearsal through the live brain with today's outline and assets: one model call per 6 s
    /// of speech, the same guards, nothing put on air. Uses the API key (a few cents).
    func replayBrain(_ url: URL) {
        guard let show else { return }
        let provider = studio.settings.s.aiProvider ?? .claude
        guard AIKeys.has(provider) else {
            brainReport = BrainReplayReport(file: url, steps: [], calls: 0, cost: nil, topicsReached: 0, covered: 0, points: 0,
                                            problem: "Add an API key in Settings › AI to replay through the live brain.")
            return
        }
        let model = studio.settings.brainModel(for: provider)
        let looks = Looks.catalog(studio)
        let start = studio.programScene(.horizontal)?.name ?? ""
        let exists: (String) -> Bool = { [weak self] f in self?.assetExists(f) ?? false }
        isReplaying = true
        Task { @MainActor in
            guard let key = await AIKeys.load(provider) else { self.isReplaying = false; return }
            let lines = RehearsalReplay.load(url)
            var s = BrainState(topic: 0, look: start)
            var steps: [String] = [], calls = 0, cost: Double? = 0, changes: [(t: Double, text: String)] = [], problem: String?
            let system = LiveBrain.system(show: show, looks: looks), schema = LiveBrain.schema(show: show, looks: looks)
            let end = lines.last?.t ?? 0
            var now = LiveBrain.interval, lastHeard = -1.0, lastCall = -1e9
            var pending: (decision: BrainDecision, tries: Int)?
            // Steps of 2 s: a call at most every 6 s while there's new speech, and briefly held changes retried
            // when the hold is up, as in a live show.
            while now <= end + LiveBrain.interval {
                if let p = pending {
                    pending = nil
                    let (action, held) = LiveBrain.plan(p.decision, state: &s, now: now, show: show, looks: looks, settings: show.director, assetExists: exists)
                    if let action {
                        LiveBrain.commit(action, state: &s, now: now, looks: looks)
                        changes.append((now, LiveBrain.describe(action)))
                        steps.append("\(Studio.chapterTime(now)) \(LiveBrain.describe(action)) · \(p.decision.reason) (after waiting)")
                    } else if let held, Self.shortHolds.contains(held), p.tries < 4 { pending = (p.decision, p.tries + 1) }
                }
                let finals = lines.filter { $0.final && $0.t <= now }.map { (t: $0.t, text: $0.text) }
                let guess = lines.last { !$0.final && $0.t <= now && $0.t > (finals.last?.t ?? -1) }?.text ?? ""
                let newest = lines.last { $0.t <= now }?.t ?? -1
                if newest > lastHeard, now - lastCall >= LiveBrain.interval {
                    lastHeard = newest; lastCall = now; pending = nil
                    let user = LiveBrain.user(state: s, now: now, show: show, heard: finals, guess: guess, changes: changes)
                    do {
                        let a = try await LiveBrain.ask(provider: provider, model: model, key: key, system: system, user: user, schema: schema)
                        calls += 1
                        cost = a.cost.flatMap { c in cost.map { $0 + c } }
                        let (action, held) = LiveBrain.plan(a.decision, state: &s, now: now, show: show, looks: looks, settings: show.director, assetExists: exists)
                        if let action {
                            LiveBrain.commit(action, state: &s, now: now, looks: looks)
                            changes.append((now, LiveBrain.describe(action)))
                            steps.append("\(Studio.chapterTime(now)) \(LiveBrain.describe(action)) · \(a.decision.reason)")
                        } else if let held {
                            steps.append("\(Studio.chapterTime(now)) held \(a.decision.action) (\(held))")
                            if Self.shortHolds.contains(held) { pending = (a.decision, 1) }
                        }
                    } catch {
                        problem = error.localizedDescription; break
                    }
                }
                now += 2
            }
            let points = show.topics.reduce(0) { $0 + $1.points.count }
            self.brainReport = BrainReplayReport(file: url, steps: steps, calls: calls, cost: cost, topicsReached: (s.topic ?? 0) + 1,
                                                 covered: s.covered.count, points: points, problem: problem)
            self.isReplaying = false
            self.log("brain-replay", ["file": url.lastPathComponent, "calls": calls, "changes": changes.count])
        }
    }

    // MARK: Outline from Claude (control link)

    func setOutline(title: String?, brief: String?, topics: [ShowTopic], assets: [ShowAsset]) {
        if show == nil { newShow(title: title ?? "New show") }
        edit { s in
            s.topics = topics
            if let title, !title.isEmpty { s.title = title }
            if let brief, !brief.isEmpty { s.brief = brief }
            for a in assets { if let i = s.assets.firstIndex(where: { $0.file == a.file }) { s.assets[i] = a } else { s.assets.append(a) } }
        }
        topicIndex = nil; covered = []; brain = BrainState()
        brainPrompt = nil
        describeNewAssets()
    }

    func describeAsset(_ file: String, _ about: String) {
        edit { s in if let i = s.assets.firstIndex(where: { $0.file == file }) { s.assets[i].about = about } else { s.assets.append(ShowAsset(file: file, about: about)) } }
        brainPrompt = nil
    }
}
