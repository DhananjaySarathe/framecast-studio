import SwiftUI
import FramecastEngine

/// The presenter view, in its own window (Rundown › Presenter view, Show › Open Presenter View). Only the presenter
/// sees it: Framecast's screen capture leaves out its own windows, and the window asks other apps not to capture
/// it. A topic show gets the outline (TopicPresenter); a scripted show gets the script in large type that follows
/// the presenter word by word (said words dim, cue lines in the accent colour; Mirror for teleprompter glass).
struct PrompterView: View {
    @Environment(Studio.self) var studio
    @AppStorage("framecast.prompter.size") var size = 34.0
    @AppStorage("framecast.prompter.mirror") var mirror = false
    @Local var follow = true
    var body: some View {
        let d = studio.director
        let script = d.prompterScript
        let next = d.scriptPosition + 1
        let currentSentence = script.sentence(containing: max(0, next))?.id
        VStack(spacing: 0) {
            if d.hasTopics {
                TopicPresenter(size: $size)
            } else {
            PrompterBar(follow: $follow, size: $size, mirror: $mirror)
            Hairline()
            if script.words.isEmpty {
                Text("Add a script or the parts' text in the Rundown, and it shows here.")
                    .font(.fc(15)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: size * 0.5) {
                            ForEach(script.sections) { section in
                                if let p = section.part, d.parts.indices.contains(p) {
                                    Text("\(p + 1) · \(d.parts[p].title)  →  \(d.parts[p].scene)")
                                        .font(.system(size: max(12, size * 0.42), weight: .bold))
                                        .foregroundStyle(d.current == p ? Theme.accent : Theme.text3)
                                        .padding(.top, size * 0.6)
                                }
                                ForEach(section.sentences) { s in
                                    Text(styled(s, script: script, next: next))
                                        .font(.system(size: size, weight: .semibold))
                                        .lineSpacing(size * 0.18)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .id(s.id)
                                }
                            }
                            Color.clear.frame(height: 400)
                        }
                        .padding(.horizontal, 48).padding(.top, 140)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: currentSentence) { _, id in
                        guard follow, let id else { return }
                        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.3)) }
                    }
                    .onAppear {
                        // Opened mid-show: start where the presenter is.
                        guard let id = currentSentence, d.scriptPosition >= 0 else { return }
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.3)) }
                    }
                }
                .scaleEffect(x: mirror ? -1 : 1, y: 1)
            }
            }
        }
        .background(Color.black)
        .background(PrivateWindow())
    }

    func styled(_ s: PrompterScript.Sentence, script: PrompterScript, next: Int) -> AttributedString {
        var out = AttributedString()
        for i in s.words {
            var w = AttributedString(script.words[i])
            if i < next { w.foregroundColor = Theme.text4 }
            else if script.cueWords.contains(i) { w.foregroundColor = Theme.accent; w.underlineStyle = .single }
            else { w.foregroundColor = Theme.text }
            out += w
            if i != s.words.upperBound - 1 {
                var space = AttributedString(" ")
                if script.cueWords.contains(i), script.cueWords.contains(i + 1), i + 1 >= next { space.underlineStyle = .single }
                out += space
            }
        }
        return out
    }
}

struct PrompterBar: View {
    @Environment(Studio.self) var studio
    @Binding var follow: Bool
    @Binding var size: Double
    @Binding var mirror: Bool
    var body: some View {
        let d = studio.director
        HStack(spacing: 14) {
            Circle().fill(!d.isListening ? Theme.text4 : (d.onScript ? Theme.healthy : Theme.warning)).frame(width: 9, height: 9)
            Text(!d.isListening ? "Not listening" : (d.onScript ? "On script" : "Off script")).font(.fc(12, .semibold)).foregroundStyle(Theme.text2)
            if let c = d.current, d.parts.indices.contains(c) {
                Text("Now: \(c + 1) · \(d.parts[c].title)").font(.fc(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            if let n = d.upcoming.first {
                Text("Next cue: “\(n.part.cue)”").font(.fc(12)).foregroundStyle(Theme.accent).lineLimit(1)
            }
            Spacer()
            Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.fc(12))
            Toggle("Mirror", isOn: $mirror).toggleStyle(.checkbox).font(.fc(12))
            Button { size = max(18, size - 4) } label: { Image(systemName: "textformat.size.smaller") }.buttonStyle(.plain).help("Smaller")
            Button { size = min(96, size + 4) } label: { Image(systemName: "textformat.size.larger") }.buttonStyle(.plain).help("Larger")
            Button { d.isListening ? d.stopListening() : d.startListening() } label: {
                Text(d.isListening ? "Stop listening" : "Listen").font(.fc(12, .semibold))
            }.disabled(!d.canListen || d.show == nil)
        }
        .foregroundStyle(Theme.icon)
        .padding(.horizontal, 16).frame(height: 44)
        .background(Theme.window)
    }
}

/// Asks macOS not to include this window in other apps' screen captures (Framecast's own capture already leaves out
/// all its windows).
struct PrivateWindow: NSViewRepresentable {
    @Environment(Studio.self) var studio
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { hide(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { hide(v.window) }
    /// Also listed with the screen capture, which leaves it out even when it shows Framecast's other windows.
    func hide(_ w: NSWindow?) {
        guard let w else { return }
        w.sharingType = .none
        let id = CGWindowID(w.windowNumber)
        if id > 0, !ScreenSource.privateWindows.contains(id) {
            ScreenSource.privateWindows.insert(id)
            studio.engine.refreshScreenFilters()
        }
    }
}

/// The outline for the presenter: every topic with its points, ticked off as they're covered, the asset on screen,
/// and what the live brain did last. The current topic scrolls to the top by itself.
struct TopicPresenter: View {
    @Environment(Studio.self) var studio
    @Binding var size: Double
    var body: some View {
        let d = studio.director
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Circle().fill(!d.isListening ? Theme.text4 : (d.brainStatus.hasPrefix("Live brain on") ? Theme.healthy : Theme.warning)).frame(width: 9, height: 9)
                Text(!d.isListening ? "Not listening" : d.brainStatus).font(.fc(12, .semibold)).foregroundStyle(Theme.text2).lineLimit(1)
                Text("On air: \(studio.programScene(.horizontal)?.name ?? "")").font(.fc(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let a = d.currentAsset { Text("Asset: \(a)").font(.fc(12)).foregroundStyle(Theme.accent).lineLimit(1) }
                Spacer()
                if d.brainCalls > 0 { Text(String(format: "%d calls · $%.3f", d.brainCalls, d.brainCost)).font(.fc(11).monospacedDigit()).foregroundStyle(Theme.text4) }
                Button { size = max(18, size - 4) } label: { Image(systemName: "textformat.size.smaller") }.buttonStyle(.plain).help("Smaller")
                Button { size = min(96, size + 4) } label: { Image(systemName: "textformat.size.larger") }.buttonStyle(.plain).help("Larger")
                Button { d.isListening ? d.stopListening() : d.startListening() } label: {
                    Text(d.isListening ? "Stop listening" : "Listen").font(.fc(12, .semibold))
                }.disabled(!d.canListen)
            }
            .foregroundStyle(Theme.icon).padding(.horizontal, 16).frame(height: 44).background(Theme.window)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: size * 0.8) {
                        ForEach(Array(d.topics.enumerated()), id: \.element.id) { i, t in topic(i, t).id(i) }
                        Color.clear.frame(height: 500)
                    }
                    .padding(.horizontal, 44).padding(.top, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: d.topicIndex) { _, i in
                    guard let i else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.04)) }
                }
                .onAppear { if let i = d.topicIndex { DispatchQueue.main.async { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.04)) } } }
            }
            if !d.lastDecision.isEmpty || d.lastAuto != nil {
                Hairline()
                HStack {
                    Text(d.lastDecision).font(.fc(12)).foregroundStyle(Theme.text3).lineLimit(1)
                    Spacer()
                    if d.lastAuto != nil { Text("Undo ⌃⌥⌘U").font(.fc(12, .semibold)).foregroundStyle(Theme.text2) }
                }
                .padding(.horizontal, 16).frame(height: 36).background(Theme.window)
            }
        }
    }

    @ViewBuilder func topic(_ i: Int, _ t: ShowTopic) -> some View {
        let d = studio.director
        let now = d.topicIndex ?? 0
        let isNow = i == now, isPast = i < now
        VStack(alignment: .leading, spacing: size * 0.3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(i + 1)").font(.system(size: size * 0.6, weight: .heavy)).foregroundStyle(isNow ? Theme.accent : Theme.text4)
                Text(t.title).font(.system(size: isNow ? size * 1.1 : size * 0.8, weight: .bold))
                    .foregroundStyle(isPast ? Theme.text4 : (isNow ? Theme.text : Theme.text2))
                if i == now + 1 { Text("NEXT").font(.system(size: max(11, size * 0.32), weight: .heavy)).foregroundStyle(Theme.accent) }
            }
            if !isPast {
                ForEach(Array(t.points.enumerated()), id: \.offset) { j, p in
                    let done = d.covered.contains("\(i + 1).\(j + 1)")
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: size * 0.5))
                            .foregroundStyle(done ? Theme.healthy.opacity(0.7) : (isNow ? Theme.accent : Theme.text4))
                        Text(p).font(.system(size: isNow ? size * 0.72 : size * 0.55, weight: .semibold))
                            .foregroundStyle(done ? Theme.text4 : (isNow ? Theme.text : Theme.text3)).strikethrough(done)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !t.assets.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(t.assets, id: \.self) { a in
                            let on = d.currentAsset == a
                            Text(on ? "ON SCREEN · \(a)" : a).font(.system(size: max(11, size * 0.34), weight: .semibold))
                                .foregroundStyle(on ? Theme.accentInk : Theme.text2)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(on ? Theme.accent : Theme.selected))
                        }
                    }
                }
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) { Rectangle().fill(isNow ? Theme.accent : .clear).frame(width: 4) }
        .opacity(isPast ? 0.55 : 1)
    }
}
