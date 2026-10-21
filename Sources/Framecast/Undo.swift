import Foundation
import AppKit
import FramecastEngine

/// One undoable step: the scenes, layers, sources, overlays and audio settings as they were before it.
struct UndoStep {
    var before: SceneCollection
    var label: String
}

/// Undo and redo for edits. Every change to the scene collection is recorded; changes that follow each other
/// within a moment (dragging a layer, moving a slider, a picker applying several changes) make one step.
/// Which scene is on air is never undone, so undo can't cut away from what viewers see.
extension Studio {
    static let undoLimit = 100
    static let undoQuietTime = 0.6

    var canUndo: Bool { !undoSteps.isEmpty || undoPending != nil }
    var canRedo: Bool { !redoSteps.isEmpty }
    var undoTitle: String { (undoPending.map { Self.describe($0.before, collection) } ?? undoSteps.last?.label).map { "Undo \($0)" } ?? "Undo" }
    var redoTitle: String { redoSteps.last.map { "Redo \($0.label)" } ?? "Redo" }

    /// Called for every change to the collection.
    func noteUndoableChange(from old: SceneCollection) {
        guard !isRestoringUndo else { return }
        var a = old; a.pointers = collection.pointers
        guard a != collection else { return }          // only switched what's on air
        let before = undoPending?.before ?? old
        undoPending?.work.cancel()
        let w = DispatchWorkItem { [weak self] in self?.commitPendingUndo() }
        undoPending = (before, w)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoQuietTime, execute: w)
    }

    func commitPendingUndo() {
        guard let p = undoPending else { return }
        undoPending = nil
        p.work.cancel()
        var a = p.before; a.pointers = collection.pointers
        guard a != collection else { return }          // changed and changed back
        undoSteps.append(UndoStep(before: p.before, label: Self.describe(p.before, collection)))
        if undoSteps.count > Self.undoLimit { undoSteps.removeFirst(undoSteps.count - Self.undoLimit) }
        redoSteps.removeAll()
    }

    func undo() {
        commitPendingUndo()
        guard let step = undoSteps.popLast() else { return }
        redoSteps.append(UndoStep(before: collection, label: step.label))
        restoreUndo(step.before)
        showFlash("Undo: \(step.label)")
    }

    func redo() {
        commitPendingUndo()
        guard let step = redoSteps.popLast() else { return }
        undoSteps.append(UndoStep(before: collection, label: step.label))
        restoreUndo(step.before)
        showFlash("Redo: \(step.label)")
    }

    /// ⌘Z: text being typed in a field undoes there first; otherwise the studio undoes.
    func performUndo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager, um.canUndo { um.undo(); return }
        undo()
    }
    func performRedo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager, um.canRedo { um.redo(); return }
        redo()
    }

    private func restoreUndo(_ snapshot: SceneCollection) {
        let old = collection
        var s = snapshot
        s.pointers = old.pointers
        var cut: [CanvasKind] = []
        if let h = s.pointers.horizontalProgram, !s.scenes.contains(where: { $0.id == h }) { s.pointers.horizontalProgram = s.scenes.first?.id; cut.append(.horizontal) }
        if let v = s.pointers.verticalProgram, !s.scenes.contains(where: { $0.id == v }) { s.pointers.verticalProgram = s.scenes.first?.id; cut.append(.vertical) }
        isRestoringUndo = true
        collection = s
        isRestoringUndo = false
        // Sources whose kind changed restart; audio settings reach the mixer.
        engine.sync(sources: s.sources, fpsHint: settings.s.horizontal.fps)
        engine.mixer.masterGain = Float(pow(s.audio.masterFader / 0.8, 3))
        engine.setHeadphoneLevel(s.audio.headphoneLevel)
        for e in s.elements where elementsOn[e.id] != nil { engine.updateElement(e) }
        for id in elementsOn.keys where !s.elements.contains(where: { $0.id == id }) { engine.hide(element: id); elementsOn[id] = nil }
        for c in cut { pushProgram(c, transition: .cut) }
        refreshProgram()
        if let sel = selectedItemID, !editingItems.contains(where: { $0.id == sel }) { selectedItemID = nil }
    }

    func showFlash(_ text: String) {
        flashWork?.cancel()
        flash = text
        let w = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    /// A short name for what changed between two collections.
    static func describe(_ a: SceneCollection, _ b: SceneCollection) -> String {
        if a.scenes.count < b.scenes.count { return "Add Scene" }
        if a.scenes.count > b.scenes.count { return "Delete Scene" }
        if a.scenes.map(\.id) != b.scenes.map(\.id) { return "Reorder Scenes" }
        if zip(a.scenes, b.scenes).contains(where: { $0.name != $1.name || $0.verticalName != $1.verticalName }) { return "Rename Scene" }
        if a.sources.count > b.sources.count { return "Remove Source" }
        let ai = a.scenes.flatMap { $0.horizontal + $0.vertical }, bi = b.scenes.flatMap { $0.horizontal + $0.vertical }
        if ai.count < bi.count { return "Add Layer" }
        if ai.count > bi.count { return "Remove Layer" }
        let backgrounds = { (c: SceneCollection) in c.sources.compactMap { s -> String? in if case .wallpaper(let w) = s.kind { return "\(s.id)\(w)" }; return nil } }
        if backgrounds(a) != backgrounds(b) || zip(ai, bi).contains(where: { $0.role == .background && $0.sourceID != $1.sourceID }) { return "Change Background" }
        if a.sources.count < b.sources.count { return "Add Source" }
        if ai != bi {
            if zip(ai, bi).contains(where: { $0.transform != $1.transform }) { return "Move Layer" }
            if zip(ai, bi).contains(where: { $0.isVisible != $1.isVisible }) { return "Show or Hide Layer" }
            if zip(ai, bi).contains(where: { $0.filters != $1.filters }) { return "Filter Change" }
            if ai.map(\.id) != bi.map(\.id) { return "Reorder Layers" }
            return "Layer Change"
        }
        if a.sources != b.sources {
            let audioOnly = zip(a.sources, b.sources).allSatisfy { x, y in var x = x; x.audio = y.audio; return x == y }
            return audioOnly ? "Audio Change" : "Source Change"
        }
        if a.elements != b.elements { return a.elements.count == b.elements.count ? "Overlay Change" : (a.elements.count < b.elements.count ? "Add Overlay" : "Delete Overlay") }
        if a.audio != b.audio { return "Audio Change" }
        return "Change"
    }
}
