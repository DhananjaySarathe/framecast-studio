import SwiftUI
import AppKit
import FramecastEngine

/// Captions: on and off, language, size and position, and the live transcript (click a line to correct it).
struct CaptionsPanel: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let c = studio.captions
        VStack(spacing: 0) {
            PanelHeader(title: "Captions", subtitle: "On this Mac") { TranscriptMenu() }
            CaptionsCard().padding(12)
            Hairline()
            TranscriptList()
        }
        .onAppear { c.loadLanguages() }
    }
}

/// The on/off switch and how the captions look.
struct CaptionsCard: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let c = studio.captions
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { c.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: c.isOn ? "captions.bubble.fill" : "captions.bubble").font(.fc(11.5, .semibold))
                        Text(c.isOn ? "Captions on" : "Turn on captions").font(.fc(12, .semibold))
                    }
                    .foregroundStyle(c.isOn ? Theme.accentInk : Theme.text)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(c.isOn ? Theme.accent : Theme.selected))
                }
                .buttonStyle(.plain).disabled(!c.canCaption)
                .help(c.isOn ? "Take the captions off the show (⌃⌥⌘L)" : "Show what you say as captions on both canvases (⌃⌥⌘L)")
                Spacer()
                Text("⌃⌥⌘L").font(.fc(10, .semibold)).foregroundStyle(Theme.text4)
            }
            if let why = c.unsupportedReason {
                Text(why).font(.fc(11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            } else if !c.status.isEmpty {
                Text(c.status).font(.fc(11)).foregroundStyle(c.status.contains("Trying again") || c.status.contains("isn't available") ? Theme.warning : Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "Language")
                Picker("", selection: Binding(get: { c.settings.language }, set: { c.settings.language = $0 })) {
                    Text("English (\(Locale.current.localizedString(forRegionCode: Locale.current.region?.identifier ?? "US") ?? "this Mac's region"))").tag("")
                    if !c.settings.language.isEmpty && !c.languages.contains(where: { $0.id == c.settings.language }) {
                        Text(CaptionEngine.title(c.settings.language)).tag(c.settings.language)
                    }
                    ForEach(c.languages) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu)
                .help("One language at a time. A language used for the first time may need a one-time download from Apple.")
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Size")
                    Picker("", selection: Binding(get: { c.settings.size }, set: { c.settings.size = $0 })) {
                        ForEach(CaptionSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Position")
                    Picker("", selection: Binding(get: { c.settings.position }, set: { c.settings.position = $0 })) {
                        ForEach(CaptionPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
            Text("Recognised on this Mac by Apple's speech recognition: nothing is sent anywhere. Grey words are still being worked out. On 9:16 the captions stay clear of the Reels and Shorts buttons.")
                .font(.fc(10.5)).foregroundStyle(Theme.text4).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!c.canCaption)
    }
}

/// Copy or clear the transcript.
struct TranscriptMenu: View {
    @Environment(Studio.self) var studio
    @Local var copied = false
    var body: some View {
        let c = studio.captions
        HStack(spacing: 10) {
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.allText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc").font(.fc(12, .semibold))
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(c.transcript.isEmpty)
            .help("Copy the whole transcript with times")
            Menu {
                Button("Clear Transcript", role: .destructive) { c.clearTranscript() }.disabled(c.transcript.isEmpty)
            } label: { Image(systemName: "ellipsis.circle").font(.fc(13, .semibold)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

/// The transcript as it's spoken: one line per settled stretch, with its time in the show, and the words still being
/// recognised under it. Clicking a line corrects it; a line still on screen changes on air too.
struct TranscriptList: View {
    @Environment(Studio.self) var studio
    @Local var editing: Int?
    @Local var draft = ""
    @Local var hovered: Int?
    @Local var note: String?
    var body: some View {
        let c = studio.captions
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if c.transcript.isEmpty && c.guess.isEmpty {
                        Text(c.isOn ? "Listening… what you say appears here a moment after it's on screen. Click a line to correct it."
                                    : "Turn captions on and start talking. Each line appears here with its time in the show; click one to correct it, and Copy all takes the whole transcript.")
                            .font(.fc(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true).padding(8)
                    }
                    ForEach(c.transcript) { line in row(line).id(line.id) }
                    if !c.guess.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("now").font(.fc(10.5, .semibold)).foregroundStyle(Theme.accent).frame(width: 44, alignment: .leading)
                            Text(c.guess).font(.fc(12.5)).italic().foregroundStyle(Theme.text3)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5).id("guess")
                    }
                    if let note {
                        Text(note).font(.fc(10.5)).foregroundStyle(Theme.text4).padding(.horizontal, 8).padding(.top, 4)
                    }
                }
                .padding(8)
            }
            .onChange(of: c.transcript.count) { _, _ in
                // New lines come into view unless a line is being corrected.
                guard editing == nil, let last = c.transcript.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder func row(_ line: CaptionLine) -> some View {
        let isEditing = editing == line.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(time(line.showStart)).font(.fc(10.5, .semibold)).monospacedDigit().foregroundStyle(Theme.text4)
                    .frame(width: 44, alignment: .leading)
                if isEditing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(.fc(12.5)).foregroundStyle(Theme.text)
                        .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.7)))
                        .onSubmit { save(line) }
                } else {
                    Text(line.text.isEmpty ? "(removed)" : line.text).font(.fc(12.5))
                        .foregroundStyle(line.text.isEmpty ? Theme.text4 : Theme.chatText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if line.isCorrected {
                        Image(systemName: "pencil").font(.fc(9.5, .semibold)).foregroundStyle(Theme.text4).help("Corrected (heard: “\(line.heard)”)")
                    }
                }
            }
            if isEditing {
                HStack(spacing: 8) {
                    Spacer()
                    if line.isCorrected { Button("Undo correction") { draft = line.heard }.buttonStyle(.plain).font(.fc(11, .semibold)).foregroundStyle(Theme.text3) }
                    PillButton(title: "Cancel") { editing = nil }
                    PillButton(title: "Save", prominent: true) { save(line) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(isEditing ? Theme.selected : (hovered == line.id ? Theme.control2 : .clear)))
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = line.id } else if hovered == line.id { hovered = nil } }
        .onTapGesture { if !isEditing { editing = line.id; draft = line.text; note = nil } }
        .help(isEditing ? "" : "Click to correct this line")
        .contextMenu {
            Button("Correct…") { editing = line.id; draft = line.text }
            Button("Copy Line") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.text, forType: .string) }
        }
    }

    private func save(_ line: CaptionLine) {
        let onAir = studio.captions.correct(line.id, draft)
        editing = nil
        note = onAir ? "Corrected on screen too." : "Corrected in the transcript and the subtitles."
    }

    private func time(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// Captions on or off, over the top-right corner of the canvases (they show on the program).
struct CaptionsToggle: View {
    @Environment(Studio.self) var studio
    var body: some View {
        let c = studio.captions
        Button { c.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: c.isOn ? "captions.bubble.fill" : "captions.bubble").font(.fc(10.5, .semibold))
                Text("Captions").font(.fc(11.5, .semibold))
            }
            .foregroundStyle(c.isOn ? Theme.accentInk : Theme.text2)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(c.isOn ? Theme.accent : Theme.control.opacity(0.9)))
            .overlay(Capsule().stroke(c.isOn ? .clear : Theme.hairline))
            .opacity(c.canCaption ? 1 : 0.45)
        }
        .buttonStyle(.plain).disabled(!c.canCaption)
        .help(c.unsupportedReason ?? (c.isOn ? "Live captions are on: click to take them off (⌃⌥⌘L). Language, size and the transcript are in Captions on the right."
                                             : "Show what you say as live captions, recognised on this Mac (⌃⌥⌘L)"))
        .contextMenu {
            Button("Captions Settings and Transcript") { studio.rail = .captions }
        }
    }
}
