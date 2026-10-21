import Foundation
import CoreImage
import FramecastEngine

/// Layouts built from the creator asset pack (Resources/AssetPacks/creator-v1): scene plates with their text and
/// countdown filled in, and camera frames with the camera, screen or guest placed in each opening. Every layout is
/// composed separately for the 16:9 and 9:16 canvases from the pack's own coordinates.
extension Studio {
    static let packStyleName = ["obsidian-mint": "Obsidian", "paper-ink": "Paper", "warm-studio": "Warm", "deep-blue": "Deep Blue"]

    /// Display name and Layouts-strip group for a scene plate or frame.
    static func packLayoutInfo(_ a: AssetPack.Asset) -> (name: String, group: LayoutGroup)? {
        let style = packStyleName[a.styleFamily ?? ""] ?? ""
        switch a.category {
        case "stream-scenes":
            let kind = ["starting-soon": "Starting soon", "be-right-back": "Be right back", "thanks-for-watching": "Thanks"][a.subcategory ?? ""] ?? a.name
            return ("\(kind) · \(style)", .scenes)
        case "frames":
            let id = a.id
            if id.contains("solo-rect") { return ("Framed solo · \(style)", .solo) }
            if id.contains("webcam-circle") { return ("Screen + cam ring · \(style)", .screen) }
            if id.contains("host-screen") { return ("Screen + host · \(style)", .screen) }
            if id.contains("interview") { return ("Interview · \(style)", .together) }
            return ("\(a.name)", .solo)
        default: return nil
        }
    }

    /// Adds a layout made from a scene plate or frame and shows it.
    func addPackLayout(_ assetID: String) {
        guard let pack = AssetPack.creator, let asset = pack.asset(assetID), let info = Self.packLayoutInfo(asset) else { return }
        var scene: StudioScene
        if asset.category == "stream-scenes" { scene = plateLayout(asset, pack: pack) } else { scene = frameLayout(asset, pack: pack) }
        var n = info.name; var k = 2
        while scenes.contains(where: { $0.name == n }) { n = "\(info.name) \(k)"; k += 1 }
        scene.name = n; scene.verticalName = n; scene.group = info.group
        // Next to the other layouts of its group in the strip.
        func group(of s: StudioScene) -> LayoutGroup { s.template?.group ?? s.group ?? .scenes }
        if let last = collection.scenes.lastIndex(where: { group(of: $0) == info.group }) { collection.scenes.insert(scene, at: last + 1) }
        else { collection.scenes.append(scene) }
        show(scene.id)
    }

    /// A source for a pack picture, reused if this asset is already in the studio.
    private func packSource(_ kind: SourceKind, _ name: String) -> UUID {
        collection.sources.first { $0.kind == kind }?.id ?? ensureSource(kind, name)
    }

    // MARK: Scene plates

    private func plateLayout(_ asset: AssetPack.Asset, pack: AssetPack) -> StudioScene {
        let short = Self.packLayoutInfo(asset)?.name ?? asset.name
        let plate = packSource(.wallpaper("pack:\(asset.id)"), short)
        var textSources: [String: UUID] = [:]      // region id → source, shared by both canvases
        var canvases: [CanvasKind: [SceneItem]] = [:]
        for c in CanvasKind.allCases {
            var items = [SceneItem(sourceID: plate, role: .background, transform: .full, fit: .fill)]
            for r in Self.plateRegions(asset, canvas: c, pack: pack) {
                guard let style = Self.plateStyle(r, subcategory: asset.subcategory ?? "") else { continue }
                let isCountdown = r.role == "countdown" && asset.subcategory != "thanks-for-watching"
                let id = textSources[r.id] ?? {
                    let kind: SourceKind = isCountdown ? .countdown(style, endsAt: Date().timeIntervalSince1970 + 300) : .text(style)
                    let src = ensureSource(kind, "\(short) · \(isCountdown ? "countdown" : r.role)")
                    textSources[r.id] = src; return src
                }()
                let sample = isCountdown ? CountdownSource.text(remaining: 300) : style.text
                items.append(SceneItem(sourceID: id, role: r.role == "title" ? .title : nil,
                                       transform: Self.textRect(sample, style: style, region: r, canvas: c), fit: .fit))
            }
            canvases[c] = items
        }
        let template: StudioLayoutTemplate? = nil
        return StudioScene(name: short, horizontal: canvases[.horizontal] ?? [], vertical: canvases[.vertical] ?? [], template: template)
    }

    /// Text slots for a scene plate on one canvas. The manifest's landscape slots match the artwork, except that the
    /// starting-soon badge overlaps the pill's dot and the thanks plate's pill has none. Its portrait slots are the
    /// same generic set for every plate and don't match the portrait artwork, so portrait slots (and the missing
    /// landscape badge) are taken from the shapes in the pack's editable SVGs (same geometry in all four styles).
    /// Slots that appear on both canvases share an id, so one text layer feeds both.
    static func plateRegions(_ asset: AssetPack.Asset, canvas: CanvasKind, pack: AssetPack) -> [AssetPack.TextRegion] {
        let sub = asset.subcategory ?? ""
        let landscape = asset.variant(for: .horizontal)?.textRegions ?? []
        // Font and colour for a slot come from the landscape slot with the same id, or the style's starting-soon badge.
        let familyBadge = pack.assets(in: "stream-scenes")
            .first { $0.styleFamily == asset.styleFamily && $0.subcategory == "starting-soon" }?
            .variant(for: .horizontal)?.textRegions?.first { $0.role == "badge" }
        func slot(_ id: String, _ role: String, px x: Double, _ y: Double, _ w: Double, _ h: Double, _ align: String, font: Double) -> AssetPack.TextRegion {
            let size = canvas == .horizontal ? (3840.0, 2160.0) : (2160.0, 3840.0)
            let like = landscape.first { $0.id == id } ?? (role == "badge" ? familyBadge : landscape.first { $0.role == role })
            return AssetPack.TextRegion(id: id, role: role, rect: AssetPack.Rect(x: x / size.0, y: y / size.1, width: w / size.0, height: h / size.1),
                                        alignment: align, relativeFontSize: font / size.1, suggestedFont: like?.suggestedFont, suggestedColor: like?.suggestedColor)
        }
        let manifest = asset.variant(for: canvas)?.textRegions ?? []
        switch (sub, canvas) {
        case ("starting-soon", .horizontal):
            // Badge text starts after the pill's dot (pill 568,489 553×109; dot centre 630, radius 21).
            return manifest.filter { $0.role != "badge" } + [slot("status-badge", "badge", px: 679, 489, 408, 109, "left", font: 43)]
        case ("thanks-for-watching", .horizontal):
            return manifest + [slot("status-badge", "badge", px: 608, 473, 534, 109, "left", font: 43)]
        case ("starting-soon", .vertical):
            return manifest.filter { $0.role == "title" || $0.role == "subtitle" } + [
                slot("status-badge", "badge", px: 425, 644, 454, 117, "left", font: 50),
                slot("countdown-text", "countdown", px: 308, 1805, 1415, 365, "center", font: 300),   // module box, above its rule
                slot("handle-text", "handle", px: 358, 2550, 911, 261, "left", font: 50),
            ]
        case ("be-right-back", .vertical):
            return [
                slot("status-badge", "badge", px: 696, 953, 638, 129, "center", font: 52),
                slot("headline", "title", px: 371, 1230, 1289, 250, "center", font: 120),
                slot("subtitle", "subtitle", px: 371, 1560, 1289, 240, "center", font: 60),
                slot("footer-status", "caption", px: 494, 2282, 1043, 218, "center", font: 48),
            ]
        case ("thanks-for-watching", .vertical):
            return manifest.filter { $0.role == "title" || $0.role == "subtitle" } + [
                slot("status-badge", "badge", px: 348, 644, 594, 117, "left", font: 50),
                slot("card-left-text", "caption", px: 368, 1819, 1295, 444, "left", font: 52),
                slot("card-right-text", "caption", px: 368, 2367, 1295, 444, "left", font: 52),
            ]
        default:
            return manifest
        }
    }

    /// Starting words for each text slot; all of them are editable text layers.
    static func plateStyle(_ r: AssetPack.TextRegion, subcategory: String) -> TextStyle? {
        let text: String
        switch (subcategory, r.role) {
        case ("starting-soon", "badge"): text = "LIVE BROADCAST"
        case ("starting-soon", "title"): text = "LIVE STREAM STARTING SOON"
        case ("starting-soon", "subtitle"): text = "Today's topic goes here"
        case ("starting-soon", "handle"): text = "@yourhandle"
        case ("be-right-back", "badge"): text = "INTERMISSION"
        case ("be-right-back", "title"): text = "BE RIGHT BACK"
        case ("be-right-back", "subtitle"): text = "Short break, back in a moment"
        case ("be-right-back", "caption"): text = "Stay tuned in chat"
        case ("thanks-for-watching", "title"): text = "THANKS FOR WATCHING"
        case ("thanks-for-watching", "subtitle"): text = "Replays and links are in the description"
        case ("thanks-for-watching", "badge"): text = "STREAM ENDED"
        case ("thanks-for-watching", "caption"): text = r.id == "card-right-text" ? "@yourhandle" : "NEXT STREAM: SOON"
        case ("thanks-for-watching", "countdown"): text = "SEE YOU NEXT TIME"
        case (_, "countdown"): text = "05:00"
        default: text = r.exampleText ?? ""
        }
        guard !text.isEmpty else { return nil }
        let font = r.suggestedFont ?? "SF Pro Text Regular"
        let bold = ["Bold", "Semibold", "Heavy", "Black"].contains { font.contains($0) }
        let reference = 2160.0      // text is drawn at 4K size and scaled down by the layout
        return TextStyle(text: text, fontName: font, fontSize: max(12, (r.relativeFontSize ?? 0.03) * reference), isBold: bold,
                         color: RGBA(hex: r.suggestedColor ?? "#FFFFFF"))
    }

    /// The layer rectangle that shows `sample` at the slot's font size, aligned in the slot and never larger than it.
    static func textRect(_ sample: String, style: TextStyle, region r: AssetPack.TextRegion, canvas: CanvasKind) -> ItemTransform {
        var s = style; s.text = sample
        let ext = StaticImageSource.text(s)?.extent.size ?? CGSize(width: style.fontSize * Double(sample.count) * 0.6, height: style.fontSize * 1.2)
        let heightOverWidth = canvas == .horizontal ? 9.0 / 16 : 16.0 / 9
        let rel = r.relativeFontSize ?? 0.03
        var h = Double(ext.height) * rel / style.fontSize
        var w = Double(ext.width) * rel / style.fontSize * heightOverWidth
        let k = min(1, r.rect.width / w, r.rect.height / h)
        w *= k; h *= k
        let x: Double
        switch r.alignment ?? "left" {
        case "center": x = r.rect.x + (r.rect.width - w) / 2
        case "right": x = r.rect.x + r.rect.width - w
        default: x = r.rect.x
        }
        return ItemTransform(x: x, y: r.rect.y + (r.rect.height - h) / 2, width: w, height: h)
    }

    // MARK: Frames

    private func frameLayout(_ asset: AssetPack.Asset, pack: AssetPack) -> StudioScene {
        let short = Self.packLayoutInfo(asset)?.name ?? asset.name
        let roles = defaultRoles()
        // A background from the same style family, so the frame sits on the backdrop it was designed with.
        let bgAsset = pack.assets(in: "backgrounds").first { $0.styleFamily == asset.styleFamily }
        let bg = bgAsset.map { packSource(.wallpaper("pack:\($0.id)"), $0.name) } ?? roles.background
        let frame = packSource(.packImage(asset.id), "\(short) frame")
        let guest = asset.variants.values.contains { $0.transparentApertures?.contains { $0.role == "guest-camera" } == true }
            ? (collection.sources.first { if case .guest(1) = $0.kind { return true }; return false }?.id ?? ensureSource(.guest(slot: 1), "Guest 1"))
            : nil
        var canvases: [CanvasKind: [SceneItem]] = [:]
        for c in CanvasKind.allCases {
            var items = [SceneItem(sourceID: bg, role: .background, transform: .full, fit: .fill)]
            let apertures = asset.variant(for: c)?.transparentApertures ?? []
            // A lone camera ring sits over the shared screen.
            if !apertures.contains(where: { $0.role == "shared-screen" }) && asset.id.contains("webcam-circle") {
                items.append(SceneItem(sourceID: roles.screen, role: .screen, transform: .full, fit: .fit))
            }
            for a in apertures {
                let t = ItemTransform(x: a.rect.x, y: a.rect.y, width: a.rect.width, height: a.rect.height)
                switch a.role {
                case "shared-screen": items.append(SceneItem(sourceID: roles.screen, role: .screen, transform: t, fit: .fit, mask: Self.mask(a, canvas: c)))
                case "guest-camera": if let guest { items.append(SceneItem(sourceID: guest, role: .camera2, transform: t, fit: .fill, mask: Self.mask(a, canvas: c))) }
                default: items.append(SceneItem(sourceID: roles.camera, role: .camera, transform: t, fit: .fill, mask: Self.mask(a, canvas: c)))
                }
            }
            items.append(SceneItem(sourceID: frame, transform: .full, fit: .fill))
            canvases[c] = items
        }
        return StudioScene(name: short, horizontal: canvases[.horizontal] ?? [], vertical: canvases[.vertical] ?? [])
    }

    /// The pack gives corner radii as a fraction of the canvas's shorter side; layer masks use a fraction of the
    /// layer's shorter side.
    static func mask(_ a: AssetPack.Aperture, canvas: CanvasKind) -> ItemMask {
        if a.maskShape == "circle" { return .circle }
        let size = canvas == .horizontal ? CGSize(width: 3840, height: 2160) : CGSize(width: 2160, height: 3840)
        let corner = (a.cornerRadiusNormalized ?? 0) * Double(min(size.width, size.height))
        let shorter = min(a.rect.width * Double(size.width), a.rect.height * Double(size.height))
        return corner > 0 && shorter > 0 ? .roundedRect(radius: corner / shorter) : .none
    }

    /// Where an annotation goes when added: centred, about a fifth of the canvas wide (two fifths on 9:16).
    static func annotationRect(_ asset: AssetPack.Asset, canvas: CanvasKind) -> ItemTransform {
        guard let v = asset.variant(for: canvas), v.width > 0 else { return ItemTransform(x: 0.4, y: 0.4, width: 0.2, height: 0.2) }
        let w = canvas == .horizontal ? 0.22 : 0.4
        let h = w * Double(v.height) / Double(v.width) * (canvas == .horizontal ? 16.0 / 9 : 9.0 / 16)
        return ItemTransform(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

extension RGBA {
    /// `#RRGGBB` or `#RRGGBBAA`.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0xFFFFFF
        if s.count == 8 { self.init(Double(v >> 24 & 0xFF) / 255, Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255) }
        else { self.init(Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255) }
    }
}
