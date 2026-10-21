import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// An asset pack in `Resources/AssetPacks/<name>/`, described by its `manifest.json`. The creator pack has
/// backgrounds, scene plates, camera frames, card backplates and annotations, most with separate 16:9 and 9:16
/// artwork (imported with `scripts/import_asset_pack.swift`); the background library holds extra backgrounds
/// (built with `scripts/add_backgrounds.swift`).
public final class AssetPack: @unchecked Sendable {
    /// Normalized, origin top-left (the manifest's convention, same as `ItemTransform`).
    public struct Rect: Codable, Hashable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    }
    public struct TextRegion: Codable, Hashable, Sendable {
        public let id: String
        public let role: String
        public let rect: Rect
        public let alignment: String?
        public let maxLines: Int?
        public let relativeFontSize: Double?
        public let suggestedFont: String?
        public let suggestedColor: String?
        public let exampleText: String?
        public init(id: String, role: String, rect: Rect, alignment: String?, maxLines: Int? = 1, relativeFontSize: Double?,
                    suggestedFont: String?, suggestedColor: String?, exampleText: String? = nil) {
            self.id = id; self.role = role; self.rect = rect; self.alignment = alignment; self.maxLines = maxLines
            self.relativeFontSize = relativeFontSize; self.suggestedFont = suggestedFont; self.suggestedColor = suggestedColor
            self.exampleText = exampleText
        }
    }
    public struct Aperture: Codable, Hashable, Sendable {
        public let role: String
        public let rect: Rect
        public let maskShape: String?
        public let cornerRadiusNormalized: Double?
    }
    public struct Variant: Codable, Hashable, Sendable {
        public let path: String
        public let width: Int
        public let height: Int
        public let hasAlpha: Bool
        public let previewPath: String?
        public let textRegions: [TextRegion]?
        public let transparentApertures: [Aperture]?
    }
    public struct Asset: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let category: String
        public let subcategory: String?
        public let styleFamily: String?
        public let description: String?
        public let tags: [String]?
        /// Hex colours, the main one first.
        public let dominantColors: [String]?
        public let variants: [String: Variant]

        /// Light artwork (for the background picker's Dark/Light filter): from the tags, else the main colour.
        public var isLight: Bool {
            if let t = tags { if t.contains("light") { return true }; if t.contains("dark") { return false } }
            guard let hex = dominantColors?.first, let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return false }
            let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
            return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.5
        }

        /// The artwork for a canvas: its own orientation, or the one universal picture (annotations).
        public func variant(for canvas: CanvasKind) -> Variant? {
            variants[canvas == .horizontal ? "horizontal" : "vertical"] ?? variants["universal"] ?? variants.values.first
        }
    }
    private struct Manifest: Codable { let packId: String; let assets: [Asset] }

    public let root: URL
    public let packID: String
    public let assets: [Asset]

    /// Pixel size of each canvas. Artwork is decoded no larger than needed to cover it (1080p canvases need a quarter
    /// of the 4K pixels); the engine updates this and reloads pack layers when a canvas size changes.
    public static var canvasSizes: [CanvasKind: CGSize] {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _canvasSizes }
        set { sizeLock.lock(); _canvasSizes = newValue; sizeLock.unlock() }
    }
    nonisolated(unsafe) private static var _canvasSizes: [CanvasKind: CGSize] = [:]
    private static let sizeLock = NSLock()

    /// Every bundled pack (app resources, or the repository copy when run with `swift run`), the creator pack first.
    public static let all: [AssetPack] = {
        let roots = [Bundle.main.resourceURL?.appendingPathComponent("AssetPacks"),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/AssetPacks")]
        for case let root? in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            let packs = names.sorted { ($0 == "creator-v1" ? "" : $0) < ($1 == "creator-v1" ? "" : $1) }
                .compactMap { try? AssetPack(root: root.appendingPathComponent($0)) }
            if !packs.isEmpty { return packs }
        }
        return []
    }()

    /// The creator pack: scene plates, frames, cards and annotations as well as backgrounds.
    public static let creator: AssetPack? = all.first { $0.root.lastPathComponent == "creator-v1" }

    /// The pack that has an asset (asset IDs are unique across packs).
    public static func find(_ assetID: String) -> (pack: AssetPack, asset: Asset)? {
        for p in all { if let a = p.asset(assetID) { return (p, a) } }
        return nil
    }

    public init(root: URL) throws {
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        self.root = root; packID = m.packId; assets = m.assets
    }

    public func asset(_ id: String) -> Asset? { assets.first { $0.id == id } }
    public func assets(in category: String) -> [Asset] { assets.filter { $0.category == category } }

    /// Opaque artwork ships as 10-bit HEIC next to where the manifest's PNG would be.
    public func fileURL(_ path: String) -> URL {
        let heic = root.appendingPathComponent((path as NSString).deletingPathExtension + ".heic")
        return FileManager.default.fileExists(atPath: heic.path) ? heic : root.appendingPathComponent(path)
    }

    public func previewURL(_ asset: Asset, canvas: CanvasKind = .horizontal) -> URL? {
        asset.variant(for: canvas)?.previewPath.map { root.appendingPathComponent($0) }
    }

    /// Decodes the picture for one canvas (slow: call off the render thread; PackImageSource keeps the result while
    /// its layer exists). HEIC artwork gets its fine grain back first (±1 step of triangular noise in sRGB, as the
    /// pack's PNGs had) and is rendered to 8 bits, so gradients don't band.
    public func loadImage(_ id: String, canvas: CanvasKind) -> CIImage? {
        guard let v = asset(id)?.variant(for: canvas) else { return nil }
        let url = fileURL(v.path)
        guard var img = CIImage(contentsOf: url) else { return nil }
        if let canvas = Self.canvasSizes[canvas], img.extent.width > 0, img.extent.height > 0 {
            let k = min(1, max(canvas.width / img.extent.width, canvas.height / img.extent.height))
            if k < 0.99 {
                img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
                let e = img.extent.integral
                img = img.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            }
        }
        if url.pathExtension == "heic", let grained = Self.withGrain(img) { img = grained }
        else if img.extent.width < 5000, let cg = Self.context.createCGImage(img, from: img.extent) { img = CIImage(cgImage: cg) }
        return img
    }

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                     .cacheIntermediates: false])

    static func withGrain(_ img: CIImage) -> CIImage? {
        let e = img.extent
        func noise(_ d: CGFloat) -> CIImage {
            CIFilter.randomGenerator().outputImage!.transformed(by: CGAffineTransform(translationX: d, y: d * 0.7)).cropped(to: e)
        }
        // Sum of two uniform noises is triangular; scale to ±1/255 per colour channel, leave alpha alone.
        let tpdf = noise(0).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: noise(4099)])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 / 255, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 / 255, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 / 255, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -1 / 255, y: -1 / 255, z: -1 / 255, w: 0)])
        let grained = img.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: tpdf])
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: e)
        guard let cg = context.createCGImage(grained, from: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return CIImage(cgImage: cg)
    }
}
