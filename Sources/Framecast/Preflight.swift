import SwiftUI
import AppKit
import AVKit
import AVFoundation
import FramecastEngine

/// Checks to run before a show: sound reaches the stream, the mic hears you, cameras show a picture, permissions,
/// destinations, disk space, and optionally upload speed and a 10-second test recording you can play back.
/// Nothing leaves the Mac except the upload test, which says so on its button.
@Observable @MainActor
final class Preflight {
    enum Status: Equatable { case waiting, running, pass, warn, fail, skipped }
    enum Fix: Equatable { case putSoundInStream, openMixer, openDestinations, openScreenPrivacy }
    struct Item: Identifiable, Equatable {
        let id: String
        var title: String
        var status: Status = .waiting
        var detail = ""
        var fix: Fix?
    }

    var items: [Item] = []
    var isRunning = false
    var isRecordingTest = false
    var isTestingUpload = false
    var testFile: URL?
    @ObservationIgnored private var testFolder: URL?
    @ObservationIgnored nonisolated(unsafe) unowned let studio: Studio

    nonisolated init(studio: Studio) { self.studio = studio }

    /// Default upload-test address; test launches can point it at a server on this Mac.
    static var uploadURL: URL {
        URL(string: ProcessInfo.processInfo.environment["FRAMECAST_SPEEDTEST_URL"] ?? "https://speed.cloudflare.com/__up")!
    }
    static let uploadBytes = 8_000_000

    private func set(_ id: String, _ status: Status, _ detail: String, fix: Fix? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status; items[i].detail = detail; items[i].fix = fix
    }

    // MARK: Checks

    func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        let keep = items.filter { $0.id == "upload" || $0.id == "test" }
        items = [Item(id: "sound", title: "Sound reaches the stream"), Item(id: "mic", title: "Microphone hears you"),
                 Item(id: "camera", title: "Cameras show a picture"), Item(id: "screen", title: "Screen recording permission"),
                 Item(id: "destinations", title: "Destinations"), Item(id: "disk", title: "Space for recordings")] + keep
        checkSound()
        checkCameras()
        checkScreen()
        checkDestinations()
        checkDisk()
        await listenToMics()
        isRunning = false
    }

    func checkSound() {
        if let w = studio.silentStreamWarning { set("sound", .fail, w.detail, fix: .putSoundInStream) }
        else {
            let names = studio.audioSources.filter { ($0.audio ?? AudioSettings()).isInProgram && !($0.audio?.isMuted ?? false) }.map(\.name)
            set("sound", names.isEmpty ? .warn : .pass, names.isEmpty ? "No sound sources in the studio." : "In the stream: \(names.joined(separator: ", ")).")
        }
    }

    var liveMics: [SourceRecord] {
        studio.audioSources.filter {
            if case .microphone = $0.kind { return ($0.audio ?? AudioSettings()).isInProgram && !($0.audio?.isMuted ?? false) }
            return false
        }
    }

    func listenToMics() async {
        let mics = liveMics
        guard !mics.isEmpty else { set("mic", .fail, "No microphone is in the stream and switched on.", fix: .openMixer); return }
        set("mic", .running, "Say something now…")
        var peak: Float = 0
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            for m in mics { peak = max(peak, studio.levels[m.id]?.peak ?? 0) }
        }
        let db = peak > 0 ? 20 * log10(peak) : -120
        let level = String(format: "loudest %.0f dB", db)
        if db < -50 { set("mic", .fail, "Heard nothing (\(level)). Speak while the check runs, or check the mic and its level in the Mixer.", fix: .openMixer) }
        else if db < -32 { set("mic", .warn, "Quiet (\(level)). Speak while the check runs; if you did, move closer or raise the mic's level in the Mixer.", fix: .openMixer) }
        else if db > -2 { set("mic", .warn, "Very loud (\(level)): it may distort. Turn the mic's level down a little in the Mixer.", fix: .openMixer) }
        else { set("mic", .pass, "Good level (\(level)).") }
    }

    /// Cameras used by the scenes on air (and the preview): running, and not a black picture.
    func checkCameras() {
        var ids: [UUID] = []
        for c in CanvasKind.allCases {
            for s in [studio.programScene(c), studio.previewMode ? studio.previewScene : nil].compactMap({ $0 }) {
                for it in s.items(for: c) where it.isVisible {
                    if case .camera? = studio.source(it.sourceID)?.kind, !ids.contains(it.sourceID) { ids.append(it.sourceID) }
                }
            }
        }
        guard !ids.isEmpty else { set("camera", .skipped, "No camera in the scenes on air."); return }
        var problems: [String] = [], ok: [String] = []
        for id in ids {
            let name = studio.source(id)?.name ?? "Camera"
            if let st = studio.engine.state(of: id), st != .running { problems.append("\(name): \(Self.describe(st))"); continue }
            if let img = studio.engine.sourceSnapshot(id, maxSide: 48), Self.meanLuma(img) < 0.02 {
                problems.append("\(name) shows a black picture (lens cover, or another app using it?)")
            } else { ok.append(name) }
        }
        if problems.isEmpty { set("camera", .pass, "Picture from \(ok.joined(separator: ", ")).") }
        else { set("camera", .fail, problems.joined(separator: " · ")) }
    }

    func checkScreen() {
        let needs = studio.collection.sources.contains {
            switch $0.kind { case .display, .window, .application: return true; default: return false }
        }
        guard needs else { set("screen", .skipped, "No screen or window in the studio."); return }
        if CGPreflightScreenCaptureAccess() { set("screen", .pass, "Allowed.") }
        else { set("screen", .fail, "Framecast isn't allowed to record the screen yet.", fix: .openScreenPrivacy) }
    }

    func checkDestinations() {
        let on = studio.streaming.enabled
        guard !on.isEmpty else { set("destinations", .warn, "None switched on. You can still record.", fix: .openDestinations); return }
        var problems: [String] = [], ok: [String] = []
        for d in on {
            if d.platform != .custom && studio.streaming.destinations.key(for: d).isEmpty { problems.append("\(d.name) has no stream key"); continue }
            if d.canvas == .vertical && !studio.isVerticalOn { problems.append("\(d.name) needs the 9:16 canvas, which is off"); continue }
            ok.append("\(d.name) (\(d.canvas.title), \(String(format: "%.1f", Double(d.videoKbps) / 1000)) Mbps)")
        }
        if problems.isEmpty { set("destinations", .pass, ok.joined(separator: ", ")) }
        else { set("destinations", .fail, problems.joined(separator: " · "), fix: .openDestinations) }
    }

    func checkDisk() {
        guard let folder = studio.recordingFolders().first else { set("disk", .fail, "No recording folder is set (Settings › Recording)."); return }
        let probe = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        guard let cap = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage else {
            set("disk", .warn, "Couldn't read the free space of \(folder.path)."); return
        }
        let canvases = studio.stage.kinds.filter { $0 == .horizontal || studio.isVerticalOn }
        let kbps = canvases.reduce(0) { $0 + studio.settings.quality($1).1 + 192 }
        let hours = Double(cap) * 8 / 1000 / Double(max(1, kbps)) / 3600
        let gb = Double(cap) / 1e9
        let text = String(format: "%.0f GB free: about %@ of recording at your settings.", gb, Self.hoursText(hours))
        set("disk", hours < 0.5 ? .fail : (hours < 2 ? .warn : .pass), text)
    }

    // MARK: Upload speed (sends test data off the Mac; only when asked)

    func testUpload() async {
        guard !isTestingUpload else { return }
        isTestingUpload = true
        defer { isTestingUpload = false }
        if !items.contains(where: { $0.id == "upload" }) { items.append(Item(id: "upload", title: "Upload speed")) }
        set("upload", .running, "Sending \(Self.uploadBytes / 1_000_000) MB of test data to \(Self.uploadURL.host ?? "the test server")…")
        var req = URLRequest(url: Self.uploadURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let body = Data((0..<Self.uploadBytes).map { _ in UInt8.random(in: 0...255) })
        let start = Date()
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                set("upload", .warn, "The speed test server didn't accept the test."); return
            }
            let mbps = Double(Self.uploadBytes) * 8 / Date().timeIntervalSince(start) / 1e6
            let needed = Double(studio.streaming.enabled.reduce(0) { $0 + $1.videoKbps + 160 }) / 1000
            let speed = String(format: "%.1f Mbps up", mbps)
            if needed == 0 { set("upload", .pass, "\(speed).") }
            else if mbps >= needed * 1.5 { set("upload", .pass, String(format: "%@; your streams need %.1f Mbps.", speed, needed)) }
            else if mbps >= needed * 1.1 { set("upload", .warn, String(format: "%@ for %.1f Mbps of streams: little room to spare. Lower the bitrate in Destinations to about %.1f Mbps.", speed, needed, mbps / 1.5), fix: .openDestinations) }
            else { set("upload", .fail, String(format: "%@ isn't enough for %.1f Mbps of streams. Lower the bitrate in Destinations to about %.1f Mbps.", speed, needed, mbps / 1.5), fix: .openDestinations) }
        } catch {
            set("upload", .warn, "Couldn't reach the speed test server (\(error.localizedDescription)).")
        }
    }

    // MARK: Test recording

    func recordTest(seconds: Double = 10) async {
        guard !isRecordingTest else { return }
        isRecordingTest = true
        defer { isRecordingTest = false }
        if !items.contains(where: { $0.id == "test" }) { items.append(Item(id: "test", title: "Test recording")) }
        cleanUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Framecast pre-flight \(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        testFolder = folder
        let c = studio.editingCanvas
        let cfg = studio.settings.canvas(c)
        let (codec, kbps) = studio.settings.quality(c)
        let spec = RecordingSpec(canvas: c, container: .mp4, codec: codec, bitrateKbps: kbps, width: cfg.width, height: cfg.height,
                                 fps: cfg.fps, folders: [folder], baseName: "Pre-flight test", splitMinutes: 0, audioTracks: [1])
        set("test", .running, "Recording \(Int(seconds)) seconds of the \(c.title) canvas. Say something…")
        let recs: [CanvasRecorder]
        do { recs = try studio.engine.startRecording([spec]) } catch {
            set("test", .fail, "Couldn't start the test recording (\(error.localizedDescription))."); return
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let files: [URL] = await withCheckedContinuation { cont in studio.engine.stopRecording(recs) { cont.resume(returning: $0) } }
        guard let file = files.first else { set("test", .fail, "The test recording didn't produce a file."); return }
        let (duration, peak) = await Task.detached { await Self.inspect(file) }.value
        testFile = file
        let db = peak > 0 ? 20 * log10(peak) : -120
        if duration < seconds * 0.8 { set("test", .fail, String(format: "Only %.1f s were recorded.", duration)) }
        else if db < -50 { set("test", .fail, "The recording has no sound. Check Sound reaches the stream and the Mixer.", fix: .openMixer) }
        else { set("test", .pass, String(format: "%.1f s with sound (loudest %.0f dB). Play it back below.", duration, db)) }
    }

    /// Duration and loudest sample of a recording.
    nonisolated static func inspect(_ url: URL) async -> (Double, Float) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return (duration, 0) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { return (duration, 0) }
        var peak: Float = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(block) / 4
            var samples = [Float](repeating: 0, count: n)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for v in samples { peak = max(peak, abs(v)) }
        }
        return (duration, peak)
    }

    func cleanUp() {
        testFile = nil
        if let f = testFolder { try? FileManager.default.removeItem(at: f); testFolder = nil }
    }

    // MARK: Fixes

    func apply(_ fix: Fix) {
        switch fix {
        case .putSoundInStream:
            for s in studio.audioSources {
                if case .microphone = s.kind { studio.setAudio(s.id) { $0.isInProgram = true; $0.isMuted = false } }
                else if !studio.audioSources.contains(where: { ($0.audio ?? AudioSettings()).isInProgram }) { studio.setAudio(s.id) { $0.isInProgram = true } }
            }
            checkSound()
        case .openMixer: studio.rail = .audio
        case .openDestinations: studio.showsPreflight = false; studio.tab = .destinations
        case .openScreenPrivacy:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: Helpers

    static func describe(_ s: SourceState) -> String {
        switch s {
        case .failed(let m), .lost(let m): return m
        default: return "not running yet"
        }
    }
    static func meanLuma(_ img: CGImage) -> Double {
        let w = 16, h = 16
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in 0..<(w * h) { sum += 0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2]) }
        return sum / Double(w * h) / 255
    }
    static func hoursText(_ h: Double) -> String {
        h < 1 ? String(format: "%.0f minutes", h * 60) : (h < 10 ? String(format: "%.1f hours", h) : String(format: "%.0f hours", h))
    }
}

// MARK: - Sheet

struct PreflightSheet: View {
    @Environment(Studio.self) var studio
    @Environment(\.dismiss) var dismiss
    /// Drawn off-screen for checks: doesn't start or clear the checks.
    var isSnapshot = false
    var body: some View {
        let pf = studio.preflight
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pre-flight check").font(.fc(17, .bold))
                    Text("Run this before you go live. Nothing leaves your Mac unless you test upload speed.")
                        .font(.fc(12)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pf.items) { row($0) }
                    if let f = pf.testFile {
                        PlayerView(url: f).frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
                            .padding(.top, 6)
                    }
                }
                .padding(20)
            }
            Hairline()
            HStack(spacing: 8) {
                PillButton(title: pf.isRunning ? "Checking…" : "Check again", systemImage: "arrow.clockwise") { Task { await pf.runAll() } }
                    .disabled(pf.isRunning)
                PillButton(title: pf.isRecordingTest ? "Recording…" : "Record a 10-second test", systemImage: "record.circle") { Task { await pf.recordTest() } }
                    .disabled(pf.isRecordingTest)
                PillButton(title: pf.isTestingUpload ? "Testing…" : "Test upload speed", systemImage: "arrow.up.circle") { Task { await pf.testUpload() } }
                    .disabled(pf.isTestingUpload)
                    .help("Sends \(Preflight.uploadBytes / 1_000_000) MB of random test data to \(Preflight.uploadURL.host ?? "a speed test server") and times it.")
                Spacer()
            }
            .padding(16)
        }
        .frame(width: 640, height: 640)
        .background(Theme.panel)
        .task { if !isSnapshot && (pf.items.isEmpty || pf.items.allSatisfy({ $0.status == .waiting })) { await pf.runAll() } }
        .onDisappear { if !isSnapshot { pf.cleanUp(); pf.items = [] } }
    }

    func row(_ it: Preflight.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(it.status).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(it.title).font(.fc(13, .semibold)).foregroundStyle(Theme.text)
                if !it.detail.isEmpty {
                    Text(it.detail).font(.fc(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let fix = it.fix {
                PillButton(title: Self.fixTitle(fix), prominent: it.status == .fail) { studio.preflight.apply(fix) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.control2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(it.status == .fail ? Theme.live.opacity(0.6) : Theme.hairline))
    }

    @ViewBuilder func icon(_ s: Preflight.Status) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(Theme.text4)
        case .running: ProgressView().controlSize(.small)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.healthy)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.live)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.text4)
        }
    }

    static func fixTitle(_ f: Preflight.Fix) -> String {
        switch f {
        case .putSoundInStream: "Put sound in the stream"
        case .openMixer: "Open Mixer"
        case .openDestinations: "Open Destinations"
        case .openScreenPrivacy: "Open Privacy Settings"
        }
    }
}

/// Plays a file with the system player controls.
struct PlayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.player = AVPlayer(url: url)
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url { v.player = AVPlayer(url: url) }
    }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause(); v.player = nil }
}
