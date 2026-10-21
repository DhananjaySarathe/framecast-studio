import SwiftUI
import AppKit
import ImageIO
import FramecastEngine

/// What the background picker changes.
enum BackgroundTarget: Identifiable, Equatable {
    /// Puts a background on the editing scene (Add to scene, or a scene without a picture background).
    case scene
    /// Changes the picture of an existing background (the Layer tab).
    case source(UUID)
    var id: String { switch self { case .scene: "scene"; case .source(let u): u.uuidString } }
}

/// One background the picker offers: a picture from an asset pack, or one of the backgrounds Framecast draws itself.
struct BackgroundChoice: Identifiable, Hashable, Sendable {
    /// The `.wallpaper` value: "pack:<asset id>" or a built-in name.
    let id: String
    let name: String
    let group: String
    let isLight: Bool
    let detail: String?
    let tags: [String]
    /// Small preview JPEGs and the full artwork, per canvas. Both empty for the drawn backgrounds.
    let previews: [CanvasKind: URL]
    let artwork: [CanvasKind: URL]
    var isDrawn: Bool { artwork.isEmpty }
    var caption: String { "\(BackgroundCatalog.title(group)) · \(isLight ? "Light" : "Dark")" }
}

/// Every background in this build: the asset packs' backgrounds (creator pack and background library), then the
/// drawn ones.
enum BackgroundCatalog {
    /// Groups in picker order, keyed by the packs' `subcategory`. Groups the background script made from new folder
    /// names come after these, before Basic.
    static let knownGroups: [(key: String, title: String)] = [
        ("soft-gradient", "Gradients"), ("mesh-aurora", "Aurora"), ("abstract", "Abstract"),
        ("tactile-texture", "Textures"), ("environmental", "Rooms"),
    ]
    static let drawnGroup = "drawn"

    static func title(_ group: String) -> String {
        if group == drawnGroup { return "Basic" }
        if group == "stream-scenes" { return "Scene plates" }
        return knownGroups.first { $0.key == group }?.title
            ?? group.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static let all: [BackgroundChoice] = {
        var out = AssetPack.all.flatMap { p in p.assets(in: "backgrounds").map { packChoice($0, in: p) } }
        out += Wallpapers.all.map {
            BackgroundChoice(id: $0.id, name: $0.name, group: drawnGroup, isLight: $0.id == "paper",
                             detail: "Drawn by Framecast, sharp at any canvas size.", tags: [], previews: [:], artwork: [:])
        }
        return out
    }()

    /// Groups that have backgrounds, in picker order.
    static let groups: [String] = {
        let present = Set(all.map(\.group))
        let known = knownGroups.map(\.key).filter(present.contains)
        let extra = present.subtracting(known).subtracting([drawnGroup]).sorted()
        return known + extra + (present.contains(drawnGroup) ? [drawnGroup] : [])
    }()

    /// A background by its `.wallpaper` value. Pack artwork that isn't a background (a scene plate) still gets an
    /// entry, so the picker can show what a layer has now.
    static func choice(_ id: String) -> BackgroundChoice? {
        if let c = all.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("pack:"), let (p, a) = AssetPack.find(String(id.dropFirst(5))) else { return nil }
        return packChoice(a, in: p)
    }

    static func packChoice(_ a: AssetPack.Asset, in p: AssetPack) -> BackgroundChoice {
        var previews: [CanvasKind: URL] = [:], artwork: [CanvasKind: URL] = [:]
        for c in CanvasKind.allCases {
            previews[c] = p.previewURL(a, canvas: c)
            artwork[c] = a.variant(for: c).map { p.fileURL($0.path) }
        }
        let group = a.category == "backgrounds" ? (a.subcategory ?? "more") : a.category
        return BackgroundChoice(id: "pack:\(a.id)", name: a.name, group: group, isLight: a.isLight, detail: a.description,
                                tags: a.tags ?? [], previews: previews, artwork: artwork)
    }
}

/// Small pictures of backgrounds, made off the main thread and kept while the app runs (a few MB at most).
enum BackgroundImages {
    nonisolated(unsafe) static let cache = NSCache<NSString, CGImage>()

    static func image(_ c: BackgroundChoice, canvas: CanvasKind, maxPixel: Int) async -> CGImage? {
        let key = "\(c.id)|\(canvas.rawValue)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img: CGImage? = await Task.detached(priority: .userInitiated) {
            if c.isDrawn {
                let long = maxPixel, short = maxPixel * 9 / 16
                return canvas == .horizontal ? Wallpapers.preview(c.id, width: long, height: short) : Wallpapers.preview(c.id, width: short, height: long)
            }
            // Grid thumbnails come from the pack's preview JPEGs; the large preview from the artwork itself.
            guard let url = (maxPixel <= 480 ? c.previews[canvas] : nil) ?? c.artwork[canvas],
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                                                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

/// A background cropped the way a canvas shows it.
struct BackgroundThumb: View {
    let choice: BackgroundChoice
    let canvas: CanvasKind
    var maxPixel = 360
    @Local var image: CGImage?
    var body: some View {
        Theme.programWell
            .aspectRatio(canvas == .horizontal ? 16 / 9 : 9 / 16, contentMode: .fit)
            .overlay { if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } }
            .clipped()
            .task(id: "\(choice.id)|\(canvas.rawValue)|\(maxPixel)") {
                image = await BackgroundImages.image(choice, canvas: canvas, maxPixel: maxPixel)
            }
    }
}

// MARK: - Picker

struct BackgroundPickerSheet: View {
    @Environment(Studio.self) var studio
    @Environment(\.dismiss) var dismiss
    let target: BackgroundTarget
    @Local var group: String?
    @Local var tone = Tone.any
    @Local var canvas: CanvasKind = .horizontal
    @Local var search = ""
    @Local var selected: String?
    @Local var hovered: String?
    @Local var everyScene = true
    @Local var previewMode = PreviewMode.scene
    @Local var previewSceneID: UUID?
    /// Live renders of the preview scene on the selected background, and which background they show.
    @Local var sceneShots: [CanvasKind: CGImage] = [:]
    @Local var shotsFor: String?

    enum PreviewMode: String, CaseIterable { case scene = "On your scene", picture = "Picture only" }
    /// Stands in for a background layer in scenes that have none.
    static let placeholderID = UUID()

    enum Tone: String, CaseIterable { case any = "Any", dark = "Dark", light = "Light" }

    /// The background this picker would replace.
    var current: String? {
        let id: UUID?
        switch target {
        case .source(let s): id = s
        case .scene: id = studio.editingBackground?.sourceID
        }
        if let id, case .wallpaper(let w)? = studio.source(id)?.kind { return w }
        return nil
    }
    var sharedCount: Int { if case .source(let id) = target { return studio.sceneCount(using: id) }; return 0 }
    var selection: BackgroundChoice? { (selected ?? current).flatMap(BackgroundCatalog.choice) }

    func matches(_ c: BackgroundChoice) -> Bool {
        (tone == .any || c.isLight == (tone == .light))
            && (search.isEmpty || c.name.localizedCaseInsensitiveContains(search)
                || BackgroundCatalog.title(c.group).localizedCaseInsensitiveContains(search)
                || c.tags.contains { $0.localizedCaseInsensitiveContains(search) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            filterBar
            Hairline()
            HStack(spacing: 0) {
                grid
                Hairline(vertical: true)
                details.frame(width: 320)
            }
        }
        .frame(width: 1040, height: 680)
        .background(Theme.panel)
        .onAppear {
            canvas = studio.editingCanvas; selected = current
            // In preview mode a change stays in the preview scene unless asked to change every scene.
            if studio.previewMode { everyScene = false }
        }
        .onChange(of: studio.testBackgroundPicker?.serial) { _, _ in runTestCommand() }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a background").font(.fc(16, .bold))
                Text("Each picture has a 16:9 and a 9:16 version.").font(.fc(12)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 12)
            Picker("", selection: $tone) { ForEach(Tone.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 156).help("Show dark or light backgrounds")
            Picker("", selection: $canvas) { Text("16:9").tag(CanvasKind.horizontal); Text("9:16").tag(CanvasKind.vertical) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 104).help("Preview the 16:9 or the 9:16 version")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.fc(11.5)).foregroundStyle(Theme.text3)
                TextField("Search backgrounds", text: $search).textFieldStyle(.plain).font(.fc(12.5))
            }
            .padding(.horizontal, 10).frame(width: 200, height: 30)
            .background(Capsule().fill(Theme.field)).overlay(Capsule().stroke(Theme.fieldBorder))
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// Group chips across the full width (scrolls sideways if more groups are added than fit).
    var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil, "All", BackgroundCatalog.all.filter(matches).count)
                ForEach(BackgroundCatalog.groups, id: \.self) { g in
                    chip(g, BackgroundCatalog.title(g), BackgroundCatalog.all.filter { $0.group == g && matches($0) }.count)
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 48)
    }

    func chip(_ g: String?, _ title: String, _ count: Int) -> some View {
        let on = group == g
        return Button { group = g } label: {
            HStack(spacing: 5) {
                Text(title).font(.fc(12, .semibold))
                Text("\(count)").font(.fc(11, .medium).monospacedDigit()).foregroundStyle(on ? Theme.accentInk.opacity(0.75) : Theme.text4)
            }
            .foregroundStyle(on ? Theme.accentInk : Theme.text2)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(on ? Theme.accent : Theme.control))
            .overlay(Capsule().stroke(on ? .clear : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    var columns: [GridItem] {
        canvas == .horizontal ? [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: 14, alignment: .top)]
                              : [GridItem(.adaptive(minimum: 112, maximum: 160), spacing: 14, alignment: .top)]
    }

    var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 0).id("top")
                    let shown = group.map { [$0] } ?? BackgroundCatalog.groups
                    ForEach(shown, id: \.self) { g in
                        let items = BackgroundCatalog.all.filter { $0.group == g && matches($0) }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                if group == nil { SectionLabel(text: BackgroundCatalog.title(g)) }
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                    ForEach(items) { card($0).id($0.id) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if BackgroundCatalog.all.filter({ (group == nil || $0.group == group) && matches($0) }).isEmpty {
                        Text("No backgrounds match.").font(.fc(12.5)).foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .onAppear { if let c = current { proxy.scrollTo(c, anchor: .center) } }
            .onChange(of: "\(group ?? "")|\(tone)|\(canvas)|\(search)") { _, _ in proxy.scrollTo("top", anchor: .top) }
        }
    }

    func card(_ c: BackgroundChoice) -> some View {
        let isSelected = c.id == selection?.id
        return VStack(alignment: .leading, spacing: 6) {
            BackgroundThumb(choice: c, canvas: canvas)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Theme.accent : (hovered == c.id ? Theme.text4 : Theme.hairline), lineWidth: isSelected ? 2.5 : 1))
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").font(.fc(17)).foregroundStyle(Theme.accentInk, Theme.accent).padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if c.id == current {
                        Text("In use").font(.fc(10, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(.black.opacity(0.6))).padding(6)
                    }
                }
            Text(c.name).font(.fc(12, .semibold)).foregroundStyle(isSelected ? Theme.text : Theme.text2)
                .lineLimit(canvas == .vertical ? 2 : 1).fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = c.id } else if hovered == c.id { hovered = nil } }
        .onTapGesture { selected = c.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { selected = c.id; apply() })
        .help(c.name)
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $previewMode) { ForEach(PreviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().help("See the background behind your scene, or on its own")
            if let c = selection {
                if previewMode == .scene, let scene = previewScene { sceneLine(scene) }
                preview(c, .horizontal)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
                    .overlay(alignment: .bottomLeading) { formatBadge("16:9") }
                HStack(alignment: .top, spacing: 14) {
                    preview(c, .vertical)
                        .frame(width: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                        .overlay(alignment: .bottomLeading) { formatBadge("9:16") }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.name).font(.fc(14, .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        Text(c.caption).font(.fc(11.5, .medium)).foregroundStyle(Theme.text3)
                        if let d = c.detail {
                            Text(d).font(.fc(11.5)).foregroundStyle(Theme.text2).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.fc(24)).foregroundStyle(Theme.text4)
                    Text("Pick a background to see it on both canvases.").font(.fc(12.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            }
            Spacer(minLength: 0)
            if sharedCount > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Change it in all \(sharedCount) scenes that use it", isOn: $everyScene).toggleStyle(.checkbox).font(.fc(12))
                    Text(everyScene ? (studio.previewMode ? "Every scene with this background changes, including the one on air, right away."
                                                          : "Every scene with this background changes.")
                                    : "Only “\(studio.editingScene?.name ?? "this scene")” changes.")
                        .font(.fc(11)).foregroundStyle(Theme.text4)
                }
            }
            let inUse = selection?.id == current
            Button { apply() } label: {
                Text(inUse ? "In use" : "Use background").font(.fc(13, .bold))
                    .foregroundStyle(inUse ? Theme.text3 : Theme.accentInk)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Capsule().fill(inUse ? Theme.control : Theme.accent))
            }
            .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(selection == nil || inUse)
        }
        .padding(18)
        .task(id: "\(selection?.id ?? "")|\(previewMode)|\(previewScene?.id.uuidString ?? "")") {
            // Re-rendered five times a second so the camera and screens stay live.
            while !Task.isCancelled {
                await renderSceneShots()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// The scene render for the selected background, or the picture alone.
    @ViewBuilder func preview(_ c: BackgroundChoice, _ canvas: CanvasKind) -> some View {
        if previewMode == .scene, shotsFor == c.id, let shot = sceneShots[canvas] {
            Image(decorative: shot, scale: 1).resizable().aspectRatio(canvas == .horizontal ? 16 / 9 : 9 / 16, contentMode: .fit)
        } else {
            BackgroundThumb(choice: c, canvas: canvas, maxPixel: canvas == .horizontal ? 960 : 720)
        }
    }

    func sceneLine(_ scene: StudioScene) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Theme.live).frame(width: 6, height: 6)
                Text("Live, in").font(.fc(11.5)).foregroundStyle(Theme.text3)
                if previewScenes.count > 1 {
                    Menu(scene.name) { ForEach(previewScenes) { s in Button(s.name) { previewSceneID = s.id } } }
                        .menuStyle(.borderlessButton).fixedSize().font(.fc(11.5, .semibold)).help("Preview another scene with this background")
                } else {
                    Text(scene.name).font(.fc(11.5, .semibold)).foregroundStyle(Theme.text2)
                }
            }
            if !showsBackground(scene) {
                Text("A layer fills this whole scene, so its background doesn't show.").font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
        }
    }

    /// Scenes the change reaches: every scene sharing the background, or just the editing scene.
    var previewScenes: [StudioScene] {
        if case .source(let id) = target, everyScene, sharedCount > 1 {
            return studio.scenes.filter { s in (s.horizontal + s.vertical).contains { $0.sourceID == id && $0.role == .background } }
        }
        return studio.editingScene.map { [$0] } ?? []
    }

    /// The scene shown: the one picked, else the editing scene if its background shows, else the first that shows it.
    var previewScene: StudioScene? {
        let list = previewScenes
        if let id = previewSceneID, let s = list.first(where: { $0.id == id }) { return s }
        if let e = studio.editingScene, list.contains(where: { $0.id == e.id }), showsBackground(e) { return e }
        return list.first(where: showsBackground) ?? list.first
    }

    /// False when an opaque layer (camera, screen, colour…) covers the whole 16:9 canvas.
    func showsBackground(_ scene: StudioScene) -> Bool {
        !scene.items(for: .horizontal).contains { it in
            let t = it.transform
            guard it.isVisible, it.role != .background, it.opacity > 0.99, it.mask == .none, t.rotationDegrees == 0,
                  t.x <= 0.001, t.y <= 0.001, t.x + t.width >= 0.999, t.y + t.height >= 0.999,
                  let kind = studio.source(it.sourceID)?.kind else { return false }
            switch kind {
            case .camera, .display, .window, .application, .color, .testPattern, .guest, .guestScreen, .guestGrid: return true
            default: return false
            }
        }
    }

    /// The scene's layers with its background swapped for the selected picture (one added if the scene has none).
    func previewItems(_ scene: StudioScene, _ canvas: CanvasKind) -> (items: [SceneItem], key: UUID) {
        var items = scene.items(for: canvas)
        if let b = items.first(where: { $0.role == .background }) { return (items, b.sourceID) }
        items.insert(SceneItem(sourceID: Self.placeholderID, role: .background, transform: .full, fit: .fill), at: 0)
        return (items, Self.placeholderID)
    }

    @MainActor func renderSceneShots() async {
        guard previewMode == .scene, let c = selection, let scene = previewScene else { return }
        var shots: [CanvasKind: CGImage] = [:]
        for (canvas, width, px) in [(CanvasKind.horizontal, CGFloat(640), 960), (.vertical, CGFloat(240), 720)] {
            guard let bg = await BackgroundImages.image(c, canvas: canvas, maxPixel: px) else { continue }
            let (items, key) = previewItems(scene, canvas)
            let engine = studio.engine, picture = CIImage(cgImage: bg)
            shots[canvas] = await Task.detached(priority: .userInitiated) {
                engine.snapshot(items: items, canvas: canvas, width: width, replacing: [key: picture])
            }.value
        }
        guard !Task.isCancelled, selection?.id == c.id else { return }
        sceneShots = shots; shotsFor = c.id
    }

    func formatBadge(_ s: String) -> some View {
        Text(s).font(.fc(10, .bold)).foregroundStyle(.white)
            .padding(.horizontal, 6).frame(height: 17).background(Capsule().fill(.black.opacity(0.55))).padding(6)
    }

    func apply() {
        guard let c = selection, c.id != current else { return }
        switch target {
        case .scene: studio.setSceneBackground(.wallpaper(c.id), name: c.name)
        case .source(let id):
            if everyScene || sharedCount <= 1 { studio.changeBackground(id, to: c) }
            else { studio.setSceneBackground(.wallpaper(c.id), name: c.name) }
        }
        dismiss()
    }

    /// Test control: "group:<key|all>", "tone:any|dark|light", "canvas:horizontal|vertical", "select:<id>",
    /// "search:<text>", "every:on|off", "preview:scene|picture", "scene:<name>", "apply".
    func runTestCommand() {
        guard let cmd = studio.testBackgroundPicker?.command else { return }
        let (k, v) = cmd.firstIndex(of: ":").map { (String(cmd[..<$0]), String(cmd[cmd.index(after: $0)...])) } ?? (cmd, "")
        switch k {
        case "group": group = v == "all" ? nil : v
        case "tone": tone = Tone.allCases.first { $0.rawValue.lowercased() == v } ?? .any
        case "canvas": canvas = CanvasKind(rawValue: v) ?? .horizontal
        case "select": selected = v
        case "search": search = v
        case "every": everyScene = v != "off"
        case "apply": apply()
        case "preview": previewMode = v == "picture" ? .picture : .scene
        case "scene": previewSceneID = studio.scenes.first { $0.name == v }?.id
        default: break
        }
    }
}

// MARK: - Layer tab

/// The background layer's picture, with a button that opens the picker.
struct BackgroundCurrentRow: View {
    @Environment(Studio.self) var studio
    let source: SourceRecord
    let wallpaperID: String
    var body: some View {
        let choice = BackgroundCatalog.choice(wallpaperID)
        let vertical = studio.editingCanvas == .vertical
        VStack(alignment: .leading, spacing: 10) {
            Button { studio.backgroundTarget = .source(source.id) } label: {
                HStack(spacing: 10) {
                    Group {
                        if let choice { BackgroundThumb(choice: choice, canvas: studio.editingCanvas, maxPixel: 240) }
                        else { Theme.programWell.aspectRatio(16 / 9, contentMode: .fit) }
                    }
                    .frame(width: vertical ? 44 : 104)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice?.name ?? source.name).font(.fc(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                        Text(choice?.caption ?? "Background").font(.fc(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Choose a different background")
            PillButton(title: "Change background…", systemImage: "photo.on.rectangle", prominent: true) { studio.backgroundTarget = .source(source.id) }
            let n = studio.sceneCount(using: source.id)
            if n > 1 { Text("Used in \(n) scenes").font(.fc(10.5)).foregroundStyle(Theme.text4) }
        }
    }
}
