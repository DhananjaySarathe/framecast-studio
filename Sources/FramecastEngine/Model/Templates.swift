import Foundation

/// Built-in scenes. Framecast's own arrangement: a 3% safe margin, 2% gaps, rounded-square cameras and
/// rounded panels. Template ids are kept stable so saved studios keep loading; names and geometry are new.
public enum LayoutTemplates {
    public struct Roles {
        public var background: UUID
        public var camera: UUID
        public var screen: UUID
        public var lowerThird: UUID
        public var title: UUID?
        public init(background: UUID, camera: UUID, screen: UUID, lowerThird: UUID, title: UUID? = nil) {
            self.background = background; self.camera = camera; self.screen = screen
            self.lowerThird = lowerThird; self.title = title
        }
    }

    typealias T = ItemTransform

    // Safe margin: 3% of the width; the same distance vertically on each canvas.
    static let mH = 0.03, mHy = 0.03 * 16 / 9            // 16:9
    static let mV = 0.04, mVy = 0.04 * 9 / 16            // 9:16

    static func bg(_ r: Roles) -> SceneItem { SceneItem(sourceID: r.background, role: .background, transform: .full, fit: .fill) }
    static func lowerH(_ r: Roles, x: Double = 0.05, y: Double = 0.80) -> SceneItem {
        SceneItem(sourceID: r.lowerThird, role: .lowerThird, transform: T(x: x, y: y, width: 0.40, height: 0.075),
                  fit: .fit, mask: .roundedRect(radius: 0.5), isVisible: false)
    }
    static func lowerV(_ r: Roles, y: Double = 0.84) -> SceneItem {
        SceneItem(sourceID: r.lowerThird, role: .lowerThird, transform: T(x: 0.08, y: y, width: 0.84, height: 0.048),
                  fit: .fit, mask: .roundedRect(radius: 0.5), isVisible: false)
    }
    static func cam(_ r: Roles, _ t: T, _ mask: ItemMask = .none) -> SceneItem {
        SceneItem(sourceID: r.camera, role: .camera, transform: t, fit: .fill, mask: mask)
    }
    static func scr(_ r: Roles, _ t: T, _ mask: ItemMask = .none) -> SceneItem {
        SceneItem(sourceID: r.screen, role: .screen, transform: t, fit: .fit, mask: mask)
    }
    static let panel = ItemMask.roundedRect(radius: 0.035)
    static let squircle = ItemMask.roundedRect(radius: 0.22)

    public static func make(_ template: StudioLayoutTemplate, roles r: Roles) -> StudioScene {
        // Common rectangles.
        let insetH = T(x: mH, y: mHy, width: 1 - 2 * mH, height: 1 - 2 * mHy)
        let insetV = T(x: mV, y: mVy, width: 1 - 2 * mV, height: 1 - 2 * mVy)
        let camSq = 0.17, camSqH = 0.17 * 16 / 9                    // square camera on 16:9
        switch template {
        case .solo:
            return StudioScene(name: "Camera", verticalName: "Camera",
                horizontal: [bg(r), cam(r, .full), lowerH(r)],
                vertical: [bg(r), cam(r, .full), lowerV(r)], template: .solo)
        case .framed:
            return StudioScene(name: "Camera card", verticalName: "Camera card",
                horizontal: [bg(r), cam(r, insetH, panel), lowerH(r, x: 0.06, y: 0.78)],
                vertical: [bg(r), cam(r, T(x: mV, y: 0.10, width: 1 - 2 * mV, height: 0.70), panel), lowerV(r)],
                template: .framed)
        case .closeUp:
            return StudioScene(name: "Camera bubble", verticalName: "Camera bubble",
                horizontal: [bg(r), cam(r, T(x: 0.30, y: 0.12, width: 0.40, height: 0.40 * 16 / 9), .circle), lowerH(r, x: 0.30, y: 0.86)],
                vertical: [bg(r), cam(r, T(x: 0.12, y: 0.28, width: 0.76, height: 0.76 * 9 / 16), .circle), lowerV(r, y: 0.74)],
                template: .closeUp)
        case .screenCam:
            return StudioScene(name: "Screen + camera", verticalName: "Screen over camera",
                horizontal: [bg(r), scr(r, insetH, panel),
                             cam(r, T(x: 1 - mH - camSq - 0.02, y: 1 - mHy - camSqH - 0.035, width: camSq, height: camSqH), squircle), lowerH(r)],
                vertical: [bg(r), scr(r, T(x: mV, y: mVy + 0.03, width: 1 - 2 * mV, height: 0.36), panel),
                           cam(r, T(x: mV, y: 0.44, width: 1 - 2 * mV, height: 0.46), panel), lowerV(r, y: 0.92)],
                template: .screenCam)
        case .camLeft:
            return StudioScene(name: "Screen + camera (left)", verticalName: "Camera over screen",
                horizontal: [bg(r), scr(r, insetH, panel),
                             cam(r, T(x: mH + 0.02, y: 1 - mHy - camSqH - 0.035, width: camSq, height: camSqH), squircle), lowerH(r, x: 0.24, y: 0.80)],
                vertical: [bg(r), cam(r, T(x: mV, y: mVy + 0.03, width: 1 - 2 * mV, height: 0.46), panel),
                           scr(r, T(x: mV, y: 0.54, width: 1 - 2 * mV, height: 0.36), panel), lowerV(r, y: 0.92)],
                template: .camLeft)
        case .screenTile:
            return StudioScene(name: "Screen + mini camera", verticalName: "Screen + mini camera",
                horizontal: [bg(r), scr(r, .full), cam(r, T(x: 1 - mH - 0.14, y: mHy, width: 0.14, height: 0.14 * 16 / 9), squircle), lowerH(r)],
                vertical: [bg(r), scr(r, T(x: 0, y: 0.20, width: 1, height: 0.5625)),
                           cam(r, T(x: 1 - mV - 0.30, y: 0.06, width: 0.30, height: 0.30 * 9 / 16), squircle), lowerV(r)],
                template: .screenTile)
        case .screenTileLeft:
            return StudioScene(name: "Screen + mini camera (left)", verticalName: "Screen + mini camera (left)",
                horizontal: [bg(r), scr(r, .full), cam(r, T(x: mH, y: mHy, width: 0.14, height: 0.14 * 16 / 9), squircle), lowerH(r)],
                vertical: [bg(r), scr(r, T(x: 0, y: 0.20, width: 1, height: 0.5625)),
                           cam(r, T(x: mV, y: 0.06, width: 0.30, height: 0.30 * 9 / 16), squircle), lowerV(r)],
                template: .screenTileLeft)
        case .side:
            let w = (1 - 2 * mH - 0.02) / 2, h = w * 16 / 9 / 1.6
            return StudioScene(name: "Split", verticalName: "Split",
                horizontal: [bg(r), scr(r, T(x: mH, y: (1 - h) / 2, width: w, height: h), panel),
                             cam(r, T(x: mH + w + 0.02, y: (1 - h) / 2, width: w, height: h), panel), lowerH(r, x: 0.30, y: 0.86)],
                vertical: [bg(r), scr(r, T(x: mV, y: 0.07, width: 1 - 2 * mV, height: 0.42), panel),
                           cam(r, T(x: mV, y: 0.51, width: 1 - 2 * mV, height: 0.42), panel), lowerV(r, y: 0.945)],
                template: .side)
        case .sideLeft:
            let w = (1 - 2 * mH - 0.02) / 2, h = w * 16 / 9 / 1.6
            return StudioScene(name: "Split (camera left)", verticalName: "Split (camera on top)",
                horizontal: [bg(r), cam(r, T(x: mH, y: (1 - h) / 2, width: w, height: h), panel),
                             scr(r, T(x: mH + w + 0.02, y: (1 - h) / 2, width: w, height: h), panel), lowerH(r, x: 0.30, y: 0.86)],
                vertical: [bg(r), cam(r, T(x: mV, y: 0.07, width: 1 - 2 * mV, height: 0.42), panel),
                           scr(r, T(x: mV, y: 0.51, width: 1 - 2 * mV, height: 0.42), panel), lowerV(r, y: 0.945)],
                template: .sideLeft)
        case .focus:
            return StudioScene(name: "Screen only", verticalName: "Screen only",
                horizontal: [bg(r), scr(r, .full), lowerH(r)],
                vertical: [bg(r), scr(r, insetV, panel), lowerV(r)],
                template: .focus)
        case .presenter:
            return StudioScene(name: "Presenter", verticalName: "Presenter",
                horizontal: [bg(r), cam(r, T(x: mH, y: mHy, width: 0.36, height: 1 - 2 * mHy), panel),
                             scr(r, T(x: mH + 0.38, y: 0.17, width: 1 - 2 * mH - 0.38, height: 0.66), panel), lowerH(r, x: 0.05, y: 0.80)],
                vertical: [bg(r), cam(r, T(x: mV, y: mVy + 0.03, width: 1 - 2 * mV, height: 0.52), panel),
                           scr(r, T(x: mV, y: 0.60, width: 1 - 2 * mV, height: 0.30), panel), lowerV(r, y: 0.92)],
                template: .presenter)
        case .podcast:
            return StudioScene(name: "Conversation", verticalName: "Conversation",
                horizontal: [bg(r), cam(r, T(x: mH, y: 0.18, width: (1 - 2 * mH - 0.02) / 2, height: 0.64), panel)],
                vertical: [bg(r), cam(r, T(x: mV, y: 0.07, width: 1 - 2 * mV, height: 0.42), panel)],
                template: .podcast)
        case .startingSoon, .beRightBack, .ending, .headline:
            let names: [StudioLayoutTemplate: String] = [.startingSoon: "Intro", .beRightBack: "Break",
                                                         .ending: "Outro", .headline: "Headline"]
            let title = r.title ?? r.lowerThird
            let item = SceneItem(sourceID: title, role: .title, transform: T(x: 0.08, y: 0.36, width: 0.84, height: 0.18), fit: .fit)
            let itemV = SceneItem(sourceID: title, role: .title, transform: T(x: 0.06, y: 0.42, width: 0.88, height: 0.08), fit: .fit)
            return StudioScene(name: names[template]!, verticalName: names[template]!,
                               horizontal: [bg(r), item], vertical: [bg(r), itemV], template: template)
        }
    }

    public static let defaultOrder: [StudioLayoutTemplate] = [
        .solo, .framed, .closeUp, .screenCam, .camLeft, .screenTile, .side, .focus, .presenter,
    ]

    /// The collection a new Framecast studio starts with.
    public static func defaultCollection() -> SceneCollection {
        let background = SourceRecord(name: "Background", kind: .wallpaper("midnight"))
        let camera = SourceRecord(name: "Camera", kind: .camera(deviceID: "", width: 1920, height: 1080, fps: 30))
        let screen = SourceRecord(name: "Screen", kind: .display(displayID: 0))
        let lower = SourceRecord(name: "Lower third", kind: .text(TextStyle(text: "Your name · what this show is about",
            fontSize: 44, color: RGBA(1, 1, 1), background: RGBA(0.49, 0.42, 1.0))))
        let soon = SourceRecord(name: "Intro card", kind: .text(TextStyle(text: "We're starting in a moment")))
        let brb = SourceRecord(name: "Break card", kind: .text(TextStyle(text: "Back in a moment")))
        let thanks = SourceRecord(name: "Outro card", kind: .text(TextStyle(text: "Thanks for joining")))
        let mic = SourceRecord(name: "Mic", kind: .microphone(deviceID: ""))
        var desktop = SourceRecord(name: "Desktop", kind: .systemAudio)
        desktop.audio?.fader = 0.7
        let roles = Roles(background: background.id, camera: camera.id, screen: screen.id, lowerThird: lower.id)
        var scenes = defaultOrder.map { make($0, roles: roles) }
        var r2 = roles; r2.title = soon.id; scenes.append(make(.startingSoon, roles: r2))
        r2.title = brb.id; scenes.append(make(.beRightBack, roles: r2))
        r2.title = thanks.id; scenes.append(make(.ending, roles: r2))
        var c = SceneCollection(sources: [background, camera, screen, lower, soon, brb, thanks, mic, desktop], scenes: scenes)
        let start = scenes.first { $0.template == .screenCam } ?? scenes[0]
        c.pointers.horizontalProgram = start.id
        c.pointers.verticalProgram = start.id
        c.elements = [
            OverlayElement(kind: .lower, name: "Name tag", title: "Your name", subtitle: "What this show is about"),
            OverlayElement(kind: .text, name: "Headline", title: "Questions? Drop them in the comments"),
            OverlayElement(kind: .thanks, name: "Thank-you", title: "Thanks for joining", subtitle: "See you next time"),
            OverlayElement(kind: .qr, name: "QR code", title: "Scan for the link", url: "https://example.com"),
        ]
        return c
    }
}
