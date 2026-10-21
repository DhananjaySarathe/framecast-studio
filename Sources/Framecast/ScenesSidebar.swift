import SwiftUI
import FramecastEngine

/// The scenes column: every scene as a live thumbnail, grouped, newest groups as they appear in the list.
struct ScenesSidebar: View {
    @Environment(Studio.self) var studio
    @Local var renaming: UUID?
    @Local var newName = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Scenes").font(.fc(14, .bold))
                Text("\(studio.scenes.count)").font(.fc(11, .semibold)).foregroundStyle(Theme.text3)
                    .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Theme.control))
                Spacer()
                NewSceneMenu()
            }
            .padding(.horizontal, 14).frame(height: 52)
            Hairline()
            if studio.stage == .both {
                Text("Changes apply to the \(studio.editingCanvas == .horizontal ? "16:9" : "9:16") canvas")
                    .font(.fc(11)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let scenes = studio.scenes
                    ForEach(Array(scenes.enumerated()), id: \.element.id) { i, s in
                        if i == 0 || group(of: scenes[i - 1]) != group(of: s) {
                            Text(group(of: s).label).font(.fc(11.5, .semibold)).foregroundStyle(Theme.text3)
                                .padding(.top, i == 0 ? 2 : 10).padding(.leading, 2)
                        }
                        SceneCard(scene: s, index: i, renaming: $renaming, newName: $newName)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
        }
        .background(Theme.strip)
    }
    func group(of s: StudioScene) -> LayoutGroup { s.template?.group ?? s.group ?? .scenes }
}

struct SceneCard: View {
    @Environment(Studio.self) var studio
    let scene: StudioScene
    let index: Int
    @Binding var renaming: UUID?
    @Binding var newName: String
    @Local var hover = false
    var body: some View {
        let canvas = studio.editingCanvas
        let isProgram = studio.programID(canvas) == scene.id
        let isPreview = studio.previewMode && studio.previewScene?.id == scene.id
        let thumbH: CGFloat = 118
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.programWell)
                if let img = studio.thumbnails[scene.id] {
                    Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: thumbH)
                        .clipShape(RoundedRectangle(cornerRadius: canvas == .horizontal ? 10 : 4))
                }
                HStack(spacing: 4) {
                    if isProgram {
                        Text("ON AIR").font(.fc(9, .heavy)).tracking(0.4).foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Theme.accent))
                    }
                    if isPreview {
                        Text("PREVIEW").font(.fc(9, .heavy)).tracking(0.4).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Theme.healthy.opacity(0.9)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
            }
            .frame(height: thumbH).frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isProgram ? Theme.accent : (isPreview ? Theme.healthy : (hover ? Theme.text4 : Theme.hairline)), lineWidth: isProgram || isPreview ? 2 : 1))
            HStack(spacing: 6) {
                if renaming == scene.id {
                    TextField("Scene name", text: $newName, onCommit: { studio.renameLayout(scene.id, newName, canvas: canvas); renaming = nil })
                        .textFieldStyle(.roundedBorder).font(.fc(12, .semibold))
                } else {
                    Text(scene.name(for: canvas)).font(.fc(12, .semibold)).foregroundStyle(isProgram ? Theme.text : Theme.text2)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if index < 9 { Text("⌃\(index + 1)").font(.fc(10, .medium).monospacedDigit()).foregroundStyle(Theme.text4) }
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 13).fill(isProgram ? Theme.accentFill.opacity(0.35) : (hover ? Theme.control2 : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { studio.show(scene.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if studio.previewMode { studio.show(scene.id); studio.takePreview() } })
        .onHover { hover = $0 }
        .help(studio.previewMode ? "Show \(scene.name) in the preview; double-click to put it on air (⌃\(index + 1) cuts straight to it)"
                                 : "Put \(scene.name) on air (⌃\(index + 1))")
        .contextMenu {
            Button("Rename…") { newName = scene.name(for: canvas); renaming = scene.id }
            Button("Duplicate") { studio.duplicateLayout(scene.id) }
            if scene.template != nil { Button("Restore Original") { studio.resetLayout(scene.id) } }
            Divider()
            Button("Move Up") { studio.moveLayout(from: index, to: index - 1) }.disabled(index == 0)
            Button("Move Down") { studio.moveLayout(from: index, to: index + 1) }.disabled(index >= studio.scenes.count - 1)
            Divider()
            Button("Delete Scene", role: .destructive) { studio.deleteLayout(scene.id) }.disabled(studio.scenes.count <= 1)
        }
    }
}

/// "+" in the scenes header: a blank scene, a starting point, or the creator pack.
struct NewSceneMenu: View {
    @Environment(Studio.self) var studio
    var body: some View {
        Menu {
            Button("Blank Scene") { studio.addLayout(from: nil) }
            Divider()
            ForEach(LayoutGroup.allCases, id: \.self) { g in
                Section(g.label) {
                    ForEach(StudioLayoutTemplate.allCases.filter { $0.group == g }, id: \.self) { t in
                        Button(LayoutTemplates.make(t, roles: .init(background: UUID(), camera: UUID(), screen: UUID(), lowerThird: UUID())).name) {
                            studio.addLayout(from: t)
                        }
                    }
                }
            }
            Divider()
            Button("From the Creator Pack…") { studio.testAddSourceCategory = "pack"; studio.isAddingSource = true }
        } label: {
            Image(systemName: "plus").font(.fc(12, .bold)).foregroundStyle(Theme.text)
                .frame(width: 26, height: 26).background(Circle().fill(Theme.control)).overlay(Circle().stroke(Theme.hairline))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("New scene")
    }
}
