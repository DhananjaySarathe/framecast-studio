import Foundation
import CoreMedia
import CoreImage
import CoreVideo
import AppKit

public enum HostClock {
    public static let clock = CMClockGetHostTimeClock()
    public static func now() -> CMTime { CMClockGetTime(clock) }
    public static func seconds() -> Double { CMTimeGetSeconds(now()) }
}

public enum SourceState: Equatable, Sendable {
    case starting
    case running
    case lost(String)        // was running, frames stopped (device unplugged, window closed)
    case failed(String)      // could not start (permission, missing device)
    case stopped
}

/// A producer of pictures for the compositor. Procedural sources draw for the exact render time, so test
/// patterns line up with the tone generator to the frame (used by A/V-sync tests).
public protocol VideoSource: AnyObject {
    var id: UUID { get }
    var state: SourceState { get }
    /// Natural size in pixels (used for aspect-correct fitting).
    var nativeSize: CGSize { get }
    /// The picture to draw for render time `time` (host clock), or nil if nothing has arrived yet.
    func image(at time: CMTime) -> CIImage?
    /// The picture for one canvas. Sources with separate 16:9 and 9:16 artwork override this.
    func image(at time: CMTime, canvas: CanvasKind) -> CIImage?
    func start()
    func stop()
}

public extension VideoSource {
    func image(at time: CMTime, canvas: CanvasKind) -> CIImage? { image(at: time) }
}

/// Thread-safe holder for the newest captured frame.
public final class FrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var pts = CMTime.invalid
    private var arrivedAt: Double = 0
    private var rotationDegrees = 0
    private var lagSeconds = 0.0
    public init() {}
    /// `rotation`: degrees clockwise the frame needs to stand upright (phones send portrait frames sideways).
    public func put(_ pb: CVPixelBuffer, pts: CMTime, rotation: Int = 0) {
        let now = HostClock.seconds()
        lock.lock()
        buffer = pb; self.pts = pts; arrivedAt = now; rotationDegrees = rotation
        // How long capture took to hand the frame over (camera timestamps are capture times on the host clock).
        if pts.isValid { let l = now - CMTimeGetSeconds(pts); if l >= 0 && l < 2 { lagSeconds = lagSeconds == 0 ? l : lagSeconds * 0.95 + l * 0.05 } }
        lock.unlock()
    }
    /// Degrees clockwise the newest frame needs to stand upright.
    public var rotation: Int { lock.lock(); defer { lock.unlock() }; return rotationDegrees }
    /// Average seconds between capture and arrival (0 for sources stamped on arrival).
    public var lag: Double { lock.lock(); defer { lock.unlock() }; return lagSeconds }
    public func get() -> (CVPixelBuffer, CMTime)? {
        lock.lock(); defer { lock.unlock() }
        guard let b = buffer else { return nil }
        return (b, pts)
    }
    /// Seconds since the last frame arrived (infinity if never).
    public var age: Double {
        lock.lock(); defer { lock.unlock() }
        return arrivedAt == 0 ? .infinity : HostClock.seconds() - arrivedAt
    }
    public func clear() { lock.lock(); buffer = nil; arrivedAt = 0; lock.unlock() }
}

public extension CIImage {
    /// Turns a frame upright by its clockwise rotation in degrees (0, 90, 180, 270).
    func rotatedUpright(_ degrees: Int) -> CIImage {
        switch (degrees % 360 + 360) % 360 {
        case 90: return oriented(.right)
        case 180: return oriented(.down)
        case 270: return oriented(.left)
        default: return self
        }
    }
}

/// A source whose picture never changes (colour, image, text, wallpaper).
public final class StaticImageSource: VideoSource {
    public let id: UUID
    public private(set) var state: SourceState = .running
    private let lock = NSLock()
    private var cached: CIImage?
    public var nativeSize: CGSize { lock.lock(); defer { lock.unlock() }; return cached?.extent.size ?? CGSize(width: 16, height: 9) }
    public init(id: UUID, image: CIImage?) {
        self.id = id; cached = image
        if image == nil { state = .failed("Image file not found") }
    }
    public func update(_ image: CIImage?) { lock.lock(); cached = image; lock.unlock(); state = image == nil ? .failed("Image file not found") : .running }
    public func image(at time: CMTime) -> CIImage? { lock.lock(); defer { lock.unlock() }; return cached }
    public func start() {}
    public func stop() {}

    public static func color(_ c: RGBA) -> CIImage {
        CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    public static func image(path: String) -> CIImage? {
        guard let img = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { return nil }
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    /// Renders text to an image. `scale` lets the same style render crisply on 1080p and 4K canvases.
    public static func text(_ style: TextStyle, scale: CGFloat = 1) -> CIImage? {
        let size = CGFloat(style.fontSize) * scale
        var font: NSFont
        if style.fontName.hasPrefix("SF Mono") { font = NSFont.monospacedSystemFont(ofSize: size, weight: style.isBold ? .bold : .regular) }
        else if style.fontName.hasPrefix("SF Pro") { font = NSFont.systemFont(ofSize: size) }
        else { font = NSFont(name: style.fontName, size: size) ?? NSFont.systemFont(ofSize: size) }
        if style.isBold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        let text = style.text.isEmpty ? " " : style.text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(srgbRed: style.color.red, green: style.color.green, blue: style.color.blue, alpha: style.color.alpha),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padX: CGFloat = style.background == nil ? size * 0.05 : size * 0.45
        let padY: CGFloat = style.background == nil ? size * 0.05 : size * 0.22
        let w = Int(ceil(bounds.width + padX * 2)), h = Int(ceil(bounds.height + padY * 2))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let bg = style.background {
            ctx.setFillColor(bg.cgColor)
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.18, cornerHeight: size * 0.18, transform: nil))
            ctx.fillPath()
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        str.draw(with: CGRect(x: padX, y: padY - bounds.origin.y, width: bounds.width, height: bounds.height),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}

/// Moving colour bars with a flash on every whole second of the engine timeline. The flash frames line up
/// with `ToneSource` beeps, which makes A/V sync measurable in the output files.
public final class TestPatternSource: VideoSource {
    public let id: UUID
    public let state: SourceState = .running
    public let nativeSize = CGSize(width: 1920, height: 1080)
    private let origin: CMTime
    private let fps: Double
    private let bars: CIImage
    private let flash: CIImage
    public init(id: UUID, origin: CMTime, fps: Double) {
        self.id = id; self.origin = origin; self.fps = fps
        let colors: [CIColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue]
        var img = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let w = 1920.0 / Double(colors.count)
        for (i, c) in colors.enumerated() {
            let bar = CIImage(color: CIColor(red: c.red * 0.75, green: c.green * 0.75, blue: c.blue * 0.75))
                .cropped(to: CGRect(x: Double(i) * w, y: 300, width: w, height: 780))
            img = bar.composited(over: img)
        }
        bars = img
        flash = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }
    public func image(at time: CMTime) -> CIImage? {
        let t = CMTimeGetSeconds(CMTimeSubtract(time, origin))
        // A frame at t covers [t - dt/2, t + dt/2); flash the frame nearest to each whole second.
        let frac = t - floor(t + 0.5)
        if abs(frac) < 0.5 / fps { return flash }
        let x = (t.truncatingRemainder(dividingBy: 4) / 4) * 1920
        let mover = CIImage(color: .white).cropped(to: CGRect(x: x, y: 80, width: 60, height: 160))
        return mover.composited(over: bars)
    }
    public func start() {}
    public func stop() {}
}

/// A guest slot with nobody in it: draws nothing and isn't an error.
public final class EmptySlotSource: VideoSource {
    public let id: UUID
    public let state: SourceState = .running
    public let nativeSize = CGSize(width: 1280, height: 720)
    public init(id: UUID) { self.id = id }
    public func image(at time: CMTime) -> CIImage? { nil }
    public func start() {}
    public func stop() {}
}
