import SwiftUI
import AppKit
import QuartzCore
import FramecastEngine

struct ProgramArea: View {
    @Environment(Studio.self) var studio
    var body: some View {
        GeometryReader { geo in
            let kinds = studio.stage.kinds.filter { $0 == .horizontal || studio.isVerticalOn }
            if studio.previewMode {
                PreviewBeforeAir(kinds: kinds, size: geo.size)
            } else {
                // Status chips float over the top-left corner; the canvases get the full height.
                let avail = CGSize(width: geo.size.width, height: max(100, geo.size.height - 36))
                let sizes = kinds.map { CanvasStage.fittedSize(studio.settings.canvas($0), available: avail, count: kinds.count) }
                let rowH = sizes.map(\.height).max() ?? 0
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        ForEach(Array(kinds.enumerated()), id: \.element) { i, k in CanvasStage(canvas: k, size: sizes[i], count: kinds.count) }
                    }
                    .frame(height: rowH)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 18)
        .overlay(alignment: .topLeading) { if !studio.previewMode { ProgramHeader().padding(.top, 10).padding(.leading, 14) } }
        .overlay(alignment: .bottom) {
            if let f = studio.flash {
                Text(f).font(.fc(12, .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Capsule().fill(Theme.selected)).overlay(Capsule().stroke(Theme.hairline))
                    .padding(.bottom, 14).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: studio.flash)
        .background(Theme.programWell)
    }
}

/// Small chips over the canvases: what's on air and whether you're live or recording.
struct ProgramHeader: View {
    @Environment(Studio.self) var studio
    var body: some View {
        HStack(spacing: 6) {
            if studio.streaming.isLive {
                chip("LIVE", fill: Theme.live, text: .white)
            }
            if studio.isRecording {
                HStack(spacing: 5) { Circle().fill(Theme.live).frame(width: 6, height: 6); Text(studio.recordingPausedAt == nil ? "REC" : "PAUSED") }
                    .font(.fc(10.5, .heavy)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Theme.selected))
            }
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up").font(.fc(10, .semibold)).foregroundStyle(Theme.text3)
                Text(studio.programScene(studio.editingCanvas)?.name(for: studio.editingCanvas) ?? "No scene").font(.fc(11.5, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 9).frame(height: 20).background(Capsule().fill(Theme.control.opacity(0.9)))
        }
    }
    func chip(_ t: String, fill: Color, text: Color) -> some View {
        Text(t).font(.fc(10.5, .heavy)).tracking(0.4).foregroundStyle(text)
            .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(fill))
    }
}

struct LiveStats: View {
    @Environment(Studio.self) var studio
    var body: some View {
        HStack(spacing: 14) {
            if studio.streaming.isLive {
                let kbps = studio.streaming.stats.values.reduce(0.0) { $0 + $1.sendKbps }
                stat(String(format: "%.1f", kbps / 1000), "Mbps")
                stat("\(studio.streaming.liveCount)/\(studio.streaming.enabled.count)", "on air")
            }
            if studio.isRecording || studio.streaming.isLive {
                stat("\(studio.droppedFrames)", "dropped frames")
            }
        }
        .padding(.trailing, 6)
    }
    func stat(_ v: String, _ l: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(v).font(.fc(13, .bold).monospacedDigit())
            Text(l).font(.fc(11)).foregroundStyle(Theme.text3)
        }
    }
}

struct CanvasTabs: View {
    @Environment(Studio.self) var studio
    var body: some View {
        HStack(spacing: 2) {
            tab(.horizontal, "16:9", w: 16, h: 10)
            tab(.vertical, "9:16", w: 8, h: 13)
            if studio.isVerticalOn { tab(.both, "Both", w: 0, h: 0) }
        }
        .padding(3)
        .background(Capsule().fill(Theme.control2))
        .overlay(Capsule().stroke(Theme.hairline))
    }
    func tab(_ s: StageCanvases, _ title: String, w: CGFloat, h: CGFloat) -> some View {
        let on = studio.stage == s
        return Button {
            if s != .horizontal && !studio.isVerticalOn { studio.setVertical(true) }
            studio.stage = s
        } label: {
            HStack(spacing: 9) {
                if s == .both {
                    HStack(spacing: 2) { glyph(on, 12, 8); glyph(on, 6, 10) }
                } else { glyph(on, w, h) }
                Text(title).font(.fc(12, .semibold)).foregroundStyle(on ? Theme.text : Theme.text2)
            }
            .padding(.leading, 10).padding(.trailing, 12).frame(height: 26)
            .background(Capsule().fill(on ? Theme.selected : .clear))
        }
        .buttonStyle(.plain)
        .help(s == .both ? "Show both canvases; click one to choose which one scene changes and edits apply to" : "Show and edit the \(title) canvas")
    }
    func glyph(_ on: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(on ? Theme.accentFill : .clear)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(on ? Theme.accent : Theme.text4, lineWidth: 1.5))
            .frame(width: w, height: h)
    }
}

/// One canvas preview with the layer editor on top.
struct CanvasStage: View {
    @Environment(Studio.self) var studio
    let canvas: CanvasKind
    let size: CGSize
    let count: Int
    /// Which frames to show: what's on air, or (preview mode) the scene being set up.
    var showsPreview = false
    static func fittedSize(_ cfg: CanvasSetting, available: CGSize, count: Int) -> CGSize {
        let aspect = CGFloat(cfg.width) / CGFloat(cfg.height)
        let slotW = (available.width - CGFloat(count - 1) * 14) / CGFloat(count)
        var w = slotW, h = w / aspect
        if h > available.height { h = available.height; w = h * aspect }
        return CGSize(width: floor(w), height: floor(h))
    }
    var body: some View {
        let isEditing = studio.editingCanvas == canvas
        ZStack {
            PreviewLayerView(canvas: canvas, hub: showsPreview ? studio.scenePreview : studio.preview)
            if studio.settings.s.previewQuality == .off {
                Text("Preview off · turn it on in Settings › General").font(.fc(12)).foregroundStyle(Theme.text3)
            }
            CanvasEditorOverlay(canvas: canvas, size: size)
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.canvasEmpty)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(count > 1 && isEditing ? Theme.accent : Theme.hairline, lineWidth: count > 1 && isEditing ? 2 : 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 24)
        .overlay(alignment: .topLeading) {
            if count > 1 {
                Text(canvas.title).font(.fc(10, .bold)).foregroundStyle(isEditing ? Theme.accentInk : Theme.text2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isEditing ? Theme.accent : Theme.selected)).padding(8)
            }
        }
        .onTapGesture { if count > 1 { studio.editingCanvas = canvas } }
        .help(count > 1 ? "Click to make scene changes and edits apply to this canvas" : "")
    }
}

/// Shows composited frames by handing their IOSurface to a CALayer (no copies).
struct PreviewLayerView: NSViewRepresentable {
    let canvas: CanvasKind
    let hub: PreviewHub
    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        hub.add(v, canvas: canvas) { [weak v] pb in v?.show(pb) }
        return v
    }
    func updateNSView(_ v: PreviewNSView, context: Context) {
        hub.remove(v)
        hub.add(v, canvas: canvas) { [weak v] pb in v?.show(pb) }
    }
    static func dismantleNSView(_ v: PreviewNSView, coordinator: ()) {}
}

final class PreviewNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ pb: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }
}

/// Click a layer to select it; drag to move; drag a corner to resize. Snaps to the canvas centre and edges.
struct CanvasEditorOverlay: View {
    @Environment(Studio.self) var studio
    let canvas: CanvasKind
    let size: CGSize
    @Local var hovering = false
    @Local var drag: DragState?
    @Local var guides: [Guide] = []

    struct DragState { var itemID: UUID; var start: ItemTransform; var corner: Int? }
    struct Guide: Hashable { var vertical: Bool; var pos: CGFloat }

    var body: some View {
        let items = studio.editScene(canvas)?.items(for: canvas) ?? []
        let isEditing = studio.editingCanvas == canvas
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { location in
                    if !isEditing { studio.editingCanvas = canvas }
                    studio.selectedItemID = hit(items, location)?.id
                    if studio.selectedItemID != nil { studio.rail = .edit }
                }
            if hovering || drag != nil || studio.selectedItemID != nil {
                ForEach(items.filter { $0.isVisible && $0.role != .background }) { it in
                    let r = rect(it.transform)
                    let selected = it.id == studio.selectedItemID && isEditing
                    Rectangle().stroke(selected ? Theme.accent : Color.white.opacity(hovering ? 0.25 : 0), lineWidth: selected ? 2 : 1)
                        .frame(width: max(1, r.width), height: max(1, r.height))
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                    if selected && !it.isLocked {
                        ForEach(0..<4, id: \.self) { c in
                            let p = corner(r, c)
                            RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.accent, lineWidth: 1.5))
                                .offset(x: p.x - 5, y: p.y - 5)
                                .gesture(resizeGesture(it, corner: c))
                        }
                    }
                }
            }
            ForEach(guides, id: \.self) { g in
                Rectangle().fill(Theme.accent.opacity(0.9))
                    .frame(width: g.vertical ? 1 : size.width, height: g.vertical ? size.height : 1)
                    .offset(x: g.vertical ? g.pos : 0, y: g.vertical ? 0 : g.pos)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(moveGesture(items))
        .onHover { hovering = $0 }
    }

    func rect(_ t: ItemTransform) -> CGRect {
        CGRect(x: t.x * size.width, y: t.y * size.height, width: t.width * size.width, height: t.height * size.height)
    }
    func corner(_ r: CGRect, _ c: Int) -> CGPoint {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)][c]
    }
    func hit(_ items: [SceneItem], _ p: CGPoint) -> SceneItem? {
        items.reversed().first { $0.isVisible && $0.role != .background && rect($0.transform).contains(p) }
    }

    func moveGesture(_ items: [SceneItem]) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if drag == nil {
                    guard let it = hit(items, v.startLocation), !it.isLocked else { return }
                    studio.editingCanvas = canvas
                    studio.selectedItemID = it.id
                    drag = DragState(itemID: it.id, start: it.transform, corner: nil)
                }
                guard let d = drag, d.corner == nil else { return }
                var t = d.start
                t.x = d.start.x + v.translation.width / size.width
                t.y = d.start.y + v.translation.height / size.height
                t = snap(t)
                studio.updateItem(d.itemID) { $0.transform = t }
            }
            .onEnded { _ in drag = nil; guides = [] }
    }

    func resizeGesture(_ it: SceneItem, corner c: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if drag == nil { drag = DragState(itemID: it.id, start: it.transform, corner: c) }
                guard let d = drag else { return }
                var t = d.start
                let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                // Keep the picture's aspect when dragging a corner (hold ⌥ for free resize).
                let free = NSEvent.modifierFlags.contains(.option)
                let aspect = d.start.width / max(0.0001, d.start.height)
                var nw = d.start.width + (c == 1 || c == 3 ? dx : -dx)
                var nh = free ? d.start.height + (c >= 2 ? dy : -dy) : nw / aspect
                nw = max(0.03, nw); nh = max(0.03, nh)
                t.width = nw; t.height = nh
                if c == 0 || c == 2 { t.x = d.start.x + d.start.width - nw }
                if c == 0 || c == 1 { t.y = d.start.y + d.start.height - nh }
                studio.updateItem(d.itemID) { $0.transform = t }
            }
            .onEnded { _ in drag = nil; guides = [] }
    }

    /// Snap to canvas edges and centre lines within 8 pt.
    func snap(_ t0: ItemTransform) -> ItemTransform {
        var t = t0
        var g: [Guide] = []
        let tol = 8 / size.width, tolY = 8 / size.height
        let xs: [(Double, Double)] = [(t.x, 0), (t.x + t.width / 2, 0.5), (t.x + t.width, 1)]
        for (v, target) in xs where abs(v - target) < tol { t.x += target - v; g.append(Guide(vertical: true, pos: target * size.width)); break }
        let ys: [(Double, Double)] = [(t.y, 0), (t.y + t.height / 2, 0.5), (t.y + t.height, 1)]
        for (v, target) in ys where abs(v - target) < tolY { t.y += target - v; g.append(Guide(vertical: false, pos: target * size.height)); break }
        guides = g
        return t
    }
}

/// Preview before air: the scene being set up (editable, large) next to what viewers see now, with the button
/// that puts the preview on air.
struct PreviewBeforeAir: View {
    @Environment(Studio.self) var studio
    let kinds: [CanvasKind]
    let size: CGSize
    var body: some View {
        let colW = min(320, max(180, size.width * 0.3))
        let avail = CGSize(width: size.width - colW - 20, height: max(100, size.height - 40))
        let sizes = kinds.map { CanvasStage.fittedSize(studio.settings.canvas($0), available: avail, count: kinds.count) }
        let airAvail = CGSize(width: colW, height: max(80, min(size.height * 0.42, 260)))
        let airSizes = kinds.map { CanvasStage.fittedSize(studio.settings.canvas($0), available: airAvail, count: kinds.count) }
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                MonitorLabel(title: "PREVIEW", scene: studio.previewScene?.name(for: studio.editingCanvas) ?? "", color: Theme.healthy,
                             note: "Edits here stay off air")
                HStack(spacing: 14) {
                    ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                        CanvasStage(canvas: k, size: sizes[i], count: kinds.count, showsPreview: true)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.healthy.opacity(0.8), lineWidth: 2))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                MonitorLabel(title: "ON AIR", scene: studio.programScene(studio.editingCanvas)?.name(for: studio.editingCanvas) ?? "", color: Theme.live,
                             note: nil)
                HStack(spacing: 8) {
                    ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                        PreviewLayerView(canvas: k, hub: studio.preview)
                            .frame(width: airSizes[i].width, height: airSizes[i].height)
                            .background(Theme.canvasEmpty)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.live.opacity(0.85), lineWidth: 2))
                    }
                }
                TakeButton()
                Text("⌘↩, or double-click a scene").font(.fc(11)).foregroundStyle(Theme.text4)
            }
            .frame(width: colW, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
    }
}

struct MonitorLabel: View {
    let title: String
    let scene: String
    let color: Color
    let note: String?
    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.fc(10, .heavy)).tracking(0.5).foregroundStyle(.white)
                .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(color))
            Text(scene).font(.fc(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            if let note { Text("· \(note)").font(.fc(11)).foregroundStyle(Theme.text4).lineLimit(1) }
        }
    }
}

/// Puts the preview on air. When the preview is the scene already on air, it sends any edits made since.
struct TakeButton: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let same = studio.previewScene?.id == studio.programScene(studio.editingCanvas)?.id
        let waiting = studio.stage.kinds.contains { studio.hasUnairedChanges($0) }
        Button { studio.takePreview() } label: {
            HStack(spacing: 7) {
                Image(systemName: same ? "arrow.triangle.2.circlepath" : "arrow.right").font(.fc(12, .bold))
                Text(same ? (waiting ? "Update on air" : "On air now") : "Put on air").font(.fc(13, .bold))
            }
            .foregroundStyle(same && !waiting ? Theme.text3 : Theme.accentInk)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(Capsule().fill(same && !waiting ? Theme.control : Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(same && !waiting)
        .help(same ? "Send the edits you made in the preview to the air" : "Switch the air to the preview scene with the transition")
    }
}
