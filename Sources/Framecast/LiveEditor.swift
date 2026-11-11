import Foundation
import AppKit
import Carbon
import Observation
import FramecastEngine

/// The live editor's settings. Decoded field by field, so a field or value from a newer build never resets
/// everything else in Settings.
struct LiveEditorSettings: Codable, Equatable {
    var moves: CameraMoves = .off
    /// What ⌃⌥⌘C turns back on.
    var lastMoves: CameraMoves = .rehearse
    var intensity: MoveIntensity = .moderate
    var idleSeconds = 5.0
    /// Apps whose windows are never magnified (bundle ids).
    var neverZoom: [String] = LiveEditor.defaultNeverZoom
    /// Leave password managers and Keychain Access out of display captures altogether.
    var hidesPasswordManagers = true
    var clickRings = false
    var showsHUD = true
    var performance: PerformanceMode = .auto
    /// The app's own steady frame time at this frame rate (Gate 0); the governor's lines start from it.
    var baselineP95Ms: Double?

    init() {}
    init(from d: Decoder) throws {
        self.init()
        guard let c = try? d.container(keyedBy: CodingKeys.self) else { return }
        func get<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        moves = get(.moves, moves); lastMoves = get(.lastMoves, lastMoves); intensity = get(.intensity, intensity)
        idleSeconds = get(.idleSeconds, idleSeconds); neverZoom = get(.neverZoom, neverZoom)
        hidesPasswordManagers = get(.hidesPasswordManagers, hidesPasswordManagers); clickRings = get(.clickRings, clickRings)
        showsHUD = get(.showsHUD, showsHUD); performance = get(.performance, performance)
        baselineP95Ms = get(.baselineP95Ms, baselineP95Ms)
    }
}

/// What the private panel shows about the live editor, refreshed twice a second.
struct LiveEditorHUD: Equatable {
    var moves = "off"
    var tier = BudgetTier.full
    var reason = ""
    var p50 = 0.0, p95 = 0.0
    var missed = 0, drops = 0
    var thermal = "nominal"
}

/// Screen auto-zoom on the app side: settings into the engine, the pointer monitor, the shortcuts and the HUD.
@Observable
final class LiveEditor {
    static let passwordManagers = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
                                   "com.agilebits.onepassword7", "com.bitwarden.desktop"]
    static let defaultNeverZoom = passwordManagers + ["com.apple.MobileSMS", "com.apple.mail", "com.apple.systempreferences",
                                                      "com.apple.notificationcenterui", "com.apple.controlcenter"]

    @ObservationIgnored unowned let studio: Studio
    @ObservationIgnored private var pointer: PointerMonitor?
    @ObservationIgnored private var applied: LiveEditorSettings?
    @ObservationIgnored private var appliedLive: Bool?
    @ObservationIgnored private var appliedOwnWindows: Bool?
    @ObservationIgnored private var polls = 0
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    var hud = LiveEditorHUD()
    /// Shortcuts another app already holds.
    var hotkeyProblems: [String] = []

    init(studio: Studio) { self.studio = studio }

    var settings: LiveEditorSettings {
        get { studio.settings.s.liveEditor ?? LiveEditorSettings() }
        set { studio.settings.s.liveEditor = newValue }
    }
    var engine: Engine { studio.engine }

    func start() {
        sync()
        // A password manager opened after the screen capture started is left out as soon as it shows up (macOS takes a
        // moment to list a new app, hence the retries).
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self, let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                      ScreenSource.hiddenApps.contains(id) else { return }
                for delay in [0.0, 0.5, 1.5, 3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.engine.refreshScreenFilters() } }
            })
        }
    }
    func stop() {
        pointer?.stop(); pointer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceObservers = []
    }

    /// 15 times a second from the studio's poll: applies changed settings, and refreshes the HUD twice a second.
    func poll() {
        sync()
        polls += 1
        if polls % 7 == 0 { refreshHUD() }
    }

    private func sync() {
        let s = settings
        let live = studio.streaming.phase != .idle
        let own = studio.settings.s.showsOwnWindows ?? false
        guard s != applied || live != appliedLive || own != appliedOwnWindows else { return }
        let old = applied
        applied = s; appliedLive = live; appliedOwnWindows = own
        var c = FocusController.Config()
        c.moves = s.moves; c.isLive = live; c.intensity = s.intensity; c.idleSeconds = s.idleSeconds
        engine.focus.setConfig(c)
        engine.governor.mode = s.performance
        engine.governor.baselineMs = s.baselineP95Ms ?? 0
        if old?.moves == .off || old == nil, s.moves != .off { engine.governor.reset() }   // switching moves on again leaves T3
        let hidden = Set(s.hidesPasswordManagers ? Self.passwordManagers : [])
        if hidden != ScreenSource.hiddenApps { ScreenSource.hiddenApps = hidden; engine.refreshScreenFilters() }
        if s.clickRings != ScreenSource.showsClicks { ScreenSource.showsClicks = s.clickRings; engine.refreshScreenConfigurations() }
        // The pointer is only watched while camera moves can happen.
        if !c.allowsMoves { pointer?.stop(); pointer = nil }
        else if pointer == nil { let p = PointerMonitor(focus: engine.focus); p.start(); pointer = p }
        pointer?.configure(neverZoom: Set(s.neverZoom), ownWindowsCaptured: own)
    }

    private func refreshHUD() {
        let g = engine.governor.current, ticks = engine.tickSummary(seconds: 20)
        let h = LiveEditorHUD(moves: engine.focus.summary, tier: g.tier, reason: g.reason, p50: (ticks.p50 * 10).rounded() / 10,
                              p95: (ticks.p95 * 10).rounded() / 10, missed: engine.missedRecordingFrames, drops: engine.captureDrops, thermal: g.thermal)
        if h != hud { hud = h }
    }

    // MARK: Actions (shortcuts, the HUD, test hooks)

    func setMoves(_ m: CameraMoves) {
        var s = settings
        s.moves = m
        if m != .off { s.lastMoves = m }
        settings = s
        sync()
    }
    /// ⌃⌥⌘C: off, or back to what it was.
    func toggleMoves() { setMoves(settings.moves == .off ? settings.lastMoves : .off) }
    /// ⌃⌥⌘Z: zoom to where the cursor is (the same checks as a click).
    func zoomToCursor() {
        guard let p = CGEvent(source: nil)?.location else { return }
        pointer?.handleClick(at: p, time: HostClock.seconds(), own: false)
    }
    /// ⌃⌥⌘X: back to the whole screen, and no zooms for 30 s.
    func resetAndPause() { engine.focus.resetAndPause(seconds: 30, at: HostClock.seconds()) }

    // Test launches only (fcctl).
    func testClick(_ p: CGPoint) { pointer?.handleClick(at: p, time: HostClock.seconds(), own: false) }
    func testCursor(_ p: CGPoint?) { pointer?.testCursor = p }
    func testSecure(_ on: Bool?) { pointer?.testSecure = on }
}

/// Where the pointer is and where it clicks, for the screen auto-zoom, with no permission prompts: the cursor
/// position, a global mouse-down monitor and the secure-input check need neither Accessibility nor Input
/// Monitoring, and nothing typed is ever read. Each click is checked against the window under it first: clicks
/// on Framecast (unless it's in the shared screen), the Dock, the menu bar, notifications or a never-zoom app don't
/// zoom, and the camera keeps off never-zoom windows.
final class PointerMonitor {
    private let focus: FocusController
    private let queue = DispatchQueue(label: "framecast.pointer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var neverZoom: Set<String> = []
    private var ownCaptured = false
    private var bundles: [pid_t: String] = [:]
    // Sampler state (on `queue`). Both start unknown: the first reading is a baseline (no click) and is always sent (secure).
    private var ticks = 0
    private var lastClickAge: Double?
    private var secure: Bool?
    // Main thread.
    private var lastMonitorClick = -1e9
    /// Test launches only: pretend the cursor is here, or that a password field is (not) focused.
    var testCursor: CGPoint? { get { lock.lock(); defer { lock.unlock() }; return _testCursor } set { lock.lock(); _testCursor = newValue; lock.unlock() } }
    var testSecure: Bool? { get { lock.lock(); defer { lock.unlock() }; return _testSecure } set { lock.lock(); _testSecure = newValue; lock.unlock() } }
    private var _testCursor: CGPoint?
    private var _testSecure: Bool?

    /// Apps that are part of macOS itself, not of what's being shown.
    static let systemUI: Set<String> = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
                                        "com.apple.systemuiserver", "com.apple.WindowManager", "com.apple.Spotlight"]

    init(focus: FocusController) { self.focus = focus }

    func configure(neverZoom: Set<String>, ownWindowsCaptured: Bool) {
        lock.lock(); self.neverZoom = neverZoom; ownCaptured = ownWindowsCaptured; lock.unlock()
    }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in self?.clicked(e, own: false) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in self?.clicked(e, own: true); return e }) {
            monitors.append(m)
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            // Coming to Framecast itself isn't a change of what's on the shared screen.
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.focus.appSwitched(at: HostClock.seconds())
        })
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))   // about 120 Hz
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); observers = []
        timer?.cancel(); timer = nil
    }

    private func sample() {
        let now = HostClock.seconds()
        let p = testCursor ?? CGEvent(source: nil)?.location
        if let p { focus.cursor(p, at: now) }
        ticks += 1
        // Fallback for a click no monitor reported: the time since the last mouse-down went back down, just now.
        let age = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        if let last = lastClickAge, age < last - 0.004, age < 0.1, testCursor == nil, let p {
            let at = now - min(age, 1.0 / 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, abs(self.lastMonitorClick - at) > 0.25 else { return }
                self.handleClick(at: p, time: at, own: false)
            }
        }
        lastClickAge = age
        if secure == nil || ticks % 30 == 0 {   // 4 times a second
            let on = testSecure ?? IsSecureEventInputEnabled()
            if on != secure { secure = on; focus.secureInput(on, at: now) }
        }
        if ticks % 60 == 0 { refreshAreas() }
        if ticks % 3600 == 0 { lock.lock(); bundles = [:]; lock.unlock() }   // process ids get reused
    }

    private func clicked(_ e: NSEvent, own: Bool) {
        guard testCursor == nil else { return }   // a test is driving the pointer: real clicks would muddle it
        // NSEvent times are seconds since startup, like the host clock; back-date at most one frame.
        let age = min(1.0 / 30, max(0, ProcessInfo.processInfo.systemUptime - e.timestamp))
        let at = HostClock.seconds() - age
        lastMonitorClick = at
        guard let p = e.cgEvent?.location ?? CGEvent(source: nil)?.location else { return }
        handleClick(at: p, time: at, own: own)
    }

    struct WindowHit {
        var number: CGWindowID; var layer: Int; var bundle: String?; var bounds: CGRect
        /// The menu bar and its status items, or a piece of macOS (the Dock, Notification Center, Control Center…).
        var isSystemUI: Bool { layer == 24 || layer == 25 || bundle.map(PointerMonitor.systemUI.contains) ?? (layer >= 20) }
        /// Utilities' see-through overlays sit far above everything (a dictation bar, screenshot tools); clicks go
        /// through them to the window below, so the filter looks through them too. App menus (101) are real.
        var isOverlay: Bool { layer > 25 && layer != 101 && !isSystemUI }
    }

    /// Hands a click to the camera unless the window under it is one that must not zoom.
    func handleClick(at p: CGPoint, time: Double, own: Bool) {
        lock.lock(); let never = neverZoom, ownOK = ownCaptured; lock.unlock()
        if own && !ownOK { return }
        if let hit = windows().first(where: { $0.bounds.contains(p) && !$0.isOverlay }) {
            if ScreenSource.privateWindows.contains(hit.number) || hit.isSystemUI { return }
            if let b = hit.bundle, never.contains(b) { return }
            if hit.bundle == Bundle.main.bundleIdentifier && !ownOK { return }
        }
        focus.click(p, at: time)
    }

    /// On-screen windows, front to back.
    private func windows() -> [WindowHit] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            return WindowHit(number: w[kCGWindowNumber as String] as? CGWindowID ?? 0, layer: w[kCGWindowLayer as String] as? Int ?? 0,
                             bundle: bundle(pid), bounds: r)
        }
    }

    private func bundle(_ pid: pid_t) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let b = bundles[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        bundles[pid] = b
        return b.isEmpty ? nil : b
    }

    /// Twice a second: where panning freezes (Framecast when it isn't shared, the Dock, the menu bar) and which
    /// windows must stay out of a zoomed view.
    private func refreshAreas() {
        lock.lock(); let never = neverZoom, ownOK = ownCaptured; lock.unlock()
        var ignored: [CGRect] = [], denied: [CGRect] = []
        let me = Bundle.main.bundleIdentifier
        for w in windows() where !w.isOverlay {
            if w.isSystemUI || ScreenSource.privateWindows.contains(w.number) || (w.bundle == me && !ownOK) { ignored.append(w.bounds) }
            else if let b = w.bundle, never.contains(b) { denied.append(w.bounds) }
        }
        focus.setAreas(ignored: ignored, denied: denied)
    }
}

/// What the Gate 0 benchmark and the soak tests read (fcctl metrics-dump), once a minute.
struct Gate0: Codable {
    var t: Double
    var last20s: TickSummary
    var last60s: TickSummary
    var governor: GovernorStatus
    var rendered: [String: Int]
    var lateFrames: Int
    var recordingDropped: Int
    var recordingMissed: Int
    var captureDrops: Int
    var cpuSeconds: Double
    var footprintMB: Double
    var moves: String
    var stream: String
    var streamDropped: Int

    static func snapshot(_ studio: Studio) -> Gate0 {
        let e = studio.engine
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        let cpu = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        let s = TestControl.localStream
        return Gate0(t: HostClock.seconds(), last20s: e.tickSummary(seconds: 20), last60s: e.tickSummary(seconds: 60), governor: e.governor.current,
                     rendered: Dictionary(uniqueKeysWithValues: e.metrics.renderedFrames.map { ($0.key.rawValue, $0.value) }), lateFrames: e.metrics.lateFrames,
                     recordingDropped: studio.recorders.reduce(0) { $0 + $1.droppedFrames }, recordingMissed: e.missedRecordingFrames,
                     captureDrops: e.captureDrops, cpuSeconds: cpu, footprintMB: kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1,
                     moves: e.focus.summary, stream: s.map { "\($0.status)" } ?? "none", streamDropped: s?.stats.droppedFrames ?? 0)
    }
}
