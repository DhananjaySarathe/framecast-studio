import SwiftUI
import AppKit

/// SwiftUI's `@State` is a compiler macro in the macOS 27 SDK whose plugin ships only with Xcode.
/// `@Local` wraps the underlying `State` type directly so Framecast builds with the Command Line Tools.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var state: State<Value>
    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { state.projectedValue }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Palette "Midnight": cool blue-black surfaces with a violet accent. Every colour in the app comes from here.
enum Theme {
    static let window = Color(hex: 0x0E1015)
    static let body = Color(hex: 0x0B0D11)
    static let programWell = Color(hex: 0x07080B)
    static let canvasEmpty = Color(hex: 0x14171D)
    static let strip = Color(hex: 0x101318)          // scenes sidebar
    static let panel = Color(hex: 0x12151B)          // inspector
    static let rail = Color(hex: 0x0E1015)
    static let hairline = Color(hex: 0x232733)
    static let control = Color(hex: 0x1A1E27)
    static let control2 = Color(hex: 0x161A22)
    static let railButton = Color(hex: 0x1A1E27)
    static let selected = Color(hex: 0x262C3A)
    static let field = Color(hex: 0x0C0E13)
    static let fieldBorder = Color(hex: 0x2C3240)
    static let text = Color(hex: 0xEEF0F6)
    static let chatText = Color(hex: 0xDDE1EA)
    static let text2 = Color(hex: 0xA8AFBF)
    static let text3 = Color(hex: 0x7F8798)
    static let text4 = Color(hex: 0x5D6475)
    static let icon = Color(hex: 0xC4CAD8)
    static let live = Color(hex: 0xFF4D5E)
    static let stopBG = Color(hex: 0x2B151B)
    static let stopBorder = Color(hex: 0x5C2230)
    static let stopText = Color(hex: 0xFFB3BC)
    static let healthy = Color(hex: 0x3DD68C)
    static let warning = Color(hex: 0xF5B544)

    // Framecast identity: violet
    static let accent = Color(hex: 0x7D6BFF)
    static let accentFill = Color(hex: 0x7D6BFF, alpha: 0.18)
    static let accentInk = Color(hex: 0xFFFFFF)
    static let accentNS = NSColor(srgbRed: 0x7D / 255.0, green: 0x6B / 255.0, blue: 0xFF / 255.0, alpha: 1)
    static let windowNS = NSColor(srgbRed: 0x0E / 255.0, green: 0x10 / 255.0, blue: 0x15 / 255.0, alpha: 1)

    static func platformColor(_ p: String) -> Color {
        switch p {
        case "youtube": return Color(hex: 0xFF0000)
        case "twitch": return Color(hex: 0x9146FF)
        case "x": return Color(hex: 0x000000)
        case "instagram": return Color(hex: 0xE4405F)
        case "guest": return Color(hex: 0x7D6BFF)
        default: return Color(hex: 0x5B6B7A)
        }
    }
}

extension Font {
    static func fc(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Small rounded capsule button used throughout the panels.
struct PillButton: View {
    var title: String
    var systemImage: String? = nil
    var prominent = false
    var destructive = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.fc(11, .semibold)) }
                Text(title).font(.fc(12, .semibold))
            }
            .padding(.horizontal, 14).frame(height: 28)
            .foregroundStyle(prominent ? Theme.accentInk : (destructive ? Theme.live : Theme.text))
            .background(Capsule().fill(prominent ? Theme.accent : Theme.selected))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.fc(11.5, .semibold)).foregroundStyle(Theme.text3)
    }
}

/// Platform circle badge (YouTube/Twitch/X/Instagram/custom), drawn with simple glyphs (no brand logos).
struct PlatformBadge: View {
    var platform: String
    var size: CGFloat = 24
    var ring: Color? = nil
    var body: some View {
        ZStack {
            Circle().fill(Theme.platformColor(platform))
            glyph.foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(ring ?? .clear, lineWidth: 2))
    }
    @ViewBuilder var glyph: some View {
        switch platform {
        case "youtube": Image(systemName: "play.fill").font(.system(size: size * 0.42, weight: .bold))
        case "twitch": Image(systemName: "bubble.left.fill").font(.system(size: size * 0.40, weight: .bold))
        case "x": Text("X").font(.system(size: size * 0.48, weight: .heavy))
        case "instagram": Image(systemName: "camera").font(.system(size: size * 0.42, weight: .bold))
        case "guest": Image(systemName: "person.fill").font(.system(size: size * 0.42, weight: .bold))
        default: Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: size * 0.40, weight: .bold))
        }
    }
}

func formatClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
