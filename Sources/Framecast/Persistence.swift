import Foundation
import FramecastEngine

/// Scenes live in ~/Library/Application Support/Framecast/Collections/<profile>.json with rolling backups
///.
enum CollectionStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Framecast")
    }
    static var dir: URL { root.appendingPathComponent("Collections") }
    static var backups: URL { dir.appendingPathComponent("Backups") }

    struct LoadResult { var collection: SceneCollection; var notice: String? }

    /// Automated test launches (FRAMECAST_UI set) keep their own scenes, so tests never change the user's studio.
    static let profile = ProcessInfo.processInfo.environment["FRAMECAST_UI"] == nil ? "default" : "autotest"

    static func load(profile: String = CollectionStore.profile) -> LoadResult {
        let url = dir.appendingPathComponent("\(profile).json")
        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(collection: LayoutTemplates.defaultCollection(), notice: nil)
        }
        if let c = try? JSONDecoder().decode(SceneCollection.self, from: data) { return LoadResult(collection: c, notice: nil) }
        // Unreadable: keep the bad file for inspection and fall back to the newest backup that parses.
        let kept = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: kept)
        let files = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where f.lastPathComponent.hasPrefix("\(profile)-") {
            if let d = try? Data(contentsOf: f), let c = try? JSONDecoder().decode(SceneCollection.self, from: d) {
                return LoadResult(collection: c, notice: "Your scenes could not be read, so the backup from \(f.lastPathComponent) was restored. The file was kept as \(kept.lastPathComponent).")
            }
        }
        return LoadResult(collection: LayoutTemplates.defaultCollection(),
                          notice: "Your scenes could not be read. The file was kept as \(kept.lastPathComponent).")
    }

    static func save(_ c: SceneCollection, profile: String = CollectionStore.profile) {
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(profile).json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(c) else { return }
        // Back up the previous version at most once a minute, keep the last 20.
        if FileManager.default.fileExists(atPath: url.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
            let b = backups.appendingPathComponent("\(profile)-\(f.string(from: Date())).json")
            if !FileManager.default.fileExists(atPath: b.path) { try? FileManager.default.copyItem(at: url, to: b) }
            let all = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.hasPrefix("\(profile)-") }.sorted()
            for old in all.dropLast(20) { try? FileManager.default.removeItem(at: backups.appendingPathComponent(old)) }
        }
        try? data.write(to: url, options: .atomic)
    }
}
