import Foundation
import IOKit.ps

/// How long ticks took over a window. Steady ticks and transition ticks are kept apart: a transition is allowed
/// to cost more for its 0.7 s, and must not count against the steady budget.
public struct TickSummary: Codable, Sendable, Equatable {
    public var count = 0
    public var p50 = 0.0, p95 = 0.0, p99 = 0.0, max = 0.0          // steady ticks, ms
    public var transitionCount = 0
    public var transitionP95 = 0.0, transitionMax = 0.0
    public var lockP95 = 0.0, renderP95 = 0.0
    public init() {}
}

/// The last few thousand ticks (about two minutes at 30 fps), filled on the render queue.
public final class TickStats: @unchecked Sendable {
    public struct Sample {
        public var t = 0.0, tick = 0.0, lock = 0.0, render = 0.0, transition = false
        public init(t: Double, tick: Double, lock: Double = 0, render: Double = 0, transition: Bool = false) {
            self.t = t; self.tick = tick; self.lock = lock; self.render = render; self.transition = transition
        }
    }
    private let lock = NSLock()
    private var ring = [Sample](repeating: Sample(t: 0, tick: 0), count: 4096)
    private var next = 0, filled = 0

    public init() {}
    public func add(_ s: Sample) {
        lock.lock(); ring[next] = s; next = (next + 1) % ring.count; filled = min(filled + 1, ring.count); lock.unlock()
    }
    public func reset() { lock.lock(); next = 0; filled = 0; lock.unlock() }

    public func summary(since t0: Double) -> TickSummary {
        lock.lock()
        var steady: [Double] = [], moving: [Double] = [], locks: [Double] = [], renders: [Double] = []
        for i in 0..<filled {
            let s = ring[(next - 1 - i + ring.count) % ring.count]
            if s.t < t0 { break }
            if s.transition { moving.append(s.tick) } else { steady.append(s.tick) }
            locks.append(s.lock); renders.append(s.render)
        }
        lock.unlock()
        var out = TickSummary()
        steady.sort(); moving.sort(); locks.sort(); renders.sort()
        out.count = steady.count
        out.p50 = Self.pct(steady, 0.5); out.p95 = Self.pct(steady, 0.95); out.p99 = Self.pct(steady, 0.99); out.max = steady.last ?? 0
        out.transitionCount = moving.count
        out.transitionP95 = Self.pct(moving, 0.95); out.transitionMax = moving.last ?? 0
        out.lockP95 = Self.pct(locks, 0.95); out.renderP95 = Self.pct(renders, 0.95)
        return out
    }

    static func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}

/// Budget tiers, from everything on to the live editor switched off.
public enum BudgetTier: Int, Codable, Sendable, Comparable, CaseIterable {
    case full = 0, eco, minimal, off
    public static func < (a: BudgetTier, b: BudgetTier) -> Bool { a.rawValue < b.rawValue }
    public var title: String { switch self { case .full: "T0 Full"; case .eco: "T1 Eco"; case .minimal: "T2 Minimal"; case .off: "T3 Off" } }
}

/// Auto steps down on battery and in Low Power Mode; Eco always holds at least T1; Full ignores power (but never heat or load).
public enum PerformanceMode: String, Codable, Sendable, CaseIterable {
    case auto, eco, full
    public var title: String { rawValue.capitalized }
}

/// What the governor last saw, for the HUD and the Gate 0 dump.
public struct GovernorStatus: Codable, Sendable, Equatable {
    public var tier: BudgetTier = .full
    public var reason = ""
    public var steadyP95 = 0.0
    /// The normal frame time the lines start from, and where it came from ("measured" in Gate 0, "learned" in the
    /// first minute after launch, or "learning").
    public var baseline = 0.0
    public var baselineFrom = "learning"
    public var missedLast10s = 0
    public var thermal = "nominal"
    public var onBattery = false
    public var lowPower = false
    public var changes = 0
    public init() {}
}

/// Watches frame time, missed recording frames, heat and power once a second and picks a tier. It steps down at
/// once when a line is crossed, and back up one tier after 60 healthy seconds (5 minutes to leave T3).
/// The frame-time lines sit above this Mac's normal frame time: other apps share the graphics chip, so a normal
/// frame can take 10-17 ms in the app where a quiet benchmark took 6. Unless Gate 0 measured it, the governor
/// learns it from 15 to 45 s after launch (the first 15 s are warm-up and never change the tier).
public final class BudgetGovernor: @unchecked Sendable {
    private let lock = NSLock()
    private var status = GovernorStatus()
    private var lastEval = 0.0
    private var overHalfSince: Double?
    private var fairSince: Double?
    private var healthySince: Double?
    private var missedHistory: [(Double, Int)] = []
    private var lastPowerCheck = -100.0
    private var battery = false
    private var startedAt: Double?
    private var learning: [Double] = []
    private var learned: Double?
    private var relearnRequested = false
    /// The app's own steady p95 at this frame rate (Gate 0), in ms. 0 until measured.
    public var baselineMs: Double { get { lock.lock(); defer { lock.unlock() }; return _baseline } set { lock.lock(); _baseline = newValue; lock.unlock() } }
    public var mode: PerformanceMode { get { lock.lock(); defer { lock.unlock() }; return _mode } set { lock.lock(); _mode = newValue; lock.unlock() } }
    private var _baseline = 0.0
    private var _mode = PerformanceMode.auto

    /// Checks only: a fixed heat level instead of the Mac's own.
    public var testThermal: ProcessInfo.ThermalState?

    public init() {}

    public var current: GovernorStatus { lock.lock(); defer { lock.unlock() }; return status }
    public var tier: BudgetTier { current.tier }

    /// The work changed (a recording, stream or replay buffer started or stopped, so there's more or less encoding):
    /// learn the normal frame time again, after the same 15 s warm-up.
    public func relearn() { lock.lock(); relearnRequested = true; lock.unlock() }

    /// Re-enables after T3 (the user switched camera moves back on). Frames from before the reset are not judged again.
    public func reset() {
        lock.lock(); status.tier = .full; status.reason = "reset"; overHalfSince = nil; healthySince = nil; resetAt = HostClock.seconds(); lock.unlock()
    }
    private var resetAt = -1e9

    /// Called from the render queue after each tick; does real work once a second, judging the steady ticks of
    /// the last 20 s (transitions have their own limit and never move the tier).
    func evaluate(now: Double, fps: Int, stats: TickStats, missedTotal: Int) {
        lock.lock(); let due = now - lastEval >= 1, since = resetAt; lock.unlock()
        guard due else { return }
        // Just after a reset there are too few new frames to judge: count them as healthy until there are 3 s of them.
        let p95 = now - since < 3 ? 0 : stats.summary(since: max(now - 20, since)).p95
        evaluate(now: now, fps: fps, steadyP95: p95, missedTotal: missedTotal)
    }

    public func evaluate(now: Double, fps: Int, steadyP95 p95: Double, missedTotal: Int) {
        lock.lock()
        lastEval = now
        let measured = _baseline, mode = _mode
        let relearnNow = relearnRequested; relearnRequested = false
        lock.unlock()
        if relearnNow { startedAt = now; learning = []; learned = nil }

        let start = startedAt ?? now
        startedAt = start
        let age = now - start
        if learned == nil && age >= 15 { learning.append(p95) }
        if learned == nil && age >= 45 && !learning.isEmpty { learned = learning.sorted()[learning.count / 2] }
        let baseline = measured > 0 ? measured : (learned ?? 0)
        let knowsBaseline = measured > 0 || learned != nil
        let interval = 1000 / Double(max(1, fps))
        missedHistory.append((now, missedTotal))
        missedHistory.removeAll { now - $0.0 > 10 }
        let missed10 = missedTotal - (missedHistory.first?.1 ?? missedTotal)
        let thermal = testThermal ?? ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if now - lastPowerCheck > 10 { lastPowerCheck = now; battery = Self.onBattery() }
        if thermal == .fair { fairSince = fairSince ?? now } else { fairSince = nil }

        // Frame time swings a few ms from minute to minute with whatever else the Mac is drawing, so the lines leave room
        // for that; at 30 fps they never sit below half, two thirds and four fifths of the frame.
        let t1 = max(baseline + 5, 0.50 * interval), t2 = max(baseline + 8, 0.65 * interval), t3 = max(baseline + 12, 0.80 * interval)
        if p95 > t3 && knowsBaseline { overHalfSince = overHalfSince ?? now } else { overHalfSince = nil }

        // The worst tier any condition asks for right now.
        var want = BudgetTier.full, why = knowsBaseline ? "healthy" : "learning this Mac's normal frame time"
        func ask(_ t: BudgetTier, _ r: String) { if t > want && age >= 15 { want = t; why = r } }
        let load = knowsBaseline   // frame-time lines apply once the normal frame time is known
        if load && p95 > t1 { ask(.eco, String(format: "frames %.1f ms (line %.1f)", p95, t1)) }
        if let f = fairSince, now - f > 120 { ask(.eco, "warm for 2 min") }
        if mode == .eco { ask(.eco, "Eco chosen") }
        if mode == .auto && battery { ask(.eco, "on battery") }
        if mode == .auto && lowPower { ask(.eco, "Low Power Mode") }
        if load && p95 > t2 { ask(.minimal, String(format: "frames %.1f ms (line %.1f)", p95, t2)) }
        // One slow frame costs a slot in each recording; more than that within 10 s is a pattern.
        if missed10 >= 4 { ask(.minimal, "\(missed10) recording frames missed") }
        if thermal == .serious { ask(.minimal, "Mac is hot") }
        if let o = overHalfSince, now - o >= 5 { ask(.off, String(format: "frames over %.1f ms for 5 s", t3)) }
        if thermal == .critical { ask(.off, "Mac is very hot") }

        lock.lock()
        var s = status
        if want > s.tier {
            s.tier = want; s.reason = why; s.changes += 1; healthySince = nil
        } else if want < s.tier {
            // Healthy enough to climb: under the T1 line, nothing missed, heat fair or better.
            let healthy = (p95 <= t1 || !load) && missed10 == 0 && thermal.rawValue <= ProcessInfo.ThermalState.fair.rawValue
            if healthy { healthySince = healthySince ?? now } else { healthySince = nil }
            let wait: Double = s.tier == .off ? 300 : 60
            if let h = healthySince, now - h >= wait {
                s.tier = BudgetTier(rawValue: s.tier.rawValue - 1) ?? .full
                s.tier = max(s.tier, want); s.reason = "recovered"; s.changes += 1; healthySince = now
            }
        } else { healthySince = nil }
        s.steadyP95 = p95; s.baseline = baseline; s.missedLast10s = missed10
        s.baselineFrom = measured > 0 ? "measured" : (learned != nil ? "learned" : "learning")
        s.thermal = ["nominal", "fair", "serious", "critical"][min(3, thermal.rawValue)]
        s.onBattery = battery; s.lowPower = lowPower
        status = s
        lock.unlock()
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
