import Foundation
import NaturalLanguage

/// What a rehearsal replay found: which parts' cues were caught and when, which were missed (with the closest
/// thing that was said, so it can be added as another way of saying the cue), and words speech recognition
/// seems to mishear (to add as aliases).
struct RehearsalReport: Equatable {
    struct Fire: Equatable { var part: Int; var t: Double; var heard: String; var how: String }
    struct Miss: Equatable { var part: Int; var closest: String? }
    struct Mishearing: Equatable, Hashable { var heard: String; var meant: String; var count: Int }
    var file: URL
    var duration: Double
    var words: Int
    var fires: [Fire]
    var misses: [Miss]
    var mishearings: [Mishearing]
    var cues: Int { fires.count + misses.count }
}

/// One recorded transcription result (the same JSON lines the experiments use: t, start, end, final, text).
struct HeardLine: Codable { var t: Double; var start: Double; var end: Double; var final: Bool; var text: String }

enum RehearsalReplay {
    static func load(_ url: URL) -> [HeardLine] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(HeardLine.self, from: Data($0.utf8)) }
    }

    /// Plays the recorded speech through the same matching the director uses, moving on to each part as its cue
    /// is caught (as Auto would), with today's cues and aliases.
    static func run(_ lines: [HeardLine], show: ShowRundown, file: URL) -> RehearsalReport {
        let m = CueMatcher()
        m.aliases = Dictionary(show.aliases.map { (m.norm($0.heard), $0.meant.lowercased()) }, uniquingKeysWith: { a, _ in a })
        var current: Int?, fires: [RehearsalReport.Fire] = []
        for l in lines {
            m.take(text: l.text, isFinal: l.final, start: l.start, end: l.end)
            if let hit = m.match(ShowDirector.upcoming(show.parts, after: current)) {
                fires.append(.init(part: hit.part, t: l.t, heard: hit.heard, how: hit.how))
                current = hit.part
            }
        }
        // Settled sentences with the time they were heard, for finding what was said instead of a missed cue.
        var sentences: [(t: Double, text: String)] = []
        for l in lines where l.final { for s in PrompterScript.sentences(l.text) where !s.isEmpty { sentences.append((l.t, s)) } }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        let caught = Set(fires.map(\.part))
        var misses: [RehearsalReport.Miss] = []
        for (i, p) in show.parts.enumerated() where i > 0 && !caught.contains(i) {
            let says = ([p.cue] + p.alsoAccept).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !says.isEmpty else { continue }
            // Between the cue caught before this part and the one caught after it, leaving out the sentences that
            // caught other cues. Closeness: sentence meaning, helped by shared words ("benchmark").
            let from = fires.last { $0.part < i }?.t ?? 0, to = fires.first { $0.part > i }?.t ?? .infinity
            let used = Set(fires.map(\.heard))
            let sayWords = Set(says.flatMap { m.words($0) }.filter { $0.count >= 4 })
            var best: (String, Double)?
            for s in sentences where s.t >= from - 1 && s.t < to {
                let w = m.words(s.text)
                guard !used.contains(where: { $0.hasSuffix(w.joined(separator: " ")) }) else { continue }
                let d = says.map { say in embedding?.distance(between: s.text, and: say, distanceType: .cosine) ?? 2 }.min() ?? 2
                let score = d - 0.15 * Double(Set(w).intersection(sayWords).count)
                if score < (best?.1 ?? 1.15) { best = (s.text, score) }
            }
            misses.append(.init(part: i, closest: best?.0))
        }
        let heardWords = lines.filter(\.final).flatMap { m.words($0.text) }
        return RehearsalReport(file: file, duration: lines.last?.t ?? 0, words: heardWords.count, fires: fires, misses: misses,
                               mishearings: mishearings(lines, show: show, matcher: m))
    }

    /// Words heard in the script's place but spelled differently, with the same first letter and a similar
    /// spelling ("opa" where the script says "opus"): likely mishearings, most frequent first. Each settled line is
    /// lined up with the script (local alignment); only lines that clearly follow the script count, so ad-libs
    /// don't produce suggestions.
    static func mishearings(_ lines: [HeardLine], show: ShowRundown, matcher m: CueMatcher) -> [RehearsalReport.Mishearing] {
        let script = PrompterScript(show: show, norm: m.norm).norms
        guard !script.isEmpty else { return [] }
        let known = Set(show.aliases.map { $0.heard.lowercased() })
        var counts: [String: (meant: String, n: Int)] = [:]
        for l in lines where l.final {
            let h = m.words(l.text)
            guard h.count >= 3 else { continue }
            var dp = [[Int]](repeating: [Int](repeating: 0, count: script.count + 1), count: h.count + 1)
            var best = (score: 0, i: 0, j: 0)
            for i in 1...h.count {
                for j in 1...script.count {
                    let same = CueMatcher.same(h[i - 1], script[j - 1])
                    dp[i][j] = max(0, dp[i - 1][j - 1] + (same ? 2 : -1), dp[i - 1][j] - 1, dp[i][j - 1] - 1)
                    if dp[i][j] > best.score { best = (dp[i][j], i, j) }
                }
            }
            guard best.score >= 6 else { continue }
            var i = best.i, j = best.j
            while i > 0, j > 0, dp[i][j] > 0 {
                let a = h[i - 1], b = script[j - 1], same = CueMatcher.same(a, b)
                if dp[i][j] == dp[i - 1][j - 1] + (same ? 2 : -1) {
                    if !same, a.count >= 2, b.count >= 4, a.allSatisfy(\.isLetter), b.allSatisfy(\.isLetter), a.first == b.first,
                       CueMatcher.similarity(a, b) >= 0.4, !known.contains(a) {
                        counts["\(a)|\(b)", default: (b, 0)].n += 1
                    }
                    i -= 1; j -= 1
                } else if dp[i][j] == dp[i - 1][j] - 1 { i -= 1 } else { j -= 1 }
            }
        }
        return counts.map { RehearsalReport.Mishearing(heard: String($0.key.split(separator: "|")[0]), meant: $0.value.meant, count: $0.value.n) }
            .sorted { ($0.count, $0.heard) > ($1.count, $1.heard) }.prefix(6).map { $0 }
    }
}

/// Rehearsing: listen as in a show while recording what was heard, then replay it.
extension ShowDirector {
    var rehearsalsDir: URL? { folder?.appendingPathComponent("rehearsals") }

    /// Earlier rehearsals of this show, newest first.
    var rehearsals: [URL] {
        guard let dir = rehearsalsDir else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Starts a rehearsal: listening (to the microphone, or for tests an audio file) with what's heard recorded.
    func startRehearsal(file: URL? = nil) {
        guard let dir = rehearsalsDir, !isRehearsing else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("\(f.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        rehearsalFile = try? FileHandle(forWritingTo: url)
        rehearsalURL = url
        isRehearsing = true
        rehearsalStart = Date()
        report = nil
        log("rehearse", ["file": url.lastPathComponent])
        if !isListening { startListening(file: file) } else if let file { startListening(file: file) }
    }

    func stopRehearsal() {
        guard isRehearsing else { return }
        stopListening()       // finishes the rehearsal too
    }

    /// Called when listening stops during a rehearsal.
    func finishRehearsal() {
        isRehearsing = false
        try? rehearsalFile?.close(); rehearsalFile = nil
        if let url = rehearsalURL { hasTopics ? replayBrain(url) : replay(url) }
    }

    func record(_ text: String, isFinal: Bool, start: Double, end: Double) {
        let line = HeardLine(t: Date().timeIntervalSince(rehearsalStart ?? Date()), start: start, end: end, final: isFinal, text: text)
        if let d = try? JSONEncoder().encode(line) { rehearsalFile?.write(d + Data([0x0A])) }
    }

    /// Replays a recorded rehearsal against the rundown as it is now (after edits, replay again to check them).
    func replay(_ url: URL) {
        guard let show else { return }
        isReplaying = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = RehearsalReplay.run(RehearsalReplay.load(url), show: show, file: url)
            DispatchQueue.main.async {
                self.report = r; self.isReplaying = false
                self.log("replay", ["file": url.lastPathComponent, "caught": r.fires.count, "cues": r.cues])
            }
        }
    }

    /// A transcript recorded elsewhere (for example by the experiments) becomes a rehearsal of this show.
    func importRehearsal(_ source: URL) {
        guard let dir = rehearsalsDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (imported).jsonl")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
        hasTopics ? replayBrain(dest) : replay(dest)
    }

    /// Adds what was said as another way of saying a part's cue, then replays.
    func acceptAlternative(part: Int, _ text: String) {
        let clean = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " }.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        edit { s in if s.parts.indices.contains(part), !s.parts[part].alsoAccept.contains(clean) { s.parts[part].alsoAccept.append(clean) } }
        log("accept", ["part": part + 1, "text": clean])
        if let url = report?.file { replay(url) }
    }

    func acceptAlias(_ a: RehearsalReport.Mishearing) {
        edit { s in if !s.aliases.contains(where: { $0.heard == a.heard }) { s.aliases.append(WordAlias(heard: a.heard, meant: a.meant)) } }
        log("alias", ["heard": a.heard, "meant": a.meant])
        if let url = report?.file { replay(url) }
    }
}
