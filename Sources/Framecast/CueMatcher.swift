import Foundation
import NaturalLanguage

/// Follows what the presenter says (live transcription results) and spots the rundown's cue lines in it.
/// Two ways to match, both on this Mac:
///  • words: the cue's words in order, allowing small misspellings and the show's alias list; fires as soon as the
///    cue's last word is heard (about 0.6–0.8 s after it is said);
///  • meaning: Apple's on-device sentence embedding compares each finished sentence with the cue and its other
///    wordings, for when the presenter says it differently.
/// Text that already triggered a cue can't trigger another one.
final class CueMatcher {
    struct Hit: Equatable { var part: Int; var heard: String; var how: String }

    /// Cosine distance at or under which a finished sentence counts as the cue (0 = same meaning, 2 = opposite).
    static let meaningThreshold = 0.85
    static let wordShare = 0.75

    var aliases: [String: String] = [:]
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    // Settled words, then the recognizer's current guess for the stretch after them. `dropped` counts settled words
    // trimmed off the front, so word positions stay absolute.
    private var settled: [String] = [], rawSettled: [String] = []
    private var guess: [String] = [], rawGuess: [String] = []
    private var guessStart = 0.0, settledEnd = 0.0
    private var dropped = 0
    private var consumed = 0
    private var scoredSentences = Set<String>()

    /// The last words heard, for showing on screen.
    var recent: String { (rawSettled + rawGuess).suffix(14).joined(separator: " ") }
    /// The last `n` words heard, normalised (for finding the place in the script).
    func tail(_ n: Int) -> [String] { Array((settled + guess).suffix(n)) }

    func reset() {
        settled = []; rawSettled = []; guess = []; rawGuess = []
        guessStart = 0; settledEnd = 0; dropped = 0; consumed = 0; scoredSentences = []
    }

    /// Text can't trigger a cue any more (after a switch by hand, so a cue said just before doesn't fire late).
    func consumeAll() { consumed = dropped + settled.count + guess.count }

    /// Takes one transcription result: `start`/`end` are its place on the audio timeline.
    func take(text: String, isFinal: Bool, start: Double, end: Double) {
        let raw = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !norm($0).isEmpty }
        if isFinal {
            settled += raw.map(norm); rawSettled += raw
            settledEnd = end
            if guessStart <= start + 0.05 { guess = []; rawGuess = [] }
            if settled.count > 400 {                       // keep the last few minutes of speech
                let n = settled.count - 300
                settled.removeFirst(n); rawSettled.removeFirst(n); dropped += n
            }
        } else if start >= settledEnd - 0.05 {
            guess = raw.map(norm); rawGuess = raw; guessStart = start
        }
    }

    /// Looks for the cue of one of `candidates` (rundown positions, earliest first) in what was heard.
    func match(_ candidates: [(index: Int, part: RundownPart)]) -> Hit? {
        let hyp = settled + guess
        let base = dropped
        // Words: the cue's words in order, ending on its last word, in the last few words not used yet.
        for c in candidates {
            for say in [c.part.cue] + c.part.alsoAccept {
                let phrase = words(say)
                guard !phrase.isEmpty else { continue }
                let lo = max(consumed - base, hyp.count - phrase.count - 4, 0)
                guard lo < hyp.count else { continue }
                let window = Array(hyp[lo...])
                if let (share, end) = Self.inOrder(phrase, window), share >= Self.wordShare {
                    consumed = base + lo + end + 1
                    return Hit(part: c.index, heard: window[...end].joined(separator: " "), how: "words")
                }
            }
        }
        // Meaning: every finished sentence once, against each cue and its other wordings.
        guard let embedding else { return nil }
        let raw = rawSettled + rawGuess
        var sentence: [String] = [], firstIndex = 0
        for (i, w) in hyp.enumerated() {
            if sentence.isEmpty { firstIndex = i }
            sentence.append(w)
            guard let r = raw.indices.contains(i) ? raw[i] : nil, r.hasSuffix(".") || r.hasSuffix("?") || r.hasSuffix("!") else { continue }
            defer { sentence = [] }
            let text = sentence.joined(separator: " ")
            guard base + i >= consumed, base + firstIndex >= consumed - 2,
                  scoredSentences.insert("\(base + i)|\(text)").inserted else { continue }
            var best: (Int, Double)?
            for c in candidates {
                let says = ([c.part.cue] + c.part.alsoAccept).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard let d = says.map({ embedding.distance(between: text, and: $0, distanceType: .cosine) }).min() else { continue }
                if d <= Self.meaningThreshold && d < (best?.1 ?? .infinity) { best = (c.index, d) }
            }
            if let best {
                consumed = base + i + 1
                return Hit(part: best.0, heard: text, how: String(format: "meaning %.2f", best.1))
            }
        }
        return nil
    }

    func norm(_ w: String) -> String {
        let s = w.lowercased().replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "." }
            .trimmingCharacters(in: CharacterSet(charactersIn: ".'"))
        return aliases[s] ?? s
    }
    func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map { norm(String($0)) }.filter { !$0.isEmpty } }

    /// In-order fuzzy match of `phrase` in `window`: the share of the phrase's words found, counting only matches up
    /// to the phrase's last word (which must be there), and that last word's position in the window.
    static func inOrder(_ phrase: [String], _ window: [String]) -> (Double, Int)? {
        guard let last = phrase.last, let j = window.indices.last(where: { same(last, window[$0]) }) else { return nil }
        let head = Array(phrase.dropLast()), before = Array(window[..<j])
        var dp = [Int](repeating: 0, count: before.count + 1)
        for p in head {
            var prev = 0
            for k in before.indices {
                let cur = dp[k + 1]
                dp[k + 1] = same(p, before[k]) ? prev + 1 : max(dp[k + 1], dp[k])
                prev = cur
            }
        }
        return (Double((dp.last ?? 0) + 1) / Double(phrase.count), j)
    }

    static func same(_ a: String, _ b: String) -> Bool { a == b || (min(a.count, b.count) >= 4 && similarity(a, b) >= 0.75) }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return x == y ? 1 : 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
