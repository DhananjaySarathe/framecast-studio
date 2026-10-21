import Foundation
import CoreImage
import CoreMedia

/// Artwork from an asset pack. Each canvas gets its own variant (16:9 or 9:16) of the same design.
/// Both are decoded in the background when the layer starts (the render thread never waits) and released when it
/// stops.
public final class PackImageSource: VideoSource {
    public let id: UUID
    let assetID: String
    private var images: [CanvasKind: CIImage] = [:]
    private var generation = 0
    private let lock = NSLock()
    public init(id: UUID, assetID: String) { self.id = id; self.assetID = assetID }

    public var state: SourceState {
        AssetPack.find(assetID) == nil ? .failed("This picture's asset pack isn't installed.") : .running
    }
    public var nativeSize: CGSize {
        guard let v = AssetPack.find(assetID)?.asset.variant(for: .horizontal) else { return CGSize(width: 16, height: 9) }
        return CGSize(width: v.width, height: v.height)
    }
    public func image(at time: CMTime) -> CIImage? { image(at: time, canvas: .horizontal) }
    public func image(at time: CMTime, canvas: CanvasKind) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return images[canvas]
    }
    public func start() {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let asset = assetID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let (pack, a) = AssetPack.find(asset) else { return }
            var loaded: [CanvasKind: CIImage] = [:]
            var byPath: [String: CIImage] = [:]      // annotations use one picture for both canvases
            for c in CanvasKind.allCases {
                guard let path = a.variant(for: c)?.path else { continue }
                if let same = byPath[path] { loaded[c] = same; continue }
                if let img = pack.loadImage(asset, canvas: c) { loaded[c] = img; byPath[path] = img }
            }
            guard let self else { return }
            self.lock.lock(); if self.generation == gen { self.images = loaded }; self.lock.unlock()
        }
    }
    public func stop() {
        lock.lock(); generation += 1; images = [:]; lock.unlock()
    }
}

/// A countdown in `MM:SS` (or `H:MM:SS`) to a moment in wall-clock time, drawn with a text style. Shows 00:00 once it
/// has passed. Redrawn once per second.
public final class CountdownSource: VideoSource {
    public let id: UUID
    let style: TextStyle
    let endsAt: Double
    private var shown = -1
    private var cached: CIImage?
    private let lock = NSLock()
    public init(id: UUID, style: TextStyle, endsAt: Double) { self.id = id; self.style = style; self.endsAt = endsAt }

    public var state: SourceState { .running }
    public var nativeSize: CGSize { cached?.extent.size ?? CGSize(width: style.fontSize * 3, height: style.fontSize * 1.2) }

    public static func text(remaining: Int) -> String {
        let s = max(0, remaining)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    public func image(at time: CMTime) -> CIImage? {
        let remaining = Int((endsAt - Date().timeIntervalSince1970).rounded(.up))
        lock.lock(); defer { lock.unlock() }
        if remaining != shown || cached == nil {
            var s = style; s.text = Self.text(remaining: remaining)
            cached = StaticImageSource.text(s); shown = remaining
        }
        return cached
    }
    public func start() {}
    public func stop() {}
}
