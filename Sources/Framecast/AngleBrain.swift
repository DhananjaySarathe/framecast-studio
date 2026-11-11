import Foundation
import Observation
import FoundationModels

/// The AI that picks camera angles from what the presenter says, on this Mac: Apple's on-device language model
/// (macOS 26 or later with Apple Intelligence on). Free, private, no API key. It gets the angles as the Mac sees them
/// (shot size, whether the presenter is in view or looking in) and the last half minute of speech, and answers with
/// one of the angle ids.
enum OnDeviceAngleAI {
    /// Whether the model can run here, and if not, why (for the Angles tab).
    static var availability: (ok: Bool, note: String) {
        guard #available(macOS 26.0, *) else { return (false, "needs macOS 26 or later") }
        switch SystemLanguageModel.default.availability {
        case .available: return (true, "on this Mac, free")
        case .unavailable(let r):
            switch r {
            case .appleIntelligenceNotEnabled: return (false, "turn on Apple Intelligence in System Settings")
            case .modelNotReady: return (false, "Apple's model is still downloading")
            case .deviceNotEligible: return (false, "this Mac can't run Apple's on-device model")
            @unknown default: return (false, "Apple's on-device model isn't available")
            }
        @unknown default: return (false, "Apple's on-device model isn't available")
        }
    }

    static func pick(angles: [(id: String, name: String, label: String, about: String)], onAir: String, heldSeconds: Int,
                     said: String) async throws -> AngleAI.Pick {
        guard #available(macOS 26.0, *) else { throw ScriptWriter.failure("The on-device AI needs macOS 26 or later.") }
        let ids = angles.map(\.id)
        let root = DynamicGenerationSchema(name: "AnglePick", properties: [
            .init(name: "angle", description: "the id of the angle to show", schema: DynamicGenerationSchema(name: "AngleID", anyOf: ids)),
            .init(name: "reason", description: "why, in at most twelve words", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "confidence", description: "from 0 to 1", schema: DynamicGenerationSchema(type: Double.self)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        // A fresh session each time: every pick stands on its own, and nothing builds up over a long show.
        let session = LanguageModelSession(model: .default, instructions: AngleAI.pickInstructions(for: ids))
        let r = try await session.respond(to: AngleAI.pickPrompt(angles: angles, onAir: onAir, heldSeconds: heldSeconds, said: said),
                                          schema: schema, includeSchemaInPrompt: true)
        let angle = (try? r.content.value(String.self, forProperty: "angle")) ?? ""
        let reason = (try? r.content.value(String.self, forProperty: "reason")) ?? ""
        let confidence = (try? r.content.value(Double.self, forProperty: "confidence")) ?? 0
        return AngleAI.Pick(angle: angle, reason: String(reason.prefix(120)), confidence: max(0, min(1, confidence)))
    }
}

/// The angles' own ears: when the AI should follow what the presenter says and Listen (the show director's
/// transcription) isn't running, the angles run Apple's on-device speech recognition on the microphone themselves.
/// It stands aside whenever the director listens (the director then passes on what it hears).
@Observable
final class AngleEars {
    @ObservationIgnored unowned let studio: Studio
    @ObservationIgnored private var listener: AnyObject?
    /// After a failed start (or the recognizer stopping), wait before trying again: 5 s, then longer, up to a minute.
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var backoff: TimeInterval = 5
    /// The microphone the ears listen to, once their start finished.
    @ObservationIgnored private var tappedID: UUID?
    private(set) var on = false
    var status = ""
    init(studio: Studio) { self.studio = studio }

    /// Called every second: starts or stops so it runs exactly when wanted and the director isn't listening.
    func keep(_ wanted: Bool) {
        let should = wanted && !studio.director.isListening
        if should {
            if !on { if Date() >= retryAt { start() }; return }
            // The presenter switched microphones (removed this one, or muted it and speaks into another): follow.
            if let id = tappedID {
                let mics = studio.audioSources.filter { if case .microphone = $0.kind { return true }; return false }
                let cur = mics.first { $0.id == id }
                let liveOther = mics.contains { $0.id != id && !($0.audio?.isMuted ?? false) }
                if cur == nil || ((cur?.audio?.isMuted ?? false) && liveOther) { stop(); start() }
            }
        } else {
            if on { stop() } else if !status.isEmpty { status = "" }
            // Not wanted, or Listen took over: forget an old failure so the next start is immediate.
            retryAt = .distantPast
            backoff = 5
        }
    }

    private func failed(_ why: String) {
        stop()
        status = "\(why) Trying again in \(Int(backoff)) s."
        retryAt = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 60)
    }

    private func start() {
        guard #available(macOS 26.0, *), ShowListener.isSupported else { status = "Hearing you needs macOS 26 or later."; return }
        let mics = studio.audioSources.filter { if case .microphone = $0.kind { return true }; return false }
        guard let mic = mics.first(where: { ($0.audio?.isInProgram ?? true) && !($0.audio?.isMuted ?? false) }) ?? mics.first else {
            status = "Add a microphone so the AI can hear you."; return
        }
        let l = ShowListener(locale: (studio.settings.s.listenLanguage ?? .auto).primary)
        l.onResult = { [weak self, weak l] text, fin, _, _ in
            guard let self else { return }
            if let l, self.listener === l { self.backoff = 5 }     // hearing works: the next failure waits 5 s again
            self.studio.angles.hear(text, isFinal: fin)
        }
        // The recognizer's own news (a one-time model download, or stopping mid-show) shows in Angles; stopping
        // means starting again after a pause.
        l.onStatus = { [weak self, weak l] s in
            guard let self, let l, self.listener === l else { return }
            if s.hasPrefix("Speech recognition stopped") { self.failed(s) } else { self.status = s }
        }
        listener = l
        on = true
        status = "Listening on this Mac…"
        Task { @MainActor in
            do {
                try await l.start()
                // Listen may have started meanwhile: its tap wins, and these ears stand aside.
                guard self.on, self.listener === l, !self.studio.director.isListening else {
                    l.stop()
                    if self.listener === l { self.listener = nil; self.on = false; self.status = "" }
                    return
                }
                self.studio.engine.mixer.setListenTap(mic.id) { [weak l] s, n in l?.push(stereo: s, frames: n) }
                self.tappedID = mic.id
                self.status = "Hearing \(mic.name) on this Mac"
            } catch {
                guard self.listener === l else { return }
                self.failed("Couldn't start hearing you: \(error.localizedDescription).")
            }
        }
    }

    func stop() {
        guard on else { return }
        on = false
        // Only clear the microphone tap if it's still ours (the director takes it over when it starts).
        if !studio.director.isListening { studio.engine.mixer.setListenTap(nil, nil) }
        if #available(macOS 26.0, *), let l = listener as? ShowListener { l.stop() }
        listener = nil
        tappedID = nil
        status = ""
    }
}
