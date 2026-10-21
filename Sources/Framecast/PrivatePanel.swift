import SwiftUI
import AppKit
import FramecastEngine

/// Content only the presenter sees, shown in place inside the studio window. The studio window itself shows
/// `placeholder` there; the real content lives in a separate borderless window lying exactly on top of it, which
/// moves and resizes with the studio window. That window is left out of Framecast's own screen capture (by its
/// window number) and asks macOS to keep it out of other apps' captures, so viewers of a shared screen or window
/// only ever see the placeholder, even if the tab is opened by mistake during a show.
struct PrivatePanel<Content: View, Placeholder: View>: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    @ViewBuilder var content: () -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    var body: some View {
        placeholder()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PrivateOverlayAnchor(studio: studio, settings: settings, content: AnyView(content())))
    }
}

/// What a shared screen shows where the Rundown is.
struct PrivatePlaceholder: View {
    var title: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.fc(22, .semibold)).foregroundStyle(Theme.text4)
            Text("\(title) · private").font(.fc(13, .semibold)).foregroundStyle(Theme.text3)
            Text("Only the presenter sees this.").font(.fc(11.5)).foregroundStyle(Theme.text4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }
}

private struct PrivateOverlayAnchor: NSViewRepresentable {
    let studio: Studio
    let settings: AppSettings
    let content: AnyView
    func makeNSView(context: Context) -> PrivateOverlayView {
        PrivateOverlayView(root: AnyView(content.environment(studio).environment(settings).preferredColorScheme(.dark)), studio: studio)
    }
    func updateNSView(_ v: PrivateOverlayView, context: Context) {
        v.host.rootView = AnyView(content.environment(studio).environment(settings).preferredColorScheme(.dark))
        v.place()
    }
    static func dismantleNSView(_ v: PrivateOverlayView, coordinator: ()) { v.close() }
}

/// A key-capable borderless panel (text fields inside it need keyboard focus).
final class PrivatePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PrivateOverlayView: NSView {
    /// Test launches only (`private-capturable` hook): lets screenshots see the private window, to check its layout.
    static var testCapturable = false
    let host: NSHostingView<AnyView>
    let panel: PrivatePanelWindow
    private weak var studio: Studio?
    private var observers: [NSObjectProtocol] = []

    init(root: AnyView, studio: Studio) {
        host = NSHostingView(rootView: root)
        panel = PrivatePanelWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        self.studio = studio
        super.init(frame: .zero)
        panel.contentView = host
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.backgroundColor = Theme.windowNS
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        guard let w = window else { close(); return }
        w.addChildWindow(panel, ordered: .above)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.place() })
        }
        place()
        panel.orderFront(nil)
        registerPrivate()
    }

    override func layout() { super.layout(); place() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); place() }

    /// Lies exactly over this view, in screen coordinates.
    func place() {
        guard let w = window else { return }
        let r = w.convertToScreen(convert(bounds, to: nil))
        if panel.frame != r { panel.setFrame(r, display: true) }
        panel.sharingType = Self.testCapturable ? .readOnly : .none
    }

    /// Framecast's display capture leaves this window out even when it shows Framecast's other windows.
    private func registerPrivate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let id = CGWindowID(self.panel.windowNumber)
            guard id > 0, !ScreenSource.privateWindows.contains(id) else { return }
            ScreenSource.privateWindows.insert(id)
            self.studio?.engine.refreshScreenFilters()
        }
    }

    func close() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
