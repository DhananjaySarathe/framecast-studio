import Foundation
import CoreMedia
import CoreImage
import ScreenCaptureKit
import FramecastEngine

// Headless harness used to verify Framecast's engine without the UI or any capture permissions.
// Sources are procedural: a test pattern that flashes white on every whole second of the engine
// timeline and a tone that beeps on the same seconds, so A/V sync can be measured in the files.
//
//   fcverify record --seconds 12 --container mov --out DIR [--codec hevc] [--pause 4:6] [--split-seconds 5]
//   fcverify stream --url rtmp://127.0.0.1/live/test --seconds 20 [--canvas vertical]

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count { return args[i + 1] }
    return def
}
let command = args.first ?? "record"

if command == "icon" {
    // Writes the Framecast logo as an .iconset for `iconutil -c icns`.
    try AppIcon.writeIconset(to: URL(fileURLWithPath: opt("out", "build/AppIcon.iconset")))
    exit(0)
}

if command == "filters" {
    // Pixel checks for the keyers, LUT and colour correction (no capture devices needed).
    let comp = Compositor()
    let size = CGSize(width: 400, height: 200)
    func pixel(_ img: CIImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var px = [UInt8](repeating: 0, count: 4)
        comp.context.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
    // Green screen with a white square in the middle.
    let green = CIImage(color: CIColor(red: 0, green: 0.8, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: size))
    let subject = CIImage(color: .white).cropped(to: CGRect(x: 150, y: 50, width: 100, height: 100)).composited(over: green)
    let red = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(origin: .zero, size: size))
    var item = SceneItem(sourceID: UUID(), transform: .full, fit: .stretch)
    item.filters = [FilterSpec(kind: .chromaKey(ChromaKeySettings()))]
    let keyed = comp.renderItem(item, input: LayerInput(image: subject), canvas: size)!.composited(over: red)
    let bg = pixel(keyed, 20, 20), fg = pixel(keyed, 200, 100)
    print("chroma key: background pixel \(bg) (expect red), subject pixel \(fg) (expect white) →",
          bg.0 > 180 && bg.1 < 60 && fg.0 > 230 && fg.1 > 230 ? "PASS" : "FAIL")
    // Luma key: key out the dark half.
    let half = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        .composited(over: CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size)))
    var li = SceneItem(sourceID: UUID(), transform: .full, fit: .stretch)
    li.filters = [FilterSpec(kind: .lumaKey(LumaKeySettings()))]
    let lk = comp.renderItem(li, input: LayerInput(image: half), canvas: size)!.composited(over: red)
    let dark = pixel(lk, 50, 100), light = pixel(lk, 350, 100)
    print("luma key: dark side \(dark) (expect red), light side \(light) (expect white) →", dark.0 > 180 && dark.1 < 60 && light.1 > 230 ? "PASS" : "FAIL")
    // LUT: a 2-point cube that inverts colours.
    let cubePath = NSTemporaryDirectory() + "framecast-invert.cube"
    var cube = "TITLE \"invert\"\nLUT_3D_SIZE 2\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
    try cube.write(toFile: cubePath, atomically: true, encoding: .utf8)
    let lut = try CubeLUT.load(path: cubePath)
    let lutOut = lut.apply(to: red, amount: 1)
    let inv = pixel(lutOut, 10, 10)
    print("LUT invert: \(inv) (expect ~cyan 26,230,230) →", inv.0 < 60 && inv.1 > 200 && inv.2 > 200 ? "PASS" : "FAIL")
    // Colour correction: saturation 0 makes grey.
    var cc = ColorCorrection(); cc.saturation = 0
    var ci = SceneItem(sourceID: UUID(), transform: .full, fit: .stretch)
    ci.filters = [FilterSpec(kind: .colorCorrection(cc))]
    let grey = pixel(comp.renderItem(ci, input: LayerInput(image: red), canvas: size)!, 10, 10)
    print("saturation 0: \(grey) (expect r≈g≈b) →", abs(grey.0 - grey.1) < 8 && abs(grey.1 - grey.2) < 8 ? "PASS" : "FAIL")
    // Circle mask: corner of the item's frame is transparent.
    var mi = SceneItem(sourceID: UUID(), transform: .full, fit: .stretch, mask: .circle)
    mi.filters = []
    let masked = comp.renderItem(mi, input: LayerInput(image: CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))), canvas: size)!.composited(over: red)
    let corner = pixel(masked, 2, 2), centre = pixel(masked, 200, 100)
    print("circle mask: corner \(corner) (expect red), centre \(centre) (expect white) →", corner.1 < 60 && centre.1 > 230 ? "PASS" : "FAIL")
    exit(0)
}

let engine = Engine()
let bg = SourceRecord(name: "Background", kind: .color(RGBA(0.1, 0.1, 0.12)))
let pattern = SourceRecord(name: "Pattern", kind: .testPattern)
var toneRec = SourceRecord(name: "Tone", kind: .tone)
toneRec.audio = AudioSettings()
let fps = Int(opt("fps", "30")) ?? 30
engine.setCanvas(.horizontal, CanvasConfig(width: Int(opt("hw", "1920"))!, height: Int(opt("hh", "1080"))!, fps: fps))
engine.setCanvas(.vertical, CanvasConfig(width: Int(opt("vw", "1080"))!, height: Int(opt("vh", "1920"))!, fps: fps, isOn: opt("canvas", "both") != "horizontal"))
engine.sync(sources: [bg, pattern, toneRec], fpsHint: fps)
for c in CanvasKind.allCases {
    engine.setProgram([SceneItem(sourceID: bg.id, transform: .full),
                       SceneItem(sourceID: pattern.id, transform: .full, fit: .fit)],
                      for: c, transition: .cut, durationMs: 0)
}
engine.previewEvery = 0
engine.start()
Thread.sleep(forTimeInterval: 0.5)

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

switch command {
case "record":
    let seconds = Double(opt("seconds", "10"))!
    let container = ContainerFormat(rawValue: opt("container", "mov"))!
    let codec = VideoCodec(rawValue: opt("codec", "h264"))!
    let out = URL(fileURLWithPath: opt("out", "local-output/verify"))
    let split = Double(opt("split-minutes", "0"))!
    let tracks = opt("tracks", "1").split(separator: ",").compactMap { Int($0) }
    let base = opt("name", "verify")
    var specs: [RecordingSpec] = []
    for c in CanvasKind.allCases where engine.canvas(c).isOn {
        let cfg = engine.canvas(c)
        specs.append(RecordingSpec(canvas: c, container: container, codec: codec, bitrateKbps: Int(opt("kbps", "8000"))!,
                                   width: cfg.width, height: cfg.height, fps: cfg.fps, folders: [out],
                                   baseName: "\(base)-\(c.rawValue)", splitMinutes: split, audioTracks: tracks))
    }
    let recs = try engine.startRecording(specs)
    log("recording \(specs.count) canvas(es) for \(seconds)s → \(out.path)")
    let pause = opt("pause", "")
    if !pause.isEmpty {
        let parts = pause.split(separator: ":").compactMap { Double($0) }
        Thread.sleep(forTimeInterval: parts[0])
        recs.forEach { $0.pause(at: HostClock.now()) }
        log("paused at \(parts[0])s")
        Thread.sleep(forTimeInterval: parts[1] - parts[0])
        recs.forEach { $0.resume(at: HostClock.now()) }
        log("resumed at \(parts[1])s")
        Thread.sleep(forTimeInterval: seconds - parts[1])
    } else {
        Thread.sleep(forTimeInterval: seconds)
    }
    let done = DispatchSemaphore(value: 0)
    engine.stopRecording(recs, queue: .global()) { files in
        for f in files { print(f.path) }
        done.signal()
    }
    // stopRecording completes on the main queue; keep it running.
    while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let m = engine.metrics
    log("rendered: \(m.renderedFrames) late ticks: \(m.lateFrames) dropped-by-writers: \(recs.map(\.droppedFrames))")
    engine.stop()

case "stream":
    // Streams the test canvas to an RTMP server; optionally records at the same time.
    let url = opt("url", "rtmp://127.0.0.1:1935/live")
    let key = opt("key", "test")
    let seconds = Double(opt("seconds", "15"))!
    let canvas = CanvasKind(rawValue: opt("canvas", "horizontal"))!
    let cfg = engine.canvas(canvas)
    let spec = StreamSpec(name: "verify", url: url, key: key, canvas: canvas, width: cfg.width, height: cfg.height,
                          fps: cfg.fps, videoKbps: Int(opt("kbps", "4500"))!)
    let s = try engine.startStream(spec) { st in log("status: \(st)") }
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let st = s.stats
        log(String(format: "t=%.0fs sent=%lld B rate=%.0f kbps bitrate=%d queued=%.0f ms dropped=%d reconnects=%d",
                   seconds - end.timeIntervalSinceNow, st.bytesSent, st.sendKbps, st.currentBitrateKbps, st.queuedMs, st.droppedFrames, st.reconnects))
    }
    engine.stopStream(s)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    engine.stop()

case "capture":
    // Records one capture source through the engine (same ScreenCaptureKit code the app uses).
    //   --kind display|window|app|sysaudio|appaudio  --target <window title text | bundle id>
    let kind = opt("kind", "display"), target = opt("target", "")
    let seconds = Double(opt("seconds", "5"))!
    let out = URL(fileURLWithPath: opt("out", "local-output/capture-test"))
    var rec: SourceRecord
    switch kind {
    case "window":
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let w = content.windows.first(where: { ($0.title ?? "").contains(target) }) else { log("window not found: \(target)"); exit(3) }
        rec = SourceRecord(name: "win", kind: .window(bundleID: w.owningApplication?.bundleIdentifier ?? "", title: w.title ?? "", windowID: w.windowID))
    case "app": rec = SourceRecord(name: "app", kind: .application(bundleID: target, name: target))
    case "sysaudio": rec = SourceRecord(name: "sys", kind: .systemAudio)
    case "appaudio": rec = SourceRecord(name: "appaudio", kind: .appAudio(bundleID: target, name: target))
    default: rec = SourceRecord(name: "display", kind: .display(displayID: 0))
    }
    // Only the captured source: no pattern, no tone.
    var srcs = [bg, rec]
    if !rec.kind.hasVideo { srcs.append(pattern) }
    engine.sync(sources: srcs, fpsHint: fps)
    for c in CanvasKind.allCases {
        engine.setProgram([SceneItem(sourceID: bg.id, transform: .full),
                           SceneItem(sourceID: rec.kind.hasVideo ? rec.id : pattern.id, transform: .full, fit: .fit)],
                          for: c, transition: .cut, durationMs: 0)
    }
    engine.mixer.removeSource(toneRec.id)
    Thread.sleep(forTimeInterval: 2.5)
    log("source state: \(String(describing: engine.state(of: rec.id)))")
    let cfg = engine.canvas(.horizontal)
    let recs = try engine.startRecording([RecordingSpec(canvas: .horizontal, container: .mov, codec: .h264, bitrateKbps: 8000,
                                                        width: cfg.width, height: cfg.height, fps: cfg.fps, folders: [out],
                                                        baseName: "capture-\(kind)")])
    Thread.sleep(forTimeInterval: seconds)
    let done = DispatchSemaphore(value: 0)
    engine.stopRecording(recs, queue: .global()) { files in files.forEach { print($0.path) }; done.signal() }
    while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    log("source state at end: \(String(describing: engine.state(of: rec.id)))")
    engine.stop()

default:
    log("unknown command \(command)")
    exit(2)
}
