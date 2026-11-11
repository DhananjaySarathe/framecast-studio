import Foundation

/// How tight an angle frames the presenter: from the face's size in the picture, or as the AI sees it (`unknown`
/// before either has looked).
public enum AngleShot: String, Codable, Sendable, CaseIterable {
    case wide, medium, close, extremeClose = "extreme_close", detail, unknown
    public var title: String {
        switch self {
        case .wide: "Wide"
        case .medium: "Medium"
        case .close: "Close-up"
        case .extremeClose: "Extreme close-up"
        case .detail: "Detail"
        case .unknown: "Not checked yet"
        }
    }
    /// Seconds a cut to this shot usually holds at the normal pace (tighter shots hold shorter). Editing practice
    /// for one presenter: shots of 3–5 s at least, about 8–10 s usually, wide shots 7–10 s.
    var baseHold: Double {
        switch self {
        case .wide: 8.5
        case .medium, .unknown: 8
        case .close: 6
        case .extremeClose: 4
        case .detail: 3.5
        }
    }
    /// Rank from wide (0) to tight (3); detail shots sit apart.
    var tightness: Int {
        switch self {
        case .wide: 0
        case .medium, .unknown: 1
        case .close: 2
        case .extremeClose, .detail: 3
        }
    }
    var isTight: Bool { tightness >= 2 }
}

/// How often the shuffle cuts.
public enum ShufflePace: String, Codable, Sendable, CaseIterable, Identifiable {
    case calm, normal, lively
    public var id: String { rawValue }
    public var title: String { switch self { case .calm: "Calm"; case .normal: "Normal"; case .lively: "Lively" } }
    var factor: Double { switch self { case .calm: 1.45; case .normal: 1; case .lively: 0.7 } }
}

/// One camera angle as the planner sees it.
public struct PlannerAngle: Sendable, Equatable {
    public var id: String
    public var shot: AngleShot
    /// Sending fresh frames with the presenter in view.
    public var usable: Bool
    /// The frame's own camera: it gets the most screen time.
    public var isPrimary: Bool
    /// 1…5 from the AI (framing, light, focus); 3 when unknown.
    public var quality: Int
    /// The presenter has been looking straight into this camera for a moment.
    public var facing: Bool
    /// Which way the presenter's face turns as this camera sees it, in degrees (0: straight at it; nil: not seen).
    /// Two angles of the same size less than 30° apart look alike, and a cut between them reads as a jump.
    public var yaw: Double?
    /// For a crop cut from a camera: that camera's angle id (nil for a camera itself).
    public var camera: String?
    public init(id: String, shot: AngleShot = .unknown, usable: Bool = true, isPrimary: Bool = false, quality: Int = 3,
                facing: Bool = false, yaw: Double? = nil, camera: String? = nil) {
        self.id = id; self.shot = shot; self.usable = usable; self.isPrimary = isPrimary; self.quality = quality
        self.facing = facing; self.yaw = yaw; self.camera = camera
    }
    /// The physical camera this angle comes from: angles with the same key are punch-ins of one picture.
    public var cameraKey: String { camera ?? id }
    /// Cut from another angle's picture rather than a camera of its own.
    public var isCrop: Bool { camera.map { $0 != id } ?? false }
}

/// The presenter's voice right now (from the program's voice level).
public struct VoiceState: Sendable, Equatable {
    public var speaking: Bool
    /// Seconds since speech stopped (0 while speaking).
    public var silence: Double
    /// Speaking clearly louder than their recent average (a point being made).
    public var emphasis: Bool
    public init(speaking: Bool, silence: Double, emphasis: Bool = false) { self.speaking = speaking; self.silence = silence; self.emphasis = emphasis }
}

/// Decides when the shuffle frame cuts to another camera angle and to which. An editor's rules: hold each angle a
/// while (tighter shots shorter), cut only in a pause in speech, vary the shot size and never cut between two angles
/// that look alike (the 30° rule), give the frame's own camera the most screen time, go tight when a point is being
/// made and wide in long silences or when no wide shot has been seen for a while, follow the presenter when they turn
/// to another camera (and back), and take the AI's pick at the next pause. Crops cut from one camera are punch-ins:
/// mostly to and from that camera's wide, rarely crop to crop. Pure logic on a clock you pass in, so it's checked by
/// `fcverify angles` and `fcverify virtual`.
public struct ShufflePlanner: Sendable {
    public struct Cut: Equatable, Sendable { public var to: String; public var reason: String }

    public var pace: ShufflePace = .normal
    public private(set) var current: String?
    public private(set) var since: Double = 0
    /// How long the angle on air is meant to hold.
    public private(set) var target: Double = 6.5
    public private(set) var screenTime: [String: Double] = [:]
    public private(set) var cuts = 0
    private var previous: String?
    /// The camera the angle on air comes from (`cameraKey`).
    private var currentCameraKey: String?
    private var lastStep: Double?
    /// The angle the presenter turned to (cut on the look); the shuffle stays there while they talk into it.
    private var lookedAt: String?
    private var lastWide: Double = 0
    private var rng: UInt64

    public init(seed: UInt64 = 0x5EED_F00D) { rng = seed == 0 ? 1 : seed }

    public var minHold: Double { 3.5 * pace.factor }
    public var maxHold: Double { 16 * pace.factor }

    /// A pick by hand (a pinned angle, or the first angle on air): starts its hold now.
    public mutating func force(_ id: String, now: Double, shot: AngleShot = .unknown, camera: String? = nil) {
        guard id != current else { return }
        previous = current; current = id; currentCameraKey = camera ?? id; since = now; lookedAt = nil
        target = shot.baseHold * pace.factor
    }

    /// Seconds a shot holds at least before the presenter's look can move it.
    public var lookHold: Double { 1.5 }

    /// One step of the clock: a cut to make now, or nil to hold.
    public mutating func step(now: Double, angles: [PlannerAngle], voice: VoiceState, hint: String? = nil) -> Cut? {
        if let last = lastStep, let c = current { screenTime[c, default: 0] += max(0, min(1, now - last)) }
        lastStep = now
        let usable = angles.filter(\.usable)
        guard !usable.isEmpty else { return nil }
        // Nothing on air yet, or the angle on air stopped sending or lost the presenter: cut at once.
        guard let cur = current, let onAir = angles.first(where: { $0.id == cur }), onAir.usable else {
            let pick = usable.first(where: \.isPrimary) ?? usable[0]
            return cut(to: pick, now: now, voice: voice, reason: current == nil ? "first angle" : "the angle on air stopped or lost you")
        }
        guard usable.count > 1 else { return nil }
        let held = now - since
        if onAir.shot == .wide { lastWide = now }
        // Looking into a camera is about the camera, never its crops: a crop is never a look target, and a crop on air
        // counts as faced when its camera is.
        let onAirFacing = onAir.isCrop ? angles.first(where: { $0.id == onAir.cameraKey })?.facing ?? false : onAir.facing
        // The presenter turned to another camera: go with them (a director cuts on the look, mid-sentence too).
        if held >= lookHold, !onAirFacing, let look = usable.first(where: { $0.facing && !$0.isCrop && !$0.isPrimary && $0.id != cur }) {
            let c = cut(to: look, now: now, voice: voice, reason: "you turned to it")
            lookedAt = look.id
            return c
        }
        // They turned back to the frame's own camera.
        if held >= lookHold, cur == lookedAt, !onAirFacing, let home = usable.first(where: { $0.isPrimary && $0.facing && !$0.isCrop }) {
            return cut(to: home, now: now, voice: voice, reason: "you turned back")
        }
        // While they talk into the camera they turned to, it stays (up to twice the usual longest hold).
        if cur == lookedAt && onAirFacing && held < maxHold * 2 { return nil }
        guard held >= minHold else { return nil }
        let pause = !voice.speaking && voice.silence >= 0.25
        // The AI's pick: taken at the first pause once the shot has had its minimum.
        if let h = hint, h != cur, let a = usable.first(where: { $0.id == h }), pause, held >= minHold + 0.5 {
            return cut(to: a, now: now, voice: voice, reason: "the AI's pick")
        }
        let due = held >= target && pause
        let overdue = held >= maxHold && (pause || held >= maxHold + 2)
        guard due || overdue else { return nil }
        guard let next = choose(from: usable, current: onAir, voice: voice, now: now) else { return nil }
        return cut(to: next, now: now, voice: voice, reason: overdue && !pause ? "held too long" : "a pause")
    }

    /// Share of screen time the frame's own camera has had so far (0…1).
    public func share(of id: String) -> Double {
        let total = screenTime.values.reduce(0, +)
        return total > 0 ? (screenTime[id] ?? 0) / total : 0
    }

    private mutating func cut(to a: PlannerAngle, now: Double, voice: VoiceState, reason: String) -> Cut {
        let sameCamera = current != nil && a.cameraKey == currentCameraKey
        previous = current; current = a.id; currentCameraKey = a.cameraKey; since = now; cuts += 1; lookedAt = nil
        if a.shot == .wide { lastWide = now }
        var hold = a.shot.baseHold * pace.factor * (0.8 + 0.45 * random())
        if voice.emphasis && a.shot.isTight { hold *= 0.85 }
        // Punch-ins within one camera hold a little longer, so they stay fewer.
        if sameCamera { hold *= 1.15 }
        target = min(max(hold, minHold + 0.5), maxHold - 1)
        return Cut(to: a.id, reason: reason)
    }

    private mutating func choose(from usable: [PlannerAngle], current: PlannerAngle, voice: VoiceState, now: Double) -> PlannerAngle? {
        let others = usable.filter { $0.id != current.id }
        guard !others.isEmpty else { return nil }
        let primaryShare = usable.first(where: \.isPrimary).map { share(of: $0.id) } ?? 0
        let fair = 1 / Double(usable.count)
        var best: (PlannerAngle, Double)?
        for a in others {
            var s = 1.0
            // Vary the shot size: a different size reads as a real cut, the same size as a jump.
            let gap = abs(a.shot.tightness - current.shot.tightness)
            if a.shot != .unknown && current.shot != .unknown { s += gap == 0 ? -0.4 : (gap == 1 ? 0.35 : 0.6) }
            // A punch-in within one camera is a smaller change than a cut to another camera; crop to crop (medium ↔
            // close-up) only now and then, as its −0.6 outweighs the +0.35 size bonus.
            let sameCamera = a.cameraKey == current.cameraKey
            if sameCamera { s -= 0.3 }
            if sameCamera && a.isCrop && current.isCrop { s -= 0.6 }
            // The 30° rule: the same size from nearly the same direction is a jump cut.
            if let y1 = a.yaw, let y2 = current.yaw, abs(y1 - y2) < 30, gap == 0 || a.shot == .unknown || current.shot == .unknown { s -= 1.2 }
            // A wide shot now and then shows the space (about every 30 s at the normal pace, counted from when the
            // last one ended).
            if a.shot == .wide { let since = (now - lastWide) / pace.factor; s += since > 30 ? 1.6 : since > 18 ? 0.8 : 0 }
            if a.isPrimary && primaryShare < 0.45 { s += 0.9 }
            if !a.isPrimary && primaryShare > 0.6 { s += 0.3 }
            if voice.emphasis && a.shot.isTight { s += 0.7 }
            if !voice.speaking && voice.silence > 1.5 && a.shot == .wide { s += 0.5 }
            if share(of: a.id) < fair * 0.6 { s += 0.4 }
            // Going back to the angle before is fine, unless it's a crop of the camera on air (no punch-in ping-pong).
            if a.id == previous { s += sameCamera && a.isCrop ? -0.3 : 0.1 }
            s += Double(a.quality - 3) * 0.2
            s += 0.35 * random()
            if best == nil || s > best!.1 { best = (a, s) }
        }
        return best?.0
    }

    /// SplitMix64: repeatable, so checks and replays give the same cuts.
    private mutating func random() -> Double {
        rng &+= 0x9E37_79B9_7F4A_7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
