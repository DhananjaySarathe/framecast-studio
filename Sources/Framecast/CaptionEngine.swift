import Foundation
import Observation
import CoreMedia
import Speech
import FramecastEngine

/// One line of the transcript: a stretch of speech once the recogniser settled it. `text` is what's shown and
/// saved (corrections included), `heard` what was recognised.
struct CaptionLine: Identifiable, Equatable {
    let id: Int
    var text: String
    let heard: String
    /// Host clock seconds, and seconds into the show.
    let hostStart: Double
    let hostEnd: Double
    let showStart: Double
    var isCorrected: Bool { text != heard }
}

struct CaptionLanguage: Identifiable, Hashable { let id: String; let title: String }

/// Live captions: Apple's on-device speech recognition on the presenter's microphone, shown at the bottom (or top)
/// of both canvases as they speak, kept as a transcript that can be corrected, and written next to recordings as
/// subtitles. It has its own microphone tap, so it runs alongside Listen and the angles' ears. Nothing leaves the Mac.
@Observable
final class CaptionEngine {
    @ObservationIgnored unowned let studio: Studio
    private(set) var isOn = false
    var status = ""
    private(set) var transcript: [CaptionLine] = []
    /// Words still being recognised (not in the transcript yet).
    private(set) var guess = ""
    private(set) var languages: [CaptionLanguage] = []
    /// The language being recognised now ("English (India)").
    private(set) var hearing = ""

    @ObservationIgnored private var listener: AnyObject?
    @ObservationIgnored private var track = CaptionTrack()
    @ObservationIgnored private let clock = ClockBox()
    @ObservationIgnored private var micID: UUID?
    @ObservationIgnored private var feeding = false
    @ObservationIgnored private var showStart: Double?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var backoff: TimeInterval = 5

    init(studio: Studio) { self.studio = studio }

    var settings: CaptionSettings {
        get { studio.settings.s.captions ?? CaptionSettings() }
        set {
            let old = settings
            studio.settings.s.captions = newValue
            if old.language != newValue.language, isOn, !feeding { start() } else { push() }
        }
    }

    var canCaption: Bool { if #available(macOS 26.0, *) { return ShowListener.isSupported } else { return false } }
    var unsupportedReason: String? {
        guard !canCaption else { return nil }
        if #available(macOS 26.0, *) { return "Apple's speech recognition isn't available on this Mac, so live captions can't run." }
        return "Live captions need macOS 26 or later (Apple's on-device speech recognition)."
    }

    // MARK: Languages

    /// English for this Mac's region when no language is chosen.
    static func locale(for id: String) -> Locale {
        id.isEmpty ? Locale(identifier: "en_\(Locale.current.region?.identifier ?? "US")") : Locale(identifier: id)
    }
    static func title(_ id: String) -> String {
        let l = locale(for: id)
        return Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier
    }

    /// Every language this Mac's recogniser knows: English and Hindi first, then the rest by name.
    func loadLanguages() {
        guard languages.isEmpty, #available(macOS 26.0, *), canCaption else { return }
        Task { @MainActor in
            let ids = await SpeechTranscriber.supportedLocales.map(\.identifier)
            let items = ids.map { CaptionLanguage(id: $0, title: Self.title($0)) }
            func rank(_ l: CaptionLanguage) -> Int { l.id.hasPrefix("en") ? 0 : (l.id.hasPrefix("hi") ? 1 : 2) }
            self.languages = items.sorted { (rank($0), $0.title) < (rank($1), $1.title) }
        }
    }

    // MARK: On and off

    func toggle() { isOn ? stop() : start() }

    /// The presenter's microphone, as Listen picks it: the first one in the stream and not muted, else the first.
    private func presenterMic() -> SourceRecord? {
        let mics = studio.audioSources.filter { if case .microphone = $0.kind { return true }; return false }
        return mics.first { ($0.audio?.isInProgram ?? true) && !($0.audio?.isMuted ?? false) } ?? mics.first
    }

    /// Starts (or restarts) captioning the presenter's microphone, or, for tests, an audio file played in real time.
    func start(file: URL? = nil) {
        guard #available(macOS 26.0, *), canCaption else { status = unsupportedReason ?? ""; return }
        let mic = file == nil ? presenterMic() : nil
        guard file != nil || mic != nil else { status = "Add a microphone to the studio first."; return }
        stopListener()
        isOn = true
        feeding = file != nil
        retryAt = nil
        if showStart == nil {
            // Transcript times count from the start of the recording or broadcast, else from the first caption.
            showStart = studio.sessionStart.map { HostClock.seconds() - Date().timeIntervalSince($0) } ?? HostClock.seconds()
        }
        let l = ShowListener(locale: Self.locale(for: settings.language))
        listener = l
        clock.reset()
        track.clear(); guess = ""
        l.onResult = { [weak self, weak l] text, fin, start, end in
            guard let self, let l, self.listener === l else { return }
            self.backoff = 5
            self.take(text, isFinal: fin, start: start, end: end)
        }
        l.onStatus = { [weak self, weak l] s in
            guard let self, let l, self.listener === l else { return }
            if s.hasPrefix("Speech recognition stopped") { self.failed(s) } else { self.status = s }
        }
        status = "Starting speech recognition…"
        push()
        startTimer()
        Task { @MainActor in
            do {
                try await l.start()
                guard self.isOn, self.listener === l else { l.stop(); return }
                let wanted = Self.locale(for: self.settings.language).identifier
                self.hearing = l.resolved.map { Self.title($0.identifier) } ?? ""
                let fellBack = l.resolved.map { $0.language.languageCode != Locale(identifier: wanted).language.languageCode } ?? false
                if let file {
                    self.clock.note(frames: 0, host: HostClock.seconds())
                    l.feed(file: file)
                    self.status = "Captioning \(file.lastPathComponent) in \(self.hearing)"
                } else if let mic {
                    let box = self.clock
                    self.studio.engine.mixer.setCaptionTap(mic.id) { [weak l] s, n, pts in
                        box.note(frames: n, host: CMTimeGetSeconds(pts))
                        l?.push(stereo: s, frames: n)
                    }
                    self.micID = mic.id
                    self.status = fellBack ? "\(Self.title(wanted)) isn't available on this Mac; captioning \(mic.name) in \(self.hearing)."
                                           : "Captioning \(mic.name) in \(self.hearing), on this Mac only"
                }
            } catch {
                guard self.listener === l else { return }
                self.failed("Captions couldn't start: \(error.localizedDescription).")
            }
        }
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        stopListener()
        timer?.invalidate(); timer = nil
        retryAt = nil
        track.clear(); guess = ""
        studio.engine.showCaptions(nil)
        status = ""
        hearing = ""
    }

    private func stopListener() {
        studio.engine.mixer.setCaptionTap(nil, nil)
        if #available(macOS 26.0, *), let l = listener as? ShowListener { l.stop() }
        listener = nil
        micID = nil
    }

    /// The recogniser stopped or couldn't start: captions stay on and try again after a pause (5 s, then longer).
    private func failed(_ why: String) {
        stopListener()
        status = "\(why) Trying again in \(Int(backoff)) s."
        retryAt = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 60)
    }

    /// Every second while on: try again after a failure, and follow the presenter to another microphone (this one
    /// removed, or muted while another isn't).
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isOn else { return }
            if let r = self.retryAt { if Date() >= r { self.start() }; return }
            guard !self.feeding, let id = self.micID else { return }
            let mics = self.studio.audioSources.filter { if case .microphone = $0.kind { return true }; return false }
            let cur = mics.first { $0.id == id }
            let liveOther = mics.contains { $0.id != id && !($0.audio?.isMuted ?? false) }
            if cur == nil || ((cur?.audio?.isMuted ?? false) && liveOther) { self.start() }
        }
    }

    // MARK: Words

    private func take(_ text: String, isFinal: Bool, start: Double, end: Double) {
        let now = HostClock.seconds()
        if let id = track.take(text, isFinal: isFinal, start: start, end: end, now: now) {
            let hs = clock.host(at: start) ?? now, he = clock.host(at: end) ?? now
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript.append(CaptionLine(id: id, text: t, heard: t, hostStart: hs, hostEnd: max(he, hs), showStart: hs - (showStart ?? hs)))
            if transcript.count > 3000 { transcript.removeFirst(500) }
        }
        let g = track.guess.joined(separator: " ")
        if g != guess { guess = g }
        push()
    }

    /// Hands the current words to the engine (both canvases).
    private func push() {
        guard isOn else { return }
        let s = settings
        studio.engine.showCaptions(CaptionFrame(words: track.words, size: s.size, position: s.position, lastChange: track.lastChange))
    }

    /// A correction from the transcript: saved in the subtitles, and shown on air if the line is still on screen.
    /// Returns whether the line was still on screen.
    @discardableResult
    func correct(_ id: Int, _ text: String) -> Bool {
        guard let i = transcript.firstIndex(where: { $0.id == id }) else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript[i].text = t
        let now = HostClock.seconds()
        guard isOn, !CaptionFade.isGone(now: now, lastChange: track.lastChange), track.correct(id: id, text: t) else { return false }
        push()
        return true
    }

    func clearTranscript() { transcript = []; showStart = isOn ? HostClock.seconds() : nil }

    /// The whole transcript with show times, for the clipboard.
    var allText: String {
        CaptionExport.transcript(transcript.filter { !$0.text.isEmpty }.map { TimedCaption(start: $0.showStart, end: $0.showStart, text: $0.text) })
    }

    // MARK: After the show

    /// Writes "<recording>.srt" and "<recording> transcript.txt" next to each file, timed from the recording's start
    /// (pauses left out), from the transcript with its corrections. Nothing when nothing was said while recording.
    func writeFiles(for files: [URL], recorder: CanvasRecorder?) {
        guard let r = recorder, !files.isEmpty else { return }
        func rec(_ host: Double) -> Double { max(0, r.recordedSeconds(now: CMTime(seconds: host, preferredTimescale: 1_000_000_000))) }
        let items = transcript.compactMap { l -> TimedCaption? in
            let s = rec(l.hostStart), e = rec(l.hostEnd)
            // Said before the recording, after it, or in a pause (or mostly): left out.
            guard !l.text.isEmpty, CaptionExport.keeps(inside: e - s, spoken: l.hostEnd - l.hostStart) else { return nil }
            return TimedCaption(start: s, end: e, text: l.text)
        }
        guard !items.isEmpty else { return }
        let srt = CaptionExport.srt(items), txt = CaptionExport.transcript(items)
        for f in files {
            let base = f.deletingPathExtension().path
            try? srt.write(to: URL(fileURLWithPath: base + ".srt"), atomically: true, encoding: .utf8)
            try? txt.write(to: URL(fileURLWithPath: base + " transcript.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// For test scripts (dump-state).
    func dump() -> [String: Any] {
        [
            "on": isOn, "status": status, "language": settings.language, "hearing": hearing, "size": settings.size.rawValue,
            "position": settings.position.rawValue, "supported": canCaption,
            "linesHorizontal": studio.engine.captionLines(.horizontal), "linesVertical": studio.engine.captionLines(.vertical),
            "transcriptCount": transcript.count, "lastText": transcript.last?.text ?? "", "guess": guess,
            "transcript": transcript.suffix(30).map { ["id": $0.id, "text": $0.text, "heard": $0.heard, "show": $0.showStart,
                                                       "hostStart": $0.hostStart, "hostEnd": $0.hostEnd] as [String: Any] },
            "now": HostClock.seconds(),
        ]
    }
}

/// The caption clock, shared with the microphone tap's thread.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var clock = CaptionClock()
    func reset() { lock.lock(); clock = CaptionClock(); lock.unlock() }
    func note(frames: Int, host: Double) { lock.lock(); clock.note(frames: frames, host: host); lock.unlock() }
    func host(at t: Double) -> Double? { lock.lock(); defer { lock.unlock() }; return clock.host(at: t) }
}
