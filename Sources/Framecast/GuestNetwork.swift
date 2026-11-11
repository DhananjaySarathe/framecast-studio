import Foundation
import Security
import SystemConfiguration
import Darwin

/// Who can reach the guest room.
enum GuestReach: String, CaseIterable, Identifiable {
    case thisMac, wifi, internet
    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMac: "This Mac only"
        case .wifi: "People on my Wi-Fi"
        case .internet: "Anyone with a link (LiveKit Cloud)"
        }
    }

    /// Automated test launches (FRAMECAST_UI set) keep their own choice, so a test never opens the user's LiveKit project.
    private static let key = ProcessInfo.processInfo.environment["FRAMECAST_UI"] == nil ? "framecast.guestReach" : "framecast.guestReach.autotest"
    static var saved: GuestReach {
        get { GuestReach(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .thisMac }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Generic-password Keychain items (login keychain).
enum SecretStore {
    static func set(_ value: String, service: String, account: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q; add[kSecValueData] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    /// Whether the item exists, without reading it (so macOS doesn't ask for Keychain access).
    static func exists(service: String, account: String) -> Bool {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func get(service: String, account: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// The user's own LiveKit Cloud project plus the public address of their copy of the guest page.
/// URL, key and page address are kept in UserDefaults; the API secret in the Keychain.
struct GuestCloudConfig: Equatable {
    var url = ""        // wss://<project>.livekit.cloud
    var apiKey = ""
    var secret = ""
    var pageURL = ""    // https://… where index.html and livekit-client.umd.js are hosted

    private static let service = "Framecast guest server", account = "livekit-api-secret"
    private static var defaults: UserDefaults { .standard }

    /// Without `secret`, only checks that the secret is saved: reading it can make macOS ask for Keychain
    /// access, so that waits until a LiveKit Cloud room is actually opened.
    static func load(secret withSecret: Bool = true) -> GuestCloudConfig {
        var c = GuestCloudConfig(url: defaults.string(forKey: "framecast.guestCloudURL") ?? "",
                                 apiKey: defaults.string(forKey: "framecast.guestCloudKey") ?? "",
                                 pageURL: defaults.string(forKey: "framecast.guestPageURL") ?? "")
        if withSecret { c.secret = SecretStore.get(service: service, account: account) ?? "" }
        else { c.secretSaved = SecretStore.exists(service: service, account: account) }
        return c
    }
    var secretSaved = false

    func save() {
        Self.defaults.set(url, forKey: "framecast.guestCloudURL")
        Self.defaults.set(apiKey, forKey: "framecast.guestCloudKey")
        Self.defaults.set(pageURL, forKey: "framecast.guestPageURL")
        if !secret.isEmpty { SecretStore.set(secret, service: Self.service, account: Self.account) }   // keep a saved one
    }

    /// Tests the remote-guest protocol end to end against the LiveKit server on this Mac (nothing leaves it).
    static let localTest = GuestCloudConfig(url: "ws://127.0.0.1:\(GuestServer.signalPort)", apiKey: "local", secret: "local", pageURL: "http://127.0.0.1:\(GuestServer.httpPort)/")
    var isLocalTest: Bool { URL(string: url)?.host == "127.0.0.1" }

    /// nil when usable; otherwise what's missing, in words.
    var problem: String? {
        guard let u = URL(string: url), u.scheme == "wss" || (u.scheme == "ws" && isLocalTest), u.host != nil else {
            return "Add your LiveKit project URL (wss://…livekit.cloud)."
        }
        if apiKey.isEmpty || (secret.isEmpty && !secretSaved) { return "Add your LiveKit API key and secret." }
        guard let p = URL(string: pageURL), p.host != nil, p.scheme == "https" || isLocalTest else {
            return "Add the https:// address where you put the guest page."
        }
        return nil
    }

    /// LiveKit's server API lives on the same host as the signalling URL, over https.
    var apiBase: String {
        url.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Reads LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET and GUEST_PAGE_URL from a .env file.
    /// Values already saved are kept for any key the file leaves out.
    static func fromEnvFile(_ path: String, base: GuestCloudConfig) throws -> GuestCloudConfig {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var env: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            env[k] = v
        }
        let known = ["LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "GUEST_PAGE_URL"]
        guard known.contains(where: { env[$0] != nil }) else {
            throw NSError(domain: "Framecast.Guests", code: 3, userInfo: [NSLocalizedDescriptionKey: "That file has no LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET or GUEST_PAGE_URL lines."])
        }
        var c = base
        if let v = env["LIVEKIT_URL"] { c.url = v }
        if let v = env["LIVEKIT_API_KEY"] { c.apiKey = v }
        if let v = env["LIVEKIT_API_SECRET"] { c.secret = v }
        if let v = env["GUEST_PAGE_URL"] { c.pageURL = v }
        return c
    }
}

/// This Mac's address on the local network, for Wi-Fi guests.
enum LocalNetwork {
    /// The private IPv4 address of the primary Wi-Fi/Ethernet interface. Public addresses are refused so a
    /// directly connected Mac never opens the guest room to the internet.
    static func privateIPv4() -> (interface: String, address: String)? {
        var primary: String?
        if let store = SCDynamicStoreCreate(nil, "Framecast" as CFString, nil, nil),
           let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            primary = v["PrimaryInterface"] as? String
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            let name = String(cString: a.ifa_name)
            let flags = Int32(a.ifa_flags)
            guard name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if isPrivate(ip) { found.append((name, ip)) }
        }
        return found.first { $0.0 == primary } ?? found.first
    }

    /// Whether any interface of this Mac has an address reachable from the internet (a public IPv4, or a global
    /// IPv6). Loopback, link-local, private and unique-local addresses don't count.
    static func hasPublicAddress() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return true }      // can't tell: assume the worst
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard Int32(a.ifa_flags) & IFF_UP != 0, Int32(a.ifa_flags) & IFF_LOOPBACK == 0, let sa = a.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
            if family == AF_INET {
                let o = ip.split(separator: ".").compactMap { Int($0) }
                // 100.64/10 is carrier-grade NAT, not reachable from outside either.
                if !isPrivate(ip) && !(o.count == 4 && o[0] == 100 && (64...127).contains(o[1])) { return true }
            } else if let first = ip.split(separator: ":").first, let v = Int(first, radix: 16), (0x2000...0x3fff).contains(v) {
                return true                                                        // global unicast IPv6 (2000::/3)
            }
        }
        return false
    }

    static func isPrivate(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }
}

/// A self-signed certificate for the Wi-Fi guest page: browsers allow camera and microphone only on https
/// pages (or on the same computer). Made with macOS's own `openssl`, kept in Application Support (key readable
/// by this user only) and reused until the Mac's address changes. Loaded into memory only, never into a keychain.
enum GuestTLS {
    static func identity(for ip: String, dir: URL) throws -> SecIdentity {
        let tls = dir.appendingPathComponent("tls")
        try FileManager.default.createDirectory(at: tls, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = tls.appendingPathComponent("key.pem"), cert = tls.appendingPathComponent("cert.pem"), san = tls.appendingPathComponent("address")
        if (try? String(contentsOf: san, encoding: .utf8)) != ip || !FileManager.default.fileExists(atPath: key.path) {
            let cfg = tls.appendingPathComponent("req.cnf")
            try """
            [req]
            distinguished_name = dn
            x509_extensions = ext
            prompt = no
            [dn]
            CN = Framecast guest room
            O = Framecast (self-signed, this Mac only)
            [ext]
            subjectAltName = IP:\(ip),IP:127.0.0.1
            basicConstraints = critical,CA:FALSE
            keyUsage = critical,digitalSignature,keyEncipherment
            extendedKeyUsage = serverAuth
            """.write(to: cfg, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: cfg) }
            _ = try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "365",
                         "-keyout", key.path, "-out", cert.path, "-config", cfg.path])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            try ip.write(to: san, atomically: true, encoding: .utf8)
        }
        // Bundle key + certificate as PKCS#12 on stdout with a one-time password, then import it in memory.
        let pass = UUID().uuidString
        let p12 = try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-passout", "env:FC_P12"], env: ["FC_P12": pass])
        var items: CFArray?
        guard #available(macOS 15, *) else {
            throw NSError(domain: "Framecast.Guests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Wi-Fi guests need macOS 15 or later."])
        }
        let opts: [CFString: Any] = [kSecImportExportPassphrase: pass, kSecImportToMemoryOnly: true]
        let status = SecPKCS12Import(p12 as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[CFString: Any]])?.first,
              let any = first[kSecImportItemIdentity] else {
            throw NSError(domain: "Framecast.Guests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Couldn't load the guest room's certificate (\(status))."])
        }
        return any as! SecIdentity
    }

    private static func run(_ args: [String], env: [String: String] = [:]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "Framecast.Guests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Couldn't make the guest room's certificate. \(msg.prefix(200))"])
        }
        return data
    }
}
