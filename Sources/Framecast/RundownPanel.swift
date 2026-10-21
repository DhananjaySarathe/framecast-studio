import SwiftUI
import AppKit
import FramecastEngine

/// The show's rundown: the director's controls, the script, and the parts with their scenes and cue lines.
struct RundownPanel: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let d = studio.director
        VStack(spacing: 0) {
            PanelHeader(title: "Rundown", subtitle: d.show?.title) { ShowMenu() }
            if d.show == nil {
                NoShowView()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DirectorCard()
                        RehearsalCard()
                        OutlineCard()
                        if !d.hasTopics {
                            ScriptCard()
                            if !d.parts.isEmpty || !(d.show?.script.isEmpty ?? true) { PartsList() }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: d.topicIndex) { _, i in
                    // While live, the topic you're on comes up by itself.
                    guard let i, d.isListening else { return }
                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo("topic-\(i)", anchor: .top) }
                }
                }
            }
        }
    }
}

struct ShowMenu: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let d = studio.director
        Menu {
            Button("New Show") { d.newShow() }
            Menu("Open") {
                let list = ShowStore.list()
                if list.isEmpty { Text("No saved shows") }
                ForEach(list.prefix(15)) { e in Button(e.title) { d.open(e.url) } }
            }
            if d.show != nil {
                Divider()
                Button("Open Presenter View") { studio.testOpenPrompter += 1 }
                Button("Start From the Top") { d.current = nil; d.suggestion = nil }
                Button("Show in Finder") { if let f = d.folder { NSWorkspace.shared.activateFileViewerSelecting([f.appendingPathComponent("show.json")]) } }
                Button("Close Show") { d.close() }
            }
        } label: { Image(systemName: "ellipsis.circle").font(.fc(13, .semibold)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("New, open or close a show")
    }
}

struct NoShowView: View {
    @Environment(Studio.self) var studio
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan the show: paste a rough script and Framecast lists its parts, the scene for each, and the words that start it. While you present, it follows your voice on this Mac and suggests the switches, or makes them.")
                .font(.fc(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            PillButton(title: "New show", systemImage: "plus", prominent: true) { studio.director.newShow() }
            let list = ShowStore.list()
            if !list.isEmpty {
                SectionLabel(text: "Recent shows")
                ForEach(list.prefix(6)) { e in
                    Button { studio.director.open(e.url) } label: {
                        HStack {
                            Text(e.title).font(.fc(12.5, .semibold)).lineLimit(1)
                            Spacer()
                            Text(e.modified, style: .date).font(.fc(10.5)).foregroundStyle(Theme.text4)
                        }
                        .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.control2))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}

/// Following your voice, the mode, and what the director heard, suggests or did.
struct DirectorCard: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let d = studio.director
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { d.isListening ? d.stopListening() : d.startListening() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: d.isListening ? "waveform" : "mic").font(.fc(11.5, .semibold))
                        Text(d.isListening ? "Listening" : "Listen").font(.fc(12, .semibold))
                    }
                    .foregroundStyle(d.isListening ? Theme.accentInk : Theme.text)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(d.isListening ? Theme.accent : Theme.selected))
                }
                .buttonStyle(.plain).disabled(!d.canListen)
                .help(d.isListening ? "Stop following your voice" : "Listen on this Mac for the next part's cue (nothing leaves the Mac)")
                Spacer()
                Picker("", selection: Binding(get: { d.mode }, set: { d.setMode($0) })) {
                    ForEach(DirectorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .help("Suggest: you take each switch (⌃⌥⌘T). Auto: Framecast switches, and ⌃⌥⌘U switches back.")
            }
            if d.hasTopics && d.isListening && !d.brainStatus.isEmpty {
                Text(d.brainStatus).font(.fc(11)).foregroundStyle(d.brainStatus.hasPrefix("Live brain on") ? Theme.text3 : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !d.canListen {
                Text("Following your voice needs macOS 26 or later. You can still take parts by hand: ⌃⌥⌘T takes the next one.")
                    .font(.fc(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            } else if !d.status.isEmpty {
                Text(d.status).font(.fc(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            if d.isListening && !d.heard.isEmpty {
                Text("“…\(d.heard)”").font(.fc(11.5)).italic().foregroundStyle(Theme.text2).lineLimit(2)
            }
            if let s = d.suggestion, d.parts.indices.contains(s.part) {
                let p = d.parts[s.part]
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next: \(s.part + 1) · \(p.title)").font(.fc(12.5, .bold))
                    Text("→ \(p.scene)  ·  heard “\(s.heard)”").font(.fc(11)).foregroundStyle(Theme.text2).lineLimit(2)
                    if let note = s.note { Text(note).font(.fc(11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        PillButton(title: "Take  ⌃⌥⌘T", prominent: true) { d.takeSuggestionOrNext() }.disabled(d.sceneID(for: p) == nil)
                        PillButton(title: "Skip") { d.skipSuggestion() }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accentFill))
            } else if let b = d.brainSuggestion {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested: \(LiveBrain.describe(b.action))").font(.fc(12.5, .bold))
                    Text(b.reason).font(.fc(11)).foregroundStyle(Theme.text2).lineLimit(2)
                    HStack {
                        PillButton(title: "Take  ⌃⌥⌘T", prominent: true) { d.takeSuggestionOrNext() }
                        PillButton(title: "Skip") { d.skipSuggestion() }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accentFill))
            } else if let a = d.lastAuto {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if ctx.date.timeIntervalSince(a.at) < 20 {
                        HStack {
                            Text("Switched: \(a.label)").font(.fc(11.5, .semibold)).lineLimit(1)
                            Spacer()
                            PillButton(title: "Undo  ⌃⌥⌘U") { d.undoAuto() }
                        }
                    }
                }
            }
            if d.hasTopics && !d.lastDecision.isEmpty {
                Text(d.lastDecision).font(.fc(10.5)).foregroundStyle(Theme.text4).lineLimit(2)
            }
            if let until = d.pausedUntil, d.mode == .auto {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if until > ctx.date {
                        HStack {
                            Text("Auto paused after your switch · \(Int(until.timeIntervalSince(ctx.date).rounded(.up))) s").font(.fc(11)).foregroundStyle(Theme.text3)
                            Spacer()
                            Button("Resume") { d.pausedUntil = nil }.buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(d.isListening ? Theme.accent.opacity(0.5) : Theme.hairline))
    }
}

/// The rough script, and the two ways to turn it into parts.
struct ScriptCard: View {
    @Environment(Studio.self) var studio
    @Local var open = false
    var body: some View {
        let d = studio.director
        let provider = studio.settings.s.aiProvider ?? .claude
        let script = d.show?.script ?? ""
        VStack(alignment: .leading, spacing: 8) {
            TextField("Show title", text: Binding(get: { d.show?.title ?? "" }, set: { v in d.edit { $0.title = v } }))
                .textFieldStyle(.plain).font(.fc(14, .bold)).padding(.bottom, 2)
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.fc(9, .bold)).foregroundStyle(Theme.text3)
                    SectionLabel(text: "Script (word for word)")
                    Spacer()
                    if !open && !script.isEmpty { Text("\(script.split(whereSeparator: \.isWhitespace).count) words").font(.fc(10.5)).foregroundStyle(Theme.text4) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                TextEditor(text: Binding(get: { d.show?.script ?? "" }, set: { v in d.edit { $0.script = v } }))
                    .font(.fc(12)).scrollContentBackground(.hidden).padding(6)
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(alignment: .topLeading) {
                        if script.isEmpty {
                            Text("Paste your rough script here: what you'll say, in order.").font(.fc(12)).foregroundStyle(Theme.text4).padding(11).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    if studio.settings.s.writeWithAPI ?? false {
                        PillButton(title: "Write it for me", systemImage: "sparkles", prominent: true) {
                            if d.parts.isEmpty || confirm("Replace the \(d.parts.count) parts?", "The current parts are kept in the show's folder as show-before-ai.json.") { d.writeWithAI() }
                        }.disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || d.writing != nil)
                    }
                    PillButton(title: "Split by paragraphs") {
                        if d.parts.isEmpty || confirm("Replace the \(d.parts.count) parts?", "") { split() }
                    }.disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || d.writing != nil)
                }
                if let w = d.writing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(w).font(.fc(11)).foregroundStyle(Theme.text2) }
                } else if let e = d.writeError {
                    Text(e).font(.fc(11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                if !(studio.settings.s.writeWithAPI ?? false) {
                    Text("Split by paragraphs needs no AI. Claude can also turn a script into parts on your plan (control link). Settings › AI has an optional Write it for me that uses your API key.")
                        .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                } else if AIKeys.has(provider) {
                    Text("Write it for me sends the script and your scene names to \(provider.company) (\(studio.settings.model(for: provider))).")
                        .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button { studio.testSettingsPane = "ai"; studio.testOpenSettings += 1 } label: {
                        Text("Add a Claude or OpenAI API key in Settings › AI to use Write it for me.").font(.fc(10.5)).foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    /// A plain alert (the Rundown lives in a private borderless window, where sheets don't fit).
    func confirm(_ title: String, _ detail: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail
        a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
    func split() {
        let parts = ScriptWriter.split(script: studio.director.show?.script ?? "", scenes: studio.scenes.map(\.name))
        studio.director.edit { $0.parts = parts }
        studio.director.current = nil
    }
}

struct PartsList: View {
    @Environment(Studio.self) var studio
    @Local var editing: UUID?
    var body: some View {
        let d = studio.director
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: d.parts.isEmpty ? "Parts" : "Parts · \(d.parts.count)")
                Spacer()
                Button {
                    let p = RundownPart(title: "Part \(d.parts.count + 1)", scene: studio.scenes.first?.name ?? "")
                    d.edit { $0.parts.append(p) }
                    editing = p.id
                } label: { Label("Add part", systemImage: "plus").font(.fc(11.5, .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if d.parts.isEmpty {
                Text("No parts yet. Write them from the script, or add them one by one.").font(.fc(12)).foregroundStyle(Theme.text3)
            }
            ForEach(Array(d.parts.enumerated()), id: \.element.id) { i, p in
                PartCard(index: i, part: p, editing: $editing)
            }
        }
    }
}

struct PartCard: View {
    @Environment(Studio.self) var studio
    let index: Int
    let part: RundownPart
    @Binding var editing: UUID?
    var body: some View {
        let d = studio.director
        let isCurrent = d.current == index
        let isNext = (d.current ?? -1) + 1 == index
        let sceneOK = d.sceneID(for: part) != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text("\(index + 1)").font(.fc(10.5, .bold)).foregroundStyle(isCurrent ? Theme.accentInk : Theme.text2)
                    .frame(width: 22, height: 22).background(Circle().fill(isCurrent ? Theme.accent : Theme.selected))
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.title.isEmpty ? "Untitled part" : part.title).font(.fc(12.5, .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: sceneOK ? "rectangle.on.rectangle" : "exclamationmark.triangle.fill").font(.fc(9))
                        Text(part.scene.isEmpty ? "No scene" : part.scene).lineLimit(1)
                    }
                    .font(.fc(11)).foregroundStyle(sceneOK ? Theme.text3 : Theme.warning)
                }
                Spacer()
                Button { d.take(index) } label: {
                    Text(isCurrent ? "On air" : "Take").font(.fc(11.5, .bold)).foregroundStyle(isCurrent ? Theme.accentInk : Theme.text)
                        .padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(isCurrent ? Theme.accent : Theme.selected))
                }
                .buttonStyle(.plain).disabled(!sceneOK).help(sceneOK ? "Put this part's scene on air" : "Choose a scene that exists for this part")
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = editing == part.id ? nil : part.id }
            if !part.cue.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("“\(part.cue)”").font(.fc(11.5)).italic().foregroundStyle(Theme.text2).lineLimit(2)
            } else if index > 0 {
                Text("Starts by hand").font(.fc(11)).foregroundStyle(Theme.text4)
            }
            if editing == part.id { PartEditor(part: part) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isCurrent ? Theme.accent.opacity(0.75) : (isNext ? Theme.accent.opacity(0.3) : Theme.hairline)))
        .contextMenu {
            Button("Edit") { editing = part.id }
            Button("Move Up") { move(-1) }.disabled(index == 0)
            Button("Move Down") { move(1) }.disabled(index == d.parts.count - 1)
            Button("Duplicate") { var c = part; c.id = UUID(); d.edit { $0.parts.insert(c, at: index + 1) } }
            Button("Delete Part", role: .destructive) { d.edit { $0.parts.removeAll { $0.id == part.id } }; if d.current == index { d.current = nil } }
        }
    }
    func move(_ by: Int) {
        studio.director.edit { s in
            guard let i = s.parts.firstIndex(where: { $0.id == part.id }), s.parts.indices.contains(i + by) else { return }
            s.parts.swapAt(i, i + by)
        }
    }
}

struct PartEditor: View {
    @Environment(Studio.self) var studio
    let part: RundownPart
    func bind<T>(_ kp: WritableKeyPath<RundownPart, T>) -> Binding<T> {
        Binding(get: { part[keyPath: kp] }, set: { v in
            studio.director.edit { s in if let i = s.parts.firstIndex(where: { $0.id == part.id }) { s.parts[i][keyPath: kp] = v } }
        })
    }
    var body: some View {
        let names = studio.scenes.map(\.name)
        VStack(alignment: .leading, spacing: 8) {
            field("Title") { TextField("Title", text: bind(\.title)).textFieldStyle(.roundedBorder).font(.fc(12)) }
            field("Scene") {
                Picker("", selection: bind(\.scene)) {
                    ForEach(names.contains(part.scene) ? names : [part.scene] + names, id: \.self) { Text($0.isEmpty ? "None" : $0).tag($0) }
                }.labelsHidden()
            }
            field("Starts when you say") {
                TextField("now let me show you the chart", text: bind(\.cue)).textFieldStyle(.roundedBorder).font(.fc(12))
            }
            field("Or (one per line)") {
                TextEditor(text: Binding(get: { part.alsoAccept.joined(separator: "\n") }, set: { v in bind(\.alsoAccept).wrappedValue = v.components(separatedBy: "\n") }))
                    .font(.fc(11.5)).scrollContentBackground(.hidden).padding(4).frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            }
            field("Notes") {
                TextEditor(text: bind(\.notes)).font(.fc(11.5)).scrollContentBackground(.hidden).padding(4).frame(height: 70)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            }
        }
    }
    func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.fc(11)).foregroundStyle(Theme.text3); c() }
    }
}

/// Rehearse a run-through, then see which cues it would have caught, with one-click fixes for the misses.
struct RehearsalCard: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let d = studio.director
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PillButton(title: d.isRehearsing ? "Stop rehearsal" : "Rehearse", systemImage: d.isRehearsing ? "stop.fill" : "figure.run",
                           destructive: d.isRehearsing) {
                    d.isRehearsing ? d.stopRehearsal() : d.startRehearsal()
                }
                .disabled(!d.canListen)
                .help("Run through the show: Framecast listens (on this Mac), keeps what it heard, and then shows which cues it caught")
                PillButton(title: "Presenter view", systemImage: "text.alignleft") { studio.testOpenPrompter += 1 }
                    .help("Your outline (or script) in its own window that follows you; only you see it")
                Spacer()
                if !d.rehearsals.isEmpty {
                    Menu {
                        ForEach(d.rehearsals.prefix(10), id: \.self) { u in
                            Button(u.deletingPathExtension().lastPathComponent) { d.hasTopics ? d.replayBrain(u) : d.replay(u) }
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath").font(.fc(12, .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Replay an earlier rehearsal with today's cues")
                }
            }
            if d.isRehearsing, let start = d.rehearsalStart {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Rehearsing · \(formatClock(ctx.date.timeIntervalSince(start)))  Go through the show as you would live.")
                        .font(.fc(11)).foregroundStyle(Theme.text3)
                }
            }
            if d.isReplaying { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Replaying…").font(.fc(11)).foregroundStyle(Theme.text3) } }
            if let r = d.report, !d.isRehearsing, !d.hasTopics { RehearsalResults(report: r) }
            if let b = d.brainReport, !d.isRehearsing, d.hasTopics { BrainReplayResults(report: b) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(d.isRehearsing ? Theme.live.opacity(0.5) : Theme.hairline))
    }
}

struct RehearsalResults: View {
    @Environment(Studio.self) var studio
    let report: RehearsalReport
    var body: some View {
        let d = studio.director
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Caught \(report.fires.count) of \(report.cues) cues").font(.fc(12.5, .bold))
                    .foregroundStyle(report.fires.count == report.cues ? Theme.healthy : Theme.text)
                Spacer()
                Text(formatClock(report.duration)).font(.fc(10.5).monospacedDigit()).foregroundStyle(Theme.text4)
                Button("Replay") { d.replay(report.file) }.buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent)
                    .help("Run it again with the cues as they are now")
            }
            let rows = (report.fires.map { ($0.part, true) } + report.misses.map { ($0.part, false) }).sorted { $0.0 < $1.0 }
            ForEach(rows, id: \.0) { part, caught in
                if d.parts.indices.contains(part) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: caught ? "checkmark.circle.fill" : "xmark.circle.fill").font(.fc(11))
                                .foregroundStyle(caught ? Theme.healthy : Theme.warning)
                            Text("\(part + 1) · \(d.parts[part].title)").font(.fc(11.5, .semibold)).lineLimit(1)
                            Spacer()
                            if let f = report.fires.first(where: { $0.part == part }) {
                                Text("\(Studio.chapterTime(f.t)) · \(f.how.hasPrefix("meaning") ? "meaning" : "words")").font(.fc(10.5)).foregroundStyle(Theme.text4)
                            }
                        }
                        if let m = report.misses.first(where: { $0.part == part }) {
                            if let c = m.closest {
                                Text("You said: “\(c)”").font(.fc(11)).italic().foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                                Button("Use this as another way to say it") { d.acceptAlternative(part: part, c) }
                                    .buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent)
                            } else {
                                Text("Nothing close was said. Check the cue, or say it as written.").font(.fc(11)).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
            }
            if !report.mishearings.isEmpty {
                SectionLabel(text: "Possibly misheard")
                ForEach(report.mishearings, id: \.self) { a in
                    HStack {
                        Text("“\(a.heard)” for “\(a.meant)”").font(.fc(11.5)).foregroundStyle(Theme.text2)
                        if a.count > 1 { Text("×\(a.count)").font(.fc(10.5)).foregroundStyle(Theme.text4) }
                        Spacer()
                        Button("Fix") { d.acceptAlias(a) }.buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent)
                            .help("From now on, “\(a.heard)” counts as “\(a.meant)” for this show")
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
    }
}

/// A topic show: the brief, getting Claude to prepare it, the outline and the assets.
struct OutlineCard: View {
    @Environment(Studio.self) var studio
    @Local var editing: UUID?
    @Local var copied = ""
    var body: some View {
        let d = studio.director
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Brief")
            TextEditor(text: Binding(get: { d.show?.brief ?? "" }, set: { v in d.edit { $0.brief = v } }))
                .font(.fc(12)).scrollContentBackground(.hidden).padding(6).frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(alignment: .topLeading) {
                    if (d.show?.brief ?? "").isEmpty {
                        Text("What's the show about? The topics, what you want to get across, a few lines you might say. Not a script.")
                            .font(.fc(12)).foregroundStyle(Theme.text4).padding(11).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                PillButton(title: "Copy for Claude", systemImage: "doc.on.doc", prominent: true) { copy(prompt(d), "Copied. Paste it into Claude Desktop.") }
                    .disabled((d.show?.brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("A request for Claude Desktop to prepare this show through the control link (your Claude plan)")
                PillButton(title: "Claude Code", systemImage: "terminal") { copy(command(d), "Copied. Paste it into Terminal.") }
                    .help("A Terminal command that opens Claude Code in this show's folder to prepare it")
            }
            Text(copied.isEmpty ? "Claude prepares the outline and the pictures and cards on your Claude plan. Turn on the control link in Settings › AI for Claude Desktop." : copied)
                .font(.fc(10.5)).foregroundStyle(copied.isEmpty ? Theme.text4 : Theme.healthy).fixedSize(horizontal: false, vertical: true)
            if d.hasTopics {
                HStack {
                    SectionLabel(text: "Outline · \(d.topics.count) topics")
                    Spacer()
                    Text("\(d.covered.count)/\(d.topics.reduce(0) { $0 + $1.points.count }) points").font(.fc(10.5)).foregroundStyle(Theme.text4)
                }
                ForEach(Array(d.topics.enumerated()), id: \.element.id) { i, t in TopicCard(index: i, topic: t, editing: $editing).id("topic-\(i)") }
            }
            Button {
                d.edit { $0.topics.append(ShowTopic(title: "Topic \(d.topics.count + 1)")) }
                editing = d.topics.last?.id
            } label: { Label("Add topic", systemImage: "plus").font(.fc(11.5, .semibold)) }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            if let show = d.show, !show.assets.isEmpty {
                SectionLabel(text: "Assets · \(show.assets.count)")
                ForEach(show.assets, id: \.file) { a in AssetRow(asset: a) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
    func copy(_ s: String, _ note: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        copied = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { copied = "" }
    }
    func prompt(_ d: ShowDirector) -> String {
        """
        Please prepare my next Framecast show from the brief below. Use the framecast tools: start with get_show_state, \
        then write the outline with set_outline (topics, each with three to six short points in my words), make a card \
        with make_card for any numbers, comparisons or lists worth showing, and save a few reference pictures with \
        save_image (only reusable sources such as Wikimedia Commons, with the credit in about; never company logos). \
        Keep facts to what you can source, and put the source on the card.

        Brief:
        \(d.show?.brief ?? "")
        """
    }
    func command(_ d: ShowDirector) -> String {
        "cd \"\(d.folder?.path ?? "")\" && claude \"Read CLAUDE.md and brief.md, then prepare this show.\""
    }
}

struct TopicCard: View {
    @Environment(Studio.self) var studio
    let index: Int
    let topic: ShowTopic
    @Binding var editing: UUID?
    func bind<T>(_ kp: WritableKeyPath<ShowTopic, T>) -> Binding<T> {
        Binding(get: { topic[keyPath: kp] }, set: { v in
            studio.director.edit { s in if let i = s.topics.firstIndex(where: { $0.id == topic.id }) { s.topics[i][keyPath: kp] = v } }
        })
    }
    var body: some View {
        let d = studio.director
        let isNow = d.topicIndex == index
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text("\(index + 1)").font(.fc(10.5, .bold)).foregroundStyle(isNow ? Theme.accentInk : Theme.text2)
                    .frame(width: 22, height: 22).background(Circle().fill(isNow ? Theme.accent : Theme.selected))
                Text(topic.title.isEmpty ? "Untitled topic" : topic.title).font(.fc(12.5, .semibold)).lineLimit(1)
                Spacer()
                Button { d.goToTopic(index) } label: {
                    Text(isNow ? "Now" : "Go").font(.fc(11.5, .bold)).foregroundStyle(isNow ? Theme.accentInk : Theme.text)
                        .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(isNow ? Theme.accent : Theme.selected))
                }.buttonStyle(.plain).help("Mark this as the topic you're on")
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = editing == topic.id ? nil : topic.id }
            ForEach(Array(topic.points.enumerated()), id: \.offset) { j, p in
                let done = d.covered.contains("\(index + 1).\(j + 1)")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.fc(9)).foregroundStyle(done ? Theme.healthy : Theme.text4)
                    Text(p).font(.fc(11)).foregroundStyle(done ? Theme.text4 : Theme.text2).lineLimit(2)
                }
            }
            if !topic.look.isEmpty || !topic.assets.isEmpty {
                Text(([topic.look.isEmpty ? nil : "Look: \(topic.look)"] + topic.assets.map { Optional($0) }).compactMap { $0 }.joined(separator: " · "))
                    .font(.fc(10.5)).foregroundStyle(Theme.text4).lineLimit(2)
            }
            if editing == topic.id {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Title", text: bind(\.title)).textFieldStyle(.roundedBorder).font(.fc(12))
                    Text("Points (one per line)").font(.fc(11)).foregroundStyle(Theme.text3)
                    TextEditor(text: Binding(get: { topic.points.joined(separator: "\n") }, set: { v in bind(\.points).wrappedValue = v.components(separatedBy: "\n") }))
                        .font(.fc(11.5)).scrollContentBackground(.hidden).padding(4).frame(height: 70)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    Picker("Look", selection: bind(\.look)) {
                        Text("Framecast picks").tag("")
                        ForEach(Looks.catalog(studio).map(\.name), id: \.self) { Text($0).tag($0) }
                    }.font(.fc(11.5))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isNow ? Theme.accent.opacity(0.7) : .clear))
        .contextMenu {
            Button("Move Up") { move(-1) }.disabled(index == 0)
            Button("Move Down") { move(1) }.disabled(index == d.topics.count - 1)
            Button("Delete Topic", role: .destructive) { d.edit { $0.topics.removeAll { $0.id == topic.id } } }
        }
    }
    func move(_ by: Int) {
        studio.director.edit { s in
            guard let i = s.topics.firstIndex(where: { $0.id == topic.id }), s.topics.indices.contains(i + by) else { return }
            s.topics.swapAt(i, i + by)
        }
    }
}

struct AssetRow: View {
    @Environment(Studio.self) var studio
    let asset: ShowAsset
    var body: some View {
        let d = studio.director
        let on = d.currentAsset == asset.file
        HStack(spacing: 8) {
            AssetThumb(url: d.folder?.appendingPathComponent("assets").appendingPathComponent(asset.file))
                .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.file).font(.fc(11.5, .semibold)).lineLimit(1)
                Text(asset.about).font(.fc(10.5)).foregroundStyle(Theme.text3).lineLimit(2)
            }
            Spacer()
            Button {
                if on { if let cam = Looks.catalog(studio).first(where: { !$0.isAsset }) { d.execute(.look(cam.name), by: "you") } }
                else {
                    d.assetSlotID = Looks.ensure(studio)
                    let cur = studio.programScene(.horizontal)?.name ?? ""
                    d.execute(.asset(asset.file, look: Looks.assetLooks.contains(cur) ? cur : Looks.circle), by: "you")
                }
            } label: {
                Text(on ? "On" : "Show").font(.fc(11, .bold)).foregroundStyle(on ? Theme.accentInk : Theme.text)
                    .padding(.horizontal, 9).frame(height: 22).background(Capsule().fill(on ? Theme.accent : Theme.selected))
            }.buttonStyle(.plain).disabled(!d.assetExists(asset.file))
        }
    }
}

/// A small picture of an asset (first frame for videos is skipped: a film icon instead).
struct AssetThumb: View {
    let url: URL?
    static var cache: [String: NSImage] = [:]
    var body: some View {
        if let url, let img = Self.image(url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack { Theme.selected; Image(systemName: "film").foregroundStyle(Theme.text3) }
        }
    }
    static func image(_ url: URL) -> NSImage? {
        guard ShowStore.imageTypes.contains(url.pathExtension.lowercased()) else { return nil }
        let key = url.path + "\((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let c = cache[key] { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = img
        return img
    }
}

struct BrainReplayResults: View {
    @Environment(Studio.self) var studio
    let report: BrainReplayReport
    var body: some View {
        let d = studio.director
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live brain replay").font(.fc(12.5, .bold))
                Spacer()
                Button("Replay") { d.replayBrain(report.file) }.buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.accent)
            }
            if let p = report.problem { Text(p).font(.fc(11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true) }
            Text("Reached topic \(report.topicsReached) of \(d.topics.count) · \(report.covered)/\(report.points) points · \(report.calls) calls\(report.cost.map { String(format: " · $%.3f", $0) } ?? "")")
                .font(.fc(11)).foregroundStyle(Theme.text2)
            ForEach(Array(report.steps.enumerated()), id: \.offset) { _, s in
                Text(s).font(.fc(10.5)).foregroundStyle(s.contains("held") ? Theme.text4 : Theme.text2).lineLimit(2)
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
    }
}
