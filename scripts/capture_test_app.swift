// A small app used only to test Framecast's window, app and audio capture with known content.
// The window shows solid red → green → blue, changing every second (title "Framecast capture test"),
// and plays a quiet 700 Hz tone. It quits by itself after the number of seconds given (default 30).
import AppKit
import AVFoundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 30
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
win.title = "Framecast capture test"
let view = NSView(); view.wantsLayer = true
win.contentView = view
win.level = .floating                 // stay visible above Framecast during the test
win.makeKeyAndOrderFront(nil)
// Keep drawing and ticking while in the background (no App Nap throttling).
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "capture test")
let colors: [NSColor] = [NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
var tick = 0
view.layer?.backgroundColor = colors[0].cgColor
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    tick += 1
    view.layer?.backgroundColor = colors[tick % 3].cgColor
}
let engine = AVAudioEngine()
var phase = 0.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
let src = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
    let b = UnsafeMutableAudioBufferListPointer(abl)
    for f in 0..<Int(frames) {
        let v = Float(sin(phase) * 0.08); phase += 2 * .pi * 700 / 48_000
        for ch in 0..<b.count { b[ch].mData!.assumingMemoryBound(to: Float.self)[f] = v }
    }
    return noErr
}
engine.attach(src); engine.connect(src, to: engine.mainMixerNode, format: fmt)
try? engine.start()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
app.activate(ignoringOtherApps: true)
app.run()
