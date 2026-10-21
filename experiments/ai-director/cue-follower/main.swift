// Script cue follower: the no-AI live layer of the director. Reads live transcription results (JSON lines from
// `stt-latency --jsonl`, piped live or replayed from a file), matches them against the cue list, and fires scene
// switches with a minimum-shot guard. Two matchers:
//   lexical   in-order fuzzy word match (edit distance + alias table); fires the moment the cue's last word shows up
//   semantic  (--semantic) Apple's on-device sentence embedding on each finished sentence, for paraphrased cues
//
//   swiftc -O main.swift -o cue-follower
//   ./cue-follower cues.json [--expect talk.expect.json] [--semantic] [--fcctl path/to/fcctl] < run.jsonl
import Foundation
import NaturalLanguage

struct Cue { let id: String, says: [String], phrases: [[String]], scene: String }   // says[0] is the script line
struct Word { let text: String, start: Double, end: Double }
struct Fire { let cue: String, t: Double, how: String, heard: String }

let args = CommandLine.arguments
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
guard args.count >= 2, let cueData = FileManager.default.contents(atPath: args[1]),
      let cueFile = try? JSONSerialization.jsonObject(with: cueData) as? [String: Any] else {
    print("usage: cue-follower cues.json [--expect file] [--semantic] [--fcctl path] < transcript.jsonl"); exit(2)
}
let aliases = cueFile["aliases"] as? [String: String] ?? [:]
let minShot = cueFile["minShotSeconds"] as? Double ?? 3
let semanticThreshold = Double(option("--threshold") ?? "") ?? 0.85
let fcctl = option("--fcctl")
let embedding = args.contains("--semantic") ? NLEmbedding.sentenceEmbedding(for: .english) : nil
if args.contains("--semantic") && embedding == nil { print("no on-device sentence embedding for English"); exit(1) }

func norm(_ w: Substring) -> String {
    let s = w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "." }
        .trimmingCharacters(in: CharacterSet(charactersIn: ".'"))
    return aliases[s] ?? s
}
func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(norm).filter { !$0.isEmpty } }

let cues: [Cue] = (cueFile["cues"] as? [[String: Any]] ?? []).map {
    let says = [$0["say"] as! String] + ($0["alsoAccept"] as? [String] ?? [])   // alsoAccept: other ways to say it
    return Cue(id: $0["id"] as! String, says: says, phrases: says.map(words), scene: $0["scene"] as! String)
}

func editRatio(_ a: String, _ b: String) -> Double {
    let x = Array(a), y = Array(b)
    if x.isEmpty || y.isEmpty { return x == y ? 1 : 0 }
    var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
        swap(&prev, &cur)
    }
    return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
}
func same(_ a: String, _ b: String) -> Bool { a == b || (min(a.count, b.count) >= 4 && editRatio(a, b) >= 0.75) }

/// In-order fuzzy match of the cue phrase against the window. Returns the share of phrase words matched and the
/// window index of the matched last phrase word (nil when the last word, the trigger, is not there yet).
func lexical(_ phrase: [String], _ window: [String]) -> (Double, Int?) {
    var dp = [[Int]](repeating: [Int](repeating: 0, count: window.count + 1), count: phrase.count + 1)
    for i in 1...phrase.count { for j in stride(from: 1, through: window.count, by: 1) {
        dp[i][j] = same(phrase[i - 1], window[j - 1]) ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1])
    } }
    guard let j = window.indices.last(where: { same(phrase.last!, window[$0]) }) else { return (0, nil) }
    let upToTrigger = j == 0 ? 0 : dp[phrase.count - 1][j]
    return (Double(upToTrigger + 1) / Double(phrase.count), j)
}

// Live state: settled words, the latest guess for the still-open stretch, what has already triggered a cue.
var settled: [String] = [], settledTimes: [Word] = []
var guess: [String] = [], guessStart = 0.0, settledEnd = 0.0
var consumed = 0                      // hypothesis words before this index can no longer trigger anything
var fired: [Fire] = [], lastFire = -Double.infinity
var sentencesChecked = Set<String>()   // "end index|sentence" already scored
var rawSettled: [String] = [], rawGuess: [String] = []   // the same words with punctuation, for sentence ends
let debug = args.contains("--debug")
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

func fire(_ cue: Cue, at t: Double, how: String, heard: String) {
    fired.append(Fire(cue: cue.id, t: t, how: how, heard: heard)); lastFire = t
    print(String(format: "%6.2fs  FIRE %-8@ → %-16@ (%@) heard: “%@”", t, cue.id, cue.scene, how, heard))
    if let fcctl {
        let p = Process(); p.executableURL = URL(fileURLWithPath: fcctl); p.arguments = ["layout-named:\(cue.scene)"]; try? p.run()
        print(String(format: "        sent to Framecast at wall clock %.3f", Date().timeIntervalSince1970))
    }
}

func step(_ t: Double) {
    let hyp = settled + guess
    guard t - lastFire >= minShot else { return }
    let open = cues.filter { c in !fired.contains { $0.cue == c.id } }
    // Lexical: every cue not fired yet, earliest in the rundown first, on the recent words not yet used by a cue.
    for cue in open {
        for phrase in cue.phrases {
            let lo = max(consumed, hyp.count - phrase.count - 4)
            guard lo < hyp.count else { continue }
            let window = Array(hyp[lo...])
            let (score, j) = lexical(phrase, window)
            if let j, score >= 0.75 {
                consumed = lo + j + 1
                fire(cue, at: t, how: String(format: "lexical %.0f%%", score * 100), heard: window[...j].joined(separator: " "))
                return
            }
        }
    }
    // Semantic: each sentence once it is finished (ends in . ? !), against every cue not fired yet.
    guard let embedding else { return }
    let rawHyp = rawSettled + rawGuess
    var sentences: [(String, Int)] = [], cur: [String] = []
    for (i, w) in hyp.enumerated() {
        cur.append(w)
        if let last = rawHyp[safe: i], last.hasSuffix(".") || last.hasSuffix("?") || last.hasSuffix("!") {
            sentences.append((cur.joined(separator: " "), i)); cur = []
        }
    }
    for (sentence, endIndex) in sentences where endIndex >= consumed {
        guard sentencesChecked.insert("\(endIndex)|\(sentence)").inserted else { continue }
        let scored = open.map { c in (c, c.says.map { embedding.distance(between: sentence, and: $0, distanceType: .cosine) }.min()!) }
        if debug { print(String(format: "%6.2fs  sentence “%@” → %@", t, sentence, scored.map { String(format: "%@ %.2f", $0.0.id, $0.1) }.joined(separator: ", "))) }
        if let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= semanticThreshold {
            consumed = endIndex + 1
            fire(best.0, at: t, how: String(format: "semantic d=%.2f", best.1), heard: sentence)
            return
        }
    }
}

while let line = readLine() {
    guard let r = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let t = r["t"] as? Double, let start = r["start"] as? Double, let text = r["text"] as? String else { continue }
    let isFinal = r["final"] as? Bool ?? false
    let raw = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !norm(Substring($0)).isEmpty }
    if isFinal {
        settled += raw.map { norm(Substring($0)) }; rawSettled += raw
        settledEnd = r["end"] as? Double ?? settledEnd
        if guessStart <= start + 0.05 { guess = []; rawGuess = [] }
        // word times for the end-of-run report
        var buf = "", spans: [(Range<Int>, Double?, Double?)] = []
        for p in r["pieces"] as? [[Any]] ?? [] {
            let s = p[0] as? String ?? ""
            spans.append((buf.count..<(buf.count + s.count), p[1] as? Double, p[2] as? Double)); buf += s
        }
        for w in buf.split(whereSeparator: \.isWhitespace) {
            let a = buf.distance(from: buf.startIndex, to: w.startIndex), b = a + w.count
            let times = spans.filter { $0.0.lowerBound < b && $0.0.upperBound > a }.compactMap { s in s.1.flatMap { st in s.2.map { (st, $0) } } }
            if !norm(w).isEmpty, let first = times.first, let last = times.last { settledTimes.append(Word(text: norm(w), start: first.0, end: last.1)) }
        }
    } else if start >= settledEnd - 0.05 {
        guess = raw.map { norm(Substring($0)) }; rawGuess = raw; guessStart = start
    }
    step(t)
}

// Report: how long after the cue's trigger word was spoken did the switch fire?
print("\ncue       fired     trigger spoken  delay   how")
let expect = option("--expect").flatMap { FileManager.default.contents(atPath: $0) }
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
let spoken = settledTimes.map(\.text)
for cue in cues {
    let f = fired.first { $0.cue == cue.id }
    var said: Double?
    if let anchor = expect[cue.id].map(words), !anchor.isEmpty {
        said = spoken.indices.first { i in i + anchor.count <= spoken.count && Array(spoken[i..<(i + anchor.count)]) == anchor }
            .map { settledTimes[$0 + anchor.count - 1].end }
    }
    let firedStr = f.map { String(format: "%6.2fs", $0.t) } ?? "  missed"
    let saidStr = said.map { String(format: "%6.2fs", $0) } ?? "     ?"
    let delay = (f?.t).flatMap { ft in said.map { String(format: "%+5.2fs", ft - $0) } } ?? "   -  "
    print("\(cue.id.padding(toLength: 9, withPad: " ", startingAt: 0)) \(firedStr)   \(saidStr)        \(delay)  \(f?.how ?? "")")
}
