import Foundation
import CoreGraphics

// Scene model: sources, layouts (scenes) with an item list per canvas, audio settings and overlay elements.

public enum CanvasKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case horizontal, vertical
    public var id: String { rawValue }
    public var title: String { self == .horizontal ? "16:9" : "9:16" }
}

public struct RGBA: Codable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { red = r; green = g; blue = b; alpha = a }
    public static let white = RGBA(1, 1, 1), black = RGBA(0, 0, 0), clear = RGBA(0, 0, 0, 0)
    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

public struct TextStyle: Codable, Hashable, Sendable {
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var isBold: Bool
    public var color: RGBA
    public var background: RGBA?
    public init(text: String, fontName: String = "Helvetica Neue", fontSize: Double = 96, isBold: Bool = true,
                color: RGBA = .white, background: RGBA? = nil) {
        self.text = text; self.fontName = fontName; self.fontSize = fontSize; self.isBold = isBold
        self.color = color; self.background = background
    }
}

public enum SourceKind: Codable, Hashable, Sendable {
    case camera(deviceID: String, width: Int, height: Int, fps: Int)
    case display(displayID: UInt32)
    case window(bundleID: String, title: String, windowID: UInt32)
    case application(bundleID: String, name: String)
    case microphone(deviceID: String)
    case appAudio(bundleID: String, name: String)
    case systemAudio
    case image(path: String)
    case color(RGBA)
    case wallpaper(String)
    case text(TextStyle)
    case guest(slot: Int)
    case guestScreen(slot: Int)
    case guestGrid
    case testPattern
    case tone
    /// Artwork from the creator asset pack (frames, annotations), by asset id. Pack backgrounds use
    /// `.wallpaper("pack:<asset id>")` so they behave like the built-in wallpapers.
    case packImage(String)
    /// A live countdown to `endsAt` (seconds since 1970) in the given text style.
    case countdown(TextStyle, endsAt: Double)
    /// A video or music file, played on the mixer's clock (see MediaFileSource).
    case media(path: String)
    /// Short sounds played from the sound pad.
    case soundPad

    public var hasVideo: Bool {
        switch self {
        case .microphone, .appAudio, .systemAudio, .tone, .soundPad: return false
        case .media(let path): return !MediaFileSource.isAudioOnly(path)
        default: return true
        }
    }
    public var hasAudio: Bool {
        switch self {
        // Guests' voices reach the mixer through the guest room, not through the layout slot.
        case .microphone, .appAudio, .systemAudio, .tone, .media, .soundPad: return true
        default: return false
        }
    }
    public var needsScreenRecording: Bool {
        switch self {
        case .display, .window, .application, .appAudio, .systemAudio: return true
        default: return false
        }
    }
    public var iconName: String {
        switch self {
        case .camera: return "camera.fill"
        case .display: return "display"
        case .window: return "macwindow"
        case .application: return "app.dashed"
        case .microphone: return "mic.fill"
        case .appAudio: return "app.badge"
        case .systemAudio: return "speaker.wave.2.fill"
        case .image: return "photo"
        case .color: return "square.fill"
        case .wallpaper: return "photo.artframe"
        case .text: return "textformat"
        case .guest: return "person.fill"
        case .guestScreen: return "rectangle.inset.filled.and.person.filled"
        case .guestGrid: return "square.grid.2x2"
        case .testPattern: return "chart.bar.fill"
        case .tone: return "waveform"
        case .packImage: return "sparkles"
        case .countdown: return "timer"
        case .media(let path): return MediaFileSource.isAudioOnly(path) ? "music.note" : "film"
        case .soundPad: return "square.grid.3x3.fill"
        }
    }
}

public enum EchoCancellation: String, Codable, Sendable, CaseIterable { case auto, on, off }

public struct AudioSettings: Codable, Hashable, Sendable {
    public var fader: Double = 0.8          // 0.8 is unity gain (0 dB)
    public var isMuted = false
    public var isMonitored = false
    public var isInProgram = true
    public var tracks: Set<Int> = [1]
    public var effects: [String] = []
    public var echoCancellation: EchoCancellation = .auto
    public var noiseReduction: Bool? = false
    public var isVoice: Bool? = false
    /// Lowered automatically while a microphone or guest is talking (music, videos, desktop sound).
    public var ducksUnderVoice: Bool?
    public var delayMs: Double = 0
    public init() {}

    /// Fader position to linear gain. 0.8 = 0 dB, 1.0 ≈ +5.8 dB, cubic taper below.
    public var linearGain: Float {
        if isMuted { return 0 }
        let r = max(0, fader) / 0.8
        return Float(r * r * r)
    }
    public static func dbLabel(fader: Double) -> String {
        let g = pow(max(0, fader) / 0.8, 3)
        if g <= 0.0001 { return "−∞ dB" }
        let db = 20 * log10(g)
        return String(format: "%@%.1f dB", db >= 0 ? "+" : "", db).replacingOccurrences(of: "-", with: "−")
    }
}

public struct SourceRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: SourceKind
    public var audio: AudioSettings?
    public var lut: CameraLUT?
    /// Playback options for video and music files.
    public var media: MediaOptions?
    public init(id: UUID = UUID(), name: String, kind: SourceKind, audio: AudioSettings? = nil, lut: CameraLUT? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.audio = audio ?? (kind.hasAudio ? AudioSettings() : nil)
        self.lut = lut
    }
}

public struct MediaOptions: Codable, Hashable, Sendable {
    public var loop = false
    /// Start from the beginning each time a scene showing it goes on air.
    public var playsWhenShown = true
    public init() {}
}

/// One button of the sound pad: a built-in sound id or a file path.
public struct SoundSlot: Codable, Hashable, Sendable {
    public var key: String
    public var name: String
    public init(key: String, name: String) { self.key = key; self.name = name }
    public var isEmpty: Bool { key.isEmpty }
    public static let defaults: [SoundSlot] = SoundBank.builtIns.map { SoundSlot(key: $0.id, name: $0.name) }
        + Array(repeating: SoundSlot(key: "", name: ""), count: 3)
}

public struct CameraLUT: Codable, Hashable, Sendable {
    public var path: String
    public var amount: Double = 1
    public var isEnabled = true
    public init(path: String) { self.path = path }
}

public enum LayoutRole: String, Codable, Sendable, CaseIterable { case camera, camera2, screen, lowerThird, title, background }

public struct ItemTransform: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public var rotationDegrees: Double = 0
    public init(x: Double, y: Double, width: Double, height: Double, rotationDegrees: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.rotationDegrees = rotationDegrees
    }
    public static let full = ItemTransform(x: 0, y: 0, width: 1, height: 1)
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct ItemCrop: Codable, Hashable, Sendable {
    public var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

public enum ItemMask: Codable, Hashable, Sendable {
    case none
    case circle
    case roundedRect(radius: Double)   // fraction of the shorter side of the item's frame
}

public enum FitMode: String, Codable, Sendable, CaseIterable { case fill = "Fill", fit = "Fit", stretch = "Stretch" }

public struct ColorCorrection: Codable, Hashable, Sendable {
    public var brightness = 0.0, contrast = 1.0, saturation = 1.0, gamma = 1.0, hueDegrees = 0.0
    public init() {}
    public var isNeutral: Bool { brightness == 0 && contrast == 1 && saturation == 1 && gamma == 1 && hueDegrees == 0 }
}

public struct MatteSettings: Codable, Hashable, Sendable {
    public var edgeRefine = 0.0, choke = 0.0, clipBlack = 0.0, clipWhite = 1.0, stability = 0.0
    public init() {}
}

public struct ChromaKeySettings: Codable, Hashable, Sendable {
    public var key = RGBA(0.0, 0.8, 0.2)
    public var similarity = 0.4, smoothness = 0.08, spill = 0.3, lumaRestore = 0.0
    public var lockExposure = false
    public var matte = MatteSettings()
    public init() {}
}

public struct LumaKeySettings: Codable, Hashable, Sendable {
    public var low = 0.0, high = 0.25, softness = 0.05
    public var invert = false
    public var lockExposure = false
    public var matte = MatteSettings()
    public init() {}
}

public enum FilterKind: Codable, Hashable, Sendable {
    case colorCorrection(ColorCorrection)
    case chromaKey(ChromaKeySettings)
    case lumaKey(LumaKeySettings)
    public var title: String {
        switch self {
        case .colorCorrection: return "Color correction"
        case .chromaKey: return "Chroma key"
        case .lumaKey: return "Luma key"
        }
    }
}

public struct FilterSpec: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var isEnabled = true
    public var kind: FilterKind
    public init(kind: FilterKind) { self.kind = kind }
}

public struct SceneItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var role: LayoutRole?
    public var isVisible = true
    public var isLocked = false
    public var transform: ItemTransform
    public var crop = ItemCrop()
    public var fit: FitMode = .fill
    public var mask: ItemMask = .none
    public var opacity = 1.0
    public var isMirrored = false
    public var filters: [FilterSpec] = []
    public var isLinked = true
    /// The frame that shows the camera angle on air (Angles › Shuffle); one frame at a time. Optional so collections
    /// saved before it existed still load.
    public var shufflesAngles: Bool?
    public init(id: UUID = UUID(), sourceID: UUID, role: LayoutRole? = nil, transform: ItemTransform = .full,
                fit: FitMode = .fill, mask: ItemMask = .none, isVisible: Bool = true) {
        self.id = id; self.sourceID = sourceID; self.role = role; self.transform = transform
        self.fit = fit; self.mask = mask; self.isVisible = isVisible
    }
}

public enum StudioLayoutTemplate: String, Codable, Sendable, CaseIterable {
    case solo, screenCam, side, podcast, focus, startingSoon, beRightBack, ending, headline, presenter
    case camLeft, screenTile, screenTileLeft, sideLeft, framed, closeUp

    public var group: LayoutGroup {
        switch self {
        case .solo, .framed, .closeUp: return .solo
        case .screenCam, .camLeft, .screenTile, .screenTileLeft, .side, .sideLeft, .focus, .presenter: return .screen
        case .podcast: return .together
        case .startingSoon, .beRightBack, .ending, .headline: return .scenes
        }
    }
}

public enum LayoutGroup: String, Codable, Sendable, CaseIterable {
    case solo, screen, together, scenes
    public var label: String {
        switch self {
        case .solo: "Camera"
        case .screen: "Screen share"
        case .together: "With guests"
        case .scenes: "Cards"
        }
    }
}

public struct StudioScene: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var verticalName: String
    public var isLinked = true
    public var horizontal: [SceneItem]
    public var vertical: [SceneItem]
    public var template: StudioLayoutTemplate?
    public var arrangesGuests = false
    /// Where a layout without a template sits in the Layouts strip (layouts made from the asset pack).
    public var group: LayoutGroup?
    public init(id: UUID = UUID(), name: String, verticalName: String? = nil, horizontal: [SceneItem], vertical: [SceneItem],
                template: StudioLayoutTemplate? = nil) {
        self.id = id; self.name = name; self.verticalName = verticalName ?? name
        self.horizontal = horizontal; self.vertical = vertical; self.template = template
    }
    public func items(for canvas: CanvasKind) -> [SceneItem] { canvas == .horizontal ? horizontal : vertical }
    public mutating func setItems(_ items: [SceneItem], for canvas: CanvasKind) {
        if canvas == .horizontal { horizontal = items } else { vertical = items }
    }
    public func name(for canvas: CanvasKind) -> String { canvas == .horizontal ? name : verticalName }
}

public struct AudioMix: Codable, Hashable, Sendable {
    public var masterFader = 0.8
    public var masterTracks: Set<Int> = [1]
    public var headphoneLevel = 0.62
    public init() {}
}

public struct ScenePointers: Codable, Hashable, Sendable {
    public var horizontalProgram: UUID?
    public var verticalProgram: UUID?
    public init() {}
}

public struct SceneCollection: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var sources: [SourceRecord]
    public var scenes: [StudioScene]
    public var pointers = ScenePointers()
    public var audio = AudioMix()
    public var elements: [OverlayElement] = []
    /// Nine sound pad buttons (nil until changed: the defaults are used).
    public var soundPad: [SoundSlot]?
    public init(sources: [SourceRecord], scenes: [StudioScene]) { self.sources = sources; self.scenes = scenes }

    public func source(_ id: UUID) -> SourceRecord? { sources.first { $0.id == id } }
}

// MARK: - Overlay elements

public struct OverlayElement: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case text, lower, thanks, qr }
    public enum Accent: String, Codable, Sendable, CaseIterable { case amber, red, green, blue, violet }
    public enum Look: String, Codable, Sendable, CaseIterable { case solid, dark, light }
    public enum Motion: String, Codable, Sendable, CaseIterable { case slide, rise, pop, fade }
    public enum Speed: String, Codable, Sendable, CaseIterable { case fast, normal, slow }
    public enum Position: String, Codable, Sendable, CaseIterable {
        case topLeft, topCenter, topRight, middleLeft, middleCenter, middleRight, bottomLeft, bottomCenter, bottomRight
    }
    public var id = UUID()
    public var kind: Kind
    public var name: String
    public var title: String
    public var subtitle: String
    public var url: String
    public var accent: Accent = .amber
    public var look: Look = .solid
    public var motion: Motion = .slide
    public var speed: Speed = .normal
    public var position: Position = .bottomLeft
    public var autoHide = 0      // seconds, 0 = stays until hidden
    public init(kind: Kind, name: String, title: String, subtitle: String = "", url: String = "") {
        self.kind = kind; self.name = name; self.title = title; self.subtitle = subtitle; self.url = url
        switch kind {
        case .thanks: position = .middleCenter; motion = .pop
        case .qr: position = .bottomRight; motion = .fade
        case .text: position = .topCenter; motion = .rise
        case .lower: break
        }
    }
    public var durationSeconds: Double {
        switch speed { case .fast: return 0.25; case .normal: return 0.45; case .slow: return 0.8 }
    }
}
