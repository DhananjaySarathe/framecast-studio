
// Scratch benchmark: on-device model WITH the screen image attached, for references that need sight
// ("the blue button", "the big number", "third item in the sidebar"). Synthetic image, nothing captured.
//   swiftc -O image_bench.swift -o image_bench && ./image_bench
import AppKit
import FoundationModels
// ---------- synthetic screen ----------
struct Label { var text: String; var x: CGFloat; var y: CGFloat; var size: CGFloat; var bold = false }
// Coordinates in a 1280x800 logical space, drawn at scale.
let labels: [Label] = {
    var l: [Label] = []
    let side = ["General", "Appearance", "Settings", "Privacy & Security", "Notifications", "Accounts", "Storage", "Export", "Share", "Help"]
    for (i, s) in side.enumerated() { l.append(Label(text: s, x: 24, y: 90 + CGFloat(i) * 34, size: 13)) }
    let toolbar = ["File", "Edit", "View", "Insert", "Format", "Window"]
    for (i, s) in toolbar.enumerated() { l.append(Label(text: s, x: 260 + CGFloat(i) * 70, y: 22, size: 13)) }
    l.append(Label(text: "Revenue growth by quarter", x: 260, y: 90, size: 22, bold: true))
    l.append(Label(text: "42%", x: 260, y: 140, size: 40, bold: true))
    l.append(Label(text: "Timer 00:12", x: 1080, y: 90, size: 18))
    l.append(Label(text: "Run prompt", x: 1080, y: 140, size: 13, bold: true))
    l.append(Label(text: "Upgrade to Pro", x: 1080, y: 190, size: 11))
    let body = ["The quick summary shows that throughput doubled after the change.",
                "Click Save to keep your work, or Discard to undo every edit.",
                "let session = LanguageModelSession(instructions: rules)",
                "for item in items where item.isVisible { draw(item) }",
                "Last updated 21 October 2026 at 10:42"]
    for (i, s) in body.enumerated() { l.append(Label(text: s, x: 260, y: 220 + CGFloat(i) * 30, size: i == 4 ? 10 : 14)) }
    for i in 0..<12 { l.append(Label(text: "Row \(i + 1)  item-\(1000 + i * 7)  $\(i * 13 + 9).00", x: 260, y: 400 + CGFloat(i) * 26, size: 12)) }
    return l
}()

func renderScreen(width: Int, height: Int, scrollY: CGFloat = 0) -> CGImage {
    let scale = CGFloat(width) / 1280
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 220 * scale, height: CGFloat(height)))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 1070 * scale, y: CGFloat(height) - 160 * scale, width: 120 * scale, height: 30 * scale))
    let g = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    // flip so y grows downward
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    for lab in labels {
        let font = lab.bold ? NSFont.boldSystemFont(ofSize: lab.size * scale) : NSFont.systemFont(ofSize: lab.size * scale)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)]
        let y = lab.y * scale - (lab.x > 250 ? scrollY * scale : 0)
        NSAttributedString(string: lab.text, attributes: attrs).draw(at: CGPoint(x: lab.x * scale, y: y))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}


let items = labels.map(\.text)
let cases: [(String, String?)] = [
    ("click the blue button on the right", "Run prompt"),
    ("look at the big number", "42%"),
    ("the third item in the sidebar", "Settings"),
    ("now click the settings button", "Settings"),
    ("my cat just walked across the desk, sorry", nil),
    ("see the small grey text at the bottom of the paragraph", "Last updated 21 October 2026 at 10:42"),
]
let instructions = """
The presenter is sharing their screen in a live video; the image is that screen. You get the presenter's newest words \
(from speech recognition). Decide if they are directing the viewer to something on screen right now, then pick which \
listed text item it is or sits on. Answer no and none otherwise.
"""
@MainActor func run() async throws {
    guard SystemLanguageModel.default.isAvailable else { print("model unavailable"); return }
    let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Pick", properties: [
        .init(name: "directingNow", schema: DynamicGenerationSchema(name: "YesNo", anyOf: ["yes", "no"])),
        .init(name: "target", schema: DynamicGenerationSchema(name: "Target", anyOf: items + ["none"]))]), dependencies: [])
    let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 40)
    for (w, h) in [(1280, 800), (640, 400)] {
        let img = renderScreen(width: w, height: h)
        var times: [Double] = [], right = 0
        print("image \(w)x\(h)")
        for (u, exp) in cases {
            let session = LanguageModelSession(instructions: instructions)
            let t0 = Date()
            let r = try await session.respond(schema: schema, options: options) {
                "Items: " + items.joined(separator: " | ")
                "Newest words: \(u)"
                Attachment(img)
            }
            let d = Date().timeIntervalSince(t0); times.append(d)
            let yes = ((try? r.content.value(String.self, forProperty: "directingNow")) ?? "no") == "yes"
            let raw = (try? r.content.value(String.self, forProperty: "target")) ?? "none"
            let got: String? = (!yes || raw == "none") ? nil : raw
            if got == exp { right += 1 }
            print(String(format: "  %5.2fs %@ %@ | %@", d, got == exp ? "ok   " : "WRONG", got ?? "none", u))
        }
        let s = times.sorted()
        print(String(format: "  %d/%d right; median %.2f s, max %.2f s", right, cases.count, s[s.count / 2], s.last!))
    }
}
Task { @MainActor in do { try await run() } catch { print("error: \(error)") }; exit(0) }
RunLoop.main.run()
