// Imports a Framecast creator asset pack (manifest.json + assets/) into Resources/AssetPacks/<name>/.
//
//   swiftc -O scripts/import_asset_pack.swift -o build/import_asset_pack
//   build/import_asset_pack <unzipped pack folder> Resources/AssetPacks/creator-v1
//
// • Checks every file the manifest lists: present, SHA-256 matches, pixel size matches.
// • Opaque 4K backgrounds and scene plates become 10-bit HEIC (about a tenth of the PNG size). Their fine grain
//   (the pack dithers to avoid banding) is put back when Framecast loads them, see AssetPack.swift.
// • Transparent frames, cards and annotations are copied unchanged (PNG, already small).
// • Previews, editable SVGs and the manifest/notes are copied as they are.
import Foundation
import CoreImage
import CryptoKit
import ImageIO

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: import_asset_pack <pack folder> <output folder>"); exit(2) }
let pack = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let fm = FileManager.default
let quality = 0.9      // measured: smooth at 10 bits, no visible contours after re-dithering

struct Manifest: Decodable {
    struct Asset: Decodable { let id: String; let category: String; let variants: [String: Variant] }
    struct Variant: Decodable {
        let path: String; let width: Int; let height: Int; let hasAlpha: Bool; let sha256: String?
        let additionalVariantPaths: [String]?
    }
    let assets: [Asset]
}

func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func pixelSize(_ url: URL) -> (Int, Int)? {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}
func copy(_ rel: String) throws {
    let dst = out.appendingPathComponent(rel)
    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
    try fm.copyItem(at: pack.appendingPathComponent(rel), to: dst)
}

let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: pack.appendingPathComponent("manifest.json")))
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
var problems: [String] = [], converted = 0, copied = 0

for asset in manifest.assets {
    for (name, v) in asset.variants.sorted(by: { $0.key < $1.key }) {
        let src = pack.appendingPathComponent(v.path)
        guard fm.fileExists(atPath: src.path) else { problems.append("missing \(v.path)"); continue }
        if let want = v.sha256, try sha256(src) != want { problems.append("checksum mismatch \(v.path)") }
        if let (w, h) = pixelSize(src), (w, h) != (v.width, v.height) { problems.append("size \(w)x\(h) ≠ manifest \(v.width)x\(v.height): \(v.path)") }
        if !v.hasAlpha && (asset.category == "backgrounds" || asset.category == "stream-scenes") {
            let dst = out.appendingPathComponent((v.path as NSString).deletingPathExtension + ".heic")
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let img = CIImage(contentsOf: src) else { problems.append("unreadable \(v.path)"); continue }
            try ctx.writeHEIF10Representation(of: img, to: dst, colorSpace: srgb,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
            converted += 1
        } else {
            try copy(v.path); copied += 1
        }
        for extra in v.additionalVariantPaths ?? [] { try copy(extra); copied += 1 }
        _ = name
    }
}
for rel in ["manifest.json", "manifest.schema.json", "design-tokens.json", "provenance.json", "README.md", "integration-notes.md"]
    where fm.fileExists(atPath: pack.appendingPathComponent(rel).path) { try copy(rel) }
for dir in ["previews", "editable"] {
    let src = pack.appendingPathComponent(dir)
    let dst = out.appendingPathComponent(dir)
    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
    if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) }
}
print("converted \(converted) to 10-bit HEIC, copied \(copied) PNGs")
if problems.isEmpty { print("all files present, checksums and sizes match the manifest") }
else { problems.forEach { print("PROBLEM: \($0)") }; exit(1) }
