import Foundation

/// The show's words laid out for the prompter: one section per rundown part (its script text), or the whole script
/// when the parts have no text, split into sentences.
struct PrompterScript: Equatable {
    struct Sentence: Identifiable, Equatable { let id: Int; let words: Range<Int> }
    struct Section: Identifiable, Equatable { let id: Int; let part: Int?; let sentences: [Sentence] }
    var words: [String] = []
    var norms: [String] = []
    var sections: [Section] = []
    /// Words that are a part's cue line (shown in the accent colour).
    var cueWords: Set<Int> = []
    /// First word of each part's text.
    var partStart: [Int: Int] = [:]

    init() {}
    init(show: ShowRundown?, norm: (String) -> String) {
        guard let show else { return }
        let byParts = show.parts.contains { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let chunks: [(Int?, String)] = byParts ? show.parts.enumerated().map { ($0.offset, $0.element.notes) }
                                               : show.script.components(separatedBy: "\n\n").map { (nil, $0) }
        var sid = 0
        for (k, chunk) in chunks.enumerated() {
            let start = words.count
            var sentences: [Sentence] = []
            for text in Self.sentences(chunk.1) {
                let ws = text.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !ws.isEmpty else { continue }
                sentences.append(Sentence(id: sid, words: words.count..<(words.count + ws.count))); sid += 1
                words += ws; norms += ws.map(norm)
            }
            if let p = chunk.0 {
                partStart[p] = start
                let cue = show.parts[p].cue.split(whereSeparator: \.isWhitespace).map { norm(String($0)) }.filter { !$0.isEmpty }
                if !cue.isEmpty, words.count - start >= cue.count,
                   let at = (start...(words.count - cue.count)).first(where: { Array(norms[$0..<($0 + cue.count)]) == cue }) {
                    cueWords.formUnion(at..<(at + cue.count))
                }
            }
            if chunk.0 != nil || !sentences.isEmpty { sections.append(Section(id: k, part: chunk.0, sentences: sentences)) }
        }
    }

    /// Sentences, keeping their punctuation; a line break also ends one.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c == "\n" { if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }; cur = ""; continue }
            cur.append(c)
            if ".?!".contains(c), i + 1 == chars.count || chars[i + 1].isWhitespace {
                out.append(cur); cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The sentence holding word `i`.
    func sentence(containing i: Int) -> Sentence? {
        for s in sections { for x in s.sentences where x.words.contains(i) { return x } }
        return nil
    }
}

/// Where the presenter is in the script. The last words heard are aligned with the script near the current place
/// (local alignment, allowing skipped and extra words). Moving up to 80 words ahead needs three matching words;
/// moving back or further ahead needs five; after 8 s with no match the whole script is searched.
final class ScriptTracker {
    /// Last script word matched (-1 before the first).
    private(set) var position = -1
    private(set) var lastMatch = Date.distantPast
    var onScript: Bool { Date().timeIntervalSince(lastMatch) < 8 }

    func reset() { position = -1; lastMatch = .distantPast }
    /// Moves to just before word `i` (when a part is taken, its text is next).
    func jump(to i: Int) { position = i - 1 }

    func update(heard h: [String], script s: PrompterScript) {
        guard !h.isEmpty, !s.norms.isEmpty else { return }
        let lost = !onScript
        let lo = lost ? 0 : max(0, position - 8), hi = lost ? s.norms.count : min(s.norms.count, position + 80)
        guard lo < hi else { return }
        let w = Array(s.norms[lo..<hi])
        var best = (score: 0, j: 0)
        var prev = [Int](repeating: 0, count: w.count + 1)
        for i in 1...h.count {
            var cur = [Int](repeating: 0, count: w.count + 1)
            for j in 1...w.count {
                let same = CueMatcher.same(h[i - 1], w[j - 1])
                cur[j] = max(0, prev[j - 1] + (same ? 2 : -1), prev[j] - 1, cur[j - 1] - 1)
                // Only alignments that end on one of the last two words heard tell where the presenter is now.
                if same, i >= h.count - 1, cur[j] > best.score { best = (cur[j], j) }
            }
            prev = cur
        }
        let at = lo + best.j - 1
        if best.score >= 10 || (best.score >= 6 && at >= position - 2 && at <= position + 80) {
            position = at
            lastMatch = Date()
        }
    }
}
