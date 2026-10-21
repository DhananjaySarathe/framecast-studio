// Live transcription latency on this Mac with Apple's on-device SpeechAnalyzer + SpeechTranscriber.
// Plays an audio file into the analyzer in real time (100 ms chunks, paced by the wall clock, like a live mic)
// and reports how long after a phrase is spoken its text appears (volatile = first guess, final = settled).
//
//   swiftc -O main.swift -o ../stt-latency.bin && ../stt-latency.bin ../talk.aiff [--context] [--fast] [--jsonl]
// --jsonl writes every result to stdout as one JSON line (arrival time, audio range, final or not, text, and the
// text pieces with their audio times) for word_latency.py and the cue follower; the readable log moves to stderr.
import Foundation
import AVFoundation
import Speech

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: stt-latency <audio file> [--context] [--fast] [--jsonl]"); exit(2) }
let url = URL(fileURLWithPath: args[1])
let useContext = args.contains("--context")
let useFast = args.contains("--fast")
let jsonl = args.contains("--jsonl")

/// Readable progress: stdout normally, stderr when stdout carries JSON lines.
func say(_ s: String) {
    if jsonl { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } else { print(s) }
}
func emit(_ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj)
    FileHandle.standardOutput.write(d + Data([0x0A]))
}

func now() -> Double { Date().timeIntervalSince1970 }

@MainActor
func run() async throws {
    say("SpeechTranscriber available: \(SpeechTranscriber.isAvailable)")
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
        say("en-US not supported"); exit(1)
    }
    let installed = await SpeechTranscriber.installedLocales
    say("locale \(locale.identifier); installed: \(installed.map(\.identifier).sorted().joined(separator: ", "))")

    var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    if useFast { reporting.insert(.fastResults) }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting,
                                        attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    if !installed.contains(where: { $0.identifier == locale.identifier }) {
        let t = now()
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            say("downloading the on-device model…")
            try await req.downloadAndInstall()
            say(String(format: "model installed in %.1f s", now() - t))
        }
    }

    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { say("no audio format"); exit(1) }
    say("analyzer format: \(format)")
    let context = AnalysisContext()
    if useContext {
        context.contextualStrings[.general] = ["Claude", "Opus", "Sonnet", "Haiku", "Opus 5.5", "Sonnet 5.5", "benchmark"]
    }
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    try await analyzer.setContext(context)
    try await analyzer.prepareToAnalyze(in: format)

    // Collect results with the wall-clock time they arrived. Per word: the first time it shows up (volatile or final)
    // minus the time it finished being spoken, from the word's own audio time range.
    var volatileLat: [Double] = [], finalLat: [Double] = []
    var firstSeen: [Int: Double] = [:]          // word end time (ms) -> first-seen latency
    var finalSeen: [Int: Double] = [:]
    var finalText = ""
    var startWall = 0.0
    let reader = Task { @MainActor in
        for try await r in transcriber.results {
            let arrived = now() - startWall
            let audioEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(r.range))
            let isFinal = CMTimeCompare(r.resultsFinalizationTime, CMTimeRangeGetEnd(r.range)) >= 0
            let lag = arrived - audioEnd
            if isFinal { finalLat.append(lag); finalText += String(r.text.characters) + " " } else { volatileLat.append(lag) }
            if jsonl {
                let pieces: [[Any]] = r.text.runs.map { run in
                    let piece = String(r.text[run.range].characters)
                    guard let tr = run.audioTimeRange else { return [piece, NSNull(), NSNull()] }
                    return [piece, CMTimeGetSeconds(tr.start), CMTimeGetSeconds(CMTimeRangeGetEnd(tr))]
                }
                emit(["t": arrived, "start": CMTimeGetSeconds(r.range.start), "end": audioEnd, "final": isFinal,
                      "text": String(r.text.characters), "pieces": pieces])
            }
            for run in r.text.runs {
                guard let tr = run.audioTimeRange else { continue }
                let key = Int((CMTimeGetSeconds(CMTimeRangeGetEnd(tr)) * 1000).rounded())
                let wordLag = arrived - CMTimeGetSeconds(CMTimeRangeGetEnd(tr))
                if firstSeen[key] == nil { firstSeen[key] = wordLag }
                if isFinal && finalSeen[key] == nil { finalSeen[key] = wordLag }
            }
            say(String(format: "%6.2fs  audio %5.2f–%5.2f  lag %5.2fs  %@  %@", arrived, CMTimeGetSeconds(r.range.start), audioEnd, lag,
                         isFinal ? "FINAL" : "volat", String(String(r.text.characters).prefix(70))))
        }
    }

    // Read the file, convert to the analyzer's format, and feed 100 ms chunks in real time.
    let file = try AVAudioFile(forReading: url)
    let inFmt = file.processingFormat
    let all = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: all)
    let conv = AVAudioConverter(from: inFmt, to: format)!
    let outAll = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(all.frameLength) * format.sampleRate / inFmt.sampleRate) + 4096)!
    var fed = false
    var err: NSError?
    conv.convert(to: outAll, error: &err) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return all }
    let chunk = AVAudioFrameCount(format.sampleRate * 0.1)
    let total = outAll.frameLength
    say(String(format: "feeding %.1f s of audio in real time…", Double(total) / format.sampleRate))

    let analysis = Task { try await analyzer.start(inputSequence: stream) }
    startWall = now()
    var pos: AVAudioFrameCount = 0
    while pos < total {
        let n = min(chunk, total - pos)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        let bytes = Int(n) * Int(format.streamDescription.pointee.mBytesPerFrame)
        if let src = outAll.audioBufferList.pointee.mBuffers.mData, let dst = b.audioBufferList.pointee.mBuffers.mData {
            memcpy(dst, src + Int(pos) * Int(format.streamDescription.pointee.mBytesPerFrame), bytes)
        }
        cont.yield(AnalyzerInput(buffer: b, bufferStartTime: CMTime(value: CMTimeValue(pos), timescale: CMTimeScale(format.sampleRate))))
        pos += n
        // Pace: the chunk ending at `pos` may only be handed over once that much real time has passed.
        let due = startWall + Double(pos) / format.sampleRate
        let wait = due - now()
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
    cont.finish()
    _ = try? await analysis.value
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = try? await reader.value

    func stats(_ a: [Double]) -> String {
        guard !a.isEmpty else { return "none" }
        let s = a.sorted()
        return String(format: "n=%d median %.2fs p90 %.2fs max %.2fs", s.count, s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))], s.last!)
    }
    say("\nper word, first appearance after it was spoken: \(stats(Array(firstSeen.values)))")
    say("per word, settled (final) after it was spoken:  \(stats(Array(finalSeen.values)))")
    say("\nFINAL TEXT:\n\(finalText)")
}

Task { @MainActor in
    do { try await run() } catch { say("error: \(error)") }
    exit(0)
}
RunLoop.main.run()
