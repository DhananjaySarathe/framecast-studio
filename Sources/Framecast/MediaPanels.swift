import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FramecastEngine

/// Play, pause, restart and scrub a video or music file, plus its loop and auto-play options.
struct MediaControls: View {
    @Environment(Studio.self) var studio
    let source: SourceRecord
    var body: some View {
        let st = studio.mediaStatus[source.id]
        let o = source.media ?? MediaOptions()
        let playing = st?.isPlaying ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                button(playing ? "pause.fill" : "play.fill", help: playing ? "Pause" : "Play") {
                    if playing { studio.engine.media(source.id)?.pause() } else { studio.engine.media(source.id)?.play() }
                }
                button("backward.end.fill", help: "Play from the start") { studio.engine.media(source.id)?.restart() }
                Slider(value: Binding(get: { st?.position ?? 0 }, set: { studio.engine.media(source.id)?.seek(to: $0) }),
                       in: 0...max(0.1, st?.duration ?? 1))
                    .controlSize(.mini).tint(Theme.accent)
                Text("\(Self.time(st?.position ?? 0)) / \(Self.time(st?.duration ?? 0))")
                    .font(.fc(10.5, .medium).monospacedDigit()).foregroundStyle(Theme.text3).fixedSize()
            }
            HStack(spacing: 14) {
                    Toggle("Loop", isOn: Binding(get: { o.loop }, set: { v in studio.setMediaOptions(source.id) { $0.loop = v } }))
                    if source.kind.hasVideo {
                        Toggle("Start from the top on air", isOn: Binding(get: { o.playsWhenShown }, set: { v in studio.setMediaOptions(source.id) { $0.playsWhenShown = v } }))
                            .help("Each time a scene showing it goes on air, play it from the beginning. Otherwise it carries on where it paused.")
                    }
                }
                .toggleStyle(.checkbox).font(.fc(11.5))
        }
    }
    func button(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.fc(11, .bold)).foregroundStyle(Theme.text)
                .frame(width: 28, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Theme.selected))
        }.buttonStyle(.plain).help(help)
    }
    static func time(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Nine buttons that play short sounds into the mix (⌃⌥1–9).
struct SoundPadGrid: View {
    @Environment(Studio.self) var studio
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sound pad").font(.fc(12, .semibold))
                Spacer()
                Text("⌃⌥1–9 · right-click to change").font(.fc(10.5)).foregroundStyle(Theme.text4)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(0..<9, id: \.self) { i in pad(i) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    func pad(_ i: Int) -> some View {
        let s = studio.padSlots[i]
        return Button { s.isEmpty ? choose(i) : studio.playPad(i) } label: {
            VStack(spacing: 2) {
                Text(s.isEmpty ? "Add sound" : s.name).font(.fc(11.5, .semibold)).lineLimit(1)
                    .foregroundStyle(s.isEmpty ? Theme.text4 : Theme.text)
                Text("\(i + 1)").font(.fc(9.5, .medium)).foregroundStyle(Theme.text4)
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(s.isEmpty ? Theme.control2 : Theme.control))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(s.isEmpty ? Theme.hairline : Theme.fieldBorder, style: StrokeStyle(lineWidth: 1, dash: s.isEmpty ? [3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.isEmpty ? "Choose a sound file for this button" : "Play \(s.name) (⌃⌥\(i + 1))")
        .contextMenu {
            Button("Choose a Sound File…") { choose(i) }
            Menu("Built-in Sound") {
                ForEach(SoundBank.builtIns, id: \.id) { b in Button(b.name) { studio.setPadSlot(i, SoundSlot(key: b.id, name: b.name)) } }
            }
            if !s.isEmpty { Divider(); Button("Clear Button") { studio.setPadSlot(i, SoundSlot(key: "", name: "")) } }
        }
    }

    func choose(_ i: Int) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.audio]
        p.message = "Choose a short sound (the first 30 seconds are used)."
        guard p.runModal() == .OK, let u = p.url else { return }
        studio.setPadSlot(i, SoundSlot(key: u.path, name: u.deletingPathExtension().lastPathComponent))
    }
}
