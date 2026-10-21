// Show prep with Apple's on-device model: for every cue in a cue list, write other ways a presenter might say it,
// so the live cue follower can match ad-libs without calling any model during the show. The model never sees the
// test talks.
//
//   swiftc -O variants.swift -o cue-variants && ./cue-variants ../cue-follower/cues.json > ../cue-follower/cues.expanded.json
import Foundation
import FoundationModels

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cues.json"
var file = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]

let schema = try! GenerationSchema(root: DynamicGenerationSchema(name: "Variants", properties: [
    .init(name: "variants", description: "different natural ways to say it, 3 to 9 words each",
          schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 8, maximumElements: 8)),
]), dependencies: [])

@MainActor
func run() async throws {
    var cues = file["cues"] as! [[String: Any]]
    for i in cues.indices {
        let say = cues[i]["say"] as! String, scene = cues[i]["scene"] as! String
        let session = LanguageModelSession(instructions: """
        You help prepare a live video show. A presenter will say a cue line out loud, and the director then switches \
        to the scene named. Presenters rarely use the exact words, so list other short, natural, spoken ways to say \
        the same thing at that moment. Keep the meaning; vary the wording. No numbering, no quotes.
        """)
        let t0 = Date()
        let r = try await session.respond(to: "Cue line: \(say)\nScene it leads to: \(scene)", schema: schema)
        let variants = try r.content.value([String].self, forProperty: "variants")
        cues[i]["alsoAccept"] = variants
        FileHandle.standardError.write(String(format: "%.2f s  %@: %@\n", Date().timeIntervalSince(t0), say, variants.joined(separator: " | ")).data(using: .utf8)!)
    }
    file["cues"] = cues
    let out = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(out + Data([0x0A]))
}

Task { @MainActor in
    do { try await run() } catch { FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!) }
    exit(0)
}
RunLoop.main.run()
