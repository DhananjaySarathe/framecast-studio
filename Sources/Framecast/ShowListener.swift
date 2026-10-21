import Foundation
import AVFoundation
import Speech

/// Live transcription with Apple's on-device recognizer (macOS 26 or later): the presenter's microphone goes in,
/// text comes out about half a second later. Nothing leaves the Mac. It gets the microphone's samples from the
/// mixer, so it hears exactly the mic that's in the show and never opens a device of its own.
@available(macOS 26.0, *)
final class ShowListener: @unchecked Sendable {
    /// Called on the main queue with each result (`isFinal` once the text for that stretch is settled).
    var onResult: ((_ text: String, _ isFinal: Bool, _ start: Double, _ end: Double) -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "framecast.listener", qos: .userInitiated)
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let mono48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private var pending: [Float] = []
    private var tasks: [Task<Void, Never>] = []
    private var running = false

    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    /// The language to recognise (falls back to US English when this Mac can't do it).
    let preferred: Locale
    init(locale: Locale = .current) { preferred = locale }

    func start() async throws {
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw Self.failure("Speech recognition isn't available for your language on this Mac.") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        if !(await SpeechTranscriber.installedLocales).contains(where: { $0.identifier == locale.identifier }),
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Downloading Apple's speech model for \(locale.identifier) (one time)…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Self.failure("Speech recognition couldn't start.")
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        queue.sync {
            self.format = format
            self.converter = AVAudioConverter(from: mono48k, to: format)
            self.input = cont
            self.analyzer = analyzer
            self.pending = []
            self.running = true
        }
        tasks.append(Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    let end = CMTimeRangeGetEnd(r.range)
                    let isFinal = CMTimeCompare(r.resultsFinalizationTime, end) >= 0
                    let text = String(r.text.characters), start = CMTimeGetSeconds(r.range.start), endS = CMTimeGetSeconds(end)
                    DispatchQueue.main.async { self?.onResult?(text, isFinal, start, endS) }
                }
            } catch { self?.status("Speech recognition stopped: \(error.localizedDescription)") }
        })
        tasks.append(Task { try? await analyzer.start(inputSequence: stream) })
    }

    func stop() {
        let (cont, analyzer) = queue.sync { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) in
            running = false
            defer { input = nil; self.analyzer = nil; converter = nil; pending = [] }
            return (input, self.analyzer)
        }
        cont?.finish()
        Task { await analyzer?.cancelAndFinishNow() }
        tasks.forEach { $0.cancel() }; tasks = []
    }

    /// Interleaved stereo 48 kHz samples from the mixer (any thread).
    func push(stereo samples: UnsafePointer<Float>, frames: Int) {
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = (samples[2 * i] + samples[2 * i + 1]) * 0.5 }
        queue.async { self.add(mono) }
    }

    /// Mono 48 kHz samples (tests feed files through here).
    func push(mono: [Float]) { queue.async { self.add(mono) } }

    // On `queue`: hand the recognizer 100 ms at a time in its own format.
    private func add(_ samples: [Float]) {
        guard running, let format, let converter, let input else { return }
        pending += samples
        let chunk = 4_800
        while pending.count >= chunk {
            let slice = Array(pending.prefix(chunk)); pending.removeFirst(chunk)
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: mono48k, frameCapacity: AVAudioFrameCount(chunk)) else { return }
            inBuf.frameLength = AVAudioFrameCount(chunk)
            slice.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: chunk) }
            let cap = AVAudioFrameCount(Double(chunk) * format.sampleRate / 48_000) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var given = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, st in
                if given { st.pointee = .noDataNow; return nil }
                given = true; st.pointee = .haveData; return inBuf
            }
            if err == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
        }
    }

    private func status(_ s: String) { DispatchQueue.main.async { self.onStatus?(s) } }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Framecast.Listener", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Reads an audio file and plays it into the recognizer in real time, like a microphone (test hook).
    func feed(file url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let f = try? AVAudioFile(forReading: url),
                  let all = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                  (try? f.read(into: all)) != nil,
                  let conv = AVAudioConverter(from: f.processingFormat, to: self.mono48k),
                  let out = AVAudioPCMBuffer(pcmFormat: self.mono48k, frameCapacity: AVAudioFrameCount(Double(all.frameLength) * 48_000 / f.processingFormat.sampleRate) + 4_096)
            else { self.status("Couldn't read \(url.lastPathComponent)"); return }
            var given = false
            conv.convert(to: out, error: nil) { _, st in
                if given { st.pointee = .endOfStream; return nil }
                given = true; st.pointee = .haveData; return all
            }
            // Then two seconds of silence, as a microphone would keep sending, so the last words settle.
            let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))) + [Float](repeating: 0, count: 96_000)
            let start = Date()
            var pos = 0
            while pos < samples.count {
                let n = min(4_800, samples.count - pos)
                self.push(mono: Array(samples[pos..<pos + n]))
                pos += n
                let due = start.addingTimeInterval(Double(pos) / 48_000).timeIntervalSinceNow
                if due > 0 { Thread.sleep(forTimeInterval: due) }
            }
        }
    }
}
