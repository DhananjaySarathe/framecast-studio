// Adds background pictures to Framecast's background library (Resources/AssetPacks/backgrounds/), where the
// background picker finds them next to the creator pack's.
//
//   swiftc -O scripts/add_backgrounds.swift -o build/add_backgrounds
//   build/add_backgrounds [--deband] <folder of pictures> [library folder, default Resources/AssetPacks/backgrounds]
//
// The folder holds one sub-folder per group: gradients, aurora, abstract, textures, rooms, or a new name that becomes
// a new group in the picker. Pictures directly in the folder go to the group "More". Each background is a pair:
//
//   gradients/Violet Haze 16x9.png      gradients/Violet Haze 9x16.png
//
// PNG, JPEG, WebP or HEIC. "16x9"/"9x16" may also be written 16-9, 16_9, horizontal/vertical or landscape/portrait;
// without it the picture's shape decides. A background with only one of the two is still added (the other canvas
// then shows the middle of it). An optional "<Name>.txt" next to the pictures holds a one-line description that the
// picker shows.
//
// --deband smooths the steps that 8-bit pictures show in dark, smooth gradients (needs ffmpeg): each picture goes
// through ffmpeg's deband filter at 16 bits first, which leaves edges and lines untouched.
//
// • Pictures are cropped to exactly 16:9 or 9:16 around the centre, scaled down to 3840×2160 at most, flattened
//   onto black if they have transparency, and stored as 10-bit HEIC (Framecast adds fine grain back when it loads
//   them, so smooth gradients don't band).
// • Each gets a 480 px preview JPEG for the picker, and is marked Dark or Light from its average brightness.
// • Adding a background with the same group and name again replaces it. Nothing else in the library changes.
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

var args = CommandLine.arguments
let deband = args.contains("--deband")
args.removeAll { $0 == "--deband" }
guard args.count == 2 || args.count == 3 else {
    print("usage: add_backgrounds [--deband] <folder of pictures> [library folder, default Resources/AssetPacks/backgrounds]"); exit(2)
}
let input = URL(fileURLWithPath: args[1], isDirectory: true)
let library = URL(fileURLWithPath: args.count == 3 ? args[2] : "Resources/AssetPacks/backgrounds", isDirectory: true)
let fm = FileManager.default
let quality = 0.9                     // same as the creator pack import
let maxLong: CGFloat = 3840
let groupAliases = ["gradient": "soft-gradient", "gradients": "soft-gradient", "aurora": "mesh-aurora", "mesh": "mesh-aurora",
                    "abstract": "abstract", "texture": "tactile-texture", "textures": "tactile-texture",
                    "room": "environmental", "rooms": "environmental", "places": "environmental", "environment": "environmental"]
let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff"]

// MARK: Manifest (same shape the app reads for every pack)

struct Variant: Codable { var path: String; var width: Int; var height: Int; var hasAlpha: Bool; var previewPath: String }
struct Asset: Codable {
    var id: String; var name: String; var category: String; var subcategory: String
    var styleFamily: String?; var description: String?; var tags: [String]; var dominantColors: [String]
    var variants: [String: Variant]
}
struct Manifest: Codable { var schemaVersion = 1; var packId = "framecast-backgrounds"; var name = "Framecast backgrounds"; var assets: [Asset] }

// MARK: Helpers

func slug(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
    return folded.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        .split(separator: "-").joined(separator: "-")
}
let orientationPattern = try! NSRegularExpression(
    pattern: #"[\s_\-\(\[]*(16\s*[x×:_\-]\s*9|9\s*[x×:_\-]\s*16|horizontal|vertical|landscape|portrait)[\)\]]?$"#, options: [.caseInsensitive])
/// "Violet Haze 16x9" → ("Violet Haze", .horizontal); nil orientation when the name doesn't say.
func split(_ base: String) -> (name: String, horizontal: Bool?) {
    let ns = base as NSString
    guard let m = orientationPattern.firstMatch(in: base, range: NSRange(location: 0, length: ns.length)) else {
        return (base.trimmingCharacters(in: .whitespaces), nil)
    }
    let token = ns.substring(with: m.range(at: 1)).lowercased().replacingOccurrences(of: " ", with: "")
    let horizontal = token.hasPrefix("16") || token == "horizontal" || token == "landscape"
    return (ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces), horizontal)
}
func hex(_ c: CIColor) -> String {
    String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
}

let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// Average colour in sRGB.
func average(_ img: CIImage) -> CIColor {
    var px = [UInt8](repeating: 0, count: 4)
    let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
    ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
    return CIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255)
}

struct Picture { let url: URL; let group: String; let name: String; let horizontal: Bool }

let work = fm.temporaryDirectory.appendingPathComponent("add_backgrounds-\(ProcessInfo.processInfo.processIdentifier)")
defer { try? fm.removeItem(at: work) }
/// A 16-bit copy with ffmpeg's deband filter applied (two passes: wide, then narrow), or nil if ffmpeg failed.
func debanded(_ url: URL) -> URL? {
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    let out = work.appendingPathComponent(UUID().uuidString + ".png")
    let pass = { (r: Int) in "deband=1thr=0.006:2thr=0.006:3thr=0.006:range=\(r):blur=1" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["ffmpeg", "-v", "error", "-y", "-i", url.path, "-vf", "format=gbrp16le,\(pass(40)),\(pass(20))", "-pix_fmt", "rgb48be", out.path]
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    return p.terminationStatus == 0 ? out : nil
}

// MARK: Find the pictures

guard let walker = fm.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
    print("can't read \(input.path)"); exit(1)
}
var pictures: [Picture] = []
var problems: [String] = [], notes: [String] = []
for case let url as URL in walker where extensions.contains(url.pathExtension.lowercased()) {
    let rel = url.path.dropFirst(input.path.count).split(separator: "/").map(String.init)
    let folder = rel.count > 1 ? rel[0] : "more"
    let group = groupAliases[folder.lowercased()] ?? slug(folder)
    var (name, horizontal) = split(url.deletingPathExtension().lastPathComponent)
    if horizontal == nil {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else {
            problems.append("unreadable: \(rel.joined(separator: "/"))"); continue
        }
        horizontal = w >= h
    }
    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
    pictures.append(Picture(url: url, group: group, name: name, horizontal: horizontal!))
}
if pictures.isEmpty { print("no pictures found in \(input.path)"); exit(1) }

// MARK: Convert

var manifest = (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: library.appendingPathComponent("manifest.json")))) ?? Manifest(assets: [])
let byBackground = Dictionary(grouping: pictures) { "\($0.group)/\($0.name.lowercased())" }
var added = 0, replaced = 0

for key in byBackground.keys.sorted() {
    let pics = byBackground[key]!
    let first = pics[0]
    let id = "fc-bg-\(first.group == "more" ? "" : first.group + "-")\(slug(first.name))"
    var variants: [String: Variant] = [:]
    var colours: [CIColor] = []
    for orientation in [true, false] {
        let matching = pics.filter { $0.horizontal == orientation }
        guard let pic = matching.first else { continue }
        if matching.count > 1 { problems.append("\(first.name): more than one \(orientation ? "16:9" : "9:16") picture, used \(pic.url.lastPathComponent)") }
        var source = pic.url
        if deband {
            guard let d = debanded(pic.url) else { problems.append("\(pic.url.lastPathComponent): ffmpeg couldn't deband it (is ffmpeg installed?)"); continue }
            source = d
        }
        guard var img = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            problems.append("unreadable: \(pic.url.lastPathComponent)"); continue
        }
        let e = img.extent
        // Crop to exactly 16:9 or 9:16 around the centre.
        let target: CGFloat = orientation ? 16.0 / 9.0 : 9.0 / 16.0
        var crop = e
        if e.width / e.height > target { crop.size.width = (e.height * target).rounded(); crop.origin.x = e.minX + ((e.width - crop.width) / 2).rounded() }
        else { crop.size.height = (e.width / target).rounded(); crop.origin.y = e.minY + ((e.height - crop.height) / 2).rounded() }
        let lost = 1 - (crop.width * crop.height) / (e.width * e.height)
        if lost > 0.08 { notes.append("\(pic.url.lastPathComponent): cropped \(Int((lost * 100).rounded()))% to make it \(orientation ? "16:9" : "9:16")") }
        img = img.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        // At most 3840×2160 (or 2160×3840).
        let long = max(crop.width, crop.height)
        if long > maxLong {
            let k = maxLong / long
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
            let r = CGRect(x: 0, y: 0, width: (crop.width * k).rounded(), height: (crop.height * k).rounded())
            img = img.cropped(to: r)
        }
        let size = img.extent.integral.size
        let short = min(size.width, size.height)
        if short < 720 { problems.append("\(pic.url.lastPathComponent): only \(Int(size.width))×\(Int(size.height)) after cropping, too small (need 1280×720 or more)"); continue }
        if short < 1080 { notes.append("\(pic.url.lastPathComponent): \(Int(size.width))×\(Int(size.height)), a little soft on 1080p canvases") }
        // Backgrounds are opaque.
        img = img.composited(over: CIImage(color: CIColor.black).cropped(to: img.extent))
        colours.append(average(img))

        let name = orientation ? "horizontal" : "vertical"
        let art = "assets/\(id)/\(name).heic", preview = "previews/\(id)-\(name).jpg"
        for rel in [art, preview] { try fm.createDirectory(at: library.appendingPathComponent(rel).deletingLastPathComponent(), withIntermediateDirectories: true) }
        try ctx.writeHEIF10Representation(of: img, to: library.appendingPathComponent(art), colorSpace: srgb,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
        let k = 480 / max(size.width, size.height)
        let small = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        try ctx.writeJPEGRepresentation(of: small.cropped(to: small.extent.integral), to: library.appendingPathComponent(preview), colorSpace: srgb,
                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82])
        variants[name] = Variant(path: art, width: Int(size.width), height: Int(size.height), hasAlpha: false, previewPath: preview)
    }
    guard !variants.isEmpty else { continue }
    if variants.count == 1 { notes.append("\(first.name): no \(variants["horizontal"] == nil ? "16:9" : "9:16") picture, that canvas shows the middle of the other one") }
    let lum = colours.map { 0.2126 * $0.red + 0.7152 * $0.green + 0.0722 * $0.blue }.reduce(0, +) / CGFloat(colours.count)
    let note = first.url.deletingLastPathComponent().appendingPathComponent("\(first.name).txt")
    let description = (try? String(contentsOf: note, encoding: .utf8))?.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    let asset = Asset(id: id, name: first.name, category: "backgrounds", subcategory: first.group, styleFamily: nil, description: description,
                      tags: [lum > 0.5 ? "light" : "dark"], dominantColors: colours.map(hex), variants: variants)
    if let i = manifest.assets.firstIndex(where: { $0.id == id }) {
        // Drop files of an orientation the new version doesn't have.
        for (o, v) in manifest.assets[i].variants where variants[o] == nil {
            try? fm.removeItem(at: library.appendingPathComponent(v.path)); try? fm.removeItem(at: library.appendingPathComponent(v.previewPath))
        }
        manifest.assets[i] = asset; replaced += 1
    } else {
        manifest.assets.append(asset); added += 1
    }
    print("\(lum > 0.5 ? "light" : "dark ")  \(first.group)  \(first.name)  [\(variants.keys.sorted().map { $0 == "horizontal" ? "16:9" : "9:16" }.joined(separator: " + "))]")
}

manifest.assets.sort { ($0.subcategory, $0.name.lowercased()) < ($1.subcategory, $1.name.lowercased()) }
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try fm.createDirectory(at: library, withIntermediateDirectories: true)
try enc.encode(manifest).write(to: library.appendingPathComponent("manifest.json"))

print("\nadded \(added), replaced \(replaced); the library now has \(manifest.assets.count) backgrounds")
notes.forEach { print("note: \($0)") }
if !problems.isEmpty { problems.forEach { print("PROBLEM: \($0)") }; exit(1) }
