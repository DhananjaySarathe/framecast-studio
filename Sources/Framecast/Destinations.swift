import Foundation
import Observation
import Security
import FramecastEngine

enum Platform: String, Codable, CaseIterable, Identifiable {
    case youtube, twitch, x, instagram, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .youtube: "YouTube"; case .twitch: "Twitch"; case .x: "X"; case .instagram: "Instagram"; case .custom: "Custom RTMP server" }
    }
    /// Default ingest addresses published by each platform. Users can change them.
    var defaultServer: String {
        switch self {
        case .youtube: "rtmps://a.rtmps.youtube.com:443/live2"
        case .twitch: "rtmps://live.twitch.tv/app"
        case .x: "rtmps://va.pscp.tv:443/x"
        case .instagram: "rtmps://live-upload.instagram.com:443/rtmp/"
        case .custom: ""
        }
    }
    var keyHelp: String {
        switch self {
        case .youtube: "YouTube Studio → Go live → Stream → Stream key."
        case .twitch: "Twitch Creator Dashboard → Settings → Stream → Primary stream key."
        case .x: "X Media Studio → Producer → Sources → create a source; copy its RTMPS URL and key."
        case .instagram: "Instagram → Live → Streaming software (Live Producer); copy the server URL and stream key."
        case .custom: "Find both values in your platform's stream or encoder settings."
        }
    }
    /// Published platform limits used for quality defaults.
    var recommendedKbps: Int { switch self { case .youtube: 9_000; case .twitch: 6_000; case .x: 6_000; case .instagram: 4_000; case .custom: 6_000 } }
    var maxHeight: Int { switch self { case .youtube: 2160; case .twitch: 1080; case .x: 1080; case .instagram: 1280; case .custom: 2160 } }
    var preferredCanvas: CanvasKind { self == .instagram ? .vertical : .horizontal }
}

struct Destination: Codable, Identifiable, Equatable {
    var id = UUID()
    var platform: Platform
    var name: String
    var server: String
    var keyHint: String = ""          // last 4 characters; the key itself is in the Keychain
    var canvas: CanvasKind
    var isOn = true
    var videoKbps: Int
    var fps: Int = 30
    var maxHeight: Int
    var autoReconnect = true
    var adaptiveBitrate = true
    var testedAt: Date?
    var createdAt = Date()
}

/// Stream keys go to the login Keychain (generic password, service "Framecast stream key").
enum KeychainStore {
    /// Automated test launches (FRAMECAST_UI set) keep their own keys, apart from the user's real stream keys.
    static let service = DestinationsStore.isTestLaunch ? "Framecast stream key (tests)" : "Framecast stream key"
    static func set(_ key: String, for id: UUID) -> Bool {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    static func get(_ id: UUID) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ id: UUID) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString] as CFDictionary)
    }
}

/// Saved destinations (server URLs and names in Application Support; keys in the Keychain).
@Observable
final class DestinationsStore {
    var items: [Destination] = [] { didSet { save() } }
    /// Automated test launches use their own destinations list and may only stream to this Mac, so a test can never
    /// go live on the user's channels.
    static let isTestLaunch = ProcessInfo.processInfo.environment["FRAMECAST_UI"] != nil
    private var url: URL { CollectionStore.root.appendingPathComponent(Self.isTestLaunch ? "Destinations-autotest.json" : "Destinations.json") }
    static func isThisMac(_ server: String) -> Bool {
        guard let host = URL(string: server.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
    init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([Destination].self, from: d) { items = v }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: CollectionStore.root, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: .atomic) }
    }
    func add(platform: Platform, name: String, server: String, key: String, canvas: CanvasKind) -> String? {
        var d = Destination(platform: platform, name: name, server: server, canvas: canvas,
                            videoKbps: platform.recommendedKbps, maxHeight: platform.maxHeight)
        d.keyHint = String(key.suffix(4))
        if !key.isEmpty && !KeychainStore.set(key, for: d.id) { return "Couldn't store the stream key in the Keychain." }
        items.append(d)
        return nil
    }
    func remove(_ id: UUID) { KeychainStore.delete(id); items.removeAll { $0.id == id } }
    func key(for d: Destination) -> String { KeychainStore.get(d.id) ?? "" }

    /// Validates an RTMP/RTMPS address and explains what's wrong in words.
    static func validate(server: String) -> String? {
        let s = server.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "Enter the server address, e.g. rtmp://live.twitch.tv/app." }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return "That address doesn't look right." }
        guard scheme == "rtmp" || scheme == "rtmps" else { return "Use an rtmp:// or rtmps:// server address." }
        guard let h = u.host, !h.isEmpty else { return "The address needs a server name." }
        return nil
    }
}
