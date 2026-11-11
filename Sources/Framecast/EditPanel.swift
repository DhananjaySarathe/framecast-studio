import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FramecastEngine

enum EditTab: String, CaseIterable { case transform, filters, color
    var title: String { rawValue.capitalized }
}

struct EditPanel: View {
    @Environment(Studio.self) var studio
    @Local var tab: EditTab = .transform
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Layer", subtitle: studio.editingScene?.name(for: studio.editingCanvas)) {
                Button { studio.isAddingSource = true } label: { Label("Source", systemImage: "plus").font(.fc(12, .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).help("Add a camera, screen, window, image or text, then drag it into place.")
            }
            LayerList().frame(maxHeight: 230)
            Hairline()
            if let item = studio.selectedItem {
                HStack(spacing: 2) {
                    ForEach(EditTab.allCases, id: \.self) { t in
                        Button { tab = t } label: {
                            Text(t.title).font(.fc(12, .semibold)).foregroundStyle(tab == t ? Theme.text : Theme.text2)
                                .frame(maxWidth: .infinity).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Theme.selected : .clear))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(3).background(RoundedRectangle(cornerRadius: 9).fill(Theme.control2)).padding(.horizontal, 12).padding(.top, 12)
                AllScenesToggle(item: item).padding(.horizontal, 14).padding(.vertical, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .transform: TransformTab(item: item)
                        case .filters: FiltersTab(item: item)
                        case .color: ColorTab(item: item)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click.2").font(.fc(20)).foregroundStyle(Theme.text4)
                    Text("Select a layer to edit it, here or on the canvas.").font(.fc(12.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                }
                .padding(24).frame(maxHeight: .infinity)
            }
        }
    }
}

/// Whether layer edits stay in this scene (default) or also go to this layer in every other scene.
struct AllScenesToggle: View {
    @Environment(Studio.self) var studio
    let item: SceneItem
    var body: some View {
        let others = studio.otherScenes(showing: item.sourceID)
        let name = studio.source(item.sourceID)?.name ?? "this layer"
        VStack(alignment: .leading, spacing: 3) {
            Toggle("Update in all scenes", isOn: Binding(get: { studio.editsAllScenes }, set: { studio.editsAllScenes = $0 }))
                .toggleStyle(.checkbox).font(.fc(12, .semibold))
                .disabled(item.role == .background || others == 0)
            Text(item.role == .background ? "Backgrounds change from Change background…" :
                 others == 0 ? "\(name) isn't in any other scene." :
                 studio.editsAllScenes ? "Shape, filters, mirroring and opacity also change for \(name) in the \(others) other scene\(others == 1 ? "" : "s"). Position and size stay per scene."
                                       : "Changes stay in “\(studio.editingScene?.name(for: studio.editingCanvas) ?? "this scene")”.")
                .font(.fc(10.5)).foregroundStyle(studio.editsAllScenes && others > 0 ? Theme.warning : Theme.text4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Off: every change stays in this scene. On: changes to shape, filters, mirroring, opacity and fit also go to this layer in every scene that shows it; position and size always stay per scene.")
    }
}

struct LayerList: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let items = studio.editingItems
        ScrollView {
            VStack(spacing: 2) {
                if items.isEmpty { Text("This scene is empty. Add something with + Source.").font(.fc(12)).foregroundStyle(Theme.text3).padding(16) }
                ForEach(items.reversed()) { it in LayerRow(item: it) }
            }
            .padding(8)
        }
    }
}

struct LayerRow: View {
    @Environment(Studio.self) var studio
    let item: SceneItem
    var body: some View {
        let src = studio.source(item.sourceID)
        let selected = studio.selectedItemID == item.id
        HStack(spacing: 8) {
            Image(systemName: src?.kind.iconName ?? "questionmark").font(.fc(11, .semibold)).foregroundStyle(Theme.icon).frame(width: 16)
            Text(src?.name ?? "Missing source").font(.fc(12.5, .semibold)).lineLimit(1)
            if case .failed(let m)? = studio.sourceStates[item.sourceID] {
                Image(systemName: "exclamationmark.triangle.fill").font(.fc(10)).foregroundStyle(Theme.warning).help(m)
            }
            Spacer()
            Button { studio.updateItem(item.id) { $0.isLocked.toggle() } } label: {
                Image(systemName: item.isLocked ? "lock.fill" : "lock.open").font(.fc(10.5)).foregroundStyle(item.isLocked ? Theme.text : Theme.text4)
            }.buttonStyle(.plain).help(item.isLocked ? "Unlock Layer" : "Lock Layer")
            Button { studio.updateItem(item.id) { $0.isVisible.toggle() } } label: {
                Image(systemName: item.isVisible ? "eye" : "eye.slash").font(.fc(10.5)).foregroundStyle(item.isVisible ? Theme.text : Theme.text4)
            }.buttonStyle(.plain).help(item.isVisible ? "Hide" : "Show")
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selected : .clear))
        .contentShape(Rectangle())
        .onTapGesture { studio.selectedItemID = item.id }
        .contextMenu {
            Button("Bring Forward") { studio.reorder(item.id, up: true) }
            Button("Send Backward") { studio.reorder(item.id, up: false) }
            Menu("Swap Input") {
                ForEach(studio.collection.sources.filter { $0.kind.hasVideo && $0.id != item.sourceID }) { s in
                    Button(s.name) { studio.updateItem(item.id) { $0.sourceID = s.id } }
                }
            }
            if item.role == .background { Button("Change Background…") { studio.chooseBackground() } }
            Button(item.isMirrored ? "Unmirror" : "Flip horizontally") { studio.updateItem(item.id) { $0.isMirrored.toggle() } }
            Divider()
            Button("Remove from Scene") { studio.removeFromLayout(item.id) }
            Button("Remove from studio", role: .destructive) { studio.removeFromStudio(item.sourceID) }
        }
    }
}

/// Slider with a number box: type a value, ↑/↓ to nudge (⇧ for 10×), double-click the name to reset.
struct ValueRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.01
    var reset: Double
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var parse: (String) -> Double? = { Double($0) }
    @Local var text = ""
    @Local var editing = false
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.fc(11.5)).foregroundStyle(Theme.text2).frame(width: 74, alignment: .leading)
                .onTapGesture(count: 2) { value = reset }
                .help("Drag to adjust · double-click to reset")
            Slider(value: $value, in: range).controlSize(.small).tint(Theme.accent)
            TextField("", text: Binding(get: { editing ? text : format(value) }, set: { text = $0; editing = true }))
                .textFieldStyle(.plain).font(.fc(11, .medium).monospacedDigit()).multilineTextAlignment(.trailing)
                .frame(width: 50, height: 22).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.fieldBorder))
                .onSubmit { if let v = parse(text) { value = min(max(v, range.lowerBound), range.upperBound) }; editing = false }
                .onKeyPress(.upArrow) { value = min(range.upperBound, value + step * (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)); return .handled }
                .onKeyPress(.downArrow) { value = max(range.lowerBound, value - step * (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)); return .handled }
        }
    }
}

struct EditSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            content
        }
    }
}

struct TransformTab: View {
    @Environment(Studio.self) var studio
    let item: SceneItem
    func bind(_ kp: WritableKeyPath<ItemTransform, Double>) -> Binding<Double> {
        Binding(get: { item.transform[keyPath: kp] }, set: { v in studio.updateItem(item.id) { $0.transform[keyPath: kp] = v } })
    }
    func crop(_ kp: WritableKeyPath<ItemCrop, Double>) -> Binding<Double> {
        Binding(get: { item.crop[keyPath: kp] }, set: { v in studio.updateItem(item.id) { $0.crop[keyPath: kp] = v } })
    }
    var body: some View {
        let pct: (Double) -> String = { String(format: "%.1f%%", $0 * 100) }
        let parsePct: (String) -> Double? = { Double($0.replacingOccurrences(of: "%", with: "")).map { $0 / 100 } }
        if let src = studio.source(item.sourceID), case .media = src.kind {
            EditSection(title: "Playback") { MediaControls(source: src) }
        }
        // A background's picture comes first: it's what people change most on that layer.
        if let src = studio.source(item.sourceID), case .wallpaper(let w) = src.kind {
            EditSection(title: "Background") { BackgroundCurrentRow(source: src, wallpaperID: w) }
        }
        if showsCamera {
            EditSection(title: "Camera angles") {
                Toggle("Shuffle camera angles here", isOn: Binding(get: { item.shufflesAngles == true }, set: { on in
                    if on, let scene = studio.editingScene { studio.angles.mark(itemID: item.id, sceneID: scene.id) } else { studio.angles.unmark() }
                }))
                .toggleStyle(.switch).controlSize(.small).font(.fc(12))
                .help("This frame shows the angle you pick or the shuffle cuts to (Angles). One frame in the whole studio.")
                Text("Its background and layout stay; only the picture in this frame changes. Angles has the cameras and the shuffle.")
                    .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                // Angles from one camera: a medium and a close-up cut from this camera's picture.
                if case .camera? = studio.source(item.sourceID)?.kind {
                    if let shots = studio.angles.settings.virtual.cameras[item.sourceID.uuidString], shots.any {
                        let made = shots.medium && shots.close ? "a medium and a close-up" : shots.medium ? "a medium shot" : "a close-up"
                        Text("This camera also makes \(made) (Angles › From one camera).")
                            .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                    } else {
                        PillButton(title: "Make angles from this camera", systemImage: "crop") {
                            studio.angles.setVirtual(camera: item.sourceID, shots: VirtualShots())
                        }
                        .disabled(studio.isRecording)
                        .help(studio.isRecording ? "After the recording: each angle has its own file until it stops."
                              : "Adds a medium and a close-up that follow your face, as more angles to cut to.")
                    }
                }
            }
        }
        EditSection(title: "Position & size") {
            ValueRow(title: "X", value: bind(\.x), range: -1...2, step: 0.001, reset: 0, format: pct, parse: parsePct)
            ValueRow(title: "Y", value: bind(\.y), range: -1...2, step: 0.001, reset: 0, format: pct, parse: parsePct)
            ValueRow(title: "Width", value: bind(\.width), range: 0.01...2, step: 0.001, reset: 1, format: pct, parse: parsePct)
            ValueRow(title: "Height", value: bind(\.height), range: 0.01...2, step: 0.001, reset: 1, format: pct, parse: parsePct)
            ValueRow(title: "Rotation", value: bind(\.rotationDegrees), range: -180...180, step: 1, reset: 0, format: { String(format: "%.0f°", $0) },
                     parse: { Double($0.replacingOccurrences(of: "°", with: "")) })
            HStack(spacing: 6) {
                PillButton(title: "Fill canvas") { studio.updateItem(item.id) { $0.transform = ItemTransform(x: 0, y: 0, width: 1, height: 1, rotationDegrees: $0.transform.rotationDegrees) } }
                PillButton(title: "Center") { studio.updateItem(item.id) { $0.transform.x = (1 - $0.transform.width) / 2; $0.transform.y = (1 - $0.transform.height) / 2 } }
            }
        }
        EditSection(title: "Crop") {
            Text("Percent of the source cut from each edge.").font(.fc(11)).foregroundStyle(Theme.text4)
            ValueRow(title: "Left", value: crop(\.left), range: 0...0.9, reset: 0, format: pct, parse: parsePct)
            ValueRow(title: "Right", value: crop(\.right), range: 0...0.9, reset: 0, format: pct, parse: parsePct)
            ValueRow(title: "Top", value: crop(\.top), range: 0...0.9, reset: 0, format: pct, parse: parsePct)
            ValueRow(title: "Bottom", value: crop(\.bottom), range: 0...0.9, reset: 0, format: pct, parse: parsePct)
        }
        EditSection(title: "Fit") {
            Picker("", selection: Binding(get: { item.fit }, set: { v in studio.updateItem(item.id) { $0.fit = v } })) {
                ForEach(FitMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
        }
        EditSection(title: "Shape") {
            Picker("", selection: Binding(get: { shapeKey }, set: { v in
                studio.updateItem(item.id) { $0.mask = v == 0 ? .none : (v == 1 ? .circle : .roundedRect(radius: 0.06)) }
            })) { Text("Square").tag(0); Text("Circle").tag(1); Text("Rounded").tag(2) }
                .pickerStyle(.segmented).labelsHidden()
            if case .roundedRect(let r) = item.mask {
                ValueRow(title: "Corner Radius", value: Binding(get: { r }, set: { v in studio.updateItem(item.id) { $0.mask = .roundedRect(radius: v) } }),
                         range: 0...0.5, step: 0.005, reset: 0.06)
            }
        }
        EditSection(title: "Look") {
            ValueRow(title: "Opacity", value: Binding(get: { item.opacity }, set: { v in studio.updateItem(item.id) { $0.opacity = v } }),
                     range: 0...1, reset: 1, format: { String(format: "%.0f%%", $0 * 100) }, parse: { Double($0.replacingOccurrences(of: "%", with: "")).map { $0 / 100 } })
            Toggle("Mirror (flip left to right)", isOn: Binding(get: { item.isMirrored }, set: { v in studio.updateItem(item.id) { $0.isMirrored = v } }))
                .toggleStyle(.switch).controlSize(.small).font(.fc(12))
                .help("Flip it left to right. Viewers and recordings see it flipped too.")
        }
        if let src = studio.source(item.sourceID) { SourceSettings(source: src) }
    }
    var shapeKey: Int { switch item.mask { case .none: 0; case .circle: 1; case .roundedRect: 2 } }
    /// A camera frame (or the one already marked) can show the camera angles.
    var showsCamera: Bool {
        if case .camera? = studio.source(item.sourceID)?.kind { return true }
        return item.shufflesAngles == true
    }
}

/// Per-source settings shown under the layer (text content, camera device, image file).
struct SourceSettings: View {
    @Environment(Studio.self) var studio
    let source: SourceRecord
    @Local var text = ""
    var body: some View {
        switch source.kind {
        case .text(let style):
            EditSection(title: "Text") {
                TextField("Your text here", text: Binding(get: { text.isEmpty ? style.text : text }, set: { text = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { var s = style; s.text = text; studio.updateSource(source.id) { $0.kind = .text(s) } }
                Text("Press Return to apply").font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
        case .camera(_, let w, let h, let f):
            EditSection(title: "Camera") {
                Picker("", selection: Binding(get: { currentCamera }, set: { id in studio.updateSource(source.id) { $0.kind = .camera(deviceID: id, width: w, height: h, fps: f) } })) {
                    Text("Default camera").tag("")
                    ForEach(CameraSource.devices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }.labelsHidden()
                Text("Applies everywhere this camera appears").font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
        case .image(let path):
            EditSection(title: "Image") {
                Text((path as NSString).lastPathComponent).font(.fc(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                PillButton(title: "Choose a picture…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                    if p.runModal() == .OK, let u = p.url { studio.updateSource(source.id) { $0.kind = .image(path: u.path) }; studio.engine.restartSource(source.id) }
                }
            }
        case .countdown(let style, let endsAt):
            EditSection(title: "Countdown") {
                Text(endsAt > Date().timeIntervalSince1970 ? "Counting down to \(Date(timeIntervalSince1970: endsAt).formatted(date: .omitted, time: .shortened))" : "Finished (shows 00:00)")
                    .font(.fc(11.5)).foregroundStyle(Theme.text2)
                HStack(spacing: 6) {
                    ForEach([1, 3, 5, 10, 15], id: \.self) { m in
                        PillButton(title: "\(m) min") { studio.restartCountdown(source.id, style: style, minutes: m) }
                    }
                }
                Text("Starts counting from now").font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
        default: EmptyView()
        }
    }
    var currentCamera: String { if case .camera(let id, _, _, _) = source.kind { return id }; return "" }
}

struct FiltersTab: View {
    @Environment(Studio.self) var studio
    let item: SceneItem
    var body: some View {
        EditSection(title: "Filters") {
            Text("Filters run top to bottom.").font(.fc(11)).foregroundStyle(Theme.text4)
            if item.filters.isEmpty { Text("No filters on this layer.").font(.fc(12)).foregroundStyle(Theme.text3) }
            ForEach(item.filters) { f in FilterEditor(item: item, filter: f) }
            HStack(spacing: 6) {
                PillButton(title: "Chroma key", systemImage: "plus") { add(.chromaKey(ChromaKeySettings())) }
                PillButton(title: "Luma key", systemImage: "plus") { add(.lumaKey(LumaKeySettings())) }
            }
            PillButton(title: "Color correction", systemImage: "plus") { add(.colorCorrection(ColorCorrection())) }
        }
        if let src = studio.source(item.sourceID), case .camera = src.kind { CameraLUTEditor(source: src) }
    }
    func add(_ k: FilterKind) { studio.updateItem(item.id) { $0.filters.append(FilterSpec(kind: k)) } }
}

struct FilterEditor: View {
    @Environment(Studio.self) var studio
    let item: SceneItem
    let filter: FilterSpec
    func update(_ f: @escaping (inout FilterSpec) -> Void) {
        studio.updateItem(item.id) { it in if let i = it.filters.firstIndex(where: { $0.id == filter.id }) { f(&it.filters[i]) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(filter.kind.title, isOn: Binding(get: { filter.isEnabled }, set: { v in update { $0.isEnabled = v } }))
                    .toggleStyle(.checkbox).font(.fc(12, .semibold))
                Spacer()
                Button { studio.updateItem(item.id) { $0.filters.removeAll { $0.id == filter.id } } } label: { Image(systemName: "trash").font(.fc(11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.text3).help("Remove Filter")
            }
            switch filter.kind {
            case .chromaKey(let s):
                HStack {
                    Text("Key color").font(.fc(11.5)).foregroundStyle(Theme.text2).frame(width: 74, alignment: .leading)
                    ColorPicker("", selection: Binding(get: { Color(.sRGB, red: s.key.red, green: s.key.green, blue: s.key.blue) }, set: { c in
                        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .green
                        update { if case .chromaKey(var k) = $0.kind { k.key = RGBA(ns.redComponent, ns.greenComponent, ns.blueComponent); $0.kind = .chromaKey(k) } }
                    }), supportsOpacity: false).labelsHidden()
                    Picker("", selection: Binding(get: { s.key.green >= s.key.blue ? 0 : 1 }, set: { v in
                        update { if case .chromaKey(var k) = $0.kind { k.key = v == 0 ? RGBA(0, 0.8, 0.2) : RGBA(0, 0.25, 0.9); $0.kind = .chromaKey(k) } }
                    })) { Text("Green").tag(0); Text("Blue").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 120)
                }
                chromaRow("Similarity", s.similarity, 0...1) { $0.similarity = $1 }
                chromaRow("Smoothness", s.smoothness, 0...0.5) { $0.smoothness = $1 }
                chromaRow("Spill", s.spill, 0...1) { $0.spill = $1 }
                chromaRow("Choke", s.matte.choke, 0...1) { $0.matte.choke = $1 }
                chromaRow("Edge refine", s.matte.edgeRefine, 0...1) { $0.matte.edgeRefine = $1 }
            case .lumaKey(let s):
                lumaRow("Low", s.low, 0...1) { $0.low = $1 }
                lumaRow("High", s.high, 0...1) { $0.high = $1 }
                lumaRow("Softness", s.softness, 0...0.5) { $0.softness = $1 }
                Toggle("Invert", isOn: Binding(get: { s.invert }, set: { v in update { if case .lumaKey(var k) = $0.kind { k.invert = v; $0.kind = .lumaKey(k) } } }))
                    .toggleStyle(.checkbox).font(.fc(11.5))
            case .colorCorrection(let c):
                ccRow("Brightness", c.brightness, -1...1, 0) { $0.brightness = $1 }
                ccRow("Contrast", c.contrast, 0...2, 1) { $0.contrast = $1 }
                ccRow("Saturation", c.saturation, 0...2, 1) { $0.saturation = $1 }
                ccRow("Gamma", c.gamma, 0.2...3, 1) { $0.gamma = $1 }
                ccRow("Hue", c.hueDegrees, -180...180, 0) { $0.hueDegrees = $1 }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.control2))
    }
    func chromaRow(_ t: String, _ v: Double, _ r: ClosedRange<Double>, _ set: @escaping (inout ChromaKeySettings, Double) -> Void) -> some View {
        ValueRow(title: t, value: Binding(get: { v }, set: { nv in update { if case .chromaKey(var k) = $0.kind { set(&k, nv); $0.kind = .chromaKey(k) } } }), range: r, reset: ChromaKeySettings()[keyPathFor: t])
    }
    func lumaRow(_ t: String, _ v: Double, _ r: ClosedRange<Double>, _ set: @escaping (inout LumaKeySettings, Double) -> Void) -> some View {
        ValueRow(title: t, value: Binding(get: { v }, set: { nv in update { if case .lumaKey(var k) = $0.kind { set(&k, nv); $0.kind = .lumaKey(k) } } }), range: r, reset: v)
    }
    func ccRow(_ t: String, _ v: Double, _ r: ClosedRange<Double>, _ reset: Double, _ set: @escaping (inout ColorCorrection, Double) -> Void) -> some View {
        ValueRow(title: t, value: Binding(get: { v }, set: { nv in update { if case .colorCorrection(var k) = $0.kind { set(&k, nv); $0.kind = .colorCorrection(k) } } }), range: r, reset: reset)
    }
}

extension ChromaKeySettings {
    /// Default value per slider title (used for double-click reset).
    subscript(keyPathFor title: String) -> Double {
        switch title { case "Similarity": similarity; case "Smoothness": smoothness; case "Spill": spill; default: 0 }
    }
}

struct ColorTab: View {
    @Environment(Studio.self) var studio
    let item: SceneItem
    var cc: ColorCorrection {
        for f in item.filters { if case .colorCorrection(let c) = f.kind { return c } }
        return ColorCorrection()
    }
    func set(_ change: @escaping (inout ColorCorrection) -> Void) {
        studio.updateItem(item.id) { it in
            if let i = it.filters.firstIndex(where: { if case .colorCorrection = $0.kind { return true }; return false }),
               case .colorCorrection(var c) = it.filters[i].kind { change(&c); it.filters[i].kind = .colorCorrection(c) }
            else { var c = ColorCorrection(); change(&c); it.filters.append(FilterSpec(kind: .colorCorrection(c))) }
        }
    }
    var body: some View {
        EditSection(title: "Color correction") {
            Text("Exposure, contrast and saturation").font(.fc(11)).foregroundStyle(Theme.text4)
            ValueRow(title: "Brightness", value: Binding(get: { cc.brightness }, set: { v in set { $0.brightness = v } }), range: -1...1, reset: 0)
            ValueRow(title: "Contrast", value: Binding(get: { cc.contrast }, set: { v in set { $0.contrast = v } }), range: 0...2, reset: 1)
            ValueRow(title: "Saturation", value: Binding(get: { cc.saturation }, set: { v in set { $0.saturation = v } }), range: 0...2, reset: 1)
            ValueRow(title: "Gamma", value: Binding(get: { cc.gamma }, set: { v in set { $0.gamma = v } }), range: 0.2...3, reset: 1)
            ValueRow(title: "Hue", value: Binding(get: { cc.hueDegrees }, set: { v in set { $0.hueDegrees = v } }), range: -180...180, step: 1, reset: 0,
                     format: { String(format: "%.0f°", $0) })
            PillButton(title: "Reset Color") { studio.updateItem(item.id) { $0.filters.removeAll { if case .colorCorrection = $0.kind { return true }; return false } } }
        }
    }
}

struct CameraLUTEditor: View {
    @Environment(Studio.self) var studio
    let source: SourceRecord
    var body: some View {
        EditSection(title: "Camera LUT") {
            if let lut = source.lut {
                HStack {
                    Text((lut.path as NSString).lastPathComponent).font(.fc(11.5)).lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(get: { lut.isEnabled }, set: { v in studio.updateSource(source.id) { $0.lut?.isEnabled = v } })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                if let p = studio.engine.lutProblems[lut.path] { Text(p).font(.fc(11)).foregroundStyle(Theme.warning) }
                ValueRow(title: "Amount", value: Binding(get: { lut.amount }, set: { v in studio.updateSource(source.id) { $0.lut?.amount = v } }), range: 0...1, reset: 1)
                PillButton(title: "Remove LUT", destructive: true) { studio.updateSource(source.id) { $0.lut = nil } }
            } else {
                Text("Choose a 3D LUT (.cube) for this camera. It applies in every scene and on the 9:16 canvas.").font(.fc(11)).foregroundStyle(Theme.text4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PillButton(title: "Choose .cube File…") {
                let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
                if p.runModal() == .OK, let u = p.url { studio.updateSource(source.id) { $0.lut = CameraLUT(path: u.path) } }
            }
        }
    }
}
