import Foundation
import FramecastEngine

/// The looks the live brain can put on air: the studio's camera and screen scenes, plus three asset looks that
/// show the asset the brain picks (camera as a circle at the bottom right, which assets keep clear, camera as a
/// square beside it, or the asset alone). Asset looks hold an "Asset slot" layer; on air it shows the current asset (Studio.resolvedItems), so
/// changing the asset never edits the scenes.
enum Looks {
    static let slotName = "Asset slot"
    static let circle = "Asset + camera circle", square = "Asset + camera square", full = "Asset full"
    static let assetLooks = [circle, square, full]
    static let boxedAssetLooks = [circle, square]

    struct Look: Equatable { var name: String; var about: String; var isAsset: Bool }

    /// What a scene looks like, in words for the brain; nil for scenes it shouldn't pick on its own.
    static func about(_ s: StudioScene) -> String? {
        switch s.name {
        case circle: return "the asset large, the camera as a circle at the bottom right"
        case square: return "the asset on the left, a square camera on the right"
        case full: return "the asset alone, full screen, hiding the presenter (only for a detailed picture)"
        default: break
        }
        guard let t = s.template else { return s.group == nil ? "the presenter's own scene" : nil }
        switch t {
        case .solo: return "full-screen camera"
        case .framed: return "camera in a framed card"
        case .closeUp: return "round camera bubble in the middle"
        case .screenCam: return "screen, with a square camera in the corner"
        case .camLeft: return "screen, with a square camera bottom left"
        case .screenTile, .screenTileLeft: return "full screen, with a small camera"
        case .side, .sideLeft: return "screen and camera side by side"
        case .focus: return "screen only, no camera"
        case .presenter: return "tall camera beside the screen"
        case .ending: return "closing card, for the goodbye"
        case .startingSoon, .beRightBack, .headline, .podcast: return nil
        }
    }

    /// Scenes the brain may pick: not cards like Intro or Break, and not scenes with guest slots (empty without guests).
    static func catalog(_ studio: Studio) -> [Look] {
        studio.scenes.compactMap { s in
            let guests = (s.horizontal + s.vertical).contains { item in
                switch studio.source(item.sourceID)?.kind { case .guest?, .guestScreen?, .guestGrid?: return true; default: return false }
            }
            return guests ? nil : about(s).map { Look(name: s.name, about: $0, isAsset: assetLooks.contains(s.name)) }
        }
    }

    /// Makes sure the asset slot and the three asset looks exist; returns the slot's source id.
    @discardableResult
    static func ensure(_ studio: Studio) -> UUID {
        let slot = studio.collection.sources.first { $0.name == slotName }?.id ?? studio.ensureSource(.color(.clear), slotName)
        let r = studio.defaultRoles()
        func bg() -> SceneItem { SceneItem(sourceID: r.background, role: .background, transform: .full, fit: .fill) }
        func asset(_ t: ItemTransform, rounded: Bool = true) -> SceneItem {
            SceneItem(sourceID: slot, transform: t, fit: .fit, mask: rounded ? .roundedRect(radius: 0.035) : .none)
        }
        func cam(_ t: ItemTransform, _ m: ItemMask) -> SceneItem { SceneItem(sourceID: r.camera, role: .camera, transform: t, fit: .fill, mask: m) }
        let T = ItemTransform.init(x:y:width:height:rotationDegrees:)
        let looks: [(String, [SceneItem], [SceneItem])] = [
            (circle,
             [bg(), asset(T(0.03, 0.053, 0.94, 0.894, 0)), cam(T(0.795, 0.64, 0.17, 0.17 * 16 / 9, 0), .circle)],
             [bg(), asset(T(0.04, 0.06, 0.92, 0.62, 0)), cam(T(0.29, 0.71, 0.42, 0.42 * 9 / 16, 0), .circle)]),
            (square,
             [bg(), asset(T(0.03, 0.053, 0.64, 0.894, 0)), cam(T(0.69, 0.25, 0.28, 0.28 * 16 / 9, 0), .roundedRect(radius: 0.1))],
             [bg(), asset(T(0.04, 0.05, 0.92, 0.5, 0)), cam(T(0.2, 0.58, 0.6, 0.6 * 9 / 16, 0), .roundedRect(radius: 0.1))]),
            (full, [bg(), asset(.full, rounded: false)], [bg(), asset(.full, rounded: false)]),
        ]
        for (name, h, v) in looks where !studio.scenes.contains(where: { $0.name == name }) {
            var s = StudioScene(name: name, horizontal: h, vertical: v)
            s.group = .screen
            studio.collection.scenes.append(s)
        }
        // A round camera look too, for variety, if the studio has none.
        if !studio.scenes.contains(where: { $0.template == .closeUp }) {
            var s = LayoutTemplates.make(.closeUp, roles: r)
            if studio.scenes.contains(where: { $0.name == s.name }) { s.name += " (round)"; s.verticalName = s.name }
            studio.collection.scenes.append(s)
        }
        return slot
    }

    /// The studio source for an asset file in the show folder (a picture or a video), added on first use.
    static func source(for file: String, in folder: URL, studio: Studio) -> UUID? {
        let path = folder.appendingPathComponent("assets").appendingPathComponent(file).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let isVideo = ShowStore.videoTypes.contains((file as NSString).pathExtension.lowercased())
        let kind: SourceKind = isVideo ? .media(path: path) : .image(path: path)
        if let existing = studio.collection.sources.first(where: { $0.kind == kind }) { return existing.id }
        var rec = SourceRecord(name: "Asset · \(file)", kind: kind)
        if isVideo { rec.media = MediaOptions(); rec.media?.loop = file.hasSuffix(".loop.mp4") }   // motion loops repeat on screen
        studio.collection.sources.append(rec)
        studio.engine.sync(sources: studio.collection.sources, fpsHint: studio.settings.s.horizontal.fps)
        return rec.id
    }
}
