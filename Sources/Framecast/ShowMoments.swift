import Foundation
import FramecastEngine

/// A scene change or marker during a show, with where it falls in the recording and in the broadcast.
struct ShowEvent: Equatable {
    var date: Date
    var label: String
    var isMarker: Bool
    var recOffset: Double?
    var liveOffset: Double?
}

/// Markers, chapters and instant clips.
extension Studio {
    static let clipSeconds = 30.0

    func noteEvent(_ label: String, marker: Bool) {
        guard isRecording || streaming.isLive else { return }
        let now = Date()
        showEvents.append(ShowEvent(date: now, label: label, isMarker: marker, recOffset: isRecording ? recordedSeconds : nil,
                                    liveOffset: streaming.liveSince.map { now.timeIntervalSince($0) }))
    }

    /// Drops a marker at this moment of the recording and broadcast (⌥⌘M).
    func addMarker() {
        guard isRecording || streaming.isLive else { notice = "Markers are for while you're recording or live."; return }
        let n = showEvents.filter(\.isMarker).count + 1
        noteEvent("Marker \(n)", marker: true)
        let at = (isRecording ? recordedSeconds : streaming.liveSince.map { Date().timeIntervalSince($0) }) ?? 0
        showFlash("Marker \(n) at \(Self.chapterTime(at))")
    }

    /// Chapter list ("0:00 Intro") on the recording's or the broadcast's timeline. Entries less than 10 s apart are
    /// merged, as YouTube asks.
    func chapters(onRecording: Bool) -> String {
        var list = showEvents.compactMap { e -> (t: Double, label: String, marker: Bool)? in
            guard let t = onRecording ? e.recOffset : e.liveOffset else { return nil }
            return (max(0, t), e.label, e.isMarker)
        }.sorted { $0.t < $1.t }
        guard !list.isEmpty else { return "" }
        if list[0].t > 1 { list.insert((0, "Start", false), at: 0) } else { list[0].t = 0 }
        // YouTube wants chapters 10 s or longer. Something closer than that to the previous chapter is left out,
        // except that a marker replaces a scene change just before it (not the opening chapter).
        var out: [(t: Double, label: String, marker: Bool)] = []
        for e in list {
            guard let l = out.last, e.t - l.t < 10 else { out.append(e); continue }
            if out.count > 1 && e.marker && !l.marker { out[out.count - 1] = e }
        }
        return out.map { "\(Self.chapterTime($0.t)) \($0.label)" }.joined(separator: "\n")
    }

    static func chapterTime(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    func startReplay() {
        var list: [ReplayBuffer.Canvas] = []
        for c in CanvasKind.allCases where c == .horizontal || isVerticalOn {
            let cfg = settings.canvas(c)
            list.append(ReplayBuffer.Canvas(kind: c, width: cfg.width, height: cfg.height, fps: cfg.fps))
        }
        replay = try? engine.startReplay(list, seconds: Self.clipSeconds)
    }

    /// Saves the last 30 seconds of each canvas next to your recordings (⌥⌘S), and marks the moment.
    func saveClip() {
        guard let r = replay else { notice = "Instant clips work while you're recording or live: Framecast keeps the last 30 seconds."; return }
        let folder = recordingFolders().first ?? URL(fileURLWithPath: AppSettings.defaultFolder)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Framecast clip \(f.string(from: Date()))"
        let held = min(Self.clipSeconds, r.heldSeconds)
        showFlash("Saving the last \(Int(held)) seconds…")
        r.save(to: folder, baseName: base) { [weak self] urls, problem in
            DispatchQueue.main.async {
                guard let self else { return }
                self.savedClips += urls
                if urls.isEmpty { self.alerts.append(AlertItem(title: "Clip not saved", detail: problem ?? "Nothing has been held yet.")) }
                else { self.showFlash(urls.count > 1 ? "Saved 16:9 and 9:16 clips" : "Saved a clip") }
            }
        }
    }
}
