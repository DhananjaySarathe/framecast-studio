import Foundation
import Observation
import FramecastEngine

enum PreviewQuality: String, Codable, CaseIterable { case full, half, off
    var title: String { rawValue.capitalized }
}
enum CanvasSizePreset: String, Codable, CaseIterable {
    case p720, p1080, p1440, p2160, custom
    var title: String { switch self { case .p720: "720p"; case .p1080: "1080p"; case .p1440: "1440p"; case .p2160: "4K"; case .custom: "Custom" } }
    var long: Int? { switch self { case .p720: 1280; case .p1080: 1920; case .p1440: 2560; case .p2160: 3840; case .custom: nil } }
}
struct CanvasSetting: Codable, Equatable {
    var size: CanvasSizePreset = .p1080
    var width = 1920, height = 1080, fps = 30
    static func horizontal() -> CanvasSetting { CanvasSetting() }
    static func vertical() -> CanvasSetting { CanvasSetting(size: .p1080, width: 1080, height: 1920, fps: 30) }
    mutating func apply(_ preset: CanvasSizePreset, vertical: Bool) {
        size = preset
        guard let l = preset.long else { return }
        let s = l * 9 / 16
        if vertical { width = s; height = l } else { width = l; height = s }
    }
}
enum StageCanvases: String, Codable, CaseIterable { case horizontal, vertical, both
    var title: String { switch self { case .horizontal: "16:9"; case .vertical: "9:16"; case .both: "Both" } }
    var kinds: [CanvasKind] { switch self { case .horizontal: [.horizontal]; case .vertical: [.vertical]; case .both: [.horizontal, .vertical] } }
}
enum RecordingPreset: String, Codable, CaseIterable { case good, great, custom
    var title: String { rawValue.capitalized }
}
enum NameTag: String, Codable, CaseIterable { case time, date, show, layout, canvas
    var title: String { switch self { case .time: "Time"; case .date: "Date"; case .show: "Show name"; case .layout: "Scene"; case .canvas: "Format" } }
}
enum EncoderSharing: String, Codable, CaseIterable { case qualityFirst, balanced, efficiencyFirst
    var title: String { switch self { case .qualityFirst: "Quality first"; case .balanced: "Balanced"; case .efficiencyFirst: "Efficiency first" } }
    var detail: String {
        switch self {
        case .qualityFirst: "Each destination gets its own settings. Uses the most encoders."
        case .balanced: "Destinations with similar settings share an encoder."
        case .efficiencyFirst: "As few encoders as possible; some destinations get a higher bitrate than they need."
        }
    }
}
struct RecordingFolder: Codable, Identifiable, Equatable { var id = UUID(); var path: String; var isEnabled = true }

/// Everything in Settings. Stored as one JSON blob in UserDefaults (no account, nothing leaves the Mac).
@Observable
final class AppSettings {
    struct Stored: Codable {
        var keepsDisplayAwake = true
        var confirmsEndStream = true
        var confirmsQuit = true
        var previewQuality: PreviewQuality = .full
        var horizontal = CanvasSetting.horizontal()
        var vertical = CanvasSetting.vertical()
        var isVerticalOn = true
        var stage: StageCanvases = .horizontal
        var containerH: ContainerFormat = .mov
        var containerV: ContainerFormat = .mov
        var preset: RecordingPreset = .good
        var customCodec: VideoCodec = .h264
        var customKbpsH = 16_000
        var customKbpsV = 12_000
        var folders: [RecordingFolder] = [RecordingFolder(path: AppSettings.defaultFolder)]
        var splitMinutes = 0
        var nameTags: [NameTag] = [.time, .date]
        var warnsLowSpace = true
        var separateTracks = false
        var recordsWhenLive = false
        var encoderSharing: EncoderSharing = .balanced
        var transition: TransitionKind = .move
        var transitionMs = 700
        var hasOnboarded = false
        var updatesNotice = true
        /// Optional so settings saved before it existed still load.
        var previewBeforeAir: Bool?
        /// AI for writing rundowns (keys are in the Keychain), and the local control link for Claude and other MCP apps.
        var aiProvider: AIProvider?
        var claudeModel: String?
        var openAIModel: String?
        var controlLink: Bool?
        /// The live brain's fast model per service (empty: the default).
        var brainClaudeModel: String?
        var brainOpenAIModel: String?
        /// Screen shares include Framecast's own windows (for demoing it); the presenter view always stays hidden.
        var showsOwnWindows: Bool?
        /// "Write it for me" (scripts) with the API key; off unless switched on, so the key is only used live.
        var writeWithAPI: Bool?
        /// The language Listen recognises (nil: the Mac's language).
        var listenLanguage: ListenLanguage?
    }
    static var defaultFolder: String {
        (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("Framecast").path
    }

    var s: Stored { didSet { save() } }
    /// Automated test launches use their own settings (recording folder, formats…), never the user's.
    private let key = ProcessInfo.processInfo.environment["FRAMECAST_UI"] == nil ? "framecast.settings.v1" : "framecast.settings.autotest"
    init() {
        if let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode(Stored.self, from: d) { s = v }
        else { s = Stored() }
    }
    private func save() { if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) } }

    func model(for p: AIProvider) -> String {
        let m = (p == .claude ? s.claudeModel : s.openAIModel)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? p.defaultModel : m
    }

    func brainModel(for p: AIProvider) -> String {
        let m = (p == .claude ? s.brainClaudeModel : s.brainOpenAIModel)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? LiveBrain.defaultModel(p) : m
    }

    func canvas(_ k: CanvasKind) -> CanvasSetting { k == .horizontal ? s.horizontal : s.vertical }
    func container(_ k: CanvasKind) -> ContainerFormat { k == .horizontal ? s.containerH : s.containerV }

    /// Codec and bitrate for a canvas. Good/Great scale with pixels × fps from a 1080p30 reference
    /// (Framecast's own numbers).
    func quality(_ k: CanvasKind) -> (VideoCodec, Int) {
        let c = canvas(k)
        let scale = Double(c.width * c.height * c.fps) / Double(1920 * 1080 * 30)
        switch s.preset {
        case .good: return (.h264, Int(12_000 * scale))
        case .great: return (.hevc, Int(20_000 * scale))
        case .custom: return (s.customCodec, k == .horizontal ? s.customKbpsH : s.customKbpsV)
        }
    }
    func gbPerHour(_ k: CanvasKind) -> Double { Double(quality(k).1 + 192) * 1000 / 8 * 3600 / 1e9 }
}

/// What Listen recognises. Hinglish runs two of Apple's on-device recognisers on the same microphone (English
/// as spoken in India, and Hindi); the live brain reads both.
enum ListenLanguage: String, Codable, CaseIterable, Identifiable {
    case auto, englishIndia, englishUS, hinglish, hindi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "This Mac's language"
        case .englishIndia: "English (India)"
        case .englishUS: "English (US)"
        case .hinglish: "Hinglish (English + Hindi)"
        case .hindi: "Hindi"
        }
    }
    var primary: Locale {
        switch self {
        case .auto: .current
        case .englishIndia, .hinglish: Locale(identifier: "en-IN")
        case .englishUS: Locale(identifier: "en-US")
        case .hindi: Locale(identifier: "hi-IN")
        }
    }
    /// A second recogniser whose text only the live brain reads.
    var secondary: Locale? { self == .hinglish ? Locale(identifier: "hi-IN") : nil }
}

/// File names: time `HH-mm-ss`, date `dd-MM-yy`, optional show and
/// layout names, and the canvas name when both canvases record.
enum RecordingFileName {
    static func sanitized(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
    /// "Framecast 2026-10-19 14.03.22 My show 16x9": date, then time, then the optional show and scene names,
    /// then the format when both canvases record (or when asked for).
    static func base(tags: [NameTag], canvas: CanvasKind, addsCanvas: Bool, show: String, layout: String, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var parts = ["Framecast"]
        if tags.contains(.date) { f.dateFormat = "yyyy-MM-dd"; parts.append(f.string(from: date)) }
        if tags.contains(.time) { f.dateFormat = "HH.mm.ss"; parts.append(f.string(from: date)) }
        if tags.contains(.show), !show.isEmpty { parts.append(sanitized(show)) }
        if tags.contains(.layout), !layout.isEmpty { parts.append(sanitized(layout)) }
        if tags.contains(.canvas) || addsCanvas { parts.append(canvas == .horizontal ? "16x9" : "9x16") }
        if parts.count == 1 { f.dateFormat = "yyyy-MM-dd HH.mm.ss"; parts.append(f.string(from: date)) }
        return parts.joined(separator: " ")
    }
}
