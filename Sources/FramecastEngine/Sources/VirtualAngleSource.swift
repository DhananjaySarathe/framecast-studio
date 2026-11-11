import Foundation
import CoreImage
import CoreMedia

/// Who a derived picture is drawn for: the program on air (and anything that glides), a per-angle recording, or a
/// still (tiles, thumbnails, the AI's pictures), which shows where a cut would land and keeps no state.
public enum DeriveRole: Sendable { case program, iso, preview }

/// A source whose picture is cut from another source's. The engine fetches the base's picture by its ID on every
/// frame, so a restarted camera or a privacy stand-in reaches the derived source at once.
public protocol DerivedVideoSource: VideoSource {
    var baseID: UUID { get }
    /// The picture to draw, made from the base's. `frame` is the layer's size in output pixels (nil for a plain
    /// still of the source). Called with the engine's lock held: it must never call the engine.
    func derive(_ base: CIImage, at t: CMTime, canvas: CanvasKind, frame: CGSize?, role: DeriveRole) -> CIImage
}

/// One crop drawn on air or into a recording (`angle-trace`).
public struct VirtualTraceEntry: Sendable {
    public var t: Double
    public var shot: VirtualShot
    public var key: VirtualDrawKey
    /// The camera picture's area, top-left origin, 0...1.
    public var rect: CGRect
    public var zoom: Double
    /// The followed face, smoothed (nil before any).
    public var face: CGRect?
    /// The followed face's last reading, unsmoothed, and the host time of its picture (nil before any).
    public var raw: CGRect?
    public var rawAt: Double?
}

/// The crops of one camera: one framer for its medium and close-up, so both follow the same presenter with the same
/// aim. Face samples come from the main thread; crops are asked for while the engine draws. Its own lock guards the
/// framer, and it never calls the engine.
public final class VirtualRig: @unchecked Sendable {
    public let cameraID: UUID
    private let lock = NSLock()
    private var framer = VirtualFramer()
    private var camera: CGSize?
    private var picture: CGSize?                       // the size the camera last sent, once drawn
    private var asked: CGSize?                         // the size the camera was last configured for
    private var frames: [CanvasKind: CGSize] = [:]
    private var shots = VirtualShots()
    private var shown = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var turned = false
    private var crops: [VirtualShot: CGSize] = [:]     // last landscape crop, camera pixels
    private var lastISO: [VirtualShot: CGRect] = [:]    // last offered framing drawn into each shot's own file
    private var trace: [VirtualTraceEntry]?
    private var traceLimit = 0

    public init(cameraID: UUID) { self.cameraID = cameraID }

    /// The camera's picture size, the marked frame's output size on each canvas, which shots are on, the area of the
    /// picture the frame shows (its Layer › Crop, top-left 0...1) and whether the frame is rotated. The size the
    /// camera last sent wins over `camera` (its configured size), which only stands in before the first picture, and
    /// again after the camera is asked for another size (Use 4K, Back to 1080p) until its next picture is drawn.
    public func setGeometry(camera: CGSize, frames: [CanvasKind: CGSize], shots: VirtualShots,
                            shown: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), turned: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if camera != asked { asked = camera; picture = nil }
        let size = picture ?? camera
        self.camera = size; self.frames = frames; self.shots = shots; self.shown = shown; self.turned = turned
        framer.setGeometry(camera: size, frames: frames, shots: shots, shown: shown, turned: turned)
    }
    public func setFace(_ s: FaceSample) { lock.lock(); framer.ingest(s); lock.unlock() }
    /// A scripted test face starts or stops: the next face is the presenter at once.
    public func refollow(at t: Double) { lock.lock(); framer.refollow(at: t); lock.unlock() }

    public func status(_ s: VirtualShot) -> ShotPlan { lock.lock(); defer { lock.unlock() }; return framer.plan(s) }
    public func edgeLimited(_ s: VirtualShot) -> Bool { lock.lock(); defer { lock.unlock() }; return framer.edgeLimited(s) }
    public func usable(_ s: VirtualShot, now: Double) -> Bool { lock.lock(); defer { lock.unlock() }; return framer.usable(s, now: now) }
    /// The presenter (their face, or a body where it was) was seen in the last 1.5 s.
    public func seen(now: Double) -> Bool { lock.lock(); defer { lock.unlock() }; return framer.seen(now: now) }
    /// Where a cut to this shot would land (tiles, the AI's pictures).
    public func previewRect(_ s: VirtualShot, aspect: Double) -> CGRect? { lock.lock(); defer { lock.unlock() }; return framer.previewRect(s, aspect: aspect) }
    public var face: CGRect? { lock.lock(); defer { lock.unlock() }; return framer.face }
    public var yaw: Double? { lock.lock(); defer { lock.unlock() }; return framer.yaw }
    public var lockedFace: Double? { lock.lock(); defer { lock.unlock() }; return framer.lockedFace }

    /// Keeps every crop drawn on air or into a recording, up to `limit` entries, until `stopTrace`.
    public func startTrace(limit: Int = 100_000) { lock.lock(); trace = []; traceLimit = limit; lock.unlock() }
    public func stopTrace() -> [VirtualTraceEntry] { lock.lock(); defer { lock.unlock() }; let t = trace ?? []; trace = nil; return t }

    /// The last landscape crop of a shot in camera pixels (the camera's size before one was drawn).
    func cropSize(_ s: VirtualShot) -> CGSize {
        lock.lock(); defer { lock.unlock() }
        return crops[s] ?? camera ?? CGSize(width: 1920, height: 1080)
    }
    /// The marked frame's shape on 16:9, for stills that have no frame of their own.
    var landscapeAspect: Double {
        lock.lock(); defer { lock.unlock() }
        let f = frames[.horizontal] ?? CGSize(width: 1920, height: 1080)
        return f.width / max(1, f.height)
    }

    /// The area of the camera picture to draw (top-left, 0...1), or nil for the whole picture. `picture` is the
    /// size the camera actually sends: a restarted or swapped camera is re-planned at once.
    func crop(_ s: VirtualShot, role: DeriveRole, canvas: CanvasKind, aspect: Double, picture: CGSize, t: Double) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        self.picture = picture
        if camera != picture {
            camera = picture
            framer.setGeometry(camera: picture, frames: frames, shots: shots, shown: shown, turned: turned)
        }
        let key: VirtualDrawKey = role == .iso ? .iso : .program(canvas)
        guard let v = role == .preview ? framer.preview(s, aspect: aspect) : framer.view(s, key: key, aspect: aspect, t: t) else {
            // A shot's file keeps its last framing when a re-plan drops the shot mid-take; the whole picture only if
            // it never had one.
            return role == .iso ? lastISO[s] : nil
        }
        if role == .iso, framer.plan(s).available { lastISO[s] = v.rect }
        if aspect >= 1 { crops[s] = CGSize(width: v.rect.width * picture.width, height: v.rect.height * picture.height) }
        if role != .preview, let n = trace?.count, n < traceLimit {
            let r = framer.reading
            trace?.append(VirtualTraceEntry(t: t, shot: s, key: key, rect: v.rect, zoom: v.zoom, face: framer.face, raw: r?.box, rawAt: r?.at))
        }
        return v.rect
    }
}

/// A medium or a close-up cut from a camera's picture, framed on the presenter. It has its own ID, so the angle keys,
/// the shuffle, tiles and recordings treat it as an angle; the engine draws it from the camera by `baseID`.
public final class VirtualAngleSource: DerivedVideoSource, @unchecked Sendable {
    public let id: UUID
    public let shot: VirtualShot
    public let rig: VirtualRig
    public var baseID: UUID { rig.cameraID }
    /// The engine reports the camera's state for a crop.
    public var state: SourceState { .running }
    /// The last 16:9 crop in camera pixels.
    public var nativeSize: CGSize { rig.cropSize(shot) }

    public init(id: UUID = UUID(), shot: VirtualShot, rig: VirtualRig) { self.id = id; self.shot = shot; self.rig = rig }

    /// Only drawn through the engine, which hands over the camera's picture.
    public func image(at time: CMTime) -> CIImage? { nil }
    /// A crop never starts or stops its camera.
    public func start() {}
    public func stop() {}

    public func derive(_ base: CIImage, at t: CMTime, canvas: CanvasKind, frame: CGSize?, role: DeriveRole) -> CIImage {
        let pic = base.transformed(by: CGAffineTransform(translationX: -base.extent.minX, y: -base.extent.minY))
        let size = pic.extent.size
        guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else { return pic }
        let aspect = frame.map { $0.width / max(1, $0.height) } ?? rig.landscapeAspect
        // Not offered (or no geometry yet): the camera's whole picture.
        guard let r = rig.crop(shot, role: role, canvas: canvas, aspect: aspect, picture: size, t: CMTimeGetSeconds(t)) else { return pic }
        // Camera pixels; Core Image's origin is bottom-left.
        let px = CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
        guard px.width >= 1, px.height >= 1 else { return pic }
        // Sample from a picture that runs on past its edges, so no output pixel blends with empty space.
        let moved = pic.clampedToExtent().transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY))
        guard let frame, frame.width >= 1, frame.height >= 1 else {
            return moved.cropped(to: CGRect(x: 0, y: 0, width: max(1, px.width.rounded()), height: max(1, px.height.rounded())))
        }
        // Scaled here to the frame's own pixels and cut on whole pixels: the compositor then draws it 1:1, and the
        // crop's edge never lands mid-pixel on the frame's edge (a seam on enlarged crops).
        let out = Self.outputSize(px.size, frame: frame)
        return moved.transformed(by: CGAffineTransform(scaleX: out.width / px.width, y: out.height / px.height))
            .cropped(to: CGRect(origin: .zero, size: out))
    }

    /// The crop filling the frame, in whole pixels: exactly the frame's size on any side within a pixel of it.
    static func outputSize(_ crop: CGSize, frame: CGSize) -> CGSize {
        let s = max(frame.width / crop.width, frame.height / crop.height)
        func side(_ v: CGFloat, _ f: CGFloat) -> CGFloat {
            let whole = (f - 0.01).rounded(.up)
            return abs(v - f) <= 1 ? whole : (v - 0.01).rounded(.up)
        }
        return CGSize(width: max(1, side(crop.width * s, frame.width)), height: max(1, side(crop.height * s, frame.height)))
    }
}
