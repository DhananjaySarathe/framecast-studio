import Foundation
import CoreGraphics

/// Live captions: what they look like, how spoken words become at most two lines on each canvas, when they fade,
/// and the subtitle files written next to a recording. Plain logic (no drawing, no speech) so it can be checked
/// without a microphone; CaptionRenderer draws it and the app's CaptionEngine feeds it.

public enum CaptionSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    public var title: String { switch self { case .small: "S"; case .medium: "M"; case .large: "L" } }
    /// Type size on a canvas whose short side is 1080 px.
    public var points: CGFloat { switch self { case .small: 36; case .medium: 46; case .large: 58 } }
}

public enum CaptionPosition: String, Codable, CaseIterable, Sendable {
    case bottom, top
    public var title: String { rawValue.capitalized }
}

/// Settings › Captions: the language recognised, the size and where they sit. Whether captions are on isn't saved
/// (they start off each launch). Every field decodes on its own, so older or newer settings still load.
public struct CaptionSettings: Codable, Equatable, Sendable {
    /// A locale identifier ("en_IN", "hi_IN"); empty: English for this Mac's region.
    public var language = ""
    public var size: CaptionSize = .medium
    public var position: CaptionPosition = .bottom
    public init() {}
    enum CodingKeys: String, CodingKey { case language, size, position }
    public init(from d: Decoder) throws {
        // Never fails: anything unreadable is left at its default, so the rest of the settings still load.
        guard let c = try? d.container(keyedBy: CodingKeys.self) else { return }
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? ""
        size = (try? c.decodeIfPresent(CaptionSize.self, forKey: .size)) ?? .medium
        position = (try? c.decodeIfPresent(CaptionPosition.self, forKey: .position)) ?? .bottom
    }
}

/// One word on screen: `settled` once the recogniser has finished with it (drawn full white), else still a guess
/// (drawn lighter, and it may still change).
public struct CaptionWord: Equatable, Hashable, Sendable {
    public var text: String
    public var settled: Bool
    public init(_ text: String, settled: Bool) { self.text = text; self.settled = settled }
}

/// What the program shows: the words of the current caption block, how they look, and when the last new words
/// came (host clock seconds), which starts the fade.
public struct CaptionFrame: Equatable, Sendable {
    public var words: [CaptionWord]
    public var size: CaptionSize
    public var position: CaptionPosition
    public var lastChange: Double
    public init(words: [CaptionWord], size: CaptionSize, position: CaptionPosition, lastChange: Double) {
        self.words = words; self.size = size; self.position = position; self.lastChange = lastChange
    }
}

/// Captions stay up while words keep coming and fade out once speech stops.
public enum CaptionFade {
    /// Seconds the last words stay fully shown, then how long they take to fade.
    public static let hold = 3.0
    public static let fade = 0.6
    /// 1 shown … 0 gone, `now` and `lastChange` on the same clock.
    public static func alpha(now: Double, lastChange: Double) -> Double {
        let t = now - lastChange - hold
        if t <= 0 { return 1 }
        if t >= fade { return 0 }
        let p = t / fade
        return 1 - p * p * (3 - 2 * p)
    }
    /// The block has faded away: the next words start a fresh one.
    public static func isGone(now: Double, lastChange: Double) -> Bool { now - lastChange >= hold + fade }
}

/// Turns the recogniser's results into the words of the current caption block. Results come as guesses (volatile)
/// that are replaced until the text for that stretch is final; final text is kept, the guess after it is redrawn.
/// A block starts when speech resumes after the old one faded, and rolls up as you speak (CaptionLayout shows its
/// last two lines).
public struct CaptionTrack: Sendable {
    public struct Segment: Equatable, Sendable { public var id: Int; public var words: [String] }
    public private(set) var segments: [Segment] = []
    public private(set) var guess: [String] = []
    public private(set) var lastChange = -Double.infinity
    /// Older words are dropped once the block is longer than this (they're long off screen by then).
    public var maxWords = 120
    private var guessStart = -Double.infinity
    private var settledEnd = -Double.infinity
    private var nextID = 0
    public init() {}

    public var words: [CaptionWord] {
        segments.flatMap { $0.words.map { CaptionWord($0, settled: true) } } + guess.map { CaptionWord($0, settled: false) }
    }
    public var isEmpty: Bool { segments.isEmpty && guess.isEmpty }

    static func split(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Takes one result (`start`/`end` on the recogniser's audio clock, `now` on the host clock). Returns the id
    /// given to a final result with words, so its transcript line can be corrected on screen later.
    @discardableResult
    public mutating func take(_ text: String, isFinal: Bool, start: Double, end: Double, now: Double) -> Int? {
        let raw = Self.split(text)
        // Speech after the old block faded starts a fresh one.
        if !raw.isEmpty, !isEmpty, CaptionFade.isGone(now: now, lastChange: lastChange) { segments = []; guess = [] }
        let before = words
        var made: Int?
        if isFinal {
            if !raw.isEmpty { made = nextID; segments.append(Segment(id: nextID, words: raw)); nextID += 1 }
            settledEnd = max(settledEnd, end)
            if guessStart <= start + 0.05 { guess = [] }
            var n = segments.reduce(0) { $0 + $1.words.count }
            while n > maxWords, segments.count > 1 { n -= segments.removeFirst().words.count }
        } else if start >= settledEnd - 0.05, !raw.isEmpty {
            // An empty guess is the recogniser starting over: the last words stay up rather than blink off for a
            // moment (the final text replaces them either way).
            guess = raw; guessStart = start
        }
        // Only new or changed words keep the captions up; a result that changes nothing lets them fade.
        if words != before { lastChange = now }
        return made
    }

    /// Replaces a final segment's words if it's still in the block (a correction from the transcript).
    @discardableResult
    public mutating func correct(id: Int, text: String) -> Bool {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return false }
        segments[i].words = Self.split(text)
        return true
    }

    public mutating func clear() { segments = []; guess = []; lastChange = -Double.infinity }
}

/// Line breaking by measured width: words fill each line greedily, so lines already shown never reflow as words are
/// added, and only the last `maxLines` lines are shown (the captions roll up).
public enum CaptionLayout {
    public static func lines(_ words: [CaptionWord], maxWidth: CGFloat, measure: (String) -> CGFloat,
                             space: CGFloat, maxLines: Int = 2) -> [[CaptionWord]] {
        var lines: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        var width: CGFloat = 0
        for w in words {
            let ww = measure(w.text)
            if cur.isEmpty { cur = [w]; width = ww; continue }
            if width + space + ww <= maxWidth { cur.append(w); width += space + ww }
            else { lines.append(cur); cur = [w]; width = ww }
        }
        if !cur.isEmpty { lines.append(cur) }
        return Array(lines.suffix(maxLines))
    }
    public static func text(_ line: [CaptionWord]) -> String { line.map(\.text).joined(separator: " ") }
}

/// Where captions sit on a canvas (CoreImage coordinates: y up from the bottom).
public enum CaptionGeometry {
    /// On 9:16, Reels and Shorts draw their own buttons and text over the bottom 22% and down the right side.
    public static let verticalUIBand = 0.22
    public static func isVertical(_ canvas: CGSize) -> Bool { canvas.height > canvas.width }
    public static func fontSize(_ size: CaptionSize, canvas: CGSize) -> CGFloat {
        (size.points * min(canvas.width, canvas.height) / 1080).rounded()
    }
    /// The plate's padding around the text for a font size.
    public static func padding(_ font: CGFloat) -> (x: CGFloat, y: CGFloat) { ((font * 0.62).rounded(), (font * 0.30).rounded()) }
    /// Widest the plate may be: inside the side margins (wider ones on 9:16, clear of the apps' buttons).
    public static func maxPlateWidth(_ canvas: CGSize) -> CGFloat {
        (canvas.width * (isVertical(canvas) ? 0.78 : 0.76)).rounded()
    }
    public static func maxTextWidth(_ canvas: CGSize, font: CGFloat) -> CGFloat { maxPlateWidth(canvas) - 2 * padding(font).x }
    /// The plate's lower edge for a plate `height` tall.
    public static func plateY(_ position: CaptionPosition, canvas: CGSize, height: CGFloat) -> CGFloat {
        let H = canvas.height
        if isVertical(canvas) {
            return position == .bottom ? (H * (verticalUIBand + 0.025)).rounded() : (H * (1 - 0.12) - height).rounded()
        }
        return position == .bottom ? (H * 0.075).rounded() : (H * (1 - 0.07) - height).rounded()
    }
}

/// A caption with its times (seconds into a recording), for subtitle files.
public struct TimedCaption: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// SubRip (.srt) and plain transcripts.
public enum CaptionExport {
    /// Characters per subtitle line and lines per cue (common subtitle guidance).
    public static let lineChars = 42
    public static let cueLines = 2
    /// Shortest a cue stays up, when the next one leaves room.
    public static let minCue = 0.8

    /// "HH:MM:SS,mmm".
    public static func timestamp(_ s: Double) -> String {
        let ms = Int((max(0, s) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Breaks text into lines of at most `lineChars` (a longer word stays whole on its own line).
    public static func wrap(_ text: String, width: Int = lineChars) -> [String] {
        var lines: [String] = [], cur = ""
        for w in text.split(whereSeparator: \.isWhitespace) {
            if cur.isEmpty { cur = String(w) }
            else if cur.count + 1 + w.count <= width { cur += " " + w }
            else { lines.append(cur); cur = String(w) }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    /// Cues in order, each at most two lines: a long caption is split into several cues, its time shared by length.
    /// Cues never overlap, and each stays up at least `minCue` when there's room before the next.
    public static func cues(_ items: [TimedCaption]) -> [TimedCaption] {
        var out: [TimedCaption] = []
        for it in items.sorted(by: { $0.start < $1.start }) {
            let lines = wrap(it.text)
            guard !lines.isEmpty, it.end > it.start else { continue }
            let groups = stride(from: 0, to: lines.count, by: cueLines).map { Array(lines[$0..<min($0 + cueLines, lines.count)]) }
            let total = Double(groups.reduce(0) { $0 + $1.joined(separator: " ").count })
            var t = it.start
            for g in groups {
                let text = g.joined(separator: "\n")
                let d = (it.end - it.start) * Double(g.joined(separator: " ").count) / max(1, total)
                out.append(TimedCaption(start: t, end: t + d, text: text))
                t += d
            }
        }
        for i in out.indices {
            let next = i + 1 < out.count ? out[i + 1].start : .infinity
            out[i].end = min(max(out[i].end, out[i].start + minCue), next)
        }
        return out.filter { $0.end - $0.start >= 0.05 }
    }

    /// Whether a caption goes into a recording's subtitles: at least half of it was said while recording (a sentence
    /// mostly said before the recording started, or in a pause, is left out rather than flashed up whole).
    public static func keeps(inside: Double, spoken: Double) -> Bool { inside > 0.05 && inside >= 0.5 * max(0.05, spoken) }

    public static func srt(_ items: [TimedCaption]) -> String {
        cues(items).enumerated().map { i, c in "\(i + 1)\n\(timestamp(c.start)) --> \(timestamp(c.end))\n\(c.text)\n" }
            .joined(separator: "\n")
    }

    /// "[00:05] What was said." per caption.
    public static func transcript(_ items: [TimedCaption]) -> String {
        items.sorted { $0.start < $1.start }.map { c in
            let s = Int(max(0, c.start))
            let t = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
            return "[\(t)] \(c.text)"
        }.joined(separator: "\n") + "\n"
    }
}

/// Maps the recogniser's audio clock (seconds of audio it has been given) to the host clock: it notes the capture
/// time of each block of microphone samples handed over, starting a new anchor whenever the samples jump (the mic
/// was muted, or paused).
public struct CaptionClock: Sendable {
    private var anchors: [(t: Double, host: Double)] = []
    private var given: Int64 = 0
    public let rate: Double
    public init(rate: Double = 48_000) { self.rate = rate }

    /// `frames` samples captured from host time `host` were handed to the recogniser.
    public mutating func note(frames: Int, host: Double) {
        let t = Double(given) / rate
        if let a = anchors.last {
            if abs(a.host + (t - a.t) - host) > 0.25 { anchors.append((t, host)) }
        } else { anchors.append((t, host)) }
        if anchors.count > 2000 { anchors.removeFirst(1000) }
        given += Int64(frames)
    }

    /// Host time of the recogniser's time `t` (nil before any audio).
    public func host(at t: Double) -> Double? {
        guard let a = anchors.last(where: { $0.t <= t + 1e-6 }) ?? anchors.first else { return nil }
        return a.host + (t - a.t)
    }
}
