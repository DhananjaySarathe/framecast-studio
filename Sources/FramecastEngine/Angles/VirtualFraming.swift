import Foundation
import CoreGraphics

// Virtual angles: a medium and a close-up cut from one camera's picture, framed on the presenter's face.
// Pure logic (no Core Image), so `fcverify virtual` can run it on a made-up clock.

/// A shot cut from one camera's picture.
public enum VirtualShot: String, Codable, Sendable, CaseIterable {
    case medium, close
    public var angleShot: AngleShot { self == .medium ? .medium : .close }
    public var title: String { self == .medium ? "Medium" : "Close-up" }
    /// Face height as a fraction of the crop's height.
    public var faceTarget: Double { self == .medium ? 0.17 : 0.30 }
    /// How far down the frame the eyes sit: a landscape frame, then a portrait one.
    public func eyeLine(aspect: Double) -> Double {
        switch self {
        case .medium: aspect < 1 ? 0.30 : 0.34
        case .close: aspect < 1 ? 0.32 : 0.37
        }
    }
    /// Space kept between the top of the head and the frame's top edge, as a fraction of the crop's height.
    public var crownGuard: Double { self == .medium ? 0.05 : 0.02 }
}

/// Which shots a camera makes.
public struct VirtualShots: Codable, Equatable, Sendable {
    public var medium = true
    public var close = true
    public init(medium: Bool = true, close: Bool = true) { self.medium = medium; self.close = close }
    public subscript(_ s: VirtualShot) -> Bool {
        get { s == .medium ? medium : close }
        set { if s == .medium { medium = newValue } else { close = newValue } }
    }
    public var any: Bool { medium || close }
    enum CodingKeys: String, CodingKey { case medium, close }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        medium = (try? c.decodeIfPresent(Bool.self, forKey: .medium)) ?? true
        close = (try? c.decodeIfPresent(Bool.self, forKey: .close)) ?? true
    }
}

/// Angles › From one camera: which cameras make crops, and whether per-angle recording keeps them.
public struct VirtualAngleSettings: Codable, Equatable, Sendable {
    /// Keyed by the camera source's UUID string. A camera that isn't listed makes no crops.
    public var cameras: [String: VirtualShots] = [:]
    /// Per-angle recording also writes a file for each crop (off: the camera's own file already holds them).
    public var recordCrops = false
    public init() {}
    enum CodingKeys: String, CodingKey { case cameras, recordCrops }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cameras = (try? c.decodeIfPresent([String: VirtualShots].self, forKey: .cameras)) ?? [:]
        recordCrops = (try? c.decodeIfPresent(Bool.self, forKey: .recordCrops)) ?? false
    }
}

/// One look at the camera: face boxes in the raw camera picture (top-left origin, 0...1, biggest first, at most 3).
public struct FaceSample: Sendable, Equatable {
    public var boxes: [CGRect]
    /// Which way the biggest face turns, in degrees.
    public var yaw: Double?
    /// Upper bodies seen, with or without a face (same coordinates as the boxes).
    public var bodies: [CGRect]
    /// Host-clock seconds when the picture was taken.
    public var at: Double
    public init(boxes: [CGRect], yaw: Double? = nil, bodies: [CGRect] = [], at: Double) {
        self.boxes = boxes; self.yaw = yaw; self.bodies = bodies; self.at = at
    }
}

/// How sharp a crop looks: output pixels per camera pixel up to 1.25 is sharp (the live editor's cap), up to 1.6
/// a little soft, more is soft.
public enum CropGrade: String, Codable, Sendable {
    case sharp, slightlySoft = "slightly_soft", soft
    public static let sharpUpTo = 1.25
    public init(enlargement e: Double) { self = e <= Self.sharpUpTo + 1e-9 ? .sharp : e <= 1.6 + 1e-9 ? .slightlySoft : .soft }
    public var title: String { switch self { case .sharp: "sharp"; case .slightlySoft: "a little soft"; case .soft: "soft" } }
}

/// What one shot of a camera will be, worked out from the presenter's face size and the camera's resolution.
public struct ShotPlan: Sendable, Equatable {
    public var available: Bool
    /// Why it isn't offered (nil when it is).
    public var reason: String?
    /// How much tighter than the camera's own (wide) shot in the 16:9 frame.
    public var zoom: Double
    /// Crop height as a fraction of the camera picture's height (both canvases share it).
    public var height: Double
    /// Face height as a fraction of the crop's height.
    public var faceInCrop: Double
    /// Output pixels per camera pixel on each canvas. The 16:9 figure is capped at 2; the 9:16 one is only reported.
    public var enlargement: [CanvasKind: Double]
    public var grade: CropGrade
    static func none(_ reason: String) -> ShotPlan {
        ShotPlan(available: false, reason: reason, zoom: 1, height: 1, faceInCrop: 0, enlargement: [:], grade: .sharp)
    }
}

/// Who a crop is drawn for. Each keeps its own glide, so a cut lands framed on each.
public enum VirtualDrawKey: Hashable, Sendable {
    case program(CanvasKind)
    case iso
}

/// A crop as drawn: the area of the camera picture (top-left origin, 0...1).
public struct VirtualView: Sendable, Equatable {
    public var rect: CGRect
    /// Zoom over the camera's own shot in the 16:9 frame.
    public var zoom: Double
    /// Pushed off the presenter by the picture's edge (more than 0.15 of the crop's width).
    public var edgeLimited: Bool
}

/// Frames the crops of one camera. Face samples come in a few times a second; views are asked for on every frame
/// drawn. A crop holds still while the presenter is still and pans gently when they move; its size stays put
/// unless the face size really changes; a key that wasn't drawn for a moment starts already framed.
public struct VirtualFramer: Sendable {
    // Shot sizes.
    /// Any two shots of one camera (the wide included) differ at least this much in zoom.
    public static let minStep = 1.4
    /// Face height in the crop from which a shot reads as a close-up (as AngleWatch classifies).
    public static let closeFrom = 0.22
    public static let maxEnlargement = 2.0
    public static let maxZoom = 4.0
    /// Shift towards where the presenter looks, in crop widths. Off: the sign of Vision's yaw isn't verified yet.
    public static let leadRoom = 0.0
    // Motion.
    static let panResponse = 0.9, zoomResponse = 2.5
    /// The pan's response with the face within `keepIn` crop widths of the crop's side.
    static let quickResponse = 0.3, keepIn = 0.15
    /// Pan speed and acceleration caps, in crop widths (or heights) per second and per second².
    static let maxSpeed = 0.35, maxAccel = 1.2
    /// A draw key not drawn for this long starts at its target.
    static let snapAfter = 0.5
    /// A shot withdrawn by a re-plan while drawn keeps its last view this long at most.
    static let holdWithdrawn = 1.0
    /// The crop stops being usable this long after the presenter's face, or a body where it was, was last seen.
    public static let lostAfter = 1.5
    /// Once the presenter has gone, a new face takes over after this long as the only one.
    static let newcomerAfter = 3.0
    /// A walk (camera widths or heights a second) from which the aim leads the smoothed face by its speed times
    /// `leadTime`, never past the newest reading: the smoothing's lag, taken back.
    static let walkFrom = 0.03, leadTime = 0.5

    struct Geometry: Equatable {
        var camera: CGSize
        var frames: [CanvasKind: CGSize]
        var shots: VirtualShots
        /// The area of the camera picture the frame shows (its Layer › Crop; the whole picture when none).
        var shown = Self.whole
        /// The frame is rotated: no crops.
        var turned = false
        static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        var frame16: CGSize { frames[.horizontal] ?? CGSize(width: 1920, height: 1080) }
        /// The 9:16 frame's shape (9:16 when none is marked).
        var portraitAspect: Double { frames[.vertical].map { $0.width / max(1, $0.height) }.flatMap { $0 < 1 ? $0 : nil } ?? 9.0 / 16 }
        /// The shape of what the frame shows, in pixels.
        var camAspect: Double { shown.width * camera.width / max(1, shown.height * camera.height) }
        /// The share of the camera's height the wide shows in the 16:9 frame (a 4:3 camera loses its top and bottom;
        /// a Layer › Crop shows less).
        var wideShown: Double { shown.height * min(1, camAspect / max(0.1, frame16.width / max(1, frame16.height))) }
        /// A face (or body) whose centre the frame shows.
        func shows(_ r: CGRect) -> Bool {
            shown == Self.whole || (r.midX >= shown.minX && r.midX <= shown.maxX && r.midY >= shown.minY && r.midY <= shown.maxY)
        }
    }
    /// Where the crops aim: the eye point, and the face height when it was set (for the head-top guard).
    struct Aim: Equatable { var x: Double, y: Double, faceH: Double }
    /// Landscape frames (the 16:9 program, recordings) and portrait ones (9:16) hold still and reframe on their own: a
    /// portrait crop is a third as wide, so it reframes on smaller drifts.
    enum Shape: Hashable {
        case landscape, portrait
        init(_ aspect: Double) { self = aspect < 1 ? .portrait : .landscape }
    }
    /// One shape's dead zone: its aim, whether it follows the face now, and since when a small offset has lasted.
    struct Hold { var aim: Aim; var following = false; var calm = 0; var offSince: Double?; var heading = (x: 0.0, y: 0.0) }
    struct Key: Hashable { var shot: VirtualShot; var key: VirtualDrawKey }
    struct Cam {
        var cx: Spring, cy: Spring, h: Spring
        var heading = (x: 0.0, y: 0.0)       // which way each pan last went
        var lastT: Double                    // last grid step
        var lastSeen: Double                 // last drawn
        var last: VirtualView?
        var heldSince: Double?               // the shot was withdrawn while drawn: its last view holds since
    }

    private var geometry: Geometry?
    private var plans: [VirtualShot: ShotPlan] = [:]
    // Tracking.
    private var tracked: CGRect?             // the presenter's face, last raw box
    private var trackedAt = -1e9
    private var others: [(box: CGRect, at: Double)] = []   // faces seen beside the presenter, followed while in view
    private var newcomer: (box: CGRect, since: Double)?    // the only new face in view since the presenter went
    private var recent: [CGRect] = []        // last 3 raw boxes of the followed face
    private var trail: [(at: Double, x: Double, y: Double)] = []   // last 4 raw eye points of the followed face
    private var walk = 0.0                   // which way the presenter walks across: 1, -1, or 0 when they don't
    private var walkX = 0.0                  // where the walk last put the face's centre (short of the newest reading)
    private var smooth: CGRect?
    private var heights: [Double] = []       // last 15 raw face heights, camera units
    private var locked: Double?              // face height the plan is built on, camera units
    private var driftSince: Double?
    // Dead zone, per frame shape.
    private var holds: [Shape: Hold] = [:]
    private var lastSample = -1e9
    private var lastSeen = -1e9              // the presenter's face, or a body where it was
    public private(set) var yaw: Double?
    private var cams: [Key: Cam] = [:]

    public init() {}

    // MARK: Inputs

    /// The camera's picture size in pixels, the marked frame's output size on each canvas (16:9 defaults to the
    /// full 1920×1080), which shots are on, the area of the picture the frame shows (its Layer › Crop, top-left 0...1)
    /// and whether the frame is rotated. Rebuilds the shot plan at once when anything changed.
    public mutating func setGeometry(camera: CGSize, frames: [CanvasKind: CGSize], shots: VirtualShots,
                                     shown: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), turned: Bool = false) {
        var area = shown.standardized.intersection(Geometry.whole)
        if area.isNull || area.width < 0.01 || area.height < 0.01 { area = Geometry.whole }
        let g = Geometry(camera: camera, frames: frames, shots: shots, shown: area, turned: turned)
        guard g != geometry else { return }
        geometry = g
        replan()
    }

    public mutating func ingest(_ sample: FaceSample) {
        guard sample.at >= lastSample else { return }
        lastSample = sample.at
        // Faces and bodies the frame doesn't show (cut off by its Layer › Crop) aren't there.
        var s = sample
        if let g = geometry, g.shown != Geometry.whole {
            s.boxes = sample.boxes.filter(g.shows)
            s.bodies = sample.bodies.filter(g.shows)
            if s.boxes.first != sample.boxes.first { s.yaw = nil }
        }
        let followed = follow(s.boxes, at: s.at)
        // The presenter was seen: their face, or a body with no face in it where their face was (turned away,
        // looking down). Anyone else's face or body isn't them.
        if followed != nil || bodyAtFace(s) { lastSeen = s.at; newcomer = nil }
        guard let box = followed else { return }
        yaw = s.yaw
        // Median of the last 3 boxes, then an exponential average: quick for the centre, slow for the size.
        recent.append(box)
        if recent.count > 3 { recent.removeFirst() }
        trail.append((s.at, box.midX, Self.eyeY(box)))
        if trail.count > 4 { trail.removeFirst() }
        let m = CGRect(x: 0, y: 0, width: Self.median(recent.map { Double($0.width) }), height: Self.median(recent.map { Double($0.height) }))
        let mc = CGPoint(x: Self.median(recent.map { Double($0.midX) }), y: Self.median(recent.map { Double($0.midY) }))
        if let p = smooth {
            let cx = p.midX + 0.5 * (mc.x - p.midX), cy = p.midY + 0.5 * (mc.y - p.midY)
            let w = p.width + 0.2 * (m.width - p.width), h = p.height + 0.2 * (m.height - p.height)
            smooth = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        } else {
            smooth = CGRect(x: mc.x - m.width / 2, y: mc.y - m.height / 2, width: m.width, height: m.height)
        }
        lockSize(box.height, at: s.at)
        moveAim(at: s.at)
    }

    /// Forget who is followed (a scripted test face starts or stops): the next face is the presenter at once, and
    /// readings taken before now are dropped.
    public mutating func refollow(at t: Double) {
        tracked = nil; trackedAt = -1e9; others = []; newcomer = nil
        lastSample = max(lastSample, t)
    }

    // MARK: Outputs

    public var plan: [VirtualShot: ShotPlan] { plans }
    public func plan(_ s: VirtualShot) -> ShotPlan { plans[s] ?? .none(Self.waiting) }
    /// The followed face, smoothed (camera picture, top-left, 0...1).
    public var face: CGRect? { smooth }
    /// The followed face's last reading as Vision saw it, and its picture's host time (`angle-trace`).
    public var reading: (box: CGRect, at: Double)? { tracked.map { ($0, trackedAt) } }
    /// Face height ÷ the wide's visible height that the plan is built on.
    public var lockedFace: Double? { geometry.flatMap { g in locked.map { $0 / g.wideShown } } }

    /// Usable on air: offered, the presenter seen in the last 1.5 s, and not pushed off them by the picture's edge.
    public func usable(_ s: VirtualShot, now: Double) -> Bool {
        guard plans[s]?.available == true, now - lastSeen <= Self.lostAfter, let face = smooth, let g = geometry,
              let t = target(s, aspect: g.frame16.aspect) else { return false }
        let seen = face.intersection(g.shown)
        return t.offset <= 0.25 && !seen.isNull && t.rect.insetBy(dx: -1e-9, dy: -1e-9).contains(seen)
    }
    /// The presenter (their face, or a body where it was) was seen in the last 1.5 s.
    public func seen(now: Double) -> Bool { now - lastSeen <= Self.lostAfter }
    /// The crop's 16:9 framing is pushed off the presenter by the picture's edge.
    public func edgeLimited(_ s: VirtualShot) -> Bool {
        target(s, aspect: geometry?.frame16.aspect ?? 16.0 / 9).map { $0.offset > 0.15 } ?? false
    }
    /// Where a cut to this shot would land, with no glide: for tiles and the AI's pictures.
    public func previewRect(_ s: VirtualShot, aspect: Double) -> CGRect? { target(s, aspect: aspect)?.rect }
    /// Like `view` but with no glide and no state: the target, or the centred crop before any face.
    public func preview(_ s: VirtualShot, aspect: Double) -> VirtualView? {
        guard let g = geometry, g.camera.width > 0, g.camera.height > 0 else { return nil }
        guard holds[Shape(aspect)] != nil else { return waitingView(s, aspect: aspect, g: g) }
        guard let p = plans[s], p.available, let to = target(s, aspect: aspect) else { return nil }
        return VirtualView(rect: to.rect, zoom: g.wideShown / max(1e-6, to.rect.height), edgeLimited: to.offset > 0.15)
    }

    /// The crop to draw for `key` at host time `t`, for a frame of `aspect` (width ÷ height). Nil when the shot isn't
    /// offered (draw the whole picture). Before any face, a centred crop at the shot's usual zoom.
    public mutating func view(_ s: VirtualShot, key: VirtualDrawKey, aspect: Double, t: Double) -> VirtualView? {
        guard let g = geometry, g.camera.width > 0, g.camera.height > 0 else { return nil }
        let shape = Shape(aspect)
        guard holds[shape] != nil else { return waitingView(s, aspect: aspect, g: g) }
        let k = Key(shot: s, key: key)
        guard let plan = plans[s], plan.available else { return withdrawn(k, t: t) }
        var cam: Cam
        if let c = cams[k], t - c.lastSeen <= Self.snapAfter {
            // Never step back in time: a snapshot may have drawn a later moment than this frame.
            if t <= c.lastSeen, let last = c.last { return last }
            cam = c
            cam.heldSince = nil
        } else {
            // Not drawn for a while (a cut): start exactly on target, aimed at where the face is now (led, and still
            // following, while the presenter walks).
            if let f = smooth {
                let l = lead()
                holds[shape] = Hold(aim: Aim(x: f.midX + l.x, y: Self.eyeY(f) + l.y, faceH: f.height), following: walk != 0)
            }
            guard let start = target(s, aspect: aspect) else { return nil }
            cam = Cam(cx: Spring(start.center.x), cy: Spring(start.center.y), h: Spring(plan.height),
                      lastT: (t / Spring.step).rounded(.down) * Spring.step, lastSeen: t)
        }
        guard let to = target(s, aspect: aspect) else { return nil }
        while cam.lastT + Spring.step <= t {
            let r = Self.rect(cx: cam.cx.value, cy: cam.cy.value, h: cam.h.value, aspect: aspect, g: g, clamp: false)
            // Pans are capped in the crop's width in a landscape frame, so a narrow portrait crop keeps up with the
            // presenter as the landscape one does.
            let w = Self.rect(cx: 0.5, cy: 0.5, h: cam.h.value, aspect: max(aspect, g.frame16.aspect), g: g, clamp: false).width
            // A target a little behind the way the crop was going (the lead fading as a walk ends, a reading's noise)
            // is where it already is: the crop comes to rest without running back.
            let band = noiseBand
            // Keep-in zone: with the face where the walk last put it near the side of the crop it walks towards, the
            // pan answers faster (same caps).
            let quick = smooth.map { b in
                walk > 0 ? r.maxX - (walkX + b.width / 2) < Self.keepIn * r.width : walk < 0 && (walkX - b.width / 2) - r.minX < Self.keepIn * r.width
            } ?? false
            Self.glide(&cam.cx, to: to.center.x, size: w, heading: &cam.heading.x, band: band.x, quick: quick)
            Self.glide(&cam.cy, to: to.center.y, size: r.height, heading: &cam.heading.y, band: band.y)
            cam.h.step(toward: plan.height, response: Self.zoomResponse)
            cam.lastT += Spring.step
        }
        let dt = t - cam.lastT
        let h = cam.h.ahead(dt)
        let rect = Self.rect(cx: cam.cx.ahead(dt), cy: cam.cy.ahead(dt), h: h, aspect: aspect, g: g)
        let v = VirtualView(rect: rect, zoom: g.wideShown / max(1e-6, rect.height), edgeLimited: to.offset > 0.15)
        cam.lastSeen = t
        cam.last = v
        cams[k] = cam
        return v
    }

    /// A shot withdrawn by a re-plan (a size change) while drawn in the last 0.5 s keeps its last view, at most 1 s,
    /// until the planner or the stall check cuts away: not the camera's whole picture under the shot's name.
    private mutating func withdrawn(_ k: Key, t: Double) -> VirtualView? {
        guard var c = cams[k], let last = c.last else { return nil }
        if c.heldSince == nil {
            guard t - c.lastSeen <= Self.snapAfter else { return nil }
            c.heldSince = t
            cams[k] = c
        }
        return t - (c.heldSince ?? t) <= Self.holdWithdrawn + 1e-9 ? last : nil
    }

    /// Before any face: a centred crop at the shot's usual zoom (nil if the shot is off or can't be made).
    private func waitingView(_ s: VirtualShot, aspect: Double, g: Geometry) -> VirtualView? {
        guard plans[s]?.reason == Self.waiting else { return nil }
        let z = s == .medium ? Self.minStep : Self.minStep * Self.minStep
        return VirtualView(rect: Self.rect(cx: g.shown.midX, cy: g.shown.midY, h: g.wideShown / z, aspect: aspect, g: g), zoom: z, edgeLimited: false)
    }

    // MARK: Shot plan

    public static let waiting = "Looking for you…"
    static let rotated = "The frame is rotated: set Layer › Rotation to 0°"

    private mutating func replan() {
        plans = [:]
        guard let g = geometry, g.camera.width > 0, g.camera.height > 0 else {
            for s in VirtualShot.allCases { plans[s] = .none("Waiting for the camera picture") }
            return
        }
        // A rotated frame would turn the crops with it: the eye line and the head-top guard would land on its side.
        if g.turned {
            for s in VirtualShot.allCases { plans[s] = g.shots[s] ? .none(Self.rotated) : .none("Turned off") }
            return
        }
        guard let lockH = locked else {
            for s in VirtualShot.allCases { plans[s] = g.shots[s] ? .none(Self.waiting) : .none("Turned off") }
            return
        }
        let f = lockH / g.wideShown
        if f >= Self.closeFrom {
            for s in VirtualShot.allCases { plans[s] = .none("Your camera already shows a close-up") }
            return
        }
        // The tightest zoom the 16:9 frame allows before the camera is enlarged more than 2×.
        let frameH = g.frame16.height
        let zSharp = Self.maxEnlargement * g.wideShown * g.camera.height / max(1, frameH)
        func limited(_ want: Double) -> (z: Double, why: String?) {
            let z = min(want, Self.maxZoom, zSharp)
            if z >= want - 1e-9 { return (want, nil) }
            if zSharp < min(want, Self.maxZoom) {
                let lines = Int(g.camera.height.rounded())
                return (z, lines < 1000 ? "This camera sends \(lines)p" : lines < 2000 ? "needs a 4K camera" : "Sit closer to the camera")
            }
            return (z, "Sit closer to the camera")
        }
        // A shot just past sharp (at most 10% tighter) is loosened to sharp, so a face a few pixels smaller than usual
        // doesn't cost the sharp grade.
        let zCrisp = CropGrade.sharpUpTo * g.wideShown * g.camera.height / max(1, frameH)
        func crisp(_ z: Double, atLeast low: Double) -> Double { z > zCrisp && z <= 1.1 * zCrisp && zCrisp >= low - 1e-9 ? zCrisp : z }
        var zMedium: Double?
        if g.shots.medium {
            var want = max(Self.minStep, VirtualShot.medium.faceTarget / f)
            // Room for the close-up: when the cap would leave it less than 1.4× tighter than this medium, the medium
            // loosens (never below 1.4×), as long as the close-up at the cap still frames a close-up.
            let closeCap = min(Self.maxZoom, zSharp)
            if g.shots.close, f * closeCap >= Self.closeFrom, closeCap >= Self.minStep * Self.minStep, want * Self.minStep > closeCap {
                want = closeCap / Self.minStep
            }
            let (zLimited, why) = limited(want)
            let z = crisp(zLimited, atLeast: Self.minStep)
            if z < Self.minStep - 1e-9 { plans[.medium] = make(.medium, z: z, f: f, g: g, reason: Self.reason(why, .medium)) }
            else if f * z >= Self.closeFrom { plans[.medium] = make(.medium, z: z, f: f, g: g, reason: "Your camera already shows a medium shot") }
            else { plans[.medium] = make(.medium, z: z, f: f, g: g, reason: nil); zMedium = z }
        } else { plans[.medium] = .none("Turned off") }
        if g.shots.close {
            let floor = Self.minStep * (zMedium ?? 1)
            let (zLimited, why) = limited(max(VirtualShot.close.faceTarget / f, floor))
            let z = crisp(zLimited, atLeast: max(floor, Self.closeFrom / f))
            if f * z < Self.closeFrom - 1e-9 || z < floor - 1e-9 { plans[.close] = make(.close, z: z, f: f, g: g, reason: Self.reason(why ?? "Sit closer to the camera", .close)) }
            else { plans[.close] = make(.close, z: z, f: f, g: g, reason: nil) }
        } else { plans[.close] = .none("Turned off") }
    }

    private static func reason(_ why: String?, _ s: VirtualShot) -> String {
        guard let why else { return "Not available" }
        return why.hasPrefix("needs") ? "\(s.title) \(why)" : why
    }

    private func make(_ s: VirtualShot, z: Double, f: Double, g: Geometry, reason: String?) -> ShotPlan {
        let h = g.wideShown / z
        var e: [CanvasKind: Double] = [:]
        for (c, size) in g.frames.merging([.horizontal: g.frame16], uniquingKeysWith: { a, _ in a }) {
            let r = Self.rect(cx: 0.5, cy: 0.5, h: h, aspect: size.width / max(1, size.height), g: g)
            e[c] = size.height / max(1e-6, r.height * g.camera.height)
        }
        let e16 = e[.horizontal] ?? 1
        return ShotPlan(available: reason == nil, reason: reason, zoom: z, height: h, faceInCrop: f * z, enlargement: e,
                        grade: CropGrade(enlargement: e16))
    }

    // MARK: Tracking and the size lock

    /// The presenter's face in this sample: the one overlapping their last box, or else the nearest within half a face
    /// width (a whole one once they've been gone a second), or a lone new face of about the same size within 3 face
    /// widths (a quick move). A face seen beside the presenter is never taken, whatever its size; once the presenter
    /// has gone, a new face takes over after 3 s as the only one. Before any presenter, the biggest face.
    private mutating func follow(_ boxes: [CGRect], at t: Double) -> CGRect? {
        others.removeAll { t - $0.at > 10 }
        guard let last = tracked else {
            guard let b = boxes.max(by: { $0.height < $1.height }) else { return nil }
            return take(b, boxes, at: t)
        }
        let gone = t - trackedAt > 1.0
        let fresh = boxes.filter { b in !others.contains { Self.near($0.box, b) } }
        // Gone a second: someone seen beside them who moves to their place still isn't them.
        let pool = gone ? fresh : boxes
        var match = pool.filter { Self.iou($0, last) > 0.3 }.max { Self.iou($0, last) < Self.iou($1, last) }
        if match == nil {
            let reach = (gone ? 1.0 : 0.5) * last.width
            match = pool.filter { Self.distance($0, last) < reach }.min { Self.distance($0, last) < Self.distance($1, last) }
        }
        if match == nil, !gone, fresh.count == 1, let only = fresh.first,
           max(only.height / last.height, last.height / only.height) < 1.3, Self.distance(only, last) < 3 * last.width {
            match = only
        }
        if let m = match {
            tracked = m; trackedAt = t; newcomer = nil
            note(boxes, besides: m, at: t)
            return m
        }
        note(boxes, besides: nil, at: t)
        // A new face alone in view (faces seen beside the presenter aside) for 3 s, with the presenter gone, takes over.
        if fresh.count == 1, let b = fresh.first {
            if let n = newcomer, Self.near(n.box, b) {
                newcomer = (b, n.since)
                if t - n.since >= Self.newcomerAfter - 1e-9 { return take(b, boxes, at: t) }
            } else { newcomer = (b, t) }
        } else { newcomer = nil }
        return nil
    }

    private mutating func take(_ b: CGRect, _ boxes: [CGRect], at t: Double) -> CGRect {
        tracked = b; trackedAt = t; newcomer = nil
        recent = []; trail = []; walk = 0; smooth = nil
        note(boxes, besides: b, at: t)
        return b
    }

    /// Keeps up with the faces seen beside the presenter as they move; with the presenter in view, any other face
    /// joins them.
    private mutating func note(_ boxes: [CGRect], besides m: CGRect?, at t: Double) {
        for b in boxes where b != m {
            if let i = others.firstIndex(where: { Self.near($0.box, b) }) { others[i] = (b, t) }
            else if m != nil { others.append((b, t)) }
        }
        if let m { others.removeAll { Self.iou($0.box, m) > 0.3 } }
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool { iou(a, b) > 0.3 || distance(a, b) < 0.5 * a.width }

    /// An upper body with no face in it covers the followed face (across, and from a face height above to below it):
    /// Vision's torso box may start at the shoulders.
    private func bodyAtFace(_ s: FaceSample) -> Bool {
        guard let f = smooth else { return false }
        return s.bodies.contains { b in
            abs(b.midX - f.midX) < b.width / 2 && b.minY <= f.maxY + f.height && b.maxY >= f.minY
                && !s.boxes.contains { b.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        }
    }

    /// The plan is rebuilt only when the face size (median of 3 s) is off by more than 20% for 3 s.
    private mutating func lockSize(_ h: Double, at t: Double) {
        heights.append(h)
        if heights.count > 15 { heights.removeFirst() }
        let med = Self.median(heights)
        guard let l = locked, l > 0, med > 0 else { locked = med; replan(); return }
        if abs(log(med / l)) > log(1.2) {
            let since = driftSince ?? t
            driftSince = since
            if t - since >= 3 - 1e-9 { locked = med; driftSince = nil; replan() }
        } else { driftSince = nil }
    }

    // MARK: Dead zone

    /// Hold, then reframe: the aim moves once the eyes drift more than 0.06 of the crop's long side (0.05 of its
    /// height), then follows each sample until the face has settled. A smaller offset that lasts 4 s re-centres.
    private mutating func moveAim(at t: Double) {
        guard let f = smooth else { return }
        let l = lead()
        let e = Aim(x: f.midX + l.x, y: Self.eyeY(f) + l.y, faceH: f.height)
        // Measured in the tightest offered crop of each shape, so a close-up never drifts more than its own allowance:
        // its width in a landscape frame, its height in a portrait one (both shapes share the crop's height).
        let h = VirtualShot.allCases.reversed().compactMap { plans[$0]?.available == true ? plans[$0]!.height : nil }.first
        guard let g = geometry, let h else { holds = [.landscape: Hold(aim: e), .portrait: Hold(aim: e)]; return }
        for shape in [Shape.landscape, .portrait] {
            guard var hold = holds[shape] else { holds[shape] = Hold(aim: e); continue }
            let r = Self.rect(cx: 0.5, cy: 0.5, h: h, aspect: shape == .landscape ? g.frame16.aspect : g.portraitAspect, g: g)
            let long = max(r.width, r.height * g.camera.height / max(1, g.camera.width))
            let ex = abs(e.x - hold.aim.x) / long, ey = abs(e.y - hold.aim.y) / r.height
            if hold.following {
                // As a walk ends the lead fades before the smoothed face arrives: the aim doesn't step back while the
                // face, as last seen, is still at or past it (give or take a reading's noise).
                var aim = e
                if let n = trail.last {
                    let dx = e.x - hold.aim.x, dy = e.y - hold.aim.y, band = noiseBand
                    if dx * hold.heading.x < 0 && (n.x - hold.aim.x) * hold.heading.x >= -band.x { aim.x = hold.aim.x } else if dx != 0 { hold.heading.x = dx > 0 ? 1 : -1 }
                    if dy * hold.heading.y < 0 && (n.y - hold.aim.y) * hold.heading.y >= -band.y { aim.y = hold.aim.y } else if dy != 0 { hold.heading.y = dy > 0 ? 1 : -1 }
                }
                hold.aim = aim
                hold.calm = ex < 0.015 && ey < 0.015 ? hold.calm + 1 : 0
                if hold.calm >= 2 { hold.following = false; hold.calm = 0 }
            } else if ex > 0.06 || ey > 0.05 {
                hold = Hold(aim: e, following: true)
            } else if max(ex, ey) >= 0.02 {
                let since = hold.offSince ?? t
                hold.offSince = since
                if t - since >= 4 - 1e-9 { hold.aim = e; hold.offSince = nil }
            } else { hold.offSince = nil }
            holds[shape] = hold
        }
    }

    /// While the presenter walks: their speed (a straight line through the last 4 readings) times `leadTime`, held
    /// short of the newest reading, so the aim never passes where the face was last seen.
    private mutating func lead() -> (x: Double, y: Double) {
        walk = 0
        guard trail.count >= 3, let n = trail.last, let f = smooth, n.at - trail[0].at >= 0.3 else { return (0, 0) }
        let ts = trail.map(\.at), mt = ts.reduce(0, +) / Double(ts.count)
        let tt = ts.map { ($0 - mt) * ($0 - mt) }.reduce(0, +)
        /// The speed (0 below a walk) and where the line puts the face at the newest reading.
        func line(_ vs: [Double]) -> (v: Double, at: Double) {
            let mv = vs.reduce(0, +) / Double(vs.count)
            let v = zip(ts, vs).map { ($0 - mt) * ($1 - mv) }.reduce(0, +) / max(1e-9, tt)
            return (abs(v) >= Self.walkFrom ? v : 0, mv + v * (n.at - mt))
        }
        // Held short of both the newest reading and the line's point for it: a noisy last reading isn't chased.
        func one(_ l: (v: Double, at: Double), newest: Double, from now: Double) -> Double {
            let d = l.v > 0 ? min(newest, l.at) - now : max(newest, l.at) - now
            return min(max(l.v * Self.leadTime, min(0, d)), max(0, d))
        }
        let lx = line(trail.map(\.x)), ly = line(trail.map(\.y))
        walk = lx.v > 0 ? 1 : lx.v < 0 ? -1 : 0
        walkX = lx.v > 0 ? min(n.x, lx.at) : max(n.x, lx.at)
        return (one(lx, newest: n.x, from: f.midX), one(ly, newest: n.y, from: Self.eyeY(f)))
    }

    // MARK: Composition

    struct Target { var rect: CGRect; var center: CGPoint; var offset: Double }

    /// Where a shot should sit for a frame of `aspect`: eyes on the shot's eye line, the head clear of the top edge,
    /// inside the picture. `offset` is how far the picture's edge pushed it, in crop widths (or heights).
    private func target(_ s: VirtualShot, aspect: Double) -> Target? {
        guard let g = geometry, let a = holds[Shape(aspect)]?.aim, let p = plans[s], p.available else { return nil }
        let r0 = Self.rect(cx: 0.5, cy: 0.5, h: p.height, aspect: aspect, g: g)
        let W = r0.width, H = r0.height
        let x = a.x + Self.leadRoom * W * (yaw.map { min(max($0 / 30, -1), 1) } ?? 0)
        var y = a.y - s.eyeLine(aspect: aspect) * H + H / 2
        // Head-top guard: the crown (about 0.75 of a face height above the eyes) stays below the top edge.
        let crown = a.y - 0.75 * a.faceH
        y = min(y, crown - s.crownGuard * H + H / 2)
        let a0 = g.shown
        let c = CGPoint(x: min(max(x, a0.minX + W / 2), a0.maxX - W / 2), y: min(max(y, a0.minY + H / 2), a0.maxY - H / 2))
        let off = max(abs(c.x - x) / W, abs(c.y - y) / H)
        return Target(rect: CGRect(x: c.x - W / 2, y: c.y - H / 2, width: W, height: H), center: c, offset: off)
    }

    /// A crop of height `h` (camera heights) shaped like the frame, centred where asked; inside what the frame shows
    /// (as wide as that at most).
    static func rect(cx: Double, cy: Double, h: Double, aspect: Double, g: Geometry, clamp: Bool = true) -> CGRect {
        let a = g.shown
        var H = h, W = h * g.camera.height * aspect / max(1, g.camera.width)
        if W > a.width { W = a.width; H = a.width * g.camera.width / (aspect * max(1, g.camera.height)) }
        H = min(H, a.height)
        var x = cx, y = cy
        if clamp { x = min(max(x, a.minX + W / 2), a.maxX - W / 2); y = min(max(y, a.minY + H / 2), a.maxY - H / 2) }
        return CGRect(x: x - W / 2, y: y - H / 2, width: W, height: H)
    }

    /// One grid step of a pan: the spring, then brakes so it stops on target, then the acceleration and speed caps.
    static func glide(_ s: inout Spring, to goal: Double, size: Double, heading: inout Double, band: Double, quick: Bool = false) {
        let x0 = s.value, v0 = s.velocity
        let back = (goal - x0) * heading
        let target = back < 0 && -back < band ? x0 + v0 * v0 / (2 * maxAccel * size) * heading : goal
        // A pan that's really moving sets the heading (not the last creep as it settles).
        defer { if abs(s.velocity) > 0.05 * size { heading = s.velocity > 0 ? 1 : -1 } }
        let vMax = maxSpeed * size, aMax = maxAccel * size, dv = aMax * Spring.step
        s.step(toward: target, response: quick ? quickResponse : panResponse)
        var v = s.velocity
        let e = target - x0
        if v * e > 0 { v = (v > 0 ? 1 : -1) * min(abs(v), (2 * aMax * abs(e)).squareRoot()) }
        v = min(max(v, v0 - dv), v0 + dv)
        v = min(max(v, -vMax), vMax)
        s.velocity = v
        s.value = x0 + v * Spring.step
    }

    /// About twice how far one reading strays from the next (±0.4% of the picture for a face of 0.12): a step back
    /// smaller than this is noise, not the presenter turning round.
    private var noiseBand: (x: Double, y: Double) {
        guard let f = smooth else { return (0, 0) }
        return (0.12 * f.width, 0.07 * f.height)
    }

    // The eyes sit about 40% down Vision's face box.
    static func eyeY(_ f: CGRect) -> Double { f.minY + 0.40 * f.height }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let inter = i.width * i.height
        return inter / max(1e-9, a.width * a.height + b.width * b.height - inter)
    }
    static func distance(_ a: CGRect, _ b: CGRect) -> Double { hypot(a.midX - b.midX, a.midY - b.midY) }
}

fileprivate extension CGSize {
    var aspect: Double { width / max(1, height) }
}
