import Foundation

/// A show's plan. Two ways to run it:
///  • topics (from a rough brief): what to cover, the key points and the assets for each; during the show the live
///    brain follows what's been covered and picks looks and assets (LiveBrain.swift);
///  • parts (from a script): parts in order, each with a scene and the words that start it (cue matching).
/// Each show has its own folder under Application Support/Framecast/Shows with show.json, brief.md, script.md,
/// the assets folder, logs and rehearsals.
struct ShowRundown: Codable, Equatable {
    var format = "framecast-show/0.2"
    var title: String
    var brief = ""
    var topics: [ShowTopic] = []
    /// What each asset in the assets folder shows, so the live brain knows when it fits.
    var assets: [ShowAsset] = []
    var script = ""
    var parts: [RundownPart] = []
    /// Words speech recognition tends to mishear in this show ("opa" → "opus").
    var aliases: [WordAlias] = []
    var director = DirectorSettings()

    init(title: String) { self.title = title }

    // Hand-written or AI-written files may leave fields out: anything missing gets its default.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled show"
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? ""
        topics = try c.decodeIfPresent([ShowTopic].self, forKey: .topics) ?? []
        assets = try c.decodeIfPresent([ShowAsset].self, forKey: .assets) ?? []
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        parts = try c.decodeIfPresent([RundownPart].self, forKey: .parts) ?? []
        aliases = try c.decodeIfPresent([WordAlias].self, forKey: .aliases) ?? []
        director = try c.decodeIfPresent(DirectorSettings.self, forKey: .director) ?? DirectorSettings()
    }
}

struct RundownPart: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    /// The scene's name (not its ID), so a rundown written by hand or by an AI reads naturally.
    var scene: String
    /// What the presenter says when this part should start. Empty: the part only starts by hand.
    var cue = ""
    /// Other ways of saying the cue.
    var alsoAccept: [String] = []
    var notes = ""

    init(title: String, scene: String, cue: String = "", alsoAccept: [String] = [], notes: String = "") {
        self.title = title; self.scene = scene; self.cue = cue; self.alsoAccept = alsoAccept; self.notes = notes
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        cue = try c.decodeIfPresent(String.self, forKey: .cue) ?? ""
        alsoAccept = try c.decodeIfPresent([String].self, forKey: .alsoAccept) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

/// Something to cover in the show: its key points, the look that suits it, and its assets (files in the show's
/// assets folder).
struct ShowTopic: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var points: [String] = []
    var look = ""
    var assets: [String] = []
    var notes = ""

    init(title: String, points: [String] = [], look: String = "", assets: [String] = [], notes: String = "") {
        self.title = title; self.points = points; self.look = look; self.assets = assets; self.notes = notes
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        points = try c.decodeIfPresent([String].self, forKey: .points) ?? []
        look = try c.decodeIfPresent(String.self, forKey: .look) ?? ""
        assets = try c.decodeIfPresent([String].self, forKey: .assets) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

struct ShowAsset: Codable, Equatable, Hashable {
    var file: String
    var about = ""
    init(file: String, about: String = "") { self.file = file; self.about = about }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
    }
}

struct WordAlias: Codable, Equatable, Hashable {
    var heard: String
    var meant: String
}

/// How much the director does on its own.
enum DirectorMode: String, Codable, CaseIterable {
    case off, suggest, auto
    var title: String {
        switch self { case .off: "Off"; case .suggest: "Suggest"; case .auto: "Auto" }
    }
}

struct DirectorSettings: Codable, Equatable {
    var mode: DirectorMode = .suggest
    /// No automatic switch sooner than this after the last switch.
    var minShotSeconds = 3.0
    /// Live brain: a look stays at least this long (shorter when the topic changes), an asset at least this long.
    var lookHoldSeconds = 20.0
    var assetHoldSeconds = 8.0

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(DirectorMode.self, forKey: .mode) ?? .suggest
        minShotSeconds = try c.decodeIfPresent(Double.self, forKey: .minShotSeconds) ?? 3
        lookHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .lookHoldSeconds) ?? 20
        assetHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .assetHoldSeconds) ?? 8
    }
}

/// Show folders. Automated test launches (FRAMECAST_UI set) keep their own, so tests never touch the user's shows.
enum ShowStore {
    static var dir: URL { CollectionStore.root.appendingPathComponent(CollectionStore.profile == "default" ? "Shows" : "Shows (tests)") }
    private static let lastKey = CollectionStore.profile == "default" ? "framecast.lastShow" : "framecast.lastShow.autotest"

    struct Entry: Identifiable { var url: URL; var title: String; var modified: Date; var id: String { url.path } }

    /// Saved shows, newest first.
    static func list() -> [Entry] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { f -> Entry? in
            let file = f.appendingPathComponent("show.json")
            guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(ShowRundown.self, from: data) else { return nil }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Entry(url: f, title: s.title, modified: date)
        }.sorted { $0.modified > $1.modified }
    }

    static func load(_ folder: URL) throws -> ShowRundown {
        try JSONDecoder().decode(ShowRundown.self, from: Data(contentsOf: folder.appendingPathComponent("show.json")))
    }

    static func save(_ show: ShowRundown, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(show) { try? d.write(to: folder.appendingPathComponent("show.json"), options: .atomic) }
        try? show.script.write(to: folder.appendingPathComponent("script.md"), atomically: true, encoding: .utf8)
        try? show.brief.write(to: folder.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
        ShowGuide.write(in: folder)
    }

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]
    static let videoTypes: Set<String> = ["mov", "mp4", "m4v"]

    /// Pictures and videos in the show's assets folder, by name.
    static func assetFiles(in folder: URL) -> [String] {
        let dir = folder.appendingPathComponent("assets")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { imageTypes.union(videoTypes).contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    }

    /// A new, unused folder: "2026-10-21 My show".
    static func newFolder(title: String) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let clean = RecordingFileName.sanitized(title)
        let base = "\(f.string(from: Date())) \(clean.isEmpty ? "Show" : clean)"
        var url = dir.appendingPathComponent(base), k = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(base) \(k)"); k += 1 }
        return url
    }

    static var lastOpened: URL? {
        get { UserDefaults.standard.string(forKey: lastKey).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: lastKey) }
    }
}
