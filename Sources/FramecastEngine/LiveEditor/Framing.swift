import Foundation
import CoreGraphics

/// Where a layer's camera points: the centre, in the layer's picture after the user's crop and mirror (0...1,
/// top-left origin), and the zoom relative to the layer's normal view (1 = today's fit or fill).
public struct Viewport: Equatable, Sendable {
    public var cx: Double, cy: Double, zoom: Double
    public init(cx: Double, cy: Double, zoom: Double) { self.cx = cx; self.cy = cy; self.zoom = zoom }
    public static let identity = Viewport(cx: 0.5, cy: 0.5, zoom: 1)
}

/// A layer as the compositor will draw it: what views of it are reachable, and how sharp they stay.
public struct LayerGeometry: Sendable, Equatable {
    public var image: CGSize      // the source picture after the user's crop, in source pixels
    public var frame: CGSize      // the layer's frame on the canvas, in canvas pixels
    public var fit: FitMode
    public var crop: ItemCrop
    public var mirrored: Bool
    public init(image: CGSize, frame: CGSize, fit: FitMode, crop: ItemCrop = ItemCrop(), mirrored: Bool = false) {
        self.image = image; self.frame = frame; self.fit = fit; self.crop = crop; self.mirrored = mirrored
    }

    var fitScale: Double { min(frame.width / image.width, frame.height / image.height) }
    var fillScale: Double { max(frame.width / image.width, frame.height / image.height) }
    /// Canvas pixels per source pixel at zoom 1.
    public var referenceScale: Double { fit == .fit ? fitScale : fillScale }
    /// The zoom at which a fit layer fills its frame (a screen on the 9:16 canvas stops being a strip).
    public var fillZoom: Double { fit == .fit ? fillScale / fitScale : 1 }
    /// The most a layer may zoom before the source is shown enlarged more than `enlargement` (1.25: at least 0.8
    /// source pixels per output pixel). Never below 1: a layer already enlarged today may pan but not zoom.
    public func maxZoom(enlargement: Double) -> Double { max(1, enlargement / referenceScale) }
    /// The fraction of the picture shown at a zoom, across and down.
    public func visible(zoom: Double) -> CGSize {
        if fit == .stretch { return CGSize(width: min(1, 1 / zoom), height: min(1, 1 / zoom)) }   // stretched to the frame at zoom 1
        let s = referenceScale * zoom
        return CGSize(width: min(1, frame.width / (image.width * s)), height: min(1, frame.height / (image.height * s)))
    }
    /// A point in the source (0...1, top-left) in the layer's picture after crop and mirror; nil when cropped away.
    public func picturePoint(_ p: CGPoint) -> CGPoint? {
        var u = (p.x - crop.left) / max(0.01, 1 - crop.left - crop.right)
        let v = (p.y - crop.top) / max(0.01, 1 - crop.top - crop.bottom)
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        if mirrored { u = 1 - u }
        return CGPoint(x: u, y: v)
    }
    /// A source area (0...1, top-left) in the layer's picture, clipped to what the crop leaves; nil when none is left.
    public func pictureRect(_ r: CGRect) -> CGRect? {
        let w = max(0.01, 1 - crop.left - crop.right), h = max(0.01, 1 - crop.top - crop.bottom)
        var x0 = (r.minX - crop.left) / w, x1 = (r.maxX - crop.left) / w
        if mirrored { (x0, x1) = (1 - x1, 1 - x0) }
        let out = CGRect(x: x0, y: (r.minY - crop.top) / h, width: x1 - x0, height: r.height / h)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return out.isNull || out.isEmpty ? nil : out
    }
    /// Keeps a centre where the view stays inside the picture at that zoom.
    public func clamp(_ c: CGPoint, zoom: Double) -> CGPoint {
        let v = visible(zoom: zoom)
        return CGPoint(x: min(max(c.x, v.width / 2), 1 - v.width / 2), y: min(max(c.y, v.height / 2), 1 - v.height / 2))
    }
    /// The picture area shown for a view (0...1, top-left).
    public func viewRect(_ vp: Viewport) -> CGRect {
        let v = visible(zoom: vp.zoom), c = clamp(CGPoint(x: vp.cx, y: vp.cy), zoom: vp.zoom)
        return CGRect(x: c.x - v.width / 2, y: c.y - v.height / 2, width: v.width, height: v.height)
    }
}

/// Where a screen capture sits on the desktop, in global points (top-left origin, like `CGEvent.location`).
public struct ScreenGeometry: Sendable, Equatable {
    public var rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
    /// A desktop point in the capture (0...1, top-left), nil outside it.
    public func normalized(_ p: CGPoint) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let n = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        return (0...1).contains(n.x) && (0...1).contains(n.y) ? n : nil
    }
    public func normalized(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - rect.minX) / rect.width, y: (r.minY - rect.minY) / rect.height,
               width: r.width / rect.width, height: r.height / rect.height)
    }
}
