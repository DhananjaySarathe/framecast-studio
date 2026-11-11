import Foundation
import Vision
import CoreGraphics
import FramecastEngine

/// What this Mac sees in one camera angle (Vision, on the Mac, a couple of times a second): where the presenter's
/// face is, which way it turns, and how tight the angle frames them. Free, private and live, so the shuffle knows
/// which angles show the presenter and which camera they're looking into without an AI key.
struct AngleSight: Equatable {
    /// The face (0…1, top-left, in the upright picture), when one is in view.
    var face: CGRect?
    /// Which way the face turns as this camera sees it, in degrees (0: straight at it).
    var yaw: Double?
    var pitch: Double?
    /// Last time a face or an upper body was in view (host seconds).
    var lastSeen: Double = -1e9
    /// Looking straight into this camera since (host seconds).
    var facingSince: Double?
    /// From the face's size in the frame the angle fills.
    var shot: AngleShot = .unknown
    /// Width over height of the picture.
    var aspect: Double = 16.0 / 9
    /// At least one look so far.
    var checked = false

    /// The presenter is in view (seen within the last 3 s).
    func inView(_ now: Double) -> Bool { now - lastSeen < 3 }
    /// Looking straight into this camera for most of a second.
    func facing(_ now: Double) -> Bool { facingSince.map { now - $0 >= 0.8 } ?? false }
}

/// One look at an angle: what Vision found in a small picture of it.
struct AngleReading {
    /// The biggest face.
    var face: CGRect?
    /// Every face found, biggest first (at most 3), for the crops that follow the presenter.
    var faces: [CGRect]
    var yaw: Double?
    var pitch: Double?
    var person: Bool
    var aspect: Double
    /// Host seconds when the picture was taken.
    var at: Double
    /// Every upper body found (0…1, top-left), for the crops: one with no face keeps them only where the face was.
    var bodies: [CGRect] = []
}

/// Looks at the angles off the main thread: a small picture of each (the Angles tiles) and, when asked, a face and
/// body check on it.
final class AngleWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "framecast.angle-watch", qos: .utility)
    private let lock = NSLock()
    private var running = false

    /// One pass over `angles` (id, engine source, picture size, whether to look for the presenter). Calls `done` on
    /// the main thread; skipped while a pass is running.
    func look(engine: Engine, angles: [(id: String, source: UUID, maxSide: CGFloat, read: Bool)],
              done: @escaping (_ pictures: [String: CGImage], _ readings: [String: AngleReading]) -> Void) {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in
            var pictures: [String: CGImage] = [:], readings: [String: AngleReading] = [:]
            for a in angles {
                let at = HostClock.seconds()
                guard let img = engine.sourceSnapshot(a.source, maxSide: a.maxSide) else { continue }
                pictures[a.id] = img
                if a.read { readings[a.id] = Self.read(img, at: at) }
            }
            self?.lock.lock(); self?.running = false; self?.lock.unlock()
            DispatchQueue.main.async { done(pictures, readings) }
        }
    }

    static func read(_ img: CGImage, at: Double) -> AngleReading {
        let faceReq = VNDetectFaceRectanglesRequest()
        faceReq.revision = VNDetectFaceRectanglesRequestRevision3
        let bodyReq = VNDetectHumanRectanglesRequest()
        bodyReq.upperBodyOnly = true
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([faceReq, bodyReq])
        let aspect = Double(img.width) / Double(max(1, img.height))
        // The biggest face is the presenter's.
        let found = (faceReq.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        // Vision: origin bottom-left.
        func topLeft(_ b: CGRect) -> CGRect { CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height) }
        let bodies = (bodyReq.results ?? []).map { topLeft($0.boundingBox) }
        guard let f = found.first else {
            return AngleReading(face: nil, faces: [], yaw: nil, pitch: nil, person: !bodies.isEmpty, aspect: aspect, at: at, bodies: bodies)
        }
        let deg = 180 / Double.pi
        return AngleReading(face: topLeft(f.boundingBox), faces: found.prefix(3).map { topLeft($0.boundingBox) },
                            yaw: f.yaw.map { $0.doubleValue * deg }, pitch: f.pitch.map { $0.doubleValue * deg },
                            person: true, aspect: aspect, at: at, bodies: bodies)
    }

    /// How tight a face of this height (fraction of the picture's height) frames the presenter in a frame of
    /// `frameAspect` that the picture fills (a tall picture loses its top and bottom in a wide frame).
    static func shot(faceHeight h: Double, pictureAspect: Double, frameAspect: Double) -> AngleShot {
        let shown = min(1, pictureAspect / max(0.1, frameAspect))
        let r = h / max(0.05, shown)
        if r >= 0.45 { return .extremeClose }
        if r >= 0.22 { return .close }
        if r >= 0.1 { return .medium }
        return .wide
    }
}
