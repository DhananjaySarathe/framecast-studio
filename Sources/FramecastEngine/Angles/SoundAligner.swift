import Foundation
import CoreMedia

/// Finds how much later one recording of the presenter's voice arrives than another: a phone's microphone against the
/// Mac's. WebRTC keeps a phone's sound and picture together, so this is how far that phone's camera angle runs behind
/// the Mac's microphone, and how long the program's voice has to wait while the angle is on air (lip sync).
///
/// It compares loudness envelopes (1 ms steps, log scale, slow changes removed) rather than waveforms, so different
/// microphones, distances, gains and noise suppression still line up on the syllables.
public final class SoundAligner: @unchecked Sendable {
    public struct Result: Equatable, Sendable {
        /// Milliseconds the second recording runs behind the first.
        public var laterMs: Double
        /// 0…1: how clearly one offset fits better than any other.
        public var confidence: Double
        /// Seconds of speech the estimate rests on.
        public var speechSeconds: Double
    }

    private let lock = NSLock()
    private var reference = Envelope()
    private var other = Envelope()

    public init() {}

    /// The Mac's microphone (interleaved stereo, 48 kHz, first sample captured at `pts`).
    public func addReference(_ samples: UnsafePointer<Float>, frames: Int, pts: CMTime) {
        lock.lock(); reference.add(samples, frames: frames, pts: pts); lock.unlock()
    }
    /// The phone's microphone, stamped when it arrived.
    public func addOther(_ samples: UnsafePointer<Float>, frames: Int, pts: CMTime) {
        lock.lock(); other.add(samples, frames: frames, pts: pts); lock.unlock()
    }
    public func reset() { lock.lock(); reference = Envelope(); other = Envelope(); lock.unlock() }

    /// Seconds of each recording held (for status and tests).
    public var held: (reference: Double, other: Double) {
        lock.lock(); defer { lock.unlock() }
        func span(_ e: Envelope) -> Double { e.newest == .min ? 0 : Double(e.newest - e.oldest) / 1000 }
        return (span(reference), span(other))
    }

    /// The best offset over the latest `windowMs` both recordings cover, or nil when there's too little speech or
    /// no clear match yet. `lags`: offsets to try, in milliseconds (the phone is normally later).
    public func estimate(windowMs: Int = 8000, lags: ClosedRange<Int> = -150...900) -> Result? {
        lock.lock()
        guard reference.newest > .min, other.newest > .min else { lock.unlock(); return nil }
        // The phone has to cover every lag tried: its recording runs up to `lags.upperBound` past the window.
        let end = min(reference.newest, other.newest - Int64(lags.upperBound)) - 30
        let from = max(end - Int64(windowMs), reference.oldest, other.oldest - Int64(lags.lowerBound))
        guard end > from + 2500 else { lock.unlock(); return nil }
        let n = Int(end - from)
        let span = lags.upperBound - lags.lowerBound
        let r = reference.series(from: from, count: n)
        let o = other.series(from: from + Int64(lags.lowerBound), count: n + span)
        lock.unlock()
        return Self.align(reference: r, other: o, lagFloor: lags.lowerBound)
    }

    /// The offset of `other` against `reference` (both 1 ms envelopes; `other` starts `lagFloor` ms after
    /// `reference` and is `span` samples longer).
    static func align(reference r: [Float?], other o: [Float?], lagFloor: Int) -> Result? {
        let n = r.count, span = o.count - n
        guard n > 1000, span > 10 else { return nil }
        // Speech: steps clearly above the reference's quiet floor.
        let known = r.compactMap { $0 }
        guard known.count > n / 2 else { return nil }
        let sorted = known.sorted()
        let floor = sorted[sorted.count / 10], loud = sorted[sorted.count * 9 / 10]
        guard loud > floor * 4 else { return nil }
        let gate = floor + (loud - floor) * 0.25
        let speech = Double(known.filter { $0 > gate }.count) / 1000
        guard speech >= 2 else { return nil }
        let a = shape(r), b = shape(o)
        var scores = [Double](repeating: -1, count: span + 1)
        for lag in 0...span {
            var sab = 0.0, saa = 0.0, sbb = 0.0
            var i = 0
            while i < n {
                let x = a[i], y = b[i + lag]
                if !x.isNaN && !y.isNaN { sab += x * y; saa += x * x; sbb += y * y }
                i += 2                      // every other step is plenty at 1 ms and halves the work
            }
            scores[lag] = saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : -1
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0.2 else { return nil }
        // Runner-up away from the peak: a clear winner means a trustworthy offset.
        var second = -1.0
        for (i, s) in scores.enumerated() where abs(i - best) > 40 { second = max(second, s) }
        var peak = Double(best)
        if best > 0 && best < span {
            let y0 = scores[best - 1], y1 = scores[best], y2 = scores[best + 1]
            let d = y0 - 2 * y1 + y2
            if d < 0 { peak += 0.5 * (y0 - y2) / d }
        }
        let margin = scores[best] - max(0, second)
        let confidence = max(0, min(1, margin * 2.5 + (scores[best] - 0.2) * 0.5))
        return Result(laterMs: peak + Double(lagFloor), confidence: confidence, speechSeconds: speech)
    }

    /// Log loudness with its slow trend (over ~150 ms) removed, so syllable onsets carry the match. Unknown steps
    /// stay NaN and are skipped.
    static func shape(_ e: [Float?]) -> [Double] {
        let logs: [Double] = e.map { $0.map { log(Double($0) + 1e-4) } ?? .nan }
        let w = 75
        var out = [Double](repeating: .nan, count: logs.count)
        var sum = 0.0, count = 0
        var lo = 0, hi = 0
        for i in 0..<logs.count {
            while hi < logs.count && hi <= i + w { if !logs[hi].isNaN { sum += logs[hi]; count += 1 }; hi += 1 }
            while lo < i - w { if !logs[lo].isNaN { sum -= logs[lo]; count -= 1 }; lo += 1 }
            if !logs[i].isNaN && count > 0 { out[i] = logs[i] - sum / Double(count) }
        }
        return out
    }

    /// Mean loudness per millisecond of host time, for the last 40 s.
    struct Envelope {
        static let capacity = 40_000
        private var sum = [Float](repeating: 0, count: capacity)
        private var count = [UInt16](repeating: 0, count: capacity)
        private var stamp = [Int64](repeating: .min, count: capacity)
        private(set) var newest: Int64 = .min
        private(set) var oldest: Int64 = .max

        mutating func add(_ s: UnsafePointer<Float>, frames: Int, pts: CMTime) {
            guard pts.isValid else { return }
            let t0 = CMTimeGetSeconds(pts) * 1000
            for f in 0..<frames {
                let ms = Int64((t0 + Double(f) / 48).rounded(.down))
                let i = Int(((ms % Int64(Self.capacity)) + Int64(Self.capacity)) % Int64(Self.capacity))
                if stamp[i] != ms { stamp[i] = ms; sum[i] = 0; count[i] = 0 }
                sum[i] += (abs(s[f * 2]) + abs(s[f * 2 + 1])) * 0.5
                count[i] &+= 1
                if ms > newest { newest = ms }
                if ms < oldest { oldest = ms }
            }
            oldest = max(oldest, newest - Int64(Self.capacity) + 1)
        }

        func value(_ ms: Int64) -> Float? {
            let i = Int(((ms % Int64(Self.capacity)) + Int64(Self.capacity)) % Int64(Self.capacity))
            return stamp[i] == ms && count[i] > 0 ? sum[i] / Float(count[i]) : nil
        }

        func series(from: Int64, count n: Int) -> [Float?] { (0..<max(0, n)).map { value(from + Int64($0)) } }
    }
}
